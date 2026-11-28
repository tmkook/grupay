import serverConfig from "../config";
import { describeProduct, listProducts, productByCode } from "../products";
import { DurableObject } from "cloudflare:workers";
import type { Env } from "../types/env";
import { Dispatcher, maxQueries, paymentGraceMs, recheckWindow, versionOk, type Order } from "../durable/order-dispatcher";
import { emptyGeo, parseGeoHeader, type Geo } from "../geo";
import { cashierSnapshot, priorStats, requestDispatch, stats } from "../services/orders";
import { deliver } from "../services/notifications";
const orderFields = `o.id,o.order_no,o.product_code,o.merchant_order_no,m.name AS merchant_name,o.amount,o.status,o.fail_reason,
  o.revision,o.created_at,o.placed_at,o.deadline_at,o.paid_at,o.expired_at,o.query_count,o.attempt_count AS attempt`;
interface Session {
  serviceOrigin: string;
  cashier?: string;
  userId?: number;
  expires: number;
  deviceId?: number;
  connectedAt?: number;
  productCode?: string;
  geo?: Geo;
}
interface User {
  id: number;
  username: string;
  password: string;
  nickname: string | null;
  status: number;
  balance: number;
  frozen: number;
}
export class DeviceSessions extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    // Earlier builds first assigned deadlines on placement.
    ctx.blockConcurrencyWhile(async () => {
      if (await ctx.storage.get<boolean>("order_deadlines_backfilled_v1")) return;
      await env.DB.prepare(`UPDATE orders SET deadline_at=created_at+?
        WHERE status IN ('created','assigned','placing') AND deadline_at IS NULL`).bind(serverConfig.orderLifetimeMs).run();
      await ctx.storage.put("order_deadlines_backfilled_v1", true);
    });
  }

  private emit(socket: WebSocket, type: string, data: unknown) {
    try {
      socket.send(JSON.stringify({
        id: crypto.randomUUID(),
        ts: Date.now(),
        type,
        data
      }));
      return true;
    } catch {
      return false;
    }
  }
  private dispatch = new Dispatcher(this.env.DB, this.ctx.storage, (id, type, data) => {
    const socket = this.ctx.getWebSockets().find(s => s.deserializeAttachment()?.deviceId === id);
    return !!socket && this.emit(socket, type, data);
  }, (o, old, countOnly) => this.changed(o, old, countOnly));
  private async changed(o: Order, old?: number | null, countOnly = false) {
    const db = this.env.DB;
    const snapshot = countOnly ? null : await cashierSnapshot(db, o.order_no);
    const previous = old && old !== o.device_id ? await db.prepare("SELECT user_id FROM devices WHERE id=?").bind(old).first<number>("user_id") : null;
    const detail = o.user_id == null ? null : await db.prepare(
      `SELECT ${orderFields} FROM orders o JOIN merchants m ON m.id=o.merchant_id WHERE o.id=?`
    ).bind(o.id).first();
    const accountTotals = new Map<number, Awaited<ReturnType<typeof stats>>>();
    const now = Date.now();
    for (const socket of this.ctx.getWebSockets()) {
      const session: Session = socket.deserializeAttachment();
      if (snapshot && session.cashier === o.order_no) this.emit(socket, "cashier.update", snapshot);
      if (!session.deviceId || !session.userId || session.expires <= now) continue;
      if (session.userId === o.user_id || session.userId === previous) {
        this.emit(socket, "order.update", {
          id: o.id,
          order_no: o.order_no,
          revision: o.revision,
          ...(session.userId === o.user_id ? detail : {}),
          can_recheck: session.productCode === o.product_code && session.deviceId === o.device_id && ["placed", "expired"].includes(o.status),
          removed: session.userId !== o.user_id
        });
        if (countOnly) continue;
        let totals = accountTotals.get(session.userId);
        if (!totals) {
          totals = await stats(db, "account", session.userId, now);
          accountTotals.set(session.userId, totals);
        }
        this.emit(socket, "stats.account", totals);
        this.emit(socket, "wallet.update", await db.prepare("SELECT balance,frozen FROM users WHERE id=?").bind(session.userId).first());
      }
      if (!countOnly && (session.deviceId === o.device_id || session.deviceId === old)) this.emit(socket, "stats.data", await stats(db, "device", session.deviceId, now));
    }
  }
  private async nextWork() {
    const work = await this.env.DB.prepare(`SELECT
      EXISTS(SELECT 1 FROM orders WHERE status IN ('assigned','placing')) OR
      EXISTS(SELECT 1 FROM orders WHERE status='created' AND dispatch_at>0) AS dispatch,
      (SELECT min(deadline_at) FROM orders WHERE status='created') AS created,
      (SELECT min(deadline_at)+?+1 FROM orders WHERE status='placed') AS placed,
      (SELECT min(CASE WHEN query_count>=? THEN 0 ELSE expired_at+? END) FROM orders WHERE status='expired') AS expired,
      (SELECT min(next_attempt_at) FROM notification_jobs WHERE status='pending') AS notify`)
      .bind(paymentGraceMs, maxQueries, recheckWindow)
      .first<{dispatch:number; created:number|null; placed:number|null; expired:number|null; notify:number|null}>();
    if (!work) throw new Error("Missing dispatch schedule");
    return {
      orders: work.dispatch ? 0 : Math.min(work.created ?? Infinity, work.placed ?? Infinity, work.expired ?? Infinity),
      notify: work.notify ?? Infinity
    };
  }
  private async tick() {
    const ids = new Set<number>();
    for (const s of this.ctx.getWebSockets()) {
      const a: Session = s.deserializeAttachment();
      if (a.deviceId && a.expires > Date.now() && s.readyState === 1) ids.add(a.deviceId);
    }
    await this.dispatch.tick(ids);
  }
  private async wake(dispatchNow = true) {
    const now = Date.now();
    const alarm = await this.ctx.storage.getAlarm();
    if (!dispatchNow && alarm !== null && alarm <= now + 1000) return;
    const work = await this.nextWork();
    const run = dispatchNow && work.orders <= now;
    const next = Math.max(now, Math.min(run ? now + 5000 : work.orders, work.notify));
    if (Number.isFinite(next) && (alarm === null || alarm > next)) await this.ctx.storage.setAlarm(next);
    if (run) await this.tick();
  }
  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname === "/internal/wake") {
      await this.ctx.blockConcurrencyWhile(() => this.wake(false));
      return new Response(null, {
        status: 204
      });
    }
    if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
      return new Response("WebSocket required", {
        status: 426
      });
    }
    const [client, socket] = Object.values(new WebSocketPair());
    this.ctx.acceptWebSocket(socket);
    const session: Session = {
      serviceOrigin: `https://${url.host}`,
      expires: Date.now() + 15000,
      geo: parseGeoHeader(request.headers.get("x-grupay-geo"))
    };
    socket.serializeAttachment(session);
    const alarm = await this.ctx.storage.getAlarm();
    if (alarm === null || alarm > session.expires) await this.ctx.storage.setAlarm(session.expires);
    return new Response(null, {
      status: 101,
      webSocket: client
    });
  }
  async webSocketMessage(socket: WebSocket, raw: string | ArrayBuffer) {
    return this.ctx.blockConcurrencyWhile(async () => {
      const session: Session = socket.deserializeAttachment();
      // Sockets created before serviceOrigin was persisted must reattach with their URL.
      if (!session.serviceOrigin) return socket.close(1012, "Reconnect to service");
      if (Date.now() >= session.expires) {
        await this.disconnect(socket);
        return;
      }
      if (typeof raw !== "string" || raw.length > 8192) return socket.close(1009, "Invalid frame");
      let message;
      try {
        message = JSON.parse(raw);
      } catch {
        return socket.close(1007, "Invalid JSON");
      }
      if (!message || typeof message.id !== "string" || typeof message.type !== "string" || !message.data || typeof message.data !== "object") return socket.close(1008, "Invalid envelope");
      const reply = (type: string, data: unknown) => socket.send(JSON.stringify({
        id: crypto.randomUUID(),
        reply_to: message.id,
        ts: Date.now(),
        type,
        data
      }));
      const now = Date.now();
      if (session.cashier) return socket.close(1008, "Read only");
      if (session.deviceId === undefined && message.type === "cashier.subscribe") {
        const no = message.data.order_no;
        if (typeof no !== "string" || !/^GR[a-f0-9]{32}$/.test(no)) {
          reply("cashier.unavailable", {});
          return socket.close(1008, "Order unavailable");
        }
        // 付款人第一次打开收银台才请求派单，记录位置供派单时比较距离。
        const claimed = await requestDispatch(this.env.DB, no, session.geo ?? emptyGeo());
        const snapshot = await cashierSnapshot(this.env.DB, no);
        if (!snapshot) {
          reply("cashier.unavailable", {});
          return socket.close(1008, "Order unavailable");
        }
        socket.serializeAttachment({
          cashier: no,
          expires: Number.MAX_SAFE_INTEGER
        });
        reply("cashier.snapshot", snapshot);
        if (claimed || (snapshot.status === "created" && Number(snapshot.deadline_at) <= Date.now())) await this.wake();
        return;
      }
      if (session.deviceId === undefined) {
        if (message.type !== "auth") return socket.close(1008, "Authenticate first");
        const {username, serial, model, version, auth_digest, product_code} = message.data;
        if (![username, serial, model, version].every(v => typeof v === "string" && v.length > 0 && v.length <= 2048) || typeof auth_digest !== "string" || !/^[a-f0-9]{32}$/.test(auth_digest)) return socket.close(1008, "Invalid authentication fields");
        const user = await this.env.DB.prepare("SELECT id,username,password,nickname,status,balance,frozen FROM users WHERE username=?").bind(username).first<User>();
        const digest = await crypto.subtle.digest("MD5", new TextEncoder().encode(username + (user?.password ?? "")));
        const received = Uint8Array.from(auth_digest.match(/../g)!, (part: string) => parseInt(part, 16));
        const reject = (code: number, message: string) => {
          reply("auth.error", {code, message});
          socket.close(1008, "Authentication rejected");
        };
        if (!crypto.subtle.timingSafeEqual(digest, received) || !user) return reject(801, "账号或密码错误");
        if (!user.status) return reject(802, "账号已禁用");
        const product = await productByCode(this.env.DB, product_code);
        if (product) {
          const activeOther = await this.env.DB.prepare("SELECT 1 FROM orders WHERE device_id=(SELECT id FROM devices WHERE serial=? AND user_id=?) AND product_code<>? AND status IN ('assigned','placing') LIMIT 1").bind(serial,user.id,product.code).first();
          if (activeOther) return reject(805, "请先完成当前产品的建单任务");
        }
        const geo = session.geo ?? {
          city: null, region: null, lat: null, lon: null
        };
        const geoAt = geo.city || geo.lat != null ? now : null;
        const device = await this.env.DB.prepare(`INSERT INTO devices
          (user_id,serial,model,version,target,product_code,online,status,city,region,lat,lon,geo_at,connected_at,created_at,updated_at)
          VALUES(?,?,?,?,?,?,1,1,?,?,?,?,?,?,?,?)
          ON CONFLICT(serial) DO UPDATE SET
            product_code=excluded.product_code,model=excluded.model,version=excluded.version,target=excluded.target,
            online=1,ready=0,account=NULL,city=coalesce(excluded.city,devices.city),region=coalesce(excluded.region,devices.region),
            lat=coalesce(excluded.lat,devices.lat),lon=coalesce(excluded.lon,devices.lon),geo_at=coalesce(excluded.geo_at,devices.geo_at),
            connected_at=max(excluded.connected_at,coalesce(devices.connected_at+1,0)),updated_at=excluded.updated_at
          WHERE devices.user_id=excluded.user_id
          RETURNING id,serial,status,online,ready,product_code,version,consecutive_failures,weight,daily_limit,pending_limit,connected_at`)
          .bind(user.id, serial, model, version, product?.url ?? "", product?.code ?? null,
            geo.city, geo.region, geo.lat, geo.lon, geoAt, now, now, now)
          .first<{id: number; connected_at: number}>();
        if (!device) return reject(803, "设备已绑定其他账号");
        for (const other of this.ctx.getWebSockets()) {
          if (other !== socket && other.deserializeAttachment()?.deviceId === device.id) {
            other.serializeAttachment({
              expires: 0
            });
            other.close(1008, "Session replaced");
          }
        }
        session.productCode = product?.code;
        session.userId = user.id;
        session.deviceId = device.id;
        session.connectedAt = device.connected_at;
        session.expires = now + 90000;
        socket.serializeAttachment(session);
        await this.env.DB.prepare("UPDATE users SET last_login_at=?,updated_at=? WHERE id=?").bind(now, now, user.id).run();
        const config = {
          ...(serverConfig.contact ? {contact: serverConfig.contact} : {}),
          min_version: serverConfig.minimumClientVersion,
          query_interval_ms: serverConfig.queryIntervalMs,
          query_timeout_ms: serverConfig.orderLifetimeMs
        };
        const products = await listProducts(this.env.DB);
        const selected = product ? describeProduct(product, session.serviceOrigin) : null;
        reply("auth.ok", {
          user: {
            id: user.id,
            username: user.username,
            nickname: user.nickname,
            balance: user.balance,
            frozen: user.frozen
          },
          device: {
            ...device,
            version_ok: versionOk(version, serverConfig.minimumClientVersion)
          },
          products,
          product: selected,
          settings: selected ? {...config, product_code: selected.code, product_origin: selected.origin, script_url: selected.script_url} : config
        });
        if (product) {
          const resume = await this.env.DB.prepare(`SELECT order_no,amount,attempt_count AS attempt,status,deadline_at,query_count FROM orders
            WHERE device_id=? AND product_code=? AND (status IN ('assigned','placing','placed')
              OR (status='expired' AND query_count<60))
            ORDER BY id DESC LIMIT 20`).bind(device.id,product.code).all();
          this.emit(socket, "order.resume", {
            orders: resume.results,
            server_time: now
          });
        }
      } else if (message.type === "product.select") {
        if (typeof message.data.code !== "string") return reply("error", {
          code: "product_unavailable",
          message: "产品不可用"
        });
        const product = await productByCode(this.env.DB, message.data.code);
        if (!product) return reply("error", {
          code: "product_unavailable",
          message: "产品不可用"
        });
        const activeOther = await this.env.DB.prepare("SELECT 1 FROM orders WHERE device_id=? AND product_code<>? AND status IN ('assigned','placing') LIMIT 1").bind(session.deviceId, product.code).first();
        if (activeOther) return reply("error", {
          code: "product_busy",
          message: "请先完成当前产品的建单任务"
        });
        await this.env.DB.prepare("UPDATE devices SET product_code=?,target=?,ready=0,account=NULL,updated_at=? WHERE id=?").bind(product.code, product.url, now, session.deviceId).run();
        session.productCode = product.code;
        socket.serializeAttachment(session);
        reply("product.selected", {
          product: describeProduct(product, session.serviceOrigin)
        });
        const resume = await this.env.DB.prepare(`SELECT order_no,amount,attempt_count AS attempt,status,deadline_at,query_count FROM orders
          WHERE device_id=? AND product_code=? AND (status IN ('assigned','placing','placed')
            OR (status='expired' AND query_count<60))
          ORDER BY id DESC LIMIT 20`).bind(session.deviceId, product.code).all();
        this.emit(socket, "order.resume", {
          orders: resume.results,
          server_time: now
        });
        await this.wake();
      } else if (message.type === "order.list") {
        const {
          limit = 20,
          before_id = Number.MAX_SAFE_INTEGER
        } = message.data;
        if (!Number.isSafeInteger(limit) || limit < 1 || limit > 100 || !Number.isSafeInteger(before_id)) return reply("error", {
          message: "分页参数无效"
        });
        const rows = await this.env.DB.prepare(`SELECT ${orderFields}, (o.device_id=? AND o.product_code=? AND o.status IN ('placed','expired')) AS can_recheck FROM orders o JOIN merchants m ON m.id=o.merchant_id WHERE o.user_id=? AND o.id<? ORDER BY o.id DESC LIMIT ?`).bind(session.deviceId, session.productCode ?? "", session.userId, before_id, limit + 1).all<{
          id: number;
        }>();
        const orders = rows.results.slice(0, limit);
        reply("order.list.result", {
          orders,
          next_before_id: rows.results.length > limit ? orders.at(-1)?.id : null
        });
      } else if (message.type === "stats.get") {
        const [device, account] = await Promise.all([
          stats(this.env.DB, "device", session.deviceId, now),
          stats(this.env.DB, "account", session.userId!, now)
        ]);
        if (message.data.history === true) {
          const [deviceHistory, accountHistory] = await Promise.all([
            priorStats(this.env.DB, "device", session.deviceId, now),
            priorStats(this.env.DB, "account", session.userId!, now)
          ]);
          reply("stats.data", { ...device, account, device_history: deviceHistory, account_history: accountHistory });
        } else {
          reply("stats.data", { ...device, account });
        }
      } else if (["order.ack", "order.failed", "order.placed", "order.paid", "order.expired", "order.recheck", "order.query.begin", "order.query.result"].includes(message.type)) {
        const result = await this.dispatch.report(session.deviceId, message.type, message.data);
        if (!result) return reply("error", {
          message: "无效的订单回执"
        });
        reply(message.type + ".result", result);
        if (!message.type.startsWith("order.query.")) await this.wake();
      } else if (message.type === "ready.set") {
        const {
          ready,
          account
        } = message.data;
        if (ready !== 0 && ready !== 1 || ready === 1 && (typeof account !== "string" || !account.trim() || account.length > 256)) {
          return reply("error", {
            code: "invalid_ready",
            message: "无效的产品登录状态"
          });
        }
        if (ready === 1) {
          if (!session.productCode) return reply("error", {code:"product_unavailable",message:"请先选择产品"});
          const product = await productByCode(this.env.DB, session.productCode);
          if (!product) return reply("error", {code:"product_unavailable",message:"产品配置不可用"});
        }
        await this.env.DB.prepare("UPDATE devices SET ready=?,account=?,updated_at=? WHERE id=?").bind(ready, ready ? account : null, now, session.deviceId).run();
        reply("ready.result", {
          ready
        });
        await this.wake();
      } else if (message.type === "device.set") {
        const {status = null, weight = null, daily_limit = null, pending_limit = null} = message.data;
        if (status === null && weight === null && daily_limit === null && pending_limit === null ||
          status !== null && status !== 0 && status !== 1 ||
          weight !== null && (!Number.isSafeInteger(weight) || weight < 0) ||
          daily_limit !== null && (!Number.isSafeInteger(daily_limit) || daily_limit < 0) ||
          pending_limit !== null && (!Number.isSafeInteger(pending_limit) || pending_limit < 0)) return reply("error", {
          code: "invalid_device_settings",
          message: "无效的设备设置"
        });
        const configured = await this.env.DB.prepare(`UPDATE devices SET
          consecutive_failures=CASE WHEN ?=1 AND status=0 THEN 0 ELSE consecutive_failures END,
          status=coalesce(?,status),weight=coalesce(?,weight),daily_limit=coalesce(?,daily_limit),
          pending_limit=coalesce(?,pending_limit),updated_at=?
          WHERE id=? RETURNING status,weight,daily_limit,pending_limit`)
          .bind(status, status, weight, daily_limit, pending_limit, now, session.deviceId).first();
        reply("device.set.result", configured);
        await this.wake();
      } else if (message.type === "password.change") {
        const {
          auth_digest,
          new_password
        } = message.data;
        if (typeof auth_digest !== "string" || !/^[a-f0-9]{32}$/.test(auth_digest) || typeof new_password !== "string" || !/^[a-f0-9]{32}$/.test(new_password)) return reply("error", {
          code: "invalid_password",
          message: "密码格式无效"
        });
        const user = await this.env.DB.prepare("SELECT username,password FROM users WHERE id=?").bind(session.userId).first<{
          username: string;
          password: string;
        }>();
        if (!user) return reply("error", {
          code: "invalid_password",
          message: "账号不存在"
        });
        const digest = await crypto.subtle.digest("MD5", new TextEncoder().encode(user.username + user.password));
        const received = Uint8Array.from(auth_digest.match(/../g)!, (part: string) => parseInt(part, 16));
        if (!crypto.subtle.timingSafeEqual(digest, received)) return reply("error", {
          code: "wrong_password",
          message: "原密码不正确"
        });
        await this.env.DB.prepare("UPDATE users SET password=?,updated_at=? WHERE id=?").bind(new_password, now, session.userId).run();
        reply("password.result", {
          changed: true
        });
      } else if (message.type === "heartbeat") {
        session.expires = now + 90000;
        socket.serializeAttachment(session);
        reply("pong", {
          ts: now
        });
      } else {
        reply("error", {
          code: "unsupported_message",
          message: "暂不支持该消息",
          retryable: false
        });
      }
    });
  }
  private async disconnect(socket: WebSocket) {
    const session: Session = socket.deserializeAttachment();
    if (session.deviceId !== undefined) {
      const now = Date.now();
      // A delayed close may belong to a replaced socket. Legacy sessions have a NULL connection time.
      await this.env.DB.prepare(`UPDATE devices SET online=0,ready=0,disconnected_at=?,updated_at=?
        WHERE id=? AND online=1 AND connected_at IS ?`).bind(now, now, session.deviceId, session.connectedAt ?? null).run();
    }
    socket.serializeAttachment({
      expires: 0
    });
    socket.close(1000, "Disconnected");
  }
  webSocketClose(socket: WebSocket) {
    return this.ctx.blockConcurrencyWhile(() => this.disconnect(socket));
  }
  webSocketError(socket: WebSocket) {
    return this.webSocketClose(socket);
  }
  async alarm() {
    const notifyDue = await this.ctx.blockConcurrencyWhile(async () => {
      let next = Infinity;
      for (const socket of this.ctx.getWebSockets()) {
        const {
          expires
        } = socket.deserializeAttachment() as Session;
        if (!expires || expires === Number.MAX_SAFE_INTEGER) continue;
        if (expires <= Date.now()) await this.disconnect(socket);else next = Math.min(next, expires);
      }
      let work = await this.nextWork();
      if (work.orders <= Date.now()) {
        await this.tick();
        work = await this.nextWork();
      }
      const now = Date.now();
      next = Math.min(next, work.orders === 0 ? now + 5000 : Math.max(now + 100, work.orders),
        Math.max(now + 1000, work.notify));
      if (Number.isFinite(next)) await this.ctx.storage.setAlarm(next);
      else await this.ctx.storage.deleteAlarm();
      return work.notify <= now;
    });
    if (!notifyDue) return;
    await deliver(this.env.DB);
    await this.ctx.blockConcurrencyWhile(async () => {
      const due = await this.env.DB.prepare("SELECT min(next_attempt_at) AS due FROM notification_jobs WHERE status='pending'").first<number>("due");
      const alarm = await this.ctx.storage.getAlarm();
      if (due != null && (alarm === null || due < alarm)) await this.ctx.storage.setAlarm(Math.max(Date.now() + 100, due));
    });
  }
}
