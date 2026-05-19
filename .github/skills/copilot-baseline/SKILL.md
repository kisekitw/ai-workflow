---
name: copilot-baseline
description: >
  Phase 1 基礎建設 Skill：把 Phase 0 產出的 copilot-instructions-draft.md
  精煉為可立即生效的 Copilot 記憶錨點系統，包含全域規則、範圍指令、
  4 個核心 slash command prompt library，以及 Husky.Net pre-push hook 設定指引。
  ALWAYS use this skill when user mentions "phase 1", "基礎建設",
  "copilot-instructions", "設定 Copilot 規則", "建立 prompt library",
  "pre-push hook", "AI 守衛", 或 "copilot guardrail"。
---

# Copilot Baseline — Phase 1

## 設計原則

**原則 A：從 Phase 0 草稿出發，不從零開始**
若 `.analysis/copilot-instructions-draft.md` 存在，以它為基礎精煉。
若不存在，逐一詢問用戶補全 5 個必填錨點後再寫入。

**原則 B：寫入前一律確認，不覆蓋現有設定**
若目標 `.github/copilot-instructions.md` 已存在，先顯示 diff，
詢問用戶確認「是否覆蓋 / 合併 / 取消」後才動作。

**原則 C：Husky.Net 只給安裝指引，不執行**
Pre-push hook 涉及 target codebase 的 dotnet 環境設定，
由用戶自行執行指令；SKILL.md 只輸出複製貼上即可使用的步驟。

---

## 邊界規則（永遠遵守）

- No-go zones 必須由用戶親口確認，不自動從分析結果推斷後直接寫入
- `*.instructions.md` 必須包含 `applyTo` front-matter，否則 VS Code Copilot 不套用
- `*.prompt.md` 必須包含 `mode: 'agent'` front-matter 才能作為 slash command 執行
- Prompt 內容只描述 AI 「應該做什麼」，不包含任何要分析的實際程式碼
- 如果目標是 net472 以外的 framework，語言版本規則需根據實際 target 調整

---

## 輸出檔案結構

```
{target-workspace}/
├── .github/
│   ├── copilot-instructions.md              ← Step 2 產出（全域規則）
│   ├── instructions/
│   │   ├── csharp-legacy.instructions.md    ← Step 3 產出（C# 版本規則）
│   │   └── winforms-ui.instructions.md      ← Step 3 產出（WinForms UI 規則）
│   └── prompts/
│       ├── characterize.prompt.md           ← Step 4 產出
│       ├── dead-code-audit.prompt.md        ← Step 4 產出
│       ├── plan-refactor.prompt.md          ← Step 4 產出
│       └── refactor-step.prompt.md          ← Step 4 產出
└── .analysis/
    └── copilot-instructions-draft.md        ← Phase 0 Synthesis 輸入來源
```

---

## Step 0 — Preflight

1. 確認 `.analysis/copilot-instructions-draft.md` 是否存在：
   - **存在** → 讀取全文，解析 YAML front-matter，萃取以下欄位供後續步驟使用：
     - `solution_name` → 用於 Step 2 全域指令標題
     - `build_cmd` → 預填 Step 1 Anchor 1
     - `framework` + `cs_version` → 預填 Step 1 Anchor 2
     - `## No-go zones` 節內容 → 預填 Step 1 Anchor 3

     告知用戶：「找到 Phase 0 草稿（{solution_name}），以它為基礎繼續。」，並摘要顯示以上欄位。

     **完整性確認**：若 `## No-go zones` 節或 `## 模組詞彙表` 節內容為空（或仍為範本占位文字），警告用戶：
     > 「Phase 0 草稿可能尚未完成（Layer 2 未跑完或 Synthesis 未執行）。建議先完成 Phase 0 再繼續。要繼續？（Y / N）」

   - **不存在** → 告知用戶：「找不到 Phase 0 草稿，將逐一詢問必填資訊。」，進入 Step 1 手動模式

2. 確認 `.github/copilot-instructions.md` 是否已存在：
   - **存在** → 讀取並顯示現有內容，詢問：「此檔案已存在，要 (A) 覆蓋 / (B) 合併新內容至現有 / (C) 取消？」，等用戶回應後才繼續
   - **不存在** → 直接進行 Step 1

---

## Step 1 — 確認 6 個錨點（逐一詢問）

每次只問一個問題，顯示預設值，等待用戶確認或修改。

> **草稿存在時**：solution_name / build_cmd / framework / cs_version 已從 front-matter 預填。
> **手動模式**（草稿不存在）：從錨點 0 開始逐一詢問。

**錨點 0：解決方案名稱**（草稿存在時可跳過，front-matter 已提供）
> 草稿偵測到的解決方案名稱是：`{draft_solution_name 或 "未偵測到"}`
> 請確認，或輸入 .sln 檔名（不含副檔名，例如：`HMIStation`）：

**錨點 1：Build 指令**
> 草稿偵測到的 build 指令是：`{draft_build_cmd 或 "未偵測到"}`
> 請確認，或輸入正確指令（例如：`msbuild MySolution.sln /t:Build /p:Configuration=Release`）：

> 同時詢問：測試專案路徑（用於 Step 2 `dotnet test` 指令）：
> 嘗試從 preflight-report.json 找出名稱含 `Test` / `Tests` / `Spec` 的 .csproj；若找不到，顯示 `（未偵測到，請手動填入或略過）`

**錨點 2：C# / .NET Target**
> 草稿偵測到的 target framework 是：`{draft_framework 或 "未偵測到"}`
> 請確認，或輸入正確值（例如：`net472`）：
> *注意：net472 = C# 7.3；net6.0 = C# 10；net8.0 = C# 12*

**錨點 3：No-go Zones**
> 以下資料夾建議列為 No-go zone（AI 禁止建議重構）：
> {draft_nogo_list 或 "草稿未列出任何 no-go zone"}
>
> 請確認此清單正確，或補充 / 修改。每個資料夾請附上一句原因，例如：
> `Payments/` — 高度耦合，改動牽動 15 個模組

**錨點 4：UI 執行緒規則**
> WinForms 標準規則：禁止在非 UI 執行緒呼叫 `.Result` 或 `.Wait()`（死鎖風險）。
> 此規則適用於此 codebase 嗎？（Y / N，預設 Y）：

**錨點 5：多檔變更門檻**
> 規則：AI 改動超過 N 個檔案前，必須先列出編號計畫等人類確認。
> 預設門檻：5 個檔案。此專案合適嗎？或請輸入你的偏好值：

---

## Step 2 — 寫入 `.github/copilot-instructions.md`

使用 Step 1 確認的錨點（solution_name + 錨點 1–5）與 Anchor 1 取得的 test_project_path，寫入以下結構：

```markdown
# GitHub Copilot 全域指令 — {SOLUTION_NAME}

> 最後更新：{DATE}
> 產出來源：/copilot-baseline (Phase 1)

## 專案簡介
{請補充 2 句，描述此 codebase 的用途與主要使用族群。範例：
「這是一套工廠自動化 WinForms 桌面應用，運行於 Windows 7+ 生產線工控電腦。
主要用戶為 15 位現場操作員與 5 位維護工程師。」}

## Build 指令
```
{build_cmd}
```
執行測試：
```
dotnet test {test_project_path} --no-build
```
（`{test_project_path}` 來自 Anchor 1 確認；若無測試專案請刪除此行）

## 語言版本規則
Target framework：`{framework}`，對應 C# 版本：`{cs_version}`。

**禁止使用下列 C# 語法（若 target 為 net472）：**
- `record` 型別
- `init` setter
- `switch expression`（`=> ...`）
- `??=` null 合併賦值
- `{` 範圍索引子
- `using` 宣告（無大括號）

## No-go Zones（AI 禁止建議重構的區域）
| 資料夾 / 模組 | 原因 |
|--------------|------|
{nogo_table_rows}

## AI 行為規則
1. **多檔門檻**：改動超過 {file_threshold} 個檔案前，必須先列出編號計畫，等待人類確認後才執行。
2. **Designer 保護**：`*.Designer.cs` 不得手動修改，只能由 Visual Studio Form Designer 產生。
3. **No-go 警告**：任何觸及 No-go zones 的建議，必須在輸出開頭標示 `⚠ NO-GO ZONE DETECTED`。
4. **UI 執行緒**：禁止在非 UI 執行緒呼叫 `.Result` 或 `.Wait()`；非同步操作請使用 `Invoke` 或 `BeginInvoke`。
5. **套件核查**：建議新增 NuGet 套件前，先說明套件的 nuget.org 下載數與最後更新日期。
```

確認寫入後告知用戶：「`.github/copilot-instructions.md` 已建立。」

---

## Step 3 — 寫入 `.github/instructions/` 範圍指令

### `csharp-legacy.instructions.md`

```markdown
---
applyTo: "**/*.cs"
---

# C# 語言版本守衛

Target framework 為 `{framework}`（C# {cs_version}）。

## 禁止語法
- 不使用 `record` 型別（C# 9+）
- 不使用 `init` setter（C# 9+）
- 不使用 `switch expression`（C# 8+）
- 不使用 `??=`（C# 8+）
- 不使用 `{` 範圍索引子（C# 8+）
- 不使用無大括號 `using` 宣告（C# 8+）

## UI 執行緒規則
- 禁止在任何非 UI 執行緒的 context 中呼叫 `.Result`、`.Wait()`、`.GetAwaiter().GetResult()`
- WinForms 跨執行緒 UI 更新必須使用 `this.Invoke(...)` 或 `this.BeginInvoke(...)`

## 命名與存取
- 保持現有 namespace 結構，不自行新增頂層 namespace
- 新增 class 時遵循鄰近檔案的命名慣例
```

### `winforms-ui.instructions.md`

```markdown
---
applyTo: "**/{Forms,UI,Views,Controls,Panels}/**/*.cs"
---

# WinForms UI 層規則

## Designer 保護
- `*.Designer.cs` 是自動產生檔案，**永遠不要直接修改**
- 如需改變 UI layout，說明應在 Form Designer 中操作的步驟，而非輸出 Designer.cs 修改

## Form 生命週期
- 不要直接 `new Form().Show()`，應遵循現有的 Form 啟動模式（通常由 `Program.cs` 或 MDI parent 控制）
- 不要在 constructor 中呼叫可能拋出 exception 的業務邏輯；應在 `Load` event 中處理

## 事件處理
- Event handler 命名保持 `{Control}_{EventName}` 格式（例如 `btnSave_Click`）
- 複雜業務邏輯從 event handler 中抽取到 backing service 方法，保持 handler 精簡
```

確認寫入後告知用戶：「`.github/instructions/` 下兩個範圍指令檔已建立。」

---

## Step 4 — 寫入 `.github/prompts/` Slash Commands

### `characterize.prompt.md`

```markdown
---
mode: 'agent'
description: '為指定 class 或 method 產生 ApprovalTests 黃金快照，記錄現有行為作為重構安全網'
---

# /characterize — 建立 Characterization Tests

## 目的
為指定的 class 或 method 產生 characterization tests（特徵化測試）。
目標是**記錄現有行為**，不管行為對不對——這是重構前的安全網。

## 執行步驟

1. 找到用戶指定的 class 或 method，讀取原始碼
2. 辨識：
   - 所有 `public` 方法與 `protected virtual` 方法（可覆寫的行為點）
   - 邊界條件：null、空字串、空集合、最大值、最小值、負數
   - 已知的 special case（從 method 內部 if/switch 推斷）
3. 產生 10–50 組測試輸入，覆蓋邊界值
4. 使用 `ApprovalTests.VerifyAll` 或 `Verify` 套件輸出測試檔
5. **不使用** `Assert.AreEqual` 或具體數值斷言

## 輸出格式

```csharp
// {ClassName}ApprovalTests.cs
[TestFixture]
public class {ClassName}ApprovalTests
{
    [Test]
    public void {MethodName}_all_cases()
    {
        var scenarios = new[]
        {
            // 列出 10–50 個輸入
        };
        Approvals.VerifyAll(scenarios, s => $"{s} => {Invoke(s)}");
    }
}
```

## 完成標準

- [ ] 跑一次測試產生 `.received.txt` 檔案
- [ ] 請開發者人工檢查 `.received.txt` 內容是否符合預期
- [ ] 開發者確認後，將 `.received.txt` rename 為 `.approved.txt`
- [ ] 再跑一次測試確認全過（全綠）

## 注意事項

- `.received.txt` 不要加入 git commit（`.gitignore` 應已排除 `*.received.*`）
- 若 class 有外部相依（DB、API、filesystem），使用現有的 fake / stub，不引入新的 mock framework
```

---

### `dead-code-audit.prompt.md`

```markdown
---
mode: 'agent'
description: '分析 NDepend CSV 或 Phase 0 dead-candidates.csv，對每個 method 給出刪除信心度'
---

# /dead-code-audit — 死碼審查

## 目的
讀取 NDepend 死碼報告或 Phase 0 的 `dead-candidates.csv`，
對每個候選 method 分析是否真的可以刪除，並給出信心度。
**本指令不刪除任何程式碼。**

## 執行步驟

1. 讀取指定的 CSV 檔案（用戶提供路徑，預設為 `.analysis/tmp/dead-candidates.csv`）
2. 對每個候選 method，依序確認：
   - **Reflection 風險**：是否有字串 literal 包含此方法名稱（`Type.GetMethod`, `Activator.CreateInstance`, `Assembly.GetType`）？
   - **設定檔風險**：是否出現在 `.resx`、`.config`、`appsettings.json` 中？
   - **介面風險**：是否實作 COM 介面、`[WebMethod]`、`[OperationContract]`？
   - **事件風險**：是否為 WinForms event handler（名稱符合 `{Control}_{EventName}` 模式）？
3. 整合四項風險，給出信心度：

| 信心度 | 條件 |
|--------|------|
| HIGH | 四項風險均無，且 git log 近 2 年無修改 |
| MEDIUM | 一項風險疑似存在，但未確認 |
| LOW | 任一風險確認存在，或為 public API |

## 輸出格式

```
## 死碼審查報告 — {DATE}

| Method | Class | Namespace | Reflection | Config | Interface | Event | 信心度 | 建議 |
|--------|-------|-----------|-----------|--------|-----------|-------|--------|------|
| ...    | ...   | ...       | ✗/⚠/✓  | ...    | ...       | ...   | HIGH   | 加 [Obsolete] |
```

**僅 HIGH 信心度的 method 建議下一步行動：**
- 加上 `[Obsolete("Candidate for removal — {DATE}")]`
- 觀察一個 Release cycle，無 exception 後移至 `Quarantine/` 資料夾

## 注意事項

- 不刪除任何程式碼，只輸出審查報告
- `public` method 信心度上限為 MEDIUM（可能被外部 dll 引用）
- 財務 / 報表相關 class 標記 `⚠ FISCAL RISK`，至少等過年結才考慮刪除
```

---

### `plan-refactor.prompt.md`

```markdown
---
mode: 'agent'
description: '為指定重構目標產生逐步編號計畫，每步 <50 LOC，等人類確認後才執行'
---

# /plan-refactor — 重構計畫生成

## 目的
分析指定的重構目標，產生一份詳細的逐步執行計畫。
**本指令只輸出計畫，不執行任何修改。**
等待人類確認計畫無誤後，再由 `/refactor-step` 逐步執行。

## 執行步驟

1. 讀取目標 class / file / module 的原始碼
2. 確認 characterization tests 已存在（若無，先執行 `/characterize`）
3. 辨識重構機會（依優先順序）：
   - 過長 method（> 50 LOC）→ Extract Method
   - 重複邏輯（3 處以上）→ Extract Helper
   - 直接相依具體 class（非介面）→ 依賴反轉
   - Form 直接操作 DB / IO → 抽取 backing service
4. 將重構分解為多個獨立步驟，每步淨修改 < 50 LOC

## 輸出格式

```
## 重構計畫 — {ClassName} — {DATE}

**前提確認：**
- [ ] Characterization tests 存在於：{測試檔路徑}
- [ ] 跑一次測試確認全綠後再繼續

**步驟清單：**

1. [Extract Method] `{MethodName}` 的第 {X}–{Y} 行 → `{NewMethodName}()`
   預估異動：~{N} LOC；影響檔案：{FileName}.cs 僅此一個
   執行指令：`/refactor-step 1`

2. [Extract Service] `{ClassName}` 的 DB 相依 → `{ServiceInterface}` + `{ServiceImpl}`
   預估異動：~{N} LOC；影響檔案：{N} 個（新增 2，修改 1）
   執行指令：`/refactor-step 2`

... （依此格式列出全部步驟）

**⚠ 注意事項：**
- 步驟必須按順序執行
- 每步完成後立即跑 approval tests，若出現非預期 diff 立即停止
- 不在同一 PR 中混入刪除操作（刪除另開 PR）
```

## 注意事項

- 輸出計畫後立即停止，等待人類回覆「確認」或「修改步驟 N」
- 不主動改動 `.Designer.cs`、No-go zone 資料夾
- 若計畫超過 10 步，詢問是否拆分為多個 PR
```

---

### `refactor-step.prompt.md`

```markdown
---
mode: 'agent'
description: '執行 /plan-refactor 計畫中的單一編號步驟，完成後立即執行 approval tests'
---

# /refactor-step — 執行重構步驟

## 目的
執行 `/plan-refactor` 已確認計畫中的某一個編號步驟。
每次只執行一步，完成後跑 characterization tests，確認無非預期行為變動。

## 執行步驟

1. 確認計畫存在，讀取指定步驟 N 的說明
2. 確認 approval tests 已存在（若無，停止並告知先執行 `/characterize`）
3. 執行步驟 N 的程式碼修改（嚴格遵守步驟說明，不擴大範圍）
4. 顯示修改的 diff 摘要：
   - 異動檔案清單
   - 淨 LOC 變化（新增 / 刪除）
5. 告知用戶執行 approval tests：
   ```
   dotnet test {test_project} --filter "{TestClassName}"
   ```
6. 詢問：「Approval tests 全過嗎？（Y 繼續 / N 立即 revert）」

## Revert 指引（測試失敗時）

```
git diff --name-only HEAD    ← 確認修改範圍
git checkout -- {files}      ← revert 修改的檔案
```
Revert 後停止，回報哪個 approval test 失敗，附上 diff 片段。

## 注意事項

- 每次只執行一個步驟，不跳過，不合併多步
- 修改不得超出步驟說明的範圍（嚴禁「順便」改其他東西）
- 若步驟要修改 No-go zone 內的檔案，輸出 `⚠ NO-GO ZONE DETECTED` 並停止等待確認
- `.Designer.cs` 不得修改
- 完成後告知下一步編號，提示用戶執行 `/refactor-step {N+1}`
```

確認寫入後告知用戶：「`.github/prompts/` 下 4 個核心 slash command 已建立。」

---

## Step 5 — Husky.Net Pre-push Hook 設定指引

在 chat 輸出以下安裝指引（**不要執行這些指令**）：

```
# Husky.Net Pre-push Hook 設定步驟
# 在 target workspace 根目錄執行以下指令：

# 1. 建立 dotnet tool manifest（若尚未存在）
dotnet new tool-manifest

# 2. 安裝 Husky.Net
dotnet tool install husky --create-manifest-if-needed

# 3. 初始化 husky
dotnet husky install

# 4. 加入 pre-push hook
dotnet husky add pre-push -c "dotnet build {your.sln} && dotnet test {test.sln} --no-build"

# 完成後的 hook 位置：.husky/pre-push
# Push 前會自動執行：Build → Tests
# 若任一失敗，push 被擋下
```

**說明 Hook 守衛的功能：**

| 守衛 | 觸發時機 | 擋下條件 |
|------|---------|---------|
| Build check | 每次 push 前 | build 失敗 |
| Test gate | 每次 push 前 | approval tests 或 unit tests 失敗 |
| *.received.* | （建議加入 `.gitignore`） | 避免未核准快照進入 commit |

---

## Step 6 — 完成驗證

在 chat 輸出驗證清單：

```
# Phase 1 完成驗證

請依序確認以下項目：

□ .github/copilot-instructions.md 存在
  → 在 VS Code Copilot Chat 輸入一個測試 prompt，確認 Copilot 有讀到規則

□ .github/instructions/ 下兩個 .instructions.md 存在
  → 確認 applyTo 路徑符合你的專案資料夾結構

□ .github/prompts/ 下四個 .prompt.md 存在
  → 在 Copilot Chat 輸入 `/characterize` 確認 slash command 出現

□ Husky.Net hook 安裝完成（若已執行 Step 5 指令）
  → 執行一次 `git push` 確認 hook 觸發且 build 通過

□ 跑一次完整 build + test 確認全鏈通
  → {build_cmd}
  → dotnet test {test_project_path} --no-build
```

---

## 完成標準

### Phase 1 完成：
- [ ] `.github/copilot-instructions.md` 已建立，含 solution_name + 5 個必填錨點（Build / Framework / No-go / UI-thread / 多檔門檻）
- [ ] `.github/instructions/` 下 2 個範圍指令檔存在且含 `applyTo` front-matter
- [ ] `.github/prompts/` 下 4 個 slash command 存在且含 `mode: 'agent'` front-matter
- [ ] 用戶已收到 Husky.Net 安裝指引
- [ ] 用戶確認 Copilot Chat 可讀取到新規則
