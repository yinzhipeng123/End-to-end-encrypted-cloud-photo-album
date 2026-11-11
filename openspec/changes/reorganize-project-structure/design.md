# Design

## Context

动机与用户确认见 proposal.md。2026-11-11只读检查得到：当前为单个Flutter根工程；`lib/`共68个Dart文件，正常入口静态依赖可达50个，其余包含旧原型和保留的iOS规则，不能整体删除。正常入口仅开放Windows；VaultController、网络代理、原生读取和存储适配直接依赖Windows能力。

用户已经确认：根级业务目录只有openspec和src；src增加windows、ios、shared；根保留AGENTS.md、README.md、.gitignore、codemagic.yaml四文件；Windows构建文件归src/windows/build，并提供src/windows/README.md。Gitee未实现、iOS暂缓及人工统一测试安排继续有效。本次是纯重构／工具调整，按工作流skip_specs，不改变产品规格。

## Goals / Non-Goals

**Goals:**
- 两个可独立执行Flutter命令的客户端工程、一份共享安全／格式代码，目录归属明确。
- 保留完整原生依赖相对布局、现有数据兼容和开发记录，迁移可审阅、可回退。
- Windows编译操作在其README中能直接复现，源码、构建产物、验收数据各有明确去处。

**Non-Goals:**
- 不实现iOS后端或Gitee，不改变用户界面／业务流程、不重写状态管理或拆解大型控制器。
- 不升级生产依赖、不改数据库schema、密文格式、密码学参数、DPAPI绑定、系统身份或账号。
- 不运行真实账号授权、仓库写入、锁屏、删除或恢复验收，不自动提交、推送或归档其他变更。

## Decisions

### D1：两个Flutter host和一个私有共享Dart包

采用用户确认的结构，完整目标树和逐项映射见directory-map.md。Windows包名继续`encrypted_photo_app`；iOS host使用`encrypted_photo_app_ios`；共享包为`encrypted_photo_shared`，均`publish_to: none`。两端用`path: ../shared`引用唯一共享源码。Dart包名不改变Windows EXE、iOS Bundle ID或原生MethodChannel。

Windows原生工程放`src/windows/windows/`，iOS原生工程放`src/ios/ios/`，保留Flutter内部目录约定；不为了消除重复名称改写CMake/Xcode布局。Windows正式main整体迁移并改imports；iOS新入口延续原有非Windows“尚未完成”行为，引用共享包不代表已运行其安全后端。iOS App身份`dev.miyu.encryptedPhotoApp`保持。

未选方案：根继续为Flutter工程不符合用户最终布局；各端复制完整Dart代码会产生两套安全规则；把全部Windows控制器/UI移入shared会隐瞒现有平台耦合，扩大到iOS架构重写。

### D2：只提取已确认的最小共享闭包

19个文件映射详见directory-map.md：12个安全与通用存储接口／记录文件、5个模型、相册跟踪规则和同步格式。共享运行依赖仅固定`sodium: 4.1.2+1`，不依赖Flutter、SQLCipher或Windows FFI；保持现有SDK约束。`vault_media_crypto.dart`、`vault_remote_recovery.dart`是`vault_credentials.dart`的part，必须在同包同库迁移。

Windows DPAPI、时钟、SQLCipher目录、GitHub服务、代理、导入／播放／导出／删除、控制器和正式UI仍属Windows。共享代码不得反向import Windows host。`album_import_tracker`仅保留规则实现，不宣称PhotoKit已接入；`media_item`包含历史枚举，原样保留，不能因迁移删除正式使用类型。

现有针对共享代码的Flutter测试先归`src/windows/test/shared/`并引用共享包，避免为此次目录迁移另引测试运行框架；平台测试仍归Windows。后续iOS必须有自己的原生验收，不复制Windows通过状态。

### D3：Windows build目录与可复现说明

`src/windows/build/`承载正常Windows产物、原生构建输出、依赖下载缓存、隔离验收程序的编译输出。正常路径为`build/windows/x64/runner/Release/`；保持EXE相邻DLL、metadata/ExifTool、data/app.so和许可证关系，不只交付EXE。`.dart_tool/`及平台ephemeral仍是工具生成缓存，受ignore控制，不把其作为可交付程序。

实际迁移时创建build目录；Git不跟踪空目录及产物，构建脚本需在新检出时创建。README写出目录、依赖、命令、代理可选项、构建失败的准确处理和产物位置，拟定内容见windows-readme-outline.md。不靠提交`.gitkeep`宣称目录含可运行程序。

主脚本位于`src/windows/scripts/build/build-windows.ps1`，从任意当前目录可调用：根据脚本绝对位置和Windows pubspec定位host，不硬编码D盘。显式target为`lib/main.dart`；所有步骤失败返回非零，保留现有可选本机工具链后备路径。启动脚本位于`src/windows/run-windows.cmd`，不存在正常包时准确失败，不启动隔离测试包。

### D4：工具、原型与数据隔离

构建和维护PowerShell归Windows scripts；验收Dart/PowerShell/Python入口归Windows tool/acceptance；SQLCipher独立验证包归Windows tool/probes/sqlcipher，保留独立pubspec。原型文件归Windows test/legacy_prototype/support，历史样片归test/fixtures/legacy_photos，许可资源继续归正式assets/licenses。正式main的传递依赖不得到达test或tool。

SQLCipher独立包的Windows编译`--output`与bundle／DLL核验位置改为Windows host的`build/probes/sqlcipher/`，不能继续写到工具包内部build。其iOS探针生成工程归`src/.local/probes/sqlcipher-ios-*`，仅保留工具路径定义，不执行iOS生成／构建；独立包.dart_tool仍为受忽略缓存。

工具根定位和Dart导入一起调整；从Windows host解析package_config。验收数据根用显式参数定位，保留规范化绝对路径、受控父目录、拒绝reparse point／越界等保护，不因改路径删除安全检查。新验收状态及账号默认归`src/.local/acceptance/`，本机报告归`src/.local/reports/`，原生／Flutter编译物仍归Windows build；这些本机目录全部ignore，用户图库不在此列。

既有根build包含加密测试账号、人工来源、报告和编译物。迁移前建立仅本机清单，记录路径、大小、摘要，确认没有相关进程占用；整体保全到`src/.local/pre-structure/build/`，不覆盖已有同名备份，不打开或导出秘密，不直接复用原来的绝对路径测试配置。它是历史存档，不是新编译输出；不自动重新绑定其账号、改写加密数据库或上传其媒体。新工具只使用显式选定隔离目录。若路径／锁定／空间／摘要异常，保留原位置并阻止本批迁移，不为完成目录树而删除。

旧根`.dart_tool`、`.idea`、iml、插件生成记录及本机`.agents`在无占用且确认归属后保存到受忽略的`src/.local/pre-structure/`或迁至`src/.agents/`；缓存不直接复用到新host。`.agents`只存本机工作流，今后从src工作目录发现；没有技能的AI仍可依据根AGENTS与OpenSpec接续。不运行openspec init，不改写生成技能内容。`.git/`留根，不能移入src。

### D5：Codemagic保留根入口，构建工作目录迁入iOS

根`codemagic.yaml`保留，三个工作流设置`working_directory: src/ios`；原有Flutter版本、签名规则、手动触发和不自动发布行为不变。所有脚本内相对路径以iOS host为准，构建产物声明改成仓库根相对的`src/ios/build/ios/...`；现有`/tmp/xcodebuild_logs/*.log`保持。

Windows专属测试不得继续作为iOS工作流的隐式整仓测试；若新iOS host暂无测试，删除对应空测试步骤并明确未执行测试，不能用占位用例冒充验收。保留共享依赖获取、静态分析、iOS现有三类构建操作。本轮迁移实施只静态核对配置，不触发云端构建；CI真实成功仍需后续实际记录。

官方依据（读取于2026-11-11）：https://docs.codemagic.io/yaml-basic-configuration/yaml-getting-started/ 要求配置位于根；https://docs.codemagic.io/yaml-basic-configuration/monorepo-configuration/ 说明working_directory不改变artifacts相对根的基准。控制台本身不需改应用或注册配置。

### D6：规范入口精简，历史事实不重写

根AGENTS保留八条正式产品约束、已批准安全规则的入口、当前平台范围、测试授权和工作规则；根README作为导航，指向Windows编译说明、iOS状态、共享边界及OpenSpec。`openspec/config.yaml`保留schema和精简的有效context，不累积逐轮日志。

`openspec/project/structure.md`描述目录，`current-status.md`集中记录当前版本、进行中变更与待验收边界；原根AGENTS、README、config的逐字历史快照归`openspec/project/history/pre-structure/`，以`.snapshot.md`／`.snapshot.yaml`命名，明确为历史，不产生新的自动指令范围。旧changes/specs/security-evidence留原位；其中旧路径和源码hash是当时事实，不能全局替换，新增映射与本次证据即可。

### D7：迁移验收与产品验收分开

实现阶段可按既有安排执行源码路径审查、Dart格式化、静态分析、OpenSpec严格校验及Windows正常入口编译。既有测试文件必须迁移并保持可发现，但不运行测试套件或App。iOS云端、真实库、锁定、密文往返及破坏性场景仍待用户执行。结构任务的勾选只证明各任务明示的结构／静态条件，不能增加媒体变更26／73的业务验收数量。

## Risks / Trade-offs

- [工作区有大量未提交和未跟踪文件] → 迁移前记录完整清单；不使用git reset/clean、覆盖式复制或只移动git跟踪文件。每批保留原文与映射，提交由用户另行决定。
- [part／package导入或动态资源路径遗漏] → 19文件闭包整批迁移，检查import/export/part/part-of、assets、ffi和测试fixture；共享包无Windows反向依赖。
- [原生库相对布局失效] → 保留host内部平台结构；CMake安装到完整Release，核对DLL/ExifTool/许可证清单和固定摘要，正常入口编译单列证据。
- [本机测试数据被当缓存删除] → 新旧数据路径隔离、仅本机清单和摘要保全；清理脚本继续白名单和WhatIf，不清理pre-structure或真实用户库。
- [移动源码触发新照片库] → 用户库定位、DPAPI用途和密封文件格式完全不变，源码路径不成为新的密钥／目录输入；用户运行验证另列。
- [新iOS工程被误解为已开发完成] → README与入口明确未开放，现有功能任务保持未勾选，shared仅共享源代码。
- [两host增加pubspec维护] → 共享代码单点维护，host依赖最小化，保留固定生产版本；Windows锁文件只做路径解析所需变更，iOS及shared各自生成受控锁文件。
- [历史文档变多] → 当前规则集中在短入口，历史快照只供追溯；不复制所有变更文件到project目录。

## Migration Plan

1. 从当前工作树建立源码清单与可恢复本机快照，记录已修改／未跟踪文件；先添加新ignore规则。核对迁移目标没有链接跳转、现有文件冲突或运行进程，边界不满足则停止该批。
2. 创建三个src目录与各自包配置，先迁移19文件共享闭包，再迁移Windows正式源码、原生工程、资源及测试；只改路径／包引用，不顺手调整业务。
3. 迁移iOS原生工程，提供独立但明确未开放入口，保留Bundle ID；调整Codemagic工作目录及产物声明。
4. 整理脚本、原型和fixtures，逐项更新工具根和资源路径；保全旧build及本机工作流后移除根级旧位置。不能在有冲突时盲目覆盖。
5. 编写三个目录说明、根导航和项目状态；更新AGENTS/config有效摘要，存历史快照，保留旧OpenSpec证据及产品任务。
6. 执行允许的静态检查和Windows编译，保存本次结构清单、构建日志与产物摘要；交付新EXE路径，不自动启动。

回退：按单批清单逆向恢复文件和imports；遇到用户后续修改，保留双方版本并报告冲突，不做全仓reset。历史build仅在原位置为空且无占用时逆向恢复；正式照片库和账号从未迁移，无需还原。生成目录不依靠Git恢复；本机快照及旧原生包保留至用户验收，不在此次任务自动删除。
