---
name: csharp-archaeology
description: >
  Phase 0 考古 Skill：針對大型 legacy C# WinForms codebase，在不依賴任何人記憶的
  情況下，讓程式碼自己說話。分兩層執行：Layer 1 產出全局依賴地圖與死碼候選清單；
  Layer 2 針對指定模組深挖 API 呼叫關係，輸出 Decision Recommendation（Delete /
  Extract / Refactor / Leave alone）。同時產出 copilot-instructions-draft.md 與
  parallel-tasks.md 供下游 Phase 1–5 使用。
  ALWAYS use this skill when user mentions "phase 0", "考古", "archaeology",
  "分析 codebase", "模組邊界", "找死碼", "開始重構前的分析", 或 "建立依賴地圖"。
---

# C# Codebase Archaeology — Phase 0

## 設計原則

**原則 A：SKILL.md 零程式碼**
所有 PowerShell 邏輯住在 `.github/skills/csharp-archaeology/scripts/` 獨立檔案中。
SKILL.md 只包含說明、決策規則、步驟指令（呼叫哪個 script）、AI 分析指引。

**原則 D：環境工具白名單（嚴格遵守）**

> ⚠️ 此 skill 在 VDI / 企業受控環境執行，**禁止使用任何需要額外安裝的外部工具**。

AI 在執行本 skill 的任何步驟時，**只允許**使用以下工具：

| 允許工具 | 用途 |
|----------|------|
| PowerShell 原生 cmdlet（`Get-Content`、`Select-String`、`Get-ChildItem`、`Where-Object` 等） | 檔案讀取與搜尋 |
| `git`（假設已安裝） | 版本歷史查詢（step2、layer2-step2 已使用） |
| `.ps1` scripts（本 skill 的 scripts/ 資料夾） | 所有分析邏輯 |

**嚴格禁止**使用以下工具（即使在其他環境下可用）：

| 禁止工具 | 原因 |
|----------|------|
| `rg` / `ripgrep` | 需額外安裝，VDI 環境無此工具 |
| `fd` | 需額外安裝 |
| `bat` | 需額外安裝 |
| `fzf` | 需額外安裝 |
| 任何 `choco` / `winget` / `scoop` 安裝的工具 | 受控環境無安裝權限 |

若需搜尋檔案內容，使用 PowerShell 原生替代：
- `rg "pattern" path` → `Get-ChildItem path -Recurse | Select-String "pattern"`
- `rg "pattern" file -n` → `Select-String -Path file -Pattern "pattern"`

**原則 E：scripts/ 資料夾內容不可修改（嚴格遵守）**

> ⚠️ `.github/skills/csharp-archaeology/scripts/` 下的所有 `.ps1` 檔案是**固化版本**，已針對 PS 5.x 環境測試通過。

- AI **絕對不可以**在 skill 執行期間修改任何 `.ps1` 腳本
- 即使發現語法可以優化或更簡潔，也不得修改
- 若腳本有 bug，應在**完成本次分析後**另外回報，而非即時改動
- 腳本已全面使用 PS 5.x 相容語法（無 `?.`、無 `??=` 等 PS7+ 語法）

**原則 B：兩種輸出格式，目的不同**

| 格式 | 目的 | 對象 |
|------|------|------|
| HTML 信息圖表 | 人讀：30 秒內看到關鍵決策與數字 | 工程師、Tech Lead |
| JSON / CSV | 機器讀：後續 Phase 2/3/4 流程處理 | AI、NDepend、CI pipeline |

**原則 C：所有輸出寫入 target workspace 根目錄下的 `.analysis/`**
step0-preflight 第一步自動建立此資料夾並放置 `.gitignore`（`*`），避免產物被 commit。

---

## 邊界規則（永遠遵守）

- 只處理 `.csproj`，跳過所有 `.vcxproj`（C++ 專案）
- `*Ex.csproj` 結尾的 project：跳過分析其內部，但保留它作為被依賴關係
- 死碼候選只涵蓋 `private` / `internal`，`public` 不標記（可能被外部 dll 引用）

---

## 輸出資料夾結構

```
{target-workspace}/.analysis/
├── tmp/                              ← Layer 1 中間檔
│   ├── preflight-report.json
│   ├── dependency-map.json
│   ├── git-stability.csv
│   └── dead-candidates.csv
├── 00-global-map.html                ← Layer 1 報告
├── parallel-tasks.md                 ← 平行任務（Layer 2 後更新為具體 targets）
├── copilot-instructions-draft.md     ← Phase 0 Synthesis（AI 直接寫入）
└── {ModuleName}/                     ← 每個 Layer 2 模組一個資料夾
    ├── {ModuleName}-api.json
    ├── {ModuleName}-usage.csv
    ├── {ModuleName}-coupling-in.csv
    ├── {ModuleName}-vitality.csv
    └── {ModuleName}-report.html
```

---

## Layer 0.5 — Preflight

**目的：** 評估 codebase 規模，建立 `.analysis/` 資料夾，提供時間預估。

執行：
```
.\.github\skills\csharp-archaeology\scripts\step0-preflight.ps1
```

確認輸出：
```
.analysis/tmp/preflight-report.json 存在且非空
```

**AI 讀取 preflight-report.json，依 Complexity Tier 告知使用者預估時間：**

| Tier | 條件 | Step 3 預估 | Layer 1 總計 |
|------|------|------------|-------------|
| SMALL | C# project < 30 | 1–2 min | 5–10 min |
| MEDIUM | 30–99 | 5–10 min | 15–30 min |
| LARGE | 100+ | 15–30 min | 45–90 min |

詢問使用者確認後繼續執行 Layer 1。

---

## Layer 1 — 全局掃描

> 目標：建立可信的依賴地圖、找出孤島模組、產出 private/internal 死碼候選。
> 前提：Layer 0.5 Preflight 已完成。
> 中間檔輸出至 `.analysis/tmp/`；HTML 報告輸出至 `.analysis/00-global-map.html`。

### Step 1：建立依賴拓樸

執行：
```
.\.github\skills\csharp-archaeology\scripts\step1-dependency-map.ps1
```

確認輸出：
```
.analysis/tmp/dependency-map.json 存在且非空
```

### Step 2：Git 活躍度

執行：
```
.\.github\skills\csharp-archaeology\scripts\step2-git-stability.ps1
```

確認輸出：
```
.analysis/tmp/git-stability.csv 存在且非空
```

### Step 3：Private/Internal 死碼掃描

執行：
```
.\.github\skills\csharp-archaeology\scripts\step3-dead-scan.ps1
```

確認輸出：
```
.analysis/tmp/dead-candidates.csv 存在且非空
```

> **提醒：** Step 3 是最慢的步驟。依 Complexity Tier 預估時間後告知使用者，請耐心等候。

---

### Layer 1 AI 分析流程

三份中間檔產出後，依序執行：

1. 讀 `.analysis/tmp/dependency-map.json`
   - 樞紐模組 Top 15（hubScore）+ 孤島模組清單（islands）

2. 讀 `.analysis/tmp/git-stability.csv`
   - 每個模組標注 ACTIVE / STALE / FROZEN

3. 讀 `.analysis/tmp/dead-candidates.csv`（Top 50，優先孤島模組）
   - 列出 HIGH Confidence 候選（Confidence=HIGH 且無 RiskFlags）

4. 計算 Tier，產出 Tier 交叉訊號表

**Tier 計算規則（明確，不自由發揮）：**

| Tier | 判斷條件 |
|------|---------|
| TIER-1（刪除候選）| `islands` 中 AND (FROZEN 或 STALE) AND dead-candidates.csv 中有對應模組的項目 |
| TIER-2（Layer 2 優先）| 高 hubScore OR dead count 多 OR STALE 但有呼叫者 |
| TIER-3（觀察）| ACTIVE 且 dead count 少 |

5. 選出 Top 3 Layer 2 深挖候選（含一句理由）

6. 記錄初步 No-go zones（TIER-2 Hub 模組 + 已知高 coupling 模組）→ 供 Phase 0 Synthesis 使用

---

### Layer 1 最終輸出

讀取 `.github/skills/csharp-archaeology/templates/layer1-global-map-template.html`，
填入 placeholder，寫出至 `.analysis/00-global-map.html`。

**純量 placeholder：**

| Token | 值 |
|-------|---|
| `{{DATE}}` | 執行當天日期（YYYY-MM-DD） |
| `{{SOLUTION_NAME}}` | 找到的 .sln 檔名（不含路徑） |
| `{{PROJECT_COUNT}}` | 分析 project 總數 |
| `{{ISLAND_COUNT}}` | 孤島模組數 |
| `{{STALE_COUNT}}` | FROZEN + STALE 模組數 |
| `{{DEAD_COUNT}}` | dead-candidates.csv 總列數 |
| `{{QUICKWIN_COUNT}}` | TIER-1 模組數（island AND stale/frozen AND 有私有死碼） |
| `{{TOP_HUB_NAME}}` | hubScore 最高的模組名稱 |
| `{{TOP_HUB_SCORE}}` | hubScore 最高的分數（被依賴次數） |

**資料區段 marker：**

| Marker | 資料來源 |
|--------|---------|
| `<!-- ##HUB_ROWS## -->` | dependency-map.json .hubs Top 15；每列含 ModuleName、HubScore、FileCount |
| `<!-- ##ISLAND_CARDS## -->` | dependency-map.json .islands × git-stability.csv × dead-candidates.csv；每列含 ModuleName、Git狀態、DeadCount |
| `<!-- ##GIT_SIGNAL_SUMMARY## -->` | AI 產出 2–4 個解讀 pills（例：「X 個 FROZEN 孤島 = 高價值清除目標」） |
| `<!-- ##GIT_ROWS## -->` | git-stability.csv 全部 |
| `<!-- ##TIER_TABLE## -->` | AI 計算的 Tier 交叉訊號表（Module \| Git Status \| Dead Count \| Tier）|
| `<!-- ##NOGO_ITEMS## -->` | TIER-2 Hub 模組的禁止重構卡片（3–8 個）；格式：nogo-item 帶 nogo-name + nogo-reason |
| `<!-- ##DEAD_ROWS## -->` | dead-candidates.csv Top 50 |
| `<!-- ##QUICKWIN_ROWS## -->` | TIER-1 模組列表：island AND (FROZEN\|STALE) AND 有私有死碼；可直接清除 |
| `<!-- ##LAYER2_CANDIDATES## -->` | Top 3 Layer 2 推薦模組卡片（含一行理由） |
| `<!-- ##PRIORITY_ITEMS## -->` | AI 根據全部分析綜合判斷的行動建議（3–6 項）；act 類型：act-layer2 / act-delete / act-monitor |
| `<!-- ##PHASE_HANDOFFS## -->` | Phase 0 交付 artifacts 簡表 |

**Layer 1 完成後，同時產出 `.analysis/parallel-tasks.md` 第一版（模組名稱暫填候選）。**

---

## Layer 1 Checkpoint — 強制，進入 Layer 2 前執行

Layer 1 所有步驟與 HTML 報告完成後，**必須**依以下順序執行 checkpoint：

### Step A：在 chat 中 surface 關鍵事實

輸出以下摘要（填入實際數字）：

```
Layer 1 complete. Found {totalProjects} projects, {islandCount} islands,
{deadCandidateCount} dead candidates. Top hub: {topHubName} (score={topHubScore}).
Git: {activeCount} ACTIVE / {staleCount} STALE / {frozenCount} FROZEN.
Top 3 Layer 2 candidates: {A}, {B}, {C}. HTML and parallel-tasks.md written.
```

### Step B：呼叫 /verify-archaeology

```
/verify-archaeology
```

evaluator 會讀取上方 chat 摘要 + 執行 `verify-outputs.ps1 -Layer layer1`，然後回傳：
- **PASS** → 進入 Layer 2
- **GAPS** → 修正所有 gap，重新 surface 更新後的數字，再次呼叫 `/verify-archaeology`

> **規則：** 未取得 `/verify-archaeology` 的 PASS，不得進入 Layer 2。

---

## Layer 2 — 模組深挖

> 目標：了解指定模組的 API 使用關係，產出 Decision Recommendation。
> 前提：Layer 1 已完成。
> 觸發：RD 指定模組名稱，例如「深挖 HMIWaferMap」。
> 時間：每個模組約 5–10 分鐘。

### Layer 2 範圍決策（執行前判斷）

AI 在執行 Layer 2 前先判斷分析粒度：

- 若目標 project 有子資料夾 > 300 LOC 且名稱含 `Pane / Manager / Service / Handler / Helper` → 建議使用 `-ModulePath` 子資料夾模式
- 否則使用 `-ModuleName` project 模式

### Step 1：找出 Public API

**Project 模式：**
```
.\.github\skills\csharp-archaeology\scripts\layer2-step1-api.ps1 -ModuleName "HMIWaferMap"
```

**Subfolder 模式：**
```
.\.github\skills\csharp-archaeology\scripts\layer2-step1-api.ps1 -ModulePath "HMIWaferMap/HMIWaferMapPane"
```

確認輸出：
```
.analysis/{ModuleName}/{ModuleName}-api.json 存在且非空
```

### Step 2：搜尋呼叫者與 coupling 資料

**Project 模式：**
```
.\.github\skills\csharp-archaeology\scripts\layer2-step2-usage.ps1 -ModuleName "HMIWaferMap"
```

**Subfolder 模式：**
```
.\.github\skills\csharp-archaeology\scripts\layer2-step2-usage.ps1 -ModulePath "HMIWaferMap/HMIWaferMapPane"
```

確認輸出：
```
.analysis/{ModuleName}/{ModuleName}-usage.csv 存在且非空
.analysis/{ModuleName}/{ModuleName}-coupling-in.csv 存在
.analysis/{ModuleName}/{ModuleName}-vitality.csv 存在
```

---

### Layer 2 AI 分析流程

讀取四份輸出後，依以下決策矩陣判斷：

| 決策 | 關鍵訊號 |
|------|---------|
| **Delete** | 零 TotalExternalCallSites AND TestCallerCount=0 AND FROZEN git AND 無 HIGH RiskFlags |
| **Extract** | 低 TotalExternalCallSites AND SAME_PROJECT coupling-in 少 AND 明確 Namespace 邊界 |
| **Refactor** | TestCallerCount > 0（有安全網）AND 無循環依賴 |
| **Leave alone** | 高 TopCallerSites（爆炸半徑大）OR ACTIVE 且多個 callers |

---

### Layer 2 最終輸出

#### 在 chat 顯示 Decision Recommendation：

```
## Decision Recommendation

**Target:** {名稱}
**Recommended Action:** Delete / Extract / Refactor / Leave alone
**Confidence:** HIGH / MEDIUM / LOW

**三行 Evidence：**
- Coupling Out: {TotalExternalCallSites} 個呼叫點 / {TotalCallerProjects} 個 projects；最深：{TopCallerProject}（{TopCallerSites} 點）
- Dead Surface: {X}/{Total} API 零呼叫；Vitality：最後 commit {日期}，近 2 年 {N} commits
- Safety Net: {TestCallerCount} 個測試呼叫；Coupling In: {N} SAME_PROJECT 阻斷器

**前置條件（若有）：** {條件清單}
**建議第一步：** {一個具體動作}
```

#### 寫出 HTML 報告：

讀取 `.github/skills/csharp-archaeology/templates/layer2-module-report-template.html`，
填入 placeholder，寫出至 `.analysis/{ModuleName}/{ModuleName}-report.html`。

**純量 placeholder：**

| Token | 值 |
|-------|---|
| `{{MODULE_NAME}}` | 目標名稱 |
| `{{DATE}}` | 執行當天日期 |
| `{{API_COUNT}}` | api.json 總項目數 |
| `{{HAS_CALLERS}}` | TotalExternalCallSites > 0 的 API 數 |
| `{{ZERO_CALLERS}}` | ZeroCaller=true 的 API 數 |
| `{{UPSTREAM_COUNT}}` | 此模組引用的 project 數（dependency-map.json） |
| `{{DOWNSTREAM_COUNT}}` | 引用此模組的 project 數 |
| `{{DECISION}}` | Delete / Extract / Refactor / Leave alone |
| `{{CONFIDENCE}}` | HIGH / MEDIUM / LOW |
| `{{EVIDENCE_COUPLING}}` | 三行 Evidence 第一行 |
| `{{EVIDENCE_DEAD}}` | 三行 Evidence 第二行 |
| `{{EVIDENCE_SAFETY}}` | 三行 Evidence 第三行 |
| `{{TEST_CALLER_COUNT}}` | TestCallerCount 合計 |

**資料區段 marker：**

| Marker | 資料來源 |
|--------|---------|
| `<!-- ##DECISION_RECOMMENDATION## -->` | Decision 卡片（色碼：Delete=coral，Extract=sky，Refactor=amber，Leave=green）；含 decision-prereq 與 decision-upgrade 區塊 |
| `<!-- ##UPSTREAM_ITEMS## -->` | dependency-map.json（此模組的 ProjectReference） |
| `<!-- ##DOWNSTREAM_ITEMS## -->` | dependency-map.json（誰依賴此模組） |
| `<!-- ##TEST_SIGNAL## -->` | TestCallerCount KPI（安全網訊號） |
| `<!-- ##COUPLING_IN_ROWS## -->` | coupling-in.csv；每列含 TypeName、CouplingType、阻斷類型（AI 由 TypeName 推斷：tag-shared/static/event/instance） |
| `<!-- ##MODULE_DEAD_ROWS## -->` | dead-candidates.csv 篩選 Module=此模組名稱（Top 20）；無資料時填空列提示 |
| `<!-- ##VITALITY_ROWS## -->` | vitality.csv 每個檔案活躍度熱力條；含 ApiCount 欄 |
| `<!-- ##API_ROWS## -->` | usage.csv 全部 API（預設收合，點擊展開） |
| `<!-- ##KEEP_PUBLIC_ITEMS## -->` | usage.csv 中 CallerCount > 0 的 API 清單（保持 public） |
| `<!-- ##MAKE_INTERNAL_ITEMS## -->` | usage.csv 中 CallerCount = 0 的 API 清單 Top 10（建議降為 internal） |
| `<!-- ##HEATMAP_CELLS## -->` | usage.csv 彙總至 project（Top 10） |

---

## Layer 2 Module Checkpoint — 每個模組完成後執行

每個 Layer 2 模組的 HTML 報告寫出後，**必須**依以下順序執行 checkpoint：

### Step A：在 chat 中 surface 模組事實

輸出以下摘要（填入實際數字）：

```
{ModuleName}: Decision={Decision}, Confidence={Confidence}.
{zeroCallerCount}/{apiCount} APIs zero-caller. TestCallerCount={n}.
git: {status}. coupling-in: {n} SAME_PROJECT. Report written.
```

### Step B：呼叫 /verify-archaeology

```
/verify-archaeology
```

- **PASS** → 進入下一個模組或 Phase 0 Synthesis
- **GAPS** → 修正所有 gap，重新 surface 更新後的數字，再次呼叫 `/verify-archaeology`

> **規則：** 未取得 `/verify-archaeology` 的 PASS，不得進入下一個模組或 Synthesis。

---

## Phase 0 Synthesis（所有建議 Layer 2 完成後）

**此步驟無 script，AI 讀取已有 artifacts，直接寫入以下兩個檔案。**

### 產出 `.analysis/copilot-instructions-draft.md`

AI 讀取來源：
1. `.analysis/tmp/preflight-report.json` → .sln 路徑、target framework、build 指令
2. `.analysis/tmp/dependency-map.json` → 所有 project 正確名稱（模組詞彙表）
3. Layer 1 分析時記錄的 No-go zones（TIER-2 Hub + 高 TopCallerSites 模組）；若記憶已遺失，從 `.analysis/00-global-map.html` 的 Tier 表重新推導

寫入格式：
```markdown
---
solution_name: {sln 檔名，不含副檔名，例如 HMIStation}
build_cmd: {完整 build 指令，例如 dotnet build HMIStation.sln}
framework: {target framework，例如 net472}
cs_version: {對應 C# 版本，例如 7.3}
generated_date: {YYYY-MM-DD}
---

## 專案簡介
{待補充 2 句，描述這個 codebase 是做什麼的}

## Build 指令
{完整 build 指令，與 front-matter build_cmd 相同，可加上說明文字}

## 語言版本
{framework}（C# {cs_version}）

## No-go zones（AI 禁止建議重構的區域）
{格式：`ModuleName` — 原因（每行一個）}

## 模組詞彙表（所有 C# project 名稱，保持原始大小寫）
{所有 project 正確名稱，一行一個}
```

### 更新 `.analysis/parallel-tasks.md` 為具體 targets

```markdown
# 平行任務清單 — {DATE}

## Task A：確認外部 dll 引用
目的：確認 TIER-1 模組的 public API 是否被外部 repo 引用。
具體模組：{來自 TIER-1 + TIER-2 的模組名稱清單}
步驟：Clone cb8/cb9/ure → 搜尋 .csproj 與 packages/ 是否有我們的 .dll
預計工作量：1–2 天

## Task B：Runtime Telemetry 佈建
目的：確認哪些 Form 功能真正被使用者觸發。
具體 Form 類別：{來自 Layer 2 api.json 中 BaseClass 含 Form 的類別清單}
步驟：在每個主要 Form 進入點加入結構化 log，部署至 staging，收集 3 個月
預計工作量：佈建 1 週，等待資料 3–6 個月
```

---

## Phase 0 Final Checkpoint — Synthesis 完成後執行

`copilot-instructions-draft.md` 與 `parallel-tasks.md` 最終版寫出後，**必須**執行：

### Step A：在 chat 中 surface Synthesis 事實

```
Phase 0 Synthesis complete. Strangler Fig pilot: {ModuleName} (Extract, {Confidence}).
No-go zones documented: {count}. Module vocabulary: {count} entries.
parallel-tasks.md updated with specific modules and Form classes.
```

### Step B：呼叫 /verify-archaeology（standalone mode）

```
/verify-archaeology
```

evaluator 此時進入 **Mode B**（standalone audit），執行所有 layer 的全面檢查，
並寫出 `.analysis/verification-report.md`。

- **PASS** → Phase 0 完成。▶ **下一步：執行 `/copilot-baseline`，將 `copilot-instructions-draft.md` 精煉為可生效的 Copilot 規則系統。**
- **GAPS / FAIL** → 修正後再次呼叫 `/verify-archaeology`

> **規則：** Phase 0 完成的唯一標準是 `/verify-archaeology` 回傳 PASS。

---

## 完成標準

### Layer 1 完成：
- [ ] `.analysis/tmp/` 下三份中間檔存在且非空
- [ ] `.analysis/00-global-map.html` 含 Tier 表與 Top 3 候選
- [ ] `.analysis/parallel-tasks.md` 第一版產出（候選模組）

### Layer 2（每個模組）完成：
- [ ] 四份 CSV/JSON 存在於 `.analysis/{Module}/`
- [ ] `.analysis/{Module}/{Module}-report.html` 置頂顯示 Decision Recommendation

### Phase 0 整體完成：
- [ ] Top 3 Layer 2 候選全部完成
- [ ] `.analysis/copilot-instructions-draft.md` 產出（含 No-go zones + 模組詞彙表）
- [ ] `.analysis/parallel-tasks.md` 更新為具體模組名稱與 Form 類別
- [ ] 至少一個 Strangler Fig Pilot 確認（Decision = Extract，Confidence = HIGH 或 MEDIUM）
