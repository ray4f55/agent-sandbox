# 遷移：自動 build → run/build 分家（`--upgrade`）

2026-07-03（B0035）起，`agent-sandbox` 的 run 與 build 徹底分家。本文給
**既有使用者**看：哪些舊行為消失、第一次跑新版要注意什麼。新使用者直接看
README「Quick start」即可，不用讀這篇。

## 行為對照

| 舊行為 | 新行為 |
|---|---|
| `agent-sandbox` 每次啟動都 `podman build`（cached） | **純啟動**：image 在就跑、不在報錯，永不 build |
| `agent-sandbox v1.2.0` 不存在 → 自動 build 該 tag | 不存在 → **報錯**（打錯字不再默默建新 image） |
| 改 Dockerfile → 下次啟動自動生效 | 改動要靠 `agent-sandbox --upgrade`（或手動帶 cache `podman build`，見 README） |
| Dockerfile 變更 + latest 存在 → 互動提示「要備份成版號嗎？」 | 提示消失；`--upgrade` **每次自動**留版號快照（如 `v1.3.0`） |
| 升級 Claude：手動改 Dockerfile 裡 `claude bump` 日期戳 | `agent-sandbox --upgrade` 一鍵（整鏈 no-cache、工具全刷新） |
| build 完直接進容器 | `--upgrade` **只 build 不進容器**；升完照常 `agent-sandbox` 進 |

## 第一次跑新版要做的事

**1. 先跑一次 `agent-sandbox --upgrade`。**

⚠️ 注意：它會**覆蓋現有的 `:latest`**，而舊機制建的 latest **沒有**對應
版號快照。如果現在這顆 latest 是「還能跑、捨不得丟」的狀態，升級前先手動
留一份：

```zsh
podman tag agent-sandbox-claude:latest agent-sandbox-claude:v0.9.0
```

（版號隨意，之後 `agent-sandbox v0.9.0` 就跑得到它。）此後每次 `--upgrade`
都會自動留快照，不再有這個問題。

**2.（可選）清掉退役的 SHA 指紋快取。**

```zsh
rm -rf ~/.cache/agent-sandbox
```

SHA 防呆機制已整組移除，這個資料夾不再被讀寫，留著也只佔幾 byte。

**3. 重新 source 或開新終端機**，讓新函式生效。

## 舊的具名 tag 還能用嗎？

能。純啟動只查 image 存在，舊機制建的 tag（`agent-sandbox v1.0` 之類）照
常 `agent-sandbox v1.0` 跑。只是新的版號快照建議跟著 semver 約定走
（minor = `--upgrade` 自動、major = 手動指定重大改版）。

## 為什麼要改

見 [`docs/design/agent-sandbox.md`](../design/agent-sandbox.md)「Tag 控制
與升級（run/build 分家）」——一句話：舊模型「run 順便 build」需要 SHA 防呆
＋互動提示＋分流表來保安全，且 Claude 出新版時被 build cache 鎖住無正式
升級路；分家後 run 永遠秒起零互動、升級顯式一鍵、每次升級必留 rollback
快照。（原追蹤於 B0035。）
