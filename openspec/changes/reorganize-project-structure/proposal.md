# Proposal

## Why

当前根目录混放 Flutter 工程、历史原型、构建脚本和验收工具；项目规范又累积了多轮历史进度，新接手者难以迅速定位正式代码及有效约束。用户明确要求以 `openspec/` 和 `src/` 为根级业务目录，将 Windows、iOS 源码分开，并批准增加共享源码目录。

## What Changes

- 按已确认结构重整：根级业务目录仅 `openspec/`、`src/`；保留用户批准的 `AGENTS.md`、`README.md`、`.gitignore`、`codemagic.yaml` 四个根级文件；`.git/` 是必须保留的版本控制元数据。
- `src/windows/` 与 `src/ios/` 各自成为 Flutter 客户端工程，`src/shared/` 是双方通过 path dependency 引用的私有 Dart 包；共享密码学及格式规则不复制维护。
- Windows 当前正式入口、控制器、SQLCipher、原生适配、UI及真实同步归入 Windows 工程；最小共享闭包共19个Dart文件。iOS保留现有原生工程和明确尚未开放的入口，不以目录重整实现或宣称iOS功能完成。
- Windows 构建产物统一放在 `src/windows/build/` 下；正常 Release 维持标准相对布局。新增 `src/windows/README.md`，说明依赖、共享包关系、构建命令、运行和完整Release目录的交付方式。
- 构建脚本、验收工具、测试、历史原型及样片按用途隔离，正常运行不引用原型／验收入口。旧样片保留来源说明，仅作为测试fixture。
- 精简根级规范与OpenSpec配置，项目导航和当前状态位于 `openspec/project/`，历史证据原文保留，避免将旧结论误当当前状态。
- **BREAKING（开发路径）**：不再从仓库根直接运行Flutter命令；原根级构建、运行及源码路径改为各客户端工程内路径。更新Codemagic工作目录、产物路径、脚本和当前说明；提供旧→新迁移映射。
- 旧 `build/` 包含测试账号、人工来源及报告，必须在本机保全；不整目录删除，不把历史账号当新配置自动加载。正常用户照片库及DPAPI定位记录不属于本次迁移范围。

## Capabilities

### New Capabilities

无。此次为源码布局、构建路径和开发文档重构，不新增产品功能。

### Modified Capabilities

无。保持现有照片密码、加密、应用锁、媒体、仓库协议、删除及恢复规则。`.openspec.yaml` 显式设置 `skip_specs: true`，不制造新的业务规格，也不改写现有主规格或进行中的媒体变更。

## Impact

- 源码：当前 `lib/`、`windows/`、`ios/`、`assets/`、`test/`、`scripts/`、各Flutter配置、根启动脚本；具体归属见 `directory-map.md`。
- 构建：根 `codemagic.yaml` 保留，工作目录改为 `src/ios`；Windows从 `src/windows` 构建，正常程序位于 `src/windows/build/windows/x64/runner/Release/encrypted_photo_app.exe`。
- 依赖：增加私有共享包及两个host的本地依赖关系，不借机升级Flutter、密码库、播放器或SQLCipher版本，不改变EXE名、Bundle ID、MethodChannel／FFI名称和持久化格式。
- 协作：保留全部已修改／未跟踪源码；当前 `extend-media-library-and-album-sync` 的26／73验收状态保持；不自动归档、提交或推送。
- 本轮边界：只生成方案文件。迁移、创建实际 `src/windows/build/`、编写实际客户端README和编译均在用户审核后进入apply阶段执行；现有统一人工测试安排保持。
