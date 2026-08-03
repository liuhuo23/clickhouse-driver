///|
/// 构造客户端 Query 包（含完整 ClientInfo 与空 settings 表）。
/// `params` 以 settings 字符串格式写入（name + flags(0x2) + value，空串结束）。
/// 字段顺序与 ClickHouse 25.x（客户端 revision 54460）逐字节对齐。
fn build_query_packet(
  client_name : String,
  sql : String,
  params? : Map[String, String] = Map([]),
) -> Bytes {
  let buf = Buffer::Buffer()
  write_varuint(buf, ClientPacket::Query.to_int().to_uint64())
  write_string(buf, "") // query_id
  // --- ClientInfo ---
  buf.write_byte(1) // query_kind: initial
  write_string(buf, "") // initial_user
  write_string(buf, "") // initial_query_id
  write_string(buf, "127.0.0.1:0") // initial_address（必须非空）
  write_uint64(buf, 0) // initial_query_start_time_microseconds (rev >= 54449)
  buf.write_byte(1) // interface: TCP
  write_string(buf, "") // os_user
  write_string(buf, "") // client_hostname
  write_string(buf, client_name)
  write_varuint(buf, CLIENT_VERSION_MAJOR)
  write_varuint(buf, CLIENT_VERSION_MINOR)
  write_varuint(buf, CLIENT_REVISION)
  write_string(buf, "") // quota_key (rev >= 54060)
  write_varuint(buf, 0) // distributed_depth (rev >= 54448)
  write_varuint(buf, 0) // client_version_patch (rev >= 54401)
  buf.write_byte(0) // OpenTelemetry：无 trace (rev >= 54442)
  write_varuint(buf, 0) // collaborate_with_initiator (rev >= 54453)
  write_varuint(buf, 0) // count_participating_replicas
  write_varuint(buf, 0) // number_of_current_replica
  // --- settings（字符串表，null 结尾）---
  // 让服务器移除 LowCardinality 包装（native 输出为原始类型），
  // 避免客户端实现复杂的低基数字典序列化
  write_string(buf, "low_cardinality_allow_in_native_format")
  buf.write_byte(0x1) // SettingsFlags::IMPORTANT
  write_string(buf, "0")
  write_string(buf, "") // 结束
  // --- interserver_secret (rev >= 54441) ---
  write_string(buf, "")
  write_varuint(buf, 2) // stage: Complete
  write_varuint(buf, 0) // compression: off
  write_string(buf, sql)
  // --- params（settings 字符串表格式, rev >= 54459）---
  write_params(buf, params)
  buf.to_bytes()
}

///|
/// 构造空 Data 块（声明无外部表数据，Query 包后必须发送）。
fn build_empty_data_packet() -> Bytes {
  let buf = Buffer::Buffer()
  write_varuint(buf, ClientPacket::Data.to_int().to_uint64())
  write_string(buf, "") // table name
  write_varuint(buf, 1) // BlockInfo: field 1
  buf.write_byte(0) // is_overflows = false
  write_varuint(buf, 2) // BlockInfo: field 2
  write_int32(buf, -1) // bucket_num = -1
  write_varuint(buf, 0) // BlockInfo: end
  write_varuint(buf, 0) // ncols = 0
  write_varuint(buf, 0) // nrows = 0
  buf.to_bytes()
}

///|
/// 执行 SELECT/DDL，返回完整 `ResultSet`（列名 + 类型 + 行）。
///
/// 循环读取服务器包：Data 累积结果；Progress / ProfileInfo /
/// ProfileEvents / Log / Totals / Extremes 读取后丢弃；Exception 映射为
/// `DbError::ServerError`；EndOfStream 结束。
pub async fn NativeConnection::execute_query(
  self : NativeConnection,
  sql : String,
  params? : Map[String, String] = Map([]),
) -> @lib.ResultSet {
  flush_bytes(
    self.tcp,
    build_query_packet(self.config.client_name, sql, params~),
  )
  flush_bytes(self.tcp, build_empty_data_packet())
  let columns : Array[@lib.Column] = []
  let rows : Array[@lib.Row] = []
  while true {
    let ptype = read_varuint(self.tcp)
    match ServerPacket::from_int(ptype.to_int()) {
      Data => {
        ignore(read_string(self.tcp)) // 表名（基础版本忽略）
        let block = read_block(self.tcp)
        append_block(columns, rows, block)
      }
      Progress =>
        // 6 个 VarUInt：read_rows / read_bytes / total_rows_to_read /
        // written_rows / written_bytes / elapsed_ns
        for _ in 0..<6 {
          ignore(read_varuint(self.tcp))
        }
      ProfileInfo => {
        // rows / blocks / bytes / applied_limit / rows_before_limit /
        // calculated_rows_before_limit（revision 54460 共 6 字段）
        ignore(read_varuint(self.tcp))
        ignore(read_varuint(self.tcp))
        ignore(read_varuint(self.tcp))
        ignore(reader_byte(self.tcp))
        ignore(read_varuint(self.tcp))
        ignore(reader_byte(self.tcp))
      }
      ProfileEvents | Log | Totals | Extremes => {
        ignore(read_string(self.tcp)) // 表名/tag
        ignore(read_block(self.tcp)) // 数据块（丢弃）
      }
      TableColumns => {
        // 表结构描述（multistring），查询响应中通常不出现，安全跳过
        ignore(read_string(self.tcp))
        ignore(read_string(self.tcp))
      }
      Exception => raise read_exception(self.tcp)
      EndOfStream => break
      Pong => () // 不应出现在查询响应中；安全跳过
      Hello => ()
    }
  }
  @lib.ResultSet::new(columns~, rows~)
}

///|
/// 读取 1 字节（用于跳过 ProfileInfo 中的 u8 字段）。
async fn[R : @io.Reader] reader_byte(reader : R) -> Byte {
  reader.read_exactly(1)[0]
}

///|
/// 把块数据追加到结果集（首个块建立列头，后续块校验列数并追加行）。
fn append_block(
  columns : Array[@lib.Column],
  rows : Array[@lib.Row],
  block : BlockData,
) -> Unit raise {
  // 查询结束时的空块（ncols=0, nrows=0）直接忽略
  if block.headers.length() == 0 {
    return
  }
  if columns.length() == 0 {
    for h in block.headers {
      columns.push(@lib.Column::new(name=h.name, type_=h.type_))
    }
  } else if block.headers.length() != columns.length() {
    raise @lib.DbError::connection_error(
      "block column count mismatch: got \{block.headers.length()}, expected \{columns.length()}",
    )
  }
  for r in block.rows {
    rows.push(@lib.Row::new(values=r))
  }
}
