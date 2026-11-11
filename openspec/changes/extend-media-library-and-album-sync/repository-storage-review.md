# Repository Access and Storage Review — RAR-1

## Status and Scope

后续批准（2026-11-10）：用户明确答复“批准 RAR-1 的 TD09-A”和“同意先完成 GitHub 部分”。本文 TD09-A 及阶段三按供应商推进的安排现已生效，不重复询问。下面“待批／建议”为评审原文，由本条批准接续；TD10／TD11、Gitee、删除策略及未指定远端写入均不在批准范围内。

2026-11-10，任务 3.1 的具体评审稿。**TD09-A 及分平台推进已获用户批准；当前只做授权和仓库只读查询，不写远端媒体。** GAR-2 TD08-A 继续生效；不改变 SFR-1、TD07、媒体范围或三种删除范围，正式上传协议仍等待 TD10／TD11。

用户本轮已明确授权按 github-app-registration.md 协助注册 GitHub App，登录由用户操作。该授权解决注册操作范围，不等于 TD09 协议批准、安装到任意仓库或授权写入测试数据。实际注册结果另记。

本稿将 TD09 的 GitHub 传输与访问边界具体化为 TD09-A。Gitee 授权和传输能力作为 TD08-B／TD09-B 保留待核实，不假定与 GitHub 接口兼容。TD10／TD11 的最终密文格式、资源身份与合并规则仍须阶段 4.1 审核。

## Platform Evidence

以下为 2026-11-10 官方资料核对，不是本项目真实平台验收。来源编号见末尾。

| 平台能力 | 已查证事实 | 对本项目的影响 |
| --- | --- | --- |
| GitHub 用户令牌 | Device Flow 用户令牌刷新仍明确豁免 Client Secret；到期及轮换行为见 G1 | GAR-2 路线继续成立，不生成应用私钥或共享 Secret |
| GitHub API 版本 | 当前列出的版本包括 2026-03-10；不传版本头仍默认旧版，见 G2 | 候选固定使用 2026-03-10，后续升级单独回归；OAuth 端点不套 REST 版本契约 |
| GitHub 对象与发布 | Git blob／tree／commit／ref API 可组成一次提交；相关读写支持 GitHub App 用户令牌，见 G3–G6 | 可不维护本地完整 Git 克隆；必须在最终发布前验证全部必要资源 |
| GitHub 非强制引用更新 | force=false 检查 fast-forward；接口没有 expected-old-sha 参数，见 G6 | 不能称为严格 CAS；同一父提交产生竞争时重读，不能 force 覆盖他端 |
| GitHub 空仓库 | 无分支的空仓库不能直接通过 Create reference 建分支，见 G6 | 空仓库不能假称已就绪；初始化需要独立明确的写入行为 |
| GitHub 大文件与列举 | Get blob 支持最高 100 MB；递归 tree 有 100,000 条／7 MB 截断边界，见 G3/G4 | 50 MB 目标仍须包含加密开销并实测；truncated 不能当完整媒体目录 |
| GitHub 仓库规模 | 官方建议磁盘体积不超过 10 GB，并列出对象、目录、推送等限制，见 G7 | 分块不能提供无限容量；不把建议值写成 App 自定硬配额，也不承诺任意大小可用 |
| GitHub 调用限制 | 普通用户授权请求通常共享 5,000 次／小时；还有内容生成和其他二级限制，见 G8 | 根据实际响应暂停及重试；不通过换身份、换仓库或隐藏重试规避限制 |
| Gitee OAuth | 官方页面脚本仍列出授权码交换 client_secret；未找到完整公开客户端／PKCE／设备流程证据，见 E1/E2 | 保留无需自建服务要求，实际 OAuth 仍受阻；未发现说明不等于证明平台绝对不支持 |
| Gitee Git API | 官方 OpenAPI 5.4.93 列出 GET blob/tree、POST/PUT/DELETE contents 及创建分支；未列出与 GitHub 相同的 POST blob/tree/commit 与 PATCH ref，见 E3 | 不复制 GitHub 端点；文件 sha 参数也不能直接当作完整多文件原子发布保证 |

Gitee OpenAPI 与前端资源通过无账号、无令牌的公开 HTTPS GET 下载到被忽略的 build/provider-docs/2026-11-10/。没有调用 OAuth 交换或私有仓库接口。当前没有足以冻结 Gitee 用户套餐容量、API 请求体大小及条件更新语义的证据，不引用第三方文章的固定容量数字代替实测。

## TD09-A — Options

| 候选 | 优点 | 代价与安全影响 | 本稿建议 |
| --- | --- | --- | --- |
| GitHub HTTPS Git Database API | 直接处理对象及提交，避免本地全库历史和额外 Git 运行时；与批准权限匹配 | Base64 请求放大、API 限流、发布冲突与不确定结果都需处理 | GitHub 采用此路线 |
| Git HTTPS 传输及受控本地对象库 | Git 原生提交模型，后续可能适配更多托管平台 | 两端库绑定、临时文件、认证传递、磁盘及打包复杂；Gitee OAuth 阻碍仍存在 | 暂不采用；不是 Gitee 授权的自动替代 |
| 按文件 Contents API 更新 | 接口直观，Gitee 公开文档存在此能力 | 多资源提交与最后清单更新的并发语义需另证；不能仅靠每文件成功认定整项完整 | Gitee 仅保留候选，不批准通用实现 |

不自动引入 LFS、Release 附件、外部对象存储、后台服务或多仓库分片。它们会改变成本、权限或既有产品范围，不能用来绕过当前方案缺口。

## TD09-A — Proposed Contract

### 1. Stage Three: Authorization and Target Selection

阶段三只连接真实账号、安装和目标仓库，不上传照片、不初始化分支、不通过写探针证明权限。

- API 固定到 api.github.com，显式发送版本头 2026-03-10；OAuth 固定到 GAR-2 的 github.com 端点。TLS 正常校验，秘密不放入 URL；不盲跟随带认证的跨域重定向或服务端提供的任意下载地址。
- 按页读取 GET /user、GET /user/installations、GET /user/installations/{installation_id}/repositories，并重新获取选定仓库详情。相同名称不是相同仓库，保存 provider、Client ID、真实 user ID、installation ID、repository ID 与当前 owner/name。
- 检查应用身份／安装范围、Contents 写权限、用户对目标的写权限，以及 private、archived、disabled 等实际状态。缺字段、未安装、非私有、只读或不可访问分别报告，不用缓存列表伪造有效性。
- 列表和详情只能证明平台当时报告的访问条件；分支规则可能阻止后续写入。因此显示“已连接／已选择，上传尚未实现”，不能显示“备份就绪”或“已验证可上传”。实际写入验收放在获准隔离仓库中。
- 目标身份写入现有 SQLCipher 加密目录；令牌按 GAR-2 使用 DPAPI，引用与材料要绑定账户／应用／安装。重启后重新核对实际平台身份；本机锁定或 72 小时到期先阻断访问，授权成功不解除门禁。
- 账号与仓库切换使旧请求失效；本轮不继承任何媒体完成状态、不创建仓库。安装未完成可以有真实“账号已授权、未安装”的状态，不能把它伪报为已连接目标。

### 2. Stage Four: Proposed Publication Boundary

本段是 TD09-A 建议的传输方向；即使批准，TD10／TD11 未冻结前仍不能生成正式远端格式。

- 用户显式选择的私有照片仓库中，建议使用专用分支 refs/heads/epa-data-v1 和应用目录 .encrypted-photo-app/v1/；其他分支及已有文件保持不变。权限仍是仓库级，分支／目录不是 GitHub 授权隔离边界。
- 首次使用时只读检查该分支与命名空间。已有未知格式或其他库时拒绝覆盖。已有有效库须经正确照片密码打开；没有库时需要明确的初始化操作。空仓库先显示待初始化，不悄悄新建 README 或修改默认分支。
- 正式对象路径使用不携带原文件名的内部标识；密文清单恢复资源角色、顺序与必要关联。路径的准确编码、分片目录、公开格式头、密码包装与恢复资料在 TD10 确定，本稿不批准将本机 vault.bootstrap 或整个 catalog.db 直接上传。
- 下载固定到已读取的提交及对象标识，避免同一次恢复跨越不同最新分支状态。原图名、本机路径、照片属性及恢复敏感信息不能进入明文提交说明；提交身份／时间的最小公开字段在 4.1 继续明确。
- 上传先创建密文对象，再创建包含完整资源及清单的 tree/commit，以观察到的当前提交为唯一父提交；最后 force=false 更新专用分支。Git 对象标识只用于定位，不能代替 SFR-1 的认证加密和完整清单校验。
- 只有读回发布结果、验证完整资源引用后才标成功；仅 blob 上传、得到 commit SHA 或请求已发送均不是完成。冲突先重读并按 TD11 合并，规则未批准时阻断，不覆盖远端或擅自最后写入胜出。
- 超时／断网后保留结果未知及待核对状态，按实际分支和清单确认是否已发布；不能盲目重发非幂等请求。普通锁、到期和取消遵守 SFR-1，已经发送的字节不可撤回。
- 不自动 force push、重写历史、删除悬挂对象或承诺平台清理旧密文。三种删除的实际动作及历史保留边界继续等待 TD14；本稿不选择删除策略。

### 3. Capacity and Recovery Limits

- 保留“不设置 App 总容量配额”和“密文尽量 50 MB 内”的需求。平台限制独立存在，达到限制时准确暂停并保留原文件和队列；不自动建更多仓库。
- Base64 长度为 4 × ceil(密文字节数 / 3)，另有 JSON 和网络开销。例如 50,000,000 字节密文仅 Base64 就需要 66,666,668 字节；这只是预算示例，**不是批准 50 MB 单位或块尺寸**。准确界限、内存、磁盘与并发预算在 TD10／TD13 冻结并测试。
- 不依赖一次递归 tree 得到全库；遇到截断必须按子树取得完整所需信息。新设备仍须真实下载、验证和解密，不能从旧本地路径恢复来冒充仓库恢复。
- 平台能观察账号、访问时间、对象数量和密文大小；认证加密不能防止仓库删除或拒绝服务。force=false 不保证发现服务端恶意回退；无既有可信状态的新设备不能凭 Git SHA 判断最新性。相关回退边界在 TD11 验收，不宣传超出证据的保护。
- GitHub 使用及资源限制可能变化；本项目不承诺 GitHub 可无限期承载无限媒体。G7/G8/G9 仅作为接口和运行边界依据，不改变用户选择的平台。

## Gitee Remaining Evidence

继续保留真实 Gitee 登录和存储目标。TD08-B 缺符合无自建服务、无客户端共享秘密的完整官方授权依据；TD09-B 还缺上传大小、并发更新、令牌请求位置及多资源发布实测。注册一个要求 Secret 的应用不会自动解决这些缺口。

不能以第三方在 Gitee 托管的 PKCE 示例证明平台支持；不能以 PAT、SSH、平台密码、第三方授权中介或内置 Secret 代替。未解决前 Gitee 入口保持未实现且禁用，任务 3.3 与相应测试保持未完成。

## Implementation and Acceptance Map

实际代码职责如下，沿用已有目录、密封存储和会话撤销，不重新创建项目；结果见 windows-github-implementation.md：

| 模块／文件 | 任务与验收 |
| --- | --- |
| lib/repositories/github_api.dart | 3.2/3.5：真实设备流程、固定 HTTPS 来源与 API 版本、分页、错误及限流，无秘密日志 |
| lib/repositories/github_connection.dart 及现有 security/ | 3.4：DPAPI 绑定、不可变密封代次与 SQLCipher 引用提交、刷新意图和中断保护 |
| lib/repositories/github_connection.dart 及 storage/library_catalog.dart | 3.5：账号／安装／私有仓库核对，目标加密保存及会话撤销 |
| lib/app/vault_controller.dart、lib/ui/production_screens.dart | 接入现有同步页与锁定生命周期；GitHub 从未配置→真实授权→选择目标，上传入口继续按真实实现状态显示 |
| lib/ui/github_connection_panel.dart、windows/runner/flutter_window.cpp | 设备码／真实状态／仓库选择界面，固定官方授权页浏览器入口 |
| test/repositories/ 及 scripts/probe-github-device.dart | 3.6：HTTP 替身与真实本机加密测试单列；实际设备码请求只记录脱敏结果，完整平台矩阵未验收 |

验收门槛：应用注册信息核对；真实授权成功和拒绝／取消；未安装与安装后状态；指定私有目标实际返回；其他未安装私有仓库不可访问；只读用户不当作可写；锁定、重启、令牌轮换与保存失败；权限／可见性变化；无敏感日志。禁止为了通过验收临时扩大个人真实照片仓库权限；需要隔离账号或仓库的场景在条件不足时写未验证。

## Approval Record

1. 用户答复“批准 RAR-1 的 TD09-A”：上述 GitHub 访问与传输方向生效；第三阶段先授权与选择，第四阶段仍等待 TD10／TD11，不包含未指定的远端写入。
2. 用户答复“同意先完成 GitHub 部分”：3.2 及 3.4–3.6 的 GitHub 实施获准；Gitee 3.3 和其余部分保留，不降低完整验收要求，不扩展进入第四阶段。

## Sources and Reproduction

核对日期：2026-11-10。官方文档是能力证据；本轮没有带令牌的私有仓库测试，没有远端上传／删除，不能据此勾选业务任务。

- G1：`https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/refreshing-user-access-tokens`
- G2：`https://docs.github.com/en/rest/about-the-rest-api/api-versions`
- G3：`https://docs.github.com/en/rest/git/blobs`
- G4：`https://docs.github.com/en/rest/git/trees`
- G5：`https://docs.github.com/en/rest/git/commits` 与 `https://docs.github.com/en/rest/guides/using-the-rest-api-to-interact-with-your-git-database`
- G6：`https://docs.github.com/en/rest/git/refs`
- G7：`https://docs.github.com/en/repositories/creating-and-managing-repositories/repository-limits`
- G8：`https://docs.github.com/en/rest/using-the-rest-api/rate-limits-for-the-rest-api`
- G9：`https://docs.github.com/en/site-policy/acceptable-use-policies/github-acceptable-use-policies`，资源使用边界，不作为法律意见。
- G10：`https://docs.github.com/en/rest/apps/installations`
- E1：`https://gitee.com/api/v5/oauth_doc`
- E2：E1 当次引用的 `https://cn-assets.gitee.com/webpacks/api_doc-d7a00b8ede1b020799dd.bundle.js` 与 `https://gitee.com/static/locales/zh-CN.js`
- E3：E2 读取的官方定义 `https://gitee.com/api/v5/doc_json`，info.version=5.4.93，SHA-256 `b8bed1e612fb02ef1c96e03718f2602fe5188d73e7819f94866821be407cb9eb`。

E2 脚本 SHA-256：`bc586a886e07a946d6d135353b80512bf93c3bc2b6c51cae088fadeb71756766`；中文资源 SHA-256：`6b18b0dc38c248cb86ea7cb2aced468c68a9b03abd0ad296d966d0b1836959f8`。对这两个资源检索 code_challenge、code_verifier、device_code、PKCE、public client 均无匹配；只证明本次公开资料中未找到，不代替注册后的真实验证。
