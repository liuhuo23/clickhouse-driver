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
  if type_name.has_prefix("LowCardinality(") {
    let inner = type_name[15:type_name.length() - 1].to_string()
    return read_low_cardinality(reader, inner)
  }
  if type_name.has_prefix("FixedString(") {
    let n = parse_int_inner(
      type_name.substring(start=12, end=type_name.length() - 1),
    )
    let bytes = reader.read_exactly(n)
    // 去掉尾部 \x00 填充
    let mut end = bytes.length()
    while end > 0 && bytes[end - 1].to_uint() == 0 {
      end = end - 1
    }
    return @utf8.decode(bytes.view(start=0, end~))
  }
  if type_name.has_prefix("DateTime64(") {
    let paren = type_name.find("(").or(0)
    let comma = type_name.find(",").or(type_name.length() - 1)
    let scale_s = type_name[paren + 1:comma].trim().to_string()
    let scale = parse_int_inner(scale_s)
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
  if type_name.has_prefix("Array(") {
    return read_array(reader, type_name)
  }
  if type_name.has_prefix("UUID") {
    return read_uuid(reader)
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
    _ if type_name.has_prefix("Enum8(") => read_int8(reader).to_string()
    _ if type_name.has_prefix("Enum16(") => read_int16(reader).to_string()
    _ => raise @lib.DbError::connection_error("unsupported type: \{type_name}")
  }
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
/// LowCardinality 解码：字典（String）+ UInt64 索引。
async fn[R : @io.Reader] read_low_cardinality(
  reader : R,
  inner : String,
) -> String {
  let dict_size = read_varuint(reader).to_int()
  if dict_size > 1000000 {
    raise @lib.DbError::connection_error(
      "low cardinality dictionary too large: \{dict_size}",
    )
  }
  let dict : Array[String] = Array::make(dict_size, "")
  for i in 0..<dict_size {
    dict[i] = read_value(reader, inner)
  }
  let index = read_uint64(reader)
  if index >= dict_size.to_uint64() {
    raise @lib.DbError::connection_error(
      "low cardinality index out of range: \{index}",
    )
  }
  dict[index.to_int()]
}

///|
/// Decimal(P,S) 解码：按精度分派 Int32/Int64/128。
async fn[R : @io.Reader] read_decimal(reader : R, type_name : String) -> String {
  let open = type_name.find("(").or(0)
  let comma = type_name.find(",").or(type_name.length() - 1)
  let prec_s = type_name[open + 1:comma].trim().to_string()
  let scale_s = type_name
    .substring(start=comma + 1, end=type_name.length() - 1)
    .trim()
    .to_string()
  let prec = parse_int_inner(prec_s)
  let scale = parse_int_inner(scale_s)
  if prec <= 9 {
    return format_decimal(read_int32(reader).to_int64(), scale)
  }
  if prec <= 18 {
    return format_decimal(read_int64(reader), scale)
  }
  // Decimal128：16 字节小端 → 用高 64 位近似（基础版本）
  let bytes = reader.read_exactly(16)
  let (lo, _) = decode_uint64(bytes, 0)
  let (hi, _) = decode_uint64(bytes, 8)
  if hi == 0 {
    return format_decimal(lo.reinterpret_as_int64(), scale)
  }
  raise @lib.DbError::connection_error(
    "Decimal128 with high bits is not supported yet: \{type_name}",
  )
}

///|
/// 按小数位格式化 Decimal 值（整数部分 + '.' + 小数位）。
fn format_decimal(v : Int64, scale : Int) -> String {
  if scale <= 0 {
    return v.to_string()
  }
  let mut abs = if v < 0 { -v } else { v }
  let negative = v < 0
  let digits : Array[Char] = []
  let mut i = 0
  while i < scale {
    digits.push(((abs % 10).to_int() + 48).unsafe_to_char())
    abs = abs / 10
    i = i + 1
  }
  let int_part = abs.to_string()
  let mut frac = ""
  let mut j = digits.length() - 1
  while j >= 0 {
    frac = frac + digits[j].to_string()
    j = j - 1
  }
  if negative {
    "-" + int_part + "." + frac
  } else {
    int_part + "." + frac
  }
}

///|
/// Array(T) 解码：VarUInt 长度 + 元素（按内层类型递归）。
async fn[R : @io.Reader] read_array(reader : R, type_name : String) -> String {
  let inner = type_name[6:type_name.length() - 1].to_string()
  let len = read_varuint(reader).to_int()
  if len > 10000000 {
    raise @lib.DbError::connection_error("array too large: \{len}")
  }
  let parts : Array[String] = Array::make(len, "")
  for i in 0..<len {
    parts[i] = read_value(reader, inner)
  }
  "[" + parts.join(",") + "]"
}

///|
/// UUID 解码：16 字节（前 8 字节小端、后 8 字节大端），输出
/// `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`。
async fn[R : @io.Reader] read_uuid(reader : R) -> String {
  let bytes = reader.read_exactly(16)
  let (lo, _) = decode_uint64(bytes, 0)
  let (hi, _) = decode_uint64(bytes, 8)
  format_uuid(lo, hi)
}

///|
fn format_uuid(lo : UInt64, hi : UInt64) -> String {
  // 前 4 字节（小端序取低 32 位）、中 2 字节、后 2 字节来自 lo；
  // 剩余 8 字节来自 hi（大端输出）。
  let hex_chars = "0123456789abcdef"
  let out = Buffer::Buffer()
  fn push_hex(buf : Buffer, v : UInt, shift : Int) -> Unit {
    let idx = ((v >> shift) & 0xF).to_int()
    buf.write_string(hex_chars.substring(start=idx, end=idx + 1))
  }
  // lo 的低 4 字节：time_low（小端读取，输出按 32 位序）
  let lo32 = lo.to_uint()
  let mut i = 4
  while i >= 1 {
    push_hex(out, lo32, i * 4 - 4 + 4)
    push_hex(out, lo32, i * 4 - 4)
    i = i - 1
  }
  out.write_string("-")
  // lo 的 5-6 字节
  let mid1 = ((lo >> 32) & 0xFFFF).to_uint()
  let mut i = 2
  while i >= 1 {
    push_hex(out, mid1, i * 4)
    push_hex(out, mid1, i * 4 - 4)
    i = i - 1
  }
  out.write_string("-")
  let mid2 = ((lo >> 48) & 0xFFFF).to_uint()
  let mut i = 2
  while i >= 1 {
    push_hex(out, mid2, i * 4)
    push_hex(out, mid2, i * 4 - 4)
    i = i - 1
  }
  out.write_string("-")
  // hi 的高 8 字节：按大端输出
  let mut shift = 56
  while shift >= 0 {
    let b = ((hi >> shift) & 0xFF).to_uint()
    push_hex(out, b, 4)
    push_hex(out, b, 0)
    shift = shift - 8
  }
  out.to_string()
}

///|
/// 把 `days`（自 1970-01-01）转换为公历 (y, m, d)。
/// 使用 Howard Hinnant 的 civil_from_days 算法。
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

///|
/// 按列读取 `nrows` 个值（ClickHouse bulk 序列化格式）。
///
/// `Nullable(T)` 列特殊处理：先读取整列 `nrows` 字节的 null mask，
/// 再逐行读取嵌套值（NULL 行也写入嵌套类型的默认值，需要读取并丢弃），
/// 因此不能按「逐行 mask + 值」的方式解码。
async fn[R : @io.Reader] read_column_values(
  reader : R,
  type_name : String,
  nrows : Int,
) -> Array[String] {
  if type_name.has_prefix("Nullable(") {
    let inner = type_name[9:type_name.length() - 1].to_string()
    let masks = reader.read_exactly(nrows)
    let values : Array[String] = Array::make(nrows, "")
    for r in 0..<nrows {
      if masks[r].to_uint() == 0 {
        values[r] = read_value(reader, inner)
      } else {
        values[r] = "" // NULL 值（HTTP 版同样以空字符串表示）
        ignore(read_value(reader, inner)) // NULL 行仍写入默认值，丢弃
      }
    }
    return values
  }
  let values : Array[String] = Array::make(nrows, "")
  for r in 0..<nrows {
    values[r] = read_value(reader, type_name)
  }
  values
}
