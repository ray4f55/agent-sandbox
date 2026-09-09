<div align="center">

<img src="website/favicon.svg" width="88" alt="agent-sandbox logo">

# agent-sandbox

**給 AI 代理的拋棄式容器沙盒 — 放心讓 agent 全自動火力全開**

*A disposable container sandbox for AI coding agents (Claude Code, Codex) —
let your agent run on full auto; the blast radius ends at the container.*

[![build-images](https://github.com/ray4f55/agent-sandbox/actions/workflows/build-images.yml/badge.svg)](https://github.com/ray4f55/agent-sandbox/actions/workflows/build-images.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-8b949e.svg)](LICENSE)
[![GHCR](https://img.shields.io/badge/GHCR-prebuilt%20images-c9503a)](https://github.com/ray4f55?tab=packages)

<img src="website/assets/demo-daily.gif" width="820" alt="agent-sandbox demo：一個指令進沙盒">

[Quick start](#quick-start) ·
[指令行為對照](#指令行為對照) ·
[設計文件](docs/design/) ·
[官網](https://ray4f55.github.io/agent-sandbox/)

</div>

---

給 AI 代理（Claude Code、Codex…）用的可拋棄式容器沙盒。
讓你能放心開啟 agent 的全自動模式（如 Claude Code 的
`--dangerously-skip-permissions`），最壞情況也只是容器內亂砍 ——
host 檔案、登入憑證、其他專案都不會受影響。

## 解決什麼問題

- AI agent 想自動跑 build／安裝套件／改檔案，但你不想授權全機讀寫
- 多專案同時開發時，希望每個專案在獨立沙盒裡跑各自的 agent
- 想凍結某個能跑的 agent 環境版本，未來能隨時回到該版

## 主要設計

- **拋棄式容器**：每次 `agent-sandbox` 啟一個 `--rm` 容器，退出消失（你的程式碼留 host）
- **資源／權限限制**：**預設** 2GB RAM、2 核 CPU、512 task 上限（可逐專案明確 opt-in 放寬，放寬時啟動會印出來）；剝奪所有 Linux 核心特權、防 SUID 提權
- **跨 session 共用語言快取**：mise-cache volume 一份持久化，多專案共用同一份 Python/Go/...
- **里程碑凍結**：具名 tag image 永不被自動覆寫，能隨時跑回某歷史版本
- **自動清理**：退出後移除孤兒 network、保留 volume 資料

## 專案結構

```
agent-sandbox/
├── agent-sandbox.sh                  # ★ 核心：啟動函式 + tab 補全（source 這個檔）
├── agent-sandbox-claude-wrapper.sh   # 可選門面：claude --sandbox（opt-in）
├── agent-sandbox-codex-wrapper.sh    # 可選門面：codex --sandbox（opt-in）
├── init.sh                           # 一鍵設定／診斷／移除（--check/--apply/--uninstall）
├── docker-compose.yaml               # 容器服務／volume／資源限制
├── Dockerfile.base.claude            # base image：Claude Code（預設）
├── Dockerfile.base.codex             # base image：OpenAI Codex
├── Dockerfile.addon.openspec         # add-on 層：OpenSpec（可疊在任一 base 上）
├── Dockerfile.addon.ops              # add-on 層：維運工具箱 gcloud＋Ansible（可疊在任一 base 上）
├── Dockerfile.addon.office           # add-on 層：Office 文件處理／OCR（可疊在任一 base 上）
├── README.md                         # 你正在讀的這份（怎麼用）
├── CLAUDE.md                         # AI 代理讀的設計紅線索引（@import docs/design）
├── CONTRIBUTING.md · CODE_OF_CONDUCT.md · LICENSE（MIT）
├── docs/
│   ├── design/                       # 為什麼這樣設計（修改前必讀的取捨）
│   ├── examples/                     # 可複製範例（.agent-sandbox、mise.toml）
│   ├── guides/                       # 操作 how-to（cleanup、mise-cache 管理…）
│   └── reference/                    # 查表（檔案結構、env vars…）
├── website/                          # GitHub Pages 官網（landing + demo 動圖）
├── .github/workflows/                # CI：GHCR 多架構發佈、Pages 部署
└── home/                             # 身分資料鏡射目錄（home/<identity>/，
                                      # 預設 home/default/）：各 agent 登入
                                      # 憑證（.claude/.codex）與 mise 設定；
                                      # gitignored 不進版控
```

詳細結構速查見 [`docs/reference/file-layout.md`](docs/reference/file-layout.md)。

## Quick start

> 適用 macOS / Linux + Podman（或 Docker，本檔以 podman 為主）。Windows 走
> WSL2，見 [`docs/guides/windows-setup.md`](docs/guides/windows-setup.md)。

### 一鍵設定（建議）

clone 後在 repo 內跑 `init.sh`：先 `--check` 看缺什麼、再 `--apply` 套用。

```bash
./init.sh            # 純診斷：檢查 podman / compose / 鏡射目錄 / rc，不改任何東西
./init.sh --apply    # 逐項徵詢後：建鏡射目錄、在 ~/.zshrc 寫入 source 一行
./init.sh --uninstall # 移除 ~/.zshrc 內的 agent-sandbox 區塊（先備份）
```

> 若回 `permission denied`，改用 `bash ./init.sh ...`（或先 `chmod +x init.sh`）。

`init.sh` 會：檢查相依（缺的印出該平台安裝指令，**不替你自動裝**）、建好下
方「主機端防錯設定」要的鏡射目錄、把一行 `source .../agent-sandbox.sh` 寫進
`~/.zshrc`（idempotent，重跑不重複；寫入前先備份 + 預覽 + 徵詢）。細節見
[`docs/guides/init-script.md`](docs/guides/init-script.md)。

> 偏好手動、或想了解每一步在做什麼？下面「主機端防錯設定」與「設定終端機
> 捷徑」是等價的手動步驟。

### 主機端防錯設定（極重要）

在第一次啟動容器前，請在 agent-sandbox repo 內預先建立鏡射容器身分資料的
目錄：`home/default/`（預設身分；多身分見下方「多身分」）。

> 容器內所有持久化設定都走「鏡射 + bind mount」：repo 內的 `home/default/*`
> ↔ 容器內 `$AGENT_HOME`（`/home/agent-sandbox/*`）一一對應。預先建立空
> 目錄/檔案的原因：podman 在掛載時找不到 host 來源會用 root 自動建立，
> 導致後續權限錯誤。
>
> `home/` 目錄已在 `.gitignore` 內，憑證不會被誤 commit。

```bash
# 在 agent-sandbox repo 內執行一次
mkdir -p home/default/.claude home/default/.config/mise
touch home/default/.claude.json
```

> `home/default/.gitconfig`（容器內 git 身分）**不必手動建** —— 首次 `agent-sandbox`
> 會自動從你 host 的 global git 身分（`git config --global user.name/email`）生成；
> host 沒設則會提示。用途：容器是拋棄式、沒有你的 global gitconfig，對「只靠
> global 身分」的 repo commit 會無身分。**想用別的身分見下方「容器內 git 身分」。**

> `home/default/.config/mise/` 是給 mise 全域設定用的（例如 `config.toml`），bind mount 後在 host 上可直接編輯。trust 紀錄則**不**走這個路徑——它在 `.local/state/mise/`，刻意留容器內不持久化（安全考量）。

> 若你之前用過 `~/.claude` 版本想保留登入狀態，可一次性把舊憑證搬進來：
> ```bash
> cp -r ~/.claude home/default/.claude
> cp ~/.claude.json home/default/.claude.json
> ```
> 舊的 `~/.claude` 留著當保險即可，不必刪。

### 設定終端機捷徑 (function)
為了達到「隨選即用 (On-demand)」的流暢體驗，只要在 `~/.zshrc` 加一行把本 repo 的 `agent-sandbox.sh` source 進來即可。

```zsh
# 在 ~/.zshrc 加這一行：source 本 repo 的 agent-sandbox.sh。
# 函式會自動定位自身所在目錄來找 docker-compose.yaml / Dockerfile，
# 無需設定任何絕對路徑變數；日後搬動 repo 只要更新這行的路徑即可。
source /path/to/agent-sandbox/agent-sandbox.sh
```

> `agent-sandbox.sh`（repo 根目錄）裝著啟動函式與 tab 補全，完整用法寫在
> 檔頭註解。常用形態：
>
> - `agent-sandbox --upgrade` —— **建立/升級 image**（首次使用先跑這個；
>   之後想更新 Claude 等工具也是它，會自動留版號快照；只 build 不進容器）
> - `agent-sandbox` —— 日常啟動（跑 latest；純啟動、秒起，永不 build）
> - `agent-sandbox v1.0.0` —— 跑某個版號快照（rollback 用）
> - `agent-sandbox --addon openspec` —— 疊加 add-on（見下方「進階：Add-on 變體」）
> - `agent-sandbox --identity ops` —— 切換身分資料來源（見下方「多身分」）
> - `agent-sandbox --new-identity ops` —— 建立新身分骨架（見下方「多身分」）
>
> 它是 **zsh** 函式（用到 zsh 限定語法）；從 bash source 會提示需要 zsh。
> 設計取捨見 [`docs/design/agent-sandbox.md`](docs/design/agent-sandbox.md)。

#### （可選）`claude --sandbox` 門面

想把「啟動沙盒」包裝成 `claude --sandbox` 當入口，可**額外** source 一個檔
（**opt-in**，預設不啟用 —— 它會以函式 shadow `claude` 指令名，所以交給你自己決定）：

```zsh
# 在上面那行 agent-sandbox.sh 「之後」再加（依賴 agent-sandbox 函式）：
source /path/to/agent-sandbox/agent-sandbox-claude-wrapper.sh
```

> 或讓 `./init.sh --apply` 幫你加 —— 它會**詢問**要不要啟用這個門面（opt-in），
> 答 yes 才在那段 rc 區塊多寫這行。

之後：
- `claude --sandbox [tag] [--base …] [-m …]` → 進沙盒並**自動啟動 claude**
  （= `agent-sandbox --launch …`；claude 退出後留在容器 bash）；`--sandbox` 後的
  參數原樣交給 `agent-sandbox`，含 tab 補全
- `claude <其他任何參數>` → 原樣轉發給**真正的** claude（本機有裝就照常用；沒裝則
  回報找不到 claude）

> 不想用門面、或想自己決定何時起 claude，直接用 `agent-sandbox`（進 bash、手動下
> `claude`）或 `agent-sandbox --launch`（進去自動起 claude）即可，效果相同。

> 指令優先序：shell 的 **function 蓋過 PATH binary**，所以 source 後 `claude` 走本
> 函式；非 `--sandbox` 時用 `command claude` 繞回真 claude。`claude --sandbox` 有
> tab 補全（委派 `agent-sandbox` 的補全）。**注意**：若本機日後裝了 claude 又仍
> source 此檔，本函式/補全會蓋過真 claude（屆時移除此檔即可）。

> 適合「本機沒裝 claude、想用 `claude --sandbox` 當沙盒入口」或「有裝 claude、想要
> `--sandbox` 一個入口同時保留原 claude」。設計取捨見
> [`docs/design/agent-sandbox.md`](docs/design/agent-sandbox.md)「`claude --sandbox` 門面」段。

**codex 版門面**同模式（另一個 opt-in 檔）：

```zsh
source /path/to/agent-sandbox/agent-sandbox-codex-wrapper.sh
```

之後 `codex --sandbox [tag] [--addon …]` = `agent-sandbox --base codex --launch …`。
⚠️ 與 claude 版不同的注意事項：**真 codex 自己有 `-s, --sandbox` 旗標**（它的執行
隔離政策）——本門面只攔「`--sandbox` 放第一個參數」這一種形態，`codex -s <mode>`、
旗標放後面、`codex sandbox` 子指令都照常轉發；要用真 codex 的長旗標寫法用
`command codex --sandbox …`。詳見 wrapper 檔頭註解。

---


### 開發使用流程：

1. 在終端機用 cd 進入想開發的任何一個專案目錄（或想掛進容器給 agent 使用的目錄）
2. 啟動沙盒：輸入 agent-sandbox
    podman 會啟動一個隔離容器，並將執行agent-sandbox指令當下的目錄投影到容器內的 /workspace，且內部身分會自動切換為本機使用者的 UID

    > **run 與 build 是分開的**：`agent-sandbox` 是**純啟動**——image 在就
    > 秒起、不在就報錯，永遠不會自己 build。第一次使用（或想更新工具）請跑
    > `agent-sandbox --upgrade`：它整鏈重建 image、把 Claude/mise/apt 全部
    > 更新到當下最新，並自動留一個版號快照（如 `v1.3.0`）供 rollback；
    > **只 build 不進容器**，升完再照常 `agent-sandbox` 進去。
    > 詳見下方「指令行為對照」。查容器內 Claude 版本：進去後
    > `cat /etc/claude-cli-version`（build 當下凍結的版本＋日期）或
    > `claude --version`。
3. 動態準備語言環境
    image 本體只有 Node + Claude + mise，**不預裝任何語言**。語言由你的「專案 mise.toml」決定，cd 到 /workspace (專案目錄) 後：
    - 若專案已有 `mise.toml`：先 `mise trust` 確認信任這個 config (mise 安全機制，**每個 session 都要做一次**，避免來路不明的 mise.toml 自動跑 hooks)，再 `mise install`
    - 若沒有：例如 `mise use python@3.11` 自動寫入 `mise.toml` 並安裝 (`mise use` 自建的檔不需 trust)
    - 安裝結果都存到 host 上的 `mise-cache` named volume，**跨 session 與不同專案共用**
      (例如 A 專案裝過 python@3.11，B 專案也用同版直接秒起)

    > **為何 trust 不持久化**（每 session 都得重做）：路徑空間撞名時，舊 trust 會把惡意 mise.toml 自動視為已信任，可能洩漏 `~/.claude` token；詳見 [`docs/design/mise.md`](docs/design/mise.md)。
4. 啟動 AI 代理：
    第一次使用時輸入 claude，它會給連結，在瀏覽器登入（只需登入一次，因為身份驗證檔寫在掛載進去的路徑）
    之後可以大膽地輸入 claude --dangerously-skip-permissions，放手讓 Agent 幫您寫 code，就算它想亂砍系統檔案或無限迴圈，也會被沙盒與記憶體上限（預設 2GB，可逐專案調整）攔住

    > 想省一步：`agent-sandbox --launch` 會在進容器當下直接起 claude（claude 退出後
    > 留在 bash 可續作業）；步驟 2＋4 併一行。需要先裝語言環境（步驟 3）的場景就別用
    > `--launch`、照原本兩步走。
5. 結束工作：輸入 exit
   容器會立刻煙消雲散 (--rm)，但 Agent 寫好的程式碼，會留在 Mac 的專案資料夾中

---

### 指令行為對照

**run 與 build 徹底分家**：不帶 `--upgrade` 就是純啟動（永不 build、零互動）；
`--upgrade` 是唯一的 build 入口。

> **重要觀念：版號 tag ≠ Claude 版本**。版號 tag（如 `v1.3.0`）是「某次
> 升級當下整顆 image 的快照」，給 rollback 用；容器內 Claude 是哪一版由
> **build 當下**決定（`cat /etc/claude-cli-version` 可查）。Claude 出新版
> 不會讓 latest 自己變新——想升級就跑 `agent-sandbox --upgrade`。

**A. 純啟動模式（日常）**

| 指令 | 效果 | image 不存在時 |
|---|---|---|
| `agent-sandbox` | 跑 `agent-sandbox-claude:latest` | ❌ 報錯，提示先 `--upgrade` |
| `agent-sandbox v1.2.0` | 跑該版號快照（rollback） | ❌ 報錯（打錯字不會默默建新 image） |
| `agent-sandbox --addon openspec` | 跑 `agent-sandbox-claude-openspec:latest` | ❌ 報錯 |
| `agent-sandbox v1.2.0 --addon openspec` | 跑 `agent-sandbox-claude-openspec:v1.2.0` | ❌ 報錯 |

> 鏡像名公式：`agent-sandbox-<base>[-<addon1>[-<addon2>...]]:<tag>`。
> Container 從**最後一層**啟動，前面層是中間產物（也可獨立用）。

**B. 升級模式（首次使用 / 想更新工具時）**

| 指令 | 版號 | 效果 |
|---|---|---|
| `agent-sandbox --upgrade` | 自動：既有 `vX.Y.Z` 最大者 **minor +1**（全無 → `v1.0.0`） | 整鏈 `--no-cache` 重建（Claude/mise/apt 全部更新到當下）→ 打 `:latest` + 版號 → **收工，不進容器** |
| `agent-sandbox --upgrade v2.0.0` | 你指定（重大改版手動跳 major） | 同上；版號已存在 → build 前報錯 |
| `agent-sandbox --upgrade --addon openspec` | 自動（掃 base + addon 全部 tag 取最大） | base 與 addon 兩層都重建、都打雙 tag |

> `--upgrade` 是**純維護操作**：build + 留快照就結束，不進容器——升級摘要
> 不會被容器 session 洗掉，可先 `podman images`（或 tab 補全）確認版號，
> 確認沒問題再照常 `agent-sandbox` 進容器。只接受 `--base`/`--addon`（+
> tag 當版號）；搭配 `-m`/`--no-config-mounts`/`--identity`/`--launch`
> 會直接報錯（這些旗標對純 build 操作沒有意義，不會默默忽略）。

要點：

- **每次升級自動留版號快照**：升壞了 `agent-sandbox v<前一版>` 就回去了；
  快照不可被覆蓋（指定既有版號會報錯）
- **版號語意約定**：minor = `--upgrade` 自動（例行工具刷新）；major = 你
  手動指定（結構性大改）；patch 保留手動微修
- **升級要付整鏈重建的時間**（分鐘級，含重新下載 Claude）——升級是低頻、
  顯式的決定，日常啟動永遠秒起
- **清舊快照**：`podman rmi agent-sandbox-claude:v1.0.0`（每顆快照都佔磁碟）
- **升級 node 底層**：`--upgrade` 會先 `podman pull` base Dockerfile 的
  `FROM` image（離線時警告後改用本地既有版本繼續）；若 pull 回來的 image
  上游已超過 180 天沒更新，會提示「可能已 EOL、該換 base 版本了」（Node
  LTS 的 EOL 日程公開可查，如 node:22 到 2027-04）

**C. 常見場景**

第一次使用（或 image 被清掉後）：

```
$ agent-sandbox
❌ image 不存在：agent-sandbox-claude:latest
   請先跑 agent-sandbox --upgrade 建立/更新 image（或檢查版號拼字，tab 可補既有 tag）。

$ agent-sandbox --upgrade
🔄 升級重建（--no-cache）：agent-sandbox-claude
   （鏈由目前目錄解析：CLI > .agent-sandbox [image] 段 > 預設 claude；換目錄執行可能建到不同鏈）
   完成後打 tag：:latest + :v1.0.0（自動配號，首版）
⬇️  刷新 base image：node:22-slim
🔧 build agent-sandbox-claude:latest …
📌 已留版號快照：v1.0.0（rollback：agent-sandbox v1.0.0）
✅ 升級完成（不進容器）。進容器：agent-sandbox（latest）或 agent-sandbox v1.0.0

$ agent-sandbox     # 確認沒問題後照常進容器
```

Claude 出新版想升級：

```
$ agent-sandbox --upgrade
🔄 升級重建（--no-cache）：agent-sandbox-claude
   （鏈由目前目錄解析：CLI > .agent-sandbox [image] 段 > 預設 claude；換目錄執行可能建到不同鏈）
   完成後打 tag：:latest + :v1.1.0（自動配號，前一版 v1.0.0）
…
```

升完發現有問題，回滾到升級前：

```
$ agent-sandbox v1.0.0
```

**改 Dockerfile 的快速迭代**（開發本專案者）：改動後不必每次付 `--upgrade`
的 no-cache 成本，手動帶 cache build 即可讓下次 `agent-sandbox` 生效：

```
podman build -f Dockerfile.base.claude -t agent-sandbox-claude:latest .
```

改到滿意再 `agent-sandbox --upgrade` 留正式快照。

> 完整設計取捨（為何 run/build 分家、為何 semver 自動配號、快照原子性…）
> 見 [`docs/design/agent-sandbox.md`](docs/design/agent-sandbox.md)「Tag 控制
> 與升級」。從舊「自動 build + SHA 防呆」版本升級？見
> [`docs/guides/migrate-autobuild-to-upgrade.md`](docs/guides/migrate-autobuild-to-upgrade.md)。

---

### 同一容器多終端機（`--enter`）

`agent-sandbox --enter` 把目前的終端機**附加**進一個已在跑的 sandbox
（`podman exec` 開一個新 bash），不另起新容器——典型用法：一個視窗跑
agent、另一個視窗進同一個容器觀察或除錯。

```
# 視窗 1：照常啟動
agent-sandbox

# 視窗 2：附加進去（本專案恰好一個在跑 → 直接進）
agent-sandbox --enter
🔗 附加進 myproj-101010-11（guest session：主 session 退出時容器即消失，本連線一併中斷）
```

行為：

- **不指定容器名**：自動找「目前專案」在跑的 sandbox——恰一個直接進；
  多個列出清單要求指定（`agent-sandbox --enter <容器名>`，tab 可補在跑
  的容器名）；零個報錯，並列出其他專案在跑的 sandbox（可跨專案指定）。
- **guest 語意**：容器生命週期仍由「起它的那個視窗」持有——主 session
  退出時容器 `--rm` 消失，所有附加中的連線一併中斷（標準 `podman exec`
  語意）；反過來 guest 打 `exit` 不影響主 session 與容器。
- 附加的 shell 與主 session **同身分、同掛載、同資源上限**（多個視窗
  共用同一份 CPU／記憶體額度，重活並行會互相排擠）。
- 純附加動作：不接受 `--identity`／`--base`／`--addon`／`-m`／`--launch`
  等旗標（目標容器的這些屬性在啟動當下已固定），給了直接報錯。

---

### 進階：Base 變體（`--base`）

base 決定容器裡裝哪套 AI 工具。內建：

| Base | Dockerfile | 工具 | 憑證持久化位置 |
|---|---|---|---|
| `claude`（預設） | [`Dockerfile.base.claude`](Dockerfile.base.claude) | Claude Code CLI | `home/default/.claude` |
| `codex` | [`Dockerfile.base.codex`](Dockerfile.base.codex) | [OpenAI Codex CLI](https://github.com/openai/codex)（Rust 版，npm 官方渠道） | `home/default/.codex` |

**用 Codex**

```bash
# 首次：建 codex 鏈（與 claude 的 image/版號各自獨立）
agent-sandbox --upgrade --base codex

# 日常：進容器並自動啟動 codex（或不加 --launch 進 bash 手動下 codex）
agent-sandbox --base codex --launch

# 容器內第一次使用：codex 會給登入流程，登入態寫在掛載進來的 ~/.codex
# → 退出重進仍有效（同 claude 的 .claude 持久化 pattern）
cat /etc/codex-cli-version    # 查 build 當下凍結的 codex 版本
```

> 兩個 base 的憑證目錄（`.claude`、`.codex`）目前**所有容器都會掛**
> （對用不到的 base 只是個空資料夾）。某專案固定用 codex？在該專案根的
> `.agent-sandbox` 加 `[image]` 段 `base = codex` 即可（見下方逐專案預設）。

---

### 進階：Add-on 變體

把工具（spec 框架、額外 CLI…）疊在 base image 上，需要時才裝、預設 image
維持精簡。addon 是 base-agnostic 的——`--base codex --addon openspec` 一樣疊。

**內建 add-on**

| Add-on | Dockerfile | 用途 |
|---|---|---|
| `openspec` | [`Dockerfile.addon.openspec`](Dockerfile.addon.openspec) | [OpenSpec](https://github.com/Fission-AI/OpenSpec) spec-driven 開發框架 |
| `ops` | [`Dockerfile.addon.ops`](Dockerfile.addon.ops) | 雲端主機維運工具箱：官方 Google Cloud CLI ＋ Ansible（ansible-core，自帶獨立 Python），供 `ops` 這類維運身分使用（見下方「多身分」段）。原 `gcloud` addon 已併入，舊用法見 [`docs/guides/migrate-gcloud-to-ops.md`](docs/guides/migrate-gcloud-to-ops.md) |
| `office` | [`Dockerfile.addon.office`](Dockerfile.addon.office) | 舊版 Office（`.doc`/`.xls`/`.ppt`）轉檔、繁中字型、掃描件 OCR——讓 agent 讀得懂非純文字文件 |

**用 ops（gcloud ＋ Ansible）**

```bash
agent-sandbox --upgrade --addon ops       # 首次：建含 gcloud＋Ansible 的鏈（約 +450 MB）
agent-sandbox --identity ops --addon ops

# 容器內：
cat /etc/ops-tools-version                # gcloud／ansible-core／uv／Python 各一行 + build date
gcloud --version
ansible --version
ansible-galaxy collection install google.cloud   # 裝進 ~/.ansible，跨 session 保留
```

兩個工具的狀態都持久化在身分資料夾、跟 `.claude`／`.codex` 同一套「拋棄式
容器、登入態不拋棄」待遇：

- `home/<identity>/.config/gcloud`：`gcloud auth login` 的 OAuth token／
  application-default credentials——登入一次，之後每個 session 都還在。
- `home/<identity>/.ansible`：`ansible-galaxy` 裝的 collections、Galaxy token
  ——image 刻意**不**預裝任何 collection，要什麼自己裝一次就留著。專案專屬的
  collection 用 Ansible 原生的 `ansible.cfg`（`collections_path` 指到 workspace
  內）即可，不需要 agent-sandbox 另外設定。

> Ansible 用 [uv](https://github.com/astral-sh/uv) 裝、自帶獨立 Python（不用 gcloud
> 帶進來的系統 python3，也不上 PATH）；SSH ControlPersist 的 socket 目錄已固定在
> 容器 `/tmp`，不會寫進身分資料夾。取捨見
> [`docs/design/agent-sandbox.md`](docs/design/agent-sandbox.md)「ops addon」段。

**用 office（讀舊版 Office／掃描件）**

```bash
agent-sandbox --upgrade --addon office    # 首次：建含 office 的鏈（這層約 1 GB+，會跑一陣子）
agent-sandbox --addon office

# 容器內：
cat /etc/office-tools-version             # 各套件版本 + build date

# 舊版 Office → 純文字（繁中可靠路徑）
soffice --headless -env:UserInstallation=file:///tmp/lo_$$ \
    --convert-to 'txt:Text (encoded):UTF8' --outdir /tmp 舊報告.doc

# 舊版 Office → PDF（保留排版，看得到圖表）
soffice --headless -env:UserInstallation=file:///tmp/lo_$$ \
    --convert-to pdf --outdir /tmp 舊報告.doc

# 掃描件（圖片型 PDF）→ 文字：先轉圖再 OCR（pdftoppm 在 base 就有）
pdftoppm -r 300 -png 掃描件.pdf /tmp/pg
tesseract /tmp/pg-1.png /tmp/pg-1 -l chi_tra+eng
```

`-env:UserInstallation=...` 不是可有可無的裝飾：多個轉檔同時跑會搶同一份
LibreOffice user profile 而互相卡住，每個呼叫給一個獨立路徑就沒事。

`antiword`／`catdoc` 也在這個 addon 裡，適合「只想快速抽純文字、不想啟動
LibreOffice」的場合；但**它們對繁中常出現亂碼**，中文文件請走上面的
`soffice --convert-to`。

> 純文字型 PDF 與各種壓縮檔不需要這個 addon——`pdftotext`／`unar` 是格式
> 無關的通用能力，兩個 base 都已內建。

**用 OpenSpec**

```bash
# 首次：先建含 OpenSpec 的鏈（base + addon 一起建/升級）
agent-sandbox --upgrade --addon openspec

# 之後日常進帶 OpenSpec 的容器（純啟動、秒起）
agent-sandbox --addon openspec

# 容器內：
openspec --version                # 確認版本
cat /etc/openspec-version         # 版本 + build date
cd /workspace/<你的專案>
openspec init                     # 初始化 per-project spec 目錄結構
```


**釘特定 openspec 版本**

addon Dockerfile 用 `ARG OPENSPEC_VERSION=latest`，build 時可覆蓋：

```bash
podman build -f Dockerfile.addon.openspec \
    --build-arg BASE_IMAGE=agent-sandbox-claude:latest \
    --build-arg OPENSPEC_VERSION=0.5.0 \
    -t agent-sandbox-claude-openspec:openspec-0.5.0 .

# 之後直接跑該 tag（純啟動只查 image 存在，手動 build 的 tag 一樣認）
agent-sandbox openspec-0.5.0 --addon openspec
```

**自製 add-on**

照 `Dockerfile.addon.<name>` 規則建檔，預設 base-agnostic：

```dockerfile
# Dockerfile.addon.mytool
ARG BASE_IMAGE
FROM ${BASE_IMAGE}
ARG MYTOOL_VERSION=latest
RUN <安裝 mytool>@${MYTOOL_VERSION}
LABEL mytool.version-file="/etc/mytool-version"
```

之後 `agent-sandbox --upgrade --addon mytool` 建鏈、日常
`agent-sandbox --addon mytool` 啟動。

**逐專案預設 base/addon（`.agent-sandbox` 的 `[image]` 段）**

某專案每次都要同一組變體（例如總是 `--addon openspec`），在該專案根的
`.agent-sandbox` 加 `[image]` 段，之後在該專案打 `agent-sandbox` 就自動套用：

```ini
# ~/repos/myproj/.agent-sandbox
[image]
# base = claude        # 預設就是 claude，通常不用寫
addon = openspec       # 可重複多行依序疊層
```

啟動時會印 `📄 讀取 …/.agent-sandbox（[image] 段：…）`。合成規則：

- `base`（單值）：`--base` > 檔案 `base` > 內建 `claude`（覆蓋）。
- `addon`（清單）：檔案 + CLI `--addon` **疊加**（去重），跟 mount 同一條規則。
- 這次不想用某個預設 addon → 把檔案那行 `#` 註解掉即可（`[image]` 只有專案層，
  註解就是逃生口，不需任何旗標）。

> 設計細節（filename prefix 規則、override 逃生口、addon 鏈 build 機制、
> `[image]` 與 CLI 的優先序取捨）
> 見 [`docs/design/agent-sandbox.md`](docs/design/agent-sandbox.md)「`--base` / `--addon` 多變體機制」段。

---

### 進階：額外掛載（多路徑同框工作）

預設容器只看得到 `cd` 那個專案（掛在 `/workspace/<basename>`）。若需要
**多路徑同框** —— 跨專案聯合開發（前端調後端 API、兩邊都在改）、把外部
資料整理進專案、引用共用 schema／design tokens —— 可額外掛載 host 路徑。

**spec 格式**：`<host>[:<container>][:ro]`

host 路徑三種寫法都吃：`~/...`（家目錄展開）、`../foo`／`foo`（相對 `$PWD`）、
`/abs/path`（絕對）。

容器內路徑（第二段）省略最省事，要指定別名時**不用打 `/workspace/` 前綴**：

| 寫法 | 容器內路徑 | 模式 |
|---|---|---|
| `../backend` | `/workspace/backend`（省略→取 host basename） | 可讀寫 |
| `../work/foo:api` | `/workspace/api`（**裸別名→自動補前綴**） | 可讀寫 |
| `../data/dump:dump:ro` | `/workspace/dump` | 唯讀 |
| `~/x:/data/raw` | `/data/raw`（**以 `/` 開頭→絕對路徑原樣**） | 可讀寫，⚠️ 見下 |

> - 第二段**不以 `/` 開頭**＝裸別名，自動掛到 `/workspace/<別名>`（免打前綴、
>   免錯字）。`ro`／`rw` 是**保留字**，不能當裸別名（會報錯，避免與選項混淆）。
> - 第二段**以 `/` 開頭**＝完整絕對路徑，原樣使用。非 `/workspace` 底下時會印
>   ⚠️ 警告（可能蓋掉容器內既有檔案／憑證，如 `/home/agent-sandbox/.claude`）
>   —— 允許但請自行確認。
> - `:ro` 只能當**第三段**：要唯讀得連別名一起寫（`<host>:<別名>:ro`）；只寫
>   `<host>:ro` 會踩到「`ro` 是保留字」報錯。

**A. 一次性（CLI `-m`，可重複）**

```bash
# 前端是當前目錄，額外把後端掛進來一起開
cd ~/repos/frontend
agent-sandbox -m ~/repos/backend

# 多條 + 唯讀參考
agent-sandbox -m ~/repos/backend -m ~/refs/api-spec:/workspace/spec:ro
```

啟動時會印出實際掛了哪些路徑：

```
📎 額外掛載：
   /Users/you/repos/backend:/workspace/backend   (-m)
   /Users/you/refs/api-spec:/workspace/spec:ro   (-m)
```

（每條結尾標**來源**：`(-m)`／`(專案)`／`(全域)`，讓你一眼看出哪條從哪來。）

**B. 穩定配對（`.agent-sandbox` 的 `[mount]` 段，每行 `path = <spec>`）**

兩個專案要合併開發好幾天、不想每次打 `-m`，就在 workspace 根目錄放一個
`.agent-sandbox`，在 `[mount]` 段一行一條 `path = <spec>`（`#` 註解、空行略）：

```ini
# ~/repos/frontend/.agent-sandbox
[mount]
path = ../backend
path = ../shared:shared:ro
```

可複製的範例（含各種寫法註解）：[`docs/examples/agent-sandbox.example`](docs/examples/agent-sandbox.example)
—— `cp` 到你的專案根改名 `.agent-sandbox` 即可。

啟動時自動讀入並印 `📄 讀取 …/.agent-sandbox（[mount] 段，N 條，專案）`；CLI 的
`-m` 會**累加在檔案設定之後**（不是覆蓋）。

**C. 每次都想掛的資料夾（全域 `[mount]`，放工具目錄）**

有些資料夾你**每個專案**都想掛（共用 reference、腳本…）。把 `[mount]` 寫進
**agent-sandbox 工具目錄**（你 `source agent-sandbox.sh` 那個 repo 根）的
`.agent-sandbox`，每個 sandbox 都會掛：

```ini
# <agent-sandbox 工具目錄>/.agent-sandbox
[mount]
path = ~/refs/shared:shared:ro   # 全域路徑須絕對 / ~（相對沒有基準）
```

- 三來源（全域 + 專案 + CLI `-m`）**全部累加**；`📎` 清單逐條標來源。
- ⚠️ **全域 mount 套在每個 sandbox**：被攻陷的專案能寫到它 → 建議盡量 `:ro`。
- 例外專案不想繼承全域：在該專案 `[mount]` 加一行 `inherit-global = false`。
- 某次想完全忽略設定檔、只用 `-m`：`agent-sandbox --no-config-mounts -m …`。

> `.agent-sandbox` 是統一設定檔、**像 git config 一樣分兩處**：**專案根**放
> `[mount]`／`[image]`／`[identity]`／`[resource]`（這個專案要什麼）；**工具目錄**放全域 `[mount]`（你每次
> 都想掛的）。`[image]`／`[identity]`／`[resource]` 只認專案層（放全域會 ⚠️ 略過）；未知段前向相容略過；
> 段標頭須獨佔一行。容器 git 身分不在這裡，是 `home/<identity>/.gitconfig`（見下節）。

**進不進版控？看你寫哪種路徑**：

- 想**隨 repo 分享給隊友**（例如 monorepo `frontend`/`backend` 互為 sibling）：
  用**相對路徑**（`../backend`），機器無關，直接 commit 當專案文件。
- 純個人、用**絕對/家目錄路徑**：屬逐開發者本機狀態，別進版控。**一勞永逸**
  做法是設一次全域 gitignore，之後所有專案都不顯示：
  ```bash
  echo '.agent-sandbox' >> ~/.config/git/ignore
  ```
  （本 repo 的 `.gitignore` 也擋了一份本地防線；跨專案靠上面這條全域。）

**衝突保護（fail-fast）**：若某條的容器路徑撞到 workspace 主掛載、或多條
互撞（典型：兩個來源 basename 相同都展開到 `/workspace/foo`），會在 build
**之前**直接報錯要你改別名，不會靜默蓋掉。host 路徑不存在也立即報錯。

**⚠️ 安全與權限**：

- 額外掛載**擴大容器可寫範圍** —— 被攻陷的 npm 套件、惡意 `mise.toml`
  hook、被誤導的 agent 都可能寫進這些路徑。**能 `:ro` 就 `:ro`**，只在
  真要寫回 host 時才開可讀寫。
- **別把 `~/` 整個掛進來**：跨專案聯合開發、特定資料夾整理 OK；整個家
  目錄＝把所有東西都暴露給 agent。
- 容器以**非 root**（你的 UID）跑：若 host 目錄權限不給該 UID 讀（例如
  macOS `~/Downloads` 這類特殊權限目錄），容器內會 `Permission denied`
  —— 這是 host 目錄權限問題，不是掛載失敗。一般你自己擁有的專案夾
  （755、owner=你）不會有此問題。

> 設計取捨（為何走 CLI `-m` 透傳 `-v` 而非環境變數／改 compose、統一設定檔
> 分段、衝突規則、為何不做中央 registry）見
> [`docs/design/agent-sandbox.md`](docs/design/agent-sandbox.md)「額外掛載」段。

---

### 容器內 git 身分（commit 用什麼身分）

容器是 `--rm` 拋棄式、沒有你 host 的 global gitconfig。容器用的身分就是
`home/<identity>/.gitconfig`（預設身分是 `home/default/.gitconfig`）這個
**標準 git 檔**（bind mount 進容器當 global fallback）—— 你照平常編
`~/.gitconfig` 的直覺改它就好，**不必學任何 agent-sandbox 專屬設定**。

它怎麼來：**首次**（檔案不存在時）`agent-sandbox` 或 `init.sh --apply` 會從你
host 的 `git config --global user.name/email` 生成一份（host 沒設則建空檔 + 提示）。
**之後就是你自己的檔，工具不再碰它**。

```ini
# home/default/.gitconfig（首次自動生成，之後你自己維護）
[user]
	name = Ray
	email = ray@example.com
```

想改身分，三種做法（git 原生優先序：repo local > 容器 global）：

| 情境 | 做法 |
|---|---|
| 改容器的全域預設身分 | 直接編 `home/default/.gitconfig`（工具不會覆寫） |
| 某個 repo 用不同身分 | 在該 repo `git config --local user.name/email`（容器內外都生效）—— 最乾淨 |
| 完全不帶身分 | 把 `home/default/.gitconfig` 清空（空檔不會被回填） |
| 切一整組不同身分（含 SSH 金鑰等） | 用 `--identity <name>`，見下方「多身分」 |

> 該檔已被 `.gitignore`（`home/`）排除、不進版控。首次只帶 `user.name`/`user.email`；
> 你要加 GPG、alias 等自己編進去即可（工具只負責「缺檔時 seed 一份」，不繼承
> host 的其他設定，避免帶進 host-only 路徑問題）。

> 設計取捨（為何受控 seed 而非整檔 mount host、為何不做 identity 模式）見
> [`docs/design/agent-sandbox.md`](docs/design/agent-sandbox.md)「容器內 git identity」段。

---

### 多身分（`--identity`）

不同工作情境想用不同的一整組身分資料（憑證、git 身分、SSH 金鑰）時，用
`--identity <name>` 切換要掛進容器的 `home/<name>/` 資料夾：

```bash
agent-sandbox --identity ops     # 掛 home/ops/，例如帶 SSH 金鑰的維運身分
agent-sandbox                    # 不帶旗標＝ --identity default（一般開發身分）
```

每個 `home/<name>/` 都是一份跟 `home/default/` 同構的獨立資料夾（`.claude`／
`.claude.json`／`.codex`／`.gitconfig`／`.config/mise`／`.config/gcloud`／
`.ansible`／`.ssh`），彼此互不
影響——適合「開發身分不帶長期憑證，維運身分帶 SSH 金鑰但少裝工具」這類風險
區隔。新增身分：

```bash
agent-sandbox --new-identity ops
```

純建立動作，不進容器；逐項列出每個子項是「已存在」還是「新建/補上」，不會
默默做掉任何一步。身分已存在時重跑也安全，天生冪等（不覆蓋既有內容），可以
當健檢用——例如某個子目錄不小心被刪掉，重跑一次就補回來。建完照常
`agent-sandbox --identity ops` 啟動。

`--identity` 指到不存在的資料夾會直接報錯（不會靜默幫你建一個空的），支援
Tab 補全。進容器後 shell prompt 會帶 `[<identity>]` 前綴，提醒目前是哪個身分。

**逐專案預設身分（`.agent-sandbox` 的 `[identity]` 段）**

某專案本質上就該用同一個身分（例如專門管雲端主機的 `ops` 專案），在該專案根
的 `.agent-sandbox` 加 `[identity]` 段，之後在該專案打 `agent-sandbox` 不用
再手動加 `--identity`：

```ini
# ~/repos/ai-ops/.agent-sandbox
[identity]
identity = ops
```

啟動時會印 `📄 讀取 …/.agent-sandbox（[identity] 段：identity=ops）`——身分
切換影響風險層級（可能帶 SSH 金鑰），這條可見性訊息不能省。合成規則：單值
覆蓋，`--identity` > 檔案 `identity` > 內建 `default`；跟 `[image]` 的
`base` 同一套規則。`[identity]` 只有專案層（跟 `[image]` 一樣），這次想改用
別的身分，CLI `--identity` 直接覆蓋即可。

> 設計取捨（為何容器內路徑固定不隨身分變動、為何預設身分資料夾叫
> `default`、`--new-identity` 為何不牴觸 `--identity` 的 fail-fast 紅線）見
> [`docs/design/agent-sandbox.md`](docs/design/agent-sandbox.md)「多身分」與
> 「建立新身分」段。本機已有舊版單一身分資料夾 `home/node/`？見
> [`docs/guides/migrate-home-node-to-default.md`](docs/guides/migrate-home-node-to-default.md)。

---

### 逐專案資源限制（`[resource]`）

容器預設**最多 2GB 記憶體、2 核 CPU、512 個 task**。要編譯／跑測試的專案可以在該專案根
的 `.agent-sandbox` 放寬：

```ini
[resource]
cpus   = 4
memory = 6g
pids   = 1024
```

三個鍵各自獨立、都可省略；沒寫的沿用 `docker-compose.yaml` 的預設。**整段不寫＝行為完全
不變。** 不想套用某一項就把那行 `#` 註解掉（專案 only，不需要旗標）。

啟動時一定會印出目前生效的值，順便告訴你這台機器有多少、其他 sandbox 用掉多少：

```
⚙️  資源限制：CPU 4 核*、記憶體 6.00 GiB*、PID 512   （* = 專案 [resource] 段，其餘為預設）
🖥  machine 6 核 / 7.72 GiB，無 swap
   另有 3 個 sandbox 在跑：
     bancs-llm-wiki-202432-95199        記憶體 1.14 / 4.00 GiB
     …
   記憶體：實際已用 1.94 GiB ／ 上限加總 12.00 GiB（含本次 18.00 GiB ⚠️ 超過 machine）／ machine 7.72 GiB
   CPU：額度加總 6 核（含本次 10 核）／ machine 6 核 —— 超賣正常，全開時互相分
```

要調 podman machine 的配額（Podman Desktop 的 Settings → Resources）時，這些數字就在眼前。

**幾個會踩到的地方**：

- **`cpus` 是時間配額不是綁定核心**：容器內 `nproc` 仍顯示 VM 的顆數，`make -j$(nproc)`
  之類會開太多。要確認實際生效值，進容器 `cat /sys/fs/cgroup/cpu.max`
  （2 核 = `200000 100000`，4 核 = `400000 100000`）。
- **調高 `cpus` 通常要一起調 `pids`**：`pids` 計的是 task（含執行緒），平行 build 很容易
  撞到 512，症狀是 `fork: Resource temporarily unavailable`，完全不指向這個設定。
- **`memory` 要帶單位**：`6g`／`512m`，大小寫皆可。`memory = 8` 會被拒絕（那在 compose
  語意上是 8 bytes，不是 8GB）；`6gb`／`6Gi` 也不收。
- **`0` 和負數一律拒絕**：那等於取消限制，本段不是關掉沙盒防線的後門。
- **記憶體超出的後果比 CPU 嚴重**：CPU 超賣只是大家變慢、會自我修正；記憶體是所有容器
  **實際**用量加起來超過 VM 就觸發 VM 層 OOM，**砍到哪個容器不受控**（可能砍掉另一個
  session 跑到一半的 build）。所以上面那行「本次若用滿會超過」的 ⚠️ 值得看一眼。
- **被莫名砍掉時先想到這裡**：容器撞到自己的記憶體上限時，通常只看到 process 突然消失或
  build 中斷，不會有訊息說是記憶體。先把 `memory` 調高或調大 machine 再試。
- **只讀 `$PWD/.agent-sandbox`、不往上找**：在專案的子目錄啟動時這段設定不會生效（同
  `[image]`／`[identity]`）。

### 使用 GHCR 預建 image（免本機 build）

每次推上 GitHub，CI 會自動把 image build 成**多架構（arm64 + amd64）**並推到
[GHCR](https://ghcr.io)。不想本機 `podman build` 的話可直接 pull 現成 image。

本機 `agent-sandbox` 函式只認**無 registry 前綴**的名字（`agent-sandbox-claude:latest`），
所以 pull 下來後 `podman tag` 成那個名字即可被既有函式使用：

```bash
# 1) 從 GHCR 拉（podman 會自動挑你機器的架構）
podman pull ghcr.io/ray4f55/agent-sandbox-claude:latest

# 2) tag 成本機函式認得的名字
podman tag ghcr.io/ray4f55/agent-sandbox-claude:latest agent-sandbox-claude:latest

# 3) 照常使用（具名版號同理：pull :v1.0.0 後 tag 成 agent-sandbox-claude:v1.0.0）
agent-sandbox        # 純啟動：image 已在（剛 tag 好）→ 直接跑，完全不 build
```

帶 add-on 的同理（`agent-sandbox-claude-openspec`）。確認多架構：

```bash
podman manifest inspect ghcr.io/ray4f55/agent-sandbox-claude:latest   # 應列出 amd64 + arm64
podman image inspect agent-sandbox-claude:latest --format '{{.Architecture}}'
```

> 設計取捨（為何純發佈、不改本機 build／compose；凍結=git tag 的對應；多架構為何
> 選 buildx+QEMU）見 [`docs/design/ci-ghcr.md`](docs/design/ci-ghcr.md)。

---

### 補充

- **mise-cache volume 管理**（查 cache 路徑／用量、清整個 cache 或單一語言）：[`docs/guides/mise-cache.md`](docs/guides/mise-cache.md)
- **手動清理 podman 資源**（清舊 alias 殘餘、連 volume 一起清、批次清多日累積、做成個人 alias）：[`docs/guides/cleanup.md`](docs/guides/cleanup.md)
- **設計取捨**（為何 compose volume 是 external、為何 agent-sandbox 是 function、mise trust 為何不持久化…）：[`docs/design/`](docs/design/)
- **檔案結構速查**（哪個檔在哪、進不進 git）：[`docs/reference/file-layout.md`](docs/reference/file-layout.md)


