# Windows Proxy Implementation

## Scope — 2026-11-11

用户要求自动检测本机代理并用于网络连接，提供 HTTP／HTTPS=http://127.0.0.1:10808 和 ALL_PROXY=socks5://127.0.0.1:10808。实际只读检查显示 Windows 当前用户手动代理已启用、地址127.0.0.1:10808、无PAC，且该本机端口正在监听。用户此前截图已经选中test-album，初始化显示笼统网络错误；不从该错误断言权限或整个同步协议已验收。

当前代码存在仅从进程环境读取代理、将SOCKS5前缀去除后当HTTP使用的问题。新增 `lib/repositories/network_proxy.dart`，无新增依赖，使用Windows WinHttpGetIEProxyConfigForCurrentUser读取当前用户设置。每次请求先选择环境变量中的HTTPS、HTTP、ALL_PROXY（兼容大小写），否则读取系统手动代理；支持NO_PROXY域名边界／端口与系统代理例外。系统设置改变后下一请求重新检测，不读取其它进程环境、不扫描端口、不修改系统配置。未配置支持代理且无自动代理脚本时才直连。

当前支持HTTP代理的CONNECT隧道，包括用户同时提供HTTP与SOCKS变量时优先选择HTTP的情况；仅SOCKS、PAC／WPAD、HTTPS代理服务器及带凭据的代理地址尚未支持，明确报错，绝不将协议改名冒充支持。显式代理故障不直连回退；当前请求冻结路由，不在同次请求中切换服务器。保留GitHub目标白名单和TLS证书验证，代理地址显示仅为解析后的主机端口，不显示URL凭据。

`GitHubHttpTransport`将解析器统一应用于授权、令牌刷新、安装／仓库查询、初始化与密文传输；新增代理配置、代理协议、代理连接及TLS错误分类。云端同步界面显示检测到的代理来源／地址，不将查询错误归为已完成。测试HTTP替身仍只在test/，正常入口使用真实传输。

## Validation

实际执行 `scripts/probe-github-network.dart`，使用生产传输，无用户密码、令牌或媒体；不写仓库，不交换用户授权。测试设备码端点只生成未使用的短期设备码，码和响应正文不记录：

| 路径 | 目标 | 结果 |
| --- | --- | --- |
| 清空注入的进程代理变量，真实WinHTTP读取系统配置 | api.github.com/rate_limit | 200，有效JSON |
| 同上 | github.com/login/device/code | 200，有效设备流程响应 |
| 用户提供的HTTP／HTTPS／SOCKS环境变量 | api.github.com/rate_limit | 200，有效JSON，选中HTTP |
| 同上 | github.com/login/device/code | 200，有效设备流程响应，选中HTTP |

日志：`build/proxy-platform-2026-11-11.json`。两条路径都使用127.0.0.1:10808。该证据只证明生产传输经代理到GitHub的TLS／HTTP连接，不证明私有仓库初始化、上传或独立恢复通过。

首轮Flutter测试在加载阶段失败：锁定版本的stack_trace、clock、vector_math缓存缺失。原始日志保留于 `build/proxy-regression-2026-11-11.log`；通过用户代理执行 `flutter pub get --enforce-lockfile` 恢复锁定依赖，不擅自升级。第二次加载失败是测试工具的本机WebSocket连接受到进程代理影响，保留于 `build/proxy-regression-recheck-2026-11-11.log`；为测试命令设置NO_PROXY=localhost,127.0.0.1,::1后成功。没有修改用户系统设置或用测试失败证明产品行为。

最终 `build/proxy-regression-final-2026-11-11.log`：39项通过，约42秒。8项代理测试包含真实Windows只读API、真实本机TCP CONNECT接收／407拒绝及锁定取消；其余14项GitHub协议、16项连接／本机加密持久化、1项生产表单测试通过。HTTP替身和真实平台探针分列；CONNECT中未出现测试Bearer标记，取消停滞代理连接在3秒验证窗口内完成。`build/proxy-analyze-2026-11-11.log`：静态检查无问题。构建结果在最终交付时补记。

## Remaining Boundary

0.6.1+7两个Windows Release入口均构建通过，隔离包更新至build/sync-platform/runner后，再以lib/main.dart恢复标准Release。正常客户端已启动，通过原生窗口状态与截图观察到真实PIN锁屏；未操作用户认证，未声称解锁后的初始化成功。AOT哈希及人工密码标记验证两入口分离；构建日志为build/proxy-probe-build-2026-11-11.log、build/proxy-production-build-2026-11-11.log。来源／产物哈希、平台网络结果及限制汇总于security-evidence/windows-proxy-2026-11-11.json。任务3.7完成，进度25／71，其余平台／同步任务不因此完成。

GitHub私有仓库初始化／上传／恢复及异常矩阵仍按原任务继续，不因本机代理连接通过而勾选。iOS和Gitee维持既有未完成边界。不得从旧截图网络错误推断当前仓库没有部分写入，后续必须由产品核对远端状态后接续，不能强制覆盖。
