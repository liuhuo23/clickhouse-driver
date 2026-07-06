# liuhuo23/clickhouse-driver

[English](README.md) | [简体中文](README.zh-CN.md)

A ClickHouse native TCP protocol driver for MoonBit.

## Overview

- Native protocol (rev 54429), compatible with ClickHouse 20.x – 23.x.
- Full type support: `UInt/Int 8–256`, `Float32/64`, `Bool`, `String`,
  `FixedString(N)`, `Date/Date32/DateTime/DateTime64`, `Decimal(P,S)`,
  `UUID`, `IPv4/IPv6`, `Enum8/16`, `Nullable(T)`, `Array(T)`, `Tuple(...)`,
  `Map(K,V)`, `LowCardinality(T)`, `SimpleAggregateFunction(func,T)`.
- Sends `Client::Ping` health checks and parses `Server::Pong`.
- Proper error handling via MoonBit `try-catch` with a `DbError` suberror
  (`ServerError` / `ConnectionError`).
- Full DDL support (`CREATE` / `DROP` / `TRUNCATE`).
- Works against the `default` and `system` databases out of the box.

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
  "moonbitlang/async/socket",
  "moonbitlang/core/buffer",
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
    port=9000,
    user="default",
    password="",
    database="default",
    client_name="my-app",
  )
  defer conn.close()

  // 1. Health check
  conn.ping()

  // 2. Run a query
  let result = conn.execute_query("SELECT id, name FROM users LIMIT 10")

  // 3. Inspect schema
  for col in result.columns {
    println(col.name + " : " + col.type_)
  }

  // 4. Iterate rows
  for row in result.rows {
    // row.values : Array[String]
    println(row.values)
  }

  // 5. Convert to row maps (each row -> Map[col_name -> value])
  let rows = result.to_map()
  for m in rows {
    println(m["name"])
  }
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

Establishes a TCP connection and performs the ClickHouse handshake.

| Parameter    | Type     | Description                            |
| ------------ | -------- | -------------------------------------- |
| `host`       | `String` | Server hostname or IP                 |
| `port`       | `Int`    | TCP port (default `9000`)              |
| `user`       | `String` | Username                               |
| `password`   | `String` | Password                               |
| `database`   | `String` | Default database                       |
| `client_name`| `String` | Identifier sent to the server          |

### `Connection`

```moonbit nocheck
pub struct Connection { ... }
```

#### `Connection::ping`

```moonbit nocheck
pub async fn ping(self : Connection) -> Unit raise
```

Sends a `Client::Ping` packet and waits for `Server::Pong`. Lightweight
health check; does not execute a query.

#### `Connection::execute_query`

```moonbit nocheck
pub async fn execute_query(
  self : Connection,
  sql : String,
) -> ResultSet raise
```

Executes any SQL statement (`SELECT`, `INSERT`, `UPDATE`, `DELETE`, DDL) and
returns the parsed result. For non-`SELECT` statements the returned `rows`
is typically empty.

Raises:
- `DbError::ServerError(code, name, message)` — the server rejected the query
  (syntax error, unknown table, permission denied, …).
- `DbError::ConnectionError(String)` — protocol / I/O error.
- Underlying I/O errors from the network layer.

#### `Connection::close`

```moonbit nocheck
pub fn close(self : Connection) -> Unit
```

Closes the underlying TCP connection. Use with `defer`:

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

#### `ResultSet::to_map`

```moonbit nocheck
pub fn to_map(self : ResultSet) -> Array[Map[String, String]]
```

Converts the result to an array of per-row maps. Each element is a
`Map[String, String]` where keys are column names and values are the
string representation of the cell value.

```moonbit nocheck
let rows = result.to_map()
for m in rows {
  let name = m["name"]   // -> String? (use get_or_default if you need non-optional)
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

Column metadata. `type_` is the raw ClickHouse type string, e.g.
`"Nullable(Int64)"`, `"LowCardinality(String)"`, `"DateTime64(3)"`.

## Error handling

```moonbit nocheck
try {
  conn.execute_query("SELECT * FROM no_such_table")
} catch {
  @lib.DbError::ServerError(code~, name~, message~) =>
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
} derive(@debug.Debug)
```

| Variant            | Fields                                    | When                                                                  |
| ------------------ | ----------------------------------------- | --------------------------------------------------------------------- |
| `ServerError`      | `code : Int`, `name : String`, `message : String` | Server returned an `Exception` packet (query rejected).       |
| `ConnectionError`  | `String`                                  | Protocol / I/O error (malformed packet, unexpected EOF, etc.).        |

The `code` corresponds to the ClickHouse error code (e.g. `60` for
`UNKNOWN_TABLE`, `62` for `SYNTAX_ERROR`, `81` for `DATABASE_ACCESS_DENIED`).

## Supported ClickHouse types

Values are returned as strings. The table shows the wire format and the
resulting string representation.

| ClickHouse type        | Wire format                                | String representation              |
| ---------------------- | ------------------------------------------ | ---------------------------------- |
| `UInt8`                | 1 byte                                     | decimal number                     |
| `UInt16`               | 2 bytes LE                                 | decimal number                     |
| `UInt32`               | 4 bytes LE                                 | decimal number                     |
| `UInt64`               | 8 bytes LE                                 | decimal number                     |
| `Int8`                 | 1 byte (signed)                            | decimal number                     |
| `Int16`                | 2 bytes LE (signed)                        | decimal number                     |
| `Int32`                | 4 bytes LE (signed)                        | decimal number                     |
| `Int64`                | 8 bytes LE (signed)                        | decimal number                     |
| `Int128` / `Int256`    | 16 / 32 bytes                              | `<Int128>` / `<Int256>` placeholder|
| `UInt128` / `UInt256`  | 16 / 32 bytes                              | `<UInt128>` / `<UInt256>` placeholder|
| `Float32`              | 4 bytes LE (IEEE 754)                      | decimal number                     |
| `Float64`              | 8 bytes LE (IEEE 754)                      | decimal number                     |
| `Bool`                 | 1 byte (`0` = false, `1` = true)           | `"true"` / `"false"`               |
| `String`               | varuint length + bytes                     | UTF-8 decoded (lossy)              |
| `FixedString(N)`       | `N` bytes                                  | UTF-8 decoded (lossy)              |
| `Date`                 | UInt16 LE (days since 1970-01-01)          | `"YYYY-MM-DD"`                     |
| `Date32`               | Int32 LE (days since 1970-01-01)           | `"YYYY-MM-DD"`                     |
| `DateTime`             | UInt32 LE (seconds since 1970-01-01)       | `"YYYY-MM-DD HH:MM:SS"`            |
| `DateTime64(scale)`    | Int64 LE (ticks of `10^-scale` seconds)    | `"YYYY-MM-DD HH:MM:SS.fff...`      |
| `Decimal(P,S)` P≤9     | Int32 LE                                   | decimal with `S` fractional digits |
| `Decimal(P,S)` P≤18    | Int64 LE                                   | decimal with `S` fractional digits |
| `Decimal128/256`       | 16 / 32 bytes                              | `<Decimal128(S)>` placeholder       |
| `UUID`                 | 16 bytes                                   | `"xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"` |
| `IPv4`                 | 4 bytes LE                                 | `"a.b.c.d"`                        |
| `IPv6`                 | 16 bytes                                   | 8 hex groups joined by `:`          |
| `Enum8` / `Enum16`     | 1 / 2 bytes (signed)                       | decimal number                     |
| `Nullable(T)`          | null flag byte + T                         | `"NULL"` or T's value              |
| `Array(T)`             | offsets (UInt64 × rows) + T elements      | `"[v1, v2, v3]"`                   |
| `Tuple(T1, T2, ...)`   | each sub-column separately                 | `"(v1, v2, v3)"`                   |
| `Map(K, V)`            | offsets + K + V (as `Array(Tuple(K,V))`)   | `"{k1:v1, k2:v2}"`                 |
| `LowCardinality(T)`    | version + dict + indices                   | the underlying T's value           |

### Notes

- **Null-map semantics** in `Nullable(T)`: `0` = NOT NULL, `1` = NULL
  (opposite of MySQL / PostgreSQL). The driver returns `"NULL"` for null
  cells and the underlying value otherwise.
- `SimpleAggregateFunction(func, T)` is read as the inner type `T`.
- String decoding is **lossy** (`@utf8.decode_lossy`): invalid UTF-8 bytes
  are replaced with U+FFFD rather than raising an error.
- `Int128` / `Int256` / `UInt128` / `UInt256` / `Decimal128` /
  `Decimal256` are not yet parsed (MoonBit lacks native 128/256-bit
  integers); the raw bytes are consumed and a placeholder string is
  returned so block-level parsing stays aligned.

## DDL, INSERT, UPDATE, DELETE

### DDL (works)

DDL statements are sent through the standard query path and work
out of the box:

```moonbit nocheck
ignore(conn.execute_query(
  "CREATE TABLE demo (id Int32, name String) ENGINE = MergeTree() ORDER BY id"
))
ignore(conn.execute_query("DROP TABLE IF EXISTS demo"))
ignore(conn.execute_query("TRUNCATE TABLE demo"))
```

### INSERT (not yet supported)

The native-protocol `INSERT` flow is different from `SELECT`:

1. Send `Client::Query` containing the `INSERT … VALUES …` statement.
2. The server responds with `EndOfStream` *expecting* a data block.
3. Send a `Client::Data` block whose schema matches the table, with the
   rows to insert.
4. Send a final empty `Client::Data` to signal end of input.

The current `execute_query` only sends the terminating empty data block,
so the server hangs waiting for the actual data. A dedicated
`insert_into(table, columns, rows)` helper is the natural next step.

### ALTER TABLE UPDATE / DELETE (not yet supported synchronously)

`ALTER TABLE … UPDATE` / `DELETE` in ClickHouse are **asynchronous
mutations**: the server enqueues the mutation and returns immediately
*without* sending `EndOfStream` until the mutation has been applied to
all parts. The synchronous `execute_query` will block forever on these.

Use `system.mutations` to poll progress, or use **lightweight** `DELETE` /
`UPDATE` (`DELETE FROM … WHERE …`) introduced in ClickHouse 22.10 — those
behave like normal queries and *do* return `EndOfStream` once finished.

## ClickHouse transactions

**ClickHouse has no traditional ACID transactions.** There is no
`BEGIN` / `COMMIT` / `ROLLBACK` and no `Serializable` isolation. The
mutations described above are atomic on a single part, but cross-part or
cross-table atomicity is not guaranteed.

For data with versioning semantics, use one of the special engines:

- `ReplacingMergeTree(version_column)` — keeps the row with the largest
  `version_column` after merge.
- `CollapsingMergeTree(sign_column)` — uses a `sign` column (`+1` insert,
  `-1` cancel) to collapse pairs of rows on merge.
- `VersionedCollapsingMergeTree(version, sign)` — like `CollapsingMergeTree`
  but order-independent.
- `SummingMergeTree` / `AggregatingMergeTree` — for state-aggregation
  patterns.

`INSERT … SELECT` is atomic, but only at the part level.

## Protocol details

- Client revision: `54429` (negotiated with the server on connect).
- Handshake: `Client::Hello` → `Server::Hello`.
- Query: `Client::Query` + a terminating empty `Client::Data` block.
- Response packet types handled:
  - `1` — `Server::Data` (schema and/or data block)
  - `2` — `Server::Exception` (error)
  - `3` — `Server::Progress` (rows, bytes, totals, elapsed)
  - `4` — `Server::Pong` (response to `Client::Ping`)
  - `5` — `Server::EndOfStream` (query finished)
  - `6` — `Server::ProfileInfo` (rows, blocks, bytes, applied limits)

Native protocol values are little-endian. Variable-length integers use the
standard ClickHouse LEB128 (`varuint`) encoding. `String` is encoded as
`varuint(length)` + bytes. `Date`, `DateTime`, etc. are fixed-size LE
integers. `Nullable(T)` is a per-row null flag byte followed by all rows of
the inner column contiguously (column-oriented, not row-oriented). `Array`
and `Map` first emit per-row cumulative offsets as `UInt64`, then all the
inner data contiguously. `LowCardinality` emits a version + dictionary +
per-row dictionary indices.

## Known limitations

1. `INSERT` is not implemented (see above).
2. `ALTER TABLE … UPDATE/DELETE` blocks the synchronous `execute_query`
   because the server does not send `EndOfStream` until the mutation
   finishes.
3. Some server errors (e.g. certain soft errors) are reported as a
   0-row `Data` block rather than an `Exception` packet; the
   `try-catch` infrastructure is in place but won't catch those cases.
4. `Int128` / `Int256` / `UInt128` / `UInt256` / `Decimal128` /
   `Decimal256` return placeholder strings; their bytes are still
   consumed correctly so block parsing stays aligned.
5. The driver only speaks the **native TCP** protocol. HTTP and the
   `mysql` / `postgres` / `interserver` ports are not supported.

## Run the example CLI

```sh
moon run cmd/main
```

The CLI demo (`cmd/main/main.mbt`) walks through ping, a `SELECT`,
DDL (`CREATE` / `DROP`), an attempted exception catch, and prints
notes about INSERT / ALTER UPDATE limitations. Edit the `host` / `port`
/ `user` / `password` / `database` fields at the top of `main.mbt` for
your environment.
