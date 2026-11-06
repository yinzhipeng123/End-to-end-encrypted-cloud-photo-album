# encrypted-photo-app 开发交接

## 接手顺序

1. 阅读 `README.md`，了解当前交付状态、待开发需求和运行方法。
2. 阅读 `openspec/config.yaml` 及本次任务涉及的 `openspec/specs/*/spec.md`。
3. 查看 `openspec/changes/implement-windows-photo-prototype/` 的设计与任务；该变更的 14 项任务已完成，但尚未归档。
4. 涉及未决方案时，查看 `openspec/changes/archive/2026-11-06-design-photo-app-prototype/design.md` 的 Open Questions。归档是历史记录；当前代码状态和 README 中后续确认的需求优先用于判断开发进度。

## 当前实现

- 使用 Flutter + Dart，`lib/` 放共用界面与业务逻辑，`windows/`、`ios/` 放平台工程。
- Windows 交互原型已经构建并运行；iOS 只有工程骨架，未构建、未签名、未真机验证。
- 根目录 `codemagic.yaml` 已配置 iOS 模拟器预览、真机目标无签名编译验证和 Ad Hoc 签名 IPA 三条流程，首次云端构建仍待验证。用户目前没有付费苹果开发者账号，当前优先运行 `ios-simulator` 生成用于 Codemagic App Preview 的 `Runner.app`。浏览器预览服务需要另行启用；签名条件见 README，不要把模拟器或无签名产物描述为可直接安装到真实 iPhone。
- 当前照片来自 `assets/photos/`。状态和演示密码仅在内存中，重启后重置。
- 真实文件夹导入、加密、GitHub/Gitee 授权、仓库上传下载和原图删除均未实现。模拟进度不能被描述为真实备份或安全能力。
- 已确认但尚未实施的文件夹导入规则见 README 的“下一项需求”。这些规则无需让用户重复确认，但未决的实现细节仍需区分。

## 工作约定

- 用中文沟通、编写项目说明与 OpenSpec 内容；保留 OpenSpec 结构标题和 SHALL/MUST 关键词。
- 根据用户当次请求区分探索、规划和实现；确认需求不等于要求立即改代码。
- 下一项真实文件夹导入应使用独立的 OpenSpec 变更追踪，并明确调整现有“仅操作样片”的原型范围；不要把它塞进已完成的原型任务。
- 不擅自确定加密算法、密码派生、密钥保存、平台授权或其他未确认的重要方案。
- 保留 Flutter 标准目录结构；不要把业务代码分别复制到 Windows 和 iOS 目录。
- 用户原图、真实密码、令牌、编译产物和缓存不进入源码仓库。`assets/photos/` 是需要随源码提交的演示资源。
- `.agents/` 是本机生成的工作流文件，不纳入版本管理。即使没有这些技能，也应先阅读本文件、README 和 OpenSpec 资料再继续。

## 验证与交付

- Flutter 相关修改使用 `flutter analyze` 和适当的 `flutter test` 验证；Windows 构建方式见 README。
- OpenSpec 修改使用 `openspec validate --all --strict --no-interactive` 验证。
- 不把历史验证记录当作本次重新执行的结果；准确说明实际验证范围。
- 更新 README 中当前状态和下一步，确保后续开发不依赖原聊天记录。
