CREATE TABLE users (
  id INTEGER PRIMARY KEY,
  username TEXT NOT NULL UNIQUE,
  password TEXT NOT NULL CHECK(length(password) = 32 AND password NOT GLOB '*[^0-9a-f]*'),
  nickname TEXT,
  balance INTEGER NOT NULL DEFAULT 0,
  frozen INTEGER NOT NULL DEFAULT 0 CHECK (frozen BETWEEN 0 AND balance),
  status INTEGER NOT NULL DEFAULT 1 CHECK (status IN (0, 1)),
  last_login_at INTEGER,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);

CREATE TABLE products (
  code TEXT PRIMARY KEY NOT NULL CHECK(length(code) BETWEEN 1 AND 64 AND code NOT GLOB '*[^a-zA-Z0-9_-]*'),
  name TEXT NOT NULL CHECK(length(trim(name)) > 0),
  url TEXT NOT NULL CHECK(url LIKE 'https://%'),
  script TEXT NOT NULL CHECK(script LIKE 'https://%' OR script GLOB '/scripts/?*'),
  enabled INTEGER NOT NULL DEFAULT 1 CHECK(enabled IN (0,1))
);

CREATE TABLE devices (
  id INTEGER PRIMARY KEY,
  user_id INTEGER NOT NULL REFERENCES users(id),
  serial TEXT NOT NULL UNIQUE,
  model TEXT NOT NULL,
  version TEXT NOT NULL,
  target TEXT NOT NULL,
  account TEXT,
  city TEXT,
  region TEXT,
  lat REAL,
  lon REAL,
  geo_at INTEGER,
  online INTEGER NOT NULL DEFAULT 0 CHECK (online IN (0, 1)),
  ready INTEGER NOT NULL DEFAULT 0 CHECK (ready IN (0, 1)),
  status INTEGER NOT NULL DEFAULT 1 CHECK (status IN (0, 1)),
  consecutive_failures INTEGER NOT NULL DEFAULT 0,
  weight INTEGER NOT NULL DEFAULT 1 CHECK (typeof(weight) = 'integer' AND weight >= 0),
  daily_limit INTEGER NOT NULL DEFAULT 0 CHECK (typeof(daily_limit) = 'integer' AND daily_limit >= 0),
  pending_limit INTEGER NOT NULL DEFAULT 5 CHECK (typeof(pending_limit) = 'integer' AND pending_limit >= 0),
  product_code TEXT,
  connected_at INTEGER,
  disconnected_at INTEGER,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
CREATE INDEX device_product_route ON devices(product_code,ready,status,online);

CREATE TABLE merchants (
  id INTEGER PRIMARY KEY,
  appid TEXT NOT NULL UNIQUE,
  appkey TEXT NOT NULL,
  name TEXT NOT NULL,
  description TEXT,
  status INTEGER NOT NULL DEFAULT 1 CHECK(status IN (0,1)),
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);

CREATE TABLE orders (
  id INTEGER PRIMARY KEY,
  order_no TEXT NOT NULL UNIQUE,
  merchant_order_no TEXT NOT NULL,
  merchant_id INTEGER NOT NULL REFERENCES merchants(id),
  user_id INTEGER REFERENCES users(id),
  device_id INTEGER REFERENCES devices(id),
  amount INTEGER NOT NULL CHECK(typeof(amount) = 'integer' AND amount > 0),
  status TEXT NOT NULL DEFAULT 'created' CHECK(status IN ('created','assigned','placing','placed','paid','expired','failed')),
  attempt_count INTEGER NOT NULL DEFAULT 0,
  query_count INTEGER NOT NULL DEFAULT 0,
  revision INTEGER NOT NULL DEFAULT 1,
  product_code TEXT NOT NULL,
  notify_url TEXT,
  pay_url TEXT,
  trade_no TEXT,
  fail_reason TEXT,
  assigned_at INTEGER,
  accepted_at INTEGER,
  placed_at INTEGER,
  deadline_at INTEGER,
  dispatch_at INTEGER NOT NULL DEFAULT 0,
  payer_city TEXT,
  payer_region TEXT,
  payer_lat REAL,
  payer_lon REAL,
  payer_geo_at INTEGER,
  paid_at INTEGER,
  expired_at INTEGER,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  UNIQUE(merchant_id,merchant_order_no)
);
CREATE INDEX order_queue ON orders(status,created_at,id);
CREATE UNIQUE INDEX device_active_placement ON orders(device_id) WHERE status IN ('assigned','placing');
CREATE INDEX device_order_stats ON orders(device_id,assigned_at);
CREATE INDEX payment_deadlines ON orders(status,deadline_at);
CREATE INDEX paid_trade_no ON orders(trade_no) WHERE status='paid' AND trade_no IS NOT NULL;
CREATE INDEX account_orders ON orders(user_id,id);
CREATE INDEX account_order_stats ON orders(user_id, assigned_at);

CREATE TABLE order_events (
  id INTEGER PRIMARY KEY,
  order_id INTEGER NOT NULL REFERENCES orders(id),
  from_status TEXT,
  to_status TEXT NOT NULL,
  source TEXT NOT NULL,
  message TEXT,
  device_id INTEGER REFERENCES devices(id),
  attempt INTEGER,
  created_at INTEGER NOT NULL
);
CREATE INDEX events_by_order ON order_events(order_id,created_at);
CREATE INDEX assigned_attempted_devices ON order_events(order_id,device_id) WHERE to_status='assigned';

CREATE TABLE wallet_logs (
  id INTEGER PRIMARY KEY,
  user_id INTEGER NOT NULL REFERENCES users(id),
  order_id INTEGER NOT NULL REFERENCES orders(id),
  attempt INTEGER NOT NULL,
  type TEXT NOT NULL,
  amount INTEGER NOT NULL,
  balance_after INTEGER NOT NULL,
  frozen_after INTEGER NOT NULL,
  created_at INTEGER NOT NULL,
  UNIQUE(order_id,attempt,type)
);

CREATE TABLE notification_jobs (
  order_id INTEGER PRIMARY KEY REFERENCES orders(id),
  next_attempt_at INTEGER NOT NULL,
  attempts INTEGER NOT NULL DEFAULT 0,
  status TEXT NOT NULL DEFAULT 'pending',
  last_error TEXT,
  last_response TEXT
);
CREATE INDEX notification_due ON notification_jobs(status,next_attempt_at);

CREATE TABLE telegram_admin_updates (
  update_id INTEGER PRIMARY KEY,
  admin_id INTEGER NOT NULL,
  action TEXT NOT NULL,
  target TEXT NOT NULL,
  applied INTEGER NOT NULL CHECK (applied IN (0,1)),
  created_at INTEGER NOT NULL
);

CREATE TABLE telegram_admins (
  id INTEGER PRIMARY KEY CHECK (id > 0),
  created_at INTEGER NOT NULL DEFAULT (unixepoch() * 1000),
  telegram_id INTEGER CHECK (telegram_id > 0),
  bind_key TEXT
);
CREATE UNIQUE INDEX telegram_admin_identity ON telegram_admins(telegram_id);
CREATE UNIQUE INDEX telegram_admin_key ON telegram_admins(bind_key);

CREATE TRIGGER order_created_event AFTER INSERT ON orders BEGIN
  INSERT INTO order_events(order_id,to_status,source,created_at)
  VALUES(NEW.id,NEW.status,'merchant',NEW.created_at);
END;

DROP TRIGGER IF EXISTS order_transition;
CREATE TRIGGER order_transition AFTER UPDATE OF status ON orders WHEN OLD.status<>NEW.status BEGIN
 INSERT INTO order_events(order_id,from_status,to_status,source,message,created_at,device_id,attempt)
 VALUES(NEW.id,OLD.status,NEW.status,'server',NEW.fail_reason,NEW.updated_at,COALESCE(NEW.device_id,OLD.device_id),NEW.attempt_count);
 INSERT INTO notification_jobs(order_id,next_attempt_at)
 SELECT NEW.id,NEW.updated_at WHERE NEW.status IN ('paid','expired','failed') AND NEW.notify_url IS NOT NULL
 ON CONFLICT(order_id) DO UPDATE SET next_attempt_at=excluded.next_attempt_at,
 attempts=0,status='pending',last_error=NULL;

 UPDATE users SET frozen=frozen+NEW.amount,updated_at=NEW.updated_at WHERE id=NEW.user_id AND NEW.status='assigned';
 UPDATE users SET frozen=frozen-OLD.amount,updated_at=NEW.updated_at WHERE id=OLD.user_id AND OLD.status IN ('assigned','placing') AND NEW.status IN ('created','failed','placed');
 UPDATE users SET balance=balance-OLD.amount,updated_at=NEW.updated_at WHERE id=OLD.user_id AND NEW.status='placed';
 UPDATE users SET balance=balance-OLD.amount,updated_at=NEW.updated_at
 WHERE id=OLD.user_id AND OLD.status='expired' AND NEW.status='paid';
 INSERT INTO wallet_logs(user_id,order_id,attempt,type,amount,balance_after,frozen_after,created_at)
 SELECT id,NEW.id,NEW.attempt_count,'late_settle',-NEW.amount,balance,frozen,NEW.updated_at
 FROM users WHERE id=OLD.user_id AND OLD.status='expired' AND NEW.status='paid';
 UPDATE users SET balance=balance+OLD.amount,updated_at=NEW.updated_at WHERE id=OLD.user_id AND NEW.status='expired';
 INSERT INTO wallet_logs(user_id,order_id,attempt,type,amount,balance_after,frozen_after,created_at)
 SELECT id,NEW.id,NEW.attempt_count,
 CASE NEW.status WHEN 'assigned' THEN 'freeze' WHEN 'placed' THEN 'settle' WHEN 'expired' THEN 'refund' ELSE 'unfreeze' END,
 CASE WHEN NEW.status IN ('assigned','expired') THEN NEW.amount ELSE -NEW.amount END,balance,frozen,NEW.updated_at
 FROM users WHERE id=COALESCE(NEW.user_id,OLD.user_id) AND (NEW.status IN ('assigned','placed','expired') OR (OLD.status IN ('assigned','placing') AND NEW.status IN ('created','failed')));
 UPDATE devices SET consecutive_failures=0 WHERE id=NEW.device_id AND NEW.status='placed';
END;

INSERT INTO products(code,name,url,script) VALUES
  ('8888','抖音充值','https://www.douyin.com/pay','/scripts/douyin-v1.js');

INSERT INTO users(id,username,password,nickname,balance,created_at,updated_at) VALUES
  (2,'demo','e10adc3949ba59abbe56e057f20f883e','demo',100000,1795493235000,1795493235000);

INSERT INTO merchants(id,appid,appkey,name,created_at,updated_at) VALUES
  (1,'smokedfc84c655a1eeed0','483f45a81a6bc1bee62be04fde99223a50342a922f47b496','部署验收',1795475801229,1795475801229);
