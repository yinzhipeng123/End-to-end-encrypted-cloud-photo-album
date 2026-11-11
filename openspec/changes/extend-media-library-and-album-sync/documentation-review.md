# Documentation Review

## Status

2026-11-09：按用户明确授权完成正式产品 OpenSpec 文档修订，等待用户审核后再开发。此次更新不选定加密算法、密钥管理、仓库协议、删除策略，不将 SQLCipher 独立验证认作正式接入。现有应用和构建能力没有因文档修订而改变。

## Changed Files

以下路径相对项目根目录。共 25 个文档文件：修改 15 个、新增 10 个；其中功能规格为 8 份原增量加强、5 份新增增量文件（生产交付及 4 个已有主能力的补充要求）。主规格与历史归档没有合并或改写。

| 文件 | 操作 | 内容 |
| --- | --- | --- |
| [AGENTS.md](../../../AGENTS.md) | 修改 | 八条项目约束、授权边界、接手顺序、真实状态及决策纪律 |
| [openspec/changes/extend-media-library-and-album-sync/acceptance.md](../../../openspec/changes/extend-media-library-and-album-sync/acceptance.md) | 新增 | 26 组实际业务验收场景、平台矩阵及证据模板 |
| [openspec/changes/extend-media-library-and-album-sync/design.md](../../../openspec/changes/extend-media-library-and-album-sync/design.md) | 修改 | 真实服务职责、前置能力实施责任、迁移及完成判定 |
| [openspec/changes/extend-media-library-and-album-sync/documentation-review.md](../../../openspec/changes/extend-media-library-and-album-sync/documentation-review.md) | 新增 | 本轮修改清单、审核要点和下一步 |
| [openspec/changes/extend-media-library-and-album-sync/implementation-notes.md](../../../openspec/changes/extend-media-library-and-album-sync/implementation-notes.md) | 修改 | 仅添加旧编号／旧验证结果的历史说明 |
| [openspec/changes/extend-media-library-and-album-sync/implementation-status.md](../../../openspec/changes/extend-media-library-and-album-sync/implementation-status.md) | 新增 | 界面／模拟／局部真实／正式验收分类及 53 项旧任务映射 |
| [openspec/changes/extend-media-library-and-album-sync/local-metadata-design.md](../../../openspec/changes/extend-media-library-and-album-sync/local-metadata-design.md) | 修改 | 明确当前文档阶段、候选未批准及新任务接续 |
| [openspec/changes/extend-media-library-and-album-sync/previous-task-baseline.md](../../../openspec/changes/extend-media-library-and-album-sync/previous-task-baseline.md) | 新增 | 旧 17／53 清单原文快照，保留历史勾选 |
| [openspec/changes/extend-media-library-and-album-sync/proposal.md](../../../openspec/changes/extend-media-library-and-album-sync/proposal.md) | 修改 | 正式产品范围、基础能力纳入、已确认需求保留 |
| [openspec/changes/extend-media-library-and-album-sync/specs/album-visibility/spec.md](../../../openspec/changes/extend-media-library-and-album-sync/specs/album-visibility/spec.md) | 修改 | 加强真实执行、持久化或平台结果场景，保留已确认行为 |
| [openspec/changes/extend-media-library-and-album-sync/specs/app-access-control/spec.md](../../../openspec/changes/extend-media-library-and-album-sync/specs/app-access-control/spec.md) | 新增 | 加强真实执行、持久化或平台结果场景，保留已确认行为 |
| [openspec/changes/extend-media-library-and-album-sync/specs/backup-management/spec.md](../../../openspec/changes/extend-media-library-and-album-sync/specs/backup-management/spec.md) | 修改 | 加强真实执行、持久化或平台结果场景，保留已确认行为 |
| [openspec/changes/extend-media-library-and-album-sync/specs/device-recovery/spec.md](../../../openspec/changes/extend-media-library-and-album-sync/specs/device-recovery/spec.md) | 新增 | 加强真实执行、持久化或平台结果场景，保留已确认行为 |
| [openspec/changes/extend-media-library-and-album-sync/specs/encrypted-storage/spec.md](../../../openspec/changes/extend-media-library-and-album-sync/specs/encrypted-storage/spec.md) | 修改 | 加强真实执行、持久化或平台结果场景，保留已确认行为 |
| [openspec/changes/extend-media-library-and-album-sync/specs/ios-album-import/spec.md](../../../openspec/changes/extend-media-library-and-album-sync/specs/ios-album-import/spec.md) | 修改 | 加强真实执行、持久化或平台结果场景，保留已确认行为 |
| [openspec/changes/extend-media-library-and-album-sync/specs/ios-media-import/spec.md](../../../openspec/changes/extend-media-library-and-album-sync/specs/ios-media-import/spec.md) | 修改 | 加强真实执行、持久化或平台结果场景，保留已确认行为 |
| [openspec/changes/extend-media-library-and-album-sync/specs/media-viewing/spec.md](../../../openspec/changes/extend-media-library-and-album-sync/specs/media-viewing/spec.md) | 修改 | 加强真实执行、持久化或平台结果场景，保留已确认行为 |
| [openspec/changes/extend-media-library-and-album-sync/specs/photo-library/spec.md](../../../openspec/changes/extend-media-library-and-album-sync/specs/photo-library/spec.md) | 修改 | 加强真实执行、持久化或平台结果场景，保留已确认行为 |
| [openspec/changes/extend-media-library-and-album-sync/specs/production-readiness/spec.md](../../../openspec/changes/extend-media-library-and-album-sync/specs/production-readiness/spec.md) | 新增 | 加强真实执行、持久化或平台结果场景，保留已确认行为 |
| [openspec/changes/extend-media-library-and-album-sync/specs/repository-connection/spec.md](../../../openspec/changes/extend-media-library-and-album-sync/specs/repository-connection/spec.md) | 新增 | 加强真实执行、持久化或平台结果场景，保留已确认行为 |
| [openspec/changes/extend-media-library-and-album-sync/specs/vault-onboarding/spec.md](../../../openspec/changes/extend-media-library-and-album-sync/specs/vault-onboarding/spec.md) | 新增 | 加强真实执行、持久化或平台结果场景，保留已确认行为 |
| [openspec/changes/extend-media-library-and-album-sync/specs/windows-media-import/spec.md](../../../openspec/changes/extend-media-library-and-album-sync/specs/windows-media-import/spec.md) | 修改 | 加强真实执行、持久化或平台结果场景，保留已确认行为 |
| [openspec/changes/extend-media-library-and-album-sync/tasks.md](../../../openspec/changes/extend-media-library-and-album-sync/tasks.md) | 修改 | 60 项八阶段任务，每项验收，全部未勾选 |
| [openspec/changes/extend-media-library-and-album-sync/technical-decisions.md](../../../openspec/changes/extend-media-library-and-album-sync/technical-decisions.md) | 新增 | 16 组技术决策选项、优缺点、安全影响及批准门槛 |
| [openspec/config.yaml](../../../openspec/config.yaml) | 修改 | 正式产品上下文、八阶段执行顺序与禁止模拟替代 |

## Requirements Retained and Strengthened

- 新增 production-readiness，将用户八条正式产品约束转为可验收要求：真实来源／操作、真实密码学、加密持久化、未实现准确禁用、测试隔离与实际证据。
- 补强真实平台授权／权限／令牌、真实首次初始化、跨启动锁与复验、独立无缓存恢复、实际导出删除、持久化队列和错误处理。
- 保留 Flutter、Windows/iOS、GitHub/Gitee、首版 ProRes 与 Live Photo、原始媒体不降质、Windows 普通原图、递归及补扫、本机加密元数据和已确认密码规则。
- 保留多选全选、隐藏规则、文件名仅详情、三种删除及显式重传、iPhone 相册改名新导入／删除保留／停止跟踪／手动恢复和 App 调整优先。
- 第六阶段的“同步”落实已确认系统到 App 变化跟踪及媒体同步；不自动增加相册元数据跨设备仓库同步。

## Development Tasks

旧 17／53 是旧验收口径；已逐项映射，不自动继承为正式完成。新 tasks.md 共 60 项，全部未勾选：

| 阶段 | 任务数 | 新增／补齐工作 |
| --- | --- | --- |
| 1 密码学与密钥管理基础 | 9 | 安全选型批准、真实密码学、平台材料、PIN／期限服务及验证 |
| 2 本机加密存储及持久化 | 6 | SQLCipher 双端验证、正式接入批准、事务目录、迁移恢复、真实启动替换 |
| 3 GitHub/Gitee 授权与仓库访问 | 6 | 两个平台独立授权、令牌保护、真实私有仓库及权限 |
| 4 上传下载分块恢复 | 8 | 格式决策、真实密文／队列／发布、独立恢复、并发与中断处理 |
| 5 双端媒体导入 | 9 | 稳定资源读取、递归及补扫、PhotoKit、实况关联、封面与真实播放 |
| 6 相册管理整理及已确认同步 | 8 | 加密整理、完整查询选择、系统相册生命周期和差异合并 |
| 7 导出删除与异常恢复 | 7 | 策略批准、实际导出／三种删除、部分失败和跨设备接续 |
| 8 完整功能测试与安全验收 | 7 | 无模拟交付检查、双端格式／仓库／恢复／安全／可靠性矩阵 |

单个组成任务的验证不等于整个 AC 产品场景通过；阶段内有自身测试，最后阶段执行完整联调。缺环境或待批准时保留未完成，不删减验收。

## Decisions Awaiting Confirmation

详见 technical-decisions.md。TD01–TD06：认证加密、KDF／参数、密钥层次、系统安全存储、密码策略、锁与期限／在途规则；TD07：数据库正式方案；TD08–TD11：平台授权、仓库提交、格式分块／元数据及并发恢复；TD12–TD15：导出暂存、运行条件／资源界限、删除与格式后端。

TD16 的额外相册元数据跨设备同步未获批准，不是本次必须补做的功能。SQLCipher 和 media_kit 已有验证授权继续保留，不重复把它们当全新路线请求选择；本轮未运行验证，正式接入和完整验收没有被宣告完成。

## Verification and Boundary

- OpenSpec 严格校验命令：`openspec validate --all --strict --no-interactive`；本轮文档校验通过，不是应用功能测试。
- 核对声明能力与 13 份增量规格、八阶段任务及 AC／TD 追踪；旧 53 项均有接续位置，旧 17 项勾选原文保留。
- 用本轮起始文件 SHA-256 基线检查改动范围：应用代码、平台工程、依赖、测试、资源、构建脚本、README、主规格及历史归档没有本轮改动；工作区此前已有修改仍保留。
- 没有构建、运行客户端、执行 Flutter 测试或 SQLCipher 探针；没有提交、推送、合并主规格或归档。

## Recommended Next Step

用户审核本轮文档后，从任务 1.1 开始：围绕 TD01–TD06 给出可批准的具体安全方案、参数与验证计划。用户明确批准相应选项后再实施 1.2 等真实业务；本轮文档审批不等于批准任何候选算法或协议。SQLCipher 按新 2.1 补验证，2.2 正式接入仍需单独满足门槛。
