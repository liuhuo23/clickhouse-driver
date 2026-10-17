///|
/// 数据块（Block）解码：BlockInfo、列头（name/type/has_custom）、列数据。
///
/// 服务器 Data / ProfileEvents / Log / Totals / Extremes 包共享同一块格式
/// （NativeWriter 输出）：**逐列交织**——每列依次写 name、type、
/// has_custom_serialization(1 字节，revision >= 54454)、该列的 nrows 个值；
/// 列数据没有每列的行数前缀，直接按块头 `nrows` 读取。

///|
/// 块内列头信息。
priv struct ColumnHeader {
  name : String
  type_ : String
}

///|
/// 解码结果：列头 + 行优先数据。
priv struct BlockData {
  headers : Array[ColumnHeader]
  rows : Array[Array[String]]
}

///|
/// 读取 BlockInfo（字段编号循环，直到 0 结束）。
/// 字段 1 = is_overflows（1 字节）；字段 2 = bucket_num（Int32）；
/// 未知字段按 VarUInt 跳过。
async fn[R : @io.Reader] read_block_info(reader : R) -> Unit {
  while true {
    let field = read_varuint(reader)
    if field == 0 {
      break
    }
    if field == 1 {
      ignore(reader.read_exactly(1))
    } else if field == 2 {
      ignore(read_int32(reader))
    } else {
      ignore(read_varuint(reader))
    }
  }
}

///|
/// 读取一个完整数据块，返回列头与行数据。
/// `nrows = 0` 时列数据为空（仅列头，如 SELECT 无结果的 SampleBlock）。
async fn[R : @io.Reader] read_block(reader : R) -> BlockData {
  read_block_info(reader)
  let ncols = read_varuint(reader).to_int()
  let nrows = read_varuint(reader).to_int()
  if ncols < 0 || nrows < 0 || ncols > 10000 || nrows > 100000000 {
    raise @lib.DbError::connection_error(
      "block dimensions out of range: ncols=\{ncols} nrows=\{nrows}",
    )
  }
  let headers : Array[ColumnHeader] = Array::make(ncols, {
    name: "",
    type_: "",
  })
  let col_data : Array[Array[String]] = Array::make(ncols, [])
  for c in 0..<ncols {
    let name = read_string(reader)
    let type_ = read_string(reader)
    ignore(reader.read_exactly(1)) // has_custom_serialization (rev >= 54454)
    headers[c] = { name, type_, }
    col_data[c] = read_column_values(reader, type_, nrows)
  }
  // 转行优先
  let rows : Array[Array[String]] = Array::make(nrows, [])
  for r in 0..<nrows {
    let row : Array[String] = Array::make(ncols, "")
    for c in 0..<ncols {
      row[c] = col_data[c][r]
    }
    rows[r] = row
  }
  { headers, rows, }
}

///|
/// 读取一个 Data 包的数据块：压缩模式读压缩块并解压后解析。
async fn[R : @io.Reader] read_data_block(
  reader : R,
  compress : Bool,
) -> BlockData {
  if !compress {
    // 非压缩：数据块直接是 NativeWriter 格式（BlockInfo + 列头 + 数据）
    return read_block(reader)
  }
  let payload = read_payload(reader, true)
  let mr = @io.MemoryReader::MemoryReader(writer => flush_bytes(writer, payload))
  let block = read_block(mr)
  mr.close()
  block
}
