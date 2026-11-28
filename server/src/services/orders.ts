import type { Geo } from "../geo";

export function cashierSnapshot(db: D1Database, no: string) {
  const now = Date.now();
  return db.prepare(`SELECT order_no,amount,status,revision,deadline_at,? AS server_time,
 pay_url FROM orders WHERE order_no=?`).bind(now, no).first();
}

/**
 * 商户只建单，付款人第一次打开收银台时才请求派单。
 * 原子抢占保证刷新、多标签只生效一次，并记录付款人位置供按距离派单使用。
 */
export async function requestDispatch(db: D1Database, no: string, geo: Geo) {
  const now = Date.now();
  const row = await db.prepare(`UPDATE orders SET dispatch_at=?,payer_city=?,payer_region=?,payer_lat=?,payer_lon=?,payer_geo_at=?,updated_at=?
    WHERE order_no=? AND status='created' AND dispatch_at=0 AND deadline_at>? RETURNING id`).bind(
    now, geo.city, geo.region, geo.lat, geo.lon, now, now, no, now,
  ).first();
  return !!row;
}
const aggregates = `count(*) received,count(*) FILTER(WHERE status='paid') paid,
 count(*) FILTER(WHERE status='failed') failed,count(*) FILTER(WHERE status='expired') expired,
 count(*) FILTER(WHERE status IN ('paid','failed','expired')) completed,count(*) FILTER(WHERE status IN ('created','assigned','placing','placed')) in_progress,
 coalesce(sum(amount),0) total_amount,coalesce(sum(amount) FILTER(WHERE status='paid'),0) paid_amount
`;

const ownerColumn = { account: "user_id", device: "device_id" } as const;
export const dayMs = 24 * 3600000;
const utc8OffsetMs = 8 * 3600000;

export function startOfStatsDay(now: number) {
  return Math.floor((now + utc8OffsetMs) / dayMs) * dayMs - utc8OffsetMs;
}

export async function stats(db: D1Database, scope: keyof typeof ownerColumn, id: number, now = Date.now()) {
  const start = startOfStatsDay(now);
  const sums = await db.prepare(`SELECT ${aggregates} FROM orders
    WHERE ${ownerColumn[scope]}=? AND assigned_at>=? AND assigned_at<?`)
    .bind(id, start, start + dayMs).first();
  return {
    date: new Date(now + utc8OffsetMs).toISOString().slice(0, 10),
    ...sums
  };
}

export async function priorStats(db: D1Database, scope: keyof typeof ownerColumn, id: number, now: number) {
  const rows = await db.prepare(`SELECT date(assigned_at/1000,'unixepoch','+8 hours') AS date, ${aggregates}
    FROM orders WHERE ${ownerColumn[scope]}=? AND assigned_at<? GROUP BY date ORDER BY date DESC LIMIT 30`)
    .bind(id, startOfStatsDay(now)).all();
  return rows.results;
}
