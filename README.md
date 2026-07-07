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
- Every call opens a short-lived HTTP connection — no persistent state to
  leak, no need to reconnect after long idle periods.
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

Add the dependency to your `moon.mod`:

```text
import {
  "moonbitlang/async@0.20.1",
}
```

Then in your package's `moon.pkg`:

```text
import {
  "moonbitlang/async/http",
  "moonbitlang/core/buffer",
  "moonbitlang/core/encoding/base64",
  "moonbitlang/core/encoding/utf8",
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
}
```

## API reference

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

Builds a `Connection` config from explicit parameters. Does **not** open a
TCP connection — calls are stateless and open fresh HTTP connections per
request.

| Parameter    | Type     | Description                            |
| ------------ | -------- | -------------------------------------- |
| `host`       | `String` | Server hostname or IP                 |
| `port`       | `Int`    | HTTP port (default `8123`)             |
| `user`       | `String` | Username                               |
| `password`   | `String` | Password                               |
| `database`   | `String` | Default database                       |
| `client_name`| `String` | Sent via `X-ClickHouse-Client-Name` header |

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

A lightweight config struct — no persistent socket. Every call opens a
short-lived HTTP connection and closes it on return.

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
Connection: close
Content-Length: 0
```

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

1. **Streaming / progress callbacks** — HTTP returns the full result
   before the connection closes. There is no way to stream partial results
   or receive row-by-row progress callbacks.
2. **No mid-query cancel** — once a request is sent, the driver has no
   handle to cancel it. Drop the connection if you must abort.
3. **Inline-VALUES only** — large bulk inserts (≫ a few thousand rows)
   should switch to ClickHouse's native TCP protocol for the actual data
   transfer, or use the `client_name` HTTP insert API which supports a
   body-streaming variant via POST with content-type `application/x-ndjson`.
   This driver sticks to the simplest form: SQL with literal VALUES, with
   the literals coming from `params`.
4. **Response body size limit** — `read_response_body` enforces a 256 MB
   cap to avoid runaway memory. Queries returning more should use filters or
   aggregation.

## Run the example CLI

```sh
moon run cmd/main
```

The CLI demo (`cmd/main/main.mbt`) walks through ping, a parameterised
SELECT, `CREATE TABLE`, an inline-VALUES INSERT with parameters, a
parameterised `SELECT … WHERE …`, exception handling, and cleanup.