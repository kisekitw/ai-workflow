---
name: csharp-archaeology
description: >
  Phase 0 考古 Skill：針對大型 legacy C# WinForms codebase，在不依賴任何人記憶的
  情況下，讓程式碼自己說話。分兩層執行：Layer 1 產出全局依賴地圖與死碼候選清單；
  Layer 2 針對指定模組深挖 public API 呼叫關係。同時產出兩個平行任務文件。
  ALWAYS use this skill when user mentions "phase 0", "考古", "archaeology",
  "分析 codebase", "模組邊界", "找死碼", "開始重構前的分析", 或 "建立依賴地圖"。
---

# C# Codebase Archaeology — Phase 0

## 設計原則

**PowerShell 做重活，AI 分批讀取結果。**

500 萬行 codebase 不能一次餵給 AI。正確做法：
- PowerShell script 掃描全部檔案，輸出結構化 JSON/CSV 中間檔
- AI 分批讀取中間檔進行分析，每次只讀需要的部分
- 不使用 Sub-agent（experimental feature，不穩定）

---

## 邊界規則（永遠遵守）

- 只處理 `.csproj`，跳過所有 `.vcxproj`（C++ 專案）
- `*Ex.csproj` 結尾的 project：跳過分析其內部，但保留它作為被依賴關係
- 死碼候選只涵蓋 `private` / `internal`，`public` 不標記（可能被 dll 外部引用）

---

## 前置確認（每次執行前必做）

執行以下指令，任何一項失敗就停下來告知 RD，不要繼續。

```powershell
# 確認 1：git 存在且有歷史
git log --oneline -5

# 確認 2：找到 .sln 檔案
Get-ChildItem -Recurse -Filter "*.sln" | Select-Object FullName

# 確認 3：確認 C# project 數量
$projs = Get-ChildItem -Recurse -Filter "*.csproj" |
  Where-Object { $_.Name -notmatch "Ex\.csproj$" }
Write-Host "找到 $($projs.Count) 個 C# project（已排除 Ex 結尾與 vcxproj）"

# 確認 4：建立輸出資料夾
New-Item -ItemType Directory -Force -Path "docs/archaeology/tmp"
```

---

## Layer 1 — 全局掃描

> 目標：建立可信的依賴地圖、找出孤島模組、產出 private/internal 死碼候選。
> 時間：約 10–20 分鐘。
> 中間檔：三份 JSON/CSV → AI 分批讀取 → 產出 `docs/archaeology/00-global-map.html`

### Step 1：建立依賴拓樸 → dependency-map.json

```powershell
$allProjects = Get-ChildItem -Recurse -Filter "*.csproj" |
  Where-Object { $_.Name -notmatch "Ex\.csproj$" -and $_.Extension -eq ".csproj" }

$dependencyMap = @{}
foreach ($proj in $allProjects) {
  $projName = [System.IO.Path]::GetFileNameWithoutExtension($proj.Name)
  [xml]$xml = Get-Content $proj.FullName -Encoding UTF8
  $refs = $xml.SelectNodes("//ProjectReference/@Include") |
    ForEach-Object { [System.IO.Path]::GetFileNameWithoutExtension($_.Value) }
  $dependencyMap[$projName] = @($refs)
}

$allReferenced = $dependencyMap.Values | ForEach-Object { $_ } | Sort-Object -Unique
$islands       = $dependencyMap.Keys  | Where-Object { $_ -notin $allReferenced }

$hubScore = @{}
foreach ($refs in $dependencyMap.Values) {
  foreach ($r in $refs) {
    if ($hubScore[$r]) { $hubScore[$r]++ } else { $hubScore[$r] = 1 }
  }
}

@{
  totalProjects = $allProjects.Count
  islands       = @($islands)
  hubs          = @($hubScore.GetEnumerator() |
                    Sort-Object Value -Descending | Select-Object -First 30 |
                    ForEach-Object { @{ name=$_.Key; count=$_.Value } })
  dependencyMap = $dependencyMap
} | ConvertTo-Json -Depth 5 |
  Out-File "docs/archaeology/tmp/dependency-map.json" -Encoding UTF8

Write-Host "dependency-map.json 產出完成 — 孤島：$($islands.Count) 個"
```

**AI 讀取**：讀取 `dependency-map.json` 一次讀完（結構化 JSON，context 壓力小）。

---

### Step 2：Git 穩定度 → git-stability.csv

> 穩定度低 ≠ 死碼。穩定 = 成熟模組，可能非常核心。

```powershell
$allProjects = Get-ChildItem -Recurse -Filter "*.csproj" |
  Where-Object { $_.Name -notmatch "Ex\.csproj$" }

$report = foreach ($proj in $allProjects) {
  $folder    = $proj.DirectoryName
  $projName  = [System.IO.Path]::GetFileNameWithoutExtension($proj.Name)
  $commits2y = (git log --since="2 years ago" --oneline -- "$folder" 2>$null |
                Measure-Object -Line).Lines
  $lastCommit = git log -1 --format="%ad" --date=short -- "$folder" 2>$null

  [PSCustomObject]@{
    Module     = $projName
    Commits2yr = $commits2y
    LastCommit = $lastCommit
    Status     = if ($commits2y -eq 0) { "FROZEN" }
                 elseif ($commits2y -lt 10) { "STALE" }
                 else { "ACTIVE" }
  }
}

$report | Sort-Object Commits2yr |
  Export-Csv "docs/archaeology/tmp/git-stability.csv" -NoTypeInformation -Encoding UTF8

Write-Host "git-stability.csv 產出完成"
Write-Host "FROZEN（2年零 commit）：$(($report | Where-Object Status -eq 'FROZEN').Count) 個"
```

**AI 讀取**：讀取 `git-stability.csv` 一次讀完（純數字，context 壓力小）。

---

### Step 3：Private/Internal 死碼掃描 → dead-candidates.csv

> 候選清單，誤報率比 Roslyn 高，需人工二次確認。

```powershell
$allCsFiles    = Get-ChildItem -Recurse -Filter "*.cs" |
  Where-Object { $_.FullName -notmatch "\\obj\\" -and $_.FullName -notmatch "\\bin\\" }
$skipPattern   = "^(InitializeComponent|Dispose|get_|set_|add_|remove_|On[A-Z])"
$methodPattern = '(?:private|internal)\s+(?:static\s+)?(?:\w+[\[\]?]*\s+)+(\w+)\s*\('
$deadCandidates = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($file in $allCsFiles) {
  $content = Get-Content $file.FullName -Raw
  foreach ($m in [regex]::Matches($content, $methodPattern)) {
    $name = $m.Groups[1].Value
    if ($name -match $skipPattern) { continue }

    $callers = ($allCsFiles |
      Select-String -Pattern "\b$name\b" -SimpleMatch |
      Where-Object { $_.Path -ne $file.FullName } |
      Measure-Object).Count

    if ($callers -eq 0) {
      $deadCandidates.Add([PSCustomObject]@{
        Method = $name
        File   = $file.FullName.Replace($PWD.Path, '')
        Line   = ($content.Substring(0, $m.Index) -split "`n").Count
      })
    }
  }
}

$deadCandidates |
  Export-Csv "docs/archaeology/tmp/dead-candidates.csv" -NoTypeInformation -Encoding UTF8

Write-Host "dead-candidates.csv 產出完成：$($deadCandidates.Count) 個候選"
```

**AI 讀取**：dead-candidates.csv 可能數千筆，**每次讀 TOP 50**，
優先讀孤島模組（dependency-map.json 中的 islands）內的候選。

---

### Layer 1 AI 分析流程

三份中間檔產出後，AI 依序執行：

```
1. 讀 dependency-map.json
   → 樞紐模組 Top 15 + 孤島模組清單
   → 交叉標記：孤島 + FROZEN = 最強刪除候選

2. 讀 git-stability.csv
   → 每個模組標注 ACTIVE / STALE / FROZEN
   → 補充孤島模組穩定度訊號

3. 分批讀 dead-candidates.csv（TOP 50，優先孤島模組）
   → 標注信心度

4. 綜合三份資料產出行動建議
   → 建議 Layer 2 深挖的模組
   → 刪除候選（待平行任務確認）
   → 監控但不先動
```

### Layer 1 最終輸出

產出 `docs/archaeology/00-global-map.html`（infographic report）：

- KPI strip：分析 project 數 / 孤島數 / 兩年未動數 / 死碼候選數
- 樞紐模組 bar chart（Top 15，含風險標籤）
- 孤島模組卡片（含最後異動日期）
- Git 穩定度表格（ACTIVE / STALE / FROZEN badge）
- 死碼候選表格（可展開，信心度 HIGH / MED / LOW）
- 行動建議優先序（Layer 2 / 待刪 / 監控）
- 警告框：public API 死碼需等平行任務完成後才能確認

---

## Layer 2 — 模組深挖

> 目標：了解指定模組的 public API 在 solution 內的呼叫關係。
> 前提：Layer 1 已完成。
> 觸發：RD 指定模組名稱，例如「深挖 HMIWafermap」。
> 時間：每個模組約 5–10 分鐘。
> 輸出：`docs/archaeology/[ModuleName]-report.html`

### Step 1：找出 Public API → [Module]-api.json

```powershell
$moduleName   = "[RD 指定的模組名稱]"
$moduleFolder = Get-ChildItem -Recurse -Filter "$moduleName.csproj" |
  Where-Object { $_.Name -notmatch "Ex\.csproj$" } |
  Select-Object -First 1 -ExpandProperty DirectoryName

$csFiles  = Get-ChildItem -Path $moduleFolder -Recurse -Filter "*.cs" |
  Where-Object { $_.FullName -notmatch "\\obj\\" }
$publicApi = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($file in $csFiles) {
  $content = Get-Content $file.FullName -Raw
  [regex]::Matches($content, 'public\s+(?:partial\s+)?class\s+(\w+)') |
    ForEach-Object { $publicApi.Add([PSCustomObject]@{ Type="class";  Name=$_.Groups[1].Value; File=$file.Name }) }
  [regex]::Matches($content, 'public\s+(?:static\s+|virtual\s+|override\s+)?(?:\w+[\[\]?]*\s+)+(\w+)\s*\(') |
    ForEach-Object { $publicApi.Add([PSCustomObject]@{ Type="method"; Name=$_.Groups[1].Value; File=$file.Name }) }
}

$publicApi | ConvertTo-Json |
  Out-File "docs/archaeology/tmp/$moduleName-api.json" -Encoding UTF8
Write-Host "找到 $($publicApi.Count) 個 public API"
```

### Step 2：搜尋呼叫者 → [Module]-usage.csv

```powershell
$allCsFiles = Get-ChildItem -Recurse -Filter "*.cs" |
  Where-Object { $_.FullName -notmatch "\\obj\\" -and $_.FullName -notmatch $moduleFolder }

$usageReport = foreach ($api in $publicApi) {
  $callers = $allCsFiles |
    Select-String -Pattern "\b$($api.Name)\b" -SimpleMatch |
    Select-Object -ExpandProperty Path | Sort-Object -Unique

  [PSCustomObject]@{
    API         = $api.Name
    Type        = $api.Type
    CallerCount = $callers.Count
    Callers     = ($callers | ForEach-Object { Split-Path $_ -Leaf }) -join "; "
  }
}

$usageReport | Sort-Object CallerCount |
  Export-Csv "docs/archaeology/tmp/$moduleName-usage.csv" -NoTypeInformation -Encoding UTF8

Write-Host "usage.csv 產出完成"
Write-Host "Solution 內零呼叫：$(($usageReport | Where-Object CallerCount -eq 0).Count) 個"
```

### Layer 2 最終輸出

產出 `docs/archaeology/[ModuleName]-report.html`（infographic report）：

- KPI strip：Public API 總數 / 有呼叫者 / 零呼叫 / 上游依賴數
- 上下游依賴關係圖（三欄：上游 → 目標模組 → 下游）
- Public API 表格（可展開呼叫者，零呼叫紅色標注）
- 呼叫熱度 heatmap（下游模組使用密度）
- 警告框：零呼叫 ≠ 死碼，需 Task A 確認

---

## 平行任務文件

Layer 1 完成後自動產出 `docs/archaeology/parallel-tasks.md`，由 Tech Lead 安排，不由 Skill 執行。

```markdown
# 平行任務清單 — [DATE]

## Task A：掃描 cb8/cb9/ure 找 dll 引用
目的：確認 public API 是否被外部 repo 透過 dll 直接引用。
步驟：
1. Clone cb8、cb9、ure
2. 搜尋 .csproj 是否引用我們的模組名稱
3. 搜尋 packages/ lib/ 是否有我們的 .dll
4. 結果回填至對應 [ModuleName]-report.html
預計工作量：1–2 天

## Task B：Runtime Telemetry 佈建
目的：透過執行期 log 確認哪些功能真正被使用者觸發。
步驟：
1. 每個主要 Form 進入點加入結構化 log
2. 部署至 staging 環境
3. 收集至少 3 個月（涵蓋季結、年結）
4. 從未出現的 log 項目標記為死碼候選
預計工作量：佈建 1 週，等待資料 3–6 個月
```
