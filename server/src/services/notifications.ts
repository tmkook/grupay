import { merchantSignature } from "../routes/merchant";

const maxAttempts = 50;
const retryStepMs = 5000;

interface Job {
  order_id: number;
  attempts: number;
  appid: string;
  appkey: string;
  order_no: string;
  merchant_order_no: string;
  amount: number;
  paid_at: number | null;
  status: string;
  notify_url: string;
}
export async function deliver(db: D1Database) {
  const now = Date.now();
  const jobs = await db.prepare(`SELECT j.order_id,j.attempts,m.appid,m.appkey,o.order_no,o.merchant_order_no,o.amount,o.paid_at,o.status,o.notify_url
 FROM notification_jobs j JOIN orders o ON o.id=j.order_id JOIN merchants m ON m.id=o.merchant_id
 WHERE j.status='pending' AND j.next_attempt_at<=? ORDER BY j.next_attempt_at LIMIT 6`).bind(now).all<Job>();
  await Promise.all(jobs.results.map(async job => {
    const lease = now + 30000;
    const claim = await db.prepare("UPDATE notification_jobs SET next_attempt_at=? WHERE order_id=? AND status='pending' AND attempts=? AND next_attempt_at<=?").bind(lease, job.order_id, job.attempts, now).run();
    if (!claim.meta.changes) return;
    let error: string | null = null;
    let response: string | null = null;
    try {
      const url = new URL(job.notify_url);
      if (url.protocol !== "https:" && url.protocol !== "http:" || url.username || url.password) throw Error("origin");
      const {
        appid,
        order_no,
        merchant_order_no,
        amount,
        status,
        paid_at
      } = job;
      const fields = {
        appid,
        order_no,
        merchant_order_no,
        amount,
        status,
        paid_at,
        timestamp: Math.floor(now / 1000)
      };
      const sign = await merchantSignature("notify", fields, job.appkey);
      const res = await fetch(url, {
        method: "POST",
        redirect: "manual",
        headers: {
          "Content-Type": "application/json"
        },
        body: JSON.stringify({
          ...fields,
          sign
        }),
        signal: AbortSignal.timeout(4000)
      });
      const reader = res.body?.getReader();
      const decoder = new TextDecoder();
      let body = "";
      try {
        while (reader && body.length < 1024) {
          const part = await reader.read();
          if (part.done) break;
          body += decoder.decode(part.value, { stream: true });
        }
        body += decoder.decode();
      } finally {
        await reader?.cancel();
      }
      response = `HTTP ${res.status} ${body}`.trim().slice(0, 1024);
      if (!res.ok || body.trim() !== "ok") throw Error("response");
    } catch (e) {
      error = "回调未获确认";
      response ??= `请求失败: ${e instanceof Error ? e.name : "error"}`;
    }
    const attempts = job.attempts + 1;
    const state = !error ? "delivered" : attempts >= maxAttempts ? "failed" : "pending";
    const nextAttemptAt = Date.now() + (state === "pending" ? attempts * retryStepMs : 0);
    await db.prepare("UPDATE notification_jobs SET next_attempt_at=?,attempts=?,status=?,last_error=?,last_response=? WHERE order_id=? AND attempts=? AND next_attempt_at=?")
      .bind(nextAttemptAt, attempts, state, error, response, job.order_id, job.attempts, lease).run();
  }));
}
