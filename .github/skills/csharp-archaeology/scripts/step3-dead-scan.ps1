# step3-dead-scan.ps1
# Phase 0 Layer 1 — 掃描未被呼叫的 private/internal 方法
# 輸出：docs/archaeology/tmp/dead-candidates.csv
#
# 掃描對象：private 或 internal 的方法（Method）
# 判斷邏輯：在整個 solution 內找不到任何呼叫者
# 重要限制：
#   - 誤報率比 Roslyn 高，結果需人工二次確認
#   - 不掃 public 方法（可能被外部 dll 引用）
#   - WinForms event handler 可能仍有誤報（命名不符 skip pattern 時）
#
# 排除規則：
#   - *Ex.csproj 資料夾內的 .cs 檔案
#   - 測試專案資料夾內的 .cs 檔案
#   - obj/ 和 bin/ 資料夾
#   - WinForms 自動產生的方法名稱（InitializeComponent、Dispose 等）

$ErrorActionPreference = 'Stop'
$root = (Get-Location).Path

# 排除的專案名稱 pattern
$excludeProjPattern = '(?i)(Ex\.csproj$|[Tt]est|UnitTest|TestProject)'

# 找出要排除的資料夾（Ex 專案 + 測試專案）
$excludeDirs = Get-ChildItem -Recurse -Filter "*.csproj" |
  Where-Object { $_.Name -match $excludeProjPattern } |
  ForEach-Object { $_.DirectoryName }

Write-Host "排除 $($excludeDirs.Count) 個 Ex/測試專案資料夾"

# 收集所有合法 .cs 檔案
$allCsFiles = Get-ChildItem -Recurse -Filter "*.cs" | Where-Object {
  $f = $_.FullName
  $_.FullName -notmatch '\\obj\\'  -and
  $_.FullName -notmatch '\\bin\\'  -and
  $_.Length   -gt 0               -and
  -not ($excludeDirs | Where-Object { $f.StartsWith($_) })
}

Write-Host "掃描 $($allCsFiles.Count) 個 .cs 檔案中的 private/internal 方法..."

# Skip pattern：WinForms 自動產生 + 常見事件委派命名
$skipPattern   = '^(InitializeComponent|Dispose|Finalize|get_|set_|add_|remove_|On[A-Z]|this_|Parent_|Child_|Form_|Btn_|btn_)'
$methodPattern = '(?:private|internal)\s+(?:static\s+|virtual\s+|override\s+|async\s+)*(?:\w+[\[\]?<>, ]*\s+)+(\w+)\s*\('

# 第一步：收集所有 private/internal 方法定義
Write-Host "第一步：收集方法定義..."
$fileMethods = [System.Collections.Generic.List[PSCustomObject]]::new()
foreach ($f in $allCsFiles) {
  $content = Get-Content $f.FullName -Raw -Encoding UTF8
  foreach ($m in [regex]::Matches($content, $methodPattern)) {
    $name = $m.Groups[1].Value
    if ($name -match $skipPattern) { continue }
    if ($name.Length -le 2)        { continue }  # 跳過過短的名稱
    $line = ($content.Substring(0, $m.Index) -split "`n").Count
    $fileMethods.Add([PSCustomObject]@{
      Method  = $name
      File    = $f.FullName
      Line    = $line
      Content = $content
    })
  }
}

Write-Host "找到 $($fileMethods.Count) 個 private/internal 方法，開始搜尋呼叫者..."

# 第二步：建立全域 token 計數
Write-Host "第二步：建立全域 token 計數（這是最慢的步驟，請耐心等候）..."
$globalTokenCount = @{}
$processed = 0
foreach ($f in $allCsFiles) {
  $content = Get-Content $f.FullName -Raw -Encoding UTF8
  foreach ($entry in $fileMethods) {
    $name = $entry.Method
    if (-not $globalTokenCount.ContainsKey($name)) {
      $globalTokenCount[$name] = 0
    }
    $count = ([regex]::Matches($content, "\b$([regex]::Escape($name))\b")).Count
    $globalTokenCount[$name] += $count
  }
  $processed++
  if ($processed % 100 -eq 0) {
    Write-Host "  已處理 $processed / $($allCsFiles.Count) 個檔案..."
  }
}

# 第三步：篩選出呼叫者為 0 的方法
Write-Host "第三步：篩選零呼叫方法..."
$deadCandidates = [System.Collections.Generic.List[PSCustomObject]]::new()
foreach ($entry in $fileMethods) {
  $name      = $entry.Method
  $selfCount = ([regex]::Matches($entry.Content, "\b$([regex]::Escape($name))\b")).Count
  $total     = if ($globalTokenCount.ContainsKey($name)) { $globalTokenCount[$name] } else { 0 }
  $callers   = [Math]::Max(0, $total - $selfCount)

  if ($callers -eq 0) {
    $deadCandidates.Add([PSCustomObject]@{
      方法名稱   = $name
      所在專案   = Split-Path (Split-Path $entry.File -Parent) -Leaf
      檔案路徑   = $entry.File.Replace($root, '').TrimStart('\')
      行號       = $entry.Line
    })
  }
}

$deadCandidates |
  Export-Csv 'docs/archaeology/tmp/dead-candidates.csv' -NoTypeInformation -Encoding UTF8 -Force

Write-Host ""
Write-Host "=== dead-candidates.csv 產出完成 ==="
Write-Host "未被呼叫的 private/internal 方法：$($deadCandidates.Count) 個候選"
Write-Host "⚠ 提醒：此為候選清單，需人工確認後才能刪除"
