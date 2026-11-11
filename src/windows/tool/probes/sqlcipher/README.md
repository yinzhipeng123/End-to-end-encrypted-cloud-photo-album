# SQLCipher 隔离验证

此目录是独立 Dart 包，验证 SQLCipher 后端；它不替代 App 的持久化实现。只生成随机测试密钥与人工数据。密码派生、PIN、系统安全存储和三天复验不在本探针中实现。

## Windows

在 `src/windows/` 目录运行（当前锁文件需要 Dart 3.13+；本轮使用 Flutter 3.47.9 / Dart 3.13.7）：

```powershell
$env:PUB_HOSTED_URL = 'https://pub.dev'
.\tool\probes\sqlcipher\verify-windows.ps1 -FlutterRoot D:\tools\flutter
```

脚本使用本目录的锁文件、分析独立包、通过 `dart build cli` 打包 native assets，并核验 Windows x64 DLL 哈希，然后运行探针。普通 `dart compile exe` 不支持此依赖的 build hooks。探针必须运行编译后的 bundle；直接 `dart run bin/verify.dart` 不能用于自启动子进程的恢复测试。

每次使用新的 `../.local/acceptance/sqlcipher-probe/results/run-*` 目录，不覆盖旧结果、不清理用户文件。报告不含测试密钥／人工敏感标记；测试密钥只在内存和匿名管道中传递，不进入命令参数、环境或磁盘。结束后遗留的测试数据库仍为密文，因不保留密钥而不能再读；需要复现时重新运行。

测试内容：后端身份与配置、正确／错误／无密钥读取、主库／WAL／journal／SHM 哨兵检查、临时表与排序、独立密钥加密导出、页面篡改、未来版本只读检查，以及 DELETE／WAL 两种模式的五个事务边界强制结束进程和重放。

## iOS 准备与实际验收

可以在 Windows 生成工程，真正的构建和执行须使用 macOS、Xcode 与 Flutter。准备脚本只在`src/.local/probes/` 下生成隔离工程，不更改现有 App、Codemagic 配置，不推送、不触发云任务：

```bash
python3 tool/probes/sqlcipher/prepare_ios.py
# 进入脚本输出的 src/.local/probes/sqlcipher-ios-probe-<随机值> 目录
flutter pub get
flutter analyze --no-pub
flutter build ios --simulator --debug --no-codesign --no-pub
flutter devices
flutter test integration_test/sqlcipher_test.dart -d '<已启动的 iOS 模拟器 ID>' --no-pub
```

在 Windows 生成时可传 `--flutter D:/tools/flutter/bin/flutter.bat`。生成工程的顶层 pubspec 显式选择 `source: sqlcipher`；不能只依赖路径依赖中的 hooks 配置。此路线走 Dart native assets，无需增加旧的 `sqlcipher_flutter_libs` 插件或预先改用 CocoaPods。是否与正式 App 的 SPM 及媒体插件共同打包成功仍需另测。

模拟器 `.app` 位于生成工程的 `build/ios/iphonesimulator/Runner.app`；启动后展示同进程测试结果，可用于单独的预览验证。**生成文件、静态分析、预览入口或有 dylib 均不代表 iOS 测试已经通过。** integration_test 运行 11 项基础检查，不含 CLI 的强制结束子进程场景，因为 iOS 不允许该进程模型。

后续 iOS 验收还需要：实际模拟器加载及 11 项检查、真机加密存储与保护等级、系统挂起／终止后恢复、在事务边界被宿主终止后重新启动的测试夹具、与现有媒体插件及 SPM 联合构建。不要用同进程 rollback 替代系统终止测试，也不要为跨重启夹具把生产密码／密钥写入明文文件。

已下载二进制可用下列只读命令核验（文件放在Windows host 的 `build/probes/sqlcipher/vendor/`）：

```powershell
python tool/probes/sqlcipher/inspect_macho.py build/probes/sqlcipher/vendor/libsqlcipher.arm64.ios.dylib build/probes/sqlcipher/vendor/libsqlcipher.arm64.ios_sim.dylib
```

## 测试边界

- SQLite 的认证加密检查、错误密钥拒绝和字节哨兵检查需结合使用。找不到特定字符串不能证明所有临时文件、系统历史或交换文件均没有明文。
- 编译参数 `TEMP_STORE=2` 是默认值，探针在每个连接设置并读取 `temp_store=MEMORY`。临时目录观察是快照，不是系统级文件 I/O 跟踪。
- 强制结束进程不是断电或存储介质故障；本轮数据量约 2.5 MB，不是大图库性能验收。
- `cipher_memory_security=ON` 不能保证 Dart 字符串、进程转储和系统交换文件全部清零。测试用原始随机密钥不构成正式 KDF／密钥管理决定。
- 原生库来源是 sqlite3.dart 维护者的 SQLCipher Community 构建；已核验哈希，没有进行独立 SLSA 签名验证或密码学安全审计。

实际结果、来源版本与许可证清单见 `../../../../../openspec/changes/extend-media-library-and-album-sync/sqlcipher-validation.md`。

Windows 命令从 `src/windows/` 执行；脚本自身从任意工作目录定位 host。探针 Windows 编译产物统一在 `src/windows/build/probes/sqlcipher/`，测试数据和临时报告在受忽略的 `src/.local/acceptance/sqlcipher-probe/results/`；结束时汇总报告另存 `src/.local/reports/sqlcipher/`。旧根 build 已保全，不复用其账号或配置。
