import { q, q1, run, regionChain, audit } from '../repo.js';
import { ok, E } from '../http/respond.js';
import { hitRate } from '../rate.js';
import { getIMProvider } from '../im/provider.js';

// 家乡可见范围白名单（OpenAPI Visibility 契约）；消费端 discover.js 找老乡仅认 'public'
const HOMETOWN_VISIBILITIES = ['public', 'friends', 'fellows_only', 'private'];

// 家乡 / 现居地 + 行政区划树（省→市→区县/乡镇）
//
// 防滥用设计准则（详见《家乡页与共建体系设计_V1》§19）：
// 家乡是身份锚点而非试穿外套——①修改频控 2 次/日（找老乡的锚点检索不受此限，
// 其自有 20 次/时 + 滑块频控）；②换家乡（市级前缀变化）自动退出原市老乡群，
// 防「改家乡→跨市串群→批量获取各地同乡信息」；③每次修改落审计可回溯。
export function registerHometownRoutes(router, { db, config }) {
  router.get('/v1/users/me/hometown', { auth: true }, (ctx) => {
    const rows = q(db, 'SELECT * FROM user_hometowns WHERE user_id=?', ctx.user.id);
    const items = rows.map((r) => {
      const chain = regionChain(db, r.region_code);
      return {
        type: r.type,
        region_code: r.region_code,
        region_name: chain.length ? chain[chain.length - 1].name : null,
        path: chain.map((c) => c.name),
        visibility: r.visibility,
      };
    });
    return ok(ctx, { items });
  });

  router.put('/v1/users/me/hometown', { auth: true }, (ctx) => {
    const { type, region_code, visibility = 'public' } = ctx.body || {};
    if (![1, 2].includes(Number(type))) throw E.param('type 仅支持 1 家乡 / 2 现居地');
    if (!HOMETOWN_VISIBILITIES.includes(visibility)) {
      throw E.param(`visibility 仅支持 ${HOMETOWN_VISIBILITIES.join(' / ')}`);
    }
    const region = q1(db, 'SELECT * FROM regions WHERE code=? AND is_active=1', String(region_code ?? ''));
    if (!region) throw E.notFound('行政区划不存在');
    if (Number(type) === 1 && region.level !== 4) throw E.param('家乡需精确到乡镇/街道（四级）');
    if (Number(type) === 2 && region.level !== 2) throw E.param('现居地精确到城市（二级）');
    // 设置频控：2 次/日（家乡是身份锚点；检索锚点切换走 discover 自有频控，不消耗此额度）
    const day = new Date().toISOString().slice(0, 10);
    if (!hitRate(db, `hometown_set:${ctx.user.id}:${day}`, 2, 86400).allowed) {
      throw E.rate('家乡修改过于频繁，请明天再来（为防止利用换家乡获取他人信息，每日限改 2 次）');
    }
    // 换家乡联动：市级前缀变化时自动退出原市老乡群（成员身份随锚点迁移）
    const old = q1(db, 'SELECT region_code FROM user_hometowns WHERE user_id=? AND type=1', ctx.user.id);
    if (Number(type) === 1 && old && old.region_code.slice(0, 4) !== region.code.slice(0, 4)) {
      const oldGroup = q1(db, 'SELECT * FROM hometown_groups WHERE region_prefix=?', old.region_code.slice(0, 4));
      if (oldGroup) {
        const provider = getIMProvider(db, config);
        if (provider.isConvMember(oldGroup.conv_id, ctx.user.id)) {
          provider.leaveConversation(oldGroup.conv_id, ctx.user.id);
          audit(db, {
            userId: ctx.user.id, event: 'hometown_group_auto_leave',
            targetId: oldGroup.group_id,
            input: { conv_id: oldGroup.conv_id, from: old.region_code, to: region.code },
          });
        }
      }
    }
    run(
      db,
      `INSERT INTO user_hometowns(user_id,type,region_code,visibility) VALUES(?,?,?,?)
       ON CONFLICT(user_id,type) DO UPDATE SET region_code=excluded.region_code, visibility=excluded.visibility`,
      ctx.user.id, Number(type), region.code, String(visibility)
    );
    audit(db, { userId: ctx.user.id, event: 'hometown_set', input: { type: Number(type), region_code: region.code, visibility: String(visibility) } });
    return ok(ctx);
  });

  router.get('/v1/regions', (ctx) => {
    const { parent_code, tree } = ctx.query;
    if (tree === '1' || tree === 'true') {
      const all = q(db, 'SELECT code,name,level,parent_code FROM regions WHERE is_active=1 ORDER BY code');
      const byParent = new Map();
      for (const r of all) {
        const key = r.parent_code ?? '';
        if (!byParent.has(key)) byParent.set(key, []);
        byParent.get(key).push(r);
      }
      const build = (parentKey) =>
        (byParent.get(parentKey) || []).map((r) => ({ code: r.code, name: r.name, level: r.level, children: build(r.code) }));
      return ok(ctx, { items: build('') });
    }
    const rows = parent_code
      ? q(db, 'SELECT code,name,level FROM regions WHERE is_active=1 AND parent_code=? ORDER BY code', String(parent_code))
      : q(db, 'SELECT code,name,level FROM regions WHERE is_active=1 AND level=1 ORDER BY code');
    return ok(ctx, { items: rows });
  });
}
