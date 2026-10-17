///|
/// ClickHouse HTTP driver for MoonBit.
///
/// Uses the native ClickHouse HTTP interface (default port 8123, also works on
/// 8000) over HTTP/1.1 — plain `http://` or `https://` (TLS). Responses are
/// parsed as TabSeparatedWithNamesAndTypes, so column names and types come
/// back automatically — no binary protocol overhead.
///
/// Public API:
///   connect → Connection  (lightweight config struct; no persistent socket)
///   conn.ping()           — SELECT 1 round-trip
///   conn.execute_query()  — SELECT/DDL, returns ResultSet
///   conn.execute()        — positional `?` binding (inline VALUES)
///   conn.execute_stream() — row-by-row streaming cursor
///   conn.insert()         — real batch insert (streamed TSV/JSONEachRow body)
///   conn.cancel()         — no-op (HTTP doesn't expose mid-query cancel)
///   conn.close()          — no-op

///|
/// Connection config for ClickHouse over HTTP.
/// Each query opens its own short-lived HTTP connection.
pub struct Connection {
  host : String
  port : Int32
  user : String
  password : String
  database : String
  client_name : String
  /// Per-request timeout in milliseconds; `0` (default) means no timeout.
  timeout_ms : Int32
  /// Use `https://` instead of `http://` (TLS).
  https : Bool
  /// Skip TLS certificate verification (only meaningful when `https=true`).
  skip_verify : Bool
  /// Ask the server to compress responses with ClickHouse-native LZ4
  /// (`compress=1`).
  compress : Bool
}

///|
/// Build a Connection config from explicit connection params.
/// Does NOT open a TCP connection — calls are stateless.
///
/// Optional params (all backward compatible):
///   timeout_ms — request timeout in ms; `0` = no timeout (default)
///   https      — use TLS (`https://`); default false
///   skip_verify— skip TLS certificate verification; default false
///   compress   — request ClickHouse LZ4 response compression; default false
pub fn connect(
  host~ : String,
  port~ : Int32,
  user~ : String,
  password~ : String,
  database~ : String,
  client_name~ : String,
  timeout_ms~ : Int32 = 0,
  https~ : Bool = false,
  skip_verify~ : Bool = false,
  compress~ : Bool = false,
) -> Connection {
  {
    host,
    port,
    user,
    password,
    database,
    client_name,
    timeout_ms,
    https,
    skip_verify,
    compress,
  }
}

///|
/// No-op for HTTP: each call opens a fresh short-lived connection.
pub fn Connection::close(self : Connection) -> Unit {
  ignore(self)
}

///|
/// No-op for HTTP: queries can't be cancelled mid-flight without persistent TCP.
pub fn Connection::cancel(self : Connection) -> Unit {
  ignore(self)
}
