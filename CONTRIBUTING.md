# 貢獻指南（CONTRIBUTING）

`agent-sandbox` 是一個給 AI Agent 用的拋棄式隔離容器沙盒（podman）。
歡迎貢獻。本指南是貢獻與審核的單一依據：維護者據此客觀地受理或退回 PR。

## 開始之前

- 本專案核心是 `Dockerfile` 與 `docker-compose.yaml`。修改與此相關的
  改動，請在本機實際**重建 image 並啟動容器驗證**後再送 PR。
- 非瑣碎的改動，建議先開一個 issue 討論方向，避免白做。

## 硬規則（PR 違反即退回）

維護者逐條對照；任一不符即可直接退回並指明條目。

1. **不得提交被 `.gitignore` 排除的檔**：個人設定、暫存、憑證、編輯器
   設定等（如 `home/`、`.DS_Store`、`.vscode/`、以底線開頭的個人目錄）
   一律不進 PR。
2. **動 `Dockerfile`／`docker-compose.yaml` 的 PR 必須附「實際 rebuild
   ＋功能驗證」**：重建 image、在新容器內驗證行為（版本／掛載／實跑）。
   只寫「應該可以」不收；PR 內須寫明你怎麼驗的。
3. **README／使用者文件保持以使用者為中心**：設計理由、取捨寫在 PR／
   commit 訊息裡，不要灌進使用者文件。
4. **一個 PR 只做一件事**，範圍單一、可獨立審查。

## Commit／分支慣例

- Commit 訊息採 conventional 風格：`type(scope): 摘要`
  （`fix`／`feat`／`chore`／`docs`／`refactor`…），主體說明「為何」。
- 從 `dev` 開分支作業，PR 對 `dev`（整合分支，通過驗證後才會合併進
  `main`）；勿直接 push 到 `main` 或 `dev`。
- 使用**你自己的 git 身分**；不得冒用他人或與本人無關的帳號 email。
- AI 協作的 commit 請附 `Co-Authored-By:` trailer 標明。

## 提交流程

1. Fork／開分支。
2. 一個 PR 對應一件事；描述內寫明：**解決什麼、為什麼、怎麼做、
   如何驗證**（尤其 Dockerfile／compose 類），並連結相關 issue。
3. 送出前自審下方「審核準則」全數通過。

## 審核準則（受理／退回）

維護者逐項檢查，任一不符即退回並引用條號：

- [ ] 無被 `.gitignore` 排除的個人／暫存／憑證檔
- [ ] Dockerfile／compose 改動附實際 rebuild ＋驗證結果
- [ ] 未把設計理由灌進使用者文件
- [ ] commit 訊息合慣例、使用本人身分
- [ ] 範圍單一、可獨立審查、（如有）連結對應 issue

## 行為準則

以尊重、就事論事為原則協作。詳見 `CODE_OF_CONDUCT.md`（若存在）。

## 授權

對本專案的貢獻，視為以本專案 `LICENSE` 所載授權條款釋出。
