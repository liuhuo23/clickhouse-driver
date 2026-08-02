///|
/// ClickHouse integration tests for CI (GitHub Actions service container).
/// Enabled when `CLICKHOUSE_INTEGRATION=1` — see `.github/workflows/check.yml`.

///|
using @test {assert_eq}

///|
/// Base name for test tables. Every test that creates a table uses its own
/// suffixed name, because the test runner executes tests concurrently — a
/// shared table would race (DROP/CREATE/INSERT interleavings).
const TABLE_BASE = "moonbit_drv_it"

///|
fn parse_int(s : String, fallback : Int) -> Int {
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

///|
fn integration_conn() -> @lib.Connection raise {
  match @env.get_env_var("CLICKHOUSE_INTEGRATION") {
    None | Some("") | Some("0") | Some("false") =>
      fail(
        "ClickHouse integration disabled. Set CLICKHOUSE_INTEGRATION=1 in CI.",
      )
    Some(_) => ()
  }
  let host = @env.get_env_var("CLICKHOUSE_HOST").unwrap_or("127.0.0.1")
  let port = match @env.get_env_var("CLICKHOUSE_PORT") {
    Some(p) => parse_int(p, 8123)
    None => 8123
  }
  let user = @env.get_env_var("CLICKHOUSE_USER").unwrap_or("default")
  let password = @env.get_env_var("CLICKHOUSE_PASSWORD").unwrap_or("")
  let database = @env.get_env_var("CLICKHOUSE_DATABASE").unwrap_or("default")
  @lib.connect(
    host~,
    port~,
    user~,
    password~,
    database~,
    client_name="moonbit-integration-test",
  )
}

///|
async fn setup_table(conn : @lib.Connection, table : String) -> Unit {
  ignore(conn.execute_query("DROP TABLE IF EXISTS " + table))
  let ddl = "CREATE TABLE " +
    table +
    " (\n" +
    "  id   Int32,\n" +
    "  name String,\n" +
    "  ts   DateTime\n" +
    ") ENGINE = MergeTree()\n" +
    "ORDER BY id"
  ignore(conn.execute_query(ddl))
}

///|
async fn teardown_table(conn : @lib.Connection, table : String) -> Unit {
  ignore(conn.execute_query("DROP TABLE IF EXISTS " + table))
}

///|
/// True when the server's `{name: Identifier}` HTTP parameter substitution is
/// available (ClickHouse >= 24.12). Older servers require `{name: String}`
/// even for identifiers.
async fn supports_identifier_param(conn : @lib.Connection) -> Bool {
  try {
    let r = conn.execute_query("SELECT version() AS v")
    if r.rows.length() == 0 {
      return false
    }
    let version = r.rows[0].values[0]
    let mut major = 0
    for ch in version.iter() {
      if ch == '.' {
        break
      }
      let c = ch.to_int() - '0'.to_int()
      if c >= 0 && c <= 9 {
        major = major * 10 + c
      } else {
        break
      }
    }
    major >= 25
  } catch {
    _ => false
  }
}

///|
async test "integration: ping" {
  let conn = integration_conn()
  defer conn.close()
  conn.ping()
}

///|
async test "integration: select version" {
  let conn = integration_conn()
  defer conn.close()
  let r = conn.execute_query("SELECT version() AS v")
  assert_eq(r.columns.length(), 1)
  assert_eq(r.columns[0].name, "v")
  assert_eq(r.rows.length(), 1)
  assert_true(r.rows[0].values[0].length() > 0)
}

///|
async test "integration: execute_query named params" {
  let conn = integration_conn()
  defer conn.close()
  let r = conn.execute_query(
    "SELECT {x: UInt32} AS a, {s} AS b, {t: DateTime} AS t",
    params=Map::from_array([
      ("x", "42"),
      ("s", "hello"),
      ("t", "2024-06-01 12:00:00"),
    ]),
  )
  assert_eq(r.rows.length(), 1)
  assert_eq(r.rows[0].values[0], "42")
  assert_eq(r.rows[0].values[1], "hello")
  assert_eq(r.columns[0].type_, "UInt32")
}

///|
async test "integration: ddl insert select to_map" {
  let conn = integration_conn()
  defer conn.close()
  let table = TABLE_BASE + "_map"
  setup_table(conn, table)
  ignore(
    conn.execute(
      "INSERT INTO " + table + " (id, name, ts) VALUES (?, ?, ?), (?, ?, ?)",
      ["1", "alice", "2024-01-01 00:00:00", "2", "bob", "2024-01-02 00:00:00"],
    ),
  )
  let r = conn.execute_query(
    "SELECT id, name, ts FROM " + table + " WHERE id >= {lo: Int32} ORDER BY id",
    params=Map::from_array([("lo", "0")]),
  )
  assert_eq(r.rows.length(), 2)
  assert_eq(r.rows[0].values[0], "1")
  assert_eq(r.rows[1].values[1], "bob")
  let maps = r.to_map()
  assert_eq(maps.length(), 2)
  assert_eq(maps[0]["name"], "alice")
  assert_eq(maps[1]["id"], "2")
  teardown_table(conn, table)
}

///|
async test "integration: update rows" {
  let conn = integration_conn()
  defer conn.close()
  let table = TABLE_BASE + "_upd"
  setup_table(conn, table)
  ignore(
    conn.execute("INSERT INTO " + table + " (id, name, ts) VALUES (?, ?, ?)", [
      "1", "before", "2024-01-01 00:00:00",
    ]),
  )
  ignore(
    conn.execute_query(
      "ALTER TABLE " +
      table +
      " UPDATE name = {n} WHERE id = {id: Int32} SETTINGS mutations_sync = 2",
      params=Map::from_array([("n", "after"), ("id", "1")]),
    ),
  )
  let r = conn.execute_query("SELECT name FROM " + table + " WHERE id = 1")
  assert_eq(r.rows.length(), 1)
  assert_eq(r.rows[0].values[0], "after")
  teardown_table(conn, table)
}

///|
async test "integration: table name param" {
  let conn = integration_conn()
  defer conn.close()
  let table = TABLE_BASE + "_tbl"
  setup_table(conn, table)
  ignore(
    conn.execute("INSERT INTO " + table + " (id, name, ts) VALUES (?, ?, ?)", [
      "7", "seven", "2024-03-03 03:03:03",
    ]),
  )
  // ClickHouse >= 25 requires `{name: Identifier}` for identifiers; older
  // versions accept the untyped `{tn}` form (defaulted to String).
  let placeholder = if supports_identifier_param(conn) {
    "{tn: Identifier}"
  } else {
    "{tn}"
  }
  let r = conn.execute_query(
    "SELECT count() AS c FROM " + placeholder,
    params=Map::from_array([("tn", table)]),
  )
  assert_eq(r.rows[0].values[0], "1")
  teardown_table(conn, table)
}

///|
async test "integration: server error on missing table" {
  let conn = integration_conn()
  defer conn.close()
  try {
    ignore(
      conn.execute_query(
        "SELECT * FROM {tn}",
        params=Map::from_array([("tn", "system.no_such_table_xyz")]),
      ),
    )
    fail("expected ServerError")
  } catch {
    @lib.DbError::ServerError(code~, name=_, message=_) =>
      assert_true(code >= 400)
    _ => fail("expected ServerError")
  }
}

///|
async test "integration: server error on syntax error" {
  let conn = integration_conn()
  defer conn.close()
  try {
    ignore(conn.execute_query("SLECT 1"))
    fail("expected ServerError")
  } catch {
    @lib.DbError::ServerError(code~, name=_, message=_) =>
      assert_true(code >= 400)
    _ => fail("expected ServerError")
  }
}

///|
async test "integration: ping after errors" {
  let conn = integration_conn()
  defer conn.close()
  ignore(conn.execute_query("SLECT 1")) catch {
    _ => ()
  }
  conn.ping()
}

///|
async test "integration: insert TSV bulk rows" {
  let conn = integration_conn()
  defer conn.close()
  let table = TABLE_BASE + "_bulk"
  setup_table(conn, table)
  let rows : Array[Array[String]] = [
    ["10", "ten", "2024-01-01 00:00:00"],
    ["11", "eleven", "2024-01-01 00:00:01"],
    ["12", "twelve", "2024-01-01 00:00:02"],
  ]
  conn.insert(table, ["id", "name", "ts"], rows)
  let r = conn.execute_query("SELECT count() AS c FROM " + table)
  assert_eq(r.rows[0].values[0], "3")
  teardown_table(conn, table)
}

///|
async test "integration: insert TSV with escaped values" {
  let conn = integration_conn()
  defer conn.close()
  let table = TABLE_BASE + "_esc"
  setup_table(conn, table)
  let rows : Array[Array[String]] = [
    ["20", "tab\tinside", "2024-01-01 00:00:00"],
    ["21", "line\ninside", "2024-01-01 00:00:01"],
  ]
  conn.insert(table, ["id", "name", "ts"], rows)
  let r = conn.execute_query("SELECT name FROM " + table + " WHERE id = 20")
  assert_eq(r.rows[0].values[0], "tab\tinside")
  let r2 = conn.execute_query("SELECT name FROM " + table + " WHERE id = 21")
  assert_eq(r2.rows[0].values[0], "line\ninside")
  teardown_table(conn, table)
}

///|
async test "integration: insert JSONEachRow (Ndjson)" {
  let conn = integration_conn()
  defer conn.close()
  let table = TABLE_BASE + "_nd"
  setup_table(conn, table)
  let rows : Array[Array[String]] = [
    ["30", "thirty", "2024-01-01 00:00:00"],
    ["31", "thirty one", "2024-01-01 00:00:01"],
  ]
  conn.insert(
    table,
    ["id", "name", "ts"],
    rows,
    format=@lib.InsertFormat::Ndjson,
  )
  let r = conn.execute_query("SELECT count() AS c FROM " + table)
  assert_eq(r.rows[0].values[0], "2")
  teardown_table(conn, table)
}

///|
async test "integration: execute_stream rows" {
  let conn = integration_conn()
  defer conn.close()
  let table = TABLE_BASE + "_str"
  setup_table(conn, table)
  let rows : Array[Array[String]] = [
    ["40", "a", "2024-01-01 00:00:00"],
    ["41", "b", "2024-01-01 00:00:01"],
    ["42", "c", "2024-01-01 00:00:02"],
  ]
  conn.insert(table, ["id", "name", "ts"], rows)
  let cur = conn.execute_stream(
    "SELECT id, name FROM " + table + " ORDER BY id",
  )
  defer cur.close()
  assert_eq(cur.columns().length(), 2)
  let seen : Array[String] = []
  while true {
    match cur.next() {
      None => break
      Some(row) => seen.push(row.values[0])
    }
  }
  assert_eq(seen.length(), 3)
  assert_eq(seen[0], "40")
  assert_eq(seen[2], "42")
  teardown_table(conn, table)
}

///|
async test "integration: execute_stream with named params" {
  let conn = integration_conn()
  defer conn.close()
  let table = TABLE_BASE + "_strp"
  setup_table(conn, table)
  let rows : Array[Array[String]] = [
    ["50", "x", "2024-01-01 00:00:00"],
    ["51", "y", "2024-01-01 00:00:01"],
  ]
  conn.insert(table, ["id", "name", "ts"], rows)
  let cur = conn.execute_stream(
    "SELECT id FROM " + table + " WHERE id >= {lo: Int32} ORDER BY id",
    params=Map::from_array([("lo", "51")]),
  )
  defer cur.close()
  let ids : Array[String] = []
  while true {
    match cur.next() {
      None => break
      Some(row) => ids.push(row.values[0])
    }
  }
  assert_eq(ids, ["51"])
  teardown_table(conn, table)
}

///|
async test "integration: execute_stream close before draining" {
  let conn = integration_conn()
  defer conn.close()
  let table = TABLE_BASE + "_strc"
  setup_table(conn, table)
  let rows : Array[Array[String]] = [
    ["60", "a", "2024-01-01 00:00:00"],
    ["61", "b", "2024-01-01 00:00:01"],
  ]
  conn.insert(table, ["id", "name", "ts"], rows)
  let cur = conn.execute_stream("SELECT id FROM " + table)
  // Read one row then abandon the rest — close() must not hang.
  ignore(cur.next())
  cur.close()
  conn.ping()
  teardown_table(conn, table)
}

///|
async test "integration: compress=1 response is decompressed" {
  let conn = integration_conn()
  let c = @lib.connect(
    host=conn.host,
    port=conn.port,
    user=conn.user,
    password=conn.password,
    database=conn.database,
    client_name="moonbit-integration-test",
    compress=true,
  )
  defer c.close()
  // ~2MB of low-entropy data — spans multiple 1MB compressed blocks, so the
  // frame parser (16B checksum + 9B header per block) is exercised for real.
  let r = c.execute_query(
    "SELECT number, randomPrintableASCII(100) FROM numbers(20000)",
  )
  assert_eq(r.rows.length(), 20000)
  assert_eq(r.rows[0].values[0], "0")
  assert_eq(r.rows[19999].values[0], "19999")
  assert_true(r.rows[0].values[1].length() > 0)
}

///|
async test "integration: timeout raises ConnectionError" {
  let conn = integration_conn()
  let c = @lib.connect(
    host=conn.host,
    port=conn.port,
    user=conn.user,
    password=conn.password,
    database=conn.database,
    client_name="moonbit-integration-test",
    timeout_ms=1,
  )
  defer c.close()
  try {
    // sleep() makes the query run much longer than the 1ms budget.
    ignore(c.execute_query("SELECT sleep(3)"))
    fail("expected ConnectionError on timeout")
  } catch {
    @lib.DbError::ConnectionError(msg) => assert_true(msg.contains("timed out"))
    _ => fail("expected ConnectionError")
  }
  // Connection is stateless: a new request (with no timeout) still works.
  conn.ping()
}
