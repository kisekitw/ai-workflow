# step2-git-stability.ps1
# Phase 0 Layer 1 — 分析各專案 Git 活躍度
# 輸出：.analysis/tmp/git-stability.csv
#
# 說明：
#   ACTIVE  = 近兩年有 10 次以上 commit（持續維護中）
#   STALE   = 近兩年有 1–9 次 commit（偶爾異動）
#   FROZEN  = 近兩年零 commit（長期未動，但不代表沒人用）
#
# 排除規則：同 Step 1（Ex、測試專案）

$ErrorActionPreference = 'Stop'
$excludePattern = '(?i)(Ex\.csproj$|[Tt]est|UnitTest|TestProject)'

$allProjects = Get-ChildItem -Recurse -Filter "*.csproj" |
  Where-Object { $_.Name -notmatch $excludePattern }

Write-Host "分析 $($allProjects.Count) 個專案的 git 活躍度..."

$report = foreach ($proj in $allProjects) {
  $folder    = $proj.DirectoryName
  $projName  = [System.IO.Path]::GetFileNameWithoutExtension($proj.Name)

  $commits2y  = (git log --since="2 years ago" --oneline -- "$folder" 2>$null |
                 Measure-Object -Line).Lines
  $lastCommit = git log -1 --format="%ad" --date=short -- "$folder" 2>$null

  [PSCustomObject]@{
    專案名稱      = $projName
    近兩年Commits = $commits2y
    最後異動日期  = if ($lastCommit) { $lastCommit } else { "N/A" }
    狀態          = if ($commits2y -eq 0)   { "FROZEN" }
                    elseif ($commits2y -lt 10) { "STALE" }
                    else                       { "ACTIVE" }
  }
}

New-Item -ItemType Directory -Force -Path ".analysis/tmp" | Out-Null
$report | Sort-Object 近兩年Commits |
  Export-Csv ".analysis/tmp/git-stability.csv" -NoTypeInformation -Encoding UTF8 -Force

Write-Host ""
Write-Host "=== git-stability.csv 產出完成 ==="
Write-Host "ACTIVE （近兩年 ≥10 commits）：$(($report | Where-Object 狀態 -eq 'ACTIVE').Count) 個"
Write-Host "STALE  （近兩年 1–9 commits）：$(($report | Where-Object 狀態 -eq 'STALE').Count) 個"
Write-Host "FROZEN （近兩年零 commit）    ：$(($report | Where-Object 狀態 -eq 'FROZEN').Count) 個"
