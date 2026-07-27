# Backlog 索引（自動產生，勿手改 AUTO 區）

本檔是 `_backlog/` 的**自動索引**，由 backlog skill 的 `index` 重生。

> 白話：**backlog ＝ 本地的待辦工作母體**（優化／修復／新需求／安全／
> 雜務／文件…的單一優先清單，含決策史），**不是只有 bug**。它是來源
> 真相；之後可用 `sync` 把項目鏡像成 GitHub Issues（Issues 是匯出去處，
> 不是這份清單本身）。`_backlog/` 刻意不進 git（每位開發者的本地狀態，
> 各人進度不同進 git 只會衝突；需團隊協作的項目走未來的 `sync`）。

**機制規格與協作協定見**
[`.claude/skills/backlog/SKILL.md`](../.claude/skills/backlog/SKILL.md)
（單一真相來源，所有 code agent 共用）。

- 一項目一檔：`<id>-<slug>.md`，frontmatter 放 metadata
- 新需求 / 新問題 → 寫進 [`intake.md`](intake.md)，agent 會整理成正式項目
- 已完成/不採納的歷史項目 → `archive/<段落>/`
- 下方 `<!-- AUTO -->` 區由 `index` 重生，勿手改；此行以上為手寫

<!-- AUTO:BEGIN -->
（尚未產生，執行 `init` 或 `index`）
<!-- AUTO:END -->
