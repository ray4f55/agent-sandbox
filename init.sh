#!/usr/bin/env bash
#
# init.sh —— agent-sandbox 一鍵環境設定
#
# 做三件事：① 檢查相依（podman / compose provider / git / podman machine），
# 缺的「印出該平台安裝指令」但不替你自動裝；② 建好 host 端鏡射目錄
# （home/default/...，預設身分，避免 podman 用 root 自動建造成權限錯誤；
# 其他身分見 docs/design/agent-sandbox.md「B0015」，本腳本只處理預設）；
# ③ 在 ~/.zshrc 寫入一個 idempotent 區塊，source 本 repo 的 agent-sandbox.sh。
#
# 用法：
#   ./init.sh            # = --check：純診斷，不改任何東西（預設、最安全）
#   ./init.sh --apply    # 逐項徵得同意後才動手
#   ./init.sh --help
#
# 定位為 bash（限 bash 3.2 相容語法，macOS 內建可跑）。Windows 走 WSL2，
# 見 docs/guides/windows-setup.md。

set -u

# ============================================================
# 自我定位 + repo 健全性
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yaml"
SANDBOX_SH="$SCRIPT_DIR/agent-sandbox.sh"

for required in "$COMPOSE_FILE" "$SANDBOX_SH" "$SCRIPT_DIR/Dockerfile.base.claude"; do
    if [ ! -f "$required" ]; then
        echo "❌ 這個腳本必須放在 agent-sandbox repo 根目錄執行（找不到 ${required##*/}）。" >&2
        exit 1
    fi
done

# ============================================================
# 顏色 / 字符
# ============================================================
if [ -t 1 ]; then
    C_RST=$'\033[0m'; C_DIM=$'\033[2m'; C_GRN=$'\033[32m'; C_YLW=$'\033[33m'; C_RED=$'\033[31m'; C_BLU=$'\033[34m'
else
    C_RST=; C_DIM=; C_GRN=; C_YLW=; C_RED=; C_BLU=
fi
ok()   { printf '  %s[ok]%s   %s\n'   "$C_GRN" "$C_RST" "$1"; }
warn() { printf '  %s[warn]%s %s\n'   "$C_YLW" "$C_RST" "$1"; }
miss() { printf '  %s[miss]%s %s\n'   "$C_YLW" "$C_RST" "$1"; }
err()  { printf '  %s[err]%s  %s\n'   "$C_RED" "$C_RST" "$1"; }
info() { printf '  %s[info]%s %s\n'   "$C_BLU" "$C_RST" "$1"; }
hdr()  { printf '\n%s%s%s\n' "$C_DIM" "$1" "$C_RST"; }

# ============================================================
# 平台偵測
# ============================================================
OS="$(uname -s)"           # Darwin / Linux / ...
ARCH="$(uname -m)"
PKG=""                     # Linux 套件管理器
case "$OS" in
    Darwin) PLATFORM=macos ;;
    Linux)  PLATFORM=linux
            if   command -v apt-get >/dev/null 2>&1; then PKG=apt
            elif command -v dnf     >/dev/null 2>&1; then PKG=dnf
            elif command -v pacman  >/dev/null 2>&1; then PKG=pacman
            fi ;;
    *)      PLATFORM=other ;;
esac

# 取得某相依在當前平台的安裝指令（印給使用者，不執行）
install_hint() {
    case "$1:$PLATFORM" in
        podman:macos)         echo "brew install podman" ;;
        podman:linux)         case "$PKG" in apt) echo "sudo apt-get install -y podman";; dnf) echo "sudo dnf install -y podman";; pacman) echo "sudo pacman -S podman";; *) echo "（用你的套件管理器安裝 podman）";; esac ;;
        podman-compose:macos) echo "brew install podman-compose   # 或升級 podman 內建 'podman compose'" ;;
        podman-compose:linux) case "$PKG" in apt) echo "sudo apt-get install -y podman-compose";; dnf) echo "sudo dnf install -y podman-compose";; pacman) echo "sudo pacman -S podman-compose";; *) echo "（安裝 podman-compose，或升級 podman 取得內建 compose）";; esac ;;
        git:macos)            echo "brew install git   # 或安裝 Xcode Command Line Tools" ;;
        git:linux)            case "$PKG" in apt) echo "sudo apt-get install -y git";; dnf) echo "sudo dnf install -y git";; pacman) echo "sudo pacman -S git";; *) echo "（用你的套件管理器安裝 git）";; esac ;;
        *)                    echo "（請手動安裝 $1）" ;;
    esac
}

# 版本比較：ver_ge A B → A >= B ?（用 sort -V，macOS/Linux 皆有）
ver_ge() {
    [ "$1" = "$2" ] && return 0
    local lo
    lo="$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)"
    [ "$lo" = "$2" ]
}

# ============================================================
# 目標 rc 檔（agent-sandbox.sh 是 zsh 函式 → 寫進 ~/.zshrc）
# ============================================================
RC="$HOME/.zshrc"
CUR_SHELL="$(basename "${SHELL:-}")"

MARKER_BEGIN="# >>> agent-sandbox >>>"
MARKER_END="# <<< agent-sandbox <<<"

# 寫進 rc 的 source 路徑：repo 在 $HOME 底下就收斂成字面 $HOME（更可攜、
# 跨機/換 home 仍對，且由 zsh 在 source 當下展開）；不在則退回絕對路徑。
SOURCE_PATH="$SANDBOX_SH"
case "$SANDBOX_SH" in
    "$HOME"/*) SOURCE_PATH="\$HOME${SANDBOX_SH#"$HOME"}" ;;
esac

# 可選門面 agent-sandbox-claude-wrapper.sh / agent-sandbox-codex-wrapper.sh 的
# source 路徑（同樣收斂 $HOME）。是否寫進 rc 由 apply 模式逐一詢問後設
# INCLUDE_WRAPPER / INCLUDE_CODEX_WRAPPER（opt-in，預設不啟用）。
WRAPPER_SH="$SCRIPT_DIR/agent-sandbox-claude-wrapper.sh"
WRAPPER_SOURCE_PATH="$WRAPPER_SH"
case "$WRAPPER_SH" in
    "$HOME"/*) WRAPPER_SOURCE_PATH="\$HOME${WRAPPER_SH#"$HOME"}" ;;
esac
INCLUDE_WRAPPER=0

CODEX_WRAPPER_SH="$SCRIPT_DIR/agent-sandbox-codex-wrapper.sh"
CODEX_WRAPPER_SOURCE_PATH="$CODEX_WRAPPER_SH"
case "$CODEX_WRAPPER_SH" in
    "$HOME"/*) CODEX_WRAPPER_SOURCE_PATH="\$HOME${CODEX_WRAPPER_SH#"$HOME"}" ;;
esac
INCLUDE_CODEX_WRAPPER=0

render_block() {
    printf '%s\n' "$MARKER_BEGIN"
    printf '%s\n' "# 由 agent-sandbox init.sh 管理；勿手動編輯標記之間內容。"
    printf '%s\n' "# 重跑 ./init.sh --apply 可重新產生；./init.sh --uninstall 可移除。"
    printf '%s\n' "source \"$SOURCE_PATH\""
    [ "$INCLUDE_WRAPPER" = 1 ] && \
        printf '%s\n' "source \"$WRAPPER_SOURCE_PATH\"   # 可選：claude --sandbox 門面"
    [ "$INCLUDE_CODEX_WRAPPER" = 1 ] && \
        printf '%s\n' "source \"$CODEX_WRAPPER_SOURCE_PATH\"   # 可選：codex --sandbox 門面"
    printf '%s\n' "$MARKER_END"
}

rc_has_block() {
    [ -f "$RC" ] && grep -q "^${MARKER_BEGIN}$" "$RC" 2>/dev/null
}

# rc 區塊是否已啟用各門面（用於 --apply 重跑時保留既有選擇）
rc_block_has_wrapper() {
    [ -f "$RC" ] && grep -q 'agent-sandbox-claude-wrapper\.sh' "$RC" 2>/dev/null
}
rc_block_has_codex_wrapper() {
    [ -f "$RC" ] && grep -q 'agent-sandbox-codex-wrapper\.sh' "$RC" 2>/dev/null
}

# ============================================================
# 用法說明（--help 與打錯參數時都印這個，免得用背的）
# ============================================================
usage() {
    cat <<'EOF'
init.sh —— agent-sandbox 一鍵環境設定

做三件事：① 檢查相依（podman / compose provider / git / podman machine），
缺的會印出該平台安裝指令但不替你自動裝；② 建好 host 端鏡射目錄
（home/default/...，預設身分）；③ 在 ~/.zshrc 寫入 idempotent 區塊 source
agent-sandbox.sh。

用法：
  ./init.sh              純診斷（= --check）：檢查環境、不改任何東西（預設、最安全）
  ./init.sh --apply      逐項徵得同意後才動手：建鏡射目錄、寫入 ~/.zshrc 的 source 一行
  ./init.sh --uninstall  移除 ~/.zshrc 內的 agent-sandbox 區塊（先備份，只動該區塊）
  ./init.sh --help       顯示本說明

備註：
  · 直接跑（無參數）最安全，會告訴你缺什麼、下一步該下哪個指令。
  · 若回 permission denied，改用 bash ./init.sh ...（或先 chmod +x init.sh）。
  · Windows 走 WSL2，見 docs/guides/windows-setup.md。
EOF
}

# ============================================================
# 參數解析
# ============================================================
MODE=check
case "${1:-}" in
    ""|--check)  MODE=check ;;
    --apply)     MODE=apply ;;
    --uninstall) MODE=uninstall ;;
    -h|--help)   usage; exit 0 ;;
    *)
        echo "未知參數：$1" >&2
        echo >&2
        usage >&2
        exit 2 ;;
esac

# ============================================================
# UNINSTALL 模式（只動 rc 區塊；不碰鏡射目錄/憑證/image/volume）
# ============================================================
if [ "$MODE" = uninstall ]; then
    if ! rc_has_block; then
        echo "ℹ️  ${RC} 內沒有 agent-sandbox 區塊，無需移除。"
        exit 0
    fi
    echo "將從 ${RC} 移除 agent-sandbox 區塊（兩個標記之間，含標記）。"
    bak="${RC}.bak.$(date +%Y%m%d-%H%M%S)"
    cp "$RC" "$bak"
    echo "🗄  已備份 → ${bak}"
    tmp="$(mktemp)"
    awk -v b="$MARKER_BEGIN" -v e="$MARKER_END" '
        $0==b {ins=1}
        ins==0 {print}
        $0==e {ins=0}
    ' "$RC" > "$tmp"
    mv "$tmp" "$RC"
    echo "✅ 已移除。重開終端機或 source ${RC} 生效。"
    echo "ℹ️  鏡射目錄/憑證、image、volume 不在此處理（要清見 docs/guides/cleanup.md）。"
    exit 0
fi

# Windows / 不支援平台：導向 WSL2
if [ "$PLATFORM" = "other" ]; then
    echo "偵測到非 macOS/Linux 平台（${OS}）。"
    echo "Windows 請在 WSL2 內 clone 並執行本腳本，詳見 docs/guides/windows-setup.md。"
    exit 1
fi

# 收集「缺項數 / 警告數」決定 --check 離開碼
N_MISS=0
N_WARN=0

# ============================================================
# 各項檢查（純讀；回報狀態，--apply 階段再依此動手）
# ============================================================
COMPOSE_PROVIDER=""        # "plugin" | "standalone" | ""

check_platform() {
    hdr "平台"
    ok "OS: $OS ($ARCH)"
    if [ "$CUR_SHELL" = "zsh" ]; then
        ok "shell: zsh → rc 檔: $RC"
    else
        warn "目前 shell 是 ${CUR_SHELL:-未知}，但 agent-sandbox.sh 需要 zsh。仍會寫入 ${RC}；請用 zsh 開啟終端機使用。"
        N_WARN=$((N_WARN+1))
    fi
}

check_deps() {
    hdr "相依"
    # podman
    if command -v podman >/dev/null 2>&1; then
        local pv
        pv="$(podman --version 2>/dev/null | awk '{print $3}')"
        if [ -n "$pv" ] && ver_ge "$pv" "4.0"; then
            ok "podman $pv (>= 4.0)"
        else
            warn "podman ${pv:-?} 版本偏舊（建議 >= 4.0）→ 升級：$(install_hint podman)"
            N_WARN=$((N_WARN+1))
        fi
    else
        err "podman 未安裝 → 安裝：$(install_hint podman)"
        N_MISS=$((N_MISS+1))
    fi

    # compose provider
    if podman compose version >/dev/null 2>&1; then
        COMPOSE_PROVIDER=plugin
        ok "compose provider: podman compose（內建）"
    elif command -v podman-compose >/dev/null 2>&1; then
        COMPOSE_PROVIDER=standalone
        ok "compose provider: podman-compose（standalone）"
    else
        err "找不到 compose provider → 安裝：$(install_hint podman-compose)"
        N_MISS=$((N_MISS+1))
    fi

    # git（軟檢查）
    if command -v git >/dev/null 2>&1; then
        ok "git $(git --version 2>/dev/null | awk '{print $3}')"
    else
        warn "git 未安裝（非必要，但建議）→ 安裝：$(install_hint git)"
        N_WARN=$((N_WARN+1))
    fi

    # podman machine（macOS）
    if [ "$PLATFORM" = "macos" ]; then
        if command -v podman >/dev/null 2>&1; then
            if podman machine list --format '{{.Running}}' 2>/dev/null | grep -qi true; then
                ok "podman machine：執行中"
            else
                warn "podman machine 未啟動 → 修復：podman machine start（首次：podman machine init）"
                N_WARN=$((N_WARN+1))
            fi
        fi
    fi
}

# 鏡射目錄狀態（預設身分 default；其他身分見 docs/design/agent-sandbox.md
# 「B0015」，用 agent-sandbox --identity <name> 首次啟動即自動建立，本
# 腳本只處理預設身分的 bootstrap）
MIRROR_DIRS="home/default/.claude home/default/.codex home/default/.config/mise"
MIRROR_FILE="home/default/.claude.json"
check_mirror() {
    hdr "Host 鏡射目錄（相對 repo 根）"
    local d missing=0
    for d in $MIRROR_DIRS; do
        if [ -d "$SCRIPT_DIR/$d" ]; then ok "$d/"; else miss "$d/ → --apply 會建立"; missing=1; fi
    done
    if [ -e "$SCRIPT_DIR/$MIRROR_FILE" ]; then ok "$MIRROR_FILE"; else miss "$MIRROR_FILE → --apply 會建立"; missing=1; fi
    [ "$missing" = 1 ] && N_MISS=$((N_MISS+1))
    info "mise-cache volume 由 agent-sandbox 首次啟動時自動建立（不在此處理）"
    info "home/default/.gitconfig（容器 git 身分）：--apply 會從 host git 身分生成；之後是你自己的標準 git 檔（改身分直接編它或 per-repo git config --local）"
}

check_rc() {
    hdr "Shell 捷徑（${RC}）"
    if ! rc_has_block; then
        miss "尚無 agent-sandbox 區塊 → --apply 會加入 source 一行"
        N_MISS=$((N_MISS+1))
        return
    fi
    # 區塊存在還不夠：比對裡面的 source 行是否指向「目前」這個 repo
    # （搬家後舊區塊仍在，但指向舊路徑 → 要抓出來提醒 --apply 更新）
    local cur expected
    expected="source \"$SOURCE_PATH\""
    cur="$(awk -v b="$MARKER_BEGIN" -v e="$MARKER_END" '
        $0==b {ins=1; next} $0==e {ins=0} ins && /^source /{print}' "$RC" | head -n1)"
    if [ "$cur" = "$expected" ]; then
        ok "已有 agent-sandbox 區塊（指向本 repo）"
    else
        miss "區塊的 source 路徑與目前 repo 不符（可能搬過家）→ --apply 會更新"
        printf '         現有：%s\n' "${cur:-（區塊內找不到 source 行）}"
        printf '         應為：%s\n' "$expected"
        N_MISS=$((N_MISS+1))
    fi
}

check_compose() {
    hdr "Compose 檔"
    # config 需滿足 docker-compose.yaml 的 WORKSPACE_* :? 守衛 → 餵假值
    if [ -n "$COMPOSE_PROVIDER" ]; then
        local cmd
        if [ "$COMPOSE_PROVIDER" = plugin ]; then cmd="podman compose"; else cmd="podman-compose"; fi
        if WORKSPACE_DIR="$SCRIPT_DIR" WORKSPACE_NAME=__init_check__ \
            $cmd -f "$COMPOSE_FILE" config >/dev/null 2>&1; then
            ok "docker-compose.yaml 可解析"
        else
            warn "compose config 解析未通過（常見原因：podman machine 未啟動）"
            N_WARN=$((N_WARN+1))
        fi
    else
        miss "無 compose provider，略過解析檢查"
    fi
}

run_checks() {
    check_platform
    check_deps
    check_mirror
    check_rc
    check_compose
}

# ============================================================
# CHECK 模式
# ============================================================
if [ "$MODE" = check ]; then
    echo "agent-sandbox init —— 檢查模式（不會更動任何東西）"
    run_checks
    hdr "結果"
    echo "  缺項 $N_MISS · 警告 $N_WARN"
    if [ "$N_MISS" -gt 0 ]; then
        echo "  下一步：./init.sh --apply（其他模式見 ./init.sh --help）"
        exit 1
    fi
    echo "  環境已就緒。（模式一覽見 ./init.sh --help）"
    exit 0
fi

# ============================================================
# APPLY 模式
# ============================================================
echo "agent-sandbox init —— 套用模式（每項變更都會先徵詢）"
run_checks

ask() {  # ask "問題" [y] → 0=yes 1=no；第二參數給 "y" 則預設 Yes（Enter=yes），否則預設 No
    local reply def="${2:-n}"
    if [ "$def" = y ]; then printf '\n%s [Y/n] ' "$1"; else printf '\n%s [y/N] ' "$1"; fi
    read -r reply || return 1
    [ -z "$reply" ] && reply="$def"
    case "$reply" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

# --- 1. 建鏡射目錄 ---
need_mirror=0
for d in $MIRROR_DIRS; do [ -d "$SCRIPT_DIR/$d" ] || need_mirror=1; done
[ -e "$SCRIPT_DIR/$MIRROR_FILE" ] || need_mirror=1
if [ "$need_mirror" = 1 ]; then
    if ask "要建立缺少的 host 鏡射目錄（home/default/...，預設身分）嗎？"; then
        mkdir -p "$SCRIPT_DIR/home/default/.claude" "$SCRIPT_DIR/home/default/.codex" "$SCRIPT_DIR/home/default/.config/mise"
        [ -e "$SCRIPT_DIR/$MIRROR_FILE" ] || touch "$SCRIPT_DIR/$MIRROR_FILE"
        echo "✅ 已建立鏡射目錄"
    fi
fi

# --- 1b. 可選：搬入既有 ~/.claude 憑證 ---
if [ -d "$HOME/.claude" ] && [ "$HOME/.claude" != "$SCRIPT_DIR/home/default/.claude" ]; then
    if ask "偵測到既有 ~/.claude 憑證，要複製進來以維持登入嗎？"; then
        cp -R "$HOME/.claude/." "$SCRIPT_DIR/home/default/.claude/" 2>/dev/null
        [ -f "$HOME/.claude.json" ] && cp "$HOME/.claude.json" "$SCRIPT_DIR/$MIRROR_FILE"
        echo "✅ 已複製憑證"
    fi
fi

# --- 1c. 容器 git 身分檔（home/default/.gitconfig）---
# 缺檔則從 host git global 身分 seed（與 agent-sandbox 函式 _agent-sandbox-ensure-gitconfig
# 同邏輯；之後它就是你自己的標準 git 檔，永不被覆寫）。host 沒設身分就留給函式建空檔。
GITCONFIG_REL="home/default/.gitconfig"
if [ ! -e "$SCRIPT_DIR/$GITCONFIG_REL" ]; then
    g_name=$(git config --global user.name 2>/dev/null)
    g_email=$(git config --global user.email 2>/dev/null)
    if [ -n "$g_name" ] && [ -n "$g_email" ]; then
        if ask "要把 host git 身分（$g_name <$g_email>）寫入 $GITCONFIG_REL 供容器 commit 用嗎？"; then
            mkdir -p "$SCRIPT_DIR/home/default"
            printf '[user]\n\tname = %s\n\temail = %s\n' "$g_name" "$g_email" > "$SCRIPT_DIR/$GITCONFIG_REL"
            echo "✅ 已生成 $GITCONFIG_REL（之後改身分直接編它，或 per-repo git config --local）"
        fi
    else
        info "host 未設 git global user.name/email；$GITCONFIG_REL 留待 agent-sandbox 啟動時建空檔（之後可自行編輯填身分）"
    fi
fi

# --- 2. macOS podman machine（唯一的狀態變更例外，明確徵詢）---
if [ "$PLATFORM" = "macos" ] && command -v podman >/dev/null 2>&1; then
    if ! podman machine list --format '{{.Running}}' 2>/dev/null | grep -qi true; then
        if ask "podman machine 未啟動，要現在啟動嗎？（首次會先 init）"; then
            podman machine list --format '{{.Name}}' 2>/dev/null | grep -q . || podman machine init
            podman machine start
        fi
    fi
fi

# --- 2c. 可選：claude --sandbox 門面（opt-in；會以函式 shadow claude 指令名）---
# 每次 --apply 都問，但「預設＝目前狀態」→ Enter 維持現況（不誤關），明確 y/n 可兩向切換。
if [ -f "$WRAPPER_SH" ]; then
    if rc_block_has_wrapper; then
        # 目前已啟用 → 預設 Yes（Enter=保留）；明確答 n 才關閉
        if ask "保留 claude --sandbox 門面嗎？（目前已啟用；n=關閉）" y; then
            INCLUDE_WRAPPER=1
        else
            INCLUDE_WRAPPER=0
        fi
    elif ask "要啟用 claude --sandbox 門面嗎？（opt-in：claude --sandbox=沙盒，會以函式 shadow claude 指令名，非 --sandbox 透明轉發真 claude）"; then
        INCLUDE_WRAPPER=1
    fi
fi

# --- 2d. 可選：codex --sandbox 門面（opt-in；同 2c 模式，shadow codex 指令名）---
# ⚠️ 與真 codex 的 --sandbox 旗標「確定撞名但面窄」（只攔第一參數的長旗標形態），
# 取捨與逃生口見 agent-sandbox-codex-wrapper.sh 檔頭。
if [ -f "$CODEX_WRAPPER_SH" ]; then
    if rc_block_has_codex_wrapper; then
        if ask "保留 codex --sandbox 門面嗎？（目前已啟用；n=關閉）" y; then
            INCLUDE_CODEX_WRAPPER=1
        else
            INCLUDE_CODEX_WRAPPER=0
        fi
    elif ask "要啟用 codex --sandbox 門面嗎？（opt-in：codex --sandbox=沙盒（codex base），會 shadow codex 指令名；注意真 codex 自身的 --sandbox 長旗標放第一位時會被攔，詳見 wrapper 檔頭）"; then
        INCLUDE_CODEX_WRAPPER=1
    fi
fi

# --- 3. rc source 區塊（idempotent）---
new_block="$(render_block)"
if rc_has_block; then
    echo
    echo "── $RC 內已有區塊，將以下列內容取代 ──"
else
    echo
    echo "── 將附加到 $RC ──"
fi
printf '%s\n' "$C_DIM$new_block$C_RST"

if ask "要寫入 $RC 嗎？"; then
    # 備份（時間戳，重跑不覆蓋舊備份）
    if [ -f "$RC" ]; then
        bak="$RC.bak.$(date +%Y%m%d-%H%M%S)"
        cp "$RC" "$bak"
        echo "🗄  已備份 → $bak"
    fi
    tmp="$(mktemp)"
    if rc_has_block; then
        # 移除舊區塊（含兩個標記），其餘原樣保留
        awk -v b="$MARKER_BEGIN" -v e="$MARKER_END" '
            $0==b {ins=1}
            ins==0 {print}
            $0==e {ins=0}
        ' "$RC" > "$tmp"
    else
        [ -f "$RC" ] && cat "$RC" > "$tmp"
    fi
    # 附加新區塊（前綴一空行）
    printf '\n%s\n' "$new_block" >> "$tmp"
    mv "$tmp" "$RC"
    echo "✅ 已寫入 $RC"
else
    echo "（略過寫入 rc）"
fi

# ============================================================
# 收尾驗證 + 下一步
# ============================================================
hdr "完成"
echo "下一步："
echo "  1. source $RC          （或開一個新終端機）"
echo "  2. cd <你要讓 agent 作業的專案目錄>"
echo "  3. agent-sandbox --upgrade （首次先建 image；只 build 不進容器）"
echo "  4. agent-sandbox       （進容器；之後日常都這個，秒起）"
echo "  5. 容器內：claude      （第一次會給連結，在瀏覽器登入一次）"
echo
echo "文件：README.md「Quick start」· docs/guides/（遷移與清理）"
