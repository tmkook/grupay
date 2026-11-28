import serverConfig from "../config";
import { distanceKm } from "../geo";
import { dayMs, startOfStatsDay } from "../services/orders";

export type Order = {
  id: number;
  order_no: string;
  user_id: number | null;
  product_code: string;
  device_id: number | null;
  amount: number;
  revision: number;
  attempt_count: number;
  status: string;
  assigned_at: number;
  accepted_at: number;
  fail_reason: string | null;
  dispatch_at: number;
  payer_city: string | null;
  payer_region: string | null;
  payer_lat: number | null;
  payer_lon: number | null;
  payer_geo_at: number | null;
  placed_at: number;
  deadline_at: number;
  trade_no: string | null;
  query_count: number;
  created_at: number;
};
export type Changed = (order: Order, previousDevice?: number | null, countOnly?: boolean) => Promise<void>;
type Send = (id: number, type: string, data: unknown) => boolean;
export function versionOk(actual: string, minimum: string) {
  const parts = (value: string) => /^\d+(?:\.\d+){0,3}(?:\+\d+)?$/.test(value) ? value.split("+")[0].split(".").map(Number) : [];
  const a = parts(actual),
    b = parts(minimum);
  if (!a.length || !b.length) return false;
  for (let i = 0; i < 4; i++) if ((a[i] ?? 0) !== (b[i] ?? 0)) return (a[i] ?? 0) > (b[i] ?? 0);
  return true;
}
// The device keeps the query snapshot; the server only counts checks and
// prevents one provider transaction from settling two orders.
export const maxQueries = 60;
export const recheckWindow = 600000;
export const paymentGraceMs = 30000;
const placementRecheck = "执行结果待核对";
const placementReconcile = "执行结果待对账";
const unusedPayment = `NOT EXISTS (SELECT 1 FROM orders AS settled
  WHERE settled.status='paid' AND settled.id<>orders.id AND settled.trade_no=?)`;
const queryTask = (o: Order) => ({
  order_no: o.order_no,
  amount: o.amount,
  attempt: o.attempt_count,
  status: o.status,
  deadline_at: o.deadline_at,
  query_count: o.query_count
});
export class Dispatcher {
  constructor(private db: D1Database, private storage: DurableObjectStorage, private send: Send, private changed: Changed) {}
  private async transition(o: Order, status: string, fields: string, values: unknown[], now: number, before: D1PreparedStatement[] = []) {
    const update = this.db.prepare(`UPDATE orders SET status=?,revision=revision+1,updated_at=?,${fields} WHERE id=? AND status=? AND revision=? RETURNING *`).bind(status, now, ...values, o.id, o.status, o.revision);
    const row = before.length ? (await this.db.batch<Order>([...before, update]))[before.length].results[0] : await update.first<Order>();
    if (row) await this.changed(row, o.device_id);
    return row;
  }
  private async fail(o: Order, reason: string, retry: boolean, now: number, confirmedFailure = false) {
    const requeue = retry && o.attempt_count < 3 && now < o.deadline_at;
    // Only the report that changes the order may affect device priority.
    const penalty = confirmedFailure ? [
      this.db.prepare(`UPDATE devices SET consecutive_failures=consecutive_failures+1
      WHERE id=? AND EXISTS(SELECT 1 FROM orders WHERE id=? AND status=? AND revision=?)`)
      .bind(o.device_id, o.id, o.status, o.revision)
    ] : [];
    const row = await this.transition(o, requeue ? "created" : "failed", "fail_reason=?" + (requeue ? ",user_id=NULL,device_id=NULL,assigned_at=NULL,accepted_at=NULL" : ""), [reason], now, penalty);
    if (row && o.device_id) {
      await this.storage.delete("active_device_id");
      if (!confirmedFailure) return;
      const state = await this.db.prepare("SELECT consecutive_failures FROM devices WHERE id=?").bind(o.device_id).first<{
        consecutive_failures: number;
      }>();
      this.send(o.device_id, "device.state", {...state, reason, order_no: o.order_no, attempt: o.attempt_count});
    }
  }
  async tick(connected: Set<number>) {
    const now = Date.now();
    const due = await this.db.prepare("SELECT * FROM orders WHERE status='placed' AND deadline_at<? ORDER BY deadline_at LIMIT 32").bind(now - paymentGraceMs).all<Order>();
    for (const o of due.results) {
      const row = await this.transition(o, "expired", "expired_at=?", [now], now);
      // Expired orders still have a client-side recheck budget; hand them out as tasks.
      if (row?.device_id != null && connected.has(row.device_id)) this.send(row.device_id, "order.query", queryTask(row));
    }
    const stale = await this.db.prepare("SELECT * FROM orders WHERE status='expired' AND (query_count>=? OR expired_at<=?) ORDER BY id LIMIT 32").bind(maxQueries, now - recheckWindow).all<Order>();
    for (const o of stale.results) await this.transition(o, "failed", "fail_reason=?", ["过期未支付"], now);
    const waiting = await this.db.prepare("SELECT * FROM orders WHERE status='created' AND deadline_at<=? ORDER BY deadline_at LIMIT 32").bind(now).all<Order>();
    for (const order of waiting.results) {
      if (order.dispatch_at) {
        await this.fail(order, order.fail_reason ?? "等待可用设备超时", false, now);
      } else {
        // Keep an unopened order silent even with the original notification trigger.
        const [expired] = await this.db.batch<Order>([
          this.db.prepare(`UPDATE orders SET status='failed',revision=revision+1,updated_at=?,fail_reason='付款人未打开收银台'
            WHERE id=? AND revision=? AND status='created' AND dispatch_at=0 RETURNING *`).bind(now, order.id, order.revision),
          this.db.prepare(`DELETE FROM notification_jobs WHERE order_id=? AND attempts=0 AND status='pending'
            AND EXISTS(SELECT 1 FROM orders WHERE id=? AND status='failed' AND dispatch_at=0)`).bind(order.id, order.id)
        ]);
        if (expired.results[0]) await this.changed(expired.results[0]);
      }
    }
    // 每台设备同时只允许一笔建单，多台设备之间并行。
    const active = await this.db.prepare("SELECT * FROM orders WHERE status IN ('assigned','placing')").all<Order>();
    for (const order of active.results) {
      if (order.status === "assigned" && now >= order.deadline_at) {
        await this.fail(order, "订单已超时", false, now);
      } else if (order.status === "assigned" && (now > order.assigned_at + 20000 || !connected.has(order.device_id!))) {
        await this.fail(order, "设备未确认", true, now);
      } else if (order.status === "placing" && now > order.accepted_at + 120000) {
        await this.fail(order, placementReconcile, false, now);
      }
    }
    if (connected.size === 0) return;
    const busyRows = await this.db.prepare(
      "SELECT DISTINCT device_id FROM orders WHERE status IN ('assigned','placing') AND device_id IS NOT NULL"
    ).all<{ device_id: number }>();
    const busy = new Set(busyRows.results.map(row => row.device_id));
    const preferred = (await this.storage.get<number>("active_device_id")) ?? 0;
    const dayStart = startOfStatsDay(now);
    // The device owner pays on assignment, so only devices whose owner can cover it are eligible.
    const eligible = `FROM devices d JOIN products p ON p.code=d.product_code AND p.enabled=1 AND p.url=d.target JOIN users u ON u.id=d.user_id WHERE d.online=1 AND d.ready=1 AND d.status=1
      AND d.product_code=? AND d.account IS NOT NULL AND u.status=1 AND u.balance-u.frozen>=?
      AND NOT EXISTS(SELECT 1 FROM orders running WHERE running.device_id=d.id AND running.status IN ('assigned','placing'))
      AND (d.pending_limit=0 OR (SELECT count(*) FROM orders pending WHERE pending.device_id=d.id
        AND pending.status IN ('assigned','placing','placed')) < d.pending_limit)
      AND (d.daily_limit=0 OR d.daily_limit-? >= (
        SELECT coalesce(sum(used.amount),0) FROM orders used WHERE used.device_id=d.id
          AND used.assigned_at>=? AND used.assigned_at<?
          AND used.status IN ('assigned','placing','placed','expired','paid')
      ))
      AND NOT EXISTS(SELECT 1 FROM order_events e WHERE e.order_id=? AND e.device_id=d.id AND e.to_status='assigned')`;
    // 单次 tick 最多推进 16 笔，避免长时间占用 Durable Object。
    for (let round = 0; round < 16; round++) {
      const queue = await this.db.prepare("SELECT * FROM orders WHERE status='created' AND dispatch_at>0 AND deadline_at>? ORDER BY created_at,id LIMIT 8").bind(now).all<Order>();
      let assigned = false;
      for (const o of queue.results) {
        const args = [o.product_code, o.amount, o.amount, dayStart, dayStart + dayMs, o.id];
        const candidates = await this.db.prepare(`SELECT d.id,d.user_id,d.version,d.lat,d.lon,d.consecutive_failures,d.weight ${eligible}`).bind(...args).all<{
          id: number;
          user_id: number;
          version: string;
          consecutive_failures: number;
          weight: number;
          lat: number | null;
          lon: number | null;
        }>();
        const available = candidates.results.filter(d => connected.has(d.id) && !busy.has(d.id) && versionOk(d.version, serverConfig.minimumClientVersion));
        if (!available.length) continue;
        // 同等失败次数下，优先使用管理员权重高的设备。
        const rank = (d: { lat: number | null; lon: number | null }) =>
          distanceKm(o.payer_lat, o.payer_lon, d.lat, d.lon);
        available.sort((x, y) => {
          const failures = x.consecutive_failures - y.consecutive_failures;
          if (failures !== 0) return failures;
          if (x.weight !== y.weight) return y.weight - x.weight;
          const a = rank(x), b = rank(y);
          if (a < b) return -1;
          if (a > b) return 1;
          if (x.id === preferred) return -1;
          if (y.id === preferred) return 1;
          return x.id - y.id;
        });
        const device = available[0];
        const row = await this.db.prepare(`UPDATE orders SET status='assigned',attempt_count=attempt_count+1,revision=revision+1,
        updated_at=?,assigned_at=?,device_id=?,user_id=?,fail_reason=NULL WHERE id=? AND status='created' AND deadline_at>? AND EXISTS(SELECT 1 ${eligible} AND d.id=? AND d.version=?) RETURNING *`).bind(now, now, device.id, device.user_id, o.id, Date.now(), ...args, device.id, device.version).first<Order>();
        if (!row) continue;
        busy.add(device.id);
        await this.storage.put("active_device_id", device.id);
        this.send(device.id, "order.task", {
          order_no: o.order_no,
          amount: o.amount,
          attempt: row.attempt_count
        });
        await this.changed(row);
        assigned = true;
        break;
      }
      if (!assigned) return;
    }
  }
  async report(device: number, type: string, data: Record<string, unknown>) {
    const {
      order_no,
      attempt
    } = data;
    if (typeof order_no !== "string" || !Number.isSafeInteger(attempt)) return null;
    const o = await this.db.prepare("SELECT * FROM orders WHERE order_no=? AND device_id=? AND attempt_count=? AND product_code=(SELECT product_code FROM devices WHERE id=orders.device_id)").bind(order_no, device, attempt).first<Order>();
    const now = Date.now();
    if (!o) return {
      order_no,
      attempt,
      can_execute: false,
      status: "stale"
    };
    if (type === "order.query.begin") {
      if (!["placed", "expired"].includes(o.status) || o.query_count >= maxQueries) return { allowed: false, query_count: o.query_count };
      if (data.counted_revision != null) return { allowed: Number.isSafeInteger(data.counted_revision) && data.counted_revision === o.revision, query_count: o.query_count };
      const row = await this.db.prepare(`UPDATE orders SET query_count=query_count+1,revision=revision+1
        WHERE id=? AND revision=? AND status IN ('placed','expired') AND query_count<? RETURNING *`).bind(o.id, o.revision, maxQueries).first<Order>();
      if (row) await this.changed(row, o.device_id, true);
      return { allowed: !!row, query_count: row?.query_count };
    }
    if (type === "order.recheck") {
      if (!["placed", "expired"].includes(o.status)) return {
        order_no, attempt, status: o.status, amount: o.amount, query_count: o.query_count
      };
      if (o.query_count >= maxQueries) return {
        order_no, attempt, status: o.status, amount: o.amount, query_count: o.query_count, reason: "查单次数已用完"
      };
      let row = o;
      if (data.count_on_request === true) {
        row = (await this.db.prepare(`UPDATE orders SET query_count=query_count+1,revision=revision+1
          WHERE id=? AND device_id=? AND attempt_count=? AND query_count<? RETURNING *`).bind(o.id, device, attempt, maxQueries).first<Order>()) ?? o;
        if (row !== o) await this.changed(row, row.device_id, true);
      }
      return {
        order_no, attempt, status: row.status, amount: row.amount, deadline_at: row.deadline_at, query_count: row.query_count,
        counted_revision: data.count_on_request === true ? row.revision : undefined
      };
    }
    if (type === "order.query.result" || (type === "order.paid" && ["placed", "expired"].includes(o.status))) {
      const outcome = type === "order.paid" ? "paid" : data.outcome;
      if (!["paid", "pending", "unknown", "error"].includes(String(outcome))) return null;
      const record = (message: string) => this.db.prepare(
        "INSERT INTO order_events(order_id,from_status,to_status,source,message,created_at,device_id,attempt) VALUES(?,?,?,'device',?,?,?,?)"
      ).bind(o.id, o.status, o.status, message, Date.now(), device, attempt).run();
      // 未支付的轮询结果只保留在 query_count，避免每 10 秒写一条事件。
      if (outcome !== "pending") await record("客户端查单：" + outcome);
      if (type === "order.query.result") return { recorded: true };
      const tradeNo = typeof data.tradeNo === "string" && /^[A-Za-z0-9_-]{1,128}$/.test(data.tradeNo) ? data.tradeNo : null;
      if (tradeNo == null || data.amount !== o.amount || typeof data.account !== "string" || !data.account.trim() || data.account.length > 256) {
        await record("支付信息与订单不一致");
        return { order_no, attempt, status: o.status, deadline_at: o.deadline_at, reason: "支付信息与订单不一致，请稍后复查" };
      }
      await record("设备确认支付");
    }
    if (type === "order.paid" && o.status === "expired") {
      const row = await this.db.prepare(`UPDATE orders SET status='paid',revision=revision+1,updated_at=?,paid_at=?,trade_no=?
        WHERE id=? AND status='expired' AND revision=? AND trade_no IS NULL AND ${unusedPayment} AND EXISTS (
          SELECT 1 FROM users WHERE id=orders.user_id AND balance-frozen>=orders.amount
        ) RETURNING *`).bind(now, now, data.tradeNo, o.id, o.revision, data.tradeNo).first<Order>();
      if (!row) return { order_no, attempt, status: "expired", reason: "余额不足，补结算待重试" };
      await this.changed(row, o.device_id);
      return { order_no, attempt, status: "paid" };
    }
    if (type === "order.failed") {
      const reason = typeof data.reason === "string" ? data.reason.trim().slice(0, 256) : "";
      const confirmed = data.outcome === "confirmed_not_created";
      if (o.status === "placing" && confirmed && now <= o.accepted_at + 120000) {
        await this.fail(o, reason || "确认未建单", true, now, true);
        return { order_no, attempt, recorded: true };
      }
      const needsReconciliation = (o.status === "placing" && (o.fail_reason === null || o.fail_reason === placementRecheck))
        || (o.status === "failed" && o.fail_reason === placementReconcile);
      if (needsReconciliation && (confirmed || data.outcome === "unknown")) {
        const latePrefix = "迟到建单失败回执：";
        const message = (o.status === "failed" ? latePrefix : "") + (reason || "未取得建单结果");
        await this.db.batch([
          this.db.prepare(`INSERT INTO order_events(order_id,from_status,to_status,source,message,device_id,attempt,created_at)
            SELECT id,status,status,'device',?,device_id,attempt_count,? FROM orders
            WHERE id=? AND revision=? AND NOT EXISTS (
              SELECT 1 FROM order_events WHERE order_id=orders.id AND attempt=orders.attempt_count
                AND source='device' AND from_status=orders.status AND to_status=orders.status
                AND (orders.status='placing' OR message LIKE ?)
            )`).bind(message, now, o.id, o.revision, latePrefix + "%"),
          this.db.prepare("UPDATE orders SET fail_reason=? WHERE id=? AND revision=? AND status='placing' AND fail_reason IS NULL")
            .bind(placementRecheck, o.id, o.revision)
        ]);
        return { order_no, attempt, status: o.status };
      }
      if (o.status === "placing") return null;
    }
    if (["paid", "expired", "failed"].includes(o.status)) {
      await this.db.prepare("INSERT INTO order_events(order_id,from_status,to_status,source,message,created_at,device_id,attempt) VALUES(?,?,?,?,?,?,?,?)").bind(o.id, o.status, o.status, "device", "迟到或重复回执 " + type, now, device, attempt).run();
    }
    let row = o;
    if (type === "order.ack") {
      if (typeof data.accepted !== "boolean") return null;
      if (o.status === "assigned" && now < o.deadline_at && now <= o.assigned_at + 20000) {
        if (!data.accepted) {
          await this.fail(o, "设备拒绝接单", true, now);
          return {
            order_no,
            attempt,
            can_execute: false
          };
        }
        row = (await this.transition(o, "placing", "accepted_at=?", [now], now)) ?? o;
      }
      return {
        order_no,
        attempt,
        can_execute: data.accepted && row.status === "placing" && now < row.deadline_at && now <= row.accepted_at + 120000
      };
    }
    if (o.status === "placing" && now <= o.accepted_at + 120000) {
      if (type === "order.placed") {
        if (typeof data.pay_url !== "string" || !URL.canParse(data.pay_url)) return null;
        const url = new URL(data.pay_url);
        if (url.protocol !== "https:" || url.username || url.password) return null;
        row = (await this.transition(o, "placed", "pay_url=?,placed_at=?,fail_reason=NULL", [url.href, now], now)) ?? o;
      }
    } else if (o.status === "placed" && type === "order.paid" && now <= o.deadline_at + paymentGraceMs) {
      const settled = await this.db.prepare(`UPDATE orders SET status='paid',revision=revision+1,updated_at=?,paid_at=?,trade_no=?
        WHERE id=? AND status='placed' AND revision=? AND trade_no IS NULL AND ${unusedPayment} RETURNING *`).bind(now, now, data.tradeNo, o.id, o.revision, data.tradeNo).first<Order>();
      if (settled) {
        await this.changed(settled, o.device_id);
        row = settled;
      }
    } else if (o.status === "placed" && type === "order.expired" && now > o.deadline_at + paymentGraceMs) {
      row = (await this.transition(o, "expired", "expired_at=?", [now], now)) ?? o;
    }
    return {
      order_no,
      attempt,
      status: row.status,
      placed_at: row.placed_at,
      deadline_at: row.deadline_at,
      server_time: now
    };
  }
}
