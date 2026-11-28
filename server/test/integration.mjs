import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { build } from 'esbuild';
import { Miniflare, convertV4MiniflareOptions } from 'miniflare';
import { unstable_splitSqlQuery } from 'wrangler';
import { testSignature, verify } from './dispatch.mjs';
import { verifyCashier } from "./cashier.mjs";
import { verifyTelegram } from "./telegram.mjs";
await import('./douyin.mjs');
await verifyCashier();
const bundled = await build({
  entryPoints: ['src/index.ts'],
  bundle: true,
  platform: 'browser',
  external: ['cloudflare:workers'],
  format: 'esm',
  write: false
});
let callbacks = 0;
const mf = new Miniflare(convertV4MiniflareOptions({
  name: 'grupay-test',
  modules: true,
  script: bundled.outputFiles[0].text,
  compatibilityDate: '2026-11-23',
  bindings: {TELEGRAM_WEBHOOK_SECRET: 'test-webhook-secret'},
  d1Databases: ['DB'],
  assets: {directory: 'public', binding: 'ASSETS', run_worker_first: ['/releases/*'], routerConfig: {has_user_worker: true}},
  durableObjects: {
    DEVICE_SESSIONS: {
      className: 'DeviceSessions',
      useSQLite: true
    }
  },
  outboundService: async request => {
    const fields = await request.json();
    assert.equal(fields.appid, 'demo');
    assert.ok(['paid', 'expired', 'failed'].includes(fields.status));
    assert.ok(Number.isSafeInteger(fields.timestamp) && Math.abs(Date.now() / 1000 - fields.timestamp) <= 300);
    assert.equal(fields.sign, testSignature('notify', fields));
    assert.notEqual(fields.sign, testSignature('notify', {...fields, amount: fields.amount + 1}));
    callbacks++;
    return new Response(callbacks === 1 ? 'retry' : 'ok');
  }
}));
try {
  const db = await mf.getD1Database('DB');
  const sql = await readFile('migrations/0001_init.sql', 'utf8');
  await db.batch(unstable_splitSqlQuery(sql).map(statement => db.prepare(statement)));
  assert.deepEqual(await db.prepare("SELECT code, url, script FROM products WHERE code='8888'").first(), {
    code: '8888',
    url: 'https://www.douyin.com/pay',
    script: '/scripts/douyin-v1.js'
  });
  const demoUser = await db.prepare("SELECT password,balance,status FROM users WHERE username='demo'").first();
  assert.deepEqual(demoUser, {
    password: createHash('md5').update('123456').digest('hex'),
    balance: 100000,
    status: 1
  });
  const seedMerchant = await db.prepare("SELECT name,status,length(appkey) AS key_length FROM merchants WHERE appid='smokedfc84c655a1eeed0'").first();
  assert.equal(seedMerchant.name, '部署验收');
  assert.equal(seedMerchant.status, 1);
  assert.ok(seedMerchant.key_length > 0);
  const columns = await db.prepare("PRAGMA table_info(products)").all();
  assert.ok(!columns.results.some(column => column.name === 'payment_provider'));
  const productCode = 'test-recharge';
  await db.prepare("UPDATE products SET code=? WHERE code='8888'").bind(productCode).run();
  await db.prepare("INSERT INTO products(code,name,url,script) VALUES('fixture','测试','https://product.example/','https://product.example/test.js')").run();
  await db.batch([
    db.prepare("INSERT INTO users(id,username,password,balance,created_at,updated_at) VALUES(1,'tester','62cc2d8b4bf2d8728120d052163a77df',1000,0,0)"),
    db.prepare("INSERT INTO merchants(id,appid,appkey,name,created_at,updated_at) VALUES(2,'demo','demo-key','test',0,0)")
  ]);
  assert.equal(await db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name='settings'").first(), null);
  const release = await (await mf.dispatchFetch('http://local/releases/latest.json')).json();
  const latest = await mf.dispatchFetch('http://local/release', {redirect: 'manual'});
  const path = new URL(release.url).pathname;
  assert.equal(latest.status, 302);
  assert.equal(latest.headers.get('location'), path);
  assert.equal(path, `/releases/grupay-${release.version}+${release.build}.apk`);
  for (const address of [path, path.replace('+', '%2B')]) {
    const apkResponse = await mf.dispatchFetch('http://local' + address, {redirect: 'manual'});
    assert.equal(apkResponse.status, 200);
    const apk = Buffer.from(await apkResponse.arrayBuffer());
    assert.ok(apk.length < 25 * 1024 * 1024);
    assert.equal(createHash('sha256').update(apk).digest('hex'), release.sha256);
  }
  console.log('PASS: release pointer, versioned APK and checksum');
  for (const [path, expected] of [['/docs/guide.md', '系统使用说明'], ['/docs/merchant.md', '商户对接']]) {
    const doc = await mf.dispatchFetch('http://local' + path);
    assert.equal(doc.status, 200);
    assert.ok((await doc.text()).includes(expected));
  }
  console.log('PASS: guide and merchant documents are served as static assets');
  // A cold cron wake must repair legacy deadlines and schedule unopened orders without a connected device.
  const createdAt = Date.now() - 599000;
  const legacy = await db.prepare(`INSERT INTO orders(order_no,merchant_order_no,merchant_id,amount,product_code,created_at,updated_at)
    VALUES('legacy-clock','legacy-clock',2,10,?,?,?) RETURNING id`).bind(productCode, createdAt, createdAt).first('id');
  const sessions = await mf.getDurableObjectNamespace('DEVICE_SESSIONS');
  await sessions.get(sessions.idFromName('devices')).fetch('https://internal/internal/wake');
  const state = db.prepare("SELECT deadline_at,status FROM orders WHERE id=?").bind(legacy);
  assert.equal((await state.first()).deadline_at, createdAt + 600000);
  const cutoff = Date.now() + 7000;
  while (Date.now() < cutoff && (await state.first()).status === 'created') await new Promise(resolve => setTimeout(resolve, 100));
  assert.equal((await state.first()).status, 'failed');
  await db.batch([db.prepare("DELETE FROM order_events WHERE order_id=?").bind(legacy), db.prepare("DELETE FROM orders WHERE id=?").bind(legacy)]);
  console.log('PASS: one-time legacy deadline backfill and deadline-driven alarm without WebSockets');
  await verify((await mf.ready).origin, db, productCode, () =>
    mf.unsafeEvictDurableObject('grupay-test', 'DeviceSessions', {name:'devices', webSockets:'hibernate'}));
  const deadline = Date.now() + 25000;
  while (Date.now() < deadline && (await db.prepare("SELECT status FROM notification_jobs").first('status')) !== 'delivered') await new Promise(r => setTimeout(r, 250));
  assert.equal(await db.prepare("SELECT status FROM notification_jobs").first('status'), 'delivered');
  assert.deepEqual(await db.prepare("SELECT status,attempts,last_response FROM notification_jobs").first(), {
    status: 'delivered', attempts: 2, last_response: 'HTTP 200 ok'
  });
  assert.equal(callbacks, 2);
  const ordersUrl = 'http://local/api/v1/orders';
  const order = {appid: 'demo', order_no: "联调 !'()*", amount: 1, product_code: productCode};
  function createOrder(overrides) {
    const fields = {...order, ...overrides, timestamp: Math.floor(Date.now() / 1000)};
    fields.sign = testSignature('create', fields);
    return mf.dispatchFetch(ordersUrl, {
      method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify(fields)
    });
  }
  async function postOrder(overrides, expectedStatus) {
    const response = await createOrder(overrides);
    assert.equal(response.status, expectedStatus);
    return response.json();
  }
  const concurrent = await Promise.all([createOrder({}), createOrder({})]);
  assert.deepEqual(concurrent.map(response => response.status).sort(), [200, 201]);
  const [created, duplicate] = await Promise.all(concurrent.map(response => response.json()));
  assert.deepEqual(created, duplicate);
  await db.prepare("UPDATE users SET balance=0 WHERE id=1").run();
  assert.equal((await postOrder({}, 200)).order_no, created.order_no);
  await db.prepare("UPDATE users SET balance=1000 WHERE id=1").run();
  const auth = {appid: order.appid, timestamp: Math.floor(Date.now() / 1000)};
  auth.sign = testSignature('query', {...auth, order_no: created.order_no});
  const queried = await mf.dispatchFetch(ordersUrl + '/' + created.order_no + '?' + new URLSearchParams(auth));
  assert.equal(queried.status, 200);
  assert.equal((await queried.json()).merchant_order_no, order.order_no);
  assert.equal((await postOrder({amount: 2}, 409)).code, 'order_conflict');
  assert.equal((await postOrder({product_code: 'unknown'}, 400)).code, 'invalid_product');
  assert.equal((await postOrder({order_no: 'fixture-ok', product_code: 'fixture'}, 201)).product_code, 'fixture');
  assert.equal((await postOrder({product_code: 'fixture'}, 409)).code, 'order_conflict');
  const oversized = await mf.dispatchFetch('http://local/api/v1/orders', {
    method: 'POST', headers: {'content-type': 'application/json'}, body: ' '.repeat(16385)
  });
  assert.equal(oversized.status, 400);
  console.log('PASS: merchant API create/retry/query, callback signature and request size');
  console.log('PASS: durable callback job, signed delivery and retry after non-ok response');
  await verifyTelegram(mf, db, created.order_no);
} finally {
  await mf.dispose();
}
