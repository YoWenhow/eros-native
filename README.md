# Eros Native

Eros Native 是面向 iPhone 的 Eros FE 原生客户端，使用 SwiftUI 和 UIKit。支持画廊浏览与搜索、阅读与续读、收藏、下载和离线阅读。

## 0.20 (Build250)

- 日文标题优先时，资料库打开画廊详情会使用列表已取得的标题。
- 返回画廊详情时，阅读按钮显示最新保存的页码。

## 签名与侧载

从 [GitHub Releases](https://github.com/YoWenhow/eros-native/releases) 下载未签名 IPA。此包适用于运行 iOS 27.0 或更新版本的 ARM64 iPhone。用自己的签名证书及描述文件签名后侧载，后续覆盖升级沿用相同的签名身份和 Bundle ID。可用同一 Release 中提供的 SHA256SUMS 核对下载。

## 从源码构建

构建环境使用 Swift 6.4.2、xtool 1.24.0 和 xtool 配置的 iOS 27.1 SDK。固定版本和发行文件校验值见 [工具链配置](native/Configuration/toolchain-lock.json)。在准备好工具链的 Linux 或 WSL 环境中，从仓库根目录执行以下命令。

    cd native
    bash scripts/build.sh release

未签名产物位于 native/dist/release/ErosNative-unsigned.ipa。在 native 目录运行以下命令可执行 Linux 包测试。

    bash scripts/test-linux.sh core persistence networking services session

## 许可证

本项目采用 [Apache License 2.0](LICENSE)。项目源自 [Eros FE](https://github.com/erosTeam/eros_fe)。随应用分发的第三方说明见 [ThirdPartyNotices](native/Sources/ErosNative/Resources/ThirdPartyNotices.txt)。
