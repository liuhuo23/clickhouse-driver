///|
/// 列类型注册表与值解码：按 ClickHouse 类型名分派，把二进制列值解码为字符串
/// （与 HTTP 版 `Row.values: Array[String]` 对齐）。
///
/// 基础版本支持：UInt8-64 / Int8-64 / Float32-64 / String / Date / Date32 /
/// DateTime / DateTime64 / FixedString(N) / Enum8 / Enum16 / Nullable(T)。
/// 未知类型抛 `@lib.ConnectionError`，保证不静默产出错误数据。

///|
/// 解码一个二进制值并返回字符串表示。
/// `Nullable(T)` 的空值返回 `""`（与 HTTP 版一致）。
async fn[R : @io.Reader] read_value(reader : R, type_name : String) -> String {
  if type_name.has_prefix("Nullable(") {
    let inner = type_name[9:type_name.length() - 1].to_string()
    let is_null = reader.read_exactly(1)[0].to_uint()
    if is_null != 0 {
      return ""
    }
    return read_value(reader, inner)
  }
  if type_name.has_prefix("FixedString(") {
    let n = parse_int_inner(type_name[12:type_name.length() - 1].to_string())
    let bytes = reader.read_exactly(n)
    let mut end = bytes.length()
    while end > 0 && bytes[end - 1].to_uint() == 0 {
      end = end - 1
    }
    return @utf8.decode(bytes.view(start=0, end~))
  }
  if type_name.has_prefix("DateTime64(") {
    let scale = parse_type_param(type_name, "(")
    let v = read_int64(reader)
    return format_datetime64(v, scale)
  }
  if type_name == "DateTime" || type_name.has_prefix("DateTime(") {
    let v = read_uint32(reader)
    return format_datetime(v.to_int64())
  }
  if type_name == "Date32" {
    let v = read_int32(reader)
    return format_date_from_days(v.to_int64())
  }
  if type_name == "Date" {
    let v = read_uint16(reader)
    return format_date_from_days(v.to_uint().to_int64())
  }
  if type_name.has_prefix("Decimal(") {
    return read_decimal(reader, type_name)
  }
  if type_name.has_prefix("UUID") {
    return read_uuid(reader)
  }
  if type_name == "IPv4" {
    let bytes = reader.read_exactly(4)
    return format_ipv4(bytes)
  }
  if type_name == "IPv6" {
    let bytes = reader.read_exactly(16)
    return format_ipv6(bytes)
  }
  match type_name {
    "UInt8" => reader.read_exactly(1)[0].to_uint().to_string()
    "UInt16" => read_uint16(reader).to_string()
    "UInt32" => read_uint32(reader).to_string()
    "UInt64" => read_uint64(reader).to_string()
    "Int8" => read_int8(reader).to_string()
    "Int16" => read_int16(reader).to_string()
    "Int32" => read_int32(reader).to_string()
    "Int64" => read_int64(reader).to_string()
    "Float32" => read_float32(reader).to_string()
    "Float64" => read_float64(reader).to_string()
    "String" => read_string(reader)
    "Nothing" => ""
    _ if type_name.has_prefix("Enum8(") => read_enum_value(reader, type_name, 1)
    _ if type_name.has_prefix("Enum16(") =>
      read_enum_value(reader, type_name, 2)
    _ => raise @lib.DbError::connection_error("unsupported type: \{type_name}")
  }
}

///|
/// UUID 解码：16 字节，先高 64 位小端、再低 64 位小端（UInt128 小端序），
/// 输出 `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`。
async fn[R : @io.Reader] read_uuid(reader : R) -> String {
  let bytes = reader.read_exactly(16)
  let (hi, _) = decode_uint64(bytes, 0)
  let (lo, _) = decode_uint64(bytes, 8)
  format_uuid(lo, hi)
}

///|
/// UUID 文本格式：`{hi 低32位}-{hi 32-47位}-{hi 48-63位}-{lo 高16位}-{lo 低48位}`
/// （ClickHouse UInt128：lo=低 64 位，hi=高 64 位；存储为小端）。
fn format_uuid(lo : UInt64, hi : UInt64) -> String {
  let hex_chars = "0123456789abcdef"
  let out = Buffer::Buffer()
  fn push_hex(buf : Buffer, v : UInt, shift : Int) -> Unit {
    let idx = ((v >> shift) & 0xF).to_int()
    buf.write_byte(hex_chars[idx].to_byte())
  }
  fn push_u32(buf : Buffer, v : UInt) -> Unit {
    let mut shift = 28
    while shift >= 0 {
      push_hex(buf, v, shift)
      shift = shift - 4
    }
  }
  fn push_u16(buf : Buffer, v : UInt) -> Unit {
    let mut shift = 12
    while shift >= 0 {
      push_hex(buf, v, shift)
      shift = shift - 4
    }
  }
  push_u32(out, (hi >> 32).to_uint()) // time_low = hi 高 32 位
  out.write_byte(b'-')
  push_u16(out, ((hi >> 16) & 0xFFFF).to_uint()) // time_mid
  out.write_byte(b'-')
  push_u16(out, (hi & 0xFFFF).to_uint()) // time_hi
  out.write_byte(b'-')
  push_u16(out, ((lo >> 48) & 0xFFFF).to_uint()) // clock_seq
  out.write_byte(b'-')
  // node = lo 低 48 位（12 hex）
  let mut shift = 40
  while shift >= 0 {
    let b = ((lo >> shift) & 0xFF).to_uint()
    push_hex(out, b, 4)
    push_hex(out, b, 0)
    shift = shift - 8
  }
  @utf8.decode_lossy(out.to_bytes())
}

///|
/// 读取 Int8（符号扩展）。
async fn[R : @io.Reader] read_int8(reader : R) -> Int {
  let u = reader.read_exactly(1)[0].to_uint()
  if u >= 128 {
    u.to_int() - 256
  } else {
    u.to_int()
  }
}

///|
/// 读取 Int16（符号扩展）。
async fn[R : @io.Reader] read_int16(reader : R) -> Int {
  let u = read_uint16(reader).to_uint()
  if u >= 32768 {
    u.to_int() - 65536
  } else {
    u.to_int()
  }
}

///|
/// 解析整数子串（仅限正数，用于 FixedString(N)/DateTime64(N)/Decimal(P,S)）。
fn parse_int_inner(s : String) -> Int raise {
  let mut v = 0
  for ch in s {
    if ch < '0' || ch > '9' {
      raise @lib.DbError::connection_error("invalid integer in type: \{s}")
    }
    v = v * 10 + (ch.to_int() - 48)
  }
  v
}

///|
/// 解析类型参数中的第一个整数（如 DateTime64(3) → 3）。
fn parse_type_param(type_name : String, marker : String) -> Int raise {
  let open = type_name.find(marker).or(0)
  let comma = type_name.find(",").or(type_name.length() - 1)
  let s = type_name[open + 1:comma].trim()
  parse_int_inner(s.to_string())
}

///|
/// 按列解码 `nrows` 个值（ClickHouse bulk 序列化格式）。
///
/// 复合类型递归处理：
/// - `Nullable(T)`：整列 mask + 内层 T 的 bulk（两段式）
/// - `Array(T)`：nrows 个 UInt64 小端累计偏移 + 平铺元素的 bulk
/// - `Tuple(...)`：各子列各自 bulk
/// - `Map(K,V)`：同 Array(Tuple(K,V)) 的 bulk
/// - 标量：逐行单值
async fn[R : @io.Reader] read_column_values(
  reader : R,
  type_name : String,
  nrows : Int,
) -> Array[String] {
  if type_name.has_prefix("Nullable(") {
    let inner = type_name[9:type_name.length() - 1].to_string()
    let masks = reader.read_exactly(nrows)
    let values = read_column_values(reader, inner, nrows)
    for r in 0..<nrows {
      if masks[r].to_uint() != 0 {
        values[r] = ""
      }
    }
    return values
  }
  if type_name.has_prefix("Array(") {
    let inner = type_name[6:type_name.length() - 1].to_string()
    return read_array_bulk(reader, inner, nrows)
  }
  if type_name.has_prefix("Map(") {
    let inner = type_name[4:type_name.length() - 1].to_string()
    let parts = split_top_level(inner)
    if parts.length() != 2 {
      raise @lib.DbError::connection_error("invalid Map type: \{type_name}")
    }
    return read_map_bulk(reader, parts[0], parts[1], nrows)
  }
  if type_name.has_prefix("Tuple(") {
    let inner = type_name[6:type_name.length() - 1].to_string()
    let parts = split_top_level(inner)
    return read_tuple_bulk(reader, parts, nrows)
  }
  if type_name.has_prefix("LowCardinality(") {
    raise @lib.DbError::connection_error(
      "LowCardinality is disabled via low_cardinality_allow_in_native_format=0; got \{type_name}",
    )
  }
  // 标量：逐行单值（单值与 bulk 字节一致）
  let values : Array[String] = Array::make(nrows, "")
  for r in 0..<nrows {
    values[r] = read_value(reader, type_name)
  }
  values
}

///|
/// Array bulk：UInt64 小端累计偏移 + 平铺元素（内层 bulk）。
async fn[R : @io.Reader] read_array_bulk(
  reader : R,
  inner : String,
  nrows : Int,
) -> Array[String] {
  let offsets : Array[Int64] = Array::make(nrows, 0L)
  for r in 0..<nrows {
    offsets[r] = read_uint64(reader).reinterpret_as_int64()
  }
  let total = if nrows == 0 { 0L } else { offsets[nrows - 1] }
  if total < 0L || total > 100000000L {
    raise @lib.DbError::connection_error("array too large: \{total}")
  }
  let elements = read_column_values(reader, inner, total.to_int())
  let values : Array[String] = Array::make(nrows, "")
  let mut prev : Int64 = 0L
  for r in 0..<nrows {
    let end = offsets[r]
    if end < prev || end > total {
      raise @lib.DbError::connection_error("invalid array offsets")
    }
    let cnt = (end - prev).to_int()
    let parts : Array[String] = Array::make(cnt, "")
    for i in 0..<cnt {
      parts[i] = format_nested_value(elements[(prev + i.to_int64()).to_int()])
    }
    values[r] = "[" + parts.join(",") + "]"
    prev = end
  }
  values
}

///|
/// Tuple bulk：各子列各自 bulk 后组合为 `(v1,v2,...)`。
async fn[R : @io.Reader] read_tuple_bulk(
  reader : R,
  parts : Array[String],
  nrows : Int,
) -> Array[String] {
  let cols : Array[Array[String]] = Array::make(parts.length(), [])
  for i in 0..<parts.length() {
    cols[i] = read_column_values(reader, parts[i], nrows)
  }
  let values : Array[String] = Array::make(nrows, "")
  for r in 0..<nrows {
    let parts_str : Array[String] = Array::make(cols.length(), "")
    for c in 0..<cols.length() {
      parts_str[c] = format_nested_value(cols[c][r])
    }
    values[r] = "(" + parts_str.join(",") + ")"
  }
  values
}

///|
/// Map bulk：同 Array(Tuple(K,V))——UInt64 累计偏移 + K bulk + V bulk。
async fn[R : @io.Reader] read_map_bulk(
  reader : R,
  ktype : String,
  vtype : String,
  nrows : Int,
) -> Array[String] {
  let offsets : Array[Int64] = Array::make(nrows, 0L)
  for r in 0..<nrows {
    offsets[r] = read_uint64(reader).reinterpret_as_int64()
  }
  let total = if nrows == 0 { 0L } else { offsets[nrows - 1] }
  if total < 0L || total > 100000000L {
    raise @lib.DbError::connection_error("map too large: \{total}")
  }
  let keys = read_column_values(reader, ktype, total.to_int())
  let vals = read_column_values(reader, vtype, total.to_int())
  let values : Array[String] = Array::make(nrows, "")
  let mut prev : Int64 = 0L
  for r in 0..<nrows {
    let end = offsets[r]
    let cnt = (end - prev).to_int()
    let parts : Array[String] = Array::make(cnt, "")
    for i in 0..<cnt {
      let idx = (prev + i.to_int64()).to_int()
      parts[i] = "\'" + keys[idx] + "\':" + format_nested_value(vals[idx])
    }
    values[r] = "{" + parts.join(",") + "}"
    prev = end
  }
  values
}

///|
/// 嵌套值文本化（tuple/map 内部）：字符串加单引号，NULL 显示 NULL。
fn format_nested_value(v : String) -> String {
  if v == "" {
    "NULL"
  } else if looks_like_string(v) {
    "\'" + v + "\'"
  } else {
    v
  }
}

///|
/// 判断值是否为字符串（需要加引号）。
fn looks_like_string(v : String) -> Bool {
  // 简单启发：非空且不是数字/日期/数组/元组/map/布尔
  let first = v[0]
  (first >= 'a' && first <= 'z') ||
  (first >= 'A' && first <= 'Z') ||
  first == '_' ||
  first == '\'' ||
  v.contains(" ")
}

///|
/// 按顶层逗号拆分类型参数（考虑嵌套括号）。
fn split_top_level(s : String) -> Array[String] {
  let parts : Array[String] = []
  let mut depth = 0
  let mut start = 0
  for i in 0..<s.length() {
    let ch = s[i]
    if ch == '(' || ch == '[' {
      depth = depth + 1
    } else if ch == ')' || ch == ']' {
      depth = depth - 1
    } else if ch == ',' && depth == 0 {
      parts.push(s[start:i].trim().to_string())
      start = i + 1
    }
  }
  parts.push(s[start:].trim().to_string())
  parts
}

///|
/// Enum 值解码：读 Int8/Int16 并映射为枚举名称；未知值回退为数字。
async fn[R : @io.Reader] read_enum_value(
  reader : R,
  type_name : String,
  byte_width : Int,
) -> String {
  let raw = if byte_width == 1 { read_int8(reader) } else { read_int16(reader) }
  let map = parse_enum_map(type_name)
  for entry in map {
    if entry.0 == raw {
      return entry.1
    }
  }
  raw.to_string()
}

///|
/// 解析 Enum 类型名中的 `'name' = value` 映射。
fn parse_enum_map(type_name : String) -> Array[(Int, String)] {
  let open = type_name.find("(").or(0)
  let close = type_name.length() - 1
  let inner = type_name[open + 1:close].to_string()
  let entries = split_top_level(inner)
  let result : Array[(Int, String)] = []
  for entry in entries {
    let eq = entry.find("=")
    match eq {
      Some(i) => {
        let name_sv = entry[:i].trim()
        let val_s = entry[i + 1:].trim().to_string()
        let name = name_sv.strip_prefix("\'").unwrap_or(name_sv)
        let name = name.strip_suffix("\'").unwrap_or(name)
        let val = parse_int_inner(val_s) catch { _ => 0 }
        result.push((val, name.to_string()))
      }
      None => ()
    }
  }
  result
}

///|
/// Decimal 解码：按精度分派 32/64/128/256 位，输出十进制字符串。
async fn[R : @io.Reader] read_decimal(reader : R, type_name : String) -> String {
  let open = type_name.find("(").or(0)
  let comma = type_name.find(",").or(type_name.length() - 1)
  let prec_s = type_name[open + 1:comma].trim()
  let scale_s = type_name[comma + 1:type_name.length() - 1].trim()
  let prec = parse_int_inner(prec_s.to_string())
  let scale = parse_int_inner(scale_s.to_string())
  let big = if prec <= 9 {
    @bigint.BigInt::from_int64(read_int32(reader).to_int64())
  } else if prec <= 18 {
    @bigint.BigInt::from_int64(read_int64(reader))
  } else if prec <= 38 {
    read_decimal_big(reader, 16)
  } else {
    read_decimal_big(reader, 32)
  }
  format_big_decimal(big, scale)
}

///|
/// 读取定长小端有符号大整数（Decimal128/256）。
async fn[R : @io.Reader] read_decimal_big(
  reader : R,
  nbytes : Int,
) -> @bigint.BigInt {
  let bytes = reader.read_exactly(nbytes)
  let rev = Buffer::Buffer(size_hint=nbytes)
  let mut i = nbytes - 1
  while i >= 0 {
    rev.write_byte(bytes[i])
    i = i - 1
  }
  // 无符号解释 + 补码修正（from_octets 的 signum 不是补码语义）
  let unsigned = @bigint.BigInt::from_octets(rev.to_bytes())
  if (bytes[nbytes - 1].to_uint() & 0x80) != 0 {
    let modulus = @bigint.BigInt::from_int(1) << (nbytes * 8)
    unsigned - modulus
  } else {
    unsigned
  }
}

///|
/// 按小数位格式化 BigInt Decimal。
fn format_big_decimal(big : @bigint.BigInt, scale : Int) -> String {
  let zero = @bigint.BigInt::from_int(0)
  let negative = big < zero
  let abs = if negative { -big } else { big }
  if scale <= 0 {
    return abs.to_string()
  }
  let pow = @bigint.BigInt::from_int(10).pow(@bigint.BigInt::from_int(scale))
  let int_part = (abs / pow).to_string()
  let frac = (abs % pow).to_string()
  let mut frac_padded = ""
  for _ in 0..<(scale - frac.length()) {
    frac_padded = frac_padded + "0"
  }
  frac_padded = frac_padded + frac
  // 去掉小数尾零（与 HTTP 文本格式一致：1.50 → 1.5，1.00 → 1）
  while frac_padded.length() > 0 && frac_padded[frac_padded.length() - 1] == '0' {
    frac_padded = frac_padded[:frac_padded.length() - 1].to_string()
  }
  if negative {
    if frac_padded.length() == 0 {
      "-" + int_part
    } else {
      "-" + int_part + "." + frac_padded
    }
  } else if frac_padded.length() == 0 {
    int_part
  } else {
    int_part + "." + frac_padded
  }
}

///|
/// IPv4：存储为 UInt32 小端 → `a.b.c.d`。
fn format_ipv4(bytes : Bytes) -> String {
  bytes[3].to_int().to_string() +
  "." +
  bytes[2].to_int().to_string() +
  "." +
  bytes[1].to_int().to_string() +
  "." +
  bytes[0].to_int().to_string()
}

///|
/// IPv6：16 字节大端 → 标准压缩文本（如 `::1`）。
fn format_ipv6(bytes : Bytes) -> String {
  let groups : Array[Int] = Array::make(8, 0)
  for i in 0..<8 {
    groups[i] = bytes[i * 2].to_int() * 256 + bytes[i * 2 + 1].to_int()
  }
  // 找最长连续 0 组
  let mut best_start = -1
  let mut best_len = 0
  let mut cur_start = -1
  let mut cur_len = 0
  for i in 0..<8 {
    if groups[i] == 0 {
      if cur_start < 0 {
        cur_start = i
        cur_len = 1
      } else {
        cur_len = cur_len + 1
      }
      if cur_len > best_len {
        best_start = cur_start
        best_len = cur_len
      }
    } else {
      cur_start = -1
      cur_len = 0
    }
  }
  let mut out = ""
  let mut i = 0
  while i < 8 {
    if i == best_start && best_len >= 2 {
      out = out + (if i == 0 { "::" } else { ":" })
      i = i + best_len
      continue
    }
    out = out + hex_group(groups[i])
    if i < 7 {
      out = out + ":"
    }
    i = i + 1
  }
  if best_len >= 2 && best_start + best_len == 8 && best_start != 0 {
    // 末尾压缩
    out = out + ":"
  }
  if best_len == 8 {
    "::"
  } else {
    out
  }
}

///|
fn hex_group(v : Int) -> String {
  let hex_chars = "0123456789abcdef"
  if v == 0 {
    return "0"
  }
  let mut s = ""
  let mut x = v
  while x > 0 {
    s = hex_chars[x % 16:x % 16 + 1].to_string() + s
    x = x / 16
  }
  s
}

///|
fn civil_from_days(days : Int64) -> (Int64, Int64, Int64) {
  let z = days + 719468L
  let era = (if z >= 0L { z } else { z - 146096L }) / 146097L
  let doe = z - era * 146097L
  let yoe = (doe - doe / 1460L + doe / 36524L - doe / 146096L) / 365L
  let y = yoe + era * 400L
  let doy = doe - (365L * yoe + yoe / 4L - yoe / 100L)
  let mp = (5L * doy + 2L) / 153L
  let d = doy - (153L * mp + 2L) / 5L + 1L
  let m = if mp < 10L { mp + 3L } else { mp - 9L }
  let y = if m <= 2L { y + 1L } else { y }
  (y, m, d)
}

///|
/// 将整数补零为至少 `width` 位字符串（截断超过部分）。
fn pad_int(v : Int64, width : Int) -> String {
  let s = v.to_string()
  if s.length() >= width {
    return s
  }
  let mut out = ""
  for i in 0..<(width - s.length()) {
    ignore(i)
    out = out + "0"
  }
  out + s
}

///|
/// 格式化 Date（自 1970-01-01 的天数）为 `YYYY-MM-DD`。
fn format_date_from_days(days : Int64) -> String {
  let (y, m, d) = civil_from_days(days)
  pad_int(y, 4) + "-" + pad_int(m, 2) + "-" + pad_int(d, 2)
}

///|
/// 格式化 DateTime（Unix 秒，UTC）为 `YYYY-MM-DD HH:MM:SS`。
fn format_datetime(seconds : Int64) -> String {
  let days = seconds / 86400L
  let rem = seconds % 86400L
  let hh = rem / 3600L
  let mm = rem % 3600L / 60L
  let ss = rem % 60L
  format_date_from_days(days) +
  " " +
  pad_int(hh, 2) +
  ":" +
  pad_int(mm, 2) +
  ":" +
  pad_int(ss, 2)
}

///|
/// 格式化 DateTime64（按精度缩放的 Int64 值，UTC）。
fn format_datetime64(v : Int64, scale : Int) -> String {
  if scale <= 0 {
    return format_datetime(v)
  }
  let mut pow : Int64 = 1L
  for i in 0..<scale {
    ignore(i)
    pow = pow * 10L
  }
  let seconds = v / pow
  let frac = v % pow
  if frac < 0L {
    return format_datetime(seconds - 1L) + "." + pad_int(frac + pow, scale)
  }
  format_datetime(seconds) + "." + pad_int(frac, scale)
}
