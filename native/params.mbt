///|
/// 写 Query 参数表：`name + u8(flags=CUSTOM) + value` 对 + 空串结束。
/// value 以带引号的 SQL 字面量形式发送（服务器端按 Field dump 解析）。
fn write_params(buf : Buffer, params : Map[String, String]) -> Unit {
  for entry in params.to_array() {
    write_string(buf, entry.0)
    buf.write_byte(0x2) // SettingsFlags::CUSTOM
    write_string(buf, escape_param_value(entry.1))
  }
  write_string(buf, "") // 结束
}

///|
/// 把参数值转义为服务器端 Field dump 格式（单引号包裹 + 特殊字符转义）。
/// 与官方客户端 `escape_param(for_server=True)` 行为一致。
fn escape_param_value(v : String) -> String {
  let bytes = @utf8.encode(v)
  let buf = Buffer::Buffer(size_hint=bytes.length() * 2)
  buf.write_byte(b'\'')
  for b in bytes {
    match b {
      b'\\' => buf.write_bytes(b"\\\\")
      b'\'' => buf.write_bytes(b"\\'")
      b'\n' => buf.write_bytes(b"\\n")
      b'\r' => buf.write_bytes(b"\\r")
      b'\t' => buf.write_bytes(b"\\t")
      b'\x00' => buf.write_bytes(b"\\0")
      _ => buf.write_byte(b)
    }
  }
  buf.write_byte(b'\'')
  @utf8.decode_lossy(buf.to_bytes())
}

///|
/// 位置参数执行：SQL 中每个 `?` 依次绑定 `values` 中的值（以 String 类型
/// 绑定，由服务器端做类型转换）。与 HTTP 版 `Connection::execute` 对齐。
pub async fn NativeConnection::execute(
  self : NativeConnection,
  sql : String,
  values : Array[String],
) -> @lib.ResultSet {
  let (processed_sql, param_map) = @internal.bind_positional(sql, values)
  self.execute_query(
    @internal.apply_default_types(processed_sql),
    params=param_map,
  )
}
