///|
/// ClickHouse integration tests for CI (GitHub Actions service container).
/// Enabled when `CLICKHOUSE_INTEGRATION=1` — see `.github/workflows/check.yml`.

///|
using @test {assert_eq}

///|
const TABLE = "moonbit_drv_it"

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
async fn setup_table(conn : @lib.Connection) -> Unit {
  ignore(conn.execute_query("DROP TABLE IF EXISTS " + TABLE))
  let ddl =
    #|CREATE TABLE moonbit_drv_it (
    #|  id   Int32,
    #|  name String,
    #|  ts   DateTime
    #|) ENGINE = MergeTree()
    #|ORDER BY id
  ignore(conn.execute_query(ddl))
}

///|
async fn teardown_table(conn : @lib.Connection) -> Unit {
  ignore(conn.execute_query("DROP TABLE IF EXISTS " + TABLE))
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
  setup_table(conn)
  ignore(
    conn.execute(
      "INSERT INTO moonbit_drv_it (id, name, ts) VALUES (?, ?, ?), (?, ?, ?)",
      ["1", "alice", "2024-01-01 00:00:00", "2", "bob", "2024-01-02 00:00:00"],
    ),
  )
  let r = conn.execute_query(
    "SELECT id, name, ts FROM moonbit_drv_it WHERE id >= {lo: Int32} ORDER BY id",
    params=Map::from_array([("lo", "0")]),
  )
  assert_eq(r.rows.length(), 2)
  assert_eq(r.rows[0].values[0], "1")
  assert_eq(r.rows[1].values[1], "bob")
  let maps = r.to_map()
  assert_eq(maps.length(), 2)
  assert_eq(maps[0]["name"], "alice")
  assert_eq(maps[1]["id"], "2")
  teardown_table(conn)
}

///|
async test "integration: update rows" {
  let conn = integration_conn()
  defer conn.close()
  setup_table(conn)
  ignore(
    conn.execute("INSERT INTO moonbit_drv_it (id, name, ts) VALUES (?, ?, ?)", [
      "1", "before", "2024-01-01 00:00:00",
    ]),
  )
  ignore(
    conn.execute_query(
      "ALTER TABLE moonbit_drv_it UPDATE name = {n} WHERE id = {id: Int32}",
      params=Map::from_array([("n", "after"), ("id", "1")]),
    ),
  )
  let r = conn.execute_query("SELECT name FROM moonbit_drv_it WHERE id = 1")
  assert_eq(r.rows.length(), 1)
  assert_eq(r.rows[0].values[0], "after")
  teardown_table(conn)
}

///|
async test "integration: table name param" {
  let conn = integration_conn()
  defer conn.close()
  setup_table(conn)
  ignore(
    conn.execute("INSERT INTO moonbit_drv_it (id, name, ts) VALUES (?, ?, ?)", [
      "7", "seven", "2024-03-03 03:03:03",
    ]),
  )
  let r = conn.execute_query(
    "SELECT count() AS c FROM {tn}",
    params=Map::from_array([("tn", TABLE)]),
  )
  assert_eq(r.rows[0].values[0], "1")
  teardown_table(conn)
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
