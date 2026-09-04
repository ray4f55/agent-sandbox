# CLAUDE.md — 設計紅線索引

讀本檔的目的：開 session 第一眼快速腦補本專案的設計取捨，**避免動到刻
意設計的部分**。

`@` 開頭的行是 Claude Code 自動 inline 載入的細節檔；人類讀者也可直接
打開讀，是 committed 的 markdown 文件。

## 文件分工

- `README.md` — 使用方式（指令、shell 函式、操作步驟）
- `CLAUDE.md`（本檔）+ `docs/design/*.md` — 設計取捨與紅線（為什麼這樣設）
- `docs/examples/` — 可複製的設定範例（mise.toml 等）
- `docs/reference/` — 查表（env vars、命名約定、檔案結構等）
- `_backlog/`（gitignored）— 過程史與進行中決策；不在 repo 內

## 寫程式碼時的紀律

- 修改任何標 `(see docs/design/...)` 的程式碼前，**先讀那個 design 檔**
- 寫新的「為什麼這樣」內聯註解時，最多 2 行 + `(see docs/design/<topic>.md)`；
  想寫更長就去 design 檔寫
- 重大決策結案後（不論 type）若結論對未來維護者有公開價值，把結論一段
  抽進 `docs/design/<topic>.md`，附「（原追蹤於 Bxxxx）」provenance
- 做 **user-facing breaking 變更**（指令／用法／檔案結構改、舊用法失效）
  時，在 `docs/guides/` 新增遷移文件（檔名建議 `migrate-<from>-<to>.md`
  或 `upgrade-<feature>.md`），讓既有使用者有路徑可循。README 本身不
  載入遷移內容（新使用者用不到）

## 主題紅線

### docker-compose.yaml — 詳見 @docs/design/docker-compose.md

- mise-cache 是 `external: true` + 固定 `name` → **不要改回 named-by-compose**
- `COMPOSE_PROJECT_NAME` 帶日期戳（agent-sandbox 設）→ **不要拿掉日期**
- `pull_policy: missing` → **不要改 `always`**

@docs/design/docker-compose.md

### agent-sandbox shell 函式 — 詳見 @docs/design/agent-sandbox.md

- 是 function 而非 alias → **不要改回 alias**（退出後接續邏輯需要 function）
- 三組變數命名各司其職（proj_basename / proj_name / container_name）→ **不要混用**
- **run/build 分家**（B0035）：run 永不 build、零互動；`--upgrade` 是唯一 build
  入口（no-cache 整鏈重建 + 自動留 semver 版號快照）→ **不要在 run 路徑加回
  build 或互動提示**；版號快照不可覆蓋
- 退出清孤兒 network 不清 volume → **預設保留 volume 資料**
- `.agent-sandbox` 設定檔：全面 `key = value`（`[mount]` 用 `path =`）；`[mount]`
  全域（工具目錄）+ 專案 + CLI **累加**、`[image]`/`[identity]`/`[resource]` 專案 only。全域
  mount 開放是 B0033 解除 B0024 紅線（配套：來源標示 + `inherit-global`/
  `--no-config-mounts`）→ **改 mount 解析要保留來源可見性與逃生口**
- `[resource]` 段（B0059）：逐專案資源上限（`cpus`/`memory`/`pids`），compose 三行改
  `${VAR:-預設}` 插值 → **預設值的唯一真相是 `docker-compose.yaml` 的字面值，函式端
  不得持有第二份**；三個變數**只在有覆寫時才傳**且用 `env -u` 清 ambient（傳空字串會
  讓 podman-compose 的 `-m` 整個不下＝限制靜默消失）→ **不要改成一律傳**
- 資源值的格式驗證**不可外包給 compose provider**（`cpus` 的垃圾值與 `0` 在
  podman-compose 是 fail-open＝無限制且靜默；`pids` 的 `-1`/`0` 會被忠實下成 unlimited），
  且格式比對擋不住 `0` → **「數值 > 0」必須是獨立一步**，少了它就是繞過「三個資源欄位
  不可拿掉」紅線的後門
- `[identity]` 段（B0049）：identity 落定邏輯留在
  `_agent-sandbox-apply-identity-config` 內（仿 `base`，不在主函式提早寫死
  `default`）→ **`--upgrade`/`--new-identity` 的旗標白名單檢查必須早於這個
  函式呼叫，否則專案帶 `[identity]` 段時會誤判成『有給 --identity』**
- 容器 git 身分 = `home/<identity>/.gitconfig` 標準 git 檔（缺檔才從 host seed、
  `-e` 判存在、之後不碰）→ **不要改回每次重寫，也不要重新引入 `[git]` identity 段**
- 容器內裸 `ssh` 找 `~/.ssh` 走系統層級 `/etc/ssh/ssh_config`（entrypoint.sh
  動態掃描身分 `.ssh/` 產生 `IdentityFile` + `Include` 使用者 config，兩份
  `Dockerfile.base.*` 開放 `chmod 666 /etc/ssh/ssh_config`）修正 pw_dir 錯誤時
  的 `~` 展開（B0050）→ **不要改回動 `/etc/passwd` 的 `pw_dir`**（該路已評估
  過風險更高，見 B0044/B0050 設計檔）

@docs/design/agent-sandbox.md

### mise（容器內語言管理）— 詳見 @docs/design/mise.md

- image **不預裝任何語言** → **不要把語言裝回 Dockerfile**（baked-in 多語言會復發舊問題）
- mise 本體用 `MISE_INSTALL_MUSL=1` 強制 musl 靜態版 → **不要拿掉**（安裝腳本
  自動偵測在 glibc 容器永遠選 gnu，gnu 有 glibc 下限、`--upgrade` 會再撞；
  舊 `MISE_LIBC` 是腳本不認的無效變數）
- mise trust 紀錄（`~/.local/state/mise/`）刻意不持久化 → **不要把這目錄 bind 出去**（路徑撞名 + 惡意 mise.toml hook = token 外洩風險）
- 安裝結果走 `mise-cache` external volume，跨 session/專案/日共用

@docs/design/mise.md

### CI/GHCR 發佈 — 詳見 @docs/design/ci-ghcr.md

- `.github/workflows/build-images.yml` 是**純發佈**管線：CI build 多架構
  （arm64+amd64）image 推 GHCR，**完全不改本機 build 與 compose**（`pull_policy:
  missing`、函式 `--upgrade` 的 `podman build`、版號快照凍結全部照舊）→
  **不要為了 CI 動本機流程**
- 凍結語意對應 git tag；addon 的 `BASE_IMAGE` 須綁**同一 tag** 的 base（鏈一致性）
  → **改 workflow 要保留 base ref 隨 tag 走**

@docs/design/ci-ghcr.md
