///|
/// 握手层：客户端 Hello 包构造、服务器 Hello 解析。

///|
/// 服务器 Hello 信息（握手成功后的服务端元数据）。
struct ServerHello {
  version_major : UInt64
  version_minor : UInt64
  timezone : String
  version_patch : UInt64
}

///|
/// 构造客户端 Hello 包字节（含包类型头）。
fn build_hello(
  client_name : String,
  database : String,
  user : String,
  password : String,
) -> Bytes {
  let buf = Buffer::Buffer()
  write_varuint(buf, ClientPacket::Hello.to_int().to_uint64())
  write_string(buf, client_name)
  write_varuint(buf, CLIENT_VERSION_MAJOR)
  write_varuint(buf, CLIENT_VERSION_MINOR)
  write_varuint(buf, CLIENT_REVISION)
  write_string(buf, database)
  write_string(buf, user)
  write_string(buf, password)
  buf.to_bytes()
}

///|
/// 从 reader 读取并解析服务器 Hello 包。
/// 额外字段按服务器返回的 revision 条件读取。
async fn[R : @io.Reader] read_server_hello(reader : R) -> ServerHello {
  ignore(read_string(reader)) // name（未使用）
  let major = read_varuint(reader)
  let minor = read_varuint(reader)
  let revision = read_varuint(reader)
  let mut timezone = ""
  let mut version_patch : UInt64 = 0
  if revision >= 54058 {
    timezone = read_string(reader)
  }
  if revision >= 54372 {
    ignore(read_string(reader)) // display_name（未使用）
  }
  if revision >= 54401 {
    version_patch = read_varuint(reader)
  }
  { version_major: major, version_minor: minor, timezone, version_patch, }
}

///|
/// 构造握手附加段（Addendum）。ClickHouse 25.x（客户端 revision >= 54458）要求
/// 客户端在 Hello 交换后继续发送 quota_key；revision >= 54470 时还需声明
/// chunked 协议能力、>= 54471 时声明 parallel replicas 协议版本。
/// 当前 CLIENT_REVISION=54460，因此仅发送空 quota_key。
fn build_addendum() -> Bytes {
  let buf = Buffer::Buffer()
  if CLIENT_REVISION >= 54458 {
    write_string(buf, "") // quota_key
  }
  buf.to_bytes()
}
