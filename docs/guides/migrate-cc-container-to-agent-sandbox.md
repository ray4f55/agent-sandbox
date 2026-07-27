# 從 `cc-container` 遷移到 `agent-sandbox`

如果你之前用 `cc-container` 函式版,需要更新 `.zshrc` 改用新的 `agent-sandbox`
函式。新拿到專案、第一次設置的使用者跳過本檔即可（README 已是當代版本）。

## 為什麼改名

原 `cc-container` 名字偏向 Claude Code，未來會支援多 base（gemini、codex
等變體）+ add-on（如 openspec）。中性化命名讓 multi-base 設計更乾淨。

同時本次移除了 `--claude` 一鍵啟動旗標與 host `claude()` 門面函式 ——
那是 claude-only 的便利機制,跟多 base 設計衝突。後續 B0016 落地時會以
通用 `--launch` 旗標重新加回類似功能。

## 步驟

### 1. 更新 `.zshrc`

打開 `~/.zshrc`,做以下三件事：

- 找到舊的 `cc-container() { ... }` 整段函式、`_cc-container() { ... }`
  補全、`compdef _cc-container cc-container`、與其相關的 `zstyle ...
  cc-container ...` 兩行,**全部刪除**
- 若你有從上一輪加進去的 host `claude()` 門面函式 + `_claude` 補全 +
  `compdef _claude claude` + `zstyle ... claude ... verbose yes`,
  **也全部刪除**(這次移除了該機制)
- 加上一行 `source /path/to/agent-sandbox/agent-sandbox.sh`(函式、
  `_agent-sandbox` 補全、zstyle、`alias docker=podman` 現在都在這個檔裡;
  也別忘了刪掉舊的 `export AGENT_COMPOSE_PATH=...`,已不需要 ——
  詳見 [`migrate-inline-function-to-sourced-file.md`](migrate-inline-function-to-sourced-file.md))

### 2. 重啟 shell

```zsh
source ~/.zshrc
type agent-sandbox       # 應顯示 "agent-sandbox is a shell function"
type cc-container        # 應顯示 "not found"（舊函式已清乾淨）
```

### 3. 保留既有 milestone image(可選)

如果你有用 `cc-container v1.0.X` 凍結過里程碑版本 image,它們仍以舊名
`agent-sandbox-cc:v1.0.X` 留在本機。新函式只認 `agent-sandbox-claude:*`
所以這些 image 變孤兒。**想保留**就 `podman tag` 重貼新名:

```zsh
# 看現有有哪些舊 tag
podman images agent-sandbox-cc

# 把想保留的逐一重貼成新名（範例）
podman tag agent-sandbox-cc:v1.0.0 agent-sandbox-claude:v1.0.0
podman tag agent-sandbox-cc:latest agent-sandbox-claude:latest

# （可選）重貼完移除舊名節省磁碟
podman rmi agent-sandbox-cc:v1.0.0 agent-sandbox-cc:latest
```

新 `agent-sandbox v1.0.0` 即會用到。

### 4. SHA cache 路徑變了

> ⚠️ 2026-07-03 起本節已過時：SHA 防呆機制整組移除（run/build 分家，B0035），
> `~/.cache/agent-sandbox/*.sha` 不再被使用。見
> [`migrate-autobuild-to-upgrade.md`](migrate-autobuild-to-upgrade.md)。

舊版用 `~/.cache/cc-container/latest.sha` 追 Dockerfile 指紋,新版改用
`~/.cache/agent-sandbox/latest.sha`(且 Dockerfile 本身已改名為
`Dockerfile.base.claude`)。

第一次跑 `agent-sandbox` 沒有舊指紋,**會跳過「Dockerfile 有變」提示**
（因為它沒有「上次」可比);第二次起恢復正常。可不理或手動清舊夾:

```zsh
rm -rf ~/.cache/cc-container         # 舊 cache，留著也只是佔幾 byte
```

## 驗證遷移完成

跑 `agent-sandbox` 進去 → bash → 各種操作正常 → `exit` 退出 → 看到
「🧹 已移除 network」訊息。

若有用過 `claude --container` 一鍵啟動,**該命令已不存在**;改用兩步:

```zsh
agent-sandbox           # 進容器 bash
claude                  # 容器內手動啟動 claude
```

後續 B0016 落地後會以 `--launch` 形式加回一鍵語意。
