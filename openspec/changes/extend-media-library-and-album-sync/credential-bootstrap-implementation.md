# Credential Bootstrap Implementation

## Status

2026-11-09，任务 1.1 已据三组明确答复完成批准记录；本报告接续 1.2／AC02、AC03 的**真实凭据服务**。已实现并执行 Windows 隔离验证；同日重启后工具链自动检测恢复，普通 Flutter 原生测试 17 项通过，未跳过原生构建 hook。1.2 仍未勾选，总进度 1／60；iPhone 构建／运行／耗时／内存及跨端一致性未验证。用户确认目前只有 Windows 和 iPhone，尚缺可用的 iOS 真机构建／安装环境。未跳至 1.3。

本次没有改动 App 启动／界面、用户媒体或已有凭据。当前 App 仍使用旧 DemoStore；本模块不自动进入现有运行包，不代表已完成照片库、媒体加密协议、SQLCipher、DPAPI／Keychain、PIN／72 小时门禁或远端备份。不得通过直接调用凭据服务绕过后续门禁集成。

## Changed Code

| 文件 | 实际职责 |
| --- | --- |
| `lib/security/photo_password.dart` | 12–128 个 Unicode 标量、严格代理项／控制字符检查、全空白／单字符重复拒绝、精确二次确认、原样 UTF-8 |
| `lib/security/vault_crypto.dart` | 实际 sodium 初始化和版本／长度核对，固定 Argon2id 参数，串行工作 isolate，随机密钥，XChaCha 包装／解包，目录用途 3 的 BLAKE2b 派生 |
| `lib/security/vault_bootstrap_record.dart` | 固定长度本机最小引导记录、解析上限、格式／参数白名单、用途／身份／版本认证上下文 |
| `lib/security/vault_bootstrap_store.dart` | 真实只读打开、OS 排他新建、不截断写入、flush；保留已有／异常文件，不自动修复或覆盖 |
| `lib/security/vault_credentials.dart` | 初始化、重新打开、写后读回认证、会话密钥持有与释放、操作互斥、撤销及晚到结果拒绝 |
| `lib/security/security_failure.dart` | 稳定错误码，不返回密码、原始密钥或文件路径 |
| `pubspec.yaml`、`pubspec.lock` | 固定 sodium 4.1.2+1，Dart 最低版本 3.13.0；无安全算法替代 |
| `test/security/`、`test/fixtures/security/bootstrap-v1.json` | 密码规则、凭据文件与篡改场景；人工独立参考向量，只在测试使用 |
| `scripts/security_probe.dart` | 调用上述真实业务模块的隔离验证，含实际 VM 子进程、取消／并发及 20 次 KDF 测量 |
| `scripts/security-reference-vectors.py` | 使用独立 Argon2 C 参考实现、PyCryptodome XChaCha 和 Python BLAKE2b 生成可复核人工向量 |
| `scripts/build-security-probe-windows.ps1` | 以已安装 MSVC 显式调用原包未修改的 build hook，编译独立原生验证产物；不修改 SDK／包缓存源码 |
| `scripts/test-security-low-memory.ps1` | 仅对本脚本启动并核对所属关系的实际 Dart VM 施加 Windows Job 内存限制，检查真实失败且无凭据文件 |

`VaultCredentialSession` 只表示两个密钥包装通过认证，其密钥不公开返回；它不表示 PIN、系统辅助存储、复验期限、重试状态或 App 访问权限已满足。上层必须在 1.4–1.6／2.5 按设计接线。所有产品密码派生请求必须由同一个应用 isolate 内的协调服务发起；工作 isolate 仅执行已获准的单次派生，不得各自另建入口绕过并发门禁。

## Local Format

这是 SFR-1 已批准最小本机引导边界的编码细化，**不是 TD10／TD11 的仓库对象或媒体分块协议**，不决定未来远端公开字段。所有整数为小端；恰好 228 字节，读取最多 229 字节以检查尾随内容；不信任外部声明的长度来分配内存。

| 字节偏移 | 长度 | 内容 |
| --- | --- | --- |
| 0 | 8 | ASCII `EPAVLT01` |
| 8 | 2 | 格式版本 1 |
| 10、11 | 各 1 | 套件 1＝已批准 XChaCha20-Poly1305；参数集 1＝已批准 Argon2id |
| 12、13 | 各 1 | Argon2 版本 0x13、lane 1 |
| 14 | 2 | opslimit 3 |
| 16 | 4 | memlimit 67,108,864 字节 |
| 20、22 | 各 2 | 明文密钥 32 字节、包装 48 字节 |
| 24 | 8 | 包装代次，新建为 1；零／不可表示值拒绝 |
| 32、48 | 各 16 | 随机库 ID、随机本机目录 ID |
| 64 | 16 | 密码派生随机盐 |
| 80、104 | 各 24 | 两次包装分别独立生成的随机 nonce |
| 128 | 4 | 密文载荷长度 96 |
| 132、180 | 各 48 | 主密钥包装、独立随机目录密钥包装（各含 16 字节标签） |

主密钥包装的 AAD 为 `EPA/bootstrap/master/v1` 的 ASCII 字节＋一个零字节＋完整 132 字节头部。目录包装 AAD 为 `EPA/bootstrap/catalog/v1`＋一个零字节＋头部＋主密钥包装。目录包装密钥使用 `EPAKDF01` 的子 ID 3。没有另存密码散列充当解锁依据；打开时必须校验调用方提供的期望库 ID 并真正解开两个包装。

参数字段不是可自由调节的配置，未知格式／参数先拒绝，不能据不可信材料降低成本或扩大 KDF 内存。这里的代次和认证不提供防重放证明，完整快照回退仍按 SFR-1 的威胁边界处理。

## Persistence and Failure Semantics

1. 先验证密码、后端及目标不存在，完成真实派生／随机生成／包装后才触碰新文件。参数错误、确认不符或派生失败不创建可用库。
2. `File.create(exclusive: true)` 由 OS 决定唯一创建者；后续追加方式打开、排他锁、核对零长度、实际写入及 flush，绝不以覆盖写修复已有文件。父目录由后续 App 路径适配提供，本模块不擅自创建用户目录或选取业务索引位置。
3. 写入后重新打开文件，核对完整记录并真实认证两个包装，成功后才发布凭据会话。已经写完但操作随后取消时仍保留材料，调用方不能收到成功会话；不可把取消理解成必定没有文件副作用。
4. 空／截断材料报初始化不完整，未知格式和超长材料分别拒绝，已有材料新建报已存在；写入／读回失败不自动删除、不覆盖旧库。正确密码也不能恢复已被外部破坏的密文。
5. 认证失败只给统一错误码，UI 接入时按 SFR-1 提示“密码错误或受保护材料已损坏”；不得据此断言一定是密码错。密码派生资源失败给后端失败，不自动减弱参数。
6. 撤销先改变操作代次并关闭已有会话。原生 KDF 无强行中止 API，允许当前一次计算结束，晚到密钥立即释放、不再写出／放行；已进入文件系统的写入可能完成，仍不发布旧会话。原始密码和派生包装密钥不缓存。

可控临时字节在使用后清零，秘密材料使用可释放原生缓冲区。Dart 字符串、运行时复制、分页／转储的限制仍按 SFR-1，不宣称全内存零残留。这里不证明物理断电、所有文件系统或全盘损坏下的耐久性。

## Windows Evidence

平台：Windows 11 专业版 Build 26300 x64；Intel Core i5-10210U；约 16 GiB RAM。Flutter 3.47.9、Dart 3.13.7、MSVC 14.44.35207。HEAD 为 `0a4ddadd8707c49fe704afd7aded1a23c71d7d3f`，工作区含既有未提交修改；以 `security-evidence/windows-2026-11-09.json` 的源文件 SHA-256 清单识别本轮实现，不能只用 HEAD 代表代码。该文件保留重启前的历史结果；重启后新增 `security-evidence/windows-2026-11-09-after-reboot.json`，核对其中 15 个源文件／依赖／测试文件哈希与前次一致，并单独记录标准流程 DLL 和日志哈希。

| 验证 | 实际结果与边界 |
| --- | --- |
| 原生身份 | 实际加载 libsodium 1.0.22；来自 sodium 包内源码，包归档 SHA-256 `ecfcfc444ba1651c9b58cb3a84c6d925ab86c6206e40ab1ce0f5d674207d15d2`，源码归档 `5d829f95ea7be72eedf373b197f01df765171da80619b1291692d3f854e10e46` |
| 重启前隔离 DLL 身份 | 实测 DLL SHA-256 `a891d498faf7a857fe72d873411a7c14692a0191173a7eb9691f58b64999aa28`，通过明确绝对路径的 native asset 映射装载；该哈希不用于标识重启后的标准构建产物 |
| 独立结果 | Argon2id 派生、BLAKE2b 用途 KDF、XChaCha 主／目录密钥包装均与独立人工参考结果一致；独立记录可以通过业务服务打开 |
| 真实集成 | 79 个检查通过：输入失败、随机性、不同库包装交换、头／nonce／标签篡改、错误密码、期望库身份、半成品／超长拒绝、真实文件错误、并发排他创建、KDF 互斥、晚到取消、跨进程打开 |
| 强制终止 | 直接核对并终止实际 Dart VM：0／10／80 ms 时未形成文件，200／600 ms 时留下完整 228 字节且可重新认证。另以真实写入的 0／1／131／180／227 字节半成品验证保留；本轮时间点未恰好截获生产写入中间的截断文件，不将人工半成品称为该过程的实测命中 |
| 性能 | 20 次固定参数派生，p95＝120.549 ms；整个验证进程峰值 RSS＝143,417,344 字节，测量前 RSS＝75,337,728 字节。RSS 含 Dart／原生／测试开销，不能解释为 KDF 单独峰值；完整逐次数据保存在证据 JSON |
| 事件循环 | 派生运行于工作 isolate，测量期间主 isolate 定时事件继续执行；不宣称已完成 App 真机流畅度验收 |
| 低内存 | 对实际 VM 设置并读回确认 Windows Job 内存限制（当前 private commit＋32 MiB）：真实派生返回 `backendFailure`、子进程正常报告失败、无凭据文件；参数未降级。最终数值见证据；极端连 Dart VM 自身也无法维持的 OOM 不保证可返回结构化错误 |
| 重启前密码纯规则测试 | `test/security/photo_password_test.dart` 4 项通过：编码、12／128 标量边界、非法／弱输入、二次确认和错误脱敏；该次运行不使用原生密码学 |
| 重启后工具链 | VS Build Tools 2022 17.14.44（17.14.37827.9），路径 `D:\tools\VSBuildTools`；`isComplete=true`、`isLaunchable=true`、`isRebootRequired=false`。Flutter doctor 的 Windows／Visual Studio 检查通过，Windows SDK 10.0.26100.0 |
| 重启后普通 Flutter 测试 | `flutter test test\security --no-pub --reporter expanded` 退出码 0，17 项通过：4 项密码规则＋13 项真实凭据测试。未设置 `NIX_SKIP_SODIUM_BUILD_HOOKS=1`，标准原生构建 hook 执行并加载 libsodium；测试断言实际运行版本 1.0.22，覆盖真实文件重开、错误密码、篡改、半成品保留、并发及晚到取消 |
| 标准流程 DLL 身份 | `build/native_assets/windows/libsodium.dll` SHA-256 `b25af177a6a2b32102b7d480dce7c8bfbf88b0919e857a8adc218b229af8ad99`；标准构建和测试宿主的两份 native asset 映射一致，指向该 DLL 的绝对路径；完整日志及哈希见新增证据 JSON |
| 静态与文档检查 | 最终 `flutter analyze --no-pub` 通过；`openspec validate --all --strict --no-interactive` 为 9 项通过、0 失败；`git diff --check` 通过。它们不替代真实密码学或平台验证 |

所有测试文件和密码均为人工样本，没有读取用户照片、真实密码、令牌或仓库；默认运行入口不加载测试向量。测试样本包含公开已知密钥，仅供独立结果校验。

## Reproduction

在项目根目录运行；脚本默认沿用本机 SDK／工具链路径，可用参数指定。生成物均位于已忽略的 `build/`，不提交 DLL、kernel、临时凭据或虚拟环境。

```powershell
& D:\tools\flutter\bin\flutter.bat pub get
& .\scripts\build-security-probe-windows.ps1
& D:\tools\flutter\bin\cache\dart-sdk\bin\dart.exe --disable-dart-dev .\build\security-probe\security-probe.dill
& .\scripts\test-security-low-memory.ps1
& D:\tools\flutter\bin\flutter.bat test test\security --no-pub --reporter expanded
& D:\tools\flutter\bin\flutter.bat analyze --no-pub
```

独立向量可在临时 Python venv 中安装 `argon2-cffi==25.1.0`、`pycryptodome==3.23.0` 后运行 `scripts/security-reference-vectors.py test/fixtures/security/bootstrap-v1.json`。本轮实际使用 argon2-cffi-bindings 26.1.0；生成器没有调用 App 的 libsodium。

重启前的历史失败：普通 `flutter test test/security --reporter expanded` 失败于原生构建前置，Visual Studio 当时的安装状态为 `isComplete=false`、`isRebootRequired=true`；包内 vswhere 自动查询排除该安装。隔离脚本显式传入已安装 MSVC，调用原包 build hook 后以 Dart SDK 编译器绑定真实 DLL，因此当时可以验证业务模块；仅凭那次隔离结果不能认定普通 Flutter 构建已恢复。

重启前的纯输入规则测试不调用 sodium，因此当时仅对该测试临时设置 `NIX_SKIP_SODIUM_BUILD_HOOKS=1` 后运行，通过后恢复环境变量。**该方式不得用于声称原生凭据测试通过**。

2026-11-09 用户完成重启后，VS 安装状态恢复，执行上述完整安全测试命令，17 项全部通过（包含 `vault_credentials_test.dart`），没有跳过原生构建 hook。本次新增标准测试宿主的真实验证；此前 79 个独立检查、性能和低内存测试没有重复执行，仍以原历史记录为准。业务代码未改变，也没有生成新的 App 交付包。

## Remaining Gates

- iPhone：需要可用的 iOS 真机构建／安装环境和设备，执行相同人工向量、真实文件失败／重启、固定参数 20 次性能及内存／低资源验证，并核对两端互操作。2026-11-09 用户确认目前只有 Windows 和 iPhone；现有模拟器预览配置不能代替真机验收，Windows 证据也不能替代。Windows 重启和普通原生测试的阻断已解除，不再列为未完成项。
- App 与安全状态：系统保护、PIN、期限／重试及持久化状态在 1.4–1.6，正式启动和数据库在 2.2–2.5。本模块不提供临时绕过路径。
- 任务顺序及其他决策：1.2 未满足完整平台门槛前不勾选、不宣称完成；SQLCipher 正式接入、仓库协议、删除策略仍等待各自审批。

本轮没有新增产品功能、改变批准参数、提交／推送、归档或重新生成项目。
