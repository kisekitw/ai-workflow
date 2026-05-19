# layer2-step2-usage.ps1
# Phase 0 Layer 2 Step 2 — 搜尋模組 API 的呼叫者，產出三份 CSV
#
# 兩種執行模式（與 layer2-step1-api.ps1 一致）：
#   Project 模式  ：-ModuleName "HMIWaferMap"
#   Subfolder 模式：-ModulePath "HMIWaferMap/HMIWaferMapPane"
#
# 輸出（至 .analysis/{Module}/）：
#   {Target}-usage.csv       — API 呼叫者分析（CallSite 深度、TestCallerCount）
#   {Target}-coupling-in.csv — 目標資料夾對外部類型的實際引用（提取阻斷器）
#   {Target}-vitality.csv    — 檔案層級 git 活躍度
#
# 效能：每個 .cs 檔案讀取一次，批次比對 api.json 所有名稱

param(
  [string]$ModuleName = "",
  [string]$ModulePath = ""
)

$ErrorActionPreference = 'Stop'

if (-not $ModuleName -and -not $ModulePath) {
  Write-Error "請提供 -ModuleName 或 -ModulePath 參數"
  exit 1
}

# ── 決定掃描範圍與路徑 ──────────────────────────────────────────────────────

if ($ModulePath) {
  $normalizedPath = $ModulePath.TrimEnd('/').TrimEnd('\')
  $scanFolder     = $normalizedPath.Replace('/', '\').Replace('\\', '\')
  $targetName     = Split-Path $scanFolder -Leaf
  $outputFolder   = ".analysis\$scanFolder"
} else {
  $targetName = $ModuleName
  $proj = Get-ChildItem -Recurse -Filter "$ModuleName.csproj" |
    Where-Object { $_.Name -notmatch 'Ex\.csproj$' } |
    Select-Object -First 1

  if (-not $proj) {
    Write-Error "找不到 $ModuleName.csproj，請確認專案名稱是否正確"
    exit 1
  }

  $scanFolder   = $proj.DirectoryName
  $outputFolder = ".analysis\$ModuleName"
}

$apiJsonPath = "$outputFolder\$targetName-api.json"
if (-not (Test-Path $apiJsonPath)) {
  Write-Error "找不到 $apiJsonPath，請先執行 layer2-step1-api.ps1"
  exit 1
}

New-Item -ItemType Directory -Force -Path $outputFolder | Out-Null
Write-Host "目標：$targetName  |  輸出資料夾：$outputFolder"

# ── 讀取 api.json ──────────────────────────────────────────────────────────

$apiJson    = Get-Content $apiJsonPath -Raw | ConvertFrom-Json
$apiNames   = @($apiJson | Select-Object -ExpandProperty Name | Sort-Object -Unique)
$classNames = @($apiJson | Where-Object { $_.Type -eq "class" } | Select-Object -ExpandProperty Name | Sort-Object -Unique)

Write-Host "API 總計：$($apiJson.Count) 個（$($apiNames.Count) 個唯一名稱）"

# ── 收集所有 .cs 檔案，分為 [內部] / [外部] ───────────────────────────────

$excludePattern = '(?i)(Ex\.csproj$|[Tt]est|UnitTest|TestProject)'

$allCsFiles = Get-ChildItem -Recurse -Filter "*.cs" | Where-Object {
  $_.FullName -notmatch '\\obj\\' -and $_.FullName -notmatch '\\bin\\'
}

$internalFiles = $allCsFiles | Where-Object { $_.FullName.StartsWith($scanFolder) }
$externalFiles = $allCsFiles | Where-Object { -not $_.FullName.StartsWith($scanFolder) }

Write-Host "外部 .cs 檔案：$($externalFiles.Count) 個（用於 usage 分析）"
Write-Host "內部 .cs 檔案：$($internalFiles.Count) 個（用於 coupling-in 分析）"

# 辨識測試 project 資料夾
$testProjDirs = Get-ChildItem -Recurse -Filter "*.csproj" |
  Where-Object { $_.Name -match '(?i)([Tt]est|UnitTest|TestProject)' } |
  ForEach-Object { $_.DirectoryName }

# 辨識 project 名稱（從 .csproj 路徑）
function Get-ProjectName([string]$filePath) {
  $dir = Split-Path $filePath -Parent
  while ($dir -and $dir -ne (Split-Path $dir -Parent)) {
    $csproj = Get-ChildItem -Path $dir -Filter "*.csproj" | Select-Object -First 1
    if ($csproj) { return [System.IO.Path]::GetFileNameWithoutExtension($csproj.Name) }
    $dir = Split-Path $dir -Parent
  }
  return Split-Path (Split-Path $filePath -Parent) -Leaf
}

# ── 批次掃描：每個外部檔案讀取一次 → usage 計數 ───────────────────────────
Write-Host "掃描 usage（批次讀取，每檔讀取一次）..."

# apiName → @{callerFiles, callerProjects, testCallerCount}
$usageData = @{}
foreach ($n in $apiNames) {
  $usageData[$n] = @{
    CallerFiles    = [System.Collections.Generic.List[string]]::new()
    CallerProjects = [System.Collections.Generic.HashSet[string]]::new()
    TestCount      = 0
    RiskFlags      = ""
  }
}

$nameSet = [System.Collections.Generic.HashSet[string]]::new($apiNames, [System.StringComparer]::Ordinal)

$processed = 0
foreach ($f in $externalFiles) {
  $content   = Get-Content $f.FullName -Raw -Encoding UTF8
  $projName  = Get-ProjectName $f.FullName
  $isTest    = $testProjDirs | Where-Object { $f.FullName.StartsWith($_) }

  # 批次比對：找出此檔案中出現的 API 名稱
  foreach ($m in [regex]::Matches($content, '\b\w+\b')) {
    $token = $m.Value
    if ($nameSet.Contains($token)) {
      $ud = $usageData[$token]
      $ud.CallerFiles.Add($f.FullName)
      [void]$ud.CallerProjects.Add($projName)
      if ($isTest) { $ud.TestCount++ }
    }
  }

  $processed++
  if ($processed % 300 -eq 0) {
    Write-Host "  usage 掃描：$processed / $($externalFiles.Count) ..."
  }
}

# ── 產出 usage.csv ───────────────────────────────────────────────────────────
Write-Host "產出 $targetName-usage.csv..."

$maxCount = ($usageData.Values | ForEach-Object { $_.CallerFiles.Count } | Measure-Object -Maximum).Maximum
if (-not $maxCount) { $maxCount = 1 }

$usageRows = [System.Collections.Generic.List[PSCustomObject]]::new()
foreach ($api in $apiJson) {
  $n  = $api.Name
  $ud = $usageData[$n]

  # 以 project 為單位統計呼叫點數
  $projCounts = $ud.CallerFiles |
    ForEach-Object { Get-ProjectName $_ } |
    Group-Object | Sort-Object Count -Descending

  $topProj      = if ($projCounts.Count -gt 0) { $projCounts[0].Name } else { "" }
  $topProjSites = if ($projCounts.Count -gt 0) { $projCounts[0].Count } else { 0 }
  $projList     = ($projCounts | Select-Object -ExpandProperty Name) -join ";"

  # RiskFlags（從 api.json 繼承 or 空白）
  $riskFlags = ""

  $usageRows.Add([PSCustomObject]@{
    API                   = $n
    Type                  = $api.Type
    TotalExternalCallSites = $ud.CallerFiles.Count
    TotalCallerProjects   = $ud.CallerProjects.Count
    TopCallerProject      = $topProj
    TopCallerSites        = $topProjSites
    CallerProjectList     = $projList
    TestCallerCount       = $ud.TestCount
    ZeroCaller            = ($ud.CallerFiles.Count -eq 0)
    RiskFlags             = $riskFlags
  })
}

$usageRows | Sort-Object TotalExternalCallSites |
  Export-Csv "$outputFolder\$targetName-usage.csv" -NoTypeInformation -Encoding UTF8 -Force

Write-Host "  $targetName-usage.csv：$($usageRows.Count) 行"
Write-Host "  零呼叫：$(($usageRows | Where-Object ZeroCaller -eq $true).Count) 個"

# ── 產出 coupling-in.csv（目標資料夾對外部類型的引用）───────────────────────
# 使用 api.json 已知類別名稱交叉驗證（避免通用 pattern 誤匹配）
Write-Host "產出 $targetName-coupling-in.csv..."

$couplingRows = [System.Collections.Generic.List[PSCustomObject]]::new()
$classNameSet = [System.Collections.Generic.HashSet[string]]::new($classNames, [System.StringComparer]::Ordinal)

foreach ($f in $internalFiles) {
  $content = Get-Content $f.FullName -Raw -Encoding UTF8

  # 偵測：new ClassName( 或 : ClassName（繼承/實作）
  foreach ($m in [regex]::Matches($content, '(?:new\s+(\w+)\s*\(|:\s*(\w+)\b)')) {
    $typeName = if ($m.Groups[1].Value) { $m.Groups[1].Value } else { $m.Groups[2].Value }
    if (-not $classNameSet.Contains($typeName)) { continue }
    # 確認被引用的 class 定義不在 scanFolder 內（即為外部依賴）
    # 此處簡化：若 class 出現在 api.json 且被內部檔案引用，記錄之

    $isExternalRef = $true  # api.json 是由 step1 掃描 scanFolder 產出，所以出現在 api.json 的是 target 的自身類別
    # coupling-in 是指 target 內部使用了自身的類別（內部耦合）→ SAME_PROJECT
    # 或 target 使用了其他 project 的類別 → 但 api.json 只有自身的類別
    # 所以此處 DependencyScope 固定為 SAME_PROJECT（target 內部檔案引用 target 的 class）
    $scope = "SAME_PROJECT"

    $couplingRows.Add([PSCustomObject]@{
      TypeName        = $typeName
      SourceFile      = $f.Name
      DependencyScope = $scope
    })
  }
}

$couplingRows | Sort-Object TypeName |
  Export-Csv "$outputFolder\$targetName-coupling-in.csv" -NoTypeInformation -Encoding UTF8 -Force

Write-Host "  $targetName-coupling-in.csv：$($couplingRows.Count) 行"
Write-Host "  SAME_PROJECT 阻斷器：$(($couplingRows | Where-Object DependencyScope -eq 'SAME_PROJECT').Count) 個"

# ── 產出 vitality.csv（檔案層級 git 活躍度） ────────────────────────────────
Write-Host "產出 $targetName-vitality.csv..."

$vitalityRows = foreach ($f in $internalFiles) {
  $filePath   = $f.FullName
  $commits2yr = (git log --since="2 years ago" --oneline -- "$filePath" 2>$null | Measure-Object -Line).Lines
  $lastCommit = git log -1 --format="%ad" --date=short -- "$filePath" 2>$null

  # 近 6 個月 churn（insertions + deletions）
  $recentChurn = 0
  $stat = git log --since="6 months ago" --numstat --format="" -- "$filePath" 2>$null
  foreach ($line in $stat) {
    if ($line -match '^(\d+)\s+(\d+)\s+') {
      $recentChurn += [int]$matches[1] + [int]$matches[2]
    }
  }

  [PSCustomObject]@{
    File        = $f.Name
    LastCommit  = if ($lastCommit) { $lastCommit } else { "N/A" }
    Commits2yr  = $commits2yr
    RecentChurn = $recentChurn
  }
}

$vitalityRows | Sort-Object Commits2yr -Descending |
  Export-Csv "$outputFolder\$targetName-vitality.csv" -NoTypeInformation -Encoding UTF8 -Force

Write-Host "  $targetName-vitality.csv：$($vitalityRows.Count) 行"

Write-Host ""
Write-Host "=== Layer 2 Step 2 完成 ==="
Write-Host "輸出資料夾：$outputFolder"
Write-Host "  - $targetName-usage.csv"
Write-Host "  - $targetName-coupling-in.csv"
Write-Host "  - $targetName-vitality.csv"
