# liuhuo23/clickhouse-driver

[English](README.md) | [简体中文](README.zh-CN.md)

MoonBit 实现的 ClickHouse **HTTP** 协议驱动——简单、跨平台、无状态。

## 概览

- 使用 ClickHouse 原生 HTTP 接口（默认端口 **8123**）
- 响应以 **TabSeparatedWithNamesAndTypes** 解析，列名和类型自动返回，客户端无需手动类型映射
- 单一统一 API：`execute_query(sql, params?)` 覆盖 SELECT、DDL、内联 VALUES INSERT
- 两种参数绑定方式，均基于 ClickHouse 原生 `{name: Type}` 占位符协议：
  - `execute_query(sql, params?)` — **命名**绑定，使用 `{name}` / `{name: Type}`。
    无类型 `{name}` 默认为 `String`，所以表名、标识符、字符串列名书写更自然。
  - `execute(sql, values)` — **位置**绑定，使用 `?`。当同一参数形状在多行重复出现时（典型场景是内联 VALUES INSERT）写法最简洁——不需要为每行发明不重复的名字。
  参数以 `param_<key>=<value>` URL 参数形式传入，由服务端（自动加引号、转义）替换
- 通过 MoonBit `try-catch` 进行错误处理，定义了 `DbError` suberror（`ServerError` / `ConnectionError`）
- 每次调用都建立短生命周期 HTTP 连接——无持久状态可泄漏，长时间空闲后无需重连
- 兼容 ClickHouse 22.x+（HTTP 接口自 21.x 起稳定）

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

## API 参考

### `connect`

```moonbit nocheck
pub async fn connect(
  host~ : String,
  port~ : Int,
  user~ : String,
  password~ : String,
  database~ : String,
  client_name~ : String,
) -> Connection
```

根据显式参数构造 `Connection` 配置。**不会**建立 TCP 连接——调用是无状态的，每次请求都会建立新的 HTTP 连接。

| 参数         | 类型     | 说明                  |
| ------------ | -------- | --------------------- |
| `host`       | `String` | 服务器主机名或 IP     |
| `port`       | `Int`    | HTTP 端口（默认 8123）|
| `user`       | `String` | 用户名                |
| `password`   | `String` | 密码                  |
| `database`   | `String` | 默认数据库            |
| `client_name`| `String` | 通过 `X-ClickHouse-Client-Name` header 发送 |

### `Connection`

```moonbit nocheck
pub struct Connection {
  host : String
  port : Int
  user : String
  password : String
  database : String
  client_name : String
}
```

轻量级配置结构——没有持久 socket。每次调用都建立短生命周期 HTTP 连接并在返回时关闭。

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
Connection: close
Content-Length: 0
```

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

1. **无流式 / 进度回调** — HTTP 在关闭连接前返回完整结果。无法流式获取部分结果或逐行进度回调。
2. **无法在查询中途取消** — 请求一旦发出，驱动就失去句柄。需要取消请断开连接。
3. **仅内联 VALUES** — 批量插入（≫ 几千行）应切换到 ClickHouse 原生 TCP 协议，或使用支持 body 流式传输的 HTTP 插入 API（POST + `application/x-ndjson`）。本驱动保持最简形式：SQL 含字面 VALUES，字面值来自 `params`。
4. **响应体大小限制** — `read_response_body` 强制 256 MB 上限以防止内存失控。返回更大的查询应使用过滤或聚合。

## 运行示例 CLI

```sh
moon run cmd/main
```

CLI 演示（`cmd/main/main.mbt`）依次演示 ping、参数化 SELECT、`CREATE TABLE`、带参数的内联 VALUES INSERT、带参数的 `SELECT … WHERE …`、异常处理与清理。