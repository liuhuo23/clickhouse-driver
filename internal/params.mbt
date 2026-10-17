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
      let content = @utf8.decode_lossy(inner.to_bytes())
      if j >= bytes.length() {
        // Unmatched '{' — copy the rest verbatim
        for k in i..<bytes.length() {
          buf.write_byte(bytes[k])
        }
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
