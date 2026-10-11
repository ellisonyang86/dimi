import { test } from 'node:test';
import assert from 'node:assert/strict';
import { openDb } from '../src/db.js';
import { run, q1 } from '../src/repo.js';
import { resolveUserView } from '../src/engine/index.js';
import { now } from '../src/util.js';

// 渐显矩阵单测：T3/T2/T1/T0 × 三档 name_mode × 好友/陌生人 全组合断言
function setupDb() {
  const db = openDb(':memory:');
  const regions = [
    ['410000', '河南省', 1, null], ['411600', '周口市', 2, '410000'], ['411623', '商水县', 3, '411600'],
    ['411623102', '城关乡', 4, '411623'], ['411623103', '练集镇', 4, '411623'],
    ['330000', '浙江省', 1, null], ['330100', '杭州市', 2, '330000'],
    ['330106', '西湖区', 3, '330100'], ['330106005', '古荡街道', 4, '330106'],
  ];
  for (const [c, n, l, p] of regions) {
    run(db, 'INSERT INTO regions(code,name,level,parent_code) VALUES(?,?,?,?)', c, n, l, p);
  }
  run(db, "INSERT INTO schools(school_id,name,former_names,region_code,stage) VALUES(1,'城关镇第二小学','[]','411623102','PRIMARY')");
  run(db, "INSERT INTO schools(school_id,name,former_names,region_code,stage) VALUES(2,'杭州某小学','[]','330106005','PRIMARY')");
  return db;
}

let seq = 0;
function mkUser(db, { name = '张晓梅', gender = 1, birth = 1989, mode = 'balanced', femaleProtect = null, edu = null, hometown = null }) {
  const id = ++seq + 1000;
  const ts = now();
  run(
    db,
    'INSERT INTO users(id,dimi_no,phone,nickname,real_name,gender,birth_year,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?,?)',
    id, 'DM' + id, '139' + String(id).padStart(8, '0'), 'nick' + id, name, gender, birth, ts, ts
  );
  run(db, 'INSERT INTO privacy_settings(user_id,name_mode,female_protect) VALUES(?,?,?)', id, mode, femaleProtect);
  if (edu) {
    run(
      db,
      'INSERT INTO education_experiences(user_id,stage,school_id,school_name_snapshot,enroll_year,class_name_raw,class_name_norm,verification_level,created_at) VALUES(?,?,?,?,?,?,?,?,?)',
      id, edu.stage || 'PRIMARY', edu.school_id ?? 1, '城关镇第二小学', edu.year, '六年2班', edu.cls || '', edu.v ?? 0, ts
    );
  }
  if (hometown) {
    run(db, 'INSERT INTO user_hometowns(user_id,type,region_code) VALUES(?,1,?)', id, hometown);
  }
  return q1(db, 'SELECT * FROM users WHERE id=?', id);
}

const T3_EDU = { year: 1996, cls: '6-2' };
const MODES = ['open', 'balanced', 'strict'];

// 期望矩阵（rules.json name_matrix + friend_display）
const EXPECT = {
  open:     { T3: 'full', T2: 'full', T1: 'full', T0: null },
  balanced: { T3: 'full', T2: 'mask', T1: 'surname', T0: null },
  strict:   { T3: 'surname', T2: 'surname', T1: 'surname', T0: null },
};
const DISPLAY = { full: '张晓梅', mask: '张*梅', surname: '张**' };

test('渐显矩阵：T3/T2/T1/T0 × 三档 name_mode × 好友/陌生人', () => {
  const db = setupDb();
  const mkTier = {
    // T3：同班（同校+同学段+同年+同班）
    T3: () => [mkUser(db, { name: '王明', gender: 1, edu: T3_EDU }), mkUser(db, { edu: T3_EDU })],
    // T2：同县（不同镇）且年龄差 ≤5
    T2: () => [mkUser(db, { name: '王明', gender: 1, birth: 1989, hometown: '411623102' }), mkUser(db, { birth: 1990, hometown: '411623103' })],
    // T1：同校但不同代（在校时间无重叠）
    T1: () => [mkUser(db, { name: '王明', gender: 1, edu: { year: 1996, cls: '6-2' } }), mkUser(db, { edu: { year: 1980, cls: '3-1' } })],
    // T0：无任何交集（异省异校、年龄差大）
    T0: () => [mkUser(db, { name: '王明', gender: 1, birth: 1989, hometown: '411623102', edu: { year: 1996, cls: '6-2' } }), mkUser(db, { birth: 1970, hometown: '330106005', edu: { year: 1985, cls: '', school_id: 2 } })],
  };
  for (const tier of ['T3', 'T2', 'T1', 'T0']) {
    for (const mode of MODES) {
      const [v, oRaw] = mkTier[tier]();
      run(db, 'UPDATE privacy_settings SET name_mode=? WHERE user_id=?', mode, oRaw.id);
      const o = q1(db, 'SELECT * FROM users WHERE id=?', oRaw.id);
      // 陌生人视角
      const view = resolveUserView(db, v, o, { scene: 'test' });
      assert.equal(view.tier, tier, `${tier} 判定错误`);
      const expectLevel = EXPECT[mode][tier];
      assert.equal(view.realName, expectLevel ? DISPLAY[expectLevel] : null, `${mode}/${tier}/陌生人`);
      // 好友视角：任何模式均为完整真名
      run(db, 'INSERT INTO friendships(user_id,friend_id,created_at) VALUES(?,?,?)', v.id, o.id, now());
      const fview = resolveUserView(db, v, o, { scene: 'test' });
      assert.equal(fview.tier, 'FRIEND');
      assert.equal(fview.realName, '张晓梅', `${mode}/${tier}/好友应为全名`);
    }
  }
  db.close();
});

test('女性默认加一档从严（§5.2.4），可自行调回', () => {
  const db = setupDb();
  const viewer = mkUser(db, { name: '王明', gender: 1, edu: T3_EDU });
  // 女性 + 平衡模式：T3 同班 → 展示档降为 T2 → 掩码名
  const female = mkUser(db, { name: '张晓梅', gender: 2, edu: T3_EDU, mode: 'balanced' });
  const v1 = resolveUserView(db, viewer, female, { scene: 'test' });
  assert.equal(v1.tier, 'T3');
  assert.equal(v1.displayTier, 'T2');
  assert.equal(v1.realName, '张*梅');
  // 隐私设置调回（female_protect=0）→ 恢复 T3 全名
  run(db, 'UPDATE privacy_settings SET female_protect=0 WHERE user_id=?', female.id);
  const v2 = resolveUserView(db, viewer, q1(db, 'SELECT * FROM users WHERE id=?', female.id), { scene: 'test' });
  assert.equal(v2.displayTier, 'T3');
  assert.equal(v2.realName, '张晓梅');
  db.close();
});

test('交集横幅：V0 经历带「未验证」限定句，V1 后为确认措辞', () => {
  const db = setupDb();
  const a = mkUser(db, { name: '王明', gender: 1, edu: { ...T3_EDU, v: 0 } });
  const b0 = mkUser(db, { name: '张晓梅', gender: 1, edu: { ...T3_EDU, v: 0 } });
  const view0 = resolveUserView(db, a, b0, { scene: 'test' });
  assert.ok(view0.banner.includes('未验证'));
  assert.ok(view0.banner.includes('六年2班'));
  const b1 = mkUser(db, { name: '张晓梅', gender: 1, edu: { ...T3_EDU, v: 1 } });
  run(db, 'UPDATE education_experiences SET verification_level=1 WHERE user_id=?', a.id);
  const view1 = resolveUserView(db, q1(db, 'SELECT * FROM users WHERE id=?', a.id), b1, { scene: 'test' });
  assert.ok(!view1.banner.includes('未验证'));
  assert.ok(view1.banner.includes('同班同学'));
  db.close();
});
