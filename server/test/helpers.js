import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createApp } from '../src/app.js';
import { seedDatabase } from '../src/seed.js';

// WHATWG Fetch 禁用端口；Windows 的随机端口分配偶尔会命中 10080。
const FETCH_BLOCKED_PORTS = new Set([1,7,9,11,13,15,17,19,20,21,22,23,25,37,42,43,53,69,77,79,87,95,101,102,103,104,109,110,111,113,115,117,119,123,135,137,139,143,161,179,389,427,465,512,513,514,515,526,530,531,532,540,548,554,556,563,587,601,636,989,990,993,995,1719,1720,1723,2049,3659,4045,4190,5060,5061,6000,6566,6665,6666,6667,6668,6669,6697,10080]);

// 启动真实服务（ephemeral 端口 + 临时 SQLite 库），供端到端测试
export async function startTestServer({ seed = true } = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dimi-test-'));
  const dbPath = path.join(dir, 'test.db');
  const { server, db } = await createApp({
    dbPath,
    port: 0,
    adminToken: 'test-admin-token',
    smsDev: true,
  });
  if (seed) seedDatabase(db);
  do {
    await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
    if (!FETCH_BLOCKED_PORTS.has(server.address().port)) break;
    await new Promise((resolve) => server.close(resolve));
  } while (true);
  const base = `http://127.0.0.1:${server.address().port}`;
  return {
    base,
    db,
    server,
    close: () => {
      server.close();
      db.close();
      fs.rmSync(dir, { recursive: true, force: true });
    },
  };
}

export async function api(base, method, p, { token, body, headers } = {}) {
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
  try { json = await res.json(); } catch { /* 非 JSON 响应 */ }
  return { status: res.status, json, headers: res.headers };
}

// 注册并拿到 token；realName 提供时通过 PUT /users/me 设置
export async function registerUser(base, { phone, nickname, gender = 1, birth_year = 1989, real_name = null }) {
  const sms = await api(base, 'POST', '/v1/auth/sms/send', { body: { phone } });
  if (sms.json?.code !== 0) throw new Error('sms/send failed: ' + JSON.stringify(sms.json));
  const reg = await api(base, 'POST', '/v1/auth/register', {
    body: { phone, sms_code: sms.json.data.sms_code, nickname, gender, birth_year },
  });
  if (reg.json?.code !== 0) throw new Error('register failed: ' + JSON.stringify(reg.json));
  const token = reg.json.data.access_token;
  const userId = reg.json.data.user.user_id;
  if (real_name) {
    const r = await api(base, 'PUT', '/v1/users/me', { token, body: { real_name } });
    if (r.json?.code !== 0) throw new Error('set real_name failed: ' + JSON.stringify(r.json));
  }
  return { token, userId, phone };
}

// 添加 demo 班经历：城关镇第二小学 1996 级 六年2班
export async function addDemoClassEducation(base, token) {
  const r = await api(base, 'POST', '/v1/users/me/educations', {
    token,
    body: { stage: 'PRIMARY', school_id: 1001, enroll_year: 1996, class_name: '六年2班' },
  });
  if (r.json?.code !== 0) throw new Error('add education failed: ' + JSON.stringify(r.json));
  return r.json.data.education.id;
}

// A 向 B 发申请并 B 通过，返回 conversation_id
export async function befriend(base, from, to, verifyMsg = '我是96届六年2班的老同学') {
  const req = await api(base, 'POST', '/v1/friends/requests', {
    token: from.token,
    body: { to_user_id: to.userId, verify_msg: verifyMsg },
  });
  if (req.json?.code !== 0) throw new Error('friend request failed: ' + JSON.stringify(req.json));
  const inbox = await api(base, 'GET', '/v1/friends/requests?box=inbox', { token: to.token });
  const item = inbox.json.data.items.find((i) => i.from_user_id === from.userId && i.status === 'pending');
  const acc = await api(base, 'POST', `/v1/friends/requests/${item.id}/accept`, { token: to.token });
  if (acc.json?.code !== 0) throw new Error('accept failed: ' + JSON.stringify(acc.json));
  return acc.json.data.conversation_id;
}
