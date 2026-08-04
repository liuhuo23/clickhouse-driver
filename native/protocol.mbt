///|
/// ClickHouse 原生 TCP 协议基础层：包类型、版本常量与二进制编解码原语。
///
/// 编码统一写入 `Buffer`（构建整条消息后一次性 flush 到 socket）；
/// 解码提供两类入口：
///   - 纯函数 `decode_*`：从内存 `Bytes` 解析（可单元测试）
///   - async 原语 `read_*`：从任意 `@io.Reader`（Tcp / pipe）读取，复用纯函数解析
///
/// 约定：协议出错统一 raise `@lib.ConnectionError`，与 HTTP 版错误语义一致。

// ============ 协议常量 ============

///|
/// 客户端声明的协议修订号（ClickHouse `DBMS_MIN_REVISION` 系列）。
/// 54460 覆盖 ClientInfo / ServerTimezone / DisplayName / VersionPatch /
/// ServerLogs，与 ClickHouse 24.8 / 25.x 均兼容。
const CLIENT_REVISION : UInt64 = 54460

///|
/// 客户端版本（major/minor，随 Hello 包发送）。
const CLIENT_VERSION_MAJOR : UInt64 = 1

///|
const CLIENT_VERSION_MINOR : UInt64 = 0

///|
/// 客户端 → 服务器包类型。
priv enum ClientPacket {
  Hello
  Query
  Data
  Cancel
  Ping
}

///|
fn ClientPacket::to_int(self : ClientPacket) -> Int {
  match self {
    Hello => 0
    Query => 1
    Data => 2
    Cancel => 9
    Ping => 4
  }
}

///|
/// 服务器 → 客户端包类型。
priv enum ServerPacket {
  Hello
  Data
  Exception
  Progress
  Pong
  EndOfStream
  ProfileInfo
  Totals
  Extremes
  Log
  ProfileEvents
  TableColumns
}

///|
fn ServerPacket::from_int(v : Int) -> ServerPacket raise {
  match v {
    0 => Hello
    1 => Data
    2 => Exception
    3 => Progress
    4 => Pong
    5 => EndOfStream
    6 => ProfileInfo
    7 => Totals
    8 => Extremes
    10 => Log
    11 => TableColumns
    14 => ProfileEvents
    _ =>
      raise @lib.DbError::connection_error("unknown server packet type: \{v}")
  }
}

// ============ 编码（写） ============

///|
/// 写入 VarUInt（无符号 LEB128）。
fn write_varuint(buf : Buffer, v : UInt64) -> Unit {
  buf.write_leb128(v)
}

///|
/// 写入带长度前缀的字符串（VarUInt 长度 + UTF-8 字节）。
fn write_string(buf : Buffer, s : String) -> Unit {
  let bytes = @utf8.encode(s)
  buf.write_leb128(bytes.length().to_uint64())
  buf.write_bytes(bytes)
}

///|
/// 写入 16 位小端无符号整数。
fn write_uint16(buf : Buffer, v : UInt16) -> Unit {
  buf.write_uint16_le(v)
}

///|
/// 写入 32 位小端无符号整数（MoonBit 无 UInt32 类型，用 UInt 的低 32 位表达）。
fn write_uint32(buf : Buffer, v : UInt) -> Unit {
  buf.write_byte((v & 0xFF).to_byte())
  buf.write_byte(((v >> 8) & 0xFF).to_byte())
  buf.write_byte(((v >> 16) & 0xFF).to_byte())
  buf.write_byte(((v >> 24) & 0xFF).to_byte())
}

///|
/// 写入 32 位小端有符号整数（补码）。
fn write_int32(buf : Buffer, v : Int) -> Unit {
  write_uint32(buf, v.reinterpret_as_uint())
}

///|
/// 写入 64 位小端无符号整数。
fn write_uint64(buf : Buffer, v : UInt64) -> Unit {
  buf.write_uint64_le(v)
}

///|
/// 写入 64 位小端有符号整数。
fn write_int64(buf : Buffer, v : Int64) -> Unit {
  buf.write_int64_le(v)
}

///|
/// 写入 32 位小端 IEEE-754 单精度浮点。
fn write_float32(buf : Buffer, v : Float) -> Unit {
  buf.write_float_le(v)
}

///|
/// 写入 64 位小端 IEEE-754 双精度浮点。
fn write_float64(buf : Buffer, v : Double) -> Unit {
  buf.write_double_le(v)
}

// ============ 解码（读，纯函数） ============

///|
/// 从 `bytes[offset:]` 解析一个 VarUInt，返回 `(值, 新 offset)`。
/// 最多 10 字节；字节不足或溢出抛 `ConnectionError`。
fn decode_varuint(bytes : Bytes, offset : Int) -> (UInt64, Int) raise {
  let mut result : UInt64 = 0
  let mut shift = 0
  let mut i = offset
  while i < bytes.length() {
    let b = bytes[i].to_uint64()
    result = result | ((b & 0x7F) << shift)
    if (b & 0x80) == 0 {
      return (result, i + 1)
    }
    shift = shift + 7
    if shift >= 64 {
      raise @lib.DbError::connection_error("varuint overflow")
    }
    i = i + 1
  }
  raise @lib.DbError::connection_error("unexpected EOF decoding varuint")
}

///|
/// 从 `bytes[offset:]` 解析 16 位小端无符号整数。
fn decode_uint16(bytes : Bytes, offset : Int) -> (UInt16, Int) raise {
  if offset + 2 > bytes.length() {
    raise @lib.DbError::connection_error("unexpected EOF decoding uint16")
  }
  let v = bytes[offset].to_uint() | (bytes[offset + 1].to_uint() << 8)
  (v.to_uint16(), offset + 2)
}

///|
/// 从 `bytes[offset:]` 解析 32 位小端无符号整数。
fn decode_uint32(bytes : Bytes, offset : Int) -> (UInt, Int) raise {
  if offset + 4 > bytes.length() {
    raise @lib.DbError::connection_error("unexpected EOF decoding uint32")
  }
  let v = bytes[offset].to_uint() |
    (bytes[offset + 1].to_uint() << 8) |
    (bytes[offset + 2].to_uint() << 16) |
    (bytes[offset + 3].to_uint() << 24)
  (v, offset + 4)
}

///|
/// 从 `bytes[offset:]` 解析 32 位小端有符号整数（补码符号扩展）。
fn decode_int32(bytes : Bytes, offset : Int) -> (Int, Int) raise {
  let (u, pos) = decode_uint32(bytes, offset)
  (u.reinterpret_as_int(), pos)
}

///|
/// 从 `bytes[offset:]` 解析 64 位小端无符号整数。
fn decode_uint64(bytes : Bytes, offset : Int) -> (UInt64, Int) raise {
  if offset + 8 > bytes.length() {
    raise @lib.DbError::connection_error("unexpected EOF decoding uint64")
  }
  let mut v : UInt64 = 0
  for i in 0..<8 {
    v = v | (bytes[offset + i].to_uint64() << (i * 8))
  }
  (v, offset + 8)
}

///|
/// 从 `bytes[offset:]` 解析 64 位小端有符号整数。
fn decode_int64(bytes : Bytes, offset : Int) -> (Int64, Int) raise {
  let (u, pos) = decode_uint64(bytes, offset)
  (u.reinterpret_as_int64(), pos)
}

///|
/// 从 `bytes[offset:]` 解析 32 位小端单精度浮点（IEEE-754）。
fn decode_float32(bytes : Bytes, offset : Int) -> (Float, Int) raise {
  let (u, pos) = decode_uint32(bytes, offset)
  (Float::reinterpret_from_uint(u), pos)
}

///|
/// 从 `bytes[offset:]` 解析 64 位小端双精度浮点（IEEE-754）。
fn decode_float64(bytes : Bytes, offset : Int) -> (Double, Int) raise {
  let (u, pos) = decode_uint64(bytes, offset)
  (u.reinterpret_as_double(), pos)
}

// ============ 解码（读，async 原语） ============

///|
/// 从 reader 读取一个 VarUInt（逐字节收集后交给纯函数解析）。
pub async fn[R : @io.Reader] read_varuint(reader : R) -> UInt64 {
  let buf = Buffer::Buffer()
  while true {
    let b = reader.read_exactly(1)
    buf.write_bytes(b)
    if (b[0].to_uint64() & 0x80) == 0 {
      break
    }
    if buf.length() >= 10 {
      raise @lib.DbError::connection_error("varuint too long")
    }
  }
  let bytes = buf.to_bytes()
  let (v, _) = decode_varuint(bytes, 0)
  v
}

///|
/// 从 reader 读取带长度前缀的字符串。
pub async fn[R : @io.Reader] read_string(reader : R) -> String {
  let len = read_varuint(reader)
  if len > 0x40000000 {
    raise @lib.DbError::connection_error("string too long: \{len} bytes")
  }
  let bytes = reader.read_exactly(len.to_int())
  @utf8.decode(bytes)
}

///|
/// 从 reader 读取 16 位小端无符号整数。
pub async fn[R : @io.Reader] read_uint16(reader : R) -> UInt16 {
  let bytes = reader.read_exactly(2)
  let (v, _) = decode_uint16(bytes, 0)
  v
}

///|
/// 从 reader 读取 32 位小端无符号整数。
pub async fn[R : @io.Reader] read_uint32(reader : R) -> UInt {
  let bytes = reader.read_exactly(4)
  let (v, _) = decode_uint32(bytes, 0)
  v
}

///|
/// 从 reader 读取 32 位小端有符号整数。
pub async fn[R : @io.Reader] read_int32(reader : R) -> Int {
  let bytes = reader.read_exactly(4)
  let (v, _) = decode_int32(bytes, 0)
  v
}

///|
/// 从 reader 读取 64 位小端无符号整数。
pub async fn[R : @io.Reader] read_uint64(reader : R) -> UInt64 {
  let bytes = reader.read_exactly(8)
  let (v, _) = decode_uint64(bytes, 0)
  v
}

///|
/// 从 reader 读取 64 位小端有符号整数。
pub async fn[R : @io.Reader] read_int64(reader : R) -> Int64 {
  let bytes = reader.read_exactly(8)
  let (v, _) = decode_int64(bytes, 0)
  v
}

///|
/// 从 reader 读取 32 位小端单精度浮点。
pub async fn[R : @io.Reader] read_float32(reader : R) -> Float {
  let bytes = reader.read_exactly(4)
  let (v, _) = decode_float32(bytes, 0)
  v
}

///|
/// 从 reader 读取 64 位小端双精度浮点。
pub async fn[R : @io.Reader] read_float64(reader : R) -> Double {
  let bytes = reader.read_exactly(8)
  let (v, _) = decode_float64(bytes, 0)
  v
}

// ============ 通用 IO 辅助 ============

///|
/// 将 `Buffer` 内容一次性完整写入 writer；部分写失败抛 `ConnectionError`。
pub async fn[W : @io.Writer] flush_bytes(writer : W, bytes : Bytes) -> Unit {
  let mut written = 0
  while written < bytes.length() {
    let n = writer.write_once(
      bytes,
      offset=written,
      len=bytes.length() - written,
    )
    if n == 0 {
      raise @lib.DbError::connection_error("failed to write to socket")
    }
    written = written + n
  }
}
