# mise — 設計筆記

對應檔：`Dockerfile`（裝 mise 本身）、`docker-compose.yaml`（bind mount
mise 全域 config + mise-cache volume）、容器內各專案 `mise.toml`。

本檔說明 mise 在本沙盒內的設計取捨。

## image 不預裝任何語言

`Dockerfile` 只裝 Node + Claude CLI + mise **本身**，**完全不 baked-in**
任何語言 runtime（Python、Go、.NET…）。

**為什麼**：

1. **image 體積**：早期 baked-in 多語言一次裝齊，image 漲到數 GB；大多
   session 用不到那些語言、純死重。
2. **更新成本**：image 內版本被凍結；要升 Python 得重 build 整個 image。
3. **跨專案污染**：每個專案 mise.toml 不同；baked-in 強迫所有 session
   都拖著全部語言。

**新模式**：image 極簡，語言由各專案 `mise.toml` 在容器內動態安裝；安裝
結果持久化在 mise-cache volume 跨 session/專案/日共用。

→ **不要把語言裝回 Dockerfile**。要新增工具走 mise.toml 路徑、不要走
Dockerfile。

> **紅線的範圍（B0062 補述）**：這條管的是「給專案用的語言 runtime」——
> base 不裝、專案的 Python／Go／Node 一律走 mise.toml。addon 裡**工具自己的
> 直譯器**不在此列：`ops` addon 的 gcloud deb 硬相依 Debian 系統 python3
> （動不了）、Ansible 用 uv 管理的獨立 Python（收在 `$AGENT_TOOLS`、不上
> PATH）。它們是那個工具的內部零件、不是給專案寫程式用的，也**不是「base
> 可以裝語言」的先例**。判斷法：專案的 mise.toml 要不要看到它？不要 → 是
> 工具內部相依，可以留在 addon 裡；要 → 走 mise。（原追蹤於 B0062；細節見
> agent-sandbox.md「ops addon」章節。）

## mise 本體用 musl 靜態版（`MISE_INSTALL_MUSL=1`）

mise 是「build 當下最新」安裝（同 Claude）。官方安裝腳本（`mise.run`）挑
binary 的邏輯：`MISE_INSTALL_MUSL=1` → musl 靜態版；否則**自動偵測**（看
`/bin/ls` 是否 musl 連結——Debian 上不是 → 選 gnu 版）。gnu 版動態連結容器
的 glibc、**有版本下限**（binary 在哪版 glibc 環境編譯，執行就至少要那版）；
musl 版把 C 函式庫靜態烤進 binary、對系統 libc 零依賴。

2026-07-03 `agent-sandbox --upgrade` 實測撞牆：mise 上游抬高編譯環境，最新
gnu 版要求 GLIBC ≥ 2.38，base（node:20-slim = Debian bookworm）只有 2.36
→ mise 完全跑不起來（`GLIBC_2.39 not found`）。改 `MISE_INSTALL_MUSL=1`
強制 musl 版根治：不管 mise 上游未來怎麼換編譯環境，升級抓到的新版永遠跑得動。

**歷史陷阱**：早期 Dockerfile 寫的是 `ENV MISE_LIBC=gnu`——安裝腳本**根本
不認這個變數**，它一直是無效設定；先前能跑是「自動偵測選 gnu ＋ 當時 gnu 版
還相容」的巧合。第一次修復曾把它改成 `MISE_LIBC=musl`，同樣無效（實測仍裝
gnu 版），才回頭讀安裝腳本原始碼找到正確變數。教訓與「compose/podman 行為
先驗證不假設」同款：**上游腳本認什麼變數，讀原始碼驗證，別看名字猜**。

範圍：此設定**只影響 mise 本體**；mise 安裝的語言是各語言自己的發行檔，在
容器內仍按 glibc 環境自動選對應版本，不受影響。musl 的實務差異（malloc
效能、DNS 邊角行為）對工具管理器無感。

→ **不要拿掉 `MISE_INSTALL_MUSL=1` 或改回依賴自動偵測**（自動偵測在 glibc
容器裡永遠選 gnu → glibc 下限問題必復發）。（原追蹤於 B0035 host 實測；
2026-07-03。）

## mise trust 不持久化（安全考量）

容器內 `~/.local/state/mise/`（mise trust 紀錄存放處）**刻意不 bind
mount 出去**，每次 session 結束就消失。

**為什麼**：mise trust 是「目錄路徑」級別。容器內 workspace 永遠掛在
`/workspace/<basename>`，路徑空間可能撞名（兩個專案 basename 相同就被
視為同一路徑）。如果 trust 持久化：

1. 你信任 A 專案的 mise.toml → state 寫死「`/workspace/foo` 已信任」
2. 明天掛載 B 專案（basename 也叫 foo）→ 自動視為已信任
3. B 是惡意的 mise.toml（在 `[hooks]` 偷讀 `~/.claude` token、外洩）
4. 你不知情就執行了它

→ **不要把 `~/.local/state/mise/` bind 出去**。每 session 重 `mise trust`
一次是設計，不是 bug。

代價：每次進新 session 都得 `mise trust` 一下。換來「惡意 mise.toml 透
過 hook 攻擊」這條的零風險。

## mise-cache volume：external + 固定 name

語言安裝結果持久化在 `agent-sandbox-mise-cache` volume，跨 session/專
案/日共用。

設計細節（external 為何、name 為何固定、cc-container 怎麼 ensure）見：

- [docker-compose.md](docker-compose.md) 的 mise-cache volume 章節
- [cc-container.md](cc-container.md) 的「mise-cache volume ensure」章節

本檔只列「**從 mise 視角看到什麼**」：

- mise 把語言裝在 `$MISE_DATA_DIR/installs/<lang>/<version>/`
  （本沙盒把 `MISE_DATA_DIR` 設為 `$AGENT_TOOLS/mise-data`，即
  `/opt/agent-tools/mise-data`，正是 mise-cache volume 掛入的位置。
  B0043 前這裡是 `/home/node/.local/share/mise`——mise 資料屬工具快取
  非身分資料，已搬出 `$HOME` 那棵樹，理由見
  `docs/design/agent-sandbox.md`「身分資料與工具安裝路徑分離」）
- `installs/<lang>/<version>/` 存在 → mise 直接拿、不重裝，這就是「跨
  session 秒用」的根因
- 同一 `(語言, 版本)` 對只佔一份儲存；多專案用同版完全共用同一份檔案

## 容器內主要操作模式

| 情境 | 指令 |
|---|---|
| 信任已存在的 mise.toml | `mise trust` |
| 安裝該 mise.toml 列的全部語言 | `mise install` |
| 從零起一個專案的 mise 設定 | `mise use python@3.11`（`use` 自建的 toml 不需 trust） |
| 看當前裝了什麼 | `mise ls` |
| 清掉某語言版本 | `mise uninstall python@3.10` |
| 列出可用版本 | `mise ls-remote python` |

> 第一次 `mise install` 某語言要花十幾秒到一分多鐘（看語言、版本）；同
> `(語言, 版本)` 第二次起秒用（cache hit）。

## 與 docker-compose / cc-container 的職責切割

| 機制 | 職責 |
|---|---|
| `Dockerfile` | 裝 mise 本身、設 `MISE_DATA_DIR`、`mise activate bash` 入 bashrc |
| `docker-compose.yaml` | mise-cache volume 宣告（external + name）；mise 全域 config bind mount |
| `cc-container` 函式 | mise-cache volume ensure（inspect or create） |
| 容器內 mise | 讀 mise.toml、安裝語言、解析符號版本到具體版本、寫入 mise-cache |

→ 改 mise 相關行為前先想「這是哪一層的事」，再去對應檔案改。

## 失敗排查

- `mise trust` 卡住或拒絕 → 看 mise.toml 是否含 `[hooks]` 或其他高權限
  指令（mise 設計上對這些會強制要求 trust）
- 安裝過的語言「不見了」 → 檢查 mise-cache volume 是否被誤刪：
  ```zsh
  podman volume ls | grep agent-sandbox-mise-cache
  ```
  沒了的話 `cc-container` 下次啟動會自動建空的、語言要重灌
- 想完全重置 → 見 [`docs/guides/cleanup.md`](../guides/cleanup.md) 與 README 的
  mise-cache volume 管理段
