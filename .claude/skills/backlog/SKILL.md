---
name: backlog
description: 用 _backlog/ 一項目一檔機制追蹤專案的優化/修復/新需求。當使用者要記錄新需求或新問題、把收件匣整理成正式項目、處理某個 backlog 項目（先給優劣再由使用者決定）、或一批工作完成可上版時依段落封存，就用本 skill。專案層、隨 repo commit、多人/多專案/不同 agent 共用。
version: 0.2.2
updated: 2026-07-06
---

# Backlog 機制

> 白話：**backlog ＝ 本地的待辦工作母體** —— 優化／修復／新需求／安全／
> 雜務／文件…的單一優先清單（含決策史），**不是只有 bug**。它是來源
> 真相；`sync`（保留待 git）可把項目鏡像成 GitHub Issues —— Issues 是
> 匯出去處，不是這份清單本身。命名取 `backlog` 即為與該同步目標區隔。

這個 skill 同時是「機制規格」與「協作協定」。它管理的資料是**當前專案**根
目錄下的 `_backlog/`；skill 本身（這個資料夾）無狀態，只是邏輯與規格。

## 資料與位置

- **skill 本身**（`<專案>/.claude/skills/backlog/`，含 `SKILL.md`、
  `scripts/`、`assets/`）**隨 repo commit**，團隊共用同一份。
- **資料**在 `<專案>/_backlog/`：一項目一檔 `<id>-<slug>.md` + `INDEX.md`
  （自動索引）+ `intake.md`（收件匣）+ `archive/<段落>/`（已封存）。
- **設計決策（勿違反、勿「順手修掉」）**：`_backlog/` 刻意以底線開頭，
  被 `.gitignore`（`_*`）排除 → **每位開發者的本地狀態，不進 git**。理由：
  各人開發進度/追蹤項目不同，進 git server 只會無謂衝突。需團隊協作的
  項目走未來的 `sync`（推成 GitHub Issues）。**不要把 `_backlog/` 改成
  被 commit**；skill 是共用的、backlog 資料是個人的，兩者分開是刻意的。
- 「專案根」解析（script 與徒手都照此）：`--root` 參數 > 環境變數
  `BACKLOG_ROOT` > 從 cwd 往上找到含 `_backlog/` 的祖先 > cwd。
  → 一律從專案根操作；資料位置與 skill 安裝位置完全無關。

## 首次使用（bootstrap，團隊成員無需手動建任何檔）

任何子命令（`new`/`index`/`archive`）執行前都會**自動建立缺少的結構**：
建 `_backlog/`，並把本 skill `assets/INDEX.template.md`、
`assets/intake.template.md` 複製成 `_backlog/INDEX.md`、`_backlog/intake.md`
（冪等，絕不覆蓋既有檔）。亦可顯式 `node ${CLAUDE_SKILL_DIR}/scripts/backlog.mjs init`。
→ 團隊成員拿到專案後，只要叫 agent 用本 skill，結構自動生出來，
**不需要知道、也不需要手動建 `_backlog/`、`INDEX.md`、`intake.md`**。

**第一次建立時的位置確認（agent 必做）**：script 偵測到「本次才新建
`_backlog/`」會醒目印出它建立的**絕對路徑**＋補救指示（非阻塞——agent 經
非互動 shell 執行，不做阻塞式輸入）。agent **必須把該絕對路徑出示給使用者
確認是否為專案根**；若不是（例如不小心在子目錄執行），刪除該 `_backlog/`
並改用 `--root <正確專案根>` 重跑。已存在則不再提示（冪等、不吵）。

## 兩條執行路徑

**A. 快路徑（有 node）**：跑內附 script，確定性、多人多 agent 結果一致。
script 在本 skill 的 `scripts/backlog.mjs`；用 `${CLAUDE_SKILL_DIR}` 變數
引用，**不管在哪個 cwd、skill 裝在專案層/user 層/plugin 都能跑**。

```bash
node ${CLAUDE_SKILL_DIR}/scripts/backlog.mjs init                  # 顯式 bootstrap（new/index/archive 皆會自動觸發；正常不必手動）
node ${CLAUDE_SKILL_DIR}/scripts/backlog.mjs new --title "<標題>" --type <type> --priority <pri> --area <area>
node ${CLAUDE_SKILL_DIR}/scripts/backlog.mjs index                 # 重生 INDEX 自動區
node ${CLAUDE_SKILL_DIR}/scripts/backlog.mjs archive <段落名>       # dry-run，列出將封存的項目
node ${CLAUDE_SKILL_DIR}/scripts/backlog.mjs archive <段落名> --commit
```

（`${CLAUDE_SKILL_DIR}` 定位「script 檔在哪」；script 內部的
`--root`/cwd 往上找則定位「資料 `_backlog/` 在哪」，兩者各司其職。）

**B. Fallback（無 node：Windows/macOS 本機只裝 Claude Code 等）**：agent
直接用自己的讀寫工具，照下方「精確規格」徒手執行。**結果必須與 script
等價**（同樣的 id、檔名、frontmatter、索引格式、封存規則）。先試 `node -v`
判斷走哪條；走不了 A 才走 B，不要兩條都做。

## 精確規格（fallback 與 script 共同遵守，這是單一真相來源）

### frontmatter（平鋪 `key: value`，順序固定如下，值可空）

```
id          B#### 四位零補，全域唯一、永不重用
type        fix | optimize | feature | security | chore | docs
priority    high | med | low
status      triaged | in-progress | done | wont-do
area        dockerfile | compose | cc-container | image | workflow | docs …（自由字串）
created     YYYY-MM-DD
closed      完成/不採納日期；未關閉留空
milestone   封存後填段落資料夾名；否則空
issue       開 git 同步 GitHub 後回填 #N；否則空
migrated_from  來源出處（保留 provenance）；否則空
title       人類可讀標題（同時是 body 的 H1）
```

body 範本：`# <title>` → `## 問題 / 背景` → `## 優劣分析` → `## 決策`。

frontmatter 除上列固定欄位外，**使用者/agent 手加的自訂鍵會被保留**
（rewrite 時接在固定欄位後，不靜默丟失）；徒手執行也須遵守此保留行為。

### id 配號

掃 `_backlog/` **遞迴含 archive/** 所有 `B(\d+)` 檔名取最大值 +1，四位零補
（`B0007`）。已封存的檔仍算數 → id 永不重用（除非有人手動刪檔，正常流程
不刪）。

### 檔名 / 項目檔識別

`<id>-<slug>.md`。slug 來源 = 明確 `--slug`（**整理項目時 agent 應一律
提供一個有意義的英文 kebab-case 名**，如 `mise-cache-daily-volume`）；
未給才從 title 推導。淨化規則：轉小寫、非 `[a-z0-9]` 連續字元換 `-`、去
頭尾 `-`。**淨化後為空（典型：純中文標題又沒給 `--slug`）→ 工具拒絕並
要求補 `--slug`，不再產生無意義的 `item`**。封存段落名同此規則（空亦拒絕）。

**哪些檔算「項目」**：檔名符合 `^B\d+.*\.md$`（正面識別）。`INDEX.md`、
`intake.md` 或任何其他檔天然不是項目，不必靠「底線開頭」判斷。掃描時遞迴
含 `archive/`。

### bootstrap（無 node 的 fallback 也要做）

若 `_backlog/` 不存在：建之，並把本 skill 的 `assets/INDEX.template.md`、
`assets/intake.template.md` **逐字**複製成 `_backlog/INDEX.md`、
`_backlog/intake.md`（已存在則不覆蓋）。模板是單一真相，勿自行另寫格式。

### 檔案分區（誰算「關閉」）

`status ∈ {done, wont-do}` = 已關閉。其餘為活躍。已關閉但尚未封存的，留在
`_backlog/` 根目錄，直到使用者下達封存指令才整批掃進 archive。

### INDEX.md 自動索引區

`_backlog/INDEX.md` 有一對標記：

```
<!-- AUTO:BEGIN — 由 backlog skill 的 scripts/backlog.mjs index 自動重生，勿手改 -->
<!-- AUTO:END -->
```

`index` 只重寫這兩個標記之間（含標記行），標記以外的手寫內容不動。區塊
內容依序：

1. `### 活躍項目（n）` + 表格。排序：priority(high<med<low) → id。
2. `### 已關閉、待下次封存（n）` + 表格，依 id 排序。
3. `### 已封存段落（n）`：每個 archive 子資料夾一個
   `<details><summary><b>資料夾名</b>（n 項）</summary>` 摺疊區，內含表格
   依 id 排序。無則 `_（無）_`。
4. 結尾一行 `_最後更新：YYYY-MM-DD · 由 … 產生_`。

表頭固定：`| id | 類型 | 優先 | 範圍 | 標題 | 狀態 |`。類型/狀態用標籤：
type→ `🐞 修復 / ⚡ 優化 / ✨ 新需求 / 🔒 安全 / 🧹 雜務 / 📄 文件`；
status→ `⬜ 待處理 / 🔧 進行中 / ✅ 已完成 / 🚫 不採納`。

### 封存（archive）

段落資料夾名 = `<NNNN>-<YYYYMMDD>-<slug>`：NNNN = `archive/` 下既有
`^(\d+)-` 最大序號 +1（四位零補），日期為今天，slug 同上規則。動作：把
`_backlog/` **根目錄**所有已關閉項目，逐檔設 `milestone:` = 該資料夾名，
移入該資料夾，然後重生索引。**封存只搬「已關閉」**；活躍項目不動。
破壞性，故先 dry-run 列清單給使用者核對，`--commit` 才真的移動。

## 協作協定（給 agent 的行為準則）

- **收件匣**：使用者把新需求/新問題隨手寫進 `_backlog/intake.md`。你定期
  把「待整理」區的東西用 `new` 升級成正式項目，並在 `intake.md` 把它劃掉
  記上 id。本 skill 只操作 `_backlog/`；除非使用者明確要求，不動專案內
  其他檔案（使用者另有的個人筆記檔等）。
- **三道關卡（何時進 intake／何時升項目／何時不追蹤）**：
  - *進 `intake.md`*：工作中冒出、不該打斷當前任務的想法/bug/需求。粗、
    沒分析、模糊都行。預設動作、門檻最低，拿不準就先丟。intake 只是緩衝、
    不代表承諾、不需 metadata。
  - *升成正式項目（`new`，triaged）*：須**同時**滿足——具體到能下標題＋
    歸一個 `type`；確實打算評估或執行（非路過碎念）；非既有活躍/已封存
    項目的重複（重複則合併進舊項，不另開）；在本專案範圍且可行動。
    時機：使用者明講，或定期整理 intake 時。**`new` 時一律帶有意義的
    英文 `--slug`**（中文標題不會自動產生 slug）。`new` 完會自動刷新
    INDEX，不需再手動 `index`。
  - *不追蹤*：太瑣碎隨手做掉的、屬別專案的、只是提問非「工作」的 → 從
    intake 移除不開項目。**例外**：即使決定「不做」，只要決策理由有保留
    價值（免日後被重複提起，如 B0017），仍開項目並直接標 `wont-do` 寫
    進理由，不默默丟。
  - 並非什麼都得繞 intake：已具體且當下就決定要追蹤的，可略過直接 `new`。
- **處理項目**：使用者說「處理 B00NN」→ 你在該檔的 `## 優劣分析` 寫出
  **優劣比較並給推薦**，但**由使用者拍板**；定案後更新 `status`／`closed`、
  寫 `## 決策`、跑 `index`。**一次只推進一項（WIP=1）**，不要批次替使用者
  決定多項。
- **status 轉換時機**：
  - `triaged` → `in-progress`：使用者拍板**開始落地**時即改（不只是分析
    優劣階段）。落地前若還在優劣評估／等使用者拍板，留 triaged。
  - `in-progress` → `done` / `wont-do`：實作完成或最終放棄時改，並填
    `closed` 日期。
- **改了項目檔就跑 `index`（機械規則，不做判斷）**：任何對項目檔
  frontmatter 的手動編輯（status 翻轉、priority、title…）之後**立刻**跑
  `index` 重生索引。`new`/`archive` 會自動重生，但直接編輯檔案這條路徑
  沒有 hook——不要自行判斷「這次改動影不影響索引」，判斷就會漏
  （B0041/B0031 的 in-progress 曾因此在 INDEX 上失真，2026-07-06）。
- **長期 in-progress 項目的進度同步**：若項目落地需多步驟／多階段
  （典型：跨多輪對話的大改造），在該檔加「落地進度」章節並維持表格。
  **每完成一個可驗證子項就同步勾選** —— 不要批量等做完才補（中途容易
  遺漏，且使用者中途查進度也看不到實況）。每次回覆使用者前自問一次：
  「這輪有完成什麼 in-progress 項目的子項嗎？要同步嗎？」
- **scope 中途擴大併入原項**：使用者在 in-progress 過程中加新子項、且
  與本項主軸相關（不是另一件獨立工作）→ 併進該檔的「落地進度」表，
  不另開新 Bxxxx。判斷標準：「使用者下次想找這件事會聯想到哪個 Bxxxx？」
  聯想到同一個 → 併；不會 → 另開。
- **結案時的公開文件抽取**：若該專案有對應的**公開設計文件機制**
  （例如 `docs/design/<topic>.md`、ADR、`RATIONALE.md` 等，看該專案約定），
  且該項決策對未來維護者有公開價值，結案前在對應公開檔寫一段結論並附
  「（原追蹤於 Bxxxx）」provenance。**過程史不搬**，留在 backlog 即可。
  判斷標準：「半年後另一個 agent 動這塊程式碼時，看不到這個結論會不會
  踩雷？」會 → 抽；不會 → 不抽。
- **修改既有公開設計檔的紅線**：若新項目是要動既有公開 design 檔上的
  結論（不是「跟以前 Bxxxx 重複」，而是「想推翻 design 檔上的紅線」），
  照常開新 Bxxxx 討論。決議後更新對應 design 檔段落，附
  「（原追蹤於 X；YYYY-MM-DD 由 <你的 Bxxxx> 修改）」provenance。
  **design 檔可累積多個 provenance 標記**，正常。
- **你自己做的決定**（工具、結構等）要明講理由並標示可否決，不默默決定。
- **封存時機由使用者觸發**：使用者修完一批、覺得可合併上版時通知你封存。
  你先 dry-run 列出將被掃走的已關閉項目給使用者核對，過了才 `--commit`。
- **大型/不可逆改動分階段設檢查點**：先做少量範本停下確認格式，再批次執行。
- **去重**：新需求與既有項目可能是同一件事（如「volume 每天增加」≡ 既有
  某項）→ 合併進既有項目，不重複開。
- 開 git 後再實作 `sync`：逐檔 `gh issue create`（label=type/priority）→
  回填 `issue: #N`；封存段落對應 GitHub milestone；`id↔issue` 當冪等橋接。

## 多人 / 多專案注意

- skill 隨各 repo commit（專案層），更新需逐 repo 同步這個資料夾。
- id 與段落序號是「**該專案、該開發者本機** `_backlog/` 內」全域唯一。
  **不跨人、也不跨專案** —— `_backlog/` 是本地狀態（見「資料與位置」），
  同一 repo 不同開發者各自從 B0001 開始累積、互不對齊，這是刻意設計。
  共享給他人的決策結論走「結案抽取到公開 design 檔」那條路徑（見
  協作協定）。
- 不同 code agent 都讀本檔 → 行為一致；務必遵守「精確規格」逐字，勿自創
  欄位或格式。

## 已知假設與限制（刻意取捨，非 bug）

- **INDEX.md 手寫頭只在「檔案存在」時被保護**：`index` 只重寫 `<!-- AUTO -->`
  區、保留其上手寫內容。但若整份 `INDEX.md` 被刪，bootstrap 會用 assets
  模板重建 → 自訂手寫頭遺失。要保留自訂手寫頭就**別刪 `INDEX.md`**。
- **id 配號非並發安全**：以「掃描現有最大 +1」配號，假設**單一使用者本地
  操作**。勿多 agent 同時對同一專案 `new`（理論上可能撞號）。
- **assets 模板與本檔可能各自漂移**：`SKILL.md` 是規格與文字的**真相
  來源**；`assets/*.template.md` 只是 bootstrap 種子。兩者若不一致，以
  `SKILL.md` 為準（種子過時不影響機制正確性）。

## 版本與同步

本 skill 目前以「逐 repo 複製檔案」方式跨專案同步。為避免「誰是最新」
漂移：

- frontmatter 維持 `version` + `updated` 兩欄
  - `version`：語意化版號（bug 修補 patch、新增小功能 minor、breaking 改 major）
  - `updated`：YYYY-MM-DD，最近一次內容變動日期
- **修改本檔或 `scripts/`、`assets/` 前**先 bump `version` 並更新
  `updated`。跨 repo 同步比對時版號高者為準。

> 中長期規劃：抽出獨立 skill 維護 repo（git submodule 引入各專案），
> 屆時版號比對改為「對齊該 repo 某個 release」。
