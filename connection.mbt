///|
/// Round-trip health check: sends `SELECT 1` and expects 200 OK.
pub async fn Connection::ping(self : Connection) -> Unit {
  let (status, headers, body) = self.http_request("SELECT 1", Map([]))
  if status != 200 {
    raise http_error(status, headers, body)
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
  params~ : Map[String, String] = Map([]),
) -> ResultSet {
  self.do_request(@internal.apply_default_types(sql), params)
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
  let (processed_sql, params) = @internal.bind_positional(sql, values)
  // apply_default_types turns any user-written `{name}` into `{name: String}`
  // (so named placeholders work too); the `{__pN: String}` placeholders we
  // just emitted already carry a type and pass through unchanged.
  self.do_request(@internal.apply_default_types(processed_sql), params)
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
  params~ : Map[String, String] = Map([]),
) -> ResultSetCursor {
  guard !self.compress else {
    raise ConnectionError(
      "execute_stream does not support compress=true; use execute_query",
    )
  }
  self.run_with_timeout(() => {
    self.execute_stream_impl(@internal.apply_default_types(sql), params)
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
  format~ : InsertFormat = Tsv,
) -> Unit {
  let sql = build_insert_sql(table, columns, format)
  self.run_with_timeout(() => {
    self.insert_impl(build_url(self, sql, Map([])), columns, rows, format)
  })
}

///|
async fn Connection::do_request(
  self : Connection,
  sql : String,
  params : Map[String, String],
) -> ResultSet {
  let (status, headers, body) = self.http_request(sql, params)
  if status != 200 {
    raise http_error(status, headers, body)
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
    raise http_error(status, response.headers, body)
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
    raise http_error(response.code, response.headers, body)
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
    cols.push({ name: names[i], type_: typ, })
  }
  { client, cols, timeout_ms: self.timeout_ms, pool: None, exhausted: [false], }
}
