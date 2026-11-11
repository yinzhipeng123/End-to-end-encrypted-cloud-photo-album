# Windows Security Implementation

## Scope

按 2026-11-09 用户最新指示，仅实施 Windows；iOS 全部需求和验收保留在 tasks.md。各任务的真实结果在本文件分别登记，不能将安全模块等同已完成 App 接线或远端备份。

## Task 1.3 — Media Cryptography

实现文件：lib/security/vault_crypto.dart、vault_credentials.dart、vault_media_crypto.dart。使用既定 libsodium 1.0.22 的 XChaCha20-Poly1305，随机生成资源版本密钥和每次加密的 nonce。用途 1 包装资源密钥、用途 2 加密恢复元数据、用途 3 包装本机目录密钥，保持 SFR-1 的 BLAKE2b 映射。

资源会话不暴露密钥。包装绑定库 ID 与调用方提供的资源版本上下文，媒体认证单元额外绑定调用方提供的单元上下文；使用不同用途标识及长度前缀消除串接歧义。上下文必须非空且每段至多 4096 字节，这是内部接口输入防护，不是仓库清单／分块格式。单元认证成功后才返回明文；父会话撤销会立即关闭所有子资源会话，旧句柄不能再加解密。

此任务不确定 TD09–TD11 的仓库目录、文件布局、块尺寸、完整清单与发布协议。调用方必须在阶段四校验整个资源完整性，再向用户报告整份恢复成功，不能将单元认证等同多块完整。此接口不提前接入未完成的 App 门禁，也不提供旁路入口。

### Windows Evidence

- 独立参考：scripts/security-reference-vectors.py 使用现有独立 Python 环境生成用途 1／2／3 KDF、资源包装、媒体和恢复元数据的已知结果；不使用 App 的 libsodium 产生参考结果。原人工引导向量保持相同，新增字段仅供测试。
- test/security/vault_media_crypto_test.dart 新增 8 项真实后端测试：独立已知结果、服务打开向量、实际文件加密及凭据重开后的逐字节恢复、错误密钥／nonce／AAD／密文／标签／截断、跨库替换、随机性及不可变公开字节、撤销与输入尺寸。
- `flutter test test/security --no-pub --reporter expanded`：25 项通过（原 17＋新增 8），实际 native hook／libsodium 路线；日志 build/security-probe/media-security-windows.log。
- `flutter analyze --no-pub`：通过。源文件与日志哈希另存 security-evidence/windows-media-2026-11-09.json。
- 测试仅使用临时目录内人工字节，不操作用户原照片、不上传仓库。App 接线及完整文件协议仍未实现，不据此宣称完整备份完成。

## Task 1.4 — Windows Platform Protection

windows_data_protection.dart 通过项目内 FFI 直接调用 Windows CryptProtectData／CryptUnprotectData，固定当前用户范围、CRYPTPROTECT_UI_FORBIDDEN，无机器范围和明文降级。临时原生输入／输出缓冲区使用后清零释放；调用者仍须释放其 Dart 字节。公开错误不含系统路径或秘密。

windows_protected_store.dart 将小型状态按用途名称与调用方绑定材料共同密封，实际写入临时密文、flush、重新解封核对后原子替换。不存在返回 null，损坏／绑定不符拒绝，不返回默认解锁材料。目录以受保护 DACL 仅授予当前用户及 SYSTEM；每次访问核对所有者／DACL，拒绝重解析点和宽松既有目录，不擅自改写用户已有目录权限。

Windows 9 项实际测试通过（test/security/windows_data_protection_test.dart），含 DPAPI 随机化／往返、篡改／绑定错误、真实密封文件重开／替换／删除、命名空间交换拒绝、失败保留、ACL 与不安全路径拒绝、真实匿名 Windows 令牌不能解密并恢复原身份后可解密。未创建或修改系统账号；匿名令牌测试证明所执行身份切换下的拒绝，不宣称验证所有域漫游／系统迁移配置。系统保护的安装／库／代次／期限绑定由后续访问服务传入，不直接将单个记录读取视为允许访问照片。

证据：security-evidence/windows-dpapi-2026-11-09.json，日志 build/security-probe/dpapi-windows.log。Windows 单调计时接口采用 GetTickCount64，9 项中包括实际计时推进；没有为了测试强制挂起用户电脑。完整生命周期与 App 锁定在后续接线验证。iOS Keychain 暂缓，未认定完成。

## Tasks 1.5–1.6 — PIN and Reverification

pin_gate.dart 使用 SFR-1 的随机 32 字节 keyed BLAKE2b 校验材料、16 字节盐和安装／库绑定，不保存 PIN 原文；PIN 与重试记录分别使用真实 DPAPI 密封保存。比较前先提交尝试预占记录，中途终止或状态写入失败不能获得免费校验。第 5–9 次错误精确等待 30／60／120／240／480 秒，第 10 次要求照片密码；记录缺失不能以任意 PIN 重新解锁。

reverification_gate.dart 固定每端 259200 秒，保存实际照片密码验证时间、截止、最大已观察 UTC、包装代次及异常标志。WindowsSecurityClock 实际使用 UTC 和 GetTickCount64；单调增量／UTC 差或回拨超过 60 秒时阻断，小幅回拨不延后截止。辅助主密钥绑定安装／库／包装代次／验证起点／截止，并核对本机引导记录和目录密钥认证。正确 PIN 不改变起点；辅助会话不能产生照片密码验证证明，同一次真正密码验证的证明只能用于建立一次周期。

密码尝试在 KDF 前持久化预占，第 5 次起按 30 秒翻倍至 900 秒；正确照片密码才清除失败状态。普通锁撤销凭据与 PIN 操作代次，旧资源句柄和晚到 KDF 结果失效。过期先阻断，再保存异常／到期状态并清除辅助记录；写入或删除失败不能放行。期限状态写操作串行，避免旧检查覆盖新周期。

Windows 7 项 PIN 测试、12 项复验测试通过。凭据、DPAPI、文件均真实执行；精确时间边界用隔离的确定性时钟输入，并不宣称人工时钟是生产计时实现。生产窗口最小化／锁屏／挂起事件、App 重启和数据库关闭在 2.5 接线验证；实际网络暂停在 4.3，不能据服务测试声称这些链路完成。日志分别为 build/security-probe/pin-windows.log 和 reverification-windows.log。

## Task 1.7 — Password Changes

VaultCredentials.changePassword 实际校验旧密码和新密码二次确认，保持主密钥／目录密钥不变，重新生成盐、nonce 与包装代次。VaultBootstrapStore 在跨实例更新锁下写入独立候选密文，重新读取并认证后才调用 Windows 同目录原子替换，替换后再读回认证；错误与未提交中断保留原材料，不截断原文件。

Windows 6 项测试通过：真实改密及原资源继续解密、旧密码／确认错误不变、候选实际写出后注入提交失败保留旧文件、派生期间取消、提交后晚到取消不返回会话但新材料可恢复、复制的旧包装仍可用旧密码打开。最后一项验证既定边界：改密不撤回已复制材料。不新增找回密码或重置真实库的路径；PIN 重设仅在后续 App 新鲜照片密码验证流程调用。日志 build/security-probe/password-change-windows.log。

## Tasks 1.8–1.9 — Verification and Handoff

安全测试集共 59 项，整体 Windows 真实后端回归通过；合并回归共 67 项通过（59 项安全＋8 项正式目录测试）；日志 build/security-probe/windows-security-and-catalog.log，依赖与源文件／日志哈希见 security-evidence/windows-security-foundation-2026-11-09.json。Dart 格式与静态检查通过。测试替身仅用于确定性时钟及明确标注的故障注入，未进入正常产品数据或密码学实现。

剩余集成边界：SQLCipher 正式 Windows 接入已由用户批准，阶段二实施；App 启动／锁屏、平台事件和实际目录生命周期尚须接线，不能把独立安全服务等同新可用 App。仓库协议、授权和删除未决项仍需确认；iOS 需求与验收保留并暂缓。没有提交、推送或归档。
