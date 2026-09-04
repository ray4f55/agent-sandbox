# 容器記憶體預設由 4GB 調降為 2GB（B0059）

**適用對象**：2026-09-04 之前就在用 agent-sandbox 的人。`git pull` 之後容器的記憶體上限
會從 4GB 變成 **2GB**。

## 會發生什麼

沙盒容器預設最多只能用 2GB 記憶體。原本跑得動的 build／測試如果吃超過 2GB，會被
**cgroup 砍掉**——而且症狀通常不明顯：process 突然消失、build 中斷，**不會有一行訊息說
是記憶體不夠**。

啟動時會印出目前生效的值，可以直接確認：

```
⚙️  資源限制：CPU 2 核、記憶體 2.00 GiB、PID 512（皆為預設值）
```

## 要改回 4GB 怎麼做

**不要去改 `docker-compose.yaml`**（那是共用檔，改了對所有專案、所有人生效）。在**該專案
根目錄**的 `.agent-sandbox` 加：

```ini
[resource]
memory = 4g
```

下次啟動即生效，不需要 `--upgrade`。啟動時會看到該值標上 `*` 表示來自專案設定：

```
⚙️  資源限制：CPU 2 核、記憶體 4.00 GiB*、PID 512   （* = 專案 [resource] 段，其餘為預設）
```

CPU 與 PID 上限同樣可以在這一段調（`cpus = 4`、`pids = 1024`），詳見 README
「逐專案資源限制」。

## 為什麼要調降

`mem_limit` 是**上限不是預約**——設 4GB 不會佔掉 4GB，所以調降**不會釋放任何記憶體**。
真正的收益是**把不受控的失敗換成受控的失敗**：

| 觸發 | 結果 |
|---|---|
| 容器撞到**自己的** `mem_limit` | cgroup 只砍該容器內的 process，其他容器不受影響、原因可歸因 |
| 所有容器**實際**用量加總超過 VM 記憶體 | **VM 層 OOM，砍誰不受控** —— 可能砍掉另一個 session 跑到一半的 build |

上限調低，等於讓第二種在數學上更難發生。數字依「同時開 N 個 sandbox 也不該拖垮 VM」推導：
開發機的 podman machine 為 7.72 GiB 且**無 swap**，常態同時開 4 個 sandbox，
7.72 ÷ 4 ≈ 1.9 GiB。

順帶說明：舊的 4GB **從來沒有被評估過**——它沿襲自 B0007 之前那個根本沒生效的
`deploy:` 區塊（`deploy.resources.limits` 是 Swarm 專用語法，非 Swarm 的 compose 會整段
忽略），B0007 只是把值搬到正確欄位讓它們真的生效，並沒有討論過 4GB 夠不夠。

（原追蹤於 B0059。設計取捨見 `docs/design/docker-compose.md`「資源／安全限制」與
`docs/design/agent-sandbox.md`「逐專案資源限制」。）
