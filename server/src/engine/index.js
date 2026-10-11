import fs from 'node:fs';
import { q, q1, run, getPrivacy, isFriend, isBlockedBetween, countMutualFriends, regionChain, audit } from '../repo.js';
import { maskName, maskSurname, now } from '../util.js';

// 可见性决策引擎（设计报告 §22.1 / 计划书 §5.4）：全部规则配置化于 rules.json，
// 每次判定写决策快照（输入特征 + 命中规则 + 输出）到 audit_logs。
export const rules = JSON.parse(fs.readFileSync(new URL('./rules.json', import.meta.url), 'utf8'));

const RANK = { T0: 0, T1: 1, T2: 2, T3: 3 };
const TAG_OF = {
  same_class: '同班',
  same_school_overlap: '同校',
  same_grade: '同届',
  same_school: '同校',
  same_town: '同镇',
  same_town_age: '同镇',
  same_town_far: '同镇',
  same_county: '同县',
  same_county_far: '同县',
  same_city: '同城',
  mutual_friends: '共同好友',
};

const stageYears = (stage) => rules.intersection.stage_years[stage] ?? 6;

function overlapYears(x, y) {
  const a1 = x.enroll_year, a2 = a1 + stageYears(x.stage);
  const b1 = y.enroll_year, b2 = b1 + stageYears(y.stage);
  return Math.max(0, Math.min(a2, b2) - Math.max(a1, b1));
}

// 交集强度四级模型（§5.2.3）
export function computeIntersection(db, viewer, owner) {
  const cfg = rules.intersection;
  const evidences = [];
  const eduA = q(db, 'SELECT * FROM education_experiences WHERE user_id=?', viewer.id);
  const eduB = q(db, 'SELECT * FROM education_experiences WHERE user_id=?', owner.id);
  for (const x of eduA) {
    for (const y of eduB) {
      if (x.school_id !== y.school_id) continue;
      const sameClass =
        x.stage === y.stage && x.enroll_year === y.enroll_year &&
        x.class_name_norm && x.class_name_norm === y.class_name_norm;
      if (sameClass) {
        evidences.push({ tier: 'T3', type: 'same_class', edu: x, eduOther: y });
      } else if (overlapYears(x, y) >= cfg.school_overlap_min_years) {
        evidences.push({ tier: 'T3', type: 'same_school_overlap', edu: x, eduOther: y });
      } else if (x.enroll_year === y.enroll_year) {
        evidences.push({ tier: 'T2', type: 'same_grade', edu: x, eduOther: y });
      } else {
        evidences.push({ tier: 'T1', type: 'same_school', edu: x, eduOther: y });
      }
    }
  }
  const ha = q1(db, 'SELECT * FROM user_hometowns WHERE user_id=? AND type=1', viewer.id);
  const hb = q1(db, 'SELECT * FROM user_hometowns WHERE user_id=? AND type=1', owner.id);
  if (ha && hb && viewer.birth_year && owner.birth_year) {
    const ageDiff = Math.abs(viewer.birth_year - owner.birth_year);
    const ca = regionChain(db, ha.region_code);
    const cb = regionChain(db, hb.region_code);
    const la = (lv) => ca.find((r) => r.level === lv);
    const lb = (lv) => cb.find((r) => r.level === lv);
    if (la(4) && lb(4) && la(4).code === lb(4).code) {
      const region = la(4);
      if (ageDiff <= cfg.same_town_max_age_t3) evidences.push({ tier: 'T3', type: 'same_town', region });
      else if (ageDiff <= cfg.same_town_max_age_t2) evidences.push({ tier: 'T2', type: 'same_town_age', region });
      else evidences.push({ tier: 'T1', type: 'same_town_far', region });
    } else if (la(3) && lb(3) && la(3).code === lb(3).code) {
      const region = la(3);
      if (ageDiff <= cfg.same_county_max_age_t2) evidences.push({ tier: 'T2', type: 'same_county', region });
      else evidences.push({ tier: 'T1', type: 'same_county_far', region });
    } else if (la(2) && lb(2) && la(2).code === lb(2).code) {
      evidences.push({ tier: 'T1', type: 'same_city', region: la(2) });
    }
  }
  const mutual = countMutualFriends(db, viewer.id, owner.id);
  if (mutual >= cfg.mutual_friends_t3) evidences.push({ tier: 'T3', type: 'mutual_friends', count: mutual });
  else if (mutual >= cfg.mutual_friends_t2) evidences.push({ tier: 'T2', type: 'mutual_friends', count: mutual });

  let best = { tier: 'T0', type: 'none' };
  for (const e of evidences) if (RANK[e.tier] > RANK[best.tier]) best = e;
  const tags = [...new Set(evidences.map((e) => TAG_OF[e.type]).filter(Boolean))];
  return { tier: best.tier, best, evidences, mutual, tags };
}

function fillBanner(tpl, e, inter) {
  return tpl
    .replace('{enroll_year}', e.edu?.enroll_year ?? '')
    .replace('{school}', e.edu?.school_name_snapshot ?? '')
    .replace('{class_raw}', e.edu?.class_name_raw ?? '')
    .replace('{town}', e.region?.name ?? '')
    .replace('{count}', inter.mutual);
}

// 交集横幅（含 V0 限定句：任一经历 verification_level=0 时使用「未验证」措辞，§3.1）
function buildBanner(inter) {
  const t = rules.banner;
  const e = inter.best;
  if (!e || e.tier === 'T0') return null;
  const unverified = e.edu && e.eduOther && (e.edu.verification_level === 0 || e.eduOther.verification_level === 0);
  switch (e.type) {
    case 'same_class':
      return fillBanner(unverified ? t.same_class_unverified : t.same_class, e, inter);
    case 'same_school_overlap':
    case 'same_grade':
    case 'same_school':
      return fillBanner(unverified ? t.same_school_unverified : t.same_school, e, inter);
    case 'same_town':
    case 'same_town_age':
      return fillBanner(t.same_town, e, inter);
    case 'same_county':
      return fillBanner(t.same_county, e, inter);
    case 'mutual_friends':
      return fillBanner(t.mutual, e, inter);
    default:
      return t.default;
  }
}

function buildReason(inter) {
  const e = inter.best;
  if (!e || e.tier === 'T0') return null;
  if (e.edu) {
    return [e.edu.enroll_year ? `${e.edu.enroll_year}级` : null, e.edu.school_name_snapshot, e.edu.class_name_raw]
      .filter(Boolean)
      .join(' ');
  }
  if (e.region) return `${e.region.name} 老乡`;
  if (e.type === 'mutual_friends') return `${inter.mutual} 位共同好友`;
  return null;
}

function applyNameLevel(level, realName) {
  if (!realName) return null;
  if (level === 'full') return realName;
  if (level === 'mask') return maskName(realName);
  if (level === 'surname') return maskSurname(realName);
  return null;
}

/**
 * resolve_view（§22.1）：返回某 viewer 看 owner 的真名展示值 / 交集横幅 / 交集标签。
 * 所有返回用户对象的出口必须经此函数（渐显中间件），客户端拿不到原始真名（除非规则允许）。
 * opts.forceFullName：好友申请「钥匙式披露」（§5.2.6，申请人 attach_real_name=1 时）
 */
export function resolveUserView(db, viewer, owner, opts = {}) {
  if (viewer.id === owner.id) {
    return { self: true, tier: 'FRIEND', displayTier: 'FRIEND', realName: owner.real_name ?? null, banner: null, tags: [], mutual: 0, reason: null };
  }
  if (isBlockedBetween(db, viewer.id, owner.id)) {
    return { blocked: true, tier: 'T0', displayTier: 'T0', realName: null, banner: null, tags: [], mutual: 0, reason: null };
  }
  const friend = isFriend(db, viewer.id, owner.id);
  const inter = computeIntersection(db, viewer, owner);
  const privacy = getPrivacy(db, owner);
  const hits = [`intersection=${inter.tier}`];

  let tier = friend ? 'FRIEND' : inter.tier;
  let displayTier = tier;
  let realName;
  if (friend) {
    hits.push('relation=friend');
    realName = applyNameLevel(rules.friend_display, owner.real_name);
  } else {
    if (
      rules.female_protection.enabled &&
      privacy.female_protect &&
      (owner.gender === 2 || owner.is_minor)
    ) {
      displayTier = rules.female_protection.degrade[displayTier] ?? 'T0';
      hits.push('female_protect');
    }
    const mode = privacy.name_mode || 'balanced';
    hits.push(`name_mode=${mode}`);
    const level = rules.name_matrix[mode]?.[displayTier] ?? 'hidden';
    hits.push(`display=${level}`);
    realName = applyNameLevel(level, owner.real_name);
  }
  if (opts.forceFullName) {
    realName = owner.real_name ?? null;
    hits.push('force_full(attach_real_name)');
  }
  const out = {
    tier,
    displayTier,
    realName,
    banner: buildBanner(inter),
    tags: inter.tags,
    mutual: inter.mutual,
    reason: buildReason(inter),
  };
  // 决策审计仅对资料卡（scene='profile'）落库：检索/推荐/列表等批量场景逐条写会放大
  // audit_logs（一次检索 N 条结果 = N 条审计）；资料卡为单次主动查看，保留完整取证链
  if (opts.scene === 'profile') {
    audit(db, {
      userId: viewer.id,
      event: 'visibility_decision',
      targetId: owner.id,
      scene: opts.scene,
      input: {
        intersection: inter.tier,
        mutual: inter.mutual,
        owner_gender: owner.gender,
        owner_name_mode: privacy.name_mode,
        friend,
      },
      rule: { hits },
      output: { real_name: out.realName, display_tier: displayTier, banner: out.banner },
    });
  }
  return out;
}

// V1 同窗互证自动升级：好友申请 accept 后调用；某段经历同单元好友 ≥ 阈值 → V1/peer_review
export function runPeerVerificationUpgrade(db, userId) {
  const cfg = rules.peer_verify;
  const edus = q(
    db,
    'SELECT * FROM education_experiences WHERE user_id=? AND verification_level < ?',
    userId, cfg.level
  );
  const upgraded = [];
  for (const e of edus) {
    if (!e.class_name_norm) continue;
    const { c } = q1(
      db,
      `SELECT COUNT(DISTINCT f.friend_id) c FROM friendships f
       JOIN education_experiences ee ON ee.user_id = f.friend_id
       WHERE f.user_id=? AND ee.school_id=? AND ee.enroll_year=? AND ee.stage=? AND ee.class_name_norm=?`,
      userId, e.school_id, e.enroll_year, e.stage, e.class_name_norm
    );
    if (c >= cfg.min_same_unit_friends) {
      run(
        db,
        'UPDATE education_experiences SET verification_level=?, verification_source=?, verified_at=? WHERE id=?',
        cfg.level, cfg.source, now(), e.id
      );
      audit(db, {
        userId,
        event: 'peer_verify_upgrade',
        targetId: e.id,
        input: { same_unit_friends: c, threshold: cfg.min_same_unit_friends },
        output: { verification_level: cfg.level, source: cfg.source },
      });
      upgraded.push(e.id);
    }
  }
  return upgraded;
}

// 内容安全（§20.5）：拦截手机号 / 微信号 / QQ号 / 加V 变体。
// 防误伤原则：手机号独立命中；微信号与 QQ 号必须带紧邻上下文关键词
// （微信/威信/薇/加V/vx/wechat、QQ/q q，允许冒号/空格间隔）才判定，
// 纯独立英文单词（"Saturday"）与无上下文数字串（"20240601聚会"）不拦。
const PHONE_PATTERN = /1[3-9]\d{9}/; // 手机号：独立命中
const WECHAT_PATTERN = /(微信|威信|薇|加v|vx|wechat)\s*[:：]?\s*[A-Za-z][A-Za-z0-9_-]{5,19}/i; // 微信号：须带上下文
const QQ_PATTERN = /q\s*q\s*[:：]?\s*\d{5,11}/i; // QQ 号：须带 QQ / q q 上下文
const CONTACT_PATTERNS = [
  PHONE_PATTERN,
  WECHAT_PATTERN,
  QQ_PATTERN,
  /(加|\+|十)\s*[VvＶｖ]/, // 加我V / +V
  /[VvＶｖ]\s*(信|[XxＸｘ])/, // V信 / VX
];

export function containsContactInfo(text) {
  if (!text) return false;
  return CONTACT_PATTERNS.some((re) => re.test(String(text)));
}
