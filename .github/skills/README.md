# Agent Skills

這個資料夾包含所有 Copilot Agent Skills，放在 `.github/skills/` 下，
VS Code GitHub Copilot 會自動讀取並在對話中按需載入。

## 使用方式

在 VS Code Copilot Chat 輸入 `/` 即可看到所有可用 skill。

---

## 自製 Skills（針對這個 C# Legacy 專案）

| Skill | 觸發時機 |
|-------|---------|
| `/csharp-archaeology` | Phase 0 考古 — 建立依賴地圖、找死碼候選 |
| `/grill-me` | 任何重大決策前 — 挑戰假設、解析 decision tree |

## 來自 mattpocock/skills（MIT License）

| Skill | 觸發時機 |
|-------|---------|
| `/grill-with-docs` | Phase 0 開始前，建立 CONTEXT.md 與 domain 共同語言 |
| `/grill-me` | Layer 1 跑完，決定深挖哪個模組前 |
| `/zoom-out` | 深入某段程式碼後，需要了解它在整個系統的位置 |
| `/handoff` | Session 結束或換人時，產出交接文件 |

---

## Phase 0 執行順序

```
Phase 0 開始
  └─ /grill-with-docs（建立 CONTEXT.md，建立共同語言）
  └─ /csharp-archaeology layer1（全局掃描）
  └─ /grill-me（決定深挖哪個模組）
  └─ /csharp-archaeology layer2（模組深挖）
  └─ /zoom-out（深入某模組需要全局視角時）
  └─ /handoff（Session 結束時）
```

---

## 原始碼

- mattpocock/skills: https://github.com/mattpocock/skills (MIT License)
- Agent Skills 標準: https://agentskills.io
