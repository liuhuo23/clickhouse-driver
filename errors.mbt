///|
/// Errors raised by the driver.
pub suberror DbError {
  /// Server rejected the request. `code` is ClickHouse's exception code
  /// (`Code: N.` / `X-ClickHouse-Exception-Code`) when the server reported
  /// one, otherwise the HTTP status; `name` is `"DB::Exception"` or
  /// `"HTTPError"` accordingly.
  ServerError(code~ : Int32, name~ : String, message~ : String)
  /// Connection-level error (I/O, malformed response, unexpected EOF)
  ConnectionError(String)
} derive(Debug)

///|
/// Re-export the derived `Debug` method explicitly (MoonBit no longer
/// promotes trait impl methods to inherent methods implicitly).
pub extend DbError with @debug.Debug::{to_repr}

///|
/// 构造服务器错误（供 native 等子包复用）。
pub fn DbError::server_error(
  code~ : Int32,
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

///|
/// Build a `ServerError` from an HTTP error response.
///
/// ClickHouse reports the real exception code in the
/// `X-ClickHouse-Exception-Code` response header and in the body's
/// `Code: N.` prefix; the HTTP status is only a transport-level fallback.
fn http_error(
  status : Int32,
  headers : Map[String, String],
  body : String,
) -> DbError {
  let message = extract_error(body)
  let parsed = match headers.get("x-clickhouse-exception-code") {
    Some(value) =>
      match parse_leading_int(value) {
        Some(code) => Some(code)
        None => parse_clickhouse_error_code(body)
      }
    None => parse_clickhouse_error_code(body)
  }
  match parsed {
    Some(code) => ServerError(code~, name="DB::Exception", message~)
    None => ServerError(code=status, name="HTTPError", message~)
  }
}

///|
/// Parse the `Code: <n>.` prefix of a ClickHouse exception body.
fn parse_clickhouse_error_code(body : String) -> Int32? {
  let prefix = "Code: "
  guard body.has_prefix(prefix) else { return None }
  parse_leading_int(body[6:].to_owned())
}

///|
/// Parse the leading ASCII digits of `s`; `None` when there are none.
fn parse_leading_int(s : String) -> Int32? {
  let mut value = 0
  let mut any = false
  for c in s {
    if c >= '0' && c <= '9' {
      value = value * 10 + (c.to_int() - '0'.to_int())
      any = true
    } else {
      break
    }
  }
  if any {
    Some(value)
  } else {
    None
  }
}
