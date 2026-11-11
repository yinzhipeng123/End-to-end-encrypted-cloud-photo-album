# GitHub App Registration Checklist

依据用户已批准的 GAR-2 TD08-A。2026-11-10 用户完成注册并提供下述公开标识；安装待用户选择，本轮无仓库写入。官方字段依据 GAR-2 的 G6，账号信息仅在 GitHub 官方网页填写。

## Registration

2026-11-10：用户授权按本清单协助注册，登录／访问验证由用户操作，随后提供注册标识。已通过生产 GitHubApi 实际请求设备码，返回有效码及 899 秒期限／5 秒轮询间隔；未交换用户令牌，不保存或记录设备码。注册权限和安装范围仍待账号授权后通过真实 API 核验。

在 GitHub 个人账号的 Settings → Developer settings → GitHub Apps → New GitHub App 创建，注意不是 OAuth Apps。

| 字段 | 填写值 |
| --- | --- |
| GitHub App name | encrypted-photo-app-yzp；如被占用可换唯一名称 |
| Homepage URL | 当前 GitHub 账号主页 |
| Callback URL | 留空，设备授权不使用回调 |
| Expire user authorization tokens | 保持开启 |
| Request user authorization (OAuth) during installation | 不勾选，随后由客户端发起设备授权 |
| Enable Device Flow | 勾选 |
| Setup URL / Redirect on update | 不填写／不启用 |
| Webhook Active | 关闭，无需 Webhook URL 和服务 |
| Repository permissions → Contents | Read and write |
| Repository permissions → Metadata | Read-only，平台自动要求 |
| 其他仓库／组织／账户权限 | 不申请 |
| Where can this GitHub App be installed? | Only on this account |

如网页要求上述设备流程不需要的必填字段，先记录非敏感错误，不虚构公网回调、不生成私钥或改选广权限应用来绕过。

## Installation and Handoff

2026-11-10 后续截图核对：test-album 的 Installed GitHub Apps 页面仅列出 ChatGPT Codex Connector 与 Codemagic CI/CD，没有本相册应用。此前用户口头确认“已经安装”不能作为当前安装证据，继续以实际 API 与安装页面核验。客户端补充“安装 / 管理 GitHub App”按钮，打开固定 github.com/settings/apps；在个人账号注册列表中核对 App ID 5690653，进入该应用的 Edit → Install App，选择 Only select repositories，仅选择 test-album。回到客户端检查连接／刷新仓库；只有实际合格查询结果可被选择。该按钮本身不会安装或修改权限，公开 slug 尚未核实，不猜测直达地址。

客户端 0.3.0+3 构建运行后，用户本人完成授权并明确反馈“授权成功，提示尚未安装仓库”。这是人工平台验证记录；下面的安装仍待用户选择，不从授权成功推断已安装。安装范围和权限应在安装后继续核验。

2026-11-10 用户完成注册并提供公开标识：Client ID `Iv23li0GQwH80cVzX6yX`；App ID `5690653`。Client ID 用于设备流程，App ID 用于核对安装属于同一应用，两者不可互换。用户另说明尚未安装，将稍后在 GitHub 选择照片私有仓库。没有提供或需要任何 Secret／私钥。注册字段是否符合清单及设备授权可用性仍须通过真实平台验证；不从标识存在推断已授权或已安装。

注册后在 Install App 进入本人账号，使用 Only select repositories，只选用于照片备份的私有仓库；不要默认选择本项目源码仓库。若尚未决定照片仓库，可先提供 Client ID，安装等待具体目标确认；不自动创建仓库。

开发接入需要公开的 **Client ID**（不是 App ID）。可把 Client ID 提供给开发者；不需要提供 Client Secret、Private Key、访问令牌或账号密码。此路线无需生成 Client Secret 或 Private Key。

注册、安装、App 内用户授权和仓库读写是不同状态。仅完成注册不能将 tasks.md 3.2–3.6 勾选；实际平台测试仍按 GAR-2，测试写入需另行明确隔离仓库及范围。
