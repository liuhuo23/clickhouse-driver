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
  priv port : Int32
  priv user : String
  priv password : String
  priv database : String
  priv client_name : String
  priv timeout_ms : Int32
  priv https : Bool
  priv skip_verify : Bool
  priv compress : Bool
  priv max_size : Int32
  /// Bounds concurrent checked-out connections (permits == max_size).
  priv sem : @async.Semaphore
  /// Idle keep-alive connections ready for reuse (with idle timestamps).
  priv idle : Array[IdleClient]
  /// Set by `close()`; further operations close connections instead of
  /// reusing them.
  priv mut closed : Bool
}

///|
/// Idle connections older than this are health-checked with `GET /ping`
/// before reuse, so a keep-alive socket closed by the server/proxy does not
/// surface as a user-visible failure.
const IDLE_HEALTH_CHECK_MS : UInt64 = 5000

///|
/// An idle keep-alive connection plus the millisecond timestamp when it was
/// returned to the pool.
priv struct IdleClient {
  client : @http.Client
  since : UInt64
}

///|
/// Build a `ConnectionPool` from this connection config.
/// `size` is the maximum number of concurrent connections (default 4;
/// values <= 0 are clamped to 4).
pub fn Connection::pool(self : Connection, size~ : Int32 = 4) -> ConnectionPool {
  ConnectionPool::new(self, size)
}

///|
fn ConnectionPool::new(conn : Connection, size : Int32) -> ConnectionPool {
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
  for entry in self.idle {
    entry.client.close()
  }
  self.idle.clear()
}

///|
/// The maximum number of concurrent connections this pool will create.
pub fn ConnectionPool::max_size(self : ConnectionPool) -> Int32 {
  self.max_size
}

///|
/// Round-trip health check through the pool.
pub async fn ConnectionPool::ping(self : ConnectionPool) -> Unit {
  let (status, headers, body) = self.pool_http_request("SELECT 1", Map([]))
  if status != 200 {
    raise http_error(status, headers, body)
  }
}

///|
/// Same as `Connection::execute_query` (named `{name: Type}` params), but
/// reuses pooled connections.
pub async fn ConnectionPool::execute_query(
  self : ConnectionPool,
  sql : String,
  params~ : Map[String, String] = Map([]),
) -> ResultSet {
  self.do_request(@internal.apply_default_types(sql), params)
}

///|
/// Same as `Connection::execute` (positional `?` binding), pooled.
pub async fn ConnectionPool::execute(
  self : ConnectionPool,
  sql : String,
  values : Array[String],
) -> ResultSet {
  let (processed_sql, params) = @internal.bind_positional(sql, values)
  self.do_request(@internal.apply_default_types(processed_sql), params)
}

///|
/// Same as `Connection::insert` (streamed TSV/JSONEachRow body), pooled.
pub async fn ConnectionPool::insert(
  self : ConnectionPool,
  table : String,
  columns : Array[String],
  rows : Array[Array[String]],
  format~ : InsertFormat = Tsv,
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
  params~ : Map[String, String] = Map([]),
) -> ResultSetCursor {
  guard !self.compress else {
    raise ConnectionError(
      "execute_stream does not support compress=true; use execute_query",
    )
  }
  let conn = self.as_connection()
  conn.run_with_timeout(() => {
    self.execute_stream_impl(@internal.apply_default_types(sql), params)
  })
}

///|
async fn ConnectionPool::do_request(
  self : ConnectionPool,
  sql : String,
  params : Map[String, String],
) -> ResultSet {
  let (status, headers, body) = self.pool_http_request(sql, params)
  if status != 200 {
    raise http_error(status, headers, body)
  }
  parse_tsv_response(body)
}

///|
/// Send a request through a pooled connection; applies the configured timeout.
async fn ConnectionPool::pool_http_request(
  self : ConnectionPool,
  query : String,
  params : Map[String, String],
) -> (Int32, Map[String, String], String) {
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
) -> (Int32, Map[String, String], String) {
  let conn = self.as_connection()
  let path = build_url(conn, query, params)
  let client = self.acquire()
  errdefer self.discard(client)
  let body_bytes : Bytes = b""
  let body_data : &@io.Data = body_bytes
  let response = client.post(path, body_data)
  let status = response.code
  let raw = read_response_bytes(client)
  self.release(client)
  let body = if self.compress {
    decompress_clickhouse_body(raw) catch {
      _ => raw
    }
  } else {
    raw
  }
  (status, response.headers, @utf8.decode_lossy(body))
}

///|
/// Borrow a connection: reuse an idle one, create a new one (up to
/// `max_size`), or wait until one is returned. Idle sockets that have been
/// sitting longer than `IDLE_HEALTH_CHECK_MS` are validated first; broken
/// connections are never cached — callers use `discard` on failure.
async fn ConnectionPool::acquire(self : ConnectionPool) -> @http.Client {
  self.sem.acquire()
  if self.closed {
    self.sem.release()
    raise ConnectionError("connection pool is closed")
  }
  let now = @env.now()
  while self.idle.length() > 0 {
    let entry = self.idle.pop().unwrap()
    // Fresh enough to trust without a round trip.
    if now < entry.since + IDLE_HEALTH_CHECK_MS {
      return entry.client
    }
    if self.is_alive(entry.client) {
      return entry.client
    }
    entry.client.close()
  }
  errdefer self.sem.release()
  self.as_connection().open_client()
}

///|
/// Cheap `GET /ping` probe; drains the body so the socket stays reusable.
/// Any I/O error or non-200 status means the connection must be dropped.
async fn ConnectionPool::is_alive(
  self : ConnectionPool,
  client : @http.Client,
) -> Bool {
  ignore(self)
  try {
    let response = client.get("/ping")
    let code = response.code
    ignore(read_response_bytes(client))
    code == 200
  } catch {
    _ => false
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
    self.idle.push({ client, since: @env.now(), })
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
  errdefer self.discard(client)
  client.request(@http.RequestMethod::Post, path)
  for row in rows {
    let row_bytes = encode_row(columns, row, format)
    let row_data : &@io.Data = row_bytes
    client.write(row_data)
  }
  client.flush()
  let response = client.end_request()
  if response.code != 200 {
    let body = read_response_body(client)
    raise http_error(response.code, response.headers, body)
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
  errdefer self.discard(client)
  let body_bytes : Bytes = b""
  let body_data : &@io.Data = body_bytes
  let response = client.post(path, body_data)
  if response.code != 200 {
    let body = read_response_body(client)
    raise http_error(response.code, response.headers, body)
  }
  let names_line = match client.read_until("\n") {
    None => raise ConnectionError("empty response from server")
    Some(line) => strip_cr(line)
  }
  let types_line = match client.read_until("\n") {
    None => raise ConnectionError("missing type header from server")
    Some(line) => strip_cr(line)
  }
  let names = split_tsv_line(names_line)
  let types = split_tsv_line(types_line)
  let cols : Array[Column] = []
  for i in 0..<names.length() {
    let typ = if i < types.length() { types[i] } else { "" }
    cols.push({ name: names[i], type_: typ, })
  }
  {
    client,
    cols,
    timeout_ms: self.timeout_ms,
    pool: Some(self),
    exhausted: [false],
  }
}
