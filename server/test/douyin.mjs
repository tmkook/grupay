import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { runInNewContext } from 'node:vm';

const source = await readFile(new URL('../public/scripts/douyin-v1.js', import.meta.url), 'utf8');
for (const mobile of [false, true]) {
  let calls = 0;
  const store = {
    currentUserInfo: { id: 'signed-in' },
    acceptRechargeAgreement: true,
    rechargeExternalData: { DiamondInfo: {} },
    async createOrder() {
      const result = { order_id: String(++calls), params: 'https://cashier.example/pay' };
      if (!mobile) return result;
      result.params = JSON.stringify({ cashdesk_url: result.params });
      return { data: result };
    }
  };
  const window = { [mobile ? '__RECHARGE_WEB_GLOBAL_STORE__' : '__RECHARGE_PC_GLOBAL_STORE__']: store };
  let reply = {status: 1};
  runInNewContext(source, {
    window, URL, URLSearchParams, location: new URL('https://www.douyin.com/pay'),
    fetch: async () => ({ok: true, json: async () => ({status_code: 0, data: reply})})
  });
  const script = window.grupay;
  assert.equal((await script.getPayUrl(10, 'order', 'previous-account')).outcome, 'confirmed_not_created');
  assert.equal(calls, 0);
  const first = (await script.getPayUrl(10, 'first', 'signed-in')).data;
  const second = (await script.getPayUrl(10)).data;
  for (const [order, tradeNo] of [[first, '1'], [second, '2']]) {
    assert.equal(order.tradeNo, tradeNo);
    assert.equal(order.payUrl, 'https://cashier.example/pay');
    assert.equal(new URL(order.query_params.url).searchParams.get('order_id'), tradeNo);
  }
  assert.equal((await script.getProcessUrl()).data.url, second.query_params.url);
  const query = {...first.query_params, account: 'signed-in', tradeNo: first.tradeNo};
  const check = async () => (await script.queryOrder(query)).data;
  assert.equal((await check()).status, 'paid');
  assert.equal((await check()).amount, 10);
  for (const mismatch of [{status: 1, order_id: 'other'}, {status: 1, price: 2000}]) {
    reply = mismatch;
    assert.equal((await check()).status, 'unknown');
  }
  reply = {status: 0};
  assert.equal((await check()).status, 'pending');
  delete store.rechargeExternalData;
  const notReady = await script.getPayUrl(100, 'preflight', 'signed-in');
  assert.equal(notReady.outcome, 'confirmed_not_created');
  assert.equal(notReady.reason, '充值页面的建单组件未就绪');
  assert.equal(calls, 2);
  store.rechargeExternalData = {DiamondInfo: {}};
  store.createOrder = async () => ({status_code: 1234});
  const rejected = await script.getPayUrl(100, 'rejected', 'signed-in');
  assert.equal(rejected.outcome, 'unknown');
  assert.equal(rejected.reason, '上游未返回有效订单号（上游状态码 1234）');
}
console.log('PASS: PC and mobile account checks and per-order query snapshots');
