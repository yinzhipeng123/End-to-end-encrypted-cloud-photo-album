# 目录迁移实施记录

日期：2026-11-11。用户明确授权实际调整已审阅结构。此次迁移保持产品行为，按当前统一测试安排只执行文件核对、静态检查和Windows编译。

## 实际目录

根目录现在为openspec、src、AGENTS.md、README.md、.gitignore、codemagic.yaml，另保留隐藏的.git管理元数据。Windows、iOS、shared已实际建立；源码、原生工程、测试、工具及依赖配置已经迁移，不是空目录或计划占位。

- Windows正常入口：`src/windows/lib/main.dart`。
- Windows编译说明：`src/windows/README.md`。
- 新正常包：`src/windows/build/windows/x64/runner/Release/encrypted_photo_app.exe`，PE文件／产品版本均为`0.7.1+10`。运行需保留整个Release目录。
- iOS仅保留独立工程及明确尚未开放的入口，没有新增iOS业务能力。
- shared恰19个Dart文件；两端通过本地包依赖引用，密码学规则不复制。

## 保全与行为边界

- 343个原项目文件完成可恢复快照核对，5,650项本机历史文件／链接记录迁移前后验证一致。旧build整体保存在`src/.local/pre-structure/build/`，其测试账号、人工来源及报告未删除，未自动重新加载。
- 快照、迁移清单和敏感的本机历史清单留在受ignore保护的src/.local。根规范的三份历史原文另保留于openspec/project/history/pre-structure，摘要匹配。
- 对52个Windows正式／shared Dart文件与原快照进行对照，除import/export/part和格式／注释外没有业务代码差异。正式main传递引用50个本项目文件，不到达test/tool/legacy。
- 原生工程源文件迁移后原文保持，Windows程序名、MethodChannel、FFI、DPAPI用途及用户库定位、iOS Bundle ID未改变。
- 锁文件与基线共同依赖版本全部保持：Windows88项、iOS29项、shared24项。没有升级密码库、SQLCipher或播放器。
- 原型及历史样片归Windows测试区域，正常assets仅包括许可证；旧OpenSpec证据没有替换路径或重算为新结果。

## 检查和编译

| 项目 | 实际结果 |
| --- | --- |
| shared Dart分析 | No issues found |
| Windows正式源码与测试文件分析 | No issues found，11.1秒 |
| iOS独立入口及工程分析 | No issues found，7.5秒；不是iOS编译／运行证明 |
| 全Windows工程最终分析 | No issues found，7.5秒，含工具源码 |
| Dart格式化 | 123文件检查，34个测试／工具文件格式调整；生产源码未因最终格式化变化 |
| PowerShell／Python | 11个PS文件语法解析、4个Python文件AST检查通过 |
| 清理脚本 | 仅执行WhatIf，列出新host的8个当时存在生成路径；没有删除 |
| 正常Windows Release | 从src/windows构建lib/main.dart，成功退出0，245.5秒 |
| OpenSpec | reorganize-project-structure严格校验通过；skip_specs保持 |

本机首次在新目录执行pub get遇到Flutter插件符号链接权限限制。核对生成插件清单后创建项目内目录联接，再次获取成功；构建脚本已提供仅针对该错误的同等后备处理。没有修改系统开发者模式、申请管理员权限或修改Pub缓存。初次失败保留说明，不计作成功。

构建仍有上游media_kit_libs_windows_video关于CMake CMP0175的开发者警告，构建成功；此次没有为消除警告升级依赖或修改第三方缓存。

日志位于`src/.local/reports/structure-migration/`；源码与关键产物摘要、检查分类见[migration-evidence.json](migration-evidence.json)。PowerShell／Python和WhatIf的首次静态结果记录在工具会话中，未伪造额外日志。

完整Release核对包括主程序、AOT、Flutter运行库、SQLCipher、libsodium、source_reader、libmpv、ExifTool及其支持目录、许可证。SQLCipher、libmpv、ExifTool等固定预编译依赖与迁移前证据一致；重编译的应用及本机源码产物记录新摘要，不要求与旧二进制相同。

libsodium由sodium 4.1.2+1的native-assets hook在新目录本机重编译，DLL摘要与旧包不同。已核对新旧PE版本均1.0.22.0，494个相关源码和工程文件逐字一致，新包DLL摘要与本次hook输出一致；路径、PDB和链接时间变化单独记录在证据中。此项证明来源未换，不冒称二进制相同或重新通过密码学运行验收。

用户随后要求根README逐项说明当前三级内目录及文件，已按真实结构补充目录用途清单，并区分正式源码、自动生成物、Git管理区及本机保全资料；更深层代码职责由对应目录说明和各host README承接。

## 接续

目录迁移的完成检查与产品验收分开。没有运行App、测试套件、真实仓库、锁屏、睡眠、删除或恢复；没有提交、推送或归档。媒体功能变更仍26／73，Gitee未实现、iOS暂缓。用户可在新路径运行Windows包统一测试。历史本机存档暂留，今后清理需另行决定。
