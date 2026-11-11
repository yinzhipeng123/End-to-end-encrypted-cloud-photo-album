# iOS 客户端工程

本目录是独立 iOS Flutter 工程根，Dart包名为 `encrypted_photo_app_ios`；原生Xcode工程位于 `ios/`，Bundle ID仍为 `dev.miyu.encryptedPhotoApp`。通过 `path: ../shared` 引用同一份共用规则，不复制Windows业务代码。

**当前iOS产品功能暂缓，入口明确尚未开放。** 目录和共享依赖接好不代表PhotoKit、系统相册导入、Keychain、SQLCipher或真机播放已完成。既有iOS需求和待验收任务保留在[媒体功能变更](../../openspec/changes/extend-media-library-and-album-sync/tasks.md)。

## 云端构建

仓库根的 [codemagic.yaml](../../codemagic.yaml) 保留三个手动工作流，工作目录指向 `src/ios`：

| 工作流 | 用途 |
| --- | --- |
| `ios-simulator` | 构建模拟器 `.app`，用于App Preview |
| `ios-unsigned` | 无签名真机目标编译检查，产物不能直接安装 |
| `ios-adhoc` | 使用Codemagic安全配置中的苹果签名资料生成Ad Hoc IPA |

配置继续使用Flutter 3.47.9。产物位于本工程的 `build/ios/`，Codemagic的artifact声明以仓库根为基准写成 `src/ios/build/ios/...`。签名资料不进入Git，不在聊天或README记录私钥、令牌、密码。

目录迁移只核对配置和路径，本轮不触发云端构建、不提供iOS功能测试通过结论。当前如无iOS测试，工作流应准确记录未执行，不复制Windows专属测试来冒充iOS验收。

## 后续开发

完整检出仓库，在此目录获取依赖和执行Flutter命令；原生构建需要相应macOS/Xcode环境或Codemagic。不要在仓库根直接执行Flutter构建。后续接入须继续遵守[根AGENTS](../../AGENTS.md)的安全、应用锁、系统相册及媒体支持规则，并单独留下iOS平台证据。
