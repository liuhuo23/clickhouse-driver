///|
/// CityHash128 v1.0.2（ClickHouse CityHash_v1_0_2，压缩块校验和算法）。
/// 移植自 ClickHouse 使用的 CityHash_v1_0_2（含 K3 常量，与 google master 不同）。
/// 返回 (low64, high64)，写入时低 64 位在前。
const K0 : UInt64 = 0xc3a5c85c97cb3127

///|
const K1 : UInt64 = 0xb492b66fbe98f273

///|
const K2 : UInt64 = 0x9ae16a3b2f90404f

///|
const K3 : UInt64 = 0xc949d7c7509e6557

///|
const KMUL : UInt64 = 0x9ddfea08eb382d69

///|
/// 循环右移。
fn rotate(v : UInt64, n : Int32) -> UInt64 {
  (v >> n) | (v << (64 - n))
}

///|
fn shift_mix(v : UInt64) -> UInt64 {
  v ^ (v >> 47)
}

///|
fn hash128_to_64(l : UInt64, h : UInt64) -> UInt64 {
  let mut a = (h ^ l) * KMUL
  a = a ^ (a >> 47)
  let mut b = (h ^ a) * KMUL
  b = b ^ (b >> 47)
  b * KMUL
}

///|
fn hash_len16(u : UInt64, v : UInt64) -> UInt64 {
  hash128_to_64(u, v)
}

///|
fn fetch64(bytes : Bytes, offset : Int32) -> UInt64 {
  let mut v : UInt64 = 0
  for i in 0..<8 {
    v = v | (bytes[offset + i].to_uint64() << (i * 8))
  }
  v
}

///|
fn fetch32(bytes : Bytes, offset : Int32) -> UInt32 {
  let mut v : UInt32 = 0
  for i in 0..<4 {
    v = v | (bytes[offset + i].to_uint() << (i * 8))
  }
  v
}

///|
fn hash_len0to16(bytes : Bytes, len : Int32) -> UInt64 {
  if len > 8 {
    let a = fetch64(bytes, 0)
    let b = fetch64(bytes, len - 8)
    return b ^ hash_len16(a, rotate(b + len.to_uint64(), len))
  }
  if len >= 4 {
    let a = fetch32(bytes, 0).to_uint64()
    return hash_len16(
      len.to_uint64() + (a << 3),
      fetch32(bytes, len - 4).to_uint64(),
    )
  }
  if len > 0 {
    let a = bytes[0].to_uint()
    let b = bytes[len >> 1].to_uint()
    let c = bytes[len - 1].to_uint()
    let y = a.to_uint64() + (b.to_uint64() << 8)
    let z = (len.reinterpret_as_uint() + (c << 2)).to_uint64()
    return shift_mix((y * K2) ^ (z * K3)) * K2
  }
  K2
}

///|
fn weak_hash_len32(
  w : UInt64,
  x : UInt64,
  y : UInt64,
  z : UInt64,
  a : UInt64,
  b : UInt64,
) -> (UInt64, UInt64) {
  let mut a = a + w
  let mut b = rotate(b + a + z, 21)
  let c = a
  a = a + x + y
  b = b + rotate(a, 44)
  (a + z, b + c)
}

///|
fn weak_hash_s(
  bytes : Bytes,
  offset : Int32,
  a : UInt64,
  b : UInt64,
) -> (UInt64, UInt64) {
  weak_hash_len32(
    fetch64(bytes, offset),
    fetch64(bytes, offset + 8),
    fetch64(bytes, offset + 16),
    fetch64(bytes, offset + 24),
    a,
    b,
  )
}

///|
fn city_murmur(
  bytes : Bytes,
  len : Int32,
  seed_low : UInt64,
  seed_high : UInt64,
) -> (UInt64, UInt64) {
  let mut a = seed_low
  let mut b = seed_high
  let mut c : UInt64 = 0
  let mut d : UInt64 = 0
  let mut l = len - 16
  if l <= 0 {
    a = shift_mix(a * K1) * K1
    c = b * K1 + hash_len0to16(bytes, len)
    d = shift_mix(a + (if len >= 8 { fetch64(bytes, 0) } else { c }))
  } else {
    c = hash_len16(fetch64(bytes, len - 8) + K1, a)
    d = hash_len16(b + len.to_uint64(), c + fetch64(bytes, len - 16))
    a = a + d
    let mut off = 0
    while l > 0 {
      a = a ^ (shift_mix(fetch64(bytes, off) * K1) * K1)
      a = a * K1
      b = b ^ a
      c = c ^ (shift_mix(fetch64(bytes, off + 8) * K1) * K1)
      c = c * K1
      d = d ^ c
      off = off + 16
      l = l - 16
    }
  }
  a = hash_len16(a, c)
  b = hash_len16(d, b)
  (a ^ b, hash_len16(b, a))
}

///|
fn cityhash128_with_seed(
  bytes : Bytes,
  len : Int32,
  seed_low : UInt64,
  seed_high : UInt64,
) -> (UInt64, UInt64) {
  if len < 128 {
    return city_murmur(bytes, len, seed_low, seed_high)
  }
  let mut x = seed_low
  let mut y = seed_high
  let mut z = len.to_uint64() * K1
  let mut v0 = rotate(y ^ K1, 49) * K1 + fetch64(bytes, 0)
  let mut v1 = rotate(v0, 42) * K1 + fetch64(bytes, 8)
  let mut w0 = rotate(y + z, 35) * K1 + x
  let mut w1 = rotate(x + fetch64(bytes, 88), 53) * K1
  let mut off = 0
  while len - off >= 128 {
    x = rotate(x + y + v0 + fetch64(bytes, off + 16), 37) * K1
    y = rotate(y + v1 + fetch64(bytes, off + 48), 42) * K1
    x = x ^ w1
    y = y ^ v0
    z = rotate(z ^ w0, 33)
    let wh = weak_hash_s(bytes, off, v1 * K1, x + w0)
    v0 = wh.0
    v1 = wh.1
    let wh2 = weak_hash_s(bytes, off + 32, z + w1, y)
    w0 = wh2.0
    w1 = wh2.1
    let tmp = z
    z = x
    x = tmp
    off = off + 64
    x = rotate(x + y + v0 + fetch64(bytes, off + 16), 37) * K1
    y = rotate(y + v1 + fetch64(bytes, off + 48), 42) * K1
    x = x ^ w1
    y = y ^ v0
    z = rotate(z ^ w0, 33)
    let wh3 = weak_hash_s(bytes, off, v1 * K1, x + w0)
    v0 = wh3.0
    v1 = wh3.1
    let wh4 = weak_hash_s(bytes, off + 32, z + w1, y)
    w0 = wh4.0
    w1 = wh4.1
    let tmp2 = z
    z = x
    x = tmp2
    off = off + 64
  }
  let rem = len - off
  y = y + rotate(w0, 37) * K0 + z
  x = x + rotate(v0 + z, 49) * K0
  let mut tail_done = 0
  while tail_done < rem {
    tail_done = tail_done + 32
    y = rotate(y - x, 42) * K0 + v1
    w0 = w0 + fetch64(bytes, off + rem - tail_done + 16)
    x = rotate(x, 49) * K0 + w0
    w0 = w0 + v0
    let wh5 = weak_hash_s(bytes, off + rem - tail_done, v0, v1)
    v0 = wh5.0
    v1 = wh5.1
  }
  x = hash_len16(x, v0)
  y = hash_len16(y, w0)
  (hash_len16(x + v1, w1) + y, hash_len16(x + w1, y + v1))
}

///|
/// 计算 CityHash128（ClickHouse CityHash_v1_0_2 入口），返回 (low64, high64)。
/// 注意入口 seed 含 k3；len 8-15 有独立分支（monoid 第三方移植在此处有误，
/// 以 ClickHouse C 源码为准）。
pub fn city_hash128(bytes : Bytes) -> (UInt64, UInt64) {
  let len = bytes.length()
  if len >= 16 {
    cityhash128_with_seed(
      bytes.exact_view(start=16, end=len).to_owned(),
      len - 16,
      fetch64(bytes, 0) ^ K3,
      fetch64(bytes, 8),
    )
  } else if len >= 8 {
    cityhash128_with_seed(
      b"",
      0,
      fetch64(bytes, 0) ^ (len.to_uint64() * K0),
      fetch64(bytes, len - 8) ^ K1,
    )
  } else {
    cityhash128_with_seed(bytes, len, K0, K1)
  }
}
