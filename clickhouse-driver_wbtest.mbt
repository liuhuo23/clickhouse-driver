// Whitebox tests for internal helpers.
// These exercise the pure functions that do the heavy lifting for value
// parsing, formatting, and type-system mapping.

///|
test "civil_from_days: epoch" {
  let (y, m, d) = civil_from_days(0)
  assert_eq(y, 1970)
  assert_eq(m, 1)
  assert_eq(d, 1)
}

///|
test "civil_from_days: 2000-01-01" {
  // 2000-01-01 is day 10957 since 1970-01-01
  let (y, m, d) = civil_from_days(10957)
  assert_eq(y, 2000)
  assert_eq(m, 1)
  assert_eq(d, 1)
}

///|
test "civil_from_days: 2024-02-29 (leap day)" {
  // 2024-01-01 = day 19723; Feb has 29 days in 2024 (leap); so
  // 2024-02-29 = 19723 + 31 + 28 = 19782 (counting Feb 1..29 as 28 days past Jan).
  let (y, m, d) = civil_from_days(19782)
  assert_eq(y, 2024)
  assert_eq(m, 2)
  assert_eq(d, 29)
}

///|
test "civil_from_days: pre-epoch" {
  // 1969-12-31 is day -1
  let (y, m, d) = civil_from_days(-1)
  assert_eq(y, 1969)
  assert_eq(m, 12)
  assert_eq(d, 31)
}

///|
test "format_date" {
  assert_eq(format_date(0), "1970-01-01")
  assert_eq(format_date(19737), "2024-01-15")
}

///|
test "format_datetime" {
  assert_eq(format_datetime(0), "1970-01-01 00:00:00")
  assert_eq(format_datetime(86400), "1970-01-02 00:00:00")
  assert_eq(format_datetime(60), "1970-01-01 00:01:00")
  assert_eq(format_datetime(3600), "1970-01-01 01:00:00")
}

///|
test "format_decimal_str: scale 0" {
  assert_eq(format_decimal_str(12345L, 0), "12345")
  assert_eq(format_decimal_str(0L, 0), "0")
}

///|
test "format_decimal_str: positive with scale" {
  assert_eq(format_decimal_str(12345L, 2), "123.45")
  assert_eq(format_decimal_str(100L, 2), "1.00")
  assert_eq(format_decimal_str(1L, 2), "0.01")
}

///|
test "format_decimal_str: negative with scale" {
  assert_eq(format_decimal_str(-12345L, 2), "-123.45")
  assert_eq(format_decimal_str(-100L, 2), "-1.00")
}

///|
test "format_decimal_str: scale larger than digits" {
  assert_eq(format_decimal_str(5L, 3), "0.005")
  assert_eq(format_decimal_str(5L, 5), "0.00005")
}

///|
test "hex_nibble: 0..15" {
  assert_eq(hex_nibble(0), "0")
  assert_eq(hex_nibble(1), "1")
  assert_eq(hex_nibble(9), "9")
  assert_eq(hex_nibble(10), "a")
  assert_eq(hex_nibble(11), "b")
  assert_eq(hex_nibble(15), "f")
}

///|
test "int_to_hex_str: zero" {
  assert_eq(int_to_hex_str(0, 4), "0000")
  assert_eq(int_to_hex_str(0, 8), "00000000")
}

///|
test "int_to_hex_str: full width" {
  assert_eq(int_to_hex_str(0xff, 4), "00ff")
  assert_eq(int_to_hex_str(0x1234, 4), "1234")
  assert_eq(int_to_hex_str(0xabcd, 4), "abcd")
}

///|
test "pad2" {
  assert_eq(pad2(0), "00")
  assert_eq(pad2(5), "05")
  assert_eq(pad2(42), "42")
  assert_eq(pad2(123), "123")
}

///|
test "pad4" {
  assert_eq(pad4(0), "0000")
  assert_eq(pad4(5), "0005")
  assert_eq(pad4(2024), "2024")
  assert_eq(pad4(12345), "12345")
}

///|
test "str_repeat" {
  assert_eq(str_repeat("ab", 3), "ababab")
  assert_eq(str_repeat("x", 0), "")
  assert_eq(str_repeat("", 5), "")
}

///|
test "substr: basic range" {
  assert_eq(substr("Hello World", 0, 5), "Hello")
  assert_eq(substr("Hello World", 6, 11), "World")
}

///|
test "substr: full string" {
  assert_eq(substr("Hello", 0, 5), "Hello")
}

///|
test "substr: empty range" {
  assert_eq(substr("Hello", 2, 2), "")
}

///|
test "substr: prefix" {
  assert_eq(substr("Hello", 0, 3), "Hel")
}

///|
test "parse_int_or: valid positive" {
  assert_eq(parse_int_or("42", -1), 42)
  assert_eq(parse_int_or("0", -1), 0)
  assert_eq(parse_int_or("100", -1), 100)
}

///|
test "parse_int_or: valid negative" {
  assert_eq(parse_int_or("-1", 0), -1)
  assert_eq(parse_int_or("-100", 0), -100)
}

///|
test "parse_int_or: with sign" {
  assert_eq(parse_int_or("+42", 0), 42)
}

///|
test "parse_int_or: with whitespace" {
  assert_eq(parse_int_or("  42  ", 0), 42)
}

///|
test "parse_int_or: invalid returns fallback" {
  assert_eq(parse_int_or("abc", -1), -1)
  assert_eq(parse_int_or("12abc", -1), -1)
  assert_eq(parse_int_or("", 99), 99)
  assert_eq(parse_int_or("3.14", 0), 0)
}

///|
test "split_type_list: three simple" {
  let parts = split_type_list("String, Int32, DateTime")
  assert_eq(parts.length(), 3)
  assert_eq(parts[0], "String")
  assert_eq(parts[1], "Int32")
  assert_eq(parts[2], "DateTime")
}

///|
test "split_type_list: with nested parens" {
  let parts = split_type_list("String, Nullable(Int32), Array(Float64)")
  assert_eq(parts.length(), 3)
  assert_eq(parts[0], "String")
  assert_eq(parts[1], "Nullable(Int32)")
  assert_eq(parts[2], "Array(Float64)")
}

///|
test "split_type_list: with Tuple in middle" {
  let parts = split_type_list("Int32, Tuple(String, Int64), Bool")
  assert_eq(parts.length(), 3)
  assert_eq(parts[0], "Int32")
  assert_eq(parts[1], "Tuple(String, Int64)")
  assert_eq(parts[2], "Bool")
}

///|
test "extract_parens: Nullable" {
  assert_eq(extract_parens("Nullable(Int32)", 8), "Int32")
}

///|
test "extract_parens: Array" {
  assert_eq(extract_parens("Array(String)", 5), "String")
}

///|
test "extract_parens: DateTime64" {
  assert_eq(extract_parens("DateTime64(3, 'UTC')", 10), "3, 'UTC'")
}

///|
test "extract_parens: FixedString" {
  assert_eq(extract_parens("FixedString(16)", 11), "16")
}

///|
test "parse_type: simple scalars" {
  assert_eq(parse_type("UInt8"), CHType::UInt8)
  assert_eq(parse_type("UInt32"), CHType::UInt32)
  assert_eq(parse_type("Int64"), CHType::Int64)
  assert_eq(parse_type("Float64"), CHType::Float64)
  assert_eq(parse_type("Bool"), CHType::Bool)
  assert_eq(parse_type("String"), CHType::String)
  assert_eq(parse_type("UUID"), CHType::UUID)
  assert_eq(parse_type("DateTime"), CHType::DateTime)
}

///|
test "parse_type: with whitespace" {
  assert_eq(parse_type("  Int32  "), CHType::Int32)
}

///|
test "parse_type: Nullable" {
  assert_eq(parse_type("Nullable(Int32)"), CHType::Nullable(CHType::Int32))
  assert_eq(parse_type("Nullable(String)"), CHType::Nullable(CHType::String))
}

///|
test "parse_type: Array" {
  assert_eq(parse_type("Array(Int32)"), CHType::Array(CHType::Int32))
  assert_eq(parse_type("Array(Nullable(String))"), CHType::Array(
    CHType::Nullable(CHType::String),
  ))
}

///|
test "parse_type: Tuple" {
  assert_eq(parse_type("Tuple(String, Int32)"), CHType::Tuple([
    CHType::String, CHType::Int32,
  ]))
  assert_eq(parse_type("Tuple()"), CHType::Tuple([]))
}

///|
test "parse_type: Map" {
  assert_eq(parse_type("Map(String, Int32)"), CHType::Map(
    CHType::String,
    CHType::Int32,
  ))
}

///|
test "parse_type: LowCardinality" {
  assert_eq(parse_type("LowCardinality(String)"), CHType::LowCardinality(
    CHType::String,
  ))
  assert_eq(parse_type("LowCardinality(Nullable(Int32))"), CHType::LowCardinality(
    CHType::Nullable(CHType::Int32),
  ))
}

///|
test "parse_type: Decimal with scale" {
  assert_eq(parse_type("Decimal(18, 2)"), CHType::Decimal(18, 2))
  assert_eq(parse_type("Decimal32(4)"), CHType::Decimal32(4))
  assert_eq(parse_type("Decimal64(6)"), CHType::Decimal64(6))
}

///|
test "parse_type: DateTime64 with scale" {
  assert_eq(parse_type("DateTime64(3)"), CHType::DateTime64(3))
  assert_eq(parse_type("DateTime64(9, 'UTC')"), CHType::DateTime64(9))
}

///|
test "parse_type: FixedString" {
  assert_eq(parse_type("FixedString(16)"), CHType::FixedString(16))
  assert_eq(parse_type("FixedString(1)"), CHType::FixedString(1))
}

///|
test "parse_type: unknown falls back" {
  assert_eq(parse_type("SomeUnknownType"), CHType::Unknown)
  assert_eq(parse_type(""), CHType::Unknown)
}

///|
test "parse_type: deeply nested" {
  // Array(Nullable(LowCardinality(String)))
  let t = parse_type("Array(Nullable(LowCardinality(String)))")
  assert_eq(t, CHType::Array(CHType::Nullable(CHType::LowCardinality(
    CHType::String,
  ))))
}

///|
test "to_map: empty result" {
  let result : ResultSet = { columns: [], rows: [] }
  let maps = result.to_map()
  assert_eq(maps.length(), 0)
}

///|
test "to_map: single row" {
  let result : ResultSet = {
    columns: [
      { name: "id", type_: "Int32" },
      { name: "name", type_: "String" },
    ],
    rows: [{ values: ["1", "alice"] }],
  }
  let maps = result.to_map()
  assert_eq(maps.length(), 1)
  assert_eq(maps[0].get("id"), Some("1"))
  assert_eq(maps[0].get("name"), Some("alice"))
}

///|
test "to_map: multiple rows preserve order" {
  let result : ResultSet = {
    columns: [{ name: "n", type_: "Int32" }],
    rows: [
      { values: ["1"] },
      { values: ["2"] },
      { values: ["3"] },
    ],
  }
  let maps = result.to_map()
  assert_eq(maps.length(), 3)
  assert_eq(maps[0].get("n"), Some("1"))
  assert_eq(maps[1].get("n"), Some("2"))
  assert_eq(maps[2].get("n"), Some("3"))
}

///|
test "to_map: NULL values preserved as string" {
  let result : ResultSet = {
    columns: [{ name: "x", type_: "Nullable(Int32)" }],
    rows: [
      { values: ["NULL"] },
      { values: ["42"] },
    ],
  }
  let maps = result.to_map()
  assert_eq(maps.length(), 2)
  assert_eq(maps[0].get("x"), Some("NULL"))
  assert_eq(maps[1].get("x"), Some("42"))
}
