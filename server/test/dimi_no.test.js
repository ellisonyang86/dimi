import test from 'node:test';
import assert from 'node:assert/strict';
import { startTestServer, api, registerUser } from './helpers.js';

test('DIMI 号：格式、大小写唯一性、重试、修改周期与旧号保护', async t => {
  const app = await startTestServer(); t.after(app.close);
  const a = await registerUser(app.base, { phone:'13988501001', nickname:'改号用户' });
  const b = await registerUser(app.base, { phone:'13988501002', nickname:'查找用户' });
  const change = (user, value) => api(app.base, 'PUT', '/v1/users/me/dimi-no', { token:user.token, body:{dimi_no:value} });
  for (const value of [null, 12, 'short', '1abcde', '名字abcdef', 'dm123456', 'a'.repeat(21), 'a bcd_']) {
    assert.equal((await change(a, value)).status, 400, String(value));
  }
  const before = await api(app.base, 'GET', '/v1/users/me', {token:a.token});
  const first = await change(a, '  My_Name-1  ');
  assert.equal(first.status, 200);
  assert.equal(first.json.data.dimi_no, 'my_name-1');
  assert.equal(first.json.data.user_id, before.json.data.user_id);
  assert.ok(first.json.data.dimi_no_changed_at);
  const repeat = await change(a, 'MY_NAME-1');
  assert.equal(repeat.status, 200);
  assert.equal(repeat.json.data.dimi_no_changed_at, first.json.data.dimi_no_changed_at);
  assert.equal((await change(b, 'MY_NAME-1')).status, 400);
  assert.equal((await change(a, 'another_name')).status, 400);
  app.db.prepare('UPDATE users SET dimi_no_changed_at=? WHERE id=?').run(new Date(Date.now() - 366*86400000).toISOString(), a.userId);
  assert.equal((await change(a, 'another_name')).status, 200);
  assert.equal((await change(b, 'my_name-1')).status, 400);
  assert.equal((await change(b, 'friend_2026')).status, 200);
});

test('自定义号精确检索遵守隐私，系统号仍可搜索', async t => {
  const app = await startTestServer(); t.after(app.close);
  const a = await registerUser(app.base, { phone:'13988502001', nickname:'改号用户' });
  const b = await registerUser(app.base, { phone:'13988502002', nickname:'查找用户' });
  const find = no => api(app.base, 'GET', '/v1/discover/search-user?dimi_no='+encodeURIComponent(no), {token:b.token});
  const before = await api(app.base, 'GET', '/v1/users/me', {token:a.token});
  assert.equal((await find(before.json.data.dimi_no.toLowerCase())).json.data.items[0].user_id, a.userId);
  await api(app.base, 'PUT', '/v1/users/me/dimi-no', {token:a.token, body:{dimi_no:'hello_dimi'}});
  assert.equal((await find(' HELLO_DIMI ')).json.data.items[0].user_id, a.userId);
  assert.equal((await find(before.json.data.dimi_no)).json.data.items.length, 0);
  await api(app.base, 'PUT', '/v1/privacy/settings', {token:a.token, body:{add_me_via:{dimi_no:false}}});
  assert.equal((await find('hello_dimi')).json.data.items.length, 0);
  const cleared = await api(app.base, 'PUT', '/v1/users/me', {token:a.token, body:{birth_year:null}});
  assert.equal(cleared.status, 200);
  assert.equal((await api(app.base, 'GET', '/v1/users/me', {token:a.token})).json.data.birth_year, null);
});
