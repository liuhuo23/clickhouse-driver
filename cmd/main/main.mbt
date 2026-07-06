///|
/// ClickHouse driver demo: SELECT, DDL, INSERT, ALTER UPDATE, exception handling.
/// Run with `moon run cmd/main`.
///
/// NOTE: ClickHouse does NOT support traditional ACID transactions
/// (BEGIN / COMMIT / ROLLBACK). For data mutations use ALTER TABLE ... UPDATE/DELETE
/// (which run asynchronously as "mutations") or, since ClickHouse 22.10,
/// lightweight DELETE/UPDATE statements. For atomicity on MergeTree tables,
/// use ReplacingMergeTree / CollapsingMergeTree with explicit versioning.
async fn main {
  let conn = @lib.connect(
    host="127.0.0.1",
    port=9002,
    user="default",
    password="barn",
    database="default",
    client_name="moonbit-cli",
  )
  defer conn.close()

  try {
    // ---- 1. Health check ----
    conn.ping()
    println("[1] ping ok")

    // ---- 2. SELECT (local query, no cross-db) ----
    let r_sel = conn.execute_query(
      "SELECT 1 AS a, 'hi' AS b, now() AS t FORMAT TabSeparized",
    )
    println(
      "[2] SELECT 1, 'hi', now(): rows=" + r_sel.rows.length().to_string(),
    )
    for row in r_sel.rows {
      println(
        "    a=" + row.values[0] + " b=" + row.values[1] + " t=" + row.values[2],
      )
    }

    // ---- 3. DDL: CREATE TABLE ----
    let ddl =
      #|CREATE TABLE IF NOT EXISTS demo_drv (
      #|  id   Int32,
      #|  name String,
      #|  ts   DateTime DEFAULT now()
      #|) ENGINE = MergeTree()
      #|ORDER BY id
    ignore(conn.execute_query(ddl))
    println("[3] DDL: CREATE TABLE demo_drv ok")

    // ---- 4. INSERT (skipped: requires separate data-block protocol) ----
    // For native-protocol INSERTs, the client must send a Client::Data block
    // matching the INSERT schema, then a terminating empty data block. The
    // current execute_query() always sends a single empty data block, which
    // works for SELECT/DDL but not for INSERTs that need a data round-trip.
    println("[4] INSERT skipped (would hang without data blocks; see code)")

    // ---- 5. SELECT to verify (any rows already in the table) ----
    let r2 = conn.execute_query("SELECT id, name FROM demo_drv ORDER BY id")
    println("[5] SELECT demo_drv: rows=" + r2.rows.length().to_string())
    for row in r2.rows {
      let mut line = "    "
      for v in row.values {
        line = line + v + " "
      }
      println(line)
    }

    // ---- 6. Mutation (skipped: ALTER TABLE UPDATE/DELETE returns no
    // EndOfStream until the mutation completes asynchronously, which our
    // synchronous request/response execute_query() can't wait for).
    println("[6] ALTER TABLE ... UPDATE skipped (async mutation; would hang)")

    // ---- 7. Exception handling: query against nonexistent table ----
    try {
      let _ = conn.execute_query("SELECT * FROM system.no_such_table_xyz")
      println("[7] unexpected success")
    } catch {
      @lib.DbError::ServerError(code~, name=_, message~) =>
        println(
          "[7] caught ServerError: code=" + code.to_string() + " msg=" + message,
        )
      @lib.DbError::ConnectionError(msg) =>
        println("[7] caught ConnectionError: " + msg)
      _ => println("[7] caught unknown error")
    }

    // ---- 8. Cleanup ----
    ignore(conn.execute_query("DROP TABLE IF EXISTS demo_drv"))
    println("[8] DROP TABLE demo_drv ok")
  } catch {
    @lib.DbError::ServerError(code~, name=_, message~) =>
      println("top-level ServerError: code=" + code.to_string() + " " + message)
    @lib.DbError::ConnectionError(msg) =>
      println("top-level ConnectionError: " + msg)
    _ => ()
  }
}
