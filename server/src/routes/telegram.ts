import type { Env } from "../types/env";

interface Message {
  from?: { id: number; is_bot: boolean };
  chat?: { id: number; type: string };
  text?: string;
}
const authorizedAdmin = "SELECT 1 FROM telegram_admins WHERE telegram_id=?";
const bindHelp = "请将收到的一次性管理员密钥直接发送到本私聊，即可绑定。";

async function bindInvite(db: D1Database, telegramId: number, key: string) {
  const claimed = await db.prepare(`UPDATE telegram_admins SET telegram_id=?,bind_key=NULL
    WHERE bind_key=? AND telegram_id IS NULL AND NOT EXISTS (${authorizedAdmin}) RETURNING id`)
    .bind(telegramId, key, telegramId).first();
  return claimed !== null;
}
const resetPasswordUsage = "/account_reset ID 新密码 重置登录密码（6 至 128 个非空白字符）";
const guides = {
  merchants: [
    "/merchants [游标] 查看商户列表",
    "/merchant ID 查看商户",
    "/merchant_add 商户名称 创建商户（自动生成 AppID 和 AppKey）",
    "/merchant_key ID 查看签名密钥",
    "/merchant_status ID 1或0 启用或停用商户"
  ],
  devices: [
    "/devices [游标] 查看设备列表",
    "/device ID 查看设备号、产品及派单状态",
    "/device_set ID 权重 日限额 设置派单参数（日限额单位元，0 为不限）"
  ],
  orders: [
    "/orders [游标] 查看订单列表",
    "/order ID或平台单号 查看订单和最近事件",
    "/notify_retry 订单ID 重试已失败的商户回调"
  ],
  accounts: [
    "/accounts [游标] 查看账号列表",
    "/account ID 查看账号",
    "/account_add 用户名 初始密码 创建账号",
    "/account_status ID 1或0 启用或停用账号",
    "/balance ID 变动金额 调整余额（元，扣减用负数）",
    resetPasswordUsage
  ]
};
const sections = { 商户管理: "merchants", 设备管理: "devices", 订单管理: "orders", 账号管理: "accounts" } as const;
const lists = {
  merchants: "SELECT id,name AS 名称,appid AS AppID,status AS 启用 FROM merchants",
  devices: "SELECT id,model AS 型号,user_id AS 账号ID,online AS 在线,weight AS 权重,daily_limit AS 日限额 FROM devices",
  orders: "SELECT id,order_no AS 平台单号,amount AS 金额,status AS 状态 FROM orders",
  accounts: "SELECT id,username AS 用户名,balance AS 余额,frozen AS 冻结,status AS 启用 FROM users"
};
function format(row: Record<string, unknown>) {
  return Object.entries(row).map(([key, value]) => key + " " + String(value ?? "—").replace(/\s+/g, " ").slice(0, 180)).join(" · ");
}
function integer(value: string, signed = false) {
  if (!(signed ? /^-?\d+$/ : /^\d+$/).test(value)) return NaN;
  const n = Number(value);
  return Number.isSafeInteger(n) ? n : NaN;
}
async function handle(db: D1Database, updateId: number, admin: number, text: string) {
  const [token, ...args] = text.trim().split(/\s+/);
  const cmd = (Object.hasOwn(sections, token) ? sections[token as keyof typeof sections] : token).replace(/^\//, "").split("@")[0];
  if (cmd === "help" || cmd === "start") return "选择管理项目，或输入 /merchants、/devices、/orders、/accounts。";
  if (Object.hasOwn(lists, cmd)) {
    const section = cmd as keyof typeof lists;
    const before = args.length ? integer(args[0]) : Number.MAX_SAFE_INTEGER;
    if (args.length > 1 || !(before > 0)) return guides[section][0];
    const { results } = await db.prepare(lists[section] + " WHERE id < ? ORDER BY id DESC LIMIT 6").bind(before).all();
    const page = results.slice(0, 5);
    return [...page.map(format), ...(!page.length ? ["暂无记录"] : []),
      ...(results.length > 5 ? ["下一页 /" + cmd + " " + page[4].id] : []), "", ...guides[section]].join("\n");
  }

  const [arg, value, limit] = args;
  const id = integer(arg);
  const details = {
    merchant: lists.merchants + " WHERE id=?",
    merchant_key: "SELECT appid AS AppID,appkey AS 签名密钥 FROM merchants WHERE id=?",
    device: "SELECT serial AS 设备号,user_id AS 账号ID,model AS 型号,product_code AS 产品,online AS 在线,ready AS 就绪,status AS 接单,consecutive_failures AS 连续失败,weight AS 权重,daily_limit AS 日限额,datetime(connected_at/1000,'unixepoch','+8 hours') AS 最近连接,datetime(disconnected_at/1000,'unixepoch','+8 hours') AS 最近离线 FROM devices WHERE id=?",
    account: lists.accounts + " WHERE id=?"
  };
  if (Object.hasOwn(details, cmd)) {
    if (args.length !== 1 || !(id > 0)) return "用法 /" + cmd + " ID";
    const row = await db.prepare(details[cmd as keyof typeof details]).bind(id).first();
    return row ? format(row) : "未找到记录";
  }
  if (cmd === "order") {
    if (args.length !== 1) return guides.orders[1];
    const byId = id > 0;
    const order = await db.prepare(`SELECT o.id,o.order_no AS 平台单号,o.merchant_order_no AS 商户单号,o.merchant_id AS 商户ID,
      o.device_id AS 设备ID,o.user_id AS 账号ID,o.amount AS 金额,o.status AS 状态,o.fail_reason AS 原因,j.status AS 商户回调
      FROM orders o LEFT JOIN notification_jobs j ON j.order_id=o.id WHERE ${byId ? "o.id" : "o.order_no"}=?`)
      .bind(byId ? id : arg).first();
    if (!order) return "未找到订单";
    const events = await db.prepare("SELECT to_status AS 状态,message AS 说明,datetime(created_at/1000,'unixepoch','+8 hours') AS 北京时间 FROM order_events WHERE order_id=? ORDER BY id DESC LIMIT 5").bind(order.id).all();
    return [format(order), ...events.results.map(format)].join("\n");
  }

  // D1 batches are atomic. Keep the mutation and its replay guard in the same transaction.
  const fresh = `NOT EXISTS (SELECT 1 FROM telegram_admin_updates WHERE update_id=?) AND EXISTS (${authorizedAdmin})`;
  async function write(sql: string, params: (string | number)[], target: string, failed: string) {
    const now = Date.now();
    const [,receipt] = await db.batch<{applied: number}>([
      db.prepare(sql).bind(...params, updateId, admin),
      db.prepare(`INSERT INTO telegram_admin_updates(update_id,admin_id,action,target,applied,created_at)
        VALUES(?,?,?,?,changes(),?) ON CONFLICT(update_id) DO NOTHING RETURNING applied`).bind(updateId, admin, cmd, target, now)
    ]);
    if (!receipt.results.length) return "这条指令已处理。请查询当前记录。";
    return receipt.results[0].applied ? "操作成功 · " + target : failed;
  }
  const now = Date.now();
  if (cmd === "merchant_add") {
    const name = args.join(" ");
    if (!name || name.length > 100) return guides.merchants[2];
    const appid = crypto.randomUUID().replaceAll("-", "");
    const key = crypto.randomUUID().replaceAll("-", "") + crypto.randomUUID().replaceAll("-", "");
    return write(`INSERT INTO merchants(appid,name,appkey,created_at,updated_at) SELECT ?,?,?,?,? WHERE ${fresh} ON CONFLICT(appid) DO NOTHING`,
      [appid, name, key, now, now], `AppID ${appid}`, "创建商户失败，请重试");
  }
  if (cmd === "account_add" || cmd === "account_reset") {
    const validPassword = args.length === 2 && value.length >= 6 && value.length <= 128;
    if (cmd === "account_reset" && (!(id > 0) || !validPassword)) return resetPasswordUsage;
    if (cmd === "account_add" && (!/^[A-Za-z0-9_-]{1,64}$/.test(arg) || !validPassword))
      return guides.accounts[2] + "（密码 6 至 128 字符）";
    const hash = new Uint8Array(await crypto.subtle.digest("MD5", new TextEncoder().encode(value)));
    const digest = Array.from(hash, byte => byte.toString(16).padStart(2, "0")).join("");
    if (cmd === "account_reset") {
      return write(`UPDATE users SET password=?,updated_at=? WHERE id=? AND ${fresh}`,
        [digest, now, id], `账号 ${id} 密码已重置`, "未找到账号");
    }
    return write(`INSERT INTO users(username,password,created_at,updated_at) SELECT ?,?,?,? WHERE ${fresh} ON CONFLICT(username) DO NOTHING`,
      [arg, digest, now, now], arg, "用户名已存在");
  }
  if (cmd === "merchant_status" || cmd === "account_status") {
    if (args.length !== 2 || !(id > 0) || !["0","1"].includes(value)) return "用法 /" + cmd + " ID 1或0";
    const table = cmd === "merchant_status" ? "merchants" : "users";
    return write(`UPDATE ${table} SET status=?,updated_at=? WHERE id=? AND ${fresh}`,
      [Number(value), now, id], `ID ${id} 启用 ${value}`, "未找到记录");
  }
  if (cmd === "device_set") {
    const weight = integer(value), daily = integer(limit);
    if (args.length !== 3 || !(id > 0 && weight >= 0 && daily >= 0)) return guides.devices[2];
    return write(`UPDATE devices SET weight=?,daily_limit=?,updated_at=? WHERE id=? AND ${fresh}`,
      [weight, daily, now, id], `设备 ${id} 权重 ${weight} 日限额 ${daily}`, "未找到设备");
  }
  if (cmd === "balance") {
    const delta = integer(value, true);
    if (args.length !== 2 || !(id > 0) || !delta) return guides.accounts[4];
    return write(`UPDATE users SET balance=balance+?,updated_at=? WHERE id=? AND balance+? BETWEEN frozen AND ? AND ${fresh}`,
      [delta, now, id, delta, Number.MAX_SAFE_INTEGER], `账号 ${id} 余额变动 ${delta} 元`, "账号不存在、可用余额不足或超出金额范围");
  }
  if (cmd === "notify_retry") {
    if (args.length !== 1 || !(id > 0)) return guides.orders[2];
    return write(`UPDATE notification_jobs SET status='pending',attempts=0,last_error=NULL,next_attempt_at=? WHERE order_id=? AND status='failed' AND ${fresh}`,
      [now, id], `订单 ${id} 回调重新入队`, "该订单没有可重试的失败回调");
  }
  return "未知命令，请输入 /help。";
}

export async function telegramWebhook(request: Request, env: Env) {
  if (request.method !== "POST") return new Response(null, {status:405, headers:{Allow:"POST"}});
  const secret = env.TELEGRAM_WEBHOOK_SECRET;
  const supplied = request.headers.get("X-Telegram-Bot-Api-Secret-Token");
  const utf8 = new TextEncoder();
  if (!secret || !supplied || !/^[A-Za-z0-9_-]{1,256}$/.test(supplied) || secret.length !== supplied.length ||
      !crypto.subtle.timingSafeEqual(utf8.encode(secret), utf8.encode(supplied))) return new Response(null, {status:403});
  const update = await request.json<{ update_id?: number; message?: Message }>().catch(() => null);
  const message = update?.message;
  const from = message?.from;
  if (!Number.isSafeInteger(update?.update_id) || !message || !from || from.is_bot || !Number.isSafeInteger(from.id) ||
      message.chat?.type !== "private" || message.chat.id !== from.id || typeof message.text !== "string")
    return new Response(null, {status:204});
  const text = message.text.trim();
  const idRequested = /^\/id(?:@\w+)?$/.test(text);
  let allowed = !idRequested && !!await env.DB.prepare(authorizedAdmin).bind(from.id).first();
  const explicitKey = /^\/bind(?:@\w+)?\s+(\S+)$/u.exec(text)?.[1];
  const plainKey = (!allowed || text.startsWith("GP-")) && !text.startsWith("/") &&
    !Object.hasOwn(sections, text) && /^\S+$/u.test(text);
  const bindingKey = explicitKey ?? (plainKey ? text : undefined);
  let answer: string;
  if (idRequested) {
    answer = "你的 Telegram ID 为 " + from.id;
  } else if (bindingKey) {
    if (allowed) {
      answer = "当前 Telegram 账号已是管理员。";
    } else {
      allowed = await bindInvite(env.DB, from.id, bindingKey);
      answer = allowed ? "绑定成功，请选择管理项目。" : "绑定密钥无效或已使用。";
    }
  } else {
    answer = allowed ? await handle(env.DB, update!.update_id!, from.id, text) : "此账号没有管理权限。" + bindHelp;
  }
  return Response.json({method:"sendMessage", chat_id:from.id, text:answer.slice(0,4096), protect_content:true,
    ...(allowed ? {reply_markup:{keyboard:[["商户管理","设备管理"],["订单管理","账号管理"]],resize_keyboard:true}} : {})
  }, {headers:{"Cache-Control":"no-store"}});
}
