import path from 'node:path';
import { pathToFileURL, fileURLToPath } from 'node:url';
import { openDb } from './db.js';
import { run, q1 } from './repo.js';
import { hashPassword, encryptField, blindIndex } from './util.js';

const SCHOOL_ID = 1001; // 城关镇第二小学
const MIDDLE_SCHOOL_ID = 1002; // 城关镇中学
const ENROLL_YEAR = 1996;
const CLASS_RAW = '六年2班';
const CLASS_NORM = '6-2';
const TOWN = '411623102'; // 河南省 周口市 商水县 城关乡

const REGIONS = [
  ['410000', '河南省', 1, null],
  ['411600', '周口市', 2, '410000'],
  ['411623', '商水县', 3, '411600'],
  ['411623102', '城关乡', 4, '411623'],
  ['411623103', '练集镇', 4, '411623'],
  ['330000', '浙江省', 1, null],
  ['330100', '杭州市', 2, '330000'],
  ['330106', '西湖区', 3, '330100'],
  ['330106005', '古荡街道', 4, '330106'],
];

// 45 人名册：前 10 为已注册 demo 用户，其余 35 为沉睡名字（预占位，不含任何联系方式）
const DEMO_USERS = [
  { id: 1, name: '李娟', nick: '娟子', gender: 2, birth: 1989, mode: 'balanced', v: 1, femaleProtect: 1, city: '330100' },
  { id: 2, name: '王丽', nick: '丽丽', gender: 2, birth: 1989, mode: 'open', v: 1, femaleProtect: 0, city: '330100' },
  { id: 3, name: '张强', nick: '强子', gender: 1, birth: 1988, mode: 'strict', v: 1, femaleProtect: 0, city: '411600' },
  { id: 4, name: '刘敏', nick: '敏敏', gender: 2, birth: 1990, mode: 'balanced', v: 1, femaleProtect: 1, city: '411600' },
  { id: 5, name: '陈建国', nick: '老陈', gender: 1, birth: 1988, mode: 'balanced', v: 1, femaleProtect: 0, city: '411600' },
  { id: 6, name: '赵红', nick: '红红', gender: 2, birth: 1989, mode: 'balanced', v: 0, femaleProtect: 1, city: '411600' },
  { id: 7, name: '孙伟', nick: '阿伟', gender: 1, birth: 1989, mode: 'balanced', v: 0, femaleProtect: 0, city: '411600' },
  { id: 8, name: '周芳', nick: '芳芳', gender: 2, birth: 1990, mode: 'balanced', v: 0, femaleProtect: 1, city: '330100' },
  { id: 9, name: '吴军', nick: '军哥', gender: 1, birth: 1988, mode: 'balanced', v: 0, femaleProtect: 0, city: '411600' },
  { id: 10, name: '郑小燕', nick: '小燕', gender: 2, birth: 1990, mode: 'balanced', v: 0, femaleProtect: 1, city: '411600' },
];

const PLACEHOLDER_NAMES = [
  '王建华', '李秀兰', '张伟', '刘洋', '陈静', '杨帆', '赵磊', '孙红', '周涛', '吴霞',
  '郑浩', '冯雪', '褚亮', '卫芳', '蒋鹏', '沈丽', '韩冰', '曹阳', '朱琳', '秦川',
  '许晴', '何勇', '吕燕', '施华', '张楠', '李想', '王鹏', '刘佳', '陈晨', '杨柳',
  '赵静', '孙浩', '周敏', '吴迪', '郑爽',
];

const daysAgo = (n) => new Date(Date.now() - n * 86400 * 1000).toISOString();

// 幂等种子：全部 INSERT OR IGNORE / 唯一键去重，重复执行不产生重复数据
export function seedDatabase(db) {
  for (const [code, name, level, parent] of REGIONS) {
    run(db, 'INSERT OR IGNORE INTO regions(code,name,level,parent_code,is_active) VALUES(?,?,?,?,1)', code, name, level, parent);
  }
  run(db, "INSERT OR IGNORE INTO schools(school_id,name,former_names,region_code,stage,status) VALUES(?,?,?,?,?,'active')",
    SCHOOL_ID, '城关镇第二小学', JSON.stringify(['城关二小', '镇二小']), TOWN, 'PRIMARY');
  run(db, "INSERT OR IGNORE INTO schools(school_id,name,former_names,region_code,stage,status) VALUES(?,?,?,?,?,'active')",
    MIDDLE_SCHOOL_ID, '城关镇中学', JSON.stringify(['城关中学']), TOWN, 'MIDDLE');

  const pw = hashPassword('demo1234');
  for (const u of DEMO_USERS) {
    const phone = '138000000' + String(u.id).padStart(2, '0');
    run(
      db,
      `INSERT OR IGNORE INTO users(id,dimi_no,phone,phone_idx,nickname,real_name,gender,birth_year,signature,password_hash,status,credit_score,created_at,updated_at)
       VALUES(?,?,?,?,?,?,?,?,?,?,1,100,?,?)`,
      u.id, 'DM' + (10000000 + u.id), encryptField(phone), blindIndex('phone', phone), u.nick, u.name, u.gender, u.birth,
      `96级六年2班的${u.name}`, pw, daysAgo(10), daysAgo(10)
    );
    run(db, 'INSERT OR IGNORE INTO privacy_settings(user_id,name_mode,female_protect) VALUES(?,?,?)', u.id, u.mode, u.femaleProtect);
    run(
      db,
      `INSERT OR IGNORE INTO education_experiences(user_id,stage,school_id,school_name_snapshot,enroll_year,class_name_raw,class_name_norm,visibility,verification_level,verified_at,verification_source,created_at)
       VALUES(?,?,?,?,?,?,?,'public',?,?,?,?)`,
      u.id, 'PRIMARY', SCHOOL_ID, '城关镇第二小学', ENROLL_YEAR, CLASS_RAW, CLASS_NORM,
      u.v, u.v ? daysAgo(5) : null, u.v ? 'peer_review' : null, daysAgo(10)
    );
    run(db, 'INSERT OR IGNORE INTO user_hometowns(user_id,type,region_code,visibility) VALUES(?,1,?,?)', u.id, TOWN, 'public');
    run(db, 'INSERT OR IGNORE INTO user_hometowns(user_id,type,region_code,visibility) VALUES(?,2,?,?)', u.id, u.city, 'public');
  }
  // 交叉经历：李娟 / 王丽 同校于城关镇中学 1999 级（资料卡 cross_experiences 演示）
  for (const uid of [1, 2]) {
    run(
      db,
      `INSERT OR IGNORE INTO education_experiences(user_id,stage,school_id,school_name_snapshot,enroll_year,class_name_raw,class_name_norm,visibility,verification_level,created_at)
       VALUES(?,?,?,?,?,?,?,'public',0,?)`,
      uid, 'MIDDLE', MIDDLE_SCHOOL_ID, '城关镇中学', 1999, '三年1班', '3-1', daysAgo(10)
    );
  }
  // 好友关系：1-5 互为小圈子（双向双行），使 1-5 的同班好友数 ≥3 → 经历为 V1 互证
  const clique = [1, 2, 3, 4, 5];
  for (const a of clique) {
    for (const b of clique) {
      if (a === b) continue;
      run(db, "INSERT OR IGNORE INTO friendships(user_id,friend_id,source,created_at) VALUES(?,?,'seed',?)", a, b, daysAgo(8));
    }
  }
  for (const name of PLACEHOLDER_NAMES) {
    run(db, 'INSERT OR IGNORE INTO placeholders(school_id,enroll_year,class_norm,name,lit_by,created_at) VALUES(?,?,?,?,1,?)',
      SCHOOL_ID, ENROLL_YEAR, CLASS_NORM, name, daysAgo(9));
  }
  run(db, 'INSERT OR IGNORE INTO invites(code,school_id,enroll_year,class_norm,class_name,created_by,created_at) VALUES(?,?,?,?,?,?,?)',
    'CG2X96', SCHOOL_ID, ENROLL_YEAR, CLASS_NORM, CLASS_RAW, 1, daysAgo(9));
  // 近 7 天活跃审计（密度看板 7 留演示：10 人中 8 人活跃 → 0.8）
  for (const uid of [1, 2, 3, 4, 5, 6, 7, 8]) {
    const exists = q1(db, "SELECT 1 x FROM audit_logs WHERE user_id=? AND event='login' AND created_at>=?", uid, daysAgo(7));
    if (!exists) {
      run(db, "INSERT INTO audit_logs(user_id,event,created_at) VALUES(?,'login',?)", uid, daysAgo(2));
    }
  }
  return {
    users: q1(db, 'SELECT COUNT(*) c FROM users').c,
    placeholders: q1(db, 'SELECT COUNT(*) c FROM placeholders').c,
    regions: q1(db, 'SELECT COUNT(*) c FROM regions').c,
  };
}

const isMain = process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href;
if (isMain) {
  const dbPath = process.env.DIMI_DB_PATH || path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', 'data', 'dimi.db');
  const db = openDb(dbPath);
  const stats = seedDatabase(db);
  console.log(`seed 完成（幂等，可重复执行）：db=${dbPath}`, stats);
  db.close();
}
