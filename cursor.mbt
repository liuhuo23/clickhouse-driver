///|
/// Streaming cursor returned by `Connection::execute_stream`.
///
/// The HTTP response body is consumed lazily, one row at a time, so queries
/// with large result sets do not need to be buffered in memory. Always call
/// `close()` when done to release the underlying connection.
///
/// `columns()` is available immediately after the cursor is created; rows are
/// read with repeated `next()` calls (returns `None` at end of stream).
pub struct ResultSetCursor {
  priv client : @http.Client
  priv cols : Array[Column]
  priv timeout_ms : Int32
  /// Owning pool (if streamed through a `ConnectionPool`); `None` means the
  /// cursor owns its connection directly.
  priv pool : ConnectionPool?
  /// Single-element cell: `true` once `next()` has reached end-of-stream, so
  /// `close()` knows whether the connection can be reused or must be dropped.
  /// (Array is a reference type — the flag survives value copies of the cursor.)
  priv exhausted : Array[Bool]
}

///|
/// The columns (name + type) of the streamed query result.
pub fn ResultSetCursor::columns(self : ResultSetCursor) -> Array[Column] {
  self.cols
}

///|
/// Read the next row from the stream, or `None` at end of stream.
///
/// If the connection was configured with a positive `timeout_ms`, each `next()`
/// call is bounded by that timeout; a timeout raises `ConnectionError`.
pub async fn ResultSetCursor::next(self : ResultSetCursor) -> Row? {
  let mut result : Row? = None
  while true {
    let line : String? = if self.timeout_ms > 0 {
      @async.with_timeout(self.timeout_ms, () => self.client.read_until("\n")) catch {
        @async.TimeoutError =>
          raise ConnectionError(
            "stream read timed out after \{self.timeout_ms}ms",
          )
        err => raise err
      }
    } else {
      self.client.read_until("\n")
    }
    match line {
      None => {
        self.exhausted[0] = true
        break
      }
      Some(line) => {
        // Skip empty trailing lines (same rule as the buffered parser).
        let line = strip_cr(line)
        if line.length() == 0 {
          continue
        }
        let values = split_tsv_line(line)
        result = Some({ values, })
        break
      }
    }
  }
  result
}

///|
/// Close the streaming cursor and release the underlying connection.
///
/// For cursors created through a `ConnectionPool`, a fully-drained stream
/// returns the connection to the pool for reuse; a partially-read stream
/// drops the connection (the server may still be streaming data).
/// Idempotent — safe to call multiple times.
pub fn ResultSetCursor::close(self : ResultSetCursor) -> Unit {
  match self.pool {
    None => self.client.close()
    Some(pool) =>
      if self.exhausted[0] {
        pool.release(self.client)
      } else {
        pool.discard(self.client)
      }
  }
}
