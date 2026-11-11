# Windows Encrypted Storage and App Integration

2026-11-10 接续：下文为 2026-11-09 的原始实现／验证记录。任务 2.5／2.6 此前缺少的实际系统锁屏／挂起、完整 App 多文件进程中断及容量耗尽验收现已补齐，见 windows-recovery-implementation.md 与对应当日证据。历史结果和平台限制仍保留，不用新证据替代未实现媒体／同步功能。

## Scope

2026-11-09，按 TD07 已批准路线实施 Windows SQLCipher 和真实启动接线。iOS 保留未实施。当前包是正式业务逐步接入的开发版本，**不是完整产品交付**；不能据本文或构建成功认定 GitHub/Gitee 同步、媒体导入、播放、整理、导出或删除已经完成。

## Tasks 2.2–2.4

`lib/storage/library_catalog.dart` 使用 sqlite3 3.9.1 的真实 SQLCipher 4.20.0 community 后端；native asset SHA-256 必须匹配 TD07。连接先设置随机目录密钥，核对后端和 MEMORY temp、FULL synchronous、外键、cipher_memory_security；真实读页通过后才使用。DELETE journal 中的数据库页由 SQLCipher 加密。SQLCipher 的 cipher_memory_security 查询返回字符串 `"1"`，与 SQLite 的整数 pragma 分开核对，不通过移除检查修复类型问题。

schema v1 建立库身份、媒体、来源、相册／成员和带命名空间的记录表；preferences、tracking、jobs、replicas 仅是持久化结构，不表示对应同步业务已实现。v2 为来源增加受 JSON 约束的状态字段，以保存后续扫描／访问状态；不提前选择 TD11/13 的媒体身份或调度协议。v1→v2 在加密独占事务中升级，提交后更新版本；版本 0 只允许全新创建，已有空文件或未知版本拒绝。迁移失败回滚，不导出明文或覆盖旧文件。

目录绑定库 ID／目录 ID；会话撤销立即关闭连接。嵌套业务修改共用外层事务，禁止异步回调跨越提交边界。相册成员由外键约束，删除相册只删除分组与关系。读取媒体分页，不以本次实现宣称大图库资源验收完成。

10 项目录测试实际通过：保存重开、整组回滚、错误成员原子拒绝、无密钥／错误密钥、会话撤销、未来版本保留、损坏／半文件保留、真实回滚日志、v1 升级、迁移失败不修改原文件。见 `test/library_catalog_test.dart` 与 `build/security-probe/catalog-final-tests.log`。

`scripts/catalog-recovery-probe.dart` 直接调用正式目录实现，编译为独立 Windows 原生程序；每个场景创建 1200 条人工媒体及相册、覆盖与停止记录，父进程在事务开始、删除旧相册、建立新相册、更新记录、提交后五点强制结束子进程，再由全新进程校验。五个场景通过；提交前旧状态、提交后新状态，其他来源的停止／覆盖保持。密码只在测试源码和 stdin 管道中使用，不传进命令行或报告；不操作用户照片。此项不等同物理断电、磁盘满或实际 App 全链路验收。

## Tasks 2.5–2.6 — Implemented Portion and Remaining Verification

`lib/app/vault_controller.dart` 将本机私有目录、真实凭据、DPAPI、PIN、72 小时门禁及 SQLCipher 接到一起，默认数据目录为当前用户 LocalAppData 下的 EncryptedPhotoApp；本日后续新增的首次数据位置选择见文末。整个运行期持有实例文件锁，防止两个客户端并行修改门禁记录。安装 ID 随机生成并由 DPAPI 保护；缺失辅助材料只允许照片密码恢复，不允许任意 PIN 初始化旧库。

首次建立凭据和空目录后仍要验证本机 PIN。重启保留原期限；照片密码验证或重设 PIN 后也要通过普通锁。改密码要求已通过 PIN 的有效会话及正确旧密码，使用同一持久化照片密码尝试预算。中断后的新包装代次从实际磁盘重新读取。已有目录缺失／损坏不自动重建，半完成初始化保留材料并明确报错。

`lib/main.dart` 的正常入口不再构造 DemoStore、默认密码或计时模拟同步。旧界面测试入口已移入 `test/support/legacy_prototype_app.dart`，只用于历史规则回归。pubspec 不再打包 assets/photos；现有演示源码保留为历史实现，没有从正常入口引用。新增 `lib/ui/production_screens.dart` 提供真实设置、锁屏、空库及密码设置；导入／相册／授权／同步明确标注未实现并禁用，不能假装业务成功。

Windows runner 注册真实 WTS 会话通知，经 miyu/access 通道传递最小化、锁屏／会话断开及挂起事件。普通窗口失焦不锁定。Dart 端撤销会话、关闭目录、替换整个 Navigator 并清理可控图片缓存；窗口恢复不自动解锁。无法确认原生监听能力时拒绝解锁。

10 项实际 controller 测试通过：首次空库、重开数据与不延期、旧句柄撤销、期限边界、PIN 重设、改密与原库保留、辅助材料缺失、目录缺失、并发实例拒绝及晚到认证结果。时间边界使用显式测试时钟，其余凭据、DPAPI、SQLCipher 和文件操作真实。新增生产界面测试通过，使用真实服务操作表单；只有 Windows 事件消息在此 widget 测试中替换，不能算物理系统事件证据。

单独的 `scripts/windows-access-probe.dart` 使用相同正式入口组件与真实后端，在独立临时目录建立人工凭据并正确通过 PIN，**不打包到正常 App**。实际 Windows runner 验证了 WTS 监听注册、库重开与 PIN 期限、真实空库；通过窗口的最小化按钮触发原生事件，恢复后只剩 PIN 界面，旧目录句柄拒绝访问。证据：`build/security-probe/windows-runner-evidence.json`。报告中的调用栈仅是人工隔离验证代码定位，不含密码或密钥。

尚未实际触发用户电脑的系统锁屏／挂起；实际 App 进程在多文件初始化／改密中的强制终止矩阵、磁盘满等完整异常验收也未完成。**2.5／2.6 保留未勾选**，不把目录子进程测试替代全部 App 验收。已实现的部分可编译运行供用户检查，但任务与完整 AC 不提前通过。

## Verification and Reproduction

- `flutter test --no-pub --reporter expanded`：143 项通过，包括历史界面／规则测试与本轮真实安全／存储／启动测试。历史模拟测试不是生产业务证据。
- `flutter test test/library_catalog_test.dart --no-pub --reporter expanded`：10 项通过。
- 最后补充原生监听不可用的明确失败提示后，生产表单＋controller 11 项定向测试再次通过（production-final-tests.log）；不是另加 11 个不同测试。`flutter analyze --no-pub` 无问题，最终正常 lib/main.dart Release 构建通过。
- `dart build cli --target scripts/catalog-recovery-probe.dart --output build/catalog-recovery`，运行生成的 catalog-recovery-probe.exe：五个真实进程终止／恢复场景。
- `flutter build windows --release --no-pub --target scripts/windows-access-probe.dart`：仅隔离验证入口；正常交付必须重新以 `--target lib/main.dart` 构建。
- 正常包版本 0.2.0+2；完整路径、当前源码／DLL／产物哈希和最终检查见 `security-evidence/windows-storage-and-app-2026-11-09.json`。
- 正常 Release 已实际启动并观察到首次照片密码／四位 PIN 设置页；未注入人工凭据，未代用户填写密码。测试专用入口未作为交付包运行。

SQLCipher、OpenSSL 和 Dart sqlite3 的完整许可放在 assets/licenses 并随包提供，界面可以打开开源许可。第三方漏洞／依赖全量审计仍不因本次许可收集自动完成。没有提交、推送或归档。

## Password Visibility — 2026-11-09

用户体验后要求密码框支持显示／隐藏。lib/ui/production_screens.dart 的共用输入组件已覆盖首次设置、照片密码／PIN 验证、PIN 重设及改密对话框：默认隐藏，各输入框独立切换，页面重新创建时不继承显隐状态，禁用输入时恢复隐藏。只处理当前输入，不读取已保存凭据或持久化偏好。

扩展现有生产表单集成测试后通过 1 项完整场景：真实凭据初始化、显隐保留输入、确认框独立、显示错误 PIN 仍不能解锁、改密输入可显示、锁定撤销对话框后 PIN 为空且隐藏。凭据、DPAPI、SQLCipher 均真实；原生事件仍是测试消息，不能算系统锁屏实测。静态检查无问题。此次源码、日志及 Windows 构建证据见 security-evidence/windows-password-visibility-2026-11-09.json；之前的 windows-storage-and-app 报告保留原构建哈希，不覆盖历史记录。2.5／2.6 的其他验收缺项保持不变。

## First-run Data Location — 2026-11-09

按用户追加需求完成任务 2.7。首次设置页现在显示实际数据目录，可通过系统文件夹选择器选择父目录，或恢复默认。应用建立其中专用的 EncryptedPhotoApp 子目录；已有自定义同名目录不覆盖，已建库不迁移。默认位置仍是 LocalAppData/EncryptedPhotoApp，保留少量启动文件；选择自定义位置后，真实 SQLCipher 数据库、照片密码包装、PIN／期限／辅助解锁材料写入自定义目录。

新增 VaultLocationStore 使用已有 WindowsProtectedStore 的用户范围 DPAPI，保存版本化 data-location.sealed；没有明文路径偏好。配置锁与目标实例锁同时覆盖自定义初始化，目标创建要求真正新建，复查与原生创建之间也不能接受已存在目录。所选路径及祖先不能是重解析点或网络驱动器，目标必须满足原有私有 ACL 校验，用户父目录权限不变。非法表单先拒绝；提交后先保存定位再创建凭据，定位记录提交后中断会在下次启动报告不完整，不退回默认空库。

最终 31 项定向测试通过：11 项目录选择／定位场景，10 项 controller 回归，1 项生产表单集成，9 项原生 DPAPI／ACL 回归。真实操作覆盖中文空格路径、自定义数据库落盘、关闭并重建控制器后数据与期限保留、错误 PIN、默认库兼容、未提交取消／恢复、非法表单、选择后目标被占用、目录失联后恢复、两类必要文件缺失、定位损坏、定位提交后中断和并发拒绝。DPAPI、凭据、数据库与文件读写均真实；controller 的部分时间边界和表单中的原生消息／选择结果为明确测试替身。该结果不是重新运行历史全套 143 项。

正常 lib/main.dart 的 Windows Release 构建成功，静态检查无问题，OpenSpec 严格校验 9 项通过。用该产物及隔离的进程级 LOCALAPPDATA 实际打开 Windows 选择器，观察取消保持路径、选择测试父目录后显示完整专用路径、恢复默认；未提交设置时核对自定义目录及定位记录均不存在。原生检查没有填写密码，没有替用户初始化。结束隔离实例后启动正常客户端，保留用户原库。最新源码／产物／日志摘要见 security-evidence/windows-data-location-2026-11-09.json。

原生窗口验证和真实后端重开验证分开记录，不称为用户密码流程的全程人工验收。系统锁屏／挂起、完整 App 多文件中断与磁盘满矩阵，以及 iOS 仍未完成；不因为完成 2.7 而勾选 2.5／2.6，不宣称媒体导入或远端同步已接入。

## Current Data Location in Settings — 2026-11-09

用户追加在设置中显示保存目的地，任务 2.8 已完成。production_screens.dart 的“访问与密码”页直接读取当前 VaultController.directory.absolute.path，并在“程序的数据保存目的地”下用可选中文字展示完整路径；没有另存路径、重新计算默认目录或加入修改／迁移入口。锁定通过既有路由撤销隐藏该位置。

复用 production_app_test.dart 的真实自定义建库流程，增加进入设置后当前路径可见、旧默认路径不可见、锁定后标签与路径均消失的校验，1 项生产表单测试通过；其中凭据、DPAPI、目录及文件读写真实，原生消息和文件夹选择结果仍为原有测试替身。静态检查、OpenSpec 9 项严格校验及正常 lib/main.dart Windows Release 构建通过，已启动客户端。此次没有重新执行此前 31 项／143 项全套，也未代用户输入密码观察原生设置页。证据及构建哈希见 security-evidence/windows-settings-data-location-2026-11-09.json。其他未完成任务不变。
