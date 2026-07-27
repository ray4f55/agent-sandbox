#!/bin/sh
# 容器啟動時的第一個進程：runtime UID 沒有對應的 /etc/passwd 紀錄
# （「幽靈使用者」），ssh／git-over-ssh 會因查無使用者直接拒絕執行。
# 動態補一筆紀錄後 exec 交還原本要跑的指令。see docs/design/agent-sandbox.md（B0044）
set -e

AGENT_SANDBOX_USER="${AGENT_SANDBOX_USER:-agent}"

if ! id -un >/dev/null 2>&1; then
    # 密碼欄用 *（非 x）：這個帳號本來就不打算給任何人用密碼登入，
    # * 明確表達「無法用密碼登入」，不必依賴（其實也不存在的）/etc/shadow 紀錄
    echo "${AGENT_SANDBOX_USER}:*:$(id -u):$(id -g):Agent Sandbox:${HOME:-/home/agent-sandbox}:/bin/bash" >> /etc/passwd
fi

if ! getent group "$(id -g)" >/dev/null 2>&1; then
    echo "${AGENT_SANDBOX_USER}:x:$(id -g):" >> /etc/group
fi

export USER="${USER:-$AGENT_SANDBOX_USER}"
export LOGNAME="${LOGNAME:-$AGENT_SANDBOX_USER}"

# 身分可視化（一次性 banner，B0015）：whoami 不保證反映身分（見上方 B0044
# 已知環境相依限制），這裡是唯一保證看得到的手段——entrypoint 是容器最先
# 執行的進程，純 bash／--launch 兩種模式都會經過。跟下面 PS1（.bashrc，
# Dockerfile 裡設定）互補：這裡給進容器當下的即時確認，PS1 給之後持續
# 工作時的提醒。see docs/design/agent-sandbox.md「B0015」
echo "🪪 agent-sandbox 身分：${AGENT_SANDBOX_USER}"

exec "$@"
