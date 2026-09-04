# docker-compose.yaml — 設計筆記

對應檔：[`/docker-compose.yaml`](../../docker-compose.yaml)。

本檔說明該 compose 檔關鍵設定**為什麼這樣選**。程式碼裡只留一句話 + 指
回本檔；想動相關設定前**先讀完本檔對應段落**，避免破壞看不見的依賴。

## mise-cache volume：`external: true` + 固定 `name`

mise 安裝的語言／工具長駐這個 volume，目標是「裝一次跨 session／跨專
案／跨日共用」。要同時做兩件事：

**1. 固定 `name: agent-sandbox-mise-cache`**

不設 `name` 時，compose 會冠上 `COMPOSE_PROJECT_NAME` 前綴 → 實際名變成
`agent-sandbox-<日期>_mise-cache`。但 agent-sandbox 函式的 project 名按
日換（見下節），這會導致 **每天一個新的空 volume、舊的永不回收**，跨
日不共用、與目標完全相反。固定 `name:` 後 volume 全域共用，符合原意。

**2. `external: true`**

僅設 `name:` 還不夠。Compose 第一次建這個 volume 時會把當日的 project
名寫進 volume 的 `com.docker.compose.project` label。**下一天** project
名變了 → compose 看到 label 對不上，每次啟動都印警告：

```
WARN[0000] volume "agent-sandbox-mise-cache" already exists but was created
for project "<昨日>" (expected "<今日>"). Use `external: true` to use an
existing volume
```

`external: true` 等於告訴 compose「這 volume 由外部管，你別擁有也別打
label」→ 警告徹底消失、跨日穩定。配套：`agent-sandbox` 函式啟動前會冪等
`podman volume inspect ... || podman volume create ...`，因為 external
意味著 compose 不會自動建。

→ **不要改回 named-by-compose**；不要拿掉 `external: true`。

（原追蹤於 B0014「不再每天一個新 volume」與 B0023「外加 external 收尾
跨日 label 警告」；過程細節見 `_backlog/archive/0002-...`，gitignored。）

## `COMPOSE_PROJECT_NAME=agent-sandbox-<日期>`（由 agent-sandbox 函式設）

每天不同的 project 名是**刻意**的，給三件事用：

1. **network／container 按日隔離**：避免不同日的 session 共用同條
   network、互相看到對方容器。
2. **退出清理用 label 精準匹配**：agent-sandbox 退出時用
   `--filter "label=com.docker.compose.project=<當日 project>"` 找
   剩餘容器，決定要不要刪 network。
3. **歷史除錯**：`podman ps -a --filter "label=..."` 翻得回去看某天
   啟動了什麼。

→ **不要拿掉日期戳**，否則上述三點全破。mise-cache 的 `external: true`
也是為了與此設計共存而設（見上節）。

## `pull_policy: missing` + 不放 `build:` 段

**設定意圖**：compose 永遠不自己 build、也不去 registry pull —— image
必須已備齊在本地，由 `agent-sandbox` 函式在 run 之前用 raw
`podman build` 自己處理好。compose 只負責 `run --rm`。

**為什麼 compose 不負責 build**：podman 在 macOS 用的 docker-compose
外部 provider（v1 classic builder）會**順手把 `:latest` 與所有歷史
repo:tag 也指到剛 build 的 image**，無論你 `image:` 指定的是什麼 tag。
這會破壞 agent-sandbox 函式「具名 tag = 凍結，絕不碰 `:latest`」的核
心紅線（B0029 phase 2 修1 驗測時挖到）。

「函式自己 build」+「compose 只 run」這個切分讓 build 行為完全可控：

- 純啟動（`agent-sandbox [tag]`）：函式**完全不 build**，只查 image 存在
  → `compose run`（run/build 分家，2026-07-03 B0035 起）
- 升級（`agent-sandbox --upgrade`）：函式 `podman build --no-cache -t
  agent-sandbox-claude:latest`，成功後補打版號快照 tag —— `-t` 指什麼
  就只 tag 什麼，版號快照不會被 compose 的副作用 tag 邏輯覆蓋
- 沒設 `pull_policy: missing` 時，image 不存在會先試 registry → denied
  → 雜訊；設了能直接報缺、靜默

→ **不要改成 `always`**，會破壞「不去 registry」的目的。**不要加回
`build:` 段**，否則 compose 又會嘗試自己 build（即使函式已 build 過、
compose 仍會走它的副作用 tag 邏輯）。函式對 build 時機與 tag 的控制依
賴這個切分，相關細節見 `docs/design/agent-sandbox.md`「Tag 控制與升級
（run/build 分家）」。

## 資源／安全限制

- `cap_drop: [ALL]` + `security_opt: [no-new-privileges:true]`：剝奪所
  有 Linux 核心特權，徹底防 SUID 提權
- `mem_limit` / `cpus` / `pids_limit`：防 agent 暴走拖垮 host。三個值自 B0059 起
  改用 `${VAR:-預設}` 插值，由專案 `.agent-sandbox` 的 `[resource]` 段覆寫；
  **compose 檔裡的字面值是預設的唯一真相**，`agent-sandbox` 函式端不得持有第二份。
  預設 `mem_limit: 2g`（2026-09-04 由 4g 調降）—— 依「同時開 N 個 sandbox 也不該
  拖垮 VM」推導：實測開發機的 podman machine 為 7.72 GiB 且**無 swap**，常態同時開
  4 個 sandbox，7.72 ÷ 4 ≈ 1.9 GiB。需要更多的專案用 `[resource]` 自行放寬。
  ⚠️ 原值 4g **沿襲自 B0007 之前的 `deploy:` 區塊、從未經過評估**——B0007 解的是
  「`deploy.resources` 被非 Swarm compose 整段忽略」（當時三個限制根本沒生效），
  它只把值搬到正確欄位讓它們生效，全文沒有一句在討論 4 GiB 夠不夠；本檔舊版那句
  「Mac M2 上 4g 是安全且夠用的下限」是寫文件時加的無來源描述，已移除。
  `cpus` 是 CFS quota 不是 cpuset → 容器內 `nproc` 仍顯示 VM 顆數，要確認實際生效值
  請在容器內 `cat /sys/fs/cgroup/cpu.max`（2 核 = `200000 100000`）。
  `pids_limit` 計的是 task（含執行緒），調高 `cpus` 後平行 build 容易撞到，症狀
  `fork: Resource temporarily unavailable` 不指向設定。
- **不用** `deploy.resources.limits`：後者是 Swarm 專用，非 Swarm 的
  `docker compose up` 會整段忽略；用 Compose v2 service 頂層欄位才是
  單機正式支援

→ 這些值有調整空間（逐專案走 `[resource]` 段），但**不要拿掉這幾個欄位**。
這條紅線自 B0059 起**同時體現在 parser**：`[resource]` 拒收 `0`／負數（`cpus = 0` 在
compose 語意上等於「不設限制」，等同把欄位拿掉），驗證放在 `agent-sandbox` 函式端而
**不外包給 compose provider**——實測本機 provider 是外部 `docker-compose`（cast 失敗
會硬失敗），但 podman-compose 那條路對 `cpus` 的垃圾值與 `0` 是 **fail-open**（旗標整個
不下＝無限制且靜默），對 `pids` 的 `-1`／`0` 則會忠實下成 unlimited。一個 fail-open、
一個訊息不指向 `.agent-sandbox`，兩邊都不能倚賴。（原追蹤於 B0059。）
