# liuhuo23/clickhouse-driver

[English](README.md) | [简体中文](README.zh-CN.md)

MoonBit 实现的 ClickHouse **HTTP** 协议驱动——简单、无状态，当前在 Linux / macOS 上验证。

## 概览

- 使用 ClickHouse 原生 HTTP 接口（默认端口 **8123**）
- 响应以 **TabSeparatedWithNamesAndTypes** 解析，列名和类型自动返回，客户端无需手动类型映射
- **批量插入**：`insert()` 将行数据（TSV 或 JSONEachRow）作为 HTTP 请求体流式发送，不再把 VALUES 字面量内联进 SQL
- **流式读取**：`execute_stream()` 返回逐行游标，大结果集无需整体载入内存
- **TLS**：`https=true` 走 TLS 连接；`skip_verify=true` 可跳过证书校验（自签名场景）
- **请求超时**：`timeout_ms` 约束每个请求（以及流式 `next()`），超时抛 `ConnectionError`
- **响应压缩**：`compress=true` 请求 ClickHouse LZ4 压缩（`compress=1`），驱动自动解压
- **连接池**：`conn.pool(size)` 复用 keep-alive 连接，避免重复 TCP/TLS 握手
- 两种参数绑定方式，均基于 ClickHouse 原生 `{name: Type}` 占位符协议：
  - `execute_query(sql, params?)` — **命名**绑定，使用 `{name}` / `{name: Type}`。
    无类型 `{name}` 默认为 `String`，所以表名、标识符、字符串列名书写更自然。
  - `execute(sql, values)` — **位置**绑定，使用 `?`。当同一参数形状在多行重复出现时（典型场景是内联 VALUES INSERT）写法最简洁——不需要为每行发明不重复的名字。
  参数以 `param_<key>=<value>` URL 参数形式传入，由服务端（自动加引号、转义）替换
- 通过 MoonBit `try-catch` 进行错误处理，定义了 `DbError` suberror（`ServerError` / `ConnectionError`）
- 默认每次请求新建一条连接——无持久状态可泄漏；高 QPS 场景可用 `conn.pool(size)` 复用 keep-alive 连接
- 兼容 ClickHouse 22.x+（HTTP 接口自 21.x 起稳定）

## 平台支持

| 平台 | 状态 |
| ---- | ---- |
| Linux | ✅ 支持 |
| macOS | ✅ 支持 |
| Windows | ❌ 暂未验证（依赖 `moonbitlang/async` native 后端） |

当前 CI 仅在 Linux / macOS 上运行 `moon check` 与 `moon test`。Windows 支持就绪后，可在 `.github/workflows/check.yml` 的 matrix 中加入 `windows-latest`。

## 安装

在 `moon.mod` 中添加依赖：

```text
import {
  "moonbitlang/async@0.20.1",
}
```

在包的 `moon.pkg` 中添加：

```text
import {
  "moonbitlang/async/http",
  "moonbitlang/core/buffer",
  "moonbitlang/core/encoding/base64",
  "moonbitlang/core/encoding/utf8",
  "liuhuo23/clickhouse-driver" @lib,
}
```

## 快速开始

```moonbit nocheck
///|
async fn main {
  let conn = @lib.connect(
    host="127.0.0.1",
    port=8123,
    user="default",
    password="",
    database="default",
    client_name="my-app",
  )
  defer conn.close()

  // 1. 健康检查
  conn.ping()

  // 2. SELECT —— 列名和类型自动返回。无类型占位符默认为 String，
  //    所以表名 / 字符串值无需标注类型。
  let result = conn.execute_query(
    "SELECT id, name FROM users WHERE created_at > {lo: DateTime} LIMIT {n: UInt32}",
    params=Map::from_array([
      ("lo", "2024-01-01 00:00:00"),
      ("n", "10"),
    ]),
  )

  // 3. 查看列信息
  for col in result.columns {
    println(col.name + " : " + col.type_)
  }

  // 4. 遍历行（每格为字符串）
  for row in result.rows {
    println(row.values)
  }

  // 5. 或转换为行 Map（按列名索引）
  for m in result.to_map() {
    println(m["name"])
  }

  // 6. INSERT —— 与其他数据库驱动一样，使用 `?` 占位符
  ignore(
    conn.execute(
      "INSERT INTO users (id, name) VALUES (?, ?), (?, ?)",
      ["1", "alice", "2", "bob"],
    ),
  )
}
```

## 原生协议（TCP）驱动

除 HTTP 接口外，本项目还附带一个实验性的 **ClickHouse 原生 TCP 协议**
驱动（端口 **9000**），位于 `native/` 子包，与 `clickhouse-client` 使用
相同的二进制协议：

- **持久连接**：一次握手、多次查询复用同一 TCP 连接（天然适合 keep-alive
  复用与连接池）。
- **二进制传输**：无文本往返开销，值按原生列编码解码，类型信息精确。
- **API 对齐**：复用根包的 `DbError` / `ResultSet` / `Column` / `Row` 类型，
  调用方迁移成本极低。

当前能力：连接 + 握手、按操作生效的 `timeout_ms`、`ping`、`execute_query` / `execute`（命名 `{name: Type}`
与位置 `?` 参数绑定）、`execute_stream`（惰性逐块游标）、`insert`（批量 Data
块上传）与 `cancel`，类型支持丰富：UInt8–64、Int8–64、Float32/64、String、
FixedString、Date、Date32、DateTime、DateTime64、Enum8/16、Nullable、Array
（可嵌套）、Tuple、Map、Decimal32/64/128/256、UUID、IPv4、IPv6（LowCardinality
由服务器端解包）、**LZ4 压缩**（Data 块，`compress=true`）与**连接池**
（acquire/release，`config.pool(size)`）；服务器异常映射、优雅关闭。
TLS 列入后续阶段。

### 快速开始

```moonbit nocheck
///|
async fn main {
  let conn = @native.connect(
    @native.native_config(
      host="127.0.0.1",
      port=9000,
      user="default",
      password="",
      database="default",
      client_name="my-app",
    ),
  )
  defer conn.close()

  conn.ping()

  let rs = conn.execute_query("SELECT 1 AS one")
  println(rs.rows[0].values[0]) // 1
}
```

在 `moon.pkg` 中引入子包：

```text
import {
  "liuhuo23/clickhouse-driver/native" @native,
}
```

### 与 HTTP 版的差异

- `@native.connect(config)` **真实建连**（含握手）；HTTP 版的 `connect`
  只是纯配置。
- 单连接串行执行查询——不要在同一个 `NativeConnection` 上并发读取。
- 错误语义一致：认证/语法错误抛 `DbError::ServerError(code, name, message)`；
  IO 与协议错误抛 `DbError::ConnectionError`。

### 示例

```bash
CLICKHOUSE_NATIVE=1 CLICKHOUSE_NATIVE_PORT=9000 moon run cmd/main
```

完整设计与分阶段实施计划（P0–P4）见 `docs/native-protocol-design.md`。
## API 参考

### `connect`

```moonbit nocheck
pub fn connect(
  host~ : String,
  port~ : Int,
  user~ : String,
  password~ : String,
  database~ : String,
  client_name~ : String,
  timeout_ms? : Int = 0,
  https? : Bool = false,
  skip_verify? : Bool = false,
  compress? : Bool = false,
) -> Connection
```

根据显式参数构造 `Connection` 配置。**不会**建立 TCP 连接——默认情况下调用是无状态的，每次请求都会建立新的 HTTP 连接。所有新选项均为可选，旧调用方式保持不变。需要复用连接时可用 `conn.pool(size)`（见[连接池](#连接池)）。

| 参数          | 类型     | 说明                                        |
| ------------- | -------- | ------------------------------------------- |
| `host`        | `String` | 服务器主机名或 IP                           |
| `port`        | `Int`    | HTTP 端口（默认 8123）                      |
| `user`        | `String` | 用户名                                      |
| `password`    | `String` | 密码                                        |
| `database`    | `String` | 默认数据库                                  |
| `client_name` | `String` | 通过 `X-ClickHouse-Client-Name` header 发送 |
| `timeout_ms`  | `Int`    | 单请求超时（毫秒）；`0` = 不超时             |
| `https`       | `Bool`   | 使用 TLS（`https://`）；默认 `false`        |
| `skip_verify` | `Bool`   | 跳过 TLS 证书校验；默认 `false`             |
| `compress`    | `Bool`   | 请求 ClickHouse LZ4 压缩；默认 `false`      |

### `Connection`

```moonbit nocheck
pub struct Connection {
  host : String
  port : Int
  user : String
  password : String
  database : String
  client_name : String
  timeout_ms : Int
  https : Bool
  skip_verify : Bool
  compress : Bool
}
```

轻量级配置结构——没有持久 socket。默认每次调用都建立短生命周期 HTTP 连接并在返回时关闭。需要跨请求复用连接时见[连接池](#连接池)。

#### `Connection::ping`

```moonbit nocheck
pub async fn ping(self : Connection) -> Unit raise
```

发送 `SELECT 1` 并期待 200 OK。轻量级健康检查。

#### `Connection::execute_query`

```moonbit nocheck
pub async fn execute_query(
  self : Connection,
  sql : String,
  params? : Map[String, String] = {},
) -> ResultSet raise
```

执行任意 SQL（SELECT、DDL、内联 VALUES INSERT 等），返回解析结果。

`params` 是可选的命名参数映射。每个条目会以 `param_<key>=<value>` URL 参数形式发送，ClickHouse 在服务端将值替换进匹配的 `{key: Type}` 占位符。值会被自动加引号并转义——直接传原始字符串即可。

对于常见的字符串参数（表名、标识符、字符串列），可以省略类型——`{name}` 会被自动当作 `{name: String}` 处理。只有在需要绑定到非 String 列（数值、日期等）时，才需要使用 `{name: Type}` 显式标注。

示例：

```moonbit nocheck
// 无参数
let r = conn.execute_query("SELECT version()")

// 单个类型参数（非 String 列）
let r = conn.execute_query(
  "SELECT * FROM events WHERE id = {id: UInt64}",
  params=Map::from_array([("id", "42")]),
)

// 表名作为参数 —— 无类型 {tn} 默认为 String
let r = conn.execute_query(
  "SELECT count() FROM {tn}",
  params=Map::from_array([("tn", "events")]),
)
```

#### `Connection::execute`

```moonbit nocheck
pub async fn execute(
  self : Connection,
  sql : String,
  values : Array[String],
) -> ResultSet raise
```

使用 **位置** `?` 占位符执行 SQL。SQL 中的每个 `?` 按顺序绑定到 `values` 里的下一个值。`execute_query` 调用多行重复 SQL 时的简洁版本——不需要为每行发明不重复的名字。

所有值按 `String` 绑定；ClickHouse 在服务端把字符串强制转换为目标列类型（数值、日期等常见标量类型都能用）。如果某列无法隐式转换（例如罕见的参数化类型），回退到 `execute_query` 并使用 `{name: Type}` 显式标注。

示例：

```moonbit nocheck
// 多行 INSERT —— 同一参数形状在每行重复
ignore(conn.execute(
  "INSERT INTO events (id, ts, msg) VALUES (?, ?, ?), (?, ?, ?)",
  ["1", "2024-01-01 00:00:00", "hello",
   "2", "2024-01-02 00:00:00", "world"],
))

// 单行位置绑定
ignore(conn.execute(
  "INSERT INTO events (id, name) VALUES (?, ?)",
  ["42", "alice"],
))
```

抛出：
- `DbError::ServerError(code, name, message)` — 服务端返回非 2xx HTTP 响应（语法错误、表不存在、权限被拒等）
- `DbError::ConnectionError(String)` — 网络 / I/O 错误



#### `Connection::insert`

```moonbit nocheck
pub async fn insert(
  self : Connection,
  table : String,
  columns : Array[String],
  rows : Array[Array[String]],
  format? : InsertFormat = Tsv,
) -> Unit raise
```

将批量插入的数据作为 HTTP 请求体流式发送（不再把 VALUES 字面量内联进 SQL）。body 分块流式传输，大批量插入不会撑爆 SQL 文本。`format` 可选 `Tsv`（默认，`FORMAT TSV`）或 `Ndjson`（`FORMAT JSONEachRow`，每行一个 JSON 对象）；值以文本形式发送，由 ClickHouse 自动转换类型。

```moonbit nocheck
conn.insert("users", ["id", "name"], [["1", "alice"], ["2", "bob"]])
```

#### `Connection::execute_stream`

```moonbit nocheck
pub async fn execute_stream(
  self : Connection,
  sql : String,
  params? : Map[String, String] = {},
) -> ResultSetCursor raise
```

执行查询并返回**流式游标**，响应体逐行惰性读取——适合大结果集 SELECT。`columns()` 立即可用；`next()` 逐行返回直到 `None`；务必 `close()` 释放连接。与 `compress=true` 暂不兼容。

```moonbit nocheck
let cur = conn.execute_stream("SELECT * FROM events")
defer cur.close()
while true {
  match cur.next() {
    None => break
    Some(row) => println(row.values)
  }
}
```

### 连接池

`Connection` 每个请求都会新建一条 TCP/TLS 连接。高 QPS 或远程/TLS 场景下，重复握手开销不小——`Connection::pool` 复用 keep-alive 连接：

```moonbit nocheck
let pool = conn.pool(size=4)   // 最多 4 条并发连接
defer pool.close()

pool.ping()                                    // 与 Connection 相同 API
let r = pool.execute_query("SELECT count() FROM events")
pool.insert("events", ["id", "ts"], [["1", "2024-01-01 00:00:00"]])
let cur = pool.execute_stream("SELECT * FROM events")  // 游标 close 时
defer cur.close()                                        // 归还连接
```

- `size` 限制并发连接数；超过时请求排队等待空闲连接
- 出错的连接会被丢弃重建，绝不回池复用
- 空闲超过 5s 的连接在复用前先用 `GET /ping` 探活，避免服务端已关闭的
  keep-alive 连接变成用户可见的请求失败
- `pool.execute_stream` 完全读完后归还连接；中途放弃则丢弃连接
- `pool.close()` 关闭空闲连接；使用中的连接归还时关闭

`ConnectionPool` 与 `Connection` 的 API 一一对应：

```moonbit nocheck
pub async fn ConnectionPool::ping(Self) -> Unit
pub async fn ConnectionPool::execute_query(Self, String, params? : Map[String, String]) -> ResultSet
pub async fn ConnectionPool::execute(Self, String, Array[String]) -> ResultSet
pub async fn ConnectionPool::insert(Self, String, Array[String], Array[Array[String]], format? : InsertFormat) -> Unit
pub async fn ConnectionPool::execute_stream(Self, String, params? : Map[String, String]) -> ResultSetCursor
pub fn ConnectionPool::max_size(Self) -> Int
pub fn ConnectionPool::close(Self) -> Unit
```

#### `Connection::cancel`

```moonbit nocheck
pub async fn cancel(self : Connection) -> Unit
```

HTTP 下为空操作。每个查询都是单次短生命周期请求，没有持久连接可发送 cancel 信号。保留此 API 以保持与之前 native TCP 设计的对称性。

#### `Connection::close`

```moonbit nocheck
pub fn close(self : Connection) -> Unit
```

HTTP 下为空操作。配合 `defer` 使用以保持对称：

```moonbit nocheck
let conn = @lib.connect(...)
defer conn.close()
```

### `ResultSet`

```moonbit nocheck
///|
pub struct ResultSet {
  columns : Array[Column]
  rows : Array[Row]
}
```

当响应使用 `TabSeparatedWithNamesAndTypes`（`execute_query` 默认请求）时填充 `columns`。对于 DDL / INSERT 语句，该数组为空。

#### `ResultSet::to_map`

```moonbit nocheck
pub fn to_map(self : ResultSet) -> Array[Map[String, String]]
```

将结果转换为按行映射数组。每个元素是 `Map[String, String]`，键为列名，值为该单元格的字符串表示。当 `columns` 为空时返回空数组。

```moonbit nocheck
for m in result.to_map() {
  let name = m.get_or_default("name", "")
  println(name)
}
```

### `Row`

```moonbit nocheck
///|
pub struct Row {
  values : Array[String]
}
```

单行数据。每个单元格是对应 ClickHouse 值的字符串表示（如 `"42"`、`"2025-01-01 00:00:00"`、`"NULL"`）。

### `Column`

```moonbit nocheck
///|
pub struct Column {
  name : String
  type_ : String
}
```

从 `TabSeparatedWithNamesAndTypes` 解析的列元数据。`type_` 是原始 ClickHouse 类型字符串，如 `"UInt32"`、`"String"`、`"Nullable(Int64)"`。

## 异常处理

```moonbit nocheck
try {
  conn.execute_query("SELECT * FROM no_such_table")
} catch {
  @lib.DbError::ServerError(code~, name=_, message~) =>
    println("server error: code=" + code.to_string() + " " + message)
  @lib.DbError::ConnectionError(msg) =>
    println("connection error: " + msg)
  _ => println("其他错误")
}
```

### `DbError` suberror

```moonbit nocheck
///|
pub suberror DbError {
  ServerError(code~ : Int, name~ : String, message~ : String)
  ConnectionError(String)
} derive(Show)
```

| 变体            | 字段                                     | 何时抛出                                                              |
| --------------- | ---------------------------------------- | --------------------------------------------------------------------- |
| `ServerError`   | `code : Int`, `name : String`, `message : String` | 服务端返回非 2xx HTTP 响应，body 含错误信息                |
| `ConnectionError`| `String`                                  | 网络 / I/O 错误（连接拒绝、响应格式异常等）                          |

`code` 是 HTTP 状态码（语法/未知表等客户端错误通常为 `400`，服务端错误为 `500`）。`name` 是 `"HTTPError"`。`message` 是响应体的前 500 字符（含 ClickHouse 异常文本）。

## 工作原理

驱动每次调用发起一次 HTTP 请求：

```
POST /?database=<db>&default_format=TabSeparatedWithNamesAndTypes
    &query=<url-encoded SQL>
    [&param_<key>=<url-encoded value>...]
HTTP/1.1
Host: <host>:<port>
Authorization: Basic <base64(user:password)>
X-ClickHouse-Client-Name: <client_name>
Content-Length: 0
```

不发送 `Connection: close`，因此连接可以保持存活：普通 `Connection` 每次调用后关闭 socket；`ConnectionPool` 会复用同一条连接处理后续请求。

ClickHouse 以 `TabSeparatedWithNamesAndTypes` 响应：

```
<col1>\t<col2>\t<col3>
<Type1>\t<Type2>\t<Type3>
<val1>\t<val2>\t<val3>
<val4>\t<val5>\t<val6>
...
```

驱动将其解析为 `ResultSet { columns, rows }`。

为什么用 POST？ClickHouse 的 HTTP 接口将 `GET` 请求视为 `readonly`（`For queries over HTTP, method GET implies readonly`）。POST 适用于所有查询类型——SELECT、DDL、INSERT——所以我们只用一种方法。

为什么命名参数用 URL 参数？ClickHouse 把 SQL 中的 `{key: Type}` 占位符替换为 `param_<key>=<value>` URL 参数。服务端负责加引号和类型转换，所以驱动可以直接传原始字符串而不必担心转义。

## ClickHouse 事务

**ClickHouse 不支持传统 ACID 事务。** 没有 `BEGIN` / `COMMIT` / `ROLLBACK`，也没有 `Serializable` 隔离级别。`INSERT … SELECT` 在 part 级别是原子的。对于需要版本语义的场景，请使用特殊的表引擎：

- `ReplacingMergeTree(version_column)` — 合并后保留 `version_column` 最大的行
- `CollapsingMergeTree(sign_column)` — 用 `sign` 列（`+1` 插入、`-1` 取消）合并时折叠成对的行
- `VersionedCollapsingMergeTree(version, sign)` — 类似 `CollapsingMergeTree`，但顺序无关
- `SummingMergeTree` / `AggregatingMergeTree` — 用于状态聚合模式

## 项目性质

**原创项目。** 参考 [ClickHouse HTTP 接口文档](https://clickhouse.com/docs/en/interfaces/http) 实现协议行为，未移植第三方驱动代码。早期原型探索过 Native TCP 协议，当前实现采用 HTTP 以提升可移植性与简洁性。

| 资源 | 链接 | 许可证 |
| ---- | ---- | ------ |
| ClickHouse（参考） | https://clickhouse.com/docs/en/interfaces/http | Apache-2.0 |
| 本项目 | — | Apache-2.0 |

## 局限性

1. **无法在查询中途取消** — 请求一旦发出，驱动就失去句柄。需要取消请断开连接。
2. **流式读取仅限游标** — `execute_stream()` 逐行惰性读取，但 `execute_query()` 仍会缓冲完整结果（上限 256 MB），因为解压与文本解析需要完整响应体。
3. **压缩与流式暂不兼容** — `compress=true` 时 `execute_stream()` 抛 `ConnectionError`；压缩响应请用 `execute_query()`。
4. **响应体大小限制** — 缓冲式响应上限 256 MB。超大结果请用过滤、聚合或 `execute_stream()`。
5. **插入无进度/重试** — `insert()` 一次性流式发送 body；失败需要整体重试。

## 运行示例 CLI

```sh
# 默认连接（127.0.0.1:8123，用户 default）
moon run cmd/main

# 通过环境变量指向任意 ClickHouse
CLICKHOUSE_HOST=127.0.0.1 CLICKHOUSE_PORT=38123 \
CLICKHOUSE_USER=default CLICKHOUSE_PASSWORD=barn \
moon run cmd/main
```

demo（`cmd/main/main.mbt`）覆盖了驱动的主要 API：

- `ping()` 健康检查，以及 `close()` / `cancel()` 语义
- `execute_query()` — 带**命名** `{name: Type}` 参数的 SELECT / DDL
- `execute()` — **位置** `?` 绑定（内联 VALUES）
- `insert()` — 以 HTTP body **流式批量插入**，支持 TSV 与 JSONEachRow
- `execute_stream()` — **逐行游标**读取，schema 立即可用
- `to_map()` — 结果转列名映射
- 错误处理 — 用 `try-catch` 捕获 `ServerError`（表不存在、语法错误）与 `ConnectionError`
- `compress=true` — LZ4 压缩响应自动解压
- `timeout_ms` — 慢查询（`SELECT sleep(3)`）在超时后被取消
- `https=true` — TLS 连接（对纯 HTTP 服务器优雅失败，对开启 TLS 的端口成功）
- `conn.pool(size)` — 连接池复用 keep-alive 连接，支持并发查询

## 集成测试（CI）

单元测试：`moon test -p liuhuo23/clickhouse-driver`（离线，无需 ClickHouse）。

`integration/` 下的集成测试**仅在 CI 中运行**，通过 GitHub Actions 服务容器
启动 `clickhouse/clickhouse-server:24.8`（端口 8123）。见
`.github/workflows/check.yml` 中的 `integration` job。