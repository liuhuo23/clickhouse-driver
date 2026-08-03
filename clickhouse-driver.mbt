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

// ============ Public data types ============

///|
/// Column metadata returned from a query.
pub struct Column {
  name : String
  type_ : String
}

///|
/// A single row of query results. Each value is a string representation.
pub struct Row {
  values : Array[String]
}

///|
/// Complete result set containing column metadata and rows.
pub struct ResultSet {
  columns : Array[Column]
  rows : Array[Row]
}

///|
/// Convert result to an array of row maps.
/// Each element is a Map[String, String] mapping column name → value for that row.
pub fn ResultSet::to_map(self : ResultSet) -> Array[Map[String, String]] {
  let result : Array[Map[String, String]] = []
  for r in 0..<self.rows.length() {
    let row_map : Map[String, String] = Map::Map([])
    for c in 0..<self.columns.length() {
      row_map.set(self.columns[c].name, self.rows[r].values[c])
    }
    result.push(row_map)
  }
  result
}

///|
/// Wire format used by `Connection::insert` for the request body.
pub(all) enum InsertFormat {
  /// `FORMAT TSV` — tab-separated values (recommended, compact).
  Tsv
  /// `FORMAT JSONEachRow` — one JSON object per line.
  Ndjson
}

///|
/// Streaming cursor returned by `Connection::execute_stream`.
///
/// The HTTP response body is consumed lazily, one row at a time, so queries
/// with large result sets do not need to be buffered in memory. Always call
/// `close()` when done to release the underlying connection.
///
/// `columns()` is available immediately after the cursor is created; rows are
/// read with repeated `next()` calls (returns `None` at end of stream).
pub struct ResultSetCursor {
  priv client : @http.Client
  priv cols : Array[Column]
  priv timeout_ms : Int
  /// Owning pool (if streamed through a `ConnectionPool`); `None` means the
  /// cursor owns its connection directly.
  priv pool : ConnectionPool?
  /// Single-element cell: `true` once `next()` has reached end-of-stream, so
  /// `close()` knows whether the connection can be reused or must be dropped.
  /// (Array is a reference type — the flag survives value copies of the cursor.)
  priv exhausted : Array[Bool]
}

///|
/// The columns (name + type) of the streamed query result.
pub fn ResultSetCursor::columns(self : ResultSetCursor) -> Array[Column] {
  self.cols
}

///|
/// Read the next row from the stream, or `None` at end of stream.
///
/// If the connection was configured with a positive `timeout_ms`, each `next()`
/// call is bounded by that timeout; a timeout raises `ConnectionError`.
pub async fn ResultSetCursor::next(self : ResultSetCursor) -> Row? {
  let mut result : Row? = None
  while true {
    let line : String? = if self.timeout_ms > 0 {
      @async.with_timeout(self.timeout_ms, () => self.client.read_until("\n")) catch {
        @async.TimeoutError =>
          raise ConnectionError(
            "stream read timed out after \{self.timeout_ms}ms",
          )
        err => raise err
      }
    } else {
      self.client.read_until("\n")
    }
    match line {
      None => {
        self.exhausted[0] = true
        break
      }
      Some(line) => {
        // Skip empty trailing lines (same rule as the buffered parser).
        let line = strip_cr(line)
        if line.length() == 0 {
          continue
        }
        let values = split_tsv_line(line)
        result = Some({ values, })
        break
      }
    }
  }
  result
}

///|
/// Close the streaming cursor and release the underlying connection.
///
/// For cursors created through a `ConnectionPool`, a fully-drained stream
/// returns the connection to the pool for reuse; a partially-read stream
/// drops the connection (the server may still be streaming data).
/// Idempotent — safe to call multiple times.
pub fn ResultSetCursor::close(self : ResultSetCursor) -> Unit {
  match self.pool {
    None => self.client.close()
    Some(pool) =>
      if self.exhausted[0] {
        pool.release(self.client)
      } else {
        pool.discard(self.client)
      }
  }
}

// ============ Connection pool ============

///|
/// A pool of reusable HTTP connections.
///
/// `Connection` opens a fresh TCP/TLS connection for every request; a pool
/// keeps up to `max_size` keep-alive connections and reuses them across
/// requests, avoiding repeated handshakes (especially valuable for TLS and
/// remote servers). All query methods mirror `Connection`.
///
/// The async runtime is single-threaded and cooperative, so the idle list is
/// only touched inside short synchronous sections — no locking is needed.
/// Requests beyond `max_size` wait for a free connection; connections that
/// fail are discarded and replaced, never handed back to the pool.
pub struct ConnectionPool {
  priv host : String
  priv port : Int
  priv user : String
  priv password : String
  priv database : String
  priv client_name : String
  priv timeout_ms : Int
  priv https : Bool
  priv skip_verify : Bool
  priv compress : Bool
  priv max_size : Int
  /// Bounds concurrent checked-out connections (permits == max_size).
  priv sem : @async.Semaphore
  /// Idle keep-alive connections ready for reuse.
  priv idle : Array[@http.Client]
  /// Set by `close()`; further operations close connections instead of
  /// reusing them.
  priv mut closed : Bool
}

///|
/// Build a `ConnectionPool` from this connection config.
/// `size` is the maximum number of concurrent connections (default 4;
/// values <= 0 are clamped to 4).
pub fn Connection::pool(self : Connection, size? : Int = 4) -> ConnectionPool {
  ConnectionPool::new(self, size)
}

///|
fn ConnectionPool::new(conn : Connection, size : Int) -> ConnectionPool {
  let size = if size <= 0 { 4 } else { size }
  {
    host: conn.host,
    port: conn.port,
    user: conn.user,
    password: conn.password,
    database: conn.database,
    client_name: conn.client_name,
    timeout_ms: conn.timeout_ms,
    https: conn.https,
    skip_verify: conn.skip_verify,
    compress: conn.compress,
    max_size: size,
    sem: @async.Semaphore(size),
    idle: [],
    closed: false,
  }
}

///|
/// No-op: pool requests are independent; kept for API symmetry with
/// `Connection`.
pub fn ConnectionPool::cancel(self : ConnectionPool) -> Unit {
  ignore(self)
}

///|
/// Close the pool: mark it closed and close all idle connections.
/// Connections still checked out are closed when they are returned.
pub fn ConnectionPool::close(self : ConnectionPool) -> Unit {
  self.closed = true
  for client in self.idle {
    client.close()
  }
  self.idle.clear()
}

///|
/// The maximum number of concurrent connections this pool will create.
pub fn ConnectionPool::max_size(self : ConnectionPool) -> Int {
  self.max_size
}

///|
/// Round-trip health check through the pool.
pub async fn ConnectionPool::ping(self : ConnectionPool) -> Unit {
  let (status, body) = self.pool_http_request("SELECT 1", Map([]))
  if status != 200 {
    raise ServerError(
      code=status,
      name="HTTPError",
      message=extract_error(body),
    )
  }
}

///|
/// Same as `Connection::execute_query` (named `{name: Type}` params), but
/// reuses pooled connections.
pub async fn ConnectionPool::execute_query(
  self : ConnectionPool,
  sql : String,
  params? : Map[String, String] = Map([]),
) -> ResultSet {
  self.do_request(apply_default_types(sql), params)
}

///|
/// Same as `Connection::execute` (positional `?` binding), pooled.
pub async fn ConnectionPool::execute(
  self : ConnectionPool,
  sql : String,
  values : Array[String],
) -> ResultSet {
  let (processed_sql, params) = bind_positional(sql, values)
  self.do_request(apply_default_types(processed_sql), params)
}

///|
/// Same as `Connection::insert` (streamed TSV/JSONEachRow body), pooled.
pub async fn ConnectionPool::insert(
  self : ConnectionPool,
  table : String,
  columns : Array[String],
  rows : Array[Array[String]],
  format? : InsertFormat = Tsv,
) -> Unit {
  let sql = build_insert_sql(table, columns, format)
  let conn = self.as_connection()
  conn.run_with_timeout(() => {
    self.insert_impl(build_url(conn, sql, Map([])), columns, rows, format)
  })
}

///|
/// Same as `Connection::execute_stream` (row-by-row cursor), pooled. The
/// cursor returns its connection to the pool on `close()` when the stream was
/// fully read, and drops it otherwise. `compress=true` is not supported for
/// streaming.
pub async fn ConnectionPool::execute_stream(
  self : ConnectionPool,
  sql : String,
  params? : Map[String, String] = Map([]),
) -> ResultSetCursor {
  guard !self.compress else {
    raise ConnectionError(
      "execute_stream does not support compress=true; use execute_query",
    )
  }
  let conn = self.as_connection()
  conn.run_with_timeout(() => {
    self.execute_stream_impl(apply_default_types(sql), params)
  })
}

///|
async fn ConnectionPool::do_request(
  self : ConnectionPool,
  sql : String,
  params : Map[String, String],
) -> ResultSet {
  let (status, body) = self.pool_http_request(sql, params)
  if status != 200 {
    raise ServerError(
      code=status,
      name="HTTPError",
      message=extract_error(body),
    )
  }
  parse_tsv_response(body)
}

///|
/// Send a request through a pooled connection; applies the configured timeout.
async fn ConnectionPool::pool_http_request(
  self : ConnectionPool,
  query : String,
  params : Map[String, String],
) -> (Int, String) {
  self
  .as_connection()
  .run_with_timeout(() => self.pool_http_request_impl(query, params))
}

///|
/// Actual round-trip over a borrowed connection (no timeout wrapping).
async fn ConnectionPool::pool_http_request_impl(
  self : ConnectionPool,
  query : String,
  params : Map[String, String],
) -> (Int, String) {
  let conn = self.as_connection()
  let path = build_url(conn, query, params)
  let client = self.acquire()
  let body_bytes : Bytes = b""
  let body_data : &@io.Data = body_bytes
  let response = client.post(path, body_data) catch {
    err => {
      self.discard(client)
      raise err
    }
  }
  let status = response.code
  let raw = read_response_bytes(client) catch {
    err => {
      self.discard(client)
      raise err
    }
  }
  self.release(client)
  let body = if self.compress {
    decompress_clickhouse_body(raw) catch {
      _ => raw
    }
  } else {
    raw
  }
  (status, @utf8.decode_lossy(body))
}

///|
/// Borrow a connection: reuse an idle one, create a new one (up to
/// `max_size`), or wait until one is returned. Broken connections are never
/// cached — callers use `discard` on failure.
async fn ConnectionPool::acquire(self : ConnectionPool) -> @http.Client {
  self.sem.acquire()
  if self.closed {
    self.sem.release()
    raise ConnectionError("connection pool is closed")
  }
  match self.idle.pop() {
    Some(client) => client
    None =>
      self.as_connection().open_client() catch {
        err => {
          self.sem.release()
          raise err
        }
      }
  }
}

///|
/// Return a healthy connection to the pool for reuse.
fn ConnectionPool::release(
  self : ConnectionPool,
  client : @http.Client,
) -> Unit {
  if self.closed {
    client.close()
  } else {
    self.idle.push(client)
  }
  self.sem.release()
}

///|
/// Close a broken or abandoned connection and free its pool slot.
fn ConnectionPool::discard(
  self : ConnectionPool,
  client : @http.Client,
) -> Unit {
  client.close()
  self.sem.release()
}

///|
/// The equivalent `Connection` config for this pool (shares request helpers).
fn ConnectionPool::as_connection(self : ConnectionPool) -> Connection {
  {
    host: self.host,
    port: self.port,
    user: self.user,
    password: self.password,
    database: self.database,
    client_name: self.client_name,
    timeout_ms: self.timeout_ms,
    https: self.https,
    skip_verify: self.skip_verify,
    compress: self.compress,
  }
}

///|
/// Streaming insert over a borrowed pool connection.
async fn ConnectionPool::insert_impl(
  self : ConnectionPool,
  path : String,
  columns : Array[String],
  rows : Array[Array[String]],
  format : InsertFormat,
) -> Unit {
  let client = self.acquire()
  let status = try {
    client.request(@http.RequestMethod::Post, path)
    for row in rows {
      let row_bytes = encode_row(columns, row, format)
      let row_data : &@io.Data = row_bytes
      client.write(row_data)
    }
    client.flush()
    client.end_request().code
  } catch {
    err => {
      self.discard(client)
      raise err
    }
  }
  if status != 200 {
    let body = read_response_body(client)
    self.discard(client)
    raise ServerError(
      code=status,
      name="HTTPError",
      message=extract_error(body),
    )
  }
  self.release(client)
}

///|
/// Streaming cursor setup over a borrowed pool connection.
async fn ConnectionPool::execute_stream_impl(
  self : ConnectionPool,
  sql : String,
  params : Map[String, String],
) -> ResultSetCursor {
  let conn = self.as_connection()
  let path = build_url(conn, sql, params)
  let client = self.acquire()
  let body_bytes : Bytes = b""
  let body_data : &@io.Data = body_bytes
  let response = client.post(path, body_data) catch {
    err => {
      self.discard(client)
      raise err
    }
  }
  if response.code != 200 {
    let body = read_response_body(client)
    self.discard(client)
    raise ServerError(
      code=response.code,
      name="HTTPError",
      message=extract_error(body),
    )
  }
  let names_line = match client.read_until("\n") {
    None => {
      self.discard(client)
      raise ConnectionError("empty response from server")
    }
    Some(line) => strip_cr(line)
  }
  let types_line = match client.read_until("\n") {
    None => {
      self.discard(client)
      raise ConnectionError("missing type header from server")
    }
    Some(line) => strip_cr(line)
  }
  let names = split_tsv_line(names_line)
  let types = split_tsv_line(types_line)
  let cols : Array[Column] = []
  for i in 0..<names.length() {
    let typ = if i < types.length() { types[i] } else { "" }
    cols.push({ name: names[i], type_: typ })
  }
  {
    client,
    cols,
    timeout_ms: self.timeout_ms,
    pool: Some(self),
    exhausted: [false],
  }
}

// ============ Errors ============

///|
/// Errors raised by the driver.
pub suberror DbError {
  /// Server returned a non-2xx HTTP response with an error body.
  ServerError(code~ : Int, name~ : String, message~ : String)
  /// Connection-level error (I/O, malformed response, unexpected EOF)
  ConnectionError(String)
} derive(Debug)

///|
/// 构造服务器错误（供 native 等子包复用）。
pub fn DbError::server_error(
  code~ : Int,
  name~ : String,
  message~ : String,
) -> DbError {
  ServerError(code~, name~, message~)
}

///|
/// 构造连接错误（供 native 等子包复用）。
pub fn DbError::connection_error(message : String) -> DbError {
  ConnectionError(message)
}

// ============ Connection ============

///|
/// Connection config for ClickHouse over HTTP.
/// Each query opens its own short-lived HTTP connection.
pub struct Connection {
  host : String
  port : Int
  user : String
  password : String
  database : String
  client_name : String
  /// Per-request timeout in milliseconds; `0` (default) means no timeout.
  timeout_ms : Int
  /// Use `https://` instead of `http://` (TLS).
  https : Bool
  /// Skip TLS certificate verification (only meaningful when `https=true`).
  skip_verify : Bool
  /// Ask the server to compress responses with ClickHouse-native LZ4
  /// (`compress=1`).
  compress : Bool
}

// ============ Public API ============

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
  port~ : Int,
  user~ : String,
  password~ : String,
  database~ : String,
  client_name~ : String,
  timeout_ms? : Int = 0,
  https? : Bool = false,
  skip_verify? : Bool = false,
  compress? : Bool = false,
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

///|
/// Round-trip health check: sends `SELECT 1` and expects 200 OK.
pub async fn Connection::ping(self : Connection) -> Unit {
  let (status, body) = self.http_request("SELECT 1", Map([]))
  if status != 200 {
    raise ServerError(
      code=status,
      name="HTTPError",
      message=extract_error(body),
    )
  }
}

///|
/// Execute any SQL statement (SELECT, DDL, INSERT, ...) and return the parsed
/// TabSeparatedWithNamesAndTypes result. For non-SELECT statements the
/// returned `rows` is typically empty.
///
/// `params` is an optional map of named parameters, substituted into the SQL
/// via ClickHouse's `{name: Type}` placeholder syntax. Each key/value is
/// passed as a `param_<key>=<value>` URL parameter; the server inserts the
/// value (quoted and escaped) into matching placeholders.
///
/// For the common case where a parameter is a string (table name, identifier,
/// or string column value), the type can be omitted and is defaulted to
/// `String` automatically — so `{tn}` and `{tn: String}` are equivalent. Use
/// the explicit `{name: Type}` form when binding into a non-String column.
///
/// Example:
///   execute_query("SELECT * FROM events WHERE ts > {lo}",
///     params=Map::from_array([("lo", "2024-01-01 00:00:00")]))
pub async fn Connection::execute_query(
  self : Connection,
  sql : String,
  params? : Map[String, String] = Map([]),
) -> ResultSet {
  self.do_request(apply_default_types(sql), params)
}

///|
/// Execute SQL with positional `?` placeholders. Each `?` in the SQL is
/// bound to the next value in `values`, in order. This is the concise form
/// for inline-VALUES INSERTs and other queries that repeat the same
/// parameter shape across rows — no need to invent unique names per row
/// and no `Map::from_array(...)` ceremony.
///
/// All values are bound as `String`; ClickHouse coerces them to the target
/// column type on the server side. This works for numbers, dates, and most
/// common scalar types. For non-String columns where coercion is not enough
/// (e.g. exotic parameterized types), fall back to `execute_query` with
/// explicit `{name: Type}` named binding.
///
/// Like `apply_default_types`, this is a byte scan — it does not parse SQL.
/// If a literal `?` appears inside a string, restructure the query to avoid
/// the literal (ClickHouse's HTTP syntax has no escape form for `?`).
///
/// Example:
///   execute("INSERT INTO t (a, b) VALUES (?, ?), (?, ?)",
///     ["1", "alice", "2", "bob"])
pub async fn Connection::execute(
  self : Connection,
  sql : String,
  values : Array[String],
) -> ResultSet {
  let (processed_sql, params) = bind_positional(sql, values)
  // apply_default_types turns any user-written `{name}` into `{name: String}`
  // (so named placeholders work too); the `{__pN: String}` placeholders we
  // just emitted already carry a type and pass through unchanged.
  self.do_request(apply_default_types(processed_sql), params)
}

///|
/// Execute a query and return a streaming cursor over the result rows.
///
/// Unlike `execute_query` (which buffers the whole result in memory), the
/// response body is read lazily row-by-row via `next()`. This is the right
/// tool for large SELECTs:
///
///   let cur = conn.execute_stream("SELECT * FROM events")
///   defer cur.close()
///   while let Some(row) = cur.next() {
///     println(row.values)
///   }
///
/// The cursor must be closed with `close()` (also via `defer`) to release the
/// underlying HTTP connection. Named `params` work exactly like
/// `execute_query`. Compressed responses (`compress=true`) are not supported
/// for streaming yet and raise `ConnectionError`.
pub async fn Connection::execute_stream(
  self : Connection,
  sql : String,
  params? : Map[String, String] = Map([]),
) -> ResultSetCursor {
  guard !self.compress else {
    raise ConnectionError(
      "execute_stream does not support compress=true; use execute_query",
    )
  }
  self.run_with_timeout(() => {
    self.execute_stream_impl(apply_default_types(sql), params)
  })
}

///|
/// Stream a batch insert to the server over the HTTP body (POST), instead of
/// inlining rows as VALUES literals in the SQL text.
///
/// `table` and `columns` are interpolated verbatim into the SQL (identifiers —
/// quote them yourself if needed). Each element of `rows` is one row whose
/// fields correspond positionally to `columns`. All values are sent as text;
/// ClickHouse coerces them to the target column types.
///
/// `format` selects the wire format (`Tsv` by default, `Ndjson` for
/// JSONEachRow). The body is streamed to the server in chunks, so large
/// inserts do not blow up the SQL text size. Raises `ServerError` on a
/// non-2xx response and `ConnectionError` on transport failures / timeouts.
///
/// Example:
///   conn.insert("users", ["id", "name"], [["1", "alice"], ["2", "bob"]])
pub async fn Connection::insert(
  self : Connection,
  table : String,
  columns : Array[String],
  rows : Array[Array[String]],
  format? : InsertFormat = Tsv,
) -> Unit {
  let sql = build_insert_sql(table, columns, format)
  self.run_with_timeout(() => {
    self.insert_impl(build_url(self, sql, Map([])), columns, rows, format)
  })
}

// ============ Internal request machinery ============

///|
async fn Connection::do_request(
  self : Connection,
  sql : String,
  params : Map[String, String],
) -> ResultSet {
  let (status, body) = self.http_request(sql, params)
  if status != 200 {
    raise ServerError(
      code=status,
      name="HTTPError",
      message=extract_error(body),
    )
  }
  parse_tsv_response(body)
}

///|
/// Run an async operation, enforcing `timeout_ms` when it is positive.
/// On timeout raises `ConnectionError` (the underlying task is cancelled).
async fn[X] Connection::run_with_timeout(
  self : Connection,
  f : async () -> X,
) -> X {
  if self.timeout_ms <= 0 {
    return f()
  }
  @async.with_timeout(self.timeout_ms, f) catch {
    @async.TimeoutError =>
      raise ConnectionError("request timed out after \{self.timeout_ms}ms")
    err => raise err
  }
}

///|
/// Send an HTTP request to ClickHouse and return (status_code, body_text).
/// Applies the connection-level timeout when configured.
async fn Connection::http_request(
  self : Connection,
  query : String,
  params : Map[String, String],
) -> (Int, String) {
  self.run_with_timeout(() => self.http_request_impl(query, params))
}

///|
/// Actual HTTP round-trip (no timeout wrapping).
async fn Connection::http_request_impl(
  self : Connection,
  query : String,
  params : Map[String, String],
) -> (Int, String) {
  let path = build_url(self, query, params)
  let client = self.open_client()
  // Always use POST with empty body — works for SELECT, DDL, INSERT, etc.
  // (ClickHouse rejects non-SELECT queries via GET as "readonly mode".)
  let body_bytes : Bytes = b""
  let body_data : &@io.Data = body_bytes
  let response = client.post(path, body_data)
  let status = response.code
  let raw = read_response_bytes(client)
  client.close()
  let body = if self.compress {
    // Decompress the ClickHouse LZ4 stream; non-200 error bodies may be plain
    // text, so fall back to the raw bytes when the stream is malformed.
    decompress_clickhouse_body(raw) catch {
      _ => raw
    }
  } else {
    raw
  }
  (status, @utf8.decode_lossy(body))
}

///|
/// Open a fresh HTTP client for one request, honoring TLS settings.
async fn Connection::open_client(self : Connection) -> @http.Client {
  let headers = self.common_headers()
  let trust = if self.skip_verify {
    @tls.NoVerification
  } else {
    @tls.SystemRoot
  }
  @http.Client::Client(self.uri(), headers~, trust~)
}

///|
/// Headers shared by all requests.
fn Connection::common_headers(self : Connection) -> Map[String, String] {
  let headers : Map[String, String] = Map::Map([])
  headers.set("Authorization", basic_auth_header(self.user, self.password))
  // No `Connection: close` — keep-alive lets `ConnectionPool` reuse sockets.
  headers.set("X-ClickHouse-Client-Name", self.client_name)
  headers
}

///|
/// Base URI for the connection, e.g. `http://host:8123/` or `https://host:8443/`.
fn Connection::uri(self : Connection) -> String {
  let scheme = if self.https { "https" } else { "http" }
  scheme + "://" + self.host + ":" + self.port.to_string() + "/"
}

///|
/// Streaming insert: send the encoded rows as the POST body.
async fn Connection::insert_impl(
  self : Connection,
  path : String,
  columns : Array[String],
  rows : Array[Array[String]],
  format : InsertFormat,
) -> Unit {
  let client = self.open_client()
  // Start the POST; only the request line + headers are sent so far.
  client.request(@http.RequestMethod::Post, path)
  for row in rows {
    let row_bytes = encode_row(columns, row, format)
    let row_data : &@io.Data = row_bytes
    client.write(row_data)
  }
  client.flush()
  let response = client.end_request()
  let status = response.code
  if status != 200 {
    let body = read_response_body(client)
    client.close()
    raise ServerError(
      code=status,
      name="HTTPError",
      message=extract_error(body),
    )
  }
  client.close()
}

///|
/// Streaming cursor setup: send the query and read the two header lines.
async fn Connection::execute_stream_impl(
  self : Connection,
  sql : String,
  params : Map[String, String],
) -> ResultSetCursor {
  let path = build_url(self, sql, params)
  let client = self.open_client()
  let body_bytes : Bytes = b""
  let body_data : &@io.Data = body_bytes
  let response = client.post(path, body_data)
  if response.code != 200 {
    let body = read_response_body(client)
    client.close()
    raise ServerError(
      code=response.code,
      name="HTTPError",
      message=extract_error(body),
    )
  }
  let names_line = match client.read_until("\n") {
    None => {
      client.close()
      raise ConnectionError("empty response from server")
    }
    Some(line) => strip_cr(line)
  }
  let types_line = match client.read_until("\n") {
    None => {
      client.close()
      raise ConnectionError("missing type header from server")
    }
    Some(line) => strip_cr(line)
  }
  let names = split_tsv_line(names_line)
  let types = split_tsv_line(types_line)
  let cols : Array[Column] = []
  for i in 0..<names.length() {
    let typ = if i < types.length() { types[i] } else { "" }
    cols.push({ name: names[i], type_: typ })
  }
  { client, cols, timeout_ms: self.timeout_ms, pool: None, exhausted: [false] }
}

///|
/// Replace `?` placeholders in SQL with auto-numbered named placeholders
/// (`{__p1: String}`, `{__p2: String}`, ...) and build the corresponding
/// `param_<name>=<value>` map from the positional `values` array. The
/// `__p` prefix keeps these synthetic names out of any user-defined
/// parameter namespace.
pub fn bind_positional(
  sql : String,
  values : Array[String],
) -> (String, Map[String, String]) {
  let bytes = @utf8.encode(sql)
  let buf = Buffer::Buffer(size_hint=bytes.length() * 2)
  let params : Map[String, String] = Map::Map([])
  let mut i = 0
  let mut counter = 0
  while i < bytes.length() {
    if bytes[i] == b'?' {
      counter = counter + 1
      let name = "__p" + counter.to_string()
      if counter - 1 < values.length() {
        params.set(name, values[counter - 1])
      }
      buf.write_bytes(@utf8.encode("{"))
      buf.write_bytes(@utf8.encode(name))
      buf.write_bytes(@utf8.encode(": String}"))
    } else {
      buf.write_byte(bytes[i])
    }
    i = i + 1
  }
  ignore(sql)
  (@utf8.decode_lossy(buf.to_bytes()), params)
}

// ============ SQL preprocessing ============

///|
/// Default unannotated `{name}` placeholders to `{name: String}`.
/// ClickHouse requires a type on every parameter placeholder; this lets
/// callers write `{tn}` instead of `{tn: String}` for the common case where
/// the value is a string (table name, identifier, string column value).
/// Placeholders that already specify a type (`{name: Type}`) are left alone.
///
/// This is a lightweight byte scan — it does not parse SQL. ClickHouse's
/// `{{` / `}}` escape syntax is recognized: `{{` emits as a single `{`
/// and `}}` as a single `}`, so `{{name}}` round-trips to literal
/// `{name}` in the final SQL instead of being misread as an untyped
/// placeholder. Unmatched `{` (no closing `}`) is copied verbatim.
pub fn apply_default_types(sql : String) -> String {
  let bytes = @utf8.encode(sql)
  let buf = Buffer::Buffer(size_hint=bytes.length() * 2)
  let mut i = 0
  while i < bytes.length() {
    let b = bytes[i]
    if b == b'{' {
      // {{ is ClickHouse's escape for a literal `{` — emit `{` and skip 2
      if i + 1 < bytes.length() && bytes[i + 1] == b'{' {
        buf.write_byte(b'{')
        i = i + 2
        continue
      }
      // Find the matching closing '}', scanning {{ and }} as escapes for
      // literal braces so they don't get mistaken for opener/closer.
      let inner = Buffer::Buffer(size_hint=8)
      let mut j = i + 1
      while j < bytes.length() {
        if bytes[j] == b'}' {
          if j + 1 < bytes.length() && bytes[j + 1] == b'}' {
            inner.write_byte(b'}')
            j = j + 2
            continue
          }
          break
        }
        if bytes[j] == b'{' && j + 1 < bytes.length() && bytes[j + 1] == b'{' {
          inner.write_byte(b'{')
          j = j + 2
          continue
        }
        inner.write_byte(bytes[j])
        j = j + 1
      }
      let content = buf_to_string(inner)
      if j >= bytes.length() {
        // Unmatched '{' — copy the rest verbatim
        buf.write_bytes(@utf8.encode(bytes_to_string(bytes, i, bytes.length())))
        break
      }
      if content.length() == 0 || content.contains(":") {
        // Empty or already typed — keep verbatim
        buf.write_bytes(@utf8.encode("{"))
        buf.write_bytes(@utf8.encode(content))
        buf.write_bytes(@utf8.encode("}"))
      } else {
        // Untyped placeholder — default to String
        buf.write_bytes(@utf8.encode("{"))
        buf.write_bytes(@utf8.encode(content))
        buf.write_bytes(@utf8.encode(": String}"))
      }
      i = j + 1
    } else if b == b'}' {
      // }} is ClickHouse's escape for a literal `}` — emit `}` and skip 2
      if i + 1 < bytes.length() && bytes[i + 1] == b'}' {
        buf.write_byte(b'}')
        i = i + 2
        continue
      }
      buf.write_byte(b)
      i = i + 1
    } else {
      buf.write_byte(b)
      i = i + 1
    }
  }
  ignore(sql)
  @utf8.decode_lossy(buf.to_bytes())
}

// ============ Batch insert encoding ============

///|
/// SQL text for a bulk insert: `INSERT INTO <table> (<cols>) FORMAT <fmt>`.
/// Identifiers are interpolated verbatim — quote them yourself if needed.
fn build_insert_sql(
  table : String,
  columns : Array[String],
  format : InsertFormat,
) -> String {
  let buf = Buffer::Buffer(size_hint=64)
  buf.write_bytes(@utf8.encode("INSERT INTO " + table + " ("))
  for i in 0..<columns.length() {
    if i > 0 {
      buf.write_bytes(@utf8.encode(", "))
    }
    buf.write_bytes(@utf8.encode(columns[i]))
  }
  buf.write_bytes(@utf8.encode(") FORMAT "))
  buf.write_bytes(@utf8.encode(format_name(format)))
  @utf8.decode_lossy(buf.to_bytes())
}

///|
/// ClickHouse FORMAT keyword for an InsertFormat.
fn format_name(format : InsertFormat) -> String {
  match format {
    Tsv => "TSV"
    Ndjson => "JSONEachRow"
  }
}

///|
/// Encode a single row for the given wire format.
fn encode_row(
  columns : Array[String],
  row : Array[String],
  format : InsertFormat,
) -> Bytes {
  let buf = Buffer::Buffer(size_hint=32)
  match format {
    Tsv => {
      let mut first = true
      for v in row {
        if !first {
          buf.write_byte(b'\t')
        }
        buf.write_bytes(@utf8.encode(tsv_escape(v)))
        first = false
      }
      buf.write_byte(b'\n')
    }
    Ndjson => {
      buf.write_byte(b'{')
      for i in 0..<columns.length() {
        if i > 0 {
          buf.write_byte(b',')
        }
        buf.write_byte(b'"')
        buf.write_bytes(@utf8.encode(json_escape(columns[i])))
        buf.write_bytes(@utf8.encode("\":"))
        let value = if i < row.length() { row[i] } else { "" }
        buf.write_byte(b'"')
        buf.write_bytes(@utf8.encode(json_escape(value)))
        buf.write_byte(b'"')
      }
      buf.write_byte(b'}')
      buf.write_byte(b'\n')
    }
  }
  buf.to_bytes()
}

///|
/// Escape a TSV field: `\`, tab, LF and CR become backslash sequences.
fn tsv_escape(s : String) -> String {
  let bytes = @utf8.encode(s)
  let buf = Buffer::Buffer(size_hint=bytes.length() + 8)
  for b in bytes {
    match b {
      b'\\' => buf.write_bytes(@utf8.encode("\\\\"))
      b'\t' => buf.write_bytes(@utf8.encode("\\t"))
      b'\n' => buf.write_bytes(@utf8.encode("\\n"))
      b'\r' => buf.write_bytes(@utf8.encode("\\r"))
      _ => buf.write_byte(b)
    }
  }
  @utf8.decode_lossy(buf.to_bytes())
}

///|
/// Escape a string as the inside of a JSON string literal.
fn json_escape(s : String) -> String {
  let bytes = @utf8.encode(s)
  let buf = Buffer::Buffer(size_hint=bytes.length() + 8)
  for b in bytes {
    match b {
      b'"' => buf.write_bytes(@utf8.encode("\\\""))
      b'\\' => buf.write_bytes(@utf8.encode("\\\\"))
      b'\n' => buf.write_bytes(@utf8.encode("\\n"))
      b'\r' => buf.write_bytes(@utf8.encode("\\r"))
      b'\t' => buf.write_bytes(@utf8.encode("\\t"))
      b'\x00'..<b'\x20' => {
        let code = b.to_int()
        buf.write_bytes(@utf8.encode("\\u00"))
        buf.write_byte(hex_nibble_byte(code / 16))
        buf.write_byte(hex_nibble_byte(code % 16))
      }
      _ => buf.write_byte(b)
    }
  }
  @utf8.decode_lossy(buf.to_bytes())
}

// ============ HTTP layer (private) ============

///|
/// Build the full request URL with query params.
/// The HTTP path always starts with "/" — ClickHouse accepts any path and
/// processes the `query` URL parameter. We send `client_name` via the
/// `X-ClickHouse-Client-Name` header instead of as a URL param, because
/// ClickHouse rejects unknown URL params with 404.
///
/// Named `params` are appended as `param_<key>=<value>` URL parameters,
/// which ClickHouse substitutes into `{key: Type}` placeholders server-side.
fn build_url(
  conn : Connection,
  query : String,
  params : Map[String, String],
) -> String {
  let buf = Buffer::Buffer(size_hint=256)
  // Path with all params encoded (raw UTF-8 bytes — Buffer.write_string
  // writes UTF-16LE which Poco rejects as invalid URI)
  buf.write_bytes(@utf8.encode("/?database="))
  buf.write_bytes(@utf8.encode(url_encode(conn.database)))
  buf.write_bytes(@utf8.encode("&default_format=TabSeparatedWithNamesAndTypes"))
  if conn.compress {
    buf.write_bytes(@utf8.encode("&compress=1"))
  }
  buf.write_bytes(@utf8.encode("&query="))
  buf.write_bytes(@utf8.encode(url_encode(query)))
  // Named parameters: param_<key>=<value> pairs
  for entry in params.to_array() {
    let (k, v) = entry
    buf.write_bytes(@utf8.encode("&param_"))
    buf.write_bytes(@utf8.encode(url_encode(k)))
    buf.write_bytes(@utf8.encode("="))
    buf.write_bytes(@utf8.encode(url_encode(v)))
  }
  ignore(params)
  @utf8.decode_lossy(buf.to_bytes())
}

///|
/// Read the entire raw response body from an HTTP client until EOF.
async fn read_response_bytes(client : @http.Client) -> Bytes {
  let acc = Buffer::Buffer(size_hint=4096)
  let buf = FixedArray::make(4096, b'\x00')
  let mut total = 0
  while true {
    let n = client.read(buf, offset=0, max_len=4096)
    if n == 0 {
      break
    }
    total = total + n
    for i in 0..<n {
      acc.write_byte(buf[i])
    }
    // Safety: bail if response is unreasonably large (256MB)
    if total > 268435456 {
      raise ConnectionError("response body exceeds 256MB limit")
    }
  }
  ignore(total)
  acc.to_bytes()
}

///|
/// Read entire response body from an HTTP client until EOF (text form).
async fn read_response_body(client : @http.Client) -> String {
  @utf8.decode_lossy(read_response_bytes(client))
}

// ============ ClickHouse LZ4 response decompression ============

///|
/// Decompress a ClickHouse `compress=1` HTTP response body.
///
/// The body is a concatenation of blocks, each:
///   [16-byte CityHash128 checksum][9-byte header][compressed payload]
/// The checksum is skipped (not verified). The 9-byte header is:
///   method (1 byte) | compressed_size incl. header (4 LE) | raw_size (4 LE)
/// Methods: 0x02 = none, 0x82 = LZ4, 0x90 = ZSTD (unsupported).
fn decompress_clickhouse_body(body : Bytes) -> Bytes raise {
  let out = Buffer::Buffer(size_hint=body.length() * 2)
  let mut i = 0
  while i < body.length() {
    if body.length() - i < 16 + 9 {
      raise ConnectionError("truncated ClickHouse compressed block header")
    }
    let header = i + 16
    let compression = body[header].to_int()
    let comp_size = read_le_u32(body, header + 1)
    let raw_size = read_le_u32(body, header + 5)
    if comp_size < 9 || header + comp_size > body.length() {
      raise ConnectionError("invalid ClickHouse compressed block size")
    }
    let payload_start = header + 9
    let payload_len = comp_size - 9
    match compression {
      0x02 => {
        if raw_size > payload_len {
          raise ConnectionError("invalid uncompressed block size")
        }
        for k in 0..<raw_size {
          out.write_byte(body[payload_start + k])
        }
      }
      0x82 => {
        let block = lz4_decompress_block(
          body, payload_start, payload_len, raw_size,
        )
        out.write_bytes(block)
      }
      _ =>
        raise ConnectionError(
          "unsupported ClickHouse compression method: \{compression}",
        )
    }
    i = payload_start + payload_len
  }
  out.to_bytes()
}

///|
/// Read a little-endian UInt32 from a byte buffer.
fn read_le_u32(bytes : Bytes, start : Int) -> Int {
  bytes[start].to_int() |
  (bytes[start + 1].to_int() << 8) |
  (bytes[start + 2].to_int() << 16) |
  (bytes[start + 3].to_int() << 24)
}

///|
/// Decompress one LZ4 *block* (no frame header) into exactly `raw_size` bytes.
/// `block` is the payload slice `[start, start + len)` of `bytes`.
///
/// LZ4 block sequence: token (high nibble = literal len, low nibble = match
/// len - 4), optional 0xFF extended lengths, literals, 2-byte LE match offset,
/// then the match (copied with overlap allowed).
fn lz4_decompress_block(
  bytes : Bytes,
  start : Int,
  len : Int,
  raw_size : Int,
) -> Bytes raise {
  let out = FixedArray::make(raw_size, b'\x00')
  let mut out_len = 0
  let mut i = start
  let end = start + len
  while i < end {
    let token = bytes[i].to_int()
    i = i + 1
    // Literal length (0xFF extension while byte == 255).
    let mut lit_len = token >> 4
    if lit_len == 15 {
      while true {
        guard i < end else {
          raise ConnectionError("truncated LZ4 literal length")
        }
        let b = bytes[i].to_int()
        i = i + 1
        lit_len = lit_len + b
        if b != 255 {
          break
        }
      }
    }
    guard i + lit_len <= end else {
      raise ConnectionError("truncated LZ4 literals")
    }
    guard out_len + lit_len <= raw_size else {
      raise ConnectionError("LZ4 output overflow")
    }
    for k in 0..<lit_len {
      out[out_len + k] = bytes[i + k]
    }
    out_len = out_len + lit_len
    i = i + lit_len
    // Last sequence may be literals only.
    if i >= end {
      break
    }
    // Match offset (2 bytes LE).
    guard i + 2 <= end else {
      raise ConnectionError("truncated LZ4 match offset")
    }
    let offset = bytes[i].to_int() | (bytes[i + 1].to_int() << 8)
    i = i + 2
    guard offset > 0 else { raise ConnectionError("invalid LZ4 match offset") }
    // Match length (0xFF extension while byte == 255).
    let mut match_len = (token & 0x0F) + 4
    if (token & 0x0F) == 15 {
      while true {
        guard i < end else {
          raise ConnectionError("truncated LZ4 match length")
        }
        let b = bytes[i].to_int()
        i = i + 1
        match_len = match_len + b
        if b != 255 {
          break
        }
      }
    }
    guard offset <= out_len else {
      raise ConnectionError("LZ4 match before start")
    }
    guard out_len + match_len <= raw_size else {
      raise ConnectionError("LZ4 output overflow")
    }
    let match_start = out_len - offset
    for k in 0..<match_len {
      out[out_len] = out[match_start + k]
      out_len = out_len + 1
    }
  }
  guard out_len == raw_size else { raise ConnectionError("LZ4 size mismatch") }
  out.unsafe_reinterpret_as_bytes()
}

///|
/// Generate an HTTP Basic auth header value from credentials.
fn basic_auth_header(user : String, password : String) -> String {
  let cred = @utf8.encode(user + ":" + password)
  "Basic " + @base64.encode(cred)
}

///|
/// Trim ClickHouse error response to a single-line summary.
/// Bodies often look like: "Code: 60. DB::Exception: Table doesn't exist..."
fn extract_error(body : String) -> String {
  // Take first 500 chars or so for a readable message
  if body.length() <= 500 {
    body
  } else {
    substr(body, 0, 500)
  }
}

// ============ TSV (de)serialization ============

///|
/// Parse a TabSeparatedWithNamesAndTypes response body.
///
/// Layout:
///   line 0: column names tab-separated
///   line 1: column types tab-separated
///   line 2..: data rows tab-separated
fn parse_tsv_response(body : String) -> ResultSet {
  let lines = split_lines(body)
  if lines.length() < 2 {
    return { columns: [], rows: [] }
  }
  let names = split_tsv_line(lines[0])
  let types = split_tsv_line(lines[1])
  let columns : Array[Column] = []
  for i in 0..<names.length() {
    let typ = if i < types.length() { types[i] } else { "" }
    columns.push({ name: names[i], type_: typ })
  }
  let rows : Array[Row] = []
  for i in 2..<lines.length() {
    // Skip empty trailing lines
    if lines[i].length() > 0 {
      let values = split_tsv_line(lines[i])
      rows.push({ values, })
    }
  }
  { columns, rows }
}

// ============ URL encoding ============

///|
/// Percent-encode a string for use in URL query parameters.
/// Encodes everything except unreserved characters (A-Z a-z 0-9 - _ . ~).
fn url_encode(s : String) -> String {
  let buf = Buffer::Buffer(size_hint=s.length() * 3)
  let bytes = @utf8.encode(s)
  for b in bytes {
    let code = b.to_int()
    let is_unreserved = (code >= 0x41 && code <= 0x5A) || // A-Z
      (code >= 0x61 && code <= 0x7A) || // a-z
      (code >= 0x30 && code <= 0x39) || // 0-9
      code == 0x2D ||
      code == 0x5F ||
      code == 0x2E ||
      code == 0x7E
    if is_unreserved {
      buf.write_byte(b)
    } else {
      buf.write_byte(b'%')
      let hi = code / 16
      let lo = code % 16
      buf.write_byte(hex_nibble_byte(hi))
      buf.write_byte(hex_nibble_byte(lo))
    }
  }
  ignore(bytes)
  @utf8.decode_lossy(buf.to_bytes())
}

// ============ String helpers ============

///|
/// Split a string by lines. Handles both `\n` and `\r\n` line endings.
fn split_lines(s : String) -> Array[String] {
  let result : Array[String] = []
  let bytes = @utf8.encode(s)
  let mut start = 0
  for i in 0..<bytes.length() {
    if bytes[i] == b'\n' {
      let end = if i > 0 && bytes[i - 1] == b'\r' { i - 1 } else { i }
      result.push(bytes_to_string(bytes, start, end))
      start = i + 1
    }
  }
  if start < bytes.length() {
    let end = if bytes.length() > start && bytes[bytes.length() - 1] == b'\r' {
      bytes.length() - 1
    } else {
      bytes.length()
    }
    if end > start {
      result.push(bytes_to_string(bytes, start, end))
    }
  }
  ignore(s)
  result
}

///|
/// Strip a single trailing carriage return (for CRLF-terminated lines).
fn strip_cr(s : String) -> String {
  if s.length() > 0 && s[s.length() - 1] == '\r' {
    substr(s, 0, s.length() - 1)
  } else {
    s
  }
}

///|
/// Split a TSV line by tab. Unescapes `\t`, `\n`, `\r`, `\\`.
fn split_tsv_line(line : String) -> Array[String] {
  let result : Array[String] = []
  let bytes = @utf8.encode(line)
  let buf = Buffer::Buffer(size_hint=line.length())
  let mut i = 0
  while i < bytes.length() {
    let b = bytes[i]
    if b == b'\\' && i + 1 < bytes.length() {
      let next = bytes[i + 1]
      match next {
        b'n' => buf.write_byte(b'\n')
        b'r' => buf.write_byte(b'\r')
        b't' => buf.write_byte(b'\t')
        b'\\' => buf.write_byte(b'\\')
        _ => {
          buf.write_byte(b)
          buf.write_byte(next)
        }
      }
      i = i + 2
    } else if b == b'\t' {
      result.push(buf_to_string(buf))
      buf.reset()
      i = i + 1
    } else {
      buf.write_byte(b)
      i = i + 1
    }
  }
  // Always push final field, even if empty (handles trailing-tab case)
  result.push(buf_to_string(buf))
  ignore(line)
  result
}

// ============ Internal byte/string conversion ============

///|
fn bytes_to_string(bytes : Bytes, start : Int, end : Int) -> String {
  let buf = Buffer::Buffer(size_hint=end - start)
  for i in start..<end {
    buf.write_byte(bytes[i])
  }
  @utf8.decode_lossy(buf.to_bytes())
}

///|
fn buf_to_string(buf : Buffer) -> String {
  @utf8.decode_lossy(buf.to_bytes())
}

///|
fn hex_nibble_byte(v : Int) -> Byte {
  if v < 10 {
    (v + 0x30).to_byte()
  } else {
    (v + 0x61 - 10).to_byte()
  }
}

// ============ Generic utilities (kept for backwards compatibility) ============

///|
/// Extract a substring [start, end) from a String (byte-indexed).
fn substr(s : String, start : Int, end : Int) -> String {
  if start >= end || start < 0 {
    return ""
  }
  let s_len = s.length()
  let real_end = if end > s_len { s_len } else { end }
  let real_start = if start > s_len { s_len } else { start }
  let buf = Buffer::Buffer(size_hint=real_end - real_start)
  for i in real_start..<real_end {
    buf.write_byte(s[i].to_int().to_byte())
  }
  @utf8.decode_lossy(buf.to_bytes())
}

// ============ Result set constructors (for sub-packages) ============

///|
/// 构造列元数据（供 native 等子包复用）。
pub fn Column::new(name~ : String, type_~ : String) -> Column {
  { name, type_ }
}

///|
/// 构造单行结果（供 native 等子包复用）。
pub fn Row::new(values~ : Array[String]) -> Row {
  { values, }
}

///|
/// 构造完整结果集（供 native 等子包复用）。
pub fn ResultSet::new(
  columns~ : Array[Column],
  rows~ : Array[Row],
) -> ResultSet {
  { columns, rows }
}
