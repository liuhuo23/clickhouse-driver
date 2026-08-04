///|
/// 编解码原语单元测试（P0）。
/// 编码 → 已知字节序列 / 解码回环 双向验证。

///|
test "varuint roundtrip" {
  let cases : Array[UInt64] = [
    0, 1, 127, 128, 300, 16384, 4294967295, 0x4000000000000000, 0xFFFFFFFFFFFFFFFF,
  ]
  for v in cases {
    let buf = Buffer::Buffer()
    write_varuint(buf, v)
    let bytes = buf.to_bytes()
    let (d, pos) = decode_varuint(bytes, 0)
    assert_eq(d, v)
    assert_eq(pos, bytes.length())
  }
}

///|
test "varuint known encodings" {
  // 300 = 0xAC 0x02；128 = 0x80 0x01
  let buf300 = Buffer::Buffer()
  write_varuint(buf300, 300)
  let b300 = buf300.to_bytes()
  assert_eq(b300[0].to_int(), 0xAC)
  assert_eq(b300[1].to_int(), 0x02)
  assert_eq(b300.length(), 2)
  let buf128 = Buffer::Buffer()
  write_varuint(buf128, 128)
  let b128 = buf128.to_bytes()
  assert_eq(b128[0].to_int(), 0x80)
  assert_eq(b128[1].to_int(), 0x01)
  assert_eq(b128.length(), 2)
}

///|
test "string roundtrip" {
  let cases = ["", "hello", "你好, ClickHouse!", "mixed 中英 Mixed"]
  for s in cases {
    let buf = Buffer::Buffer()
    write_string(buf, s)
    let bytes = buf.to_bytes()
    let (d, pos) = decode_string(bytes, 0)
    assert_eq(d, s)
    assert_eq(pos, bytes.length())
  }
}

///|
test "uint16 roundtrip" {
  let cases : Array[UInt16] = [0, 1, 255, 256, 65535]
  for v in cases {
    let buf = Buffer::Buffer()
    write_uint16(buf, v)
    let bytes = buf.to_bytes()
    assert_eq(bytes.length(), 2)
    let (d, _) = decode_uint16(bytes, 0)
    assert_eq(d, v)
  }
}

///|
test "uint32 roundtrip" {
  let cases : Array[UInt] = [
    0, 1, 255, 65536, 0x7FFFFFFF, 0x80000000, 0xFFFFFFFF,
  ]
  for v in cases {
    let buf = Buffer::Buffer()
    write_uint32(buf, v)
    let bytes = buf.to_bytes()
    assert_eq(bytes.length(), 4)
    let (d, _) = decode_uint32(bytes, 0)
    assert_eq(d, v)
  }
}

///|
test "int32 roundtrip" {
  let cases = [0, 1, -1, 127, -128, 32767, -32768, 2147483647, -2147483648]
  for v in cases {
    let buf = Buffer::Buffer()
    write_int32(buf, v)
    let bytes = buf.to_bytes()
    assert_eq(bytes.length(), 4)
    let (d, _) = decode_int32(bytes, 0)
    assert_eq(d, v)
  }
}

///|
test "int32 known encoding" {
  // -1 补码 32 位 = FF FF FF FF；1 = 01 00 00 00
  let bneg = Buffer::Buffer()
  write_int32(bneg, -1)
  let bn = bneg.to_bytes()
  for i in 0..<4 {
    assert_eq(bn[i].to_int(), 0xFF)
  }
  let bpos = Buffer::Buffer()
  write_int32(bpos, 1)
  let bp = bpos.to_bytes()
  assert_eq(bp[0].to_int(), 0x01)
  assert_eq(bp[1].to_int(), 0x00)
  assert_eq(bp[2].to_int(), 0x00)
  assert_eq(bp[3].to_int(), 0x00)
}

///|
test "uint64 and int64 roundtrip" {
  let cases64 : Array[UInt64] = [0, 1, 0xFFFFFFFF, 0xFFFFFFFFFFFFFFFF]
  for v in cases64 {
    let buf = Buffer::Buffer()
    write_uint64(buf, v)
    let bytes = buf.to_bytes()
    assert_eq(bytes.length(), 8)
    let (d, _) = decode_uint64(bytes, 0)
    assert_eq(d, v)
  }
  let casesi : Array[Int64] = [
    0, 1, -1, 9223372036854775807, -9223372036854775808,
  ]
  for v in casesi {
    let buf = Buffer::Buffer()
    write_int64(buf, v)
    let bytes = buf.to_bytes()
    assert_eq(bytes.length(), 8)
    let (d, _) = decode_int64(bytes, 0)
    assert_eq(d, v)
  }
}

///|
test "float32 roundtrip and encoding" {
  // 1.0f 小端 = 00 00 80 3F
  let buf = Buffer::Buffer()
  write_float32(buf, 1.0)
  let bytes = buf.to_bytes()
  assert_eq(bytes.length(), 4)
  assert_eq(bytes[0].to_int(), 0x00)
  assert_eq(bytes[1].to_int(), 0x00)
  assert_eq(bytes[2].to_int(), 0x80)
  assert_eq(bytes[3].to_int(), 0x3F)
  let (d, _) = decode_float32(bytes, 0)
  assert_true(d.is_close(1.0))
  let buf2 = Buffer::Buffer()
  write_float32(buf2, -0.5)
  let (d2, _) = decode_float32(buf2.to_bytes(), 0)
  assert_true(d2.is_close(-0.5))
}

///|
test "float64 roundtrip and encoding" {
  // 1.0 小端 = 00 00 00 00 00 00 F0 3F
  let buf = Buffer::Buffer()
  write_float64(buf, 1.0)
  let bytes = buf.to_bytes()
  assert_eq(bytes.length(), 8)
  assert_eq(bytes[7].to_int(), 0x3F)
  assert_eq(bytes[6].to_int(), 0xF0)
  let (d, _) = decode_float64(bytes, 0)
  assert_true(d.is_close(1.0))
  let buf2 = Buffer::Buffer()
  write_float64(buf2, 3.141592653589793)
  let (d2, _) = decode_float64(buf2.to_bytes(), 0)
  assert_true(d2.is_close(3.141592653589793))
}

///|
test "build_hello structure" {
  let bytes = build_hello("test-client", "db1", "user1", "pw1")
  let (ptype, pos1) = decode_varuint(bytes, 0)
  assert_eq(ptype, 0) // Hello
  let (name, pos2) = decode_string(bytes, pos1)
  assert_eq(name, "test-client")
  let (major, pos3) = decode_varuint(bytes, pos2)
  assert_eq(major, CLIENT_VERSION_MAJOR)
  let (minor, pos4) = decode_varuint(bytes, pos3)
  assert_eq(minor, CLIENT_VERSION_MINOR)
  let (rev, pos5) = decode_varuint(bytes, pos4)
  assert_eq(rev, CLIENT_REVISION)
  let (db, pos6) = decode_string(bytes, pos5)
  assert_eq(db, "db1")
  let (user, pos7) = decode_string(bytes, pos6)
  assert_eq(user, "user1")
  let (pw, pos8) = decode_string(bytes, pos7)
  assert_eq(pw, "pw1")
  assert_eq(pos8, bytes.length())
}

///|
test "truncated input raises connection error" {
  let caught1 = try {
    ignore(decode_uint32(b"\x01\x02", 0))
    false
  } catch {
    _ => true
  }
  assert_true(caught1)
  let caught2 = try {
    ignore(decode_varuint(b"\x80", 0))
    false
  } catch {
    _ => true
  }
  assert_true(caught2)
  let caught3 = try {
    ignore(decode_string(b"\x05hi", 0))
    false
  } catch {
    _ => true
  }
  assert_true(caught3)
}

///|
test "server packet type mapping" {
  assert_true(ServerPacket::from_int(0) is Hello)
  assert_true(ServerPacket::from_int(1) is Data)
  assert_true(ServerPacket::from_int(2) is Exception)
  assert_true(ServerPacket::from_int(3) is Progress)
  assert_true(ServerPacket::from_int(4) is Pong)
  assert_true(ServerPacket::from_int(5) is EndOfStream)
  assert_true(ServerPacket::from_int(6) is ProfileInfo)
  assert_true(ServerPacket::from_int(7) is Totals)
  assert_true(ServerPacket::from_int(8) is Extremes)
  assert_true(ServerPacket::from_int(10) is Log)
  let unknown = try {
    ignore(ServerPacket::from_int(99))
    false
  } catch {
    _ => true
  }
  assert_true(unknown)
}

///|
/// native 子包单元测试（P2）：块解码、类型解码、Query 包构造、日期格式化。

///|
test "date formatting" {
  assert_eq(format_date_from_days(0), "1970-01-01")
  assert_eq(format_date_from_days(1), "1970-01-02")
  assert_eq(format_date_from_days(31), "1970-02-01")
  assert_eq(format_date_from_days(365), "1971-01-01")
  assert_eq(format_date_from_days(20657), "2026-07-23")
  assert_eq(format_date_from_days(20750), "2026-10-24")
  // 闰年：2024-02-29 = 1970-01-01 起 19782 天
  assert_eq(format_date_from_days(19782), "2024-02-29")
}

///|
test "datetime formatting" {
  assert_eq(format_datetime(0), "1970-01-01 00:00:00")
  assert_eq(format_datetime(86399), "1970-01-01 23:59:59")
  assert_eq(format_datetime(86400), "1970-01-02 00:00:00")
  assert_eq(format_datetime(1785621296), "2026-08-01 21:54:56")
  // DateTime64(3)
  assert_eq(format_datetime64(1785635696123, 3), "2026-08-02 01:54:56.123")
}

///|
test "query packet structure" {
  let bytes = build_query_packet("tester", "SELECT 1", compress=false)
  let (ptype, pos1) = decode_varuint(bytes, 0)
  assert_eq(ptype, 1) // Query
  let (qid, pos2) = decode_string(bytes, pos1)
  assert_eq(qid, "")
  // query_kind = 1 (initial)
  assert_eq(bytes[pos2].to_int(), 1)
  let (user, pos3) = decode_string(bytes, pos2 + 1)
  assert_eq(user, "")
  let (iid, pos4) = decode_string(bytes, pos3)
  assert_eq(iid, "")
  let (addr, pos5) = decode_string(bytes, pos4)
  assert_true(addr.length() > 0) // initial_address 必须非空
  // initial_query_start_time_microseconds (uint64) + interface=1(TCP)
  let pos6 = pos5 + 8
  assert_eq(bytes[pos6].to_int(), 1)
  // os_user / client_hostname 都为空
  let (osu, pos7) = decode_string(bytes, pos6 + 1)
  assert_eq(osu, "")
  let (host, pos8) = decode_string(bytes, pos7)
  assert_eq(host, "")
  let (cname, pos9) = decode_string(bytes, pos8)
  assert_eq(cname, "tester")
  let (major, pos10) = decode_varuint(bytes, pos9)
  assert_eq(major, CLIENT_VERSION_MAJOR)
  let (minor, pos11) = decode_varuint(bytes, pos10)
  assert_eq(minor, CLIENT_VERSION_MINOR)
  let (rev, pos12) = decode_varuint(bytes, pos11)
  assert_eq(rev, CLIENT_REVISION)
  // quota_key("") + distributed_depth(0) + version_patch(0) + otel(0) + parallel(0)×3
  let (qk, pos13) = decode_string(bytes, pos12)
  assert_eq(qk, "")
  let (dd, pos14) = decode_varuint(bytes, pos13)
  assert_eq(dd, 0)
  let (vp, pos15) = decode_varuint(bytes, pos14)
  assert_eq(vp, 0)
  assert_eq(bytes[pos15].to_int(), 0) // otel
  let (pr1, pos16) = decode_varuint(bytes, pos15 + 1)
  assert_eq(pr1, 0)
  let (pr2, pos17) = decode_varuint(bytes, pos16)
  assert_eq(pr2, 0)
  let (pr3, pos18) = decode_varuint(bytes, pos17)
  assert_eq(pr3, 0)
  // settings：low_cardinality_allow_in_native_format + IMPORTANT(1) + "0" + 空串结束
  let (sname, pos19) = decode_string(bytes, pos18)
  assert_eq(sname, "low_cardinality_allow_in_native_format")
  assert_eq(bytes[pos19].to_int(), 1) // SettingsFlags::IMPORTANT
  let (sval, pos20) = decode_string(bytes, pos19 + 1)
  assert_eq(sval, "0")
  let (send, pos20b) = decode_string(bytes, pos20)
  assert_eq(send, "")
  // interserver_secret("")
  let (s2, pos20c) = decode_string(bytes, pos20b)
  assert_eq(s2, "")
  let (stage, pos21) = decode_varuint(bytes, pos20c)
  assert_eq(stage, 2) // Complete
  let (comp, pos22) = decode_varuint(bytes, pos21)
  assert_eq(comp, 0) // 无压缩
  let (sql, pos23) = decode_string(bytes, pos22)
  assert_eq(sql, "SELECT 1")
  let (params, pos24) = decode_string(bytes, pos23)
  assert_eq(params, "")
  assert_eq(pos24, bytes.length())
}

///|
test "empty data packet structure" {
  let bytes = build_empty_data_packet(false)
  let (ptype, pos1) = decode_varuint(bytes, 0)
  assert_eq(ptype, 2) // Data
  let (table, pos2) = decode_string(bytes, pos1)
  assert_eq(table, "")
  // BlockInfo：field1(1) + u8(0) + field2(2) + int32(-1) + 0
  let (f1, pos3) = decode_varuint(bytes, pos2)
  assert_eq(f1, 1)
  assert_eq(bytes[pos3].to_int(), 0)
  let (f2, pos4) = decode_varuint(bytes, pos3 + 1)
  assert_eq(f2, 2)
  let (bucket, pos5) = decode_int32(bytes, pos4)
  assert_eq(bucket, -1)
  let (f0, pos6) = decode_varuint(bytes, pos5)
  assert_eq(f0, 0)
  let (ncols, pos7) = decode_varuint(bytes, pos6)
  assert_eq(ncols, 0)
  let (nrows, pos8) = decode_varuint(bytes, pos7)
  assert_eq(nrows, 0)
  assert_eq(pos8, bytes.length())
}

///|
async test "read block with basic types" {
  let reader = @io.MemoryReader::MemoryReader(fn(writer) {
    // 1 列 UInt8，2 行：值 1, 200
    let buf = Buffer::Buffer()
    write_varuint(buf, 1) // blockinfo field1
    buf.write_byte(0) // is_overflows
    write_varuint(buf, 2) // blockinfo field2
    write_int32(buf, -1) // bucket
    write_varuint(buf, 0) // blockinfo end
    write_varuint(buf, 1) // ncols
    write_varuint(buf, 2) // nrows
    write_string(buf, "num") // col name
    write_string(buf, "UInt8") // col type
    buf.write_byte(0) // has_custom
    buf.write_byte(1) // value 1
    buf.write_byte(200) // value 200
    flush_bytes(writer, buf.to_bytes())
  })
  let block = read_block(reader)
  assert_eq(block.headers.length(), 1)
  assert_eq(block.headers[0].name, "num")
  assert_eq(block.headers[0].type_, "UInt8")
  assert_eq(block.rows.length(), 2)
  assert_eq(block.rows[0][0], "1")
  assert_eq(block.rows[1][0], "200")
}

///|
async test "read block with nullable column" {
  let reader = @io.MemoryReader::MemoryReader(fn(writer) {
    let buf = Buffer::Buffer()
    write_varuint(buf, 1)
    buf.write_byte(0)
    write_varuint(buf, 2)
    write_int32(buf, -1)
    write_varuint(buf, 0)
    write_varuint(buf, 1) // ncols
    write_varuint(buf, 2) // nrows
    write_string(buf, "maybe") // name
    write_string(buf, "Nullable(Int64)") // type
    buf.write_byte(0) // has_custom
    // bulk 格式：先 2 字节 mask（0=非空, 1=NULL），再 2 个 Int64 值
    buf.write_byte(0)
    buf.write_byte(1)
    write_int64(buf, 42)
    write_int64(buf, 0) // NULL 行的默认值（丢弃）
    flush_bytes(writer, buf.to_bytes())
  })
  let block = read_block(reader)
  assert_eq(block.rows.length(), 2)
  assert_eq(block.rows[0][0], "42")
  assert_eq(block.rows[1][0], "")
}

///|
async test "read block with string and datetime" {
  let reader = @io.MemoryReader::MemoryReader(fn(writer) {
    let buf = Buffer::Buffer()
    write_varuint(buf, 1)
    buf.write_byte(0)
    write_varuint(buf, 2)
    write_int32(buf, -1)
    write_varuint(buf, 0)
    write_varuint(buf, 2) // ncols
    write_varuint(buf, 1) // nrows
    write_string(buf, "s") // col0
    write_string(buf, "String")
    buf.write_byte(0)
    write_string(buf, "你好")
    write_string(buf, "dt") // col1
    write_string(buf, "DateTime")
    buf.write_byte(0)
    write_uint32(buf, 1785621296)
    flush_bytes(writer, buf.to_bytes())
  })
  let block = read_block(reader)
  assert_eq(block.headers.length(), 2)
  assert_eq(block.rows.length(), 1)
  assert_eq(block.rows[0][0], "你好")
  assert_eq(block.rows[0][1], "2026-08-01 21:54:56")
}

///|
async test "read block with zero rows only headers" {
  let reader = @io.MemoryReader::MemoryReader(fn(writer) {
    let buf = Buffer::Buffer()
    write_varuint(buf, 0) // blockinfo 直接结束
    write_varuint(buf, 2) // ncols
    write_varuint(buf, 0) // nrows
    write_string(buf, "a")
    write_string(buf, "Int32")
    buf.write_byte(0)
    write_string(buf, "b")
    write_string(buf, "Float64")
    buf.write_byte(0)
    flush_bytes(writer, buf.to_bytes())
  })
  let block = read_block(reader)
  assert_eq(block.headers.length(), 2)
  assert_eq(block.rows.length(), 0)
}

///|
async test "unsupported type raises connection error" {
  let caught = try {
    // 直接在内存构造 reader 并解码未支持类型会走 unsupported 分支
    let reader = @io.MemoryReader::MemoryReader(fn(writer) {
      let buf = Buffer::Buffer()
      write_varuint(buf, 0)
      write_varuint(buf, 1)
      write_varuint(buf, 1)
      write_string(buf, "c")
      write_string(buf, "AggregateFunction(uniq, UInt64)") // 未支持类型
      buf.write_byte(0)
      write_uint64(buf, 0)
      flush_bytes(writer, buf.to_bytes())
    })
    let result = try {
      ignore(read_block(reader))
      false
    } catch {
      @lib.DbError::ConnectionError(_) => true
      _ => false
    }
    reader.close()
    result
  } catch {
    _ => false
  }
  assert_true(caught)
}

///|
test "write_value numeric roundtrip" {
  // 用 Buffer 编码后用解码原语验证回环
  let buf = Buffer::Buffer()
  write_value(buf, "UInt8", "255")
  write_value(buf, "UInt16", "65535")
  write_value(buf, "UInt32", "4294967295")
  write_value(buf, "UInt64", "18446744073709551615")
  write_value(buf, "Int8", "-128")
  write_value(buf, "Int16", "-32768")
  write_value(buf, "Int32", "-2147483648")
  write_value(buf, "Int64", "-9223372036854775808")
  write_value(buf, "Float32", "1.5")
  write_value(buf, "Float64", "2.25")
  write_value(buf, "String", "你好")
  let bytes = buf.to_bytes()
  // UInt8 = 1 字节
  assert_eq(bytes[0].to_int(), 255)
  let (v2, p2) = decode_uint16(bytes, 1)
  assert_eq(v2.to_string(), "65535")
  let (v3, p3) = decode_uint32(bytes, p2)
  assert_eq(v3.to_uint64().to_string(), "4294967295")
  let (v4, p4) = decode_uint64(bytes, p3)
  assert_eq(v4.to_string(), "18446744073709551615")
  // Int8 = 1 字节（-128 → 0x80）
  assert_eq(bytes[p4].to_int(), 0x80)
  let (u6, p6) = decode_uint16(bytes, p4 + 1) // Int16 = 2 字节
  assert_eq(u6.to_uint().to_int() - 65536, -32768)
  let (v7, p7) = decode_int32(bytes, p6)
  assert_eq(v7, -2147483648)
  let (v8, p8) = decode_int64(bytes, p7)
  assert_eq(v8, -9223372036854775808)
  let (v9, p9) = decode_float32(bytes, p8)
  assert_true(v9.is_close(1.5))
  let (v10, p10) = decode_float64(bytes, p9)
  assert_true(v10.is_close(2.25))
  let (s, p11) = decode_string(bytes, p10)
  assert_eq(s, "你好")
  assert_eq(p11, bytes.length())
}

///|
test "write_value out of range raises" {
  let caught1 = try {
    let buf = Buffer::Buffer()
    write_value(buf, "UInt8", "300")
    false
  } catch {
    @lib.DbError::ConnectionError(_) => true
    _ => false
  }
  assert_true(caught1)
  let caught2 = try {
    let buf = Buffer::Buffer()
    write_value(buf, "Int16", "40000")
    false
  } catch {
    @lib.DbError::ConnectionError(_) => true
    _ => false
  }
  assert_true(caught2)
  let caught3 = try {
    let buf = Buffer::Buffer()
    write_value(buf, "Int32", "abc")
    false
  } catch {
    @lib.DbError::ConnectionError(_) => true
    _ => false
  }
  assert_true(caught3)
}

///|
test "write date and datetime" {
  let buf = Buffer::Buffer()
  write_date(buf, "1970-01-01")
  write_date(buf, "2026-08-03")
  write_datetime(buf, "1970-01-01 00:00:00")
  write_datetime(buf, "2026-08-03 12:34:56")
  let bytes = buf.to_bytes()
  let (d1, p1) = decode_uint16(bytes, 0)
  assert_eq(d1.to_int(), 0)
  let (d2, p2) = decode_uint16(bytes, p1)
  assert_eq(format_date_from_days(d2.to_uint().to_int64()), "2026-08-03")
  let (t1, p3) = decode_uint32(bytes, p2)
  assert_eq(t1, 0)
  let (t2, p4) = decode_uint32(bytes, p3)
  assert_eq(format_datetime(t2.to_int64()), "2026-08-03 12:34:56")
  assert_eq(p4, bytes.length())
}

///|
test "days from civil roundtrip" {
  // days_from_civil 与 format_date_from_days 互逆
  for days in [0, 1, 31, 365, 19782, 20657, 20750] {
    let (y, m, d) = civil_from_days(days.to_int64())
    let back = days_from_civil(y.to_int(), m.to_int(), d.to_int())
    assert_eq(back, days.to_int64())
  }
}

///|
test "write_column_values nullable two-phase" {
  let buf = Buffer::Buffer()
  write_column_values(buf, "Nullable(Int64)", ["42", "", "300"])
  let bytes = buf.to_bytes()
  // 阶段 1：3 字节 mask（0=非空, 1=NULL）
  assert_eq(bytes[0].to_int(), 0)
  assert_eq(bytes[1].to_int(), 1)
  assert_eq(bytes[2].to_int(), 0)
  // 阶段 2：3 个 Int64（NULL 行写默认值 0）
  let (v1, p1) = decode_int64(bytes, 3)
  assert_eq(v1, 42)
  let (v2, p2) = decode_int64(bytes, p1)
  assert_eq(v2, 0)
  let (v3, p3) = decode_int64(bytes, p2)
  assert_eq(v3, 300)
  assert_eq(p3, bytes.length())
}

///|
test "build_insert_sql and data packet" {
  let sql = build_insert_sql("t", ["a", "b"])
  assert_eq(sql, "INSERT INTO t (a, b) VALUES")
  let headers : Array[ColumnHeader] = [
    { name: "a", type_: "Int32" },
    { name: "b", type_: "String" },
  ]
  let pkt = build_data_packet(headers, [["1", "x"], ["2", "yy"]], false)
  // 包类型 2
  let (ptype, pos1) = decode_varuint(pkt, 0)
  assert_eq(ptype, 2)
  let (table, pos2) = decode_string(pkt, pos1)
  assert_eq(table, "")
  // BlockInfo
  let (f1, pos3) = decode_varuint(pkt, pos2)
  assert_eq(f1, 1)
  let (f2, pos4) = decode_varuint(pkt, pos3 + 1)
  assert_eq(f2, 2)
  let (bucket, pos5) = decode_int32(pkt, pos4)
  assert_eq(bucket, -1)
  let (f0, pos6) = decode_varuint(pkt, pos5)
  assert_eq(f0, 0)
  let (ncols, pos7) = decode_varuint(pkt, pos6)
  assert_eq(ncols, 2)
  let (nrows, pos8) = decode_varuint(pkt, pos7)
  assert_eq(nrows, 2)
  // col0 列头 + 数据
  let (name0, pos9) = decode_string(pkt, pos8)
  assert_eq(name0, "a")
  let (type0, pos10) = decode_string(pkt, pos9)
  assert_eq(type0, "Int32")
  assert_eq(pkt[pos10].to_int(), 0) // has_custom
  let (v0, pos11) = decode_int32(pkt, pos10 + 1)
  assert_eq(v0, 1)
  let (v1, pos12) = decode_int32(pkt, pos11)
  assert_eq(v1, 2)
  // col1 列头 + 数据
  let (name1, pos13) = decode_string(pkt, pos12)
  assert_eq(name1, "b")
  let (type1, pos14) = decode_string(pkt, pos13)
  assert_eq(type1, "String")
  assert_eq(pkt[pos14].to_int(), 0)
  let (s1, pos15) = decode_string(pkt, pos14 + 1)
  assert_eq(s1, "x")
  let (s2, pos16) = decode_string(pkt, pos15)
  assert_eq(s2, "yy")
  assert_eq(pos16, pkt.length())
}

///|
test "escape param value" {
  assert_eq(escape_param_value("42"), "'42'")
  assert_eq(escape_param_value("hello"), "'hello'")
  assert_eq(escape_param_value("a'b"), "'a\\'b'")
  assert_eq(escape_param_value("a\\b"), "'a\\\\b'")
  assert_eq(escape_param_value("line\nbreak"), "'line\\nbreak'")
  assert_eq(escape_param_value("你好"), "'你好'")
}

///|
test "query packet params encoding" {
  let bytes = build_query_packet(
    "t",
    "SELECT {n: UInt32}",
    compress=false,
    params=Map::from_array([("n", "42")]),
  )
  // 定位到 SQL 之后（结构见 "query packet structure" 测试）
  let (ptype, pos1) = decode_varuint(bytes, 0)
  assert_eq(ptype, 1)
  // 跳过 query_id + query_kind
  let (qid, pos2) = decode_string(bytes, pos1)
  assert_eq(qid, "")
  // 快速定位：从 pos2 按 ClientInfo 结构推进到 SQL
  let mut pos = pos2 + 1 // query_kind
  for _ in 0..<3 {
    let (_, np) = decode_string(bytes, pos) // user / query_id / address
    pos = np
  }
  pos = pos + 8 // start_time
  assert_eq(bytes[pos].to_int(), 1) // interface TCP
  let (_, np) = decode_string(bytes, pos + 1) // os_user
  let (_, np2) = decode_string(bytes, np) // hostname
  let (cname, np3) = decode_string(bytes, np2)
  assert_eq(cname, "t")
  let (major, np4) = decode_varuint(bytes, np3)
  assert_eq(major, CLIENT_VERSION_MAJOR)
  let (minor, np5) = decode_varuint(bytes, np4)
  assert_eq(minor, CLIENT_VERSION_MINOR)
  let (rev, np6) = decode_varuint(bytes, np5)
  assert_eq(rev, CLIENT_REVISION)
  let (qk, np7) = decode_string(bytes, np6)
  assert_eq(qk, "")
  let (dd, np8) = decode_varuint(bytes, np7)
  assert_eq(dd, 0)
  let (vp, np9) = decode_varuint(bytes, np8)
  assert_eq(vp, 0)
  let (pr1, np10) = decode_varuint(bytes, np9 + 1) // otel 后
  assert_eq(pr1, 0)
  let (pr2, np11) = decode_varuint(bytes, np10)
  assert_eq(pr2, 0)
  let (pr3, np12) = decode_varuint(bytes, np11)
  assert_eq(pr3, 0)
  let (sname, np13) = decode_string(bytes, np12)
  assert_eq(sname, "low_cardinality_allow_in_native_format")
  let (sval, np14) = decode_string(bytes, np13 + 1)
  assert_eq(sval, "0")
  let (send, np14b) = decode_string(bytes, np14)
  assert_eq(send, "")
  let (s2, np14c) = decode_string(bytes, np14b)
  assert_eq(s2, "")
  let (stage, np15) = decode_varuint(bytes, np14c)
  assert_eq(stage, 2)
  let (comp, np16) = decode_varuint(bytes, np15)
  assert_eq(comp, 0)
  let (sql, np17) = decode_string(bytes, np16)
  assert_eq(sql, "SELECT {n: UInt32}")
  // params：name + flags(2) + value + 空串结束
  let (pname, np18) = decode_string(bytes, np17)
  assert_eq(pname, "n")
  assert_eq(bytes[np18].to_int(), 2) // SettingsFlags::CUSTOM
  let (pval, np19) = decode_string(bytes, np18 + 1)
  assert_eq(pval, "'42'")
  let (pend, np20) = decode_string(bytes, np19)
  assert_eq(pend, "")
  assert_eq(np20, bytes.length())
}

///|
test "query packet empty params" {
  let bytes = build_query_packet("t", "SELECT 1")
  let (_, pos1) = decode_varuint(bytes, 0)
  let (_, pos2) = decode_string(bytes, pos1)
  let mut pos = pos2 + 1
  for _ in 0..<3 {
    let (_, np) = decode_string(bytes, pos)
    pos = np
  }
  pos = pos + 8
  let (_, np) = decode_string(bytes, pos + 1) // os_user
  let (_, np2) = decode_string(bytes, np)
  let (_, np3) = decode_string(bytes, np2) // client_name
  let (_, np4) = decode_varuint(bytes, np3)
  let (_, np5) = decode_varuint(bytes, np4)
  let (_, np6) = decode_varuint(bytes, np5)
  let (_, np7) = decode_string(bytes, np6) // quota_key
  let (_, np8) = decode_varuint(bytes, np7)
  let (_, np9) = decode_varuint(bytes, np8)
  let (_, np10) = decode_varuint(bytes, np9 + 1)
  let (_, np11) = decode_varuint(bytes, np10)
  let (_, np12) = decode_varuint(bytes, np11)
  let (_, np13) = decode_string(bytes, np12) // settings name
  let (_, np14) = decode_string(bytes, np13 + 1) // settings value
  let (_, np14b) = decode_string(bytes, np14) // settings end
  let (_, np14c) = decode_string(bytes, np14b) // interserver
  let (_, np15) = decode_varuint(bytes, np14c)
  let (_, np16) = decode_varuint(bytes, np15)
  let (sql, np17) = decode_string(bytes, np16)
  assert_eq(sql, "SELECT 1")
  let (pend, np18) = decode_string(bytes, np17) // params 空表
  assert_eq(pend, "")
  assert_eq(np18, bytes.length())
}

///|
test "uuid formatting" {
  // 123e4567-e89b-12d3-a456-426614174000
  // 存储：先高 64 位小端（d3 12 9b e8 67 45 3e 12），再低 64 位小端（00 40 17 14 66 42 56 a4）
  let bytes = b"\xd3\x12\x9b\xe8\x67\x45\x3e\x12\x00\x40\x17\x14\x66\x42\x56\xa4"
  let (hi, _) = decode_uint64(bytes, 0)
  let (lo, _) = decode_uint64(bytes, 8)
  assert_eq(format_uuid(lo, hi), "123e4567-e89b-12d3-a456-426614174000")
  // 全零
  assert_eq(format_uuid(0, 0), "00000000-0000-0000-0000-000000000000")
}

///|
test "ipv6 formatting" {
  // ::1 = 00...01
  let ip6_1 = b"\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01"
  assert_eq(format_ipv6(ip6_1), "::1")
  // 2001:db8::1
  let ip6_2 = b"\x20\x01\x0d\xb8\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01"
  assert_eq(format_ipv6(ip6_2), "2001:db8::1")
  // fe80::1
  let ip6_3 = b"\xfe\x80\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01"
  assert_eq(format_ipv6(ip6_3), "fe80::1")
  // 无压缩：1:2:3:4:5:6:7:8
  let ip6_4 = b"\x00\x01\x00\x02\x00\x03\x00\x04\x00\x05\x00\x06\x00\x07\x00\x08"
  assert_eq(format_ipv6(ip6_4), "1:2:3:4:5:6:7:8")
}

///|
test "ipv4 formatting" {
  // 127.0.0.1 = UInt32 0x7F000001 小端
  assert_eq(format_ipv4(b"\x01\x00\x00\x7f"), "127.0.0.1")
  assert_eq(format_ipv4(b"\x00\x00\x00\x00"), "0.0.0.0")
  assert_eq(format_ipv4(b"\x0a\x00\x00\xc0"), "192.0.0.10")
}

///|
async test "decimal big formatting" {
  let d128 = read_decimal_big_async(
    b"\x83\x1a\x99\xbe\x1c\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00", 16,
  )
  assert_eq(format_big_decimal(d128, 3), "123456789.123")
  let d256 = read_decimal_big_async(
    b"\x96\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00",
    32,
  )
  assert_eq(format_big_decimal(d256, 2), "1.5")
  let neg = read_decimal_big_async(
    b"\xc7\xcf\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff", 16,
  )
  assert_eq(format_big_decimal(neg, 2), "-123.45")
}

///|
test "split top level" {
  let parts = split_top_level("Int32, String, Nullable(Int64)")
  assert_eq(parts.length(), 3)
  assert_eq(parts[0], "Int32")
  assert_eq(parts[1], "String")
  assert_eq(parts[2], "Nullable(Int64)")
  let parts2 = split_top_level("Array(Int32), Tuple(String, Int64)")
  assert_eq(parts2.length(), 2)
  assert_eq(parts2[0], "Array(Int32)")
  assert_eq(parts2[1], "Tuple(String, Int64)")
}

///|
test "enum map parsing" {
  let map = parse_enum_map("Enum8('a' = 1, 'b' = 2)")
  assert_eq(map.length(), 2)
  assert_eq(map[0].0, 1)
  assert_eq(map[0].1, "a")
  assert_eq(map[1].0, 2)
  assert_eq(map[1].1, "b")
}

///|
test "nested value formatting" {
  assert_eq(format_nested_value(""), "NULL")
  assert_eq(format_nested_value("42"), "42")
  assert_eq(format_nested_value("hello"), "'hello'")
  assert_eq(format_nested_value("[1,2]"), "[1,2]")
}

///|
/// 用 MemoryReader 调用 read_decimal_big。
async fn read_decimal_big_async(bytes : Bytes, n : Int) -> @bigint.BigInt {
  let reader = @io.MemoryReader::MemoryReader(fn(writer) {
    flush_bytes(writer, bytes)
  })
  let v = read_decimal_big(reader, n)
  reader.close()
  v
}

///|
async test "decimal write roundtrip" {
  let reader = @io.MemoryReader::MemoryReader(fn(writer) {
    let buf = Buffer::Buffer()
    write_value(buf, "Decimal(38, 3)", "123456789.123")
    write_value(buf, "Decimal(9, 2)", "-0.50")
    write_value(buf, "Decimal(76, 2)", "1.5")
    flush_bytes(writer, buf.to_bytes())
  })
  let d1 = read_decimal(reader, "Decimal(38, 3)")
  let d2 = read_decimal(reader, "Decimal(9, 2)")
  let d3 = read_decimal(reader, "Decimal(76, 2)")
  reader.close()
  assert_eq(d1, "123456789.123")
  assert_eq(d2, "-0.5")
  assert_eq(d3, "1.5")
}

///|
test "write uuid and ipv4" {
  let buf = Buffer::Buffer()
  write_uuid_value(buf, "123e4567-e89b-12d3-a456-426614174000")
  write_uuid_value(buf, "00000000-0000-0000-0000-000000000000")
  write_ipv4(buf, "127.0.0.1")
  write_ipv4(buf, "0.0.0.0")
  let bytes = buf.to_bytes()
  // UUID 高 64 位小端在前
  let (hi, p1) = decode_uint64(bytes, 0)
  let (lo, p2) = decode_uint64(bytes, 8)
  assert_eq(format_uuid(lo, hi), "123e4567-e89b-12d3-a456-426614174000")
  let (hi2, p3) = decode_uint64(bytes, 16)
  let (lo2, p4) = decode_uint64(bytes, 24)
  assert_eq(format_uuid(lo2, hi2), "00000000-0000-0000-0000-000000000000")
  // IPv4：UInt32 小端（127.0.0.1 → 01 00 00 7f）
  assert_eq(bytes[p4].to_int(), 0x01)
  assert_eq(bytes[p4 + 3].to_int(), 0x7f)
  assert_eq(bytes[p4 + 4].to_int(), 0x00)
  assert_eq(bytes[p4 + 7].to_int(), 0x00)
}

///|
test "write enum" {
  let buf = Buffer::Buffer()
  write_enum(buf, "Enum8('a' = 1, 'b' = 2)", "a", 1)
  write_enum(buf, "Enum8('a' = 1, 'b' = 2)", "b", 1)
  write_enum(buf, "Enum8('a' = 1, 'b' = 2)", "2", 1)
  let bytes = buf.to_bytes()
  assert_eq(bytes[0].to_int(), 1)
  assert_eq(bytes[1].to_int(), 2)
  assert_eq(bytes[2].to_int(), 2)
}

///|
test "parse decimal string" {
  let v1 = parse_decimal_string("123456789.123", 3)
  assert_eq(v1.to_string(), "123456789123")
  let v2 = parse_decimal_string("-0.5", 2)
  assert_eq(v2.to_string(), "-50")
  let v3 = parse_decimal_string("1.5", 2)
  assert_eq(v3.to_string(), "150")
  let v4 = parse_decimal_string("7", 0)
  assert_eq(v4.to_string(), "7")
}

///|
test "timezone offset parsing" {
  assert_eq(timezone_offset("DateTime('Asia/Shanghai')"), 480)
  assert_eq(timezone_offset("DateTime64(3, 'Asia/Shanghai')"), 480)
  assert_eq(timezone_offset("DateTime('UTC')"), 0)
  assert_eq(timezone_offset("DateTime('Etc/GMT-3')"), 180)
  assert_eq(timezone_offset("DateTime('Etc/GMT+5')"), -300)
  assert_eq(timezone_offset("DateTime"), 0)
  assert_eq(timezone_offset("DateTime('America/New_York')"), -300)
  assert_eq(timezone_offset("DateTime('Asia/Tokyo')"), 540)
}

///|
test "lz4 decompress samples" {
  // 样本来自 Python lz4.block.compress（与 ClickHouse LZ4_compress_default 同格式）
  let cases : Array[(Bytes, Bytes, Int)] = [
    (b"\x68\x65\x6c\x6c\x6f\x20\x77\x6f\x72\x6c\x64", b"hello world", 0),
  ]
  let d1 = lz4_decompress(
    b"\xb0\x68\x65\x6c\x6c\x6f\x20\x77\x6f\x72\x6c\x64", 11,
  )
  assert_eq(d1, b"hello world")
  // abc×100
  let repeated = lz4_decompress(
    b"\x3f\x61\x62\x63\x03\x00\xff\x12\x50\x62\x63\x61\x62\x63", 300,
  )
  assert_eq(repeated.length(), 300)
  assert_eq(repeated[0], b'a')
  assert_eq(repeated[299], b'c')
  // 纯字面量
  let lit = lz4_decompress(b"\x10\x78", 1)
  assert_eq(lit, b"x")
  // 空
  let empty = lz4_decompress(b"\x00", 0)
  assert_eq(empty.length(), 0)
}

///|
async test "read compressed payload" {
  let reader = @io.MemoryReader::MemoryReader(fn(writer) {
    // 构造 C++ 格式压缩块：16B checksum(0) + comp_size + uncomp_size + 0x82 + LZ4
    let buf = Buffer::Buffer()
    for _ in 0..<16 {
      buf.write_byte(0)
    }
    let payload = b"\xb0\x68\x65\x6c\x6c\x6f\x20\x77\x6f\x72\x6c\x64" // LZ4("hello world")
    buf.write_byte(0x82) // method: LZ4
    write_uint32(buf, (9 + payload.length()).to_uint()) // comp_size
    write_uint32(buf, 11) // uncomp_size
    buf.write_bytes(payload)
    flush_bytes(writer, buf.to_bytes())
  })
  let out = read_payload(reader, true)
  reader.close()
  assert_eq(out, b"hello world")
}

///|
async test "read uncompressed payload when compression off" {
  let reader = @io.MemoryReader::MemoryReader(fn(writer) {
    let buf = Buffer::Buffer()
    write_string(buf, "plain data")
    flush_bytes(writer, buf.to_bytes())
  })
  let out = read_payload(reader, false)
  reader.close()
  assert_eq(out, b"plain data")
}

///|
test "cityhash128 vectors" {
  // 与 clickhouse_cityhash（ClickHouse CityHash_v1_0_2）对照。
  // 注意：Python int 的低 64 位 = C++ high64，高 64 位 = C++ low64；
  // city_hash128 返回 (C++ low64, C++ high64)，写入时 low64 在前。
  let cases : Array[(Bytes, UInt64, UInt64)] = [
    (b"", 0x3df09dfc64c09a2b, 0x3cb540c392e51e29),
    (b"a", 0xd27139a1afe01ad0, 0xfd7e8ee2e4c86cf6),
    (b"hello world", 0x7dfb52dd24b29c7b, 0x0f6075c357e384d0),
    (
      b"The quick brown fox jumps over the lazy dog", 0x69102202d326a2fd, 0xe4b1346bbee531a1,
    ),
    (
      b"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
      0xac565824d014f9f2, 0xa6215b222dbf04ac,
    ),
  ]
  for case in cases {
    let (data, lo, hi) = case
    let (l, h) = city_hash128(data)
    assert_eq(l, lo)
    assert_eq(h, hi)
  }
  // 长输入（>= 128 走 with_seed 主路径）
  let long = Buffer::Buffer()
  for i in 0..<100 {
    long.write_bytes(b"data")
  }
  let (l2, h2) = city_hash128(long.to_bytes())
  assert_eq(l2, 0x1592f5c672d377d7)
  assert_eq(h2, 0x9d9326ed80f02340)
}

///|
test "cityhash128 full vector check" {
  // len 0..39 与 clickhouse_cityhash 对照（C++ low, high）
  let expected : Array[(Int, UInt64, UInt64)] = [
    (0, 0x3df09dfc64c09a2b, 0x3cb540c392e51e29),
    (1, 0xaf63bd6670cfb269, 0x879aef3966e6eed9),
    (2, 0x440a8a39d76709b0, 0xd404c769f5802b60),
    (3, 0x1b96c82f088f4a5f, 0x18dea354ffa74abb),
    (4, 0x34dc29d42325d5c6, 0x5c5406016dfc42b0),
    (5, 0xdf95b0116f6404b5, 0x338df7cf01add573),
    (6, 0xdc94c8d354b5826a, 0xcd46939f3945bb92),
    (7, 0xaef9eb639afacfd1, 0xb9d723bad4edd427),
    (8, 0xc55f34464082cb38, 0xc72b251dbe7727a3),
    (9, 0x4ce418cb68eb9a76, 0x71f186a9f6a85efd),
    (10, 0x2e7038741742c039, 0xe18e330e147e1a2b),
    (11, 0xc94c8e545a8a5f36, 0x43688e7b89e420b6),
  ]
  for case in expected {
    let (ln, elo, ehi) = case
    let buf = Buffer::Buffer()
    for i in 0..<ln {
      buf.write_byte((65 + i % 26).to_byte())
    }
    let (l, h) = city_hash128(buf.to_bytes())
    assert_eq(l, elo)
    assert_eq(h, ehi)
  }
  // 主路径（len >= 128）
  let long_cases : Array[(Int, UInt64, UInt64)] = [
    (128, 0x292f5e1651d7427e, 0x1251bc99ab918911),
    (129, 0xcc0219ec07506579, 0xff373dc4b7d980ab),
    (130, 0x1905ef921e7bd5dc, 0x8ea1c8a1ea71c7fa),
    (200, 0x65a2e22bc96c266e, 0xb1ca79b729fa73d0),
    (256, 0x0f0988c85c37c622, 0xb5e00e8d1af48470),
    (400, 0x119a0f277f23d7d5, 0x9cdc3726e06d5ed5),
  ]
  for case in long_cases {
    let (ln, elo, ehi) = case
    let buf = Buffer::Buffer()
    for i in 0..<ln {
      buf.write_byte((65 + i % 26).to_byte())
    }
    let (l, h) = city_hash128(buf.to_bytes())
    assert_eq(l, elo, msg="long \{ln} low")
    assert_eq(h, ehi, msg="long \{ln} high")
  }
  // data*100（400 字节）
  let dbuf = Buffer::Buffer()
  for i in 0..<100 {
    dbuf.write_bytes(b"data")
  }
  let (dl, dh) = city_hash128(dbuf.to_bytes())
  assert_eq(dl, 0x1592f5c672d377d7, msg="data100 low")
  assert_eq(dh, 0x9d9326ed80f02340, msg="data100 high")
}

///|

///|
test "connection pool config" {
  let config = native_config(host="h", user="u", password="p", database="d")
  let pool = config.pool(size=3)
  assert_eq(pool.max_size(), 3)
  // size <= 0 时按默认 4
  let pool2 = config.pool(size=0)
  assert_eq(pool2.max_size(), 4)
  let pool3 = config.pool()
  assert_eq(pool3.max_size(), 4)
  // 关闭无连接的池
  pool.close()
  pool2.close()
  pool3.close()
}
