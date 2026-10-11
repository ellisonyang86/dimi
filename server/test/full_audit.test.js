import { test } from 'node:test';
import assert from 'node:assert/strict';
import { startTestServer, api, registerUser, befriend, addDemoClassEducation } from './helpers.js';
import { q1, run } from '../src/repo.js';
import { now } from '../src/util.js';

async function fixture(t, count = 2) {
  const app = await startTestServer();
  t.after(app.close);
  const users = [];
  for (let i=0; i<count; i++) users.push(await registerUser(app.base, {
    phone: `1398800000${i}`, nickname: `审查用户${i}`,
  }));
  return { ...app, users };
}

test('已读只能到当前消息；删除只清除本人历史，新消息恢复且不能翻回旧记录', async (t) => {
  const { base, users: [a,b] } = await fixture(t);
  const conv = await befriend(base,a,b);
  const messages = (user, query='') => api(base,'GET',`/v1/conversations/${conv}/messages${query}`,{token:user.token});
  assert.equal((await api(base,'POST',`/v1/conversations/${conv}/read`,{token:a.token})).json.code,0);
  const sent = await api(base,'POST',`/v1/conversations/${conv}/messages`,{token:b.token,body:{client_msg_id:'next',content:'新的消息'}});
  let list = await api(base,'GET','/v1/conversations',{token:a.token});
  assert.equal(list.json.data.items[0].unread_count,1);
  const oldId = sent.json.data.msg_id;
  assert.equal((await api(base,'DELETE',`/v1/conversations/${conv}`,{token:a.token})).json.code,0);
  assert.equal((await messages(a)).json.data.items.length,0);
  assert.equal((await messages(a,'?since_msg_id=0')).json.data.items.length,0);
  assert.ok((await messages(b)).json.data.items.some(m=>m.msg_id===oldId));
  assert.equal((await api(base,'GET','/v1/conversations',{token:a.token})).json.data.items.length,0);
  await api(base,'POST',`/v1/conversations/${conv}/messages`,{token:b.token,body:{client_msg_id:'after-delete',content:'重新联系'}});
  list = await api(base,'GET','/v1/conversations',{token:a.token});
  assert.equal(list.json.data.items.length,1);
  assert.equal(list.json.data.items[0].unread_count,1);
  assert.equal((await messages(a)).json.data.items.length,1);
  assert.equal((await messages(a,`?cursor=${oldId+1}`)).json.data.items.length,0);
});

test('置顶实际改变排序，幂等键按具体会话隔离；系统消息不能撤回', async (t) => {
  const { base, users: [a,b,c] } = await fixture(t,3);
  const first = await befriend(base,a,b);
  const second = await befriend(base,a,c);
  await api(base,'PUT',`/v1/conversations/${first}/settings`,{token:a.token,body:{is_pinned:true}});
  const list = await api(base,'GET','/v1/conversations',{token:a.token});
  assert.equal(list.json.data.items[0].conv_id, first);
  const options={token:a.token,headers:{'Idempotency-Key':'same-across-resources'},body:{client_msg_id:'idem',content:'问候'}};
  const one=await api(base,'POST',`/v1/conversations/${first}/messages`,options);
  const two=await api(base,'POST',`/v1/conversations/${second}/messages`,options);
  assert.notEqual(one.json.data.msg_id,two.json.data.msg_id);
  const msgs=await api(base,'GET',`/v1/conversations/${first}/messages`,{token:b.token});
  const system=msgs.json.data.items.find(m=>m.msg_type==='system');
  assert.equal((await api(base,'POST',`/v1/messages/${system.msg_id}/recall`,{token:b.token})).json.code,40001);
});

test('高隐私组不能通过降级或移出绕过密码，改密码撤销旧解锁凭证', async (t) => {
  const {base,users:[a,b]}=await fixture(t);
  await befriend(base,a,b);
  await api(base,'PUT','/v1/privacy/password',{token:a.token,body:{password:'secret-one'}});
  const created=await api(base,'POST','/v1/contact-groups',{token:a.token,body:{name:'私密',privacy_level:'high'}});
  const group=created.json.data.group_id;
  await api(base,'PUT',`/v1/friends/${b.userId}/group`,{token:a.token,body:{group_id:group}});
  assert.equal((await api(base,'PUT',`/v1/contact-groups/${group}`,{token:a.token,body:{privacy_level:'normal'}})).json.code,40301);
  assert.equal((await api(base,'PUT',`/v1/friends/${b.userId}/group`,{token:a.token,body:{group_id:null}})).json.code,40301);
  const unlocked=await api(base,'POST','/v1/privacy/groups/unlock',{token:a.token,body:{password:'secret-one'}});
  const headers={'X-Group-Unlock':unlocked.json.data.unlock_token};
  await api(base,'PUT','/v1/privacy/password',{token:a.token,body:{password:'secret-two',old_password:'secret-one'}});
  assert.equal((await api(base,'PUT',`/v1/contact-groups/${group}`,{token:a.token,headers,body:{privacy_level:'normal'}})).json.code,40301);
});

test('过期申请可重新发送；拉黑后不能通过历史申请建立好友关系', async(t)=>{
  const {base,db,users:[a,b]}=await fixture(t);
  const body={to_user_id:b.userId,verify_msg:'老同学你好'};
  const first=await api(base,'POST','/v1/friends/requests',{token:a.token,body});
  run(db,"UPDATE friend_requests SET expire_at='2000-01-01T00:00:00.000Z' WHERE id=?",first.json.data.request_id);
  const second=await api(base,'POST','/v1/friends/requests',{token:a.token,body});
  assert.notEqual(second.json.data.request_id,first.json.data.request_id);
  await api(base,'POST',`/v1/friends/${a.userId}/block`,{token:b.token});
  const accept=await api(base,'POST',`/v1/friends/requests/${second.json.data.request_id}/accept`,{token:b.token});
  assert.equal(accept.json.code,40301);
  assert.equal(q1(db,'SELECT COUNT(*) c FROM friendships WHERE user_id=? AND friend_id=?',a.userId,b.userId).c,0);
});

test('家乡内容详情与点赞一致执行 friends/private 和拉黑门禁',async(t)=>{
  const {base,users:[a,b]}=await fixture(t);
  await api(base,'PUT','/v1/users/me/hometown',{token:a.token,body:{type:1,region_code:'411623102'}});
  const content=await api(base,'POST','/v1/hometown-contents',{token:a.token,body:{region_code:'411623102',category:'story',title:'老街记忆',body:'放学路上的小桥'}});
  const id=content.json.data.content_id;
  const like=()=>api(base,'POST',`/v1/hometown-contents/${id}/like`,{token:b.token});
  await api(base,'PUT','/v1/privacy/settings',{token:a.token,body:{hometown_visibility:'friends'}});
  assert.equal((await like()).json.code,41001);
  assert.equal((await api(base,'GET',`/v1/hometown-contents/${id}`,{token:b.token})).json.code,41001);
  await befriend(base,a,b);
  assert.equal((await like()).json.code,0);
  await api(base,'PUT','/v1/privacy/settings',{token:a.token,body:{hometown_visibility:'private'}});
  assert.equal((await like()).json.code,41001);
  await api(base,'PUT','/v1/privacy/settings',{token:a.token,body:{hometown_visibility:'public'}});
  await api(base,'POST',`/v1/friends/${b.userId}/block`,{token:a.token});
  assert.equal((await like()).json.code,41001);
});

test('200 条不可见动态不能挡住更早的好友动态；注销作者详情不可见',async(t)=>{
  const {base,db,users:[a,b,c]}=await fixture(t,3);
  await befriend(base,a,b);
  const moment=await api(base,'POST','/v1/moments',{token:b.token,body:{content:'老友近况',content_type:'text',visibility:'public'}});
  const id=moment.json.data.moment_id;
  const insert=db.prepare("INSERT INTO moments(author_id,content_type,content,visibility,created_at) VALUES(?,'text','陌生动态','private',?)");
  for(let i=0;i<205;i++) insert.run(c.userId,now());
  const feed=await api(base,'GET','/v1/moments/feed',{token:a.token});
  assert.ok(feed.json.data.items.some(m=>m.moment_id===id));
  run(db,'UPDATE users SET status=9 WHERE id=?',b.userId);
  assert.equal((await api(base,'GET',`/v1/moments/${id}`,{token:a.token})).json.code,40301);
});

test('重复保存真名不重置年度限制；注册不可省略出生年份',async(t)=>{
  const {base,db,users:[a]}=await fixture(t,1);
  await api(base,'PUT','/v1/users/me',{token:a.token,body:{real_name:'王同学'}});
  run(db,"UPDATE users SET real_name_changed_at='2020-01-01T00:00:00.000Z' WHERE id=?",a.userId);
  assert.equal((await api(base,'PUT','/v1/users/me',{token:a.token,body:{real_name:'王同学'}})).json.code,0);
  assert.equal(q1(db,'SELECT real_name_changed_at FROM users WHERE id=?',a.userId).real_name_changed_at,'2020-01-01T00:00:00.000Z');
  assert.equal((await api(base,'PUT','/v1/users/me',{token:a.token,body:{real_name:'王小明'}})).json.code,0);
  const reg=await api(base,'POST','/v1/auth/register',{body:{phone:'13988000009',nickname:'未填年龄',sms_code:'123456'}});
  assert.equal(reg.json.code,40001);
  assert.match(reg.json.message,/出生年份/);
});


test('家乡投稿仅作者可删除，举报可入库，删除后列表详情点赞与公开页均不可见', async(t)=>{
  const {base,db,users:[a,b]}=await fixture(t);
  await api(base,'PUT','/v1/users/me/hometown',{token:a.token,body:{type:1,region_code:'411623102'}});
  await api(base,'PUT','/v1/privacy/settings',{token:a.token,body:{hometown_visibility:'public'}});
  const created=await api(base,'POST','/v1/hometown-contents',{token:a.token,body:{region_code:'411623102',category:'story',title:'家乡故事'}});
  assert.equal(created.json.code,0);
  const id=created.json.data.content_id;
  const report=await api(base,'POST','/v1/misc/report',{token:b.token,body:{target_type:'hometown_content',target_id:id,reason:'other'}});
  assert.equal(report.json.code,0);
  assert.equal(q1(db,'SELECT target_type FROM reports WHERE id=?',report.json.data.report_id).target_type,'hometown_content');
  assert.equal((await api(base,'DELETE',`/v1/hometown-contents/${id}`,{token:b.token})).json.code,40301);
  assert.equal((await api(base,'DELETE',`/v1/hometown-contents/${id}`,{token:a.token})).json.code,0);
  for (const user of [a,b]) {
    assert.equal((await api(base,'GET',`/v1/hometown-contents/${id}`,{token:user.token})).json.code,41001);
    assert.equal((await api(base,'POST',`/v1/hometown-contents/${id}/like`,{token:user.token})).json.code,41001);
    assert.equal((await api(base,'GET','/v1/hometown-pages/411623102/contents',{token:user.token})).json.data.items.length,0);
  }
  assert.equal((await api(base,'GET','/v1/public/hometown-pages/411623102')).json.data.items.length,0);
});

test('不可见投稿不挤占分页或公开页；外地页入群不能跳到自己的群',async(t)=>{
  const {base,db,users:[a,b,c]}=await fixture(t,3);
  for (const u of [a,b,c]) await api(base,'PUT','/v1/users/me/hometown',{token:u.token,body:{type:1,region_code:'411623102'}});
  await api(base,'PUT','/v1/privacy/settings',{token:b.token,body:{hometown_visibility:'public'}});
  await api(base,'PUT','/v1/privacy/settings',{token:c.token,body:{hometown_visibility:'private'}});
  const insert=db.prepare("INSERT INTO hometown_contents(region_code,author_id,category,title,status,created_at,updated_at) VALUES('411623102',?,'story','旧时光','published',?,?)");
  for(let i=0;i<23;i++) insert.run(b.userId,now(),now());
  for(let i=0;i<30;i++) insert.run(c.userId,now(),now());
  const page1=(await api(base,'GET','/v1/hometown-pages/411623102/contents',{token:a.token})).json.data;
  assert.equal(page1.items.length,20);
  assert.ok(page1.next_cursor);
  const page2=(await api(base,'GET',`/v1/hometown-pages/411623102/contents?cursor=${page1.next_cursor}`,{token:a.token})).json.data;
  assert.equal(page2.items.length,3);
  assert.equal(page2.next_cursor,null);
  assert.equal((await api(base,'GET','/v1/public/hometown-pages/411623102')).json.data.items.length,10);
  assert.equal((await api(base,'POST','/v1/hometown-groups/join',{token:a.token,body:{region_code:'330106005'}})).json.code,40301);
  assert.equal(q1(db,'SELECT COUNT(*) c FROM hometown_groups').c,0);
});

test('删除班级经历和跨市修改家乡会退出原群，并将群主交给仍在群内的成员',async(t)=>{
  const {base,db,users:[a,b]}=await fixture(t);
  for (const u of [a,b]) await addDemoClassEducation(base,u.token);
  const join=token=>api(base,'POST','/v1/class-groups/join',{token,body:{school_id:1001,enroll_year:1996,class_name:'六年2班'}});
  const conv=(await join(a.token)).json.data.conv_id;
  await join(b.token);
  const edu=q1(db,'SELECT id FROM education_experiences WHERE user_id=?',a.userId);
  assert.equal((await api(base,'DELETE',`/v1/users/me/educations/${edu.id}`,{token:a.token})).json.code,0);
  assert.equal(q1(db,'SELECT COUNT(*) c FROM conversation_members WHERE conv_id=? AND user_id=?',conv,a.userId).c,0);
  assert.equal(q1(db,'SELECT created_by FROM class_groups WHERE conv_id=?',conv).created_by,b.userId);
  const home=token=>api(base,'PUT','/v1/users/me/hometown',{token,body:{type:1,region_code:'411623102'}});
  await home(a.token); await home(b.token);
  const homeConv=(await api(base,'POST','/v1/hometown-groups/join',{token:a.token})).json.data.conv_id;
  await api(base,'POST','/v1/hometown-groups/join',{token:b.token});
  await api(base,'PUT','/v1/users/me/hometown',{token:a.token,body:{type:1,region_code:'330106005'}});
  assert.equal(q1(db,'SELECT COUNT(*) c FROM conversation_members WHERE conv_id=? AND user_id=?',homeConv,a.userId).c,0);
  assert.equal(q1(db,'SELECT created_by FROM hometown_groups WHERE conv_id=?',homeConv).created_by,b.userId);
});
