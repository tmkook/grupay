// The integration harness creates a fresh D1 database for each run.
import assert from 'node:assert/strict';
import { createHash, createHmac, randomUUID } from 'node:crypto';
export function testSignature(operation, fields, key = 'demo-key') {
  const encode = value => encodeURIComponent(String(value)).replace(/[!'()*]/g,
    char => '%' + char.charCodeAt(0).toString(16).toUpperCase());
  const canonical = Object.keys(fields).sort()
    .filter(name => name !== 'sign' && fields[name] != null && fields[name] !== '')
    .map(name => name + '=' + encode(fields[name])).join('&');
  return createHmac('sha256', key).update(operation + '\n' + canonical)
    .digest().subarray(0, 16).toString('base64url');
}

export async function verify(base, db, productCode, hibernate) {
  if (new URL(base).hostname !== '127.0.0.1') throw Error('Local test database required');
  const sockets = [];
  async function peer() {
    const s = new WebSocket(base.replace('http:', 'ws:') + '/ws');
    sockets.push(s);
    const queue = [],
      waiting = new Set();
    s.onmessage = e => {
      queue.push(JSON.parse(e.data));
      for (const f of [...waiting]) f();
    };
    await new Promise((resolve, reject) => {
      s.onopen = resolve;
      s.onerror = reject;
    });
    function take(match) {
      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => {
          waiting.delete(read);
          reject(Error('Timed out: ' + match));
        }, 12000);
        function read() {
          const i = queue.findIndex(match);
          if (i >= 0) {
            clearTimeout(timer);
            waiting.delete(read);
            resolve(queue.splice(i, 1)[0].data);
          }
        }
        waiting.add(read);
        read();
      });
    }
    return {
      queue, take,
      closed: new Promise(resolve => s.addEventListener('close', resolve, {once:true})),
      close: () => s.close(),
      request(type, data) {
        const id = randomUUID();
        s.send(JSON.stringify({
          id,
          type,
          data,
          ts: Date.now()
        }));
        return take(m => m.reply_to === id);
      }
    };
  }
  async function device(username = "tester", product = productCode, choose = false) {
    const p = await peer();
    const auth = await p.request('auth', {
      username,
      auth_digest: createHash('md5').update(username + '62cc2d8b4bf2d8728120d052163a77df').digest('hex'),
      serial: randomUUID(),
      model: 'test',
      version: '1.0.0',
      ...(choose ? {} : {product_code: product})
    });
    assert.ok(auth.user);
    if (!choose && product === productCode) {
      const script = `https://${new URL(base).host}/scripts/douyin-v1.js`;
      assert.equal(auth.product.script_url, script);
      assert.equal(auth.settings.script_url, script);
    }
    if (choose) {
      assert.equal(auth.product, null);
      assert.ok(auth.products.some(p => p.code === product));
      assert.equal((await p.request('ready.set', {ready: 1, account: 'test'})).code, 'product_unavailable');
      assert.equal((await p.request('product.select', {code: 'missing'})).code, 'product_unavailable');
      const selected = await p.request('product.select', {code: product, url: 'https://ignored.example'});
      assert.equal(selected.product.url, 'https://product.example/');
      assert.equal(selected.product.script_url, 'https://product.example/test.js');
    }
    assert.equal((await p.request('ready.set', {
      ready: 1,
      account: 'test'
    })).ready, 1);
    assert.equal((await p.request('device.set', {
      status: 1
    })).status, 1);
    return p;
  }
  async function post(notify = false) {
    const f = {
      amount: 10,
      product_code: productCode,
      appid: 'demo',
      order_no: randomUUID(),
      timestamp: Math.floor(Date.now() / 1000)
    };
    if (notify === true) f.notify_url = 'http://merchant.example/result';
    f.sign = testSignature('create', f);
    const r = await fetch(base + '/api/v1/orders', {
      method: 'POST',
      headers: {
        'content-type': 'application/json'
      },
      body: JSON.stringify(f)
    });
    assert.equal(r.status, 201);
    return (await r.json()).order_no;
  }
  // 商户建单不派单，付款人打开收银台（WSS 订阅）才触发派单。
  async function open(no) {
    const cashier = await peer();
    await cashier.request('cashier.subscribe', {order_no: no});
    cashier.close();
  }
  async function create(notify = false) {
    const no = await post(notify);
    await open(no);
    return no;
  }
  try {
    const credentials = {
      username: 'tester', auth_digest: createHash('md5').update('tester62cc2d8b4bf2d8728120d052163a77df').digest('hex'),
      serial: randomUUID(), model: 'session-test', version: '1.0.0'
    };
    const connectionState = () => db.prepare(
      'SELECT online,ready,status,connected_at,disconnected_at,updated_at FROM devices WHERE serial=?'
    ).bind(credentials.serial).first();
    const original = await peer();
    await original.request('auth', credentials);
    const firstConnection = await connectionState();
    assert.equal(firstConnection.status, 1);
    assert.ok(firstConnection.connected_at > 0);
    await original.request('device.set', {status: 0});
    const replacement = await peer();
    await replacement.request('auth', credentials);
    await original.closed;
    await hibernate();
    const connected = await connectionState();
    assert.ok(connected.connected_at > firstConnection.connected_at);
    assert.equal(connected.disconnected_at, null);
    assert.equal(connected.online, 1);
    assert.equal(connected.status, 0);
    assert.ok((await replacement.request('heartbeat', {})).ts >= connected.connected_at);
    assert.deepEqual(await connectionState(), connected);
    replacement.close();
    await replacement.closed;
    let offline = await connectionState();
    for (let i = 0; offline.online && i < 50; i++) {
      await new Promise(resolve => setTimeout(resolve, 20));
      offline = await connectionState();
    }
    assert.equal(offline.online, 0);
    assert.equal(offline.ready, 0);
    assert.equal(offline.connected_at, connected.connected_at);
    assert.ok(offline.disconnected_at >= offline.connected_at);
    const reconnect = await peer();
    await reconnect.request('auth', credentials);
    assert.equal((await connectionState()).disconnected_at, offline.disconnected_at);
    if (process.argv.includes('--verify-idle-timeout')) {
      await new Promise(resolve => setTimeout(resolve, 2500));
      const pong = await reconnect.request('heartbeat', {});
      const watchdog = setTimeout(() => reconnect.close(), 120000);
      try {
        assert.equal((await reconnect.closed).reason, 'Disconnected');
        const expired = await connectionState();
        assert.equal(expired.online, 0);
        assert.equal(expired.ready, 0);
        assert.ok(expired.disconnected_at >= pong.ts + 90000);
        console.log('PASS: idle disconnect after', expired.disconnected_at - pong.ts, 'ms');
      } finally {
        clearTimeout(watchdog);
      }
    } else {
      reconnect.close();
    }
    console.log('PASS: heartbeat leaves D1 unchanged, session replacement, hibernation and disconnect timestamps');

    const wrongProduct = await device("tester","fixture",true);
    const a = await device(),
      b = await device();
    const aId = await db.prepare("SELECT max(id) AS id FROM devices").first("id");
    const bId = await db.prepare("SELECT max(id) AS id FROM devices").first("id");
    // 两台设备都只保留一笔未完成订单，用例按单设备串行验证派单与失败重排。
    await db.prepare("UPDATE devices SET pending_limit=1 WHERE id IN (?,?)").bind(aId, bId).run();
    await b.request('device.set', {status: 0});
    await db.prepare("INSERT INTO users(username,password,created_at,updated_at) SELECT 'observer',password,0,0 FROM users WHERE id=1").run();
    const observer = await device('observer');
    await observer.request('device.set', {status: 0});
    await db.prepare('UPDATE users SET balance=1000 WHERE username=?').bind('observer').run();
    const start = performance.now();
    const task = p => p.take(m => m.type === 'order.task');
    const health = id => db.prepare("SELECT consecutive_failures FROM devices WHERE id=?").bind(id).first();
    // 先只放一笔订单，验证拒绝后改派给另一台设备。
    const orders = [await create()];
    const first = await task(a);
    assert.equal(first.order_no, orders[0]);
    const c = await peer(),
      snapshot = await c.request('cashier.subscribe', {
        order_no: first.order_no
      });
    assert.equal(snapshot.status, 'assigned');
    assert.equal((await a.request('order.ack', {
      ...first,
      accepted: false
    })).can_execute, false);
    await a.request('device.set', {status: 0});
    await b.request('device.set', {status: 1});
    const second = await task(b);
    assert.equal(second.order_no, first.order_no);
    const rejectedId = await db.prepare("SELECT device_id FROM order_events WHERE order_id=(SELECT id FROM orders WHERE order_no=?) AND to_status='assigned' AND attempt=1").bind(first.order_no).first('device_id');
    assert.deepEqual(await health(rejectedId), {consecutive_failures: 0});
    assert.equal(second.attempt, 2);
    assert.equal((await a.request('order.ack', {
      ...first,
      accepted: true
    })).can_execute, false);
    await hibernate();
    // 其余订单按创建顺序进入队列，由 b 逐笔处理。
    for (let i = 0; i < 9; i++) orders.push(await create());
    const seen = new Set();
    for (let i = 0; i < 10; i++) {
      const t = i === 0 ? second : await task(b);
      assert.ok(orders.includes(t.order_no));
      assert.ok(!seen.has(t.order_no));
      seen.add(t.order_no);
      assert.equal((await b.request('order.ack', {
        ...t,
        accepted: true
      })).can_execute, true);
      const placed = await b.request('order.placed', {
        ...t,
        pay_url: 'https://product.example/payment'
      });
      assert.equal(placed.status, 'placed');
      if (i === 0) assert.equal(placed.deadline_at, snapshot.deadline_at);
      assert.equal((await b.request('order.placed', {
        ...t,
        pay_url: 'https://product.example/payment'
      })).deadline_at, placed.deadline_at);
      if (i === 0) {
        assert.equal((await b.request('order.query.result', {...t, outcome: 'pending'})).recorded, true);
        assert.equal(await db.prepare(`SELECT count(*) AS n FROM order_events
          WHERE order_id=(SELECT id FROM orders WHERE order_no=?) AND message=?`)
          .bind(t.order_no, '客户端查单：pending').first('n'), 0);
      }
      const paid = {...t, tradeNo: t.order_no, account: 'test', amount: 10};
      assert.equal((await b.request('order.paid', paid)).status, 'paid');
      assert.equal((await b.request('order.paid', paid)).status, 'paid');
    }
    const fifo = await db.prepare("SELECT order_no FROM orders ORDER BY created_at,id").all();
    assert.deepEqual([...seen], fifo.results.map(o => o.order_no));
    const phases = ['created', 'assigned', 'placing', 'placed', 'paid'];
    for (const phase of phases) assert.equal((await c.take(m => m.type === 'cashier.update' && m.data.status === phase)).status, phase);
    const stats = await b.request('stats.get', {});
    assert.equal(stats.received, 10);
    assert.equal(stats.paid, 10);
    assert.equal(stats.total_amount, 100);
    assert.equal((await a.request('stats.get', {})).received, 0);
    const firstDevice = await a.request('stats.get', {});
    assert.deepEqual(firstDevice.account, stats.account);
    assert.equal(stats.account.received, 10);
    assert.equal(stats.account.paid_amount, 100);
    assert.deepEqual(await a.take(m => m.type === 'stats.account' && m.data.paid === 10), stats.account);
    const isolated = await observer.request('stats.get', {user_id: 1});
    assert.equal(isolated.account.received, 0);
    assert.ok(!observer.queue.some(m => m.type === 'stats.account'));
    assert.ok(!observer.queue.some(m => m.type === 'order.task'));
    assert.ok(!wrongProduct.queue.some(m => m.type === 'order.task'));
    const list = await b.request('order.list', {
      limit: 5
    });
    assert.equal(list.orders.length, 5);
    assert.ok(list.next_before_id);
    const elapsed = Math.round(performance.now() - start);
    const wallet = () => db.prepare('SELECT balance,frozen FROM users WHERE id=1').first();
    assert.deepEqual(await wallet(), {
      balance: 900,
      frozen: 0
    });
    const counts = await db.prepare('SELECT type,count(*) n FROM wallet_logs GROUP BY type').all();
    assert.deepEqual(Object.fromEntries(counts.results.map(r => [r.type, r.n])), {
      freeze: 11,
      settle: 10,
      unfreeze: 1
    });
    console.log('10 orders completed in ' + elapsed + ' ms (local WebSocket devices)');
    const uncertain = await create(true);
    const t = await task(b);
    assert.equal(t.order_no, uncertain);
    await b.request('order.ack', {
      ...t,
      accepted: true
    });
    assert.equal((await b.request('order.failed', {
      ...t,
      outcome: 'unknown', reason: '未取得支付链接'
    })).status, 'placing');
    await b.request('order.failed', {...t, outcome: 'unknown', reason: '未取得支付链接'});
    assert.equal(await db.prepare(`SELECT count(*) AS n FROM order_events e JOIN orders o ON o.id=e.order_id
      WHERE o.order_no=? AND e.message='未取得支付链接' AND e.source='device'`).bind(uncertain).first('n'), 1);
    await db.prepare("UPDATE orders SET accepted_at=? WHERE order_no=?").bind(Date.now() - 120001, uncertain).run();
    // Status updates wake the same scheduler used by the alarm.
    await b.request('device.set', {
      status: 1
    });
    const late = await b.request('order.placed', {
      ...t,
      pay_url: 'https://product.example/pay'
    });
    assert.equal(late.status, 'failed');
    const lateFailure = {...t, outcome: 'unknown', reason: '上游支付参数缺失或格式不符'};
    assert.equal((await b.request('order.failed', lateFailure)).status, 'failed');
    await b.request('order.failed', lateFailure);
    const lateMessage = '迟到建单失败回执：' + lateFailure.reason;
    const lateEvents = await db.prepare(`SELECT e.from_status,e.to_status,e.message FROM order_events e
      JOIN orders o ON o.id=e.order_id WHERE o.order_no=? AND e.message=?`).bind(uncertain, lateMessage).all();
    assert.deepEqual(lateEvents.results, [{from_status: 'failed', to_status: 'failed', message: lateMessage}]);
    assert.equal(await db.prepare("SELECT fail_reason FROM orders WHERE order_no=?").bind(uncertain).first('fail_reason'), '执行结果待对账');
    assert.deepEqual(await wallet(), {
      balance: 900,
      frozen: 0
    });
    assert.deepEqual(await health(await db.prepare("SELECT device_id FROM orders WHERE order_no=?").bind(uncertain).first('device_id')),
      {consecutive_failures: 0});
    await a.request('device.set', {status: 0});
    await b.request('device.set', {status: 0});
    const cDevice = await device(),
      timeoutNo = await create();
    const cId = await db.prepare("SELECT max(id) AS id FROM devices").first('id');
    const missed = await task(cDevice);
    assert.equal(missed.order_no, timeoutNo);
    const dDevice = await device();
    await db.prepare("UPDATE orders SET assigned_at=? WHERE order_no=?").bind(Date.now() - 20001, timeoutNo).run();
    await dDevice.request('device.set', {
      status: 1
    });
    const retry = await task(dDevice);
    assert.equal(retry.order_no, timeoutNo);
    // ACK 超时只换设备，不计入连续失败。
    assert.deepEqual(await db.prepare("SELECT consecutive_failures FROM devices WHERE id=?").bind(cId).first(), {
      consecutive_failures: 0
    });
    await db.prepare("UPDATE devices SET status=0 WHERE id=?").bind(cId).run();
    assert.equal((await cDevice.request('order.ack', {
      ...missed,
      accepted: true
    })).can_execute, false);
    await dDevice.request('order.ack', {
      ...retry,
      accepted: true
    });
    await dDevice.request('order.placed', {
      ...retry,
      pay_url: 'https://product.example/pay'
    });
    const liveRecheck = await dDevice.request('order.recheck', retry);
    assert.equal(liveRecheck.status, 'placed');
    assert.equal(liveRecheck.query_count, 0);
    const checkRequest = {...retry, tradeNo: 'late-order', account: 'test'};
    assert.equal((await dDevice.request('order.query.begin', checkRequest)).allowed, true);
    const checked = (await dDevice.request('order.list', {})).orders.find(o => o.order_no === timeoutNo);
    assert.equal(checked.query_count, 1);
    const manual = await dDevice.request('order.recheck', {...retry, count_on_request: true});
    assert.equal((await dDevice.request('order.query.begin', {...checkRequest, counted_revision: manual.counted_revision})).allowed, true);
    assert.equal(await db.prepare("SELECT query_count FROM orders WHERE order_no=?").bind(timeoutNo).first("query_count"), 2);
    await db.prepare("UPDATE orders SET deadline_at=? WHERE order_no=?").bind(Date.now() - 30001, timeoutNo).run();
    await dDevice.request('device.set', {
      status: 1
    });
    assert.equal((await dDevice.request('order.expired', retry)).status, 'expired');
    assert.deepEqual(await wallet(), {
      balance: 900,
      frozen: 0
    });
    const combined = await dDevice.request('stats.get', {});
    assert.equal(combined.received, 1);
    assert.deepEqual(combined.account, {
      date: combined.date, received: 12, paid: 10, failed: 1, expired: 1,
      completed: 12, in_progress: 0, total_amount: 120, paid_amount: 100
    });
    await dDevice.request('device.set', {
      status: 0
    });
    const head = await create(),
      tail = await create();
    await dDevice.request('device.set', {
      status: 0
    });
    // Both orders have been queued for over a minute; neither has reached its deadline.
    await db.prepare("UPDATE orders SET created_at=?,dispatch_at=?,deadline_at=? WHERE order_no IN (?,?)")
      .bind(Date.now() - 61000, Date.now() - 61000, Date.now() + 539000, head, tail).run();
    await dDevice.request('device.set', {status: 0});
    assert.equal(await db.prepare("SELECT status FROM orders WHERE order_no=?").bind(head).first("status"), 'created');
    await db.prepare("UPDATE orders SET deadline_at=? WHERE order_no=?").bind(Date.now() - 1, head).run();
    await dDevice.request('device.set', {status: 0});
    assert.equal(await db.prepare("SELECT status FROM orders WHERE order_no=?").bind(head).first("status"), 'failed');
    assert.equal(await db.prepare("SELECT status FROM orders WHERE order_no=?").bind(tail).first("status"), 'created');
    assert.deepEqual(await wallet(), {
      balance: 900,
      frozen: 0
    });
    await dDevice.request('device.set',{status:1});
    const e=await device(), f=await device();
    for(const [index,peer] of [dDevice,e,f].entries()){
      const attempt=await task(peer);
      assert.equal(attempt.order_no,tail);
      assert.equal(attempt.attempt,index+1);
      await peer.request('order.ack',{...attempt,accepted:true});
      await peer.request('order.failed',{...attempt,outcome:'confirmed_not_created',reason:'product rejected'});
    }
    assert.equal(await db.prepare("SELECT status FROM orders WHERE order_no=?").bind(tail).first("status"),'failed');
    assert.deepEqual(await wallet(),{balance:900,frozen:0});
    const recheck = await dDevice.request('order.recheck', retry);
    assert.equal(recheck.status, 'expired');
    assert.equal((await b.request('order.recheck', retry)).status, 'stale');
    const proof = {...retry, tradeNo: 'late-order', account: 'test', amount: 10};
    assert.equal((await dDevice.request('order.paid', {...proof, amount: 2})).status, 'expired');
    assert.equal((await dDevice.request('order.paid', proof)).status, 'paid');
    assert.equal((await dDevice.request('order.paid', proof)).status, 'paid');
    assert.equal(await db.prepare("SELECT trade_no FROM orders WHERE order_no=?").bind(timeoutNo).first('trade_no'), 'late-order');
    assert.equal((await dDevice.request('order.list', {})).orders.find(o => o.order_no === timeoutNo).query_count, 2);
    assert.deepEqual(await wallet(), {balance: 890, frozen: 0});
    assert.equal(await db.prepare("SELECT count(*) AS n FROM wallet_logs WHERE type='late_settle'").first('n'), 1);
    await db.prepare("UPDATE orders SET assigned_at=? WHERE order_no=?").bind(Date.now()-86400000, timeoutNo).run();
    const historical = await dDevice.request('stats.get', {history:true});
    assert.equal(historical.device_history[0].paid, 1);
    assert.equal(historical.account_history[0].received, 1);
    assert.equal(historical.device_history[0].paid_amount, 10);
    assert.deepEqual((await observer.request('stats.get', {history:true})).account_history, []);
    for (const peer of [a, b, observer, dDevice, e, f, wrongProduct]) {
      await peer.request('device.set', {status: 0});
    }
    const staleDevice = await device();
    const staleNo = await create();
    const staleTask = await task(staleDevice);
    assert.equal(staleTask.order_no, staleNo);
    assert.equal((await staleDevice.request('order.ack', {...staleTask, accepted: true})).can_execute, true);
    await staleDevice.request('order.placed', {...staleTask, pay_url: 'https://product.example/pay'});
    await db.prepare("UPDATE orders SET deadline_at=?,query_count=60 WHERE order_no=?").bind(Date.now() - 31000, staleNo).run();
    await staleDevice.request('device.set', {status: 1});
    assert.equal((await staleDevice.take(m => m.type === 'order.query')).order_no, staleNo);
    await new Promise(resolve => setTimeout(resolve, 300));
    assert.equal(await db.prepare("SELECT status FROM orders WHERE order_no=?").bind(staleNo).first('status'), 'failed');
    console.log('PASS: expired orders are pushed as query tasks and fail after the recheck budget');
    await staleDevice.request('device.set', {status: 0});
    await db.prepare("INSERT INTO users(username,password,created_at,updated_at) SELECT 'payer',password,0,0 FROM users WHERE id=1").run();
    const payerDevice = await device('payer');
    const payerNo = await create();
    await new Promise(resolve => setTimeout(resolve, 1200));
    assert.ok(!payerDevice.queue.some(m => m.type === 'order.task'));
    assert.equal(await db.prepare("SELECT status FROM orders WHERE order_no=?").bind(payerNo).first('status'), 'created');
    await db.prepare("UPDATE users SET balance=100 WHERE username='payer'").run();
    await payerDevice.request('device.set', {status: 1});
    assert.equal((await task(payerDevice)).order_no, payerNo);
    assert.equal(await db.prepare("SELECT user_id FROM orders WHERE order_no=?").bind(payerNo).first('user_id'),
      await db.prepare("SELECT id FROM users WHERE username='payer'").first('id'));
    assert.deepEqual(await db.prepare("SELECT balance,frozen FROM users WHERE username='payer'").first(),
      {balance: 100, frozen: 10});
    console.log('PASS: unpaid devices are skipped and the executing device owner pays');
    const md5hex = s => createHash('md5').update(s).digest('hex');
    await db.prepare("INSERT INTO users(username,password,created_at,updated_at) SELECT 'pwuser',password,0,0 FROM users WHERE id=1").run();
    const pwDevice = await device('pwuser');
    assert.equal((await pwDevice.request('password.change', {
      auth_digest: md5hex('pwuser' + md5hex('wrong-password')),
      new_password: md5hex('new-secret')
    })).code, 'wrong_password');
    assert.equal((await pwDevice.request('password.change', {
      auth_digest: md5hex('pwuser' + '62cc2d8b4bf2d8728120d052163a77df'),
      new_password: md5hex('new-secret')
    })).changed, true);
    assert.equal(await db.prepare("SELECT password FROM users WHERE username='pwuser'").first('password'), md5hex('new-secret'));
    console.log('PASS: password change rejects wrong old password and stores new digest');
    // 距离优先：付款人位置已知时选择最近的设备。
    await db.prepare("UPDATE orders SET status='failed',fail_reason='测试清理' WHERE status IN ('created','assigned','placing')").run();
    await db.prepare("UPDATE devices SET status=0").run();
    const near = await device();
    const nearId = await db.prepare("SELECT max(id) AS id FROM devices").first('id');
    const far = await device();
    const farId = await db.prepare("SELECT max(id) AS id FROM devices").first('id');
    await db.prepare("UPDATE devices SET city='北京',lat=39.9,lon=116.4 WHERE id=?").bind(nearId).run();
    await db.prepare("UPDATE devices SET city='广州',lat=23.13,lon=113.26 WHERE id=?").bind(farId).run();
    const distanceNo = await post();
    const stamp = Date.now();
    await db.prepare("UPDATE orders SET dispatch_at=?,payer_city='北京',payer_lat=39.9,payer_lon=116.4,payer_geo_at=? WHERE order_no=?").bind(stamp, stamp, distanceNo).run();
    await near.request('device.set', {status: 1});
    const nearest = await task(near);
    assert.equal(nearest.order_no, distanceNo);
    assert.equal((await near.request('stats.get', {})).received, 1);
    assert.ok(!far.queue.some(m => m.type === 'order.task'));
    // 建单成功清零连续失败次数。
    await db.prepare("UPDATE devices SET consecutive_failures=2 WHERE id=?").bind(nearId).run();
    await db.prepare("UPDATE orders SET status='placed',pay_url='https://product.example/pay',placed_at=?,deadline_at=? WHERE order_no=?").bind(Date.now(), Date.now() + 600000, distanceNo).run();
    assert.deepEqual(await db.prepare("SELECT consecutive_failures FROM devices WHERE id=?").bind(nearId).first(), {
      consecutive_failures: 0
    });
    // 未打开的订单使用建单时确定的有效期，到期后静默失败。
    const idleNo = await post(true);
    assert.equal(await db.prepare("SELECT deadline_at-created_at AS lifetime FROM orders WHERE order_no=?").bind(idleNo).first('lifetime'), 600000);
    await db.prepare("UPDATE orders SET deadline_at=? WHERE order_no=?").bind(Date.now() - 1, idleNo).run();
    await open(idleNo);
    assert.equal(await db.prepare("SELECT dispatch_at FROM orders WHERE order_no=?").bind(idleNo).first('dispatch_at'), 0);
    await near.request('device.set', {status: 1});
    assert.equal(await db.prepare("SELECT status FROM orders WHERE order_no=?").bind(idleNo).first('status'), 'failed');
    assert.equal(await db.prepare("SELECT count(*) AS n FROM notification_jobs j JOIN orders o ON o.id=j.order_id WHERE o.order_no=?").bind(idleNo).first('n'), 0);
    // 建单失败过就保留设备反馈的原因，不覆盖成队列超时。
    await db.prepare("UPDATE orders SET status='failed',fail_reason='测试清理' WHERE status IN ('created','assigned','placing')").run();
    await db.prepare("UPDATE devices SET status=0").run();
    const reasonNo = await post();
    await db.prepare("UPDATE orders SET dispatch_at=?,fail_reason=? WHERE order_no=?").bind(Date.now(), '产品页提示：账号已失效', reasonNo).run();
    await near.request('device.set', {status: 0});
    await db.prepare("UPDATE orders SET deadline_at=? WHERE order_no=?").bind(Date.now() - 1, reasonNo).run();
    await near.request('device.set', {status: 0});
    assert.equal(await db.prepare("SELECT status FROM orders WHERE order_no=?").bind(reasonNo).first('status'), 'failed');
    assert.equal(await db.prepare("SELECT fail_reason FROM orders WHERE order_no=?").bind(reasonNo).first('fail_reason'), '产品页提示：账号已失效');
    // 每次明确失败后换设备完成原订单，下一笔才允许再用 near。
    await near.request('device.set', {status: 1});
    async function confirmedFailure(no) {
      const t = await task(near);
      assert.equal(t.order_no, no);
      await near.request('order.ack', {...t, accepted: true});
      const failure = {...t, outcome: 'confirmed_not_created', reason: '产品账号已变化'};
      assert.equal((await near.request('order.failed', failure)).recorded, true);
      await near.request('order.failed', failure);
      await far.request('device.set', {status: 1});
      const retry = await task(far);
      assert.equal(retry.order_no, no);
      await far.request('order.ack', {...retry, accepted: true});
      await far.request('order.placed', {...retry, pay_url: 'https://product.example/pay'});
      await far.request('device.set', {status: 0});
    }
    const firstFailure = await create();
    await confirmedFailure(firstFailure);
    assert.deepEqual(await health(nearId), {consecutive_failures: 1});

    // A healthy device takes priority even when the failing device is closer.
    await far.request('device.set', {status: 1});
    const priorityNo = await post();
    await db.prepare("UPDATE orders SET dispatch_at=?,payer_lat=39.9,payer_lon=116.4 WHERE order_no=?")
      .bind(Date.now(), priorityNo).run();
    await far.request('device.set', {status: 1});
    const preferred = await task(far);
    assert.equal(preferred.order_no, priorityNo);
    await far.request('order.ack', {...preferred, accepted: true});
    await far.request('order.placed', {...preferred, pay_url: 'https://product.example/pay'});
    await far.request('device.set', {status: 0});

    const secondFailure = await create();
    await confirmedFailure(secondFailure);
    assert.deepEqual(await health(nearId), {consecutive_failures: 2});
    await confirmedFailure(await create());
    assert.equal((await health(nearId)).consecutive_failures, 3);
    assert.ok(!near.queue.some(m => m.type === 'device.pause'));
    const fallbackNo = await create();
    const fallback = await task(near);
    assert.equal(fallback.order_no, fallbackNo);
    await near.request('order.ack', {...fallback, accepted: true});
    assert.equal((await near.request('order.placed', {...fallback, pay_url: 'https://product.example/pay'})).status, 'placed');
    assert.deepEqual(await health(nearId), {consecutive_failures: 0});
    console.log('PASS: distance ranking, failure-based deprioritization, single-device fallback and recovery');
    const weighted = await device();
    const {id: weightedId, weight, daily_limit} = await db.prepare(
      "SELECT id,weight,daily_limit FROM devices ORDER BY id DESC LIMIT 1"
    ).first();
    assert.deepEqual([weight, daily_limit], [1, 0]);
    assert.equal((await weighted.request('device.set', {weight: -1, daily_limit: 10})).code, 'invalid_device_settings');
    assert.deepEqual(await weighted.request('device.set', {status: 1, weight: 5, daily_limit: 10, pending_limit: 3}),
      {status: 1, weight: 5, daily_limit: 10, pending_limit: 3});
    async function placeOn(peer, no) {
      const t = await task(peer);
      assert.equal(t.order_no, no);
      assert.equal((await peer.request('order.ack', {...t, accepted: true})).can_execute, true);
      assert.equal((await peer.request('order.placed', {...t, pay_url: 'https://product.example/pay'})).status, 'placed');
      return t;
    }
    await db.prepare("UPDATE devices SET pending_limit=0 WHERE id=?").bind(nearId).run();
    // Weight wins over the sticky device. A rejected attempt releases the original device's quota.
    const rejectedNo = await create();
        const rejected = await task(weighted);
    assert.equal(rejected.order_no, rejectedNo);
    await weighted.request('order.ack', {...rejected, accepted: false});
        await placeOn(near, rejectedNo);
        const atLimit = await placeOn(weighted, await create());
        await placeOn(near, await create());
    // A late payment can still settle, so expiry must not free the amount.
    await db.prepare("UPDATE orders SET deadline_at=? WHERE order_no=?").bind(Date.now()-31000, atLimit.order_no).run();
    await placeOn(near, await create());
    assert.equal((await weighted.request('order.paid', {
      ...atLimit, amount: 10, account: 'test', tradeNo: 'weighted-late-payment'
    })).status, 'paid');
    await placeOn(near, await create());
    // Move the paid order just before Beijing midnight to exercise the day boundary.
    const today = Math.floor((Date.now() + 8 * 3600000) / 86400000) * 86400000 - 8 * 3600000;
    await db.prepare("UPDATE orders SET assigned_at=? WHERE order_no=?").bind(today - 1, atLimit.order_no).run();
    await placeOn(weighted, await create());
    await db.prepare("UPDATE devices SET daily_limit=0 WHERE id=?").bind(weightedId).run();
    await placeOn(weighted, await create());
    console.log('PASS: device weight, daily limit, reassignment, late settlement and Beijing day rollover');
    // 多台设备并行接单，同一设备同时只保留一笔在途建单。
    await db.prepare("UPDATE orders SET status='failed',fail_reason='测试清理' WHERE status IN ('created','assigned','placing')").run();
    await db.prepare("UPDATE devices SET status=0").run();
    const p1 = await device();
    const p1Id = await db.prepare("SELECT max(id) AS id FROM devices").first("id");
    const p2 = await device();
    const p2Id = await db.prepare("SELECT max(id) AS id FROM devices").first("id");
    await db.prepare("UPDATE devices SET pending_limit=0 WHERE id IN (?,?)").bind(p1Id, p2Id).run();
    const parallel = [await create(), await create()];
    const [parallelTask1, parallelTask2] = await Promise.all([task(p1), task(p2)]);
    assert.notEqual(parallelTask1.order_no, parallelTask2.order_no);
    assert.deepEqual([parallelTask1.order_no, parallelTask2.order_no].sort(), parallel.sort());
    console.log('PASS: devices accept orders in parallel while each keeps one active placement');
    console.log('PASS: FIFO queue, sticky dispatch, stale ACK, cashier updates, idempotent settlement, device stats, execution timeout, ACK timeout and refund');
  } finally {
    for (const s of sockets) s.close();
  }
}
