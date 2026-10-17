# ClickHouse 原生协议（Native Protocol）驱动 — 基础版本框架设计

> 分支：`native` ｜ 状态：P2 完成（v0.2）｜ 更新：2026-08-03

## 1. 背景与目标

当前 `liuhuo23/clickhouse-driver` 通过 **HTTP 接口**（端口 8123）与 ClickHouse 通信：
每次查询建立短连接、以 `TabSeparatedWithNamesAndTypes` 文本格式收发、逐行字符串解析。
优点是实现简单、可调试；缺点是二进制列类型丢失、无法流式读取原始块、查询取消不可用、
每次请求都有 HTTP 开销。

本分支的目标是新增 **ClickHouse 原生 TCP 协议（Native Protocol，端口 9000）** 驱动：

- **持久连接**：一次握手，多次查询复用，支持 `keep-alive`，天然可做连接池。
- **二进制传输**：无文本编解码开销，列数据按原生类型编码，类型信息精确。
- **完整协议能力**：`INSERT` 数据块流式上传、查询 `cancel`、Progress/日志回调等（后续阶段）。
- **与 HTTP 版 API 形态对齐**：降低用户迁移成本，二者可共用一个上层 API 心智模型。

**基础版本（本设计覆盖范围，P0–P2 已完成）**：连接与握手 → 认证 → `ping` → `SELECT`
查询（基础列类型）→ 服务器异常解析 → 优雅关闭。不包含 INSERT、压缩、TLS、流式游标
（列入后续阶段）。

## 2. 与 HTTP 版的关系

| 维度 | 决策 |
| --- | --- |
| 代码位置 | 新增独立子包 `native/`，**不改动**根包 HTTP 实现与现有 API |
| 类型复用 | `native/` import 根包（`@lib`），复用 `Column` / `Row` / `ResultSet` / `DbError` |
| 命名 | 新增 `NativeConfig` / `NativeConnection`，避免与根包 `Connection` 混淆 |
| 依赖方向 | `native/` → 根包 → `moonbitlang/async`（单向，无循环） |

复用根包类型的收益：`DbError`（`ServerError` / `ConnectionError`）错误语义与 HTTP 版完全一致；
`Column` / `Row` / `ResultSet` 的字符串形态让调用方零迁移。代价是丢失强类型——基础版本接受
该取舍，强类型 API 作为后续演进项（见 §9 未来演进）。

## 3. 目录与模块结构

```
native/
  moon.pkg              # 依赖：根包 @lib、moonbitlang/async、core/buffer 等
  native.mbt            # 公共 API：NativeConfig、NativeConnection、connect/ping/execute_query/close
  protocol.mbt          # 协议常量 + 编解码原语（VarUInt / 定长整型 / String）
  handshake.mbt         # 握手流程（Hello 收发、revision 协商、异常处理）
  block.mbt             # 数据块（Block）编解码：块头、列头、列数据读写
  types.mbt             # 列类型注册表 + 值解码（按 ClickHouse 类型名分派）
  server_error.mbt      # Exception 包解析 → DbError::ServerError
  native_test.mbt       # 单元测试（编解码原语、块头、类型解码）
  native_wbtest.mbt     # 白盒测试（内部状态）
cmd/main/               # 追加 native 示例（经环境变量切换，见 §10）
integration/
  native_integration_test.mbt   # 真实服务器集成测试（9000 端口）
```

## 4. 公共 API 设计（基础版本）

```moonbit
///|
/// 原生协议连接配置（结构与 HTTP 版 Connection 对齐）。
pub struct NativeConfig {
  host : String
  port : Int              // 默认 9000
  user : String
  password : String
  database : String
  client_name : String
  timeout_ms : Int        // 0 = 无超时（默认）
}

///|
/// 建立 TCP 连接并完成握手。失败时 raise DbError。
pub async fn connect(config : NativeConfig) -> NativeConnection

///|
/// 持久连接句柄（内部持有 Tcp + 服务端信息）。
pub struct NativeConnection { ... }

///| SELECT 1 往返健康检查。
pub async fn NativeConnection::ping(self : NativeConnection) -> Unit

///| 执行 SELECT/DDL，返回完整 ResultSet（列名 + 类型 + 行）。
pub async fn NativeConnection::execute_query(
  self : NativeConnection, sql : String
) -> ResultSet

///| 关闭连接（发送关闭或直接断开 TCP）。
pub async fn NativeConnection::close(self : NativeConnection) -> Unit

///| 取消当前查询（基础版本先实现为发送 Cancel 包）。
pub async fn NativeConnection::cancel(self : NativeConnection) -> Unit
```

设计要点：

- `connect` 是 **async 且真实建连**（与 HTTP 版的纯配置 `connect` 语义不同——这是原生协议
  持久连接的本质要求；文档中明确标注该差异）。
- `execute_query` 基础版本接受纯 SQL；参数绑定（`{name: Type}` / `?`）列入 P3。
- 复用根包 `ResultSet`（`columns: Array[Column]`，`rows: Array[Row]`，`Row.values: Array[String]`），
  `to_map()` 等辅助方法直接可用。

## 5. 协议层设计

### 5.1 包类型常量

| 方向 | 包 | 值 |
| --- | --- | --- |
| C→S | Hello | 0 |
| C→S | Query | 1 |
| C→S | Data | 2 |
| C→S | Cancel | 9 |
| C→S | Ping | 4 |
| S→C | Hello | 0 |
| S→C | Data | 2 |
| S→C | Exception | 3 |
| S→C | Progress | 5 |
| S→C | Pong | 4 |
| S→C | EndOfStream | 6 |
| S→C | ProfileInfo | 7 |
| S→C | Log | 10 |
| S→C | ProfileEvents | 14 |

基础版本只处理：`Hello`、`Data`、`Exception`、`EndOfStream`；`Progress` / `ProfileInfo` / `Log`
读后丢弃（保留计数）。

### 5.2 编解码原语（`protocol.mbt`）

| 原语 | 编码 | 读写实现 |
| --- | --- | --- |
| VarUInt | LEB128（最高位续传） | `read_varuint()` / `write_varuint(v)` |
| String | VarUInt 长度 + UTF-8 字节 | `read_string()` / `write_string(s)` |
| UInt8/16/32/64 | 小端定长 | `read_uint16()` 等 |
| Int8/16/32/64 | 小端补码 | `read_int32()` 等 |
| Float32/64 | IEEE-754 小端 | `read_float64()` 等 |
| UUID | 16 字节（混合端序，按 ClickHouse 规范） | `read_uuid()` |
| Date | UInt16（自 1970-01-01 天数） | `read_date()` |
| DateTime | UInt32（Unix 秒） | `read_datetime()` |
| DateTime64 | Int64（按精度缩放） | `read_datetime64(scale)` |
| Decimal(P,S) | Int32/64/128（按 P 分派） | `read_decimal(size, scale)` |
| FixedString(N) | N 字节 | `read_fixed_string(n)` |
| Array(T) | VarUInt 长度 + 元素（按 T 递归） | `read_array(inner)` |
| Nullable(T) | 每行 1 字节 mask + 非空值 | `read_nullable(inner)` |
| LowCardinality(String) | 字典表 + 索引 | `read_low_cardinality(inner)` |

统一入口：`read_value(type_name : String, reader) -> String`，返回值的 **字符串表示**
（与 HTTP 版 `Row.values: Array[String]` 一致，如 `Nullable(Int64)` 空值返回 `""`）。

### 5.3 握手流程（`handshake.mbt`）

```
client ── Hello{client_name, version_major=25, version_minor=?, revision=54468, database, user, password}
server ── Hello{server_name, version_major, version_minor, revision}
       ── Exception{code, name, message}  → raise ServerError / ConnectionError
```

- revision 取 **54468**（支持 ClientInfo/QueryParameters 的稳定档位；与 ClickHouse 25.x/24.8
  均兼容）。握手后保存服务器 `version` / `revision` 到 `NativeConnection`，供协议分支判断。
- 密码默认按明文发送（ClickHouse 原生协议默认不带 SHA256 盐）；若后续需要 `secure`，
  密码使用 SHA256 摘要（列入 P4）。

### 5.4 查询流程（`execute_query`）

```
client ── Query{ query_id="", client_info(完整 ClientInfo), settings=空, stage=Complete(2),
                 compression=0, query_text=sql, params=空 }
       ── 空 Data 块（声明无外部表数据）
server ── 循环读包：
    Data  → 首块记录列名/列类型（SampleBlock），随后块累积行
    Progress / ProfileInfo / Log → 忽略
    Exception → raise ServerError(code, name, message)
    EndOfStream → 结束
```

- 基础版本 `stage = Complete`，服务器一次性返回全量块，客户端累积为 `ResultSet`。
- 流式游标（`execute_stream` 等价物）依赖 `stage = FetchColumns` 逐块处理，列入 P3。
- 若首个数据块行数为 0（如 `SELECT` 无结果），服务器仍会以空块返回列头；`columns` 照常填充。

### 5.5 数据块（Block）格式（`block.mbt`）

```
BlockHeader:
  BlockInfo: 字段编号循环（field=1 读 1 字节, field=2 读 Int32, 其他读 VarUInt, 0 结束）
  num_columns : VarUInt
  num_rows    : VarUInt
逐列交织（NativeWriter 输出，与 clickhouse-client 一致）:
  每列: name : String + type : String + has_custom : UInt8(rev >= 54454)
       + num_rows × 列值（无 rows 前缀，直接按块头 num_rows 读取）
```

- **列头与列数据逐列交织**：不是「先全部列头再全部数据」，而是每列写完
  name/type/has_custom 后立即写该列数据。
- `nrows = 0` 时该块只有列头（如 SELECT 无结果的 SampleBlock），列数据无字节。
- 查询结束服务器还会发送一个 `ncols=0, nrows=0` 的空块，客户端忽略。
- `Nullable(T)` 列的 bulk 格式是**两段式**：先整列 `nrows` 字节的 null mask，
  再整列 `nrows` 个嵌套值（NULL 行也写入嵌套类型的默认值，需要读取并丢弃）。
  因此解码按列进行（`read_column_values`），不能按「逐行 mask + 值」。
- `types.mbt` 维护 `类型名 → 解码函数` 分派；**未知类型**默认抛
  `ConnectionError("unsupported type: ...")`，保证不静默产出错误数据。
- 注意 `DateTime` 以 `"Date"` 为前缀，分派顺序必须先判断 DateTime/DateTime64
  再判断 Date，否则会按 2 字节错误解码。

### 5.5f 复合类型解码（实测 25.7）

- 顶层列统一按 **bulk 格式**解码（`read_column_values` 递归）：
  - `Array(T)`：`nrows` 个 UInt64 小端**累计偏移** + 平铺元素的 bulk
  - `Tuple(...)`：各子列各自 bulk
  - `Map(K,V)`：同 `Array(Tuple(K,V))`（偏移 + K bulk + V bulk）
  - `Nullable(T)`：整列 mask + 内层 bulk（已支持）
- 文本表示与 HTTP 版对齐：`[1,2,3]`、`(1,'x',1.5)`、`{'k1':10}`；
  数组/元组内的 NULL 显示 `NULL`。
- `Decimal(P,S)`：按精度 4/8/16/32 字节小端补码（128/256 用 BigInt，
  无符号读 + 减 2^(8n) 补码修正）；文本去小数尾零（`1.50` → `1.5`）。
- `UUID`：16 字节 = **先高 64 位小端、再低 64 位小端**；文本
  `{hi 高32}-{hi 32-47}-{hi 48-63}-{lo 高16}-{lo 低48}`。
- `IPv4`：4 字节小端；`IPv6`：16 字节大端，标准压缩文本（`::1`）。
- `Enum8/16`：解码为枚举名称（解析类型名映射，未知回退数字）。
- `Bool`：1 字节（UInt8），显示 `true`/`false`。
- `Interval*`（Day/Second/...）：Int64，显示数字。
- `DateTime('tz')` / `DateTime64(3, 'tz')`：native 值为绝对 epoch（UTC），
  显示按列时区偏移（内置常见时区表 + `Etc/GMT±N`，DST 用标准偏移近似；
  未知时区按 UTC）。
- `LowCardinality`：Query 包 settings 发送
  `low_cardinality_allow_in_native_format=0`，服务器解包为原始类型，
  客户端无需实现低基数字典格式。
- 已知 `from_octets(signum=-1)` 非补码语义；补码用「无符号 + 减模」修正。

### 5.5b 响应包补充（实测 25.7）

- `Progress`（rev >= 54460）：**6 个 VarUInt**——read_rows, read_bytes,
  total_rows_to_read, written_rows, written_bytes, elapsed_ns。
- `ProfileInfo`（rev 54460，无 rows_before_aggregation 字段）：rows(varuint) +
  blocks(varuint) + bytes(varuint) + applied_limit(u8) + rows_before_limit(varuint) +
  calculated_rows_before_limit(u8)，共 6 个字段；rev >= 54469 时尾部追加
  applied_aggregation / rows_before_aggregation。
- `ProfileEvents`（包类型 **14**）：`string("")` + Block（host_name,
  current_time, thread_id, type, name, value 六列），SELECT 后自动发送，客户端
  按 Block 格式解析后丢弃。
- `Log`（包类型 **10**）：`string("")` + Block；仅在客户端设置
  `send_logs_level` 时发送，基础版本不设置。
- Data / Totals / Extremes：`string("")` 表名 + Block。

### 5.6 服务器异常解析（`server_error.mbt`）

```
Exception 包: code : Int32, name : String, message : String,
              stack_trace : String, has_nested : Bool
映射: DbError::ServerError(code=code, name=name, message=message)
```

- 与 HTTP 版 `ServerError(code, name, message)` 完全一致，上层捕获逻辑无需改动。
- 握手阶段收到 Exception 视为认证失败，同样映射 `ServerError`。

### 5.5c INSERT 数据上传（实测 25.7）

```
client ── Query{ "INSERT INTO t (c1, c2) VALUES" }   （与 SELECT 相同的 Query 包）
       ── 空 Data 块（无外部表声明）
server ── TableColumns（包类型 11：2 个字符串，跳过）
       ── SampleBlock（Data 包，nrows=0，含列名/类型，客户端据此编码）
client ── 数据 Data 块（列头 + 列数据，逐列交织，Nullable 两段式）
       ── 空 Data 块（数据结束）
server ── ProfileEvents / Progress / Exception / EndOfStream
```

- 客户端**必须**先读 SampleBlock 拿到列类型，再编码行数据上传；
  编码侧 `write_value` / `write_column_values` 与解码侧对称。
- 行值以字符串表示（与 HTTP 版 `Connection::insert` 对齐），NULL 用空字符串。
- 注意：SampleBlock 也是 Data 包，**要先读表名**再读块。

### 5.5d 参数绑定（实测 25.7）

- Query 包 `params` 字段采用 settings 字符串格式：
  `string(name) + u8(flags=0x2) + string(value)` 对 + `string("")` 结束。
- **value 必须是带引号的 SQL 字面量**（`'42'`、`'hello'`），服务器端按
  Field dump 解析；`'` / `\` / 换行等需转义（与官方客户端
  `escape_param(for_server=True)` 一致）。
- 已知服务器限制：参数不能出现在 `numbers()` 的数字参数、`<` 比较右值等
  位置（官方客户端同样失败）；`=` / `%` 等比较位置可用。
- `execute(sql, values)` 把 `?` 转为 `{__pN: String}` 后走命名参数路径。

### 5.5e 流式游标（`execute_stream`）

- `NativeResultSetCursor`：`columns()` / `next() -> Row?` / `close()`，
  与 HTTP 版 `ResultSetCursor` 对齐。逐块读取，不缓存全部结果。
- `close()` 会把连接上剩余包读取到 EndOfStream，保证连接可复用；
  提前关闭（未读完）同样安全。
- 单连接同一时刻只允许一个游标/查询（与 HTTP 版相同的串行约束）。

### 5.5g LZ4 压缩（实测 25.7）

- Query 包 `compression` 字段置 1 后，**Data / Totals / Extremes 包**的 block
  内容以压缩块发送；Exception / Progress / ProfileInfo / ProfileEvents / Log /
  EndOfStream 始终明文。
- 压缩块（C++ 格式）：
  `checksum(16B CityHash128) + method(1B=0x82 LZ4) + comp_size(4B LE) +
  uncomp_size(4B LE) + LZ4 数据`；comp_size 含 9 字节头。
- **CityHash128 用 ClickHouse CityHash_v1_0_2**（入口 seed 含 k3、len 8-15
  独立分支；与 google master / 第三方移植不同，已实测修正）。
- LZ4 为标准 block 格式；解压器纯 MoonBit 实现；压缩器当前为字面量-only
  （合法但压缩率差，后续可替换完整实现）。
- `NativeConfig.compress=true` 启用；客户端空块/数据块也需压缩（否则服务器
  解析错位）。

### 5.5h 连接池（`NativeConnectionPool`）

- `config.pool(size)` 创建池（默认 4）；acquire/release/discard 模式与 HTTP
  版 `ConnectionPool` 对齐（Semaphore 限流 + idle 数组复用）。
- acquire 时对空闲连接 ping 校验健康，失效则丢弃换新；超过 `max_size`
  等待。
- 池化 `execute_query` / `execute` / `insert` / `execute_stream` / `ping`；
  失败自动 discard 连接（协议错位后不归还）。
- `execute_stream` 返回 `NativePooledCursor`，必须 `close()`（或 `defer`）
  归还连接；`close()` 会 drain 剩余数据确保连接可复用。
- 单连接同一时刻只允许一个操作（与连接级串行约束一致）。

## 6. 错误处理

| 场景 | 错误 |
| --- | --- |
| 服务器 Exception 包 | `DbError::ServerError(code, name, message)` |
| TCP 连接失败 / 中途 EOF / 读超时 | `DbError::ConnectionError(String)` |
| 协议格式非法（VarUInt 越界、块头不一致） | `DbError::ConnectionError(String)` |
| 未知列类型 | `DbError::ConnectionError("unsupported type ...")` |

超时：`timeout_ms > 0` 时每次公开操作（connect / ping / query / insert /
游标 next / close）都用 `@async.with_timeout` 包住（与 HTTP 版同款做法）；
超时后连接停在半个数据包上，应关闭，连接池会自动 discard。

## 7. 配置演进（预留字段）

基础版本 `NativeConfig` 只含 §4 字段；以下作为后续版本扩展（不阻塞本期）：

```moonbit
// P4 预留（不在本期实现）
secure : Bool            // 原生协议 + TLS（端口 9440）
compress : Bool          // 协商 LZ4 块压缩
settings : Map[String, String]  // 服务端 settings 透传
connect_timeout_ms : Int
```

## 8. 分阶段实施计划

| 阶段 | 内容 | 验收标准 |
| --- | --- | --- |
| **P0** | `native/` 目录骨架 + `protocol.mbt` 编解码原语 + 单元测试 | `moon test -p .../native` 通过；VarUInt/String/定长读写边界正确 |
| **P1** | TCP 连接 + 握手 + `ping` + Exception 解析 | 对真实容器 `SELECT 1` 往返成功；错误密码得到 `ServerError` |
| **P2** ✅ | `execute_query` + 块解码（基础类型）→ `ResultSet` | 集成测试覆盖 Int/UInt/Float/String/Date/DateTime/Nullable、错误 SQL、空结果；demo 展示 |
| **P3** ✅ | 参数绑定 + `INSERT`（Data 块上传）+ 流式游标 + `cancel` | 命名/位置参数、批量插入、流式游标、取消全部可用 |
| **P4** 🔶 | 更多类型 + LZ4 压缩 + TLS + 连接池 | 类型/LZ4 压缩/连接池已完成；TLS 待续 |

## 9. 未来演进（非本期）

- **强类型结果 API**：`Row` 提供类型化取值（`get_int64(col)` / `get_string(col)`），
  底层仍以 String 兼容层实现。
- **异步并发**：多查询并行需每查询独立连接或连接级串行队列——基础版本单连接串行，
  与 `@async` 运行时配合时注意「同一连接同时只允许一个读任务」约束。
- **Progress / 日志回调**：暴露 `on_progress` 回调，实现 `clickhouse-client` 风格的进度输出。

## 10. 测试与演示策略

- **单元测试**（无需服务器）：VarUInt 边界（0 / 127 / 128 / 2^63）、String 含多字节 UTF-8、
  块头与列头编解码、各类型二进制解码（构造内存 Buffer 喂给解码器）。
- **集成测试**（真实服务器）：Docker 启动 `clickhouse/clickhouse-server:24.8` 并暴露
  `9000:9000`；新增 `CLICKHOUSE_NATIVE_HOST` / `CLICKHOUSE_NATIVE_PORT` 环境变量（默认
  `127.0.0.1:9000`），沿用 `CLICKHOUSE_INTEGRATION=1` 门控；断言与现有 `integration/`
  同风格。覆盖：ping、SELECT 基础类型、无结果空列头、语法错误 → ServerError、断连重连。
- **demo**：`cmd/main` 新增 `--native` 参数分支（或独立 `cmd/main_native`），复用现有
  `demo_drv` 场景（建表 → 插入 → 查询 → 清理），展示与 HTTP 版相同数据路径。
- **CI**：`.github/workflows/check.yml` 增加 native 集成 job（`docker run -p 9000:9000`）。

## 11. 风险与待确认

1. **revision 兼容性**：ClickHouse 24.8 与 25.x 对 ClientInfo/握手字段要求略有差异，
   取 54468 需在两类服务器上实测；必要时降级为 54447（不含 ClientInfo）或 54455。
2. **Decimal128 编码**：128 位小端需要 `Bytes` 手动拼装，注意 MoonBit `Int64` 溢出边界。
3. **UUID 字节序**：ClickHouse UUID 混合端序（前 8 字节小端、后 8 字节大端），实现时
   需对照官方 `clickhouse-cpp` 行为。
4. **单连接串行**：基础版本不承诺并发查询；连接池（P4）复用 HTTP 版 `ConnectionPool`
   的 acquire/release/discard 模式。
5. **API 语义差异**：`connect` 从「纯配置」变为「真实建连」，文档与 demo 需明确提示。

## 12. 验收清单（基础版本）

- [x] `moon check --target native` 通过，`moon info && moon fmt` 无意外 diff
- [x] `native/` 单元测试覆盖编解码原语、块解码与类型解码（22 个）
- [x] 真实容器上 `ping` / `execute_query` / 错误密码 / 语法错误 全部符合预期
- [x] 与 HTTP 版共用 `DbError`、`ResultSet` 语义，demo 展示两种连接方式等价数据
- [x] `NativeConnection::insert` 批量 Data 块上传（含 Nullable/Date/数值/字符串）
- [x] 命名 `{name: Type}` / 位置 `?` 参数绑定；`execute_stream` 流式游标与提前关闭
- [x] README 三语补充 native 章节与快速开始示例
