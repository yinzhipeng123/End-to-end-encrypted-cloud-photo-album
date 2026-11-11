# encrypted-photo-app 开发规范

先读本文件及 [当前状态](openspec/project/current-status.md)，再读本次 OpenSpec 变更的 proposal、design、tasks。项目目录与入口见 [结构说明](openspec/project/structure.md)。历史快照仅供追溯，不代替这里的有效规范。

## 当前执行约定

- 用户已批准 `reorganize-project-structure`，实施 `src/windows/`、`src/ios/`、`src/shared/` 布局。根目录不再作为 Flutter 工程；Windows 正常入口为 `src/windows/lib/main.dart`。
- 用户后续要求根目录保留 `clean-build.cmd` 作为 Windows 构建产物清理入口；复用维护脚本白名单，保留用户库及 `src/.local/` 历史资料。编写或检查脚本不等于授权当场执行实际清理。
- 当前开发 Windows；iOS 全部需求保留但暂缓，Gitee 授权和同步未实现。共享源码存在不能当成 iOS 已完成或已验收。
- 用户已明确默认批准已确认 Windows 产品范围内的后续技术实现选择，不再逐项重复询问；不得因此改变已确认产品规则、密码学承诺，或扩大为对用户数据执行删除、远端历史重写等操作。
- 用户统一执行测试。当前允许源码检查、格式化、静态分析、OpenSpec 校验和编译；不运行测试套件、App、真实平台授权／仓库／锁屏／睡眠／破坏性验收。记录实际做过的检查，不能把编译算成功能验收。
- 不自动提交、推送或归档。保留工作区未提交及未跟踪文件；不得用 reset、clean 或覆盖复制丢弃现有工作。
- 结构迁移任务与媒体功能任务分开。`extend-media-library-and-album-sync` 仍为 26／73 已验收；结构重整不增加其勾选。

## 八条正式产品约束

1. 所有功能都必须有真实业务逻辑，界面或接口存在不等于功能完成。
2. 禁止使用模拟数据代替真实业务数据；首次空库显示真实空状态，测试样本不得自动进入用户媒体库。
3. 禁止假按钮、假操作和模拟成功提示；成功必须来自真实执行及结果核对，入队不等于完成。
4. 文件读取、写出、恢复和删除必须真实执行并反馈实际结果，不能只修改内存副本标志。
5. 加密和解密必须调用经确认方案中的真实密码学实现，不用密码字符串比较、状态位或改扩展名代替。
6. 业务数据按设计持久化；本机路径、文件名、相册、整理和跟踪元数据加密保存，凭据不得明文落盘。临时界面选择状态无需持久化。
7. 未实现能力必须准确标记并禁用执行入口，不能用演示代替；部分可用包不得宣称完整产品已交付。
8. 每项功能须有可验证验收标准和实现／平台／版本／结果证据；构建、界面测试、模拟测试及规格语法通过不代表真实业务验收。

## 已确认产品规则

- Flutter＋Dart；Windows 与 iOS 共用安全／格式代码，不能复制两套规则。Windows 原照片仍是普通图片；递归目录导入、运行期监听、重启补扫保留。
- iPhone 默认将权限允许的本机照片和视频纳入管理，不等于远端原文件自动全量下载。照片、视频、Live Photo、H.264／HEVC／ProRes 和平台保存视频的原需求保留，完整格式兼容性待真实验收。
- 平台授权与照片解密分开。GitHub／Gitee 使用私有仓库，上传前客户端加密；应用不自行限制总容量。Gitee 保留无自建服务／客户端无 Secret 的要求，不以 PAT、内置 Secret 或模拟授权替代。
- 本机元数据使用已批准 Windows SQLCipher 方案；数据位置为用户首次选定父目录下的 `EncryptedPhotoApp`，默认 `%LOCALAPPDATA%\EncryptedPhotoApp`。DPAPI 保护定位；目标缺失或损坏时拒绝打开，不新建替代库、不自动迁移已有库。设置页显示实际目录。
- 照片密码 12–128 个 Unicode 标量；遗忘不提供绕过恢复。正确照片密码可重设四位 PIN，改照片密码须旧密码并重新包装主密钥，不承诺撤销旧材料。
- 两端独立四位数字 PIN。Windows 最小化／手动锁只撤销界面、音画和预览，已解锁进程继续后台导入／同步；系统锁屏／睡眠／退出、72 小时到期和时间异常撤销后台。辅助解锁和 PIN 不延长三天期限；到期必须正确照片密码。手动暂停不因解锁解除。
- 多选、完整当前结果全选、批量上传／导出／删除保留；属于任一隐藏相册时，从所有照片与收藏隐藏；文件名只在详情显示。
- 三种删除范围保留，作用于原文件和用户选定副本。Windows 本地可恢复同卷移动至 `.epa-recycle`，不冒称系统回收站或永久擦除；仓库删除不重写 Git 历史。仅删仓库后抑制自动重传，允许显式单项／批量重传。
- iPhone 系统相册改名作为新相册导入，旧相册保留；系统删除不删 App 相册；App 删除停止该关联，手动导入可恢复；停止后系统改名仍作新相册。成员仅合并系统侧变化，保留 App 内调整，不反向写系统相册。
- 相册名称／成员／隐藏设置的跨设备仓库同步不因阶段名称自动纳入。不新增 iCloud 接入或其界面说明、分享、编辑、下载器、自动多仓库备份或手工密钥／恢复码要求。

## 已批准技术依据

以下均在 `openspec/changes/extend-media-library-and-album-sync/`。文中的历史“待确认”以明确批准记录和后续接续为准，不重复审批；批准仍不等于验收。

| 依据 | 有效范围 |
| --- | --- |
| [SFR-1](openspec/changes/extend-media-library-and-album-sync/security-foundation-review.md) | XChaCha20-Poly1305；Argon2id 64 MiB／3次／1 lane；随机主密钥及用途隔离；DPAPI／本设备Keychain；密码、PIN与复验规则 |
| [TD07 Windows](openspec/changes/extend-media-library-and-album-sync/windows-delivery.md) | SQLCipher、sqlite3 3.9.1、独立目录密钥、加密事务及内存临时表；错误／损坏不覆盖旧库；iOS另验 |
| [GAR-2](openspec/changes/extend-media-library-and-album-sync/repository-authorization-review.md)、[RAR-1](openspec/changes/extend-media-library-and-album-sync/repository-storage-review.md) | 私有GitHub App、指定仓库、Device Flow与DPAPI令牌；HTTPS API、专用分支、非强制发布 |
| [WIR-1](openspec/changes/extend-media-library-and-album-sync/windows-import-review.md) | 本机来源身份、独立副本、稳定读取、监听与重试预算 |
| [WSR-1](openspec/changes/extend-media-library-and-album-sync/windows-sync-review.md) | 4 MiB分块、加密清单与恢复材料、读回验证、断点、冲突及空库初始化；密文暂存预算 |
| [WBL-1](openspec/changes/extend-media-library-and-album-sync/windows-background-lock.md) | Windows普通界面锁保留后台，替换旧普通锁即暂停条款 |
| [WRP-1](openspec/changes/extend-media-library-and-album-sync/windows-remote-playback-review.md) | 随机认证127.0.0.1读取、逐块认证解密、不落内部明文、查看撤销 |
| [Windows后续决策](openspec/changes/extend-media-library-and-album-sync/windows-completion-decisions.md) | 真实导出、三范围删除、回收恢复与异常接续 |

## 源码、数据与证据

- Windows 编译说明见 `src/windows/README.md`，产物位于其 `build/`；交付保留完整 Release 依赖。不要升级依赖或改存储协议来顺带解决路径问题。
- `src/shared/`不得反向引用 Windows host；credentials 的两个 part 与主文件保持同包同库。正式入口不得依赖 test、tool 或旧原型。
- `src/.local/`、`src/.agents/`仅本机使用。旧 build 的账号、人工来源及报告保全在 `src/.local/pre-structure/`；不整目录清理、自动加载旧账号或把它当用户图库。
- 用户原图、密码、令牌、密钥、签名材料、编译物及缓存不得提交。测试向量／旧样片仅在明确测试范围保留，正式包不携带样片。
- 历史 `changes/`、规格和 evidence 的旧路径、哈希、结果保持原文，用新映射和新记录接续。没有执行的验收明确为待验证，不伪造通过。
- `.agents`是本机技能，不作为新授权。缺少技能时仍可按根规范、OpenSpec及当前状态接续；不要重新初始化或生成整个项目。
