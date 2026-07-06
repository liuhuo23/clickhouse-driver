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
