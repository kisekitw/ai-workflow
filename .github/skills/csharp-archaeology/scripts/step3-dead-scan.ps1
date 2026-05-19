# step3-dead-scan.ps1
# Phase 0 Layer 1 — O(N+M) 掃描未被呼叫的 private/internal 方法
# 輸出：.analysis/tmp/dead-candidates.csv
#
# 欄位：Method, FullyQualifiedName, File, Line, Confidence, RiskFlags
#
# Confidence：
#   HIGH   = private，無任何 RiskFlags
#   MEDIUM = internal，無 RiskFlags；或 private 但模糊情境
#   LOW    = 有任何 RiskFlags（REFLECTION/ATTRIBUTE/WINFORMS/RESXREF）
#
# RiskFlags：
#   WINFORMS   = 方法有 (object sender, *EventArgs) 參數特徵（event handler）
#   ATTRIBUTE  = 方法上方有 DllImport/ComVisible/WebMethod/DispId 等屬性
#   REFLECTION = 方法名稱出現在字串字面值中（可能被 Reflection 呼叫）
#   RESXREF    = 方法名稱出現在 .resx 檔案中
#
# 效能設計（O(N+M)）：
#   Phase 1：收集所有 private/internal 方法名稱 → HashSet（去重）
#   Phase 2：每個 .cs 檔案讀取一次，對 HashSet 中的 token 累加 globalCount
#   Phase 3：比對定義次數 vs 全域次數，差為 0 = 死碼候選

$ErrorActionPreference = 'Stop'
$root = (Get-Location).Path

$excludePattern = '(?i)(Ex\.csproj$|[Tt]est|UnitTest|TestProject)'

$excludeDirs = Get-ChildItem -Recurse -Filter "*.csproj" |
  Where-Object { $_.Name -match $excludePattern } |
  ForEach-Object { $_.DirectoryName }

$allCsFiles = Get-ChildItem -Recurse -Filter "*.cs" | Where-Object {
  $f = $_.FullName
  $_.FullName -notmatch '\\obj\\' -and
  $_.FullName -notmatch '\\bin\\' -and
  $_.Length   -gt 0 -and
  -not ($excludeDirs | Where-Object { $f.StartsWith($_) })
}

Write-Host "掃描 $($allCsFiles.Count) 個 .cs 檔案..."

# Patterns
$skipPattern      = '^(InitializeComponent|Dispose|Finalize|get_|set_|add_|remove_|On[A-Z])'
$methodPattern    = '(?:private|internal)\s+(?:static\s+|virtual\s+|override\s+|async\s+)*(?:\w+[\[\]?<>, ]*\s+)+(\w+)\s*\('
$winFormsPattern  = '\(\s*object\s+sender\s*,\s*\w*EventArgs\b'   # 比 name prefix 更可靠
$attributePattern = '\[\s*(?:DllImport|ComVisible|WebMethod|DispId|ClassInterface|Guid|MarshalAs)\b'

# 收集 .resx 檔案中所有 name 值（用於 RESXREF 偵測）
Write-Host "收集 .resx 參照..."
$resxNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
Get-ChildItem -Recurse -Filter "*.resx" | ForEach-Object {
  try {
    [xml]$rx = Get-Content $_.FullName -Encoding UTF8
    $rx.SelectNodes("//data/@name") | ForEach-Object { [void]$resxNames.Add($_.Value) }
  } catch { }
}

# ── Phase 1：收集所有 private/internal 方法定義 ──────────────────────────────
Write-Host "Phase 1：收集方法定義..."
$fileMethods = [System.Collections.Generic.List[PSCustomObject]]::new()
$uniqueNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)

foreach ($f in $allCsFiles) {
  $content = Get-Content $f.FullName -Raw -Encoding UTF8

  # 提取 namespace（取第一個 namespace 宣告）
  $nsMatch   = [regex]::Match($content, '(?m)^\s*namespace\s+([\w.]+)')
  $namespace = if ($nsMatch.Success) { $nsMatch.Groups[1].Value } else { "" }

  foreach ($m in [regex]::Matches($content, $methodPattern)) {
    $name = $m.Groups[1].Value
    if ($name -match $skipPattern) { continue }
    if ($name.Length -le 2)        { continue }

    $line = ($content.Substring(0, $m.Index) -split "`n").Count

    # 找最近的 class 宣告（方法定義前的最後一個 class）
    $before   = $content.Substring(0, $m.Index)
    $clsMatch = ([regex]::Matches($before, '(?:public|internal|private|protected|abstract|sealed|static)?\s*(?:partial\s+)?class\s+(\w+)') |
                  Select-Object -Last 1)
    $className = if ($clsMatch) { $clsMatch.Groups[1].Value } else { "" }

    $fqn = if ($namespace -and $className) { "$namespace.$className.$name" }
           elseif ($className)             { "$className.$name" }
           else                            { $name }

    # 取方法宣告後 300 字元作為 snippet（用於 WinForms 偵測）
    $snippetLen = [Math]::Min(300, $content.Length - $m.Index)
    $snippet    = $content.Substring($m.Index, $snippetLen)

    # RiskFlags
    $flags = [System.Collections.Generic.List[string]]::new()
    if ($snippet -match $winFormsPattern)                              { $flags.Add("WINFORMS") }
    if ($before  -match $attributePattern)                             { $flags.Add("ATTRIBUTE") }
    if ($resxNames.Contains($name))                                    { $flags.Add("RESXREF") }
    if ([regex]::IsMatch($content, '"' + [regex]::Escape($name) + '"')) { $flags.Add("REFLECTION") }

    $isPrivate = $m.Value -match '\bprivate\b'
    $conf = if ($flags.Count -gt 0) { "LOW" }
            elseif ($isPrivate)      { "HIGH" }
            else                     { "MEDIUM" }  # internal

    [void]$uniqueNames.Add($name)
    $fileMethods.Add([PSCustomObject]@{
      Method             = $name
      FullyQualifiedName = $fqn
      File               = $f.FullName
      Line               = $line
      Confidence         = $conf
      RiskFlags          = ($flags -join "|")
    })
  }
}

Write-Host "找到 $($fileMethods.Count) 個 private/internal 方法（$($uniqueNames.Count) 個唯一名稱）"

# ── Phase 2：每個檔案讀取一次，批次計算 token 計數 ──────────────────────────
Write-Host "Phase 2：建立全域 token 計數（O(N+M)）..."

# 初始化全域計數與定義檔案計數
$globalCount = @{}
foreach ($n in $uniqueNames) { $globalCount[$n] = 0 }

$defFileSet = [System.Collections.Generic.HashSet[string]]::new(
  ($fileMethods | Select-Object -ExpandProperty File),
  [System.StringComparer]::OrdinalIgnoreCase
)
$fileLocalCounts = @{}   # key: filename → @{methodName → count}

$processed = 0
foreach ($f in $allCsFiles) {
  $content     = Get-Content $f.FullName -Raw -Encoding UTF8
  $isDefFile   = $defFileSet.Contains($f.FullName)
  $localCounts = if ($isDefFile) { @{} } else { $null }

  foreach ($match in [regex]::Matches($content, '\b\w+\b')) {
    $token = $match.Value
    if ($globalCount.ContainsKey($token)) {
      $globalCount[$token]++
      if ($isDefFile) {
        if (-not $localCounts.ContainsKey($token)) { $localCounts[$token] = 0 }
        $localCounts[$token]++
      }
    }
  }

  if ($isDefFile) { $fileLocalCounts[$f.FullName] = $localCounts }

  $processed++
  if ($processed % 200 -eq 0) {
    Write-Host "  已處理 $processed / $($allCsFiles.Count) 個檔案..."
  }
}

# ── Phase 3：篩選零呼叫方法 ─────────────────────────────────────────────────
Write-Host "Phase 3：篩選零呼叫方法..."
$deadCandidates = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($entry in $fileMethods) {
  $total = $globalCount[$entry.Method]
  $local = if ($fileLocalCounts.ContainsKey($entry.File) -and
               $fileLocalCounts[$entry.File].ContainsKey($entry.Method)) {
             $fileLocalCounts[$entry.File][$entry.Method]
           } else { 0 }

  $callers = [Math]::Max(0, $total - $local)

  if ($callers -eq 0) {
    $deadCandidates.Add([PSCustomObject]@{
      Method             = $entry.Method
      FullyQualifiedName = $entry.FullyQualifiedName
      File               = $entry.File.Replace($root, '').TrimStart('\').TrimStart('/')
      Line               = $entry.Line
      Confidence         = $entry.Confidence
      RiskFlags          = $entry.RiskFlags
    })
  }
}

New-Item -ItemType Directory -Force -Path ".analysis/tmp" | Out-Null
$deadCandidates |
  Export-Csv '.analysis/tmp/dead-candidates.csv' -NoTypeInformation -Encoding UTF8 -Force

Write-Host ""
Write-Host "=== dead-candidates.csv 產出完成 ==="
Write-Host "死碼候選總計：$($deadCandidates.Count) 個"
Write-Host "  HIGH   (private，無 RiskFlags)   ：$(($deadCandidates | Where-Object Confidence -eq 'HIGH').Count) 個"
Write-Host "  MEDIUM (internal 或模糊)          ：$(($deadCandidates | Where-Object Confidence -eq 'MEDIUM').Count) 個"
Write-Host "  LOW    (有 RiskFlags，需謹慎確認)：$(($deadCandidates | Where-Object Confidence -eq 'LOW').Count) 個"
Write-Host ""
Write-Host "⚠ 提醒：此為候選清單，需人工確認後才能刪除。Public 成員不在此列。"
Write-Host "  WinForms event handler 已透過 EventArgs 參數特徵偵測，誤報率低。"
