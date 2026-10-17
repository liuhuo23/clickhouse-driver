///|
/// ClickHouse 原生 TCP 协议驱动（基础版本）。
///
/// 与根包 HTTP 驱动相对：建立持久 TCP 连接（端口 9000），握手后复用连接。
/// 基础版本能力：连接 / 握手 / ping / 取消 / 关闭；SELECT 查询与 INSERT
/// 在后续阶段补齐（见 docs/native-protocol-design.md）。
///
/// 错误语义与 HTTP 版一致：raise `@lib.DbError`
/// （`ServerError` / `ConnectionError`）。

///|
/// 原生连接配置。
pub struct NativeConfig {
  host : String
  port : Int32
  user : String
  password : String
  database : String
  client_name : String
  /// 每次公开操作（connect / ping / query / insert / cursor next）的超时
  /// （毫秒）；`0` = 无超时（默认）。超时后连接停在半个数据包上，应关闭。
  timeout_ms : Int32
  /// 是否启用 LZ4 压缩（原生协议压缩块，Data/Totals/Extremes 包）。
  compress : Bool
}

///|
/// 从显式参数构建 `NativeConfig`（不建立连接）。
///
/// 可选参数：`database` 默认 `"default"`，`client_name` 默认
/// `"moonbit-clickhouse-native"`，`timeout_ms` 默认 `0`（无超时）。
pub fn native_config(
  host~ : String,
  port~ : Int32 = 9000,
  user~ : String,
  password~ : String,
  database~ : String = "default",
  client_name~ : String = "moonbit-clickhouse-native",
  timeout_ms~ : Int32 = 0,
  compress~ : Bool = false,
) -> NativeConfig {
  { host, port, user, password, database, client_name, timeout_ms, compress, }
}

///|
/// 在 `timeout_ms > 0` 时给一次完整操作加超时；超时映射为
/// `ConnectionError`（与 HTTP 版语义一致）。
///
/// 超时意味着协议流停在半个数据包上，该连接不能再复用——调用方应
/// `close()`；连接池路径会自动 discard。
async fn[X] NativeConfig::with_timeout(
  self : NativeConfig,
  f : async () -> X,
) -> X {
  if self.timeout_ms <= 0 {
    return f()
  }
  @async.with_timeout(self.timeout_ms, f) catch {
    @async.TimeoutError =>
      raise @lib.DbError::connection_error(
        "native operation timed out after \{self.timeout_ms}ms",
      )
    err => raise err
  }
}

///|
/// 原生连接句柄：持有持久 TCP 连接与服务端握手信息。
pub struct NativeConnection {
  priv tcp : @socket.Tcp
  priv server : ServerHello
  priv config : NativeConfig
  /// 压缩模式（协商 compression=1 后 Data 块为 LZ4 压缩块）。
  priv compress : Bool
}

///|
/// 建立 TCP 连接并完成握手；任何阶段失败都会关闭 socket 并 raise `@lib.DbError`。
///
/// `config.timeout_ms > 0` 时整次建连 + 握手都受该超时约束。
pub async fn connect(config : NativeConfig) -> NativeConnection {
  config.with_timeout(() => connect_impl(config))
}

///|
async fn connect_impl(config : NativeConfig) -> NativeConnection {
  let addr = @socket.Addr::resolve(config.host, port=config.port) catch {
    err =>
      raise @lib.DbError::connection_error(
        "failed to resolve host \{config.host}: \{err}",
      )
  }
  let tcp = @socket.Tcp::connect(addr) catch {
    err =>
      raise @lib.DbError::connection_error(
        "failed to connect to \{config.host}:\{config.port}: \{err}",
      )
  }
  // 任何后续失败（握手/Addendum）都关闭 socket，避免泄露。
  errdefer tcp.close()
  let hello = build_hello(
    config.client_name,
    config.database,
    config.user,
    config.password,
  )
  flush_bytes(tcp, hello) catch {
    err => raise @lib.DbError::connection_error("failed to send hello: \{err}")
  }
  let ptype = read_varuint(tcp)
  let server = match ServerPacket::from_int(ptype.to_int()) {
    Hello => read_server_hello(tcp)
    Exception => raise read_exception(tcp)
    _ =>
      raise @lib.DbError::connection_error(
        "unexpected packet type during handshake: \{ptype}",
      )
  }
  // ClickHouse 25.x 要求握手后发送 Addendum（quota_key）
  flush_bytes(tcp, build_addendum()) catch {
    err =>
      raise @lib.DbError::connection_error(
        "failed to send handshake addendum: \{err}",
      )
  }
  { tcp, server, config, compress: config.compress, }
}

///|
/// 服务器版本字符串（`major.minor.patch`），可用于诊断与协议分支判断。
pub fn NativeConnection::server_version(self : NativeConnection) -> String {
  "\{self.server.version_major}.\{self.server.version_minor}.\{self.server.version_patch}"
}

///|
/// 服务器时区（握手返回的 IANA 时区名，如 `Asia/Shanghai`）。
pub fn NativeConnection::server_timezone(self : NativeConnection) -> String {
  self.server.timezone
}

///|
/// 往返健康检查：发送 Ping 包并等待 Pong。
/// 失败 raise `@lib.DbError`；受 `timeout_ms` 约束。
pub async fn NativeConnection::ping(self : NativeConnection) -> Unit {
  self.config.with_timeout(() => self.ping_impl())
}

///|
async fn NativeConnection::ping_impl(self : NativeConnection) -> Unit {
  let buf = Buffer::Buffer()
  write_varuint(buf, ClientPacket::Ping.to_int().to_uint64())
  flush_bytes(self.tcp, buf.to_bytes())
  let ptype = read_varuint(self.tcp).to_int()
  match ServerPacket::from_int(ptype) {
    Pong => ()
    Exception => raise read_exception(self.tcp)
    _ =>
      raise @lib.DbError::connection_error(
        "unexpected packet type in ping: \{ptype}",
      )
  }
}

///|
/// 发送取消包中断当前查询（若连接上存在未完成的查询）。
pub async fn NativeConnection::cancel(self : NativeConnection) -> Unit {
  let buf = Buffer::Buffer()
  write_varuint(buf, ClientPacket::Cancel.to_int().to_uint64())
  flush_bytes(self.tcp, buf.to_bytes())
}

///|
/// 关闭底层 TCP 连接。
pub fn NativeConnection::close(self : NativeConnection) -> Unit {
  self.tcp.close()
}
