# 遷移：`home/node/` → `home/default/`（多身分機制，`--identity`）

2026-07-24（B0015）起，host 端身分資料夾改用 `home/<identity>/` 目錄樹
（可用 `--identity <name>` 切換不同的一整組憑證），取代原本單一寫死的
`home/node/`；不帶 `--identity` 時的預設身分資料夾叫 `home/default/`。

本文給**本機已經有 `home/node/`（含真實 `.claude`／`.codex`／`.gitconfig`
等憑證）的既有使用者**看。全新 clone、還沒建過任何 `home/` 內容的使用者
跳過本檔即可，直接看 README「Quick start」與「多身分」段。

## ⚠️ 沒有自動搬移，且錯誤訊息的字面建議會誤導你

`git pull` 這次更新後，程式碼**不會**自動偵測或搬移舊的 `home/node/`。
如果你直接跑 `agent-sandbox`，會看到：

```
❌ 未知 --identity: default（找不到 <repo>/home/default）
   新增身分：mkdir -p <repo>/home/default 後重跑即可。
```

**不要照字面直接 `mkdir -p home/default`**——那只會建一個空資料夾，你在
`home/node/` 裡的真實憑證不會自動搬過去（沒有遺失，只是沒人告訴你要搬，
容易誤以為要重新登入）。正確做法是**把舊資料夾整個改名**，見下方步驟。

## 步驟

### 1. 確認你有沒有受影響

```zsh
ls home/
```

- 只看到 `default/`（或本來就是空的）→ 已經是新結構，或是全新環境，
  **不用做任何事**，跳過本檔。
- 看到 `node/` → 有受影響，繼續下一步。

### 2. 把舊資料夾改名成新名字

```zsh
cd /path/to/agent-sandbox
mv home/node home/default
```

`.credentials.json`／`.gitconfig`／`.config/mise` 等內容原樣保留，純粹
改資料夾名稱，不影響容器內任何路徑（身分資料的容器內掛載目標一直是固定
的 `$AGENT_HOME`，只有 host 端來源路徑會變，見
[`docs/design/agent-sandbox.md`](../design/agent-sandbox.md)「多身分」段）。

### 3. 驗證

```zsh
agent-sandbox
```

應該正常啟動，看到 `🪪 使用身分：default（home/default/）`；容器內
`git config --get user.name` 應該顯示你原本設定的身分（如果之前有）；
`claude`／`codex` 應該維持登入狀態，不需要重新驗證。

## 如果你已經照錯誤訊息字面 `mkdir -p home/default` 建出空資料夾

先確認新建的 `home/default/` 底下是空的（沒有真實憑證），刪掉它，再照
上面步驟 2 重新 `mv` 一次：

```zsh
rmdir home/default   # 或確認內容為空後 rm -rf home/default
mv home/node home/default
```

## 想順便用多身分機制（例如另建一個帶 SSH 金鑰的維運身分）？

改名完成、確認 `agent-sandbox` 正常運作後，可以參考 README「多身分」段
用 `--identity <name>` 建立額外的身分資料夾——這是全新功能，跟本文的
「搬移既有資料」是兩件事，不衝突。

## 為什麼要改

見 [`docs/design/agent-sandbox.md`](../design/agent-sandbox.md)「多身分」
段——單一身分資料夾無法區隔「開發身分不該帶長期憑證」與「維運身分需要
SSH 金鑰但該少裝工具」這類風險分級需求；`default` 這個名字本身也比舊名
`node`（純粹繼承自 base image 曾用 `node:*-slim` 預設帳號的巧合）更精確
對應「不帶 `--identity` 時的預設身分」這個角色。（原追蹤於 B0015。）
