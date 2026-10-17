///|
fn bytes_to_string(bytes : Bytes, start : Int32, end : Int32) -> String {
  let buf = Buffer::Buffer(size_hint=end - start)
  for i in start..<end {
    buf.write_byte(bytes[i])
  }
  @utf8.decode_lossy(buf.to_bytes())
}

///|
fn buf_to_string(buf : Buffer) -> String {
  @utf8.decode_lossy(buf.to_bytes())
}

///|
/// Extract a substring `[start, end)` from a String, indexed by UTF-16 code
/// unit and clamped to valid character boundaries.
fn substr(s : String, start : Int32, end : Int32) -> String {
  if start >= end || start < 0 {
    return ""
  }
  let s_len = s.length()
  let real_end = if end > s_len { s_len } else { end }
  let real_start = if start > s_len { s_len } else { start }
  s[real_start:real_end].to_owned()
}
