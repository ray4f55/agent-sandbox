#!/usr/bin/env node
// backlog.mjs — backlog 機制的確定性工具（零第三方依賴，跨平台）。
//
// 這支 script 是 backlog skill 的「快路徑」：有 node 就用它，保證多人 / 多
// agent 操作結果一致（id 配號、index 冪等重生、封存搬移都確定性）。沒有
// node 時，agent 應改照 SKILL.md 的精確規格徒手執行，結果須與本 script 等價。
//
// 重要：script 本身「無狀態」。它操作的是「當前專案」的 _backlog/，不是
// script 自己的安裝位置（skill 在 .claude/skills/backlog/，script 在其
// scripts/ 子目錄；資料在各專案根）。專案根解析順序：--root 參數 > 環境
// 變數 BACKLOG_ROOT > 從 cwd 往上找含 _backlog/ 的祖先 > cwd（首次使用、
// 尚無 _backlog/ 時就建在 cwd）。
//
// 建議以 `node ${CLAUDE_SKILL_DIR}/scripts/backlog.mjs <子命令>` 呼叫，
// 跨 cwd / 跨安裝層（專案層、user 層、plugin）都成立。
// 子命令：new / index / archive <slug> [--commit] / sync（保留待 git）

import { readFileSync, writeFileSync, readdirSync, mkdirSync, rmSync, statSync, existsSync } from "node:fs";
import { join, basename, relative, resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

// 顯示用：標記/footer 用「與安裝位置無關」的中性標籤（不寫死路徑——
// skill 可裝在專案層/user 層/plugin，寫死路徑會誤導）。usage 範例則用
// 官方建議的 ${CLAUDE_SKILL_DIR} 引用（字面字串，非此處 JS 內插）。
const LABEL = "backlog skill";
const INVOKE = "node ${CLAUDE_SKILL_DIR}/scripts/backlog.mjs";
// 本 skill 的 assets/（bootstrap 模板所在）：由 script 自身位置往上推，與
// cwd / 資料專案根無關。scripts/backlog.mjs → 上一層 = skill 根 → assets/
const ASSETS = join(dirname(dirname(fileURLToPath(import.meta.url))), "assets");
// 項目檔的正面識別規則：只有 B#### 開頭的 .md 是「項目」。intake.md /
// INDEX.md / 任何非項目檔天然被排除，不再依賴「底線開頭」這個脆弱訊號。
const ITEM_RE = /^B\d+.*\.md$/;

// ── 專案根解析（script 位置無關）────────────────────────────────────────
function resolveRoot(argv) {
  const i = argv.indexOf("--root");
  if (i !== -1 && argv[i + 1]) return resolve(argv[i + 1]);
  if (process.env.BACKLOG_ROOT) return resolve(process.env.BACKLOG_ROOT);
  let d = process.cwd();
  while (true) {
    if (existsSync(join(d, "_backlog"))) return d;
    const up = dirname(d);
    if (up === d) break;
    d = up;
  }
  return process.cwd();
}
const ROOT = resolveRoot(process.argv.slice(2));
const BACKLOG = join(ROOT, "_backlog");
const ARCHIVE = join(BACKLOG, "archive");
const INDEX = join(BACKLOG, "INDEX.md");
const INTAKE = join(BACKLOG, "intake.md"); // 無底線（底線本是腳本訊號，已改用 ITEM_RE）

const AUTO_BEGIN = `<!-- AUTO:BEGIN — 由 ${LABEL} 的 index 自動重生，勿手改 -->`;
const AUTO_END = "<!-- AUTO:END -->";

const TYPES = ["fix", "optimize", "feature", "security", "chore", "docs"];
const PRIORITIES = ["high", "med", "low"];
const STATUSES = ["triaged", "in-progress", "done", "wont-do"];
const CLOSED = ["done", "wont-do"];

const TYPE_LABEL = { fix: "🐞 修復", optimize: "⚡ 優化", feature: "✨ 新需求", security: "🔒 安全", chore: "🧹 雜務", docs: "📄 文件" };
const STATUS_LABEL = { triaged: "⬜ 待處理", "in-progress": "🔧 進行中", done: "✅ 已完成", "wont-do": "🚫 不採納" };
const PRI_ORDER = { high: 0, med: 1, low: 2 };
const FIELD_ORDER = ["id", "type", "priority", "status", "area", "created", "closed", "milestone", "issue", "migrated_from", "title"];

const today = () => new Date().toISOString().slice(0, 10);
const die = (m) => { console.error(m); process.exit(1); };

// ── frontmatter 解析 / 序列化（只認平鋪 key: value，值可空）──────────────
function parse(path) {
  const text = readFileSync(path, "utf8");
  if (!text.startsWith("---\n")) return [{}, text];
  const end = text.indexOf("\n---\n", 4);
  if (end === -1) return [{}, text];
  const fm = {};
  for (const line of text.slice(4, end).split("\n")) {
    const t = line.trim();
    if (!t || t.startsWith("#")) continue;
    const i = line.indexOf(":");
    if (i === -1) continue;
    fm[line.slice(0, i).trim()] = line.slice(i + 1).trim();
  }
  return [fm, text.slice(end + 5)];
}
function dump(fm, body) {
  // 先輸出固定欄位（順序穩定），再把使用者/agent 自訂的未知鍵接在後面
  // → rewrite（如 archive 設 milestone）不會靜默丟掉手加的 frontmatter
  const known = FIELD_ORDER.filter((k) => k in fm);
  const extra = Object.keys(fm).filter((k) => !FIELD_ORDER.includes(k));
  const lines = [...known, ...extra].map((k) => `${k}: ${fm[k] ?? ""}`);
  return `---\n${lines.join("\n")}\n---\n${body}`;
}

function allItemFiles(dir = BACKLOG) {
  const out = [];
  if (!existsSync(dir)) return out;
  for (const name of readdirSync(dir).sort()) {
    const p = join(dir, name);
    if (statSync(p).isDirectory()) { out.push(...allItemFiles(p)); continue; }
    if (!ITEM_RE.test(name)) continue; // 只認 B#### 項目檔
    out.push(p);
  }
  return out;
}
function nextId() {
  let n = 0;
  for (const p of allItemFiles()) {
    const m = basename(p).match(/^B(\d+)/);
    if (m) n = Math.max(n, parseInt(m[1], 10));
  }
  return "B" + String(n + 1).padStart(4, "0");
}
// 純淨化器：轉小寫、非 [a-z0-9] 連續字元換 -、去頭尾 -。空字串就回空
// （不再 fallback "item"）。呼叫端負責「空就明確報錯」，避免靜默無名檔。
const slugify = (s) => (s || "").trim().toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "");

// ── bootstrap ───────────────────────────────────────────────────────────
// 任何子命令前都會跑：缺什麼補什麼，冪等、絕不覆蓋既有檔。團隊成員無需
// 手動建任何檔。模板來自本 skill 的 assets/（單一真相，fallback agent 也讀它）。
function ensureScaffold() {
  const created = [];
  const freshDir = !existsSync(BACKLOG);
  if (freshDir) { mkdirSync(BACKLOG, { recursive: true }); created.push("_backlog/"); }
  for (const [dest, tpl] of [[INDEX, "INDEX.template.md"], [INTAKE, "intake.template.md"]]) {
    if (existsSync(dest)) continue;
    const src = join(ASSETS, tpl);
    if (!existsSync(src)) die(`❌ 找不到 skill 模板 ${relative(ROOT, src)}（skill 安裝不完整）`);
    writeFileSync(dest, readFileSync(src, "utf8"));
    created.push(relative(ROOT, dest));
  }
  // #5：只有「真的新建 _backlog/ 那一次」才醒目印出絕對路徑 + 補救指示。
  // 非阻塞（agent 經非互動 Bash 跑，阻塞式 read 會卡死）；改為可逆提示，
  // 讓 agent 把路徑出示給使用者確認（見 SKILL.md 協作協定）。
  if (freshDir) {
    console.log(
      `\n⚠️  已在此絕對路徑建立 backlog：\n` +
      `      ${resolve(BACKLOG)}\n` +
      `   請確認這是你的「專案根」。若不是（例如不小心在子目錄執行）：\n` +
      `      1) 刪除上面這個 _backlog/\n` +
      `      2) 改用 --root <正確專案根> 重跑\n`);
  }
  return created;
}
function cmdInit() {
  const created = ensureScaffold();
  console.log(created.length ? `✅ 已建立：${created.join("、")}` : "ℹ️  結構已存在，未變更");
  cmdIndex();
}

// ── new ─────────────────────────────────────────────────────────────────
function cmdNew(o) {
  if (!o.title) die("❌ new 需要 --title");
  if (o.type && !TYPES.includes(o.type)) die(`❌ type 須為 ${TYPES.join("|")}`);
  if (o.priority && !PRIORITIES.includes(o.priority)) die(`❌ priority 須為 ${PRIORITIES.join("|")}`);
  if (o.status && !STATUSES.includes(o.status)) die(`❌ status 須為 ${STATUSES.join("|")}`);
  ensureScaffold(); // 首次使用自動 bootstrap，不需先手動建結構
  const id = nextId();
  // slug 一律經淨化（連 --slug 提供的也是，避免空白/大寫混進檔名）。
  // 取不出（如純中文標題又沒給 --slug）→ 明確報錯要求英文檔名，
  // 不再靜默產生無意義的 "item"。整理項目時就該給有意義的英文名。
  const slug = slugify(o.slug || o.title);
  if (!slug) die(`❌ 無法從標題自動產生英文檔名（多為非 ASCII 標題）。\n` +
    `   請用 --slug 提供有意義的英文 kebab-case 名，例：\n` +
    `   --slug mise-cache-daily-volume`);
  const path = join(BACKLOG, `${id}-${slug}.md`);
  if (existsSync(path)) die(`❌ ${path} 已存在`);
  const fm = { id, type: o.type || "optimize", priority: o.priority || "med", status: o.status || "triaged", area: o.area || "", created: today(), closed: "", milestone: "", issue: "", migrated_from: "", title: o.title };
  const body = `\n# ${o.title}\n\n## 問題 / 背景\n\n\n## 優劣分析\n\n（待 Claude 提供，使用者決定）\n\n## 決策\n\n（採納 / 不採納 + 理由）\n`;
  writeFileSync(path, dump(fm, body));
  console.log(`✅ 已建立 ${relative(ROOT, path)}  (id=${id}, root=${ROOT})`);
  cmdIndex(); // #2：建完即刷新 INDEX，與 archive 一致，避免索引落後
}

// ── index ───────────────────────────────────────────────────────────────
const HDR = "| id | 類型 | 優先 | 範圍 | 標題 | 狀態 |\n|---|---|---|---|---|---|";
function row(fm) {
  const t = TYPE_LABEL[fm.type] || `⚠${fm.type || ""}`;
  const s = STATUS_LABEL[fm.status] || `⚠${fm.status || ""}`;
  return `| ${fm.id || ""} | ${t} | ${fm.priority || ""} | ${fm.area || ""} | ${fm.title || ""} | ${s} |`;
}
function cmdIndex() {
  ensureScaffold(); // 缺結構自動補（含 INDEX.md），不再因找不到而報錯
  const active = [], closedRoot = [], archived = {};
  for (const p of allItemFiles()) {
    const [fm] = parse(p);
    const rel = relative(BACKLOG, p).split(/[\\/]/);
    if (rel[0] === "archive") (archived[rel[1]] ||= []).push(fm);
    else if (CLOSED.includes(fm.status)) closedRoot.push(fm);
    else active.push(fm);
  }
  active.sort((a, b) => (PRI_ORDER[a.priority] ?? 9) - (PRI_ORDER[b.priority] ?? 9) || (a.id || "").localeCompare(b.id || ""));
  closedRoot.sort((a, b) => (a.id || "").localeCompare(b.id || ""));

  const out = [AUTO_BEGIN, "", `### 活躍項目（${active.length}）`, "", HDR];
  out.push(...(active.length ? active.map(row) : ["| — | | | | _（無）_ | |"]));
  out.push("", `### 已關閉、待下次封存（${closedRoot.length}）`, "", HDR);
  out.push(...(closedRoot.length ? closedRoot.map(row) : ["| — | | | | _（無）_ | |"]));
  out.push("", `### 已封存段落（${Object.keys(archived).length}）`, "");
  if (!Object.keys(archived).length) out.push("_（無）_", "");
  for (const ms of Object.keys(archived).sort()) {
    const items = archived[ms].sort((a, b) => (a.id || "").localeCompare(b.id || ""));
    out.push(`<details><summary><b>${ms}</b>（${items.length} 項）</summary>`, "", HDR, ...items.map(row), "", "</details>", "");
  }
  out.push(`_最後更新：${today()} · 由 ${LABEL} 的 index 產生_`, "", AUTO_END);

  // 用標記前綴定位起點（容忍 AUTO:BEGIN 註解尾字不同寫法），終點用 AUTO_END
  const text = readFileSync(INDEX, "utf8");
  const begin = text.indexOf("<!-- AUTO:BEGIN"), j = text.indexOf(AUTO_END);
  if (begin === -1 || j === -1) die("❌ INDEX.md 找不到 AUTO 標記");
  writeFileSync(INDEX, text.slice(0, begin) + out.join("\n") + text.slice(j + AUTO_END.length));
  console.log(`✅ 已重生 INDEX 自動區：活躍 ${active.length} · 待封存 ${closedRoot.length} · 段落 ${Object.keys(archived).length}`);
}

// ── archive ─────────────────────────────────────────────────────────────
function nextMilestoneSeq() {
  let n = 0;
  if (existsSync(ARCHIVE)) for (const d of readdirSync(ARCHIVE)) {
    const m = d.match(/^(\d+)-/);
    if (m && statSync(join(ARCHIVE, d)).isDirectory()) n = Math.max(n, parseInt(m[1], 10));
  }
  return n + 1;
}
function cmdArchive(o) {
  if (!o.slug) die("❌ archive 需要段落名，例：archive 2026-bugfix-batch");
  const mslug = slugify(o.slug);
  if (!mslug) die("❌ 段落名需含英數（請用英文 kebab-case），例：archive 2026-bugfix-batch");
  const targets = [];
  if (existsSync(BACKLOG)) for (const name of readdirSync(BACKLOG).sort()) {
    if (!ITEM_RE.test(name)) continue; // 只掃根目錄的 B#### 項目檔
    const p = join(BACKLOG, name);
    if (statSync(p).isDirectory()) continue;
    const [fm, body] = parse(p);
    if (CLOSED.includes(fm.status)) targets.push({ p, fm, body });
  }
  if (!targets.length) { console.log("（沒有已關閉項目可封存）"); return; }
  const folder = `${String(nextMilestoneSeq()).padStart(4, "0")}-${today().replace(/-/g, "")}-${mslug}`;
  const dest = join(ARCHIVE, folder);
  console.log(`段落資料夾：_backlog/archive/${folder}/`);
  console.log(`將封存 ${targets.length} 個已關閉項目：`);
  for (const { p, fm } of targets) console.log(`  · ${fm.id}  [${fm.status}]  ${fm.title}  (${basename(p)})`);
  if (!o.commit) { console.log("\n（dry-run。確認無誤後加 --commit 真的封存）"); return; }
  mkdirSync(dest, { recursive: true });
  for (const { p, fm, body } of targets) {
    fm.milestone = folder;
    writeFileSync(join(dest, basename(p)), dump(fm, body));
    rmSync(p);
  }
  console.log(`\n✅ 已封存 ${targets.length} 項 → ${relative(ROOT, dest)}`);
  cmdIndex();
}

function cmdSync() {
  console.log("⏸  sync 尚未實作：需先 git init 並有 GitHub remote + gh CLI。\n" +
    "    屆時：逐檔 gh issue create（label=type/priority）→ 回填 issue: #N；\n" +
    "    封存段落對應 GitHub milestone；id↔issue 當冪等橋接。");
}

// ── arg 解析（極簡，零依賴）─────────────────────────────────────────────
// 布林旗標採白名單，其餘旗標一律「原樣吃下一個 token 當值」（值可以 -- 開頭，
// 如 --title "--upgrade 太慢"）；帶值旗標缺值 → 報錯，不再靜默。舊版靠
// 「下一個 token 是否 -- 開頭」猜語意 → 值被誤判成布林、殘值再被誤當旗標，
// 靜默寫出 title: true（B0040）。
const BOOL_FLAGS = new Set(["commit"]);
const [cmd, ...rest] = process.argv.slice(2);
const opt = { _: [] };
for (let i = 0; i < rest.length; i++) {
  if (rest[i].startsWith("--")) {
    const k = rest[i].slice(2);
    if (BOOL_FLAGS.has(k)) { opt[k] = true; continue; }
    if (i + 1 >= rest.length) {
      console.error(`❌ --${k} 需要值（布林旗標僅有：${[...BOOL_FLAGS].map(f => "--" + f).join("、")}）`);
      process.exit(1);
    }
    opt[k] = rest[++i];
  } else opt._.push(rest[i]);
}
switch (cmd) {
  case "init": cmdInit(); break;
  case "new": cmdNew(opt); break;
  case "index": cmdIndex(); break;
  case "archive": cmdArchive({ slug: opt._[0], commit: !!opt.commit }); break;
  case "sync": cmdSync(); break;
  default:
    console.log(`用法（從專案根執行，或加 --root <專案路徑>；new/index/archive 會自動 bootstrap，無需先手動建結構）：\n` +
      `  ${INVOKE} init                                  # 顯式建立 _backlog/ 結構（冪等）\n` +
      `  ${INVOKE} new --title <t> [--type fix|optimize|feature|security|chore|docs] [--priority high|med|low] [--status ...] [--area ...] [--slug ...]\n` +
      `  ${INVOKE} index\n  ${INVOKE} archive <段落名> [--commit]\n  ${INVOKE} sync`);
    process.exit(cmd ? 1 : 0);
}
