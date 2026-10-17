// Whitebox tests for the shared parameter-binding helpers.

///|
using @test {assert_eq}

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
