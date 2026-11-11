# 当前项目状态

更新日期：2026-11-11。此文件是当前状态入口；历史快照及旧实施记录不自动覆盖本页和用户后续明确指示。

| 项目 | 当前状态 |
| --- | --- |
| Windows 源码版本 | 0.7.1+10 |
| 正常入口 | `src/windows/lib/main.dart` |
| Windows 构建根 | `src/windows/` |
| Windows 产物位置 | `src/windows/build/windows/x64/runner/Release/` |
| 目录变更 | `reorganize-project-structure` 已实际迁移，结构检查与新路径 Windows Release 编译通过；详见实施记录和 tasks.md |
| 媒体功能变更 | `extend-media-library-and-album-sync`，26／73 项已验收；近期编码待用户统一测试 |
| iOS | 独立工程与共享依赖按结构方案保留；产品功能暂缓、未开放 |
| Gitee | 授权和同步未实现；无自建服务且客户端无Secret的授权能力缺口保留 |

本次迁移后，shared、Windows 和 iOS 工程的静态分析通过；从 `src/windows/` 对正常入口重新编译 Windows Release 成功，耗时 245.5 秒，EXE 文件／产品版本均为 `0.7.1+10`。完整依赖、许可证与固定依赖摘要已核对，正式包没有历史样片。iOS 只做静态分析，没有云端构建或原生功能验收。新记录见[目录迁移实施记录](../changes/reorganize-project-structure/implementation.md)和[摘要证据](../changes/reorganize-project-structure/migration-evidence.json)；编译通过不代表产品功能验收通过。

根 [README.md](../../README.md) 按实际目录说明三级以内文件与目录用途。旧构建、测试账号及人工来源保存在受 Git 忽略保护的 `src/.local/pre-structure/`；343 个原项目文件快照和 5,650 项历史文件／链接记录已核对一致。此处是迁移保全资料，不是正常用户照片库。

Windows 已接入真实密码学、DPAPI、SQLCipher、递归导入、相册整理、GitHub授权及密文同步、媒体播放、导出、三范围删除和恢复等代码。这里不表示完整业务或全媒体格式已经验收。普通界面锁保留后台，系统锁屏／睡眠／期限到期撤销后台，按既有批准规则保持。

用户要求统一测试，当前不由开发代理运行测试套件、App、真实账号／仓库或破坏性验收。目录重整允许静态分析和编译；不提交、推送、归档，不修改其他变更的业务勾选。

接续入口：

- [目录重整任务](../changes/reorganize-project-structure/tasks.md)及[迁移设计](../changes/reorganize-project-structure/design.md)。
- [媒体功能任务](../changes/extend-media-library-and-album-sync/tasks.md)及[最近编码交接](../changes/extend-media-library-and-album-sync/windows-followup-implementation.md)。
- [Windows 编译说明](../../src/windows/README.md)。
- [项目结构](structure.md)及[根级规范](../../AGENTS.md)。
