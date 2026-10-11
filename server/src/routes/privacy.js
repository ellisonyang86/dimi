import { q, run, getPrivacy, audit, regionChain } from '../repo.js';
import { ok, E } from '../http/respond.js';
import { hitRate } from '../rate.js';

const NAME_MODES = ['open', 'balanced', 'strict'];
// 枚举白名单（OpenAPI Visibility / friend_moments_range 契约）：
// hometown_visibility 四档分档生效（users.js 资料卡：private 隐藏 / friends 仅好友 /
// fellows_only 好友或同乡 / public 按交集深度降级展示）
const HOMETOWN_VISIBILITIES = ['public', 'friends', 'fellows_only', 'private'];
const FRIEND_MOMENTS_RANGES = ['all', 'one_month', 'three_days', 'half_year'];
const BOOL_KEYS = [
  'friend_verify_required', 'current_city_visible', 'stranger_moments_10',
  'read_receipt', 'typing_visible', 'group_temp_chat', 'notify_when_searched',
  'personalized_recommend', 'female_protect',
];
const ADD_VIA_KEYS = ['dimi_no', 'phone', 'school_search', 'hometown_search', 'group', 'business_card', 'contact_match'];

// 隐私设置：真名三档 name_mode（§5.2.8）、各添加方式开关、个性化推荐总开关（A4）
export function registerPrivacyRoutes(router, { db }) {
  router.get('/v1/privacy/settings', { auth: true }, (ctx) => {
    return ok(ctx, selfViewPrivacy(db, ctx.user));
  });

  router.put('/v1/privacy/settings', { auth: true }, (ctx) => {
    const body = ctx.body || {};
    const sets = [];
    const vals = [];
    for (const k of BOOL_KEYS) {
      if (body[k] !== undefined) {
        if (typeof body[k] !== 'boolean') throw E.param(`${k} 须为布尔值`);
        sets.push(`${k}=?`); vals.push(body[k] ? 1 : 0);
      }
    }
    if (body.name_mode !== undefined) {
      if (!NAME_MODES.includes(body.name_mode)) throw E.param('name_mode 仅支持 open / balanced / strict');
      sets.push('name_mode=?'); vals.push(body.name_mode);
    }
    if (body.hometown_visibility !== undefined) {
      if (!HOMETOWN_VISIBILITIES.includes(body.hometown_visibility)) {
        throw E.param(`hometown_visibility 仅支持 ${HOMETOWN_VISIBILITIES.join(' / ')}`);
      }
      sets.push('hometown_visibility=?'); vals.push(String(body.hometown_visibility));
    }
    if (body.friend_moments_range !== undefined) {
      if (!FRIEND_MOMENTS_RANGES.includes(body.friend_moments_range)) {
        throw E.param(`friend_moments_range 仅支持 ${FRIEND_MOMENTS_RANGES.join(' / ')}`);
      }
      sets.push('friend_moments_range=?'); vals.push(String(body.friend_moments_range));
    }
    if (body.add_me_via !== undefined) {
      if (!body.add_me_via || typeof body.add_me_via !== 'object' || Array.isArray(body.add_me_via)) throw E.param('add_me_via 须为对象');
      const cur = getPrivacy(db, ctx.user).add_me_via;
      for (const [k, v] of Object.entries(body.add_me_via || {})) {
        if (!ADD_VIA_KEYS.includes(k) || typeof v !== 'boolean') throw E.param('添加方式须为已知选项及布尔值');
        cur[k] = v;
      }
      sets.push('add_me_via=?'); vals.push(JSON.stringify(cur));
    }
    if (!sets.length) throw E.param('没有可更新的字段');
    run(db, `INSERT OR IGNORE INTO privacy_settings(user_id) VALUES(?)`, ctx.user.id);
    run(db, `UPDATE privacy_settings SET ${sets.join(',')} WHERE user_id=?`, ...vals, ctx.user.id);
    // 收窄 5 分钟内全端生效（§20.2）：本实现即时生效，无缓存
    return ok(ctx);
  });

  // 个人信息导出（PIPL 可携带权，契约 /privacy/data-export）：
  // 同步返回本人全量数据 JSON 包；频控 1 次/小时；全程记审计
  router.post('/v1/privacy/data-export', { auth: true }, (ctx) => {
    if (!hitRate(db, `data_export:${ctx.user.id}:hour`, 1, 3600).allowed) {
      throw E.rate('导出过于频繁，请 1 小时后再试');
    }
    const u = ctx.user;
    const hometowns = q(db, 'SELECT type, region_code, visibility FROM user_hometowns WHERE user_id=?', u.id)
      .map((h) => ({ ...h, path: regionChain(db, h.region_code).map((r) => r.name) }));
    const educations = q(
      db,
      'SELECT stage, school_name_snapshot, enroll_year, class_name_raw, department, major, verification_level, created_at FROM education_experiences WHERE user_id=?',
      u.id
    );
    const friends = q(
      db,
      `SELECT u.dimi_no, f.remark_name, f.tags, f.created_at FROM friendships f JOIN users u ON u.id=f.friend_id WHERE f.user_id=?`,
      u.id
    ).map((f) => ({ ...f, tags: JSON.parse(f.tags || '[]') }));
    const data = {
      exported_at: new Date().toISOString(),
      profile: {
        dimi_no: u.dimi_no, phone: u.phone, nickname: u.nickname, real_name: u.real_name,
        gender: u.gender, birth_year: u.birth_year, signature: u.signature,
        credit_score: u.credit_score, created_at: u.created_at,
      },
      privacy_settings: selfViewPrivacy(db, u),
      hometowns,
      educations,
      friends,
    };
    audit(db, { userId: u.id, event: 'data_export', output: { sections: Object.keys(data) } });
    return ok(ctx, data);
  });
}

function selfViewPrivacy(db, user) {
  const p = getPrivacy(db, user);
  return {
    friend_verify_required: !!p.friend_verify_required,
    name_mode: p.name_mode,
    add_me_via: p.add_me_via,
    hometown_visibility: p.hometown_visibility,
    current_city_visible: !!p.current_city_visible,
    stranger_moments_10: !!p.stranger_moments_10,
    friend_moments_range: p.friend_moments_range,
    read_receipt: !!p.read_receipt,
    typing_visible: !!p.typing_visible,
    group_temp_chat: !!p.group_temp_chat,
    notify_when_searched: !!p.notify_when_searched,
    personalized_recommend: !!p.personalized_recommend,
    female_protect: !!p.female_protect,
  };
}
