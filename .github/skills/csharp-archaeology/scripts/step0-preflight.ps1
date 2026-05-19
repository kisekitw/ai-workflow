# step0-preflight.ps1
# Phase 0 Layer 0.5 — Preflight：建立 .analysis/ 資料夾結構，評估 codebase 規模
# 輸出：.analysis/tmp/preflight-report.json
#
# 同時建立 .analysis/.gitignore（* 全排除）避免分析產物進 target repo

$ErrorActionPreference = 'Stop'
$root = (Get-Location).Path

# 建立輸出資料夾結構
New-Item -ItemType Directory -Force -Path ".analysis/tmp" | Out-Null
"*" | Out-File ".analysis/.gitignore" -Encoding UTF8 -Force

Write-Host "=== Phase 0 Preflight — 分析 codebase 基本數據 ==="

$excludePattern = '(?i)(Ex\.csproj$|[Tt]est|UnitTest|TestProject)'

# C# project 掃描（排除 Ex、測試、vcxproj）
$allCsProj = Get-ChildItem -Recurse -Filter "*.csproj" |
  Where-Object { $_.Name -notmatch $excludePattern -and $_.Extension -eq ".csproj" }

$allVcxProj = Get-ChildItem -Recurse -Filter "*.vcxproj"

# 測試 project
$testProjs = Get-ChildItem -Recurse -Filter "*.csproj" |
  Where-Object { $_.Name -match '(?i)([Tt]est|UnitTest|TestProject)' }

# Target framework 分佈
$frameworkDist = @{}
foreach ($proj in $allCsProj) {
  try {
    [xml]$xml = Get-Content $proj.FullName -Encoding UTF8
    $tfNode = $xml.SelectSingleNode("//TargetFramework")
    $tf = if ($tfNode) { $tfNode.'#text' } else { $null }
    if (-not $tf) {
      $tfNode = $xml.SelectSingleNode("//TargetFrameworks")
      $tf = if ($tfNode) { $tfNode.'#text' } else { $null }
    }
    if (-not $tf) {
      $tfNode = $xml.SelectSingleNode("//TargetFrameworkVersion")
      $tf = if ($tfNode) { $tfNode.'#text' } else { $null }
    }
    if ($tf) {
      $tf = $tf.Trim()
      if ($frameworkDist[$tf]) { $frameworkDist[$tf]++ } else { $frameworkDist[$tf] = 1 }
    }
  } catch { }
}

# .cs 檔案統計
$allCsFiles = Get-ChildItem -Recurse -Filter "*.cs" | Where-Object {
  $_.FullName -notmatch '\\obj\\' -and $_.FullName -notmatch '\\bin\\'
}

Write-Host "統計 LOC，請稍候..."
$totalLoc = 0
foreach ($f in $allCsFiles) {
  try {
    $lines = [System.IO.File]::ReadAllLines($f.FullName).Count
    $totalLoc += $lines
  } catch { }
}

# NuGet PackageReference 總數
$nugetCount = 0
foreach ($proj in $allCsProj) {
  try {
    [xml]$xml = Get-Content $proj.FullName -Encoding UTF8
    $nugetCount += $xml.SelectNodes("//PackageReference").Count
  } catch { }
}

# CI config 存在性
$ciConfigs = @()
if (Test-Path ".github/workflows") {
  $ciConfigs += @(Get-ChildItem ".github/workflows" -Filter "*.yml" |
    Select-Object -ExpandProperty Name)
}
if (Test-Path "bitbucket-pipelines.yml") { $ciConfigs += "bitbucket-pipelines.yml" }
if (Test-Path "azure-pipelines.yml")     { $ciConfigs += "azure-pipelines.yml" }

# .sln 檔案
$slnFiles = @(Get-ChildItem -Recurse -Filter "*.sln" | Select-Object -ExpandProperty Name)

# Complexity tier（依 C# project 數量）
$projCount = $allCsProj.Count
$tier = if ($projCount -lt 30)    { "SMALL" }
        elseif ($projCount -lt 100) { "MEDIUM" }
        else                        { "LARGE" }

$timeEstimate = switch ($tier) {
  "SMALL"  { @{ step3 = "1-2 min";   layer1Total = "5-10 min" } }
  "MEDIUM" { @{ step3 = "5-10 min";  layer1Total = "15-30 min" } }
  "LARGE"  { @{ step3 = "15-30 min"; layer1Total = "45-90 min" } }
}

$output = @{
  generatedAt        = (Get-Date -Format "yyyy-MM-dd HH:mm")
  slnFiles           = $slnFiles
  csharpProjectCount = $allCsProj.Count
  vcxprojCount       = $allVcxProj.Count
  testProjectCount   = $testProjs.Count
  testProjectNames   = @($testProjs | Select-Object -ExpandProperty BaseName)
  csFileCount        = $allCsFiles.Count
  estimatedLOC       = $totalLoc
  nugetPackageRefs   = $nugetCount
  targetFrameworks   = $frameworkDist
  ciConfigs          = $ciConfigs
  complexityTier     = $tier
  timeEstimate       = $timeEstimate
}

$output | ConvertTo-Json -Depth 5 |
  Out-File ".analysis/tmp/preflight-report.json" -Encoding UTF8 -Force

Write-Host ""
Write-Host "=== preflight-report.json 產出完成 ==="
Write-Host "C# 專案數：$($allCsProj.Count) 個  →  Complexity Tier：$tier"
Write-Host ".cs 檔案數：$($allCsFiles.Count)  |  估計 LOC：$totalLoc"
Write-Host "測試專案：$($testProjs.Count) 個"
Write-Host "NuGet PackageReference：$nugetCount 個"
if ($frameworkDist.Count -gt 0) {
  Write-Host "Target Frameworks：$(($frameworkDist.GetEnumerator() | ForEach-Object { "$($_.Key)($($_.Value))" }) -join ', ')"
}
if ($ciConfigs.Count -gt 0) {
  Write-Host "CI Configs：$($ciConfigs -join ', ')"
} else {
  Write-Host "CI Configs：未找到"
}
Write-Host ""
Write-Host "預估執行時間："
Write-Host "  Step 3 (dead scan)：$($timeEstimate.step3)"
Write-Host "  Layer 1 總計      ：$($timeEstimate.layer1Total)"
Write-Host ""
Write-Host ".analysis/ 資料夾已建立，.gitignore 已放置（分析產物不會進 target repo）"
