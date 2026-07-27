# mise-cache volume 管理

語言安裝結果存在固定名 `agent-sandbox-mise-cache` 的 podman volume，跨
session／專案／日共用。由 `agent-sandbox` 啟動時自動冪等建立（手動清掉
下次啟動會自動補回空 volume）。

設計取捨見 [`docs/design/docker-compose.md`](../design/docker-compose.md)
與 [`docs/design/mise.md`](../design/mise.md)。

> 第一次跑 `mise install` 某語言要花十幾秒到一分多鐘（看語言、版本）。
> 同樣的 `(語言, 版本)` 第二次起秒用，因為 mise 看到 `installs/` 已有
> 就直接拿。

## 查看

```zsh
# cache volume 在 host 上的實際路徑
podman volume inspect agent-sandbox-mise-cache --format '{{.Mountpoint}}'

# cache 用了多少空間
du -sh "$(podman volume inspect agent-sandbox-mise-cache --format '{{.Mountpoint}}')"

# cache 裡裝了哪些語言／版本
podman volume inspect agent-sandbox-mise-cache --format '{{.Mountpoint}}' \
  | xargs -I{} ls -1 {}/installs
```

## 清理

```zsh
# 完全清掉 cache（下次啟動容器後 agent-sandbox 會自動建空 volume；語言要重裝）
podman volume rm agent-sandbox-mise-cache
```

只想清某個語言 / 版本，**在容器內**用 mise 自己的指令：

```zsh
# 例：清過時的 python 3.10
mise uninstall python@3.10
```

更多通用 podman 清理操作（network、compose project、批次清等）見
[`docs/guides/cleanup.md`](cleanup.md)。
