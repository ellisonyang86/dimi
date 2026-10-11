// 场景化端到端验证：默认自动启动临时数据库和随机端口，跑完即关闭。
// 运行：node scripts/scenario_check.mjs；显式使用外部测试实例时须同时提供 SMOKE_BASE / SMOKE_DB_PATH。
// 覆盖：
//   a. 登录种子号 → 教育经历 → 加入班级群 → 群内发消息 → 另一账号轮询收到
//   b. 好友申请全流程（含自动破冰系统消息）
//   c. 动态可见性矩阵（public/classmates/fellows/private × 4 视角 × 主feed/同学圈/老乡圈）
//   d. 觅豆链路（签到/教育奖励/加好友奖励 → 私聊红包 → 领取 → 明细 → 动态打赏）
//   e. 高隐私分组门禁（锁定 → 密码解锁 → 短时凭证 → 主动锁定失效）
//   f. 频控 42901 need_captcha → 滑块验证 → 放行（短信 + 精确检索两个消费点）
// 说明：滑块 target_x 不下发是安全设计；脚本经本地 SQLite 只读取出缺口坐标以完成真实验证，
//       仅作为测试桥（等同用户手动滑对），不绕过任何服务端校验。
import { DatabaseSync } from 'node:sqlite';
import { startTestServer } from '../test/helpers.js';

if (process.env.SMOKE_BASE && !process.env.SMOKE_DB_PATH) {
  throw new Error('外部场景实例必须同时提供 SMOKE_DB_PATH，避免校验时访问错误数据库');
}
const owned = process.env.SMOKE_BASE ? null : await startTestServer();
const base = owned?.base ?? process.env.SMOKE_BASE;
const dbPath = owned?.db.prepare('PRAGMA database_list').get().file ?? process.env.SMOKE_DB_PATH;

let passed = 0, failed = 0;
const failures = [];
function step(name, ok, extra = '') {
  if (ok) passed++;
  else { failed++; failures.push({ name, extra }); }
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${extra ? '  → ' + extra : ''}`);
}
const section = (t) => console.log(`\n===== 场景 ${t} =====`);

async function api(method, p, { token, body, headers } = {}) {
  const res = await fetch(base + p, {
    method,
    headers: {
      ...(body ? { 'Content-Type': 'application/json' } : {}),
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
      ...headers,
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  let json = null;
  try { json = await res.json(); } catch { /* ignore */ }
  return { status: res.status, json };
}
const brief = (r) => `HTTP ${r.status} code=${r.json?.code} msg=${r.json?.message}`;

const randPhone = () => '136' + String(Math.floor(Math.random() * 1e8)).padStart(8, '0');

async function registerUser(nickname, realName) {
  const phone = randPhone();
  const sms = await api('POST', '/v1/auth/sms/send', { body: { phone } });
  if (sms.json?.code !== 0 || !sms.json.data?.sms_code) throw new Error('sms/send（需 DIMI_SMS_DEV=true）: ' + brief(sms));
  const reg = await api('POST', '/v1/auth/register', {
    body: { phone, sms_code: sms.json.data.sms_code, nickname, gender: 1, birth_year: 1990 },
  });
  if (reg.json?.code !== 0) throw new Error('register: ' + brief(reg));
  const token = reg.json.data.access_token;
  const userId = reg.json.data.user.user_id;
  if (realName) await api('PUT', '/v1/users/me', { token, body: { real_name: realName } });
  return { token, userId, phone, nickname };
}

// 种子号登录：优先 dev 短信回显，撞 60s 频控则密码兜底（种子密码 demo1234）
async function loginSeed(phone) {
  const sms = await api('POST', '/v1/auth/sms/send', { body: { phone } });
  if (sms.json?.code === 0 && sms.json.data?.sms_code) {
    const login = await api('POST', '/v1/auth/login', { body: { grant_type: 'sms', phone, sms_code: sms.json.data.sms_code } });
    if (login.json?.code === 0) return { token: login.json.data.access_token, via: 'sms' };
  }
  const pw = await api('POST', '/v1/auth/login', { body: { grant_type: 'password', phone, password: 'demo1234' } });
  if (pw.json?.code === 0) return { token: pw.json.data.access_token, via: 'password' };
  throw new Error('种子号登录失败: sms=' + brief(sms) + ' password=' + brief(pw));
}

async function befriend(from, to, msg = '老同学，是我') {
  const req = await api('POST', '/v1/friends/requests', { token: from.token, body: { to_user_id: to.userId, verify_msg: msg } });
  if (req.json?.code !== 0) return { req };
  const inbox = await api('GET', '/v1/friends/requests?box=inbox', { token: to.token });
  const item = inbox.json?.data?.items?.find((i) => i.from_user_id === from.userId && i.status === 'pending');
  if (!item) return { req, inbox };
  const acc = await api('POST', `/v1/friends/requests/${item.id}/accept`, { token: to.token });
  return { req, item, acc, convId: acc.json?.data?.conversation_id };
}

// 测试桥：滑块缺口坐标只落库不下发，脚本从本地库只读取出以完成真实 /captcha/verify
function captchaTargetX(captchaId) {
  let db;
  try { db = new DatabaseSync(dbPath, { readOnly: true }); }
  catch { throw new Error('无法以只读方式打开测试数据库'); }
  try {
    return db.prepare('SELECT target_x FROM captcha_challenges WHERE captcha_id=?').get(captchaId)?.target_x ?? null;
  } finally { db.close(); }
}
async function solveCaptcha() {
  const ch = await api('GET', '/v1/captcha/slider');
  if (ch.json?.code !== 0) return { error: 'slider: ' + brief(ch) };
  const x = captchaTargetX(ch.json.data.captcha_id);
  if (x == null) return { error: '本地库未查到 target_x' };
  const v = await api('POST', '/v1/captcha/verify', { body: { captcha_id: ch.json.data.captcha_id, x } });
  if (v.json?.code !== 0) return { error: 'verify: ' + brief(v) };
  return { token: v.json.data.captcha_token };
}

// ============================================================
try {
section('a. 登录 → 教育经历 → 班级群 → 群消息 → 轮询');
// ============================================================
const seed = await loginSeed('13800000001'); // 李娟：城关镇第二小学 1996级 六年2班
step('a1. 种子号李娟登录（dev 短信回显/密码兜底）', !!seed.token, `via=${seed.via}`);
const seedEdus = await api('GET', '/v1/users/me/educations', { token: seed.token });
const seedEdu = seedEdus.json?.data?.items?.find((e) => e.school_id === 1001 && e.enroll_year === 1996);
step('a2. 李娟教育经历含 1001/1996', !!seedEdu, JSON.stringify(seedEdu?.class_name_raw ?? seedEdu?.class_name_norm));

const ga = await registerUser('场景群甲', '群发甲');
const eduGa = await api('POST', '/v1/users/me/educations', {
  token: ga.token, body: { stage: 'PRIMARY', school_id: 1001, enroll_year: 1996, class_name: '六年2班' },
});
step('a3. 新账号添加同班教育经历', eduGa.json?.code === 0, brief(eduGa));

// 无对应经历者入群应被拒（40301）
const gb = await registerUser('场景群乙', '群发乙');
const joinDeny = await api('POST', '/v1/class-groups/join', {
  token: gb.token, body: { school_id: 1001, enroll_year: 1996, class_name: '六年2班' },
});
step('a4. 无班级经历者入群被拒 40301', joinDeny.json?.code === 40301, brief(joinDeny));

const joinA = await api('POST', '/v1/class-groups/join', {
  token: ga.token, body: { school_id: 1001, enroll_year: 1996, class_name: '六年2班' },
});
step('a5. 有经历者加入班级群', joinA.json?.code === 0 && !!joinA.json?.data?.conv_id, `conv=${joinA.json?.data?.conv_id} members=${joinA.json?.data?.member_count}`);
const groupConv = joinA.json?.data?.conv_id;
const joinSeed = await api('POST', '/v1/class-groups/join', {
  token: seed.token, body: { school_id: 1001, enroll_year: 1996, class_name: '六年2班' },
});
step('a6. 李娟加入同一班级群', joinSeed.json?.code === 0 && joinSeed.json?.data?.conv_id === groupConv, brief(joinSeed));

const gaClientMsgId = `scn-a-${Date.now()}`;
const gmsg = await api('POST', `/v1/conversations/${groupConv}/messages`, {
  token: ga.token, body: { client_msg_id: gaClientMsgId, msg_type: 'text', content: '同学们好，我是新来的群发甲' },
});
step('a7. 群内发消息（群成员无需互为好友）', gmsg.json?.code === 0 && !!gmsg.json?.data?.msg_id, brief(gmsg));

// 李娟轮询：会话未读 + 增量拉取
const mineSeed = await api('GET', '/v1/class-groups/mine', { token: seed.token });
const seedGroup = mineSeed.json?.data?.items?.find((i) => i.group?.conv_id === groupConv)?.group;
step('a8. 李娟班级群列表未读≥1', !!seedGroup && seedGroup.unread_count >= 1, `unread=${seedGroup?.unread_count}`);
const poll = await api('GET', `/v1/conversations/${groupConv}/messages?since_msg_id=0`, { token: seed.token });
// 按本次运行的 client_msg_id 匹配（群会话跨运行保留历史，内容相同的旧消息不能误判）
const gotMsg = poll.json?.data?.items?.find((m) => m.client_msg_id === gaClientMsgId);
step('a9. 李娟轮询收到群消息', !!gotMsg && gotMsg.sender?.user_id === ga.userId, `msgs=${poll.json?.data?.items?.length}`);
// 成员列表可见两人（非好友也可见，姓名走渐显引擎）
const members = await api('GET', `/v1/class-groups/${groupConv}/members`, { token: seed.token });
step('a10. 群成员列表含新同学', members.json?.code === 0 && members.json.data.items.some((m) => m.user_id === ga.userId),
  `members=${members.json?.data?.items?.length}`);

// ============================================================
section('b. 好友申请全流程');
// ============================================================
const ba = await registerUser('场景甲', '申甲');
const bb = await registerUser('场景乙', '申乙');
const freq = await api('POST', '/v1/friends/requests', { token: ba.token, body: { to_user_id: bb.userId, verify_msg: '乙，我是甲，还记得我吗' } });
step('b1. A 发出好友申请', freq.json?.code === 0 && !!freq.json?.data?.request_id, brief(freq));
const inboxB = await api('GET', '/v1/friends/requests?box=inbox', { token: bb.token });
const bItem = inboxB.json?.data?.items?.find((i) => i.from_user_id === ba.userId && i.status === 'pending');
step('b2. B 收件箱看到 pending 申请', !!bItem && bItem.verify_msg === '乙，我是甲，还记得我吗');
const bAcc = await api('POST', `/v1/friends/requests/${bItem?.id}/accept`, { token: bb.token });
step('b3. B 通过申请返回会话', bAcc.json?.code === 0 && !!bAcc.json?.data?.conversation_id, `conv=${bAcc.json?.data?.conversation_id}`);
const bConv = bAcc.json?.data?.conversation_id;
const flA = await api('GET', '/v1/friends', { token: ba.token });
const flB = await api('GET', '/v1/friends', { token: bb.token });
step('b4. 双方好友列表互见',
  flA.json?.data?.items?.some((i) => i.user_id === bb.userId) && flB.json?.data?.items?.some((i) => i.user_id === ba.userId));
const bMsgs = await api('GET', `/v1/conversations/${bConv}/messages?since_msg_id=0`, { token: ba.token });
const ice = bMsgs.json?.data?.items?.find((m) => m.msg_type === 'system');
const iceJson = (() => { try { return JSON.parse(ice?.content ?? ''); } catch { return null; } })();
step('b5. 自动破冰系统消息进会话', !!ice && iceJson?.type === 'ice_breaker', iceJson?.banner ?? '');

// ============================================================
section('c. 动态可见性矩阵');
// ============================================================
// 角色：P=作者；Q=同班好友（同校同届同班+同乡）；R=好友但不同届不同乡；S=非好友同窗同乡；T=非好友无交集
// P 发四条动态：pub(public) cls(classmates) fel(fellows) pri(private)
// 预期矩阵（✓=该视角在该位置可见）：
//   视角            | 主feed: pub cls fel pri | 同学圈: pub cls fel pri | 老乡圈: pub cls fel pri
//   P 自己          |        ✓   ✓   ✓   ✓    |        ✓   ✓   ✗   ✗    |        ✓   ✗   ✓   ✗
//   Q 同班好友      |        ✓   ✓   ✓   ✗    |        ✓   ✓   ✗   ✗    |        ✓   ✗   ✓   ✗
//   R 好友(异届异乡)|        ✓   ✗   ✗   ✗    |        ✗   ✗   ✗   ✗    |        ✗   ✗   ✗   ✗
//   S 非好友同窗同乡|        ✗   ✗   ✗   ✗    |        ✓   ✓   ✗   ✗    |        ✓   ✗   ✓   ✗
//   T 非好友无交集  |        ✗   ✗   ✗   ✗    |        ✗   ✗   ✗   ✗    |        ✗   ✗   ✗   ✗
// 依据：主feed好友门（仅自己+好友）+ canSeeMoment；同学圈=同校同届作者的 public|classmates；
// 老乡圈=家乡同市作者的 public|fellows；private/partial/excluded 不进圈页。
const P = await registerUser('动态作者', '动态甲');
const Q = await registerUser('同班好友', '动态乙');
const R = await registerUser('异届好友', '动态丙');
const S = await registerUser('同窗路人', '动态丁');
const T = await registerUser('纯路人', '动态戊');
for (const [u, edu, home] of [
  [P, { stage: 'PRIMARY', school_id: 1001, enroll_year: 1996, class_name: '六年5班' }, '411623102'],
  [Q, { stage: 'PRIMARY', school_id: 1001, enroll_year: 1996, class_name: '六年5班' }, '411623102'],
  [R, { stage: 'PRIMARY', school_id: 1001, enroll_year: 1997, class_name: '六年1班' }, '330106005'],
  [S, { stage: 'PRIMARY', school_id: 1001, enroll_year: 1996, class_name: '六年7班' }, '411623102'],
]) {
  await api('POST', '/v1/users/me/educations', { token: u.token, body: edu });
  await api('PUT', '/v1/users/me/hometown', { token: u.token, body: { type: 1, region_code: home } });
}
await api('PUT', '/v1/users/me/hometown', { token: T.token, body: { type: 1, region_code: '330106005' } }); // T 无教育经历、异乡
const frPQ = await befriend(P, Q, '同班的老同学');
const frPR = await befriend(P, R, '隔壁班的老同学');
step('c0. P 与 Q/R 成为好友（S/T 保持非好友）', !!frPQ.convId && !!frPR.convId);

const mPub = await api('POST', '/v1/moments', { token: P.token, body: { content_type: 'text', content: '公开：回母校转了转', visibility: 'public' } });
const mCls = await api('POST', '/v1/moments', { token: P.token, body: { content_type: 'text', content: '同学圈：咱们届聚一次', visibility: 'classmates' } });
const mFel = await api('POST', '/v1/moments', { token: P.token, body: { content_type: 'text', content: '老乡圈：周口老乡集合', visibility: 'fellows' } });
const mPri = await api('POST', '/v1/moments', { token: P.token, body: { content_type: 'text', content: '私密：仅自己可见', visibility: 'private' } });
const ids = {
  pub: mPub.json?.data?.moment_id, cls: mCls.json?.data?.moment_id,
  fel: mFel.json?.data?.moment_id, pri: mPri.json?.data?.moment_id,
};
step('c1. P 发布 public/classmates/fellows/private 四条动态', !!(ids.pub && ids.cls && ids.fel && ids.pri), JSON.stringify(ids));

async function feedIds(u, visibility) {
  const r = await api('GET', '/v1/moments/feed' + (visibility ? `?visibility=${visibility}` : ''), { token: u.token });
  return r.json?.data?.items?.map((m) => m.moment_id) ?? [];
}
const expectMatrix = {
  //          主feed               同学圈                老乡圈
  P: { main: 'pub,cls,fel,pri', classmates: 'pub,cls', fellows: 'pub,fel' },
  Q: { main: 'pub,cls,fel', classmates: 'pub,cls', fellows: 'pub,fel' },
  R: { main: 'pub', classmates: '', fellows: '' },
  S: { main: '', classmates: 'pub,cls', fellows: 'pub,fel' },
  T: { main: '', classmates: '', fellows: '' },
};
let matrixOk = true;
const matrixLog = [];
for (const [name, u] of Object.entries({ P, Q, R, S, T })) {
  for (const [surface, vis] of [['main', null], ['classmates', 'classmates'], ['fellows', 'fellows']]) {
    const got = await feedIds(u, vis);
    for (const key of ['pub', 'cls', 'fel', 'pri']) {
      const should = (expectMatrix[name][surface] || '').split(',').includes(key);
      const actual = got.includes(ids[key]);
      if (should !== actual) {
        matrixOk = false;
        matrixLog.push(`${name}/${surface}/${key}: 预期${should ? '可见' : '不可见'}实际${actual ? '可见' : '不可见'}`);
      }
    }
  }
}
step('c2. 可见性矩阵 5 视角 × 3 位置 × 4 动态 全部符合预期', matrixOk, matrixLog.join(' | ') || '60 格全对');

// 详情直访：S（同窗非好友）可见 public 与 classmates；R（好友异届）看 classmates 被拒；T 看 public 被拒
const detSPub = await api('GET', `/v1/moments/${ids.pub}`, { token: S.token });
const detSCls = await api('GET', `/v1/moments/${ids.cls}`, { token: S.token });
const detRCls = await api('GET', `/v1/moments/${ids.cls}`, { token: R.token });
const detTPub = await api('GET', `/v1/moments/${ids.pub}`, { token: T.token });
step('c3. 详情直访与圈页语义一致', detSPub.json?.code === 0 && detSCls.json?.code === 0 && detRCls.json?.code === 40301 && detTPub.json?.code === 40301,
  `S/pub=${detSPub.json?.code} S/cls=${detSCls.json?.code} R/cls=${detRCls.json?.code} T/pub=${detTPub.json?.code}`);

// ============================================================
section('d. 觅豆链路：签到 → 红包 → 领取 → 明细 → 打赏');
// ============================================================
const W1 = await registerUser('钱包甲', '钱甲');
const W2 = await registerUser('钱包乙', '钱乙');
const balOf = async (u) => (await api('GET', '/v1/wallet', { token: u.token })).json?.data?.balance;

const w0 = await balOf(W1);
const ck1 = await api('POST', '/v1/wallet/checkin', { token: W1.token });
const ck2 = await api('POST', '/v1/wallet/checkin', { token: W1.token });
step('d1. 签到 +5 且当日幂等', w0 === 0 && ck1.json?.data?.granted === true && ck1.json?.data?.amount === 5
  && ck2.json?.data?.granted === false && ck2.json?.data?.balance === 5,
  `b0=${w0} after=${ck2.json?.data?.balance}`);

await api('POST', '/v1/users/me/educations', { token: W1.token, body: { stage: 'PRIMARY', school_id: 1001, enroll_year: 1996, class_name: '六年5班' } });
const wAfterEdu = await balOf(W1);
step('d2. 完善首条教育经历 +10', wAfterEdu === 15, `balance=${wAfterEdu}`);

const frW = await befriend(W1, W2, '加个好友');
const wAfterFriend = await balOf(W1);
step('d3. 成功添加好友 +30（每目标一次）', !!frW.convId && wAfterFriend === 45, `balance=${wAfterFriend}`);

await api('POST', '/v1/wallet/checkin', { token: W2.token }); // W2 至少有 5，便于后面对账
const rp = await api('POST', '/v1/red-packets', {
  token: W1.token, body: { conv_id: frW.convId, type: 'normal', total_amount: 10, count: 1, greeting: '请你喝汽水' },
});
step('d4. 私聊发红包 10 觅豆（固定 1 份）', rp.json?.code === 0 && rp.json?.data?.balance === 35 && !!rp.json?.data?.packet_id,
  `packet=${rp.json?.data?.packet_id} balance=${rp.json?.data?.balance}`);
const packetId = rp.json?.data?.packet_id;

const rpMsg = await api('GET', `/v1/conversations/${frW.convId}/messages?since_msg_id=0`, { token: W2.token });
step('d5. 对方会话内收到红包消息卡', rpMsg.json?.data?.items?.some((m) => m.msg_type === 'red_packet' && (m.content ?? '').includes(packetId)));

const selfClaim = await api('POST', `/v1/red-packets/${packetId}/claim`, { token: W1.token });
step('d6. 自己发的私聊红包不能自己领', selfClaim.json?.code === 40001, brief(selfClaim));
const claim = await api('POST', `/v1/red-packets/${packetId}/claim`, { token: W2.token });
step('d7. 对方领取成功', claim.json?.code === 0 && claim.json?.data?.amount === 10 && claim.json?.data?.packet?.status === 'finished',
  `amount=${claim.json?.data?.amount} balance=${claim.json?.data?.balance}`);
const claimAgain = await api('POST', `/v1/red-packets/${packetId}/claim`, { token: W2.token });
step('d8. 重复领取被拒', claimAgain.json?.code === 40001, brief(claimAgain));

const w1Bal = await balOf(W1);
const w2Bal = await balOf(W2);
const txW1 = await api('GET', '/v1/wallet/transactions', { token: W1.token });
const txW2 = await api('GET', '/v1/wallet/transactions', { token: W2.token });
const txSend = txW1.json?.data?.items?.find((t) => t.biz_type === 'red_packet_send');
const txClaim = txW2.json?.data?.items?.find((t) => t.biz_type === 'red_packet_claim');
step('d9. 双方余额与流水正确',
  w1Bal === 35 && w2Bal === 15 && txSend?.direction === 'out' && txSend?.amount === 10 && txSend?.balance_after === 35
  && txClaim?.direction === 'in' && txClaim?.amount === 10 && txClaim?.balance_after === 15,
  `W1=${w1Bal} W2=${w2Bal}`);

const w2moment = await api('POST', '/v1/moments', { token: W2.token, body: { content_type: 'text', content: '第一条动态，求鼓励', visibility: 'public' } });
const w2AfterMoment = await balOf(W2);
step('d10. 发布首条动态 +10', w2moment.json?.code === 0 && w2AfterMoment === 25, `balance=${w2AfterMoment}`);
const giftBad = await api('POST', `/v1/moments/${w2moment.json?.data?.moment_id}/gifts`, { token: W1.token, body: { coin_amount: 3 } });
const gift = await api('POST', `/v1/moments/${w2moment.json?.data?.moment_id}/gifts`, { token: W1.token, body: { coin_amount: 5 } });
step('d11. 打赏：非法面额拒 40001，5 觅豆打赏成功', giftBad.json?.code === 40001 && gift.json?.code === 0 && gift.json?.data?.balance === 30,
  `W1 balance=${gift.json?.data?.balance}`);
const giftList = await api('GET', `/v1/moments/${w2moment.json?.data?.moment_id}/gifts`, { token: W2.token });
const w2Final = await balOf(W2);
step('d12. 打赏到账与榜单正确', giftList.json?.data?.total_coins === 5 && giftList.json?.data?.total_count === 1 && w2Final === 30,
  `W2=${w2Final} gifts=${giftList.json?.data?.total_coins}`);

// ============================================================
section('e. 高隐私分组门禁');
// ============================================================
const X1 = await registerUser('隐私甲', '隐甲');
const X2 = await registerUser('隐私乙', '隐乙');
const frX = await befriend(X1, X2, '加个好友');
step('e0. X1/X2 成为好友', !!frX.convId);

const noPw = await api('POST', '/v1/contact-groups', { token: X1.token, body: { name: '密友', privacy_level: 'high' } });
step('e1. 未设隐私密码拒建高隐私组', noPw.json?.code === 40001, brief(noPw));
await api('PUT', '/v1/privacy/password', { token: X1.token, body: { password: 'scenario-pw-1' } });
const gHigh = await api('POST', '/v1/contact-groups', { token: X1.token, body: { name: '密友', privacy_level: 'high' } });
step('e2. 设密码后创建高隐私分组', gHigh.json?.code === 0 && !!gHigh.json?.data?.group_id);
await api('PUT', `/v1/friends/${X2.userId}/group`, { token: X1.token, body: { group_id: gHigh.json?.data?.group_id } });

const listLock = await api('GET', '/v1/friends', { token: X1.token });
step('e3. 未解锁：好友列表隐藏且 locked_count=1',
  !listLock.json?.data?.items?.some((i) => i.user_id === X2.userId) && listLock.json?.data?.locked_count === 1);
const cardLock = await api('GET', `/v1/users/${X2.userId}`, { token: X1.token });
step('e4. 未解锁：资料卡门禁 40301 locked', cardLock.json?.code === 40301 && cardLock.json?.data?.locked === true, brief(cardLock));

const badPw = await api('POST', '/v1/privacy/groups/unlock', { token: X1.token, body: { password: 'wrong-pw' } });
step('e5. 错误隐私密码拒绝', badPw.json?.code === 40001, brief(badPw));
const unlock = await api('POST', '/v1/privacy/groups/unlock', { token: X1.token, body: { password: 'scenario-pw-1' } });
step('e6. 正确密码换到短时凭证', unlock.json?.code === 0 && !!unlock.json?.data?.unlock_token, `ttl=${unlock.json?.data?.expires_in}s`);
const ut = unlock.json?.data?.unlock_token;
const listUn = await api('GET', '/v1/friends', { token: X1.token, headers: { 'X-Group-Unlock': ut } });
const cardUn = await api('GET', `/v1/users/${X2.userId}`, { token: X1.token, headers: { 'X-Group-Unlock': ut } });
step('e7. 凭证可访问列表与资料卡', listUn.json?.data?.items?.some((i) => i.user_id === X2.userId) && cardUn.json?.code === 0);
const relock = await api('POST', '/v1/privacy/groups/lock', { token: X1.token });
const listRelock = await api('GET', '/v1/friends', { token: X1.token, headers: { 'X-Group-Unlock': ut } });
step('e8. 主动锁定后凭证立即失效', relock.json?.code === 0 && !listRelock.json?.data?.items?.some((i) => i.user_id === X2.userId));

// ============================================================
section('f. 频控 42901 → 滑块验证 → 放行');
// ============================================================
// f1: 短信 60s 间隔频控（sms:interval:{phone}，1 次/60s）
const fPhone = randPhone();
const sms1 = await api('POST', '/v1/auth/sms/send', { body: { phone: fPhone } });
const sms2 = await api('POST', '/v1/auth/sms/send', { body: { phone: fPhone } });
step('f1. 同号 60s 内二次发送触发 42901 need_captcha',
  sms1.json?.code === 0 && sms2.json?.code === 42901 && sms2.json?.data?.need_captcha === true,
  `first=${sms1.json?.code} second=${sms2.json?.code}`);

const ch = await api('GET', '/v1/captcha/slider');
step('f2. 滑块挑战签发且不下发缺口坐标', ch.json?.code === 0 && !!ch.json?.data?.captcha_id && ch.json?.data?.target_x === undefined,
  `captcha_id=${ch.json?.data?.captcha_id}`);
const wrongX = await api('POST', '/v1/captcha/verify', { body: { captcha_id: ch.json?.data?.captcha_id, x: 999 } });
step('f3. 错误滑块位置被拒且挑战一次性作废', wrongX.json?.code === 40001, brief(wrongX));

const solved = await solveCaptcha();
step('f4. 滑块验证通过签发 captcha_token', !!solved.token, solved.error ?? 'token issued');
const sms3 = await api('POST', '/v1/auth/sms/send', { body: { phone: fPhone, captcha_token: solved.token } });
step('f5. 携带 captcha_token 重试短信成功（窗口已重置）', sms3.json?.code === 0 && !!sms3.json?.data?.sms_code, brief(sms3));

// f2: 精确找人频控（search_exact:{uid}:hour，20 次/时）
const fUser = await registerUser('频控甲', '频甲');
let lastSearch = null;
for (let i = 0; i < 21; i++) {
  lastSearch = await api('GET', '/v1/discover/search-user?dimi_no=DM10000001', { token: fUser.token });
  if (lastSearch.json?.code !== 0) break;
}
step('f6. 精确找人第 21 次触发 42901 need_captcha',
  lastSearch.json?.code === 42901 && lastSearch.json?.data?.need_captcha === true, brief(lastSearch));
const solved2 = await solveCaptcha();
const retrySearch = await api('GET', '/v1/discover/search-user?dimi_no=DM10000001', {
  token: fUser.token, headers: { 'X-Captcha-Token': solved2.token },
});
step('f7. 验证通过后重试检索成功', !!solved2.token && retrySearch.json?.code === 0 && retrySearch.json?.data?.items?.length === 1,
  brief(retrySearch));

// ============================================================
console.log(`\n===== 场景验证结果：${passed} PASS / ${failed} FAIL =====`);
if (failures.length) {
  for (const f of failures) console.log(`FAIL 明细：${f.name} → ${f.extra}`);
  process.exitCode = 1;
}

} finally {
  owned?.close();
}
