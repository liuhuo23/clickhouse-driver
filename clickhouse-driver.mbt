///|
/// ClickHouse native TCP protocol driver for MoonBit.
/// Supports rev 54429 (handshake + query + response parsing).

///|
/// Client protocol revision (negotiated = min(client, server)).
const CLIENT_REVISION : UInt = 54429U

// ============ Public data types ============

///|
/// Column metadata returned from a query.
pub struct Column {
  name : String
  type_ : String
}

///|
/// A single row of query results. Each value is a string representation.
pub struct Row {
  values : Array[String]
}

///|
/// Complete result set containing column metadata and rows.
pub struct ResultSet {
  columns : Array[Column]
  rows : Array[Row]
}

///| Convert result to column_name → values map.
pub fn ResultSet::to_map(self : ResultSet) -> Map[String, Array[String]] {
  let map : Map[String, Array[String]] = Map::new()
  for i in 0..<self.columns.length() {
    let col_name = self.columns[i].name
    let vals : Array[String] = []
    for r in 0..<self.rows.length() {
      vals.push(self.rows[r].values[i])
    }
    map.set(col_name, vals)
  }
  map
}

///|
/// Connection to ClickHouse server.
pub struct Connection {
  tcp : @socket.Tcp
  server_rev : UInt
  user : String
  client_name : String
}

// ============ Write helpers ============

///|
/// VarUInt (LEB128) encoder.
fn write_varuint(buf : Buffer, value : UInt) -> Unit {
  let mut v = value
  while v >= 128U {
    buf.write_byte(v.land(127U).to_byte() | b'\x80')
    v = v >> 7
  }
  buf.write_byte(v.to_byte())
}

///|
/// String binary: varuint length + UTF-8 bytes.
fn write_string_binary(buf : Buffer, s : String) -> Unit {
  let bytes = @utf8.encode(s)
  write_varuint(buf, bytes.length().reinterpret_as_uint())
  buf.write_bytes(bytes)
}

///|
/// Write a single byte (UInt8).
fn write_uint8(buf : Buffer, value : UInt) -> Unit {
  buf.write_byte(value.to_byte())
}

///|
/// Write Int32 little-endian (for BlockInfo bucket_num).
fn write_int32_le(buf : Buffer, value : Int) -> Unit {
  let mut v = value
  for _i in 0..<4 {
    buf.write_byte(v.land(0xFF).to_byte())
    v = v >> 8
  }
}

// ============ Protocol builders ============

///|
fn build_client_hello(
  client_name~ : String,
  version_major~ : UInt,
  version_minor~ : UInt,
  revision~ : UInt,
  default_database~ : String,
  user~ : String,
  password~ : String,
) -> Bytes {
  let buf = Buffer::Buffer(size_hint=128)
  write_varuint(buf, 0U)
  write_string_binary(buf, client_name)
  write_varuint(buf, version_major)
  write_varuint(buf, version_minor)
  write_varuint(buf, revision)
  write_string_binary(buf, default_database)
  write_string_binary(buf, user)
  write_string_binary(buf, password)
  buf.to_bytes()
}

///|
fn build_client_info(
  user~ : String,
  initial_address~ : String,
  client_name~ : String,
  rev~ : UInt,
) -> Bytes {
  let buf = Buffer::Buffer(size_hint=128)
  write_uint8(buf, 1U) // query_kind = InitialQuery
  write_string_binary(buf, user)
  write_string_binary(buf, "")
  write_string_binary(buf, initial_address)
  write_uint8(buf, 1U) // query_interface = TCP
  write_string_binary(buf, "")
  write_string_binary(buf, "")
  write_string_binary(buf, client_name)
  write_varuint(buf, 1U)
  write_varuint(buf, 0U)
  write_varuint(buf, rev)
  if rev >= 54060U {
    write_string_binary(buf, "")
  }
  if rev >= 54401U {
    write_varuint(buf, 0U)
  }
  buf.to_bytes()
}

///|
fn build_query(client_info~ : Bytes, sql~ : String) -> Bytes {
  let buf = Buffer::Buffer(size_hint=256)
  write_varuint(buf, 1U)
  write_string_binary(buf, "")
  buf.write_bytes(client_info)
  write_varuint(buf, 0U)
  write_varuint(buf, 2U)
  write_varuint(buf, 0U)
  write_string_binary(buf, sql)
  buf.to_bytes()
}

///|
fn build_empty_data() -> Bytes {
  let buf = Buffer::Buffer(size_hint=16)
  write_varuint(buf, 2U)
  write_varuint(buf, 0U)
  write_varuint(buf, 1U)
  write_uint8(buf, 0U)
  write_varuint(buf, 2U)
  write_int32_le(buf, -1)
  write_varuint(buf, 0U)
  write_varuint(buf, 0U)
  write_varuint(buf, 0U)
  buf.to_bytes()
}

// ============ Read helpers ============

///|
async fn read_varuint(conn : @socket.Tcp) -> UInt {
  let buf = FixedArray::make(1, b'\x00')
  let mut result : UInt = 0U
  let mut shift : Int = 0
  for _i in 0..<10 {
    let n = conn.read(buf)
    if n == 0 {
      abort("connection closed while reading varuint")
    }
    let byte = buf[0]
    let low7 = byte.to_int().land(0x7F).reinterpret_as_uint()
    result = result | (low7 << shift)
    if (byte.to_int() & 0x80) == 0 {
      break
    }
    shift = shift + 7
  }
  result
}

///|
async fn read_string_binary(conn : @socket.Tcp) -> String {
  let len = read_varuint(conn).reinterpret_as_int()
  let bytes = conn.read_exactly(len)
  @utf8.decode(bytes)
}

///|
async fn read_n_bytes(conn : @socket.Tcp, n : Int) -> FixedArray[Byte] {
  let buf = FixedArray::make(n, b'\x00')
  let mut got = 0
  while got < n {
    let r = conn.read(buf, offset=got, max_len=n - got)
    if r == 0 {
      abort("eof")
    }
    got = got + r
  }
  buf
}

///|
async fn read_uint16_le(conn : @socket.Tcp) -> UInt {
  let buf = read_n_bytes(conn, 2)
  buf[0].to_uint() | (buf[1].to_uint() << 8)
}

///|
async fn read_uint32_le(conn : @socket.Tcp) -> UInt64 {
  let buf = read_n_bytes(conn, 4)
  buf[0].to_uint64() |
  (buf[1].to_uint64() << 8) |
  (buf[2].to_uint64() << 16) |
  (buf[3].to_uint64() << 24)
}

///|
async fn read_uint64_le(conn : @socket.Tcp) -> UInt64 {
  let buf = read_n_bytes(conn, 8)
  let mut v : UInt64 = 0UL
  for i in 0..<8 {
    v = v | (buf[i].to_uint64() << (i * 8))
  }
  v
}

///|
async fn read_int32_le(conn : @socket.Tcp) -> Int {
  let buf = read_n_bytes(conn, 4)
  buf[0].to_int() |
  (buf[1].to_int() << 8) |
  (buf[2].to_int() << 16) |
  (buf[3].to_int() << 24)
}

// ============ ServerHello ============

///|
async fn read_server_hello(conn : @socket.Tcp) -> UInt {
  let _ = read_varuint(conn)
  let server_name = read_string_binary(conn)
  let major = read_varuint(conn).reinterpret_as_int()
  let minor = read_varuint(conn).reinterpret_as_int()
  let srv_rev = read_varuint(conn)
  let _ = if srv_rev >= 54058U { read_string_binary(conn) } else { "" }
  let _ = if srv_rev >= 54372U { read_string_binary(conn) } else { "" }
  if srv_rev >= 54401U {
    let _ = read_varuint(conn)
  }
  println(
    "Connected to " +
    server_name +
    " v" +
    major.to_string() +
    "." +
    minor.to_string(),
  )
  srv_rev
}

// ============ Block parsing ============

///|
/// Skip BlockInfo tagged stream.
async fn skip_block_info(conn : @socket.Tcp) -> Unit {
  let mut tag = read_varuint(conn)
  while tag != 0U {
    if tag == 1U {
      let _ = read_varuint(conn)
    } else if tag == 2U {
      let _ = read_int32_le(conn)
    } else if tag == 3U {
      let n = read_varuint(conn).reinterpret_as_int()
      for _i in 0..<n {
        let _ = read_int32_le(conn)
      }
    } else {
      tag = 0U
    }
    tag = read_varuint(conn)
  }
}

///|
/// Read a single column value as string based on type.
async fn read_value(conn : @socket.Tcp, typ : String) -> String {
  if typ == "UInt8" {
    read_varuint(conn).to_string()
  } else if typ == "Int8" {
    read_varuint(conn).reinterpret_as_int().to_string()
  } else if typ == "UInt16" {
    read_uint16_le(conn).to_string()
  } else if typ == "Int16" {
    read_uint16_le(conn).reinterpret_as_int().to_string()
  } else if typ == "UInt32" {
    read_uint32_le(conn).to_string()
  } else if typ == "Int32" {
    read_int32_le(conn).to_string()
  } else if typ == "UInt64" {
    read_uint64_le(conn).to_string()
  } else if typ == "Int64" {
    read_uint64_le(conn).reinterpret_as_int64().to_string()
  } else if typ == "Float32" {
    let _ = read_n_bytes(conn, 4)
    "<float32>"
  } else if typ == "Float64" {
    let _ = read_n_bytes(conn, 8)
    "<float64>"
  } else if typ == "String" {
    read_string_binary(conn)
  } else {
    // fallback: try to read as string
    read_string_binary(conn)
  }
}

///|
/// Parse one Data packet. Returns (columns, rows).
/// For schema blocks (0 rows): returns (columns, []).
/// For data blocks: returns ([], rows).
async fn parse_data_block(conn : @socket.Tcp) -> (Array[Column], Array[Row]) {
  let _ = read_string_binary(conn) // temp_table
  skip_block_info(conn)
  let num_cols = read_varuint(conn).reinterpret_as_int()
  let num_rows = read_varuint(conn).reinterpret_as_int()

  // Read column definitions
  let cols : Array[Column] = []
  let col_types : Array[String] = []
  for _c in 0..<num_cols {
    let name = read_string_binary(conn)
    let typ = read_string_binary(conn)
    cols.push({ name, type_: typ })
    col_types.push(typ)
  }

  // Read row data (if any)
  let rows : Array[Row] = []
  for _r in 0..<num_rows {
    let values : Array[String] = []
    for _c in 0..<num_cols {
      let v = read_value(conn, col_types[_c])
      values.push(v)
    }
    rows.push({ values, })
  }

  if num_rows == 0 {
    (cols, [])
  } else {
    ([], rows)
  }
}

// ============ Response reader ============

///|
/// Read all response packets, return ResultSet.
async fn read_response(conn : @socket.Tcp) -> ResultSet {
  let mut columns : Array[Column] = []
  let rows : Array[Row] = []
  let mut ok = true
  while ok {
    let pkt = read_varuint(conn).reinterpret_as_int()
    if pkt == 1 {
      // Server::Data
      let (new_cols, new_rows) = parse_data_block(conn)
      if new_cols.length() > 0 {
        columns = new_cols
      }
      for i in 0..<new_rows.length() {
        rows.push(new_rows[i])
      }
    } else if pkt == 2 {
      // Server::Exception
      let code = read_int32_le(conn)
      let name = read_string_binary(conn)
      let message = read_string_binary(conn)
      let _ = read_string_binary(conn)
      let _ = read_varuint(conn)
      abort(
        "Exception: code=" + code.to_string() + ", " + name + ": " + message,
      )
    } else if pkt == 3 {
      // Progress — skip
      let _ = read_varuint(conn)
      let _ = read_varuint(conn)
      let _ = read_varuint(conn)
      let _ = read_varuint(conn)
      let _ = read_varuint(conn)
      let _ = read_varuint(conn)
    } else if pkt == 4 {
      // Pong
    } else if pkt == 5 {
      // EndOfStream
      let _ = read_varuint(conn)
      let _ = read_varuint(conn)
      let _ = read_varuint(conn)
      ok = false
    } else if pkt == 6 {
      // ProfileInfo — skip
      let _ = read_varuint(conn)
      let _ = read_varuint(conn)
      let _ = read_varuint(conn)
      let _ = read_varuint(conn)
    } else {
      ok = false
    }
  }
  { columns, rows }
}

// ============ Public API ============

///|
/// Connect to a ClickHouse server, perform the handshake.
pub async fn connect(
  host~ : String,
  port~ : Int,
  user~ : String,
  password~ : String,
  database~ : String,
  client_name~ : String,
) -> Connection {
  let addr = @socket.Addr::parse(host + ":" + port.to_string())
  let tcp = @socket.Tcp::connect(addr)

  let hello = build_client_hello(
    client_name~,
    version_major=1U,
    version_minor=0U,
    revision=CLIENT_REVISION,
    default_database=database,
    user~,
    password~,
  )
  tcp.write(hello)

  let srv_rev = read_server_hello(tcp)

  { tcp, server_rev: srv_rev, user, client_name }
}

///|
/// Close the connection.
pub fn Connection::close(self : Connection) -> Unit {
  self.tcp.close()
}

///|
/// Execute a SQL query and return the parsed results.
pub async fn Connection::execute_query(
  self : Connection,
  sql : String,
) -> ResultSet {
  let client_info = build_client_info(
    user=self.user,
    initial_address="127.0.0.1:9002",
    client_name=self.client_name,
    rev=CLIENT_REVISION,
  )
  let query = build_query(client_info~, sql~)
  let empty = build_empty_data()

  self.tcp.write(query)
  self.tcp.write(empty)

  read_response(self.tcp)
}
