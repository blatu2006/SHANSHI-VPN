# NLVC VPN 本机签名清单

这份目录只保存 NLVC VPN 的本机签名配置、provisioning profiles 和必要的恢复备份。
不要提交到 Git，不要通过聊天、邮件或网盘发送这里的文件。

## 固定标识

- Apple Team ID：`T84BKD53ZD`
- App Bundle ID：`com.linlu.hillstoneconnect`
- System Extension Bundle ID：`com.linlu.hillstoneconnect.PacketTunnel`
- App Group：`T84BKD53ZD.com.linlu.hillstoneconnect`
- Notary Keychain Profile：`NLVC-VPN-Notary`
- System Extension 安装位置：
  `Contents/Library/SystemExtensions/com.linlu.hillstoneconnect.PacketTunnel.systemextension`
- 不允许出现旧的 `Contents/PlugIns/*.appex`。

App 和 System Extension 的最终签名 entitlement 必须同时使用上面的精确 App Group。
这是 macOS 的 Team-ID 格式，不需要在 Apple Developer 网站注册，也不要求出现在
provisioning profile 中。System Extension 的 `NEMachServiceName` 必须以
`T84BKD53ZD.com.linlu.hillstoneconnect.` 开头。

## 钥匙串中必须存在的身份

以下身份都必须包含私钥，只有证书文件没有私钥不能签名：

1. `Apple Development`：本地 Xcode 开发构建使用。
2. `Developer ID Application: lu lin (T84BKD53ZD)`：App 和 System Extension 使用。
3. `Developer ID Installer: lu lin (T84BKD53ZD)`：最终 PKG 使用。
4. `NLVC-VPN-Notary`：由 `notarytool` 保存在 macOS 钥匙串中的公证凭据。

检查命令：

```bash
security find-identity -v -p codesigning
security find-identity -v -p basic
```

多个证书可以具有相同显示名称。实际 App 签名必须使用 App 和扩展 profiles 共同授权、
且本机钥匙串中带私钥的 SHA-1 身份。构建脚本会自动选择，不应手工按显示名称猜测。

## Apple Developer 后台能力

两个 Identifier 都必须启用：

- Network Extensions / Packet Tunnel Provider（System Extension 版本）。

容器 App Identifier 还必须允许安装 System Extension。

不要在网站的 App Groups 列表里选择无关的 `group.*` 条目。项目使用的
`T84BKD53ZD.com.linlu.hillstoneconnect` 是 macOS Team-ID 格式，由代码签名验证团队
前缀，直接写在 App 和 System Extension 的 entitlements 中。

每次修改后台能力后，都要重新生成以下四个 profiles：

| 用途 | App | PacketTunnel |
|---|---|---|
| 本地开发 | Mac Development profile | Mac Development profile |
| 内部分发 | Developer ID / Mac Direct profile | Developer ID / Mac Direct profile |

每个 profile 必须包含：

- 正确的 `com.apple.application-identifier`；
- Team ID `T84BKD53ZD`；
- `packet-tunnel-provider-systemextension`；
- 容器 App profile 还需要 `com.apple.developer.system-extension.install = true`。

最终签名的 App 和 System Extension（不是 profile）必须同时包含精确 App Group
`T84BKD53ZD.com.linlu.hillstoneconnect`。

## 本目录应有的文件

| 文件 | 用途 | 权限 |
|---|---|---|
| `config.plist` | Team、签名身份名称和 Notary profile 名称 | `0600` |
| `NLVC-App.provisionprofile` | App 的 Developer ID / Mac Direct profile | `0600` |
| `NLVC-PacketTunnel.provisionprofile` | 扩展的 Developer ID / Mac Direct profile | `0600` |
| `README.md` | 本清单 | `0600` |
| `*.p12`（可选） | 证书和私钥的恢复备份，不参与日常构建 | `0600` |

当前机器检测到 `Untitled.p12` 和 `develop.p12` 两个恢复文件；脚本不会自动导入或猜测
其用途。只有钥匙串身份缺失并确认文件来源、密码和证书类型后才应导入。

目录权限必须为 `0700`。P12 密码、Apple ID 专用密码和私钥内容不能写入
`config.plist`、README、源码或日志。日常构建从 macOS 钥匙串读取私钥，P12 只用于恢复。

## 固定操作顺序

把新生成的四个 profiles 双击安装到 Xcode 后执行：

```bash
cd /Users/linlu/hillstone
./scripts/setup_apple_signing.command
./scripts/check_apple_signing.command
./scripts/build_developer_id_pkg.command
./scripts/notarize_pkg.command
```

只有下面的检查全部成功，包才可安装：

```bash
cat dist/release-*/RELEASE-STATUS.txt
pkgutil --check-signature dist/release-*/NLVC-VPN-*.pkg
```

`RELEASE-STATUS.txt` 必须明确显示 `STATUS=READY`。旧 PKG 即使仍在目录中，也不能作为
本次构建成功的依据。

## 一键诊断

```bash
cd /Users/linlu/hillstone
./scripts/check_apple_signing.command
```

如果提示 profile 缺少 System Extension entitlement，必须回到 Apple Developer 后台
修正 Identifier 并重新生成 profile；本地修改 entitlement 文件或重新 codesign 不能
补上 Apple 未授权的 Network Extension 能力。Team-ID 格式 App Group 则由最终签名
entitlement 和相同 Team ID 验证。
