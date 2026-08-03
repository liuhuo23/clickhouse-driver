///|
/// 原生协议集成测试（需要真实 ClickHouse，`CLICKHOUSE_INTEGRATION=1` 门控）。
/// 环境变量：CLICKHOUSE_NATIVE_HOST / CLICKHOUSE_NATIVE_PORT（默认 127.0.0.1:39000）。

///|
fn native_env() -> (String, Int) {
  let host = @env.get_env_var("CLICKHOUSE_NATIVE_HOST").unwrap_or("127.0.0.1")
  let port = @env.get_env_var("CLICKHOUSE_NATIVE_PORT").unwrap_or("39000")
  let port = parse_int(port, 39000)
  (host, port)
}

///|
fn require_integration() -> Unit raise {
  if @env.get_env_var("CLICKHOUSE_INTEGRATION") != Some("1") {
    fail("ClickHouse integration disabled. Set CLICKHOUSE_INTEGRATION=1 in CI.")
  }
}

///|
async fn make_conn() -> @native.NativeConnection {
  let (host, port) = native_env()
  @native.connect(
    @native.native_config(
      host~,
      port~,
      user="default",
      password="barn",
      database="default",
    ),
  )
}

///|
async test "native integration: ping" {
  require_integration()
  let conn = make_conn()
  conn.ping()
  assert_true(conn.server_version().length() > 0)
  println("native server version: \{conn.server_version()}")
  conn.close()
}

///|
async test "native integration: wrong password raises ServerError" {
  require_integration()
  let (host, port) = native_env()
  let caught = try {
    let conn = @native.connect(
      @native.native_config(
        host~,
        port~,
        user="default",
        password="wrong-password",
        database="default",
      ),
    )
    conn.close()
    false
  } catch {
    @lib.DbError::ServerError(code~, name=_, message=_) => {
      println("auth error code=\{code} (expected)")
      true
    }
    _ => false
  }
  assert_true(caught)
}

///|
async test "native integration: ping after wrong auth" {
  require_integration()
  let conn = make_conn()
  conn.ping()
  conn.ping() // 连接复用：连续 ping
  conn.close()
}

///|
async test "native integration: select basic types" {
  require_integration()
  let conn = make_conn()
  let rs = conn.execute_query(
    "SELECT toUInt8(1) AS u8, toInt16(-2) AS i16, toInt32(-300) AS i32, " +
    "toInt64(1234567890123) AS i64, toFloat32(1.5) AS f32, toFloat64(2.25) AS f64, " +
    "'hello' AS s",
  )
  assert_eq(rs.columns.length(), 7)
  assert_eq(rs.rows.length(), 1)
  assert_eq(rs.columns[0].name, "u8")
  assert_eq(rs.rows[0].values[0], "1")
  assert_eq(rs.rows[0].values[1], "-2")
  assert_eq(rs.rows[0].values[2], "-300")
  assert_eq(rs.rows[0].values[3], "1234567890123")
  assert_true(rs.rows[0].values[4].starts_with("1.5"))
  assert_true(rs.rows[0].values[5].starts_with("2.25"))
  assert_eq(rs.rows[0].values[6], "hello")
  conn.close()
}

///|
async test "native integration: select date and nullable" {
  require_integration()
  let conn = make_conn()
  let rs = conn.execute_query(
    "SELECT toDate('2026-08-03') AS d, toDateTime('2026-08-03 12:34:56') AS dt, " +
    "CAST(NULL AS Nullable(Int64)) AS n, CAST(42 AS Nullable(Int64)) AS v",
  )
  assert_eq(rs.rows.length(), 1)
  assert_eq(rs.rows[0].values[0], "2026-08-03")
  assert_eq(rs.rows[0].values[1], "2026-08-03 12:34:56")
  assert_eq(rs.rows[0].values[2], "")
  assert_eq(rs.rows[0].values[3], "42")
  conn.close()
}

///|
async test "native integration: select multiple rows" {
  require_integration()
  let conn = make_conn()
  let rs = conn.execute_query(
    "SELECT number AS n, toString(number * number) AS sq FROM numbers(3)",
  )
  assert_eq(rs.columns.length(), 2)
  assert_eq(rs.rows.length(), 3)
  assert_eq(rs.rows[0].values[0], "0")
  assert_eq(rs.rows[1].values[1], "1")
  assert_eq(rs.rows[2].values[0], "2")
  assert_eq(rs.rows[2].values[1], "4")
  conn.close()
}

///|
async test "native integration: empty result has columns" {
  require_integration()
  let conn = make_conn()
  let rs = conn.execute_query(
    "SELECT number AS n FROM numbers(3) WHERE number > 100",
  )
  assert_eq(rs.columns.length(), 1)
  assert_eq(rs.columns[0].name, "n")
  assert_eq(rs.rows.length(), 0)
  conn.close()
}

///|
async test "native integration: syntax error raises ServerError" {
  require_integration()
  let conn = make_conn()
  let caught = try {
    ignore(conn.execute_query("SLECT 1"))
    false
  } catch {
    @lib.DbError::ServerError(code~, name=_, message~) => {
      println("syntax error code=\{code} (expected)")
      assert_true(message.length() > 0)
      true
    }
    _ => false
  }
  assert_true(caught)
  // 错误后连接仍可复用
  conn.ping()
  let rs = conn.execute_query("SELECT 1 AS one")
  assert_eq(rs.rows[0].values[0], "1")
  conn.close()
}

///|
async test "native integration: insert basic rows" {
  require_integration()
  let conn = make_conn()
  ignore(conn.execute_query("DROP TABLE IF EXISTS native_demo_ins"))
  ignore(
    conn.execute_query(
      "CREATE TABLE native_demo_ins (a Int32, b String, c Float64) ENGINE = Memory",
    ),
  )
  conn.insert("native_demo_ins", ["a", "b", "c"], [
    ["1", "x", "1.5"],
    ["2", "yy", "2.25"],
    ["3", "zzz", "3.75"],
  ])
  let rs = conn.execute_query("SELECT a, b, c FROM native_demo_ins ORDER BY a")
  assert_eq(rs.rows.length(), 3)
  assert_eq(rs.rows[0].values[0], "1")
  assert_eq(rs.rows[0].values[1], "x")
  assert_true(rs.rows[0].values[2].has_prefix("1.5"))
  assert_eq(rs.rows[1].values[0], "2")
  assert_eq(rs.rows[2].values[1], "zzz")
  ignore(conn.execute_query("DROP TABLE IF EXISTS native_demo_ins"))
  conn.close()
}

///|
async test "native integration: insert with null and date" {
  require_integration()
  let conn = make_conn()
  ignore(conn.execute_query("DROP TABLE IF EXISTS native_demo_ins2"))
  ignore(
    conn.execute_query(
      "CREATE TABLE native_demo_ins2 (id UInt64, name String, note Nullable(String), d Date) ENGINE = Memory",
    ),
  )
  conn.insert("native_demo_ins2", ["id", "name", "note", "d"], [
    ["1", "alice", "hello", "2026-08-03"],
    ["2", "bob", "", "2026-08-04"],
    ["3", "carol", "world", "2026-08-05"],
  ])
  let rs = conn.execute_query(
    "SELECT id, name, note, d FROM native_demo_ins2 ORDER BY id",
  )
  assert_eq(rs.rows.length(), 3)
  assert_eq(rs.rows[0].values[1], "alice")
  assert_eq(rs.rows[0].values[2], "hello")
  assert_eq(rs.rows[0].values[3], "2026-08-03")
  // NULL 以空字符串表示
  assert_eq(rs.rows[1].values[2], "")
  assert_eq(rs.rows[2].values[3], "2026-08-05")
  ignore(conn.execute_query("DROP TABLE IF EXISTS native_demo_ins2"))
  conn.close()
}

///|
async test "native integration: insert then reuse connection" {
  require_integration()
  let conn = make_conn()
  ignore(conn.execute_query("DROP TABLE IF EXISTS native_demo_ins3"))
  ignore(
    conn.execute_query(
      "CREATE TABLE native_demo_ins3 (x Int64) ENGINE = Memory",
    ),
  )
  conn.insert("native_demo_ins3", ["x"], [["10"], ["20"], ["30"]])
  conn.ping() // 插入后连接仍可复用
  let rs = conn.execute_query("SELECT sum(x) AS s FROM native_demo_ins3")
  assert_eq(rs.rows[0].values[0], "60")
  ignore(conn.execute_query("DROP TABLE IF EXISTS native_demo_ins3"))
  conn.close()
}

///|
async test "native integration: named params" {
  require_integration()
  let conn = make_conn()
  let rs = conn.execute_query(
    "SELECT {n: UInt32} AS n, {s: String} AS s",
    params=Map::from_array([("n", "42"), ("s", "hello")]),
  )
  assert_eq(rs.rows.length(), 1)
  assert_eq(rs.rows[0].values[0], "42")
  assert_eq(rs.rows[0].values[1], "hello")
  conn.close()
}

///|
async test "native integration: positional params" {
  require_integration()
  let conn = make_conn()
  let rs = conn.execute("SELECT ? AS a, ? AS b", ["7", "world"])
  assert_eq(rs.rows[0].values[0], "7")
  assert_eq(rs.rows[0].values[1], "world")
  conn.close()
}

///|
async test "native integration: execute_stream rows" {
  require_integration()
  let conn = make_conn()
  let cur = conn.execute_stream("SELECT number AS n FROM numbers(5)")
  assert_eq(cur.columns().length(), 1)
  assert_eq(cur.columns()[0].name, "n")
  let mut sum = 0
  while true {
    match cur.next() {
      Some(row) => sum = sum + parse_int(row.values[0], 0)
      None => break
    }
  }
  cur.close()
  assert_eq(sum, 10) // 0+1+2+3+4
  // 流式游标关闭后连接可复用
  conn.ping()
  let rs = conn.execute_query("SELECT 1 AS one")
  assert_eq(rs.rows[0].values[0], "1")
  conn.close()
}

///|
async test "native integration: execute_stream with params and early close" {
  require_integration()
  let conn = make_conn()
  let cur = conn.execute_stream(
    "SELECT number AS n FROM numbers(100) WHERE number % 10 = {mod: UInt32}",
    params=Map::from_array([("mod", "3")]),
  )
  // 只读前 3 行后提前关闭，连接仍需可复用
  let mut got = 0
  while got < 3 {
    match cur.next() {
      Some(_) => got = got + 1
      None => break
    }
  }
  cur.close()
  conn.ping()
  let rs = conn.execute_query("SELECT 2 AS two")
  assert_eq(rs.rows[0].values[0], "2")
  conn.close()
}

///|
async test "native integration: array and tuple types" {
  require_integration()
  let conn = make_conn()
  let rs = conn.execute_query(
    "SELECT [1, 2, 3] AS arr, [] AS empty_arr, [[1,2],[3]] AS arr2, " +
    "(1, 'x', 1.5) AS t",
  )
  assert_eq(rs.rows.length(), 1)
  assert_eq(rs.rows[0].values[0], "[1,2,3]")
  assert_eq(rs.rows[0].values[1], "[]")
  assert_eq(rs.rows[0].values[2], "[[1,2],[3]]")
  assert_eq(rs.rows[0].values[3], "(1,'x',1.5)")
  conn.close()
}

///|
async test "native integration: map type" {
  require_integration()
  let conn = make_conn()
  let rs = conn.execute_query("SELECT map('k1', 10, 'k2', 20) AS m")
  assert_eq(rs.rows[0].values[0], "{'k1':10,'k2':20}")
  conn.close()
}

///|
async test "native integration: decimal types" {
  require_integration()
  let conn = make_conn()
  let rs = conn.execute_query(
    "SELECT toDecimal32(1.23, 2) AS d32, toDecimal64(45678.12, 2) AS d64, " +
    "toDecimal128(123456789.123, 3) AS d128, toDecimal256(1.50, 2) AS d256, " +
    "toDecimal32(1.00, 2) AS d_int",
  )
  assert_eq(rs.rows[0].values[0], "1.23")
  assert_eq(rs.rows[0].values[1], "45678.12")
  assert_eq(rs.rows[0].values[2], "123456789.123")
  assert_eq(rs.rows[0].values[3], "1.5")
  assert_eq(rs.rows[0].values[4], "1")
  conn.close()
}

///|
async test "native integration: uuid ip datetime64 enum" {
  require_integration()
  let conn = make_conn()
  let rs = conn.execute_query(
    "SELECT toUUID('123e4567-e89b-12d3-a456-426614174000') AS u, " +
    "toIPv4('127.0.0.1') AS ip4, toIPv6('::1') AS ip6, " +
    "toIPv6('2001:db8::1') AS ip6b, " +
    "toDateTime64('2026-08-03 12:34:56.123', 3) AS dt64, " +
    "CAST(1 AS Enum8('a' = 1, 'b' = 2)) AS e",
  )
  assert_eq(rs.rows[0].values[0], "123e4567-e89b-12d3-a456-426614174000")
  assert_eq(rs.rows[0].values[1], "127.0.0.1")
  assert_eq(rs.rows[0].values[2], "::1")
  assert_eq(rs.rows[0].values[3], "2001:db8::1")
  assert_eq(rs.rows[0].values[4], "2026-08-03 12:34:56.123")
  assert_eq(rs.rows[0].values[5], "a")
  conn.close()
}

///|
async test "native integration: nullable array and low cardinality" {
  require_integration()
  let conn = make_conn()
  let rs = conn.execute_query(
    "SELECT CAST([1, NULL, 3] AS Array(Nullable(Int32))) AS na, " +
    "toLowCardinality('hello') AS lc",
  )
  assert_eq(rs.rows[0].values[0], "[1,NULL,3]")
  // low_cardinality_allow_in_native_format=0 时服务器返回 String
  assert_eq(rs.rows[0].values[1], "hello")
  assert_eq(rs.columns[1].type_, "String")
  conn.close()
}

///|
async test "native integration: insert complex scalar types" {
  require_integration()
  let conn = make_conn()
  ignore(conn.execute_query("DROP TABLE IF EXISTS native_scalars"))
  ignore(
    conn.execute_query(
      "CREATE TABLE native_scalars (id UInt32, d Decimal(38,3), u UUID, ip IPv4, e Enum8('a' = 1, 'b' = 2), dt DateTime64(3)) ENGINE = Memory",
    ),
  )
  conn.insert("native_scalars", ["id", "d", "u", "ip", "e", "dt"], [
    [
      "1", "123456789.123", "123e4567-e89b-12d3-a456-426614174000", "127.0.0.1",
      "a", "2026-08-03 12:34:56.123",
    ],
    [
      "2", "-0.5", "00000000-0000-0000-0000-000000000000", "192.168.1.1", "b", "2026-08-03 00:00:00.5",
    ],
  ])
  let rs = conn.execute_query("SELECT * FROM native_scalars ORDER BY id")
  assert_eq(rs.rows.length(), 2)
  assert_eq(rs.rows[0].values[1], "123456789.123")
  assert_eq(rs.rows[0].values[2], "123e4567-e89b-12d3-a456-426614174000")
  assert_eq(rs.rows[0].values[3], "127.0.0.1")
  assert_eq(rs.rows[0].values[4], "a")
  assert_eq(rs.rows[0].values[5], "2026-08-03 12:34:56.123")
  assert_eq(rs.rows[1].values[1], "-0.5")
  assert_eq(rs.rows[1].values[3], "192.168.1.1")
  assert_eq(rs.rows[1].values[4], "b")
  ignore(conn.execute_query("DROP TABLE IF EXISTS native_scalars"))
  conn.close()
}
