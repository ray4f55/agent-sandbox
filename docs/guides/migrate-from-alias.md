# 從舊 alias 遷移（歷史文件）

> **本檔是歷史遷移指南**，描述早期 `alias cc-container='...'` → `function`
> 的轉換。**該 function 後續再被改名為 `agent-sandbox`**（cc-container →
> agent-sandbox），完整當代遷移路徑見 [`migrate-cc-container-to-agent-sandbox.md`](migrate-cc-container-to-agent-sandbox.md)。
>
> 若你還停在 alias 版,建議直接跳過本檔、改照新指南一步到位遷到
> `agent-sandbox`(本檔的步驟仍可作為「為什麼改 function」的歷史背景參考)。

如果你之前用過早期的 `alias cc-container='...'` 版本，需要手動把舊
alias 換成 `source .../agent-sandbox.sh`（函式名已從 `cc-container` 改為
`agent-sandbox`，且現在改為 source 單一檔而非貼整段函式 —— 見
[`migrate-inline-function-to-sourced-file.md`](migrate-inline-function-to-sourced-file.md)）。
新拿到專案的使用者跳過本檔即可。

## 為什麼改

舊 alias 只能塞一行、無法在容器退出後接續邏輯。新的 function 才能在
`podman compose run --rm` 結束後執行「清孤兒 network」這類後處理。完整
設計理由見 [`docs/design/agent-sandbox.md`](../design/agent-sandbox.md) 的
「為什麼用 function 而非 alias」段。

## 步驟

1. 用編輯器開啟 `~/.zshrc`（不建議用指令增刪，`.zshrc` 通常是手動整理
   過的）
2. 找到舊的 `alias cc-container='...'`，**整段**刪掉。注意它是用 `\`
   折行的，從 `alias cc-container=` 到收尾的單引號 `'` 都要刪
3. 加上一行 `source /path/to/agent-sandbox/agent-sandbox.sh`（函式、補全、
   `alias docker=podman` 現在都在這個檔裡，不再貼整段）
4. 存檔，執行 `source ~/.zshrc` 讓設定生效
5. 驗證：`type agent-sandbox` 應顯示 `agent-sandbox is a shell function`

## 驗證沒有殘留舊行為

換完後第一次跑 `agent-sandbox` 進容器、`exit` 退出，輸出應該看到：

```
🧹 已移除 network: <project>_default
```

這行是 function 才有的退出清理；如果看不到、且 `podman network ls` 還
能看到 `<project>_default` → alias 沒清乾淨或 function 段貼錯位置，重
檢查 `~/.zshrc`。
