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

**每個步驟都先寫成 `.ps1` 檔案，再執行。絕不把 script 壓成一行丟進 terminal。**

500 萬行 codebase 的正確做法：
- 每個 Step 的 PowerShell script 先存成獨立 `.ps1` 檔案
- 確認檔案寫入後再執行
- AI 分批讀取輸出的 JSON/CSV 中間檔進行分析
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

---

### Step 1：建立依賴拓樸

**先寫檔，再執行：**

```
將以下內容寫入 docs/archaeology/tmp/step1-dependency-map.ps1
執行完成後再執行該檔案
```

```powershell
# step1-dependency-map.ps1
$ErrorActionPreference = 'Stop'
$root = (Get-Location).Path

$allProjects = Get-ChildItem -Recurse -Filter "*.csproj" |
  Where-Object { $_.Name -notmatch "Ex\.csproj$" -and $_.Extension -eq ".csproj" }

Write-Host "掃描 $($allProjects.Count) 個 C# project..."

$dependencyMap = @{}
foreach ($proj in $allProjects) {
  $projName = [System.IO.Path]::GetFileNameWithoutExtension($proj.Name)
  try {
    [xml]$xml = Get-Content $proj.FullName -Encoding UTF8
    $refs = $xml.SelectNodes("//ProjectReference/@Include") |
      ForEach-Object { [System.IO.Path]::GetFileNameWithoutExtension($_.Value) }
    $dependencyMap[$projName] = @($refs)
  } catch {
    Write-Warning "無法解析：$($proj.Name)"
    $dependencyMap[$projName] = @()
  }
}

$allReferenced = $dependencyMap.Values | ForEach-Object { $_ } | Sort-Object -Unique
$islands       = $dependencyMap.Keys  | Where-Object { $_ -notin $allReferenced }

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

$output | ConvertTo-Json -Depth 5 |
  Out-File "docs/archaeology/tmp/dependency-map.json" -Encoding UTF8 -Force

Write-Host "dependency-map.json 產出完成"
Write-Host "孤島模組：$($islands.Count) 個"
Write-Host "樞紐 Top 3：$(($output.hubs | Select-Object -First 3 | ForEach-Object { "$($_.name)($($_.count))" }) -join ', ')"
```

**執行：**
```powershell
.\docs\archaeology\tmp\step1-dependency-map.ps1
```

---

### Step 2：Git 穩定度

**先寫檔，再執行：**

```
將以下內容寫入 docs/archaeology/tmp/step2-git-stability.ps1
執行完成後再執行該檔案
```

```powershell
# step2-git-stability.ps1
$ErrorActionPreference = 'Stop'

$allProjects = Get-ChildItem -Recurse -Filter "*.csproj" |
  Where-Object { $_.Name -notmatch "Ex\.csproj$" }

Write-Host "分析 $($allProjects.Count) 個 project 的 git 活躍度..."

$report = foreach ($proj in $allProjects) {
  $folder    = $proj.DirectoryName
  $projName  = [System.IO.Path]::GetFileNameWithoutExtension($proj.Name)

  $commits2y  = (git log --since="2 years ago" --oneline -- "$folder" 2>$null |
                 Measure-Object -Line).Lines
  $lastCommit = git log -1 --format="%ad" --date=short -- "$folder" 2>$null

  [PSCustomObject]@{
    Module     = $projName
    Commits2yr = $commits2y
    LastCommit = if ($lastCommit) { $lastCommit } else { "N/A" }
    Status     = if ($commits2y -eq 0) { "FROZEN" }
                 elseif ($commits2y -lt 10) { "STALE" }
                 else { "ACTIVE" }
  }
}

$report | Sort-Object Commits2yr |
  Export-Csv "docs/archaeology/tmp/git-stability.csv" -NoTypeInformation -Encoding UTF8 -Force

Write-Host "git-stability.csv 產出完成"
Write-Host "FROZEN（2年零 commit）：$(($report | Where-Object Status -eq 'FROZEN').Count) 個"
Write-Host "STALE（少於 10 commits）：$(($report | Where-Object Status -eq 'STALE').Count) 個"
Write-Host "ACTIVE：$(($report | Where-Object Status -eq 'ACTIVE').Count) 個"
```

**執行：**
```powershell
.\docs\archaeology\tmp\step2-git-stability.ps1
```

---

### Step 3：Private/Internal 死碼掃描

**先寫檔，再執行：**

```
將以下內容寫入 docs/archaeology/tmp/step3-dead-scan.ps1
執行完成後再執行該檔案
```

```powershell
# step3-dead-scan.ps1
$ErrorActionPreference = 'Stop'
$root = (Get-Location).Path

# 取得所有 Ex.csproj 的資料夾（排除這些資料夾內的 .cs 檔案）
$exProjDirs = Get-ChildItem -Recurse -Filter '*Ex.csproj' |
  ForEach-Object { $_.DirectoryName }

$allCsFiles = Get-ChildItem -Recurse -Filter "*.cs" | Where-Object {
  $_.FullName -notmatch '\\obj\\' -and
  $_.FullName -notmatch '\\bin\\' -and
  $_.Length -gt 0
}

# 排除 Ex 資料夾內的檔案
$filteredFiles = $allCsFiles | Where-Object {
  $filePath = $_.FullName
  $skip = $false
  foreach ($exDir in $exProjDirs) {
    if ($filePath.StartsWith($exDir)) { $skip = $true; break }
  }
  -not $skip
}

Write-Host "掃描 $($filteredFiles.Count) 個 .cs 檔案..."

$skipPattern   = '^(InitializeComponent|Dispose|get_|set_|add_|remove_|On[A-Z])'
$methodPattern = '(?:private|internal)\s+(?:static\s+)?(?:\w+[\[\]?]*\s+)+(\w+)\s*\('

# 第一步：收集所有 method 定義
$fileMethods = [System.Collections.Generic.List[PSCustomObject]]::new()
foreach ($f in $filteredFiles) {
  $content = Get-Content $f.FullName -Raw -Encoding UTF8
  foreach ($m in [regex]::Matches($content, $methodPattern)) {
    $name = $m.Groups[1].Value
    if ($name -match $skipPattern) { continue }
    $line = ($content.Substring(0, $m.Index) -split "`n").Count
    $fileMethods.Add([PSCustomObject]@{
      Method = $name
      File   = $f.FullName
      Line   = $line
    })
  }
}

Write-Host "找到 $($fileMethods.Count) 個 private/internal method，開始交叉搜尋呼叫者..."

# 第二步：建立全域 token 計數（避免重複 grep 同名 method）
$globalTokenCount = @{}
foreach ($f in $filteredFiles) {
  $content = Get-Content $f.FullName -Raw -Encoding UTF8
  foreach ($entry in $fileMethods) {
    $name = $entry.Method
    if (-not $globalTokenCount.ContainsKey($name)) {
      $globalTokenCount[$name] = 0
    }
    $selfCount = ([regex]::Matches($content, "\b$([regex]::Escape($name))\b")).Count
    $globalTokenCount[$name] += $selfCount
  }
}

# 第三步：找出呼叫者為 0 的 method
$deadCandidates = [System.Collections.Generic.List[PSCustomObject]]::new()
foreach ($entry in $fileMethods) {
  $name        = $entry.Method
  $fileContent = Get-Content $entry.File -Raw -Encoding UTF8
  $selfCount   = ([regex]::Matches($fileContent, "\b$([regex]::Escape($name))\b")).Count
  $totalCount  = if ($globalTokenCount.ContainsKey($name)) { $globalTokenCount[$name] } else { 0 }
  $callers     = [Math]::Max(0, $totalCount - $selfCount)

  if ($callers -eq 0) {
    $rel = $entry.File.Replace($root, '')
    $deadCandidates.Add([PSCustomObject]@{
      Method = $name
      File   = $rel
      Line   = $entry.Line
    })
  }
}

$deadCandidates |
  Export-Csv 'docs/archaeology/tmp/dead-candidates.csv' -NoTypeInformation -Encoding UTF8 -Force

Write-Host "dead-candidates.csv 產出完成：$($deadCandidates.Count) 個候選"
```

**執行：**
```powershell
.\docs\archaeology\tmp\step3-dead-scan.ps1
```

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

讀取 `.github/skills/csharp-archaeology/templates/layer1-global-map-template.html`，
依下表填入 placeholder，寫出至 `docs/archaeology/00-global-map.html`。

**純量 placeholder：**

| Token | 值 |
|-------|---|
| `{{DATE}}` | 執行當天日期（YYYY-MM-DD） |
| `{{SOLUTION_NAME}}` | 找到的 .sln 檔名（不含路徑） |
| `{{PROJECT_COUNT}}` | 分析 project 總數 |
| `{{ISLAND_COUNT}}` | 孤島模組數（dependency-map.json） |
| `{{STALE_COUNT}}` | FROZEN + STALE 模組數（git-stability.csv） |
| `{{DEAD_COUNT}}` | dead-candidates.csv 總列數 |

**資料區段 marker：** 把 marker 行替換為從 CSV/JSON 產生的 HTML 列（格式見模板內 HTML comment）。

| Marker | 資料來源 |
|--------|---------|
| `<!-- ##HUB_ROWS## -->` | dependency-map.json .hubs Top 15 |
| `<!-- ##ISLAND_CARDS## -->` | dependency-map.json .islands × git-stability.csv |
| `<!-- ##GIT_ROWS## -->` | git-stability.csv 全部 |
| `<!-- ##DEAD_ROWS## -->` | dead-candidates.csv Top 50 |
| `<!-- ##PRIORITY_ITEMS## -->` | AI 綜合分析建議 |

---

## Layer 2 — 模組深挖

> 目標：了解指定模組的 public API 在 solution 內的呼叫關係。
> 前提：Layer 1 已完成。
> 觸發：RD 指定模組名稱，例如「深挖 HMIWafermap」。
> 時間：每個模組約 5–10 分鐘。
> 輸出：`docs/archaeology/[ModuleName]-report.html`

### Step 1：找出 Public API

**先寫檔，再執行：**

```
將以下內容寫入 docs/archaeology/tmp/layer2-step1-api.ps1
執行完成後再執行該檔案
```

```powershell
# layer2-step1-api.ps1
param([string]$ModuleName)
$ErrorActionPreference = 'Stop'

$moduleFolder = Get-ChildItem -Recurse -Filter "$ModuleName.csproj" |
  Where-Object { $_.Name -notmatch "Ex\.csproj$" } |
  Select-Object -First 1 -ExpandProperty DirectoryName

if (-not $moduleFolder) {
  Write-Error "找不到 $ModuleName.csproj，請確認模組名稱"
  exit 1
}

Write-Host "分析模組：$ModuleName（$moduleFolder）"

$csFiles  = Get-ChildItem -Path $moduleFolder -Recurse -Filter "*.cs" |
  Where-Object { $_.FullName -notmatch '\\obj\\' }

$publicApi = [System.Collections.Generic.List[PSCustomObject]]::new()
foreach ($file in $csFiles) {
  $content = Get-Content $file.FullName -Raw -Encoding UTF8
  [regex]::Matches($content, 'public\s+(?:partial\s+)?class\s+(\w+)') |
    ForEach-Object {
      $publicApi.Add([PSCustomObject]@{ Type="class"; Name=$_.Groups[1].Value; File=$file.Name })
    }
  [regex]::Matches($content, 'public\s+(?:static\s+|virtual\s+|override\s+)?(?:\w+[\[\]?]*\s+)+(\w+)\s*\(') |
    ForEach-Object {
      $publicApi.Add([PSCustomObject]@{ Type="method"; Name=$_.Groups[1].Value; File=$file.Name })
    }
}

$publicApi | ConvertTo-Json |
  Out-File "docs/archaeology/tmp/$ModuleName-api.json" -Encoding UTF8 -Force

Write-Host "找到 $($publicApi.Count) 個 public API → $ModuleName-api.json"
```

**執行：**
```powershell
.\docs\archaeology\tmp\layer2-step1-api.ps1 -ModuleName "HMIWafermap"
```

### Step 2：搜尋呼叫者

**先寫檔，再執行：**

```
將以下內容寫入 docs/archaeology/tmp/layer2-step2-usage.ps1
執行完成後再執行該檔案
```

```powershell
# layer2-step2-usage.ps1
param([string]$ModuleName)
$ErrorActionPreference = 'Stop'

$moduleFolder = Get-ChildItem -Recurse -Filter "$ModuleName.csproj" |
  Where-Object { $_.Name -notmatch "Ex\.csproj$" } |
  Select-Object -First 1 -ExpandProperty DirectoryName

$apiJson  = Get-Content "docs/archaeology/tmp/$ModuleName-api.json" -Raw | ConvertFrom-Json
$allCsFiles = Get-ChildItem -Recurse -Filter "*.cs" | Where-Object {
  $_.FullName -notmatch '\\obj\\' -and
  $_.FullName -notmatch '\\bin\\' -and
  $_.FullName -notmatch $moduleFolder
}

Write-Host "搜尋 $($apiJson.Count) 個 API 在 $($allCsFiles.Count) 個檔案中的呼叫者..."

$usageReport = foreach ($api in $apiJson) {
  $callers = $allCsFiles |
    Select-String -Pattern "\b$([regex]::Escape($api.Name))\b" -SimpleMatch |
    Select-Object -ExpandProperty Path | Sort-Object -Unique

  [PSCustomObject]@{
    API         = $api.Name
    Type        = $api.Type
    CallerCount = $callers.Count
    Callers     = ($callers | ForEach-Object { Split-Path $_ -Leaf }) -join "; "
  }
}

$usageReport | Sort-Object CallerCount |
  Export-Csv "docs/archaeology/tmp/$ModuleName-usage.csv" -NoTypeInformation -Encoding UTF8 -Force

Write-Host "$ModuleName-usage.csv 產出完成"
Write-Host "Solution 內零呼叫：$(($usageReport | Where-Object CallerCount -eq 0).Count) 個"
```

**執行：**
```powershell
.\docs\archaeology\tmp\layer2-step2-usage.ps1 -ModuleName "HMIWafermap"
```

### Layer 2 最終輸出

讀取 `.github/skills/csharp-archaeology/templates/layer2-module-report-template.html`，
填入 placeholder，寫出至 `docs/archaeology/{{MODULE_NAME}}-report.html`。

**純量 placeholder：** `{{MODULE_NAME}}`, `{{API_COUNT}}`, `{{HAS_CALLERS}}`, `{{ZERO_CALLERS}}`, `{{UPSTREAM_COUNT}}`, `{{DOWNSTREAM_COUNT}}`, `{{DATE}}`

**資料區段 marker：**

| Marker | 資料來源 |
|--------|---------|
| `<!-- ##UPSTREAM_ITEMS## -->` | dependency-map.json（此模組的 ProjectReference） |
| `<!-- ##DOWNSTREAM_ITEMS## -->` | dependency-map.json（誰依賴此模組） |
| `<!-- ##API_ROWS## -->` | `{ModuleName}-usage.csv` |
| `<!-- ##HEATMAP_CELLS## -->` | `{ModuleName}-usage.csv` 彙總至 project |

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
