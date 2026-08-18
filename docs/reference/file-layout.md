# 檔案結構速查

Repo 內每個檔案／資料夾的角色、是否進版控、主要讀寫者。動手前查這份比
亂 grep 快。

## 根目錄

| 路徑 | 角色 | 進 git |
|---|---|---|
| `README.md` | 使用方式（指令、shell 函式、操作步驟） | ✅ |
| `agent-sandbox.sh` | 啟動函式 + tab 補全（自我定位 sourceable，加進 `~/.zshrc`） | ✅ |
| `init.sh` | 一鍵環境設定（相依檢查 + 建鏡射目錄 + 寫 rc source 區塊；`--check`/`--apply`） | ✅ |
| `CLAUDE.md` | AI 設計索引（紅線 invariant + `@import` 細節檔） | ✅ |
| `CONTRIBUTING.md` | 貢獻指南 | ✅ |
| `CODE_OF_CONDUCT.md` | 行為準則 | ✅ |
| `LICENSE` | 授權 (MIT) | ✅ |
| `Dockerfile.base.<name>` | base image 定義（目前：`Dockerfile.base.claude`） | ✅ |
| `docker-compose.yaml` | 服務／volume／資源限制 | ✅ |
| `.dockerignore` | build context 排除清單 | ✅ |
| `.gitignore` | 版控排除清單 | ✅ |
| `.agent-sandbox`（選用） | **全域**設定檔（工具目錄）：全域 `[mount]`（每個 sandbox 都掛的共用路徑）；逐開發者本機狀態。專案層同名檔放各專案根（`[mount]`/`[image]`/`[identity]`，後兩者僅專案層生效） | ❌（gitignored） |

## docs/

| 路徑 | 用途 | 何時看 |
|---|---|---|
| `docs/design/` | 為什麼這樣設（設計取捨與紅線細節） | 動程式碼前 |
| `docs/examples/` | 可複製的設定範例 | 第一次設定／新建類似專案 |
| `docs/reference/` | 查表（env vars、命名、結構） | 卡在「這個叫什麼／放哪」時 |

整個 `docs/` 不進 image build（見 `.dockerignore`）。

## 私有目錄與檔案（gitignored，不進 OSS repo）

| 路徑 | 內容 |
|---|---|
| `_backlog/` | 開發 backlog 過程史；由 `.claude/skills/backlog/` 管理 |
| `_notes/` | 跟專案較無關的延伸知識筆記；由 `.claude/skills/notes/` 管理 |
| `_terminal*` / `_temp*` / `_安全*.md` | 個人開發筆記、暫存 |
| `home/` | 身分資料鏡射目錄，`home/<identity>/`（預設 `home/default/`；`--identity` 切換，見 `docs/design/agent-sandbox.md`「多身分」）鏡射進容器 `$AGENT_HOME`（`/home/agent-sandbox/`）；含登入憑證、mise 設定、`.gitconfig` 容器 git 身分檔——首次從 host 身分 seed，之後使用者自管 |

排除規則：`.gitignore` 用 `_*` 統一排除底線開頭的檔案與目錄。

## .claude/

`.claude/` 採白名單規則：`.claude/*` 預設排除，僅放行 `skills/`。

| 路徑 | 進 git |
|---|---|
| `.claude/skills/` | ✅ 團隊共用 skill 機制（backlog、notes、…） |
| `.claude/settings.local.json` 等其他 | ❌ 個人／本地設定 |

## 環境變數使用點速查

| 變數 | 由誰設 | 由誰讀 |
|---|---|---|
| `AGENT_SANDBOX_IMAGE` | `agent-sandbox` 函式（依 base/addon 算出） | `docker-compose.yaml` |
| `WORKSPACE_DIR` | `agent-sandbox` 函式（從 `$PWD`） | `docker-compose.yaml` |
| `WORKSPACE_NAME` | `agent-sandbox` 函式（從 basename） | `docker-compose.yaml` |
| `COMPOSE_PROJECT_NAME` | `agent-sandbox` 函式（含日期戳） | compose / podman cleanup |
| `UID` / `GID` | `agent-sandbox` 函式（從 `id`） | `docker-compose.yaml`（user mapping） |
| `AGENT_SANDBOX_IDENTITY` | `agent-sandbox` 函式（`--identity`，預設 `default`） | `docker-compose.yaml`（選 `home/<identity>/` 掛載來源） |
| `AGENT_SANDBOX_HOME` | 未設時 `docker-compose.yaml` 預設 `/home/agent-sandbox` | `docker-compose.yaml`（`HOME` 環境變數與掛載目標） |
| `AGENT_SANDBOX_USER` | `agent-sandbox` 函式（一律＝目前 `--identity` 名稱本身，零特例） | `entrypoint.sh`（動態補 `/etc/passwd`）、bashrc `PS1` |
| `HOME` | `docker-compose.yaml`：`${AGENT_SANDBOX_HOME:-/home/agent-sandbox}` | 容器內 process |

詳細的命名約定與 label schema：待補（[ ] `docs/reference/labels-and-naming.md`）。
