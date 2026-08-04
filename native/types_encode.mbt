// ============ 编码（写） ============

///|
/// 把字符串值编码为该类型的二进制表示。
/// 基础版本支持 UInt/Int/Float/String/Date/DateTime；`Nullable(T)` 走列级
/// 两段式编码（见 `write_column_values`），不能单值编码。
fn write_value(buf : Buffer, type_name : String, value : String) -> Unit raise {
  if type_name.has_prefix("DateTime64(") {
    return write_datetime64(buf, type_name, value)
  }
  if type_name == "DateTime" || type_name.has_prefix("DateTime(") {
    return write_datetime(buf, value)
  }
  if type_name == "Date" {
    return write_date(buf, value)
  }
  if type_name.has_prefix("FixedString(") {
    return write_fixed_string(buf, type_name, value)
  }
  if type_name.has_prefix("Decimal(") {
    return write_decimal(buf, type_name, value)
  }
  if type_name.has_prefix("UUID") {
    return write_uuid_value(buf, value)
  }
  if type_name == "IPv4" {
    return write_ipv4(buf, value)
  }
  match type_name {
    "Enum8" => ()
    _ => ()
  }
  if type_name.has_prefix("Enum8(") {
    return write_enum(buf, type_name, value, 1)
  }
  if type_name.has_prefix("Enum16(") {
    return write_enum(buf, type_name, value, 2)
  }
  match type_name {
    "UInt8" => {
      let v = parse_uint_value(value, "UInt8")
      if v > 255 {
        raise @lib.DbError::connection_error("UInt8 out of range: \{value}")
      }
      buf.write_byte(v.to_byte())
    }
    "UInt16" => {
      let v = parse_uint_value(value, "UInt16")
      if v > 65535 {
        raise @lib.DbError::connection_error("UInt16 out of range: \{value}")
      }
      write_uint16(buf, v.to_uint16())
    }
    "UInt32" => {
      let v = parse_uint_value(value, "UInt32")
      write_uint32(buf, v)
    }
    "UInt64" => write_uint64(buf, parse_uint64_value(value))
    "Int8" => {
      let v = parse_int_value(value, "Int8")
      if v < -128 || v > 127 {
        raise @lib.DbError::connection_error("Int8 out of range: \{value}")
      }
      buf.write_byte(v.to_byte())
    }
    "Int16" => {
      let v = parse_int_value(value, "Int16")
      if v < -32768 || v > 32767 {
        raise @lib.DbError::connection_error("Int16 out of range: \{value}")
      }
      write_uint16(buf, v.reinterpret_as_uint().to_uint16())
    }
    "Int32" => write_int32(buf, parse_int_value(value, "Int32"))
    "Int64" => write_int64(buf, parse_int64_value(value))
    "Float32" =>
      write_float32(buf, Float::from_double(parse_float_value(value)))
    "Float64" => write_float64(buf, parse_float_value(value))
    "String" => write_string(buf, value)
    "Bool" =>
      buf.write_byte(if value == "true" || value == "1" { 1 } else { 0 })
    _ if type_name.has_prefix("Interval") =>
      write_int64(buf, parse_int64_value(value))
    _ =>
      raise @lib.DbError::connection_error(
        "unsupported type for insert: \{type_name}",
      )
  }
}

///|
/// 按列编码 `values` 为二进制数据（Nullable 使用两段式 bulk 格式）。
fn write_column_values(
  buf : Buffer,
  type_name : String,
  values : Array[String],
) -> Unit raise {
  if type_name.has_prefix("Nullable(") {
    let inner = type_name[9:type_name.length() - 1].to_owned()
    // 阶段 1：整列 null mask（1 = NULL）
    for v in values {
      buf.write_byte(if v == "" { 1 } else { 0 })
    }
    // 阶段 2：整列嵌套值（NULL 行写嵌套类型默认值）
    for v in values {
      if v == "" {
        write_default_value(buf, inner)
      } else {
        write_value(buf, inner, v)
      }
    }
    return
  }
  for v in values {
    write_value(buf, type_name, v)
  }
}

///|
/// 写嵌套类型的默认值（NULL 行占位）。
fn write_default_value(buf : Buffer, type_name : String) -> Unit raise {
  if type_name.has_prefix("Nullable(") {
    return write_default_value(
      buf,
      type_name[9:type_name.length() - 1].to_owned(),
    )
  }
  if type_name.has_prefix("FixedString(") {
    let n = parse_type_size(type_name, 12)
    for _ in 0..<n {
      buf.write_byte(0)
    }
    return
  }
  if type_name.has_prefix("Array(") {
    write_varuint(buf, 0) // 空数组
    return
  }
  if type_name == "String" || type_name.has_prefix("LowCardinality(") {
    write_string(buf, "")
    return
  }
  if type_name == "UInt8" || type_name == "Int8" {
    buf.write_byte(0)
    return
  }
  if type_name == "UInt16" || type_name == "Int16" || type_name == "Date" {
    write_uint16(buf, 0)
    return
  }
  if type_name == "UInt32" ||
    type_name == "Int32" ||
    type_name == "Float32" ||
    type_name == "DateTime" ||
    type_name.has_prefix("DateTime64(") {
    write_uint32(buf, 0)
    return
  }
  if type_name == "UInt64" || type_name == "Int64" || type_name == "Float64" {
    write_uint64(buf, 0)
    return
  }
  if type_name.has_prefix("Decimal(") {
    let prec = decimal_precision(type_name)
    if prec <= 9 {
      write_uint32(buf, 0)
    } else {
      write_uint64(buf, 0)
    }
    return
  }
  raise @lib.DbError::connection_error(
    "unsupported type for insert default: \{type_name}",
  )
}

///|
/// 解析无符号整数（错误时抛 ConnectionError）。
fn parse_uint_value(value : String, type_name : String) -> UInt raise {
  @string.parse_uint(value) catch {
    _ =>
      raise @lib.DbError::connection_error(
        "invalid \{type_name} value: \{value}",
      )
  }
}

///|
/// 解析有符号 32 位整数。
fn parse_int_value(value : String, type_name : String) -> Int raise {
  @string.parse_int(value) catch {
    _ =>
      raise @lib.DbError::connection_error(
        "invalid \{type_name} value: \{value}",
      )
  }
}

///|
/// 解析 64 位有符号整数。
fn parse_int64_value(value : String) -> Int64 raise {
  @string.parse_int64(value) catch {
    _ => raise @lib.DbError::connection_error("invalid Int64 value: \{value}")
  }
}

///|
/// 解析 64 位无符号整数。
fn parse_uint64_value(value : String) -> UInt64 raise {
  @string.parse_uint64(value) catch {
    _ => raise @lib.DbError::connection_error("invalid UInt64 value: \{value}")
  }
}

///|
/// 解析浮点数。
fn parse_float_value(value : String) -> Double raise {
  @string.parse_double(value) catch {
    _ => raise @lib.DbError::connection_error("invalid Float value: \{value}")
  }
}

///|
/// 解析 Date "YYYY-MM-DD" → UInt16 天数（自 1970-01-01）。
fn write_date(buf : Buffer, value : String) -> Unit raise {
  let (y, m, d) = parse_date_parts(value)
  let days = days_from_civil(y, m, d)
  if days < 0 || days > 65535 {
    raise @lib.DbError::connection_error("Date out of range: \{value}")
  }
  write_uint16(buf, days.to_int().reinterpret_as_uint().to_uint16())
}

///|
/// 解析 DateTime "YYYY-MM-DD HH:MM:SS" → UInt32 秒。
fn write_datetime(buf : Buffer, value : String) -> Unit raise {
  let (y, m, d, hh, mm, ss) = parse_datetime_parts(value)
  let days = days_from_civil(y, m, d)
  let seconds = days * 86400L +
    hh.to_int64() * 3600L +
    mm.to_int64() * 60L +
    ss.to_int64()
  if seconds < 0L || seconds > 4294967295L {
    raise @lib.DbError::connection_error("DateTime out of range: \{value}")
  }
  write_uint32(buf, seconds.to_int().reinterpret_as_uint())
}

///|
/// 解析 DateTime64 "YYYY-MM-DD HH:MM:SS[.ffffff]" → Int64（按精度缩放）。
fn write_datetime64(
  buf : Buffer,
  type_name : String,
  value : String,
) -> Unit raise {
  let scale = parse_type_param(type_name, "(")
  let dot = value.find(".")
  let (main, frac) = match dot {
    Some(i) => (value[:i].to_owned(), value[i + 1:].to_owned())
    None => (value, "")
  }
  let (y, m, d, hh, mm, ss) = parse_datetime_parts(main)
  let days = days_from_civil(y, m, d)
  let seconds = days * 86400L +
    hh.to_int64() * 3600L +
    mm.to_int64() * 60L +
    ss.to_int64()
  let mut pow : Int64 = 1L
  for _ in 0..<scale {
    pow = pow * 10
  }
  // 小数部分按 scale 缩放
  let mut frac_num : Int64 = 0
  for ch in frac {
    let c = ch.to_int() - '0'.to_int()
    if c >= 0 && c <= 9 {
      frac_num = frac_num * 10 + c.to_int64()
    } else {
      break
    }
  }
  let mut frac_pow : Int64 = 1
  for _ in 0..<frac.length() {
    frac_pow = frac_pow * 10
  }
  while frac_pow < pow {
    frac_num = frac_num * 10
    frac_pow = frac_pow * 10
  }
  write_int64(buf, seconds * pow + frac_num)
}

///|
/// 解析 "YYYY-MM-DD" 为 (y, m, d)。
fn parse_date_parts(value : String) -> (Int, Int, Int) raise {
  let parts = value.split("-")
  let arr = parts.to_array()
  if arr.length() != 3 {
    raise @lib.DbError::connection_error("invalid Date: \{value}")
  }
  let y = parse_int_strict(arr[0], "year")
  let m = parse_int_strict(arr[1], "month")
  let d = parse_int_strict(arr[2], "day")
  if m < 1 || m > 12 || d < 1 || d > 31 {
    raise @lib.DbError::connection_error("invalid Date: \{value}")
  }
  (y, m, d)
}

///|
/// 解析 "YYYY-MM-DD HH:MM:SS" 为 (y, m, d, hh, mm, ss)。
fn parse_datetime_parts(value : String) -> (Int, Int, Int, Int, Int, Int) raise {
  let sp = value.find(" ")
  let (date_s, time_s) = match sp {
    Some(i) => (value[:i].to_owned(), value[i + 1:].to_owned())
    None => (value, "00:00:00")
  }
  let (y, m, d) = parse_date_parts(date_s)
  let tparts = time_s.split(":").to_array()
  if tparts.length() != 3 {
    raise @lib.DbError::connection_error("invalid DateTime: \{value}")
  }
  let hh = parse_int_strict(tparts[0], "hour")
  let mm = parse_int_strict(tparts[1], "minute")
  let ss = parse_int_strict(tparts[2], "second")
  if hh < 0 || hh > 23 || mm < 0 || mm > 59 || ss < 0 || ss > 59 {
    raise @lib.DbError::connection_error("invalid DateTime: \{value}")
  }
  (y, m, d, hh, mm, ss)
}

///|
/// 严格解析整数（不抛底层异常，转为 ConnectionError）。
fn parse_int_strict(s : StringView, field : String) -> Int raise {
  @string.parse_int(s) catch {
    _ => raise @lib.DbError::connection_error("invalid \{field}: \{s}")
  }
}

///|
/// 提取类型名中的数值参数（如 FixedString(8) → 8）。
fn parse_type_size(type_name : String, prefix_len : Int) -> Int raise {
  let inner = type_name[prefix_len:type_name.length() - 1].trim()
  parse_int_strict(inner, "size")
}

///|
/// 提取 Decimal 精度。
fn decimal_precision(type_name : String) -> Int raise {
  let comma = type_name.find(",").unwrap_or(type_name.length() - 1)
  let prec_s = type_name[10:comma].trim()
  parse_int_strict(prec_s, "precision")
}

///|
/// 公历 → 自 1970-01-01 的天数（Howard Hinnant 逆算法）。
fn days_from_civil(y : Int, m : Int, d : Int) -> Int64 {
  let y = if m <= 2 { y - 1 } else { y }
  let era = (if y >= 0 { y } else { y - 399 }) / 400
  let yoe = (y - era * 400).to_int64() // [0, 399]
  let mp = (m + 9) % 12 // [0, 11]
  let doy = (153 * mp + 2) / 5 + d - 1 // [0, 365]
  let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy.to_int64()
  era.to_int64() * 146097 + doe - 719468
}

///|
/// 写 FixedString(N)：不足 N 字节补 \x00。
fn write_fixed_string(
  buf : Buffer,
  type_name : String,
  value : String,
) -> Unit raise {
  let n = parse_type_size(type_name, 12)
  let bytes = @utf8.encode(value)
  if bytes.length() > n {
    raise @lib.DbError::connection_error("FixedString value too long: \{value}")
  }
  buf.write_bytes(bytes)
  for _ in bytes.length()..<n {
    buf.write_byte(0)
  }
}

///|
/// Decimal 写入：解析 `"123.456"`（按 scale 缩放为整数）→ 定长小端。
fn write_decimal(
  buf : Buffer,
  type_name : String,
  value : String,
) -> Unit raise {
  let open = type_name.find("(").unwrap_or(0)
  let comma = type_name.find(",").unwrap_or(type_name.length() - 1)
  let prec = parse_int_inner(type_name[open + 1:comma].trim().to_owned())
  let scale = parse_int_inner(
    type_name[comma + 1:type_name.length() - 1].trim().to_owned(),
  )
  let big = parse_decimal_string(value, scale)
  if prec <= 9 {
    write_int32(buf, big.to_int())
  } else if prec <= 18 {
    write_int64(buf, big.to_int64())
  } else if prec <= 38 {
    write_big_le(buf, big, 16)
  } else {
    write_big_le(buf, big, 32)
  }
}

///|
/// 解析十进制字符串为缩放后的 BigInt。
fn parse_decimal_string(value : String, scale : Int) -> @bigint.BigInt {
  let neg = value.has_prefix("-")
  let s = if neg { value[1:].to_owned() } else { value }
  let (int_s, frac_s) = match s.find(".") {
    Some(i) => (s[:i].to_owned(), s[i + 1:].to_owned())
    None => (s, "")
  }
  let mut frac = frac_s
  while frac.length() < scale {
    frac = frac + "0"
  }
  if frac.length() > scale {
    frac = frac[:scale].to_owned()
  }
  let digits = int_s + frac
  let big = @bigint.BigInt::from_string(digits)
  if neg {
    -big
  } else {
    big
  }
}

///|
/// 写 BigInt 的小端字节（补码，固定长度）。
fn write_big_le(buf : Buffer, big : @bigint.BigInt, nbytes : Int) -> Unit {
  let zero = @bigint.BigInt::from_int(0)
  let modulus = @bigint.BigInt::from_int(1) << (nbytes * 8)
  let v = if big < zero { modulus + big } else { big }
  let be = v.to_octets(length=nbytes)
  let mut i = nbytes - 1
  while i >= 0 {
    buf.write_byte(be[i])
    i = i - 1
  }
}

///|
/// UUID 写入：解析 `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` → 16 字节
/// （先高 64 位小端、再低 64 位小端）。
fn write_uuid_value(buf : Buffer, value : String) -> Unit raise {
  let parts = value.split("-").to_array()
  if parts.length() != 5 {
    raise @lib.DbError::connection_error("invalid UUID: \{value}")
  }
  let hi_s = parts[0].to_owned() + parts[1].to_owned() + parts[2].to_owned()
  let lo_s = parts[3].to_owned() + parts[4].to_owned()
  let hi = parse_hex64(hi_s)
  let lo = parse_hex64(lo_s)
  // 高 64 位小端
  write_uint64(buf, hi)
  // 低 64 位小端
  write_uint64(buf, lo)
}

///|
/// 解析 16 位 hex 字符串为 UInt64。
fn parse_hex64(s : String) -> UInt64 raise {
  if s.length() != 16 {
    raise @lib.DbError::connection_error("invalid UUID hex: \{s}")
  }
  let mut v : UInt64 = 0
  for ch in s {
    let c = ch.to_int()
    let d = if c >= '0'.to_int() && c <= '9'.to_int() {
      c - '0'.to_int()
    } else if c >= 'a'.to_int() && c <= 'f'.to_int() {
      c - 'a'.to_int() + 10
    } else if c >= 'A'.to_int() && c <= 'F'.to_int() {
      c - 'A'.to_int() + 10
    } else {
      raise @lib.DbError::connection_error("invalid UUID hex: \{s}")
    }
    v = (v << 4) | d.to_uint64()
  }
  v
}

///|
/// IPv4 写入：`a.b.c.d` → UInt32 小端。
fn write_ipv4(buf : Buffer, value : String) -> Unit raise {
  let parts = value.split(".").to_array()
  if parts.length() != 4 {
    raise @lib.DbError::connection_error("invalid IPv4: \{value}")
  }
  let bytes : Array[Byte] = Array::make(4, 0)
  for i in 0..<4 {
    let n = parse_int_strict(parts[i].trim(), "IPv4 octet")
    if n < 0 || n > 255 {
      raise @lib.DbError::connection_error("invalid IPv4 octet: \{value}")
    }
    bytes[i] = n.to_byte()
  }
  // UInt32 小端：a.b.c.d → 0xddccbbaa 的小端字节 = aa bb cc dd
  buf.write_byte(bytes[3])
  buf.write_byte(bytes[2])
  buf.write_byte(bytes[1])
  buf.write_byte(bytes[0])
}

///|
/// Enum 写入：名称或数字 → Int8/Int16 值。
fn write_enum(
  buf : Buffer,
  type_name : String,
  value : String,
  byte_width : Int,
) -> Unit raise {
  let raw = enum_name_to_value(type_name, value)
  if raw == 0 && value != "0" && value != "0.0" {
    // 不是已知名称，尝试解析为数字
    if byte_width == 1 {
      let n = parse_int_value(value, "Enum8")
      if n < -128 || n > 127 {
        raise @lib.DbError::connection_error("Enum8 out of range: \{value}")
      }
      buf.write_byte(n.to_byte())
      return
    }
    let n = parse_int_value(value, "Enum16")
    if n < -32768 || n > 32767 {
      raise @lib.DbError::connection_error("Enum16 out of range: \{value}")
    }
    write_uint16(buf, n.reinterpret_as_uint().to_uint16())
    return
  }
  if byte_width == 1 {
    buf.write_byte(raw.to_byte())
  } else {
    write_uint16(buf, raw.reinterpret_as_uint().to_uint16())
  }
}

///|
/// 查 Enum 映射：名称 → 数值。
fn enum_name_to_value(type_name : String, name : String) -> Int {
  let map = parse_enum_map(type_name)
  for entry in map {
    if entry.1 == name {
      return entry.0
    }
  }
  0
}
