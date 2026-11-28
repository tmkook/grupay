import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { runInNewContext } from 'node:vm';
export async function verifyCashier() {
  const no = 'GR' + 'a'.repeat(32);
  const elements = new Map();
  const el = id => {
    if (!elements.has(id)) elements.set(id, {
      setAttribute(name, value) { this[name] = value; },
      removeAttribute(name) {
        delete this[name];
      }
    });
    return elements.get(id);
  };
  let socket, reconnect, tick;
  class Socket {
    constructor(url) {
      this.url = url;
      this.closed = false;
      socket = this;
    }
    send(raw) {
      assert.equal(JSON.parse(raw).data.order_no, no);
    }
    close() {
      this.closed = true;
      this.onclose?.();
    }
  }
  let now = Date.now();
  const redirects = [];
  class Clock extends Date {
    static now() {
      return now;
    }
  }
  const context = {
    document: {
      getElementById: el,
      querySelector: () => ({ content: 'wss://service.example' })
    },
    window: {},
    URL: class extends URL { static canParse = undefined; },
    URLSearchParams,
    crypto: { getRandomValues: bytes => crypto.getRandomValues(bytes) },
    Date: Clock,
    location: new URL('https://cashier.example/cashier?order_no=' + no),
    WebSocket: Socket,
    setTimeout: fn => {
      reconnect = fn;
    },
    setInterval: fn => {
      tick = fn;
      return fn;
    },
    clearInterval: handle => {
      assert.equal(handle, tick);
      tick = undefined;
    }
  };
  context.location.assign = url => redirects.push(url);
  const script = /<script type="module">([\s\S]*?)<\/script>/.exec(await readFile('public/cashier.html', 'utf8'))?.[1];
  assert.ok(script, 'cashier.html 内联脚本缺失');
  runInNewContext(script, context);
  assert.equal(socket.url, 'wss://service.example/ws');
  socket.onopen();
  function send(type, data) {
    socket.onmessage({ data: JSON.stringify({ type, data }) });
  }
  function event(status, revision, windowMs = 2000) {
    send('cashier.update', {
      order_no: no,
      amount: 10,
      status,
      revision,
      server_time: now,
      deadline_at: now + windowMs,
      pay_url: ['placed','paid','expired'].includes(status) ? 'https://product.example/pay' : null
    });
  }
  send('cashier.snapshot', {
    order_no: no, amount: 10, status: 'created', revision: 1,
    server_time: now, deadline_at: now + 2000, pay_url: null
  });
  assert.equal(el('phase').textContent, '分配资源中');
  assert.equal(el('remaining').textContent, '00:02');
  event('assigned', 2);
  assert.equal(el('phase').textContent, '已分配资源');
  event('placing', 3);
  assert.equal(el('phase').textContent, '正在创建订单');
  event('placed', 4);
  assert.equal(el('pay').href, 'https://product.example/pay');
  send('cashier.snapshot', {
    order_no: no, amount: 10, status: 'created', revision: 1,
    server_time: now, deadline_at: now + 2000, pay_url: null
  });
  assert.equal(el('phase').textContent, '已创建订单');
  socket.onclose();
  assert.equal(el('connection').textContent, '正在重新连接');
  assert.equal(el('pay').href, 'https://product.example/pay');
  now += 2500;
  tick();
  assert.equal(el('pay').href, 'https://product.example/pay');
  assert.equal(el('copyLink').disabled, false);
  reconnect();
  assert.equal(redirects.length, 0);
  event('placed', 5, 12000);
  now += 4999;
  tick();
  assert.equal(redirects.length, 0);
  now += 1;
  tick();
  tick();
  assert.deepEqual(redirects, ['https://product.example/pay']);
  event('expired', 6);
  now += 6000;
  tick();
  assert.equal(redirects.length, 1);
  assert.equal(el('pay').href, 'https://product.example/pay');
  assert.equal(el('copyLink').disabled, false);
  assert.equal(socket.closed, false);
  event('paid', 7);
  assert.equal(el('phase').textContent, '支付成功');
  assert.equal(el('pay').href, undefined);
  assert.equal(socket.closed, true);
  assert.equal(tick, undefined);
  runInNewContext(script, {...context, document: {getElementById: el, querySelector: () => null}});
  assert.equal(socket.url, 'wss://cashier.example/ws');
  event('placed', 1, 12000);
  send('cashier.unavailable', {});
  assert.equal(el('phase').textContent, '订单不存在');
  assert.equal(el('amount').textContent, '—');
  assert.equal(el('pay').href, undefined);
  assert.equal(el('remaining').textContent, '--:--');
  assert.equal(tick, undefined);
  console.log('PASS: cashier rendering, stale snapshot, reconnect and payment cutoff');
}
