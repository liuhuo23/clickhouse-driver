///|
/// 服务器 Exception 包解析，映射为根包 `DbError::ServerError`。
///
/// 包格式：`code:Int32, name:String, message:String, stack_trace:String,
/// has_nested:UInt8`。嵌套异常（`has_nested=1`）递归读取但仅保留最外层信息。

///|
/// 从 reader 读取 Exception 包并映射为 `@lib.DbError::ServerError`。
pub async fn[R : @io.Reader] read_exception(reader : R) -> @lib.DbError {
  let code_bytes = reader.read_exactly(4)
  let (code, _) = decode_int32(code_bytes, 0)
  let name = read_string(reader)
  let message = read_string(reader)
  ignore(read_string(reader)) // stack_trace（基础版本不保留）
  let nested_bytes = reader.read_exactly(1)
  if nested_bytes[0].to_int() != 0 {
    // 嵌套异常：继续消费字节流（基础版本只保留最外层信息）
    ignore(read_exception(reader))
  }
  @lib.DbError::server_error(code~, name~, message~)
}
