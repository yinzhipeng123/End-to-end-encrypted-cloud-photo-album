# 密屿 · encrypted-photo-app



## 先从哪里看

| 想做什么 | 阅读入口 |
| --- | --- |
| 编译、运行 Windows 客户端 | [Windows README](src/windows/README.md) |
| 一键清理 Windows 编译包和中间产物 | 双击根目录 [clean-build.cmd](clean-build.cmd)；用法见下方 |
| 查看 iOS 工程和 Codemagic 构建说明 | [iOS README](src/ios/README.md) |
| 了解两端共用哪些代码 | [共享包 README](src/shared/README.md) |
| 了解当前版本、进度和待验收项目 | [当前状态](openspec/project/current-status.md) |
| 继续开发或交给另一个 AI | [AGENTS.md](AGENTS.md)，然后阅读当前变更的 proposal、design、tasks |
| 查旧目录迁到哪里 | [迁移映射](openspec/changes/reorganize-project-structure/directory-map.md) |



## 三级目录总览



```bash
encrypted-photo-app/                                  # 项目根目录
├── AGENTS.md                                         # AI 与开发者规范、产品约束和安全决策入口
├── README.md                                         # 项目导航、目录用途与编译入口（本文件）
├── .gitignore                                        # Git 忽略规则：缓存、产物、本机数据和秘密
├── codemagic.yaml                                    # iOS 云端构建配置，工作目录为 src/ios
├── clean-build.cmd                                   # 双击清理 Windows 构建包和中间产物
├── .git/                                             # Git 版本库管理数据，内部不展开
├── openspec/                                         # 产品需求、设计、开发任务和验收证据
│   ├── config.yaml                                   # OpenSpec 工作流和项目上下文配置
│   ├── changes/                                      # 各项变更的方案、设计、任务及证据
│   │   ├── archive/                                  # 已归档的历史变更
│   │   ├── extend-media-library-and-album-sync/       # 媒体与相册功能变更，业务验收仍为 26/73
│   │   ├── implement-windows-photo-prototype/        # 早期 Windows 原型的历史变更记录
│   │   └── reorganize-project-structure/             # 本次目录迁移方案、映射与完成证据
│   ├── project/                                      # 项目级结构、当前状态与历史规范
│   │   ├── current-status.md                         # 当前版本、构建结果和待验收事项
│   │   ├── structure.md                              # 工程关系、目录职责和路径边界
│   │   └── history/                                  # 迁移前规范和说明的原文快照
│   └── specs/                                        # 已有主规格，结合当前变更阅读
│       ├── .gitkeep                                  # 历史空目录占位文件
│       ├── app-access-control/                       # 应用锁、照片密码复验和访问控制规格
│       ├── backup-management/                        # 备份副本管理与删除范围规格
│       ├── device-recovery/                          # 已有照片库的授权与解密恢复规则
│       ├── encrypted-storage/                        # 上传前加密、密文分块及解密规格
│       ├── photo-library/                            # 照片和媒体库管理的基础规格
│       ├── repository-connection/                    # 平台授权、私有仓库选择与连接规格
│       └── vault-onboarding/                         # 初次建库、照片密码和应用锁设置规格
└── src/                                              # 客户端、共享代码及本机辅助资料
    ├── windows/                                      # Windows Flutter 工程根
    │   ├── README.md                                 # Windows 编译、运行及故障处理说明
    │   ├── pubspec.yaml                              # Windows 版本、依赖、资源与构建配置
    │   ├── pubspec.lock                              # Windows 依赖版本锁定
    │   ├── analysis_options.yaml                     # Dart 静态分析规则
    │   ├── .metadata                                 # Flutter 工程元数据，随源码保存
    │   ├── run-windows.cmd                           # 启动已编译的正常 Windows Release 包
    │   ├── lib/                                      # 正式业务代码：入口、UI、导入、加密和同步
    │   ├── windows/                                  # 原生 Windows 工程、CMake 和平台适配
    │   ├── assets/                                   # 正式资源，当前为许可证
    │   ├── test/                                     # 测试、人工样本及隔离的旧原型
    │   ├── scripts/                                  # 构建、维护和路径定位脚本
    │   ├── tool/                                     # 隔离验收、探针和样本生成工具
    │   ├── build/                                    # Windows 编译产物和依赖缓存（不提交）
    │   ├── .dart_tool/                               # Dart/Flutter 自动生成的工具缓存（不提交）
    │   └── .flutter-plugins-dependencies              # 自动生成的插件依赖信息（不提交）
    ├── ios/                                          # iOS Flutter 工程根，产品功能暂缓
    │   ├── README.md                                 # iOS 工程、云构建及未完成事项说明
    │   ├── pubspec.yaml                              # iOS 版本、依赖及共享包引用
    │   ├── pubspec.lock                              # iOS 依赖版本锁定
    │   ├── analysis_options.yaml                     # iOS Dart 静态分析规则
    │   ├── .metadata                                 # Flutter 工程元数据，随源码保存
    │   ├── lib/                                      # 当前未开放的入口及后续 iOS 代码位置
    │   ├── ios/                                      # 原生 Xcode 工程、Runner 和平台资源
    │   └── .dart_tool/                               # 自动生成的依赖配置与工具缓存（不提交）
    ├── shared/                                       # Windows 与 iOS 共用的 Dart 包
    │   ├── README.md                                 # 共享范围、平台边界和维护约束
    │   ├── pubspec.yaml                              # 共享包配置及固定依赖
    │   ├── pubspec.lock                              # 共享包依赖版本锁定
    │   ├── analysis_options.yaml                     # 共享代码静态分析规则
    │   ├── lib/                                      # 共用安全规则、模型、相册规则和同步格式
    │   └── .dart_tool/                               # 自动生成的 Dart 工具缓存（不提交）
    ├── .agents/                                      # 本机 AI 工作流（不提交）
    │   └── skills/                                   # 本机 OpenSpec 等技能定义
    └── .local/                                       # 本机保全和报告资料（不提交）
        ├── pre-structure/                            # 迁移前源码快照、旧 build 和历史测试资料
        └── reports/                                  # 本机检查、构建及验收报告
```

## 一键清理构建产物

先关闭正在运行的 Windows 客户端，再双击根目录的 [clean-build.cmd](clean-build.cmd)。脚本会清理当前 Windows 工程的已编译程序、构建依赖缓存、Dart/Flutter 中间产物和原生临时文件，结束后保留窗口显示结果。清理后需要重新编译才能运行程序。

源码、OpenSpec、照片库、密码数据及 `src/.local/` 中的历史测试资料会保留。正在运行的客户端不会被自动关闭；发现占用或不安全的路径时，脚本报错停止。实际清理逻辑位于 `src/windows/scripts/maintenance/clean-build-artifacts.ps1`，采用明确路径清单；当前只清理 Windows 工程。

也可以在 PowerShell 中运行，命令不依赖当前工作目录：

```powershell
# 只预览将清理的路径，不删除文件
& 'D:\encrypted-photo-app\clean-build.cmd' -WhatIf -NoPause

# 执行清理，完成后直接退出，适合命令行使用
& 'D:\encrypted-photo-app\clean-build.cmd' -NoPause
```
