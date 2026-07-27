# GitHub CI → GHCR（多架構發佈）— 設計筆記

對應檔：[`.github/workflows/build-images.yml`](../../.github/workflows/build-images.yml)。

本檔說明「CI 自動 build image 推 GHCR」這條管線的關鍵取捨。核心一句話：

> **它是純發佈管線，完全不改本機 `agent-sandbox` 流程。** 本機照舊 `podman
> build`、`pull_policy: missing`、具名 tag 凍結；CI 只是「另外」把同一批
> Dockerfile build 成多架構 image 推到 GHCR，讓人能直接 pull。

## 為何純 additive（不碰既有紅線）

加 registry 發佈本可能撞到三條紅線，這裡刻意都不碰：

- **不改 `docker-compose.yaml`**：`pull_policy: missing`（不去 registry）、無
  `build:` 段照舊。compose 仍只負責 `run --rm` 本機 image。
- **不改 `agent-sandbox.sh`**：本機 build 鏈（`--upgrade`）、凍結語意原封
  不動。**不**在函式加 registry-first / fallback（評估過，使用者選純發佈）。
- **不改 Dockerfile**：CI 用 `docker buildx`、本機用 `podman build`，兩邊共用
  同一批工具無關的 Dockerfile。本專案 Dockerfile **無 `COPY .`**，故
  `context: .` 只為提供 Dockerfile，build 行為單純。

要用 GHCR image 的人手動 pull（步驟見 README「使用 GHCR 預建 image」）。本機
函式只認無 registry 前綴的名字（`agent-sandbox-claude:latest`），所以 pull 後
`podman tag` 成那個名字即可被既有函式使用 —— 不需要函式知道 GHCR 存在。

## 凍結語意在 CI 的對應：git tag

本機「具名 tag = 凍結里程碑」的 CI 等價物是 **git tag**：

| 觸發 | GHCR tag |
|---|---|
| push `main` | `:latest`（rolling）+ `:sha-<short>` |
| push git tag `vX.Y.Z` | `:vX.Y.Z`（凍結） |

由 `docker/metadata-action` 自動生成（`type=raw latest@default-branch` +
`type=ref,event=tag` + `type=sha`）。

**鏈一致性（對應「整鏈共用 image_tag」紅線）**：build addon 時
`--build-arg BASE_IMAGE` **必須指向同一 tag 的 base**。tag push `v1.2.0` 時
addon 要疊在 `agent-sandbox-claude:v1.2.0`（而非 `:latest`），否則 `v1.2.0`
的 base/addon 鏈不一致。workflow 依 `github.ref_type` 推出 base ref（tag 用
`github.ref_name`，其餘用 `latest`）。`addon` job `needs: base`，確保 base 先
推上 GHCR，addon 的 `FROM ${BASE_IMAGE}` 才拉得到。

## 多架構作法：buildx + QEMU（單 job，簡單優先）

`docker/build-push-action` 配 `platforms: linux/amd64,linux/arm64` + QEMU，
一個 job 出 multi-arch manifest。addon 的 `FROM ${BASE_IMAGE}` 由 buildx 依各
平台自動拉對應架構的 base。

選 QEMU 而非 native-runner matrix 的理由：image 極輕（node slim + mise +
claude CLI，**不裝語言**，見 `docs/design/mise.md`），被模擬那一架構的 build
成本可接受，換來最簡單的 YAML。

**更快的替代（先不用）**：native runner matrix（`ubuntu-24.04-arm` +
`ubuntu-latest` 各架構原生 build → 再 merge manifest），public repo 免費但
YAML 較複雜。若日後 build 太慢再升級到這個。

## 其他細節

- **觸發 `paths:` 過濾**：只有 `Dockerfile.*` 或本 workflow 改動才 build，純
  文件 commit 不會浪費 CI。另有 `workflow_dispatch` 手動觸發。
  > ⚠️ **刻意依賴的 GitHub 行為（已查證，勿「修掉」）**：`paths:` 過濾**只**作用於
  > branch push，**對 tag push 不生效** —— tag 一律觸發。這正好是我們要的：main
  > 上 doc-only commit 被擋掉，但 `vX.Y.Z` 凍結 tag 永遠會 build（freeze 不漏）。
  > 不要為了「讓 tag 也吃 paths」去加 `dorny/paths-filter` 之類 —— 會破壞凍結。
- **認證**：`permissions: packages: write` + `docker/login-action` 用內建
  `GITHUB_TOKEN`（同 repo 免 PAT）。
- **image 名**：`ghcr.io/<owner>/agent-sandbox-<base>[-<addon>]`，沿用本機公式
  加 registry 前綴。`github.repository_owner` 須小寫（GHCR 要求；`ray4f55`
  已小寫）。
- **套件 visibility 實測（2026-07-09，B0041 上架時發現，修正原假設）**：原本
  假設「首次 push 後要手動去 Packages 把 visibility 轉 Public」；實測發現
  **repo 先轉 public、CI 才第一次跑並創建套件時，4 個套件直接就是 Public**，
  不需手動切。推測：套件在創建當下會繼承來源 repo 當時的可見性。若順序反過來
  （CI 在 repo 還 private 時就先跑過），套件可能維持 Private，屆時仍需手動去
  Packages 逐一轉 Public——遇到這情況才需要這一步，非每次上架必做。
- **新增 base/addon**：在 workflow 的 matrix 加一行（CI 用顯式 matrix，不像本機
  靠 glob 自動發現 —— 加變體時記得兩邊同步，workflow 內已留註解提醒）。

（原追蹤於本次討論，2026-06-15 落地。範圍決策：純發佈不改本機、arm64+amd64
多架構、base+addon 都建。）
