# 密屿 · encrypted-photo-app

当前 Windows 编码包：**0.7.1+10**，正常入口已编译至 `build/windows/x64/runner/Release/encrypted_photo_app.exe`；运行时保留整个 Release 目录。静态分析与构建通过，本轮未启动、未执行功能测试。新增功能、技术决策与待用户统一测试项目见 [Windows 增量编码交接](openspec/changes/extend-media-library-and-album-sync/windows-followup-implementation.md)。

2026-11-11 Windows 编码接续（0.7.0+9）：按用户默认批准与统一测试安排，已接入真实本地／仓库媒体播放、实况标识配对与双资源发布、导出、三范围删除、回收恢复和加密操作记录。具体实现、依赖、资源边界及待验收矩阵见 windows-coding-delivery.md；决策见 windows-completion-decisions.md。新增实现均待用户测试，不勾选任务，仍26／73；Gitee能力缺口保留，iOS暂缓。正常入口lib/main.dart；本轮不运行App或测试、不提交推送归档。下文为历史记录，旧的“播放／导出／删除未实现”和“逐项待批准”在上述Windows范围内由本条接续。

2026-11-11 14:11 GitHub授权验收接续：网页拒绝、拒绝后重新授权、真实账号／仓库查询及设备码申请在途取消均已留证。用户明确确认取消前点过“断开本机连接”；账号消失与主动断开一致，不是取消误删连接。两次设备申请cancelled，停止等待且没有后续令牌请求。已显示设备码后的取消、保留原连接及其他GAR-2平台场景仍待验收；3.2不勾选，26／73不变。本轮无业务代码修改，见github-authorization-followup.md及github-auth-cancel-2026-11-11.json。

2026-11-11 授权验收准备：用户手动清理的29个路径已核对，随后按本轮需要重建依赖及双入口0.6.2+8。新增独立GitHub授权验收入口和仅允许授权／只读查询的真实传输观察器；22项测试、analyze及严格规格校验通过。隔离窗口位于build/github-auth-acceptance/runner，已运行并观察到PIN页，等待用户本人完成拒绝／重新授权。正常Release已按lib/main.dart重建，AOT不同且不含测试密码标记，正常包未启动。本轮没有新增应用业务改动、没有用户授权或仓库写入结果；3.2保持未完成，26／73不变。详见github-authorization-followup.md及security-evidence/github-auth-acceptance-2026-11-11.json；旧“当前没有可运行包”描述仅指清理后的历史时点。

2026-11-11 Windows 普通锁调整（0.6.2+8）：最小化／手动锁只关闭照片界面，已解锁进程继续监听导入、加密和同步；系统锁屏／睡眠／退出、72小时到期及时间异常仍暂停并撤销后台。重启需先解锁，手动暂停不会被解锁取消。121项关联回归和最终表单复核、静态检查、正常入口构建已通过；新版实际最小化时锁中导入通过，恢复窗口两次截图均为PIN页；任务2.9已完成，当前26／73，正常客户端已运行。真实GitHub锁中上传4.9尚未验收。见 [WBL-1](openspec/changes/extend-media-library-and-album-sync/windows-background-lock.md) 与 [实施记录](openspec/changes/extend-media-library-and-album-sync/windows-background-lock-implementation.md)。

Flutter + Dart 的隐私照片管理应用，目标是在 Windows 与 iPhone 之间管理并加密同步照片。当前先开发 Windows，iOS 需求保留。当前代码版本0.7.0+9支持真实文件夹递归导入、自动发现新增、重启补扫，以及本机相册、收藏、隐藏和多选批量整理；使用真实安全服务、加密存储与 GitHub 授权／仓库查询。GitHub加密传输、按需读取和恢复已接入，真实平台验收尚未完成；本地与仓库播放、实况多资源、导出和删除恢复已接入，仍待用户统一测试，Gitee未实现、iOS暂缓，不能称全部功能正式验收完成。

## 仓库内容与 AI 交接

本仓库保存 App 源码、OpenSpec 资料及复现开发所需的配置、测试和说明，沿用 Flutter 标准目录结构。

| 内容 | 路径 |
| --- | --- |
| 共用界面与业务代码 | `lib/` |
| Windows、iOS 平台工程 | `windows/`、`ios/` |
| 开源许可、历史样本与隔离测试 | `assets/`、`test/` |
| 依赖与工程配置 | `pubspec.yaml`、`pubspec.lock`、`.metadata`、`analysis_options.yaml` |
| 构建与启动脚本 | `scripts/`、`run-windows.cmd` |
| iOS 云端构建配置 | `codemagic.yaml` |
| 产品规格、变更与历史记录 | `openspec/` |
| AI 接手入口与项目说明 | `AGENTS.md`、`README.md` |

`build/`、`.dart_tool/`、`.idea/`、`.agents/` 和本机日志等由 `.gitignore` 排除，留在本机即可。`assets/photos/` 仅保留为历史隔离测试样本，不再随正式运行包打包；`assets/licenses/` 为随包提供的开源许可。这个仓库不用于保存用户原图或照片密文备份。

让下一位 AI 从 [AGENTS.md](AGENTS.md) 开始，接着阅读本文件和 `openspec/config.yaml`，就能了解项目状态。`.agents/skills/` 是本机生成的 OpenSpec 工作流，不是项目需求的唯一记录。项目使用 OpenSpec CLI 1.16.0；更换 AI 工具时可按该工具需要生成对应工作流，保留现有规格和变更。

## 当前实施状态（2026-11-11）

2026-11-11 代理更新（0.6.1+7）：Windows每次网络请求自动检测启动环境代理与系统手动HTTP代理；环境变量优先，无变量时可直接使用系统代理，因此不必通过命令行启动。云端同步显示检测到的来源／地址。实际本机127.0.0.1:10808在两条路径下访问GitHub API和设备端点均成功，39项相关回归通过。仅SOCKS、PAC/WPAD、HTTPS代理服务器及带凭据代理尚未支持，准确报错；不会将SOCKS伪装HTTP或失败后静默直连。代理连接成功不等于仓库初始化／备份已验收，详见[代理实施记录](openspec/changes/extend-media-library-and-album-sync/windows-proxy-implementation.md)。

安装入口修正：云端同步增加“安装 / 管理 GitHub App”按钮，打开固定GitHub官方管理页；仓库选择区域始终显示真实状态。账号授权和仓库安装分开，Codex Connector／Codemagic的安装不能代替本相册应用。用户最新截图中尚未显示本相册应用，实际安装待用户完成并刷新核验。24项最终定向回归、静态检查及OpenSpec校验通过，具体构建与验证边界见同步实施记录。

最新同步开发进度 **24／70**：WSR-1设计及Windows真实资源加密准备（4.1／4.2）完成。GitHub传输、自动／单项／批量上传、持久化队列、密文缓存、仓库状态筛选、按需图片查看、新目录恢复和改密发布已接入真实服务；**真实GitHub平台验收仍未完成，不能称同步已正式完成**。详见[同步实施与验收记录](openspec/changes/extend-media-library-and-album-sync/windows-sync-implementation.md)。本轮测试包使用隔离人工资源，正式启动入口仍为`lib/main.dart`。以下22／70、20／70及“上传尚未实现”等为此前阶段的历史记录，由本段接续。

最新完成 Windows 本机整理任务 **6.1／6.3**，进度 **22／70**。相册创建／改名／删除分组、收藏、成员和隐藏设置真实加密保存；列表、搜索、计数和全选遵守同一可见范围。6.2 本机多选／全选／批量整理已可用，但已同步／仅仓库筛选依赖真实传输，明确禁用，整项保持未完成。57 项相关回归、最终相关 9 项复核及跨进程事务中断恢复通过，详见 [本机整理实施记录](openspec/changes/extend-media-library-and-album-sync/windows-organization-implementation.md)。下文导入轮次的 20／70 和原验证数量为历史记录。

本轮完成 Windows 导入任务 5.1–5.3，进度 **20／70**。54 项定向回归通过，另完成实际 Windows 文件夹选择、图片显示／详情、三个新进程的提交中断／恢复，以及人工 H.264／HEVC／ProRes 文件导入验证。源文件保留原位和原字节，来源与媒体索引进入 SQLCipher schema v3。详情见 [Windows 导入实施记录](openspec/changes/extend-media-library-and-album-sync/windows-import-implementation.md)。下文此前版本与测试数量作为历史证据保留。

本轮已接入 GitHub 设备授权、DPAPI 令牌保存与刷新、SQLCipher 目标配置、私有仓库查询及锁定取消。41 项定向检查最终通过（测试分类与一次失败修正见 [GitHub 实施记录](openspec/changes/extend-media-library-and-album-sync/windows-github-implementation.md)），真实设备码端点通过，静态检查和正常 Windows 构建通过并已启动。用户已手动确认真实账号授权成功，提示尚未安装仓库；实际刷新／撤销和完整权限矩阵未验收，3.2／3.4–3.6 不勾选。正常运行不会使用 HTTP 测试替身。

导入前的 Windows 任务 2.5／2.6 基线为 17／70：实际系统锁屏和睡眠恢复、12 个 App 强制进程终止恢复场景及 4 个真实虚拟磁盘容量耗尽场景通过。修复 PIN 材料丢失时仍提示输入 PIN 的恢复问题，现明确要求通过照片密码重设应用锁。详见 [存储恢复验收记录](openspec/changes/extend-media-library-and-album-sync/windows-recovery-implementation.md)。这些历史测试数量保留原始范围；远端同步仍未实现。

当前变更 `extend-media-library-and-album-sync` 仍在实施中。正常入口已移除 DemoStore、默认凭据、样片和模拟执行；尚未实现的按钮明确禁用。

- **真实可用**：首次创建加密空库、密码／PIN 管理、72 小时复验、DPAPI 辅助解锁、SQLCipher 持久化、锁定撤销；文件夹递归导入、运行期发现新增、重启补扫、分页图片预览和真实详情；本机相册、收藏、任一相册隐藏、多选／当前完整结果全选及批量整理。
- **已接入、平台验收未齐**：GitHub 真实授权、令牌保护、私有仓库查询选择和本机断开。安装／授权／目标选择分别显示，不等于已备份。
- **尚未完成**：真实平台同步和异常矩阵验收、iOS系统相册跟踪、视频／实况播放与全格式图片支持、Gitee授权、普通导出及三种媒体删除。已接入的GitHub链路状态见顶部同步记录；旧会话预览与模拟整理代码仅作历史依据，正常入口不调用。
- **验证**：此前全套 143 项及数据位置选择 31 项保留为历史证据；2026-11-10 完成 43 项定向回归及上述原生锁屏／完整 App 中断／满卷恢复验收。正式目录五个中断场景为旧记录，不与新 App 12 场景混算。当前仅完成 Windows 安全与持久化范围，未来媒体／同步验收及 iOS 仍待实现。
- **未决条件**：GitHub 已注册，GAR-2、RAR-1 TD09-A及WSR-1已批准，安装仍须实际核验；Gitee 无自建服务的安全公开客户端尚未确认。删除、普通导出其余范围及跨设备相册元数据继续按评审门槛确认。ProRes 与 Live Photo 要求保留。

首次运行由用户自己设置照片密码和 PIN，没有默认密码。数据默认保存在 `%LOCALAPPDATA%\EncryptedPhotoApp`；首次设置页可选择其他本机父目录，程序在其中建立专用 `EncryptedPhotoApp` 子目录并显示完整路径。加密数据库与凭据材料写入所选位置，默认目录保留 DPAPI 保护的启动定位记录等少量文件；Windows 用户原照片目录保持原样。已有库不自动迁移，目标丢失、定位损坏、初始化未完成或库损坏不自动重建覆盖。

实施证据见 [Windows 存储与 App 接线报告](openspec/changes/extend-media-library-and-album-sync/windows-storage-implementation.md)，安全模块见 [安全实施报告](openspec/changes/extend-media-library-and-album-sync/windows-security-implementation.md)，精确进度及缺项见 [tasks.md](openspec/changes/extend-media-library-and-album-sync/tasks.md)。不得将编译成功或历史模拟测试说成完整正式交付。没有提交、推送或归档。

## 启动 Windows 应用

本机已完成构建时，双击项目根目录的 [run-windows.cmd](run-windows.cmd)，即可启动程序：

```text
D:\encrypted-photo-app\build\windows\x64\runner\Release\encrypted_photo_app.exe
```

程序需要同目录的 DLL 和 `data` 文件夹，不能只复制 EXE。发布构建可直接运行，不依赖 Flutter 开发服务。

Git 仓库不包含 `build/`，因此新检出源码后需要先按“开发与构建”生成程序，再使用此启动脚本。

## 当前版本使用方式

首次打开显示真实密码设置页，由用户设置 12–128 个字符的照片密码和四位 PIN。初始化创建加密空库后仍需输入 PIN；没有默认密码或内置照片。重启不会重新计算三天期限。

“程序的数据保存目的地”支持“选择文件夹”和“恢复默认位置”。例如选择 `D:\MyPhotoData`，实际使用 `D:\MyPhotoData\EncryptedPhotoApp`。取消选择保持原位置，未提交初始化不创建自定义库；已有同名子目录不覆盖，请选择其他位置。目标需支持本机私有目录权限，不能使用网络或链接目录。当前没有已建库迁移功能。

解锁后进入“访问与密码”设置页，可在“程序的数据保存目的地”下查看、选中当前实际数据目录的完整路径；默认和自定义位置都适用。

“所有照片”中点击“选择文件夹导入”，选择已有照片／视频目录。App 包含其实际子目录，原文件保留原位；新增内容在 App 解锁运行时发现，下次打开并解锁后补扫遗漏。可以再次选择其他根目录；同一原文件的重叠来源不会重复建项。同卷改名能够可靠识别时保留整理，独立复制的文件分别管理。目录失联或读取占用显示实际状态，不清空旧记录。导入成功不等于上传或仓库备份。

当前图片预览限原文件不超过 16 MiB，且取决于实际解码能力；较大文件仍会导入，但可能显示“预览暂不可用”。点击图片可打开查看页，菜单“查看详情”显示原文件名、来源和实际大小。视频可导入登记，播放仍标为未实现，不能把人工 ProRes 导入通过当作 ProRes 播放通过。

本机相册整理已可用；GitHub实际同步链路已接入，真实平台验收未完成。Gitee授权、完整播放、普通导出和三种实际媒体删除仍未完成并准确禁用。历史演示界面及默认凭据只保留于隔离测试。

GitHub 使用方式：解锁 → 云端同步 → GitHub 授权登录 → 打开官方授权页面并输入 App 当前显示的代码。账号登录由用户在浏览器完成，不在聊天发送密码或令牌。点击“安装 / 管理 GitHub App”打开个人账号的注册应用列表，核对本相册应用App ID 5690653，进入 Edit → Install App，以 Only select repositories 选择照片私有库，再回App检查连接并选择目标。打开浏览器不等于安装成功，真实查询通过才提供可选目标。正常入口首次初始化须明确确认；成功后自动上传已导入媒体的密文；最小化／手动锁继续，系统安全锁或到期暂停。重启后需PIN并核验平台状态；本机断开不等于平台撤销。真实平台同步验收尚未完成，获准的测试使用build/sync-platform隔离数据。

GitHub 配置与失败边界见 [GAR-2](openspec/changes/extend-media-library-and-album-sync/repository-authorization-review.md)，完整平台验收待补。Gitee 必须无需自建服务，当前尚缺符合约束的公开客户端能力证据，不改用内置 Client Secret 或假授权。

## 开发与构建

在另一台已配置好 Flutter Windows 开发环境的机器上，从项目根目录执行：

```powershell
flutter pub get
./scripts/build-source-reader.ps1
flutter analyze
flutter test
flutter build windows --release --target lib/main.dart
.\run-windows.cmd
```

下面的 SDK 路径与安装情况仅为本机记录，换机器不要求使用相同磁盘路径。构建脚本可通过 `-FlutterRoot` 指定 Flutter SDK 目录。

本机环境：Flutter 3.47.9、Dart 3.13.7、Visual Studio Build Tools 2022 17.14.44、Windows SDK 10.0.26100。Flutter 位于 `D:\tools\flutter`，未修改全局 PATH。SDK 压缩包已对照官方发布索引校验 SHA-256，下载使用 Flutter 中国镜像。

```powershell
cd D:\encrypted-photo-app
$env:PATH = 'D:\tools\flutter\bin;' + $env:PATH
$env:FLUTTER_STORAGE_BASE_URL = 'https://storage.flutter-io.cn'
$env:PUB_HOSTED_URL = 'https://pub.dev'
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
- [当前实施提案](openspec/changes/extend-media-library-and-album-sync/proposal.md)
- [原型实现设计](openspec/changes/implement-windows-photo-prototype/design.md)
- [当前任务清单](openspec/changes/extend-media-library-and-album-sync/tasks.md)
- [归档的产品决定与 Q01–Q09](openspec/changes/archive/2026-11-06-design-photo-app-prototype/design.md)

当前变更为 `extend-media-library-and-album-sync`。旧 `implement-windows-photo-prototype` 的 14 个完成任务和原始规划归档保持不变。新变更继续追踪尚未满足的真实能力与 iOS 验收。

```powershell
$env:OPENSPEC_TELEMETRY = '0'
openspec.cmd status --change extend-media-library-and-album-sync
openspec.cmd list
openspec.cmd validate --all --strict --no-interactive
```

真实授权协议、加密及密码派生、密钥保存、密码遗忘、分块格式、后台同步、删除冲突与历史清理仍待设计。原型通过不表示这些正式能力已实现。

`D:\OpenSpec` 是工具源码；`D:\encrypted-photo-app` 是本产品工程。照片密文仓库与产品源码仓库用途不同。

## 新模块与交接

- `lib/model/media_item.dart`、`album.dart`、`album_source_binding.dart`：媒体资源、稳定相册 ID、来源观察与成员覆盖。
- `library_store.dart`、`library_query.dart`、`selection_state.dart`：共享整理、隐藏与查询范围、选择快照。
- `local_preview_library.dart` 与 `services/windows_folder_importer.dart`：仅内存的 Windows 来源，事件与定时核对；不存在明文持久化目录。
- `services/album_import_tracker.dart`：已测试的系统相册状态转换；尚未接入真实 PhotoKit 或数据库。
- `services/media_sync_service.dart`：上传请求规划，不执行密码学或网络操作。
- `services/media_playback.dart`、`playback_session.dart`、`ui/media_viewer.dart`：media_kit 适配、撤销会话和全屏控件。
- `scripts/verify-media-playback.dart`：对人工测试视频进行原生解码、进度、音轨与控制状态探针，不替代窗口和真机验收。

运行时资源来自所选本机目录，播放器不向远端传输媒体。导入完成与备份完成始终分开；本机来源当前的上传和删除操作返回未接入状态。

新增依赖为 media_kit 1.2.6、media_kit_video 2.0.1、media_kit_libs_video 1.0.7 及 Flutter 官方 file_selector 1.1.0，解析结果记录在 pubspec.lock。本机镜像缺少部分传递依赖，本轮改用 pub.dev；构建脚本现在尊重调用者设置的镜像。

Windows 插件需要目录链接。本机没有启用开发者模式，本轮在被 Git 忽略的 `windows/flutter/ephemeral/.plugin_symlinks/` 下为 Pub 缓存建立目录连接，没有改变系统设置。干净检出时需满足 Flutter 标准插件构建要求，或者由开发者按生成的 `.flutter-plugins-dependencies` 重建项目内目录连接。

媒体库原生下载直链曾返回 504；本轮通过同一官方 GitHub Release 的 asset API 下载并核对依赖 CMake 文件中的哈希。没有替换第三方解码库版本或修改 Pub 缓存代码。iOS 新增原生依赖后的 Codemagic 构建仍待执行，不能沿用旧无插件工程的构建结论。
