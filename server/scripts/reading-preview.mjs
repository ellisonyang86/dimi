// Isolated local preview data. Never opens or changes the normal dimi.db.
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createApp } from '../src/app.js';
import { seedDatabase } from '../src/seed.js';
import { creditCoins } from '../src/coins.js';

if (process.env.DIMI_ENV === 'production') throw new Error('仅用于本地界面预览');
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const { server, db } = await createApp({
  dbPath: path.join(root, 'data', 'reading-preview-20260927.db'),
  port: 18089, smsDev: true, adminToken: null,
});
seedDatabase(db);
const date = new Date().toISOString();
const body = '每次回到家乡，总想沿着老街再走一遍。清晨的风穿过树梢，熟悉的叫卖声从巷子深处传来。\n\n'
  + '## 记忆里的清晨\n\n小时候，街边的早点摊总是最先亮灯。热汤升起白雾，赶集的人提着篮子，慢慢走过青石板路。\n\n'
  + '> 故乡，是走得再远，也能认出的一盏灯。\n\n'
  + '## 把故事留给后来的人\n\n**老街变了，记忆还在。** 如果你也来过这里，不妨在下面写下自己的故事。\n\n'
  + '一处街角、一门手艺、一段往事，都值得被认真记住。我们一起把散落的记忆，慢慢拼回家乡的模样。';
if (!db.prepare("SELECT 1 FROM hometown_contents WHERE title='沿着老街，走回记忆里的家乡'").get()) {
  const town = db.prepare('SELECT region_code FROM user_hometowns WHERE user_id=2 AND type=1').get()?.region_code;
  if (town) {
    const result = db.prepare("INSERT INTO hometown_contents(region_code,author_id,category,title,body,status,created_at,updated_at) VALUES(?,2,'story',?,?,'published',?,?)")
      .run(town, '沿着老街，走回记忆里的家乡', body, date, date);
    db.prepare('INSERT INTO hometown_comments(content_id,from_user,content,created_at) VALUES(?,3,?,?)')
      .run(result.lastInsertRowid, '最怀念老街清晨的热汤，谢谢你把这些记忆写下来。', date);
  }
  db.prepare("INSERT INTO moments(author_id,content_type,content,media,visibility,created_at) VALUES(2,'article',?,'[]','classmates',?)")
    .run('# 沿着老街，走回记忆里的家乡\n\n' + body, date);
}
creditCoins(db, { userId: 1, bizType: 'preview_grant', bizId: 'reading-preview', amount: 30, remark: '本地预览体验觅豆' });
server.listen(18089, '0.0.0.0', () => console.log('Reading preview ready on :18089; isolated demo database.'));
