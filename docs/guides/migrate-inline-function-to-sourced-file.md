# 從「整段函式貼進 .zshrc」遷移到「source agent-sandbox.sh」

舊版安裝方式是把 README 裡整段 `agent-sandbox()` 函式（連同補全、zstyle、
`alias docker=podman`、以及 `export AGENT_COMPOSE_PATH=...`）**複製貼進
`~/.zshrc`**。現在改成 source repo 內的單一檔 [`agent-sandbox.sh`](../../agent-sandbox.sh)。

新拿到專案、第一次設置的使用者跳過本檔即可（README 已是當代版本）。

## 為什麼改

- **消除 drift**：貼進 rc 的是一份**副本**，會與 repo 權威版分岔；手改過、
  或 repo 更新後，跑的常是舊副本（曾導致「Dockerfile 改了卻沒跳備份提示」）。
  改成 source 同一個檔後，世上只有一份權威版。
- **搬家不壞**：舊版靠寫死的 `AGENT_COMPOSE_PATH` 絕對路徑定位 compose／
  Dockerfile，repo 一搬就失效。新檔**自我定位**自身所在目錄，
  `AGENT_COMPOSE_PATH` 直接移除、不再需要。
- **一行取代數百行**：rc 只剩一行 `source ...`。

## 步驟

### 1. 編輯 `~/.zshrc`，刪掉舊區塊

打開 `~/.zshrc`，把下列舊內容**全部刪除**：

- `agent-sandbox() { ... }` 整段函式
- `_agent-sandbox() { ... }` 補全、`compdef _agent-sandbox agent-sandbox`
- 相關的 `zstyle ... agent-sandbox ...` 兩行
- `alias docker=podman`
- `export AGENT_COMPOSE_PATH="..."` —— **已不需要**（自我定位取代它）

> 還停在更舊的 `cc-container` 版？先照
> [`migrate-cc-container-to-agent-sandbox.md`](migrate-cc-container-to-agent-sandbox.md)
> 把舊名清乾淨，再回來做本檔這步。

### 2. 改成一行 source

加上（換成你 repo 的實際路徑）：

```zsh
source /path/to/agent-sandbox/agent-sandbox.sh
```

### 3. 重新載入

```zsh
source ~/.zshrc
type agent-sandbox       # 應顯示 "agent-sandbox is a shell function"
```

## 驗證

跑一次 `agent-sandbox` 進容器 → `exit` 退出 → 看到「🧹 已移除 network」訊息即正常。

搬動 repo 後：只要把 `~/.zshrc` 裡 `source` 那行的路徑改成新位置即可，
**不需要再設定任何路徑變數**。

## 注意：更新後請重開終端機

`source` 是在開 shell 當下把函式載進記憶體。`git pull` 更新了
`agent-sandbox.sh` 之後，**已開著的終端機仍跑舊函式**，需重開終端機或
重新 `source ~/.zshrc` 才會生效（這屬正常 shell 行為，刻意不加 runtime
版本檢查；原追蹤於 B0020）。
