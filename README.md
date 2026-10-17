# liuhuo23/clickhouse-driver

[English](README.md) | [简体中文](README.zh-CN.md)

A ClickHouse **HTTP** driver for MoonBit — simple and stateless. Validated on
Linux and macOS today.

## Overview

- Uses the native ClickHouse HTTP interface (default port **8123**).
- Responses parsed as **TabSeparatedWithNamesAndTypes** so column names and
  types come back automatically — no manual type mapping on the client side.
- Two flavors of parameter binding, both backed by ClickHouse's native
  `{name: Type}` placeholder protocol:
  - `execute_query(sql, params?)` — **named** binding with `{name}` /
    `{name: Type}`. Untyped `{name}` defaults to `String`, so table names,
    identifiers, and string columns read naturally.
  - `execute(sql, values)` — **positional** binding with `?`. Concise form
    for inline-VALUES INSERTs and other queries that repeat the same
    parameter shape across rows — no need to invent unique names per row.
  Values are passed as `param_<key>=<value>` URL parameters and substituted
  server-side (quoted and escaped automatically).
- Proper error handling via MoonBit `try-catch` with a `DbError` suberror
  (`ServerError` / `ConnectionError`).
- Simple per-request connections by default — no persistent state to leak;
  opt into keep-alive reuse with `conn.pool(size)` for high-QPS workloads.
- **Real batch inserts** — `insert()` streams the row data (TSV or
  JSONEachRow) as the HTTP request body instead of inlining VALUES literals.
- **Streaming reads** — `execute_stream()` returns a row-by-row cursor, so
  large result sets don't have to fit in memory.
- **TLS** — `https=true` connects over TLS; `skip_verify=true` disables
  certificate verification for self-signed setups.
- **Request timeouts** — `timeout_ms` bounds every request (and each
  streaming `next()`), raising `ConnectionError` on timeout.
- **Response compression** — `compress=true` asks ClickHouse for LZ4
  (`compress=1`); the driver decompresses automatically.
- **Connection pooling** — `conn.pool(size)` reuses keep-alive connections
  across requests, avoiding repeated TCP/TLS handshakes.
- Compatible with ClickHouse 22.x+ (the HTTP interface has been stable since
  21.x).

## Platform support

| Platform | Status |
| -------- | ------ |
| Linux | ✅ Supported |
| macOS | ✅ Supported |
| Windows | ❌ Not validated yet (relies on `moonbitlang/async` native backend) |

CI currently runs `moon check` and `moon test` on Linux and macOS only. Add
`windows-latest` to the matrix in `.github/workflows/check.yml` once Windows
support is ready.

## Installation

Add the dependency to your `moon.mod` (or run
`moon add liuhuo23/clickhouse-driver`):

```text
import {
  "liuhuo23/clickhouse-driver@0.4.0",
}
```

Then import it in your package's `moon.pkg`:

```text
import {
  "liuhuo23/clickhouse-driver" @lib,
}
```

## Quick start

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

  // 1. Health check
  conn.ping()

  // 2. SELECT — columns come back automatically. Untyped placeholders
  //    default to String, so table names / string values need no type tag.
  let result = conn.execute_query(
    "SELECT id, name FROM users WHERE created_at > {lo: DateTime} LIMIT {n: UInt32}",
    params=Map::from_array([
      ("lo", "2024-01-01 00:00:00"),
      ("n", "10"),
    ]),
  )

  // 3. Inspect schema
  for col in result.columns {
    println(col.name + " : " + col.type_)
  }

  // 4. Iterate rows (each cell is a string)
  for row in result.rows {
    println(row.values)
  }

  // 5. Or convert to row maps keyed by column name
  for m in result.to_map() {
    println(m["name"])
  }

  // 6. INSERT — same `?` placeholder convention as other DB drivers.
  ignore(
    conn.execute(
      "INSERT INTO users (id, name) VALUES (?, ?), (?, ?)",
      ["1", "alice", "2", "bob"],
    ),
  )

  // 7. Bulk insert — streamed as the HTTP body (TSV by default).
  conn.insert(
    "users",
    ["id", "name"],
    [["3", "carol"], ["4", "dave"]],
  )

  // 8. Streaming read — one row at a time, no full buffering.
  let cur = conn.execute_stream("SELECT id, name FROM users")
  defer cur.close()
  while true {
    match cur.next() {
      None => break
      Some(row) => println(row.values)
    }
  }
}
```

## Native protocol (TCP) driver

In addition to the HTTP interface, this project ships an experimental
**ClickHouse native TCP protocol** driver (port **9000**) in the `native/`
sub-package. It speaks the same binary protocol as `clickhouse-client`:

- **Persistent connection**: one handshake, then many queries over the same
  TCP socket (a natural fit for keep-alive reuse and connection pooling).
- **Binary transport**: no text round-trip; values are decoded from their
  native column encodings, so types stay exact.
- **Aligned API**: reuses the root package's `DbError` / `ResultSet` /
  `Column` / `Row` types, so migrating call sites is trivial.

Current capabilities: connect + handshake, `ping`, `execute_query` /
`execute` (named `{name: Type}` and positional `?` parameter binding),
`execute_stream` (lazy block-by-block cursor), `insert` (batch Data-block
upload) and `cancel`, with rich type support: UInt8–64, Int8–64, Float32/64,
String, FixedString, Date, Date32, DateTime, DateTime64, Enum8/16, Nullable,
Array (nested), Tuple, Map, Decimal32/64/128/256, UUID, IPv4, IPv6 (and
LowCardinality via server-side unwrapping), **LZ4 compression** (Data
blocks, `compress=true`), a **connection pool** (acquire/release,
`config.pool(size)`), server exception mapping, and graceful close.
TLS is planned for later stages.

### Quick start

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

To use it, import the sub-package in your `moon.pkg`:

```text
import {
  "liuhuo23/clickhouse-driver/native" @native,
}
```

### Differences from the HTTP driver

- `@native.connect(config)` **actually connects** (handshake included); the
  HTTP `connect` is config-only.
- One connection executes queries serially — do not run concurrent reads on
  the same `NativeConnection`.
- Errors use the same `DbError`: auth / syntax failures raise
  `DbError::ServerError(code, name, message)`; I/O and protocol problems raise
  `DbError::ConnectionError`.

### Demo

```bash
CLICKHOUSE_NATIVE=1 CLICKHOUSE_NATIVE_PORT=9000 moon run cmd/main
```

See `docs/native-protocol-design.md` for the full design and the staged
implementation plan (P0–P4).
## API reference

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

Builds a `Connection` config from explicit parameters. Does **not** open a
TCP connection — by default calls are stateless and open fresh HTTP
connections per request. All new options are optional, so existing call
sites keep working unchanged. Wrap it with `conn.pool(size)` when you want
to reuse connections (see [Connection pooling](#connection-pooling)).

| Parameter      | Type     | Description                                        |
| -------------- | -------- | -------------------------------------------------- |
| `host`         | `String` | Server hostname or IP                              |
| `port`         | `Int`    | HTTP port (default `8123`)                         |
| `user`         | `String` | Username                                           |
| `password`     | `String` | Password                                           |
| `database`     | `String` | Default database                                   |
| `client_name`  | `String` | Sent via `X-ClickHouse-Client-Name` header         |
| `timeout_ms`   | `Int`    | Per-request timeout in ms; `0` = no timeout        |
| `https`        | `Bool`   | Use TLS (`https://`); default `false`              |
| `skip_verify`  | `Bool`   | Skip TLS cert verification; default `false`        |
| `compress`     | `Bool`   | Request ClickHouse LZ4 compression; default `false`|

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

A lightweight config struct — no persistent socket. Every call opens a
short-lived HTTP connection and closes it on return. For connection reuse
across requests, see [Connection pooling](#connection-pooling).

#### `Connection::ping`

```moonbit nocheck
pub async fn ping(self : Connection) -> Unit raise
```

Sends `SELECT 1` and expects 200 OK. Lightweight health check.

#### `Connection::execute_query`

```moonbit nocheck
pub async fn execute_query(
  self : Connection,
  sql : String,
  params? : Map[String, String] = {},
) -> ResultSet raise
```

Executes any SQL statement (SELECT, DDL, inline-VALUES INSERT, ...) with
**named** parameter binding and returns the parsed result.

`params` is an optional map of named parameters. Each entry is sent as a
`param_<key>=<value>` URL parameter, and ClickHouse substitutes the value
into matching `{key: Type}` placeholders server-side. Values are
automatically quoted and escaped — pass them as raw strings.

For the common case where a parameter is a string (table name, identifier,
or string column value), the type can be omitted — `{name}` is treated as
`{name: String}` automatically. Use the explicit `{name: Type}` form only
when binding into a non-String column (numbers, dates, etc.).

Examples:

```moonbit nocheck
// No params
let r = conn.execute_query("SELECT version()")

// Single typed param (non-String column)
let r = conn.execute_query(
  "SELECT * FROM events WHERE id = {id: UInt64}",
  params=Map::from_array([("id", "42")]),
)

// Table-name param — untyped {tn} defaults to String
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

Executes SQL with **positional** `?` placeholders. Each `?` in the SQL is
bound to the next value in `values`, in order. The concise form for
inline-VALUES INSERTs and other queries that repeat the same parameter
shape across rows — no need to invent unique names per row.

All values are bound as `String`; ClickHouse coerces them to the target
column type on the server side (works for numbers, dates, and most common
scalar types). For non-String columns where coercion is not enough, fall
back to `execute_query` with explicit `{name: Type}` named binding.

Examples:

```moonbit nocheck
// Multi-row INSERT — same parameter shape repeated per row
ignore(conn.execute(
   "INSERT INTO events (id, ts, msg) VALUES (?, ?, ?), (?, ?, ?)",
   ["1", "2024-01-01 00:00:00", "hello",
    "2", "2024-01-02 00:00:00", "world"],
 ))

// Single-row with positional binding
ignore(conn.execute(
   "INSERT INTO events (id, name) VALUES (?, ?)",
   ["42", "alice"],
 ))
 ```

Raises:
- `DbError::ServerError(code, name, message)` — the server returned a
  non-2xx HTTP response (syntax error, unknown table, permission denied, …).
- `DbError::ConnectionError(String)` — network / I/O error.

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

Streams a batch insert to the server as the HTTP request body, instead of
inlining rows as VALUES literals in the SQL text. This is the right tool for
bulk loading — the body is streamed in chunks, so large inserts do not blow
up the SQL text size.

- `table` / `columns` are interpolated verbatim into the SQL — quote
  identifiers yourself if needed.
- Each element of `rows` is one row whose fields map positionally to
  `columns`. Values are sent as text and coerced by ClickHouse.
- `format` selects the wire format: `Tsv` (default, `FORMAT TSV`) or
  `Ndjson` (`FORMAT JSONEachRow`, one JSON object per line).

```moonbit nocheck
conn.insert(
  "users",
  ["id", "name", "created_at"],
  [
    ["1", "alice", "2024-01-01 00:00:00"],
    ["2", "bob",   "2024-01-02 00:00:00"],
  ],
)
```

#### `Connection::execute_stream`

```moonbit nocheck
pub async fn execute_stream(
  self : Connection,
  sql : String,
  params? : Map[String, String] = {},
) -> ResultSetCursor raise
```

Executes a query and returns a **streaming cursor** over the result rows.
Unlike `execute_query` (which buffers the whole result set in memory), the
response body is consumed lazily, one row at a time — ideal for large
SELECTs.

```moonbit nocheck
let cur = conn.execute_stream("SELECT * FROM events")
defer cur.close()
let cols = cur.columns()  // schema is available immediately
while true {
  match cur.next() {
    None => break
    Some(row) => println(row.values)
  }
}
```

`params` works exactly like `execute_query`. Always call `close()` (e.g. via
`defer`) to release the underlying HTTP connection. If the connection was
configured with `timeout_ms`, each `next()` call is also bounded by it.
Streaming is not supported together with `compress=true` (raises
`ConnectionError`) — use `execute_query` for compressed responses.

### Connection pooling

`Connection` opens a fresh TCP/TLS connection for every request. For
high-QPS workloads or remote/TLS servers, repeated handshakes add up —
`Connection::pool` reuses keep-alive connections:

```moonbit nocheck
let conn = @lib.connect(host="127.0.0.1", port=8123, user="default",
                        password="", database="default", client_name="app")
let pool = conn.pool(size=4)   // up to 4 concurrent connections
defer pool.close()

pool.ping()                                    // same API as Connection
let r = pool.execute_query("SELECT count() FROM events")
pool.insert("events", ["id", "ts"], [["1", "2024-01-01 00:00:00"]])
let cur = pool.execute_stream("SELECT * FROM events")  // cursor returns the
defer cur.close()                                        // connection on close
```

- `size` bounds concurrent connections; extra requests wait for a free one.
- Connections that fail are discarded and replaced, never reused.
- Idle connections are reused immediately; ones idle for more than 5s are
  validated with `GET /ping` before reuse, so a keep-alive socket closed by
  the server does not surface as a request failure.
- `pool.execute_stream` returns its connection when the stream is fully
  drained; an abandoned stream drops the connection instead.
- `pool.close()` closes idle connections; in-flight ones are closed on return.

`ConnectionPool` mirrors the `Connection` API:

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

No-op over HTTP. Each query is a single short-lived request, so there is no
persistent connection in which to send a cancel signal. Kept in the API
for symmetry with the previous native-TCP design.

#### `Connection::close`

```moonbit nocheck
pub fn close(self : Connection) -> Unit
```

No-op over HTTP. Use with `defer` for symmetry:

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

`columns` is populated when the response uses
`TabSeparatedWithNamesAndTypes` (which is what `execute_query` requests by
default). For DDL / INSERT statements the array is empty.

#### `ResultSet::to_map`

```moonbit nocheck
pub fn to_map(self : ResultSet) -> Array[Map[String, String]]
```

Converts the result to an array of per-row maps. Each element is a
`Map[String, String]` where keys are column names and values are the string
representation of the cell. Empty if `columns` is empty.

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

A single row. Each cell is a string representation of the underlying
ClickHouse value (e.g. `"42"`, `"2025-01-01 00:00:00"`, `"NULL"`).

### `Column`

```moonbit nocheck
///|
pub struct Column {
  name : String
  type_ : String
}
```

Column metadata parsed from `TabSeparatedWithNamesAndTypes`. `type_` is the
raw ClickHouse type string, e.g. `"UInt32"`, `"String"`, `"Nullable(Int64)"`.

## Error handling

```moonbit nocheck
try {
  conn.execute_query("SELECT * FROM no_such_table")
} catch {
  @lib.DbError::ServerError(code~, name=_, message~) =>
    println("server error: code=" + code.to_string() + " " + message)
  @lib.DbError::ConnectionError(msg) =>
    println("connection error: " + msg)
  _ => println("other error")
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

| Variant            | Fields                                    | When                                                                  |
| ------------------ | ----------------------------------------- | --------------------------------------------------------------------- |
| `ServerError`      | `code : Int`, `name : String`, `message : String` | Server returned a non-2xx HTTP response with an error body. |
| `ConnectionError`  | `String`                                  | Network / I/O error (connection refused, malformed response, …).       |

`code` is the HTTP status code (typically `400` for client errors like
syntax / unknown table, `500` for server errors). `name` is `"HTTPError"`.
`message` is the first 500 chars of the response body (which contains the
ClickHouse exception text).

## How it works

The driver issues one HTTP request per call:

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

No `Connection: close` is sent, so connections can be kept alive: the plain
`Connection` closes the socket after each call, while `ConnectionPool` reuses
the same socket for subsequent requests.

ClickHouse replies with `TabSeparatedWithNamesAndTypes`:

```
<col1>\t<col2>\t<col3>
<Type1>\t<Type2>\t<Type3>
<val1>\t<val2>\t<val3>
<val4>\t<val5>\t<val6>
...
```

The driver parses this into `ResultSet { columns, rows }`.

Why POST? ClickHouse's HTTP interface treats `GET` requests as `readonly`
(`For queries over HTTP, method GET implies readonly`). POST works for every
query type — SELECT, DDL, INSERT — so we use a single method.

Why URL params for named parameters? ClickHouse substitutes `{key: Type}`
placeholders in SQL with `param_<key>=<value>` URL parameters. The server
takes care of quoting and type coercion, so the driver can pass values as
raw strings without worrying about escaping.

## ClickHouse transactions

**ClickHouse has no traditional ACID transactions.** There is no
`BEGIN` / `COMMIT` / `ROLLBACK` and no `Serializable` isolation.
`INSERT … SELECT` is atomic at the part level. For data with versioning
semantics, use one of the special engines:

- `ReplacingMergeTree(version_column)` — keeps the row with the largest
  `version_column` after merge.
- `CollapsingMergeTree(sign_column)` — uses a `sign` column (`+1` insert,
  `-1` cancel) to collapse pairs of rows on merge.
- `VersionedCollapsingMergeTree(version, sign)` — like `CollapsingMergeTree`
  but order-independent.
- `SummingMergeTree` / `AggregatingMergeTree` — for state-aggregation
  patterns.

## Project nature

This is an **original project**. It references the [ClickHouse HTTP interface documentation](https://clickhouse.com/docs/en/interfaces/http) for protocol behavior; no third-party driver code was ported. An early prototype explored the Native TCP protocol; the current implementation uses HTTP for portability and simplicity.

| Resource | Link | License |
| -------- | ---- | ------- |
| ClickHouse (reference) | https://clickhouse.com/docs/en/interfaces/http | Apache-2.0 |
| This project | — | Apache-2.0 |

## Limitations

1. **No mid-query cancel** — once a request is sent, the driver has no
   handle to cancel it. Drop the connection if you must abort.
2. **Streaming reads are cursor-only** — `execute_stream()` streams rows
   lazily, but `execute_query()` still buffers the full result (capped at
   256 MB) because the driver needs the complete body for LZ4 decompression
   and text parsing.
3. **Compression + streaming don't mix yet** — `execute_stream()` raises
   `ConnectionError` when `compress=true`; use `execute_query()` for
   compressed responses.
4. **Response body size limit** — buffered responses are capped at 256 MB
   to avoid runaway memory. Queries returning more should use filters,
   aggregation, or `execute_stream()`.
5. **No insert progress / retries** — `insert()` streams the body in one
   shot; on failure the whole request must be retried.

## Run the example CLI

```sh
# Default connection (127.0.0.1:8123, user `default`)
moon run cmd/main

# Point it at any ClickHouse via environment variables
CLICKHOUSE_HOST=127.0.0.1 CLICKHOUSE_PORT=38123 \
CLICKHOUSE_USER=default CLICKHOUSE_PASSWORD=barn \
moon run cmd/main
```

The demo (`cmd/main/main.mbt`) walks through every major API:

- `ping()` health check and `close()` / `cancel()` semantics
- `execute_query()` — SELECT / DDL with **named** `{name: Type}` params
- `execute()` — **positional** `?` binding (inline VALUES)
- `insert()` — **streamed bulk insert** as the HTTP body, TSV and
  JSONEachRow formats
- `execute_stream()` — **row-by-row cursor** with immediate schema access
- `to_map()` — result rows as column-name maps
- Error handling — `ServerError` (missing table, syntax error) and
  `ConnectionError` caught with `try-catch`
- `compress=true` — LZ4-compressed responses decoded automatically
- `timeout_ms` — a slow query (`SELECT sleep(3)`) is cancelled after the
  configured timeout
- `https=true` — TLS connection (fails gracefully against a plain-HTTP
  server, succeeds against a TLS-enabled port)
- `conn.pool(size)` — pooled keep-alive connections with concurrent queries

## Integration tests (CI)

Unit tests: `moon test -p liuhuo23/clickhouse-driver` (offline, no ClickHouse).

Integration tests in `integration/` run **only in CI** against a ClickHouse
service container. GitHub Actions sets `CLICKHOUSE_INTEGRATION=1` and starts
`clickhouse/clickhouse-server:24.8` on port 8123.

| Workflow | Trigger | Jobs |
| -------- | ------- | ---- |
| `check.yml` | push/PR to `master` | `build` (unit) + `integration` (ClickHouse) |
| `publish.yml` | push tag / manual | `check` + `integration` → `publish` |

Push code or open a PR to run checks; push a tag matching `moon.mod` `version`
to publish (requires `MOONCAKES_MOONBIT_COMMUNITY_TOKEN` secret).