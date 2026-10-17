# Project Agents.md Guide

This is a [MoonBit](https://docs.moonbitlang.com) project:
**`liuhuo23/clickhouse-driver`** — a ClickHouse driver with **two transports**:

| Transport | Package | Port | State |
| --- | --- | --- | --- |
| HTTP interface | root package `.` | 8123 (8000) | mature |
| Native TCP protocol | `native/` | 9000 | feature-complete except TLS |

Both share the same result/error types (`Column` / `Row` / `ResultSet` /
`DbError`), so migrating a caller between the two is mostly a `connect` swap.

Module metadata lives in `moon.mod` (`version`, `preferred_target = "native"`,
dependency `moonbitlang/async`). The public API of each package is summarized
in its generated `pkg.generated.mbti` — never edit that file by hand.

## Public API

### HTTP driver (root package)

- `connect(host~, port~, user~, password~, database~, client_name~,
  timeout_ms?, https?, skip_verify?, compress?) -> Connection` — pure config,
  no socket is opened.
- `Connection::ping` / `execute_query` (named `{name: Type}` params) /
  `execute` (positional `?`) / `execute_stream` (row cursor) /
  `insert` (streamed TSV or JSONEachRow body) / `pool` / `cancel` / `close`.
- `ConnectionPool` mirrors every `Connection` query method.
- `ResultSet`, `ResultSetCursor`, `Row`, `Column`, `InsertFormat`, `DbError`
  (`ServerError` / `ConnectionError`).

### Native driver (`native/`)

- `native_config(host~, port? = 9000, user~, password~, database?,
  client_name?, timeout_ms?, compress?) -> NativeConfig`.
- `connect(NativeConfig) -> NativeConnection` — **actually opens TCP and
  performs the handshake** (unlike the HTTP `connect`).
- `NativeConnection::ping` / `execute_query` / `execute` / `execute_stream` /
  `insert` / `cancel` / `close` / `server_version` / `server_timezone`.
- `NativeConfig::pool(size?) -> NativeConnectionPool`, with matching query
  methods and `NativePooledCursor`.
- Results reuse `@lib.ResultSet` / `@lib.Row` / `@lib.Column`; errors reuse
  `@lib.DbError`.

## Project Structure

- Root package (`./`): HTTP driver.
  - `clickhouse-driver.mbt` — implementation (HTTP request building, TSV
    parsing, LZ4 response decompression, connection pool, parameter binding).
  - `clickhouse-driver_test.mbt` — blackbox tests (external API only).
    **Currently a placeholder; add real blackbox coverage here.**
  - `clickhouse-driver_wbtest.mbt` — whitebox tests for parsing/encoding
    internals.
  - `moon.pkg` — package dependencies.
- `native/` — native TCP protocol driver, split by protocol layer:
  - `native.mbt` — public API (`NativeConfig` / `NativeConnection`).
  - `protocol.mbt` — packet types, revision constants, VarUInt / fixed-width
    primitives; `handshake.mbt` — Hello + Addendum.
  - `block.mbt` — Block / column-header codec; `types.mbt` — value decoding
    (30+ ClickHouse types, unknown types raise `ConnectionError`);
    `types_encode.mbt` — symmetric encoding for INSERT.
  - `query.mbt` — Query packet + result accumulation; `stream.mbt` — streaming
    cursor; `insert.mbt` — Data-block upload; `pool.mbt` — connection pool;
    `server_error.mbt` — Exception packet -> `ServerError`.
  - `compression.mbt` — LZ4 + CityHash128-framed blocks; `cityhash.mbt` —
    ClickHouse CityHash_v1_0_2 port; `params.mbt` — query parameter encoding.
  - `native_wbtest.mbt` — whitebox tests for the protocol layers.
- `integration/` — tests against a **real ClickHouse server**:
  `integration_test.mbt` (HTTP), `native_integration_test.mbt` (TCP),
  `support.mbt` (non-test markers that keep package imports alive).
- `cmd/main/` — runnable demo CLI; `main.mbt` is the HTTP demo (default),
  `native_demo.mbt` runs with `CLICKHOUSE_NATIVE=1`.
- `docs/` — design/report material. Only `native-protocol-design.md` is
  tracked (it is linked from the README); PDFs, the older
  `clickhouse-driver-项目说明.md` submission draft, and `docs/superpowers/`
  are gitignored working files.
- `.github/` — CI: `_check.yml` (lint + unit tests, reusable),
  `_integration.yml` (Docker-backed integration, reusable), `check.yml`
  (PR/push matrix), `publish.yml` (tag-triggered), plus `actions/`
  (`setup-moonbit`, `start-clickhouse`). `docker-compose.yml` and
  `.devcontainer/` provide the local ClickHouse / dev environment.
- `.githooks/pre-commit` runs `moon check`; enable with
  `git config core.hooksPath .githooks`.

## Coding convention

- MoonBit code is organized in block style, each block separated by `///|`;
  block order is irrelevant.
- Keep deprecated blocks in `deprecated.mbt` in each directory.
- Document every public API block with a `///|` doc comment so `moon info` and
  generated docs stay accurate.
- New code belongs in a file that matches its responsibility. The HTTP
  implementation is currently one large file; splitting it into focused files
  (`http.mbt`, `pool.mbt`, `params.mbt`, `tsv.mbt`, `lz4.mbt`, ...) is welcome
  and safe because files in a package share one namespace.
- The native package is the reference for layering: one protocol concern per
  file, package-private protocol primitives, `priv` structs unless a type is
  part of the public API.

## Known limitations / gotchas

- **Native `timeout_ms` bounds each public operation** (`connect`, `ping`,
  `execute_query`, `insert`, and each cursor `next` / `close`). A timed-out
  native connection is left mid-packet and must be closed; the pooled path
  discards it automatically.
- Native has **no TLS** (`secure` / port 9440) and no settings passthrough yet.
- `NativeConfig.compress = true` uses a literal-only LZ4 encoder (valid but
  not smaller) and does not verify CityHash128 checksums.
- HTTP `execute_stream` rejects `compress = true`; use `execute_query`.
- `?` positional binding is a byte scan, not a SQL parser: a literal `?`
  inside a string will be rewritten. `execute_query` with named parameters is
  the safe escape hatch.
- HTTP error mapping now uses ClickHouse's real exception code when the
  server reports one (`X-ClickHouse-Exception-Code` header or the `Code: N.`
  body prefix) with `name = "DB::Exception"`; otherwise it falls back to the
  HTTP status with `name = "HTTPError"`. Native always uses the exception
  packet's code/name.
- HTTP sends SQL in the `query=` URL parameter, so very long statements can
  hit proxy request-line limits. `insert` streams the body and is not affected.
- HTTP pool reuse is cheap: fresh idle sockets are returned directly, while
  sockets idle for more than 5 seconds are validated with `GET /ping` first.
- Both integration suites read `CLICKHOUSE_*` env vars; native defaults to
  `127.0.0.1:39000` and user/password `default` / `barn` (the compose setup).

## Tooling

- `moon fmt` formats; `moon fmt --check` verifies CI-style without writing.
  Moon 0.1.20261012+ applies language-compatibility migrations during
  formatting (`Int` -> `Int32`, `UInt` -> `UInt32`, optional parameters
  `name?` -> `name~`); keep the tree migrated so `moon fmt --check` stays
  green. Generated `.mbti` files still normalize these back to `Int` / `?`.
- `moon check --target native` type-checks (also what the pre-commit hook runs;
  `moon check` alone is equivalent because of `preferred_target`).
- `moon ide` provides navigation: `outline`, `peek-def`, `find-references`,
  `doc`. See $moonbit-agent-guide for details.
- `moon info` regenerates `pkg.generated.mbti`. If the file does not change,
  the public API did not change — a useful refactoring signal.
- In the last step, run `moon info && moon fmt` and review the `.mbti` diff.

## Testing

- **Unit tests (no server)** — both packages must be run explicitly; `-p <root>`
  does **not** include subpackages:

  ```bash
  moon test -p liuhuo23/clickhouse-driver --target native
  moon test -p liuhuo23/clickhouse-driver/native --target native
  ```

- **Integration tests** need a real ClickHouse. `docker-compose.yml` (or the
  CI action) exposes HTTP 8123 and native 9000 on host port **39000**:

  ```bash
  CLICKHOUSE_INTEGRATION=1 moon test integration/ --target native
  ```

  HTTP tests read `CLICKHOUSE_HOST` / `CLICKHOUSE_PORT` / `CLICKHOUSE_USER` /
  `CLICKHOUSE_PASSWORD` / `CLICKHOUSE_DATABASE`; native tests read
  `CLICKHOUSE_NATIVE_HOST` / `CLICKHOUSE_NATIVE_PORT` (default
  `127.0.0.1:39000`). Plain `moon test` at the repo root includes
  `integration/` and fails loudly without a server.

- MoonBit snapshot testing: after output changes run `moon test --update` and
  review the snapshot diffs.
- Prefer `assert_eq` / `assert_true(pattern is Pattern(...))` for stable
  results. For structured debug output derive `Debug` and use
  `debug_inspect`; reserve a manual `Show` for real display formats.
- `moon coverage analyze > uncovered.log` shows uncovered code.

## CI expectations

- `_check.yml` runs `moon check --target native`, unit tests for **both**
  packages, and `moon fmt --check` + `moon info && git diff --exit-code`.
  Keep the tree format-clean under the current toolchain, otherwise the lint
  job fails.
- `_integration.yml` starts `clickhouse/clickhouse-server` (24.8 and latest)
  with HTTP 8123 and native 39000 and runs `moon test integration/`.
- `publish.yml` runs on tags; the tag must equal `v<version>` from `moon.mod`.
