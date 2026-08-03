///|
/// 原生协议（Native Protocol, TCP 9000）演示示例。
///
/// 通过 `CLICKHOUSE_NATIVE=1` 切换（HTTP 版默认）：
///   CLICKHOUSE_NATIVE=1 CLICKHOUSE_NATIVE_PORT=39000 moon run cmd/main
///
/// 展示：连接 + 握手、ping、SELECT 基础类型、NULL 值、错误处理、连接复用。

///|
async fn run_native_demo() -> Unit {
  let host = @env.get_env_var("CLICKHOUSE_NATIVE_HOST").unwrap_or("127.0.0.1")
  let port = match @env.get_env_var("CLICKHOUSE_NATIVE_PORT") {
    Some(p) => parse_int_or(p, 9000)
    None => 9000
  }
  let user = @env.get_env_var("CLICKHOUSE_NATIVE_USER").unwrap_or("default")
  let password = @env.get_env_var("CLICKHOUSE_NATIVE_PASSWORD").unwrap_or(
    "barn",
  )
  let database = @env.get_env_var("CLICKHOUSE_NATIVE_DATABASE").unwrap_or(
    "default",
  )
  let conn = @native.connect(
    @native.native_config(
      host~,
      port~,
      user~,
      password~,
      database~,
      client_name="moonbit-native-cli",
    ),
  )
  defer conn.close()

  println(
    "[0] native connected to " +
    host +
    ":" +
    port.to_string() +
    " server=" +
    conn.server_version() +
    " tz=" +
    conn.server_timezone(),
  )

  try {
    // ---- 1. ping ----
    conn.ping()
    println("[1] native ping ok")

    // ---- 2. SELECT 基础类型 ----
    let rs = conn.execute_query(
      "SELECT toUInt8(1) AS u8, toInt32(-42) AS i32, toFloat64(3.14) AS f64, " +
      "'hello' AS s, toDate('2026-08-03') AS d, toDateTime('2026-08-03 12:34:56') AS dt",
    )
    println("[2] columns=" + rs.columns.length().to_string())
    if rs.rows.length() > 0 {
      println("[2] row=" + rs.rows[0].values.to_string())
    }

    // ---- 3. 多行 + NULL ----
    let rs2 = conn.execute_query(
      "SELECT number AS n, if(number % 2 = 0, toString(number), NULL) AS even FROM numbers(4)",
    )
    println(
      "[3] rows=" +
      rs2.rows.length().to_string() +
      " (NULL 显示为空字符串)",
    )
    for row in rs2.rows {
      println("[3]   " + row.values.to_string())
    }

    // ---- 4. 语法错误 → ServerError（连接保持可用）----
    let caught = try {
      ignore(conn.execute_query("SLECT 1"))
      false
    } catch {
      @lib.DbError::ServerError(code~, name~, message~) => {
        println(
          "[4] expected ServerError code=" + code.to_string() + ": " + message,
        )
        true
      }
      _ => false
    }
    if caught {
      conn.ping()
      println("[4] connection reusable after error")
    }

    // ---- 5. INSERT 批量插入（Data 块上传）----
    ignore(
      conn.execute_query(
        "CREATE TABLE IF NOT EXISTS native_demo_ins (id UInt64, name String, note Nullable(String)) ENGINE = Memory",
      ),
    )
    ignore(conn.execute_query("TRUNCATE TABLE native_demo_ins"))
    conn.insert("native_demo_ins", ["id", "name", "note"], [
      ["1", "alice", "hello"],
      ["2", "bob", ""],
      ["3", "carol", "world"],
    ])
    let rs_ins = conn.execute_query(
      "SELECT id, name, note FROM native_demo_ins ORDER BY id",
    )
    println("[5] insert 3 rows, select back:")
    for row in rs_ins.rows {
      println("[5]   " + row.values.to_string())
    }
    ignore(conn.execute_query("DROP TABLE IF EXISTS native_demo_ins"))

    // ---- 6. 命名参数 + 位置参数绑定 ----
    let rs_p1 = conn.execute_query(
      "SELECT {n: UInt32} AS n, {s: String} AS s",
      params=Map::from_array([("n", "42"), ("s", "hello")]),
    )
    let rs_p2 = conn.execute("SELECT ? AS a, ? AS b", ["7", "world"])
    println(
      "[6] named=" +
      rs_p1.rows[0].values.to_string() +
      " positional=" +
      rs_p2.rows[0].values.to_string(),
    )

    // ---- 7. 流式游标（逐块读取，不缓存全部结果）----
    let cur = conn.execute_stream("SELECT number AS n FROM numbers(5)")
    println("[7] stream columns=" + cur.columns().length().to_string())
    let mut n_rows = 0
    while true {
      match cur.next() {
        Some(row) => {
          n_rows = n_rows + 1
          println("[7]   row=" + row.values.to_string())
        }
        None => break
      }
    }
    cur.close()
    println("[7] stream rows=" + n_rows.to_string())

    // ---- 8. 连接池（复用持久连接，acquire/release 模式）----
    let pool = @native.native_config(
      host~,
      port~,
      user~,
      password~,
      database~,
    ).pool(size=2)
    ignore(
      pool.execute_query(
        "CREATE TABLE IF NOT EXISTS native_pool_demo (id UInt32, name String) ENGINE = Memory",
      ),
    )
    ignore(pool.execute_query("TRUNCATE TABLE native_pool_demo"))
    let rs_pool = pool.execute_query("SELECT number AS n FROM numbers(4)")
    println("[8] pool query rows=" + rs_pool.rows.length().to_string())
    pool.insert(
      "native_pool_demo",
      ["id", "name"],
      [["10", "pooled"]],
    )
    let rs_pool2 = pool.execute_query(
      "SELECT name FROM native_pool_demo WHERE id = 10",
    )
    println("[8] pool insert-back=" + rs_pool2.rows[0].values[0])
    ignore(pool.execute_query("DROP TABLE IF EXISTS native_pool_demo"))
    pool.close()

    // ---- 9. 无结果查询（仍返回列头）----
    let rs3 = conn.execute_query(
      "SELECT number AS n FROM numbers(3) WHERE number > 100",
    )
    println(
      "[5] empty result columns=" +
      rs3.columns.length().to_string() +
      " rows=" +
      rs3.rows.length().to_string(),
    )
  } catch {
    @lib.DbError::ServerError(code~, name=_, message~) =>
      println("TOP-LEVEL ServerError: code=" + code.to_string() + " " + message)
    @lib.DbError::ConnectionError(msg) =>
      println("TOP-LEVEL ConnectionError: " + msg)
    _ as e => println("TOP-LEVEL unknown: " + e.to_string())
  }

  println("Native demo completed.")
}
