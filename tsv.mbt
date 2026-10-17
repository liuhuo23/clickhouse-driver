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
    return { columns: [], rows: [], }
  }
  let names = split_tsv_line(lines[0])
  let types = split_tsv_line(lines[1])
  let columns : Array[Column] = []
  for i in 0..<names.length() {
    let typ = if i < types.length() { types[i] } else { "" }
    columns.push({ name: names[i], type_: typ, })
  }
  let rows : Array[Row] = []
  for i in 2..<lines.length() {
    // Skip empty trailing lines
    if lines[i].length() > 0 {
      let values = split_tsv_line(lines[i])
      rows.push({ values, })
    }
  }
  { columns, rows, }
}

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

///|
fn hex_nibble_byte(v : Int32) -> Byte {
  if v < 10 {
    (v + 0x30).to_byte()
  } else {
    (v + 0x61 - 10).to_byte()
  }
}
