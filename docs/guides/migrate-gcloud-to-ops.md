# 遷移：`--addon gcloud` → `--addon ops`（B0062）

2026-09-09（B0062）起，`Dockerfile.addon.gcloud` 併入用途型的
`Dockerfile.addon.ops`（Google Cloud CLI ＋ Ansible），image 名由
`agent-sandbox-<base>-gcloud` 改為 `agent-sandbox-<base>-ops`，版本記錄檔由
`/etc/gcloud-version` 改為逐工具一行的 `/etc/ops-tools-version`。

本文給**已經用 `--addon gcloud` 建過鏈、或專案 `.agent-sandbox` 寫了
`addon = gcloud` 的既有使用者**看。沒用過 gcloud addon 的使用者跳過本檔，
直接看 README「進階：Add-on 變體」的「用 ops」段。

## 會發生什麼

`git pull` 之後 `Dockerfile.addon.gcloud` 不存在了（函式靠
`Dockerfile.addon.*` glob 發現可用 addon）：

- `agent-sandbox --addon gcloud` → `❌ 未知 --addon: gcloud（找不到 …/Dockerfile.addon.gcloud）`。
- 專案 `.agent-sandbox` 的 `[image]` 段有 `addon = gcloud` → 同樣報錯，訊息
  會註明來自 `.agent-sandbox [image] 段`。
- 本機已建好的 `agent-sandbox-<base>-gcloud:*` image **不會被刪**，但
  `--addon` 旗標已經指不到它（run 只認 `agent-sandbox-<base>-<addon>` 這個
  公式算出來的名字）。
- 登入態 `home/<identity>/.config/gcloud/` **原樣保留**，換 addon 不用重新
  `gcloud auth login`。

## 步驟

### 1. 改設定檔（只有寫了 `[image]` 段的專案需要）

```ini
[image]
addon = ops        # 原本是 addon = gcloud
```

### 2. 重建鏈

```zsh
agent-sandbox --upgrade --addon ops        # codex base：--base codex --addon ops
```

比原本的 gcloud 鏈多裝 Ansible（uv ＋ 獨立 Python ＋ ansible-core，約
+140 MB），時間多幾分鐘。`--upgrade` 照舊自動留版號快照。

### 3. 啟動並驗證

```zsh
agent-sandbox --identity ops --addon ops
# 容器內：
cat /etc/ops-tools-version     # gcloud／ansible-core／uv／Python 各一行 + build date
gcloud auth list               # 登入態應仍在
ansible --version
```

第一次啟動時函式會自動補建 `home/<identity>/.ansible/`（Ansible 的
collections／Galaxy token 持久化在這裡；`agent-sandbox --new-identity <name>`
重跑一次也會逐項列出它的狀態）。

### 4. 清掉舊 image（可選）

```zsh
podman images --filter 'reference=agent-sandbox-*-gcloud'
podman rmi agent-sandbox-claude-gcloud:latest   # 逐一刪；凍結版號 tag 想留就留
```

GHCR 上既有的 `ghcr.io/<owner>/agent-sandbox-<base>-gcloud` 套件不再更新，
之後 CI 只推 `agent-sandbox-<base>-ops`；用 GHCR 預建 image 的人改 pull
`agent-sandbox-<base>-ops` 再 `podman tag` 成本機名字（步驟同 README
「使用 GHCR 預建 image」）。

> 為什麼合併、為什麼 Ansible 這樣裝：見
> [`docs/design/agent-sandbox.md`](../design/agent-sandbox.md)「ops addon」章節。
