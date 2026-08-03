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
  port : Int
  user : String
  password : String
  database : String
  client_name : String
  /// 每次读写超时（毫秒）；`0` = 无超时（默认）。当前阶段未生效，后续阶段接入。
  timeout_ms : Int
}

///|
/// 从显式参数构建 `NativeConfig`（不建立连接）。
///
/// 可选参数：`database` 默认 `"default"`，`client_name` 默认
/// `"moonbit-clickhouse-native"`，`timeout_ms` 默认 `0`（无超时）。
pub fn native_config(
  host~ : String,
  port? : Int = 9000,
  user~ : String,
  password~ : String,
  database? : String = "default",
  client_name? : String = "moonbit-clickhouse-native",
  timeout_ms? : Int = 0,
) -> NativeConfig {
  { host, port, user, password, database, client_name, timeout_ms }
}

///|
/// 原生连接句柄：持有持久 TCP 连接与服务端握手信息。
pub struct NativeConnection {
  priv tcp : @socket.Tcp
  priv server : ServerHello
  priv config : NativeConfig
}

///|
/// 建立 TCP 连接并完成握手；任何阶段失败都会关闭 socket 并 raise `@lib.DbError`。
pub async fn connect(config : NativeConfig) -> NativeConnection {
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
  let hello = build_hello(
    config.client_name,
    config.database,
    config.user,
    config.password,
  )
  flush_bytes(tcp, hello) catch {
    err => {
      tcp.close()
      raise @lib.DbError::connection_error("failed to send hello: \{err}")
    }
  }
  let server = try {
    let ptype = read_varuint(tcp)
    match ServerPacket::from_int(ptype.to_int()) {
      Hello => read_server_hello(tcp)
      Exception => raise read_exception(tcp)
      _ =>
        raise @lib.DbError::connection_error(
          "unexpected packet type during handshake: \{ptype}",
        )
    }
  } catch {
    err => {
      tcp.close()
      raise err
    }
  }
  // ClickHouse 25.x 要求握手后发送 Addendum（quota_key）
  flush_bytes(tcp, build_addendum()) catch {
    err => {
      tcp.close()
      raise @lib.DbError::connection_error(
        "failed to send handshake addendum: \{err}",
      )
    }
  }
  { tcp, server, config }
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
/// 失败 raise `@lib.DbError`。
pub async fn NativeConnection::ping(self : NativeConnection) -> Unit {
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
