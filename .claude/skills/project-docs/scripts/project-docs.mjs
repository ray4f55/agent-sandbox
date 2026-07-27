#!/usr/bin/env node
// project-docs skill scaffold + audit
// 規格見 ../SKILL.md（單一真相來源）

import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const TEMPLATES_DIR = path.join(__dirname, '..', 'assets', 'templates');

// --- 參數解析 ---
const args = process.argv.slice(2);
const command = args[0] || 'scaffold';
const flags = {
  force: args.includes('--force'),
  root: getFlagValue('--root') || process.cwd(),
  name: getFlagValue('--name'),
};

function getFlagValue(name) {
  const i = args.indexOf(name);
  if (i === -1 || i === args.length - 1) return null;
  return args[i + 1];
}

const ROOT = path.resolve(flags.root);
const PROJECT_NAME = flags.name || path.basename(ROOT);

if (!['scaffold', 'help', '--help', '-h'].includes(command)) {
  console.error(`❌ 未知命令: ${command}`);
  console.error(`可用：scaffold [--root <path>] [--name <name>] [--force]`);
  process.exit(1);
}

if (['help', '--help', '-h'].includes(command)) {
  console.log(`
project-docs — 專案文件骨架生成與 audit

用法：
  scaffold [--root <path>] [--name <name>] [--force]

行為：
  - 對 cwd（或 --root 指定的路徑）做 auto-detect
  - 缺檔 → 從 template 生成（{{project_name}} 替換）
  - 既有檔 → audit 必要 sections，回報建議
  - --force：整檔覆寫（破壞性，需明確指定）
`);
  process.exit(0);
}

// --- 目標清單與 audit 規則 ---
const TARGETS = [
  {
    type: 'file',
    target: 'README.md',
    template: 'README.md.template',
    audits: [
      {
        name: 'has H1 heading',
        check: c => /^#\s+\S/m.test(c),
        suggest: '在檔首加 `# <project_name>` H1 標題',
      },
      {
        name: 'has intro paragraph after H1',
        check: c => {
          const lines = c.split('\n');
          let pastH1 = false;
          for (const line of lines) {
            if (/^#\s+/.test(line)) { pastH1 = true; continue; }
            if (/^##\s+/.test(line)) break;
            if (pastH1 && line.trim() && !line.startsWith('<!--')) return true;
          }
          return false;
        },
        suggest: '在 H1 後加 1-2 句 elevator pitch（這專案是什麼、給誰用）',
      },
      {
        name: 'has "專案結構" or "Project Structure" section',
        check: c => /^##\s+(專案結構|Project Structure|目錄結構)/m.test(c),
        suggest: '加「## 專案結構」段，列主要目錄與檔的用途',
      },
      {
        name: 'has "Quick start" or 安裝 section',
        check: c => /^##\s+(Quick\s*start|Quickstart|快速開始|安裝)/im.test(c),
        suggest: '加「## Quick start」段，提供從零到第一次能跑的最短步驟',
      },
    ],
  },
  {
    type: 'file',
    target: 'CLAUDE.md',
    template: 'CLAUDE.md.template',
    audits: [
      {
        name: 'has 文件分工 section',
        check: c => /^##\s+文件分工/m.test(c),
        suggest: '加「## 文件分工」段，列各檔職責（README / CLAUDE / docs/）',
      },
      {
        name: 'has 紀律 section',
        check: c => /^##\s+(寫程式碼時的紀律|紀律|Discipline)/m.test(c),
        suggest: '加「## 寫程式碼時的紀律」段，列改 code 時要遵守的規則',
      },
      {
        name: 'has 紅線 or 主題 section + design import',
        check: c =>
          /^##\s+(主題紅線|紅線|主題)/m.test(c) ||
          /^@docs\/design\//m.test(c),
        suggest:
          '加「## 主題紅線」段並用行首 @docs/design/<topic>.md 引入細節',
      },
    ],
  },
  {
    type: 'file',
    target: '.gitignore',
    template: '.gitignore.template',
    audits: [
      {
        name: 'excludes _* (個人本地檔慣例)',
        check: c => /^_\*\s*$/m.test(c),
        suggest:
          '加 `_*` 排除底線開頭的檔／夾（backlog/notes skill 的本機慣例）',
      },
      {
        name: 'has .claude/* whitelist for skills/',
        check: c =>
          /^\.claude\/\*\s*$/m.test(c) && /^!\.claude\/skills\//m.test(c),
        suggest:
          '加 `.claude/*` + `!.claude/skills/` 白名單（讓 skills 進 git、其他 .claude/* 不進）',
      },
    ],
  },
  {
    type: 'dir',
    target: 'docs/design',
    audits: [
      {
        name: 'has at least one design file',
        check: dir =>
          fs.readdirSync(dir).some(f => f.endsWith('.md') && !f.startsWith('.')),
        suggest:
          '至少建一個 design 檔；骨架與命名規則見 SKILL.md「docs/design/ 檔的骨架」段',
      },
    ],
  },
  { type: 'dir', target: 'docs/examples', audits: [] },
  { type: 'dir', target: 'docs/guides', audits: [] },
  { type: 'dir', target: 'docs/reference', audits: [] },
];

// --- 執行 ---
const report = { created: [], existing: [], audits: [], skipped: [], todos: [] };

// 數 scaffold TODO 標記 — 衡量「文件填了沒」的完整度指標
function countTodos(content) {
  const m = content.match(/TODO/g);
  return m ? m.length : 0;
}

for (const t of TARGETS) {
  const fullPath = path.join(ROOT, t.target);
  const exists = fs.existsSync(fullPath);

  if (t.type === 'file') {
    if (!exists || flags.force) {
      if (exists && flags.force) report.skipped.push(`${t.target}（--force 覆寫）`);
      const tplPath = path.join(TEMPLATES_DIR, t.template);
      let content = fs.readFileSync(tplPath, 'utf8');
      content = content.replaceAll('{{project_name}}', PROJECT_NAME);
      fs.mkdirSync(path.dirname(fullPath), { recursive: true });
      fs.writeFileSync(fullPath, content);
      report.created.push(t.target);
      const n = countTodos(content);
      if (n > 0) report.todos.push({ file: t.target, count: n });
    } else {
      report.existing.push(t.target);
      const content = fs.readFileSync(fullPath, 'utf8');
      const n = countTodos(content);
      if (n > 0) report.todos.push({ file: t.target, count: n });
      for (const a of t.audits || []) {
        if (!a.check(content)) {
          report.audits.push({ file: t.target, name: a.name, suggest: a.suggest });
        }
      }
    }
  } else if (t.type === 'dir') {
    if (!exists) {
      fs.mkdirSync(fullPath, { recursive: true });
      fs.writeFileSync(path.join(fullPath, '.gitkeep'), '');
      report.created.push(`${t.target}/`);
    } else {
      report.existing.push(`${t.target}/`);
      for (const a of t.audits || []) {
        try {
          if (!a.check(fullPath)) {
            report.audits.push({
              file: `${t.target}/`,
              name: a.name,
              suggest: a.suggest,
            });
          }
        } catch (e) {
          // ignore audit errors silently
        }
      }
    }
  }
}

// --- 報告 ---
console.log('');
console.log(`📋 project-docs scaffold report`);
console.log(`   project: ${PROJECT_NAME}`);
console.log(`   root:    ${ROOT}`);
console.log('');

if (report.created.length) {
  console.log(`✨ 生成（${report.created.length}）`);
  report.created.forEach(p => console.log(`     + ${p}`));
  console.log('');
}

if (report.existing.length) {
  console.log(`📦 已存在，未動（${report.existing.length}）`);
  report.existing.forEach(p => console.log(`     · ${p}`));
  console.log('');
}

if (report.todos.length) {
  const total = report.todos.reduce((s, t) => s + t.count, 0);
  console.log(`📝 待填 TODO（${report.todos.length} 檔，共 ${total} 處）`);
  for (const t of report.todos) {
    console.log(`     ${t.file.padEnd(14)} ${t.count} 處`);
  }
  console.log('   ⤷ 骨架已就位但內容尚未填 — 後續開發者拿不到上下文。');
  console.log('     應讀專案現有程式碼／文件／git 歷史後補全（見 SKILL.md 協作協定）。');
  console.log('');
}

if (report.audits.length) {
  console.log(`⚠️  audit 建議（${report.audits.length}）`);
  for (const a of report.audits) {
    console.log(`     [${a.file}] ${a.name}`);
    console.log(`        → ${a.suggest}`);
  }
  console.log('   ⤷ 上列為結構檢查；逐項手動補上。');
  console.log('');
}

if (report.audits.length === 0 && report.todos.length === 0 && report.existing.length) {
  console.log('✅ 結構齊備、無待填 TODO — 文件完整');
}

console.log('');
