# Windows Sync Implementation

## Scope — 2026-11-10

用户批准 WSR-1 的 TD10-S／TD11-S、TD13-S／TD12-S 和 TD09-I，允许在私有测试仓库 `yinzhipeng123/test-album`（1452541678）使用隔离人工媒体。此前用户口头确认 App 已安装到该库；后续截图仅显示 Codex Connector 与 Codemagic，没有本相册应用，因此实际安装仍待核验。连接器曾核对该库为私有，写前仍由产品重新检查。正式业务通过产品自己的 GitHub App Device Flow 获取授权，未使用连接器令牌代替。

本轮仅实施 Windows。4.1 设计和4.2本机资源加密准备完成，当前24／70。4.3–4.8、6.2、6.8不因代码接入或替身测试通过而勾选。iOS、Gitee、三种实际删除、导出其余策略及跨端相册元数据边界保持原约定。

截至此记录，**没有真实 GitHub 上传、下载或跨客户端恢复通过的证据**。自动审批此前两次拒绝启动测试进程，返回 `blocked by policy`，未给出更具体理由；随后用户已手动打开隔离窗口并完成产品授权。已观测实际连接账号、导入两个人工媒体，所选目标为空、初始化为 false、已验证副本为 0；安装查询未返回匹配安装。用户随后提供安装页截图，缺少本相册应用，现需用户完成安装再刷新。没有读取用户库的受保护令牌、跳过 PIN 或复制用户原图。

## Implementation

| 模块 | 已接入的真实逻辑 | 验收边界 |
| --- | --- | --- |
| `lib/sync/sync_format.dart`、恢复投影解析器 | 4 MiB 独立认证块、严格规范 JSON／字段、用途绑定、188 字节主密钥包装投影；不上传本机目录密钥包装 | 本机真实密码学和边界通过；网络与 iOS 另验 |
| `sync_resource_preparer.dart`、`sync_object_store.dart`、原生来源读取 | 完整稳定资源先加密为随机命名密文块；SQLCipher 逐块断点、源版本检查、512 MiB暂存预算及已批准单大资源例外、256 MiB空间预留 | 真实51.9 MB人工AVI、逐字节恢复与RSS已验证；网络阶段RSS未测 |
| `github_git_access.dart`、`github_sync_repository.dart` | 真实HTTPS blob/tree/commit/ref；专用分支；每次写前检查私有属性和目标；非强制提交、读回认证、已知提交与认证根链核对、未知命名空间拒绝；空库标识例外 | HTTP协议替身通过不代表GitHub平台通过 |
| `windows_sync_service.dart` | 自动／单项／批量共用持久化任务；真实进度；目标／版本绑定；手动暂停、锁定取消、期限撤销；失败退避；未知提交结果核对；冲突版本保留 | 队列重开、暂停及重复提交测试通过；真实断网／进程终止／双客户端竞争矩阵尚未完成 |
| 密码更新 | 本机改密前保存关联目标的待发布意图；新恢复投影和根一次发布；读回后才清除待办；发现另一端改密先撤销访问，持久化要求当前仓库密码；正确密码重新包装本机独立目录 | 真实加密／SQLCipher＋HTTP替身验证丢失回复、错旧密码、独立目录保留；真实多客户端改密未验收 |
| `sync_cipher_cache.dart` | 按需密文缓存512 MiB，映射和LRU时间在SQLCipher，原子密文落盘，孤立半文件清理、读取摘要检查和逐块AEAD | 有界缓存、淘汰和篡改测试；正式视频随机读取接线未完成 |
| `repository_vault_recovery.dart`、controller、恢复对话框 | 显示目标库身份；正确仓库密码在新目录建立独立catalog/PIN/安装/DPAPI；完整清单认证后显式切换，保留旧库；不复制发送端目录、辅助解锁或平台令牌；不自动下载全库 | 真实新目录、PIN和controller重开＋HTTP替身通过；实际新进程独立GitHub授权与无原图恢复未验收 |
| 列表、筛选和查看 | 只依据目标与版本匹配的持久化回执显示已同步；远端清单单独标“内容按需校验”；仅仓库／待同步／仅本地；显式按需图片查看；改名、收藏、隐藏仍仅本机 | 已接入真实目录；完整原生视觉验收待进行。图片内存查看器沿用32 MiB边界，大图、视频与实况完整播放仍未实现，不隐藏该限制 |

新表未引入；SQLCipher schema仍为v3，复用加密records命名空间。原照片位置和字节保持不变。正式入口没有测试凭据、自动样片、HTTP替身或假成功。`test/support/git_database_transport.dart`只属于测试；`scripts/windows-sync-platform-probe.dart`只属于独立人工测试构建，不是发布入口。

## Validation

已完成的局部证据分别记录，不能简单相加为不同测试总数：

- `build/sync-format-tests.log`：32项格式／密码学／原生读测试通过，含4MiB边界及50,000,001字节。
- `build/github-sync-module-tests.log`：32项GitHub适配／连接与协议测试通过，网络是HTTP替身，本机密码学、DPAPI、SQLCipher及文件读写是真实执行。
- `build/sync-lifecycle-tests-recheck.log`：27项通过；初次失败是旧界面断言及测试未配置Windows原子替换回调，修复后通过。旧失败日志保留。
- `build/sync-recovery-tests.log`：15项通过，含新目录恢复后真实controller/PIN打开、缓存淘汰及篡改、目标与版本筛选。
- `build/sync-resource-budget-tests.log`：独立51,905,272字节RGB24 AVI加密准备通过；13块，12块4,194,352字节＋末块1,573,672字节；实际逐字节恢复相同、源摘要不变。加密RSS增量86,020,096字节＜134,217,728字节预算。完整数据见 `security-evidence/windows-sync-format-2026-11-10.json`。
- 首次并行全套 `build/sync-full-regression.log`：249项通过，1项`vault_location_test`在初始化阶段失败。未将其归因为已确认原因；后续串行重跑结果另记，不删除该失败。
- 串行全套 `build/sync-full-regression-serial.log`：251项全部通过，约5分钟。此结果先于最后的保留命名空间校验和安装入口调整；最终代码另跑定向回归，不改写该全套测试边界。

- 最终定向回归 `build/sync-installation-regression.log`：24项全部通过，包含16项真实本机凭据／连接与HTTP替身测试、7项同步协议／恢复／缓存测试及1项生产表单集成测试，约1分54秒；包含最终命名空间校验和安装入口文案变更，不以此代替实际平台验收。
- `build/sync-installation-analyze.log`：静态检查无问题；当前变更 `openspec validate --strict` 通过。

最终构建：0.6.0+6隔离入口Windows Release构建通过，并在确认隔离进程已关闭后更新 `build/sync-platform/runner/`，保留 sender 数据和已有产品授权材料；随后 `--target lib/main.dart` 正常入口构建通过，标准Release目录已恢复为正常客户端。两份AOT哈希不同，核对隔离测试密码标记只存在于隔离产物，正常产物不包含该标记，最终CMake目标为lib/main.dart。本次未启动新版／点击原生安装按钮，没有新增远端写入证据；86份源文件及4份核心产物SHA-256见 `security-evidence/windows-sync-installation-2026-11-10.json`。此前测试版本和最终产物必须区分。

## Installation Entry Follow-up

2026-11-10：修复无仓库时隐藏整个选择区域的问题，始终显示选择标题及真实空／待核验状态；新增安装管理按钮，只调用原生 ShellExecute 打开固定 GitHub 官方管理页，失败提供手动地址，不自动完成安装。提示核对本相册应用 App ID 5690653，与 Codex Connector／Codemagic 区分。连接信息改为“未查到当前账号下的安装”，不从过滤后的空列表断言平台上完全没有安装；移除连接层已过时的“上传／下载尚未实现”文案，具体能力与状态由同步模块显示。没有放宽 App ID、账号归属、指定仓库、私有属性及写权限校验。安装和真实同步平台验收仍未完成。

## Remaining Acceptance

1. 用户本人在隔离客户端授权后，用test-album实际验证初始化、图片／视频上传、对象大小与远端内容、无原图／旧缓存独立恢复。测试入口不能代表生产入口已运行。
2. 实际断网、终止与重启、限流、权限／安装撤销、非私有／错误目标、两个独立客户端竞争和并发改密；测试替身故障注入另列。
3. 网络传输工作集预算、长期暂存与队列清理、完整大库成本／磁盘满矩阵；本机单资源RSS不替代这些验收。
4. Live Photo可靠多资源准备／完整发布／恢复及视频播放器受控随机读取仍缺；不以AVI传输或视频文件导入声称ProRes／实况音画播放通过。
5. TD14真实删除、TD12普通导出其余规则、Gitee无自建服务授权和iOS维持未决或暂缓状态。没有据上传代码增加相册元数据跨设备同步。

## Reproduction

定向测试使用 `flutter test --no-pub test/sync/`；原生来源DLL仍由既有 `scripts/build-source-reader.ps1` 构建。全套Windows安全测试建议串行执行并保留任何失败，不以重试删除失败证据。

隔离GitHub入口：`flutter build windows --release --no-pub --target scripts/windows-sync-platform-probe.dart`，必须复制到隔离运行目录后，再用 `--target lib/main.dart` 恢复正常发布产物。隔离数据仅位于 `build/sync-platform/`；人工PIN为5837，人工照片密码只用于测试。该入口经用户本人授权后只选择固定测试仓库ID，且只导入人工源目录，不读取用户图库。正式入口没有这些测试默认值。

程序数据目录新增 `sync-staging/` 和 `sync-cache/`，内容均为密文；来源、名称、队列、回执与缓存映射在加密catalog中。新恢复库独立保存自己的安全材料，原库不会自动删除。
