import { q, q1, run, audit } from '../repo.js';
import { ok, E } from '../http/respond.js';
import { isInt, now, maskName } from '../util.js';
import { hitRate } from '../rate.js';

// 举报 / 反馈 / 申诉 / 媒体上传 / 召集令公开接口 / 运营密度看板
export function registerMiscRoutes(router, { db, storage }) {
  // 契约路径 /misc/report（/v1/reports 为兼容别名，二者同逻辑）
  const handleReport = (ctx) => {
    const { target_type, target_id, reason, detail } = ctx.body || {};
    const types = ['user', 'moment', 'article', 'message', 'group', 'hometown_content', 'hometown_comment'];
    const reasons = ['politics', 'porn', 'fraud', 'harassment', 'infringement', 'impersonation', 'other'];
    if (!types.includes(target_type)) throw E.param('target_type 不合法');
    if (!isInt(target_id)) throw E.param('target_id 必填');
    if (!reasons.includes(reason)) throw E.param('reason 不合法');
    if (detail && [...String(detail)].length > 500) throw E.param('detail 不超过 500 字');
    // 举报小时级频控（防恶意刷举报淹没人工复核队列）：20 次/小时
    if (!hitRate(db, `report:${ctx.user.id}:hour`, 20, 3600).allowed) throw E.rate('举报过于频繁，请稍后再试');
    // 人工复核 SLA 24h（计划书 §9 D4）
    const sla = new Date(Date.now() + 24 * 3600 * 1000).toISOString();
    const info = run(
      db,
      'INSERT INTO reports(reporter_id,target_type,target_id,reason,detail,sla_deadline,created_at) VALUES(?,?,?,?,?,?,?)',
      ctx.user.id, target_type, Number(target_id), reason, detail ?? null, sla, now()
    );
    audit(db, { userId: ctx.user.id, event: 'report', targetId: Number(target_id), input: { target_type, reason } });
    return ok(ctx, { report_id: Number(info.lastInsertRowid), status: 'pending', sla: '24h', sla_deadline: sla });
  };
  router.post('/v1/misc/report', { auth: true }, handleReport);
  router.post('/v1/reports', { auth: true }, handleReport);

  // 申诉（契约 /misc/appeal）：冻结 24h / 内容 72h / 冒名 3 工作日 SLA
  router.post('/v1/misc/appeal', { auth: true }, (ctx) => {
    const { type, content } = ctx.body || {};
    const SLAS = { freeze: 24, content: 72, impersonation: 72 };
    if (!Object.keys(SLAS).includes(type)) throw E.param('type 仅支持 freeze / content / impersonation');
    if (!content || [...String(content)].length > 500) throw E.param('content 必填且不超过 500 字');
    // 申诉小时级频控：20 次/小时
    if (!hitRate(db, `appeal:${ctx.user.id}:hour`, 20, 3600).allowed) throw E.rate('申诉过于频繁，请稍后再试');
    const slaHours = SLAS[type];
    const sla = new Date(Date.now() + slaHours * 3600 * 1000).toISOString();
    const info = run(
      db,
      'INSERT INTO appeals(user_id,type,content,status,sla_deadline,created_at) VALUES(?,?,?,?,?,?)',
      ctx.user.id, type, String(content), 'pending', sla, now()
    );
    audit(db, { userId: ctx.user.id, event: 'appeal', input: { type } });
    return ok(ctx, { appeal_id: Number(info.lastInsertRowid), status: 'pending', sla: `${slaHours}h`, sla_deadline: sla });
  });

  // 媒体上传（契约 /misc/upload）：base64 先传后引用，media_id 回执；扩展名与大小上限按 scene 分档——
  // 图片 scene：jpg/jpeg/png/webp，≤2MB；chat_voice 语音：m4a/aac，≤2MB（60s AAC 约 500KB–1MB）；
  // chat_video 视频：mp4/mov，≤20MB（30 秒，客户端已限 20MB 内）。
  // bodyLimit 28MB：20MB 视频 base64 约 27MB + JSON 余量（全局 cap 1MB，见 app.js readBody）。
  // 落盘经 storage 分层：local 返回 /media/ 相对路径，oss 返回绝对公网 URL（URL 契约见 src/storage.js）
  router.post('/v1/misc/upload', { auth: true, bodyLimit: 28 * 1024 * 1024 }, async (ctx) => {
    const { scene, content_base64, ext } = ctx.body || {};
    const SCENES = ['avatar', 'chat_image', 'chat_voice', 'chat_video', 'evidence', 'feedback', 'moment'];
    const EXTS_IMAGE = { jpg: 'jpg', jpeg: 'jpg', png: 'png', webp: 'webp' };
    const EXTS_VOICE = { m4a: 'm4a', aac: 'aac' };
    const EXTS_VIDEO = { mp4: 'mp4', mov: 'mov' };
    if (!SCENES.includes(scene)) throw E.param('scene 不合法');
    const whitelist = scene === 'chat_voice' ? EXTS_VOICE : scene === 'chat_video' ? EXTS_VIDEO : EXTS_IMAGE;
    const normExt = whitelist[String(ext ?? '').toLowerCase()];
    if (!normExt) {
      throw E.param(scene === 'chat_voice' ? '语音仅支持 m4a / aac'
        : scene === 'chat_video' ? '视频仅支持 mp4 / mov'
        : '仅支持 jpg / png / webp');
    }
    if (!content_base64) throw E.param('content_base64 必填');
    const buf = Buffer.from(String(content_base64), 'base64');
    const maxBytes = scene === 'chat_video' ? 20 * 1024 * 1024 : 2 * 1024 * 1024;
    if (!buf.length || buf.length > maxBytes) {
      throw E.param(scene === 'chat_video' ? '视频为空或超过 20MB' : '文件为空或超过 2MB');
    }
    if (!hitRate(db, `upload:${ctx.user.id}:hour`, 50, 3600).allowed) throw E.rate('上传过于频繁');
    const { media_id, url } = await storage.put({ buf, ext: normExt });
    audit(db, { userId: ctx.user.id, event: 'upload', input: { scene, bytes: buf.length, storage: storage.name } });
    return ok(ctx, { media_id, url });
  });

  router.post('/v1/feedback', { auth: true }, (ctx) => {
    const { content, contact } = ctx.body || {};
    if (!content || [...String(content)].length > 1000) throw E.param('content 必填且不超过 1000 字');
    // 反馈小时级频控：20 次/小时
    if (!hitRate(db, `feedback:${ctx.user.id}:hour`, 20, 3600).allowed) throw E.rate('反馈过于频繁，请稍后再试');
    run(db, 'INSERT INTO feedback(user_id,content,contact,created_at) VALUES(?,?,?,?)',
      ctx.user.id, String(content), contact ?? null, now());
    return ok(ctx);
  });

  // 召集令公开落地页（H5 用，免鉴权）：班级单元名 + 已点亮头像墙 + 还差几人
  router.get('/v1/public/invites/:code', (ctx) => {
    const invite = q1(db, 'SELECT * FROM invites WHERE code=?', String(ctx.params.code));
    if (!invite) throw E.notFound('召集令不存在或已失效');
    const school = q1(db, 'SELECT * FROM schools WHERE school_id=?', invite.school_id);
    const members = q(
      db,
      `SELECT DISTINCT u.id, u.nickname, u.real_name FROM users u
       JOIN education_experiences e ON e.user_id=u.id
       WHERE u.status=1 AND e.school_id=? AND e.enroll_year=? AND e.class_name_norm=?
       ORDER BY u.id`,
      invite.school_id, invite.enroll_year, invite.class_norm
    );
    const placeholders = q1(
      db,
      'SELECT COUNT(*) c FROM placeholders WHERE school_id=? AND enroll_year=? AND class_norm=?',
      invite.school_id, invite.enroll_year, invite.class_norm
    ).c;
    const inviter = invite.created_by
      ? q1(db, 'SELECT nickname FROM users WHERE id=?', invite.created_by)
      : null;
    return ok(ctx, {
      code: invite.code,
      unit_name: `${school?.name ?? ''} ${invite.enroll_year}级 ${invite.class_name || invite.class_norm}`,
      inviter: inviter ? { nickname: inviter.nickname } : null,
      slogan: '就差你了，点亮我们班的名字',
      target: members.length + placeholders,
      lit: members.length,
      // 头像墙：昵称 + 掩码名（公开场景强制掩码，不走完整真名）+ 确定性配色
      avatars: members.map((m) => ({
        nickname: m.nickname,
        masked_name: maskName(m.real_name),
        avatar_color: AVATAR_COLORS[m.id % AVATAR_COLORS.length],
      })),
    });
  });
}

const AVATAR_COLORS = ['#DFE9E2', '#EEE2D8', '#E1E8EF', '#E9E2EC', '#EBE7DC', '#E0EBE5', '#F0E2DE'];

// 运营密度看板（X-Admin-Token 鉴权）：单元注册数 / 目标数 / 7 日留存
export function registerAdminRoutes(router, { db }) {
  // 达标定义（V3.0 §2.1）：注册 ≥15 人 且 7 留 ≥60%
  const qualified = (u) => u.registered >= 15 && (u.retention_7d ?? 0) >= 0.6;

  router.get('/admin-api/density/summary', { admin: true }, (ctx) => {
    const users = q1(db, 'SELECT COUNT(*) c FROM users WHERE status=1').c;
    const units = [...classUnits(db), ...townUnits(db)];
    const okUnits = units.filter(qualified);
    return ok(ctx, {
      total_units: units.length,
      qualified_units: okUnits.length,
      qualified_rate: units.length ? round2(okUnits.length / units.length) : 0,
      total_users: users,
      dau7_retention: retentionOf(db, q(db, 'SELECT id FROM users WHERE status=1').map((r) => r.id)),
    });
  });

  router.get('/admin-api/density/units', { admin: true }, (ctx) => {
    const level = ctx.query.level || 'class';
    const items =
      level === 'class' ? classUnits(db) :
      level === 'town' ? townUnits(db) : null;
    if (!items) throw E.param('level 仅支持 class / town');
    return ok(ctx, items.map((u) => ({ ...u, qualified: qualified(u) })));
  });

  function classUnits(db) {
    const rows = q(
      db,
      `SELECT e.school_id, s.name school_name, e.enroll_year, e.class_name_norm,
              COUNT(DISTINCT e.user_id) registered,
              GROUP_CONCAT(DISTINCT e.user_id) user_ids
       FROM education_experiences e JOIN schools s ON s.school_id=e.school_id
       WHERE e.class_name_norm != ''
       GROUP BY e.school_id, e.enroll_year, e.class_name_norm
       ORDER BY registered DESC`
    );
    return rows.map((r) => {
      const ph = q1(
        db,
        'SELECT COUNT(*) c FROM placeholders WHERE school_id=? AND enroll_year=? AND class_norm=?',
        r.school_id, r.enroll_year, r.class_name_norm
      ).c;
      const userIds = String(r.user_ids).split(',').map(Number);
      return {
        unit_name: `${r.school_name} · ${r.enroll_year}级 · ${r.class_name_norm}班`,
        level: 'class',
        school_id: r.school_id,
        school_name: r.school_name,
        enroll_year: r.enroll_year,
        class_norm: r.class_name_norm,
        registered: r.registered,
        target: r.registered + ph,
        retention_7d: retentionOf(db, userIds),
      };
    });
  }

  function townUnits(db) {
    const rows = q(
      db,
      `SELECT h.region_code, r.name region_name, COUNT(*) registered, GROUP_CONCAT(h.user_id) user_ids
       FROM user_hometowns h JOIN regions r ON r.code=h.region_code
       WHERE h.type=1 GROUP BY h.region_code ORDER BY registered DESC`
    );
    return rows.map((r) => ({
      unit_name: r.region_name,
      level: 'town',
      region_code: r.region_code,
      region_name: r.region_name,
      registered: r.registered,
      target: 200, // 镇级可存活临界值（V3.0 §2.1）
      retention_7d: retentionOf(db, String(r.user_ids).split(',').map(Number)),
    }));
  }

  // 7 留：注册满 7 天的用户中，近 7 天仍有审计活动的比例
  function retentionOf(db, userIds) {
    if (!userIds.length) return null;
    const sevenDaysAgo = new Date(Date.now() - 7 * 86400 * 1000).toISOString();
    const old = q(
      db,
      `SELECT id FROM users WHERE id IN (${userIds.join(',')}) AND created_at <= ?`,
      sevenDaysAgo
    ).map((r) => r.id);
    if (!old.length) return null;
    const active = q1(
      db,
      `SELECT COUNT(DISTINCT user_id) c FROM audit_logs WHERE user_id IN (${old.join(',')}) AND created_at >= ?`,
      sevenDaysAgo
    ).c;
    return round2(active / old.length);
  }

  function round2(n) {
    return Math.round(n * 100) / 100;
  }
}
