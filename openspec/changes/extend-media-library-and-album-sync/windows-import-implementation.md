# Windows Import Implementation

## Scope — 2026-11-10

用户批准 WIR-1 的 TD11-W／TD13-W 后，按导入优先顺序实施 Windows 5.1–5.3。正常入口使用真实本地文件与现有安全会话／SQLCipher，不调用 DemoStore 或旧 LocalPreviewLibrary。0.4.0+4 为本轮开发版本；完整产品、iOS、上传／下载、整理、导出删除及完整媒体播放仍未完成。任务勾选以 tasks.md 为准。

本轮导入是记录并管理原位置的媒体：不复制、改名、覆盖或删除原文件，不在仓库写文件。程序数据目录保存加密索引，普通原照片仍在用户选定目录。测试人工凭据、生成照片和视频只存在隔离入口及 build/，不进入正常启动数据。

## Implementation

| 文件 | 真实行为 |
| --- | --- |
| `windows/source_reader/source_reader.cpp`、CMakeLists | `epa_source_reader.dll` 提供打开和异步读取封装，在同次原生调用中保留 Win32 错误码；作为正常 Windows bundle 的一部分 |
| `lib/services/windows_source_reader.dart` | 本机路径／祖先句柄／重解析点检查；只读且拒绝写入和删除共享；原生身份、完整流式指纹、前后属性核对；1 MiB 分块及 CancelIoEx 撤销 |
| `lib/security/vault_crypto.dart` | 使用既有固定 libsodium 实现 BLAKE2b-256 流式摘要；不改变密码学方案或产生新的远端格式 |
| `lib/storage/library_catalog.dart` | schema v3 在加密事务中增加 import_files，兼容 v1/v2 升级；128 条候选、100 条缺失检查批次、200 项展示页；媒体与来源状态原子提交 |
| `lib/services/windows_import_service.dart` | 系统选定根目录的真实递归扫描、2 秒观察、运行期监听、1／5 秒事件合并、60 秒补扫、5／15／60 秒退避；仅在解锁代次内工作 |
| `lib/app/vault_controller.dart`、`lib/main.dart` | 解锁创建导入服务；锁定先撤销服务再关数据库，所有非媒体状态清理 Flutter 图片缓存；旧结果不能写库／显示 |
| `lib/ui/production_library_panel.dart`、`production_screens.dart` | 真实系统目录选择、来源状态／错误、媒体分页、图片内存预览、查看与详情；名称仅详情；上传和视频播放准确标为未实现 |

媒体 ID 为随机 128 位值。可靠同卷文件身份保留整理；独立副本分别管理，重叠来源和硬链接保存引用。缺少可靠身份时只按同路径、创建信息与完整内容版本保守匹配；明确缺失后不凭旧 ID 自动复活。内容变化保留可靠同源整理，但不继承旧版本验证，禁止自动重传意图不被扫描清除。库内副本记录不被扫描删除。

文件头只识别容器类别，`decodeStatus=unverified` 与完整字节快照分开。拍摄时间、时长未知则显示未知。当前图片预览只接纳不超过 16 MiB 的原文件，并在内存解码；更大媒体仍可导入。不能将这项局部预览当作任务 5.7–5.9 的完整格式、播放或性能验收。卡片离开或会话撤销会清零 App 持有的预览字节，取消中的缓冲也清理；不宣称能清除操作系统／驱动的一切历史副本。

## Verification

平台：本机 Windows x64，C:／D: NTFS。测试素材为隔离人工文件，没有读取用户原图库或密码。依赖继续沿用批准的 sodium 4.1.2+1、sqlite3 3.9.1／SQLCipher 和 file_selector 1.1.0；未更换安全选型。

| 层次与证据 | 实际结果与范围 |
| --- | --- |
| `build/import-final-regression.log` | **54 项通过**：原生读取 15、导入服务 13、真实加密目录 15、controller 10、生产表单 1。选择器返回值和原生事件在 widget 测试内替身传递；文件、KDF、DPAPI、SQLCipher、监听及导入读取真实执行 |
| 原生读取 | 同卷改名、独立副本、硬链接、目录联接拒绝、真实 deny-read、磁盘根路径、6 MiB 多块完整指纹对照独立 Python 结果；64 MiB 活动写入拒绝，读到首个 1 MiB 后取消并小于 2 秒释放，随后可实际改名 |
| 目录与调度 | 多层中文／空格目录、重叠根、实际 watcher 新增、同卷移动保留整理、同大小新字节不继承旧版本、写占用退避、失联不清库、外部删除不改副本记录；被删除的空来源目录重建后自动发现新文件 |
| 新增数据库边界 | 真实 SQLCipher trigger 注入写失败，媒体更新和候选 ready 一起回滚，重开可重试；257 条候选保持 128 条读取上限、200+57 分页不漏项、缺失批次 100+100+57；v1/v2→v3 迁移保留记录 |
| `build/import-process-initial-final.log`、`import-process-crash.log`、`import-process-reopen-final.log` | 三个独立 tester 进程使用真实 controller／SQLCipher。先提交两项，再在第三项导入的外层事务提交前执行进程终止；新进程启动 PIN 门禁，先恢复两项，再补扫为三项，旧 ID 保留、未提交 ID 不存在、完整性通过。crash 模式的非零退出是刻意中断，不能列为普通测试通过 |
| 隔离 Windows UI | 通过真实 Windows 文件夹选择器导入 build/import-ui-fixtures，根及 nested 各一张 320×240 PNG；实际画面显示两项，卡片无名称，详情显示正确名称／路径／780 B。ui-result.json：2 项、1 来源、0 待处理 |
| 锁定局部接线 | 生产表单中导入真实图片后打开详情，传递 runner 同名 lock 事件；详情、图片与路径消失，图片缓存为 0；PIN 解锁恢复原记录。service 测试确认原始预览字节在释放／锁定后清零，旧会话拒绝读取 |
| `build/import-media-probe.log` | 独立一项真实集成检查通过：生成的 H.264 514095 B、HEVC 372093 B、ProRes 9377991 B 均从子目录导入为视频，原字节保持，SQLCipher 完整性通过；decodeStatus 保持 unverified，未测试播放 |
| 静态／规格／正常构建 | analyze 无问题；OpenSpec strict 9 项通过；正常 `lib/main.dart` Windows Release 构建 102.6 秒通过，文件版本与产品版本均为 0.4.0+4，包含原生读取 DLL；SQLCipher DLL 哈希与 TD07 一致 |
| 正常客户端启动 | 已运行标准 Release 路径；实际无障碍界面显示“密屿 · 应用已锁定”和四位 PIN 输入，未代填用户密码。隔离 UI 探针已关闭，标准构建已替换探针入口 |

跨进程目录：`build/import-e2e/a4467798d21d491d82a160b4622a5e08`，其 initial／crash／reopen JSON 只含人工测试信息。UI 探针 bundle 位于 `build/import-ui-runner/4430b14d94254512bf43b33d9d45abef`；它使用单独人工库，**不能用作交付包**。正常 Release 必须用 `lib/main.dart` 重新构建，并核对包含 `epa_source_reader.dll`。

本轮实际修正过的验证问题：Win32 错误码跨 FFI 读取偶发变成 0，改为原生封装；junction 测试传入斜杠路径失败，修正测试路径；早期 tiny PNG 的 CRC 错误，替换后执行当前测试，旧字节读取结果不冒称解码验证；生产表单新加导入后等待真实 I/O 不足引发 pumpAndSettle 超时，补充等待服务工作完成及 teardown 释放，复测通过。定时器无实际工作时不再每秒通知重建。

## Reproduction

在项目根目录执行 `scripts/build-source-reader.ps1`，然后执行：

```powershell
flutter test --no-pub test/windows_source_reader_test.dart test/windows_import_service_test.dart test/library_catalog_test.dart test/vault_controller_test.dart test/production_app_test.dart --reporter expanded
```

跨进程探针使用一个新的 `build/import-e2e/<随机目录>`，设置 `EPA_IMPORT_PROBE_ROOT` 后，依次令 `EPA_IMPORT_PROBE_MODE` 为 initial、crash、reopen，分别执行 `flutter test --no-pub scripts/windows-import-process-probe.dart`。crash 模式必须产生 crash.json 并异常终止，reopen 才判断恢复结果；不能只看到 crash 失败就认定恢复通过。

人工 H.264／HEVC／ProRes 容器验证脚本为 `scripts/windows-import-media-probe.dart`，依赖已生成的 build/media-fixtures；生成来源沿用 implementation-notes.md，不把视频工具或素材提交仓库。导入验证不会运行播放器，也不会消除原 ProRes 解码失败记录。

## Remaining Validation

- 全部图片格式／超大图预览、EXIF、视频封面／时长、真实 iPhone 视频及 Live Photo 配对、ProRes 音画播放仍未完成；5.7–5.9 不勾选。
- 本轮未重新要求用户进行 Windows 实际锁屏／睡眠；既有原生路由证据保留，新增媒体读取在这些事件下的完整矩阵、长期大库性能与持续事件压力由 5.9／8.5 继续验证。
- FAT／exFAT／ReFS、跨卷实际移动、大小写敏感目录和恶意文件 ID 复用未实际验收；保守降级规则经真实 SQLCipher 测试，但不冒称相应文件系统测试通过。
- 远端恢复、上传成功、删除及 Gitee 不属于本轮导入验收；iOS 全部要求保留。
- 本轮不提交、不推送、不归档。最终编译、静态检查、工作区源码与产物 SHA-256 见 security-evidence/windows-import-2026-11-10.json。探针与最终构建的验证层次分列，不把正常启动 PIN 页等同于用户真实图库完整验收。
