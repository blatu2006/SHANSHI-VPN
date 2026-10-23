# NLVC VPN

Apple Silicon 原生的 Hillstone Secure Connect 兼容客户端，面向当前已观察的
Hillstone 5.7.0 用户名/密码、3DES/SHA-1 网关配置。

## 已实现

- SwiftUI 主程序、菜单栏状态和沙箱内 AES-GCM 加密凭据保存；
- `NETunnelProviderManager` 安装、启动、停止和状态同步；
- Packet Tunnel Provider 与 `utun` 数据收发；
- TLS 1.2 控制通道和可选服务器证书验证；
- Hillstone 8 字节头、四字节对齐 TLV 及流式拆包；
- `AUTH`、`CLNT_INFO`、`SET_IP`、`SET_ROUTE`、`NEW_KEY`、`KEY_DONE`、
  `KEEP_ALIVE`、`CLNT_LOGOUT`；
- 明确识别 `HOST_CHECK` / `HOST_CHECK_UPD`，遇到网关合规检查时安全失败并提示管理员，
  不伪造终端检查结果；
- 从服务器下发值动态设置 IPv4、DNS、MTU 和路由；
- 48 字节 KEYMAT 派生、双向 SPI、3DES-CBC、HMAC-SHA1-96；
- UDP 优先、TCP 兼容回退的 ESP 数据通道自动选择与真实流量统计；
- TCP 数据通道关闭 Nagle 延迟，支持批量拆帧、批量解密与批量写回；
- UDP Pacing 平滑突发，并在持续传输时自适应提高发送速率；
- 数据包批量加密/发送与批量写回，降低高速传输时的调度开销；
- 实时上下行速率、心跳延迟、丢包、路由和 DNS 诊断；
- 断线指数退避重连、控制通道超时和重协商处理；
- 服务器策略/全流量两种路由模式与安全 MTU；
- 多连接配置、证书指纹固定，以及脱敏诊断报告复制/导出。
- Wi-Fi/有线自动连接、登录启动、网络切换与睡眠唤醒恢复；
- 自适应 MTU、动态收包批次、加密耗时和心跳抖动/丢包诊断；
- 可选“中国大陆公网 IPv4 直连”，国内公网流量绕过 VPN；
- 版本检查、签名/公证发布脚本，以及安装前备份和一键回滚。
- 轮转连接事件日志和连接、失败、重连系统通知。

默认配置只预置网关地址 `223.71.10.170` 和端口 `4433`。用户名与密码首次
启动均为空；保存后用户名和密码进入应用沙箱内的本地加密文件，不使用钥匙串。当前网关
的旧客户端配置显示 SPA 模式关闭，因此使用直连 TLS，不发送 SPA 数据包。

## 构建与运行

真实 VPN 需要 Network Extension 权限和 Apple 开发签名。可直接运行
`./scripts/build_app.sh`；产物写入 `dist/NLVC VPN.app`。也可以打开
`HillstoneConnect.xcodeproj`，选择 `HillstoneConnect` Scheme 后运行。第一次连接时
macOS 会要求允许添加 VPN 配置。

在构建前可运行 `./scripts/check_apple_signing.command`。它会同时检查本地开发与
Developer ID profiles 是否授权 System Extension Packet Tunnel，以及证书和私钥是否
可用。macOS Team-ID 格式 App Group 不需要在开发者网站注册，构建脚本会在最终签名
产物中检查两个程序是否都包含 `T84BKD53ZD.com.linlu.hillstoneconnect`。
把新 profiles 安装到 Xcode 后，依次运行：

```bash
./scripts/setup_apple_signing.command
./scripts/check_apple_signing.command
./scripts/build_developer_id_pkg.command
./scripts/notarize_pkg.command
```

重复运行 setup 会复用已有公证凭据，只刷新并校验 profiles。
完整的本机证书、profile 和权限清单会同步到
`~/.apple-signing/nlvc-vpn/README.md`，该目录不得提交或外传。

本地安装使用 `scripts/install_local.sh`，它只覆盖 `/Applications/NLVC VPN.app`，
并先将旧的自研版本备份到 `archive/app-bundles`；不会触碰原版
`Hillstone Secure Connect.app`。需要回退时运行 `scripts/rollback_local.sh`。

命令行可执行无签名编译与全部回归测试：

```bash
swift test
./scripts/build_app.sh --unsigned
```

## 国内直连地址库

应用内置中国大陆公网 IPv4 CIDR 快照，连接时作为 Network Extension 的排除路由。
默认关闭；开启后命中国地址库的公网 IPv4 走 Mac 当前物理网络，私有地址、隧道 DNS
及其他流量仍按 VPN 路由。正式发布前下载 APNIC 的
`delegated-apnic-latest`，然后执行：

```bash
./scripts/update_china_routes.py /path/to/delegated-apnic-latest
```

脚本会验证并聚合 APNIC 的 `CN|ipv4` 记录。App 连接时不联网查询归属，也不会上传
访问目标。IPv6 单独由“阻止 IPv6 绕过隧道”设置控制。

命令行进程若无法访问 Xcode 管理的开发证书，签名构建会提示找不到
`Mac Development` 私钥；此时在已登录开发账号的 Xcode 中运行即可。

当前 macOS 客户端使用嵌入于 `Contents/Library/SystemExtensions` 的 Packet Tunnel
System Extension。首次连接时应用通过 `OSSystemExtensionRequest` 请求系统激活；内部
分发版本使用 Developer ID 专用的 `packet-tunnel-provider-systemextension` entitlement。
构建脚本会拒绝旧的 `PlugIns/*.appex` 布局，防止生成“已公证但数据通道不能运行”的包。

本软件只在公司内部部署，不发布到 App Store，也不提供官网下载。正式内部发布仍使用
Developer ID Application、Developer ID Installer 和 Apple 公证。安装完成后首次连接时，
用户只需在“系统设置 > 通用 > 登录项与扩展 > 网络扩展”中允许一次
“NLVC VPN 数据通道”；同一 Team ID 和扩展 ID 的后续升级无需重复批准。

不需要内部在线更新地址时，发布命令为：

```bash
./scripts/build_developer_id_pkg.command
./scripts/notarize_pkg.command
```

如仍需生成带内部更新地址的完整发布物：

```bash
NOTARY_KEYCHAIN_PROFILE="你的 notarytool profile" \
DOWNLOAD_URL="https://example.com/NLVC-VPN-1.3.0.pkg" \
UPDATE_MANIFEST_URL="https://example.com/update.json" \
./scripts/release_notarized.sh
```

脚本会归档并导出 Developer ID 应用、签名 PKG、提交公证、装订公证票据，并生成
带 SHA-256 的 `update.json`。应用下载更新后会再次校验 SHA-256，校验失败不会打开安装器。

## 兼容范围

实现的算法组合是当前网关实际报告的 3DES-CBC + HMAC-SHA1-96，属于旧式兼容
模式。AES、证书登录、短信验证码以及启用了 SPA 的其他网关配置不在当前连接
配置范围内。协议字段参考了公开的 Hillstone 兼容实现
[hilldust](https://github.com/LionNatsu/hilldust) 并与本机 5.7.0 客户端行为交叉核对。
