// Adapted from the supplied console-pay.js. Installing/identifying never submits an order.
// Runs in the signed-in Douyin PC or mobile recharge page, not in Node.js.
(() => {
  const getStore = () => window.__RECHARGE_PC_GLOBAL_STORE__ || window.__RECHARGE_WEB_GLOBAL_STORE__;
  const signedOut = () => ({ ready: false, uid: '', nickname: '', avatar: '' });
  const string = (value) => typeof value === 'string' ? value.trim() : '';
  // sec_user_id is encrypted and can rotate on each page request. The site's
  // id/short_id identifies the same account across a fresh login check.
  const userId = (user) => string(user?.id) ||
    (string(user?.short_id) ? 'SHORT_ID_' + string(user.short_id) : string(user?.sec_user_id));
  class PlacementError extends Error {
    constructor(message, reauth = false) {
      super(message);
      this.reauth = reauth;
    }
  }
  const upstreamCode = (result) => {
    const code = result?.status_code ?? result?.data?.status_code;
    return Number.isSafeInteger(code) ? code : null;
  };
  // 上游判定登录态失效的状态码，需要重新登录充值账号。
  const reauthCodes = new Set([4005436]);
  const upstreamStatus = (result) => {
    const code = upstreamCode(result);
    return code == null ? '' : `（上游状态码 ${code}）`;
  };
  const needsReauth = (result) => reauthCodes.has(upstreamCode(result));
  let lastPaymentQuery;
  const avatarUrl = (value) => {
    if (value && typeof value === 'object') value = value.url_list?.[0] ?? value.url;
    if (typeof value !== 'string' || !value.trim()) return '';
    try {
      const url = new URL(value, window.location.origin);
      return url.protocol === 'https:' && !url.username && !url.password && url.href.length <= 2048 ? url.href : '';
    } catch { return ''; }
  };

  const adapter = {
    getUser() {
      const store = getStore();
      const raw = store?.currentUserInfo;
      if (!raw || typeof raw !== 'object' || raw.is_current_user === false) return signedOut();
      const uid = userId(raw);
      if (!uid || uid.length > 256) return signedOut();
      const recipient = store.rechargeAccountInfo;
      if (recipient && (recipient.is_current_user === false ||
          (userId(recipient) && userId(recipient) !== uid))) return signedOut();
      return {
        ready: true,
        uid,
        nickname: string(raw.nick_name).slice(0, 100),
        // Optional: absent/unrecognised site avatar data is represented as an empty string.
        avatar: avatarUrl(raw.avatar_url || raw.avatar || raw.avatar_thumb || raw.avatar_medium),
      };
    },

    async getPayUrl(price, store) {
      const info = store.rechargeExternalData.DiamondInfo;
      const count = info.custom_diamond_x10_rate > 0
        ? Math.round(price * info.custom_diamond_x10_rate / 100) : price;
      const combo = {
        id: 666666, price, exchange_price: count,
        diamond_count_x10: count, diamond_count: count / 10,
        is_customized_diamond: true,
      };
      if (info.custom_tax_info) {
        const { tax_rate_bp, user_burden_ratio_bp } = info.custom_tax_info;
        const base = BigInt(price) * BigInt(tax_rate_bp);
        const tax = (base + 5000n) / 10000n;
        const userTax = (base * BigInt(user_burden_ratio_bp) + 50000000n) / 100000000n;
        combo.tax_info = { tax_amount: Number(tax), platform_subsidy: Number(tax - userTax) };
      }
      store.selectedCombo = combo;
      let result;
      try {
        result = await store.createOrder({ isOversea: false });
      } catch (error) {
        throw new PlacementError('上游建单调用异常' + upstreamStatus(error), needsReauth(error));
      }
      if (!result) throw new PlacementError('上游未返回建单结果');
      const upstreamOrderId = string(result?.order_id || result?.data?.order_id);
      if (!/^[A-Za-z0-9_-]{1,128}$/.test(upstreamOrderId)) {
        throw new PlacementError('上游未返回有效订单号' + upstreamStatus(result), needsReauth(result));
      }
      // PC returns params directly. Mobile returns data.params, which can be
      // either a URL or a JSON string containing the cashdesk_url for pay_type=2.
      const params = result?.params ?? result?.data?.params;
      if (typeof params !== 'string') throw new PlacementError('上游支付参数缺失或格式不符');
      let url = params;
      if (params.trim().startsWith('{')) {
        try {
          url = JSON.parse(params).cashdesk_url;
        } catch {
          throw new PlacementError('无法解析上游支付参数');
        }
      }
      if (typeof url !== 'string') throw new PlacementError('上游未返回支付链接');
      let parsedUrl;
      try {
        parsedUrl = new URL(url);
      } catch {
        throw new PlacementError('上游支付链接格式无效');
      }
      if (parsedUrl.protocol !== 'https:' || parsedUrl.username || parsedUrl.password) {
        throw new PlacementError('上游支付链接格式无效');
      }
      const queryUrl = new URL('https://www.douyin.com/webcast/wallet_api/query_order/');
      queryUrl.searchParams.set('aid', '1128');
      queryUrl.searchParams.set('order_id', upstreamOrderId);
      queryUrl.searchParams.set('source', '3');
      lastPaymentQuery = { provider: 'douyin', order_id: upstreamOrderId, request: { method: 'GET', url: queryUrl.href, amount: price / 100 } };
      return {payUrl: parsedUrl.href, tradeNo: upstreamOrderId, query_params: lastPaymentQuery.request};
    },
  };

  const api = {
    version: "1.0.0",
    async getUserInfo() {
      const user = adapter.getUser();
      return user.ready ? {ok: true, data: {uid: user.uid, name: user.nickname, avatar: user.avatar}}
                        : {ok: false, reason: '请在产品页登录'};
    },
    async getPayUrl(amount, orderNo, expectedAccount) {
      lastPaymentQuery = undefined;
      if (!Number.isSafeInteger(amount) || amount <= 0 || !Number.isSafeInteger(amount * 100)) {
        return {ok: false, reason: '充值金额无效或超出支持范围', outcome: 'confirmed_not_created'};
      }
      const user = adapter.getUser();
      const store = getStore();
      if (!user.ready || (expectedAccount != null && user.uid !== expectedAccount)) {
        return {ok: false, reason: '充值账号未登录或已变化', outcome: 'confirmed_not_created'};
      }
      if (!store?.acceptRechargeAgreement) {
        return {ok: false, reason: '充值页尚未确认充值协议', outcome: 'confirmed_not_created'};
      }
      if (!store?.rechargeExternalData?.DiamondInfo || typeof store.createOrder !== 'function') {
        return {ok: false, reason: '充值页面的建单组件未就绪', outcome: 'confirmed_not_created'};
      }
      try {
        return {ok: true, data: await adapter.getPayUrl(amount * 100, store)};
      } catch (error) {
        return {
          ok: false,
          reason: error instanceof PlacementError ? error.message : '充值脚本处理建单数据时异常',
          outcome: 'unknown',
          ...(error instanceof PlacementError && error.reauth ? {reauth: true} : {}),
        };
      }
    },
    async getProcessUrl() {
      return lastPaymentQuery ? {ok: true, data: lastPaymentQuery.request}
                              : {ok: false, reason: '没有订单查询地址'};
    },
    async queryOrder(params) {
      const user = adapter.getUser();
      if (!user.ready || user.uid !== params.account || !/^[A-Za-z0-9_-]{1,128}$/.test(params.tradeNo)) {
        return {ok: false, reason: '查单账号或订单号无效'};
      }
      const url = new URL('/webcast/wallet_api/query_order/', location.origin);
      url.search = new URLSearchParams({aid: '1128', order_id: params.tradeNo, source: '3'});
      if (url.href !== params.url) return {ok: false, reason: '查单地址不匹配'};
      const response = await fetch(url, {credentials: 'same-origin', redirect: 'error', cache: 'no-store'});
      if (!response.ok) return {ok: false, reason: '查单失败'};
      const result = await response.json();
      const data = result.data;
      if (result.status_code !== 0 || !data) return {ok: false, reason: '查单结果未知'};
      // The wallet endpoint can return only a status for the requested order.
      // In that case use the amount captured when this exact order was created.
      const amount = data.price == null ? params.amount
        : Number.isSafeInteger(data.price) ? data.price / 100 : null;
      const matchesOrder = data.order_id == null || String(data.order_id) === params.tradeNo;
      const paid = data.status === 1 && matchesOrder &&
          Number.isSafeInteger(amount) && amount > 0 &&
          (params.amount == null || amount === params.amount);
      return {ok: true, data: {status: paid ? 'paid' : data.status === 0 ? 'pending' : 'unknown',
                              tradeNo: params.tradeNo, account: user.uid, amount: paid ? amount : null}};
    },
  };
  // Keep the automation API out of key scans while still readable by the app.
  try {
    Object.defineProperty(window, 'grupay', {
      value: api, configurable: true, enumerable: false,
    });
  } catch {
    window.grupay = api;
  }
})();
