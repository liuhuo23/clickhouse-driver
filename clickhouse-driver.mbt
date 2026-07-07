///|
/// ClickHouse HTTP driver for MoonBit.
///
/// Uses the native ClickHouse HTTP interface (default port 8123, also works on 8000)
/// over plain HTTP/1.1. Responses are parsed as TabSeparatedWithNamesAndTypes, so
/// column names and types come back automatically — no binary protocol overhead.
///
/// Public API mirrors the previous native driver:
///   connect → Connection  (lightweight config struct; no persistent socket)
///   conn.ping()           — SELECT 1 round-trip
///   conn.execute_query()  — SELECT/DDL, returns ResultSet
///   conn.insert()         — streaming TSV INSERT
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

// ============ Errors ============

///|
/// Errors raised by the driver.
pub suberror DbError {
  /// Server returned a non-2xx HTTP response with an error body.
  ServerError(code~ : Int, name~ : String, message~ : String)
  /// Connection-level error (I/O, malformed response, unexpected EOF)
  ConnectionError(String)
} derive(Debug)

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
}

// ============ Public API ============

///|
/// Build a Connection config from explicit connection params.
/// Does NOT open a TCP connection — calls are stateless.
pub fn connect(
  host~ : String,
  port~ : Int,
  user~ : String,
  password~ : String,
  database~ : String,
  client_name~ : String,
) -> Connection {
  { host, port, user, password, database, client_name }
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
  let (status, body) = self.http_request("SELECT 1", {})
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
  params? : Map[String, String] = {},
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
/// Replace `?` placeholders in SQL with auto-numbered named placeholders
/// (`{__p1: String}`, `{__p2: String}`, ...) and build the corresponding
/// `param_<name>=<value>` map from the positional `values` array. The
/// `__p` prefix keeps these synthetic names out of any user-defined
/// parameter namespace.
fn bind_positional(
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
fn apply_default_types(sql : String) -> String {
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
      println(
        "[DEBUG] scan start i=" +
        i.to_string() +
        " len=" +
        bytes.length().to_string(),
      )
      while j < bytes.length() && bytes[j] != b'}' {
        let c0 = bytes[j]
        println("[DEBUG] j=" + j.to_string() + " c0=" + c0.to_int().to_string())
        let next_is_brace = j + 1 < bytes.length() &&
          (bytes[j + 1] == b'{' || bytes[j + 1] == b'}')
        let same_char = next_is_brace && bytes[j + 1] == bytes[j]
        if same_char {
          println(
            "[DEBUG] brace escape at j=" +
            j.to_string() +
            " writing " +
            bytes[j].to_int().to_string(),
          )
          inner.write_byte(bytes[j])
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

// ============ HTTP layer (private) ============

///|
/// Send an HTTP request to ClickHouse.
/// Returns (status_code, response_body). On network/protocol failure raises
/// ConnectionError.
async fn Connection::http_request(
  self : Connection,
  query : String,
  params : Map[String, String],
) -> (Int, String) {
  // Build query string (path + named params)
  let path = build_url(self, query, params)
  // Common headers
  let headers : Map[String, String] = Map::Map([])
  headers.set("Host", self.host + ":" + self.port.to_string())
  headers.set("Authorization", basic_auth_header(self.user, self.password))
  headers.set("Connection", "close")
  headers.set("X-ClickHouse-Client-Name", self.client_name)

  // Open a fresh HTTP client per request. URI form: http://host:port/
  let uri = "http://" + self.host + ":" + self.port.to_string() + "/"
  let client = @http.Client::Client(uri, headers~)
  // Always use POST with empty body — works for SELECT, DDL, INSERT, etc.
  // (ClickHouse rejects non-SELECT queries via GET as "readonly mode".)
  let body_bytes : Bytes = b""
  let body_data : &@io.Data = body_bytes
  let response = client.post(path, body_data)

  let body_str = read_response_body(client)
  let status = response.code
  client.close()
  (status, body_str)
}

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
/// Read entire response body from an HTTP client until EOF.
async fn read_response_body(client : @http.Client) -> String {
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
  @utf8.decode_lossy(acc.to_bytes())
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
