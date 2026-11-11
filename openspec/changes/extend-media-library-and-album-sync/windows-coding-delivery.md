# Windows 编码交接：0.7.0+9

日期：2026-11-11。接续用户“默认批准，先完成编码，随后统一测试”的明确授权。本文记录真实代码及剩余验收，不把编译当成业务测试，不替代历史证据。

## 本轮边界与状态

- 正常入口仍为 `lib/main.dart`。当前实现 Windows；iOS 全部需求继续保留，入口明确未开放。
- 已实施本轮可独立完成的 Windows 媒体播放、Live Photo 关联及多资源同步、导出、三范围删除、回收恢复代码。此前安全服务、本机加密索引、递归导入、整理、GitHub 授权及传输继续使用真实业务实现。
- 本轮不运行测试套件、不启动客户端、不调用用户仓库做同步验收；不提交、不推送、不归档。格式化、静态分析和正常入口编译另行留证。
- `tasks.md` 仍为 26/73 已验收。新增实现均为“代码已接入／待用户测试”；Gitee 是外部能力阻塞，不能说所有平台任务已经全部完成。

## 最终静态与构建结果

- Dart 格式化完成；最终 `flutter analyze --no-pub` 为 `No issues found`（7.1 秒）。
- `flutter build windows --release --no-pub --target lib/main.dart` 成功退出0（72.4 秒）。正常程序为 `D:\encrypted-photo-app\build\windows\x64\runner\Release\encrypted_photo_app.exe`，PE文件与产品版本均为 `0.7.0+9`；须保留完整 Release 目录。
- OpenSpec 当前变更严格校验通过。apply状态仍 ready，26／73，未更改未验收勾选。
- 已核对8个关键产物及88个源码／构建配置文件的SHA-256；随包libmpv与ExifTool匹配固定归档解压内容，历史样片目录不存在。证据：`security-evidence/windows-coding-2026-11-11.json`。
- 本轮没有运行App、功能测试、播放测试或真实仓库操作；上述结果均不证明业务验收通过。

## 需求—实现—待验收映射

| 任务 | 实现位置 | 本轮行为 | 用户需验证的结果 |
| --- | --- | --- | --- |
| 4.3–4.7 | `lib/sync/windows_sync_service.dart`、`github_sync_repository.dart` | 同一队列处理自动／单项／批量上传；实况两资源分别加密、上传、读回，父清单最后发布；旧删除任务不会阻断显式重传 | GitHub 私有库实际往返、断网和重启、切换目标、竞争写入及配对资源完整性 |
| 4.5–4.6、5.8–5.9 | `lib/services/loopback_media_source.dart`、`media_playback.dart`、`lib/ui/production_media_viewer.dart` | 本地持稳定原文件句柄；远端按需获取密文、逐块认证解密，播放器只取得当前查看会话的本机 URL；全屏、暂停、定位、声音控制和撤销 | 真实 iPhone H.264/HEVC/ProRes、平台保存视频和 Live Photo 音画；拖动、锁定、断网、权限撤销 |
| 5.7 | `windows_media_metadata.dart`、`windows_media_thumbnailer.dart`、`windows_import_service.dart` | 固定 ExifTool 只读实际标签；实际解码生成缩略图、取得时长和尺寸；封面只存 SQLCipher；缺信息不捏造 | 大尺寸图片、旋转、色彩、首帧、元数据缺失、损坏文件与资源预算 |
| 5.7、4.6 | `lib/storage/library_catalog.dart`、`windows_import_service.dart` | 相同 Apple ContentIdentifier 且恰为一图一视频时建立稳定关联；歧义不猜；合成单项，保留整理；缺组件准确标本地不完整 | 真实实况原始文件、独立副本、重命名、缺失后恢复、旧独立组件已备份时的升级 |
| 6.2、6.8 | `lib/ui/production_library_panel.dart`、既有 organization/query 服务 | 当前完整结果多选／全选；上传、导出、删除共用可见范围；文件名只在详情展示 | 隐藏相册、收藏、分页全选、混合媒体、范围改变与批量部分失败 |
| 7.1–7.2 | `windows-completion-decisions.md`、`windows_media_export.dart` | 用户选择目录，每项随机子目录，按原始资源写出，完整读回摘要核验；通过不覆盖的原生句柄改名发布 | 原始字节和 Live Photo 两资源一致、磁盘满、取消、同名文件与强制终止 |
| 7.3–7.6 | `windows_media_deletion.dart`、`windows_import_service.dart`、`windows/source_reader/source_reader.cpp` | 实际同卷移动原文件到 `.epa-recycle`；前置副本校验；保存每个来源的回收记录；支持原位置恢复，不覆盖；恢复与同步删除串行 | 三种删除范围、硬链接／重叠来源、占用文件、恢复一半实况、同版本再次删除 |
| 7.4–7.7 | `github_sync_repository.dart`、`windows_sync_service.dart` | 认证 tombstone 和非强制提交，删除当前引用对象；保留历史；离线只处理匹配旧版本，变化保留冲突；恢复后不重放同次删除 | 多客户端及离线冲突、Git 历史边界、旧版本客户端拒绝新删除条目、恢复后不会再次移除 |
| 7.6–7.7 | `production_library_panel.dart`、加密 jobs 记录 | 展示导出／删除记录、部分结果与回收分页；中断后依据真实原／回收文件核验恢复；已完成旧意图不冒充新操作成功 | 进程在移动前后和提交前后终止，重新打开后记录及文件真实状态一致 |
| 8.1、8.6–8.7 | 正常 main、依赖 CMake、本文与编码证据 | 正常入口无样片或测试凭据；固定依赖随包；编译和静态检查单列 | 用户统一功能和安全验收；本轮未据此勾选 |

## 远端播放的具体边界（WRP-1 B）

- 每次查看随机端口、随机路径和 32 字节 bearer；仅 IPv4 `127.0.0.1`，精确 Host／路径／认证。拒绝 Origin、请求体、非 GET/HEAD 和多 Range。
- 支持普通、单范围及 suffix Range；串行获取认证后的 4 MiB 分块。新 seek 撤销旧流；读取／写出有超时和背压；结束清理受控缓冲，不写内部明文文件。
- 每次资源访问核对当前认证清单，不能用已删媒体的旧 receipt 从 Git 历史读取。随机播放只证明已访问分块，不把它记为完整备份验证。
- 显式关闭 media_kit 默认的磁盘缓存、保存播放位置、外部媒体引用及自动字幕／音轨；限制协议和容器。回环读取显式关闭 FFmpeg HTTP 代理，外网仓库请求继续按现有代理规则。
- 普通应用锁立即关闭查看器、音画及回环服务；后台导入／同步按 WBL-1 保留。系统锁屏、睡眠、到期和退出仍撤销全部后台会话。
- 原生解码器和操作系统内存／显存并非 Dart 可完全擦除的受控缓冲；本实现不宣称抵御同用户恶意进程、管理员或内存取证。实际锁定、晚到回调、HTTP 拒绝矩阵仍待验收。

## 导出、删除与恢复

具体决策见 `windows-completion-decisions.md`。回收目录中的内容与 Windows 原目录一样是普通媒体，不属于程序内部解密缓存；它保留恢复能力但不释放容量。没有新增永久删除或重写 Git 历史功能。

恢复按记录移动回原位置；目标存在则拒绝覆盖。若之前在移动后、数据库提交前退出，下次核对原位置完整字节再修复索引。恢复取消同次尚未完成的删除意图并保留不自动重传决定；需要备份时用户显式上传。实况两个资源分别恢复，齐全后仍为原来的一项。

导出每个资源先写 `.partial`，读回完整摘要后发布。多文件发布不是跨文件系统原子事务；终止或失败可能保留已发布部分。正常取消尝试清理自己的未完成文件；强制终止可能留下用户选择目录中的 `.partial`，可通过加密操作记录查看目的地并重新导出。本轮不自动擦除用户导出目录中的遗留内容。

## 原生依赖和可复现构建

`windows/media_dependencies.cmake` 固定下载位置与 SHA-256，摘要不匹配或下载失败即终止；不修改 Pub 缓存。完整 Release 目录一起使用，不能只复制 EXE。

| 依赖 | 固定来源／版本 | SHA-256 |
| --- | --- | --- |
| 完整 libmpv | `shinchiro/mpv-winbuild-cmake` 的 `20261111` release；`mpv-dev-x86_64-20261111-git-bcde6b93cc.7z` | `273c079b11ea5575822f972756f4c9a71149a5c10130353abeb8586738938452` |
| ExifTool Windows | `exiftool-13.63_64.zip`；按官方 `checksums-13.63.txt` 固定 | `7a4bff4b1d6ee15adef882837847f76c0ed23228d294feed285939b6c9b293bd` |

完整 libmpv 用于接续既有 media_kit 后端，替代插件原有精简二进制；这不等于 ProRes 已实测通过。缩略图路径通过原生缩放滤镜控制截图大小，真实原文件不转码覆盖。ExifTool 关闭用户配置加载，只读标签，串行执行、输出有界、超时和撤销终止；仍需大文件和异常输入资源验收。

libmpv 的固定 GPL 文本已随包并接到“开源许可”；ExifTool 原包许可随 metadata 子目录保留。向他人分发前必须核对完整构建全部组件许可，并提供适用许可要求的对应源码及构建信息；目前没有完成对外分发许可审查，没有发布本轮二进制，也不将所有上游组件误标为 MIT。维护者构建源码为上述固定 release 对应的构建仓库，mpv commit `bcde6b93cc`；可复现下载配置保存在 CMake。

## 剩余阻塞和测试安排

- **Gitee：代码未实现。** 本轮重新读取官方 `https://gitee.com/api/v5/oauth_doc` 及其官方文档 bundle，仍未获得符合“无自建服务／客户端无 Secret”的 PKCE 或 Device Flow 公开客户端能力证据。缓存仅供复核于 `build/provider-docs/gitee-oauth-2026-11-11.*`。这不证明平台永远不支持，但不足以安全实现已确认授权；不改成 PAT、内置 Secret 或模拟授权。
- **iOS：按用户指示暂缓。** PhotoKit、系统相册规则、原生安全后端及真机播放等任务保持未完成。
- **Windows：本轮代码需用户统一测试。** 建议先用独立目录与媒体副本，依次验证导入整理、真实文件播放、测试私有库往返、远端查看导出、三种删除及恢复，再做锁定／断网／空间不足／竞争写入。上述顺序是验收建议，本轮未执行。
- 没有真实平台证据的任务不勾选，不归档本次变更。旧的“待逐项批准”表述在本轮 Windows 已有默认授权范围内由本记录接续，不影响 iOS 保留范围和外部能力缺口。
