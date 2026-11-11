# encrypted_photo_shared

这是Windows与iOS客户端通过 `path: ../shared` 共用的私有Dart包，`publish_to: none`。安全规则和持久化格式只在这里维护一份，平台工程不得各复制一份修改。

## 当前共享范围

| 目录 | 内容 |
| --- | --- |
| `lib/security/` | 12个安全相关文件：密码规则、PIN、复验、通用保护存储接口／记录、凭据、密码学、媒体与恢复格式 |
| `lib/model/` | album、album_source_binding、library_query、media_item、selection_state五个模型 |
| `lib/services/` | album_import_tracker，保留系统相册跟踪规则 |
| `lib/sync/` | sync_format，共用仓库存储格式 |

最小闭包共19个Dart文件，运行依赖固定为 `sodium: 4.1.2+1`，不依赖Flutter、SQLCipher或Windows FFI。`vault_media_crypto.dart`和`vault_remote_recovery.dart`是`vault_credentials.dart`的part，三者必须保持同一个Dart库，不能跨包拆开。

Windows DPAPI、时钟、SQLCipher目录、媒体导入／播放／导出／删除、GitHub服务、代理、控制器和UI留在 `../windows/`。**本包不能反向引用Windows host。** iOS目前仅引用共享包且入口未开放，共享源码存在不表示原生安全后端已加载、PhotoKit已接入或平台已经验收。

`media_item.dart`含正式类型及原型历史枚举；原样保留类型不是把旧模拟同步变成正式实现。历史DemoStore、原型UI及样片仅在Windows测试支持目录，不能从共享包或正式入口引入。

## 维护与验证

当前针对这些共用规则的既有Flutter测试位于 `../windows/test/shared/`；此次迁移保留测试，不为目录整理另引测试运行框架。平台专属测试仍归Windows目录，iOS未来必须另做原生验证。

修改共享代码前阅读[根规范](../../AGENTS.md)和[安全决策索引](../../AGENTS.md#已批准技术依据)。当前用户统一安排测试；可以进行静态分析，不能擅自把构建或Windows证据记为双端验证通过。版本、状态和接续任务见[当前状态](../../openspec/project/current-status.md)。
