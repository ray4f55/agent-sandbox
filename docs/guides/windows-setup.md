# Windows 設定（走 WSL2）

agent-sandbox v1 **不提供原生 Windows 支援**（不附 PowerShell 版的 `init.ps1`）。
Windows 使用者請走 **WSL2**——這是受支援的路徑，且不需任何額外程式碼。

## 為什麼是 WSL2

`agent-sandbox.sh` 是 zsh 函式、`init.sh` 是 bash 腳本，兩者都針對
macOS/Linux；容器與 podman 在 WSL2 的 Linux 環境裡跑得最自然。維護兩套
（再加一份 PowerShell 的標記注入與相依矩陣）成本高、效益低，故 v1 先不做。

## 步驟

1. 安裝 WSL2 與一個 Linux 發行版（如 Ubuntu）：
   ```powershell
   wsl --install
   ```
2. **在 WSL2 的 Linux 檔案系統內** clone 本 repo（不要放在 `/mnt/c/...`，
   跨界 I/O 慢且權限行為不同）：
   ```bash
   git clone <repo> ~/agent-sandbox && cd ~/agent-sandbox
   ```
3. 在該 Linux 發行版內安裝 podman（如 Ubuntu）：
   ```bash
   sudo apt-get update && sudo apt-get install -y podman podman-compose
   ```
4. 照 Linux 流程跑 `init.sh`：
   ```bash
   ./init.sh            # 檢查
   ./init.sh --apply    # 套用（會寫進 WSL 內的 ~/.zshrc，非 Windows 端）
   ```
5. 之後就跟 Linux 完全一樣：`source ~/.zshrc` → `agent-sandbox`。

> 註：marker 區塊與 zsh 函式都落在 **WSL 發行版內**的 `~/.zshrc`，與 Windows
> 端設定無關。

## 未來

若日後要做原生 Windows，`init.sh` 的相依矩陣／標記注入／徵詢 UX 三段可作為
`init.ps1` 的對照藍本。目前優先推 WSL2。
