export interface Env {
  DEVICE_SESSIONS: DurableObjectNamespace;
  ASSETS: Fetcher;
  DB: D1Database;
  TELEGRAM_WEBHOOK_SECRET?: string;
}
