///|
/// 原生连接池：复用持久 TCP 连接（acquire/release/discard 模式，
/// 与 HTTP 版 `ConnectionPool` 对齐）。
///
/// 池中的连接由池统一管理；归还时若连接已损坏则丢弃换新。
/// `execute_stream` 返回的游标必须在用完后 `close()`（或 `defer`），
/// 否则连接不会归还池。

///|
/// 原生连接池。
pub struct NativeConnectionPool {
  priv config : NativeConfig
  priv max_size : Int32
  priv sem : @async.Semaphore
  priv idle : Array[NativeConnection]
  priv closed : Array[Bool]
}

///|
/// 从连接配置创建连接池。`size` 为最大并发连接数（默认 4，<=0 时按 4）。
pub fn NativeConfig::pool(
  self : NativeConfig,
  size~ : Int32 = 4,
) -> NativeConnectionPool {
  let size = if size <= 0 { 4 } else { size }
  {
    config: self,
    max_size: size,
    sem: @async.Semaphore(size),
    idle: [],
    closed: [false],
  }
}

///|
/// 池的最大并发连接数。
pub fn NativeConnectionPool::max_size(self : NativeConnectionPool) -> Int32 {
  self.max_size
}

///|
/// 关闭池：关闭所有空闲连接；已借出的连接在归还时关闭。
pub fn NativeConnectionPool::close(self : NativeConnectionPool) -> Unit {
  self.closed[0] = true
  for conn in self.idle {
    conn.close()
  }
  self.idle.clear()
}

///|
/// 借出连接：复用空闲连接（校验健康，失效则丢弃换新）或新建；
/// 超出 `max_size` 时等待。
async fn NativeConnectionPool::acquire(
  self : NativeConnectionPool,
) -> NativeConnection {
  self.sem.acquire()
  if self.closed[0] {
    self.sem.release()
    raise @lib.DbError::connection_error("connection pool is closed")
  }
  // 复用空闲连接：ping 校验健康，失效则关闭并继续
  while self.idle.length() > 0 {
    let conn = self.idle.pop().unwrap()
    let healthy = try {
      conn.ping()
      true
    } catch {
      _ => false
    }
    if healthy {
      return conn
    }
    conn.close()
  }
  // 新建连接
  errdefer self.sem.release()
  connect(self.config)
}

///|
/// 归还健康连接到池。
fn NativeConnectionPool::release(
  self : NativeConnectionPool,
  conn : NativeConnection,
) -> Unit {
  if self.closed[0] {
    conn.close()
  } else {
    self.idle.push(conn)
  }
  self.sem.release()
}

///|
/// 关闭损坏/放弃的连接并释放池槽。
fn NativeConnectionPool::discard(
  self : NativeConnectionPool,
  conn : NativeConnection,
) -> Unit {
  conn.close()
  self.sem.release()
}

///|
/// 通过池执行健康检查（SELECT 1）。
pub async fn NativeConnectionPool::ping(self : NativeConnectionPool) -> Unit {
  let conn = self.acquire()
  errdefer self.discard(conn)
  let result = conn.ping()
  self.release(conn)
  result
}

///|
/// 通过池执行查询（命名参数 `{name: Type}` 同 `execute_query`）。
pub async fn NativeConnectionPool::execute_query(
  self : NativeConnectionPool,
  sql : String,
  params~ : Map[String, String] = Map([]),
) -> @lib.ResultSet {
  let conn = self.acquire()
  errdefer self.discard(conn)
  let result = conn.execute_query(sql, params~)
  self.release(conn)
  result
}

///|
/// 通过池执行位置参数查询（`?` 绑定）。
pub async fn NativeConnectionPool::execute(
  self : NativeConnectionPool,
  sql : String,
  values : Array[String],
) -> @lib.ResultSet {
  let (processed_sql, param_map) = @lib.bind_positional(sql, values)
  self.execute_query(@lib.apply_default_types(processed_sql), params=param_map)
}

///|
/// 通过池批量插入（Data 块上传）。
pub async fn NativeConnectionPool::insert(
  self : NativeConnectionPool,
  table : String,
  columns : Array[String],
  rows : Array[Array[String]],
) -> Unit {
  let conn = self.acquire()
  errdefer self.discard(conn)
  let result = conn.insert(table, columns, rows)
  self.release(conn)
  result
}

///|
/// 通过池执行流式查询，返回借用池连接的游标。
/// 游标必须 `close()`（或 `defer`）以归还连接。
pub async fn NativeConnectionPool::execute_stream(
  self : NativeConnectionPool,
  sql : String,
  params~ : Map[String, String] = Map([]),
) -> NativePooledCursor {
  let conn = self.acquire()
  errdefer self.discard(conn)
  let cursor = conn.execute_stream(sql, params~)
  { pool: self, cursor, }
}

///|
/// 池化游标：包装 `NativeResultSetCursor`，`close()` 时归还连接。
pub struct NativePooledCursor {
  priv pool : NativeConnectionPool
  priv cursor : NativeResultSetCursor
}

///|
/// 返回下一行；结果耗尽返回 `None`。
pub async fn NativePooledCursor::next(self : NativePooledCursor) -> @lib.Row? {
  self.cursor.next()
}

///|
/// 游标列信息。
pub fn NativePooledCursor::columns(
  self : NativePooledCursor,
) -> Array[@lib.Column] {
  self.cursor.columns()
}

///|
/// 关闭游标：读完剩余数据后把连接归还池；失败则丢弃连接。
pub async fn NativePooledCursor::close(self : NativePooledCursor) -> Unit {
  let conn = self.cursor.conn
  errdefer self.pool.discard(conn)
  self.cursor.close()
  self.pool.release(conn)
}
