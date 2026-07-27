# 手動清理 podman 資源

本沙盒 `agent-sandbox` 函式退出時會**自動清掉「該日該 project 的孤兒
network」**，預設不清 volume（保留資料）。但有些情況需要手動處理：

- 之前的 alias 版本（pre-v4 function）沒清理留下的殘餘
- 想連 volume 一起清（拋棄式哲學的徹底版）
- 想批次清掉好幾天累積的 daily project
- 想做成個人 alias 常駐使用

本指南列出常用操作。**請先看清楚自己要清什麼**再執行：`down` 跟
`--volumes` 會強制砍掉資料，跟 `network rm`（碰到使用中會失敗）不同。

完整自動清理邏輯與紅線見 [`docs/design/agent-sandbox.md`](../design/agent-sandbox.md) 的
「退出後的自動清理」章節。

## 一、查看現有資源

```zsh
# 列出所有 compose 自動建的 network（最常用）
podman network ls --filter "label=com.docker.compose.network"

# 列出所有「還被 compose 視為 project」的（有 container 還在的才會列）
podman compose ls -a

# 查容器（含已停止的）並看它屬於哪個 compose project
podman ps -a --filter "label=com.docker.compose.project"
```

## 二、關掉指定名稱的 network

```zsh
# 單一條
podman network rm agent-sandbox-20260511_default

# 一次刪多條（空白分隔）
podman network rm agent-sandbox-20260511_default agent-sandbox-20260513_default

# 強制刪（network 上還有 container 連著時才需要，會強制斷線）
podman network rm -f agent-sandbox-20260513_default

# 用名稱前綴批次刪（最實用，會自動跳過正在使用中的）
podman network ls --format '{{.Name}}' \
  | grep '^agent-sandbox-' \
  | xargs -r podman network rm

# 清掉所有「沒被使用」的 network（最安全的萬用清理）
podman network prune -f
```

## 三、關掉指定名稱的 compose project

「compose project」其實是一個用 label 綁定的資源群組，要清掉它**必須同
時指定 compose 設定檔（`-f`）和 project 名稱（`COMPOSE_PROJECT_NAME`）**：

> 本節（及第四節）範例用 `$compose` 指向你的 compose 檔。先設一次（`export`
> 讓後面的子 shell 也吃得到；換成你 repo 的實際路徑）：
>
> ```zsh
> export compose=/path/to/agent-sandbox/docker-compose.yaml
> ```

```zsh
# 只清 container + network（保留 volume，預設行為）
COMPOSE_PROJECT_NAME=agent-sandbox-20260513 \
  podman compose -f "$compose" down

# 連 volume 一起清（拋棄式哲學選這個）
COMPOSE_PROJECT_NAME=agent-sandbox-20260513 \
  podman compose -f "$compose" down --volumes

# 連 image 也一起清（最徹底，下次要重 build）
COMPOSE_PROJECT_NAME=agent-sandbox-20260513 \
  podman compose -f "$compose" down --volumes --rmi all
```

> ⚠️ `down` 會**強制停掉並移除**該 project 名下所有 container，跟單純
> `network rm` 不一樣（後者對使用中的 network 會失敗、不會誤殺正在跑
> 的容器）。確認 project 內沒有想保留的工作再下 `down`。

## 四、批次清掉「所有 agent-sandbox-*」（每日大掃除）

```zsh
# 用 project name 前綴一次清光（含 network、volume）
podman compose ls -a --format json \
  | jq -r '.[].Name' \
  | grep '^agent-sandbox-' \
  | xargs -I{} sh -c 'COMPOSE_PROJECT_NAME={} podman compose -f "$compose" down --volumes'

# 純粹只清 network 前綴（最保守，volume 不動）
podman network ls --format '{{.Name}}' \
  | grep '^agent-sandbox-' \
  | xargs -r podman network rm
```

## 五、把常用清理做成個人 alias

如果常清，加進 `~/.zshrc`：

```zsh
# 列所有 agent-sandbox 相關的 network
alias cc-net-ls='podman network ls | grep agent-sandbox'

# 清掉所有 agent-sandbox-* 的 network（會自動跳過使用中的）
alias cc-net-clean='podman network ls --format "{{.Name}}" | grep "^agent-sandbox-" | xargs -r podman network rm'

# 清掉所有沒在用的 network（萬用版）
alias cc-net-prune='podman network prune -f'
```
