# Windows Organization Implementation

## Scope — 2026-11-10

用户确认 GitHub App 仍未安装到仓库，要求“先继续本机功能”。本轮接续 6.1–6.3 中已确认的本机相册、收藏、隐藏、查询及选择规则，沿用 TD07 SQLCipher、schema v3 和既有安全会话，不更改密码学、原文件身份、传输格式或删除策略。iOS 需求继续保留；相册元数据经仓库跨设备同步仍未批准。

正常入口版本为 0.5.0+5。真实业务服务不使用 DemoStore／LocalPreviewLibrary，不注入样片。隔离脚本、人工凭据与生成媒体仅用于测试。任务 6.1、6.3 按以下证据完成 Windows 范围；6.2 的本机部分实现并验证，但已同步／仅仓库状态筛选依赖真实传输服务，明确禁用，完整任务保持未勾选。6.8 的媒体同步衔接尚未验收。

## Implementation

| 文件 | 实际行为 |
| --- | --- |
| lib/storage/library_catalog.dart | 在现有加密表上增加查询与事务操作，无结构迁移；同一参数化条件服务分页、计数、ID 快照及执行前复查。SQLite 调用 Dart 小写函数做文件名搜索，搜索符号按字面处理。收藏／成员批次整体提交，失败整体回滚；不替换原媒体内容及副本／抑制自动上传字段 |
| lib/services/library_organization_service.dart | 解锁代次内的真实相册创建／改名／删除、收藏、成员、隐藏服务；随机相册 ID，不以名称合并；监听导入变化以清理选择；异步建相册写入前重新访问当前门禁 |
| lib/model/selection_state.dart | 复用选择规则，支持仅 ID 的当前完整结果快照；全选不局限于页面 200 项，新导入不会自动选中；切换查询清空、隐藏后剔除旧选择 |
| lib/app/vault_controller.dart | 与导入服务一起建立整理服务；锁定／关闭撤销服务与选择，旧引用不能读写库 |
| lib/ui/production_library_panel.dart | 所有照片／收藏、文件名搜索、本地状态筛选、多选／全选及取消、单项／批量收藏与相册成员操作；文件名仍仅详情显示；保存提示只在事务提交之后，取消无操作 |
| lib/ui/production_album_panel.dart、production_screens.dart | 我的相册实际创建、改名、隐藏开关、内部浏览和删除分组确认；明确只删分组、保留原照片；所属相册可浏览聚合隐藏项 |

任一隐藏相册使对应媒体从所有照片和收藏的列表／搜索／计数／全选中排除；移出最后一个隐藏来源或删除该相册恢复可见性，收藏不变。隐藏设置和整理不触发文件、仓库删除或自动重传。

本机整理批次采用单个 SQLCipher 事务：冻结选择 ID，执行前按当前查询再次筛选，所有符合条件项一起提交。SQLite 错误则整批不成功，不能把部分内存更改报告为保存。过期或不可见 ID 不扩展到其他媒体；结果数量按实际有效集合反馈。所有来源路径／名称／成员与收藏仍仅进入加密数据库。

当前“已同步”和“仅仓库”没有真实验证过的副本服务，界面标记未实现并禁用，目录接口也拒绝这两种查询；不从旧布尔字段推断备份，不用硬编码空列表冒充实现。当前“待同步”只筛选本地存在且未禁止自动上传的项目，不表示已经排入真实上传队列。批量上传／导出／媒体删除保持禁用，不能以整理事务代替这些真实文件操作。

## Verification

本机 Windows x64／NTFS，沿用已批准依赖。所有测试均使用隔离人工目录或人工目录记录，未读取用户图库、密码、PIN 或令牌。

| 证据 | 结果与实际边界 |
| --- | --- |
| build/organization-regression.log | 57 项通过：真实目录 15、controller 10、导入 13、整理服务 8、生产表单 1、历史查询规则 10。此轮后补充云端筛选的未实现拒绝，最终相关 9 项另行复测；不将两次重复检查加成独立数量 |
| build/organization-final-tests.log | 最终 9 项通过：8 个真实 SQLCipher／整理服务集成＋1 个生产表单完整流程。包括 257 项混合类型跨页快照、新项目不自动选入、Unicode 文件名及特殊符号查询、任一隐藏相册、旧选择再校验、同名相册分离、事务失败与凭据撤销 |
| 生产表单 | 正常 PhotoVaultApp／controller，真实源 PNG 导入、创建／改名／隐藏、全选收藏／成员调整、删除分组取消与确认、原文件存在、文件名仅详情、锁定清除路由与图像。只有原生选择器响应和 runner 事件投递为替身，业务、KDF、DPAPI、SQLCipher 与真实文件导入执行 |
| 实际写入失败 | SQLCipher trigger 在批次中途拒绝 UPDATE；整批收藏均回滚，重开后无半份记录，原选择保留以便重试，完整性通过 |
| build/organization-process-initial.log | 独立进程真实导入两张生成 PNG 和此前生成的 H.264 MP4，经真实服务建立／改名／隐藏相册、加入成员和收藏后关闭 |
| build/organization-process-crash.log | 第二个进程确认已提交整理恢复，在外层事务内取消收藏、改名、删除分组后主动 exit(91)，不执行关闭／回滚。Flutter 返回非零属预期中断，不能列为普通测试通过 |
| build/organization-process-reopen.log | 第三个进程从 PIN 门禁打开同库，确认未提交修改全部回滚、旧 ID／名称／隐藏／成员／收藏恢复；实际移出成员和删除分组后原图片及视频逐字节不变，加密库完整性通过 |

跨进程目录：build/organization-e2e/6b6e81ad3dae40f48ba307444667d751。initial／crash／reopen JSON 只记录人工验证结果。SQLCipher 页面明文标记检查是辅助证据，不单独证明安全；原密码学与数据库后端证据继续适用。

首次新测试缺少 unlock 的必需 expectedVaultId 参数，编译失败后补齐；界面测试曾未正确驱动弹窗 Future 与真实异步任务导致建相册尚未完成就断言，调整测试的 pump／runAsync 交替等待后通过。没有把失败结果计入通过。原生 UI、最终静态检查与标准构建记录在下方接续。

### Native and Release Checks

- 隔离入口 scripts/windows-organization-ui-probe.dart 构建通过（64.4 秒），复制到 build/organization-ui-runner/9ca73fe2163645cd82a9848dbdd17520 后运行；真实生成并导入 3 张 320×240 PNG，经生产服务保存一个隐藏相册及收藏。ready.json 记录媒体 3 项、聚合可见 2 项，人工数据与用户库隔离。
- Computer Use 获取该窗口截图时报告 `window is minimized`，刷新窗口并重试激活报告 `failed to activate captured window`。因此隔离原生界面视觉检查未通过／未验证，不把该记录冒充实际目视检查。上述生产 widget 的业务流程结果独立保留。
- 隔离进程已按其已核对的 PID／绝对路径关闭。随后已用 **lib/main.dart** 正常入口重新构建，69.2 秒通过；正常包不包含隔离入口行为。FileVersion／ProductVersion 均为 0.5.0+5，路径 build/windows/x64/runner/Release/encrypted_photo_app.exe。
- 正常程序已启动，PID 25896；只读无障碍树确认“密屿 · 应用已锁定”、四位应用锁输入及解锁按钮。未代填用户凭据、未读取用户图库。正常启动锁页不等同于用户原库全部功能验收。
- 最终 analyze 无问题；OpenSpec 全量 strict 9 项通过，apply 复核 22／70。日志 build/organization-analyze-final.log、organization-openspec-final.log、organization-release-build.log、organization-normal-launch.json。测试 57 项与最后 9 项属于重叠集合，不合计成 66 项。

## Remaining Work

- 6.2 的已同步／仅仓库筛选和 6.8 的真实媒体同步衔接等待阶段四；本机选择与整理结果不被包装成远端成功。
- 5.7–5.9 完整属性、封面、视频／Live Photo／ProRes 播放和全格式预览仍未完成；已有 ≤16 MiB 图片预览边界不变。
- 远端格式、恢复、导出及媒体删除仍按相关 TD 确认；本轮删除相册只操作加密分组关系。
- iOS 系统相册来源跟踪／覆盖／代次／停止规则保留，未接入到本轮 Windows 普通 App 相册；未将人工混合类型目录测试当作实况导入或播放验证。
- 未做长期大库压力、所有存储介质或新相册功能的物理锁屏／挂起全矩阵。本轮复用已验证的根门禁，另做生产 widget 撤销回归，不冒称新增物理测试。
- 不提交、不推送、不归档。源文件及正常构建哈希由 security-evidence/windows-organization-2026-11-10.json 记录。
