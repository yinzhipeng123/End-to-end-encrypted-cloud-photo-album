# Implementation Notes

> 历史实施记录：本文的任务编号和 17／53 对应 previous-task-baseline.md。2026-11-09 正式产品文档修订后的任务见 tasks.md，类别及接续见 implementation-status.md。本轮未重新执行下列测试、探针或构建，不将历史结果提升为正式验收。

## 2026-11-09 实施边界与依赖审核

用户已授权实施并运行 Windows 客户端。共享模型、查询、选择、相册规则和原型交互可先执行；下面的正式能力不由演示逻辑替代。

### 正式上传依赖检查（任务 1.4）

| 所需能力 | 当前代码及可调用入口 | 检查结果 |
| --- | --- | --- |
| GitHub / Gitee 授权、凭据保管和仓库接口 | `DemoStore.connectRepository` 仅更改内存字符串；`showRepositoryDialog` 明示模拟 | 无真实授权、网络访问或 token 存储实现 |
| 密码派生、密钥保管、认证加密 | `verifyPhotoPassword` 仅与会话演示字符串比较 | 无正式密码学接口；不得用该比较授权真实解密 |
| 密文清单、50 MB 分块、完整性恢复 | `DemoStore.tick` 推进枚举，`demoChunks` 为示意数字 | 无真实分块格式、读写或完整性确认 |
| 删除、导出 | `deletePhoto` 修改虚构副本状态，`exportDemo` 写演示事件 | 不触及来源原文件、仓库或 Git 历史 |
| 新增上传入口 | `UploadPlanner.request` 定义目的地、媒体 ID、版本的请求边界 | 只做请求规划；真实资源在 DemoStore 被阻断，不允许假装备份完成 |

因此第 9 组继续保持未完成。前置设计需要另行批准，不在本次选定加密算法、密码派生、密钥存储或授权协议。

### 本机元数据加密设计（验证获准，正式密钥方案待审核）

2026-11-09 用户明确拒绝普通 SQLite 明文元数据方案，要求本机元数据也加密、先设计。新的候选比较、密钥边界、事务与恢复、临时文件保护和验收计划见 `local-metadata-design.md`。未把 sqlite3、SQLCipher 或密码学依赖加入工程。

此前隔离探针只完成普通 sqlite3 依赖解析，原生下载失败，未验证事务／重启；该旧探针不构成加密后端选型证据。用户随后批准先验证 SQLCipher，并确定三天内允许系统安全存储辅助解锁、重启仍须四位应用锁；辅助解锁不得重置三天周期。具体数据库发行版的正式选用、密码派生及密钥保护仍待审核。

新探针位于 `scripts/sqlcipher_probe/`：Windows 实际使用 SQLCipher 4.20.0，11 项基础检查和 DELETE／WAL 共 10 个强制进程中断恢复场景通过。iOS ARM64 真机／模拟器库已做哈希、Mach-O 和符号预检；独立 Flutter 测试工程在 Windows 生成并完成依赖解析、Dart 分析，未在 Xcode 构建或执行。完整证据、脚本、许可和局限见 `sqlcipher-validation.md`。没有将探针包接入正式 App，任务 1.3、2.4、5.3 仍未完成。

### 播放候选（用户已批准接入验证）

已加入并锁定 `media_kit 1.2.6`、`media_kit_video 2.0.1`、`media_kit_libs_video 1.0.7`。`PlaybackSession` 隔离生命周期，撤销后不再接受播放控制；`MediaKitPlayback` 限制本地文件／数据协议，未加入远端媒体播放入口。

Windows 原生依赖来自插件声明的官方 Release，下载经过 CMake 中的哈希校验，未修改 Pub 缓存或替换原生版本。当前插件使用的 Windows libmpv 包为 2023-09-24 版本；Dart 包升级不能替代原生库维护、安全与许可证审核。

`scripts/verify-media-playback.dart` 对人工生成的 H.264、HEVC 视频完成了解码尺寸、进度、定位、暂停、音轨及音量状态验证。ProRes 合成样本失败，原生错误为 `Failed to initialize a decoder for codec 'prores'.`，不能声称第一版 ProRes 已实现。窗口画面和控制结果单独记录，不用无窗口探针代替。

尚无可追溯的 iPhone 原始 ProRes、完整实况照片与平台保存视频样本；没有 iOS 编译／真机证据。1.1、1.2、8.2–8.5 不因模型或封面可显示而完成。

### 文件夹来源与当前实现

已接入 `file_selector 1.1.0`，只调用目录选择；扫描和事件核对使用 Dart `Directory` / `File`，递归时设置 `followLinks: false`。只有完整核对才判定记录缺失。运行期间使用事件合并和 15 秒周期核对。前后文件状态检查只能发现检查间隔内的变化，不能证明暂停复制的大文件已经完整；第 5.2 项仍未完成。权限失败、扫描中断和循环连接点的完整验证也尚未完成。

启动补扫依赖上面的持久化审核。本次不把“仅本次会话导入”冒充该完整需求。

### 数据结构与会话生命周期（任务 2.5）

- `MediaItem` 按一个逻辑媒体项目管理一或多个 `MediaResource`，保留实际文件名、来源引用、版本和资源完整性；Live Photo 还需明确配对标识，不能凭同名推断。
- `Album` 使用稳定 ID 保存成员及聚合隐藏设置；来源观察与导入代次分别建模，成员由系统快照 S、App 显式加入 A／移出 R 合并。当前只是内存状态转换，未连接 PhotoKit。
- 目前**没有持久化目录**。所选路径、文件名、相册、收藏和来源跟踪只在 `LocalPreviewLibrary` 内存中存在；关闭后不恢复。没有保存真实密码、PIN、token 或密钥。
- `DemoStore` 的虚构样片与本机来源分开；重置演示切回样片，保留本次进程内独立的真实来源整理状态，不触碰原文件。旧内存样片无需生产数据库迁移。
- 扫描失败保留现有记录，不把失败推断为删除仓库副本；重新扫描可补齐本次会话内的新增。进程退出／崩溃后的整理状态恢复尚不存在，必须待加密持久化和故障恢复验证完成。
- 界面中的真实来源上传、导出与删除返回未接入状态；演示队列不处理真实资源。本机预览不等于备份。

### 相册状态转换的当前覆盖

`AlbumImportTracker` 及单元测试覆盖以下内存规则；尚未接入 iPhone 来源事件、权限、持久化或移动端“导入相册”对话框，第 7 组不据此整体完成。

| 输入变化 | 已实现的内存结果 |
| --- | --- |
| 同一系统来源重复快照 | 不重复创建；同名不同来源按 ID 分开 |
| 系统“旅行”改名为“假期” | 冻结旧 App 相册的有效成员，建立新代次；重放不再新增 |
| 系统删除相册 | 冻结已有 App 相册与成员，不执行媒体删除 |
| App 删除相册 | 保存停止状态；同名来源成员变化不恢复，系统后来改名则新建代次 |
| 手动恢复停止来源 | 重新建立关联；重复导入活动关联不复制 |
| App 加入／移出成员后系统变化 | 保留 App 覆盖，只合并系统侧差异；后一次 App 操作覆盖前一次 |
| 不完整来源快照 | 不推断系统删除、改名或成员移出 |

### 本轮回归证据与未完成范围

- 共享规则：`library_rules_test.dart` 覆盖三类媒体、隐藏聚合查询、屏幕外全选、目的仓库／资源版本去重、真实与演示隔离。
- 界面行为：`library_interaction_test.dart` 覆盖无标题卡片、文件名搜索与详情、多选、隐藏后选择清理、宽窄工具栏、批量取消／部分失败及锁定时移除全屏。
- 来源与会话：`windows_folder_importer_test.dart` 使用独立临时目录，验证多层扫描、只读、重复核对、外部删除保留远端记录和演示重置隔离。仍缺写入暂停的大文件、访问权限及循环连接点完整场景。
- 播放撤销：`playback_session_test.dart` 验证延迟打开、过期／锁定和后续异步命令不能恢复播放；不能代替实际设备听音与双端平台验收。
- 原型的安全、仓库、三范围删除基线保留在 `app_test.dart`、`demo_store_test.dart`。
- 尚未实现：视频缩略图提取和时长元数据、正式本机加密目录及启动恢复、PhotoKit 和平台相册入口、生产授权／密码学／加密同步与真实资源删除导出。

任务 10.4 仍未完成：严格语法检查只能证明 OpenSpec 文档结构有效，不能证明以上未完成需求已经交付。

### 2026-11-09 执行结果

| 检查 | 结果与实际覆盖 |
| --- | --- |
| Flutter 静态分析 | `flutter analyze --no-pub`：No issues found |
| Flutter 全量测试 | `flutter test --no-pub`：63 项通过，包含新增 Live Photo 单项目批量删除和逐项结果 |
| Dart 格式 | 34 个 Dart 文件检查无待格式化修改；最后新增测试另行格式化 |
| Windows 构建 | `scripts/build-windows.ps1 -UseInstalledToolchain` 成功，最终包重新启动 |
| 窗口实际验证 | 原生选择器导入人工目录；4 项混合媒体全选包含屏幕外照片；真实上传显示未接入；H.264／HEVC 生成画面并播放；H.264 定位至约 2 秒、静音；ProRes 超时后错误提示可退出 |
| OpenSpec | `openspec validate --all --strict --no-interactive`：9 项通过、0 项失败 |
| 任务跟踪 | 17／53 项完成；每次勾选后重新查询 apply instructions 确认；其余未缩减验收标准 |
| iOS、真实听音及真实照片库 | 本轮未验证；没有用 Windows 证据代替 iPhone／模拟器验收 |

Windows 画面验证曾发现原生硬件解码尝试失败后能正常回退，但界面将早期错误当最终失败。现在以首帧就绪判断打开结果；打开时不会自动播放，未能读取画面时撤销会话，后续错误不写入含原路径的日志。移除了只针对人工目录的临时诊断代码。

最终程序路径：`build/windows/x64/runner/Release/encrypted_photo_app.exe`。使用根目录 `run-windows.cmd` 启动；需要同目录 DLL 与 data 目录。

### 人工媒体矩阵（不能替代任务 1.1 的真实样本）

视频位于被 Git 忽略的 `build/media-fixtures/`，由 FFmpeg 9.0.2 的测试画面与合成音轨生成，不来自用户照片库；工具通过隔离目录中的 imageio-ffmpeg 0.8.1 提供。视频为约 5 秒、640×360、24 fps 和 AAC 音轨。JPEG 复制自已有 `assets/photos/photo_01.jpg`，来源说明沿用 `assets/photos/SOURCES.md`。

| 文件 | 原生探针 | Windows 窗口 | 未覆盖 |
| --- | --- | --- | --- |
| h264.mp4 | 解码、进度、定位、暂停、音轨、音量状态通过 | 首帧、动态画面、定位及静音控制通过 | iPhone 实际编码、HDR／方向、听音 |
| hevc.mp4 | 同上 | 首帧及动态播放通过 | iPhone 原始 HEVC、HDR／方向、听音 |
| prores.mov | 解码器初始化失败 | 未生成画面，显示失败提示 | 原始 iPhone ProRes；当前不能称为已支持 |
| sample.jpg | 普通图片资源 | 导入识别 | HEIC／大尺寸／方向完整矩阵 |
| Live Photo、平台保存视频、大文件 | 无实际样本 | 未验证 | 全部真实来源与配对／编码／内存边界 |

本轮样本 SHA-256：

```text
h264.mp4   4a0970254af240ba22ea2f7a24208c1695e82fb14e4b68fa0cb9aefeaf26918d
hevc.mp4   f049f159d2b9a5dde4ec89a321ff37da5ecbd119e79df7382b4df50634d10c0a
prores.mov d8a75e568ac20b046edbe011d856bc1d9cb4c4019d536f689fe571c0f650c80f
sample.jpg 13ec5e71050d8cfb66acabace2573b2d97d2d9b41b362c0e5f699aec1b1dd6ff
```

没有添加、提交或上传这些测试媒体、工具、日志和编译产物。下一步完成 iOS SQLCipher 实测及正式密码派生／密钥保护审核，再完成跨启动目录；重启体验已确认，不再重复询问。ProRes 需调查并验证兼容的原生解码构建，不静默转码或删减用户确认的格式范围。

### 官方资料

- SQLite 原子事务：<https://sqlite.org/atomiccommit.html>
- Dart SQLite：<https://pub.dev/packages/sqlite3>
- media_kit：<https://pub.dev/packages/media_kit>
- Flutter file_selector：<https://pub.dev/packages/file_selector>
- Flutter 视频指南：<https://docs.flutter.dev/cookbook/plugins/play-video>
