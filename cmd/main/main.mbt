///|
/// ClickHouse HTTP driver demo: comprehensive test of v0.4 features.
/// Run with `moon run cmd/main`.
///
/// Single unified API: `execute_query(sql, params?)` — covers SELECT, DDL,
/// and inline-VALUES INSERT, with optional named-parameter substitution.
async fn main {
  let conn = @lib.connect(
    host="127.0.0.1",
    port=8123,
    user="default",
    password="barn",
    database="default",
    client_name="moonbit-cli",
  )
  defer conn.close()

  // ---- 0. Verify connection config ----
  println(
    "[0] connected to " +
    conn.host +
    ":" +
    conn.port.to_string() +
    " db=" +
    conn.database +
    " user=" +
    conn.user,
  )

  try {
    // ---- 1. Health check ----
    conn.ping()
    println("[1] ping ok")

    // ---- 2. Cancel is a no-op over HTTP ----
    conn.cancel()
    println("[2] cancel() called (HTTP: no-op)")

    // ---- 3. SELECT with named parameters ----
    let r_sel = conn.execute_query(
      "SELECT {x: UInt32} AS a, {s} AS b, {t: DateTime} AS t",
      params=Map::from_array([
        ("x", "1"),
        ("s", "hi"),
        ("t", "2024-01-01 00:00:00"),
      ]),
    )
    println(
      "[3] SELECT with params: rows=" +
      r_sel.rows.length().to_string() +
      " cols=" +
      r_sel.columns.length().to_string(),
    )
    for row in r_sel.rows {
      println(
        "    a=" + row.values[0] + " b=" + row.values[1] + " t=" + row.values[2],
      )
    }
    if r_sel.columns.length() > 0 {
      println(
        "    schema: " +
        r_sel.columns[0].name +
        ":" +
        r_sel.columns[0].type_ +
        ", " +
        r_sel.columns[1].name +
        ":" +
        r_sel.columns[1].type_,
      )
    }

    // ---- 4. DDL: CREATE TABLE (no params needed) ----
    let ddl =
      #|CREATE TABLE IF NOT EXISTS demo_drv (
      #|  id   Int32,
      #|  name String,
      #|  ts   DateTime DEFAULT now()
      #|) ENGINE = MergeTree()
      #|ORDER BY id
    ignore(conn.execute_query(ddl))
    println("[4] CREATE TABLE demo_drv ok")

    // ---- 5. INSERT — same `?` placeholder convention as other DB drivers.
    ignore(
      conn.execute(
        "INSERT INTO demo_drv (id, name, ts) VALUES " +
        "(?, ?, ?), (?, ?, ?), (?, ?, ?)",
        [
          "1", "alice", "2024-01-01 00:00:00", "2", "bob", "2024-01-01 00:00:01",
          "3", "carol", "2024-06-15 12:30:00",
        ],
      ),
    )
    println("[5] INSERT demo_drv ok (3 rows via positional `?`)")

    // ---- 6. SELECT verify INSERT (with WHERE filter via param) ----
    let r2 = conn.execute_query(
      "SELECT id, name, ts FROM demo_drv WHERE id >= {lo: Int32} ORDER BY id",
      params=Map::from_array([("lo", "0")]),
    )
    println(
      "[6] SELECT demo_drv WHERE id >= {lo}: rows=" +
      r2.rows.length().to_string(),
    )
    for row in r2.rows {
      println(
        "    id=" +
        row.values[0] +
        " name=" +
        row.values[1] +
        " ts=" +
        row.values[2],
      )
    }

    // ---- 7. SELECT with to_map() ----
    let rows_map = r2.to_map()
    println("[7] to_map() result:")
    for m in rows_map {
      println(
        "    " +
        m.get_or_default("id", "?") +
        " -> " +
        m.get_or_default("name", "?"),
      )
    }

    // ---- 8. ServerError: nonexistent table ----
    try {
      ignore(
        conn.execute_query(
          "SELECT * FROM {tn}",
          params=Map::from_array([("tn", "system.no_such_table_xyz")]),
        ),
      )
      println("[8] UNEXPECTED: query succeeded")
    } catch {
      @lib.DbError::ServerError(code~, name=_, message~) =>
        println(
          "[8] caught ServerError(code=" + code.to_string() + "): " + message,
        )
      @lib.DbError::ConnectionError(msg) =>
        println("[8] caught ConnectionError: " + msg)
      _ as e => println("[8] caught other: " + e.to_string())
    }

    // ---- 9. Syntax error ----
    try {
      ignore(conn.execute_query("SLECT 1")) // typo: SLECT
      println("[9] UNEXPECTED: syntax error not caught")
    } catch {
      @lib.DbError::ServerError(code~, name=_, message~) =>
        println(
          "[9] caught syntax error (code=" + code.to_string() + "): " + message,
        )
      @lib.DbError::ConnectionError(msg) =>
        println("[9] caught ConnectionError: " + msg)
      _ => println("[9] caught unknown")
    }

    // ---- 10. Ping after errors ----
    conn.ping()
    println("[10] ping after errors ok")

    // ---- Cleanup ----
    ignore(conn.execute_query("DROP TABLE IF EXISTS demo_drv"))
    println("[cleanup] DROP TABLE demo_drv ok")
  } catch {
    @lib.DbError::ServerError(code~, name=_, message~) =>
      println("TOP-LEVEL ServerError: code=" + code.to_string() + " " + message)
    @lib.DbError::ConnectionError(msg) =>
      println("TOP-LEVEL ConnectionError: " + msg)
    _ as e => println("TOP-LEVEL unknown: " + e.to_string())
  }

  println("All tests completed.")
}
