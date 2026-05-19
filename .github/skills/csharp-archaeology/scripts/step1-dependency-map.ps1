# step1-dependency-map.ps1
# Phase 0 Layer 1 — 建立專案依賴拓樸
# 輸出：.analysis/tmp/dependency-map.json
#
# 排除規則：
#   - *Ex.csproj 結尾（擴充專案）
#   - .vcxproj（C++ 專案）
#   - 名稱包含 Test / Tests / UnitTest 的測試專案

$ErrorActionPreference = 'Stop'
$root = (Get-Location).Path

# 排除條件
$excludePattern = '(?i)(Ex\.csproj$|[Tt]est|UnitTest|TestProject)'

$allProjects = Get-ChildItem -Recurse -Filter "*.csproj" |
  Where-Object { $_.Name -notmatch $excludePattern -and $_.Extension -eq ".csproj" }

Write-Host "掃描 $($allProjects.Count) 個 C# 專案（已排除 Ex、測試專案）..."

$dependencyMap = @{}
foreach ($proj in $allProjects) {
  $projName = [System.IO.Path]::GetFileNameWithoutExtension($proj.Name)
  try {
    [xml]$xml = Get-Content $proj.FullName -Encoding UTF8
    $refs = $xml.SelectNodes("//ProjectReference/@Include") |
      ForEach-Object { [System.IO.Path]::GetFileNameWithoutExtension($_.Value) } |
      Where-Object { $_ -notmatch $excludePattern }
    $dependencyMap[$projName] = @($refs)
  } catch {
    Write-Warning "無法解析：$($proj.Name)"
    $dependencyMap[$projName] = @()
  }
}

# 孤島專案：沒有任何其他專案依賴它
$allReferenced = $dependencyMap.Values | ForEach-Object { $_ } | Sort-Object -Unique
$islands       = $dependencyMap.Keys  | Where-Object { $_ -notin $allReferenced }

# 核心專案：被最多其他專案引用
$hubScore = @{}
foreach ($refs in $dependencyMap.Values) {
  foreach ($r in $refs) {
    if ($hubScore[$r]) { $hubScore[$r]++ } else { $hubScore[$r] = 1 }
  }
}

$output = @{
  totalProjects = $allProjects.Count
  islands       = @($islands)
  hubs          = @($hubScore.GetEnumerator() |
                    Sort-Object Value -Descending | Select-Object -First 30 |
                    ForEach-Object { @{ name=$_.Key; count=$_.Value } })
  dependencyMap = $dependencyMap
}

New-Item -ItemType Directory -Force -Path ".analysis/tmp" | Out-Null
$output | ConvertTo-Json -Depth 5 |
  Out-File ".analysis/tmp/dependency-map.json" -Encoding UTF8 -Force

Write-Host ""
Write-Host "=== dependency-map.json 產出完成 ==="
Write-Host "分析專案數：$($allProjects.Count)"
Write-Host "孤島專案（無人依賴）：$($islands.Count) 個"
Write-Host "核心專案 Top 3：$(($output.hubs | Select-Object -First 3 | ForEach-Object { "$($_.name)($($_.count))" }) -join ', ')"
