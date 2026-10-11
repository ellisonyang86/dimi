import { test } from 'node:test';
import assert from 'node:assert/strict';
import { startTestServer, api, registerUser, befriend, addDemoClassEducation } from './helpers.js';
import { run } from '../src/repo.js';
import { now } from '../src/util.js';

test('推荐排除好友、待处理申请和不感兴趣；关闭开关停止推荐且主动检索仍可用', async t => {
  const app = await startTestServer(); t.after(app.close);
  const {base} = app;
  const users=[];
  for(let i=0;i<4;i++) {
    const u=await registerUser(base,{phone:`1376600000${i}`,nickname:`深检${i}`});
    await addDemoClassEducation(base,u.token); users.push(u);
  }
  const [a,b,c,d]=users;
  await befriend(base,a,b);
  await api(base,'POST','/v1/friends/requests',{token:a.token,body:{to_user_id:c.userId,verify_msg:'同学你好'}});
  const rec=()=>api(base,'GET','/v1/discover/recommendations?scene=classmate',{token:a.token});
  let result=await rec(); assert.equal(result.json.code,0);
  let ids=result.json.data.items.map(u=>u.user_id);
  assert.ok(!ids.includes(b.userId)); assert.ok(!ids.includes(c.userId)); assert.ok(ids.includes(d.userId));
  await api(base,'POST','/v1/discover/feedback',{token:a.token,body:{target_user_id:d.userId,action:'not_interested'}});
  assert.ok(!(await rec()).json.data.items.some(u=>u.user_id===d.userId));
  await api(base,'PUT','/v1/privacy/settings',{token:a.token,body:{personalized_recommend:false}});
  assert.deepEqual((await rec()).json.data.items,[]);
  const search=await api(base,'GET','/v1/discover/classmates?school_id=1001&enroll_year=1996',{token:a.token});
  assert.equal(search.json.code,0); assert.ok(search.json.data.items.length>0);
  assert.equal((await api(base,'PUT','/v1/privacy/settings',{token:a.token,body:{personalized_recommend:'false'}})).json.code,40001);
  assert.equal((await api(base,'PUT','/v1/privacy/settings',{token:a.token,body:{add_me_via:{school_search:'false'}}})).json.code,40001);
});

test('学校、老乡及推荐分页在大量隐藏候选后仍完整连续；拒绝非法页码',async t=>{
  const app=await startTestServer(); t.after(app.close);
  const {base,db}=app;
  const a=await registerUser(base,{phone:'13766000009',nickname:'检索者'});
  run(db,"INSERT INTO schools(school_id,name,stage,status,region_code) VALUES(9001,'深检学校','PRIMARY','active','411623102')");
  const edu=uid=>run(db,"INSERT INTO education_experiences(user_id,stage,school_id,school_name_snapshot,enroll_year,class_name_raw,class_name_norm,visibility,created_at) VALUES(?,'PRIMARY',9001,'深检学校',2000,'六年1班','6-1','public',?)",uid,now());
  edu(a.userId);
  await api(base,'PUT','/v1/users/me/hometown',{token:a.token,body:{type:1,region_code:'411623102'}});
  const visible=[];
  for(let i=0;i<35;i++) {
    const id=Number(run(db,"INSERT INTO users(dimi_no,phone,nickname,status,created_at,updated_at) VALUES(?,?,?,1,?,?)",`DM9000${i}`,`1376610${String(i).padStart(4,'0')}`,`深检候选${i}`,now(),now()).lastInsertRowid);
    edu(id);
    run(db,"INSERT INTO user_hometowns(user_id,type,region_code,visibility) VALUES(?,1,'411623102','public')",id);
    run(db,'INSERT INTO privacy_settings(user_id,add_me_via) VALUES(?,?)',id,JSON.stringify({school_search:i>=30,hometown_search:i>=30}));
    if(i>=30) visible.push(id);
  }
  for(const path of ['/v1/discover/classmates?school_id=9001&enroll_year=2000','/v1/discover/fellows?region_code=411623102&level=4&name='+encodeURIComponent('深检候选'),'/v1/discover/recommendations?scene=classmate']) {
    const all=[];
    for(let page=1;page<=3;page++) {
      const r=await api(base,'GET',`${path}&size=2&page=${page}`,{token:a.token});
      assert.equal(r.json.code,0,JSON.stringify(r.json));
      all.push(...r.json.data.items.map(u=>u.user_id));
      assert.equal(r.json.data.next_cursor,page<3?String(page+1):null);
    }
    assert.deepEqual(all,visible);
  }
  for(const value of ['-1','1.5','oops']) {
    const r=await api(base,'GET',`/v1/discover/classmates?school_id=9001&enroll_year=2000&page=${value}`,{token:a.token});
    assert.equal(r.json.code,40001);
  }
});


test('并发重试消息与红包领取：只生成一条消息、只入账一次、余额守恒',async t=>{
  const {base,db,close}=await startTestServer();t.after(close);
  const a=await registerUser(base,{phone:'13766900001',nickname:'并发甲'});
  const b=await registerUser(base,{phone:'13766900002',nickname:'并发乙'});
  const conv=await befriend(base,a,b);
  const sends=await Promise.all(Array.from({length:12},()=>api(base,'POST',`/v1/conversations/${conv}/messages`,{
    token:a.token,body:{client_msg_id:'same-message-retry',content:'网络恢复后的问候'},
  })));
  assert.ok(sends.every(r=>r.json.code===0));
  assert.equal(new Set(sends.map(r=>r.json.data.msg_id)).size,1);
  const balance=async user=>(await api(base,'GET','/v1/wallet',{token:user.token})).json.data.balance;
  const beforeA=await balance(a),beforeB=await balance(b);
  const send=await api(base,'POST','/v1/red-packets',{token:a.token,body:{conv_id:conv,type:'normal',total_amount:10,count:1}});
  assert.equal(send.json.code,0);
  const packet=send.json.data.packet_id;
  const claims=await Promise.all(Array.from({length:12},()=>api(base,'POST',`/v1/red-packets/${packet}/claim`,{token:b.token,headers:{'Idempotency-Key':'same-claim-retry'}})));
  assert.ok(claims.every(r=>r.json.code===0),JSON.stringify(claims.map(r=>r.json)));
  const repeated=await api(base,'POST',`/v1/red-packets/${packet}/claim`,{token:b.token});
  assert.equal(repeated.json.code,40001);
  assert.equal(await balance(a),beforeA-10);
  assert.equal(await balance(b),beforeB+10);
  assert.equal(db.prepare('SELECT COUNT(*) c FROM red_packet_claims WHERE packet_id=?').get(packet).c,1);
});


test('从经历进入找同学：原始班名与标准班名得到同一批结果', async t => {
  const app = await startTestServer(); t.after(app.close);
  const a = await registerUser(app.base, {phone:'13988503001',nickname:'班级查找'});
  await api(app.base, 'POST', '/v1/users/me/educations', {token:a.token,body:{stage:'PRIMARY',school_id:1001,enroll_year:1996,class_name:'六年2班'}});
  let expected;
  for (const value of ['6-2','六年2班','六年级二班','6（2）']) {
    const r = await api(app.base, 'GET', '/v1/discover/classmates?school_id=1001&enroll_year=1996&class_norm='+encodeURIComponent(value), {token:a.token});
    assert.equal(r.status, 200);
    const ids = r.json.data.items.map(u=>u.user_id);
    assert.ok(ids.length > 0);
    if (expected) assert.deepEqual(ids, expected); else expected=ids;
  }
});
