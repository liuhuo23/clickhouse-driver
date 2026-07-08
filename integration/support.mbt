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
