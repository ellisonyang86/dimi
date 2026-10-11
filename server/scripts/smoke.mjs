// 冒烟脚本：注册 → 填经历 → 锚点检索 → 渐显资料卡 → 发申请（含 45001 拦截）→ 通过 → 发消息
const base = process.env.SMOKE_BASE || 'http://127.0.0.1:8080';

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
  return { status: res.status, json: await res.json() };
}

const phone = '137' + String(Math.floor(Math.random() * 1e8)).padStart(8, '0');
const step = (name, ok, extra = '') => console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${extra ? '  → ' + extra : ''}`);

// 1. 注册
const sms = await api('POST', '/v1/auth/sms/send', { body: { phone } });
step('sms/send dev 返回验证码', sms.json.code === 0 && !!sms.json.data.sms_code, sms.json.data.sms_code);
const reg = await api('POST', '/v1/auth/register', {
  body: { phone, sms_code: sms.json.data.sms_code, nickname: '冒烟用户', gender: 1, birth_year: 1988 },
});
step('register', reg.json.code === 0, reg.json.data?.user?.dimi_no);
const token = reg.json.data.access_token;
const myId = reg.json.data.user.user_id;
await api('PUT', '/v1/users/me', { token, body: { real_name: '钱进' } });

// 2. 填同班经历
const edu = await api('POST', '/v1/users/me/educations', {
  token, body: { stage: 'PRIMARY', school_id: 1001, enroll_year: 1996, class_name: '六年2班' },
});
step('add education', edu.json.code === 0, `registered_count=${edu.json.data?.registered_count}`);
await api('PUT', '/v1/users/me/hometown', { token, body: { type: 1, region_code: '411623102' } });

// 3. 锚点检索（找李娟）
const search = await api('GET', '/v1/discover/search-user?school_id=1001&enroll_year=1996&name=李娟', { token });
const lijuan = search.json.data?.items?.find((i) => (i.real_name || '').startsWith('李'));
step('anchor search', search.json.code === 0 && !!lijuan, JSON.stringify(lijuan?.real_name) + ' tier=' + lijuan?.intersection_tier);

// 4. 渐显资料卡（rules.json name_matrix：balanced 模式 T3 同班显示全名，T2 掩码名）
const card = await api('GET', `/v1/users/${lijuan.user_id}`, { token });
step('profile 渐显（T3 同班显全名）', card.json.code === 0 && card.json.data.real_name === '李娟', `${card.json.data?.real_name} | ${card.json.data?.intersection_banner}`);

// 5. 申请：先拦一个带联系方式的，再发正常的
const bad = await api('POST', '/v1/friends/requests', { token, body: { to_user_id: lijuan.user_id, verify_msg: '我微信 wxid_smoke1' } });
step('45001 content block', bad.json.code === 45001);
const req = await api('POST', '/v1/friends/requests', { token, body: { to_user_id: lijuan.user_id, verify_msg: '我是96届六年2班的钱进' } });
step('friend request', req.json.code === 0, 'request_id=' + req.json.data?.request_id);

// 6. 李娟登录并通过（频控阶梯兜底：60s 窗口 → 日上限则用密码登录，种子用户密码 demo1234）
let sms2 = await api('POST', '/v1/auth/sms/send', { body: { phone: '13800000001' } });
if (sms2.json.code === 42901) {
  console.log('… 同号 60s 频控生效（符合预期），等待窗口后重试');
  await new Promise((r) => setTimeout(r, 61_000));
  sms2 = await api('POST', '/v1/auth/sms/send', { body: { phone: '13800000001' } });
}
let login;
if (sms2.json.code === 0) {
  login = await api('POST', '/v1/auth/login', { body: { grant_type: 'sms', phone: '13800000001', sms_code: sms2.json.data.sms_code } });
} else {
  // 日发送上限（10 条/日）触顶：改走密码通道，保证冒烟可重复运行
  console.log('… 短信日上限触顶（符合预期），改用密码登录演示账号');
  login = await api('POST', '/v1/auth/login', { body: { grant_type: 'password', phone: '13800000001', password: 'demo1234' } });
}
step('demo login (李娟)', login.json.code === 0);
const tkL = login.json.data.access_token;
const inbox = await api('GET', '/v1/friends/requests?box=inbox', { token: tkL });
const item = inbox.json.data.items.find((i) => i.from_user_id === myId && i.status === 'pending');
const acc = await api('POST', `/v1/friends/requests/${item.id}/accept`, { token: tkL });
step('accept', acc.json.code === 0, 'conv=' + acc.json.data?.conversation_id);

// 7. 发消息
const msg = await api('POST', `/v1/conversations/${acc.json.data.conversation_id}/messages`, {
  token, body: { client_msg_id: 'smoke-1', msg_type: 'text', content: '李娟，是我，钱进！' },
});
step('send message', msg.json.code === 0, 'msg_id=' + msg.json.data?.msg_id);

// 8. 召集令公开页 + 密度看板
const invite = await api('GET', '/v1/public/invites/CG2X96');
step('public invite', invite.json.code === 0, `${invite.json.data?.unit_name} ${invite.json.data?.lit}/${invite.json.data?.target}`);
const admin = await api('GET', '/admin-api/density/units?level=class', { headers: { 'X-Admin-Token': process.env.ADMIN_TOKEN || 'dev-admin-token' } });
if (admin.json?.code === 41001) {
  // dev 服务未设 ADMIN_TOKEN 时 /admin-api/* 整体禁用（app.js 启动告警），属环境原因，跳过
  step('admin density', true, 'SKIP（dev 未配置 ADMIN_TOKEN，admin-api 已禁用）');
} else {
  const cls = admin.json.data?.items?.find((i) => i.school_id === 1001 && i.class_norm === '6-2');
  step('admin density', admin.json.code === 0, `registered=${cls?.registered} target=${cls?.target} retention=${cls?.retention_7d}`);
}

console.log('smoke done');
