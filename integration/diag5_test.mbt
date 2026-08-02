///|
async test "diag5: table name param flow" {
  let conn = integration_conn()
  let table = "moonbit_drv_it_tbl_diag"
  ignore(conn.execute_query("DROP TABLE IF EXISTS " + table)) catch { _ => () }
  let ddl =
    "CREATE TABLE " + table + " (\n  id   Int32,\n  name String,\n  ts   DateTime\n) ENGINE = MergeTree()\nORDER BY id"
  try {
    ignore(conn.execute_query(ddl))
    println("create OK")
  } catch {
    @lib.DbError::ServerError(code~, name=_, message~) =>
      println("create err: [" + message + "]")
    _ => println("create other")
  }
  try {
    ignore(
      conn.execute("INSERT INTO " + table + " (id, name, ts) VALUES (?, ?, ?)", [
        "7", "seven", "2024-03-03 03:03:03",
      ]),
    )
    println("insert OK")
  } catch {
    @lib.DbError::ServerError(code~, name=_, message~) =>
      println("insert err: [" + message + "]")
    _ => println("insert other")
  }
  try {
    let r = conn.execute_query(
      "SELECT count() AS c FROM {tn}",
      params=Map::from_array([("tn", table)]),
    )
    println("select OK count=" + r.rows[0].values[0])
  } catch {
    @lib.DbError::ServerError(code~, name=_, message~) =>
      println("select err: [" + message + "]")
    _ => println("select other")
  }
}
