# liuhuo23/clickhouse-driver

[English](README.md) | [简体中文](README.zh-CN.md)

MoonBit 实现的 ClickHouse 原生 TCP 协议驱动。

## 概览

- 原生协议（rev 54429），兼容 ClickHouse 20.x – 23.x
- 完整类型支持：`UInt/Int 8–256`、`Float32/64`、`Bool`、`String`、
  `FixedString(N)`、`Date/Date32/DateTime/DateTime64`、`Decimal(P,S)`、
  `UUID`、`IPv4/IPv6`、`Enum8/16`、`Nullable(T)`、`Array(T)`、`Tuple(...)`、
  `Map(K,V)`、`LowCardinality(T)`、`SimpleAggregateFunction(func,T)`
- 发送 `Client::Ping` 健康检查并解析 `Server::Pong`
- 通过 MoonBit `try-catch` 进行错误处理，定义了 `DbError` suberror
  （`ServerError` / `ConnectionError`）
- 完整 DDL 支持（`CREATE` / `DROP` / `TRUNCATE`）
- 开箱即用支持 `default` 和 `system` 数据库

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
  "moonbitlang/async/socket",
  "moonbitlang/core/buffer",
  "moonbitlang/core/encoding/utf8",
  "liuhuo23/clickhouse-driver" @lib,
}
```

## 快速开始

```moonbit
async fn main {
  let conn = @lib.connect(
    host="127.0.0.1",
    port=9000,
    user="default",
    password="",
    database="default",
    client_name="my-app",
  )
  defer conn.close()

  // 1. 健康检查
  conn.ping()

  // 2. 执行查询
  let result = conn.execute_query("SELECT id, name FROM users LIMIT 10")

  // 3. 查看列信息
  for col in result.columns {
    println(col.name + " : " + col.type_)
  }

  // 4. 遍历行
  for row in result.rows {
    // row.values : Array[String]
    println(row.values)
  }

  // 5. 转换为行 Map（每行 -> Map[列名 -> 值]）
  let rows = result.to_map()
  for m in rows {
    println(m["name"])
  }
}
```

## API 参考

### `connect`

```moonbit
pub async fn connect(
  host~ : String,
  port~ : Int,
  user~ : String,
  password~ : String,
  database~ : String,
  client_name~ : String,
) -> Connection
```

建立 TCP 连接并完成 ClickHouse 握手。

| 参数         | 类型     | 说明                  |
| ------------ | -------- | --------------------- |
| `host`       | `String` | 服务器主机名或 IP     |
| `port`       | `Int`    | TCP 端口（默认 9000） |
| `user`       | `String` | 用户名                |
| `password`   | `String` | 密码                  |
| `database`   | `String` | 默认数据库            |
| `client_name`| `String` | 客户端标识            |

### `Connection`

```moonbit
pub struct Connection { ... }
```

#### `Connection::ping`

```moonbit
pub async fn ping(self : Connection) -> Unit raise
```

发送 `Client::Ping` 包并等待 `Server::Pong`。轻量级健康检查，不执行查询。

#### `Connection::execute_query`

```moonbit
pub async fn execute_query(
  self : Connection,
  sql : String,
) -> ResultSet raise
```

执行任意 SQL 语句（`SELECT`、`INSERT`、`UPDATE`、`DELETE`、DDL），返回解析结果。
对于非 `SELECT` 语句，返回的 `rows` 通常为空。

可能抛出：
- `DbError::ServerError(code, name, message)` — 服务器拒绝了查询
  （语法错误、表不存在、权限不足等）
- `DbError::ConnectionError(String)` — 协议 / I/O 错误
- 底层网络 I/O 错误

#### `Connection::close`

```moonbit
pub fn close(self : Connection) -> Unit
```

关闭底层 TCP 连接。配合 `defer` 使用：

```moonbit
let conn = @lib.connect(...)
defer conn.close()
```

### `ResultSet`

```moonbit
pub struct ResultSet {
  columns : Array[Column]
  rows : Array[Row]
}
```

#### `ResultSet::to_map`

```moonbit
pub fn to_map(self : ResultSet) -> Array[Map[String, String]]
```

将结果转换为行 Map 数组。每个元素是一个 `Map[String, String]`，
键为列名，值为该单元格的字符串表示。

```moonbit
let rows = result.to_map()
for m in rows {
  let name = m["name"]   // -> String?（如需非可选值请用 get_or_default）
  println(name)
}
```

### `Row`

```moonbit
pub struct Row {
  values : Array[String]
}
```

单行数据。每个单元格是对应 ClickHouse 值的字符串表示
（如 `"42"`、`"2025-01-01 00:00:00"`、`"NULL"`）。

### `Column`

```moonbit
pub struct Column {
  name : String
  type_ : String
}
```

列元数据。`type_` 是原始 ClickHouse 类型字符串，例如
`"Nullable(Int64)"`、`"LowCardinality(String)"`、`"DateTime64(3)"`。

## 异常处理

```moonbit
try {
  conn.execute_query("SELECT * FROM no_such_table")
} catch {
  @lib.DbError::ServerError(code~, name~, message~) =>
    println("服务器错误: code=" + code.to_string() + " " + message)
  @lib.DbError::ConnectionError(msg) =>
    println("连接错误: " + msg)
  _ => println("其他错误")
}
```

### `DbError` suberror

```moonbit
pub suberror DbError {
  ServerError(code~ : Int, name~ : String, message~ : String)
  ConnectionError(String)
} derive(@debug.Debug)
```

| 变体               | 字段                                             | 触发场景                              |
| ------------------ | ------------------------------------------------ | ------------------------------------- |
| `ServerError`      | `code : Int`、`name : String`、`message : String` | 服务器返回 Exception 包（查询被拒绝） |
| `ConnectionError`  | `String`                                         | 协议 / I/O 错误（格式错误、意外 EOF）|

`code` 对应 ClickHouse 错误码（如 `60` = `UNKNOWN_TABLE`，
`62` = `SYNTAX_ERROR`，`81` = `DATABASE_ACCESS_DENIED`）。

## 支持的 ClickHouse 类型

所有值以字符串形式返回。下表列出了各类型的传输格式和字符串表示。

| ClickHouse 类型         | 传输格式                                   | 字符串表示                          |
| ----------------------- | ------------------------------------------ | ----------------------------------- |
| `UInt8`                 | 1 字节                                     | 十进制数字                          |
| `UInt16`                | 2 字节 LE                                  | 十进制数字                          |
| `UInt32`                | 4 字节 LE                                  | 十进制数字                          |
| `UInt64`                | 8 字节 LE                                  | 十进制数字                          |
| `Int8`                  | 1 字节（有符号）                           | 十进制数字                          |
| `Int16`                 | 2 字节 LE（有符号）                        | 十进制数字                          |
| `Int32`                 | 4 字节 LE（有符号）                        | 十进制数字                          |
| `Int64`                 | 8 字节 LE（有符号）                        | 十进制数字                          |
| `Int128` / `Int256`     | 16 / 32 字节                               | `<Int128>` / `<Int256>` 占位符      |
| `UInt128` / `UInt256`   | 16 / 32 字节                               | `<UInt128>` / `<UInt256>` 占位符    |
| `Float32`               | 4 字节 LE（IEEE 754）                      | 十进制数字                          |
| `Float64`               | 8 字节 LE（IEEE 754）                      | 十进制数字                          |
| `Bool`                  | 1 字节（`0` = false, `1` = true）          | `"true"` / `"false"`                |
| `String`                | varuint 长度 + 字节                        | UTF-8 解码（容错）                  |
| `FixedString(N)`        | `N` 字节                                   | UTF-8 解码（容错）                  |
| `Date`                  | UInt16 LE（自 1970-01-01 的天数）          | `"YYYY-MM-DD"`                      |
| `Date32`                | Int32 LE（自 1970-01-01 的天数）           | `"YYYY-MM-DD"`                      |
| `DateTime`              | UInt32 LE（自 1970-01-01 的秒数）          | `"YYYY-MM-DD HH:MM:SS"`             |
| `DateTime64(scale)`     | Int64 LE（`10^-scale` 秒的 tick 数）       | `"YYYY-MM-DD HH:MM:SS.fff..."`      |
| `Decimal(P,S)` P≤9      | Int32 LE                                   | 带 `S` 位小数的数字                 |
| `Decimal(P,S)` P≤18     | Int64 LE                                   | 带 `S` 位小数的数字                 |
| `Decimal128/256`        | 16 / 32 字节                               | `<Decimal128(S)>` 占位符            |
| `UUID`                  | 16 字节                                    | `"xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"` |
| `IPv4`                  | 4 字节 LE                                  | `"a.b.c.d"`                         |
| `IPv6`                  | 16 字节                                    | 8 组十六进制，用 `:` 连接           |
| `Enum8` / `Enum16`      | 1 / 2 字节（有符号）                       | 十进制数字                          |
| `Nullable(T)`           | null 标志字节 + T                          | `"NULL"` 或 T 的值                  |
| `Array(T)`              | 偏移量（UInt64 × 行数）+ T 元素            | `"[v1, v2, v3]"`                    |
| `Tuple(T1, T2, ...)`    | 每个子列分别序列化                         | `"(v1, v2, v3)"`                    |
| `Map(K, V)`             | 偏移量 + K + V（等同 `Array(Tuple(K,V))`） | `"{k1:v1, k2:v2}"`                  |
| `LowCardinality(T)`     | 版本号 + 字典 + 索引                       | 底层 T 的值                         |

### 注意事项

- **Nullable 的 null_map 语义**：`0` = 非空，`1` = 空（与 MySQL / PostgreSQL 相反）。
  驱动对空值返回 `"NULL"`，对非空值返回底层值。
- `SimpleAggregateFunction(func, T)` 按内部类型 `T` 读取。
- 字符串解码使用 **容错模式**（`@utf8.decode_lossy`）：无效的 UTF-8 字节会被
  替换为 U+FFFD，而不是抛出错误。
- `Int128` / `Int256` / `UInt128` / `UInt256` / `Decimal128` / `Decimal256`
  尚未解析（MoonBit 缺少原生 128/256 位整数）；原始字节仍被正确消耗，
  返回占位符字符串，不影响后续 block 解析的对齐。

## DDL / INSERT / UPDATE / DELETE

### DDL（已支持）

DDL 语句通过标准查询路径发送，开箱即用：

```moonbit
ignore(conn.execute_query(
  "CREATE TABLE demo (id Int32, name String) ENGINE = MergeTree() ORDER BY id"
))
ignore(conn.execute_query("DROP TABLE IF EXISTS demo"))
ignore(conn.execute_query("TRUNCATE TABLE demo"))
```

### INSERT（暂不支持）

原生协议中 `INSERT` 的流程与 `SELECT` 不同：

1. 发送包含 `INSERT … VALUES …` 语句的 `Client::Query`
2. 服务器响应 `EndOfStream`，**期望**客户端发送数据块
3. 客户端发送 `Client::Data` 块，schema 需匹配表结构，包含要插入的行
4. 客户端发送最终的空 `Client::Data` 表示输入结束

当前 `execute_query` 只发送终止用的空数据块，服务器会挂起等待实际数据。
需要实现专门的 `insert_into(table, columns, rows)` 辅助函数。

### ALTER TABLE UPDATE / DELETE（暂不支持同步等待）

ClickHouse 的 `ALTER TABLE … UPDATE` / `DELETE` 是**异步 mutation**：
服务器将 mutation 入队后立即返回，**不发送** `EndOfStream`，
直到 mutation 在所有 part 上应用完毕。同步的 `execute_query` 会永久阻塞。

可通过 `system.mutations` 轮询进度，或使用 ClickHouse 22.10+ 引入的
**轻量级** `DELETE` / `UPDATE`（`DELETE FROM … WHERE …`），它们的行为类似
普通查询，完成后会返回 `EndOfStream`。

## ClickHouse 事务

**ClickHouse 不支持传统 ACID 事务。** 没有 `BEGIN` / `COMMIT` / `ROLLBACK`，
也没有 `Serializable` 隔离级别。上述 mutation 在单个 part 上是原子的，
但跨 part 或跨表的原子性不保证。

对于需要版本语义的数据，可使用特殊引擎：

- `ReplacingMergeTree(version_column)` — merge 后保留 `version_column` 最大的行
- `CollapsingMergeTree(sign_column)` — 用 `sign` 列（`+1` 插入，`-1` 取消）
  在 merge 时折叠行对
- `VersionedCollapsingMergeTree(version, sign)` — 类似 `CollapsingMergeTree`
  但顺序无关
- `SummingMergeTree` / `AggregatingMergeTree` — 状态聚合模式

`INSERT … SELECT` 是原子的，但仅在 part 级别。

## 协议细节

- 客户端协议版本：`54429`（连接时与服务器协商）
- 握手：`Client::Hello` → `Server::Hello`
- 查询：`Client::Query` + 终止用的空 `Client::Data` 块
- 响应包类型：
  - `1` — `Server::Data`（schema 和/或数据块）
  - `2` — `Server::Exception`（错误）
  - `3` — `Server::Progress`（进度：行数、字节数、总计、耗时）
  - `4` — `Server::Pong`（`Client::Ping` 的响应）
  - `5` — `Server::EndOfStream`（查询结束）
  - `6` — `Server::ProfileInfo`（行数、块数、字节数、limit 信息）

原生协议使用小端序。变长整数使用 ClickHouse 标准的 LEB128（`varuint`）编码。
`String` 编码为 `varuint(长度)` + 字节。`Date`、`DateTime` 等是固定大小的 LE 整数。
`Nullable(T)` 先发送每行的 null 标志字节，然后连续发送所有行的内部类型数据
（列式存储，非行式）。`Array` 和 `Map` 先发送每行的累积偏移量（`UInt64`），
然后连续发送所有内部数据。`LowCardinality` 发送版本号 + 字典 + 每行的字典索引。

## 已知限制

1. `INSERT` 未实现（见上文）
2. `ALTER TABLE … UPDATE/DELETE` 会导致同步 `execute_query` 阻塞，
   因为服务器在 mutation 完成前不发送 `EndOfStream`
3. 某些服务器错误（如部分软错误）以 0 行 `Data` 块而非 `Exception` 包返回；
   `try-catch` 基础设施已就位，但无法捕获这些情况
4. `Int128` / `Int256` / `UInt128` / `UInt256` / `Decimal128` / `Decimal256`
   返回占位符字符串；字节仍被正确消耗，不影响 block 解析对齐
5. 驱动仅支持**原生 TCP** 协议，不支持 HTTP 及 `mysql` / `postgres` /
   `interserver` 端口

## 运行示例 CLI

```sh
moon run cmd/main
```

CLI 示例（`cmd/main/main.mbt`）演示了 ping、`SELECT`、DDL（`CREATE` / `DROP`）、
异常捕获尝试，并打印了关于 INSERT / ALTER UPDATE 限制的说明。
请根据你的环境修改 `main.mbt` 顶部的 `host` / `port` / `user` / `password` /
`database` 字段。
