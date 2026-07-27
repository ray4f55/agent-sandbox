---
name: project-docs
description: 用 templates 為新專案產生 README/CLAUDE.md/docs/ 結構骨架，或對既有專案做結構 audit（檢查必要檔是否存在、必要 sections 是否齊、擺放是否雜亂）並給調整建議。當使用者要 bootstrap 新專案、檢查既有專案結構、或想知道文件組織該怎麼擺時用本 skill。專案層、隨 repo commit、多人/多專案/不同 agent 共用。
version: 0.1.0
updated: 2026-05-21
---

# Project-docs 機制（專案文件骨架）

> 白話：**project-docs 的目的 ＝ 讓專案有「足夠的上下文文件」，使後續
> 開發者（人類或 agent）一進來就能理解這專案在幹嘛、怎麼用、為什麼這樣
> 設計**。結構（README / CLAUDE.md / docs/）只是手段；真正的產出是
> 「內容填滿、不留 TODO」的完整文件。
>
> skill 做兩件事：(1) `scaffold` 出結構骨架；(2) 對既有專案 audit 缺什麼。
> **但骨架不是終點** —— scaffold 後 agent 應主動讀專案現有的程式碼、
> 文件、git 歷史去理解，再把 TODO 補成有實質內容的文件（見「協作協定」）。
>
> **不**處理 CONTRIBUTING / LICENSE 等 OSS 發佈相關檔（那是另一條軸）。

這個 skill 同時是「結構規格」與「協作協定」，是多 agent 行為的**單一
真相來源**。它生成／檢查當前 cwd（或 `--root` 指定）的專案結構；skill
本身（這個資料夾）無狀態，只是邏輯與規格＋模板。

## 資料與位置

- **skill 本身**（`<專案>/.claude/skills/project-docs/`，含 `SKILL.md`、
  `scripts/`、`assets/templates/`）**隨 repo commit**，團隊共用同一份。
- **沒有運行時資料**：本 skill 不在專案內留 `_project-docs/` 之類本機
  狀態（不同於 backlog/notes）。產生的檔直接寫進專案根；audit 結果是
  一次性 stdout 報告，不持久化。
- **目標專案根**解析：`--root` 參數 > cwd。本 skill 不上溯找祖先（沒
  「資料夾標記」可找）—— 命令直接作用於指定／當前位置。

## 目標結構（spec）

scaffold 與 audit 對齊的「對的結構」：

```
<project>/
├── README.md               # 人類入口，含 intro / 解決什麼 / 主要設計 / 結構 / Quick start
├── CLAUDE.md               # AI 紅線索引，含 文件分工 / 紀律 / 主題紅線 + @import
├── .gitignore              # 含 _* 與 .claude/* 白名單慣例
└── docs/
    ├── design/             # Explanation（為什麼這樣設）
    ├── examples/           # 可複製的設定範例
    ├── guides/             # How-to 操作型
    └── reference/          # 查表（env vars、檔案結構…）
```

**不**在 spec 內：CONTRIBUTING / LICENSE / CHANGELOG / CODE_OF_CONDUCT
（屬「OSS 發佈」軸，由使用者手動補或另開 skill）。

## 兩條執行路徑

**A. 快路徑（有 node）**：跑內附 script，確定性、多 agent 結果一致。

```bash
node ${CLAUDE_SKILL_DIR}/scripts/project-docs.mjs scaffold
node ${CLAUDE_SKILL_DIR}/scripts/project-docs.mjs scaffold --name "<專案名>"
node ${CLAUDE_SKILL_DIR}/scripts/project-docs.mjs scaffold --root /path/to/project
node ${CLAUDE_SKILL_DIR}/scripts/project-docs.mjs scaffold --force   # 整檔覆寫（破壞性）
node ${CLAUDE_SKILL_DIR}/scripts/project-docs.mjs help
```

`--name` 預設取 cwd basename；用於替換模板內 `{{project_name}}`。

**B. Fallback（無 node）**：agent 直接讀 `assets/templates/` 內各範本檔，
照下方「精確規格」逐字產出。結果須與 script 等價。先試 `node -v` 判斷，
能跑 A 就不要走 B。

## 精確規格（fallback 與 script 共同遵守）

### Scaffold（auto-detect）行為

對 `--root`（預設 cwd）下每個目標執行：

| 目標類型 | 不存在時 | 已存在時（預設） | 已存在時（`--force`） |
|---|---|---|---|
| 檔案（README / CLAUDE.md / .gitignore） | 從 template 生成，`{{project_name}}` 替換成 `--name` 或 cwd basename | **不覆寫**，跑 audit | 覆寫，跑 audit |
| 目錄（docs/design /examples /guides /reference） | 建夾 + 放 `.gitkeep` | 不動，跑 audit | 不動（無意義覆寫） |

**輸出**：一份 stdout 報告，含這些類別：
- ✨ **生成**：本次寫入的檔／夾
- 📦 **已存在，未動**：跳過建立的檔／夾
- 📝 **待填 TODO**：受管檔內剩餘的 `TODO` 標記數（衡量「內容填了沒」）
- ⚠️ **audit 建議**：既有檔缺哪些必要 sections
- ✅ **完整**：audit 無建議 **且** 待填 TODO 歸零時才印

### Audit 規則（初版）

對既有檔逐項檢查；任一未過就列建議。**只報告、不自動改**。

**README.md**：
- 有 H1 標題（`^#\s+`）
- H1 後到第一個 H2 之間有非空 paragraph（intro）
- 有「## 專案結構」或「## Project Structure」或「## 目錄結構」段
- 有「## Quick start」/ Quickstart / 快速開始 / 安裝 段

**CLAUDE.md**：
- 有「## 文件分工」段
- 有「## 寫程式碼時的紀律」或「## 紀律」/「## Discipline」段
- 有「## 主題紅線」/「## 紅線」段 或 至少一條行首 `@docs/design/...` import

**.gitignore**：
- 有獨立行 `_*`（個人本地檔慣例）
- 有 `.claude/*` + `!.claude/skills/` 白名單

**docs/design/**：
- 至少有一個 `.md` 檔（非 `.gitkeep` / `.` 開頭）

### 完整度檢查（TODO 偵測）

audit 規則檢查「**結構在不在**」；TODO 偵測檢查「**內容填了沒**」——
兩者合起來才涵蓋「文件完整」這個目的。

- 對每個受管檔（README.md / CLAUDE.md / .gitignore，含本次新生成的）
  數其中 `TODO` 字串出現次數
- 任一檔 count > 0 → 列進報告「📝 待填 TODO」並附引導
- 報告的「✅ 完整」結論**只在 audit 無建議 ＋ 待填 TODO 歸零時**才印

理由：只查「`## 專案結構` 標題在不在」會漏掉「標題在、底下整段是 TODO」
的空殼。剛 scaffold 出的專案結構齊全卻零內容，對「讓後續開發者有上下
文」這個目的等於沒做 —— TODO 偵測就是補這個洞。歸零才代表真的完整。

### 模板內容（assets/templates/）

僅列檔名與寫作原則；內容以 `assets/templates/` 內檔為單一真相來源。
**templates/ 內每個檔都會被 scaffold 部署**，無「躺著沒人用」的範本。

- `README.md.template`：**結構預填、內容 TODO**。H1 用 `{{project_name}}`
  替換；其餘段全是 TODO 註解 + 空 bullets
- `CLAUDE.md.template`：**通用文件分工與紀律預填、主題紅線 TODO**。紀
  律內容是與 docs/ 結構綁定的通用版本，不專案特定
- `.gitignore.template`：**全部預填**（macOS / 編輯器 / `_*` / `.claude/*`
  白名單）；內容跨專案通用

`docs/{design,examples,guides,reference}/` 由 script 程式化建立（`mkdir`
+ 放空 `.gitkeep`），**不走 template 檔** —— 空目錄不需要範本。

> ⚠️ **HTML 註解內不寫「行首 @」**：避免被 Claude Code 當 import 觸發。
> 想示範語法時用 backtick 包起來、或用敘述性說明。

### docs/design/ 檔的骨架

design 檔「用 N 次、每次主題不同、由使用者命名」，生命週期與 README /
CLAUDE.md（一次性 scaffold）不同 → **刻意不做對應的 `.template` 檔**，
scaffold 只建空的 `docs/design/` 夾。寫一份新 design 檔時照此骨架
（audit 偵測到 `docs/design/` 沒有 `.md` 檔時也會指回這段）：

```markdown
# <主題> — 設計筆記

對應檔：`<path/to/source>`。

本檔說明該檔關鍵設定為什麼這樣選。修改前先讀對應段落。

## <主題段>

- 當時考慮的選項
- 為什麼選了現在這個
- 紅線：不要做什麼
```

檔名規則：文件化某個原始檔 → 與該檔同名去副檔名（`docker-compose.yaml`
→ `docker-compose.md`）；跨檔的概念主題 → 用概念名（如 `mise.md`）。

## 協作協定（給 agent 的行為準則）

- **觸發**：使用者明說「建立新專案文件骨架」、「檢查專案結構」、「補
  本專案缺的文件」、「audit docs」等 → 跑 scaffold。
- **不要直接覆寫既有檔**：除非使用者明說 `--force` 或語意等價。預設只
  生成缺檔 + audit 既有檔給報告。
- **報告後等使用者決定下一步**：audit 建議是「建議」，**由使用者拍板
  哪些要採納**；不自己順手改既有檔。
- **如報告全綠**：明確告訴使用者「結構齊備、無建議」，不要為了顯得做
  了事而亂提建議。
- **scaffold 後要主動補全，不能只丟骨架**：scaffold 產出的檔含
  `<!-- TODO -->` 標記、報告會列「📝 待填 TODO」。agent **不應停在這裡**，
  應主動：
  1. 讀專案現有素材 —— 原始碼、既有 README/docs、`git log`、套件設定
     檔（package.json / Cargo.toml / pyproject.toml …）、Dockerfile 等
  2. 從中理解「這專案是什麼、解決什麼、怎麼跑、有哪些設計取捨」
  3. 把理解寫進對應 TODO（README 的 intro／結構、CLAUDE.md 的紅線…）
  4. 真的需要使用者意圖才能定的（roadmap、設計偏好等）才留 TODO，
     並明確向使用者提問
  目標：讓報告的「📝 待填 TODO」歸零 —— 那才代表文件完整、後續開發者
  真的有上下文。完全空的新專案（無程式碼可讀）則 scaffold 後直接引導
  使用者口述、由 agent 整理填入。
- **跟 backlog/notes 的協作**：若該專案有用 backlog skill，scaffold 不
  自動建 `_backlog/`（那是 backlog skill 的 bootstrap 職責）；audit 不
  檢查 `_backlog/` 是否存在（不屬本 skill 範圍）。

## 多人 / 多專案注意

- skill 隨各 repo commit（專案層），更新需逐 repo 同步這個資料夾（中
  長期：抽出獨立 skill 維護 repo）。
- 模板版本跟著 skill 版本走；專案 scaffold 完不會繼承 skill 之後的更新
  （除非使用者再跑 audit 看新版規則）。
- 不同 code agent 都讀本檔 → 行為一致；務必遵守「精確規格」逐字。

## 已知假設與限制（刻意取捨，非 bug）

- **audit 是表面結構檢查、不深究內容品質**：例如能偵測「有沒有 H1」，
  不能偵測「intro 寫得好不好」。後者屬人類判斷，不是規則化能解的。
- **模板與本檔可能漂移**：`SKILL.md` 是規格與文字的**真相來源**；
  `assets/templates/*` 只是 bootstrap 種子。兩者若不一致，以 SKILL.md
  描述為準（種子過時不影響機制正確性）。
- **audit 只報告、不自動改**：刻意。修補是否安全因 case 而異（補 H1
  安全、寫 intro 不能自動），交由使用者／agent 看報告後手動處理。
- **模板目前只有中文**：scaffold 英文專案時產出的骨架是中文，自行翻譯。

## 版本與同步

本 skill 目前以「逐 repo 複製檔案」方式跨專案同步。為避免「誰是最新」
漂移：

- frontmatter 維持 `version` + `updated` 兩欄
  - `version`：語意化版號（bug 修補 patch、新增小功能 minor、breaking 改 major）
  - `updated`：YYYY-MM-DD，最近一次內容變動日期
- **修改本檔、`scripts/`、`assets/templates/` 任一前**先 bump `version`
  並更新 `updated`。跨 repo 同步比對時版號高者為準。

> 中長期規劃：抽出獨立 skill 維護 repo（git submodule 引入各專案），
> 屆時版號比對改為「對齊該 repo 某個 release」。
