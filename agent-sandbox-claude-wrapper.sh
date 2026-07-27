# agent-sandbox-claude-wrapper.sh —— 可選門面：讓 `claude --sandbox` 啟動 agent-sandbox 容器。
#
# 這是 opt-in（預設不啟用）：它會以 shell 函式 shadow `claude` 這個指令名，
# 該不該這麼做應由你明確選擇，所以「不」放進 agent-sandbox.sh，而是獨立一檔。
#
# 啟用：在 ~/.zshrc 裡、`source …/agent-sandbox.sh` 那行「之後」再加一行：
#   source /path/to/agent-sandbox/agent-sandbox-claude-wrapper.sh
# （依賴 agent-sandbox 函式與其補全，故須先 source agent-sandbox.sh）
# 也可由 init.sh --apply 的詢問式 opt-in 自動加入這行。
#
# 行為：
#   claude --sandbox [tag] [--base …] [-m …]   → 進沙盒並自動啟動 claude
#                                                 （= agent-sandbox --launch …；claude 退出後留容器 bash）
#   claude <其他任何參數>                        → 原樣轉發給「真正的」claude
# 本機沒裝 claude 時，非 --sandbox 的 claude 呼叫會回報找不到 claude（預期行為）。
#
# 指令解析優先序：function（本檔）> PATH 的 claude binary；函式內 `command claude`
# 繞過本函式直呼真 claude。本檔也提供 `claude --sandbox …` 的 tab 補全（委派給
# agent-sandbox 的補全邏輯）。
# ⚠️ 若本機日後裝了 claude 又仍 source 本檔：claude 函式會 shadow 真 claude（非
#    --sandbox 仍 command claude 轉發、行為基本不變），且本補全會蓋掉 claude 原生
#    補全 → 屆時移除本檔（或下方 compdef 那行）即可。
#
# 設計取捨見 docs/design/agent-sandbox.md「claude --sandbox 門面」段（原追蹤於 B0032）。

claude() {
    if [[ "$1" == "--sandbox" ]]; then
        shift
        # --launch：進容器自動啟動 claude（名實相符）；--sandbox 後的參數續傳給 agent-sandbox
        agent-sandbox --launch "$@"
    else
        command claude "$@"     # 其餘原樣轉發真正的 claude（command 繞過本函式）
    fi
}

# tab 補全：`claude --sandbox <…>` 把 --sandbox 之後當 agent-sandbox 參數來補
# （委派既有 _agent-sandbox，零重複）。依賴 agent-sandbox.sh 已先 source。
_agent-sandbox-claude-wrapper() {
    if [[ "${words[2]}" == "--sandbox" ]]; then
        # 把 `claude --sandbox <args>` 重寫成 `agent-sandbox <args>` 再委派
        words=( agent-sandbox "${(@)words[3,-1]}" )
        (( CURRENT-- ))
        _agent-sandbox
    else
        _arguments '1:模式:(--sandbox)'    # 還沒打 --sandbox → 先補它
    fi
}
(( $+functions[compdef] )) && compdef _agent-sandbox-claude-wrapper claude
