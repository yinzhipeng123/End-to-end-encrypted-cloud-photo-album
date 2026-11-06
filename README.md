# 密屿 · encrypted-photo-app

Flutter + Dart 的中文照片管理交互原型，当前交付 Windows 桌面体验。产品目标是个人在 Windows 与 iPhone 之间管理并加密同步照片；本轮实现明确标识的本地演示会话。

## 仓库内容与 AI 交接

本仓库保存 App 源码、OpenSpec 资料及复现开发所需的配置、测试和说明，沿用 Flutter 标准目录结构。

| 内容 | 路径 |
| --- | --- |
| 共用界面与业务代码 | `lib/` |
| Windows、iOS 平台工程 | `windows/`、`ios/` |
| 必需的演示资源与测试 | `assets/`、`test/` |
| 依赖与工程配置 | `pubspec.yaml`、`pubspec.lock`、`.metadata`、`analysis_options.yaml` |
| 构建与启动脚本 | `scripts/`、`run-windows.cmd` |
| iOS 云端构建配置 | `codemagic.yaml` |
| 产品规格、变更与历史记录 | `openspec/` |
| AI 接手入口与项目说明 | `AGENTS.md`、`README.md` |

`build/`、`.dart_tool/`、`.idea/`、`.agents/` 和本机日志等由 `.gitignore` 排除，留在本机即可。`assets/photos/` 内置样片是应用运行资源，需要随源码提交。这个仓库不用于保存用户原图或照片密文备份。

让下一位 AI 从 [AGENTS.md](AGENTS.md) 开始，接着阅读本文件和 `openspec/config.yaml`，就能了解项目状态。`.agents/skills/` 是本机生成的 OpenSpec 工作流，不是项目需求的唯一记录。项目使用 OpenSpec CLI 1.16.0；更换 AI 工具时可按该工具需要生成对应工作流，保留现有规格和变更。

## 下一项需求：Windows 文件夹自动导入

以下需求于 2026-11-06 在原型体验后确认，**尚未实现，也尚未创建对应的新变更**：

1. 导入入口支持选择电脑上的照片文件夹。
2. 自动扫描所选文件夹及其所有子文件夹，将找到的照片加入 App 相册；Windows 原图继续保留为普通文件。
3. App 运行期间发现新增照片并自动导入。
4. 下次启动时补扫 App 关闭期间遗漏的新增照片。
5. 在 Windows 文件管理器中删除或移走原图后，App 标记“本地原图缺失”，保留已有仓库副本；需要删除远端副本时，通过 App 的删除选项操作。

下一步应建立独立变更，明确真实文件夹导入的设计、持久化与验收，并处理现有原型“只操作内置样片”的范围调整。媒体格式、重复识别、目录与相册映射、监测及补扫的具体实现仍待设计；这些细节不应被误写成已经确认。这里的“加入相册”不代表已经加密上传，现阶段真实加密及仓库同步仍未接入。

## 启动 Windows 应用

本机已完成构建时，双击项目根目录的 [run-windows.cmd](run-windows.cmd)，即可启动程序：

```text
D:\encrypted-photo-app\build\windows\x64\runner\Release\encrypted_photo_app.exe
```

程序需要同目录的 DLL 和 `data` 文件夹，不能只复制 EXE。发布构建可直接运行，不依赖 Flutter 开发服务。

Git 仓库不包含 `build/`，因此新检出源码后需要先按“开发与构建”生成程序，再使用此启动脚本。

## 体验方式

首次打开直接进入预置演示照片库。内置 16 张样片，部分照片最初处于待同步状态，自动演示加密、分块和上传。

| 功能 | 操作 |
| --- | --- |
| 浏览与搜索 | 按日期浏览；搜索照片名或文件名，切换已同步、待同步、仅本地、仅仓库筛选 |
| 整理照片 | 点击照片查看详情，收藏、创建相册、添加或移出相册 |
| 导入与导出 | 导入 1、3 或 6 张内置样片；详情中可体验导出，不读取或写入用户照片 |
| 仓库选择 | 同步中心或设置 → 管理仓库，选择 GitHub/Gitee，模拟授权并选择私有仓库 |
| 四位应用锁 | 右上角锁图标；默认 PIN 为 `2468` |
| 照片解密密码 | 默认演示密码为 `photo-demo-2026`，与 PIN 独立 |
| 三天强制验证 | 设置 → 模拟到期；禁止查看照片并暂停同步，只有正确照片密码解除到期限制 |
| 新设备解锁 | 设置 → 体验解锁；模拟平台授权后仍要求照片密码 |
| 三种删除范围 | 照片菜单 → 选择删除范围，模拟删除本地、同步删除或删除仓库；取消不改变状态 |
| 异常与恢复 | 设置中模拟网络、权限、容量问题或下一次删除失败 |
| 首次设置 | 设置 → 重新体验首次设置，配置虚构照片密码、PIN 和仓库 |
| 重置 | 设置 → 重置全部演示数据；关闭后重新启动也恢复默认会话 |

演示密码只在内存中比较，不是密码学实现；请勿输入真实密码。Windows 源目录、iPhone 系统相册及真实仓库均不会被访问。界面容量、分块和另一客户端为虚构状态；示例块数不确定正式格式或算法。

普通 PIN 锁屏是否暂停同步可在演示控制台切换，仅供体验。照片密码到期则始终暂停。删除后不会自动重新上传或下载对应演示项，这不是正式删除协议。切换仓库会将本地样片重新排队，不把旧目的地的状态冒充新目的地备份。

## 开发与构建

在另一台已配置好 Flutter Windows 开发环境的机器上，从项目根目录执行：

```powershell
flutter pub get
flutter analyze
flutter test
flutter build windows --release
.\run-windows.cmd
```

下面的 SDK 路径与安装情况仅为本机记录，换机器不要求使用相同磁盘路径。构建脚本可通过 `-FlutterRoot` 指定 Flutter SDK 目录。

本机环境：Flutter 3.47.9、Dart 3.13.7、Visual Studio Build Tools 2022 17.14.44、Windows SDK 10.0.26100。Flutter 位于 `D:\tools\flutter`，未修改全局 PATH。SDK 压缩包已对照官方发布索引校验 SHA-256，下载使用 Flutter 中国镜像。

```powershell
cd D:\encrypted-photo-app
$env:PATH = 'D:\tools\flutter\bin;' + $env:PATH
$env:FLUTTER_STORAGE_BASE_URL = 'https://storage.flutter-io.cn'
$env:PUB_HOSTED_URL = 'https://pub.flutter-io.cn'
$env:FLUTTER_SUPPRESS_ANALYTICS = 'true'
flutter pub get
flutter analyze
flutter test
flutter run -d windows
```

标准发布构建：

```powershell
.\scripts\build-windows.ps1
```

本次首次安装后，Visual Studio Installer 返回 3010 并报告等待重启，导致标准 `flutter build windows` 拒绝选择工具链。已安装的 MSVC 和 Windows SDK 通过实际 CMake 编译检测，因此本次显式指定安装目录及版本，用 CMake/MSBuild 构建同一个 Flutter Windows 工程：

```powershell
.\scripts\build-windows.ps1 -UseInstalledToolchain
```

该路径不修改 Flutter SDK、系统注册表或安装器状态。用户方便时自行重启完成安装，之后可使用标准 Flutter 构建和热重载；已生成的发布包可直接运行。SDK 位于其他位置时可传入 `-FlutterRoot`。

## iOS 云端构建：Codemagic

根目录的 [codemagic.yaml](codemagic.yaml) 为本 Flutter 项目配置了三条手动运行的 macOS 工作流，Flutter 固定为与当前工程一致的 `3.47.9`，Xcode 使用 Codemagic 的 `latest`。三条流程都会获取依赖、执行静态分析与 Flutter 测试，然后构建 iOS。当前 iOS 工程使用 Swift Package Manager，流程不执行针对 CocoaPods 工程的 `pod install`。

| 工作流 ID | 用途 | 产物与条件 |
| --- | --- | --- |
| `ios-simulator` | **在浏览器中预览 App，当前优先使用** | 面向模拟器的 `Runner.app`，不需要苹果分发签名；浏览器预览需启用 Codemagic App Preview |
| `ios-unsigned` | 验证真机目标的 iOS 编译 | 真机目标的无签名 `.app.zip`，不能直接安装到 iPhone，也不能替代模拟器产物 |
| `ios-adhoc` | 构建真机安装包 | 签名 `.ipa`，需要付费 Apple Developer Program 账号、有效的分发证书及包含目标 iPhone 的 Ad Hoc 描述文件 |

用户于 2026-11-06 确认目前没有付费苹果开发者账号，并选择先创建模拟器应用进行预览。因此当前使用 `ios-simulator`；`ios-adhoc` 的配置已经准备好，但签名条件尚未满足。模拟器产物不能直接安装到真实 iPhone。

在 Codemagic 中打开本 GitHub 项目，使用 YAML 配置，选择 `main` 分支及所需工作流，再点击 **Start new build**。本文件未设置自动触发，也未设置向 App Store Connect 上传或发布应用。

本次模拟器预览操作：

1. 选择 `main` 分支和 `ios-simulator` 工作流，启动构建。
2. 流程执行 `flutter build ios --simulator --debug --no-codesign`，生成 `build/ios/iphonesimulator/Runner.app`，并检查其平台确实为 `iphonesimulator`。
3. YAML 直接把上述 `.app` 目录声明为构建产物。构建成功后，在构建概览中点击该产物旁的 **Quick Launch**，即可在浏览器里的 iOS 模拟器中预览。
4. Codemagic 的 App Preview 仅供团队使用，需要在团队的 App Preview 页面启用，并有独立的试用额度和计费。生成模拟器产物不等于已经开通此服务；这里不会替用户开启计费或启动预览会话。

以后启用 `ios-adhoc` 前，需要准备：

1. 开通付费 Apple Developer Program，在开发者后台登记目标 iPhone 的 UDID，并注册与应用匹配的 App ID。
2. 当前工程和 YAML 的 Bundle ID 均为 `dev.miyu.encryptedPhotoApp`。它目前只是代码中的标识，并不表示已在苹果后台注册；若使用其他标识，需要同时更新 `ios/Runner.xcodeproj/project.pbxproj` 和 YAML。
3. 在 Codemagic 的团队设置中进入 **Code signing identities → iOS certificates / iOS provisioning profiles**，导入含私钥的分发证书（`.p12`）和匹配的 Ad Hoc 描述文件，或通过其支持的 Apple 开发者集成获取这些资料。描述文件须包含目标设备，且与证书、App ID 相匹配。
4. 选择 `ios-adhoc` 运行。Codemagic 会根据 `ios_signing` 安装签名资料，`xcode-project use-profiles` 配置工程和导出选项，随后生成 IPA。只有描述文件包含的设备可以使用这条 Ad Hoc 安装路线。

签名资料和密码只配置在 Codemagic 的安全设置中；`.gitignore` 已排除 `.p12`、`.p8` 和 `.mobileprovision` 文件。首次云端成功构建和真机安装验证仍待执行，Windows 上的检查不能替代这两项验收。

2026-11-06 本机验证：Codemagic 官方 JSON Schema 校验通过，16 段 Bash 脚本语法检查通过，`flutter analyze --no-pub` 无问题，`flutter test --no-pub` 的 29 项测试全部通过。云端模拟器编译和浏览器 App Preview 尚未实际运行。

官方参考：[App Preview 指南](https://docs.codemagic.io/yaml-distributing/app-preview/)、[Flutter YAML 指南](https://docs.codemagic.io/yaml-quick-start/building-a-flutter-app/)、[iOS 签名配置](https://docs.codemagic.io/yaml-code-signing/signing-ios/)、[Apple 账号能力对比](https://developer.apple.com/support/compare-memberships/)。

## 工程结构

验证记录（2026-11-06）：格式检查通过，`flutter analyze` 无问题，`flutter test` 的 29 项测试全部通过；Windows Release 已经由上述 CMake/MSBuild 路径构建并实际启动。原生窗口检查确认照片库、样片和设置页面可显示；锁屏、到期、恢复、仓库选择及删除结果等由行为和界面测试验证。OpenSpec 严格校验通过。iOS 尚未验收。

- `lib/model/demo_store.dart`：演示照片、相册、凭据、访问条件、同步状态和删除范围。
- `lib/ui/`：中文桌面界面、窄窗口抽屉、照片详情及演示流程。
- `assets/photos/`：本地样片和[来源记录](assets/photos/SOURCES.md)，运行期间不下载远程图片。
- `test/`：行为、访问控制、对话框与宽窄布局测试。
- `windows/`、`ios/`：平台工程；iOS 仅有骨架，未构建、未签名、未进行真机验收。
- `scripts/build-windows.ps1`：发布构建入口。
- `codemagic.yaml`：iOS 模拟器预览、真机目标无签名编译验证与 Ad Hoc 真机安装包三条云端构建流程；首次云端运行待验证。

## OpenSpec

- [项目配置](openspec/config.yaml)
- [产品主规格](openspec/specs/)
- [当前实施提案](openspec/changes/implement-windows-photo-prototype/proposal.md)
- [原型实现设计](openspec/changes/implement-windows-photo-prototype/design.md)
- [当前任务清单](openspec/changes/implement-windows-photo-prototype/tasks.md)
- [归档的产品决定与 Q01–Q09](openspec/changes/archive/2026-11-06-design-photo-app-prototype/design.md)

当前变更为 `implement-windows-photo-prototype`。原始规划归档及其 18 项任务保留不变，新变更追踪本次 Windows 原型交付，后续 iOS 验收与正式能力另行安排。

```powershell
$env:OPENSPEC_TELEMETRY = '0'
openspec.cmd status --change implement-windows-photo-prototype
openspec.cmd list
openspec.cmd validate --all --strict --no-interactive
```

真实授权协议、加密及密码派生、密钥保存、密码遗忘、分块格式、后台同步、删除冲突与历史清理仍待设计。原型通过不表示这些正式能力已实现。

`D:\OpenSpec` 是工具源码；`D:\encrypted-photo-app` 是本产品工程。照片密文仓库与产品源码仓库用途不同。
