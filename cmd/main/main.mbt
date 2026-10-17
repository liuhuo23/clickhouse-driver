///|
/// Parse a string as Int (best effort), returning 0 on failure.
fn parse_int_or(s : String, fallback : Int32) -> Int32 {
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
/// ClickHouse >= 25 requires `{name: Identifier}` for identifiers (table
/// names); older versions accept `{name}` / `{name: String}` instead.
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
/// ClickHouse HTTP driver demo: comprehensive test of the current features.
/// Run with `moon run cmd/main`.
///
/// Single unified API: `execute_query(sql, params?)` covers SELECT / DDL /
/// inline-VALUES INSERT; `insert()` streams bulk rows as the HTTP body;
/// `execute_stream()` reads large result sets row by row.
async fn main {
  // 原生协议（TCP 9000）演示：CLICKHOUSE_NATIVE=1 时走 native 分支
  if @env.get_env_var("CLICKHOUSE_NATIVE") == Some("1") {
    run_native_demo()
    return
  }
  // Connection settings come from env vars (CLICKHOUSE_HOST / CLICKHOUSE_PORT /
  // CLICKHOUSE_USER / CLICKHOUSE_PASSWORD / CLICKHOUSE_DATABASE) with sensible
  // defaults, so the same demo works against any ClickHouse:
  //   CLICKHOUSE_PORT=38123 moon run cmd/main
  let host = @env.get_env_var("CLICKHOUSE_HOST").unwrap_or("127.0.0.1")
  let port = match @env.get_env_var("CLICKHOUSE_PORT") {
    Some(p) => parse_int_or(p, 8123)
    None => 8123
  }
  let user = @env.get_env_var("CLICKHOUSE_USER").unwrap_or("default")
  let password = @env.get_env_var("CLICKHOUSE_PASSWORD").unwrap_or("barn")
  let database = @env.get_env_var("CLICKHOUSE_DATABASE").unwrap_or("default")
  let conn = @lib.connect(
    host~,
    port~,
    user~,
    password~,
    database~,
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
    // ---- 0b. Reset demo tables (idempotent reruns) ----
    ignore(conn.execute_query("DROP TABLE IF EXISTS demo_drv"))
    ignore(conn.execute_query("DROP TABLE IF EXISTS demo_drv_ident"))

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

    // ---- 5d. execute_stream — row-by-row reading (no full buffering) ----
    let cur = conn.execute_stream("SELECT id, name FROM demo_drv ORDER BY id")
    defer cur.close()
    // Schema is available immediately, before any row is read.
    let schema = cur.columns().map(fn(c) { c.name + ":" + c.type_ }).join(", ")
    println("[5d] execute_stream() schema: " + schema)
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
    // The `{tn}` placeholder binds a table name; ClickHouse >= 25 needs the
    // explicit `Identifier` type for identifier positions.
    let tn_placeholder = if supports_identifier_param(conn) {
      "{tn: Identifier}"
    } else {
      "{tn}"
    }
    try {
      ignore(
        conn.execute_query(
          "SELECT * FROM " + tn_placeholder,
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

    // ---- 11. compress=true — LZ4-compressed responses ----
    // ClickHouse compresses the response body (`compress=1`); the driver
    // decodes the LZ4 blocks transparently. Use it for large result sets.
    let conn_c = @lib.connect(
      host~,
      port~,
      user~,
      password~,
      database~,
      client_name="moonbit-cli-compress",
      compress=true,
    )
    defer conn_c.close()
    let r_c = conn_c.execute_query(
      "SELECT number, randomPrintableASCII(64) FROM numbers(5000)",
    )
    println(
      "[11] compress=true: rows=" +
      r_c.rows.length().to_string() +
      " (LZ4 decompressed)",
    )

    // ---- 12. timeout_ms — bound every request ----
    // A positive timeout cancels slow requests and raises ConnectionError.
    let conn_t = @lib.connect(
      host~,
      port~,
      user~,
      password~,
      database~,
      client_name="moonbit-cli-timeout",
      timeout_ms=2000,
    )
    defer conn_t.close()
    try {
      ignore(conn_t.execute_query("SELECT sleep(3)"))
      println("[12] UNEXPECTED: sleep(3) finished within 2000ms")
    } catch {
      @lib.DbError::ConnectionError(msg) =>
        println("[12] timeout demo (expected): " + msg)
      @lib.DbError::ServerError(code=_, name=_, message~) =>
        println("[12] ServerError instead of timeout: " + message)
      _ as e => println("[12] other: " + e.to_string())
    }

    // ---- 13. https=true — TLS connection ----
    // Point `port` at a TLS-enabled ClickHouse (e.g. 8443 with HTTPS) and the
    // same API works over TLS. `skip_verify=true` disables certificate
    // validation for self-signed setups. Against the local plain-HTTP server
    // the handshake fails — the driver surfaces it as a connection error.
    let conn_tls = @lib.connect(
      host~,
      port~,
      user~,
      password~,
      database~,
      client_name="moonbit-cli-tls",
      https=true,
      skip_verify=true,
    )
    defer conn_tls.close()
    try {
      conn_tls.ping()
      println("[13] https ping ok (server has TLS)")
    } catch {
      @lib.DbError::ConnectionError(msg) =>
        println("[13] https attempt on plain-HTTP server (expected): " + msg)
      _ as e =>
        println(
          "[13] https attempt failed (server has no TLS): " + e.to_string(),
        )
    }

    // ---- 14. ConnectionPool — reuse keep-alive connections ----
    // `conn.pool(size)` keeps up to `size` connections and reuses them across
    // requests; extra concurrent requests wait for a free connection.
    let pool = conn.pool(size=3)
    defer pool.close()
    pool.ping()
    let r_p = pool.execute_query("SELECT number FROM numbers(3)")
    println("[14] pool execute_query: rows=" + r_p.rows.length().to_string())
    // Three concurrent queries share the pool's 3 connections.
    @async.with_task_group() <| group => {
      for _ in 0..<3 {
        ignore(
          group.spawn(() => {
            let rr = pool.execute_query("SELECT count() FROM numbers(1000)")
            println("    pool task rows=" + rr.rows.length().to_string())
          }),
        )
      }
    }
    // Streaming through the pool: the connection is returned on close().
    let cur_p = pool.execute_stream("SELECT number FROM numbers(5)")
    let mut pn = 0
    while true {
      match cur_p.next() {
        None => break
        Some(_) => pn = pn + 1
      }
    }
    cur_p.close()
    println("[14] pool execute_stream rows=" + pn.to_string())

    // ---- 15. Aggregation (GROUP BY) ----
    let r_agg = conn.execute_query(
      "SELECT name, count() AS n FROM demo_drv GROUP BY name ORDER BY n DESC LIMIT 3",
    )
    println("[15] GROUP BY top-3:")
    for row in r_agg.rows {
      println("    " + row.values[0] + " -> " + row.values[1] + " row(s)")
    }

    // ---- 16. insert() with a large generated batch ----
    // The point of insert() is bulk loading: 10k rows streamed as the HTTP
    // body in one request (no giant VALUES literal).
    let big_rows : Array[Array[String]] = []
    for i in 0..<10000 {
      big_rows.push([
        i.to_string(),
        "name_" + i.to_string(),
        "2024-06-16 00:00:00",
      ])
    }
    conn.insert("demo_drv", ["id", "name", "ts"], big_rows)
    let r_big = conn.execute_query("SELECT count() AS c FROM demo_drv")
    println(
      "[16] insert() 10k rows streamed; total rows=" + r_big.rows[0].values[0],
    )

    // ---- 17. Identifier parameter — bind a table name ----
    // ClickHouse >= 25 requires `{name: Identifier}` for identifiers (older
    // versions accept the untyped `{t}` form). CREATE TABLE keeps a literal
    // name because CREATE + Identifier substitution is buggy in some
    // ClickHouse versions; SELECT and DROP use the bound identifier.
    let id_tbl = "demo_drv_ident"
    let id_ph = if supports_identifier_param(conn) {
      "{t: Identifier}"
    } else {
      "{t}"
    }
    ignore(
      conn.execute_query(
        "CREATE TABLE IF NOT EXISTS demo_drv_ident (x Int32) ENGINE = Memory",
      ),
    )
    ignore(
      conn.execute_query(
        "INSERT INTO demo_drv_ident VALUES ({x: Int32})",
        params=Map::from_array([("x", "42")]),
      ),
    )
    let r_id = conn.execute_query(
      "SELECT sum(x) AS s FROM " + id_ph,
      params=Map::from_array([("t", id_tbl)]),
    )
    println("[17] identifier param sum(x)=" + r_id.rows[0].values[0])
    ignore(
      conn.execute_query(
        "DROP TABLE IF EXISTS " + id_ph,
        params=Map::from_array([("t", id_tbl)]),
      ),
    )
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
