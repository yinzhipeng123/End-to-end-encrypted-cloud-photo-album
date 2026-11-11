# Windows Lifecycle and Application Recovery — 2026-11-10

## Scope

接续任务 2.5／2.6，沿用 SFR-1 与 TD07，不改变密码学、密钥、仓库协议或删除策略。所有故障和人工数据在隔离目录／专用虚拟磁盘验证，未使用用户密码、原照片或真实照片库。iOS 验收继续留在 9.1／9.2；媒体导入、播放、平台授权与同步仍未实现。

## Task 2.5 — Actual Windows Lifecycle

用户手动执行 Win+L、重新登录，以及 S3 睡眠／唤醒／登录。scripts/windows-lifecycle-probe.dart 使用生产 PhotoVaultApp、VaultController、DPAPI、SQLCipher 和原生窗口监听，仅目录与输入是人工测试样本。生产进程不自动填入凭据；验证入口中的人工解锁仅用于核对事件后的门禁，不进入 lib/main.dart。

Windows 原生桥增加只读 state 查询，记录当前进程的会话锁定、挂起和恢复事件计数，全部留在内存，不持久化用户行为或敏感信息，也不改变授权。

实际结果：会话锁定一次；S3 运行中观察到一次挂起和两次恢复通知。每个观察点均为 PIN 页面、旧 SQLCipher 句柄已失效、访问阻断、原 72 小时截止时间不变。返回后错误 PIN 拒绝，正确 PIN 能重新打开真实空库。首次睡眠期间用户曾关闭测试窗口，该次不计应用验收，重新启动隔离客户端后再次实际执行通过。

证据：security-evidence/windows-session-lock-2026-11-10.json、windows-suspend-2026-11-10.json。验证 runner exe SHA-256：5ccc527d117569d34d465abc0dfcfb34968e48921d8bfc6f445ad24fa31c3cf1；验证 app.so：cfb5a0f67ace1514f793d4c78bdf4f091badd9e5392824ca7db549499ce83d69。该产物为隔离入口，不是交付包。

结合既有真实首次设置、空库、重启、最小化、生产表单及未实现入口禁用证据，2.5 的 Windows 范围完成。未来媒体／同步任务仍须各自验证锁定取消，不能由本次空库验收替代。

## Recovery Defect and Fix

新增 test/vault_recovery_test.dart 首次运行 9 项中 2 项失败：初始化中断或已有库 PIN 文件缺失时，正确照片密码会清空 PIN 重试并更新期限，然后显示“照片密码验证通过，请输入四位应用锁密码”，实际却没有可用 PIN 校验记录。

修复在 PinGate.clearFailuresAfterPhotoAuthentication 先真实读取并验证 DPAPI 保护的 PIN 材料；缺失、认证失败或格式错误产生 pinSetupRequired。VaultController 保持照片密码页，明确提示使用已存在的“同时重新设置本机四位应用锁”，不发布新期限或辅助解锁状态。用户显式输入新 PIN 后仍须正确照片密码及两次一致输入，不覆盖数据库或绕过门禁。

9 项新测试覆盖：占用数据库目标、PIN 未完成初始化、已有库 PIN 丢失、改密提交前的两个写入故障、提交后的两个辅助状态故障、PIN 重试写入失败，以及应用文件敏感标记扫描。故障通过隔离目录中真实不可写的目标形态产生，未用模拟成功替代文件 IO。

修复后定向回归 43 项通过：新恢复 9、controller 10、目录选择 11、生产表单 1、复验门禁 12。日志：build/security-probe/app-recovery-before-2026-11-10.log（失败基线）、app-recovery-after-2026-11-10.log（修复后）。测试时钟与原生事件／选择器替身沿用原测试的明确边界；DPAPI、密码学、SQLCipher 和文件保存真实。

## Actual Process Termination Matrix

scripts/windows-app-recovery-probe.dart 加载生产 PhotoVaultApp／VaultController；app-recovery-file-observer.dart 委托真实 File／RandomAccessFile，仅在选定 IO 边界暂停供父进程强制结束，不替代返回值、不进入 lib/。scripts/verify-windows-app-recovery.ps1 按已启动 PID 终止进程，再启动全新 runner 读回并核对。

12 个场景通过：

| 操作 | 强制终止点 | 新进程实际结果 |
| --- | --- | --- |
| 初始化 | bootstrap 新建空文件、bootstrap 刷盘 | 拒绝不完整库，不自动创建缺失数据库、不覆盖包装 |
| 初始化 | 加密数据库建立、PIN 提交、辅助材料提交、完整初始化 | 正确照片密码及显式 PIN 恢复后打开真实空库，无样片 |
| 改密码 | 新包装候选刷盘、原子替换后、辅助材料提交、完整改密 | 提交前旧密码可用；提交后旧密码被拒、新密码恢复；已提交数据库内容保留 |
| 相册事务 | 提交前、提交后 | 分别恢复完整旧关系／新关系；来源代次和停止记录一致 |

每次恢复均检查启动未解锁、错误 PIN 拒绝、正确 PIN 后真实 SQLCipher 完整性、已提交人工数据、恢复后普通锁撤销旧句柄。中断后、恢复前读取主库、回滚日志、密封／包装候选等实际文件扫描人工密码和元数据的 UTF-8／UTF-16 标记，结果未发现；同时保存文件大小及 SHA-256。不是仅凭字符串扫描认定加密安全，后端身份、密钥认证、实际读回与配置沿用 TD07 验证。

原始报告：build/app-recovery-results/run-60c8fd23/report.json。该矩阵补齐实际 App 业务接线的进程中断证据，区别于旧的直接目录探针；不表示媒体业务已接入，也不等于物理断电或任意硬件故障保证。

## Bounded Disk Exhaustion

用户已明确同意创建一个最大 256 MiB 的临时 VHDX，手动批准管理员 UAC。scripts/mount-storage-test-volume.ps1 仅创建并核对该新虚拟磁盘，再初始化为 NTFS；不接受物理磁盘编号，拒绝已有镜像、系统盘、启动盘或身份／大小不符的磁盘。挂载管理需要提升权限，实际应用测试 runner 继续由普通用户进程启动。

四个实际容量耗尽场景通过，填充器记录 Windows 错误 112；每次由新进程完成恢复验证。初始化中断真实触发受保护文件创建失败，未报告成功；SQLCipher 事务写入失败后保留旧相册和来源关系。两次改密测试中，NTFS 在数据空间不足时仍完成了小型凭据文件的更新：记录实际成功，核对包装代次为 2，重启只接受新密码并保留数据库。不能把这两项说成“改密 IO 因磁盘满失败”；提交前／后真正失败的保存路径由真实目标阻塞测试另行覆盖。最初测试把“卷满”直接等同“任何写入都会失败”，因此出现一项测试预期失败；修订验收脚本后按真实 IO／成功提示／重启结果分别核对，没有修改产品逻辑让失败变成功。

原始报告：build/storage-volume-7d64a7f3/run-80273aac/disk-full-report.json；256 MiB VHDX 于 2026-11-10T01:45:32Z 已卸载，detached.json 有记录，测试期间新出现的 E: 卷已不再挂载。镜像仅含人工测试数据，保留在被忽略的 build/ 中供复核。

结合 12 个实际进程终止场景、真实文件故障回归、后端／日志配置、残留检查及旧目录迁移／损坏证据，任务 2.6 的当前 Windows 安全与持久化范围完成。尚未实现的媒体、平台令牌、传输与未来缓存仍由各后续任务验证，不提前声称完整 AC06／AC07 或 8.5 全部通过。

## Evidence Limits and Next Gate

最终验证：补充“失败恢复不延长期限”断言后，9 项恢复测试再次全部通过（不是额外新增 9 项）。flutter analyze 无问题，OpenSpec 严格校验 9 项通过；已明确使用 lib/main.dart 重新构建 Windows Release，并启动正常包，实际观察到用户现有库的 PIN 锁屏界面，未代填凭据。源码、产物及日志哈希见 security-evidence/windows-recovery-2026-11-10.json；本轮没有重跑历史全套 143 项，也没有提交、推送或归档。

敏感扫描只覆盖 App 可控的实际文件、候选和日志，不承诺清除系统页面文件、休眠镜像、转储、磁盘控制器缓存或已删除文件历史。原照片没有接入本轮测试，不进行原文件迁移、覆盖或删除。

下一阶段 3.1：GitHub GAR-2 已批准，但没有已注册 GitHub App 的公开 Client ID／隔离照片仓库；Gitee 安全公开客户端流程与 TD09 仓库协议仍未确定。不能把本轮安全与存储通过当作授权、上传或恢复已经实现。
