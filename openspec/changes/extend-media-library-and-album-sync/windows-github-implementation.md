# Windows GitHub Implementation — 2026-11-10

## Scope and Status

用户已批准 GAR-2 TD08-A、RAR-1 TD09-A，以及先实施阶段三 GitHub 部分。公开 Client ID/App ID 来自用户，见 github-app-registration.md；用户明确尚未安装到照片仓库，稍后自行选择。当前实现只进行用户授权、只读查询和本机连接保存，不创建仓库、分支或远端文件，不上传媒体。

正常入口使用真实服务。测试中的 HTTP 替身仅位于 test/repositories/，没有生产回退路径。版本为 0.3.0+3，仍是部分功能可用的开发包。3.2／3.4–3.6 的完整平台验收未完成，任务保持未勾选，总进度仍为 17／70；Gitee、iOS 和媒体传输没有因此完成。

构建运行后的人工平台结果：用户在本次 0.3.0+3 中亲自完成解锁及 GitHub 浏览器授权，并明确反馈“授权成功，提示尚未安装仓库”。将账号授权成功及未安装提示记为用户手动验证通过；没有读取、记录或索取用户令牌。此证据不扩展为实际刷新、拒绝、仓库选择或权限矩阵通过。

## Implementation and Files

| 文件 | 实际行为 |
| --- | --- |
| lib/repositories/github_api.dart | dart:io 真实 HTTPS；固定官方来源和 REST 版本；设备码、轮询、无 Secret 刷新；分页、错误及限流 |
| lib/repositories/github_connection.dart | 真实账号与安装范围核验、私有目标选择、DPAPI 密封令牌、SQLCipher 配置提交、锁定取消 |
| lib/ui/github_connection_panel.dart | 真实设备授权码、连接状态、仓库查询与选择、取消及本机断开；不显示伪造账号或仓库 |
| lib/app/vault_controller.dart | PIN 解锁后建立连接服务；普通锁、到期、退出销毁连接并取消操作 |
| lib/ui/production_screens.dart | 云端同步页接入 GitHub 面板；Gitee 与开始同步继续禁用 |
| windows/runner/flutter_window.cpp、CMakeLists.txt | ShellExecuteW 只打开固定 GitHub 官方设备页，显式链接 shell32；不接收任意 URL |
| test/repositories/github_api_test.dart | 14 项协议与输入防护测试，HTTP 为替身 |
| test/repositories/github_connection_test.dart | 16 项真实 DPAPI／SQLCipher／controller 集成，HTTP 响应与故障时机为替身 |
| test/production_app_test.dart | 生产表单回归：GitHub 真实入口启用，未实现同步／Gitee 保持禁用 |
| scripts/probe-github-device.dart | 实际设备码请求，输出脱敏结果；不打印设备码、不轮询换令牌、不写仓库 |
| pubspec.yaml | 版本更新为 0.3.0+3；没有新增第三方依赖 |

## Security and Failure Semantics

1. HTTP 只允许 HTTPS 443 的 github.com／api.github.com，Bearer 只发到 api.github.com；禁止重定向。OAuth 资料放 POST 表单，不出现在 URL。连接 20 秒、单请求 45 秒超时，响应最多 2 MiB；每批最多 100 页，每页 100 个。这是一次查询的资源边界，不是媒体容量配额。代理读取进程环境，不写系统配置。
2. Device Flow 以平台 interval 和 expires_in 为准；pending 继续等待，slow_down 至少增加五秒并服从平台更长间隔。单调时钟检查请求前后期限，取消和迟到结果拒绝。只在 UI 显示 user_code，不保存设备码；拒绝／过期／网络错误不建立假连接。
3. SQLCipher 的 preferences/github-connection 保存版本、账号 ID、安装 ID、仓库 ID 与显示名称及凭据代次；访问／刷新令牌不写入该记录。令牌对经用户范围 DPAPI 保存在当前数据目录的 github-token-<随机代次>.sealed，绑定本机安装、provider、Client ID、App ID、账号和安装 ID。
4. 先写完整密封代次，再同步提交 SQLCipher 引用。失败清理本次候选；提交后尽力清理旧代次。崩溃可能留下未引用的密封文件，程序不枚举它们作为恢复回退；不能宣称文件系统中绝无密封残留。旧会话迟到写入不能替换新会话当前引用。
5. 刷新前先持久化 refreshing。丢响应、取消、保存失败或重启遇到该状态均要求重新授权；不能重用可能已失效的旧对。完整新对提交后才恢复 active。同一解锁会话串行处理连接操作，锁定撤销旧服务。
6. 目标只来自当前 App、本人的安装及真实返回仓库，要求 selected 安装范围、未挂起、Contents write、Metadata read、private、未归档／未禁用及用户 push 权限。选择前再次查询安装列表和仓库身份。API 报告可写不代表已实际写入；当前没有试写远端。
7. 已授权但未安装可以保存账号连接，并明确提示尚未安装；没有“同步就绪”。重启显示已保存身份和待核验，用户检查连接后再核对权限。401／身份变化要求重新授权；403 区分权限与限流；权限或私有属性变化令目标失去核验状态。
8. 本机断开先持久化失效，再删除当前密封材料并保存断开状态；不把本机操作称为 GitHub 平台撤销。已提交结果不能由用户取消追溯撤回，取消文案准确说明后续可核验保存状态。
9. 日志不记录响应体、令牌或设备码。主动清零可变明文缓冲；Dart String、JSON／HTTP／系统内部缓冲和已攻陷进程不在可保证擦除范围。平台凭据保护不抵抗同一 Windows 用户下的恶意进程，不替代照片密码或应用锁。

## Validation Evidence

| 验证层 | 结果 | 边界 |
| --- | --- | --- |
| 协议模块 | 14 项通过 | 替身覆盖 pending／slow_down、拒绝／过期、错配置、坏令牌、取消、晚到响应、刷新、限流、分页和 HTTPS 来源拒绝；不等于平台行为实测 |
| 本机连接集成 | 16 项通过 | DPAPI、ACL、SQLCipher、文件、PIN、关闭／重开均真实；HTTP 和故障调度替身。覆盖绑定错误、缺失／损坏、刷新意图、丢响应／保存失败、权限变化、锁后迟到和本机断开 |
| 既有入口回归 | 11 项通过 | 10 项 VaultController 和 1 项生产表单；OS 事件投递／文件选择器结果使用现有测试替身，不重做系统锁屏验收 |
| 实际 GitHub 设备端点 | 通过 | 生产 GitHubApi 和传输，返回有效设备码；expires_in=899、interval=5。没有轮询换令牌、用户身份或仓库请求 |
| 真实账号授权与未安装提示 | 用户手动确认通过 | 用户本人在运行的 0.3.0+3 完成浏览器授权后反馈成功且提示未安装；与前一行无账号探针分开记录 |
| 静态检查 | flutter analyze --no-pub 无问题 | 不代表业务验收 |
| 正常 Windows 包 | flutter build windows --release --no-pub --target lib/main.dart 成功 | 0.3.0+3；已启动并观察原有库的四位应用锁页，未代填密码 |
| OpenSpec | 严格校验 9 项通过 | 文档格式证据，不代表 GitHub 真实平台验收 |

初次组合运行 41 项中 40 项通过，1 项残留扫描在读取测试实例独占的 instance.lock 时失败。修正测试为正常关闭库后扫描全部文件，整个 16 项连接组重跑通过。该修正没有修改应用的文件锁行为。协议 14 项和既有 11 项来自首次通过记录，未声称第二次再次跑完全部 41 项。

日志：build/github-tests-2026-11-10.log、build/github-store-tests-final-2026-11-10.log、build/github-build-2026-11-10.log。构建／源码哈希见 security-evidence/windows-github-2026-11-10.json。初次静态检查发现冗余导入、探针 print lint，修正后无问题；不隐去初次失败。

## Pending Platform Acceptance

- 用户本人解锁、GitHub 浏览器授权及未安装提示已由本次人工反馈确认。后续真实拒绝／取消／过期等仍需逐项留证，成功流程不代替失败矩阵。
- 用户在 Install App → Only select repositories 选择照片私有库后，实际查询／保存／关闭重开／重新核验。
- 实际拒绝／取消／过期、刷新与旧令牌失效、平台撤销、权限缩减、安装移除、仓库变公开、未安装的另一私有仓库拒绝、只读用户拒绝等按 GAR-2 分项留证。
- 需要隔离账号或仓库的场景在条件不足时明确未验证，不扩大真实照片仓库权限。当前没有远端写入授权，不做试写。
- Gitee 公开客户端与 TD09-B、TD10／TD11 传输格式及后续未决策略继续保留；下一步先补 GitHub 真实平台验收，不擅自进入上传开发。

## Reproduction

```powershell
flutter analyze --no-pub
flutter test --no-pub test/repositories test/production_app_test.dart test/vault_controller_test.dart --reporter expanded
dart run scripts/probe-github-device.dart
flutter build windows --release --no-pub --target lib/main.dart
openspec validate --all --strict --no-interactive
```

探针每次会申请一份实际设备码，不要循环运行。此次网络探针使用用户允许的进程级本机代理；最终客户端通过窗口工具启动，未设置持久代理，使用该启动进程实际可用的网络环境。账号授权仍应以当前界面实际结果为准。
