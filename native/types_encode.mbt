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
    "Float32" => write_float32(buf, parse_float_value(value).to_float())
    "Float64" => write_float64(buf, parse_float_value(value))
    "String" => write_string(buf, value)
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
    let inner = type_name[9:type_name.length() - 1].to_string()
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
      type_name[9:type_name.length() - 1].to_string(),
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
  let scale = parse_type_size(type_name, 12)
  let dot = value.find(".")
  let (main, frac) = match dot {
    Some(i) => (value[:i].to_string(), value[i + 1:].to_string())
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
    Some(i) => (value[:i].to_string(), value[i + 1:].to_string())
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
  let comma = type_name.find(",").or(type_name.length() - 1)
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
