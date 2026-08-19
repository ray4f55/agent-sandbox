# agent-sandbox shell 函式 — 設計筆記

對應檔：repo 根目錄的 [`agent-sandbox.sh`](../../agent-sandbox.sh)（`agent-sandbox()` 函式 + 補全 `_agent-sandbox`）。README 只示範如何 `source` 它。

本檔說明該函式關鍵設計取捨。修改函式前先讀本檔對應段落，避免破壞看不
見的依賴。

## 為什麼用 function 而非 alias

alias 只能塞一行，**無法在 `podman compose run --rm` 結束後接續執行**。
退出清理（移除孤兒 network）必須在 run 之後做 → 必須用 function。

→ **不要改回 alias**。呼叫方式（終端輸入 `agent-sandbox`）與 alias 完全
相同，使用體驗沒差。

## 命名與識別

三組變數各司其職，**不要混用或拿掉日期戳**：

| 變數 | 計算方式 | 用途 |
|---|---|---|
| `proj_basename` | `$PWD` 的 basename，**淨化** | mount target `/workspace/<basename>` + container name 前綴 |
| `proj_name` | `<compose 目錄 basename>-<YYYYMMDD>`，**淨化** | `COMPOSE_PROJECT_NAME`：按日隔離 + cleanup label 匹配 |
| `container_name` | `<proj_basename>-<HHMMSS>-<PID>` | 同日同專案多 session 不撞名；`--rm` 後立即釋放此名 |

**淨化規則**：共用 helper `_agent-sandbox-sanitize-name`——小寫化 +
`sed 's/[^a-z0-9_-]/-/g'`（compose project name 規範只收
`[a-z0-9_-]`），**再去掉淨化後殘留在開頭的 `-`／`_`**，結果為空則落
`workspace` 預設值。去頭這步是 B0051 補的：podman/docker 的 container
命名規則要求**開頭必須是英數字**（`[a-zA-Z0-9][a-zA-Z0-9_.-]*`），
若 `$PWD` 是隱藏資料夾（如 `.ssh`）或底線開頭資料夾（如 `_backlog`），
淨化後開頭會是 `-`／`_`，組出的 `container_name` 不合法、`run` 直接
被 daemon 拒絕。

→ **紅線**：`proj_basename`／`proj_name` 都必須呼叫這個共用 helper，
不要各自 inline 一份淨化 pipeline——B0051 的成因正是兩處各自複製了
同一段邏輯，只有其中一處後來被修過，另一處帶著舊漏洞繼續存在。

**為什麼 `proj_name` 帶日期戳**：見 docker-compose.md 的
`COMPOSE_PROJECT_NAME` 章節（network/container 按日隔離 + cleanup label
精準匹配 + 歷史除錯）。

（原追蹤於 B0051，2026-08-19 使用者 `cd` 進 `.ssh` 資料夾當 cwd 啟動時
發現、確認根因、落地並實機驗證。）

## Tag 控制與升級（run/build 分家）

**run 與 build 徹底分家**（原「latest 每啟動重建＋具名 tag 缺則 build」
模型與 SHA 覆蓋防呆，2026-07-03 由 B0035 取代）：

| 命令形態 | 函式行為 |
|---|---|
| `agent-sandbox`（= `latest`） | **純啟動**：image 在就跑；不在 → 報錯提示先 `--upgrade` |
| `agent-sandbox v1.2.0` | 純啟動該凍結快照；不在 → 報錯（**不會默默建新 image**） |
| `agent-sandbox --upgrade` | **唯一 build 入口**：整鏈 `--no-cache` 重建 → 打 `:latest` + 自動配號版號 → **收工不進容器** |
| `agent-sandbox --upgrade v2.0.0` | 同上，但版號用指定值（位置 tag 在 upgrade 模式 = 要建立的版號） |

Design intents：

1. **升級有正式入口**：Claude 等工具「裝當下最新」但被 build cache 鎖住，
   出新版不會改 Dockerfile → 舊模型永遠裝不到新版（B0035 的原始問題）。
   `--upgrade` 用 `--no-cache` 讓整鏈工具（apt/mise/Claude/addon）一次刷新，
   並先 `podman pull` base 的 `FROM` image（離線失敗只警告不中止）。pull 後
   附 **base 時效警告**：FROM image 的建立日期距今 >180 天 → 提示可能已
   EOL（上游停更的表徵就是 pull 回來的日期不再前進；Node LTS 的 EOL 是
   公開日程，如 node:22 到 2027-04-30）。純本地啟發式、不擋流程，提醒
   出現在你本來就在做升級決策的時刻。（原追蹤於 B0038。）
2. **凍結無法誤穿**：舊模型「具名 tag 缺則 build」有打錯字 footgun
   （`v1.20` 打成 `v1.2.0` → 默默用當前 Dockerfile 建一顆新 image，你以為
   在跑凍結版）。純 run fail-fast 後，凍結語意結構上不可繞過。
3. **每次升級必留 rollback 快照**：版號 tag 由 `--upgrade` 自動產生（或
   指定），取代舊互動備份提示——提示會被無腦 Enter 跳過，自動 tag 不會忘。
4. **啟動零互動、可預期**：純 run 永遠秒起、不問問題（對 `claude --sandbox`
   門面與腳本化呼叫友善）。
5. **`--upgrade` 只 build 不進容器**（純維護操作）：升級摘要與快照版號不被
   容器 session 洗掉，可先用補全/`podman images` 確認再進；分家哲學貫徹到底
   （build 完接 run 等於又混回去）；順帶可腳本化（排程預熱升級）。刻意**不做
   進/不進的旗標**——為低頻操作多立一條要記的規則不值得，升完打 `agent-sandbox`
   與日常啟動肌肉記憶相同。
6. **`--upgrade` 旗標白名單**：只接受 `--base`／`--addon`（+ 位置 tag 當版
   號）；搭配 `-m`／`--no-config-mounts`／`--identity`／`--launch` 一律
   `_agent-sandbox-validate-upgrade-flags` 直接報錯，不靜默忽略。這幾個
   旗標對純 build 操作沒有意義，早期版本讓它們默默通過（`--identity`／
   `-m` 甚至一度因為 `ensure-prereqs`／`collect-mounts` 沒有跟著在
   `--upgrade` 模式下略過而**真的產生副作用**——見「多身分」章節「檔案型
   vs 資料夾型掛載來源」附近的 regression 記錄；`--launch` 則是純粹無意
   義但曾經只印提示放行）。統一改成 fail-fast 後，同一種「打錯字/給錯
   旗標不該默默發生」的立場貫徹到底，不再有的旗標軟性忽略、有的旗標
   報錯這種不一致（原追蹤於 B0015，2026-07-24）。
7. **避免 registry 雜訊**：run 在「image 已在」狀態下執行，
   `pull_policy: missing` 既不 build 也不 pull、靜默（此紅線不變，
   見 docker-compose.md）。

### 版號：semver 自動配號 + 可指定

- **自動配號**：掃**整條鏈所有 repo**（base + 各 addon 層）符合
  `vX.Y.Z` 的 tag 取全域最大 → **minor +1、patch 歸零**；全無 → `v1.0.0`。
  全鏈取最大是因為鏈共用 tag——只看最終層會在 base repo 撞既有 tag。
  比較用純 zsh 數值比較（`_agent-sandbox-ver-gt`），不依賴 `sort -V`
  （macOS BSD sort 的 `-V` 跨版本不一）。
- **指定版號**：upgrade 模式的位置 tag = 要建立的版號（與 run 模式
  「要跑的版號」語意對稱）。格式自由（`v2.0.0-claude5` 放行），但非純
  `vX.Y.Z` 不列入日後自動配號基準。已存在於鏈中任一 repo → build 前
  報錯、零副作用（凍結不可覆蓋）。
- **語意分工約定**：minor = `--upgrade` 自動（例行工具刷新）；major =
  使用者指定（結構性大改）；patch = 保留手動微修。
- **不用日期 tag**：時間維度 `podman images` 的 CREATED 欄天然保存，
  tag 字面讓給語意；semver 也天然免同日撞名特例。
- **快照原子性**：build 全程只打 `:latest`，**全鏈成功後**才逐層
  `podman tag` 補版號——中途失敗不留半套快照、不害下次自動配號跳號
  （失敗時只有滾動的 latest 處於中間態，重跑 `--upgrade` 即收拾）。

### Dockerfile 迭代逃生口（開發本專案者）

改 Dockerfile 的快速迭代不必每次付 `--upgrade` 的 no-cache 分鐘級成本：
手動 `podman build -f Dockerfile.base.claude -t agent-sandbox-claude:latest .`
（帶 cache、秒級）即可讓下次 `agent-sandbox` 跑到新內容；改到滿意再
`--upgrade` 留正式快照。

→ **紅線**：run 路徑**永不 build、永無互動提示**；build 只進不出
`--upgrade`。舊 SHA 指紋快取（`~/.cache/agent-sandbox/*.sha`）已全數退役。
（「latest 覆蓋防呆（Dockerfile SHA 指紋）」機制原追蹤於 B0013；
2026-07-03 由 B0035 連同自動 build 一併移除，本節取而代之。遷移路徑見
`docs/guides/migrate-autobuild-to-upgrade.md`。）

## mise-cache volume ensure

`docker-compose.yaml` 把 `mise-cache` 宣告為 `external: true` → compose
不會自動建 volume。函式啟動前用：

```zsh
podman volume inspect agent-sandbox-mise-cache >/dev/null 2>&1 \
    || podman volume create agent-sandbox-mise-cache >/dev/null
```

冪等：首次 create、之後 inspect 命中秒過。

詳細為何 external：見 docker-compose.md 的 mise-cache volume 章節。

## 退出後的自動清理

`podman compose run --rm` 在 exit 當下就刪掉容器自己，但 compose 建出
來的 network 不會自動清。函式 hook 在 run 之後檢查：

```zsh
podman ps -q --filter "label=com.docker.compose.project=$proj_name" | wc -l
```

回傳 0（除了剛 `--rm` 的自己外沒別人）→ `podman network rm
${proj_name}_default`。

**靠 compose project label 精準匹配**：不會誤殺其他專案的 network。
`proj_name` 帶日期戳，所以「同日同專案」其他 session 仍會被 label match
計入 → 避免清掉還在用的 network。

**刻意只清 network、不清 volume**：未來若加新 volume（DB 資料、build
cache），預設保留資料；要清自己跑 `podman compose -f ... down --volumes`。

## 額外掛載（`-m` / `.agent-sandbox` 的 `[mount]` 段）

預設只掛當前 workspace 一條（`/workspace/<basename>`）。額外掛載讓使用者
把第二、第三條 host 路徑同框掛入，支援跨專案聯合開發、外部資料整理、共用
資源引用等「多路徑同框」情境。

### 為何走 CLI `-m` 透傳 `podman -v`（而非改 compose / 環境變數）

落地前先驗過核心假設（呼應「先驗 compose 行為再設計」紅線）：
`podman compose run -v <extra>` 會把 extra volume **疊加**在 service 既有
volumes 之上、且 `:ro` 生效（實測 mount flag 為 `virtiofs (ro,...)`，主
掛載 `/workspace/<basename>` 仍在）。假設成立 → 函式只需把解析出的
`-v` 陣列接在 `compose run --rm` 後，**完全不動 compose 檔、不動 build**。

被否決的替代：

- **改 compose 檔加 N 個預留欄**：YAML 無法動態生成 N 條 volume，只能寫死
  上限，仍需 CLI 補足 → 自擋去路。
- **環境變數 `CC_EXTRA_MOUNTS`**：多路徑分隔不好設計（空白炸含空白路徑），
  且忘了 unset 會跨 session 殘留成隱形 mount。CLI `-m` + 設定檔更顯式。
- **shell alias 取代設定檔**：評估後不採 —— 看得到的檔案比 alias 難忘記，
  多條規則塞 `.zshrc` 也會亂；且設定檔本質是「逐專案」，放專案根最自然。
- **自組 `podman run`（方案 D）**：只在「`-v` 疊加假設不成立」時才退守；
  會讓 compose 失去「容器跑起來」的單一真相地位、cleanup label 要重做。
  假設已驗證成立，未採。

### 統一設定檔 `.agent-sandbox`（分段、兩層、key=value）

持久化設定走 `.agent-sandbox`，**INI 式分段、每行 `key = value`、重複 key
視為清單**。兩個位置（對映 git 的 global/local，使用者心智零負擔）：

| 位置 | 角色 | 支援的段 |
|---|---|---|
| **工具目錄** `$_AGENT_SANDBOX_DIR/.agent-sandbox` | 全域（關於「你/你的環境」） | `[mount]` |
| **專案根** `$PWD/.agent-sandbox` | 專案（關於「這個專案需要什麼」） | `[mount]`、`[image]` |

段的歸屬語意（**不是隨意的不對稱，是 mount/image 本質不同**）：

- **`[mount]` 兩層皆可**：要掛的資料夾，可能是「你每次都想掛的個資夾」（全域）
  或「這專案要的」（專案）。全域 + 專案 + CLI `-m` **全部累加**（清單型一律疊加）。
- **`[image]` 專案 only**：「這專案要哪個 base/addon」是專案屬性、非你的偏好。
  全域預設 base/addon 暫不做（**目前只有 1 base/1 addon，零價值＝YAGNI**；
  前向相容可後加，見 B0016 關聯）。因為只有專案層，關掉只需把該行 `#` 註解掉，
  不需任何旗標 —— 這是它比 mount 簡單的地方。
- **git 身分不走設定段**：是 `home/<identity>/.gitconfig` 這個標準 git 檔
  （見下節），不是 `.agent-sandbox` 的某段。**`[git]` 已移除**（早期
  identity-mode 設計棄用）。

**為什麼這樣分（而非「任何段任一層、專案覆蓋全域」自由制）**：自由制要為每段
定義覆蓋／合併語意，反而更難記。固定歸屬 + 單一合併總則（見下）最好解釋。

**格式為何 key=value 全面統一**（而非 `[mount]` 裸 spec + 選項混排，或換 YAML）：
單一 parser 規則「切第一個 `=`、trim、按 key 分派、重複 key 累加」，沒有裸行/
sigil/保留字問題；YAML 要引入 `yq`/python 相依，違反「純 zsh、最少相依」骨幹。
代價：mount 從 `../backend` 變 `path = ../backend`（多打 `path = `，可接受）。

**合併總則（由型別決定、不可設定）**：

> **清單型（`path`、`addon`）→ 累加**（全域 + 專案 + CLI）；
> **單值型（`base`）→ 覆蓋**（CLI > 專案 > 內建 claude）。

逃生口：專案 `inherit-global = false`（丟掉全域 mount）、CLI `--no-config-mounts`
（忽略兩個檔的 mount，只用 `-m`）、`[image]` 那行 `#` 註解（不要該預設）。

**放錯層 / 已移除段**：`_agent-sandbox-lint-config` 掃段標頭——`[image]` 在全域
檔 → ⚠️ 略過；`[git]` 任何層 → ⚠️ 提示改用 `home/<identity>/.gitconfig`；未知段
一律前向相容靜默略過。**「`$PWD` == 工具目錄」**（從本 repo 自身啟動）：同一檔當
**專案檔** lint（`[image]` 在其中合法），且 mount 只讀一次（不雙掛）。

- 解析器極簡且通用（`_agent-sandbox-config-lines <file> <section>`）：追當前
  `[section]`、輸出指定段的非空非註解行；各 caller 再做 `key = value` 解析。
  段標頭 `[name]` 須獨佔一行。
- 全域 `[mount]` 路徑**須絕對/`~`**（相對路徑在全域沒有基準）→ fail-fast。

（兩層架構原追蹤於 B0033；2026-06-15 定案落地：`[git]` 段移除改回
`home/<identity>/.gitconfig`（B0015 起這個資料夾可切換，早期文字寫死
`home/node/`，命名沿革見「多身分」章節）、`[mount]` 開放全域層、格式全面
key=value。早期 identity-mode + 固定單層歸屬草案於同項討論中被取代。）

### spec 展開與來源累加

spec 值 `<host>[:<container>][:ro]`（設定檔寫成 `path = <spec>`）。三來源
（全域 `[mount]` → 專案 `[mount]` → CLI `-m`）**共用同一條展開 pipeline**：

- host 路徑三式皆可：`~` 展開、相對路徑相對 `$PWD`、絕對直接用。
  **但全域 `[mount]` 的 host 須絕對/`~`**（相對在全域沒有基準）→ fail-fast。
- container path 三分支（讓常見情境免打 `/workspace/` 前綴、免錯字）：
  - 省略 → `/workspace/<host basename>`
  - **裸名（不以 `/` 開頭）→ `/workspace/<裸名>`**；`ro`／`rw` 為保留字不可
    當裸名（fail-fast，避免與選項混淆）
  - **以 `/` 開頭 → 完整絕對路徑原樣**（逃生口，如掛工具 config 到
    `/home/agent-sandbox/...`）；非 `/workspace` 底下時印 ⚠️ **允許但警告**，不擋
- 省略 opts → 可讀寫；`:ro` 只能當第三段（`<host>:ro` 會踩到「`ro` 是裸名
  保留字」報錯，這是 grammar 取捨）。**全域/專案 mount 預設一致**（皆可讀寫、
  `:ro` 才唯讀）—— 刻意不給全域「預設 ro」特例（特例＝多一條要記的規則）。
- 累加順序：全域 → 專案 → CLI（CLI 永遠是「在檔案之上再加」，遇衝突較後報、
  方便除錯）。`📎 額外掛載：` 清單**逐條標來源**（全域/專案/-m）——可見性紅線。
- 逃生口：專案 `inherit-global = false`（不繼承全域 mount，例外專案用）；
  CLI `--no-config-mounts`（忽略兩個檔的 [mount]，只用 `-m`）。

**可攜性／版控**：專案層用**相對路徑**寫的設定檔機器無關，可 commit 隨 repo
分享給隊友（sibling 專案佈局）；全域層與用絕對／`~` 路徑者屬逐開發者本機狀態，
建議 gitignore（跨專案一勞永逸設全域 `~/.config/git/ignore`）。

### 衝突 fail-fast（不靜默 shadow）

展開每條後立即比對，在 build／run **之前**就 `return 1`：

1. 容器路徑撞 workspace 主掛載（`/workspace/<basename>`）→ 報錯要改別名
2. 多條 extra mount 容器路徑互撞（典型：不同來源 basename 相同）→ 報錯
3. host 路徑不存在 → 報錯

主掛載目標在解析前就拿得到，當保留字處理。

### 安全紅線

額外掛載**擴大容器可寫範圍**，所以：

- 啟動時必印 `📄 讀取 …/.agent-sandbox（[mount] 段…）` 與 `📎 額外掛載：…`
  清單、**逐條標來源（全域/專案/-m）** —— 隱形 mount 很危險，使用者必須看得到
  「這個容器現在能碰哪些 host 路徑、來自哪層設定」。
- **全域 `[mount]` 開放（B0024「不做全域 registry」紅線於 B0033 解除）**：
  B0024 當初拒絕全域 mount 的理由是「看不見 + 會忘記」。但啟動 `📎` 清單本就
  每次印出所有 active mount，「看不見」已不成立；加上逐條標來源、全域檔本身
  `ls -a` 看得到、以及專案 `inherit-global = false` 逃生口，殘留的「忘了我有掛」
  風險已足夠緩解。換得真實需求（「每次開發都想掛的共用資料夾」）。
  ⚠️ **代價**：全域 mount 套在**每個 sandbox**，被攻陷的專案（惡意 npm/mise
  hook）能寫到全域掛入路徑 → blast radius 比專案 mount 大。文件強烈建議全域
  mount 盡量 `:ro`；但**不在程式強制全域預設 ro**（與專案不一致＝多一條要記
  的規則，違反降認知負擔目標），由使用者自負。
- **目標非 `/workspace` 底下：允許但警告，不 hard block**。預設掛在
  `/workspace/` 命名空間（保持乾淨）；但容許絕對路徑逃生口（如掛工具 config
  到 `/home/agent-sandbox/...`），偵測到非 `/workspace`（含 `..` 逃逸）時印 ⚠️ 提醒
  「可能蓋掉容器內既有檔案/憑證」。刻意不擋 —— 進階使用者要自負其責，硬擋
  反而逼他們繞去 raw `podman run`、失去所有現成基礎建設。
- 容器以非 root（使用者 UID）跑：host 目錄權限不給該 UID 讀時容器內會
  `Permission denied`，是 host 權限問題非掛載失敗（一般自己擁有的專案夾
  不受影響）。

→ **紅線**：額外掛載一律走「解析 spec → `vol_args` → 接在 `compose run`
後」這條；不要改成動 compose 檔或自組 `podman run`，除非先重驗 `-v` 疊加
假設已不成立。

（原追蹤於 B0024；2026-06-09 驗證 `-v` 疊加假設於實機 podman/macOS 通過、
落地；2026-06-10 定案設定檔由 `.cc-mounts` 改為統一檔 `.agent-sandbox` 的
`[mount]` 段，並加裸別名 shorthand（`ro`/`rw` 保留）＋非 `/workspace` 目標
allow-but-warn；2026-06-15 由 B0033 開放全域層 `[mount]`、格式改 `path =`、加
來源標示與 `inherit-global`/`--no-config-mounts` 逃生口，「不做全域 registry」
紅線在來源可見性配套下解除。）

## 容器內 git identity（`home/<identity>/.gitconfig`：seed-if-missing 後使用者自管）

`--rm` 拋棄式容器沒有 host 的 global gitconfig。只靠 host global 身分（沒設
repo local `.git/config`）的 repo 在容器內 commit 會無身分、落入 podman fallback
（`core@...`）。函式提供一份 **global fallback 身分**在
`$AGENT_HOME/.gitconfig`（容器內路徑，B0043 起是 `/home/agent-sandbox/
.gitconfig`），host 端來源是 `home/<identity>/.gitconfig`（repo 內路徑，
**host 端資料夾名稱刻意不隨容器內部路徑改名**，理由見「身分資料與工具
安裝路徑分離」章節）——本節後續提到的 `home/<identity>/.gitconfig` 均指這個
host 端檔案，不是容器內路徑。`<identity>` 由 `--identity` 旗標決定、預設
`default`（B0015，見「多身分」章節）；本節寫的規則對每個身分資料夾各自
獨立生效，不因身分切換而互相污染。

### 設計：身分回歸標準 git 檔，不另立設定段

「容器用什麼身分」就是 `home/<identity>/.gitconfig` 這個**標準 git 檔**——使用者
照平常編 `~/.gitconfig` 的直覺改即可，**不必學任何 agent-sandbox 專屬設定**
（git 已夠普及）。規則只有一條：

> **`home/<identity>/.gitconfig` 缺檔 → 從 host `git config --global` 身分 seed
> （host 沒設就建空檔 + ⚠️ 提示）；有檔（含空檔）→ 完全不碰。**

- **改身分**：直接編 `home/<identity>/.gitconfig`（容器全域），或某 repo 用
  `git config --local`（git 原生優先序 local > global，容器內外都生效）。
- **不帶身分**：把該檔留空（空檔不會被回填——`-e` 判存在，不是 `! -s`）。
- 一處邏輯（`_agent-sandbox-ensure-gitconfig`）由**函式每次啟動**跑（安全網）；
  **`init.sh --apply`** 安裝時也做同一件事（早一步到位 + 友善訊息，但 init.sh
  只處理預設身分 `home/default/`——其他身分第一次 `agent-sandbox --identity
  <name>` 啟動時才會補齊）。兩者結果一致：缺檔才 seed、有檔不動。

### 為何不沿用草案的 `[git] identity` 模式（footgun 的更簡單修法）

B0028 seed-once（`! -s` 才寫）的問題是：它**從 host 抄一份**，使用者於是以為
「host 改了容器會跟」，但其實不會（stale footgun）。B0033 草案一度想用全域
`[git] identity = host|off|Name` 每次重生來修，但評估後**改採更簡單的路**：

- 不宣稱「會跟 host 同步」，footgun 就不存在——`home/<identity>/.gitconfig`
  就是你自己的檔，改它就改了，沒有隱藏的「真相在別處」。
- 不引入 `[git]` 段、不引入 identity 模式、不需「內容異動才重寫」的比對邏輯
  → 函式更短、心智負擔更低（與本項「降認知負擔」目標一致）。
- `off`（不帶身分）用「留空檔」表達即可，不需要一個模式關鍵字。

### 掛載來源存在性（紅線不變）

**podman 掛載找不到 host 來源會用 root 自動建 → 後續權限錯誤**（README「主機端
防錯設定」載明）。所以 `.gitconfig` 必須在 `compose run` 前存在。`ensure-gitconfig`
「缺檔必建（含空檔）」滿足這條 —— 改這段邏輯時必須保持「函式跑完、檔案必存在」。
（用 `-e`「存在就不碰」而非 `! -s`「空也重建」：後者會把使用者**刻意留空**的
「不帶身分」狀態在 host 有身分時又回填，違反使用者意圖。）

### 為何受控鏡射檔 + seed（而非整檔 mount host）

- **不整檔 mount host `~/.gitconfig`**：會連 GPG 簽章（指向 host 金鑰路徑）、
  alias（依賴 host-only 工具）、credential helper、`includeIf` host 路徑等一起
  帶進容器 → 行為怪異。seed 出來的檔**只帶 `user.name`/`user.email`**，內容透明，
  且之後是你自己的檔，要加什麼自便。
- **不走 env var**（`GIT_AUTHOR_*`/`GIT_COMMITTER_*`）：要寫對 4 個、少一組就
  出怪事，且容器內 `git config --get user.name` 仍回空（部分工具會誤判）。
- 與既有 `.claude`/`.config/mise` 鏡射 pattern 同質，學習成本零。

### 範圍邊界

seed 只帶 `user.name`/`user.email`。**不**做：GPG signing（另議）、繼承 host 的
alias/credential helper（你要的話自己編進那個檔）。**「啟動時多身分切換」本身
已由 B0015 的 `--identity` 旗標實現**（見「多身分」章節）——每個 `home/<identity>/`
各自一份獨立 `.gitconfig`，切身分就自動切 git 身分，不需要額外的 `[git]` 設定段。

> 與 [[feedback-git-vs-claude-identity]] 的區別：那條是 **host 端對 agent-sandbox
> repo 自身**設 local 身分（瑞凡）；本段是**容器內**該用什麼身分，範圍不同。

（原追蹤於 B0028，2026-06-10 採 seed-once 落地；2026-06-15 由 B0033 定案：
保留 seed-if-missing（改用 `-e`）、移除草案中的 `[git]` identity 模式，身分回歸
標準 git 檔。舊機制/草案使用者見 `docs/guides/upgrade-two-layer-config.md`。
2026-07-23 由 B0015 起路徑改參數化為 `home/<identity>/.gitconfig`，預設身分
資料夾由 `node` 更名 `default`，多身分切換能力落地——見「多身分」章節。）

## 容器內 runtime UID 身分（entrypoint 動態補 `/etc/passwd`）

對應檔：[`entrypoint.sh`](../../entrypoint.sh)（兩個 base 共用，
`Dockerfile.base.*` 的 `ENTRYPOINT` 指向它）。

### 問題：幽靈使用者讓 ssh／git-over-ssh 直接崩潰

容器以裸 `user: "${UID}:${GID}"`（host 使用者的真實 UID:GID）跑，
`/etc/passwd` 沒有對應這個 UID 的紀錄（「幽靈使用者」）。多數工具靠
compose 強制的 `HOME=$AGENT_HOME`（`/home/agent-sandbox`）環境變數繞過
查表需求，但 `ssh` 決定
連線帳號時會呼叫 `getpwuid()` 查 `/etc/passwd`，查不到**直接拒絕
執行**（`No user exists for uid`），不是優雅降級；`git` 走 SSH
transport（`git@host:...`）底層也呼叫 `ssh`，同樣中招。

### 解法：entrypoint 動態補紀錄，不是 build time 猜一個固定帳號

`entrypoint.sh` 在容器啟動當下（`ENTRYPOINT`，保證先於任何指令執行）
檢查 `id -un`，查不到才補一筆 `/etc/passwd`／`/etc/group` 紀錄。**必須
是動態、不能是 build time 建的固定帳號**：runtime UID 來自 host 真實
UID，不同開發者/機器不同，固定帳號只在剛好撞到那個 UID 時有效。

- **必須用 `ENTRYPOINT`，不能塞進 `.bashrc`**：`.bashrc` 只對互動式
  bash 生效，`--launch` 模式的 `bash -c '<tool>; exec bash'` 外層是
  非互動式，工具若搶在互動 bash 之前呼叫 ssh 會漏補。`ENTRYPOINT`
  保證是容器最先執行的進程，`exec "$@"` 接手後才輪到原本要跑的指令。
- **腳本放 `/usr/local/bin`、不放家目錄**：不在 `chmod -R 777
  $AGENT_HOME` 範圍內、不會被任何身分／profile 的 bind mount 碰到，
  runtime 唯讀，容器內被攻陷的 plugin/hook 沒辦法竄改它。
- **`chmod 666 /etc/passwd /etc/group`（world-writable），不是
  OpenShift 慣例的 `chmod g=u`**：`g=u` 要搭配「容器永遠是 GID 0」
  這個 OpenShift 專屬慣例才有意義，本專案 GID 是 host 真實 GID、非
  固定 0，`g=u` 不生效。world-writable 之所以安全：`/etc/passwd`
  不是核心權限邊界，只是查表用的文字檔，核心永遠只認數字 UID/GID；
  唯一理論攻擊面（SUID 二進位查表被誤導）已被既有 `cap_drop: ALL` +
  `no-new-privileges` 堵死。
- **密碼欄用 `*` 不用 `x`**：這帳號本來就不打算給任何人用密碼登入，
  `*` 明確表達「無法用密碼登入」，不依賴（也不存在的）`/etc/shadow`
  紀錄。
- **`AGENT_SANDBOX_USER`**：由 `agent-sandbox.sh` 呼叫 compose 時傳入
  （B0015 起一律等於目前 `--identity` 名稱本身，見「多身分」章節），
  可被覆寫；只影響 `whoami`／`ssh` 未指定帳號時的預設猜測，跟核心 bug
  修復無關（那個只要紀錄存在就解了）。
- **`pw_dir`（家目錄欄位）刻意設成 `${HOME}`，不是從使用者名稱推導**：
  容器內幾乎所有工具認的是 `$HOME` 環境變數，不是 passwd 的 `pw_dir`
  欄位；兩者不一致（如使用者名稱 `ray`、家目錄仍是 `$AGENT_HOME`）完全
  無害，這在 Unix 上本來就合法常見。

→ **紅線**：改這段邏輯要保持「entrypoint、非 bashrc」「world-writable
非 GID 0 慣例」「腳本在 `/usr/local/bin` 非家目錄」三個結構性選擇；
`AGENT_SANDBOX_USER`／`pw_dir` 只是錦上添花，可以調整但不影響核心
正確性。

### 已知環境相依限制：macOS podman machine 會自己搶先補一筆

`podman --userns=keep-id`（2.0.5 起）有個副作用：runtime UID 沒有
passwd 紀錄時，podman **自己**會補一筆——家目錄欄位抓 `--workdir`
（本專案是 `working_dir: /workspace/${WORKSPACE_NAME}`），**不是**
`$HOME`；這是 podman 已知、被社群提過 issue 的既定行為
（[containers/podman#13185](https://github.com/containers/podman/issues/13185)，
2022 已用 `--passwd-entry` 旗標提供客製化選項，但那是 `podman run`
專屬旗標、標準 compose schema 沒有管道透傳，此路不通，見下）。

本專案 compose 沒有顯式開 `userns_mode: keep-id`（該行註解掉）。
**已用三組對照實驗查證觸發源頭**（2026-07-21，非推測）：

1. **繞過 compose、繞過本專案自己的 entrypoint、也不下任何 `--userns`
   旗標**，純 `podman run --user "$(id -u):$(id -g)" --entrypoint ""`
   直接測——**podman 依然自己補了紀錄**。→ 排除 compose provider、
   排除本專案的 entrypoint，問題出在 podman／podman machine 本身。
2. **在 compose 明確寫 `userns_mode: "private"`（刻意跟 keep-id 唱
   反調）** → podman 直接報錯「must provide at least one UID or GID
   mapping」，不是預期中的「變回幽靈使用者」。→ 代表「明確講
   `private`」跟「完全不講 `userns_mode`」在這個 compose provider 的
   轉譯路徑上走的是**不同程式碼路徑**：不講的時候 podman 用它自己的
   聰明預設值（就是實驗 1 驗到的 keep-id 等效行為）；明確講反而要求
   你自己把細節填完整。
3. **`podman machine ssh` 進 VM 直接查 `core` 帳號的 subuid/subgid
   配額**（`100000:1000000`）——容器裡實際看到的 UID 是 `501`（直接
   對應 host 真實 UID），**沒有落在這個配額偏移範圍內**，證實明確給
   的 `--user` 完全跳過一般 rootless 的 subuid 偏移映射、直接 1:1
   映射進去，這正是 keep-id 在做的事。

**結論**：這是 **podman 本身（至少此版本 + podman machine 的 libkrun
後端）的既定行為**——只要明確給 `--user <uid>:<gid>` 而該 UID 在
`/etc/passwd` 查無紀錄，podman 就自動視為「你顯然想要這個 UID 對應
host 同一個 UID」，套用 keep-id 等效映射並補紀錄，**完全不需要顯式
`--userns=keep-id` 旗標**。家目錄欄位抓的是有效的 `--workdir`
（本專案是 `working_dir: /workspace/${WORKSPACE_NAME}`），不是
`$HOME`——這與 podman 官方文件裡 `keep-id` 模式的既有記載
（[containers/podman#13185](https://github.com/containers/podman/issues/13185)，
2022 已提供 `--passwd-entry` 旗標可客製化，但那是 `podman run` 專屬
旗標、標準 compose schema 沒有管道透傳，此路不通）一致，只是連
`keep-id` 都不用明講。

**實測現象**：macOS + podman machine 上，容器內 `whoami` 顯示的是
podman 自己選的名字（Fedora CoreOS VM 的預設帳號 `core`），不是
`AGENT_SANDBOX_USER`；`entrypoint.sh` 的 `if ! id -un ...` 判斷式正確
偵測到已有紀錄、不出手，核心目標（ssh／git-over-ssh 不崩潰）依然
達成，只是「客製化使用者名稱」這個附加價值在這類環境不生效。

**刻意不做**：不把判斷式改成「不管有沒有既有紀錄都強制覆寫」——podman
自己補的紀錄可能有它自己的內部用途，貿然覆寫同一個 UID 的紀錄有未知
連鎖風險；「有就不動、沒有才補」的保守做法讓核心目標在兩種情境下都
達成，代價只是次要功能變成環境相依，判斷此取捨划算。

→ **影響評估提醒**：日後若想用 `AGENT_SANDBOX_USER` 做身分可視化
（例如讓 `whoami` 顯示目前 profile 名稱），**不能假設它在所有環境都
生效**——至少 macOS podman machine 這個組合會被 podman 自己的紀錄
蓋過。需要保證生效的可視化需求應另尋不受此限制影響的手段（如啟動
banner）。

### 為什麼這個修正不因 podman 自帶而多餘：Docker 完全沒有這個機制

已查證 **Docker 不會自動補 `/etc/passwd` 紀錄**——`docker run --user
1000` 只會直接把容器跑在 UID 1000，查無紀錄就是查無紀錄，沒有任何
自動補救；Docker 的 `userns-remap`（概念上對應 podman 的命名空間機制）
也預設關閉，多數安裝根本沒開。這與 podman rootless 架構（無特權常駐
daemon，本來就需要處理命名空間映射，順便做了這個補紀錄的便利功能）
是不同世代的設計。

這也解釋了為什麼 OpenShift 官方「arbitrary UID」支援指引、
`nss_wrapper`、Jupyter docker-stacks 的 entrypoint 補丁模式（本項最初
設計即參考這些）會存在——**它們都是為了解決 Docker／一般 OCI runtime
從不自動處理這件事而生的**，這些工具的存在本身就是「不能指望容器引擎
自動幫你解決」最直接的佐證。

**本項修正即使在「podman 自己就會處理」的環境下也不算白做**：
1. **换成 Docker（或任何沒有這個智慧預設值的 OCI runtime）時是唯一解**，
   不是備援。
2. **無法確認這個智慧預設值在所有 podman 版本／後端都一致**——只驗證
   過這台機器（macOS + podman machine + libkrun）；這是未經明文承諾
   的實作細節，非正式 API 合約，理論上未來版本可能改變判斷邏輯。
3. `entrypoint.sh` 的判斷式是 idempotent 的，維持它零成本，podman 自己
   處理時完全不出手、不衝突。

（原追蹤於 B0044，2026-07-21 落地、實機驗證、三組對照實驗定位觸發源頭。）

## 容器內 SSH client 找錯 `~/.ssh` 路徑（系統層級 ssh_config，B0050）

對應檔：`entrypoint.sh`（`/etc/ssh/ssh_config` 動態產生區塊）、
`Dockerfile.base.*` 的 `RUN chmod 666 /etc/passwd /etc/group
/etc/ssh/ssh_config`。

### 問題：上一節「已知環境相依限制」原本沒預料到的具體後果

上一節記載的 podman/macOS 限制（podman 搶先補的 passwd 紀錄 `pw_dir`
指向 `--workdir` 而非 `$HOME`）原本只評估影響 `whoami`／身分可視化。
實機驗證發現真正後果更嚴重：**OpenSSH client 對 `~/.ssh/id_*`、
`~/.ssh/known_hosts`，甚至它自己找 `~/.ssh/config` 這個內建預設行為，
走的都是 `getpwuid()` 的 `pw_dir`，不是 `$HOME` 環境變數**。`pw_dir`
錯了，SSH 就會去 `/workspace/<專案>/.ssh/` 找——不只找不到金鑰、退回
密碼登入，還會把新學到的 host key 意外寫進使用者的專案 workspace
（實測過寫出 `<專案>/.ssh/known_hosts`）。`gcloud compute ssh` 不受
影響（Python 的 `~` 展開走 `$HOME` 環境變數，不同機制）。

### 解法：系統層級 `/etc/ssh/ssh_config`，動態掃描身分 `.ssh/` 資料夾

`entrypoint.sh` 每次容器啟動動態產生一段 `Host *`：

- **動態掃描 `${HOME}/.ssh/` 內所有檔案生成 `IdentityFile`**（排除
  `.pub`／`known_hosts`／`known_hosts2`／`config`／`authorized_keys`），
  不寫死固定檔名——使用者的金鑰可能自訂命名（不在 SSH 內建那七個
  預設檔名之列），寫死清單解決不了這個情境。
- **`Include ${HOME}/.ssh/config`**（僅檔案存在才加）：讓使用者自己
  在身分資料夾寫的個人化 `Host` 別名設定（`HostName`／`Port`／`User`
  捷徑）也能在容器內生效——SSH 自己找 `~/.ssh/config` 這個內建行為
  同樣中招，不能只靠使用者自己建檔就會被讀到。
- **`UserKnownHostsFile ${HOME}/.ssh/known_hosts ${HOME}/.ssh/known_hosts2`**：
  修正 host key 學習位置，對應原始症狀（意外寫進專案 workspace）的
  直接修正。

**為何不修 `/etc/passwd` 的 `pw_dir`（而是繞道系統層級 ssh_config）**：
上一節已明確決定「podman 補的既有紀錄不覆寫」（未知連鎖風險），本次
不重新翻案這個決策——`/etc/ssh/ssh_config` 用絕對路徑寫死，完全不經過
`~` 展開，不管 `pw_dir` 對不對都恆定生效，改動侷限、風險最小。

**寫入權限**：`entrypoint.sh` 以非 root UID 執行，`/etc/ssh/ssh_config`
預設 root 擁有——沿用上一節同一行 `RUN chmod 666 /etc/passwd
/etc/group`，一併加上 `/etc/ssh/ssh_config`（同一套已評估過的安全
論證：`cap_drop: ALL` + `no-new-privileges` 已堵死唯一理論提權路徑）。

**使用者自己 config 檔裡的路徑仍要用絕對路徑**：`Include` 只解決「這
個檔案找不找得到」，檔案**內容**裡如果寫 `IdentityFile ~/.ssh/xxx`，
這個 `~` 在被實際使用的當下仍會重新觸發同一個展開機制、同樣找錯地方
——`Include` 不會連帶修好使用者自己寫的相對路徑，這點無法從系統層級
根治，只能靠文件／README 提醒。

→ **紅線**：改這段邏輯要保持「不碰 `/etc/passwd`」「動態掃描不寫死
檔名清單」「系統 ssh_config 用絕對路徑」三個結構性選擇；`gcloud
compute ssh` 不受這個 bug 影響，不需要這個修法涵蓋它。

（原追蹤於 B0050，2026-08-18 於 B0047 驗證過程發現、確認根因、落地並
實機驗證。）

## 身分資料與工具安裝路徑分離（`$AGENT_HOME` / `$AGENT_TOOLS`）

對應檔：兩個 `Dockerfile.base.*` 開頭的 `ARG AGENT_HOME` / `ARG
AGENT_TOOLS`、`docker-compose.yaml` 的 `AGENT_SANDBOX_HOME` 環境變數。

### 兩條路徑各自的職責

- **`$AGENT_HOME`**（`/home/agent-sandbox`）：**純身分資料**——
  `.claude`／`.codex`／`.gitconfig`／`.config/mise` 這些 bind mount
  進來的東西，world-writable（`chmod -R 777`）只為了幽靈使用者的
  ad hoc 寫入需求。
- **`$AGENT_TOOLS`**（`/opt/agent-tools`）：**純工具二進位**——claude
  CLI、mise 本體與其 data dir，root 擁有，runtime UID 只需要讀＋執行，
  不開放寫入。

兩者職責分開，讓 `chmod -R 777` 的範圍收斂到只有身分資料本身，工具
本身不再暴露在「執行期可被竄改」的風險裡（容器內被攻陷的
plugin/hook 沒辦法竄改 claude/mise 二進位）。

**路徑本身不借用任何 base image 慣例**——不管 `--base` 未來加什麼新的
底層 image，這兩條路徑都是這個專案自己 `mkdir`／`chmod` 從頭建的，不
依賴底層 image 有沒有預先準備。

### 為什麼 claude CLI 要指定安裝路徑、codex CLI 卻用全域安裝——不是本
專案的選擇，是兩邊上游官方安裝方式本來就不同

**claude CLI**：官方安裝腳本（`claude.ai/install.sh`）本身就是
`$HOME` 相對路徑的安裝邏輯（`$HOME/.local/share/claude/versions/<v>`
+ `$HOME/.local/bin/claude`），跟 `rustup`／`pipx` 那類個人層級工具
安裝器同一種模式。**更關鍵的是 claude 自己內部有邏輯依賴這個安裝
方式**——早期（B0021）試過把裸執行檔直接複製到 `/usr/local/bin`
這種系統全域路徑，結果 claude 自己不認得這個安裝：每次容器啟動在
暫存層重建 233MB、`claude doctor` 誤判成殘留的 npm-global 安裝、
實際執行版本跟版本記錄檔分裂。**繞過官方安裝腳本自己的邏輯會直接讓
claude 的自我識別機制壞掉**，已實測驗證過，不是「換個裝法一樣能用」
的選擇題。B0043 把 `HOME=` 只覆寫給安裝那一行用（官方腳本本來就吃
這個變數決定裝哪，跟 runtime `$HOME` 是誰無關），把裝的目的地從
runtime `$HOME` 換成固定的 `$AGENT_TOOLS`，沒有繞過官方安裝流程本身。

**codex CLI**：`npm install -g @openai/codex` 走的是標準 npm 全域安裝
機制，設計上就是裝到系統層級路徑（`/usr/local/lib/node_modules` +
`/usr/local/bin` symlink），跟 `$HOME` 從頭到尾沒有關係，npm 自己的
既定慣例，不是 OpenAI 或本專案特別安排的。codex 是一個薄的 npm 包裝殼
（`optionalDependencies` 依平台下載 Rust 原生執行檔），沒有 claude
那種「自己檢查、依賴特定安裝結構」的內部邏輯——**本來就不在身分資料
那棵樹裡，B0043 搬遷完全不需要動它**。

→ **紅線**：不要為了「兩個 base 看起來要對稱」硬把 codex CLI 也套進
`$AGENT_TOOLS` 的安裝流程——它從未需要這個處理，硬套只是徒增一個
沒有實際問題要解的改動。改 claude 安裝方式前，先確認新做法不會讓
claude 自己的安裝識別邏輯又壞掉（B0021 的教訓）。

### `$AGENT_TOOLS` 底下的 `.npm`／`.cache` 殘留——刻意保留、不清除

實測（2026-07-22）發現 claude 安裝完後 `$AGENT_TOOLS` 底下除了預期的
`.local/`，還多出 `.npm`、`.cache`、`.claude`、`.claude.json` 這幾個
install.sh 順手留下的東西。已查證 `claude.ai/install.sh`
（實際是轉址到 `downloads.claude.ai/.../bootstrap.sh`）**這層 shell
script 本身沒有建立 `.npm`／`.cache`**——它只做「下載執行檔到
`$HOME/.claude/downloads` → 驗證 → 呼叫 `"$binary_path" install` 交給
執行檔本身安裝 → `rm -f` 清掉下載暫存檔」，`.npm`／`.cache` 是被呼叫
的 **編譯後執行檔內部邏輯**建立的，無法從外部查看原始碼。

**決定：不刪除，原樣保留**。理由：

- **刪除的收益很低**——純粹讓 `$AGENT_TOOLS` 目錄看起來更乾淨，不影響
  任何已驗證的功能（runtime 讀寫的是 `$AGENT_HOME`，不是這裡）。
- **無法 100%排除潛在依賴**——`bootstrap.sh` 自己有「用完即清」的習慣
  （下載暫存檔安裝後主動 `rm -f`），但 `.npm`／`.cache` 沒有被同樣
  清掉，可能代表執行檔內部邏輯**刻意**留著（例如背景更新檢查、npm
  registry 查詢等尚不明確的用途），也可能只是實作疏漏——**外部查證
  已達極限**（編譯二進位檔看不到原始碼），無法進一步確認是哪一種。
- **收益低 + 風險無法完全排除 → 不動**，跟本項其他幾處判斷同一個原則
  （不強制覆寫 podman 自己補的 passwd 紀錄、不去動已有 mise-cache
  volume 的既有權限狀態）——刪除這種「查不到底」的建置期產物，不划算。

→ **紅線**：看到這幾個檔案不要誤以為是遺留 bug 想「順手清掉」——
已經評估過、決定保留，且 `$AGENT_TOOLS` 的權限模型（root 擁有、
runtime UID 唯讀）不因為多這幾個檔案而改變，不構成安全疑慮。

### mise 搬遷的 mkdir→chmod 技巧（兩個 base 都要）

mise-cache 是 external named volume，掛進 `$AGENT_TOOLS/mise-data`。
幽靈使用者（runtime UID 無 passwd 帳號）能寫入這裡，靠的是
build time 的 `RUN mkdir -p "$MISE_DATA_DIR" && chmod 777
"$MISE_DATA_DIR"`——**mkdir 必須先於 chmod**，這樣 named volume
第一次掛進這個路徑時才會繼承到這裡已經開放的權限（podman/docker
的既有行為：named volume 首次掛進一個「image 裡已存在內容」的路徑
時，會把 image 當下那個目錄節點的權限複製進新 volume，此後這個
volume 不管掛到哪裡都帶著當初繼承到的權限）。這個技巧只需要精準
開放 `$MISE_DATA_DIR` 這一個節點，不需要對整棵 `$AGENT_TOOLS` 做
`chmod -R 777`（claude CLI 完全不需要寫入權限，開了反而是風險）。

**既有 volume（在改動前就已建立、已有內容）換掛載路徑不需要重跑這個
技巧**——volume 自己的根目錄權限在第一次建立/掛載時就定了，之後掛到
哪個路徑都帶著走，跟後續掛載路徑無關；這個 mkdir→chmod 技巧只在
volume**全新、從未掛載過**時才會被觸發。

→ **紅線**：搬 mise data dir 位置時，`mkdir` 與 `chmod` 的順序、以及
兩者都必須在 `docker-compose.yaml` 的掛載目標路徑之前就緒，不可以
省略或調換順序。

（原追蹤於 B0043，2026-07-22 落地並完成實機驗證：既有 mise-cache
volume 換掛載路徑後內容完整保留——`mise ls` 正常列出改動前已裝好的
語言版本、實際執行確認可用，證實「named volume 內容不綁死掛載路徑」
的推論成立。）

## 多身分（`--identity`，B0015）

對應檔：`agent-sandbox.sh` 的 `_agent-sandbox-validate-identity` /
`_agent-sandbox-ensure-gitconfig` / `_agent-sandbox-ensure-prereqs` / 主
函式的 `identity` 變數；`docker-compose.yaml` 的 `AGENT_SANDBOX_IDENTITY`；
`home/<identity>/` 目錄樹。

### 動機

原本只有單一身分資料夾，所有專案共用同一份 `.claude`／`.ssh`／
`.gitconfig`。但實務上不同工作情境需要的風險/權限組合不同：例如「開發用」
身分可能會跑不確定安全性的第三方 mise/npm 外掛，理想上不該帶任何長期憑證；
「維運用」身分需要 `.ssh` 金鑰能連線管理正式機器，但應該儘量少裝其他工具、
降低暴露面。單一身分資料夾無法表達這種區隔——要嘛所有 session 都能碰到
SSH 金鑰，要嘛都不能。

### 設計：host 端資料夾即身分邊界，容器端路徑固定不變

`home/<identity>/` 底下每個子資料夾都是一份完整、獨立的身分資料（`.claude`／
`.claude.json`／`.codex`／`.gitconfig`／`.config/mise`／`.ssh`），跟
`home/default/` 內容同構——多一個身分就是多一份同構的資料夾，不是新的
資料形態。

`--identity <name>` 決定要掛哪個資料夾（透傳成 `AGENT_SANDBOX_IDENTITY`
環境變數，`docker-compose.yaml` 據此選
`./home/${AGENT_SANDBOX_IDENTITY:-default}/...` 掛載來源）；不帶旗標＝
`default`。

**容器內路徑固定，不隨身分變動**——`$AGENT_HOME`（`/home/agent-sandbox`）
是唯一的容器內身分資料路徑，不會變成 `/home/agent-sandbox-ops` 之類。
理由：

- 容器內所有工具（claude CLI、mise、git）認的都是這條固定路徑，身分只是
  「這次要把哪份 host 資料掛進來」的選擇，不需要、也不該讓容器內部路徑
  跟著身分名稱變動——身分差異只發生在 host 端「掛哪份資料」這一層，不該
  滲透進容器內部設定。
- 容器內路徑固定，也讓 Dockerfile／compose 的其餘邏輯完全不需要知道
  「身分」這個概念存在，複雜度只收斂在「host 端掛哪個資料夾」這一個
  決策點。

### 為什麼預設身分資料夾命名 `default`（原本沿用 base image 帳號名 `node`）

舊名 `node` 是繼承自 base image 曾經以 `node:*-slim` 預設帳號 `node` 命名
的巧合產物，跟身分本身的語意無關（B0043 已把容器內身分改成專案自訂的
`agent-sandbox` 使用者，`node` 這個名字連著容器內慣例的關聯已經斷了）。
多身分機制上線後，這個資料夾其實扮演「預設 / 主要」身分的角色——
`default` 才是這個角色的正確名字，也跟 `--identity` 不帶旗標時的
fallback 值語意一致（`AGENT_SANDBOX_IDENTITY:-default`）。B0015 落地時
一併把 `home/node/` 更名 `home/default/`（純 host 端資料夾重新命名，容器
內路徑完全不受影響）。

**修正**：這件事**沒有自動化**——程式碼不會偵測或搬移既有的
`home/node/`，本機已有舊資料夾（含真實憑證）的使用者 `git pull` 後直接
`agent-sandbox` 會撞到 fail-fast 報錯，且錯誤訊息字面建議的
`mkdir -p home/default` 會誤導使用者建出空資料夾（憑證還在 `home/node/`
沒被搬過去，容易誤以為要重新登入）。屬 CLAUDE.md「user-facing breaking
變更需遷移文件」紅線範圍內，已補
[`docs/guides/migrate-home-node-to-default.md`](../guides/migrate-home-node-to-default.md)。

### fail-fast：不自動建立未知身分

`--identity <name>` 指到不存在的 `home/<name>/` 時直接報錯（列出目前可用
的身分資料夾清單 + 提示 `mkdir -p home/<name>` 即可補齊），**不會靜默
自動建立一個空資料夾**。呼應「run/build 分家」同一種紀律：打錯字不該
悄悄產生一個你沒注意到的新身分（想像 `--identity prod` 打成
`--identity prdo`，若自動建立，你會在一個空白、未預期的身分裡工作而
不自知）。新增身分是刻意的動作，`mkdir -p` 一行即可，不需要專門的建立
指令。

`--upgrade`（純 build，不進容器）**跳過**這項驗證——身分是 run-time 關注
的事，build 階段不需要任何 `home/<name>/` 資料夾存在，讓打錯字的
`--identity` 卡在不相關的 build 操作上沒有意義（維持 run/build 分家紅線）。

### 身分可視化：banner + PS1 雙重提示

錯誤身分下操作（尤其是帶 SSH 金鑰的維運身分）風險較高，必須讓使用者在
容器內隨時看得出目前是哪個身分：

- **啟動當下**：函式印 `🪪 使用身分：<identity>（home/<identity>/）`
  （host 端，進容器前）；`entrypoint.sh` 印
  `🪪 agent-sandbox 身分：<user>`（容器內，一次性 banner，見「容器內
  runtime UID 身分」章節）。
- **持續提醒**：`.bashrc` 追加的 `PS1` 帶 `[${AGENT_SANDBOX_USER}]`
  前綴，每一行提示字元都看得到，比一次性 banner 更能避免「操作到一半
  忘記自己在哪個身分」。
- `AGENT_SANDBOX_USER`：**一律直接用 identity 名稱本身**（`whoami` 顯示
  `default`／`ops`／`dev` 等，零特例）——但如「容器內 runtime UID 身分」
  章節記載，**macOS podman machine 環境這個客製化名稱可能被 podman 自己
  補的紀錄蓋過**，banner／PS1 兩者都直接讀 `AGENT_SANDBOX_USER` 環境變數
  本身（非 `whoami`），不受這個環境限制影響，是唯一保證生效的身分可視化
  管道。
  > 曾評估 `default` 身分特例顯示 host 使用者名稱（沿用單一身分時代的
  > 既有體驗），但發現一個實質安全性問題：若使用者另建的身分名稱**剛好
  > 撞到 host 使用者名稱**（例如 host 使用者叫 `ray`、又建了
  > `home/ray/`），兩個完全不同的身分資料夾會顯示出一模一樣的
  > banner／PS1，可視化安全網對這個組合靜默失效。零特例規則從根源避免
  > 撞名（`identity` 字串本身互不相同，`sandbox_user` 就不會相同），
  > 換掉的代價只是 `default` 身分不再顯示 host 真實使用者名稱。
  > （原追蹤於 B0015，2026-07-24 定案由零特例規則取代。）

### Tab 補全

`--identity` 走同一套 `_arguments` 狀態機
（`(--identity)--identity[...]:identity:->identities`），候選來源掃
`home/*(N/)` 列出目前已存在的身分資料夾名稱，與 `--base`／`--addon`
同款「不寫死清單、glob 即時發現」原則。

### 與既有機制的關係

- **git 身分**：每個 `home/<identity>/.gitconfig` 各自獨立、各自走
  seed-if-missing（見「容器內 git identity」章節）——切身分等於整批
  切換 git commit 身分，不需要額外機制。
- **`.ssh`**：跟其餘身分資料同一份清單、同一套待遇（不透過 `-m` /
  `.agent-sandbox` 額外掛載機制）——一旦身分本身就是一整份專屬資料夾，
  `.ssh` 沒有理由被特殊對待。`home/default/.ssh` 留空即可，無害。
- **`.agent-sandbox` 的 `[mount]` / `[image]`**：身分與這兩段完全
  正交——`--identity` 只決定身分資料來源，不影響額外掛載或 base/addon
  選擇，三者可任意組合。（`[identity]` 段是例外——它本來就是設定
  identity 用的，見下方「逐專案預設身分」小節，不算違反這條正交性，
  只是同一個維度換一種輸入方式。）

**檔案型 vs 資料夾型掛載來源都要主動補、不能只補資料夾**（2026-07-24 使用
者實機測試 `--identity ops` 時發現）：`.claude`／`.codex`／`.config/mise`／
`.ssh` 是資料夾掛載，host 來源缺失時 podman 自動建的也是資料夾，型態不會
錯；但 `.claude.json`／`.gitconfig` 是**檔案**掛載，podman 對缺失來源一律
自動建成資料夾——型態直接錯掉，掛出來的會是一個 root 擁有的空資料夾，容器
內任何預期讀寫該檔案的工具會直接壞掉。`.gitconfig` 從一開始就有
`_agent-sandbox-ensure-gitconfig` 這個安全網涵蓋所有身分，但 `.claude.json`
起初只有 `init.sh` 幫 `default` 身分補過，其他身分完全沒人補——直到使用者
新建 `home/ops/` 才第一次真的踩到（`home/ops/.claude.json` 被 podman 誤建
成 root 擁有的空資料夾）。已修正：`_agent-sandbox-ensure-prereqs` 比照
`.gitconfig` 加了 `.claude.json` 的 `touch`-if-missing，套用到所有身分。

→ **紅線**：容器內路徑（`$AGENT_HOME`）不隨身分變動；未知身分一律
fail-fast、不自動建立；`--upgrade` 不做身分驗證；身分可視化一律讀
`AGENT_SANDBOX_USER` 環境變數本身，不依賴 `whoami`；**新增身分掛載清單裡的
檔案型項目時，記得在 `ensure-prereqs` 加對應的 touch-if-missing，不能只
靠資料夾的 `mkdir -p` 概括承受**。

（原追蹤於 B0015，2026-05-18 建立、最初動機是「多個 home 目錄」構想；
2026-07-23 因應 B0043／B0044 已完整落地重新全面分析；2026-07-24 拍板
命名（`--identity`，含 Tab 補全）與容器內路徑固定不變兩項關鍵決策，
同日開始實作：`home/node/` 更名 `home/default/`、compose 多身分掛載、
函式 `--identity` 旗標與驗證、Tab 補全、身分可視化 banner/PS1。）

### 逐專案預設身分（`.agent-sandbox` 的 `[identity]` 段，B0049）

B0015 落地當時刻意先不做「`.agent-sandbox` project-level 預設身分」
（YAGNI——「你是誰」比較像使用者屬性，等真的有反覆手動打 `--identity`
的痛點再加）。B0047 之後這個痛點真的出現了：`ai-ops` 這類專案本質上
就是要用固定身分（如 `ops`）管雲端主機，每次手動打 `--identity ops`
是真實反覆的操作，觸發本項落地。

**獨立 `[identity]` 段，不塞進 `[image]`**：`[image]` 段語意單純只管
「image 變體」，混進身分會模糊「身分與 image 變體正交」這條既有結論
（見上方「與既有機制的關係」）。鍵名 `identity =`——跟 CLI 旗標同一個
詞，不必多記一套對應詞彙；`[identity]` 段只有這一個鍵，用段名當鍵名
不會有歧義。

**專案 only，比照 `[image]`**：「這個專案該用哪個身分」是專案屬性
（跟「這個專案要哪個 base」同一種問法），不是使用者全域偏好；全域層
目前沒有具體需求支撐，開放只會重演 `[image]` 當初「1 base/1 addon、
零價值＝YAGNI」的同款過度設計，放全域層會被 lint 警告並略過（跟
`[image]` 同一套「未知/誤放段落」健檢機制）。

**合成規則跟 `base` 完全同構**：單值覆蓋，`--identity` > 檔案
`identity` > 內建 `default`。落定時機仿照 `base`——`local identity=""`
一路留空，直到 `_agent-sandbox-apply-identity-config` 這個函式裡才
真正決定（CLI 有給就用 CLI、否則用檔案值、都沒有才落 `default`），
不在主函式一開始就提早 `identity="${identity:-default}"`（B0015 原本
這樣寫，因為那時候還沒有設定檔層；B0049 起這樣寫會讓檔案值永遠贏不了
提早寫死的 `default`，所以連帶把這行拿掉，改到 apply 函式裡收尾）。

**與 `--upgrade`／`--new-identity` 白名單檢查的耦合（本項最容易踩雷
的一點）**：`_agent-sandbox-validate-upgrade-flags`／
`_agent-sandbox-validate-new-identity-flags` 用「`$identity` 是否非空」
判斷「使用者是否有給 `--identity`」，藉此擋 `--upgrade --identity x`
這類旗標衝突。這兩個檢查的呼叫時機必須維持在
`_agent-sandbox-apply-identity-config`（讀 `[identity]` 段、把檔案值
寫進 `$identity`）**之前**，且 `_agent-sandbox-apply-identity-config`
本身整段包在 `if [[ -z "$upgrade" ]]` 內，`--upgrade` 模式完全不呼叫
它——否則單純因為在帶 `[identity]` 段的專案資料夾下跑 `--upgrade`，
就會被誤判成「有給 --identity」而報錯拒絕，這是實作時故意留設計
紀錄提醒的坑，別在後續改動時把呼叫順序打亂。

→ **紅線**：`identity` 的落定邏輯必須留在
`_agent-sandbox-apply-identity-config` 內（不要在主函式提早寫死
`default`）；`--upgrade`／`--new-identity` 的旗標白名單檢查必須早於
這個函式呼叫；`[identity]` 維持專案 only，全域層開放前需另外評估
（同 `[image]` 的 YAGNI 判斷基準）。

（原追蹤於 B0049，2026-08-18 拍板並落地、實機驗證通過。）

## 建立新身分（`--new-identity`，B0046）

對應檔：`agent-sandbox.sh` 的 `_agent-sandbox-validate-new-identity-flags`
/ `_agent-sandbox-create-identity` / 重構後接受參數的
`_agent-sandbox-ensure-prereqs` / `_agent-sandbox-ensure-gitconfig`。

### 動機

`--identity` 的 fail-fast 紅線（見上節）要求身分頂層資料夾
`home/<name>/` 必須先手動 `mkdir -p` 才能用——這個手動步驟本身沒有被
自動化過，是刻意設計（防打錯字時默默落入未預期的空白身分）。但這也代表
「建立一個全新身分」永遠要手動一行指令，2026-07-28 使用者提出：想要
連這個 `mkdir` 都省掉，但不透過修改 `--identity` 本身的 fail-fast 行為，
而是「透過一個獨立的指令或參數處理」。

### 設計：獨立動作型旗標，比 `--upgrade` 分岔得更早

`--new-identity <name>` 是跟 `--upgrade` 同一類「動作型、做完就結束、
不進容器」的旗標，但分岔位置更早——`--upgrade` 還需要跑
`_agent-sandbox-validate-variant` 才知道要 build 哪條 base/addon 鏈；
`--new-identity` 完全不需要，身分與 image 變體是正交的兩件事（見上節
「與既有機制的關係」）。主函式流程裡，`--new-identity` 在
`_agent-sandbox-parse-args` 之後、`identity="${identity:-default}"`
**落定之前**就整個分岔掉，不進入後續 identity/base/addon/mount/build
主線：

```zsh
_agent-sandbox-validate-upgrade-flags || return 1
_agent-sandbox-validate-new-identity-flags || return 1
if [[ -n "$new_identity" ]]; then
    _agent-sandbox-create-identity "$new_identity"
    return $?
fi
identity="${identity:-default}"
...（原本主線繼續）
```

**旗標白名單**（比照 `_agent-sandbox-validate-upgrade-flags` 同一套
紀律）：`--new-identity` 不接受 `--identity`（語意衝突：到底要建新的
還是選舊的）、`--upgrade`（兩者都是「做完就結束」，同時給沒有意義）、
`--launch`、`-m`／`--mount`／`--no-config-mounts`、`--base`／`--addon`
——一律 fail-fast 直接報錯，不靜默忽略，跟這個專案一貫「打錯字/給錯
旗標不該默默發生」的立場一致。

### 身分已存在時：照跑一次、當健檢，不拒絕

**捨棄了跟 `--upgrade` 版號快照「已存在就拒絕覆蓋」對稱的做法**。重新
檢視後發現這個類比不成立：`--upgrade` 擋覆蓋是因為真的會摧毀東西
（舊版號 tag 被蓋掉、rollback 能力消失）；`--new-identity` 底層操作
（`mkdir -p`／touch-if-missing／`.gitconfig` seed-if-missing）本質上就是
「檢查缺什麼補什麼」，不管跑幾次都不會動到已存在的內容，選項 B（拒絕）
擋的是不存在的風險，只是表面上長得像。`--identity` fail-fast 紅線真正
要防的是「靜默」與「意外落入非預期狀態」——只要把每一步做了什麼明確
印出來（見下節），選項 A（照跑）就沒有踩到那條紅線的精神，還多換到一個
實用的副作用：身分裡某個子項如果因故被刪掉或壞掉（例如曾經真的發生過的
`.claude.json` 被 podman 誤建成資料夾，見上節），重跑一次
`--new-identity` 就能自動修復。

### 逐項可見性：不管有沒有變動，六個子項都要明確列出

使用者明確要求：「不管是已存在還是補了什麼，全都要顯示出來，不可以
默默在背後做掉」。落地方式：`_agent-sandbox-ensure-prereqs` 與
`_agent-sandbox-ensure-gitconfig` 重構成接受兩個參數
（`target_identity`、`verbose`），對 `.claude`／`.codex`／
`.config/mise`／`.ssh`／`.claude.json`／`.gitconfig` 六個子項逐一在
動手前判斷存在與否、動手後依實際結果（成功才印「🆕 已建立」，不能
無條件宣稱）分類回報：

```
🔍 檢查身分 home/ops/：
   .claude       已存在，未變動
   .codex        已存在，未變動
   .config/mise  已存在，未變動
   .ssh          🆕 已建立
   .claude.json  已存在，未變動
   .gitconfig    已存在，未變動
✅ 身分 ops 已就緒。下一步：agent-sandbox --identity ops
```

**回報必須基於操作的真實結果，不能樂觀假設成功**：`mkdir -p`／`touch`／
寫入 `.gitconfig` 都先判斷實際回傳值，失敗就印 `❌` 並 `return 1`，不會
在操作失敗的情況下還印出「🆕 已建立」——印一個錯誤的成功訊息比什麼都
不印更誤導，這正是使用者「不可默默做掉」要求的真正精神（見「行為設計」
的完整討論脈絡於 backlog）。

**範圍界定：只有 `--new-identity` 走逐項回報，日常啟動維持安靜**。
`ensure-prereqs`／`ensure-gitconfig` 是共用同一份邏輯（`verbose` 參數
控制輸出多寡），但日常啟動路徑（`agent-sandbox --identity <name>`）
呼叫時明確傳 `verbose=0`——那條路徑的既有紅線是「零互動、秒起」，99%
情況下這個檢查完全無事可做，若也逐項印 6 行會變成每次日常啟動都多出
雜訊，跟現有「只有真的有東西要秀才印」的安靜風格（額外掛載清單、
`[image]` 段讀取摘要都是這樣）不一致。**若日後想把逐項回報也套用到
日常啟動路徑，需要另外評估、明確拍板，不是本項自動涵蓋的範圍**。

→ **紅線**：`--new-identity` 一律 fail-fast 對待不相干旗標；
`ensure-prereqs`／`ensure-gitconfig` 的 verbose 輸出必須基於操作真實
成功與否，不能樂觀假設；日常啟動路徑的安靜行為不受本項影響，除非另有
明確決策。

（原追蹤於 B0046，2026-07-28 從 intake「多身份 home 目錄不用手動 mkdir」
分析出發，查證後發現 `.ssh` 等子目錄早已由既有 `ensure-prereqs` 自動
補齊、真正缺的只有頂層資料夾這層，據此設計獨立指令，不牴觸
`--identity` 本身的 fail-fast 紅線；同日拍板命名、行為與可見性細節、
落地實作。）

## gcloud addon + 身分掛載清單擴充（B0047）

對應檔：`Dockerfile.addon.gcloud`、`docker-compose.yaml` 的
`.config/gcloud` 掛載、`agent-sandbox.sh` 的 `_agent-sandbox-ensure-prereqs`
子目錄清單。

### 動機

`--identity ops` 這類雲端主機維運身分，除了 SSH 金鑰還會用到 `gcloud`
CLI 連 GCP。`gcloud` 跟身分是正交的兩件事（見「與既有機制的關係」），
所以走既有 `--base`/`--addon` 機制新增一個 addon，不是身分機制的一部分
——這點跟 B0046 的判斷（`--new-identity` 不碰 `--base`/`--addon`）同一
個道理。

### 安裝方式：官方 apt repo，不走 mise

`Dockerfile.addon.gcloud` 用 Google 官方文件記載的 Debian/Ubuntu apt repo
安裝法（`packages.cloud.google.com/apt` + `gpg --dearmor` 到
`/usr/share/keyrings/`，取代已棄用的 `apt-key add`）。**不走 mise**：
mise 生態圈沒有穩定通用的 gcloud plugin，而 gcloud 本身不是「語言環境」
（`docs/design/mise.md`「image 不預裝任何語言」那條紅線管的是 Python／
Go 這類語言 runtime，gcloud 是獨立 CLI 工具，跟 codex/openspec 走
apt/npm 官方管道是同一類）。裝「當下最新」（保鮮哲學同 claude/codex/
openspec），版本固化進 `/etc/gcloud-version`，跟其他工具的版本記錄機制
對齊。

### 登入態持久化：身分掛載清單擴充成七項

`gcloud auth login` 的 OAuth token／application-default credentials
存在 `$HOME/.config/gcloud/`。跟 `.claude`／`.codex` 同一套「拋棄式容器、
登入態不拋棄」待遇——`docker-compose.yaml` 新增
`home/<identity>/.config/gcloud` 掛載，`_agent-sandbox-ensure-prereqs`
的子目錄清單從六項（`.claude`／`.codex`／`.config/mise`／`.ssh`／
`.claude.json`／`.gitconfig`）擴充成七項（加 `.config/gcloud`）。

**對沒裝 `gcloud` addon 的身分／base 無害**：跟 `.codex` 全掛的邏輯一樣
（B0016 方案 A）——沒裝 gcloud 的容器裡這就是一個空資料夾，不影響任何
東西；換掉的代價只是身分資料夾多一個子目錄，跟現有六項一起靠
`ensure-prereqs` 冪等維護，機制上零額外成本。

→ **紅線**：新增任何會被身分掛載、需要持久化登入態的工具時，走同一套
「加進 `docker-compose.yaml` 掛載清單 + `ensure-prereqs` 子目錄清單」
模式，不要為單一工具另開特例機制。

（原追蹤於 B0047，2026-08-18 使用者提出 `ops` 身分要管理雲端主機的
實際需求，當場拍板走 addon 機制 + 持久化登入態；gcloud 實際登入流程
（OAuth device code vs service account）留待建完 addon、實測連線時再
細談，不在本項範圍內先假設。）

## Tab 補全（`_agent-sandbox` + `compdef`）

**用 `_arguments` 宣告式狀態機**（非 `case $words[CURRENT-1]` 的弱位置感）：
spec 一條描述一個旗標／位置參數，由 `_arguments` 自己管位置、互斥、可重複：

```zsh
_arguments -S \
    '(- *)'{-h,--help}'[顯示用法]' \
    '(--base)--base[...]:base:->bases' \      # (--base) → 不可重複
    '*--addon[...]:addon:->addons' \           # *      → 可重複
    '*'{-m,--mount}'[...]:mount spec:_files' \  # *      → 可重複，值補路徑
    '1:image tag:->tags'                        # 1:     → 單一位置參數
```

換來真正的位置感：**位置 tag 給過就不再推、其他位置不誤推**；`--base` 給過
不再提示；`--addon`/`-m` 可重複。`->state` 把值補完導到下方 `case $state`
分支，沿用既有 `_describe` 候選。

> 旗標值用**空白式**（`--addon openspec`），**不支援 `=` 形式**（`--addon=x`）
> —— 因為 runtime 解析器（`case "$1" in --addon)`）也只配字面旗標、只吃空白式；
> 補全與 runtime 保持一致，不去補一個函式自己會 reject 的語法。（要全面支援
> `=` 須 runtime + 補全一起改，評估後不做，2026-06-10。）

> 為什麼不用 `case $prev`：那只看「上一個詞」、位置不敏感（tag 給過還推、
> `--base` 不互斥）。`_arguments` 是 zsh 慣用法，也是跨版本最穩的標準路徑。
> （原追蹤於 B0030；2026-06-10 由 `case $prev` 升級。）

> tag 維持**位置參數**（`agent-sandbox v1.0`，非 `-t v1.0`）：它是「最常指定
> 的主角」，位置寫法更短、合 `docker run <image>` 慣例；改旗標屬 breaking
> 且只換到內部實作乾淨，CP 值不高（2026-06-10 評估後保留位置）。

候選來源：`podman images <最終 repo> --format '{{.Tag}}:{{.ID}} {{.Size}}'`，
格式 `tag:ID size`。`_describe` 以第一個 `:` 切「候選:描述」 → tag 是
候選、ID + size 是說明。

**tag 候選是 context-aware 的**（2026-07-03，B0035 host 實測發現）：補全先
掃命令列已敲的 `--base`/`--addon`、再套 `_agent-sandbox-apply-image-config`
（專案 `[image]` 段，**與 runtime 同一套合成規則**）推導出最終 repo，只列
**那個 repo** 的 tag。早期寫死 `agent-sandbox-claude` 會把 base-only 的版號
（如不帶 addon 升級出的 `v0.11.0`）推薦給帶 `--addon` 的指令，補到的 tag
run 不起來。→ **改補全的 tag 來源時保持「補得到＝跑得起來」**：推導邏輯
沿用 runtime 的 helper，別另寫一份會 drift 的副本。

**ID 相同的 tag 互為別名**（切過去等於沒切）；**ID 不同才是真的不同版
本**。

`_describe` 第二參數**必須傳陣列變數名**，不能傳字串字面：傳字面會讓描
述裡的空白被拆碎、引號混進候選（跑版）。

**zstyle 故意極簡**：只設 `verbose yes`（顯示描述）+ `list-grouped no`
（別把描述相同的別名擠成同一行）。**不設** `descriptions format` /
`group-name` / `group-order`：那些跨 zsh 版本與 oh-my-zsh 等全域 zstyle
對齊行為不穩、純外觀。保持最簡 → 候選與描述永遠正確、任何環境都不跑
版。

## 安裝位置與自我定位

在 `~/.zshrc` 加一行 `source /path/to/agent-sandbox/agent-sandbox.sh` 即可。
**不需要任何路徑環境變數** —— 函式自我定位本檔所在目錄，從那裡找
`docker-compose.yaml` 與 `Dockerfile.*`。其他 env var 函式內自動推導（見
[file-layout 環境變數速查表](../reference/file-layout.md)）。

**為什麼移除 `AGENT_COMPOSE_PATH`**：舊版要使用者手 export 一個絕對路徑，
搬動 repo 就失效（B0020）；且整段函式是貼進 rc 的副本，會與權威版分岔。
抽成單一 sourceable 檔 + 自我定位後，兩個問題一併消除。

→ **紅線：自我定位必須在 source 當下、檔案頂層擷取，不可延後到函式內**。
函式之後會從任意 cwd 被呼叫，`$0` 屆時不再指向本檔。zsh 用
`_AGENT_SANDBOX_DIR="${${(%):-%x}:A:h}"`（`%x`＝正在被 source 的檔，`:A`
解 symlink+絕對，`:h` 取目錄），存成全域供函式與補全共用。

→ **紅線：本檔定位為 zsh**（函式本體用到 `(N)` glob、`compdef`/`zstyle`、
`read "var?prompt"`、1-起算陣列等 zsh 限定語法，bash 連 parse 都過不了）。
檔頭以早退守衛擋住非 zsh：趁 bash 讀到含 `(N)` 的函式定義**前**就 `return`，
只印一行提示而非噴 parse error。

> staleness（長時間 session 仍跑記憶體裡的舊函式）刻意不處理：抽檔已消除
> drift；剩下的長 session 陳舊靠「`git pull` 後重開終端機／重新 source」即可
> （原追蹤於 B0020，使用者決定不加 runtime 版本檢查）。

## `--base` / `--addon` 多變體機制

容器 image 採二維命名空間：

- **base**：底層 image variant（如 `claude` / `codex` …）。
  每個 base 一份 `Dockerfile.base.<name>`，內含完整 `FROM`（如
  `FROM node:22-slim`）。預設 `--base claude`。
- **addon**：層級式 add-on（如 `openspec` …）。每個 addon 一份
  `Dockerfile.addon.<name>`，**base-agnostic**：開頭 `ARG BASE_IMAGE`
  + `FROM ${BASE_IMAGE}`，能疊在任何 base 上。可多次 `--addon` 堆疊。

### 命名規則（filename prefix）

| 檔名格式 | 用途 | 內容約定 |
|---|---|---|
| `Dockerfile.base.<name>` | base | 完整 `FROM ...`（外部 image 或本地） |
| `Dockerfile.addon.<name>` | addon | `ARG BASE_IMAGE` + `FROM ${BASE_IMAGE}` |
| `Dockerfile.override.<base>.<addon>` | 特殊組合 override | 取代鏈中對應 addon 那層 |

函式用 `Dockerfile.base.*(N)` / `Dockerfile.addon.*(N)` 即時掃發現可用候
選，供補全與旗標驗證共用。

### Image 名命名

`agent-sandbox-<base>[-<addon1>][-<addon2>]:<tag>`

範例：

- `agent-sandbox-claude:latest` —— `--base claude`（預設）
- `agent-sandbox-claude:v1.2.0` —— 凍結 milestone
- `agent-sandbox-claude-openspec:latest` —— `--base claude --addon openspec`
- `agent-sandbox-codex:latest` —— `--base codex`（B0016 起內建第二 base）
- `agent-sandbox-codex-openspec:latest` —— `--base codex --addon openspec`
- `agent-sandbox-claude-gcloud:latest` —— `--base claude --addon gcloud`
  （B0047，官方 Google Cloud CLI，供雲端主機維運身分使用）

### 逐專案預設 base/addon（專案 `.agent-sandbox` 的 `[image]` 段）

`base = <name>`（單值）、`addon = <name>`（可重複行，順序＝疊層順序；一行
空白分隔多個也收）。合成（沿用全檔「清單疊加、單值覆蓋」總則）：

- **base（單值→覆蓋）**：CLI `--base` > 檔案 `base` > 內建 `claude`。「不帶
  `--base` 等同 `--base claude`」紅線語意自此精確化為「**無 CLI 且無檔案設定**
  時 = claude」。
- **addon（清單→疊加）**：檔案 addons + CLI `--addon` **累加、去重保序**
  （`${(@u)…}`）。與 mount 同一條規則（清單一律疊加），不搞「CLI 取代整組」的
  特例。要「這次不用某預設 addon」就把 `[image]` 那行 `#` 註解掉（專案 only，
  所以註解即逃生口，不需旗標）。
- 檔案值實際生效時必印 `📄 讀取 …（[image] 段：…）`（可見性，比照 [mount]）；
  檔案 base 驗證失敗時錯誤訊息附註「來自 .agent-sandbox [image] 段」（使用者沒打
  `--base` 卻看到「未知 --base」會困惑）。
- **`[image]` 維持專案 only**：全域預設 base/addon 暫不做（目前 1 base/1 addon、
  零價值＝YAGNI；前向相容可後加）。處理 B0016（多 base）時再評估是否開全域層。

（原追蹤於 B0033；2026-06-15 落地，addon 由草案「CLI 取代」改為「疊加去重」、
與 mount 同則。）

### Build 鏈（僅 `--upgrade` 模式；run 模式只查最終 image 存在）

**整鏈共用版號**：`--upgrade` 建出的所有層（base + 各 addon）打同一組
tag（`:latest` + 版號）。凍結整鏈一致 —— `agent-sandbox --upgrade --addon
openspec` 產生的快照同時含 `agent-sandbox-claude:vX.Y.Z` 與
`agent-sandbox-claude-openspec:vX.Y.Z`；container 從最終層啟動，中間層
順帶可單獨用（`agent-sandbox vX.Y.Z` 不帶 addon 也跑得到 base 快照）。

**Build 全部走 raw `podman build`、不走 compose build**：

1. base：`podman build --no-cache -f Dockerfile.base.<base> -t agent-sandbox-<base>:latest .`
2. 每個 addon 順序 build：
   `podman build --no-cache -f Dockerfile.addon.<a> --build-arg BASE_IMAGE=<prev>:latest -t agent-sandbox-<base>-<a>:latest .`
3. 全鏈成功後逐層 `podman tag <repo>:latest <repo>:<版號>`（快照原子性，
   見「Tag 控制與升級」章）
4. compose 只負責 `run --rm`，image 已備齊（`pull_policy: missing`
   既不 build 也不 pull）

**為什麼禁用 compose build**：podman 在 macOS 用的 docker-compose 外部
provider（v1 classic builder）會**順手把 `:latest` 與所有歷史 repo:tag
都重新指到剛 build 的 image**，無論 `image:` 指定的是什麼 tag。這直接
破壞「版號 tag = 凍結快照，不可被覆蓋」的核心保證。`podman build` 直接
呼叫就乾淨 —— `-t` 指什麼就只 tag 什麼。

→ **紅線**：函式裡 build 一律走 `podman build`；若未來想加 compose
build 路徑（例如為了某個情境的便利），先確認 provider 行為是否已修，
否則會打回原型。

**混版本（少見、進階）**：函式只接受單一 tag。要「base v1.0 + addon
0.5」這種跨層混搭，手動 `podman build --build-arg OPENSPEC_VERSION=0.5
-t agent-sandbox-claude-openspec:my-mix .`，再用
`agent-sandbox my-mix --addon openspec` 跑它（run 只查存在，手動 build
的 tag 一樣認）。

### Override

若 `Dockerfile.override.<base>.<addon>` 存在，鏈中該 addon 那層改用它,
不走通用 `Dockerfile.addon.<addon>`。預期用於「某 addon 在特定 base 上
需要特殊處理」的邊緣案例。**addon base-agnostic 為預設,override 是逃
生口**。

→ **紅線**：改參數解析時保持「不帶 `--base` 等同 `--base claude`」、
鏡像名公式不變、`Dockerfile.<kind>.<name>` 命名規則不變。

> per-layer SHA 防呆（`~/.cache/agent-sandbox/*.sha` 指紋 + 逐層備份提示）
> 已於 2026-07-03 隨 run/build 分家整組移除（B0035）——run 永不 build，
> 「覆蓋前備份」由 `--upgrade` 每次自動留版號快照取代。舊指紋快取檔可
> 手動清（見 `docs/guides/migrate-autobuild-to-upgrade.md`）。

## `--launch`：進容器自動啟動 base 的工具

`agent-sandbox --launch` 進容器後自動啟動該 base 宣告的工具，工具退出後 `exec bash`
留在容器續作業（通用化舊 B0027 的 `--claude`，但不綁死 claude）。

### base→工具：純 Dockerfile LABEL（嚴謹）

每個 `Dockerfile.base.<name>` 自宣告 `LABEL agent-sandbox.launch="<tool>"`；函式啟動前
`podman image inspect <最終 image> --format '{{ index .Config.Labels "agent-sandbox.launch" }}'`
讀出工具名。**沒宣告（空 / `<no value>`）→ 報錯、不啟動**（不 fallback、不猜 base 名）。

為何純 label：
- **維持 base-agnostic**：函式不持有任何 per-base 對照表（會 drift、違反「函式靠 glob
  發現 base、不寫死」紅線）。「啟動什麼」寫在 base 自己的 Dockerfile，新增 base 只動一檔。
- **沿用既有 LABEL 慣例**（`claude-cli.version-file` 等）；addon 層 `FROM base` 繼承
  label，inspect 最終 image 即得。
- **嚴謹**（使用者選）：缺 label 就報錯，逼明確宣告，不靠脆弱的「工具名＝base 名」猜測。
  （評估過 fallback-to-base-name 與 `--launch <cmd>` 顯式覆蓋，為了嚴謹一律不做。）

### 容器命令

`--launch` 時把 `compose run … agent bash` 改成 `agent bash -c '<tool> ; exec bash'`：
跑工具 → 退出後 `exec` 回互動 bash（容器仍在、`--rm` 在退出 bash 時才生效）。v1
**不轉發工具參數**（要 `--dangerously-skip-permissions` 等進去再打）。

→ **紅線**：base→工具一律走 LABEL inspect；別在函式裡加 base→工具對照表（破壞
base-agnostic）。（原追蹤於 B0037。）

## `claude --sandbox` 門面（可選 opt-in，`agent-sandbox-claude-wrapper.sh`）

把「啟動沙盒」包裝成 `claude --sandbox` 的趣味／品牌入口。實作是一個 shell 函式
wrapper：`$1 == --sandbox` → `agent-sandbox --launch "$@"`（透過 `--launch` 進容器
**自動啟動 claude**，名實相符），否則 `command claude "$@"` 原樣轉發真 claude。

**為何放獨立檔 + opt-in（不進 `agent-sandbox.sh`）**：wrapper 會以函式 **shadow
`claude`** 這個常用指令名。雖然非 `--sandbox` 一律 `command claude` 透明轉發、行為
不變，但「要不要 shadow `claude`」應由使用者**明確選擇**，不該強加給每個 source
`agent-sandbox.sh` 的人。故獨立成 `agent-sandbox-claude-wrapper.sh`，使用者**另外**再
source 才生效（或由 init.sh 詢問式 opt-in 加入）。這也與「單一 sourceable 檔」紅線
不衝突 —— 它是**另一個**可選檔，不混進主檔。（命名：`agent-sandbox-` 前綴點出歸屬、
`wrapper` 點出「包 claude 指令」用途；副檔名沿用專案慣例 `.sh`，與 `agent-sandbox.sh`/
`init.sh` 一致。）

**為何 `--sandbox` 可行**：已驗證 `claude --help`（2.1.168）**無 `--sandbox` 旗標**
→ 不撞現有功能。殘留風險：未來 claude 版本可能新增 `--sandbox`，wrapper 會攔截它
（命名空間賭注，低機率）；opt-in + 可隨時移除/改 trigger 緩解。

**共存語意**：沒裝 claude → `claude --sandbox` 當入口、其餘 `claude …` 報 not found
（預期）；有裝 claude → `--sandbox` 進沙盒並自動跑 claude、其餘透明轉發真 claude。
`--sandbox` 後的參數**原樣**傳給 `agent-sandbox`（tag/--base/--addon/-m 全沿用）。
指令解析優先序 **function > PATH binary**，故函式蓋過真 claude；函式內 `command claude`
是繞過自身、直呼真 binary 的逃生口。

**tab 補全（委派，opt-in 才不怕蓋到 claude）**：本檔額外註冊 `claude` 的補全
`_agent-sandbox-claude-wrapper` —— `--sandbox` 之後把 `claude --sandbox <args>`
重寫成 `agent-sandbox <args>`（改 `words`/`CURRENT`）再委派既有 `_agent-sandbox`，
零重複。一般會擔心「幫 `claude` 註冊補全會蓋掉 claude 原生補全」，但本檔是 opt-in：
**只有想要門面、又（多半）本機沒裝 claude 的人才 source 它** → 沒有原生補全可被蓋。
（紅線推論：若日後裝了 claude 又仍 source 本檔，補全與函式都會蓋過真 claude →
移除本檔即可；這由使用者自負，不是預設狀態。）

**init.sh 詢問式 opt-in**：`./init.sh --apply` 會問「要不要啟用 `claude --sandbox`
門面」，答 yes 才在 rc 受管區塊多寫一行 `source …agent-sandbox-claude-wrapper.sh`
（`INCLUDE_WRAPPER`）。**每次 --apply 都問、但預設＝目前狀態**：已啟用時預設 Yes
（Enter 保留、明確答 n 才關），未啟用時預設 No → idempotent 且能兩向切換（避免
「只能開不能關」的不對稱）。為此 `ask` 加了可選的「預設值」參數。

→ **紅線**：保持 opt-in（預設不啟用、不進主檔）；非 `--sandbox` 一律 `command claude`
原樣轉發（別攔截或改寫真 claude 的行為）。（原追蹤於 B0032。）

### codex 版門面（`agent-sandbox-codex-wrapper.sh`，B0016）

同模式的獨立 opt-in 檔：`codex --sandbox …` → `agent-sandbox --base codex
--launch …`（注入 `--base codex`，補全委派時也注入 → tag 候選自動是 codex
repo 的）。與 claude 版的關鍵差異：

- **命名空間賭注的性質不同**：claude 版是「驗證過無此旗標、未來低機率撞」；
  codex 版是**已知確定撞**——真 codex 有 `-s, --sandbox <MODE>`（其執行隔離
  政策）與 `sandbox` 子指令。評估後刻意接受，因為攔截面極窄：**只攔
  「`--sandbox` 為第一個參數」**這一種形態；`-s` 短旗標、旗標放後面、
  `sandbox` 子指令（無 dash）都照常轉發真 codex。逃生口同款：
  `command codex` / `\codex` / 移除 source 行。（2026-07-05 使用者知情拍板：
  「不裝 host codex 就零衝突；裝了只犧牲一種旗標寫法」。）
- 其餘紅線同 claude 版：opt-in、獨立檔、非 `--sandbox` 一律 `command codex`
  原樣轉發。

> 若日後想加第三個工具的門面，先查那個工具的旗標/子指令命名空間再決定
> 觸發詞——claude 的空位、codex 的窄面衝突、下一個工具可能是完全佔用
> （屆時改走獨立指令名，如 `<tool>-sandbox`）。

## 內部 helper 切分（檔案結構約定）

`agent-sandbox.sh` 內部把原單一大函式拆成 `_agent-sandbox-*` 私有 helper +
~60 行的 `agent-sandbox()` 流程編排（parse-args → validate-variant →
collect-mounts → ensure-prereqs → build-chain → resolve-launch
→ compose run → cleanup-network）。約定：

- **命名前綴 `_agent-sandbox-`**：與補全函式 `_agent-sandbox` 同族、底線開頭
  表私有。不用更短前綴（如 `_as_`）—— 易撞使用者 shell 其他工具的 namespace。
- **動態作用域契約**：zsh 函式是動態作用域，helper 直接讀寫主函式宣告的
  local 變數。每個 helper 頭部註解標明「讀：…／寫：…」，改 helper 前先看
  頭註、改完同步更新。
- **失敗一律 `return 1`、絕不 `exit`**：函式在使用者 interactive shell 內
  執行，exit 會關掉使用者的終端機。主函式逐站 `|| return 1` 傳遞。
- **`-h` 用 return 200 訊號**：parse-args 印完 usage 回傳 200（非錯誤），
  主函式轉成 return 0 —— 維持 `agent-sandbox -h` exit code 為 0。
- **跨層一致紅線**：build/tag/存在檢查在 `_agent-sandbox-build-chain` 內
  以同一迴圈套用到 base 與所有 addon 層 —— **不要為某層另開分支邏輯**，
  要改行為就改鏈的共同路徑、全鏈一起變。（原「SHA 防呆單一實作」紅線
  隨 B0035 移除防呆機制後，由本條承接同一精神。）
- 單一 sourceable 檔紅線不變：helper 全部住在 `agent-sandbox.sh` 同檔；
  檔案膨脹到 ~700+ 行再評估拆 `lib/*.zsh`（屆時本切分可直接搬）。

（原追蹤於 B0034；2026-06-11 重構落地，外部行為零變更、以重構前後輸出
與 podman 呼叫序列逐字 diff 驗證。）

## 演進簡史

agent-sandbox 從 alias 演進到 function 經歷四個里程碑：

1. **v1 alias**：單行，只傳 UID/GID + 掛當前目錄
2. **v2 alias**：改 podman（docker desktop 太常當機）
3. **v3 alias**：加日期戳 project name + 淨化規則
4. **v4 function**：function 才能在 run 之後接續清 network；後續才加上
   Tag 控制、latest SHA 防呆、ensure-volume 等機制
5. **v5 run/build 分家**（B0035，2026-07-03）：run 永不 build、
   `--upgrade` 成為唯一 build 入口；SHA 防呆與自動 build 一併退役，
   由「每次升級自動留版號快照」取代

完整歷程含每版原始指令與決策原因見本機 `_terminal捷徑history.md`
（gitignored、個人開發歷程）。
