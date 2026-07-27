# agent-sandbox-codex-wrapper.sh —— 可選門面：讓 `codex --sandbox` 啟動 agent-sandbox 容器（codex base）。
#
# 這是 opt-in（預設不啟用）：它會以 shell 函式 shadow `codex` 這個指令名，
# 該不該這麼做應由你明確選擇，所以不放進 agent-sandbox.sh，而是獨立一檔
# （慣例同 agent-sandbox-claude-wrapper.sh，原追蹤於 B0032；本檔於 B0016）。
#
# 啟用：在 ~/.zshrc 裡、`source …/agent-sandbox.sh` 那行「之後」再加一行：
#   source /path/to/agent-sandbox/agent-sandbox-codex-wrapper.sh
# 也可由 init.sh --apply 的詢問式 opt-in 自動加入。
#
# 行為：
#   codex --sandbox [tag] [--addon …] [-m …]   → 進沙盒並自動啟動 codex
#                                                 （= agent-sandbox --base codex --launch …）
#   codex <其他任何參數>                          → 原樣轉發給「真正的」codex
#
# ⚠️ 已知撞名（與 claude 版「未來可能撞」不同，這是「確定撞、但面窄」，刻意接受）：
#   真 codex 本身有 `-s, --sandbox <MODE>` 旗標（它自己的執行隔離政策）與
#   `sandbox` 子指令。本函式只攔「`--sandbox` 是第一個參數」這一種形態：
#     codex --sandbox workspace-write   ← 被本門面攔走（唯一犧牲面）
#     codex -s workspace-write          ← 短旗標，透明轉發真 codex，不受影響
#     codex "prompt" --sandbox read-only ← 旗標不在第一位，轉發，不受影響
#     codex sandbox run …               ← 子指令（無 dash），轉發，不受影響
#   要用真 codex 的長旗標寫法：`command codex --sandbox …` 或 `\codex --sandbox …`
#   繞過本函式；徹底停用＝移除 rc 的 source 行（或重跑 init.sh --apply 答 n）。
#   本補全也會蓋掉真 codex 的原生補全（同 claude wrapper 的注意事項）。

codex() {
    if [[ "$1" == "--sandbox" ]]; then
        shift
        # --base codex + --launch：進 codex base 容器並自動啟動 codex；
        # --sandbox 後的參數續傳給 agent-sandbox（tag/--addon/-m 全沿用）
        agent-sandbox --base codex --launch "$@"
    else
        command codex "$@"      # 其餘原樣轉發真正的 codex（command 繞過本函式）
    fi
}

# tab 補全：`codex --sandbox <…>` 把 --sandbox 之後當 agent-sandbox 參數來補，
# 並注入 --base codex → tag 候選是 codex repo 的（context-aware 補全自動生效）。
# 委派既有 _agent-sandbox，零重複。依賴 agent-sandbox.sh 已先 source。
_agent-sandbox-codex-wrapper() {
    if [[ "${words[2]}" == "--sandbox" ]]; then
        # `codex --sandbox <args>` 重寫成 `agent-sandbox --base codex <args>` 再委派；
        # 拿掉 1 個詞（--sandbox）補進 2 個詞（--base codex）→ CURRENT 淨位移 +1
        words=( agent-sandbox --base codex "${(@)words[3,-1]}" )
        (( CURRENT++ ))
        _agent-sandbox
    else
        _arguments '1:模式:(--sandbox)'    # 還沒打 --sandbox → 先補它
    fi
}
(( $+functions[compdef] )) && compdef _agent-sandbox-codex-wrapper codex
