# Tasks

本表仅追踪目录迁移。用户于2026-11-11明确要求按已审阅结构实际调整，现按apply工作流实施；不改变媒体变更的26／73业务验收状态。按用户既有安排，实施阶段可格式化、静态分析、编译及只读核验，不执行测试套件、App、真实仓库或破坏性验收。不得用跳过测试代替通过，也不为目录重构自动提交或归档。

## 1. 建立可回退迁移基线

- [x] 1.1 记录全部源文件、已修改及未跟踪文件清单、摘要和原Git状态，在受忽略的本机目录保存可恢复快照；验收：清单覆盖本次映射全部文件，原内容有对应恢复来源，未执行reset/clean或提交。
- [x] 1.2 先更新根ignore，覆盖各host的build/.dart_tool、src/.local、src/.agents及签名／凭据等原有规则；验收：用git check-ignore核对代表路径，正式源码、锁文件、许可和OpenSpec仍可跟踪，旧ignore未失效。
- [x] 1.3 固定目录迁移清单和目标冲突检查，核对解析后路径、reparse point及运行进程；验收：无越界／覆盖式移动，不自动关闭用户程序；发现占用仅阻断相关批次。
- [x] 1.4 为旧build、IDE缓存及本机工作流建立仅本机保全清单，并在迁移说明写明恢复办法；验收：账号／人工来源／报告与产物都有归属，秘密和本机敏感路径清单未写入可提交证据。

## 2. 建立共享包及客户端工程

- [x] 2.1 建立src/shared私有Dart包，按directory-map迁移19文件闭包；验收：import/export/part/part-of解析正确，三个credentials关联文件保持同库，无Windows／Flutter反向依赖，无业务算法差异。
- [x] 2.2 建立src/windows Flutter根，保留encrypted_photo_app包名及固定生产依赖，以path引用../shared；迁移正式main/app/security/storage/repositories/services/sync/ui并改imports；验收：所有正式文件归属唯一，主入口传递依赖不含原型或验收工具。
- [x] 2.3 迁移Windows原生工程及许可assets，更新CMake／源码读取路径；验收：EXE名、MethodChannel、FFI导出、固定下载摘要、许可和EXE相邻依赖布局保持，路径均以Windows host为根。
- [x] 2.4 建立src/ios Flutter根，迁移原iOS工程及配置，以path引用shared，提供延续“尚未开放”的独立入口；验收：Bundle ID及原生工程保留，不复制Windows后端，不声称iOS实现完成。
- [x] 2.5 获取三个包的依赖并生成各自有效锁文件，保留已固定生产版本；验收：依赖解析成功、shared路径正确，没有借机升级算法／SQLCipher／播放器或更改Windows密码／数据配置。
- [x] 2.6 编写shared/README说明19文件归属、part约束及平台验收边界，编写ios/README说明目录、Codemagic入口及暂缓状态；验收：文档与当前源码／包关系一致，iOS未完成项完整保留。

## 3. 整理测试、原型与验收工具

- [x] 3.1 将旧原型模型／服务／界面及测试入口移入Windows test/legacy_prototype，样片与来源说明移入test/fixtures/legacy_photos；验收：原型源文件未丢失，正式assets不包含样片，生产import图不达测试支持目录。
- [x] 3.2 按Windows模块及shared分类迁移已有测试、support和安全向量，更新包导入与fixture路径；验收：文件数量与迁移清单一致，静态分析无缺失引用；不运行测试、不改断言来隐藏错误。
- [x] 3.3 将构建、维护、验收、fixtures生成器及SQLCipher独立probe按映射归类，补统一根定位和Dart包解析；验收：源码中无固定D盘业务路径或错误向上层数假设，独立包排除范围准确，跨tool的observer引用有效。
- [x] 3.4 更新验收工具的显式数据／报告根参数，保留隔离路径、VHD身份、来源范围和越界拒绝检查；验收：逐一静态对照原保护与新路径，默认不会打开旧账号或正常用户库，不执行实际平台测试。
- [x] 3.5 将旧build及本机文件按清单保全至src/.local/pre-structure，将本机工作流迁至src/.agents；验收：目标无覆盖、摘要逐项匹配、源位置仅在成功后移除，历史账号／来源／报告保留，新工具不会自动加载它们。

## 4. Windows编译目录与说明

- [x] 4.1 创建src/windows/build目录并调整构建脚本，使正常Flutter、原生source_reader、依赖缓存和验收程序编译输出落在其中，SQLCipher独立探针的--output及bundle／DLL核验改到build/probes/sqlcipher；验收：Windows编译输出配置均位于该build边界，独立iOS探针工程只配置到src/.local/probes，不向根或工具包内部build产生新产物，不执行iOS探针。
- [x] 4.2 更新src/windows/run-windows.cmd和构建脚本，显式指向正常lib/main.dart及标准Release，支持任意调用工作目录和带空格路径；验收：脚本解析／静态路径检查通过，失败不报成功、不启动隔离入口；本轮不执行启动脚本。
- [x] 4.3 在src/windows/README.md落实windows-readme-outline中的依赖、脚本与标准命令、可选代理、完整包位置和故障说明；验收：命令路径真实存在，依赖版本与实际工具链核对，说明build自动生成和编译不等于测试通过。
- [x] 4.4 更新维护清理脚本的明确产物白名单、WhatIf、占用和路径校验，不允许清理src/.local历史／账号；验收：只读审查及WhatIf无删除效果、目标全部限于已批准生成物，不执行实际清理。

## 5. Codemagic与项目规范

- [x] 5.1 保留根codemagic.yaml，三个工作流设置src/ios工作目录并更新仓库根相对artifacts，调整已经迁走的测试路径／暂无iOS测试的说明；验收：YAML解析及各脚本／产物路径一致，三类构建、签名要求和手动触发不变，不触发云端构建。
- [x] 5.2 将根AGENTS/README/config原文保留为明确历史快照，精简有效入口并保留八条正式产品约束、当前授权与安全决策索引；验收：快照摘要匹配，最新规则无丢失，旧历史不作为新指令。
- [x] 5.3 编写openspec/project/structure.md与current-status.md，根README导航到三个源码目录及Windows编译说明；验收：所有当前链接存在，历史changes/evidence路径与内容未改，媒体任务仍26／73。
- [x] 5.4 核对根结构只剩已批准文件、openspec、src及Git管理元数据；验收：无遗留正式源码／工具业务目录；额外本机文件先保全而非删除，缺少workflow技能也能由根AGENTS和OpenSpec接手。

## 6. 结构集成检查与Windows构建

- [x] 6.1 对迁移涉及Dart执行格式化和各包静态分析，对OpenSpec执行严格校验；验收：命令成功、路径／part／assets问题解决，无扩大analyzer排除项来掩盖错误；记录实际日志。
- [x] 6.2 从src/windows按其README构建正常Windows Release；验收：构建成功、EXE实际版本和入口正确，路径位于src/windows/build/windows/x64/runner/Release，未运行App。
- [x] 6.3 核对完整Release中的app.so、Flutter、SQLCipher、libsodium、source_reader、libmpv、ExifTool和许可，并记录源码／产物摘要；验收：固定依赖匹配、样片未打包、不会仅交付EXE，未以此宣称功能通过。
- [x] 6.4 输出本次迁移完成清单、旧→新路径、新构建日志和用户待验收事项；验收：正常用户库与DPAPI位置未修改，历史内容保全证据完整，未执行测试／App／提交／推送，其他变更状态未自动推进。

## Workflow follow-up

- 用户统一运行与测试：已有照片库解锁、导入、同步、播放和重启恢复的行为保持；iOS云端构建与原生能力仍单独记录，不能以路径检查代替。
- 用户确认迁移结果后再决定历史本机存档清理、提交及归档；本变更不自动执行这些操作。
