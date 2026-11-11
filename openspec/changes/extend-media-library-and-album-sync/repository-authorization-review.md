# Repository Authorization Review — GAR-2 (GitHub Approved)

## Current Facts and User Direction

2026-11-09 初始评估：GitHub **先评估权限更细的 GitHub App**；Gitee **要求无需自建服务，继续核实能力**。当时两平台均未注册。2026-11-10 已取得用户提供的 GitHub 注册标识并实际验证设备码接口，用户手动确认真实授权成功并提示未安装；安装与完整平台矩阵尚未验收；Gitee 保留原缺口。

**后续批准（2026-11-09）：用户明确答复“批准 GAR-2 的 GitHub 方案”。TD08-A 下列配置、权限、Device Flow 用户令牌、DPAPI 与刷新／失败处理现已批准。未包含注册应用、远端写入或 TD09 仓库协议；Gitee 能力仍未确定。下列选项比较记录评估过程，GitHub 推荐候选不再处于待批准状态。**

本稿接续旧候选：OAuth App 的 repo 方案未获批准；Gitee HTTPS 中介不符合最新约束，不再作为实施路线。3.1 仍未完成，3.2／3.4–3.6 的 GitHub 局部实现与分层验证见 windows-github-implementation.md；下述平台资料不代表真实授权验收。

## TD08-A — GitHub App Evaluation

### Verified Platform Capabilities

- GitHub App 安装与用户授权分开：安装指定仓库及应用权限；用户令牌的私有仓库访问能力取应用与用户权限的交集。另有读取公开资源的隐含权限，不能宣称完全无法读取其他公开资料。[G1][G2]
- GitHub App Device Flow 的初次交换不要求 Client Secret；刷新文档也明确豁免设备流程取得的用户令牌。原生客户端应使用 user access token，不生成需要私钥的 installation access token。[G3][G4][G5]
- 官方最佳实践偏好浏览器授权＋PKCE，并提示设备码的远程冒充／钓鱼风险；但当前生成页仍将网页交换的 client_secret 列为必需，刷新页也仅豁免设备流程。不能从“支持 PKCE”推导完整网页链路已无需 secret。[G3][G4][G5]

### Options and Approved Selection

| 路线 | 收益 | 代价与安全影响 | 结论 |
| --- | --- | --- | --- |
| 私有 GitHub App＋指定仓库安装＋Device Flow 用户令牌 | 细化私有仓库权限；客户端只需公开 Client ID；无需自建服务 | 安装和用户授权两步；设备码钓鱼风险；需处理刷新与权限变化 | 用户已批准 |
| GitHub App＋浏览器／PKCE | 回调与 verifier 绑定 | 官方资料不足以确认完整无 secret 交换和刷新 | 不当作已证实路线 |
| OAuth App＋Device Flow＋repo | 设备流程明确 | 私有仓库授权较宽；用户要求优先评估细权限 | 旧候选未采用 |

### Approved Configuration

1. 用户个人账号注册私有 GitHub App，仅该账号可安装。建议名称 encrypted-photo-app-yzp（以实际可用性为准），主页用所有者 GitHub 主页。启用 Device Flow，保留用户令牌到期；关闭 Webhook，不启用安装时网页用户授权，不增加 Setup URL。设备流程无需回调接收器，不部署服务。[G6]
2. 仅申请仓库 Contents: Read and write，以及平台要求的 Metadata: Read-only；不申请账户邮箱、组织管理、Administration、Actions、Workflows。Contents 并非仓库内目录级隔离。TD09 确定具体端点后再核对所需权限，不静默扩大。[G2][G7]
3. 安装时 Only select repositories，仅勾选用户指定的照片备份私有仓库。不能自动使用当前源码远端作照片库。随后真实查询 GET /user、GET /user/installations 及 GET /user/installations/{installation_id}/repositories，保存账号／安装／仓库 ID。[G1][G3]
4. 用户可扩大安装范围；App 选中一个目标不等于令牌始终只有一个仓库权限。候选要求单仓库安装以缩小初始范围。设备交换的 repository_id 参数在目标不可访问时可能被忽略，不能作为唯一隔离保证。[G3]
5. 仅由 App 显式发起设备授权，打开固定 GitHub 官方设备页，提示只使用本 App 当前显示的码；不收集平台密码。遵守实际 interval／expires_in，处理 pending／slow_down／拒绝／过期／取消；本机锁定取消事务，晚到结果不得建立连接。
6. 请求过期令牌：offline_access 只控制到期，不授予仓库权限。官方当前默认 access token 八小时、refresh token 六个月，实际以响应为准。刷新使旧令牌对失效；每账号／安装串行刷新，完整新令牌对用 DPAPI 保护并原子替换。响应丢失或保存失败要求重新授权，不伪报连接有效。[G4]
7. 使用已批准 Windows 用户范围 DPAPI，按 provider／Client ID／账号／安装绑定材料。仅有效会话中使用；日志不含 code、token 或秘密。401、权限缩减、仓库变公开、身份变化阻断对应业务；403 区分限流与权限。
8. 断开连接移除本机材料；平台撤销引导用户在官方设置操作，再依据真实响应核对。未实际撤销不称“平台已撤销”。无 Webhook 时不能承诺实时获知变动，相关操作前真实检查。

这些项目策略已获上述批准。细权限减少影响范围，但不能阻止获权进程破坏密文；平台授权不等于照片解密。本稿不批准存储协议、文件删除或历史清理。

### Acceptance Before Completion

- 实际注册应用与隔离私有仓库：指定仓库可用、未安装的另一个私有仓库拒绝、只读用户不可写；测试写入只在另行明确选定的隔离仓库进行。
- 未安装、未授权、拒绝、取消、过期、限流、锁定、晚到响应分别验证。
- 真实令牌刷新及旧令牌失效、重启、响应丢失／保存失败、撤销、安装范围缩减和可见性变化分别留证。
- DPAPI 与敏感日志检查独立记录；HTTP 替身仅补异常覆盖，不能代替平台验收。

## TD08-B — Gitee Without a Self-hosted Service

### Verified Evidence and Limit

读取官方 OAuth 页及其引用的前端脚本、中文正文：[E1–E3]

- 授权码交换示例含 client_id、code、redirect_uri、client_secret；正文建议 secret 放 POST body。POST body 不解决桌面客户端无法保密共享 secret 的问题。
- 密码模式仍含 secret，并要求客户端取得平台账号密码，不采用。
- 刷新示例只列 grant_type 与 refresh_token，不能据此解决初次交换的 secret 问题。
- 对官方脚本核对 code_challenge、code_verifier、device_code 未找到匹配；官方帮助及 OAuth 资料检索没有找到足以确认公开客户端能力的说明。Gitee 托管的第三方 PKCE 代码不是平台能力证据。

**截至本次核对，无法确认同时满足真实 Gitee OAuth、客户端无共享 secret、无需自建服务的完整链路。不是断言平台永久不支持。** 未注册应用，没有有效授权码，无法进行真实交换验收；用无效 Client ID 测试错误响应也不能证明能力。

### Retained Constraints and Evidence Needed

Gitee 需求保留，入口继续标未实现。自建中介、第三方代换服务、内置／混淆 Client Secret、索取平台密码均不采用。PAT 或 SSH 不是 OAuth 登录的自动替代品。

缺口是官方可核对说明及真实注册条件：能否注册 public client／token endpoint auth method none；是否支持 S256 PKCE 或设备授权；允许哪些本机回调、刷新及撤销方式。具备证据后才形成可实施路线。本次不创建应用、不联系第三方、不操作服务器。

## Decision Gate

2026-11-10 用户已授权“按清单协助注册，登录由我操作”，随后提供 Client ID/App ID。生产 API 已实际取得设备码；安装待用户自行选择；用户已手动确认客户端真实授权成功，提示尚未安装。用户另明确批准 repository-storage-review.md（RAR-1）的 TD09-A 与 GitHub 独立推进，不重复请求同一批准。Gitee 官方资源及 OpenAPI 本日重新核对，公开客户端缺口未解决。

TD08-A 已批准，公开标识见 github-app-registration.md。真实账号授权成功由用户手动确认；令牌实际轮换、安装范围及权限变化的完整平台验收尚未执行。Gitee 无需自建服务已确定，不重复询问是否接受服务，安全公开客户端能力仍缺证据。

TD09-A 已批准；TD09-B、TD10–TD14 的 Gitee 协议、分块、媒体身份、调度、导出和删除仍保留门槛。阶段二 Windows 已验收，不扩大本次 GitHub 实施范围。

## Evidence Sources

核对日期 2026-11-09。官方资料用于能力判断；GitHub 项目策略已批准，实际平台验收待执行。注册字段清单见 github-app-registration.md。公开页面缓存位于被忽略的 build/provider-docs，无登录态。

- [G1] https://docs.github.com/en/apps/using-github-apps/authorizing-github-apps
- [G2] https://docs.github.com/en/apps/creating-github-apps/registering-a-github-app/choosing-permissions-for-a-github-app
- [G3] https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-a-user-access-token-for-a-github-app
- [G4] https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/refreshing-user-access-tokens
- [G5] https://docs.github.com/en/apps/creating-github-apps/about-creating-github-apps/best-practices-for-creating-a-github-app
- [G6] https://docs.github.com/en/apps/creating-github-apps/registering-a-github-app/registering-a-github-app
- [G7] https://docs.github.com/en/rest/repos/contents
- [E1] https://gitee.com/api/v5/oauth_doc
- [E2] https://cn-assets.gitee.com/webpacks/api_doc-d7a00b8ede1b020799dd.bundle.js
- [E3] https://gitee.com/static/locales/zh-CN.js

