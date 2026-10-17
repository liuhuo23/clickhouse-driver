///|
/// Send an HTTP request to ClickHouse and return (status_code, headers,
/// body_text). Applies the connection-level timeout when configured.
async fn Connection::http_request(
  self : Connection,
  query : String,
  params : Map[String, String],
) -> (Int32, Map[String, String], String) {
  self.run_with_timeout(() => self.http_request_impl(query, params))
}

///|
/// Actual HTTP round-trip (no timeout wrapping).
async fn Connection::http_request_impl(
  self : Connection,
  query : String,
  params : Map[String, String],
) -> (Int32, Map[String, String], String) {
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
  (status, response.headers, @utf8.decode_lossy(body))
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

///|
/// Generate an HTTP Basic auth header value from credentials.
fn basic_auth_header(user : String, password : String) -> String {
  let cred = @utf8.encode(user + ":" + password)
  "Basic " + @base64.encode(cred)
}

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
