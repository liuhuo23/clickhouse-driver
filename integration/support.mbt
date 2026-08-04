///|
/// Keep package imports referenced in non-test source to avoid unused warnings.
pub fn make_ci_conn(
  host~ : String,
  port~ : Int,
  user~ : String,
  password~ : String,
  database~ : String,
) -> @lib.Connection {
  @lib.connect(
    host~,
    port~,
    user~,
    password~,
    database~,
    client_name="moonbit-integration-support",
  )
}

///|
/// Marker for async package usage in this package.
pub fn async_runtime_loaded() -> Bool {
  @async.is_being_cancelled()
}

///|
/// Marker for native package usage in this package (native integration tests
/// are the only consumers; this non-test reference keeps the import alive).
pub fn native_runtime_loaded() -> Bool {
  let cfg = @native.native_config(
    host="",
    port=0,
    user="",
    password="",
    database="",
  )
  cfg.host == "" && cfg.port == 0
}
