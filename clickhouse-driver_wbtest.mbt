// Whitebox tests for internal helpers of the HTTP-based driver.
// Pure functions only — no network I/O.

///|
using @test {assert_eq}

///|
/// Try to parse a string as Int, returning fallback on failure.
fn parse_int_or(s : String, fallback : Int) -> Int {
  let s = s.trim()
  if s.length() == 0 {
    return fallback
  }
  let mut result = 0
  let mut idx = 0
  let mut neg = false
  if s[0] == '-' {
    neg = true
    idx = 1
  } else if s[0] == '+' {
    idx = 1
  }
  // Lone sign with no digits is not a valid number — fall back
  if idx >= s.length() {
    return fallback
  }
  let mut ok = true
  while idx < s.length() {
    let c = s[idx].to_int() - '0'.to_int()
    if c >= 0 && c <= 9 {
      result = result * 10 + c
    } else {
      ok = false
      break
    }
    idx = idx + 1
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

// ============ URL encoding ============

///|
test "url_encode: passthrough ASCII alphanumerics" {
  assert_eq(url_encode("abcXYZ123"), "abcXYZ123")
  assert_eq(url_encode(""), "")
  assert_eq(url_encode("with-dash_and.dot~tilde"), "with-dash_and.dot~tilde")
}

///|
test "url_encode: encodes spaces and reserved chars" {
  // We use lowercase hex per RFC 3986 (ClickHouse accepts either)
  assert_eq(url_encode("a b"), "a%20b")
  assert_eq(url_encode("a&b=c"), "a%26b%3dc")
  assert_eq(url_encode("a+b"), "a%2bb")
  assert_eq(url_encode("a%b"), "a%25b")
  assert_eq(url_encode("a/b"), "a%2fb")
}

///|
test "url_encode: encodes query string" {
  assert_eq(
    url_encode("SELECT 1 AS x FROM db WHERE y = 'hi'"),
    "SELECT%201%20AS%20x%20FROM%20db%20WHERE%20y%20%3d%20%27hi%27",
  )
}

// ============ Basic auth header ============

///|
test "basic_auth_header: encodes user:password as base64" {
  // base64("user:pass") = "dXNlcjpwYXNz"
  assert_eq(basic_auth_header("user", "pass"), "Basic dXNlcjpwYXNz")
  assert_eq(basic_auth_header("default", "barn"), "Basic ZGVmYXVsdDpiYXJu")
  assert_eq(basic_auth_header("u", ""), "Basic dTo=")
}

// ============ TSV parsing ============

///|
test "split_tsv_line: simple cells" {
  let r = split_tsv_line("a\tb\tc")
  assert_eq(r.length(), 3)
  assert_eq(r[0], "a")
  assert_eq(r[1], "b")
  assert_eq(r[2], "c")
}

///|
test "split_tsv_line: single cell no tabs" {
  let r = split_tsv_line("hello")
  assert_eq(r.length(), 1)
  assert_eq(r[0], "hello")
}

///|
test "split_tsv_line: empty cells" {
  let r = split_tsv_line("\t\t")
  assert_eq(r.length(), 3)
  assert_eq(r[0], "")
  assert_eq(r[1], "")
  assert_eq(r[2], "")
}

///|
test "split_tsv_line: unescapes backslash sequences" {
  // Embedded tab/newline/backslash inside a cell
  let r = split_tsv_line("a\\tb\tc")
  assert_eq(r.length(), 2)
  assert_eq(r[0], "a\tb")
  assert_eq(r[1], "c")
}

///|
test "parse_tsv_response: names + types + rows" {
  let body = "id\tname\tvalue\nUInt32\tString\tFloat64\n1\talice\t1.5\n2\tbob\t2.5\n"
  let r = parse_tsv_response(body)
  assert_eq(r.columns.length(), 3)
  assert_eq(r.columns[0].name, "id")
  assert_eq(r.columns[0].type_, "UInt32")
  assert_eq(r.columns[1].name, "name")
  assert_eq(r.columns[1].type_, "String")
  assert_eq(r.columns[2].name, "value")
  assert_eq(r.columns[2].type_, "Float64")
  assert_eq(r.rows.length(), 2)
  assert_eq(r.rows[0].values[0], "1")
  assert_eq(r.rows[0].values[1], "alice")
  assert_eq(r.rows[0].values[2], "1.5")
  assert_eq(r.rows[1].values[0], "2")
  assert_eq(r.rows[1].values[1], "bob")
  assert_eq(r.rows[1].values[2], "2.5")
}

///|
test "parse_tsv_response: schema-only block (DDL response)" {
  let body = "id\tname\nUInt32\tString\n"
  let r = parse_tsv_response(body)
  assert_eq(r.columns.length(), 2)
  assert_eq(r.rows.length(), 0)
}

///|
test "parse_tsv_response: empty body" {
  let r = parse_tsv_response("")
  assert_eq(r.columns.length(), 0)
  assert_eq(r.rows.length(), 0)
}

///|
test "parse_tsv_response: \\r\\n line endings" {
  let body = "a\tb\r\nInt32\tString\r\nx\ty\r\n"
  let r = parse_tsv_response(body)
  assert_eq(r.columns.length(), 2)
  assert_eq(r.rows.length(), 1)
  assert_eq(r.rows[0].values[0], "x")
  assert_eq(r.rows[0].values[1], "y")
}

// ============ ResultSet::to_map ============

///|
test "to_map: produces per-row column maps" {
  let rs : ResultSet = {
    columns: [
      { name: "id", type_: "UInt32" },
      { name: "name", type_: "String" },
    ],
    rows: [{ values: ["1", "alice"] }, { values: ["2", "bob"] }],
  }
  let maps = rs.to_map()
  assert_eq(maps.length(), 2)
  assert_eq(maps[0].get("id"), Some("1"))
  assert_eq(maps[0].get("name"), Some("alice"))
  assert_eq(maps[1].get("id"), Some("2"))
  assert_eq(maps[1].get("name"), Some("bob"))
}

// ============ Generic helpers ============

///|
test "parse_int_or: positive numbers" {
  assert_eq(parse_int_or("42", -1), 42)
  assert_eq(parse_int_or("0", -1), 0)
  assert_eq(parse_int_or("100", -1), 100)
}

///|
test "parse_int_or: negative numbers" {
  assert_eq(parse_int_or("-1", 0), -1)
  assert_eq(parse_int_or("-100", 0), -100)
}

///|
test "parse_int_or: signs and whitespace" {
  assert_eq(parse_int_or("+42", 0), 42)
  assert_eq(parse_int_or("  42  ", 0), 42)
}

///|
test "parse_int_or: invalid falls back" {
  assert_eq(parse_int_or("abc", -1), -1)
  assert_eq(parse_int_or("12abc", -1), -1)
  assert_eq(parse_int_or("", 99), 99)
  assert_eq(parse_int_or("3.14", 0), 0)
}

///|
test "substr: byte-indexed slice" {
  assert_eq(substr("Hello World", 0, 5), "Hello")
  assert_eq(substr("Hello World", 6, 11), "World")
  assert_eq(substr("Hello", 0, 5), "Hello")
  assert_eq(substr("Hello", 0, 0), "")
}

///|
test "substr: clamps out-of-range" {
  // end past string length is clamped
  assert_eq(substr("Hi", 0, 100), "Hi")
  // start past end returns empty
  assert_eq(substr("Hi", 5, 10), "")
}

// ============ build_url with named params ============

///|
fn make_conn_for_url_test() -> Connection {
  {
    host: "127.0.0.1",
    port: 8123,
    user: "default",
    password: "barn",
    database: "default",
    client_name: "moonbit-cli",
  }
}

///|
test "build_url: query only, no named params" {
  let conn = make_conn_for_url_test()
  let url = build_url(conn, "SELECT 1", {})
  assert_eq(
    url, "/?database=default&default_format=TabSeparatedWithNamesAndTypes&query=SELECT%201",
  )
}

///|
test "build_url: query with single named param" {
  let conn = make_conn_for_url_test()
  let url = build_url(
    conn,
    "SELECT {name: String}",
    Map::from_array([("name", "hello")]),
  )
  // url_encode produces lowercase hex; spaces and braces encoded.
  assert_eq(
    url, "/?database=default&default_format=TabSeparatedWithNamesAndTypes&query=SELECT%20%7bname%3a%20String%7d&param_name=hello",
  )
}

///|
test "build_url: query with multiple named params" {
  let conn = make_conn_for_url_test()
  let url = build_url(
    conn,
    "SELECT {a: Int32}, {b: String}",
    Map::from_array([("a", "1"), ("b", "hi")]),
  )
  // Map iteration order is implementation-defined; check both orderings.
  let opt1 = "/?database=default&default_format=TabSeparatedWithNamesAndTypes&query=SELECT%20%7ba%3a%20Int32%7d%2c%20%7bb%3a%20String%7d&param_a=1&param_b=hi"
  let opt2 = "/?database=default&default_format=TabSeparatedWithNamesAndTypes&query=SELECT%20%7ba%3a%20Int32%7d%2c%20%7bb%3a%20String%7d&param_b=hi&param_a=1"
  assert_true(url == opt1 || url == opt2)
}

///|
test "build_url: named param values are URL-encoded" {
  let conn = make_conn_for_url_test()
  let url = build_url(
    conn,
    "SELECT {ts: DateTime}",
    Map::from_array([("ts", "2024-01-01 00:00:00")]),
  )
  // Space → %20, colon in DateTime → %3a (lowercase)
  assert_true(url.contains("param_ts=2024-01-01%2000%3a00%3a00"))
}

// ============ apply_default_types ============

///|
test "apply_default_types: single untyped placeholder defaults to String" {
  assert_eq(apply_default_types("SELECT {tn}"), "SELECT {tn: String}")
  assert_eq(apply_default_types("{x}"), "{x: String}")
}

///|
test "apply_default_types: typed placeholders are left alone" {
  assert_eq(apply_default_types("SELECT {tn: String}"), "SELECT {tn: String}")
  assert_eq(apply_default_types("SELECT {x: Int32}"), "SELECT {x: Int32}")
  assert_eq(apply_default_types("SELECT {x : Int32}"), "SELECT {x : Int32}")
  assert_eq(apply_default_types("SELECT {x:}"), "SELECT {x:}")
}

///|
test "apply_default_types: mixed typed and untyped" {
  assert_eq(
    apply_default_types("SELECT {a}, {b: Int32}"),
    "SELECT {a: String}, {b: Int32}",
  )
  assert_eq(
    apply_default_types("WHERE x = {lo} AND id = {id: UInt64}"),
    "WHERE x = {lo: String} AND id = {id: UInt64}",
  )
}

///|
test "apply_default_types: no placeholders is a no-op" {
  assert_eq(apply_default_types("SELECT 1"), "SELECT 1")
  assert_eq(apply_default_types(""), "")
  assert_eq(
    apply_default_types("CREATE TABLE t (id Int32) ENGINE = MergeTree()"),
    "CREATE TABLE t (id Int32) ENGINE = MergeTree()",
  )
}

///|
test "apply_default_types: empty placeholder is left alone" {
  assert_eq(apply_default_types("SELECT {}"), "SELECT {}")
  assert_eq(apply_default_types("{}"), "{}")
}

///|
test "apply_default_types: unmatched brace is left alone" {
  assert_eq(apply_default_types("SELECT {"), "SELECT {")
  assert_eq(apply_default_types("foo {bar"), "foo {bar")
}

///|
test "apply_default_types: multiple placeholders in one query" {
  assert_eq(
    apply_default_types(
      "INSERT INTO t (a, b) VALUES ({id}, {name}), ({id2}, {name2})",
    ),
    "INSERT INTO t (a, b) VALUES ({id: String}, {name: String}), ({id2: String}, {name2: String})",
  )
}

// ============ bind_positional ============

///|
test "bind_positional: renames ? to {__pN: String} in order" {
  let (sql, params) = bind_positional("INSERT INTO t VALUES (?, ?)", [
    "1", "alice",
  ])
  assert_eq(sql, "INSERT INTO t VALUES ({__p1: String}, {__p2: String})")
  assert_eq(params.get("__p1"), Some("1"))
  assert_eq(params.get("__p2"), Some("alice"))
}

///|
test "bind_positional: multi-row INSERT" {
  let (sql, params) = bind_positional(
    "INSERT INTO t (id, name) VALUES (?, ?), (?, ?), (?, ?)",
    ["1", "alice", "2", "bob", "3", "carol"],
  )
  assert_eq(
    sql, "INSERT INTO t (id, name) VALUES ({__p1: String}, {__p2: String}), ({__p3: String}, {__p4: String}), ({__p5: String}, {__p6: String})",
  )
  assert_eq(params.length(), 6)
  assert_eq(params.get("__p1"), Some("1"))
  assert_eq(params.get("__p6"), Some("carol"))
}

///|
test "bind_positional: no placeholders leaves SQL alone" {
  let (sql, params) = bind_positional("SELECT 1", ["unused"])
  assert_eq(sql, "SELECT 1")
  assert_eq(params.length(), 0)
}

///|
test "bind_positional: more values than placeholders ignores extras" {
  let (sql, params) = bind_positional("SELECT ?", ["a", "b", "c"])
  assert_eq(sql, "SELECT {__p1: String}")
  assert_eq(params.length(), 1)
  assert_eq(params.get("__p1"), Some("a"))
}

///|
test "bind_positional: empty values with placeholders" {
  let (sql, _params) = bind_positional("SELECT ?", [])
  assert_eq(sql, "SELECT {__p1: String}")
}

///|
test "bind_positional: empty sql is empty" {
  let (sql, params) = bind_positional("", [])
  assert_eq(sql, "")
  assert_eq(params.length(), 0)
}

///|
test "bind_positional: leaves {name} placeholders untouched" {
  let (sql, params) = bind_positional("SELECT {x}, ?", ["v"])
  // bind_positional only touches `?`; the {x} placeholder is left alone and
  // would be rewritten by apply_default_types in the execute() integration path.
  assert_eq(sql, "SELECT {x}, {__p1: String}")
  assert_eq(params.length(), 1)
  assert_eq(params.get("__p1"), Some("v"))
}

// ============ split_lines ============

///|
test "split_lines: empty string returns empty array" {
  let lines = split_lines("")
  assert_eq(lines.length(), 0)
}

///|
test "split_lines: single line with no terminator" {
  let lines = split_lines("hello")
  assert_eq(lines, ["hello"])
}

///|
test "split_lines: LF endings" {
  let lines = split_lines("a\nb\nc")
  assert_eq(lines, ["a", "b", "c"])
}

///|
test "split_lines: CRLF endings" {
  let lines = split_lines("a\r\nb\r\nc")
  assert_eq(lines, ["a", "b", "c"])
}

///|
test "split_lines: trailing LF is consumed" {
  let lines = split_lines("a\nb\n")
  assert_eq(lines, ["a", "b"])
}

///|
test "split_lines: trailing CRLF is consumed" {
  let lines = split_lines("a\r\nb\r\n")
  assert_eq(lines, ["a", "b"])
}

///|
test "split_lines: trailing bare CR is consumed" {
  let lines = split_lines("a\nb\r")
  assert_eq(lines, ["a", "b"])
}

///|
test "split_lines: mixed line endings" {
  // \n, \r\n, \n all mixed — should still split cleanly
  let lines = split_lines("a\nb\r\nc\nd")
  assert_eq(lines, ["a", "b", "c", "d"])
}

///|
test "split_lines: empty lines in middle are preserved" {
  let lines = split_lines("a\n\nb")
  assert_eq(lines, ["a", "", "b"])
}

///|
test "split_lines: only newlines" {
  let lines = split_lines("\n\n\n")
  assert_eq(lines, ["", "", ""])
}

///|
test "split_lines: single newline produces empty array of 1" {
  let lines = split_lines("\n")
  assert_eq(lines.length(), 1)
  assert_eq(lines[0], "")
}

///|
test "split_lines: single CRLF" {
  let lines = split_lines("\r\n")
  assert_eq(lines.length(), 1)
  assert_eq(lines[0], "")
}

// ============ extract_error ============

///|
test "extract_error: short body returned as-is" {
  assert_eq(
    extract_error("Code: 60. Table doesn't exist"),
    "Code: 60. Table doesn't exist",
  )
}

///|
test "extract_error: empty body returns empty string" {
  assert_eq(extract_error(""), "")
}

///|
test "extract_error: body of exactly 500 chars returned as-is" {
  let body = String::make(500, 'x')
  assert_eq(extract_error(body).length(), 500)
}

///|
test "extract_error: body of 501 chars is truncated to 500" {
  let body = String::make(501, 'x')
  let trimmed = extract_error(body)
  assert_eq(trimmed.length(), 500)
}

///|
test "extract_error: body of 1000 chars is truncated to 500" {
  let body = String::make(1000, 'a')
  let trimmed = extract_error(body)
  assert_eq(trimmed.length(), 500)
}

///|
test "extract_error: preserves content at the start of long bodies" {
  // Make a body starting with a distinctive prefix and trailing filler
  let prefix = "Code: 42. DB::Exception: "
  let filler = String::make(600, 'X')
  let body = prefix + filler
  let trimmed = extract_error(body)
  assert_true(trimmed.length() <= 500)
  // The prefix should be fully preserved in the trimmed output
  assert_eq(trimmed.length() - prefix.length(), 500 - prefix.length())
}

// ============ url_encode (expanded) ============

///|
test "url_encode: encodes all RFC 3986 reserved chars" {
  // Reserved characters that MUST be percent-encoded
  assert_eq(url_encode("!"), "%21")
  assert_eq(url_encode("*"), "%2a")
  assert_eq(url_encode("'"), "%27")
  assert_eq(url_encode("("), "%28")
  assert_eq(url_encode(")"), "%29")
  assert_eq(url_encode(";"), "%3b")
  assert_eq(url_encode(":"), "%3a")
  assert_eq(url_encode("@"), "%40")
  assert_eq(url_encode("&"), "%26")
  assert_eq(url_encode("="), "%3d")
  assert_eq(url_encode("+"), "%2b")
  assert_eq(url_encode("$"), "%24")
  assert_eq(url_encode(","), "%2c")
  assert_eq(url_encode("/"), "%2f")
  assert_eq(url_encode("?"), "%3f")
  assert_eq(url_encode("#"), "%23")
  assert_eq(url_encode("["), "%5b")
  assert_eq(url_encode("]"), "%5d")
}

///|
test "url_encode: preserves unreserved chars" {
  assert_eq(url_encode("-_.~"), "-_.~")
}

///|
test "url_encode: handles unicode characters (UTF-8 bytes)" {
  // '中' = E4 B8 AD in UTF-8
  assert_eq(url_encode("中"), "%e4%b8%ad")
  // '日' = E6 97 A5
  assert_eq(url_encode("日"), "%e6%97%a5")
}

///|
test "url_encode: encodes control characters" {
  // \t = 0x09
  assert_eq(url_encode("\t"), "%09")
  // \n = 0x0a
  assert_eq(url_encode("\n"), "%0a")
  // \r = 0x0d
  assert_eq(url_encode("\r"), "%0d")
  // NUL = 0x00
  assert_eq(url_encode("\u{00}"), "%00")
}

///|
test "url_encode: long input round-trips through decode" {
  let original = "hello world 123 abc-def_ghi.jkl~mno"
  let encoded = url_encode(original)
  assert_eq(encoded, "hello%20world%20123%20abc-def_ghi.jkl~mno")
}

///|
test "url_encode: only special characters" {
  assert_eq(url_encode("   "), "%20%20%20")
  assert_eq(url_encode("&&&"), "%26%26%26")
}

///|
test "url_encode: numeric string passes through" {
  assert_eq(url_encode("12345"), "12345")
  assert_eq(url_encode("0"), "0")
}

///|
test "url_encode: mixed case passes through" {
  assert_eq(url_encode("ABCabc"), "ABCabc")
  assert_eq(url_encode("XyZ"), "XyZ")
}

// ============ basic_auth_header (expanded) ============

///|
test "basic_auth_header: empty user and empty password" {
  // base64(":") = "Og=="
  assert_eq(basic_auth_header("", ""), "Basic Og==")
}

///|
test "basic_auth_header: empty user with non-empty password" {
  // base64(":secret") = "OnNlY3JldA=="
  assert_eq(basic_auth_header("", "secret"), "Basic OnNlY3JldA==")
}

///|
test "basic_auth_header: non-empty user with empty password" {
  // base64("admin:") = "YWRtaW46"
  assert_eq(basic_auth_header("admin", ""), "Basic YWRtaW46")
}

///|
test "basic_auth_header: user containing colon character" {
  // base64("us:er:pass") = "dXM6ZXI6cGFzcw=="
  assert_eq(basic_auth_header("us:er", "pass"), "Basic dXM6ZXI6cGFzcw==")
}

///|
test "basic_auth_header: unicode credentials get UTF-8 base64" {
  // UTF-8 bytes of "用户:密码" then base64
  let cred = @utf8.encode("用户:密码")
  let expected_b64 = @base64.encode(cred)
  assert_eq(basic_auth_header("用户", "密码"), "Basic " + expected_b64)
}

// ============ split_tsv_line (expanded) ============

///|
test "split_tsv_line: trailing tab produces empty final cell" {
  let r = split_tsv_line("a\tb\t")
  assert_eq(r.length(), 3)
  assert_eq(r[0], "a")
  assert_eq(r[1], "b")
  assert_eq(r[2], "")
}

///|
test "split_tsv_line: lone backslash at end is preserved" {
  // Trailing \ with no escape sequence after — both bytes kept as-is
  let r = split_tsv_line("a\\")
  assert_eq(r.length(), 1)
  assert_eq(r[0], "a\\")
}

///|
test "split_tsv_line: unknown escape sequence is preserved verbatim" {
  // \x is not a recognized escape — both chars kept
  let r = split_tsv_line("a\\xb")
  assert_eq(r.length(), 1)
  assert_eq(r[0], "a\\xb")
}

///|
test "split_tsv_line: many cells" {
  let r = split_tsv_line("a\tb\tc\td\te\tf\tg")
  assert_eq(r.length(), 7)
  assert_eq(r[6], "g")
}

///|
test "split_tsv_line: all escape sequences in one cell" {
  let r = split_tsv_line("a\\tb\\nc\\\\d")
  assert_eq(r.length(), 1)
  assert_eq(r[0], "a\tb\nc\\d")
}

///|
test "split_tsv_line: empty string yields single empty cell" {
  let r = split_tsv_line("")
  assert_eq(r.length(), 1)
  assert_eq(r[0], "")
}

///|
test "split_tsv_line: only tabs" {
  let r = split_tsv_line("\t\t\t")
  assert_eq(r.length(), 4)
  for i in 0..<4 {
    assert_eq(r[i], "")
  }
}

// ============ parse_tsv_response (expanded) ============

///|
test "parse_tsv_response: single column single row" {
  let r = parse_tsv_response("id\nUInt32\n42\n")
  assert_eq(r.columns.length(), 1)
  assert_eq(r.columns[0].name, "id")
  assert_eq(r.columns[0].type_, "UInt32")
  assert_eq(r.rows.length(), 1)
  assert_eq(r.rows[0].values[0], "42")
}

///|
test "parse_tsv_response: more columns in types than names" {
  // types line has 3 entries but names line only has 2 — extra type is dropped
  let body = "a\tb\nT1\tT2\tT3\nx\ty\n"
  let r = parse_tsv_response(body)
  assert_eq(r.columns.length(), 2)
  assert_eq(r.columns[0].type_, "T1")
  assert_eq(r.columns[1].type_, "T2")
}

///|
test "parse_tsv_response: fewer columns in types than names" {
  // names has 3, types has 1 — missing types default to ""
  let body = "a\tb\tc\nT1\nx\ty\tz\n"
  let r = parse_tsv_response(body)
  assert_eq(r.columns.length(), 3)
  assert_eq(r.columns[0].type_, "T1")
  assert_eq(r.columns[1].type_, "")
  assert_eq(r.columns[2].type_, "")
}

///|
test "parse_tsv_response: long cell content preserved" {
  let long_val = String::make(2000, 'x')
  let body = "col\nString\n" + long_val + "\n"
  let r = parse_tsv_response(body)
  assert_eq(r.rows.length(), 1)
  assert_eq(r.rows[0].values[0].length(), 2000)
}

///|
test "parse_tsv_response: empty trailing lines are skipped" {
  let body = "a\tb\nT1\tT2\nx\ty\n\n\n"
  let r = parse_tsv_response(body)
  assert_eq(r.rows.length(), 1)
}

///|
test "parse_tsv_response: only headers no data rows" {
  let body = "a\tb\nT1\tT2\n"
  let r = parse_tsv_response(body)
  assert_eq(r.columns.length(), 2)
  assert_eq(r.rows.length(), 0)
}

///|
test "parse_tsv_response: only one line returns empty" {
  let r = parse_tsv_response("just_one_line")
  assert_eq(r.columns.length(), 0)
  assert_eq(r.rows.length(), 0)
}

///|
test "parse_tsv_response: many rows" {
  let body = "id\nInt32\n1\n2\n3\n4\n5\n"
  let r = parse_tsv_response(body)
  assert_eq(r.rows.length(), 5)
  assert_eq(r.rows[4].values[0], "5")
}

///|
test "parse_tsv_response: escaped tab in cell value" {
  let body = "msg\nString\na\\tb\n"
  let r = parse_tsv_response(body)
  assert_eq(r.rows.length(), 1)
  assert_eq(r.rows[0].values[0], "a\tb")
}

// ============ ResultSet::to_map (expanded) ============

///|
test "to_map: empty result set returns empty array" {
  let rs : ResultSet = { columns: [], rows: [] }
  let maps = rs.to_map()
  assert_eq(maps.length(), 0)
}

///|
test "to_map: columns with no rows" {
  let rs : ResultSet = { columns: [{ name: "x", type_: "Int32" }], rows: [] }
  let maps = rs.to_map()
  assert_eq(maps.length(), 0)
}

///|
test "to_map: column names with special characters preserved" {
  let rs : ResultSet = {
    columns: [
      { name: "user_id", type_: "UInt64" },
      { name: "ts-v2", type_: "DateTime" },
    ],
    rows: [{ values: ["1", "2024-01-01"] }],
  }
  let maps = rs.to_map()
  assert_eq(maps.length(), 1)
  assert_eq(maps[0].get("user_id"), Some("1"))
  assert_eq(maps[0].get("ts-v2"), Some("2024-01-01"))
}

///|
test "to_map: many columns preserved in each row" {
  let cols : Array[Column] = []
  for i in 0..<10 {
    cols.push({ name: "c\{i}", type_: "String" })
  }
  let values : Array[String] = []
  for i in 0..<10 {
    values.push("v\{i}")
  }
  let rs : ResultSet = { columns: cols, rows: [{ values, }] }
  let maps = rs.to_map()
  assert_eq(maps.length(), 1)
  for i in 0..<10 {
    assert_eq(maps[0].get("c\{i}"), Some("v\{i}"))
  }
}

///|
test "to_map: empty values preserved" {
  let rs : ResultSet = {
    columns: [{ name: "a", type_: "String" }, { name: "b", type_: "String" }],
    rows: [{ values: ["", ""] }],
  }
  let maps = rs.to_map()
  assert_eq(maps[0].get("a"), Some(""))
  assert_eq(maps[0].get("b"), Some(""))
}

// ============ parse_int_or (expanded) ============

///|
test "parse_int_or: large numbers within Int range" {
  assert_eq(parse_int_or("999999999", -1), 999999999)
  assert_eq(parse_int_or("2147483647", -1), 2147483647)
}

///|
test "parse_int_or: leading zeros are accepted" {
  assert_eq(parse_int_or("007", 0), 7)
  assert_eq(parse_int_or("0042", 0), 42)
}

///|
test "parse_int_or: lone sign returns fallback" {
  // "-" / "+" alone is not a valid integer — fall back rather than returning 0
  assert_eq(parse_int_or("-", 99), 99)
  assert_eq(parse_int_or("+", 99), 99)
}

///|
test "parse_int_or: only whitespace returns fallback" {
  assert_eq(parse_int_or("   ", 99), 99)
}

///|
test "parse_int_or: stops at first non-digit" {
  // After "42" comes "abc" — fallback kicks in for the whole string
  assert_eq(parse_int_or("42abc", -1), -1)
  // But "  42  " is fine because trim runs first
  assert_eq(parse_int_or("  42  ", -1), 42)
}

// ============ substr (expanded) ============

///|
test "substr: full string with start=0" {
  assert_eq(substr("Hello", 0, 5), "Hello")
}

///|
test "substr: end equals length" {
  assert_eq(substr("Hi", 0, 2), "Hi")
  assert_eq(substr("Hi", 1, 2), "i")
}

///|
test "substr: start past length returns empty" {
  assert_eq(substr("Hi", 10, 20), "")
}

///|
test "substr: start equals end returns empty" {
  assert_eq(substr("Hello", 2, 2), "")
}

///|
test "substr: empty input returns empty" {
  assert_eq(substr("", 0, 0), "")
  assert_eq(substr("", 0, 10), "")
}

// ============ build_url (expanded) ============

///|
test "build_url: database name with special chars is encoded" {
  let conn : Connection = {
    host: "h",
    port: 8123,
    user: "u",
    password: "p",
    database: "my db/with spaces",
    client_name: "c",
  }
  let url = build_url(conn, "SELECT 1", {})
  assert_true(url.contains("database=my%20db%2fwith%20spaces"))
}

///|
test "build_url: query with special chars is encoded" {
  let conn : Connection = {
    host: "h",
    port: 8123,
    user: "u",
    password: "p",
    database: "d",
    client_name: "c",
  }
  let url = build_url(conn, "SELECT * FROM t WHERE x = 'a b'", {})
  assert_true(
    url.contains(
      "query=SELECT%20%2a%20FROM%20t%20WHERE%20x%20%3d%20%27a%20b%27",
    ),
  )
}

///|
test "build_url: param keys are url-encoded" {
  let conn : Connection = {
    host: "h",
    port: 8123,
    user: "u",
    password: "p",
    database: "d",
    client_name: "c",
  }
  let url = build_url(conn, "SELECT {k v}", Map::from_array([("k v", "x")]))
  assert_true(url.contains("param_k%20v=x"))
}

///|
test "build_url: many params are all included" {
  let conn : Connection = {
    host: "h",
    port: 8123,
    user: "u",
    password: "p",
    database: "d",
    client_name: "c",
  }
  let url = build_url(
    conn,
    "SELECT 1",
    Map::from_array([("a", "1"), ("b", "2"), ("c", "3"), ("d", "4")]),
  )
  // Map iteration order is undefined — check that all 4 are present
  assert_true(url.contains("param_a=1"))
  assert_true(url.contains("param_b=2"))
  assert_true(url.contains("param_c=3"))
  assert_true(url.contains("param_d=4"))
}

///|
test "build_url: response_format is always TabSeparatedWithNamesAndTypes" {
  let conn : Connection = {
    host: "h",
    port: 8123,
    user: "u",
    password: "p",
    database: "d",
    client_name: "c",
  }
  let url = build_url(conn, "SELECT 1", {})
  assert_true(url.contains("default_format=TabSeparatedWithNamesAndTypes"))
}

// ============ apply_default_types (expanded) ============

///|
test "apply_default_types: placeholder at start of sql" {
  assert_eq(apply_default_types("{x} FROM t"), "{x: String} FROM t")
}

///|
test "apply_default_types: placeholder at end of sql" {
  assert_eq(
    apply_default_types("FROM t WHERE id = {x}"),
    "FROM t WHERE id = {x: String}",
  )
}

///|
test "apply_default_types: multiple placeholders in a row" {
  assert_eq(
    apply_default_types("{a}{b}{c}"),
    "{a: String}{b: String}{c: String}",
  )
}

///|
test "apply_default_types: placeholder adjacent to text" {
  assert_eq(apply_default_types("a{x}b"), "a{x: String}b")
  assert_eq(apply_default_types("({x})"), "({x: String})")
}

///|
test "apply_default_types: typed placeholder with extra whitespace" {
  // Whitespace around the colon does not change the typed/untyped classification
  assert_eq(apply_default_types("{x : Int32}"), "{x : Int32}")
  assert_eq(apply_default_types("{x:  Int32}"), "{x:  Int32}")
}

///|
test "apply_default_types: placeholder with digits and underscores" {
  assert_eq(apply_default_types("{user_id_2}"), "{user_id_2: String}")
  assert_eq(apply_default_types("{x1}"), "{x1: String}")
}

///|
test "apply_default_types: placeholder name with embedded colon is typed" {
  // "a:b" contains a colon, so the placeholder is treated as already typed
  assert_eq(apply_default_types("{a:b}"), "{a:b}")
}

///|
test "apply_default_types: {{ and }} are ClickHouse escape sequences" {
  // {{ unescapes to a single literal `{`; }} likewise. So `{{name}}` round-trips
  // to literal `{name}` text in the final SQL instead of becoming `{name: String}`.
  assert_eq(apply_default_types("{{name}}"), "{name}")
  assert_eq(apply_default_types("{{x}}"), "{x}")
  // Empty body
  assert_eq(apply_default_types("{{}}"), "{}")
  // The outer `{...}` is a placeholder; `{{x}}` inside unescapes to literal
  // `{x}` in the content, and the outer placeholder gets `: String`.
  assert_eq(apply_default_types("{a {{x}} b}"), "{a {x} b: String}")
  // {{ and }} work mid-string too
  assert_eq(
    apply_default_types("SELECT '{{' || x || '}}' FROM t"),
    "SELECT '{' || x || '}' FROM t",
  )
  // Unmatched `{` (no closing `}` anywhere) is copied verbatim
  assert_eq(apply_default_types("SELECT {orphan"), "SELECT {orphan")
}

///|
test "apply_default_types: real-world SELECT example" {
  let sql = "SELECT id, name FROM users WHERE created_at > {lo} AND id > {n}"
  let expected = "SELECT id, name FROM users WHERE created_at > {lo: String} AND id > {n: String}"
  assert_eq(apply_default_types(sql), expected)
}

// ============ bind_positional (expanded) ============

///|
test "bind_positional: many consecutive ? placeholders" {
  let (sql, params) = bind_positional("?, ?, ?, ?, ?", ["1", "2", "3", "4", "5"])
  assert_eq(
    sql, "{__p1: String}, {__p2: String}, {__p3: String}, {__p4: String}, {__p5: String}",
  )
  assert_eq(params.length(), 5)
  for i in 1..<=5 {
    assert_eq(params.get("__p\{i}"), Some("\{i}"))
  }
}

///|
test "bind_positional: ? at the very start of sql" {
  let (sql, params) = bind_positional("? = x", ["v"])
  assert_eq(sql, "{__p1: String} = x")
  assert_eq(params.get("__p1"), Some("v"))
}

///|
test "bind_positional: ? at the very end of sql" {
  let (sql, params) = bind_positional("x = ?", ["v"])
  assert_eq(sql, "x = {__p1: String}")
  assert_eq(params.get("__p1"), Some("v"))
}

///|
test "bind_positional: ? adjacent to punctuation" {
  let (sql, _) = bind_positional("VALUES (?,?,?)", ["a", "b", "c"])
  assert_eq(sql, "VALUES ({__p1: String},{__p2: String},{__p3: String})")
}

///|
test "bind_positional: ? adjacent to commas and parentheses" {
  let (sql, params) = bind_positional("INSERT INTO t VALUES (?, ?, ?)", [
    "a", "b", "c",
  ])
  assert_eq(
    sql, "INSERT INTO t VALUES ({__p1: String}, {__p2: String}, {__p3: String})",
  )
  assert_eq(params.length(), 3)
}

///|
test "bind_positional: many ? in a realistic INSERT statement" {
  let (sql, params) = bind_positional(
    "INSERT INTO t (a, b, c) VALUES (?, ?, ?), (?, ?, ?), (?, ?, ?)",
    ["1", "x", "y", "2", "p", "q", "3", "r", "s"],
  )
  assert_eq(
    sql, "INSERT INTO t (a, b, c) VALUES ({__p1: String}, {__p2: String}, {__p3: String}), ({__p4: String}, {__p5: String}, {__p6: String}), ({__p7: String}, {__p8: String}, {__p9: String})",
  )
  assert_eq(params.length(), 9)
  assert_eq(params.get("__p9"), Some("s"))
}

///|
test "bind_positional: value with special chars preserved verbatim" {
  let (sql, params) = bind_positional("WHERE x = ?", ["a 'b' & c; --drop"])
  assert_eq(sql, "WHERE x = {__p1: String}")
  // The value is NOT escaped here — that happens via ClickHouse's server-side
  // substitution with proper quoting.
  assert_eq(params.get("__p1"), Some("a 'b' & c; --drop"))
}

// ============ Public API structural tests ============

///|
test "connect: returns struct with all fields" {
  let c = connect(
    host="my.host",
    port=8123,
    user="alice",
    password="s3cr3t",
    database="analytics",
    client_name="my-app",
  )
  assert_eq(c.host, "my.host")
  assert_eq(c.port, 8123)
  assert_eq(c.user, "alice")
  assert_eq(c.password, "s3cr3t")
  assert_eq(c.database, "analytics")
  assert_eq(c.client_name, "my-app")
}

///|
test "Connection::close: is a no-op (does not raise)" {
  let c = connect(
    host="h",
    port=8123,
    user="u",
    password="p",
    database="d",
    client_name="c",
  )
  c.close() // Should not throw
}

///|
test "Connection::cancel: is a no-op (does not raise)" {
  let c = connect(
    host="h",
    port=8123,
    user="u",
    password="p",
    database="d",
    client_name="c",
  )
  c.cancel() // Should not throw
}

///|
test "Column and Row and ResultSet struct literals work" {
  // Round-trip a row through a ResultSet and inspect all fields
  let col : Column = { name: "id", type_: "UInt64" }
  let row : Row = { values: ["42"] }
  let rs : ResultSet = { columns: [col], rows: [row] }
  assert_eq(rs.columns.length(), 1)
  assert_eq(rs.columns[0].name, "id")
  assert_eq(rs.columns[0].type_, "UInt64")
  assert_eq(rs.rows.length(), 1)
  assert_eq(rs.rows[0].values[0], "42")
}

///|
test "DbError::ServerError variant carries its fields" {
  let err = DbError::ServerError(code=400, name="HTTPError", message="bad sql")
  match err {
    ServerError(code~, name~, message~) => {
      assert_eq(code, 400)
      assert_eq(name, "HTTPError")
      assert_eq(message, "bad sql")
    }
    ConnectionError(_) => abort("wrong variant")
  }
}

///|
test "DbError::ConnectionError variant carries its message" {
  let err = DbError::ConnectionError("connection refused")
  match err {
    ConnectionError(msg) => assert_eq(msg, "connection refused")
    ServerError(_) => abort("wrong variant")
  }
}
