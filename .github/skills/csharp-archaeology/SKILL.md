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

## 邊界規則（永遠遵守）

- 只處理 `.csproj`，跳過所有 `.vcxproj`（C++ 專案）
- `*Ex.csproj` 結尾的 project：跳過分析其內部，但保留它作為被依賴關係
- 死碼候選只涵蓋 `private` / `internal`，`public` 不標記為死碼

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

# 確認 4：docs/archaeology 資料夾存在，不存在就建立
New-Item -ItemType Directory -Force -Path "docs/archaeology"
```

---

## Layer 1 — 全局掃描

> 目標：建立可信的依賴地圖、找出孤島模組、產出 private/internal 死碼候選。
> 時間：約 10–20 分鐘。
> 輸出：`/docs/archaeology/00-global-map.md`

### Step 1：建立依賴拓樸

```powershell
# 取得所有合法 C# project（排除 Ex 結尾）
$allProjects = Get-ChildItem -Recurse -Filter "*.csproj" |
  Where-Object { $_.Name -notmatch "Ex\.csproj$" -and $_.Extension -eq ".csproj" }

$dependencyMap = @{}

foreach ($proj in $allProjects) {
  $projName = [System.IO.Path]::GetFileNameWithoutExtension($proj.Name)
  [xml]$content = Get-Content $proj.FullName -Encoding UTF8
  $refs = $content.SelectNodes("//ProjectReference/@Include") |
    ForEach-Object {
      [System.IO.Path]::GetFileNameWithoutExtension($_.Value)
    }
  $dependencyMap[$projName] = @($refs)
}

# 找出孤島：沒有任何 project 依賴它的模組
$allReferenced = $dependencyMap.Values | ForEach-Object { $_ } | Sort-Object -Unique
$islands = $dependencyMap.Keys | Where-Object { $_ -notin $allReferenced }

# 找出樞紐：被最多 project 依賴的模組
$hubScore = @{}
foreach ($refs in $dependencyMap.Values) {
  foreach ($ref in $refs) {
    if ($hubScore[$ref]) { $hubScore[$ref]++ } else { $hubScore[$ref] = 1 }
  }
}
$hubs = $hubScore.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 20
```

將結果整理成 Markdown 表格，格式如下：

```markdown
## 依賴拓樸

### 樞紐模組（被依賴次數最多，改動風險最高）
| 模組名稱 | 被依賴次數 |
|---------|-----------|
| HMIWafermap | 23 |
| HMIDataBasic | 18 |

### 孤島模組（沒有任何 project 依賴它）
| 模組名稱 | 備註 |
|---------|------|
| HMIKlarfLegacy | 候選刪除，需搭配其他訊號確認 |
```

---

### Step 2：Git 穩定度分析

> 用途：了解模組活躍度，作為參考資訊。
> 注意：穩定度低不代表是死碼，穩定度高代表模組相對成熟。

```powershell
$allProjects = Get-ChildItem -Recurse -Filter "*.csproj" |
  Where-Object { $_.Name -notmatch "Ex\.csproj$" }

$activityReport = foreach ($proj in $allProjects) {
  $folder = $proj.DirectoryName
  $projName = [System.IO.Path]::GetFileNameWithoutExtension($proj.Name)

  # 過去兩年的 commit 數
  $commitCount = git log --since="2 years ago" --oneline -- "$folder" 2>$null |
    Measure-Object -Line | Select-Object -ExpandProperty Lines

  # 最後一次 commit 日期
  $lastCommit = git log -1 --format="%ad" --date=short -- "$folder" 2>$null

  [PSCustomObject]@{
    Module     = $projName
    Commits2yr = $commitCount
    LastCommit = $lastCommit
  }
}

$activityReport | Sort-Object Commits2yr | Format-Table -AutoSize
```

將結果整理成 Markdown 表格，標注：
- `Commits2yr = 0`：兩年完全沒有異動
- `LastCommit > 3 years ago`：超過三年未動

---

### Step 3：Private/Internal 死碼候選掃描

> 用途：找出定義了但在 solution 內找不到呼叫者的 private/internal 成員。
> 注意：這是候選清單，需要人工二次確認，誤報率比 Roslyn 高。

```powershell
$allCsFiles = Get-ChildItem -Recurse -Filter "*.cs" |
  Where-Object { $_.FullName -notmatch "\\obj\\" -and $_.FullName -notmatch "\\bin\\" }

$deadCandidates = @()

foreach ($file in $allCsFiles) {
  $content = Get-Content $file.FullName -Raw

  # 找出所有 private / internal method 定義
  $methodPattern = '(?:private|internal)\s+(?:static\s+)?(?:\w+\s+)+(\w+)\s*\('
  $matches = [regex]::Matches($content, $methodPattern)

  foreach ($match in $matches) {
    $methodName = $match.Groups[1].Value

    # 跳過常見的 WinForms 自動產生 pattern
    if ($methodName -match "^(InitializeComponent|Dispose|get_|set_)") { continue }

    # 在整個 solution 搜尋呼叫者
    $callerCount = $allCsFiles |
      Select-String -Pattern "\b$methodName\b" -SimpleMatch |
      Where-Object { $_.Path -ne $file.FullName } |
      Measure-Object | Select-Object -ExpandProperty Count

    if ($callerCount -eq 0) {
      $deadCandidates += [PSCustomObject]@{
        Method   = $methodName
        File     = $file.FullName
        Line     = ($content.Substring(0, $match.Index) -split "`n").Count
      }
    }
  }
}

$deadCandidates | Export-Csv "docs/archaeology/dead-candidates.csv" -NoTypeInformation
Write-Host "找到 $($deadCandidates.Count) 個 private/internal 死碼候選"
```

---

### Layer 1 輸出格式

將以上三個步驟的結果整合，產出 `/docs/archaeology/00-global-map.md`：

```markdown
# Codebase 全局地圖
產出日期：[DATE]
分析範圍：[N] 個 C# project（排除 Ex 結尾與 vcxproj）

## 1. 依賴拓樸
### 樞紐模組
[表格]

### 孤島模組
[表格]

## 2. Git 穩定度
[表格]
兩年完全未動的模組：[N] 個
超過三年未動的模組：[N] 個

## 3. Private/Internal 死碼候選
總計：[N] 個候選（詳見 dead-candidates.csv）
⚠️ 以下為候選清單，需人工二次確認後才能刪除

## 4. 建議優先深挖模組
根據以上分析，建議優先針對以下模組執行 Layer 2：
1. [孤島 + 兩年未動] → 刪除候選
2. [樞紐模組] → 理解邊界，重構時避開
```

---

## Layer 2 — 模組深挖

> 目標：了解指定模組的 public API 在 solution 內的呼叫關係。
> 前提：Layer 1 已完成。
> 觸發：RD 指定模組名稱，例如「深挖 HMIWafermap」。
> 時間：每個模組約 5–10 分鐘。
> 輸出：`/docs/archaeology/[ModuleName]-report.md`

### Step 1：找出模組的 Public API

```powershell
$moduleName = "[RD 指定的模組名稱]"
$moduleFolder = Get-ChildItem -Recurse -Filter "$moduleName.csproj" |
  Where-Object { $_.Name -notmatch "Ex\.csproj$" } |
  Select-Object -First 1 -ExpandProperty DirectoryName

# 找出所有 public class 和 public method
$csFiles = Get-ChildItem -Path $moduleFolder -Recurse -Filter "*.cs" |
  Where-Object { $_.FullName -notmatch "\\obj\\" }

$publicApi = @()
foreach ($file in $csFiles) {
  $content = Get-Content $file.FullName -Raw

  # Public class
  $classMatches = [regex]::Matches($content, 'public\s+(?:partial\s+)?class\s+(\w+)')
  foreach ($m in $classMatches) {
    $publicApi += [PSCustomObject]@{ Type = "class"; Name = $m.Groups[1].Value; File = $file.Name }
  }

  # Public method
  $methodMatches = [regex]::Matches($content, 'public\s+(?:static\s+|virtual\s+|override\s+)?(?:\w+\s+)+(\w+)\s*\(')
  foreach ($m in $methodMatches) {
    $publicApi += [PSCustomObject]@{ Type = "method"; Name = $m.Groups[1].Value; File = $file.Name }
  }
}

Write-Host "找到 $($publicApi.Count) 個 public API"
```

### Step 2：找出 Solution 內的呼叫者

```powershell
# 在整個 solution（排除該模組自身）搜尋每個 public API 的呼叫者
$allCsFiles = Get-ChildItem -Recurse -Filter "*.cs" |
  Where-Object { $_.FullName -notmatch "\\obj\\" -and $_.FullName -notmatch $moduleFolder }

$usageReport = foreach ($api in $publicApi) {
  $callers = $allCsFiles |
    Select-String -Pattern "\b$($api.Name)\b" -SimpleMatch |
    Select-Object -ExpandProperty Path |
    Sort-Object -Unique

  [PSCustomObject]@{
    API          = $api.Name
    Type         = $api.Type
    CallerCount  = $callers.Count
    Callers      = ($callers | ForEach-Object { Split-Path $_ -Leaf }) -join ", "
  }
}

$usageReport | Sort-Object CallerCount | Format-Table -AutoSize
```

### Layer 2 輸出格式

產出 `/docs/archaeology/[ModuleName]-report.md`：

```markdown
# [ModuleName] 模組深挖報告
產出日期：[DATE]

## Public API 清單與 Solution 內呼叫關係

| API 名稱 | 類型 | Solution 內呼叫次數 | 呼叫來源 |
|---------|------|-------------------|---------|
| ProcessKlarfFile | method | 3 | CDDataReview, HMIMain, HMIBatch |
| KlarfParser | class | 0 | （solution 內無呼叫） |

⚠️ Solution 內呼叫次數為 0 的項目：不代表是死碼。
   可能被 cb8/cb9/ure 透過 dll 引用，需等平行任務 A 完成後才能確認。

## 這個模組依賴誰
[從 .csproj ProjectReference 列出]

## 誰依賴這個模組
[從 Layer 1 依賴拓樸取出]
```

---

## 平行任務文件

> Layer 1 完成後，自動產出 `/docs/archaeology/parallel-tasks.md`。
> 這份文件不由 Skill 自動執行，由 RD 或 Tech Lead 安排人力處理。

```markdown
# 平行任務清單
產出日期：[DATE]

## Task A：掃描 cb8/cb9/ure 找 dll 引用

目的：確認哪些 public API 被外部 repo 透過 dll 直接引用，
     補上靜態分析無法看到的依賴關係。

執行步驟：
1. Clone cb8、cb9、ure 三個 repo
2. 在每個 repo 中執行：
   Get-ChildItem -Recurse -Filter "*.csproj" |
     Select-String -Pattern "[你的模組名稱]"
3. 同時搜尋 packages/ 或 lib/ 資料夾下是否有你們的 .dll 檔案
4. 將結果回填至對應的 [ModuleName]-report.md

預計工作量：1–2 天（視三個 repo 大小而定）

## Task B：Runtime Telemetry 佈建

目的：透過執行期 log 確認哪些功能真正被使用者觸發，
     補上靜態分析無法判斷的 public API 使用情況。

執行步驟：
1. 在每個主要 Form 的進入點加入結構化 log：
   Logger.Log($"[TELEMETRY] {moduleName}.{methodName} called");
2. 部署至 staging 環境
3. 收集至少 3 個月資料（涵蓋季結、年結等低頻操作）
4. 將從未出現的 log 項目標記為死碼候選

預計工作量：
- 佈建：1 週
- 等待資料：3–6 個月
```
