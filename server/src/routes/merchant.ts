import serverConfig from "../config";
import { productByCode } from "../products";
type Fields = Record<string, string | number | null>;
type Operation = "create" | "query";
interface Order {
  order_no: string;
  merchant_order_no: string;
  product_code: string;
  amount: number;
  status: string;
  notify_url: string | null;
  fail_reason: string | null;
}
const orderColumns = "order_no,merchant_order_no,product_code,amount,status,notify_url,fail_reason";

function json(data: unknown, status: number) {
  return Response.json(data, {status, headers: {"Cache-Control":"no-store"}});
}
function invalid() {
  return json({code:"invalid_parameters"},400);
}

async function parameters(request:Request, operation:Operation, orderNo:string): Promise<Fields | null> {
  const params:Fields = Object.create(null);
  if (operation === "query") {
    params.order_no = orderNo;
    for (const [key, value] of new URL(request.url).searchParams) {
      if (Object.hasOwn(params,key)) return null;
      params[key] = value;
    }
    if (!/^\d+$/.test(String(params.timestamp))) return null;
    params.timestamp = Number(params.timestamp);
  } else {
    if (request.headers.get("content-type")?.split(";")[0].trim() !== "application/json") return null;
    const reader = request.body?.getReader();
    if (!reader) return null;
    const decoder = new TextDecoder("utf-8", { fatal: true, ignoreBOM: false });
    let raw = "", size = 0;
    try {
      while (true) {
        const part = await reader.read();
        if (part.done) break;
        size += part.value.byteLength;
        if (size > 16384) {
          await reader.cancel();
          return null;
        }
        raw += decoder.decode(part.value, { stream: true });
      }
      raw += decoder.decode();
    } finally {
      reader.releaseLock();
    }
    const parsed = JSON.parse(raw);
    if (!parsed || Array.isArray(parsed) || typeof parsed !== "object") return null;
    // The schema is flat. Count parsed key tokens before JSON.parse can hide a duplicate.
    const strings = raw.matchAll(/"(?:\\.|[^"\\])*"(\s*:)?/g);
    const keys = Array.from(strings).filter(match => match[1]);
    if (keys.length !== Object.keys(parsed).length) return null;
    Object.assign(params,parsed);
    if (!Number.isSafeInteger(params.amount) || Number(params.amount) < 1) return null;
    if (params.notify_url != null && params.notify_url !== "") {
      if (typeof params.notify_url !== "string") return null;
      const callback = new URL(params.notify_url);
      if (callback.protocol !== "https:" && callback.protocol !== "http:" || callback.username || callback.password || callback.hash) return null;
    }
  }
  const allowed = ["appid","sign","timestamp","order_no"];
  if (operation === "create") allowed.push("amount","notify_url","product_code");
  if (Object.keys(params).some(key=>!allowed.includes(key))) return null;
  if (![params.appid,params.order_no].every(value=>typeof value === "string" && value.length > 0 && value.length <= 256)) return null;
  if (!Number.isSafeInteger(params.timestamp)) return null;
  if (typeof params.sign !== "string" || !/^[A-Za-z0-9_-]{22}$/.test(params.sign)) return null;
  return params;
}

export async function merchantSignature(operation: Operation | "notify", fields: Fields, secret:string) {
  const query = Object.keys(fields).sort().filter(key=>key !== "sign" && fields[key] != null && fields[key] !== "").map(key=>{
    const encoded = encodeURIComponent(String(fields[key])).replace(/[!'()*]/g,c=>"%"+c.charCodeAt(0).toString(16).toUpperCase());
    return key+"="+encoded;
  }).join("&");
  const utf8 = new TextEncoder();
  const key = await crypto.subtle.importKey("raw",utf8.encode(secret),{name:"HMAC",hash:"SHA-256"},false,["sign"]);
  const mac = await crypto.subtle.sign("HMAC",key,utf8.encode(operation+"\n"+query));
  return btoa(String.fromCharCode(...new Uint8Array(mac,0,16))).replace(/=/g,"").replace(/\+/g,"-").replace(/\//g,"_");
}

export async function merchantOrders(request:Request, db:D1Database, orderNo:string) {
  const operation = orderNo ? "query" : "create";
  const method = orderNo ? "GET" : "POST";
  if (request.method !== method) return new Response(null,{status:405,headers:{Allow:method}});
  let fields;
  try { fields = await parameters(request,operation,orderNo); } catch { return invalid(); }
  if (!fields) return invalid();
  const now = Date.now();
  const timestamp = Number(fields.timestamp);
  if (Math.abs(Math.floor(now/1000)-timestamp)>300) return json({code:"timestamp_expired"},401);
  const merchant = await db.prepare("SELECT id,appkey FROM merchants WHERE appid=? AND status=1").bind(fields.appid).first<{id:number,appkey:string}>();
  if (!merchant) return json({code:"invalid_signature"},401);
  let expected;
  try { expected = await merchantSignature(operation,fields,merchant.appkey); } catch {return invalid();}
  const utf8=new TextEncoder();
  if (!crypto.subtle.timingSafeEqual(utf8.encode(expected),utf8.encode(String(fields.sign)))) return json({code:"invalid_signature"},401);

  let created = false;
  let order: Order | null;
  if (operation === "create") {
    if (!await productByCode(db, fields.product_code)) return json({code:"invalid_product"},400);
    const notify = fields.notify_url || null;
    const existing = db.prepare(`SELECT ${orderColumns} FROM orders WHERE merchant_id=? AND merchant_order_no=?`)
      .bind(merchant.id, fields.order_no);
    order = await existing.first<Order>();
    if (!order) {
      const platform = "GR" + crypto.randomUUID().replaceAll("-", "");
      order = await db.prepare(`INSERT INTO orders(order_no,merchant_order_no,merchant_id,product_code,amount,notify_url,created_at,updated_at,deadline_at)
        VALUES(?,?,?,?,?,?,?,?,?) ON CONFLICT(merchant_id,merchant_order_no) DO NOTHING RETURNING ${orderColumns}`)
        .bind(platform, fields.order_no, merchant.id, fields.product_code, fields.amount, notify, now, now, now + serverConfig.orderLifetimeMs)
        .first<Order>();
      created = order !== null;
      // A concurrent retry may have inserted the order after our first lookup.
      order ??= await existing.first<Order>();
      if (!order) return json({ code: "merchant_route_unavailable" }, 403);
    }
    if (order.product_code !== fields.product_code || order.amount !== fields.amount || order.notify_url !== notify) return json({code:"order_conflict"},409);
  } else {
    order = await db.prepare(`SELECT ${orderColumns} FROM orders WHERE merchant_id=? AND order_no=?`)
      .bind(merchant.id, orderNo).first<Order>();
  }
  if (!order) return json({code:"order_not_found"},404);
  const cashier=new URL(serverConfig.cashierBaseUrl,request.url);
  cashier.searchParams.set("order_no",order.order_no);
  return json({
    product_code: order.product_code,
    order_no: order.order_no,
    merchant_order_no: order.merchant_order_no,
    amount: order.amount,
    status: order.status,
    ...(order.fail_reason ? { fail_reason: order.fail_reason } : {}),
    cashier_url: cashier.href
  }, created ? 201 : 200);
}
