///|
/// Column metadata returned from a query.
pub struct Column {
  name : String
  type_ : String
}

///|
/// A single row of query results. Each value is a string representation.
pub struct Row {
  values : Array[String]
}

///|
/// Complete result set containing column metadata and rows.
pub struct ResultSet {
  columns : Array[Column]
  rows : Array[Row]
}

///|
/// Convert result to an array of row maps.
/// Each element is a Map[String, String] mapping column name → value for that row.
pub fn ResultSet::to_map(self : ResultSet) -> Array[Map[String, String]] {
  let result : Array[Map[String, String]] = []
  for r in 0..<self.rows.length() {
    let row_map : Map[String, String] = Map::Map([])
    for c in 0..<self.columns.length() {
      row_map.set(self.columns[c].name, self.rows[r].values[c])
    }
    result.push(row_map)
  }
  result
}

///|
/// Wire format used by `Connection::insert` for the request body.
pub(all) enum InsertFormat {
  /// `FORMAT TSV` — tab-separated values (recommended, compact).
  Tsv
  /// `FORMAT JSONEachRow` — one JSON object per line.
  Ndjson
}

///|
/// 构造列元数据（供 native 等子包复用）。
pub fn Column::new(name~ : String, type_~ : String) -> Column {
  { name, type_, }
}

///|
/// 构造单行结果（供 native 等子包复用）。
pub fn Row::new(values~ : Array[String]) -> Row {
  { values, }
}

///|
/// 构造完整结果集（供 native 等子包复用）。
pub fn ResultSet::new(
  columns~ : Array[Column],
  rows~ : Array[Row],
) -> ResultSet {
  { columns, rows, }
}
