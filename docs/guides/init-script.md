# `init.sh` 一鍵環境設定

`init.sh`（repo 根目錄）把新使用者的手動設定流程自動化：相依檢查、建 host
鏡射目錄、在 `~/.zshrc` 寫入 source 區塊。對應 README「Quick start → 一鍵設定」。

## 模式

```bash
./init.sh             # = --check：純診斷，不更動任何東西（預設、最安全）
./init.sh --apply     # 逐項徵得同意後才動手
./init.sh --uninstall # 移除 ~/.zshrc 內的 agent-sandbox 區塊（先備份）
./init.sh --help
```

> 若 `./init.sh` 回 `permission denied`（執行位沒帶到），改用 `bash ./init.sh ...`
> 即可，或先 `chmod +x init.sh`。

- **`--check`（預設）**：印出每項狀態（`[ok]`/`[warn]`/`[miss]`/`[err]`），
  全就緒回傳 0、有缺項回傳非 0（可用於腳本/CI）。完全不寫入。
- **`--apply`**：跑同樣檢查，對可自動處理的項目逐一徵詢後動手；對需你親自
  處理的（如缺 podman）只**印出安裝指令、不自動安裝**。

## 它檢查 / 處理什麼

| 項目 | --check | --apply |
|---|---|---|
| 平台 / shell | 報 OS、shell（非 zsh 會警告：agent-sandbox.sh 需要 zsh） | — |
| podman（>= 4.0） | 在否、版本 | 缺則印安裝指令（brew/apt/dnf），不自動裝 |
| compose provider | `podman compose`（內建）優先、退而 `podman-compose` | 同上 |
| git | 軟檢查（非必要） | 缺則印安裝指令 |
| podman machine（macOS） | 是否執行中 | 徵詢後 `init`/`start`（唯一的狀態變更例外） |
| host 鏡射目錄 | `home/default/.claude`、`.config/mise`、`.claude.json` 是否存在（預設身分；其他身分見 `docs/design/agent-sandbox.md`「多身分」） | 徵詢後 `mkdir -p` / `touch` |
| 既有 `~/.claude` 憑證 | — | 徵詢後複製進來（維持登入） |
| `~/.zshrc` source 區塊 | 是否已有 **＋ 路徑是否指向目前 repo**（搬家後會抓出舊路徑） | 徵詢後寫入/更新（見下） |
| compose 檔可解析 | 餵假 `WORKSPACE_*` 跑 `config` | — |

## rc 區塊（idempotent）

`--apply` 在 `~/.zshrc` 寫入一個標記區塊：

```zsh
# >>> agent-sandbox >>>
# 由 agent-sandbox init.sh 管理；勿手動編輯標記之間內容。
# 重跑 ./init.sh --apply 可重新產生；./init.sh --uninstall 可移除。
source "$HOME/agent-sandbox/agent-sandbox.sh"
# <<< agent-sandbox <<<
```

- **路徑用 `$HOME` 收斂**：repo 在 home 底下時寫成字面 `$HOME/...`（更可攜、
  換機/換使用者名仍對，由 zsh 在 source 當下展開）；repo 不在 home 底下
  （如外接碟）才退回絕對路徑。
- **重跑不重複**：偵測到既有區塊就整段替換（不會 append 第二份）。
- **寫入前**：先把 `~/.zshrc` 備份成 `~/.zshrc.bak.<時間戳>`、印出將寫入的
  內容預覽、再徵詢（預設 No）。
- **不自動 source**：寫完提示你 `source ~/.zshrc` 或開新終端機（腳本無法
  影響父 shell，也不該偷偷 source 你的 rc）。
- **解除安裝**：`./init.sh --uninstall`（會先備份再移除整個區塊）；或手動
  刪掉兩個標記之間（含標記）那段。**只動 rc 區塊**，不碰鏡射目錄/憑證、
  image、volume（要清那些見 [`cleanup.md`](cleanup.md)）。

## 安全姿態

- 預設 `--check` 不動任何東西。
- 缺的系統套件只「印指令」不自動裝（權限/安全考量）。
- 唯一的狀態變更例外是 macOS `podman machine init/start`——那是 podman 自身
  首次啟動、且明確徵詢過才做。
- 每項變更各自徵詢，可只接受部分。

## 之後更新

`git pull` 更新了 `agent-sandbox.sh` 後，**已開著的終端機仍跑舊函式**，
重開終端機或 `source ~/.zshrc` 即可（屬正常 shell 行為）。

## Windows

v1 不提供原生 Windows 支援；請走 WSL2，見
[`windows-setup.md`](windows-setup.md)。
