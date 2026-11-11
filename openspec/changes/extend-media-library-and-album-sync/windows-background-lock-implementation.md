# Windows Background Lock Implementation — 2026-11-11

## Final Follow-up

用户明确告知已解锁，并说明此前手动关闭隔离进程，要求重新测试。重新启动同一最终隔离构建后，于2026-11-11 13:28（Asia/Shanghai）完成实际标题栏最小化：报告 `phase=passed`、`minimizeEvents=1`、`minimized=true`、`privacyShieldVisible=true`、`screen=pin`；新增嵌套PNG在锁中导入，原后台实例不变、旧界面连接失效、期限不变、加密数据库未出现人工文件名明文。

随后恢复窗口，第一次截图和再次截图均显示PIN密码页，未显示旧图库；首次可访问性树短暂仍含旧图库文本，再次刷新已与密码页一致。记录这一工具观察差异，不把有限截图声称为逐帧录像或所有桌面环境证明。原生遮挡实际生效与恢复可用已核对，本机验收任务2.9完成，当前26／73。4.9真实GitHub锁中上传仍未执行。

隔离窗口已通过标题栏关闭并确认进程退出。随后启动正常 `build/windows/x64/runner/Release/encrypted_photo_app.exe`，截图与可访问性树均显示PIN页；留给用户自行解锁，没有输入用户密码。本次复验没有修改业务源码，沿用上一轮已通过构建的0.6.2+8，不需要重复构建。以下桌面锁定／等待记录保留为此前过程，由本段接续。

## Scope and Approval

用户已明确批准 WBL-1。仅改变 Windows 最小化和手动应用锁：保留已建立的后台密钥／SQLCipher／来源／仓库会话，继续完整导入和同步；界面、整理及查看读取即时撤销。系统会话锁定／断开、睡眠／恢复、退出／重启、72小时到期、时间异常、远端密码变更仍全撤销。手动暂停独立；iOS 暂缓且原规则不变。

## Implementation

- `lib/app/vault_controller.dart`：后台目录与界面目录分别打开真实 SQLCipher 连接；界面连接绑定代次与门禁，旧连接关闭不可复活。普通 lock 只撤销界面，suspend 全撤销；界面 PIN 复验复用后台，目录和密码格式不变。
- `lib/security/reverification_gate.dart`、`pin_gate.dart`：界面 PIN 验证仍执行受保护尝试记录及限速；普通错误不停止后台，第十次、材料损坏或期限异常撤销。损坏受保护 PIN 材料不与普通错 PIN 混淆。
- `lib/storage/library_catalog.dart`：连接可绑定访问检查，已取得的句柄也检查期限与代次。关闭界面连接不关闭后台连接；全撤销由密钥会话统一关闭二者。
- `lib/services/windows_import_service.dart`、`library_organization_service.dart`：目录监听／导入与界面预览的取消分离；清零预览缓冲、拒绝旧排队读取。整理服务在锁定时销毁并使用界面目录。
- `lib/repositories/github_connection.dart`：登录／查询／仓库选择等交互请求独立取消；后台令牌刷新和仓库操作继续。查看请求从仓库访问开始就可以取消，包括身份核验阶段。
- `lib/sync/windows_sync_service.dart`：后台队列继续，查看请求和已返回明文另有代次／取消与清零；手动暂停保留，不以解锁创建第二个同步服务。
- `lib/main.dart`、`windows/runner/flutter_window.cpp/.h`：原生最小化明确标识，其他／未知安全消息全撤销；Flutter detached 全撤销，hidden／paused 为界面锁。解锁前后的原生核验区分“仅最小化”和系统不可用，避免竞态误停后台。
- 原生窗口在最小化前显示中性遮挡，恢复后等待密码页完成渲染再隐藏。事件携带代次，迟到回调不能移除新遮挡；未显示遮挡时不替换引擎初始显示回调，避免窗口无法首次出现。
- `lib/ui/production_screens.dart`、`github_connection_panel.dart`：按真实规则更新设置和同步说明。
- `pubspec.yaml`：版本 0.6.2+8，无新依赖或磁盘格式迁移。

## Verification

最终关联回归 `build/background-lock-regression-final.log`：121 项全部通过。涉及真实 Windows 文件读写、递归目录监听、libsodium、SQLCipher、DPAPI、PIN、重启、目录事务、来源与队列；HTTP替身和受控时钟仅用于确定性边界，不算真实 GitHub 验收。

新增 `test/background_lock_test.dart` 共10项：普通锁下新增嵌套文件导入／持久化和重启、旧目录／整理／预览撤销、排队预览不能在重新解锁后复活、PIN限速及十次错误、损坏PIN材料、锁中到期／时间异常、系统暂停及手动暂停保持；协议替身覆盖锁中加密上传／读回字节一致、远端查看在身份核验阶段取消、交互授权取消、锁中到期不发布成功。

`test/production_app_test.dart` 通过真实表单检查最小化后隐藏详情／路径／图片且保留后台、拒绝最小化中的PIN提交但保留后台、系统或未知原生消息全撤销。此测试的原生消息是 messenger 注入；真实 Windows 最小化必须另外留证。

回归相关文件还包括 `test/repositories/github_connection_test.dart`：原“普通锁销毁连接”断言改为系统安全撤销；普通锁行为由新增生产控制器测试验证，未删除强制撤销场景。

### Initial Runs and Corrections

- 首轮 `build/background-lock-tests-initial.log`：40项通过。
- 扩展回归 `build/background-lock-regression.log`：旧测试仍断言普通锁清空连接，失败1项；界面测试等待保留后台导入的空闲状态导致与Flutter虚拟时钟互等，执行被中止，不算全套通过。
- 修正测试的安全事件分类和表单等待条件后，`build/background-lock-regression-recheck.log`：27项通过。随后补原生最小化判定竞态回归，最终121项全部通过。修正等待只影响测试，未以禁用后台掩盖问题。
- OpenSpec 严格校验通过：`build/background-lock-openspec.log`。
- 首次真实最小化测试已经通过后台导入，但恢复后的第一张截图仍显示旧图库，而可访问性树已是密码页；第二张截图才显示密码页。未把这个观察视为隐私验收通过，随后补上述原生遮挡和代次检查，并重新构建／验证。

## Platform and Delivery

隔离入口 `scripts/windows-background-lock-probe.dart` 只创建新的人工目录，不打开用户库、不联网；使用生产 PhotoVaultApp、真实 SQLCipher、DPAPI、来源监听和 Windows runner。

追加原生遮挡之前的实际最小化报告保存在 `build/background-lock-platform/result-before-shield.json`：原生最小化事件1次、PIN页、后台导入和同步实例不变、锁中新增嵌套PNG被导入、旧界面目录拒绝读取、期限不变，数据库未出现人工文件名明文。此报告不能单独证明后续遮挡版本的窗口恢复效果。

最后的事件代次修订后，`build/background-lock-epoch-test.log` 的1项完整生产表单回归通过；`build/background-lock-epoch-analyze.log` 静态检查无问题；`build/background-lock-epoch-probe-build.log` 隔离 Release 构建成功。121项关联回归是在追加原生遮挡前完成，后续复核按改动范围执行，未声称重新执行全部121项。

新版隔离包已经启动并产生 `ready_for_minimize` 报告。桌面验证工具两次返回 `failed to activate captured window`，随后只读截图确认 Windows 桌面处于系统锁屏；停止所有桌面输入，已请用户本人解锁。最终版本的真实最小化／恢复显示验证尚待继续，任务2.9暂不勾选。

正常入口 `lib/main.dart` 已在隔离构建后重新构建成功：`build/background-lock-epoch-production-build.log`，产物为 `build/windows/x64/runner/Release/encrypted_photo_app.exe`。正常／隔离 AOT 哈希不同，正常 AOT 中未发现隔离测试密码与路径标记；这项扫描仅区分入口，不是安全证明。77份相关源码、两份产物、5份测试／构建日志摘要及平台报告保存在 `security-evidence/windows-background-lock-2026-11-11.json`。正常客户端尚未启动，当前25／73。

接续步骤：用户解锁桌面后重新枚举隔离窗口，用真实最小化按钮触发测试，读取 `build/background-lock-platform/result.json`；需确认最终版 `passed` 和遮挡状态，再恢复窗口核对密码页没有旧图库画面。结束隔离窗口后启动正常 Release，由用户本人解锁。通过后更新证据和2.9状态，不据此勾选4.9。

## Remaining

真实 GitHub 锁中新增上传、恢复和到期矩阵尚未执行，任务4.9保持未勾选；既有3.2／3.4–3.6和4.3–4.8等平台门槛仍不由本轮自动完成。本轮没有操作真实仓库、提交、推送或归档。Windows 系统锁屏／S3 的历史实测记录保留，本轮的系统事件分类用模块／生产根消息回归，不声称再次执行真实睡眠。完整视频／ProRes／Live Photo播放依旧按原任务验收。
