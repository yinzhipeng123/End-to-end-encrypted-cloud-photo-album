# 目标目录与迁移映射

本文件记录2026-11-11用户确认的迁移映射；目录已按此调整，实际静态检查和构建结果见implementation.md。历史路径保持可追溯，不修改旧验收证据中的原路径。

```text
encrypted-photo-app/
├─ AGENTS.md
├─ README.md
├─ .gitignore
├─ codemagic.yaml
├─ .git/                          # 保留的Git管理元数据
├─ openspec/
│  ├─ config.yaml
│  ├─ specs/
│  ├─ changes/
│  └─ project/                    # 结构、当前状态、历史规范快照
└─ src/
   ├─ .agents/                    # 本机工作流，忽略提交
   ├─ .local/                     # 历史保全、验收账号／来源／报告，忽略提交
   ├─ windows/
   │  ├─ README.md
   │  ├─ pubspec.yaml / pubspec.lock
   │  ├─ analysis_options.yaml / .metadata
   │  ├─ lib/
   │  │  ├─ main.dart
   │  │  ├─ app/                  # Windows启动与controller
   │  │  ├─ security/             # Windows DPAPI／安全存储／时钟
   │  │  ├─ storage/              # Windows已接入SQLCipher目录
   │  │  ├─ repositories/         # GitHub与代理
   │  │  ├─ services/
   │  │  │  ├─ library/
   │  │  │  ├─ import/
   │  │  │  ├─ playback/
   │  │  │  └─ media_operations/
   │  │  ├─ sync/                 # 真实传输与调度
   │  │  └─ ui/                   # 正式界面；首轮不拆类
   │  ├─ windows/                 # 原生runner、CMake、source_reader
   │  ├─ assets/licenses/
   │  ├─ test/                    # 正式测试、shared测试、legacy_prototype、fixtures
   │  ├─ scripts/{build,maintenance,support}/
   │  ├─ tool/{acceptance,fixtures,probes}/
   │  ├─ run-windows.cmd
   │  └─ build/                   # 编译生成，忽略提交
   │     ├─ windows/x64/runner/Release/
   │     ├─ source-reader/
   │     ├─ dependencies/
   │     └─ probes/sqlcipher/
   ├─ ios/
   │  ├─ README.md
   │  ├─ pubspec.yaml / pubspec.lock
   │  ├─ analysis_options.yaml / .metadata
   │  ├─ lib/main.dart            # 尚未开放入口，不是新iOS实现
   │  ├─ ios/                    # 原Xcode工程及平台资源
   │  └─ build/                  # 未来云端生成，忽略提交
   └─ shared/
      ├─ README.md
      ├─ pubspec.yaml / pubspec.lock
      ├─ analysis_options.yaml
      └─ lib/{model,security,services,sync}/
```

Flutter额外生成的.dart_tool、ephemeral不作为业务目录或交付物提交；根目录不再是Flutter工程。空build由脚本创建，Git不跟踪空目录。

## 根级文件／工程

| 当前 | 目标／处理 |
| --- | --- |
| `AGENTS.md`、`README.md`、`.gitignore`、`codemagic.yaml` | 留根，更新有效规则／导航／ignore／CI路径 |
| `openspec/` | 原位保留；增加project导航，不搬动历史changes/specs/evidence |
| `pubspec.yaml`、`pubspec.lock`、`analysis_options.yaml`、`.metadata` | Windows host继承；iOS/shared建立各自匹配配置，旧配置快照保全 |
| `lib/` | 下表明确分流至Windows、shared或legacy；不整份复制两端 |
| `windows/` | `src/windows/windows/`，保留内部相对布局和原生名称 |
| `ios/` | `src/ios/ios/`，保留原Bundle ID／Xcode配置 |
| `assets/licenses/` | `src/windows/assets/licenses/`，pubspec仍只包含真实生产许可资源 |
| `assets/photos/`及SOURCES.md | `src/windows/test/fixtures/legacy_photos/`，不进入正式assets |
| `run-windows.cmd` | `src/windows/run-windows.cmd` |
| 旧`build/` | `src/.local/pre-structure/build/`逐项保全；历史数据不覆盖、不复用、不删；新编译全到Windows build |
| 根`.agents/` | `src/.agents/`，本机工作流，不提交 |
| 根IDE／生成缓存 | `src/.local/pre-structure/`保全必要文件；新host重新生成，不继承旧绝对路径 |

## shared：19个文件（保持文件名）

| 当前目录 | 文件 | 目标 |
| --- | --- | --- |
| `lib/security/` | photo_password.dart、pin_gate.dart、protected_record_store.dart、reverification_gate.dart、security_failure.dart、vault_bootstrap_record.dart、vault_bootstrap_store.dart、vault_credentials.dart、vault_crypto.dart、vault_media_crypto.dart、vault_recovery_record.dart、vault_remote_recovery.dart | `src/shared/lib/security/` |
| `lib/model/` | album.dart、album_source_binding.dart、library_query.dart、media_item.dart、selection_state.dart | `src/shared/lib/model/` |
| `lib/services/` | album_import_tracker.dart | `src/shared/lib/services/` |
| `lib/sync/` | sync_format.dart | `src/shared/lib/sync/` |

## Windows正式代码

| 当前 | 目标（均在src/windows/） |
| --- | --- |
| `lib/main.dart`、`lib/app/` | 同名相对路径 |
| `lib/security/windows_*.dart` | `lib/security/` |
| `lib/storage/`、`lib/repositories/`、除sync_format外的`lib/sync/` | 同名相对路径 |
| `library_organization_service.dart` | `lib/services/library/` |
| `windows_import_service.dart`、`windows_source_reader.dart`、`windows_media_metadata.dart` | `lib/services/import/` |
| `media_playback.dart`、`playback_session.dart`、`loopback_media_source.dart`、`windows_media_thumbnailer.dart` | `lib/services/playback/` |
| `windows_media_export.dart`、`windows_media_deletion.dart` | `lib/services/media_operations/` |
| `lib/ui/production_*.dart`、`github_connection_panel.dart`、`theme.dart` | `lib/ui/`原文件名；本轮不拆类和改UI |

## 原型、测试和工具

| 当前 | 目标（均在src/windows/） |
| --- | --- |
| `lib/model/{demo_store,library_store,local_preview_library}.dart` | `test/legacy_prototype/support/model/` |
| `lib/services/{media_sync_service,windows_folder_importer}.dart` | `test/legacy_prototype/support/services/` |
| 旧`lib/ui/`的access_screen、batch_dialogs、components、dialogs、home_shell、library_screen、media_thumbnail、media_viewer、selection_toolbar、settings_screen、sync_screen | `test/legacy_prototype/support/ui/` |
| `test/support/legacy_prototype_app.dart` | `test/legacy_prototype/support/` |
| 旧app_test、demo_store_test、library_interaction_test、library_rules_test、windows_folder_importer_test | `test/legacy_prototype/` |
| 相册tracker、纯安全规则、同步格式等测试 | `test/shared/`，import共享包；Windows原生安全测试仍归`test/security/` |
| 其余正式test、support、security fixtures | `test/`按app/storage/services/repositories/sync/security分类；不得漏掉跨tool observer引用 |
| build-windows.ps1、build-source-reader.ps1、build-security-probe-windows.ps1 | `scripts/build/` |
| clean-build-artifacts.ps1 | `scripts/maintenance/`，保留白名单、WhatIf、占用检查 |
| 原平台探针／真实验收Dart与PowerShell | `tool/acceptance/{security,storage,github,media,lifecycle}/`按原职责；更新根定位和Dart包导入 |
| scripts/support/ | `tool/acceptance/support/` |
| scripts/sqlcipher_probe/ | `tool/probes/sqlcipher/`，独立包整体迁移；Windows编译--output与bundle／DLL核验改到host的`build/probes/sqlcipher/`；iOS生成工程归`src/.local/probes/` |
| create-sync-platform-fixtures.py、security-reference-vectors.py | `tool/fixtures/` |

## 路径更新清单

- PS脚本所有`Split-Path -Parent $PSScriptRoot`假设改为host根定位；不得指向src或仓库根运行Flutter。
- 三个硬编码D盘的后台锁／授权／同步验收入口改用受控数据根；process-probe中的隔离目录判断同步变更且保持拒绝越界。
- Dart import/export/part和测试fixture引用、`test/repositories/github_auth_observer_test.dart`到工具support的引用一起修改。
- `analysis_options.yaml`只排除新的独立SQLCipher probe及真正生成目录，不能屏蔽正式源码错误。
- CMake固定缓存、assets/license及EXE相邻加载路径在Windows host内保持；全部构建输出在其build下。
- Codemagic三工作流的working_directory与artifact基准分别调整；不静默禁用现有三种构建。
- 当前README、根AGENTS、config更新为新路径；旧证据／历史快照里的路径保留原文，由此映射解释。
