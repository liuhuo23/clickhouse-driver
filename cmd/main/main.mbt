///|
/// ClickHouse CLI using the driver library.
/// Run with `moon run cmd/main`.
async fn main {
  let conn = @lib.connect(
    host="127.0.0.1",
    port=9002,
    user="default",
    password="barn",
    database="barn",
    client_name="moonbit-cli",
  )
  defer conn.close()

  let result = conn.execute_query("select * from barn.data limit 10")
  println("Columns (" + result.columns.length().to_string() + "):")
  for i in 0..<result.columns.length() {
    let col = result.columns[i]
    println("  [" + i.to_string() + "] " + col.name + " : " + col.type_)
  }
  println("Rows (" + result.rows.length().to_string() + "):")
  for i in 0..<result.rows.length() {
    let row = result.rows[i]
    let mut line = "  row[" + i.to_string() + "]:"
    for j in 0..<row.values.length() {
      line = line + " " + row.values[j]
    }
    println(line)
  }

  // Demo: to_map
  let maps = result.to_map()
  println("Map entries (" + maps.length().to_string() + " rows):")
  for i in 0..<maps.length() {
    let m = maps[i]
    let mut line = "  row[" + i.to_string() + "]: {"
    for j in 0..<result.columns.length() {
      let col_name = result.columns[j].name
      if j > 0 {
        line = line + ", "
      }
      line = line + col_name + ": " + m[col_name]
    }
    line = line + "}"
    println(line)
  }
}
