# Grupay

Grupay 包含 Flutter 客户端和 Cloudflare Worker。商户建单后，付款人首次打开收银台才触发派单。Durable Object 管理设备与收银台连接，D1 保存订单、资金流水和回调任务。商户接口、签名示例和联调入口见[商户对接文档](docs/06-merchant.md)。

## 本地开发

服务端需要 Node.js 22.12.0 或更高版本。在项目根目录运行以下命令，初始化本地 D1 并启动 Worker。

```sh
cd server
npm ci
npx wrangler d1 migrations apply DB --local
npm run dev
```

访问开发服务的 `/api/health`，返回 `{"status":"ok"}` 表示 Worker 能读取 D1 的产品表。在 `server/` 运行 `npm run typecheck` 和 `npm test`。集成测试使用独立的本地 D1 和 Durable Object。

客户端需要包含 Dart 3.13.7 或兼容 3.x 版本的 Flutter SDK。在项目根目录运行以下命令。

```sh
cd client
flutter pub get
flutter analyze
flutter test
flutter run
```

App 登录地址为 `wss://<租户域名>/ws`。新库预置产品 `8888`、商户「部署验收」及演示账号 `demo`（初始密码 `123456`，余额 100000 元）。生产部署前请替换或停用演示凭据。

## 部署与排查

1. 每个租户使用独立的 Worker 和 D1。在 Wrangler 配置中设置 `name`、`routes[].pattern` 及 `d1_databases` 的库名和 ID。代码使用绑定 `DB` 和 `DEVICE_SESSIONS`。[Wrangler 配置](server/wrangler.jsonc)
2. 设置客服、最低客户端版本、收银台路径及订单有效期。默认有效期从商户建单起算，为 10 分钟。[运行配置](server/src/config.ts)
3. 在 `server/` 执行 `npx wrangler deploy --dry-run` 验证打包。全新远程库先执行 `npx wrangler d1 migrations apply DB --remote`，再用 `npm run deploy` 发布。上线后访问租户的 `/api/health`，用 `npx wrangler tail` 查看日志。

排查单笔订单时，用平台单号查询 `orders`，再用其主键 `id` 查询 `order_events` 的状态记录、`wallet_logs` 的资金流水和 `notification_jobs` 的回调结果。派单会冻结设备所属账号的余额，生成付款链接后扣款，支付超时后退款，超时单确认已支付时再扣款。以上变动与订单状态在同一事务内写入，统计按北京时间的派单日期归属。[数据库初始化 SQL](server/migrations/0001_init.sql) · [统计查询](server/src/services/orders.ts)

### 设备派单配置

设备可在 App 的「设置 → 接单设置」中修改接单状态、权重、日限额和未完成上限，新设备默认开启接单。管理员也可在 D1 按设备号调整，以下示例将一台设备的权重设为 5，日限额设为 1000 元，未完成上限设为 3 笔。

```sql
UPDATE devices SET weight = 5, daily_limit = 1000, pending_limit = 3, updated_at = unixepoch() * 1000
WHERE serial = '替换为设备号'
RETURNING serial, weight, daily_limit, pending_limit;
```

- `weight` 为非负整数，默认 1。候选设备先比较连续失败次数，次数相同时权重高的优先，权重相同再按距离、上次派单设备、设备 ID 排序。权重为 0 的设备仍可接单。
- `daily_limit` 为非负整数，单位为元，默认 0 表示不限。按北京时间派单日期累计该设备所有产品的金额。派单时占用额度，已支付订单计入当日总额，过期补查期间保留占用，失败或改派后释放。剩余额度恰好等于订单金额时可以接单。
- `pending_limit` 为非负整数，默认 5，0 表示不限。统计该设备 `assigned`、`placing`、`placed` 三种状态的订单数，达到上限后跳过该设备，避免单台设备积压过多待支付订单。
- 派单按设备串行：同一设备同时只允许一笔 `assigned/placing` 建单，不同设备之间并行处理。全局唯一索引 `device_active_placement` 保证这一约束。

设备详情显示最近一次认证连接和判定离线的北京时间。心跳只续期会话；同一设备接管连接时，旧连接迟到的关闭通知会被忽略。

### 已有 D1 库升级

表、索引和触发器的变更统一维护在 `server/migrations/0001_init.sql`。Wrangler 会跳过已应用的初始化文件，升级旧库时按该库实际结构同步差异。

- 上线设备连接时间记录前，按初始化 SQL 为旧库 `devices` 增加可空整数列 `connected_at`、`disconnected_at`。从下一次相应事件开始记录，历史心跳时间保留在旧库原列。
- 发布带设备日限额的 Worker 前，按初始化 SQL 的列定义给旧库 `devices` 表补齐 `weight`、`daily_limit` 和 `pending_limit`。已有设备使用相同默认值。
- 改为按设备并行派单前，删除旧索引 `DROP INDEX IF EXISTS single_active_placement;`，再执行初始化 SQL 中的 `device_active_placement`，否则全局仍只允许一笔在途建单。
- 启用 Telegram 管理前，同步初始化 SQL 中的 `telegram_admins`、其唯一索引和 `telegram_admin_updates` 表，分别保存管理员记录和写指令的操作记录。
- 从使用 `settings` 的版本升级时，先把原客服、最低版本、收银台地址和时间参数迁入运行配置。旧服务停用后，可清理 `settings` 表及旧列 `devices.cooldown_until`、`devices.reset_minutes`、`orders.head_since`。
- 从旧设备降权策略升级时，在同一个 D1 batch 中执行初始化 SQL 内 `order_transition` 的完整 DROP 和 CREATE 语句，避免重复累计设备失败次数。
- 旧库若仅接受绝对 HTTPS 脚本地址，内置产品可先使用当前租户的完整地址。改用本站 `/scripts/` 相对路径时，同步初始化 SQL 中 `products.script` 的约束。
- 设备会话服务首次升级时，对缺少截止时间的 `created`、`assigned`、`placing` 订单按原创建时间加有效期补齐，成功后记录完成标记。
- 同步初始化 SQL 的 `assigned_attempted_devices` 和 `paid_trade_no` 部分索引后，可删除旧的 `attempted_devices` 索引。设备派单排重只查询派单事件，支付流水排重只查询已支付订单。

## Telegram 管理机器人

在私聊中输入 `/start` 打开管理菜单，`/id` 查看自己的数字用户 ID。每个管理菜单显示最近五条记录、翻页命令和该项的操作用法。

| 菜单 | 操作 |
| --- | --- |
| 商户管理 | 列表、详情、通过 `/merchant_add 商户名称` 新建商户并自动生成 AppID 和 AppKey、查看签名密钥、启停商户 |
| 设备管理 | 列表、查看上线和接单状态、调整权重和日限额 |
| 订单管理 | 列表、按 ID 或平台单号查看详情和最近事件、将已失败的商户回调重新入队 |
| 账号管理 | 列表、查看余额和冻结金额、新建账号、启停账号、增减可用余额、通过 `/account_reset 账号ID 新密码` 重置登录密码 |

在租户 D1 中生成管理员记录，将返回的密钥私下交给对应管理员。

```sql
INSERT INTO telegram_admins (bind_key)
VALUES ('GP-' || lower(hex(randomblob(24))))
RETURNING id, bind_key;
```

管理员在机器人私聊中直接发送完整密钥。只有记录的 `telegram_id` 为空时，机器人才会填入当前私聊的 ID，并清除已用密钥。已绑定的管理员可以直接打开菜单。

在 D1 执行 `SELECT id, telegram_id FROM telegram_admins` 查看绑定情况。按记录编号执行 `DELETE FROM telegram_admins WHERE id = ?` 可作废待绑定密钥或撤销已绑定管理员的权限。

为 Worker Secret `TELEGRAM_WEBHOOK_SECRET` 设置独立随机值。用机器人 Token 调用 Telegram 的 `setWebhook`，将 `url` 设置为租户 HTTPS 地址的 `/api/telegram/webhook`，`secret_token` 与 Worker 中的随机值一致，`allowed_updates` 设为 `["message"]`。用 `getWebhookInfo` 核对注册地址。Worker 在 webhook 响应内回复私聊消息。[Telegram Webhook 文档](https://core.telegram.org/bots/api#setwebhook)

## Android 单架构发布

在 `client/android/key.properties` 中配置原发布密钥的 `storeFile`、`storePassword`、`keyAlias`、`keyPassword`。在 `client/` 只构建 ARM64 发布包，并读取 APK 的实际版本和校验值。

```sh
flutter build apk --release --split-per-abi --target-platform android-arm64
apk=build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
aapt dump badging "$apk"
shasum -a 256 "$apk"
```

本机验收时，用 `adb devices` 确认设备序列号，再用 `adb -s <序列号> install -r "$apk"` 覆盖安装并保留应用数据。

按包内 `versionName` 和 `versionCode` 命名文件为 `server/public/releases/grupay-<版本>+<版本码>.apk`。拆包会调整版本码。保留旧包，在运行配置中同步 `releaseVersion`、`releaseBuild` 和 `releaseSha256`，随 Worker 发布。租户的 `/release` 提供当前下载，`/releases/latest.json` 供 App 检查更新。
