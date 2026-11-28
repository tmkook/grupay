# Grupay 商户对接

使用租户提供的 HTTPS 基址、产品编码和商户凭据。商户服务端用 `appid` 标识商户、用 `appkey` 签名。下单时保存商户单号，建单成功后保存返回的平台单号，并将完整的 `cashier_url` 交给付款人。

| 操作 | 方法与路径 | 签名操作名 |
| --- | --- | --- |
| 创建订单 | `POST /api/v1/orders` | `create` |
| 查询订单 | `GET /api/v1/orders/{平台单号}` | `query` |
| 接收通知 | 平台向本单的 `notify_url` 发送 POST | `notify` |

## 创建订单

发送 UTF-8 JSON 对象，设置 `Content-Type: application/json`。请求体上限为 16 KiB，仅接受下表字段，且每个字段只可出现一次。

| 字段 | 要求 |
| --- | --- |
| `appid`、`order_no` | 必填字符串，各为 1–256 字符。这里的 `order_no` 是商户生成的订单号，在该商户下唯一 |
| `product_code` | 已启用的产品编码，字符串 |
| `amount` | 金额，单位为元，必须是大于零的 JSON 安全整数 |
| `notify_url` | 可选的 HTTP 或 HTTPS 回调地址，须无用户凭据和 URL 片段。省略时可主动查询结果 |
| `timestamp`、`sign` | 当前 Unix 秒（整数，允许偏差 300 秒）及本次操作的签名（字符串） |

下面的固定请求可配合测试密钥 `demo-key` 核对签名。实际下单使用当前时间、商户凭据和实际产品编码。

```json
{
  "appid": "demo",
  "order_no": "M1",
  "product_code": "example_product",
  "amount": 10,
  "timestamp": 1700000000,
  "sign": "-3NGS9S6FLqQiOh7yGtS-A"
}
```

首次创建返回 HTTP 201。响应包含 `order_no`（平台单号）、`merchant_order_no`（商户单号）、`product_code`、`amount`、`status` 和 `cashier_url`。网络超时后，沿用原商户单号、产品、金额和回调地址，用新时间戳重新签名。重复提交成功返回 HTTP 200 和同一笔订单。

## 签名

1. 从本次操作的字段中排除 `sign`、`null` 和空字符串，保留数字 0。按字段名 ASCII 升序排列，整数用十进制表示。
2. 将值按 UTF-8 做 RFC 3986 百分号编码，保留字母、数字和 `-._~`。空格编码为 `%20`，十六进制用大写。将各项写作 `key=value` 并用 `&` 连接。
3. 待签文本由操作名、一个 LF 换行和参数串组成，末尾无换行。使用 UTF-8 编码的 `appkey` 对待签文本的 UTF-8 字节计算 HMAC-SHA256。取前 16 个原始字节作无填充 Base64URL 编码，得到 22 字符的签名。

上例的待签文本为

```text
create
amount=10&appid=demo&order_no=M1&product_code=example_product&timestamp=1700000000
```

## 查询和订单状态

查询串只传 `appid`、`timestamp` 和 `sign`。签名时用 `query`，将路径中的**平台单号**以字段名 `order_no` 一并签入。成功返回 HTTP 200，响应字段同建单，有失败原因时附带 `fail_reason`。

| 状态 | 商户应如何理解 |
| --- | --- |
| `created` | 已受理，等待付款人打开收银台或等待可用设备。默认有效期自建单起为 10 分钟。一直未打开收银台的订单到期转为 `failed`，仅可查询结果 |
| `assigned`、`placing` | 设备已获分配或正在建单 |
| `placed` | 已生成付款链接，待支付 |
| `expired` | 支付超时，仍在复查。收银台可手动打开已有付款链接，最终以查询或通知为准 |
| `paid`、`failed` | 支付成功，或建单失败、复查结束仍未支付 |

## 接收通知

已登记 `notify_url` 的订单在 `paid`、`expired` 或 `failed` 时可收到 JSON 通知，未打开收银台即到期的订单除外。字段为 `appid`、`merchant_order_no`、`order_no`、`amount`、`status`、`paid_at`、`timestamp` 和 `sign`。`paid_at` 是 Unix **毫秒**，未付款时为 `null`，签名时省略。`timestamp` 是投递时的 Unix **秒**。

核对商户标识与时间戳（允许偏差 300 秒），用 `notify` 重算签名，以固定时间比较。验签通过后，在同一事务核对两个单号与金额，按平台单号幂等入账。处理 `expired` 后仍须接受后续的 `paid` 或 `failed`，已入账订单应忽略迟到的超时通知。

成功处理和重复通知均返回 HTTP 2xx 和纯文本 `ok`。平台不跟随重定向。未获确认时最多投递 50 次（含首次），每次重新签名，第 n 次失败后等待 n × 5 秒。

## 错误与联调

| HTTP / `code` | 处理 |
| --- | --- |
| 400 / `invalid_parameters`、`invalid_product` | 核对字段、类型、回调地址及产品是否已启用 |
| 401 / `invalid_signature`、`timestamp_expired` | 核对商户凭据、操作名、签名编码或当前 Unix 秒 |
| 403 / `merchant_route_unavailable` | 联系租户核对商户及订单创建情况 |
| 404 / `order_not_found` | 使用原商户凭据和平台单号查询 |
| 409 / `order_conflict` | 同一商户单号的产品、金额或回调地址与原单不同 |

在当前租户的 `/tools` 中，「生成请求」可预览已签名 JSON，「发送请求」会创建真实订单。勾选「记住参数」会将商户密钥保存在当前浏览器，取消勾选会清除保存的参数。
