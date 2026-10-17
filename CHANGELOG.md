# Changelog

本项目遵循 [Semantic Versioning](https://semver.org/lang/zh-CN/)。
0.x 阶段：次版本号用于不兼容变更与功能性新增。

## [0.4.0] - 2026-10-17

汇总 0.3.0 与 0.4.0 的全部变更（0.3.0 仅创建 tag，未成功发布到 mooncakes）。

### Added

- native 驱动接入 `timeout_ms`：`connect` / `ping` / `execute_query` /
  `insert` / 游标 `next` / `close` 均受超时约束，超时抛 `ConnectionError`。
- HTTP 连接池空闲超过 5 秒的连接在复用前用 `GET /ping` 探活，避免复用
  已被服务端关闭的 keep-alive socket。
- 新增 `internal` 包承载参数绑定助手，供根包与 native 包共享。
- 随源码发布 `docs/native-protocol-design.md` 与本 `CHANGELOG.md`。

### Changed

- HTTP `ServerError.code` 优先使用 ClickHouse 真实异常码
  （`X-ClickHouse-Exception-Code` 响应头或 body 的 `Code: N.` 前缀），
  `name = "DB::Exception"`；仅在无法解析时回退 HTTP 状态码与 `"HTTPError"`，
  与 native 驱动的错误语义对齐。
- 根包从单文件拆分为 `connection` / `http` / `pool` / `cursor` / `types` /
  `errors` / `tsv` / `lz4` / `text` 等职责文件，公共 API 形态不变。
- native 协议原语（`read_*`、`flush_bytes`、`city_hash128` 等）收为包内私有。
- 适配 moon 0.1.20261012：`Int` → `Int32`、`UInt` → `UInt32`、可选参数
  `name?` → `name~`（生成的 `.mbti` 对外仍显示 `Int` / `?`，公共 API 不变）。
- 安装说明简化为只需依赖 `liuhuo23/clickhouse-driver`。

### Removed

- 根包不再公开 `bind_positional` / `apply_default_types`（迁入 `internal`）。
- native 包不再公开 `read_*`、`flush_bytes`、`city_hash128`、
  `write_compressed_block`、`read_server_hello`、`read_exception`。

### Fixed

- native 连接在服务端不响应时可能永久挂起。
- 超时取消时连接池 semaphore permit 泄漏，可能耗尽池容量。
- `substr` 按 UTF-16 code unit 截断导致中文错误信息/CRLF 行乱码。
- 连接池复用已失效的 keep-alive 连接导致首个请求失败。
- `moon check` 警告从 22 个清零（`errdefer`、unused import、
  `exact_view`、显式 `Debug` 方法）。

## [0.3.0] - 2026-08-03

- native TCP 驱动：握手、30+ 类型编解码、命名/位置参数绑定、批量 INSERT、
  流式游标、LZ4 + CityHash128、连接池。

## [0.2.0] - 2026-08-03

- HTTP 驱动：命名/位置参数绑定、批量 `insert`、流式游标、连接池、
  LZ4 响应解压、TLS。

## [0.1.1] - 2026-07-07

- 首个发布版本：HTTP 连接、查询、`ResultSet`、`DbError`。
