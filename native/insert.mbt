///|
/// 构造 INSERT 语句（数据通过 Data 块上传，语句不含数据）。
fn build_insert_sql(table : String, columns : Array[String]) -> String {
  "INSERT INTO " + table + " (" + columns.join(", ") + ") VALUES"
}

///|
/// 构造数据 Data 块（列头 + 列数据，供 INSERT 上传）。
fn build_data_packet(
  headers : Array[ColumnHeader],
  rows : Array[Array[String]],
  compress : Bool,
) -> Bytes raise {
  let buf = Buffer::Buffer()
  write_varuint(buf, ClientPacket::Data.to_int().to_uint64())
  write_string(buf, "") // table name（明文）
  // block 内容（BlockInfo + 列头 + 列数据）
  let block = Buffer::Buffer()
  write_varuint(block, 1)
  block.write_byte(0)
  write_varuint(block, 2)
  write_int32(block, -1)
  write_varuint(block, 0)
  write_varuint(block, headers.length().to_uint64())
  let nrows = rows.length()
  write_varuint(block, nrows.to_uint64())
  for c in 0..<headers.length() {
    let h = headers[c]
    write_string(block, h.name)
    write_string(block, h.type_)
    block.write_byte(0) // has_custom_serialization = false
    // 提取该列所有行的值
    let values : Array[String] = Array::make(nrows, "")
    for r in 0..<nrows {
      values[r] = rows[r][c]
    }
    write_column_values(block, h.type_, values)
  }
  let block_bytes = block.to_bytes()
  if compress {
    write_compressed_block(buf, block_bytes)
  } else {
    buf.write_bytes(block_bytes)
  }
  buf.to_bytes()
}

///|
/// 批量插入：`INSERT INTO table (columns) VALUES` + Data 块上传。
///
/// 流程：发送 Query → 空 Data 块 → 读取服务器 SampleBlock（列头，提供列类型）
/// → 按列类型编码行数据为 Data 块发送 → 空 Data 块结束 → 读取响应直到结束。
/// 行值均为字符串表示（与 HTTP 版 `Connection::insert` 对齐），NULL 用空字符串。
pub async fn NativeConnection::insert(
  self : NativeConnection,
  table : String,
  columns : Array[String],
  rows : Array[Array[String]],
) -> Unit {
  let sql = build_insert_sql(table, columns)
  flush_bytes(
    self.tcp,
    build_query_packet(self.config.client_name, sql, compress=self.compress),
  )
  flush_bytes(self.tcp, build_empty_data_packet(self.compress))
  // 等待 SampleBlock（含列名与列类型）
  let sample = read_sample_block(self.tcp, self.compress)
  // 上传数据块 + 结束块
  flush_bytes(self.tcp, build_data_packet(sample.headers, rows, self.compress))
  flush_bytes(self.tcp, build_empty_data_packet(self.compress))
  // 读取响应直到 EndOfStream
  read_insert_response(self.tcp, self.compress)
}

///|
/// 读取 INSERT 的 SampleBlock：跳过 TableColumns，等待首个 Data 块列头。
async fn[R : @io.Reader] read_sample_block(
  reader : R,
  compress : Bool,
) -> BlockData {
  while true {
    let ptype = read_varuint(reader)
    match ServerPacket::from_int(ptype.to_int()) {
      Data => {
        ignore(read_string(reader)) // 表名
        return read_data_block(reader, compress)
      }
      TableColumns => {
        // 2 个字符串（multistring）
        ignore(read_string(reader))
        ignore(read_string(reader))
      }
      Exception => raise read_exception(reader)
      Log | ProfileEvents => {
        ignore(read_string(reader))
        ignore(read_block(reader))
      }
      Progress =>
        for _ in 0..<6 {
          ignore(read_varuint(reader))
        }
      _ => () // 忽略其他包
    }
  } nobreak {
    raise @lib.DbError::connection_error(
      "unexpected end of stream while waiting for sample block",
    )
  }
}

///|
/// 读取 INSERT 响应直到 EndOfStream。
async fn[R : @io.Reader] read_insert_response(
  reader : R,
  compress : Bool,
) -> Unit {
  while true {
    let ptype = read_varuint(reader)
    match ServerPacket::from_int(ptype.to_int()) {
      EndOfStream => return
      Exception => raise read_exception(reader)
      Data => {
        ignore(read_string(reader))
        ignore(read_data_block(reader, compress))
      }
      Progress =>
        for _ in 0..<6 {
          ignore(read_varuint(reader))
        }
      ProfileInfo => {
        ignore(read_varuint(reader))
        ignore(read_varuint(reader))
        ignore(read_varuint(reader))
        ignore(reader_byte(reader))
        ignore(read_varuint(reader))
        ignore(reader_byte(reader))
      }
      Log | ProfileEvents => {
        ignore(read_string(reader))
        ignore(read_block(reader))
      }
      Totals | Extremes => {
        ignore(read_string(reader))
        ignore(read_data_block(reader, compress))
      }
      _ => () // 忽略其他包
    }
  }
}
