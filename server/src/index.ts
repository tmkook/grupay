import serverConfig from "./config";
import { geoFromCf } from "./geo";
import { merchantOrders } from "./routes/merchant";
import { telegramWebhook } from "./routes/telegram";
import type { Env } from "./types/env";
export { DeviceSessions } from "./ws/device-session";

const releasePath = `/releases/grupay-${serverConfig.releaseVersion}+${serverConfig.releaseBuild}.apk`;
const noStore = { "Cache-Control": "no-store" };

const worker: ExportedHandler<Env> = {
  async scheduled(_event, env) {
    await env.DEVICE_SESSIONS.getByName("devices").fetch("https://internal/internal/wake");
  },
  async fetch(request, env) {
    const url = new URL(request.url);
    const { pathname } = url;
    if (pathname === "/api/telegram/webhook") return telegramWebhook(request, env);
    const canDownload = request.method === "GET" || request.method === "HEAD";
    if (request.method === "GET" && pathname === "/releases/latest.json") {
      return Response.json({
        version: serverConfig.releaseVersion,
        build: serverConfig.releaseBuild,
        sha256: serverConfig.releaseSha256,
        url: new URL(releasePath, url).href
      }, { headers: noStore });
    }
    if (canDownload && pathname === "/release") {
      return new Response(null, { status: 302, headers: { ...noStore, Location: releasePath } });
    }
    // Android's downloader accepts a direct 200. Static Assets canonicalizes "+" to "%2B".
    if (canDownload && /^\/releases\/grupay-\d+\.\d+\.\d+(?:\+|%2b)\d+\.apk$/i.test(pathname)) {
      url.pathname = pathname.replace(/\+|%2b/i, "%2B");
      return env.ASSETS.fetch(new Request(url, request));
    }
    const merchantRoute = /^\/api\/v1\/orders(?:\/([^/]+))?$/.exec(pathname);
    if (merchantRoute) return merchantOrders(request, env.DB, merchantRoute[1] ?? "");
    if (pathname === "/ws" && request.method === "GET") {
      // Durable Object 内读不到请求的 cf 字段，用请求头把城市级位置转交过去。
      const headers = new Headers(request.headers);
      headers.set("x-grupay-geo", JSON.stringify(geoFromCf(request.cf)));
      return env.DEVICE_SESSIONS.getByName("devices").fetch(new Request(request, { headers }));
    }
    if (pathname !== "/api/health") {
      return new Response("Not found", { status: 404 });
    }
    if (request.method !== "GET") {
      return new Response(null, { status: 405, headers: { Allow: "GET" } });
    }
    try {
      await env.DB.prepare("SELECT code FROM products LIMIT 1").first();
      return Response.json({ status: "ok" }, { headers: noStore });
    } catch {
      return Response.json({ status: "unavailable" }, { status: 503, headers: noStore });
    }
  }
};
export default worker;
