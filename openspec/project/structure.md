# 项目目录与工作入口

目录重整依据 [reorganize-project-structure](../changes/reorganize-project-structure/proposal.md)。迁移完成与构建状态见[当前状态](current-status.md)，逐项旧路径映射见[迁移映射](../changes/reorganize-project-structure/directory-map.md)。

```text
encrypted-photo-app/
├─ AGENTS.md                 项目有效开发规范
├─ README.md                 人工阅读导航
├─ .gitignore                生成物与本机数据规则
├─ codemagic.yaml            iOS云端构建入口
├─ clean-build.cmd           Windows构建包和中间产物的一键清理入口
├─ openspec/
│  ├─ config.yaml            精简项目上下文
│  ├─ specs/                 主规格
│  ├─ changes/               变更、任务、决策和证据
│  └─ project/               目录说明、当前状态、规范历史快照
└─ src/
   ├─ windows/               Windows Flutter工程根
   │  ├─ README.md
   │  ├─ pubspec.yaml / pubspec.lock
   │  ├─ lib/                正常入口、平台业务与界面
   │  ├─ windows/            原生runner、CMake与source_reader
   │  ├─ assets/licenses/
   │  ├─ test/               正式、共享规则及旧原型测试
   │  ├─ scripts/            构建和维护脚本
   │  ├─ tool/               隔离验收、探针与fixture工具
   │  ├─ run-windows.cmd
   │  └─ build/              Windows编译生成物，不提交
   ├─ ios/                   iOS Flutter工程根，功能暂缓
   │  ├─ README.md
   │  ├─ pubspec.yaml / pubspec.lock
   │  ├─ lib/main.dart        明确未开放的入口
   │  └─ ios/                原生Xcode工程
   └─ shared/                私有共享Dart包
      ├─ README.md
      ├─ pubspec.yaml / pubspec.lock
      └─ lib/                共用模型、安全规则、格式
```

根目录中的 `.git/` 是版本控制元数据。`src/.agents/` 是本机工作流，`src/.local/` 是受忽略的本机保全／验收数据；Flutter生成的 `.dart_tool`、ephemeral等也不提交，不属于额外业务工程。

两个客户端通过 `path: ../shared` 引用 `encrypted_photo_shared`。Windows 包名保持 `encrypted_photo_app`，iOS 为 `encrypted_photo_app_ios`；可执行程序名和 iOS Bundle ID 保持原身份。`src/windows/windows/`、`src/ios/ios/` 的内层目录是各自 Flutter 工程的原生平台目录，不是第二份客户端。

共享包保留19个Dart文件，包含12个安全相关文件、5个模型、相册跟踪规则与同步格式。DPAPI、SQLCipher、Windows导入／播放／同步控制器仍在Windows工程；共享包不可反向引用它们。现有共享规则测试位于 `src/windows/test/shared/`，不因此声明iOS已通过同样验证。

普通构建从 `src/windows/` 开始；最终程序位于其 `build/windows/x64/runner/Release/`，须连同全部依赖使用。SQLCipher独立探针虽在 `tool/probes/sqlcipher/`，Windows编译输出也归host的 `build/probes/sqlcipher/`。iOS由根Codemagic配置选择 `src/ios` 工作目录，产物声明以仓库根定位。

旧原型和样片只放Windows测试目录，不进入正式assets或主入口依赖。旧根build中的测试账号、人工来源和报告保全于 `src/.local/pre-structure/`，新验收数据与报告另行显式定位，清理脚本不删除这些保全目录。正常用户图库仍在选定位置或默认LocalAppData，目录重整不搬动或重建它。

当前状态和开发规范集中在本目录与根AGENTS中。历史规范保存在[迁移前快照](history/pre-structure/README.md)，旧OpenSpec证据仍保留原路径及哈希；不要批量替换历史记录里的旧目录字符串。
