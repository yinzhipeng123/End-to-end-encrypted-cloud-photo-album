# GitHub Authorization Follow-up — 2026-11-11

## Scope

用户要求清理已编译程序及中间产物，然后按计划继续。阶段一／二已完成；3.1包含尚未决定的Gitee部分，按既有分平台批准先接续3.2 GitHub，兼顾共享请求校验。未变更GAR-2、密码学、仓库格式、删除策略、iOS范围，也没有提交或推送。

## Cleanup

已只读核对正常包、隔离包、缓存与运行进程。build/混有原始验收日志、人工媒体和sync-platform/sender加密测试账号；不整目录删除。

第一次清理调用在执行前被自动审批拒绝，仅返回`blocked by policy`，无进一步理由。未删除任何产物，未换工具绕过。已向用户解释无法确认原因，不能当作Windows权限或杀毒软件错误。

准备`scripts/clean-build-artifacts.ps1`供用户手动运行：固定目标白名单、核对项目绝对路径及重定向父路径、拒绝在应用仍运行时清理、保留生命周期原始JSON并校验副本摘要、保留用户数据及加密测试账号；支持`-WhatIf`，成功后写`build/cleanup-result.json`。已解析PowerShell语法，没有执行删除或把脚本准备算作清理完成。下载的开发工具／依赖、人工媒体、原始日志不是本次编译产物删除范围。

用户随后手动执行脚本，报告于2026-11-11 13:45（Asia/Shanghai）删除29个路径。已只读复核正常及隔离EXE、.dart_tool、Windows ephemeral均不存在，build下未发现encrypted_photo_app.exe；源码、OpenSpec、加密测试账号及保留的生命周期报告存在。清理完成，当前没有可运行App包。本轮没有重新构建，后续测试／构建会按需重新生成缓存；用户真实照片库路径不在删除名单内。

## Implementation

- `lib/repositories/github_api.dart`：设备码携带从申请前开始的单调计时；从同一剩余时间判断轮询前、等待后和响应后的过期，响应本身已经过期也拒绝。公开测试构造同样从创建时计时；不引入持久化设备码。
- `lib/repositories/github_connection.dart`：界面有效期使用上述剩余时长，避免重新增加完整期限。`incorrect_device_code`／`bad_verification_code`提示重新授权，`unverified_user_email`提示在GitHub验证主邮箱。
- 共享HTTP检查修复未允许的200状态被放过的问题：具体请求允许201时不再因为收到200就走成功路径；2xx异常记为无法验证响应。该检查不等于上传验收。
- 两个既有测试文件增加过期、错误分流、异常状态、失败不保存／可重试检查；HTTP替身仍只存在test/，生产没有替身回退。
- `scripts/probe-github-auth-boundaries.dart`：限制为两个固定官方OAuth端点，记录路径及状态码，不记录响应体、设备码或令牌，不使用用户库，不打开浏览器，不请求仓库。

## Verification

1. 第一组协议测试19项通过；覆盖原有14项与新增错误／期限／状态码检查。
2. 关联回归54项通过：GitHub协议与连接、真实SQLCipher／DPAPI保存、Git同步协议和普通锁背景工作。HTTP和部分故障时机为测试替身，不能代替平台权限验证。
3. 最后补齐官方文档中的`incorrect_device_code`分流后，协议组20项全部通过；analyze无问题。没有将54＋20说成74个互不重复的测试。
4. 实际GitHub请求两次，均收到HTTP200：设备码申请返回899秒有效期；取消后未发令牌请求；另用一次人工无效设备码请求真实令牌端点，被生产解析为invalidDeviceCode。报告passed。没有用户授权或仓库写入；邮箱未验证、用户拒绝、真实令牌刷新／撤销及平台权限变化没有在本次实测。
5. OpenSpec严格校验及源码／日志摘要见`security-evidence/github-authorization-followup-2026-11-11.json`。

日志：`build/github-auth-followup-regression.log`、`build/github-auth-followup-final-api.log`、`build/github-auth-followup-analyze.log`；原始脱敏端点报告`build/github-auth-platform-2026-11-11.json`。

## Remaining

3.2仍保留未勾选：实际网页拒绝已于2026-11-11 14:06完成，拒绝后成功重试于14:08完成，设备码申请在途取消于14:11完成并留证；已显示设备码后的取消、保留原连接及其余适用GAR-2平台场景尚未齐。3.4–3.6、4.9未因此完成。当前26／73。用户数据／授权不能通过连接器凭据、解封令牌或自动填写用户密码代替。

清理结果已核对。下一步接续隔离产品入口的实际GitHub授权失败／重试与仓库访问验收；若需新测试包，明确其为本轮重新生成的测试产物，不沿用旧EXE冒充修正已打包。

## Isolated authorization acceptance preparation

2026-11-11 用户要求继续下一开发任务，接续 3.2。新增 `scripts/windows-github-auth-acceptance.dart`，使用生产 `PhotoVaultApp`、`VaultController`、SQLCipher 与 DPAPI，在 `build/github-auth-acceptance/vault` 保存独立人工测试库。没有导入用户媒体，也不读取此前测试账号的令牌。初次设置后停在 PIN 页面，由用户本人解锁及操作 GitHub 授权。

`scripts/support/github_auth_observer.dart` 委托真实 HTTP 传输，仅允许官方设备授权端点和账号／安装／仓库只读查询；仓库写入请求在委托前拒绝。`status.json` 只记录固定结果类别、HTTP 状态、已知 OAuth 错误、连接状态与计数，不包含账号名、仓库名、设备码、密码或令牌。生产入口没有导入该观察器。

`test/repositories/github_auth_observer_test.dart` 验证请求边界和输出脱敏，测试替身仅用于测试。首轮发现相对导入与 package 导入导致 Dart 类型身份不一致，统一新脚本的生产模块导入后，观察器及 GitHub API 共 22 项测试通过；静态分析无问题。这些结果不代替用户拒绝／取消／重新授权的实际平台验收。任务 3.2 继续保持未勾选。

清理后按需恢复依赖和构建缓存。首次依赖恢复提示系统未启用 symlink 支持，按 README 既有流程重建项目内插件 Junction 后，离线依赖复核成功；未修改 Windows 设置。

本轮验收步骤：独立窗口解锁 → GitHub 申请设备授权 → 用户在官方页面拒绝 → 核对真实 `access_denied` 和未保存连接 → 再次申请并由用户同意 → 核对实际账号／仓库查询及受保护保存；本机取消独立记录。不得由测试人员自动点击授权同意，也不得用连接器令牌代替用户操作。后续期限、刷新／撤销、权限矩阵和同步平台验收分别保留。

日志：`build/auth-acceptance-tests.log`、`build/auth-acceptance-analyze.log`、`build/auth-acceptance-build.log`。

两个 Windows Release 入口均构建成功（0.6.2+8）。隔离包完整复制到 `build/github-auth-acceptance/runner/`；标准 `build/windows/x64/runner/Release/` 随后按 `lib/main.dart` 重建。两份 AOT 摘要不同，标准包没有隔离测试密码字符串标记，隔离包包含该标记。标准包本轮没有启动。隔离构建有 media_kit CMake CMP0175 开发者警告，不影响本轮构建；不修改依赖源码来隐藏警告。

2026-11-11 13:59（Asia/Shanghai）独立窗口已实际运行并前置，截图及无障碍树均显示 PIN 锁屏页，脱敏报告同样为 `screen=pin`，请求数组为空。已请用户本人用人工测试 PIN 解锁，先完成 GitHub 拒绝授权。当前只是验收准备及启动通过，不是拒绝／授权／仓库访问通过。持久证据见 `security-evidence/github-auth-acceptance-2026-11-11.json`；后续用户操作结果须另行核对补录。

## Browser refusal — real platform result

2026-11-11 用户本人在 GitHub 授权确认页选择取消，提供两张截图：浏览器跳转 dashboard 并明确提示已拒绝该应用访问；App 显示“你在 GitHub 拒绝了本次授权。”，设备码／等待状态消失，授权按钮恢复可用。

真实传输观察器于 06:06:21.703774Z（14:06:21，Asia/Shanghai）记录令牌端点 HTTP 200、OAuth `access_denied`。随后生产连接状态为 `denialShown=true`、`busy=false`、`waitingForAuthorization=false`、`accountPresent=false`、`verified=false`、`savedConnectionState=null`。这一请求没有返回成功令牌，应用没有保存授权连接或选择仓库。没有仓库请求或写入；独立库媒体计数为零。

该场景通过，持久脱敏证据见 `security-evidence/github-auth-denial-2026-11-11.json`。记录还显示此前另一轮等待在 PIN 页面切换时被取消，但不能据此推断用户点击了“取消本次操作”，也不能把该观察当作显式取消按钮验收。已请用户继续拒绝后的重新授权，这次在网页同意；保持 3.2 未勾选，整体26／73不变。没有修改业务代码，也无需因纯证据补录重编译。

## Successful retry after refusal — real platform result

2026-11-11 用户本人再次发起设备授权并在官方页面同意。截图显示网页设备已连接，App 展示实际账号及 `test-album` 私有仓库，并显示平台报告具有写权限。

脱敏观察器在06:08:28.927060Z记录实际成功令牌响应；随后账号查询及两次安装／仓库查询分别返回200。06:08:35.982333Z记录生产目录连接状态为 `active`，`accountPresent=true`、`verified=true`、`eligibleRepositoryCount=1`、`busy=false`，尚未选择目标且媒体计数为0。同一进程此前有真实 `access_denied`，时间顺序证明拒绝后重新授权能够完成。受保护保存路径由生产连接执行，验收不读取或解封任何令牌；跨进程恢复及令牌刷新尚未由本场景覆盖。

该场景通过，证据见 `security-evidence/github-auth-retry-2026-11-11.json`。未执行仓库初始化、写入或媒体传输。已请用户补显式 App 内取消：重新申请设备码后点击“取消本次操作”，不打开浏览器；原已保存连接的保留及后续核验须按实际结果记录。任务3.2保持未勾选，26／73不变。本次无业务代码变更。

## Explicit cancellation during device request — real result

用户提供 App“本次操作已停止”的截图；核对日志发现原连接在14:11:12已为`disconnected`，之后才出现两次设备码申请取消。用户明确确认此前点击过“断开本机连接”。因此账号／仓库入口消失与主动断开一致，不归因为取消新授权错误删除已有连接；未据此修改业务代码。

两次真实设备码申请分别在06:11:31.309356Z及06:11:34.095549Z以`cancelled`结束，随后`busy=false`、`waitingForAuthorization=false`、`cancellationShown=true`、`savedConnectionState=disconnected`，断开之后没有令牌请求。截图、用户操作说明和请求记录共同证明“设备码申请在途取消”场景通过，没有伪报成功或保存新连接。这里没有设备码成功响应，不能误称为“显示设备码后停止轮询”验收，也不能证明取消时保留原有效连接；这两个范围仍待验证。

脱敏证据见`security-evidence/github-auth-cancel-2026-11-11.json`。本机断开不代表已撤销GitHub平台授权；本轮没有访问或更改平台授权设置。用户已完成的拒绝、重新授权及本次在途取消均单独保留，任务3.2不整体勾选，进度26／73不变。

## Official reference

2026-11-11重新核对GitHub官方“Generating a user access token for a GitHub App”的设备流及Troubleshooting章节。文档定义expires_in与interval，列出incorrect_device_code，并在排错中说明bad_verification_code和unverified_user_email。设备码保守计时属于既有期限校验的落实，没有改变平台授权方式。

官方来源：`https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-a-user-access-token-for-a-github-app`
