# src/windows/README.md 编写要求与拟用命令

这是方案内的README内容草案，当前工程尚未迁移，不应按下面的新路径执行。apply阶段在实际`src/windows/README.md`落实，并用实际静态／构建结果核对。

## 说明范围

1. 当前目录是Windows Flutter工程根；共享源码在`../shared`，需要完整检出仓库，不能只复制windows源码目录构建。
2. 列明Windows x64、既有Flutter固定版本（当前Codemagic配置为3.47.9，实施时核对本机SDK版本）、Visual Studio 2022 C++桌面工具链及Windows SDK；Flutter SDK路径可通过参数传入，不能要求所有机器都装在D盘。
3. 依赖版本以pubspec.lock及CMake固定摘要为准；首次获取需要网络，已有本机代理可按需配置，不能写入凭据或把代理设为所有用户强制配置。

## 推荐脚本编译

在PowerShell中执行，路径按本机检出位置调整：

```powershell
Set-Location 'D:\encrypted-photo-app\src\windows'
& '.\scripts\build\build-windows.ps1' -FlutterRoot 'D:\tools\flutter'
```

脚本获取依赖并以`lib/main.dart`构建Release，失败应以非零状态停止并保留错误。脚本不得启动App、运行测试、清理用户照片库或自动推送。

## 标准命令编译

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

将以下可选代理片段放在同一PowerShell会话的联网步骤之前；只描述用户本机可用配置，换电脑按自己的代理调整，不写进项目默认网络逻辑：

```powershell
$env:HTTP_PROXY = 'http://127.0.0.1:10808'
$env:HTTPS_PROXY = 'http://127.0.0.1:10808'
$env:NO_PROXY = 'localhost,127.0.0.1,::1'
```

## 产物与运行

- 所有新的Windows构建产物在`src/windows/build/`下。Flutter工具缓存如`.dart_tool/`不属于可交付程序，不提交。
- 正常程序：`build/windows/x64/runner/Release/encrypted_photo_app.exe`。
- 用户自行运行：在Windows目录执行`.\run-windows.cmd`，或打开上述EXE。
- 复制／交付须保留完整Release目录，包括DLL、data、metadata与许可；不要只复制EXE。
- build属于生成目录，不进入Git；新检出没有build时由构建脚本创建。程序密码与用户数据不在这里，源码重整不会设置新密码。

## 故障与边界

- 依赖下载失败检查本机网络／代理；校验失败不能跳过固定摘要。
- 缺少C++工具链按`flutter doctor -v`实际结果处理，不把安装程序返回当作编译通过。
- 文件被运行中的程序占用时提示用户关闭，不自动杀进程。
- 构建通过不等于媒体、同步或安全验收通过。测试由用户统一安排，不把测试套件塞入默认构建命令。
- 数据路径仍是已选照片库或默认`%LOCALAPPDATA%\EncryptedPhotoApp`；不可通过清空它来解决构建问题。
- 根旧build的历史保全在`src/.local/pre-structure/build/`，维护清理不处理它。用户想回收历史空间时另行确认。
