# Windows 客户端：编译与运行

本目录是 Windows Flutter 工程根，正常入口为 `lib/main.dart`。共用安全、模型与格式代码来自相邻的 `../shared/`，请完整检出仓库后编译，不能只复制本目录源码。

## 环境

- Windows x64。
- Flutter **3.47.9 stable**，当前本机缓存版本信息对应 Dart **3.13.7**；依赖以各 `pubspec.lock` 和原生CMake固定版本／摘要为准，不在迁移时升级。
- Visual Studio 2022 的 C++ 桌面开发工具、Windows SDK 和 CMake 工具链。
- 首次获取Flutter依赖与原生依赖需要网络。Flutter SDK路径由脚本参数指定，以下 `D:\tools\flutter` 只是当前电脑示例。

可用 `flutter doctor -v` 查看实际工具链问题。不要将安装器完成提示当作项目已经编译成功。

## 使用脚本编译

在 PowerShell 执行，检出路径和 SDK 路径按自己的电脑修改：

```powershell
Set-Location 'D:\encrypted-photo-app\src\windows'
& '.\scripts\build\build-windows.ps1' -FlutterRoot 'D:\tools\flutter'
```

脚本定位当前客户端工程、获取依赖并以 `lib/main.dart` 构建 Release。依赖或编译失败会返回错误；不会启动应用、运行测试、删除用户照片库或推送仓库。若当前安装工具链的状态需要显式后备路径，可查看脚本的 `-UseInstalledToolchain` 参数；不要用后备路径跳过依赖摘要或签名检查。

如果 Flutter 明确报告缺少符号链接支持，脚本会核对已解析插件的来源，在本工程内建立目录联接后重试；不需要脚本更改系统开发者模式或申请管理员权限。其他依赖错误仍会停止。标准命令方式遇到该问题时，可改用上述脚本。

## 使用标准命令编译

```powershell
Set-Location 'D:\encrypted-photo-app\src\windows'
$flutter = 'D:\tools\flutter\bin\flutter.bat'
& $flutter pub get
if ($LASTEXITCODE -ne 0) { throw '依赖获取失败' }
& $flutter analyze --no-pub
if ($LASTEXITCODE -ne 0) { throw '静态分析失败' }
& $flutter build windows --release --no-pub --target lib/main.dart
if ($LASTEXITCODE -ne 0) { throw 'Windows 编译失败' }
```

如果需要使用当前电脑的本机代理，在同一 PowerShell 会话、联网步骤之前设置：

```powershell
$env:HTTP_PROXY = 'http://127.0.0.1:10808'
$env:HTTPS_PROXY = 'http://127.0.0.1:10808'
$env:NO_PROXY = 'localhost,127.0.0.1,::1'
```

这是可选的构建网络配置；换电脑时使用自己的有效代理，不把该地址或凭据写成所有使用者的默认要求。

## 编译产物

所有新的 Windows 编译产物位于本目录的 `build/` 下，正常程序为：

```text
build/windows/x64/runner/Release/encrypted_photo_app.exe
```

当前检出位置对应：

```text
D:\encrypted-photo-app\src\windows\build\windows\x64\runner\Release\encrypted_photo_app.exe
```

原生 source_reader 输出、依赖下载缓存及独立Windows探针产物也在本host的build下。`.dart_tool/`和平台ephemeral属于工具生成缓存，不是交付程序。build及缓存不进入Git；新检出没有build时，构建过程会创建它。

用户运行时可在本目录执行：

```powershell
.\run-windows.cmd
```

也可以直接打开上述EXE。**复制或交付时保留整个 `Release` 文件夹**，其中包括Flutter、播放器、SQLCipher、libsodium、source_reader、ExifTool、data与许可证等依赖。只复制EXE无法构成完整客户端。

## 清理编译包和中间产物

关闭 Windows 客户端后，双击仓库根目录的 [clean-build.cmd](../../clean-build.cmd)。它调用本工程的维护脚本，清理白名单中的构建包、依赖缓存、Dart/Flutter 中间产物及原生临时文件；保留源码、OpenSpec、照片库和 `src/.local/` 中的历史账号与报告。正常程序仍在运行时会报错停止，不自动结束进程。

在本目录的 PowerShell 中可先预览，再按需执行：

```powershell
& '..\..\clean-build.cmd' -WhatIf -NoPause
& '..\..\clean-build.cmd' -NoPause
```

不带参数双击会执行清理，完成后显示结果并等待按键；`-WhatIf` 只列出路径，`-NoPause` 关闭结束时的按键等待。清理后按本文重新编译，依赖缓存可能需要重新下载。

## 数据与故障处理

- 照片库仍位于首次选择的数据目录或默认 `%LOCALAPPDATA%\EncryptedPhotoApp`；源码重整不设置新密码、不迁移用户库。不要删除照片库来解决编译问题。
- 依赖下载失败时检查网络或代理；固定摘要不匹配时必须失败，不能跳过完整性验证。
- 编译提示文件占用时，先由使用者关闭正在运行的程序；构建工具不自动终止用户进程。
- 旧根build中混有测试账号、人工来源和报告，保全目录为 `../.local/pre-structure/build/`，维护清理不处理它。需要清理历史空间时另行决定。
- 测试由用户统一安排，默认编译命令不运行测试套件。静态分析或编译成功不代表媒体兼容性、同步及安全场景已验收。

最新迁移／构建结果见[当前状态](../../openspec/project/current-status.md)。Gitee未实现、iOS暂缓及Windows完整验收边界见根级规范和OpenSpec，不能从编译结果推断全部功能完成。
