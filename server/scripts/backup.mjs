#!/usr/bin/env node
// SQLite 备份：VACUUM INTO 生成一致性快照（避免拷到 WAL 写中途的文件），保留最近 30 份。
// 用法：npm run backup   （可用 DIMI_DB_PATH 指定源库，默认 server/data/dimi.db）
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { DatabaseSync } from 'node:sqlite';

const SERVER_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const DATA_DIR = path.dirname(process.env.DIMI_DB_PATH ?? path.join(SERVER_ROOT, 'data', 'dimi.db'));
const DB_PATH = process.env.DIMI_DB_PATH ?? path.join(DATA_DIR, 'dimi.db');
const BACKUP_DIR = path.join(DATA_DIR, 'backups');
const KEEP = 30;

if (!fs.existsSync(DB_PATH)) {
  console.error(`[backup] 源库不存在：${DB_PATH}`);
  process.exit(1);
}
fs.mkdirSync(BACKUP_DIR, { recursive: true });

const ts = new Date().toISOString().replace(/[-:T]/g, '').replace(/\..+$/, '')
  .replace(/^(\d{8})(\d{6})$/, '$1-$2');
const target = path.join(BACKUP_DIR, `dimi-${ts}.db`);

// VACUUM INTO：SQLite 层一致性快照（内含 checkpoint 语义），同一进程只读打开即可
const db = new DatabaseSync(DB_PATH, { readOnly: true });
db.exec(`VACUUM INTO '${target.replace(/'/g, "''")}'`);
db.close();

// 保留最近 KEEP 份，超出按文件名（时间戳序）删最旧
const files = fs.readdirSync(BACKUP_DIR).filter((f) => /^dimi-\d{8}-\d{6}\.db$/.test(f)).sort();
const removed = files.slice(0, Math.max(0, files.length - KEEP));
for (const f of removed) fs.rmSync(path.join(BACKUP_DIR, f));

const size = (fs.statSync(target).size / 1024).toFixed(1);
console.log(`[backup] 完成：${target}（${size} KB）`);
if (removed.length) console.log(`[backup] 清理旧备份 ${removed.length} 份：${removed.join(', ')}`);
console.log(`[backup] 当前保留 ${files.length - removed.length} 份（上限 ${KEEP}）`);
