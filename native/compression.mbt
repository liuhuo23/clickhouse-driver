///|
/// LZ4 压缩支持：ClickHouse 原生协议 C++ 压缩块格式。
///
/// 压缩块布局（CompressedWriteBuffer）：
///   checksum(16B CityHash128) + compressed_size(4B LE) +
///   uncompressed_size(4B LE) + method(1B) + 压缩数据
/// 方法字节：0x82 = LZ4（标准 LZ4 block 格式），0x02 = None（明文），
/// 0x90 = ZSTD（暂不支持）。
///
/// 仅 Data / Totals / Extremes 包使用压缩；Exception / Progress /
/// ProfileInfo / ProfileEvents / Log / EndOfStream 始终明文。

///|
/// LZ4 block 解压（标准 LZ4 block 格式，与 ClickHouse LZ4_compress_default
/// 输出兼容）。
fn lz4_decompress(src : Bytes, expected : Int32) -> Bytes raise {
  let out : Array[Byte] = []
  let mut ip = 0
  while ip < src.length() {
    let token = src[ip].to_uint()
    ip = ip + 1
    let mut lit_len = (token >> 4).reinterpret_as_int()
    if lit_len == 15 {
      while true {
        let b = src[ip].to_uint()
        ip = ip + 1
        lit_len = lit_len + b.reinterpret_as_int()
        if b != 255 {
          break
        }
      }
    }
    if ip + lit_len > src.length() {
      raise @lib.DbError::connection_error("lz4: literal out of range")
    }
    for i in 0..<lit_len {
      out.push(src[ip + i])
    }
    ip = ip + lit_len
    if ip >= src.length() {
      break // 最后一段（无匹配）
    }
    if ip + 2 > src.length() {
      raise @lib.DbError::connection_error("lz4: truncated match offset")
    }
    let offset = src[ip].to_uint() | (src[ip + 1].to_uint() << 8)
    ip = ip + 2
    if offset == 0 {
      raise @lib.DbError::connection_error("lz4: zero offset")
    }
    let mut match_len = (token & 0xF).reinterpret_as_int() + 4
    if (token & 0xF) == 15 {
      while true {
        let b = src[ip].to_uint()
        ip = ip + 1
        match_len = match_len + b.reinterpret_as_int()
        if b != 255 {
          break
        }
      }
    }
    let start = out.length() - offset.reinterpret_as_int()
    if start < 0 {
      raise @lib.DbError::connection_error("lz4: offset before start")
    }
    // 重叠复制（LZ4 允许 match 与输出重叠）
    for i in 0..<match_len {
      out.push(out[start + i])
    }
  }
  if expected >= 0 && out.length() != expected {
    raise @lib.DbError::connection_error(
      "lz4: size mismatch got \{out.length()} expected \{expected}",
    )
  }
  Bytes::from_array(out)
}

///|
/// 读取一个压缩块并解压，返回原始字节。
/// `compression=false` 时直接原样读取（供非压缩模式复用）。
async fn[R : @io.Reader] read_payload(reader : R, compression : Bool) -> Bytes {
  if !compression {
    return read_string_bytes(reader)
  }
  ignore(reader.read_exactly(16)) // CityHash128 checksum（跳过验证）
  let comp_method = reader.read_exactly(1)[0].to_uint()
  let comp_size = read_uint32(reader).reinterpret_as_int()
  let uncomp_size = read_uint32(reader).reinterpret_as_int()
  if comp_size < 9 || comp_size > 0x40000000 {
    raise @lib.DbError::connection_error(
      "invalid compressed block size: \{comp_size}",
    )
  }
  let data = reader.read_exactly(comp_size - 9)
  match comp_method {
    0x82 => lz4_decompress(data, uncomp_size)
    0x02 => data // None：明文（未压缩）
    0x90 =>
      raise @lib.DbError::connection_error(
        "ZSTD compression is not supported (method 0x90)",
      )
    _ =>
      raise @lib.DbError::connection_error(
        "unknown compression method: 0x\{comp_method.to_uint64().to_string(radix=16)}",
      )
  }
}

///|
/// 读取一个带长度前缀的字节串（与 read_string 类似但不要求 UTF-8）。
async fn[R : @io.Reader] read_string_bytes(reader : R) -> Bytes {
  let len = read_varuint(reader)
  if len > 0x40000000 {
    raise @lib.DbError::connection_error("payload too long: \{len} bytes")
  }
  reader.read_exactly(len.to_int())
}

///|
/// LZ4 字面量-only 压缩（合法 LZ4 block：token + 扩展长度 + 全部字面量）。
/// 压缩率较差但保证正确性；后续可替换为完整 LZ4 压缩器。
fn lz4_compress_literals(data : Bytes) -> Bytes {
  let out = Buffer::Buffer(size_hint=data.length() + 8)
  let len = data.length()
  if len < 15 {
    out.write_byte((len << 4).to_byte())
  } else {
    out.write_byte(0xF0)
    let mut remaining = len - 15
    while remaining >= 255 {
      out.write_byte(255)
      remaining = remaining - 255
    }
    out.write_byte(remaining.to_byte())
  }
  out.write_bytes(data)
  out.to_bytes()
}

///|
/// 构造 C++ 格式压缩块并写入 buf：
///   checksum(16B) + method(1B) + comp_size(4B LE) + uncomp_size(4B LE) + LZ4 数据
fn write_compressed_block(buf : Buffer, payload : Bytes) -> Unit {
  let lz = lz4_compress_literals(payload)
  let body = Buffer::Buffer(size_hint=9 + lz.length())
  body.write_byte(0x82) // LZ4
  write_uint32(body, (9 + lz.length()).reinterpret_as_uint())
  write_uint32(body, payload.length().reinterpret_as_uint())
  body.write_bytes(lz)
  let body_bytes = body.to_bytes()
  let (lo, hi) = city_hash128(body_bytes)
  write_uint64(buf, lo) // C++ low64 在前
  write_uint64(buf, hi)
  buf.write_bytes(body_bytes)
}
