# requires zsh
#
# agent-sandbox —— AI Agent 拋棄式容器沙盒的啟動函式 + tab 補全。
#
# 安裝：在 ~/.zshrc 加一行 `source /path/to/agent-sandbox/agent-sandbox.sh`。
#   函式會自動定位「本檔所在目錄」來找 docker-compose.yaml 與 Dockerfile，
#   無需設定任何絕對路徑環境變數（搬動 repo 後只要更新 source 那行路徑）。
#
# 用法：agent-sandbox [tag] [--upgrade] [--base <name>] [--addon <name>]... [-m <spec>]... [--identity <name>]
#   不帶參數      → 純啟動 agent-sandbox-claude:latest（run 永不 build）
#   tag（位置）   → 純啟動模式=要跑哪個 tag（不存在→報錯不 build）；
#                   --upgrade 模式=要建立的版號（省略→自動配號 minor+1）
#   --upgrade     → 唯一 build 入口：整鏈 --no-cache 重建（工具更新到當下最新），
#                   全鏈成功後打 :latest + 版號 tag（每次升級必留 rollback 快照）；
#                   只 build 不進容器；只接受 --base/--addon，搭配
#                   -m/--no-config-mounts/--identity/--launch 直接報錯（白名單）
#   --base        → 切 base variant（對應 Dockerfile.base.<name>；預設 claude）
#   --addon       → 疊加 add-on（對應 Dockerfile.addon.<name>；可重複，FROM 上一層）
#   -m/--mount    → 額外掛載 host 路徑（<host>[:<container>][:ro]，可重複）；
#                   亦可寫進 .agent-sandbox 的 [mount] 段（全域+專案累加）
#   --identity    → 切換身分資料來源（對應 home/<name>/；預設 default，不存在→
#                   報錯不自動建）。容器內身分路徑固定，只換 host 端來源。B0015
#   --new-identity → 建立新身分骨架（home/<name>/...），純建立動作、不進容器、
#                   不接受其他旗標；已存在也可執行，逐項回報狀態，冪等不覆蓋。B0046
#   設定檔        → .agent-sandbox（key = value）：專案根放 [mount]/[image]/[identity]，
#                   工具目錄放全域 [mount]；容器 git 身分改編 home/<identity>/.gitconfig
#   tab 可補完本地 image tag、Dockerfile.{base,addon}.*、home/<identity> 候選
# 最終 image：agent-sandbox-<base>[-<addon1>][-<addon2>]:<tag>
# 把 $PWD 掛到 /workspace/<basename>，保留 /workspace 乾淨可 cd .. 測試。
# 不同天用不同 compose project（按日隔離），退出時清掉孤兒 network，刻
# 意保留 volume。完整設計取捨見 docs/design/agent-sandbox.md。
#
# 注意：本檔為 zsh 函式（用到 (N) glob、compdef/zstyle、read "var?prompt"、
# 1-起算陣列等 zsh 限定語法）。下方早退守衛確保非 zsh 環境（如 bash 誤
# source）會在解析到函式本體前就提早 return、只印一行提示，不噴 parse error。

# === 早退守衛：非 zsh 直接停 ===
# 必須趁 bash 還沒讀到下方含 (N) glob 的函式定義前 return，否則 bash 會在
# 解析期就報 syntax error（runtime 守衛擋不住 parse error）。
if [ -z "${ZSH_VERSION:-}" ]; then
    echo "agent-sandbox.sh 需要 zsh 環境（請在 zsh 下 source）。" >&2
    return 1 2>/dev/null || exit 1
fi

# === 自我定位（source 當下、頂層執行一次；不可延後到函式內）===
# 函式之後會從任意 cwd 被呼叫，$0 屆時已不指向本檔，故必須在 source 當下
# 就把本檔所在目錄抓下來存成全域。see docs/design/agent-sandbox.md
#   %x = 目前正在被 source 的檔案；(%) 開 prompt 展開；:A 轉絕對+解 symlink；:h 取目錄
_AGENT_SANDBOX_DIR="${${(%):-%x}:A:h}"
_AGENT_SANDBOX_COMPOSE="$_AGENT_SANDBOX_DIR/docker-compose.yaml"

# === 私有 helpers（_agent-sandbox-*，只供 agent-sandbox() 呼叫）===
# 約定：zsh 函式是動態作用域 —— helper 直接讀寫主函式宣告的 local 變數，
# 每個 helper 頭註標明「讀：…／寫：…」（主函式的 local）。失敗一律 return 1
# 不 exit（在使用者 interactive shell 內執行）。依主函式呼叫順序排列。
# see docs/design/agent-sandbox.md「內部 helper 切分」

# --- 參數解析 ---
# 讀：$@／寫：image_tag base addons cli_mounts no_config_mounts launch upgrade
#             new_identity
# -h 印完 usage 後回傳 200（≠0 但非錯誤），主函式據此 return 0。
_agent-sandbox-parse-args() {
    while (( $# )); do
        case "$1" in
            --upgrade)
                upgrade=1; shift ;;
            --base)
                [[ -z "$2" || "$2" == -* ]] && { echo "❌ --base 需要值" >&2; return 1; }
                base="$2"; shift 2 ;;
            --addon)
                [[ -z "$2" || "$2" == -* ]] && { echo "❌ --addon 需要值" >&2; return 1; }
                addons+=("$2"); shift 2 ;;
            --identity)
                [[ -z "$2" || "$2" == -* ]] && { echo "❌ --identity 需要值" >&2; return 1; }
                identity="$2"; shift 2 ;;
            --new-identity)
                [[ -z "$2" || "$2" == -* ]] && { echo "❌ --new-identity 需要值" >&2; return 1; }
                new_identity="$2"; shift 2 ;;
            -m|--mount)
                [[ -z "$2" ]] && { echo "❌ $1 需要值（<host>[:<container>][:ro]）" >&2; return 1; }
                cli_mounts+=("$2"); shift 2 ;;
            --no-config-mounts)
                no_config_mounts=1; shift ;;
            --launch)
                launch=1; shift ;;
            -h|--help)
                cat <<'USAGE'
用法: agent-sandbox [tag] [--upgrade] [--base <name>] [--addon <name>]... [-m <spec>]... [--identity <name>] [--launch]
       agent-sandbox --new-identity <name>

  tag                  image tag（位置參數，預設 latest）。
                         純啟動模式：要跑哪個 tag —— 存在就跑、不存在報錯，
                                     永不 build（打錯字不會默默建新 image）
                         --upgrade 模式：這次快照要打的版號；省略 → 自動配號
                                     （既有 vX.Y.Z 最大者 minor+1；全無 → v1.0.0）
  --upgrade            唯一的 build 入口：整鏈 --no-cache 重建，Claude/mise/apt
                       等工具全部更新到當下最新；全鏈成功後打 :latest + 版號
                       tag（每次升級必留 rollback 快照）。只 build 不進容器
                       （進容器另打 agent-sandbox，可先確認版號資訊）。
                       rollback = agent-sandbox <舊版號>；清舊快照 = podman rmi
                       純 build 操作，只接受 --base/--addon（+ tag 當版號）；
                       搭配 -m/--no-config-mounts/--identity/--launch 一律
                       直接報錯（這些旗標對 build 沒有意義，不默默忽略）
  --base <name>        切 base variant（對應 Dockerfile.base.<name>；預設 claude）
  --addon <name>       疊加 add-on（對應 Dockerfile.addon.<name>；可重複，
                       依序 FROM 上一層）
  -m, --mount <spec>   額外掛載一條 host 路徑進容器（可多次）。
                       spec = <host>[:<container>][:ro]
                         host       host 路徑（~ 會展開；相對路徑相對 $PWD）
                         container  省略     → /workspace/<host basename>
                                    裸別名   → /workspace/<別名>（免打前綴；
                                              ro/rw 為保留字不可當別名）
                                    /開頭   → 完整絕對路徑原樣（非 /workspace
                                              會警告，可能蓋掉容器內既有檔）
                         ro         唯讀（省略 = 可讀寫）
  --no-config-mounts   本次忽略設定檔的 [mount]（全域+專案），只用 -m 給的
  --identity <name>    切換身分資料來源（對應 home/<name>/，內含 .claude／
                       .codex／.gitconfig／.config/mise／.ssh；預設 default）。
                       容器內身分路徑固定不變，只換 host 端來源；不存在的
                       identity 會報錯，不會自動建立資料夾（tab 補完可列現有
                       候選）。see docs/design/agent-sandbox.md「B0015」
  --new-identity <name>
                       建立一個新身分骨架（home/<name>/ 及其子目錄／檔案），
                       純建立動作，不進容器、不接受其他旗標（--identity/
                       --upgrade/--base/--addon/-m/--launch 一律報錯）。
                       身分已存在也可執行，逐項列出「已存在」或「新建/
                       補上」，天生冪等——可當健檢重跑，不會覆蓋既有內容。
                       建完照常 agent-sandbox --identity <name> 啟動。
                       see docs/design/agent-sandbox.md「B0046」
  --launch             進容器後自動啟動該 base 宣告的工具（claude base → claude），
                       工具退出後留在容器 bash 可續作業。base 須在其 Dockerfile
                       宣告 LABEL agent-sandbox.launch=<tool>，否則報錯。
  -h, --help           顯示本說明

最終 image：agent-sandbox-<base>[-<addon1>][-<addon2>]:<tag>

.agent-sandbox 設定檔（每行 key = value，重複 key 視為清單）：
  專案根   [mount] path = <spec>（額外掛載；inherit-global = false 可不繼承全域）
           [image] base = <name> / addon = <name>（逐專案預設；CLI 優先、addon 疊加）
           [identity] identity = <name>（逐專案預設身分；CLI 優先，單值覆蓋）
           [resource] cpus = <n> / memory = <n>g / pids = <n>（逐專案資源上限；
                      不寫＝沿用 docker-compose.yaml 的預設）
  工具目錄 [mount]（全域額外掛載；路徑須絕對/~，每個 sandbox 都會掛）
  全域 + 專案 + CLI 的 mount 全部累加。容器 git 身分改為直接編
  home/<identity>/.gitconfig（預設 identity 是 home/default/.gitconfig）。
  詳見 README。
USAGE
                return 200 ;;
            -*)
                echo "❌ 未知旗標: $1" >&2; return 1 ;;
            *)
                image_tag="$1"; shift ;;
        esac
    done
}

# --- 驗證 --upgrade 旗標白名單：只接受 --base/--addon（+位置版號）---
# 讀：upgrade identity launch no_config_mounts cli_mounts（皆主函式 local）
# 紅線：--upgrade 是純 build 操作，run/build 分家——不只「這些旗標的解析
# 結果」不該生效，連「使用者是否給了這些旗標」本身都該直接拒絕，而不是
# 靜默忽略（呼應這個專案一貫的 fail-fast 立場）。必須在
# _agent-sandbox-apply-identity-config 落定 identity（CLI／檔案／預設
# 三選一）之前呼叫，否則 identity 永遠非空、每次 --upgrade 都會誤判
# 成「有給 --identity」（B0049 起 identity 也可能來自 [identity] 段，
# 不只 CLI，但這個檢查只該擋 CLI 給的值，順序必須早於檔案值合成）。
_agent-sandbox-validate-upgrade-flags() {
    [[ -n "$upgrade" ]] || return 0
    local -a rejected=()
    [[ -n "$identity" ]] && rejected+=("--identity")
    [[ -n "$launch" ]] && rejected+=("--launch")
    (( ${#cli_mounts[@]} > 0 )) && rejected+=("-m/--mount")
    [[ -n "$no_config_mounts" ]] && rejected+=("--no-config-mounts")
    if (( ${#rejected[@]} > 0 )); then
        echo "❌ --upgrade 只接受 --base/--addon（純 build 操作，不碰 mount／identity／啟動行為）；不支援：${(j:、:)rejected}" >&2
        return 1
    fi
}

# --- 驗證 --new-identity 旗標白名單：純建立身分骨架，不接受其他旗標 ---
# 讀：new_identity identity upgrade launch no_config_mounts cli_mounts base
#     addons（皆主函式 local）
# 紅線：--new-identity 跟 --upgrade 同一種「動作型、做完就結束」旗標，
# 不該跟其他旗標混用——尤其 --identity（語意衝突：到底要建新的還是選
# 舊的）、--upgrade（兩者都是「做完就結束」，同時給沒有意義）。也不接受
# --base/--addon：身分與 image 變體正交，建身分不需要知道要跑哪個 base。
# 必須在 _agent-sandbox-apply-identity-config 落定 identity 之前呼叫，
# 否則 identity 永遠非空、每次 --new-identity 都會誤判成「有給
# --identity」（同上方 validate-upgrade-flags 的順序要求，B0049 起）。
# see docs/design/agent-sandbox.md「B0046」
_agent-sandbox-validate-new-identity-flags() {
    [[ -n "$new_identity" ]] || return 0
    local -a rejected=()
    [[ -n "$identity" ]] && rejected+=("--identity")
    [[ -n "$upgrade" ]] && rejected+=("--upgrade")
    [[ -n "$launch" ]] && rejected+=("--launch")
    (( ${#cli_mounts[@]} > 0 )) && rejected+=("-m/--mount")
    [[ -n "$no_config_mounts" ]] && rejected+=("--no-config-mounts")
    [[ -n "$base" ]] && rejected+=("--base")
    (( ${#addons[@]} > 0 )) && rejected+=("--addon")
    if (( ${#rejected[@]} > 0 )); then
        echo "❌ --new-identity 只接受身分名稱本身，是純建立動作；不支援：${(j:、:)rejected}" >&2
        return 1
    fi
}

# --- 設定檔 INI 段落讀取（通用，.agent-sandbox 兩層共用）---
# 參數：$1=檔案路徑 $2=段名；stdout 逐行輸出該段的非空非註解行（已去前導/尾端空白、
# 行內註解）。段標頭 [name] 須獨佔一行（可帶行內註解）；只取要的段 → 未知段天然
# 略過（前向相容，B0024 起）。行格式由各 caller 解析（皆為 key = value）。檔不
# 存在 → 無輸出、return 0。行內註解只認「前面有空白的 #」（避免誤傷值本身含 #
# 但無空白緊鄰的情況，如路徑）。see docs/design/agent-sandbox.md（B0048）
_agent-sandbox-config-lines() {
    local file="$1" want="$2"
    local line stripped section=""
    [[ -f "$file" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        stripped="${line#"${line%%[![:space:]]*}"}"   # 去前導空白
        stripped="${stripped%% \#*}"                    # 剝除行內註解（見上方 B0048）
        stripped="${stripped%"${stripped##*[![:space:]]}"}"   # 去尾端空白（含註解剝除後殘留）
        [[ -z "$stripped" || "$stripped" == \#* ]] && continue
        if [[ "$stripped" == \[*\] ]]; then           # [section] 標頭（須獨佔一行）
            section="${stripped#\[}"; section="${section%\]}"
            section="${section//[[:space:]]/}"
            continue
        fi
        [[ "$section" == "$want" ]] && printf '%s\n' "$stripped"
    done < "$file"
}

# --- 設定檔健檢：段落放錯層 / 已移除段 提示（純提醒，不影響解析）---
# 參數：$1=檔案 $2=scope（global|project）
# [git] 已移除（任何層都提醒改編 home/<identity>/.gitconfig）；[image]/[identity]
# 僅專案層（放全域提醒）；[mount] 兩層皆可；未知段靜默（前向相容）。標頭判斷比照
# config-lines 去尾端空白/行內註解，兩處保持一致（B0048）。see docs/design/agent-sandbox.md
_agent-sandbox-lint-config() {
    local file="$1" scope="$2"
    [[ -f "$file" ]] || return 0
    local line sec
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%% \#*}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ "$line" == \[*\] ]] || continue
        sec="${line#\[}"; sec="${sec%\]}"; sec="${sec//[[:space:]]/}"
        case "$sec" in
            git)   echo "⚠️  $file 的 [git] 段已移除：容器 git 身分改為直接編輯 home/<identity>/.gitconfig（見 docs/guides/upgrade-two-layer-config.md），本段略過" >&2 ;;
            image) [[ "$scope" == global ]] && echo "⚠️  $file 的 [image] 段僅支援專案層，已略過" >&2 ;;
            identity) [[ "$scope" == global ]] && echo "⚠️  $file 的 [identity] 段僅支援專案層，已略過（B0049）" >&2 ;;
            resource) [[ "$scope" == global ]] && echo "⚠️  $file 的 [resource] 段僅支援專案層，已略過（B0059）" >&2 ;;
        esac
    done < "$file"
}

# --- 專案 [image] 段：逐專案預設 base/addon，與 CLI 合成 ---
# 讀：base addons（CLI 原值；base 空=未指定）／寫：base addons base_from_file addons_from_file
# base：CLI --base > 檔案 base > 內建 claude（單值覆蓋）。addon：檔案 + CLI 疊加、去重保序
# （清單型一律疊加，與 mount 同則）。see docs/design/agent-sandbox.md
_agent-sandbox-apply-image-config() {
    local config_file="$PWD/.agent-sandbox"
    local -a img_lines=() file_addons=()
    local file_base="" line key val
    img_lines=(${(f)"$(_agent-sandbox-config-lines "$config_file" image)"})
    for line in "${img_lines[@]}"; do
        key="${line%%=*}"; key="${key//[[:space:]]/}"
        val="${line#*=}"
        [[ "$val" == "$line" ]] && val=""              # 無 '=' 的行
        val="${val#"${val%%[![:space:]]*}"}"; val="${val%"${val##*[![:space:]]}"}"
        case "$key" in
            base)  file_base="$val" ;;
            addon) [[ -n "$val" ]] && file_addons+=(${=val}) ;;   # 空白分隔可一行多個
            *) echo "⚠️  $config_file [image] 段未知鍵 '$key'，略過" >&2 ;;
        esac
    done
    local -a applied=()
    # base：CLI 未指定才用檔案值
    if [[ -z "$base" && -n "$file_base" ]]; then
        base="$file_base"; base_from_file=1
        applied+=("base=$base")
    fi
    # addon：檔案 + CLI 疊加（檔案在前），去重保序
    if (( ${#file_addons[@]} > 0 )); then
        addons=("${file_addons[@]}" "${addons[@]}")
        addons=("${(@u)addons}")
        addons_from_file=1
        applied+=("addon=${(j: :)file_addons}")
    fi
    (( ${#applied[@]} > 0 )) && echo "📄 讀取 $config_file（[image] 段：${(j:、:)applied}）"
    [[ -z "$base" ]] && base="claude"   # 無 CLI 且無檔案設定 → 內建預設
    return 0
}

# --- 專案 [identity] 段：逐專案預設身分，與 CLI 合成 ---
# 讀：identity（CLI 原值；空=未指定）／寫：identity identity_from_file
# 優先序：CLI --identity > 檔案 identity= > 內建 default（單值覆蓋，同 base 的合成
# 規則）。呼叫時機必須晚於 validate-upgrade-flags／validate-new-identity-flags
# （那兩個檢查只該擋 CLI 給的值，見各自頭註）；--upgrade 模式下主函式不呼叫本
# 函式（身分與純 build 操作無關）。see docs/design/agent-sandbox.md（B0049）
_agent-sandbox-apply-identity-config() {
    local config_file="$PWD/.agent-sandbox"
    local -a id_lines=()
    local file_identity="" line key val
    id_lines=(${(f)"$(_agent-sandbox-config-lines "$config_file" identity)"})
    for line in "${id_lines[@]}"; do
        key="${line%%=*}"; key="${key//[[:space:]]/}"
        val="${line#*=}"
        [[ "$val" == "$line" ]] && val=""              # 無 '=' 的行
        val="${val#"${val%%[![:space:]]*}"}"; val="${val%"${val##*[![:space:]]}"}"
        case "$key" in
            identity) file_identity="$val" ;;
            *) echo "⚠️  $config_file [identity] 段未知鍵 '$key'，略過" >&2 ;;
        esac
    done
    # identity：CLI 未指定才用檔案值（單值覆蓋，同 base）
    if [[ -z "$identity" && -n "$file_identity" ]]; then
        identity="$file_identity"; identity_from_file=1
        echo "📄 讀取 $config_file（[identity] 段：identity=$identity）"
    fi
    [[ -z "$identity" ]] && identity="default"   # 無 CLI 且無檔案設定 → 內建預設（B0015）
    return 0
}

# --- 專案 [resource] 段：逐專案資源上限，覆寫 compose 的預設值（B0059）---
# 讀：（無）／寫：res_cpus res_memory res_pids
# 專案 only、單值覆蓋（檔案值 > docker-compose.yaml 的 ${VAR:-…} 字面 fallback）。
# 三個變數初值空字串＝未設定；**本函式不得寫入任何內建預設數字** —— 預設的唯一
# 真相是 docker-compose.yaml 那三行字面值，函式端持有第二份就會 drift。
# 值一律在此 fail-fast，**不可外包給 compose provider**：podman-compose 對 cpus 的
# 垃圾值與 0 是 fail-open（`if cpus:` 為假 → --cpus 整個不下 ＝ 無限制且靜默），
# 對 pids 的 -1／0 則會忠實下成 unlimited。⚠️ 純格式比對擋不住 0（`<->` match `0`），
# 數值 > 0 的判定是獨立且必要的一步，少了它 `cpus = 0` 就是繞過
# docs/design/docker-compose.md「這幾個欄位不可拿掉」紅線的後門。
# see docs/design/agent-sandbox.md（B0059）
_agent-sandbox-apply-resource-config() {
    local config_file="$PWD/.agent-sandbox"
    local -a res_lines=() applied=()
    local line key val
    res_lines=(${(f)"$(_agent-sandbox-config-lines "$config_file" resource)"})
    for line in "${res_lines[@]}"; do
        key="${line%%=*}"; key="${key//[[:space:]]/}"
        val="${line#*=}"
        [[ "$val" == "$line" ]] && val=""              # 無 '=' 的行
        val="${val#"${val%%[![:space:]]*}"}"; val="${val%"${val##*[![:space:]]}"}"
        [[ -z "$val" ]] && continue                    # 空值＝未設定（同 base=／identity=）
        case "$key" in
            cpus)
                if [[ "$val" != <->(.<->|) ]] || (( val <= 0 )); then
                    echo "❌ [resource] cpus 值無效：'$val'（來自 $config_file [resource] 段）" >&2
                    echo "   只接受大於 0 的數，例：cpus = 4 或 cpus = 2.5" >&2
                    echo "   （0 在 compose 語意上等於「不設限制」，等同把欄位拿掉，本段不開放）" >&2
                    return 1
                fi
                res_cpus="$val"; applied+=("cpus=$val") ;;
            memory)
                val="${val:l}"                         # 大小寫皆可，內部統一小寫
                if [[ "$val" != <->[mg] ]] || (( ${val%[mg]} <= 0 )); then
                    echo "❌ [resource] memory 值無效：'$val'（來自 $config_file [resource] 段）" >&2
                    echo "   需帶單位 m 或 g（大小寫皆可，內部轉小寫），例：memory = 8g" >&2
                    echo "   不接受裸數字與 gb／gi（memory = 8 會被當成 8 bytes，故一律拒收）" >&2
                    return 1
                fi
                res_memory="$val"; applied+=("memory=$val") ;;
            pids)
                if [[ "$val" != <-> ]] || (( val <= 0 )); then
                    echo "❌ [resource] pids 值無效：'$val'（來自 $config_file [resource] 段）" >&2
                    echo "   -1／0 等於取消 process 上限、關掉 fork bomb 防線（provider 會忠實照做）；" >&2
                    echo "   要放寬請給正整數，例：pids = 1024" >&2
                    return 1
                fi
                res_pids="$val"; applied+=("pids=$val") ;;
            *) echo "⚠️  $config_file [resource] 段未知鍵 '$key'，略過" >&2 ;;
        esac
    done
    (( ${#applied[@]} > 0 )) && echo "📄 讀取 $config_file（[resource] 段：${(j:、:)applied}）"
    return 0
}

# --- 讀 docker-compose.yaml 裡 ${VAR:-預設} 的字面 fallback（B0059）---
# 預設值的唯一真相在 compose 檔，函式端不得複製一份 → 要顯示就回頭讀那個檔。
# 純文字 sed，零 provider 呼叫。$1=變數名，印出預設值（找不到則空）。
_agent-sandbox-compose-default() {
    sed -n "s/.*\${$1:-\([^}]*\)}.*/\1/p" "$_AGENT_SANDBOX_COMPOSE" 2>/dev/null | head -1
}

# --- 人類可讀容量字串 → bytes（B0059）---
# podman stats 用**十進位**單位（4.295GB ＝ 4 GiB），compose 的 `4g` 是 GiB，
# 兩者混用會讓使用者對不上數字 → 一律先轉 bytes 再統一以 GiB 呈現。
_agent-sandbox-to-bytes() {
    printf '%s' "$1" | awk '{
        v=$0; sub(/[A-Za-z]+$/,"",v);
        u=$0; sub(/^[0-9.]+/,"",u); u=tolower(u);
        m=1;
        if(u=="kb"||u=="k")m=1000; else if(u=="kib")m=1024;
        else if(u=="mb")m=1000000; else if(u=="mib")m=1048576;
        else if(u=="gb")m=1000000000; else if(u=="gib")m=1073741824;
        else if(u=="tb")m=1000000000000; else if(u=="tib")m=1099511627776;
        printf "%.0f", v*m
    }'
}

# --- bytes → GiB 字串（兩位小數）---
_agent-sandbox-gib() { awk -v b="${1:-0}" 'BEGIN{printf "%.2f", b/1073741824}'; }

# --- 設定檔的記憶體 token（4g／512m）→ bytes ---
_agent-sandbox-memtoken-bytes() {
    local t="${1:l}"
    case "$t" in
        <->g) awk -v n="${t%g}" 'BEGIN{printf "%.0f", n*1073741824}' ;;
        <->m) awk -v n="${t%m}" 'BEGIN{printf "%.0f", n*1048576}' ;;
        *)    printf '0' ;;
    esac
}

# --- 啟動資源資訊報表（B0059）---
# 讀：res_cpus res_memory res_pids proj_name／寫：無
# **一律印，含零覆寫的情況**：使用者明確要求「沒寫 [resource] 的人也要看得到預設值」，
# 而且本項的觸發事件正是「machine 給 6 顆、容器只跑得動 2 顆卻查不出原因」——這一行
# 是診斷用途，不是裝飾。此舉推翻 B0046「日常啟動維持安靜」對本區塊的適用；該紅線原文
# 即要求此類擴充需「另外評估、明確拍板」（2026-09-04 已拍板，見 B0059）。
# 呈現原則（源自 CPU 可壓縮／記憶體不可壓縮的非對稱）：記憶體看「實際用量」（上限
# 加總是常態超賣、不足以判斷），CPU 看「額度加總」（瞬時使用率是無意義的快照）。
# 上限加總只**列出並標示**、不另發警告。
# ⚠️ 所有 podman 查詢一律容錯：查不到就少印一段，**絕不阻斷啟動** —— 資訊功能不該
# 變成新的失敗模式。實測 podman info／stats 各約 0.09s，對「秒起」紅線無感。
_agent-sandbox-report-resources() {
    # --- 1) 本次生效的三個值（未覆寫者讀 compose 字面 fallback）---
    local d_cpus d_mem d_pids
    d_cpus="$(_agent-sandbox-compose-default AGENT_SANDBOX_CPUS)"
    d_mem="$(_agent-sandbox-compose-default AGENT_SANDBOX_MEMORY)"
    d_pids="$(_agent-sandbox-compose-default AGENT_SANDBOX_PIDS)"
    local eff_cpus="${res_cpus:-$d_cpus}" eff_mem="${res_memory:-$d_mem}" eff_pids="${res_pids:-$d_pids}"
    eff_cpus="${eff_cpus%.0}"      # 顯示用：compose 字面 2.0 → 2（傳給 compose 的仍是原值）
    [[ -n "$eff_cpus$eff_mem$eff_pids" ]] || return 0    # compose 讀不到就整段不印

    local mem_b; mem_b="$(_agent-sandbox-memtoken-bytes "$eff_mem")"
    local -a seg=()
    [[ -n "$eff_cpus" ]] && seg+=("CPU ${eff_cpus} 核${res_cpus:+*}")
    [[ -n "$eff_mem" ]]  && seg+=("記憶體 $(_agent-sandbox-gib "$mem_b") GiB${res_memory:+*}")
    [[ -n "$eff_pids" ]] && seg+=("PID ${eff_pids}${res_pids:+*}")
    if [[ -n "$res_cpus$res_memory$res_pids" ]]; then
        echo "⚙️  資源限制：${(j:、:)seg}   （* = 專案 [resource] 段，其餘為預設）"
    else
        echo "⚙️  資源限制：${(j:、:)seg}（皆為預設值）"
    fi

    # --- 2) machine 容量（拿不到就到此為止，只留上面那行）---
    local info_out mach_cpus mach_mem_b mach_swap_b
    info_out="$(podman info --format '{{.Host.CPUs}} {{.Host.MemTotal}} {{.Host.SwapTotal}}' 2>/dev/null)"
    [[ -n "$info_out" ]] || return 0
    read -r mach_cpus mach_mem_b mach_swap_b <<< "$info_out"
    [[ "$mach_mem_b" == <-> ]] || return 0
    local swap_note=""
    [[ "$mach_swap_b" == 0 ]] && swap_note="，無 swap"
    echo "🖥  machine ${mach_cpus} 核 / $(_agent-sandbox-gib "$mach_mem_b") GiB${swap_note}"

    # --- 3) 其他在跑的 sandbox（service label ＋ project 前綴雙重比對）---
    # service=agent 是 compose 依 docker-compose.yaml 的服務名自動貼的，別的專案若也有
    # 同名服務會被誤抓 → 再比對 project 是否為本工具目錄 basename 開頭（proj_name 去尾
    # 日期戳即該 basename）。
    local ps_out line nm proj
    local -a other=()
    ps_out="$(podman ps --filter "label=com.docker.compose.service=agent" \
        --format '{{.Names}}|{{index .Labels "com.docker.compose.project"}}' 2>/dev/null)"
    for line in ${(f)ps_out}; do
        [[ -n "$line" ]] || continue
        nm="${line%%|*}"; proj="${line#*|}"
        [[ "$proj" == "${proj_name%-*}-"* ]] || continue
        other+=("$nm")
    done

    # --- 4) 其他容器的實際用量與上限（stats 一次取兩個數字）---
    local used_b=0 cap_b=0 have_usage=1
    if (( ${#other[@]} > 0 )); then
        local stats_out u l ub lb
        stats_out="$(podman stats --no-stream --format '{{.Name}}|{{.MemUsage}}' "${other[@]}" 2>/dev/null)"
        if [[ -z "$stats_out" ]]; then
            have_usage=0
            echo "   另有 ${#other[@]} 個 sandbox 在跑（用量取得失敗，略過統計）"
        else
            echo "   另有 ${#other[@]} 個 sandbox 在跑："
            for line in ${(f)stats_out}; do
                [[ -n "$line" ]] || continue
                nm="${line%%|*}"
                u="${${line#*|}%%/*}"; u="${u//[[:space:]]/}"
                l="${${line#*|}##*/}"; l="${l//[[:space:]]/}"
                ub="$(_agent-sandbox-to-bytes "$u")"; lb="$(_agent-sandbox-to-bytes "$l")"
                used_b=$(( used_b + ub )); cap_b=$(( cap_b + lb ))
                printf '     %-34s 記憶體 %s / %s GiB\n' "$nm" \
                    "$(_agent-sandbox-gib "$ub")" "$(_agent-sandbox-gib "$lb")"
            done
        fi
    fi
    # --- 5) 加總（記憶體看實際用量；上限加總只列出＋標示，不另發警告）---
    # 只有這段與下方 6(b) 真的依賴 podman stats → 守衛只包這兩處。
    # 曾經在此處放一行 `(( have_usage )) || return 0`，但那會在 stats 失敗時
    # 連帶吞掉 6(a)（純算術、只用設定檔值與 podman info）與 CPU 額度加總（走
    # podman inspect），變成「最需要診斷的環境剛好看不到診斷」——與本函式
    # 「查不到就少印一段」的原則相反。
    if (( have_usage )); then
        local total_cap_b=$(( cap_b + mem_b )) cap_flag=""
        (( total_cap_b > mach_mem_b )) && cap_flag=" ⚠️ 超過 machine"
        echo "   記憶體：實際已用 $(_agent-sandbox-gib "$used_b") GiB ／ 上限加總 $(_agent-sandbox-gib "$cap_b") GiB（含本次 $(_agent-sandbox-gib "$total_cap_b") GiB${cap_flag}）／ machine $(_agent-sandbox-gib "$mach_mem_b") GiB"
    fi

    # CPU 額度加總需 podman inspect；拿不到就略過這行（不阻斷）
    if (( ${#other[@]} > 0 )) && [[ "$mach_cpus" == <-> ]]; then
        local ins_out nano cpu_sum=0 cpu_total
        ins_out="$(podman inspect --format '{{.HostConfig.NanoCpus}}' "${other[@]}" 2>/dev/null)"
        if [[ -n "$ins_out" ]]; then
            for nano in ${(f)ins_out}; do
                [[ "$nano" == <-> ]] && (( nano > 0 )) || continue
                cpu_sum=$(awk -v a="$cpu_sum" -v b="$nano" 'BEGIN{printf "%.4g", a + b/1000000000}')
            done
            cpu_total=$(awk -v a="$cpu_sum" -v b="${eff_cpus:-0}" 'BEGIN{printf "%.4g", a+b}')
            echo "   CPU：額度加總 ${cpu_sum} 核（含本次 ${cpu_total} 核）／ machine ${mach_cpus} 核 —— 超賣正常，全開時互相分"
        fi
    fi

    # --- 6) 兩條算術事實警告（結構上不可能誤報）---
    # (a) 單一請求本身就超過 machine 容量 → 這個容器永遠拿不到它要的量
    if (( mem_b > mach_mem_b )); then
        echo "⚠️  這台 podman machine 只有 $(_agent-sandbox-gib "$mach_mem_b") GiB，本次要的 $eff_mem 超過上限，容器拿不到。"
        echo "   請調大 podman machine，或把 [resource] 的 memory 調小。"
    fi
    if [[ "$mach_cpus" == <-> && -n "$eff_cpus" ]] && (( eff_cpus > mach_cpus )); then
        echo "⚠️  這台 podman machine 只有 ${mach_cpus} 核，本次要的 ${eff_cpus} 核超過上限，容器拿不到。"
    fi
    # (b) 現有實際用量 ＋ 本次上限 > machine（算術上界：其他維持現狀、本次用滿）
    #     依賴 stats → 取不到用量時整條跳過（不能拿 used_b=0 去算，會得出誤導值）
    if (( have_usage )); then
        local worst_b=$(( used_b + mem_b ))
        if (( mem_b <= mach_mem_b && worst_b > mach_mem_b )); then
            echo "⚠️  現有已用 $(_agent-sandbox-gib "$used_b") GiB ＋ 本次上限 $(_agent-sandbox-gib "$mem_b") GiB = $(_agent-sandbox-gib "$worst_b") GiB，超過 machine 的 $(_agent-sandbox-gib "$mach_mem_b") GiB。"
            echo "   記憶體超出時是 VM 層 OOM，會砍到哪個容器不受控（CPU 超賣只是變慢，記憶體不是）。"
        fi
    fi
    return 0
}

# --- 驗證 --base/--addon + 推導最終 image 名 ---
# 讀：base addons compose_dir base_from_file addons_from_file／寫：base_df image_name
_agent-sandbox-validate-variant() {
    local addon f
    # 值來自 .agent-sandbox 時錯誤附註來源（使用者沒打 --base 卻看到該錯會困惑）
    local base_src="" addon_src=""
    [[ -n "$base_from_file" ]] && base_src="，來自 $PWD/.agent-sandbox [image] 段"
    [[ -n "$addons_from_file" ]] && addon_src="（可能來自 $PWD/.agent-sandbox [image] 段）"
    base_df="$compose_dir/Dockerfile.base.$base"
    if [[ ! -f "$base_df" ]]; then
        echo "❌ 未知 --base: $base（找不到 $base_df$base_src）" >&2
        local -a avail
        for f in "$compose_dir"/Dockerfile.base.*(N); do
            avail+=("${${f:t}#Dockerfile.base.}")
        done
        echo "   可用 base：${avail[*]}" >&2
        return 1
    fi
    for addon in "${addons[@]}"; do
        if [[ ! -f "$compose_dir/Dockerfile.addon.$addon" ]]; then
            echo "❌ 未知 --addon: $addon（找不到 $compose_dir/Dockerfile.addon.$addon）$addon_src" >&2
            local -a avail
            for f in "$compose_dir"/Dockerfile.addon.*(N); do
                avail+=("${${f:t}#Dockerfile.addon.}")
            done
            echo "   可用 addon：${avail[*]}" >&2
            return 1
        fi
    done

    # 最終 image name：agent-sandbox-<base>[-<addon1>][-<addon2>]...
    image_name="agent-sandbox-$base"
    for addon in "${addons[@]}"; do
        image_name="${image_name}-${addon}"
    done
}

# --- 驗證 --identity：home/<identity>/ 必須已存在（fail-fast，不默默生資料夾）---
# 讀：identity compose_dir identity_from_file
# 紅線：跟 --base/--addon/tag 同一套「純 run 不默默生東西」原則——不存在的
# identity 直接報錯，不自動 mkdir（要新增身分，使用者自己先建
# home/<name>/，或至少留一個空 .gitconfig／讓下面 ensure 補齊子檔）。
# 值來自 .agent-sandbox 時錯誤附註來源（同 validate-variant 的 base_src 模式，
# 使用者沒打 --identity 卻看到這個錯會困惑，B0049）。see docs/design/agent-sandbox.md「B0015」
_agent-sandbox-validate-identity() {
    local identity_dir="$compose_dir/home/$identity" f
    local identity_src=""
    [[ -n "$identity_from_file" ]] && identity_src="，來自 $PWD/.agent-sandbox [identity] 段"
    if [[ ! -d "$identity_dir" ]]; then
        echo "❌ 未知 --identity: $identity（找不到 $identity_dir$identity_src）" >&2
        local -a avail
        for f in "$compose_dir"/home/*(N/); do
            avail+=("${f:t}")
        done
        if (( ${#avail[@]} > 0 )); then
            echo "   可用 identity：${avail[*]}" >&2
        else
            echo "   目前沒有任何 home/<name>/ 資料夾" >&2
        fi
        echo "   新增身分：mkdir -p $identity_dir 後重跑即可（子檔案會自動補齊）。" >&2
        return 1
    fi
}

# --- 淨化字串成合法的 podman/compose 命名片段 ---
# 參數：$1=原始字串；stdout 淨化後結果。
# 小寫化＋非法字元換 `-`；podman/compose 命名規則要求開頭是英數字
# （`[a-zA-Z0-9][a-zA-Z0-9_.-]*`），額外去掉淨化後殘留在開頭的 `-`／`_`
#（例：`.ssh` 先變 `-ssh` 再去頭變 `ssh`）。結果為空（原字串整個是特殊
# 字元組成，如 `...`）→ 落 `workspace` 預設值，避免組出不合法名稱。
# `proj_basename`／`proj_name` 共用同一份，避免各自 inline 一份、只改
# 一處忘了另一處。see docs/design/agent-sandbox.md（B0051）
_agent-sandbox-sanitize-name() {
    local s
    s="$(printf '%s' "$1" \
         | tr '[:upper:]' '[:lower:]' \
         | sed 's/[^a-z0-9_-]/-/g' \
         | sed 's/^[-_]*//')"
    [[ -z "$s" ]] && s="workspace"
    printf '%s' "$s"
}

# --- 額外掛載：全域 + 專案 .agent-sandbox 的 [mount] 段 + CLI -m → podman -v ---
# 讀：cli_mounts no_config_mounts proj_basename compose_dir／寫：vol_args mount_display
# 三來源累加（全域 → 專案 → CLI）；全域路徑須絕對/~（相對在全域沒有基準）；專案可
# inherit-global = false 不繼承全域；CLI --no-config-mounts 則兩個檔都不讀。spec 展開
# 與衝突檢查來源無關、共用同一段；mount_display 標來源。see docs/design/agent-sandbox.md
_agent-sandbox-collect-mounts() {
    local global_file="$compose_dir/.agent-sandbox"
    local project_file="$PWD/.agent-sandbox"
    local -a specs=() sources=()      # 平行陣列：spec 與其來源標籤
    local line key val s

    if [[ -z "$no_config_mounts" ]]; then
        # 專案 [mount]：path = <spec> 收清單；inherit-global 設旗標
        local inherit_global=1
        local -a proj_lines=() proj_specs=()
        proj_lines=(${(f)"$(_agent-sandbox-config-lines "$project_file" mount)"})
        for line in "${proj_lines[@]}"; do
            key="${line%%=*}"; key="${key//[[:space:]]/}"
            val="${line#*=}"; [[ "$val" == "$line" ]] && val=""
            val="${val#"${val%%[![:space:]]*}"}"; val="${val%"${val##*[![:space:]]}"}"
            case "$key" in
                path) [[ -n "$val" ]] && proj_specs+=("$val") ;;
                inherit-global) [[ "$val" == false || "$val" == no || "$val" == 0 ]] && inherit_global=0 ;;
                *) echo "⚠️  $project_file [mount] 段未知鍵 '$key'，略過" >&2 ;;
            esac
        done

        # 全域 [mount]：僅當不同檔（同檔已當專案讀）且專案沒關閉繼承時讀；路徑須絕對/~
        local -a glob_lines=() glob_specs=()
        if [[ "$project_file" != "$global_file" && $inherit_global -eq 1 ]]; then
            glob_lines=(${(f)"$(_agent-sandbox-config-lines "$global_file" mount)"})
            for line in "${glob_lines[@]}"; do
                key="${line%%=*}"; key="${key//[[:space:]]/}"
                val="${line#*=}"; [[ "$val" == "$line" ]] && val=""
                val="${val#"${val%%[![:space:]]*}"}"; val="${val%"${val##*[![:space:]]}"}"
                case "$key" in
                    path)
                        [[ -n "$val" ]] || continue
                        if [[ "${val%%:*}" != /* && "${val%%:*}" != \~* ]]; then
                            echo "❌ 全域 [mount] 路徑須絕對或 ~ 開頭（相對路徑在全域沒有基準）：$val" >&2
                            return 1
                        fi
                        glob_specs+=("$val") ;;
                    inherit-global) echo "⚠️  inherit-global 只在專案層有意義（全域檔此設定已略過）" >&2 ;;
                    *) echo "⚠️  $global_file [mount] 段未知鍵 '$key'，略過" >&2 ;;
                esac
            done
        fi

        # 累加順序：全域 → 專案（各自印讀取訊息，標來源）
        (( ${#glob_specs[@]} > 0 )) && echo "📄 讀取 $global_file（[mount] 段，${#glob_specs[@]} 條，全域）"
        for s in "${glob_specs[@]}"; do specs+=("$s"); sources+=("全域"); done
        (( ${#proj_specs[@]} > 0 )) && echo "📄 讀取 $project_file（[mount] 段，${#proj_specs[@]} 條，專案）"
        for s in "${proj_specs[@]}"; do specs+=("$s"); sources+=("專案"); done
    fi

    # CLI -m 最後累加
    for s in "${cli_mounts[@]}"; do specs+=("$s"); sources+=("-m"); done

    # 展開每條 spec + 衝突檢查（來源無關，共用）；mount_display 標來源
    local -a used_targets=()
    local workspace_target="/workspace/${proj_basename}"
    local i spec src host_path container_path opts rest t spec_str
    for (( i=1; i<=${#specs[@]}; i++ )); do
        spec="${specs[i]}"; src="${sources[i]}"
        host_path="${spec%%:*}"
        if [[ "$spec" == *:* ]]; then
            rest="${spec#*:}"
            container_path="${rest%%:*}"
            opts="${rest#*:}"
            [[ "$opts" == "$rest" ]] && opts=""    # 只有兩段 → 無 opts
        else
            container_path=""; opts=""
        fi
        host_path="${host_path/#\~/$HOME}"                       # ~ 展開
        [[ "$host_path" == /* ]] || host_path="$PWD/$host_path"  # 相對 → 相對 $PWD
        # container path 三分支：省略→host basename；裸名→補 /workspace/（免打前綴、
        # 免錯字）；以 / 開頭→完整絕對路徑原樣（逃生口）。裸名禁用 ro/rw（保留字）。
        if [[ -z "$container_path" ]]; then
            container_path="/workspace/${host_path:t}"
        elif [[ "$container_path" != /* ]]; then
            if [[ "$container_path" == ro || "$container_path" == rw ]]; then
                echo "❌ 額外掛載別名不能叫 '$container_path'（保留字，易與 :ro/:rw 選項混淆）。spec: $spec" >&2
                echo "   要唯讀寫 path = <host>:<別名>:ro；真要掛到 /workspace/$container_path 請寫 :/workspace/$container_path。" >&2
                return 1
            fi
            container_path="/workspace/${container_path}"
        fi
        [[ -e "$host_path" ]] || { echo "❌ 額外掛載 host 路徑不存在：$host_path（spec: $spec，來源：$src）" >&2; return 1; }
        # 衝突 1：撞 workspace 主掛載
        if [[ "$container_path" == "$workspace_target" ]]; then
            echo "❌ 額外掛載 '$spec' 的目標 $container_path 與當前 workspace 主掛載同名。" >&2
            echo "   請改用 <host>:<別名>（自動掛到 /workspace/<別名>）。" >&2
            return 1
        fi
        # 衝突 2：多條 extra mount 互撞（典型：basename 撞名）
        for t in "${used_targets[@]}"; do
            if [[ "$t" == "$container_path" ]]; then
                echo "❌ 額外掛載目標 $container_path 被多條 spec 重複佔用（最後一條：$spec，來源：$src）。" >&2
                echo "   請其中一條改用別名。" >&2
                return 1
            fi
        done
        used_targets+=("$container_path")
        spec_str="${host_path}:${container_path}"
        [[ -n "$opts" ]] && spec_str="${spec_str}:${opts}"
        vol_args+=("-v" "$spec_str")
        # 非 /workspace 底下：允許但警告。警告延後到最末 📎 清單跟著該條印，
        # 否則在這裡 echo 會被 build 的一長串輸出洗掉、進容器時看不到。
        if [[ "$container_path" != /workspace/* || "$container_path" == */../* || "$container_path" == */.. ]]; then
            mount_display+=("$spec_str   ($src)  ⚠️ 不在 /workspace 底下，可能蓋掉容器內既有檔/憑證")
        else
            mount_display+=("$spec_str   ($src)")
        fi
    done
}

# --- semver 比較：$1 > $2 → return 0（兩者皆須為 vX.Y.Z）---
# 供 --upgrade 自動配號取「既有最大版」用；純 zsh 數值比較，不依賴 sort -V
# （macOS BSD sort 的 -V 支援跨版本不一，避免多一個要驗的外部行為）。
_agent-sandbox-ver-gt() {
    local -a a b
    a=(${(s:.:)${1#v}})
    b=(${(s:.:)${2#v}})
    if (( a[1] != b[1] )); then (( a[1] > b[1] )); return; fi
    if (( a[2] != b[2] )); then (( a[2] > b[2] )); return; fi
    (( a[3] > b[3] ))
}

# --- 容器內 git 身分：確保 home/<identity>/.gitconfig 存在（缺檔才 seed，永不覆蓋）---
# 參數：$1=要套用的 identity 名稱（省略→主函式目前的 $identity，動態作用域）；
#       $2=verbose（1→逐項印「已存在/新建」狀態給 --new-identity 用；省略/0→
#       維持原本「只在真的新建時才印一行」的安靜行為，日常啟動路徑不變）。
# 紅線：podman 掛載找不到 host 來源會用 root 建 → 權限錯，故此檔必須在 run 前存在。
# 規則：缺檔 → 從 host git global 身分建（host 沒設就建空檔 + 提示）；有檔（含空檔）
# → 完全不碰。之後它就是你自己的標準 git 檔：改身分直接編它，或 per-repo
# git config --local。要「不帶身分」就讓它空著（不會被回填）。init.sh --apply 安裝時
# 做同一件事，此處是「沒跑 init / 被刪」的安全網。B0015 起套用到「目前選定的
# identity」，不寫死 node/default；B0046 起參數化＋支援 verbose，供
# --new-identity 重用同一份邏輯。see docs/design/agent-sandbox.md
_agent-sandbox-ensure-gitconfig() {
    local target_identity="${1:-$identity}" verbose="${2:-0}"
    local repo_gitconfig="$_AGENT_SANDBOX_DIR/home/$target_identity/.gitconfig"
    if [[ -e "$repo_gitconfig" ]]; then                 # 已存在（含空檔）→ 不碰
        (( verbose )) && printf '   %-13s 已存在，未變動\n' ".gitconfig"
        return 0
    fi
    local gname gemail
    gname=$(git config --global user.name 2>/dev/null)
    gemail=$(git config --global user.email 2>/dev/null)
    mkdir -p "${repo_gitconfig:h}" || { echo "❌ 無法建立 ${repo_gitconfig:h}" >&2; return 1; }
    # 回報成功訊息前先確認寫檔真的成功——不能無條件宣稱「已建立」，
    # 那會比安靜不報更糟（明確違反「不可默默做掉」：印一個假的成功
    # 訊息比什麼都不印還誤導）。
    if [[ -n "$gname" && -n "$gemail" ]]; then
        if printf '[user]\n\tname = %s\n\temail = %s\n' "$gname" "$gemail" > "$repo_gitconfig"; then
            if (( verbose )); then
                printf '   %-13s 🆕 已建立（帶入 host 身分：%s <%s>）\n' ".gitconfig" "$gname" "$gemail"
            else
                echo "📝 首次生成 home/$target_identity/.gitconfig（帶入 host 身分：$gname <$gemail>）"
            fi
        else
            echo "❌ 無法寫入 $repo_gitconfig" >&2
            return 1
        fi
    else
        if : > "$repo_gitconfig"; then   # 空檔：保證掛載來源存在（避免 podman root 建）
            if (( verbose )); then
                printf '   %-13s 🆕 已建立（空檔，host 未設 git 身分）\n' ".gitconfig"
            else
                echo "⚠️  host 未設 git global user.name/email；已建空的 home/$target_identity/.gitconfig，容器內 git commit 將無身分。"
                echo "    設好 host git config --global 後刪掉該空檔重跑可自動帶入，或直接編輯它填身分。"
            fi
        else
            echo "❌ 無法建立 $repo_gitconfig" >&2
            return 1
        fi
    fi
}

# --- 啟動前置：mise-cache volume + 容器內身分骨架
# （.claude/.codex/.config/mise/.config/gcloud/.ssh/.claude.json/.gitconfig）---
# 參數：$1=要套用的 identity 名稱（省略→主函式目前的 $identity）；
#       $2=verbose（1→逐項回報，供 --new-identity 用；省略/0→安靜，日常啟動不變）。
_agent-sandbox-ensure-prereqs() {
    local target_identity="${1:-$identity}" verbose="${2:-0}"

    # 確保 mise-cache volume 存在（compose external，不自動建；冪等）
    # see docs/design/docker-compose.md 的 mise-cache 章節
    podman volume inspect agent-sandbox-mise-cache >/dev/null 2>&1 \
        || podman volume create agent-sandbox-mise-cache >/dev/null

    # bind mount 的 host 來源目錄缺時 podman 會用 root 建 → 容器內權限錯
    # （README「主機端防錯設定」紅線）。冪等補齊 compose 掛的子目錄
    # （init.sh --apply 也建預設 identity 的部分；此處是沒跑 init／用了
    # 非預設 identity 的安全網，比照 gitconfig）。B0015 起加 .ssh；B0046 起
    # 逐項檢查存在與否（而非無條件 mkdir -p），verbose 模式下才報得出
    # 「本來就在」vs「這次新建」，日常啟動（verbose=0）不受影響；B0047 起
    # 加 .config/gcloud（gcloud addon 的登入態持久化）。
    local target_home="$_AGENT_SANDBOX_DIR/home/$target_identity"
    local -a subdirs=(.claude .codex .config/mise .config/gcloud .ssh)
    local d dpath
    for d in "${subdirs[@]}"; do
        dpath="$target_home/$d"
        if [[ -d "$dpath" ]]; then
            (( verbose )) && printf '   %-13s 已存在，未變動\n' "$d"
        elif mkdir -p "$dpath"; then
            (( verbose )) && printf '   %-13s 🆕 已建立\n' "$d"
        else
            echo "❌ 無法建立 $dpath" >&2
            return 1
        fi
    done

    # .claude.json 是「檔案」掛載（跟上面四個資料夾掛載不同）：podman 對
    # 缺失的 bind mount 來源一律自動建成資料夾，不會建成檔案——缺這個檔
    # 案的話，掛載出來的會是一個 root 擁有的空資料夾，型態就錯了，容器內
    # 任何預期讀寫 JSON 的工具會直接壞掉。之前只有 init.sh 幫 default 身
    # 分補過這個檔案，其他身分完全沒人補；比照 .gitconfig 的做法，補到
    # 這個每次啟動都跑的安全網，涵蓋所有 identity。
    # 內容須是 `{}`、不能是 touch 出來的 0 bytes：claude CLI 直接對內容
    # 做 JSON.parse()，空檔案（連 `{}` 都不是）會被判定成「損毀設定檔」
    # （`Unexpected EOF`），逼出一個「Reset with default configuration」
    # 的互動選單——這正是本專案「run 永不互動」紅線要避免的情境（B0046
    # 用 --new-identity 建全新身分、第一次真的把這個檔案交給 claude CLI
    # 讀時發現，此前 default 身分的 .claude.json 幾乎都早有真實內容，
    # 這條路徑一直沒被踩過）。
    # 用 -s（存在且非空）而非 -e（只看存在）判斷：0 bytes 對 .claude.json
    # 沒有「使用者刻意留空」這種合法語意（不像 .gitconfig 留空表示不帶
    # 身分），純粹是壞檔案，該被視同缺檔重建——這樣舊版 touch 出來的
    # 0-byte 殘留檔，下次重跑（含 --new-identity 的健檢用途）會自動修復。
    local claude_json="$target_home/.claude.json"
    if [[ -s "$claude_json" ]]; then
        (( verbose )) && printf '   %-13s 已存在，未變動\n' ".claude.json"
    else
        local claude_json_was_empty_stub=0
        [[ -e "$claude_json" ]] && claude_json_was_empty_stub=1
        if printf '{}' > "$claude_json"; then
            if (( verbose )); then
                if (( claude_json_was_empty_stub )); then
                    printf '   %-13s 🔧 修復壞檔（原為 0 bytes，非合法 JSON）\n' ".claude.json"
                else
                    printf '   %-13s 🆕 已建立\n' ".claude.json"
                fi
            fi
        else
            echo "❌ 無法建立 $claude_json" >&2
            return 1
        fi
    fi

    _agent-sandbox-ensure-gitconfig "$target_identity" "$verbose"
}

# --- --new-identity 的實際動作：建立身分骨架，逐項回報，不進容器 ---
# 參數：$1=要建立的 identity 名稱
# 紅線：不管身分本來就存在還是全新建立，所有子項（.claude/.codex/
# .config/mise/.config/gcloud/.ssh/.claude.json/.gitconfig）都要逐條列出
# 狀態，不可以有任何一步默默做掉（呼應本專案「隱形狀態必須可見」的一貫
# 紅線，見「額外掛載」章節同一種立場）。底層操作天生冪等，身分已存在時
# 重跑此指令等同一次健檢/補齊，不會覆蓋既有內容。
# see docs/design/agent-sandbox.md「B0046」「B0047」
_agent-sandbox-create-identity() {
    local target_identity="$1"
    echo "🔍 檢查身分 home/$target_identity/："
    if _agent-sandbox-ensure-prereqs "$target_identity" 1; then
        echo "✅ 身分 $target_identity 已就緒。下一步：agent-sandbox --identity $target_identity"
    else
        echo "❌ 身分 $target_identity 未完全建立成功，見上方錯誤訊息" >&2
        return 1
    fi
}

# --- Build 鏈（雙模）：run 永不 build；--upgrade 是唯一 build 入口 ---
# 讀：upgrade base base_df image_tag addons compose_dir image_name
# 寫：prev_image（純啟動模式；最終 image，供 --launch inspect 與 run）
# 純啟動：最終 image 不存在 → 報錯提示 --upgrade（不 build、無互動）——
#   打錯字的 tag 會直接報錯，不會默默建出一顆新 image（凍結不可誤穿）。
# --upgrade：定版號（build 前定案、零副作用）→ 整鏈 --no-cache 重建（先只打
#   :latest）→ 全鏈成功後才逐層 podman tag 補版號（原子性：中途失敗不留半套
#   快照、不害下次自動配號跳號）。build 完即收工，主函式不進容器。
# 仍走 raw `podman build`，不走 compose build —— compose classic builder
# 會順手把歷史 repo:tag 也指到剛 build 的 image，破壞「版號 tag 凍結」紅線。
# see docs/design/agent-sandbox.md「Tag 控制與升級（run/build 分家）」
_agent-sandbox-build-chain() {
    # 鏈中各層 repo（不含 tag）與各層 Dockerfile（含 override 偵測）
    local -a chain_repos=("agent-sandbox-$base") chain_dfs=("$base_df")
    local accumulator="$base" addon override_df
    for addon in "${addons[@]}"; do
        accumulator="${accumulator}-${addon}"
        chain_repos+=("agent-sandbox-${accumulator}")
        # override 偵測：Dockerfile.override.<base>.<addon> 存在則優先用
        override_df="$compose_dir/Dockerfile.override.${accumulator}"
        if [[ -f "$override_df" ]]; then
            chain_dfs+=("$override_df")
        else
            chain_dfs+=("$compose_dir/Dockerfile.addon.$addon")
        fi
    done

    if [[ -z "$upgrade" ]]; then
        # 純啟動：只檢查最終 image 存在
        prev_image="${image_name}:${image_tag}"
        if ! podman image exists "$prev_image"; then
            echo "❌ image 不存在：$prev_image" >&2
            echo "   請先跑 agent-sandbox --upgrade 建立/更新 image（或檢查版號拼字，tab 可補既有 tag）。" >&2
            return 1
        fi
        return 0
    fi

    # === --upgrade ===
    # 1) 定版號：位置 tag = 要建立的版號；latest（未給）→ 自動配號
    local new_ver ver_note repo t
    if [[ "$image_tag" != latest ]]; then
        new_ver="$image_tag"
        ver_note="（指定）"
    else
        # 掃整條鏈所有 repo 的 vX.Y.Z tag 取全域最大（鏈共用 tag，只看最終層
        # 會在 base repo 撞既有 tag）→ minor+1、patch 歸零；全無 → v1.0.0
        local max_ver=""
        for repo in "${chain_repos[@]}"; do
            for t in ${(f)"$(podman images "$repo" --format '{{.Tag}}' 2>/dev/null)"}; do
                [[ "$t" == v<->.<->.<-> ]] || continue
                if [[ -z "$max_ver" ]] || _agent-sandbox-ver-gt "$t" "$max_ver"; then
                    max_ver="$t"
                fi
            done
        done
        if [[ -z "$max_ver" ]]; then
            new_ver="v1.0.0"
            ver_note="（自動配號，首版）"
        else
            local -a mv=(${(s:.:)${max_ver#v}})
            new_ver="v${mv[1]}.$((mv[2]+1)).0"
            ver_note="（自動配號，前一版 $max_ver）"
        fi
    fi
    # 版號在鏈中任一 repo 已存在 → 報錯（凍結不可覆蓋；此時尚未 build，零副作用）
    for repo in "${chain_repos[@]}"; do
        if podman image exists "${repo}:${new_ver}"; then
            echo "❌ ${repo}:${new_ver} 已存在（版號快照不可覆蓋）。換個版號重跑。" >&2
            return 1
        fi
    done
    echo "🔄 升級重建（--no-cache）：${(j:、:)chain_repos}"
    echo "   （鏈由目前目錄解析：CLI > .agent-sandbox [image] 段 > 預設 claude；換目錄執行可能建到不同鏈）"
    echo "   完成後打 tag：:latest + :${new_ver}${ver_note}"

    # 2) 刷新 base 的 FROM image（如 node:22-slim；--no-cache 不會自動拉新底）
    #    離線/pull 失敗只警告不中止 —— 用本地既有的底繼續升級工具層
    local from_image
    from_image="$(awk '/^FROM /{print $2; exit}' "$base_df")"
    if [[ -n "$from_image" ]]; then
        echo "⬇️  刷新 base image：$from_image"
        podman pull "$from_image" \
            || echo "⚠️  pull $from_image 失敗（離線？），改用本地既有版本繼續" >&2
        # base 時效警告：上游停更/EOL 的表徵＝pull 回來的建立日期不再前進。
        # 活躍 tag 通常 1-2 個月內就 rebuild → 180 天門檻幾乎不誤報。只取
        # Created 前 10 碼（YYYY-MM-DD）解析 —— podman 模板輸出的時間格式
        # 有多種變體，日期前綴皆同且天級精度已夠。（原追蹤於 B0038）
        local from_created from_created_epoch age_days
        from_created="$(podman image inspect "$from_image" --format '{{.Created}}' 2>/dev/null)"
        if [[ -n "$from_created" ]] && zmodload zsh/datetime 2>/dev/null \
            && strftime -s from_created_epoch -r '%Y-%m-%d' "${from_created:0:10}" 2>/dev/null; then
            age_days=$(( (EPOCHSECONDS - from_created_epoch) / 86400 ))
            if (( age_days > 180 )); then
                echo "⚠️  $from_image 上游最後更新已是 ${age_days} 天前 —— 該版本可能已 EOL、"
                echo "    不再收到安全修補。考慮升級 base（改 ${base_df:t} 的 FROM）。"
            fi
        fi
    fi

    # 3) 整鏈 --no-cache 重建，先只打 :latest（任一層失敗 → 中止、不打版號）
    local i df layer_latest prev_latest=""
    for (( i=1; i<=${#chain_repos[@]}; i++ )); do
        df="${chain_dfs[i]}"
        layer_latest="${chain_repos[i]}:latest"
        echo "🔧 build $layer_latest …"
        if (( i == 1 )); then
            podman build --no-cache -f "$df" \
                -t "$layer_latest" \
                "$compose_dir" || return 1
        else
            podman build --no-cache -f "$df" \
                --build-arg "BASE_IMAGE=$prev_latest" \
                -t "$layer_latest" \
                "$compose_dir" || return 1
        fi
        prev_latest="$layer_latest"
    done

    # 4) 全鏈成功 → 逐層補打版號 tag（快照原子性）
    for repo in "${chain_repos[@]}"; do
        podman tag "${repo}:latest" "${repo}:${new_ver}" || return 1
    done
    echo "📌 已留版號快照：${new_ver}（rollback：agent-sandbox ${new_ver}）"
    echo "✅ 升級完成（不進容器）。進容器：agent-sandbox（latest）或 agent-sandbox ${new_ver}"
}

# --- --launch：解析進容器要自動啟動的工具 ---
# 讀：launch prev_image base／寫：run_cmd
# 從最終 image 的 LABEL 讀該 base 宣告的工具（純 label，嚴謹：沒宣告就報錯）。
# see docs/design/agent-sandbox.md「--launch」
_agent-sandbox-resolve-launch() {
    run_cmd=( agent bash )
    [[ -n "$launch" ]] || return 0
    local launch_tool
    launch_tool=$(podman image inspect "$prev_image" \
        --format '{{ index .Config.Labels "agent-sandbox.launch" }}' 2>/dev/null)
    if [[ -z "$launch_tool" || "$launch_tool" == "<no value>" ]]; then
        echo "❌ base '$base' 未宣告啟動工具；請在 Dockerfile.base.$base 加 LABEL agent-sandbox.launch=<tool>" >&2
        return 1
    fi
    # 啟動工具，工具退出後 exec 回互動 bash（容器仍在，可續作業）
    run_cmd=( agent bash -c "${launch_tool} ; exec bash" )
    echo "🚀 啟動工具：${launch_tool}（退出後留在容器 bash）"
}

# --- 退出後自動清孤兒 network（用 project label 精準匹配；刻意不清 volume）---
# 讀：proj_name（globals）_AGENT_SANDBOX_COMPOSE
# see docs/design/agent-sandbox.md「退出後的自動清理」
_agent-sandbox-cleanup-network() {
    local remaining
    remaining=$(podman ps -q \
                --filter "label=com.docker.compose.project=$proj_name" \
                | wc -l | tr -d ' ')

    if [ "$remaining" -eq 0 ]; then
        if podman network rm "${proj_name}_default" >/dev/null 2>&1; then
            echo "🧹 已移除 network: ${proj_name}_default"
            echo "ℹ️  volume 資料已保留（要清：podman compose -f <工具目錄>/docker-compose.yaml down --volumes）"
        fi
    else
        echo "ℹ️  $proj_name 還有 $remaining 個 container 在跑，network 保留"
    fi
}

# === 主函式：流程編排（細節在上方各 helper）===
agent-sandbox() {
    local image_tag="latest"
    local base=""                     # 空=CLI 未指定；與專案 [image] 段合成後落定（皆無 → claude）
    local identity=""                 # 空=CLI 未指定；與專案 [identity] 段合成後落定
                                       # （皆無 → default，B0015；B0049 起可來自設定檔）
    local new_identity=""             # --new-identity：建立身分骨架，純動作、不進容器（B0046）
    local launch=""                   # --launch：進容器自動啟動該 base 宣告的工具
    local upgrade=""                  # --upgrade：唯一 build 入口（run 永不 build）
    local no_config_mounts=""         # --no-config-mounts：本次忽略設定檔 mount
    local res_cpus="" res_memory="" res_pids=""   # 空=未覆寫；[resource] 段落定（B0059）
                                      # 刻意不放預設數字——唯一真相是 docker-compose.yaml
    local -a addons=()
    local -a cli_mounts=()            # CLI -m 的 spec（與設定檔 [mount] 累加）
    _agent-sandbox-parse-args "$@"
    case $? in
        0)   ;;
        200) return 0 ;;   # -h 已印 usage
        *)   return 1 ;;
    esac

    # 必須在 identity 落定為 default 之前檢查（見各 helper 頭註，兩者
    # 皆是「動作型旗標」的白名單，同一種順序要求）
    _agent-sandbox-validate-upgrade-flags || return 1
    _agent-sandbox-validate-new-identity-flags || return 1

    # --new-identity 在這裡就分岔掉，完全不進入後續 identity/base/addon/
    # mount/build 主線——比 --upgrade 分岔得更早（--upgrade 好歹要跑
    # validate-variant 才知道要 build 哪條鏈；--new-identity 連這步都不用，
    # 身分與 image 變體正交）。見 docs/design/agent-sandbox.md「B0046」
    if [[ -n "$new_identity" ]]; then
        _agent-sandbox-create-identity "$new_identity"
        return $?
    fi

    # compose 目錄＝本檔所在目錄（自我定位，見檔頭）
    local compose_dir="$_AGENT_SANDBOX_DIR"

    # 設定檔健檢（段落放錯層 / 已移除段）。同檔（從工具目錄自身啟動）只當專案檢，
    # 因為那份檔同時是專案檔、[image]/[identity] 在它裡面是合法的。
    local _gf="$compose_dir/.agent-sandbox" _pf="$PWD/.agent-sandbox"
    if [[ "$_pf" == "$_gf" ]]; then
        _agent-sandbox-lint-config "$_pf" project
    else
        _agent-sandbox-lint-config "$_gf" global
        _agent-sandbox-lint-config "$_pf" project
    fi

    # 專案 [image] 段：逐專案預設 base/addon（CLI 優先；來源旗標供錯誤訊息標註）
    local base_from_file="" addons_from_file=""
    _agent-sandbox-apply-image-config || return 1

    local base_df image_name
    _agent-sandbox-validate-variant || return 1

    # --upgrade 是純 build 操作、不碰 mount／identity（run/build 分家紅線）：
    # identity 落定（CLI／[identity] 段／預設三選一）與存在性驗證在這裡都無意義，
    # 略過避免擋到不相干的建置流程；identity 在 --upgrade 模式下維持空字串，
    # 反正後續 build-chain 不會讀它（B0049）
    local identity_from_file=""
    if [[ -z "$upgrade" ]]; then
        _agent-sandbox-apply-identity-config || return 1
        _agent-sandbox-validate-identity || return 1
        # 資源上限同為純 runtime 概念，與 build 無關（比照 identity 略過 --upgrade）；
        # 白名單擋得住 CLI 旗標、擋不住設定檔，略過呼叫才是真正的「build 不碰資源」
        _agent-sandbox-apply-resource-config || return 1
    fi

    local proj_basename proj_name container_name
    # 淨化過的當前目錄 basename，給 mount target 與 container_name 共用
    # （B0051：淨化邏輯收斂進 _agent-sandbox-sanitize-name，隱藏資料夾
    # 如 .ssh 淨化後開頭是 - 會讓 container 命名不合法，不能只做小寫化
    # +換字元這兩步）
    proj_basename="$(_agent-sandbox-sanitize-name "$(basename "$PWD")")"
    proj_name="$(_agent-sandbox-sanitize-name "$(basename "$compose_dir")")-$(date +%Y%m%d)"
    container_name="${proj_basename}-$(date +%H%M%S)-$$"

    # --upgrade 不碰 mount／identity（run/build 分家紅線）：collect-mounts 會讀
    # .agent-sandbox 的 [mount] 段（含專案檔，不只 CLI -m——上面的白名單只能擋
    # CLI 旗標，擋不住設定檔），略過才是真正的「build 完全不碰 mount」。
    local -a vol_args=() mount_display=()
    if [[ -z "$upgrade" ]]; then
        _agent-sandbox-collect-mounts || return 1
    fi

    # 同上：ensure-prereqs 會 mkdir home/$identity/... 並在缺檔時 seed
    # gitconfig —— 若在 --upgrade 也跑，打錯字的 --identity 會在純 build
    # 操作裡被靜默建出一個新身分資料夾（違反「未知 identity 一律
    # fail-fast、不自動建」的設計，見上方 validate-identity）。verbose
    # 明確傳 0：日常啟動維持安靜，逐項回報只在 --new-identity 開啟
    # （B0046；那條路徑走 --new-identity 的分岔，不會經過這裡）。
    if [[ -z "$upgrade" ]]; then
        _agent-sandbox-ensure-prereqs "$identity" 0 || return 1
    fi

    local prev_image
    _agent-sandbox-build-chain || return 1

    # --upgrade 是純維護操作：build + 留快照就收工，不進容器（進容器另打
    # agent-sandbox，可先用補全/podman images 確認版號）。see design「Tag 控制與升級」
    # （--launch 不可能與 --upgrade 同時非空走到這裡——上面的白名單已擋掉）
    if [[ -n "$upgrade" ]]; then
        return 0
    fi

    local -a run_cmd
    _agent-sandbox-resolve-launch || return 1

    # 身分可見性（B0015）：跟額外掛載同一個「隱形狀態必須可見」原則——身分
    # 資料夾決定容器內能碰到哪些憑證，永遠印出來，不只是非預設 identity 才印
    # （這樣「以為在用 default、其實前一個指令留了 --identity」的情境也看得出來）。
    echo "🪪 使用身分：$identity（home/$identity/）"

    # 進容器前印出實際掛了哪些額外路徑（隱形 mount 會擴大可寫範圍，務必可見）；
    # 非 /workspace 的 ⚠️ 警告就跟在對應行尾，與清單一起印在 build 之後不被洗掉
    if (( ${#mount_display[@]} > 0 )); then
        echo "📎 額外掛載："
        local md
        for md in "${mount_display[@]}"; do
            echo "   $md"
        done
    fi
    # 資源資訊（B0059）：一律印本次生效的三個上限 + machine 容量 + 其他 sandbox 的
    # 實際用量。放在 📎 之後、compose run 之前——與掛載清單同屬「進容器前把隱形狀態
    # 攤開」，且在 build 輸出之後不會被洗掉。所有 podman 查詢皆容錯、不阻斷啟動。
    _agent-sandbox-report-resources

    # AGENT_SANDBOX_USER：一律用 identity 名稱本身（零特例），讓
    # whoami／banner／PS1 精準反映目前身分（B0044 的 whoami 顯示機制在
    # 此接上；環境相依、非保證，見 docs/design/agent-sandbox.md「已知
    # 環境相依限制」，但沒有更差）。曾評估 default 特例顯示 host 使用者
    # 名稱，但那會在「identity 名稱剛好撞 host 使用者名稱」時讓兩個不同
    # 身分顯示出一樣的 banner/PS1，可視化安全網靜默失效；零特例規則
    # 簡單、可預期，且徹底不會撞。
    local sandbox_user="$identity"

    # 資源覆寫「有值才傳」＋ env -u 清掉 ambient（B0059，兩者缺一不可）：
    #   有值才傳 → 零覆寫時三個變數**根本不存在**，走 compose 檔 `${VAR:-…}` 的 unset
    #     分支，行為與引入本機制前逐字相同（AGENT_SANDBOX_HOME 是同款先例）。
    #     ⚠️ 不可改成「一律傳空字串」：podman-compose 對空的 mem_limit 是 `if mem:`
    #     為假 → -m 整個不下 ＝ 記憶體限制靜默消失。
    #   env -u → 清掉使用者 shell 裡殘留的 export，避免變成跨 session 的隱形放寬
    #     （本專案否決 CC_EXTRA_MOUNTS 的正是這個理由）。
    local -a res_env=()
    [[ -n "$res_cpus" ]]   && res_env+=(AGENT_SANDBOX_CPUS="$res_cpus")
    [[ -n "$res_memory" ]] && res_env+=(AGENT_SANDBOX_MEMORY="$res_memory")
    [[ -n "$res_pids" ]]   && res_env+=(AGENT_SANDBOX_PIDS="$res_pids")

    env -u AGENT_SANDBOX_CPUS -u AGENT_SANDBOX_MEMORY -u AGENT_SANDBOX_PIDS \
    AGENT_SANDBOX_IMAGE="${image_name}:${image_tag}" \
    UID=$(id -u) GID=$(id -g) AGENT_SANDBOX_USER="$sandbox_user" \
    AGENT_SANDBOX_IDENTITY="$identity" \
    WORKSPACE_DIR="$PWD" WORKSPACE_NAME="$proj_basename" \
    COMPOSE_PROJECT_NAME="$proj_name" \
    "${res_env[@]}" \
    podman compose -f "$_AGENT_SANDBOX_COMPOSE" run --rm \
        "${vol_args[@]}" \
        --name "$container_name" "${run_cmd[@]}"
    _agent-sandbox-cleanup-network
}

# 補全 + zstyle + alias（已過早退守衛，以下保證在 zsh 下執行）
# agent-sandbox tab 補全：`_arguments` 宣告式狀態機 —— 由它管位置、互斥、可重複，
# 拿到真正的位置感（位置 tag 給過不再推、--base 不重複、--addon/-m 可重複）。
# 旗標值用空白式（--addon openspec），不支援 = 形式 —— runtime 解析器也只吃空白式。
# 候選值來源（Dockerfile.{base,addon}.* glob、podman images 的 tag:ID size）沿用 _describe。
# 補全行為與 ID 同/異判讀、為何用 _arguments 見 docs/design/agent-sandbox.md「Tab 補全」
_agent-sandbox() {
    local compose_dir="$_AGENT_SANDBOX_DIR" state
    _arguments -S \
        '(- *)'{-h,--help}'[顯示用法]' \
        '(--base)--base[切 base variant（預設 claude）]:base:->bases' \
        '*--addon[疊加 add-on（可多次）]:addon:->addons' \
        '*'{-m,--mount}'[額外掛載 host 路徑（可多次）]:mount spec:_files' \
        '(--no-config-mounts)--no-config-mounts[本次忽略設定檔 mount，只用 -m]' \
        '(--identity)--identity[切換身分資料來源（預設 default）]:identity:->identities' \
        '(--new-identity)--new-identity[建立新身分骨架，純動作不進容器]:new identity name:' \
        '(--launch)--launch[進容器自動啟動該 base 宣告的工具]' \
        '(--upgrade)--upgrade[重建整鏈並更新工具到最新（自動留版號快照；只 build 不進容器）]' \
        '1:image tag:->tags'
    case "$state" in
        bases)
            local -a bases
            for f in "$compose_dir"/Dockerfile.base.*(N); do
                bases+=("${${f:t}#Dockerfile.base.}")
            done
            _describe 'base' bases ;;
        addons)
            local -a as
            for f in "$compose_dir"/Dockerfile.addon.*(N); do
                as+=("${${f:t}#Dockerfile.addon.}")
            done
            _describe 'addon' as ;;
        identities)
            # 候選＝home/ 底下現有的資料夾名稱（(N/) 只列目錄、找不到不報錯）
            local -a ids
            for f in "$compose_dir"/home/*(N/); do
                ids+=("${f:t}")
            done
            _describe 'identity' ids ;;
        tags)
            # 依命令列已敲的 --base/--addon ＋ 專案 [image] 段（同 runtime 合成
            # 規則）推導「最終 repo」，只列它的 tag —— 補到的 tag 保證 run 得起來。
            # 寫死 agent-sandbox-claude 會把 base-only 的版號推給帶 addon 的指令。
            local base="" base_from_file="" addons_from_file=""
            local -a addons=()
            local w prev=""
            for w in "${words[@]:1}"; do
                case "$prev" in
                    --base)  base="$w" ;;
                    --addon) addons+=("$w") ;;
                esac
                prev="$w"
            done
            _agent-sandbox-apply-image-config >/dev/null 2>&1
            local tag_repo="agent-sandbox-$base" a
            for a in "${addons[@]}"; do tag_repo="${tag_repo}-${a}"; done
            local -a tags
            tags=(${(f)"$(podman images "$tag_repo" \
                --format '{{.Tag}}:{{.ID}} {{.Size}}' 2>/dev/null \
                | grep -v '^<none>:')"})
            _describe 'image tag' tags ;;
    esac
}
compdef _agent-sandbox agent-sandbox

# 補全只開 verbose + list-grouped no；故意不自訂分組樣式（跨 zsh 版本不穩）
# see docs/design/agent-sandbox.md「Tab 補全」zstyle 段
zstyle ':completion:*:*:agent-sandbox:*' verbose yes
zstyle ':completion:*:*:agent-sandbox:*' list-grouped no

alias docker=podman
