# Proposal

## Why

需求基线已经归档，但目前没有可运行的应用。用户已明确要求开始开发并在 Windows 上运行查看，因此本变更将已确认流程实现为可交互、可测试的 Flutter 桌面原型。

## What Changes

- 新建 Flutter + Dart 工程及 Windows 运行入口，提供中文照片库、相册、同步与设置页面。
- 用虚构照片及内存状态演示 GitHub/Gitee 私有仓库选择、照片密码、四位应用锁、三天复验、同步暂停恢复和三种删除范围。
- 增加可控时间、失败情景、重置演示等原型工具，明确区分模拟与正式能力。
- 完成 Windows 构建、交互验证和启动，保留可适配手机的布局。iOS 原生构建和真机验收属于后续阶段，本次不将它们标为完成。
- 不改动七项产品行为契约，不实现真实账号连接、密码学或用户原图操作，归档中的 Q01–Q09 继续待定。

## Capabilities

### New Capabilities

- `prototype-session`：独立的演示会话、模拟边界、可重复场景以及 Windows 桌面运行体验。

### Modified Capabilities

无。既有七项规格保持不变，本次在明确的原型边界内演示它们的交互，不能据此宣称正式功能实现。

## Impact

- 增加 lib、test、assets、windows 等 Flutter 工程文件；更新 README 和忽略规则。
- 使用 Flutter 内置组件与 ChangeNotifier，减少原型依赖；演示状态仅在进程内存中保留，退出即重置。
- 本机补齐 Flutter SDK 与 Windows C++ 构建环境；不触及用户真实照片和仓库。
