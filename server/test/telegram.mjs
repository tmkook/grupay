import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {once} from 'node:events';

export async function verifyTelegram(mf, db, orderNo) {
  let sequence = 0;
  const endpoint = 'https://local/api/telegram/webhook';
  function send(text, {admin = 111, secret = 'test-webhook-secret', type = 'private', update = ++sequence} = {}) {
    return mf.dispatchFetch(endpoint, {method: 'POST', headers: {'X-Telegram-Bot-Api-Secret-Token':secret},
      body: JSON.stringify({update_id:update, message:{chat:{id:admin,type},from:{id:admin,is_bot:false},text}})});
  }
  async function command(text, options) {
    const response = await send(text, options);
    assert.equal(response.status, 200);
    return (await response.json()).text;
  }
  assert.equal((await mf.dispatchFetch(endpoint)).status, 405);
  assert.equal((await send('/accounts', {secret:'wrong'})).status, 403);
  assert.equal((await send('/accounts', {type:'group'})).status, 204);
  assert.match(await command('/id', {admin:333}), /333/);
  assert.match(await command('/balance 1 10', {admin:333}), /没有管理权限/);
  assert.match(await command('/start'), /没有管理权限/);
  await db.prepare("INSERT INTO telegram_admins(telegram_id) VALUES (?)").bind(111).run();
  async function issue() {
    return db.prepare("INSERT INTO telegram_admins(bind_key) VALUES ('GP-' || lower(hex(randomblob(24)))) RETURNING id,bind_key").first();
  }
  const pending = await issue();
  assert.equal((await send(pending.bind_key, {admin:444, type:'group'})).status, 204);
  assert.match(await command(pending.bind_key), /已是管理员/);
  const contenders = [444, 555];
  const claims = await Promise.all(contenders.map(admin => command(pending.bind_key, {admin})));
  assert.equal(claims.filter(reply => reply.includes('绑定成功')).length, 1);
  const winner = contenders[claims.findIndex(reply => reply.includes('绑定成功'))];
  assert.deepEqual(await db.prepare("SELECT telegram_id,bind_key FROM telegram_admins WHERE id=?").bind(pending.id).first(),
    {telegram_id:winner,bind_key:null});
  assert.match(await command('/start', {admin:winner}), /选择管理项目/);
  assert.match(await command(pending.bind_key, {admin:666}), /无效或已使用/);
  const spare = await issue();
  assert.match(await command(spare.bind_key, {admin:winner}), /已是管理员/);
  assert.match(await command('/bind ' + spare.bind_key, {admin:777}), /绑定成功/);
  await db.prepare("UPDATE telegram_admins SET bind_key='existing-key' WHERE id=?").bind(spare.id).run();
  assert.match(await command('existing-key', {admin:888}), /无效或已使用/);
  assert.equal(await db.prepare("SELECT telegram_id FROM telegram_admins WHERE id=?").bind(spare.id).first('telegram_id'), 777);
  assert.match(await command('/start'), /选择管理项目/);
  assert.match(await command('设备管理'), /device_set/);
  assert.match(await command('/merchant_add'), /商户名称/);
  const createUpdate = ++sequence;
  const created = await command('/merchant_add 测试商户', {update:createUpdate});
  assert.match(created, /成功 · AppID [0-9a-f]{32}$/);
  assert.match(await command('/merchant_add 测试商户', {update:createUpdate}), /已处理/);
  assert.equal(await db.prepare("SELECT count(*) FROM merchants WHERE name='测试商户'").first('count(*)'), 1);
  const secondMerchant = await command('/merchant_add 测试 商户二');
  assert.match(secondMerchant, /成功 · AppID [0-9a-f]{32}$/);
  assert.notEqual(created, secondMerchant);
  const merchant = await db.prepare("SELECT id, appkey FROM merchants WHERE appid=? AND name='测试商户'").bind(created.split(' ').at(-1)).first();
  assert.equal(await db.prepare("SELECT name FROM merchants WHERE appid=?").bind(secondMerchant.split(' ').at(-1)).first('name'), '测试 商户二');
  assert.equal(merchant.appkey.length, 64);
  assert.ok(!(await command('/merchants')).includes(merchant.appkey));
  assert.ok((await command('/merchant_key ' + merchant.id)).includes(merchant.appkey));
  assert.match(await command('/merchant_status ' + merchant.id + ' 0'), /成功/);
  assert.match(await command('/merchant ' + merchant.id), /启用 0/);
  assert.match(await command('/account_add tg_user initial-pass'), /成功/);
  const user = await db.prepare("SELECT id,password FROM users WHERE username='tg_user'").first();
  assert.equal(user.password, createHash('md5').update('initial-pass').digest('hex'));
  assert.match(await command('账号管理'), /account_reset/);
  const reset = '/account_reset ' + user.id + ' ';
  assert.match(await command(reset + 'unauthorized', {admin:333}), /没有管理权限/);
  assert.match(await command(reset + 'short'), /6 至 128/);
  assert.match(await command('/account_reset 999999 changed-pass'), /未找到账号/);
  assert.equal(await db.prepare("SELECT password FROM users WHERE id=?").bind(user.id).first('password'), user.password);
  const firstReset = ++sequence;
  assert.match(await command(reset + 'first-reset', {update:firstReset}), /密码已重置/);
  assert.match(await command(reset + 'final-reset'), /密码已重置/);
  assert.match(await command(reset + 'first-reset', {update:firstReset}), /已处理/);
  const receipt = await db.prepare("SELECT target FROM telegram_admin_updates WHERE update_id=?").bind(firstReset).first('target');
  assert.equal(receipt, `账号 ${user.id} 密码已重置`);
  async function login(password) {
    const url = new URL('/ws', await mf.ready);
    url.protocol = 'ws:';
    const socket = new WebSocket(url);
    const options = {signal:AbortSignal.timeout(5000)};
    try {
      await once(socket, 'open', options);
      const reply = once(socket, 'message', options);
      const md5 = input => createHash('md5').update(input).digest('hex');
      socket.send(JSON.stringify({id:'login', type:'auth', data:{username:'tg_user',
        auth_digest:md5('tg_user' + md5(password)), serial:'reset-test', model:'test', version:'1.0.0'}}));
      return JSON.parse((await reply)[0].data).type;
    } finally {
      socket.close();
    }
  }
  assert.equal(await login('initial-pass'), 'auth.error');
  assert.equal(await login('final-reset'), 'auth.ok');
  const add = '/balance ' + user.id + ' 50';
  const update = ++sequence;
  const replies = await Promise.all([command(add,{update}), command(add,{update})]);
  assert.equal(replies.filter(r => r.includes('成功')).length, 1);
  assert.match(await command('/balance ' + user.id + ' -51'), /可用余额不足/);
  assert.match(await command('/account ' + user.id), /余额 50/);
  assert.match(await command('/account_status ' + user.id + ' 0'), /成功/);
  assert.match(await command('/account ' + user.id), /启用 0/);
  const id = await db.prepare("SELECT max(id) FROM devices").first('max(id)');
  assert.match(await command('/device_set ' + id + ' 8 200'), /成功/);
  assert.match(await command('/device ' + id), /权重 8 · 日限额 200/);
  assert.match(await command('/device_set ' + id + ' -1 20'), /非负|日限额/);
  assert.match(await command('/order ' + orderNo), /平台单号/);
  assert.match(await command('/orders'), /下一页/);
  assert.match(await command('/notify_retry 999999'), /没有可重试/);
  const job = await db.prepare("SELECT order_id FROM notification_jobs LIMIT 1").first('order_id');
  await db.prepare("UPDATE notification_jobs SET status='failed' WHERE order_id=?").bind(job).run();
  assert.match(await command('/notify_retry ' + job), /成功/);
  assert.match(await command('/notify_retry ' + job), /没有可重试/);
  await db.prepare("DELETE FROM telegram_admins WHERE telegram_id=?").bind(111).run();
  assert.match(await command('/merchant_key ' + merchant.id), /没有管理权限/);
  assert.match(await command('/balance ' + user.id + ' 5'), /没有管理权限/);
  assert.equal(await db.prepare("SELECT balance FROM users WHERE id=?").bind(user.id).first('balance'), 50);
  assert.match(await command('/id'), /111/);
  console.log('PASS: Telegram webhook validation, private admin access, four management menus and replay-safe adjustments');
}
