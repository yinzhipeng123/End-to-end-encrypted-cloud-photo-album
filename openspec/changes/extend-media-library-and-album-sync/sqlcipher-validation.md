# SQLCipher Validation

## Status

2026-11-09，按用户“同意，先验证 SQLCipher”的授权完成 Windows 隔离验证，并准备 iOS 探针。**Windows 的 11 项基础检查与 10 个进程中断恢复场景通过；iOS 仅完成二进制预检，尚无 Xcode 编译或运行结果。** 任务 1.3 保持未完成，正式 App 尚未接入数据库；任务 2.4、5.3 及平台相册跨启动任务也没有解除门槛。

用户已确定三天周期内可使用系统安全存储辅助解锁、重启仍需四位应用锁。这是产品规则，不是本次探针已实现的能力。正式密码派生与密钥保管设计继续见 `local-metadata-design.md`。

## Candidate and Provenance

| 项目 | 本次实际证据 |
| --- | --- |
| 绑定 | 独立包 `scripts/sqlcipher_probe`，锁定 `sqlite3 3.9.1`，通过顶层 hooks 的 `source: sqlcipher` 选择原生资产 |
| Windows 工具链 | Flutter 3.47.9 / Dart 3.13.7；`dart build cli` 打包 EXE 与 DLL，实际运行 Windows x64 |
| 实际后端 | 数据库连接返回 SQLCipher `4.20.0 community`、SQLite `3.54.1`、provider `openssl`、OpenSSL `4.1.0 23 Oct 2026` |
| 下载来源 | sqlite3.dart 维护者的 GitHub Release `sqlite3-3.9.1`；API 返回发布时间 2026-11-08 12:46:51 UTC、immutable=true |
| 校验 | DLL 与 iOS dylib 的 SHA-256 分别匹配已发布 Dart 包 `asset_hashes.dart` 和 Release 资产摘要；未验证 SLSA 签名 |
| 原生配置 | 实测含 `HAS_CODEC`、`TEMP_STORE=2`；每个测试连接显式 `temp_store=MEMORY`、`cipher_memory_security=ON`、`synchronous=FULL`；未启用明文头部 |
| 正式工程影响 | App 根依赖、平台工程与 Codemagic 配置未因本轮验证增加数据库。根分析配置排除独立探针包，由探针自己分析 |

SHA-256：

```text
sqlcipher.x64.windows.dll          f13740c540bc2fd35c52372bf6effcaaf488b09e81c11d1896ac61b6cab06dce
libsqlcipher.arm64.ios.dylib        3ce5dec3e52c008ec33eadfd45ae441ca6c2ca82643cf6fd191a8f228b7192e1
libsqlcipher.arm64.ios_sim.dylib    4449e5c5078e768bdf6ba874992a5b14770f83876cc84ebda7fa0b4ca3e8d900
```

## Windows Evidence

脚本入口：`scripts/sqlcipher_probe/verify-windows.ps1`；同进程检查在 `lib/probe.dart`，父子进程中断检查在 `bin/verify.dart`。所有数据库位于被忽略的 `build/sqlcipher-probe/results/`，初次通过报告为 `run-60721508/report.json`，完整复现脚本复跑报告为 `run-106271a6/report.json`（2026-11-09 07:00:35 UTC）。人工数据为 1200 条路径／文件名、相册及来源记录，数据库 2,486,272 字节；不使用用户照片、密码或 PIN。

| 检查 | 结果及边界 |
| --- | --- |
| 后端身份 | `cipher_version` 非空并且真实页面可读，避免普通 SQLite 静默忽略 key pragma 的假成功 |
| 主库与完整性 | 无 SQLite 明文头，UTF-8／UTF-16 LE／BE 人工标记未命中；SQLite integrity_check 与 SQLCipher 页面认证检查通过 |
| 密钥拒绝 | 错误随机密钥和无密钥读取均失败，主文件字节不变；正确密钥重开成功。未测试生产照片密码派生 |
| 篡改 | 翻转密文页面中的一个字节，正确密钥也不能读取；未自动重建空数据库 |
| 回滚日志 | 未提交更新产生 2,610,720 字节 journal，未命中明文标记；rollback 恢复旧文件名 |
| WAL 与 SHM | 产生 2,480,272 字节 WAL 和 32,768 字节 SHM，未命中明文标记；独立连接可读到完整提交状态。日志头／结构信息不等同加密数据页 |
| 临时存储 | 实际创建 TEMP 表，查询计划使用 TEMP B-TREE，排序 1200 行；专用临时目录观察为空。该观察不覆盖瞬时删除文件和系统交换／转储 |
| 加密导出 | 使用 sqlcipher_export，目标显式设置独立随机密钥；目标可读、原密钥不能读、无人工明文标记。不是生产备份／迁移实现 |
| 新版本保护 | 设置 user_version=999 后以只读方式检查，主文件不变；只是后端能力示例，正式版本拒绝适配器尚未实现 |
| 相册事务 | 结束旧关联、建立新相册、推进来源名称／代次在一个事务；另一个来源的停止状态与 App 加入／移出覆盖保留 |
| 进程中断 | DELETE 与 WAL 各在 begin、ended、created、observed、committed 五个点，由父进程强制结束子进程；提交前恢复旧状态，提交后保留新状态，重复重放不新增第三个相册 |

密钥由安全随机源生成，只在本进程内存与匿名 stdin 管道中传递；未写入文件、命令参数、环境或报告。探针中的原始随机密钥用法是为了隔离后端验证，**不表示已确定用户密码派生或正式密钥保存方案**。

测试期间修正了探针自身的一处观测问题：Windows 活动 WAL 的共享内存含跨进程字节锁，父进程在子进程仍运行时读取会失败。现于强制结束后、打开恢复连接前检查残留 DB/WAL/SHM，再执行恢复验证；没有忽略读失败或跳过 WAL 场景。

## iOS Evidence and Gaps

已下载并校验上述 ARM64 真机／模拟器 dylib，用 `inspect_macho.py` 读取 Mach-O：真机平台为 iOS、最低版本 12.0；模拟器平台为 iOS Simulator、最低版本 14.0；均含 sqlite3_key、sqlite3_open_v2、sqlcipher_extra_init 导出符号。当前 App 的 deployment target 为 iOS 15.0，版本下限未发现冲突。构建脚本使用 Apple CommonCrypto 路线，二进制依赖 Foundation、Security、CoreFoundation 和 libSystem；这不是实际加载成功的证据。

`prepare_ios.py` 已在根 build/ 生成独立 Flutter 工程 `sqlcipher-ios-probe-s2r2evuf`，将共享的 11 项检查接入 integration_test，并提供可显示检查结果的模拟器 App 入口。Windows 上 `flutter pub get` 与 `flutter analyze --no-pub` 已通过；这不编译或执行 iOS 原生代码。顶层 pubspec 明确指定 SQLCipher hooks，不新增旧 sqlcipher_flutter_libs 插件；不要求为该探针预先切换 CocoaPods。当前 iOS 工程使用 SPM，但需要后续实测 native assets 与媒体插件的共同打包／动态加载，不能仅靠依赖声明验收。

仍缺 macOS/Xcode 构建、模拟器执行、真机数据保护与挂起／终止恢复证据。iOS 不使用 CLI 的子进程中断方式，需专门的宿主终止／重启夹具；同进程事务测试不能代替该部分。准备步骤和命令见探针 README，尚未推送或触发 Codemagic。

## Maintenance and Acceptance Boundary

- 候选使用 MIT 许可的 Dart 绑定、SQLCipher Community 的 BSD 风格许可；Windows 构建静态链接 OpenSSL，其版本、许可及分发告知也要纳入正式产物。官方商业支持版不是本次使用的构建。正式接入时需保留各版本完整许可／告知；本轮仅做源文件核对，未分发安装包。
- 这次验证支持继续评估 SQLCipher，但不等于完成生产安全审计、第三方依赖全量漏洞审查或全部存储验收。
- 未覆盖大图库性能、断电／磁盘满／设备故障、持续系统级文件 I/O 跟踪、用户权限与备份策略、跨端版本升级、正式元数据适配、系统安全存储、PIN 限速、三天期限与时钟回拨。不得据本报告声称本机完全无明文痕迹。
- 文件型临时存储必须持续禁止；每个连接均需校验后端与配置，备份／迁移必须明确设置加密目标，不能退回明文 SQLite。Windows 原照片目录仍按用户要求保留普通原文件。
- 正式接入前继续完成 iOS 实测，以及照片密码派生、目录密钥包裹、平台保护材料和到期撤销设计。用户已确认的重启体验不再重复征求选择。

## Delivery Checks

本轮交付检查：探针 `dart analyze` 与格式检查通过；生成的 iOS 测试工程依赖解析和 `flutter analyze --no-pub` 通过；主 App `flutter analyze --no-pub` 通过；PowerShell／Python 脚本语法检查通过；OpenSpec 严格校验 9 项通过、0 项失败，`git diff --check` 通过。未改 App 业务代码，因此未重跑上一阶段的 63 项 Flutter 用例，也未重建 App。Windows 原型进程仍在运行且响应正常。

## References

- SQLCipher 设计及临时文件：<https://www.zetetic.net/sqlcipher/design/>
- SQLCipher API（key、导出、完整性及内存保护）：<https://www.zetetic.net/sqlcipher/sqlcipher-api/>
- 固定版本的 Dart native assets 文档：<https://github.com/simolus3/sqlite3.dart/blob/sqlite3-3.9.1/sqlite3/doc/hook.md>
- 原生构建脚本：<https://github.com/simolus3/sqlite3.dart/blob/sqlite3-3.9.1/tool/build_sqlite.dart>
- SQLCipher 4.20.0 许可：<https://github.com/sqlcipher/sqlcipher/blob/v4.20.0/LICENSE.md>
- Dart 绑定许可：<https://pub.dev/packages/sqlite3/versions/3.9.1/license>
- OpenSSL 许可：<https://github.com/openssl/openssl/blob/openssl-4.1.0/LICENSE.txt>
- SQLite 原子提交：<https://sqlite.org/atomiccommit.html>
