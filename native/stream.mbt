///|
/// 流式游标：逐块读取 SELECT 结果，避免一次性缓冲全部数据。
/// 必须调用 `close()` 释放连接（或 `defer`）；连接在游标关闭后复用。
/// 可变状态用单元素数组 cell 表达（MoonBit 结构体字段不可变）。
pub struct NativeResultSetCursor {
  priv conn : NativeConnection
  priv cols : Array[Array[@lib.Column]]
  priv current : Array[Array[Array[String]]]
  priv row_idx : Array[Int32]
  priv done : Array[Bool]
}

///|
/// 执行 SELECT 并返回流式游标（与 HTTP 版 `execute_stream` 对齐）。
///
///   let cur = conn.execute_stream("SELECT * FROM t")
///   defer cur.close()
///   while let Some(row) = cur.next() {
///     println(row.values)
///   }
///
/// 建立游标受 `timeout_ms` 约束；之后每次 `next()` / `close()` 也各自受限。
pub async fn NativeConnection::execute_stream(
  self : NativeConnection,
  sql : String,
  params~ : Map[String, String] = Map([]),
) -> NativeResultSetCursor {
  self.config.with_timeout(() => self.execute_stream_impl(sql, params~))
}

///|
async fn NativeConnection::execute_stream_impl(
  self : NativeConnection,
  sql : String,
  params~ : Map[String, String] = Map([]),
) -> NativeResultSetCursor {
  flush_bytes(
    self.tcp,
    build_query_packet(
      self.config.client_name,
      sql,
      compress=self.compress,
      params~,
    ),
  )
  flush_bytes(self.tcp, build_empty_data_packet(self.compress))
  let cursor = {
    conn: self,
    cols: [[]],
    current: [[]],
    row_idx: [0],
    done: [false],
  }
  // 读取首个数据块（列头块），建立列信息
  cursor.prepare_first_block()
  cursor
}

///|
/// 读取首个 Data 块（列头），并消费其行数据。
async fn NativeResultSetCursor::prepare_first_block(
  self : NativeResultSetCursor,
) -> Unit {
  while !self.done[0] {
    let ptype = read_varuint(self.conn.tcp)
    match ServerPacket::from_int(ptype.to_int()) {
      Data => {
        ignore(read_string(self.conn.tcp)) // 表名
        let block = read_data_block(self.conn.tcp, self.conn.compress)
        if block.headers.length() == 0 {
          continue // 空块
        }
        self.cols[0] = []
        for h in block.headers {
          self.cols[0].push(@lib.Column::new(name=h.name, type_=h.type_))
        }
        self.current[0] = block.rows
        self.row_idx[0] = 0
        return
      }
      EndOfStream => {
        self.done[0] = true
        return
      }
      Exception => raise read_exception(self.conn.tcp)
      TableColumns => {
        ignore(read_string(self.conn.tcp))
        ignore(read_string(self.conn.tcp))
      }
      Progress =>
        for _ in 0..<6 {
          ignore(read_varuint(self.conn.tcp))
        }
      ProfileInfo => {
        ignore(read_varuint(self.conn.tcp))
        ignore(read_varuint(self.conn.tcp))
        ignore(read_varuint(self.conn.tcp))
        ignore(reader_byte(self.conn.tcp))
        ignore(read_varuint(self.conn.tcp))
        ignore(reader_byte(self.conn.tcp))
      }
      Log | ProfileEvents => {
        ignore(read_string(self.conn.tcp))
        ignore(read_block(self.conn.tcp))
      }
      Totals | Extremes => {
        ignore(read_string(self.conn.tcp))
        ignore(read_data_block(self.conn.tcp, self.conn.compress))
      }
      Pong | Hello => ()
    }
  }
}

///|
/// 返回下一行；结果耗尽返回 `None`。每次调用受 `timeout_ms` 约束。
pub async fn NativeResultSetCursor::next(
  self : NativeResultSetCursor,
) -> @lib.Row? {
  self.conn.config.with_timeout(() => self.next_impl())
}

///|
async fn NativeResultSetCursor::next_impl(
  self : NativeResultSetCursor,
) -> @lib.Row? {
  if self.done[0] {
    return None
  }
  while true {
    if self.row_idx[0] < self.current[0].length() {
      let row = self.current[0][self.row_idx[0]]
      self.row_idx[0] = self.row_idx[0] + 1
      return Some(@lib.Row::new(values=row))
    }
    // 当前块耗尽，读下一个块
    let ptype = read_varuint(self.conn.tcp)
    match ServerPacket::from_int(ptype.to_int()) {
      Data => {
        ignore(read_string(self.conn.tcp)) // 表名
        let block = read_data_block(self.conn.tcp, self.conn.compress)
        if block.headers.length() == 0 {
          continue // 空块
        }
        if self.cols[0].length() == 0 {
          for h in block.headers {
            self.cols[0].push(@lib.Column::new(name=h.name, type_=h.type_))
          }
        }
        self.current[0] = block.rows
        self.row_idx[0] = 0
      }
      EndOfStream => {
        self.done[0] = true
        return None
      }
      Exception => raise read_exception(self.conn.tcp)
      TableColumns => {
        ignore(read_string(self.conn.tcp))
        ignore(read_string(self.conn.tcp))
      }
      Progress =>
        for _ in 0..<6 {
          ignore(read_varuint(self.conn.tcp))
        }
      ProfileInfo => {
        ignore(read_varuint(self.conn.tcp))
        ignore(read_varuint(self.conn.tcp))
        ignore(read_varuint(self.conn.tcp))
        ignore(reader_byte(self.conn.tcp))
        ignore(read_varuint(self.conn.tcp))
        ignore(reader_byte(self.conn.tcp))
      }
      Log | ProfileEvents => {
        ignore(read_string(self.conn.tcp))
        ignore(read_block(self.conn.tcp))
      }
      Totals | Extremes => {
        ignore(read_string(self.conn.tcp))
        ignore(read_data_block(self.conn.tcp, self.conn.compress))
      }
      Pong | Hello => ()
    }
  } nobreak {
    raise @lib.DbError::connection_error("unexpected end of stream in cursor")
  }
}

///|
/// 游标列信息（与 HTTP 版 `ResultSetCursor::columns` 对齐）。
pub fn NativeResultSetCursor::columns(
  self : NativeResultSetCursor,
) -> Array[@lib.Column] {
  self.cols[0]
}

///|
/// 关闭游标：把连接上剩余数据读取到 EndOfStream，以便连接复用。
/// 受 `timeout_ms` 约束；超时则游标连接只能丢弃。
pub async fn NativeResultSetCursor::close(self : NativeResultSetCursor) -> Unit {
  self.conn.config.with_timeout(() => self.close_impl())
}

///|
async fn NativeResultSetCursor::close_impl(
  self : NativeResultSetCursor,
) -> Unit {
  while !self.done[0] {
    let ptype = read_varuint(self.conn.tcp)
    match ServerPacket::from_int(ptype.to_int()) {
      EndOfStream => {
        self.done[0] = true
        return
      }
      Exception => raise read_exception(self.conn.tcp)
      Data => {
        ignore(read_string(self.conn.tcp))
        ignore(read_data_block(self.conn.tcp, self.conn.compress))
      }
      TableColumns => {
        ignore(read_string(self.conn.tcp))
        ignore(read_string(self.conn.tcp))
      }
      Progress =>
        for _ in 0..<6 {
          ignore(read_varuint(self.conn.tcp))
        }
      ProfileInfo => {
        ignore(read_varuint(self.conn.tcp))
        ignore(read_varuint(self.conn.tcp))
        ignore(read_varuint(self.conn.tcp))
        ignore(reader_byte(self.conn.tcp))
        ignore(read_varuint(self.conn.tcp))
        ignore(reader_byte(self.conn.tcp))
      }
      Log | ProfileEvents => {
        ignore(read_string(self.conn.tcp))
        ignore(read_block(self.conn.tcp))
      }
      Totals | Extremes => {
        ignore(read_string(self.conn.tcp))
        ignore(read_data_block(self.conn.tcp, self.conn.compress))
      }
      Pong | Hello => ()
    }
  }
}
