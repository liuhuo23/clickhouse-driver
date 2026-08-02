///|
/// Parse a string as Int (best effort), returning 0 on failure.
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
/// ClickHouse HTTP driver demo: comprehensive test of the current features.
/// Run with `moon run cmd/main`.
///
/// Single unified API: `execute_query(sql, params?)` covers SELECT / DDL /
/// inline-VALUES INSERT; `insert()` streams bulk rows as the HTTP body;
/// `execute_stream()` reads large result sets row by row.
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

    // ---- 5b. INSERT via insert() — bulk rows streamed as TSV body ----
    let bulk_rows : Array[Array[String]] = [
      ["4", "dave", "2024-06-15 12:30:01"],
      ["5", "erin", "2024-06-15 12:30:02"],
      ["6", "frank", "2024-06-15 12:30:03"],
    ]
    conn.insert("demo_drv", ["id", "name", "ts"], bulk_rows)
    println("[5b] insert() ok (3 rows via streamed TSV body)")

    // ---- 5c. insert() with JSONEachRow (Ndjson) format ----
    let nd_rows : Array[Array[String]] = [
      ["7", "grace", "2024-06-15 12:30:04"],
      ["8", "heidi", "2024-06-15 12:30:05"],
    ]
    conn.insert(
      "demo_drv",
      ["id", "name", "ts"],
      nd_rows,
      format=@lib.InsertFormat::Ndjson,
    )
    println("[5c] insert() ok (2 rows via JSONEachRow body)")

    // ---- 5d. execute_stream — row-by-row reading ----
    let cur = conn.execute_stream("SELECT id, name FROM demo_drv ORDER BY id")
    defer cur.close()
    let mut stream_count = 0
    let mut stream_sum = 0
    while true {
      match cur.next() {
        None => break
        Some(row) => {
          stream_count = stream_count + 1
          stream_sum = stream_sum + parse_int_or(row.values[0], 0)
        }
      }
    }
    println(
      "[5d] execute_stream() rows=" +
      stream_count.to_string() +
      " id-sum=" +
      stream_sum.to_string(),
    )

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
