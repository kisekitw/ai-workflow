#Requires -Version 5.1
<#
.SYNOPSIS
    Structural fact-gatherer for /verify-archaeology evaluator skill.
    Checks that csharp-archaeology output files exist, are non-empty,
    contain no unfilled placeholders, and extracts key numeric facts.

.PARAMETER TargetWorkspace
    Root folder of the target C# workspace (where .analysis/ lives).

.PARAMETER Layer
    Which layer(s) to check: preflight | layer1 | layer2 | synthesis | all
    Default: all

.PARAMETER Quiet
    Suppress progress output to stderr; only emit JSON to stdout.

.OUTPUTS
    JSON object to stdout. See schema in plan documentation.
#>
param(
    [Parameter(Mandatory=$true)]
    [string]$TargetWorkspace,

    [ValidateSet("preflight","layer1","layer2","synthesis","all")]
    [string]$Layer = "all",

    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── helpers ──────────────────────────────────────────────────────────────────

function Write-Progress-Safe {
    param([string]$msg)
    if (-not $Quiet) { Write-Host "[verify] $msg" -ForegroundColor DarkGray }
}

function New-Check {
    param([string]$Id, [string]$Description, [string]$Result, [string]$Detail)
    [PSCustomObject]@{ id=$Id; description=$Description; result=$Result; detail=$Detail }
}

function Check-FileExists {
    param([string]$Id, [string]$Description, [string]$FilePath)
    if (Test-Path $FilePath) {
        $size = (Get-Item $FilePath).Length
        if ($size -eq 0) {
            return New-Check $Id $Description "FAIL" "File exists but is empty: $FilePath"
        }
        return New-Check $Id $Description "PASS" "OK ($size bytes)"
    }
    return New-Check $Id $Description "FAIL" "Missing: $FilePath"
}

function Check-NoPlaceholders {
    param([string]$Id, [string]$FilePath)
    $desc = "No unfilled {{PLACEHOLDERS}} in $(Split-Path $FilePath -Leaf)"
    if (-not (Test-Path $FilePath)) {
        return New-Check $Id $desc "FAIL" "File missing, cannot check placeholders"
    }
    try {
        # Read only first 50KB to avoid memory issues on large HTML
        $content = Get-Content $FilePath -Raw -Encoding UTF8 -ErrorAction Stop
        if ($content.Length -gt 51200) { $content = $content.Substring(0, 51200) }
        $placeholderMatches = [regex]::Matches($content, '\{\{[A-Z_]{2,}\}\}')
        if ($placeholderMatches.Count -gt 0) {
            $found = ($placeholderMatches | ForEach-Object { $_.Value } | Select-Object -Unique) -join ", "
            return New-Check $Id $desc "FAIL" "Found unfilled placeholders: $found"
        }
        return New-Check $Id $desc "PASS" "No placeholders found"
    } catch {
        return New-Check $Id $desc "FAIL" "Read error: $_"
    }
}

function Extract-HtmlDecision {
    param([string]$FilePath)
    # Try to extract Decision and Confidence from first 3000 chars of HTML
    if (-not (Test-Path $FilePath)) { return $null, $null }
    try {
        $content = Get-Content $FilePath -Raw -Encoding UTF8 -ErrorAction Stop
        if ($content.Length -gt 15000) { $content = $content.Substring(0, 15000) }
        # Pattern 1: data-decision="Extract" or value="Extract"
        $dm = [regex]::Match($content, 'data-decision="([^"]+)"')
        if (-not $dm.Success) {
            # Pattern 2: Decision</... ...> Extract (text near "Decision")
            $dm = [regex]::Match($content, '(?i)Recommended Action[^>]*>[^<]*<[^>]+>([A-Za-z ]+)<')
        }
        $cm = [regex]::Match($content, '(?i)Confidence[^>]*>[^<]*<[^>]+>(HIGH|MEDIUM|LOW)<')
        if (-not $cm.Success) {
            $cm = [regex]::Match($content, '\b(HIGH|MEDIUM|LOW)\b')
        }
        $decision  = if ($dm.Success) { $dm.Groups[1].Value.Trim() } else { $null }
        $confidence = if ($cm.Success) { $cm.Groups[1].Value.Trim() } else { $null }
        return $decision, $confidence
    } catch {
        return $null, $null
    }
}

# ── paths ────────────────────────────────────────────────────────────────────

$analysisDir  = Join-Path $TargetWorkspace ".analysis"
$tmpDir       = Join-Path $analysisDir "tmp"

$preflightJson    = Join-Path $tmpDir "preflight-report.json"
$depMapJson       = Join-Path $tmpDir "dependency-map.json"
$gitStabilityCsv  = Join-Path $tmpDir "git-stability.csv"
$deadCandidateCsv = Join-Path $tmpDir "dead-candidates.csv"
$globalMapHtml    = Join-Path $analysisDir "00-global-map.html"
$parallelTasksMd  = Join-Path $analysisDir "parallel-tasks.md"
$copilotDraftMd   = Join-Path $analysisDir "copilot-instructions-draft.md"
$verificationMd   = Join-Path $analysisDir "verification-report.md"

# ── checks collection ────────────────────────────────────────────────────────

$checks = [System.Collections.Generic.List[PSCustomObject]]::new()
$fatalError = $null
$extractedFacts = [ordered]@{}
$layer2DiscoveredModules = @()

# Guard: .analysis/ must exist for any layer
if (-not (Test-Path $analysisDir)) {
    $fatalError = ".analysis/ directory not found at: $analysisDir — re-run step0-preflight.ps1"
}

# ── PREFLIGHT checks ──────────────────────────────────────────────────────────

if ($null -eq $fatalError -and ($Layer -eq "all" -or $Layer -eq "preflight")) {
    Write-Progress-Safe "Checking preflight outputs..."

    $checks.Add((Check-FileExists "S-P-1" "preflight-report.json exists and non-empty" $preflightJson))

    if (Test-Path $preflightJson) {
        try {
            $pf = Get-Content $preflightJson -Raw -Encoding UTF8 | ConvertFrom-Json
            $checks.Add((New-Check "S-P-2" "preflight-report.json is valid JSON" "PASS" "Parsed OK"))
            if ($pf.PSObject.Properties.Name -contains "complexityTier") {
                $checks.Add((New-Check "S-P-3" "complexityTier present" "PASS" "Tier: $($pf.complexityTier)"))
                $extractedFacts["preflightTier"] = $pf.complexityTier
            } else {
                $checks.Add((New-Check "S-P-3" "complexityTier present" "WARN" "Field missing in preflight JSON"))
            }
        } catch {
            $checks.Add((New-Check "S-P-2" "preflight-report.json is valid JSON" "FAIL" "Parse error: $_"))
        }
    }
}

# ── LAYER 1 checks ────────────────────────────────────────────────────────────

if ($null -eq $fatalError -and ($Layer -eq "all" -or $Layer -eq "layer1")) {
    Write-Progress-Safe "Checking Layer 1 outputs..."

    $checks.Add((Check-FileExists "S-L1-1" "dependency-map.json exists and non-empty" $depMapJson))
    $checks.Add((Check-FileExists "S-L1-2" "git-stability.csv exists and non-empty" $gitStabilityCsv))
    $checks.Add((Check-FileExists "S-L1-3" "dead-candidates.csv exists and non-empty" $deadCandidateCsv))
    $checks.Add((Check-FileExists "S-L1-4" "00-global-map.html exists and non-empty" $globalMapHtml))
    $checks.Add((Check-FileExists "S-L1-5" "parallel-tasks.md (v1) exists and non-empty" $parallelTasksMd))

    # Placeholder check on HTML
    $checks.Add((Check-NoPlaceholders "S-L1-6" $globalMapHtml))

    # Extract facts from dependency-map.json
    if (Test-Path $depMapJson) {
        try {
            $dm = Get-Content $depMapJson -Raw -Encoding UTF8 | ConvertFrom-Json
            $totalProjects = 0
            $islandCount   = 0
            $topHubName    = $null
            $topHubScore   = 0

            if ($dm.PSObject.Properties.Name -contains "projects") {
                $totalProjects = @($dm.projects).Count
            } elseif ($dm.PSObject.Properties.Name -contains "totalProjects") {
                $totalProjects = [int]$dm.totalProjects
            }
            if ($dm.PSObject.Properties.Name -contains "islands") {
                $islandCount = @($dm.islands).Count
            } elseif ($dm.PSObject.Properties.Name -contains "islandCount") {
                $islandCount = [int]$dm.islandCount
            }
            if ($dm.PSObject.Properties.Name -contains "hubs" -and @($dm.hubs).Count -gt 0) {
                $topHub = @($dm.hubs)[0]
                if ($topHub.PSObject.Properties.Name -contains "name")     { $topHubName  = $topHub.name }
                if ($topHub.PSObject.Properties.Name -contains "hubScore") { $topHubScore = [int]$topHub.hubScore }
            }

            $extractedFacts["dependencyMapTotalProjects"] = $totalProjects
            $extractedFacts["islandCount"]  = $islandCount
            $extractedFacts["topHubName"]   = $topHubName
            $extractedFacts["topHubScore"]  = $topHubScore

            $checks.Add((New-Check "S-L1-7" "dependency-map.json is valid JSON with data" "PASS" "$totalProjects projects, $islandCount islands"))
        } catch {
            $checks.Add((New-Check "S-L1-7" "dependency-map.json is valid JSON with data" "FAIL" "Parse error: $_"))
        }
    }

    # Extract facts from git-stability.csv
    if (Test-Path $gitStabilityCsv) {
        try {
            $git = Import-Csv $gitStabilityCsv -Encoding UTF8
            # V6: Validate GitStatus column exists before using it
            if (@($git).Count -gt 0 -and ($git[0].PSObject.Properties.Name -notcontains "GitStatus")) {
                $availCols = ($git[0].PSObject.Properties.Name) -join ", "
                $checks.Add((New-Check "S-L1-8" "git-stability.csv parseable with GitStatus column" "WARN" "Column 'GitStatus' not found. Available columns: $availCols"))
            } else {
                $activeCount = @($git | Where-Object { $_.GitStatus -eq "ACTIVE" }).Count
                $staleCount  = @($git | Where-Object { $_.GitStatus -eq "STALE"  }).Count
                $frozenCount = @($git | Where-Object { $_.GitStatus -eq "FROZEN" }).Count
                $extractedFacts["gitActiveCount"] = $activeCount
                $extractedFacts["gitStaleCount"]  = $staleCount
                $extractedFacts["gitFrozenCount"] = $frozenCount
                $checks.Add((New-Check "S-L1-8" "git-stability.csv parseable with GitStatus column" "PASS" "ACTIVE=$activeCount STALE=$staleCount FROZEN=$frozenCount"))
            }
        } catch {
            $checks.Add((New-Check "S-L1-8" "git-stability.csv parseable with GitStatus column" "FAIL" "Parse/import error: $_"))
        }
    }

    # Extract dead count
    if (Test-Path $deadCandidateCsv) {
        try {
            $dead = Import-Csv $deadCandidateCsv -Encoding UTF8
            $deadCount = @($dead).Count
            $extractedFacts["deadCandidateCount"] = $deadCount
            $checks.Add((New-Check "S-L1-9" "dead-candidates.csv row count" "PASS" "$deadCount candidates"))
        } catch {
            $checks.Add((New-Check "S-L1-9" "dead-candidates.csv row count" "FAIL" "Parse/import error: $_"))
        }
    }
}

# ── LAYER 2 checks ────────────────────────────────────────────────────────────

if ($null -eq $fatalError -and ($Layer -eq "all" -or $Layer -eq "layer2")) {
    Write-Progress-Safe "Checking Layer 2 outputs..."

    # V4: Pre-load git-stability.csv into a lookup dict for per-module git status
    $gitStatusByModule = @{}
    if (Test-Path $gitStabilityCsv) {
        try {
            $gitRows = Import-Csv $gitStabilityCsv -Encoding UTF8
            if (@($gitRows).Count -gt 0) {
                $nameCol = $null
                foreach ($candidateCol in @("ModuleName","ProjectName","Project","Name","Assembly")) {
                    if ($gitRows[0].PSObject.Properties.Name -contains $candidateCol) {
                        $nameCol = $candidateCol
                        break
                    }
                }
                if ($null -ne $nameCol) {
                    foreach ($gitRow in $gitRows) {
                        $gitStatusByModule[$gitRow.$nameCol] = $gitRow.GitStatus
                    }
                }
            }
        } catch { }
    }

    # Discover module subfolders (one level deep under .analysis/)
    $moduleData = [ordered]@{}
    if (Test-Path $analysisDir) {
        $moduleDirs = Get-ChildItem $analysisDir -Directory -ErrorAction SilentlyContinue |
                      Where-Object { $_.Name -ne "tmp" }
        foreach ($modDir in $moduleDirs) {
            $modName = $modDir.Name
            $layer2DiscoveredModules += $modName

            $apiJson     = Join-Path $modDir.FullName "$modName-api.json"
            $usageCsv    = Join-Path $modDir.FullName "$modName-usage.csv"
            $couplingCsv = Join-Path $modDir.FullName "$modName-coupling-in.csv"
            $vitalityCsv = Join-Path $modDir.FullName "$modName-vitality.csv"
            $reportHtml  = Join-Path $modDir.FullName "$modName-report.html"

            $checks.Add((Check-FileExists "S-L2-$modName-1" "[$modName] api.json exists" $apiJson))
            $checks.Add((Check-FileExists "S-L2-$modName-2" "[$modName] usage.csv exists" $usageCsv))
            # coupling-in known bug: WARN not FAIL; V3: also check content is non-empty
            if (Test-Path $couplingCsv) {
                $sz = (Get-Item $couplingCsv).Length
                try {
                    $couplingRows = @(Import-Csv $couplingCsv -Encoding UTF8)
                    $couplingRowCount = $couplingRows.Count
                    if ($couplingRowCount -eq 0) {
                        $checks.Add((New-Check "S-L2-$modName-3" "[$modName] coupling-in.csv content (known inversion bug — WARN)" "WARN" "File exists but has no data rows (header only). Note: coupling-in logic currently inverted."))
                    } else {
                        $checks.Add((New-Check "S-L2-$modName-3" "[$modName] coupling-in.csv content (known inversion bug — WARN)" "WARN" "File exists with $couplingRowCount data rows ($sz bytes). Note: coupling-in logic currently inverted; data shows intra-module, not incoming callers."))
                    }
                } catch {
                    $checks.Add((New-Check "S-L2-$modName-3" "[$modName] coupling-in.csv content (known inversion bug — WARN)" "WARN" "File exists ($sz bytes) but could not parse as CSV. Note: coupling-in logic currently inverted."))
                }
            } else {
                $checks.Add((New-Check "S-L2-$modName-3" "[$modName] coupling-in.csv content (known inversion bug — WARN)" "WARN" "File missing — WARN only due to known inversion bug"))
            }
            $checks.Add((Check-FileExists "S-L2-$modName-4" "[$modName] vitality.csv exists" $vitalityCsv))
            $checks.Add((Check-FileExists "S-L2-$modName-5" "[$modName] report.html exists" $reportHtml))
            $checks.Add((Check-NoPlaceholders "S-L2-$modName-6" $reportHtml))

            # Extract decision and confidence from report HTML
            $decision, $confidence = Extract-HtmlDecision $reportHtml

            # Validate decision value
            $validDecisions = @("Delete","Extract","Refactor","Leave alone")
            if ($null -ne $decision -and $validDecisions -notcontains $decision) {
                $checks.Add((New-Check "S-L2-$modName-7" "[$modName] Decision value is valid" "FAIL" "Invalid Decision: '$decision'. Must be one of: $($validDecisions -join ', ')"))
            } elseif ($null -ne $decision) {
                $checks.Add((New-Check "S-L2-$modName-7" "[$modName] Decision value is valid" "PASS" "Decision=$decision"))
            } else {
                $checks.Add((New-Check "S-L2-$modName-7" "[$modName] Decision value is valid" "FAIL" "Could not extract Decision from report HTML (checked first 15000 chars) — verify data-decision attribute exists in template"))
            }

            # Validate confidence value
            $validConfidences = @("HIGH","MEDIUM","LOW")
            if ($null -ne $confidence -and $validConfidences -notcontains $confidence) {
                $checks.Add((New-Check "S-L2-$modName-8" "[$modName] Confidence value is valid" "FAIL" "Invalid Confidence: '$confidence'. Must be HIGH/MEDIUM/LOW"))
            } elseif ($null -ne $confidence) {
                $checks.Add((New-Check "S-L2-$modName-8" "[$modName] Confidence value is valid" "PASS" "Confidence=$confidence"))
            } else {
                $checks.Add((New-Check "S-L2-$modName-8" "[$modName] Confidence value is valid" "FAIL" "Could not extract Confidence from report HTML (checked first 15000 chars) — verify HIGH/MEDIUM/LOW appears in template output"))
            }

            # V1: Extract apiCount from api.json
            $apiCount = 0
            if (Test-Path $apiJson) {
                try {
                    $apiContent = Get-Content $apiJson -Raw -Encoding UTF8 | ConvertFrom-Json
                    if ($apiContent -is [System.Array]) {
                        $apiCount = $apiContent.Count
                    } elseif ($apiContent.PSObject.Properties.Name -contains "items") {
                        $apiCount = @($apiContent.items).Count
                    } elseif ($apiContent.PSObject.Properties.Name -contains "apis") {
                        $apiCount = @($apiContent.apis).Count
                    }
                } catch {
                    # non-fatal: apiCount stays 0
                }
            }

            # Extract usage facts
            $zeroCallerCount = 0
            $testCallerCount = 0
            if (Test-Path $usageCsv) {
                try {
                    $usage = Import-Csv $usageCsv -Encoding UTF8
                    # V6: Validate required columns exist
                    if (@($usage).Count -gt 0) {
                        $usageCols = $usage[0].PSObject.Properties.Name
                        $missingCols = @()
                        if ($usageCols -notcontains "ZeroCaller")      { $missingCols += "ZeroCaller" }
                        if ($usageCols -notcontains "TestCallerCount") { $missingCols += "TestCallerCount" }
                        if ($missingCols.Count -gt 0) {
                            $checks.Add((New-Check "S-L2-$modName-9" "[$modName] usage.csv has required columns" "WARN" "Missing: $($missingCols -join ', '). Available: $($usageCols -join ', ')"))
                        } else {
                            $checks.Add((New-Check "S-L2-$modName-9" "[$modName] usage.csv has required columns" "PASS" "ZeroCaller and TestCallerCount confirmed"))
                        }
                    }
                    $zeroCallerCount = @($usage | Where-Object { $_.ZeroCaller -eq "true" -or $_.ZeroCaller -eq "True" -or $_.ZeroCaller -eq "1" }).Count
                    $testCallerCount = 0
                    foreach ($row in $usage) {
                        if ($row.PSObject.Properties.Name -contains "TestCallerCount") {
                            $testCallerCount += [int]($row.TestCallerCount)
                        }
                    }
                } catch {
                    # non-fatal
                }
            }

            # V4: Lookup per-module git status from pre-loaded dict
            $modGitStatus = if ($gitStatusByModule.ContainsKey($modName)) { $gitStatusByModule[$modName] } else { "UNKNOWN" }

            $moduleData[$modName] = [ordered]@{
                extractedDecision   = $decision
                extractedConfidence = $confidence
                zeroCallerCount     = $zeroCallerCount
                testCallerCount     = $testCallerCount
                apiCount            = $apiCount
                gitStatus           = $modGitStatus
            }
        }
    }

    $extractedFacts["layer2Modules"] = $moduleData
}

# ── SYNTHESIS checks ──────────────────────────────────────────────────────────

if ($null -eq $fatalError -and ($Layer -eq "all" -or $Layer -eq "synthesis")) {
    Write-Progress-Safe "Checking Phase 0 Synthesis outputs..."

    $checks.Add((Check-FileExists "S-SYN-1" "copilot-instructions-draft.md exists" $copilotDraftMd))
    $checks.Add((Check-FileExists "S-SYN-2" "parallel-tasks.md (final) exists" $parallelTasksMd))

    if (Test-Path $copilotDraftMd) {
        try {
            $ci = Get-Content $copilotDraftMd -Raw -Encoding UTF8
            $hasNoGo = $ci -match "No-go zones"
            $hasVocab = $ci -match "(?i)(module|vocabulary|詞彙)"
            if ($hasNoGo) {
                $checks.Add((New-Check "S-SYN-3" "copilot-instructions-draft.md has No-go zones section" "PASS" "Section found"))
                # V5: Check the section has actual content beyond the heading
                $noGoMatch = [regex]::Match($ci, '(?s)## No-go zones\s*\r?\n(.*?)(?:\r?\n## |\z)')
                if ($noGoMatch.Success) {
                    $noGoLines = @($noGoMatch.Groups[1].Value -split '\r?\n' | Where-Object { $_.Trim().Length -gt 0 })
                    if ($noGoLines.Count -eq 0) {
                        $checks.Add((New-Check "S-SYN-3b" "No-go zones section has content" "WARN" "Section heading present but no content — section may be empty or placeholder only"))
                    } else {
                        $checks.Add((New-Check "S-SYN-3b" "No-go zones section has content" "PASS" "$($noGoLines.Count) line(s) of content found"))
                    }
                } else {
                    $checks.Add((New-Check "S-SYN-3b" "No-go zones section has content" "WARN" "Could not extract section body for content validation"))
                }
            } else {
                $checks.Add((New-Check "S-SYN-3" "copilot-instructions-draft.md has No-go zones section" "FAIL" "No-go zones section missing"))
            }
            if ($hasVocab) {
                $checks.Add((New-Check "S-SYN-4" "copilot-instructions-draft.md has module vocabulary" "PASS" "Vocabulary section found"))
            } else {
                $checks.Add((New-Check "S-SYN-4" "copilot-instructions-draft.md has module vocabulary" "WARN" "Vocabulary section may be missing"))
            }
        } catch {
            $checks.Add((New-Check "S-SYN-3" "copilot-instructions-draft.md readable" "FAIL" "Read error: $_"))
        }
    }

    if (Test-Path $parallelTasksMd) {
        try {
            $pt = Get-Content $parallelTasksMd -Raw -Encoding UTF8
            $hasTaskA = $pt -match "Task A"
            $hasTaskB = $pt -match "Task B"
            if ($hasTaskA -and $hasTaskB) {
                $checks.Add((New-Check "S-SYN-5" "parallel-tasks.md has Task A and Task B" "PASS" "Both tasks present"))
            } else {
                $missing = @()
                if (-not $hasTaskA) { $missing += "Task A" }
                if (-not $hasTaskB) { $missing += "Task B" }
                $checks.Add((New-Check "S-SYN-5" "parallel-tasks.md has Task A and Task B" "WARN" "Missing: $($missing -join ', ')"))
            }
        } catch {
            $checks.Add((New-Check "S-SYN-5" "parallel-tasks.md readable" "FAIL" "Read error: $_"))
        }
    }
}

# ── summary ───────────────────────────────────────────────────────────────────

$passed  = @($checks | Where-Object { $_.result -eq "PASS" }).Count
$warned  = @($checks | Where-Object { $_.result -eq "WARN" }).Count
$failed  = @($checks | Where-Object { $_.result -eq "FAIL" }).Count

# ── output ────────────────────────────────────────────────────────────────────

$output = [ordered]@{
    scriptVersion            = "1.2"
    executedAt               = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    targetLayer              = $Layer
    targetWorkspace          = $TargetWorkspace
    fatalError               = $fatalError
    checks                   = $checks.ToArray()
    summary                  = [ordered]@{ passed=$passed; warned=$warned; failed=$failed }
    layer2DiscoveredModules  = $layer2DiscoveredModules
    extractedFacts           = $extractedFacts
}

$output | ConvertTo-Json -Depth 10
