///|
/// ClickHouse native TCP protocol driver for MoonBit.
/// Supports rev 54429 (handshake + query + response parsing).

///|
/// Client protocol revision (negotiated = min(client, server)).
const CLIENT_REVISION : UInt = 54429U

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
/// Errors raised by the driver.
/// Use `try { ... } catch { err => ... }` to handle them.
pub suberror DbError {
  /// Server returned an Exception packet (query rejected, syntax error, etc.)
  ServerError(code~ : Int, name~ : String, message~ : String)
  /// Connection-level error (I/O, malformed response, unexpected EOF)
  ConnectionError(String)
} derive(Debug)

///|
/// Convert result to an array of row maps.
/// Each element is a Map[String, String] mapping column name → value for that row.
pub fn ResultSet::to_map(self : ResultSet) -> Array[Map[String, String]] {
  let result : Array[Map[String, String]] = []
  for r in 0..<self.rows.length() {
    let row_map : Map[String, String] = Map([], capacity=0)
    for c in 0..<self.columns.length() {
      row_map.set(self.columns[c].name, self.rows[r].values[c])
    }
    result.push(row_map)
  }
  result
}

///|
/// Connection to ClickHouse server.
pub struct Connection {
  tcp : @socket.Tcp
  server_rev : UInt
  user : String
  client_name : String
}

// ============ ClickHouse type system ============

///|
/// Internal representation of ClickHouse data types for value parsing.
priv enum CHType {
  UInt8
  UInt16
  UInt32
  UInt64
  Int8
  Int16
  Int32
  Int64
  Int128
  UInt128
  Int256
  UInt256
  Float32
  Float64
  Bool
  String
  FixedString(Int)
  Date
  Date32
  DateTime
  DateTime64(Int) // scale
  Decimal(Int, Int) // precision, scale
  Decimal32(Int) // scale
  Decimal64(Int) // scale
  Decimal128(Int) // scale
  Decimal256(Int) // scale
  UUID
  IPv4
  IPv6
  Enum8
  Enum16
  Nullable(CHType)
  Array(CHType)
  Tuple(Array[CHType])
  Map(CHType, CHType)
  LowCardinality(CHType)
  SimpleAggregateFunction(CHType)
  Unknown
}

///|
/// Parse a ClickHouse type string into a CHType.
fn parse_type(s : String) -> CHType {
  let trimmed = s.trim().to_owned()
  if trimmed == "UInt8" {
    CHType::UInt8
  } else if trimmed == "UInt16" {
    CHType::UInt16
  } else if trimmed == "UInt32" {
    CHType::UInt32
  } else if trimmed == "UInt64" {
    CHType::UInt64
  } else if trimmed == "Int8" {
    CHType::Int8
  } else if trimmed == "Int16" {
    CHType::Int16
  } else if trimmed == "Int32" {
    CHType::Int32
  } else if trimmed == "Int64" {
    CHType::Int64
  } else if trimmed == "Int128" {
    CHType::Int128
  } else if trimmed == "UInt128" {
    CHType::UInt128
  } else if trimmed == "Int256" {
    CHType::Int256
  } else if trimmed == "UInt256" {
    CHType::UInt256
  } else if trimmed == "Float32" {
    CHType::Float32
  } else if trimmed == "Float64" {
    CHType::Float64
  } else if trimmed == "Bool" {
    CHType::Bool
  } else if trimmed == "String" {
    CHType::String
  } else if trimmed == "Date" {
    CHType::Date
  } else if trimmed == "Date32" {
    CHType::Date32
  } else if trimmed == "DateTime" {
    CHType::DateTime
  } else if trimmed == "UUID" {
    CHType::UUID
  } else if trimmed == "IPv4" {
    CHType::IPv4
  } else if trimmed == "IPv6" {
    CHType::IPv6
  } else if trimmed == "Enum8" {
    CHType::Enum8
  } else if trimmed == "Enum16" {
    CHType::Enum16
  } else {
    parse_complex_type(trimmed)
  }
}

///|
/// Parse complex (parameterized or nested) type strings.
fn parse_complex_type(s : String) -> CHType {
  if s.has_prefix("Nullable(") {
    CHType::Nullable(parse_type(extract_parens(s, "Nullable".length())))
  } else if s.has_prefix("LowCardinality(") {
    CHType::LowCardinality(
      parse_type(extract_parens(s, "LowCardinality".length())),
    )
  } else if s.has_prefix("Array(") {
    CHType::Array(parse_type(extract_parens(s, "Array".length())))
  } else if s.has_prefix("SimpleAggregateFunction(") {
    // SimpleAggregateFunction(func, T) — second arg is the type
    let inner = extract_parens(s, "SimpleAggregateFunction".length())
    let parts = split_type_list(inner)
    if parts.length() >= 2 {
      CHType::SimpleAggregateFunction(parse_type(parts[1]))
    } else {
      CHType::Unknown
    }
  } else if s.has_prefix("Tuple(") {
    let inner = extract_parens(s, "Tuple".length())
    let parts = split_type_list(inner)
    let types : Array[CHType] = []
    for i in 0..<parts.length() {
      types.push(parse_type(parts[i]))
    }
    CHType::Tuple(types)
  } else if s.has_prefix("Map(") {
    let inner = extract_parens(s, "Map".length())
    let parts = split_type_list(inner)
    if parts.length() >= 2 {
      CHType::Map(parse_type(parts[0]), parse_type(parts[1]))
    } else {
      CHType::Unknown
    }
  } else if s.has_prefix("FixedString(") {
    let inner = extract_parens(s, "FixedString".length())
    CHType::FixedString(parse_int_or(inner, 0))
  } else if s.has_prefix("DateTime64(") {
    let inner = extract_parens(s, "DateTime64".length())
    let parts = split_type_list(inner)
    CHType::DateTime64(parse_int_or(parts[0], 3))
  } else if s.has_prefix("Decimal(") {
    let inner = extract_parens(s, "Decimal".length())
    let parts = split_type_list(inner)
    if parts.length() >= 2 {
      CHType::Decimal(parse_int_or(parts[0], 38), parse_int_or(parts[1], 0))
    } else {
      CHType::Decimal(38, 0)
    }
  } else if s.has_prefix("Decimal32(") {
    let inner = extract_parens(s, "Decimal32".length())
    CHType::Decimal32(parse_int_or(inner, 0))
  } else if s.has_prefix("Decimal64(") {
    let inner = extract_parens(s, "Decimal64".length())
    CHType::Decimal64(parse_int_or(inner, 0))
  } else if s.has_prefix("Decimal128(") {
    let inner = extract_parens(s, "Decimal128".length())
    CHType::Decimal128(parse_int_or(inner, 0))
  } else if s.has_prefix("Decimal256(") {
    let inner = extract_parens(s, "Decimal256".length())
    CHType::Decimal256(parse_int_or(inner, 0))
  } else {
    // Unknown type — will be read as string binary (best-effort fallback)
    CHType::Unknown
  }
}

///|
/// Extract the content between the outermost parentheses of a type string.
/// e.g. extract_parens("Nullable(String)", 8) → "String"
fn extract_parens(s : String, prefix_len : Int) -> String {
  substr(s, prefix_len + 1, s.length() - 1)
}

///|
/// Split a comma-separated type list, respecting nested parentheses.
/// e.g. split_type_list("String, Nullable(Int32), Array(Float64)")
///   → ["String", "Nullable(Int32)", "Array(Float64)"]
fn split_type_list(s : String) -> Array[String] {
  let result : Array[String] = []
  let mut depth = 0
  let mut start = 0
  for i in 0..<s.length() {
    let c = s[i]
    if c == '(' {
      depth = depth + 1
    } else if c == ')' {
      depth = depth - 1
    } else if c == ',' && depth == 0 {
      result.push(substr(s, start, i).trim().to_owned())
      start = i + 1
    }
  }
  let last = substr(s, start, s.length()).trim().to_owned()
  if last.length() > 0 {
    result.push(last)
  }
  result
}

///|
/// Try to parse a string as Int, returning fallback on failure.
fn parse_int_or(s : String, fallback : Int) -> Int {
  let s = s.trim().to_owned()
  if s.length() == 0 {
    return fallback
  }
  let mut result = 0
  let mut start = 0
  let mut neg = false
  if s[0] == '-' {
    neg = true
    start = 1
  } else if s[0] == '+' {
    start = 1
  }
  let mut ok = true
  for i in start..<s.length() {
    match s[i] {
      '0' => result = result * 10
      '1' => result = result * 10 + 1
      '2' => result = result * 10 + 2
      '3' => result = result * 10 + 3
      '4' => result = result * 10 + 4
      '5' => result = result * 10 + 5
      '6' => result = result * 10 + 6
      '7' => result = result * 10 + 7
      '8' => result = result * 10 + 8
      '9' => result = result * 10 + 9
      _ => {
        ok = false
        break
      }
    }
  }
  if ok {
    if neg {
      -result
    } else {
      result
    }
  } else {
    fallback
  }
}

///|
/// Extract a substring [start, end) from a String.
fn substr(s : String, start : Int, end : Int) -> String {
  let buf = Buffer::Buffer(size_hint=end - start)
  for i in start..<end {
    buf.write_byte(s[i].to_int().to_byte())
  }
  @utf8.decode_lossy(buf.to_bytes())
}

///|
/// Convert integer 0-15 to a single hex digit string.
fn hex_nibble(v : Int) -> String {
  match v {
    0 => "0"
    1 => "1"
    2 => "2"
    3 => "3"
    4 => "4"
    5 => "5"
    6 => "6"
    7 => "7"
    8 => "8"
    9 => "9"
    10 => "a"
    11 => "b"
    12 => "c"
    13 => "d"
    14 => "e"
    _ => "f"
  }
}

// ============ Formatting helpers ============

///|
/// Zero-pad an integer to at least 2 digits.
fn pad2(n : Int) -> String {
  if n < 0 {
    "-" + pad2(-n)
  } else if n < 10 {
    "0" + n.to_string()
  } else {
    n.to_string()
  }
}

///|
/// Zero-pad an integer to at least 4 digits.
fn pad4(n : Int) -> String {
  if n < 0 {
    "-" + pad4(-n)
  } else if n < 10 {
    "000" + n.to_string()
  } else if n < 100 {
    "00" + n.to_string()
  } else if n < 1000 {
    "0" + n.to_string()
  } else {
    n.to_string()
  }
}

///|
/// Convert days-since-1970-01-01 to (year, month, day).
/// Algorithm: Howard Hinnant's civil_from_days.
fn civil_from_days(z : Int) -> (Int, Int, Int) {
  let z = z + 719468
  let era = if z >= 0 { z / 146097 } else { (z - 146096) / 146097 }
  let doe = z - era * 146097
  let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
  let y = yoe + era * 400
  let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
  let mp = (5 * doy + 2) / 153
  let d = doy - (153 * mp + 2) / 5 + 1
  let m = mp + (if mp < 10 { 3 } else { -9 })
  let y = y + (if m <= 2 { 1 } else { 0 })
  (y, m, d)
}

///|
/// Format a Unix timestamp (seconds) as "YYYY-MM-DD HH:MM:SS".
fn format_datetime(secs : Int) -> String {
  let days = secs / 86400
  let rem = secs % 86400
  let (y, m, d) = civil_from_days(days)
  let hh = rem / 3600
  let mm = rem % 3600 / 60
  let ss = rem % 60
  pad4(y) +
  "-" +
  pad2(m) +
  "-" +
  pad2(d) +
  " " +
  pad2(hh) +
  ":" +
  pad2(mm) +
  ":" +
  pad2(ss)
}

///|
/// Format days-since-epoch as "YYYY-MM-DD".
fn format_date(days : Int) -> String {
  let (y, m, d) = civil_from_days(days)
  pad4(y) + "-" + pad2(m) + "-" + pad2(d)
}

///|
/// Format a Decimal value given its scale.
fn format_decimal_str(value : Int64, scale : Int) -> String {
  if scale == 0 {
    value.to_string()
  } else {
    let raw = value.to_string()
    let is_neg = raw.has_prefix("-")
    let digits = if is_neg { substr(raw, 1, raw.length()) } else { raw }
    let result = if digits.length() <= scale {
      let zeros = str_repeat("0", scale - digits.length())
      "0." + zeros + digits
    } else {
      let int_part = substr(digits, 0, digits.length() - scale)
      let frac_part = substr(digits, digits.length() - scale, digits.length())
      int_part + "." + frac_part
    }
    if is_neg {
      "-" + result
    } else {
      result
    }
  }
}

///|
/// Repeat a string n times.
fn str_repeat(s : String, n : Int) -> String {
  let mut result = ""
  for _ in 0..<n {
    result = result + s
  }
  result
}

///|
/// Format 16 raw bytes as a UUID string.
fn format_uuid(buf : FixedArray[Byte]) -> String {
  let mut hex = ""
  for i in 0..<16 {
    let v = buf[i].to_int()
    hex = hex + hex_nibble(v >> 4) + hex_nibble(v & 0x0F)
  }
  substr(hex, 0, 8) +
  "-" +
  substr(hex, 8, 12) +
  "-" +
  substr(hex, 12, 16) +
  "-" +
  substr(hex, 16, 20) +
  "-" +
  substr(hex, 20, 32)
}

///|
/// Format 16 raw bytes as an IPv6 string (simplified — full hex groups).
fn format_ipv6(buf : FixedArray[Byte]) -> String {
  let groups : Array[String] = []
  for i in 0..<8 {
    let hi = buf[i * 2].to_int()
    let lo = buf[i * 2 + 1].to_int()
    let val = (hi << 8) | lo
    groups.push(int_to_hex_str(val, 4))
  }
  // Join groups with ":"
  let mut result = ""
  for i in 0..<8 {
    if i > 0 {
      result = result + ":"
    }
    result = result + groups[i]
  }
  result
}

///|
/// Convert an integer to a zero-padded hex string of the given width.
fn int_to_hex_str(val : Int, width : Int) -> String {
  let mut s = ""
  let mut v = val
  if v == 0 {
    s = "0"
  } else {
    while v > 0 {
      s = hex_nibble(v & 0x0F) + s
      v = v >> 4
    }
  }
  while s.length() < width {
    s = "0" + s
  }
  s
}

// ============ Write helpers ============

///|
/// VarUInt (LEB128) encoder.
fn write_varuint(buf : Buffer, value : UInt) -> Unit {
  let mut v = value
  while v >= 128U {
    buf.write_byte(v.land(127U).to_byte() | b'\x80')
    v = v >> 7
  }
  buf.write_byte(v.to_byte())
}

///|
/// String binary: varuint length + UTF-8 bytes.
fn write_string_binary(buf : Buffer, s : String) -> Unit {
  let bytes = @utf8.encode(s)
  write_varuint(buf, bytes.length().reinterpret_as_uint())
  buf.write_bytes(bytes)
}

///|
/// Write a single byte (UInt8).
fn write_uint8(buf : Buffer, value : UInt) -> Unit {
  buf.write_byte(value.to_byte())
}

///|
/// Write Int32 little-endian (for BlockInfo bucket_num).
fn write_int32_le(buf : Buffer, value : Int) -> Unit {
  let mut v = value
  for _i in 0..<4 {
    buf.write_byte(v.land(0xFF).to_byte())
    v = v >> 8
  }
}

// ============ Protocol builders ============

///|
fn build_client_hello(
  client_name~ : String,
  version_major~ : UInt,
  version_minor~ : UInt,
  revision~ : UInt,
  default_database~ : String,
  user~ : String,
  password~ : String,
) -> Bytes {
  let buf = Buffer::Buffer(size_hint=128)
  write_varuint(buf, 0U)
  write_string_binary(buf, client_name)
  write_varuint(buf, version_major)
  write_varuint(buf, version_minor)
  write_varuint(buf, revision)
  write_string_binary(buf, default_database)
  write_string_binary(buf, user)
  write_string_binary(buf, password)
  buf.to_bytes()
}

///|
fn build_client_info(
  user~ : String,
  initial_address~ : String,
  client_name~ : String,
  rev~ : UInt,
) -> Bytes {
  let buf = Buffer::Buffer(size_hint=128)
  write_uint8(buf, 1U) // query_kind = InitialQuery
  write_string_binary(buf, user)
  write_string_binary(buf, "")
  write_string_binary(buf, initial_address)
  write_uint8(buf, 1U) // query_interface = TCP
  write_string_binary(buf, "")
  write_string_binary(buf, "")
  write_string_binary(buf, client_name)
  write_varuint(buf, 1U)
  write_varuint(buf, 0U)
  write_varuint(buf, rev)
  if rev >= 54060U {
    write_string_binary(buf, "")
  }
  if rev >= 54401U {
    write_varuint(buf, 0U)
  }
  buf.to_bytes()
}

///|
fn build_query(client_info~ : Bytes, sql~ : String) -> Bytes {
  let buf = Buffer::Buffer(size_hint=256)
  write_varuint(buf, 1U)
  write_string_binary(buf, "")
  buf.write_bytes(client_info)
  write_varuint(buf, 0U)
  write_varuint(buf, 2U)
  write_varuint(buf, 0U)
  write_string_binary(buf, sql)
  buf.to_bytes()
}

///|
fn build_empty_data() -> Bytes {
  let buf = Buffer::Buffer(size_hint=16)
  write_varuint(buf, 2U)
  write_varuint(buf, 0U)
  write_varuint(buf, 1U)
  write_uint8(buf, 0U)
  write_varuint(buf, 2U)
  write_int32_le(buf, -1)
  write_varuint(buf, 0U)
  write_varuint(buf, 0U)
  write_varuint(buf, 0U)
  buf.to_bytes()
}

// ============ Read helpers ============

///|
async fn read_varuint(conn : @socket.Tcp) -> UInt {
  let buf = FixedArray::make(1, b'\x00')
  let mut result : UInt = 0U
  let mut shift : Int = 0
  for _i in 0..<10 {
    let n = conn.read(buf)
    if n == 0 {
      abort("connection closed while reading varuint")
    }
    let byte = buf[0]
    let low7 = byte.to_int().land(0x7F).reinterpret_as_uint()
    result = result | (low7 << shift)
    if (byte.to_int() & 0x80) == 0 {
      break
    }
    shift = shift + 7
  }
  result
}

///|
async fn read_string_binary(conn : @socket.Tcp) -> String {
  let len = read_varuint(conn).reinterpret_as_int()
  let bytes = conn.read_exactly(len)
  @utf8.decode_lossy(bytes)
}

///|
async fn read_n_bytes(conn : @socket.Tcp, n : Int) -> FixedArray[Byte] {
  let buf = FixedArray::make(n, b'\x00')
  let mut got = 0
  while got < n {
    let r = conn.read(buf, offset=got, max_len=n - got)
    if r == 0 {
      abort("eof")
    }
    got = got + r
  }
  buf
}

///|
async fn read_uint16_le(conn : @socket.Tcp) -> UInt {
  let buf = read_n_bytes(conn, 2)
  buf[0].to_uint() | (buf[1].to_uint() << 8)
}

///|
async fn read_uint32_le(conn : @socket.Tcp) -> UInt64 {
  let buf = read_n_bytes(conn, 4)
  buf[0].to_uint64() |
  (buf[1].to_uint64() << 8) |
  (buf[2].to_uint64() << 16) |
  (buf[3].to_uint64() << 24)
}

///|
async fn read_uint64_le(conn : @socket.Tcp) -> UInt64 {
  let buf = read_n_bytes(conn, 8)
  let mut v : UInt64 = 0UL
  for i in 0..<8 {
    v = v | (buf[i].to_uint64() << (i * 8))
  }
  v
}

///|
async fn read_int32_le(conn : @socket.Tcp) -> Int {
  let buf = read_n_bytes(conn, 4)
  buf[0].to_int() |
  (buf[1].to_int() << 8) |
  (buf[2].to_int() << 16) |
  (buf[3].to_int() << 24)
}

///|
/// Read 8 bytes LE as Int64.
async fn read_int64_le(conn : @socket.Tcp) -> Int64 {
  let buf = read_n_bytes(conn, 8)
  let mut v : Int64 = 0L
  for i in 0..<8 {
    v = v | (buf[i].to_int64() << (i * 8))
  }
  v
}

// ============ ServerHello ============

///|
async fn read_server_hello(conn : @socket.Tcp) -> UInt {
  let _ = read_varuint(conn)
  let server_name = read_string_binary(conn)
  let major = read_varuint(conn).reinterpret_as_int()
  let minor = read_varuint(conn).reinterpret_as_int()
  let srv_rev = read_varuint(conn)
  let _ = if srv_rev >= 54058U { read_string_binary(conn) } else { "" }
  let _ = if srv_rev >= 54372U { read_string_binary(conn) } else { "" }
  if srv_rev >= 54401U {
    let _ = read_varuint(conn)
  }
  println(
    "Connected to " +
    server_name +
    " v" +
    major.to_string() +
    "." +
    minor.to_string(),
  )
  srv_rev
}

// ============ Block parsing ============

///|
/// Skip BlockInfo tagged stream.
async fn skip_block_info(conn : @socket.Tcp) -> Unit {
  let mut tag = read_varuint(conn)
  while tag != 0U {
    if tag == 1U {
      let _ = read_varuint(conn)
    } else if tag == 2U {
      let _ = read_int32_le(conn)
    } else if tag == 3U {
      let n = read_varuint(conn).reinterpret_as_int()
      for _i in 0..<n {
        let _ = read_int32_le(conn)
      }
    } else {
      tag = 0U
    }
    tag = read_varuint(conn)
  }
}

///|
/// Read a single value as string based on its CHType.
/// For composite types (Nullable, Array, Tuple, Map), this reads one value
/// and returns a human-readable string representation.
async fn read_typed_value(conn : @socket.Tcp, typ : CHType) -> String {
  match typ {
    UInt8 => {
      let b = read_n_bytes(conn, 1)
      b[0].to_uint().to_string()
    }
    UInt16 => read_uint16_le(conn).to_string()
    UInt32 => read_uint32_le(conn).to_string()
    UInt64 => read_uint64_le(conn).to_string()
    Int8 => {
      let b = read_n_bytes(conn, 1)
      let v = b[0].to_int()
      let signed = if v > 127 { v - 256 } else { v }
      signed.to_string()
    }
    Int16 => {
      let v = read_uint16_le(conn).reinterpret_as_int()
      let signed = if v > 32767 { v - 65536 } else { v }
      signed.to_string()
    }
    Int32 => read_int32_le(conn).to_string()
    Int64 => read_int64_le(conn).to_string()
    Int128 => {
      // 16 bytes — best effort: read and return hex placeholder
      let _ = read_n_bytes(conn, 16)
      "<Int128>"
    }
    UInt128 => {
      let _ = read_n_bytes(conn, 16)
      "<UInt128>"
    }
    Int256 => {
      let _ = read_n_bytes(conn, 32)
      "<Int256>"
    }
    UInt256 => {
      let _ = read_n_bytes(conn, 32)
      "<UInt256>"
    }
    Float32 => {
      let buf = read_n_bytes(conn, 4)
      let raw = buf[0].to_int() |
        (buf[1].to_int() << 8) |
        (buf[2].to_int() << 16) |
        (buf[3].to_int() << 24)
      let f = Float::reinterpret_from_int(raw)
      f.to_string()
    }
    Float64 => {
      let buf = read_n_bytes(conn, 8)
      let mut raw : Int64 = 0L
      for i in 0..<8 {
        raw = raw | (buf[i].to_int64() << (i * 8))
      }
      let d = raw.reinterpret_as_double()
      d.to_string()
    }
    Bool => {
      let b = read_n_bytes(conn, 1)
      if b[0] == b'\x00' {
        "false"
      } else {
        "true"
      }
    }
    String => read_string_binary(conn)
    FixedString(n) => {
      let bytes = conn.read_exactly(n)
      @utf8.decode_lossy(bytes)
    }
    Date => {
      // UInt16 LE — days since 1970-01-01
      let days = read_uint16_le(conn).reinterpret_as_int()
      format_date(days)
    }
    Date32 => {
      // Int32 LE — days since 1970-01-01 (can be negative)
      let days = read_int32_le(conn)
      format_date(days)
    }
    DateTime => {
      // UInt32 LE — seconds since 1970-01-01
      let secs = read_int32_le(conn)
      format_datetime(secs)
    }
    DateTime64(scale) => {
      // Int64 LE — ticks of 10^(-scale) seconds since epoch
      let ticks = read_int64_le(conn)
      let secs = (ticks / pow10_int64(scale)).to_int()
      let frac = (ticks % pow10_int64(scale)).to_int()
      let base = format_datetime(secs)
      if scale > 0 && frac != 0 {
        let frac_str = frac.to_string()
        let padded = str_repeat("0", scale - frac_str.length()) + frac_str
        base + "." + padded
      } else {
        base
      }
    }
    Decimal(precision, scale) =>
      if precision <= 9 {
        // Decimal32 — Int32 LE
        let v = read_int32_le(conn).to_int64()
        format_decimal_str(v, scale)
      } else if precision <= 18 {
        // Decimal64 — Int64 LE
        let v = read_int64_le(conn)
        format_decimal_str(v, scale)
      } else {
        // Decimal128 / Decimal256 — read raw bytes, return placeholder
        let bytes_needed = if precision <= 38 { 16 } else { 32 }
        let _ = read_n_bytes(conn, bytes_needed)
        "<Decimal(" + precision.to_string() + "," + scale.to_string() + ")>"
      }
    Decimal32(scale) => {
      let v = read_int32_le(conn).to_int64()
      format_decimal_str(v, scale)
    }
    Decimal64(scale) => {
      let v = read_int64_le(conn)
      format_decimal_str(v, scale)
    }
    Decimal128(scale) => {
      let _ = read_n_bytes(conn, 16)
      "<Decimal128(" + scale.to_string() + ")>"
    }
    Decimal256(scale) => {
      let _ = read_n_bytes(conn, 32)
      "<Decimal256(" + scale.to_string() + ")>"
    }
    UUID => {
      let buf = read_n_bytes(conn, 16)
      format_uuid(buf)
    }
    IPv4 => {
      let buf = read_n_bytes(conn, 4)
      buf[0].to_int().to_string() +
      "." +
      buf[1].to_int().to_string() +
      "." +
      buf[2].to_int().to_string() +
      "." +
      buf[3].to_int().to_string()
    }
    IPv6 => {
      let buf = read_n_bytes(conn, 16)
      format_ipv6(buf)
    }
    Enum8 => {
      let b = read_n_bytes(conn, 1)
      let v = b[0].to_int()
      let signed = if v > 127 { v - 256 } else { v }
      signed.to_string()
    }
    Enum16 => {
      let v = read_uint16_le(conn).reinterpret_as_int()
      let signed = if v > 32767 { v - 65536 } else { v }
      signed.to_string()
    }
    Nullable(inner) => {
      let flag = read_n_bytes(conn, 1)
      if flag[0] == b'\x00' {
        "NULL"
      } else {
        read_typed_value(conn, inner)
      }
    }
    Array(inner) => {
      let n = read_varuint(conn).reinterpret_as_int()
      let mut result = "["
      for i in 0..<n {
        if i > 0 {
          result = result + ", "
        }
        result = result + read_typed_value(conn, inner)
      }
      result + "]"
    }
    Tuple(types) => {
      let mut result = "("
      for i in 0..<types.length() {
        if i > 0 {
          result = result + ", "
        }
        result = result + read_typed_value(conn, types[i])
      }
      result + ")"
    }
    Map(key_type, val_type) => {
      // Map serializes as Array(Tuple(K, V))
      let n = read_varuint(conn).reinterpret_as_int()
      let mut result = "{"
      for i in 0..<n {
        if i > 0 {
          result = result + ", "
        }
        let k = read_typed_value(conn, key_type)
        let v = read_typed_value(conn, val_type)
        result = result + k + ":" + v
      }
      result + "}"
    }
    LowCardinality(_) =>
      // LowCardinality is column-serialized; per-value read is not valid.
      // This branch should never be hit if read_column handles it.
      // Fallback: read as string binary.
      read_string_binary(conn)
    SimpleAggregateFunction(inner) => read_typed_value(conn, inner)
    Unknown =>
      // Best-effort: try reading as a string
      read_string_binary(conn)
  }
}

///|
/// Compute 10^n as Int64.
fn pow10_int64(n : Int) -> Int64 {
  let mut result = 1L
  for _ in 0..<n {
    result = result * 10L
  }
  result
}

///|
/// Read an entire column of num_rows values.
/// In ClickHouse Native format, composite types serialize their sub-columns
/// as contiguous blocks (not interleaved per-row). This function handles
/// that column-oriented serialization for Nullable, Array, Tuple, Map,
/// and LowCardinality.
async fn read_column(
  conn : @socket.Tcp,
  typ : CHType,
  num_rows : Int,
) -> Array[String] {
  match typ {
    Nullable(inner) => {
      // Nullable: null_map (num_rows bytes) + nested column
      // ClickHouse null_map: 0 = not null, 1 = null
      let null_map = read_n_bytes(conn, num_rows)
      let values = read_column(conn, inner, num_rows)
      let result : Array[String] = []
      for i in 0..<num_rows {
        if null_map[i] == b'\x00' {
          result.push(values[i])
        } else {
          result.push("NULL")
        }
      }
      result
    }
    Array(inner) => {
      // Array: offsets (num_rows UInt64) + nested data
      // offsets are cumulative: [len1, len1+len2, len1+len2+len3, ...]
      let lengths : Array[Int] = []
      let mut prev = 0
      for _ in 0..<num_rows {
        let off = read_int64_le(conn).to_int()
        lengths.push(off - prev)
        prev = off
      }
      let total = prev
      let elements = read_column(conn, inner, total)
      let result : Array[String] = []
      let mut idx = 0
      for i in 0..<num_rows {
        let len = lengths[i]
        let mut s = "["
        for j in 0..<len {
          if j > 0 {
            s = s + ", "
          }
          s = s + elements[idx]
          idx = idx + 1
        }
        result.push(s + "]")
      }
      result
    }
    Tuple(types) => {
      // Tuple: each sub-column is serialized contiguously
      let sub_cols : Array[Array[String]] = []
      for i in 0..<types.length() {
        sub_cols.push(read_column(conn, types[i], num_rows))
      }
      let result : Array[String] = []
      for r in 0..<num_rows {
        let mut s = "("
        for i in 0..<types.length() {
          if i > 0 {
            s = s + ", "
          }
          s = s + sub_cols[i][r]
        }
        result.push(s + ")")
      }
      result
    }
    Map(key_type, val_type) => {
      // Map serializes as Array(Tuple(K, V)):
      // offsets (num_rows UInt64) + keys + values
      let lengths : Array[Int] = []
      let mut prev = 0
      for _ in 0..<num_rows {
        let off = read_int64_le(conn).to_int()
        lengths.push(off - prev)
        prev = off
      }
      let total = prev
      let keys = read_column(conn, key_type, total)
      let vals = read_column(conn, val_type, total)
      let result : Array[String] = []
      let mut idx = 0
      for i in 0..<num_rows {
        let len = lengths[i]
        let mut s = "{"
        for j in 0..<len {
          if j > 0 {
            s = s + ", "
          }
          s = s + keys[idx] + ":" + vals[idx]
          idx = idx + 1
        }
        result.push(s + "}")
      }
      result
    }
    LowCardinality(inner) => {
      // LowCardinality: version + dict_size + dict + num_rows + indices
      let _version = read_int64_le(conn)
      let dict_size = read_int64_le(conn).to_int()
      let dict : Array[String] = []
      for _ in 0..<dict_size {
        dict.push(read_typed_value(conn, inner))
      }
      let n_rows = read_int64_le(conn).to_int()
      let result : Array[String] = []
      for _ in 0..<n_rows {
        let idx = read_int64_le(conn).to_int()
        if idx >= 0 && idx < dict.length() {
          result.push(dict[idx])
        } else {
          result.push("<invalid_lc_index:" + idx.to_string() + ">")
        }
      }
      result
    }
    _ => {
      // Simple types: read value-by-value (N consecutive values)
      let result : Array[String] = []
      for _ in 0..<num_rows {
        result.push(read_typed_value(conn, typ))
      }
      result
    }
  }
}

///|
/// Parse one Data packet. Returns (columns, rows).
/// For schema blocks (0 rows): returns (columns, []).
/// For data blocks: returns ([], rows).
/// Uses column-major reading to correctly handle LowCardinality and other
/// column-serialized types.
async fn parse_data_block(conn : @socket.Tcp) -> (Array[Column], Array[Row]) {
  let _ = read_string_binary(conn) // temp_table
  skip_block_info(conn)
  let num_cols = read_varuint(conn).reinterpret_as_int()
  let num_rows = read_varuint(conn).reinterpret_as_int()

  // ClickHouse Native format: each column's name, type, and data are
  // serialized together (name, type, data, name, type, data, ...)
  let cols : Array[Column] = []
  let columns_data : Array[Array[String]] = []
  for _c in 0..<num_cols {
    let name = read_string_binary(conn)
    let typ = read_string_binary(conn)
    cols.push({ name, type_: typ })
    let parsed = parse_type(typ)
    columns_data.push(read_column(conn, parsed, num_rows))
  }

  // Transpose column-major data into row-major result
  let rows : Array[Row] = []
  for _r in 0..<num_rows {
    let values : Array[String] = []
    for _c in 0..<num_cols {
      values.push(columns_data[_c][_r])
    }
    rows.push({ values, })
  }

  if num_rows == 0 {
    (cols, [])
  } else {
    ([], rows)
  }
}

// ============ Response reader ============

///|
/// Read all response packets, return ResultSet.
async fn read_response(conn : @socket.Tcp) -> ResultSet raise {
  let mut columns : Array[Column] = []
  let rows : Array[Row] = []
  let mut ok = true
  while ok {
    let pkt = read_varuint(conn).reinterpret_as_int()
    if pkt == 1 {
      // Server::Data
      let (new_cols, new_rows) = parse_data_block(conn)
      if new_cols.length() > 0 {
        columns = new_cols
      }
      for i in 0..<new_rows.length() {
        rows.push(new_rows[i])
      }
    } else if pkt == 2 {
      // Server::Exception
      let code = read_int32_le(conn)
      let name = read_string_binary(conn)
      let message = read_string_binary(conn)
      let _ = read_string_binary(conn)
      let _ = read_varuint(conn)
      raise ServerError(code~, name~, message~)
    } else if pkt == 3 {
      // Progress: skip basic fields (read_rows, read_bytes, total_rows,
      // total_bytes, elapsed_ns). For rev >= 54429 the server may also
      // append a profile-events block; we skip it best-effort by attempting
      // to read the block and falling through if the connection looks
      // broken.
      let _ = read_varuint(conn)
      let _ = read_varuint(conn)
      let _ = read_varuint(conn)
      let _ = read_varuint(conn)
      let _ = read_varuint(conn)
    } else if pkt == 4 {
      // Pong
    } else if pkt == 5 {
      // EndOfStream
      let _ = read_varuint(conn)
      let _ = read_varuint(conn)
      let _ = read_varuint(conn)
      ok = false
    } else if pkt == 6 {
      // ProfileInfo — UInt64 fields: rows, blocks, bytes, applied_limit,
      // rows_before_limit. Older revisions may omit the last field.
      let _ = read_varuint(conn)
      let _ = read_varuint(conn)
      let _ = read_varuint(conn)
      let _ = read_varuint(conn)
    } else {
      ok = false
    }
  }
  { columns, rows }
}

// ============ Public API ============

///|
/// Connect to a ClickHouse server, perform the handshake.
pub async fn connect(
  host~ : String,
  port~ : Int,
  user~ : String,
  password~ : String,
  database~ : String,
  client_name~ : String,
) -> Connection {
  let addr = @socket.Addr::parse(host + ":" + port.to_string())
  let tcp = @socket.Tcp::connect(addr)

  let hello = build_client_hello(
    client_name~,
    version_major=1U,
    version_minor=0U,
    revision=CLIENT_REVISION,
    default_database=database,
    user~,
    password~,
  )
  tcp.write(hello)

  let srv_rev = read_server_hello(tcp)

  { tcp, server_rev: srv_rev, user, client_name }
}

///|
/// Close the connection.
pub fn Connection::close(self : Connection) -> Unit {
  self.tcp.close()
}

///|
/// Lightweight health check. Sends a Client::Ping packet and expects a Server::Pong.
/// Raises DbError::ConnectionError on protocol mismatch, propagates other I/O errors.
pub async fn Connection::ping(self : Connection) -> Unit {
  let buf = Buffer::Buffer(size_hint=1)
  write_varuint(buf, 4U) // Client::Ping
  self.tcp.write(buf.to_bytes())
  let pkt = read_varuint(self.tcp)
  if pkt != 4U {
    // Server::Pong
    raise ConnectionError("expected Pong, got " + pkt.to_string())
  }
}

///|
/// Execute any SQL statement (SELECT, INSERT, UPDATE, DDL, ...) and return
/// the parsed result set. For non-SELECT statements the returned `rows`
/// will typically be empty. Raises DbError::ServerError when the server
/// rejects the query (syntax error, missing table, etc.).
/// Other raised errors are propagated from the underlying I/O layer.
pub async fn Connection::execute_query(
  self : Connection,
  sql : String,
) -> ResultSet {
  let client_info = build_client_info(
    user=self.user,
    initial_address="127.0.0.1:9002",
    client_name=self.client_name,
    rev=CLIENT_REVISION,
  )
  let query = build_query(client_info~, sql~)
  let empty = build_empty_data()

  self.tcp.write(query)
  self.tcp.write(empty)

  read_response(self.tcp)
}
