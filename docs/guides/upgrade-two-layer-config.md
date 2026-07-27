# 升級到 `.agent-sandbox` 新格式 + git 身分改回標準 gitconfig

這次有兩個 user-facing 變更。多數人**只受第 1 點**影響（且只有你寫過
`.agent-sandbox` 的 `[mount]` 段才要動）；第 2 點只影響「手動編過
`home/default/.gitconfig`，或試用過早期 `[git] identity` 草案」的人。

## 1. `[mount]` 改成 `path = <spec>`（key = value 格式）

`.agent-sandbox` 全面改成「每行 `key = value`」，`[mount]` 的裸 spec 行要加
`path = ` 前綴。

**之前**：

```ini
[mount]
../backend
../shared:shared:ro
```

**現在**：

```ini
[mount]
path = ../backend
path = ../shared:shared:ro
```

spec 格式本身（`<host>[:<container>][:ro]`、裸別名、`:ro` 規則）完全不變，只是
每行前面多 `path = `。CLI 的 `-m` 不受影響（照舊 `-m ../backend`）。

> 為什麼改：要在 `[mount]` 加選項（如下面的 `inherit-global`）又不想引入保留字/
> 特殊符號，最乾淨的是全段統一 key=value。詳見
> [`docs/design/agent-sandbox.md`](../design/agent-sandbox.md)「統一設定檔」段。

### 新增能力（順便了解）

- **全域 `[mount]`**：把 `[mount]` 寫進 agent-sandbox 工具目錄的 `.agent-sandbox`，
  每個 sandbox 都會掛（路徑須絕對/`~`）。全域 + 專案 + CLI 全部累加。
- **`inherit-global = false`**：某專案不想繼承全域 mount，在它的 `[mount]` 加這行。
- **`--no-config-mounts`**：某次想忽略所有設定檔 mount、只用 `-m`。

## 2. 容器 git 身分：改回直接編 `home/default/.gitconfig`

容器 git 身分**不再有任何 `.agent-sandbox` 設定**（早期 `[git] identity = host|off|
Name <email>` 是開發中途的草案，已移除）。身分就是 `home/default/.gitconfig` 這個
**標準 git 檔**：

- **首次**（檔案不存在）`agent-sandbox` 或 `init.sh --apply` 會從你 host 的
  `git config --global` 身分 seed 一份；**之後工具不再碰它**，是你自己的檔。
- 它若已存在（你之前就有），**完全不受影響**，照用。

### 要做什麼

| 你的情況 | 動作 |
|---|---|
| 沒寫過 `[git]` 段、沒手改過 gitconfig | **什麼都不用做** |
| 試過草案的 `[git] identity = …` | 把該段從 `.agent-sandbox` 刪掉（留著會被 ⚠️ 提示略過）。要固定身分就直接寫進 `home/default/.gitconfig` |
| 想固定容器身分 | 直接編 `home/default/.gitconfig` 的 `[user]`（工具不再覆寫） |
| 想完全不帶身分 | 把 `home/default/.gitconfig` 清空（空檔不會被回填） |
| 某 repo 要不同身分 | 該 repo `git config --local user.name/email`（git 原生，最乾淨） |

## 驗證

```bash
agent-sandbox        # 啟動
# 容器內：
git config --get user.name && git config --get user.email
cat /workspace/<你的專案>/...   # 確認額外掛載有掛上（看啟動的 📎 清單與來源標示）
```
