///|
/// Decompress a ClickHouse `compress=1` HTTP response body.
///
/// The body is a concatenation of blocks, each:
///   [16-byte CityHash128 checksum][9-byte header][compressed payload]
/// The checksum is skipped (not verified). The 9-byte header is:
///   method (1 byte) | compressed_size incl. header (4 LE) | raw_size (4 LE)
/// Methods: 0x02 = none, 0x82 = LZ4, 0x90 = ZSTD (unsupported).
fn decompress_clickhouse_body(body : Bytes) -> Bytes raise {
  let out = Buffer::Buffer(size_hint=body.length() * 2)
  let mut i = 0
  while i < body.length() {
    if body.length() - i < 16 + 9 {
      raise ConnectionError("truncated ClickHouse compressed block header")
    }
    let header = i + 16
    let compression = body[header].to_int()
    let comp_size = read_le_u32(body, header + 1)
    let raw_size = read_le_u32(body, header + 5)
    if comp_size < 9 || header + comp_size > body.length() {
      raise ConnectionError("invalid ClickHouse compressed block size")
    }
    let payload_start = header + 9
    let payload_len = comp_size - 9
    match compression {
      0x02 => {
        if raw_size > payload_len {
          raise ConnectionError("invalid uncompressed block size")
        }
        for k in 0..<raw_size {
          out.write_byte(body[payload_start + k])
        }
      }
      0x82 => {
        let block = lz4_decompress_block(
          body, payload_start, payload_len, raw_size,
        )
        out.write_bytes(block)
      }
      _ =>
        raise ConnectionError(
          "unsupported ClickHouse compression method: \{compression}",
        )
    }
    i = payload_start + payload_len
  }
  out.to_bytes()
}

///|
/// Read a little-endian UInt32 from a byte buffer.
fn read_le_u32(bytes : Bytes, start : Int32) -> Int32 {
  bytes[start].to_int() |
  (bytes[start + 1].to_int() << 8) |
  (bytes[start + 2].to_int() << 16) |
  (bytes[start + 3].to_int() << 24)
}

///|
/// Decompress one LZ4 *block* (no frame header) into exactly `raw_size` bytes.
/// `block` is the payload slice `[start, start + len)` of `bytes`.
///
/// LZ4 block sequence: token (high nibble = literal len, low nibble = match
/// len - 4), optional 0xFF extended lengths, literals, 2-byte LE match offset,
/// then the match (copied with overlap allowed).
fn lz4_decompress_block(
  bytes : Bytes,
  start : Int32,
  len : Int32,
  raw_size : Int32,
) -> Bytes raise {
  let out = FixedArray::make(raw_size, b'\x00')
  let mut out_len = 0
  let mut i = start
  let end = start + len
  while i < end {
    let token = bytes[i].to_int()
    i = i + 1
    // Literal length (0xFF extension while byte == 255).
    let mut lit_len = token >> 4
    if lit_len == 15 {
      while true {
        guard i < end else {
          raise ConnectionError("truncated LZ4 literal length")
        }
        let b = bytes[i].to_int()
        i = i + 1
        lit_len = lit_len + b
        if b != 255 {
          break
        }
      }
    }
    guard i + lit_len <= end else {
      raise ConnectionError("truncated LZ4 literals")
    }
    guard out_len + lit_len <= raw_size else {
      raise ConnectionError("LZ4 output overflow")
    }
    for k in 0..<lit_len {
      out[out_len + k] = bytes[i + k]
    }
    out_len = out_len + lit_len
    i = i + lit_len
    // Last sequence may be literals only.
    if i >= end {
      break
    }
    // Match offset (2 bytes LE).
    guard i + 2 <= end else {
      raise ConnectionError("truncated LZ4 match offset")
    }
    let offset = bytes[i].to_int() | (bytes[i + 1].to_int() << 8)
    i = i + 2
    guard offset > 0 else { raise ConnectionError("invalid LZ4 match offset") }
    // Match length (0xFF extension while byte == 255).
    let mut match_len = (token & 0x0F) + 4
    if (token & 0x0F) == 15 {
      while true {
        guard i < end else {
          raise ConnectionError("truncated LZ4 match length")
        }
        let b = bytes[i].to_int()
        i = i + 1
        match_len = match_len + b
        if b != 255 {
          break
        }
      }
    }
    guard offset <= out_len else {
      raise ConnectionError("LZ4 match before start")
    }
    guard out_len + match_len <= raw_size else {
      raise ConnectionError("LZ4 output overflow")
    }
    let match_start = out_len - offset
    for k in 0..<match_len {
      out[out_len] = out[match_start + k]
      out_len = out_len + 1
    }
  }
  guard out_len == raw_size else { raise ConnectionError("LZ4 size mismatch") }
  out.unsafe_reinterpret_as_bytes()
}
