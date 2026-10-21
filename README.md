# ClashLite

一个极简的 macOS 菜单栏 [mihomo](https://github.com/MetaCubeX/mihomo) 客户端。

## 为什么做这个

mihomo 内核本身就能托管 Web 面板（`external-ui`），像 [metacubexd](https://github.com/MetaCubeX/metacubexd) 这样的面板已经把节点、连接、规则、日志都做得很好了。可现在的客户端大多还要自己再造一个面板，功能重复，体积和复杂度也跟着上去了——内核：我自己有面板啊？

ClashLite 的想法很简单：**只做内核做不了的事，其余的交给内核和它自带的面板。**

- 管理内核进程、配置文件、订阅更新、覆写、TUN 授权这类「客户端」的活，由 ClashLite 负责
- 查看连接、日志、规则、测速这类「面板」的活，一键打开内核托管的面板即可
- 日常最常用的操作（切换模式、切换节点、开关网卡代理）放在菜单栏里，不用打开面板

没有主窗口，没有 Dock 图标，只有一个菜单栏图标。

## 功能

- **内核托管面板**：一键打开 mihomo 托管的面板，自动带上地址和密钥，无需手动填写后端；默认使用 metacubexd，也可以通过配置中的 `external-ui-url` 换成其他面板，支持在菜单中更新面板
- **配置管理**：支持订阅链接和本地 YAML 文件；订阅可自动更新（默认采用订阅提供的 `profile-update-interval`）；可在应用内编辑本地配置、查看订阅配置
- **配置校验**：导入、编辑、更新配置以及保存覆写时，都会先用内核（`mihomo -t`）完整校验，配置有问题不会被应用
- **覆写**：分为「配置覆写」（只对单个配置生效）和「全局覆写」（对所有配置生效），按 YAML 深度合并
- **菜单栏快捷操作**：切换代理模式（规则 / 全局 / 直连）、在策略组中切换节点（显示延迟）、解除锁定、关闭所有连接、重启内核
- **网卡代理（TUN）**：只需授权一次；开启时自动将 DNS 调整为 fake-ip 模式，并把局域网 DNS 换成公网 DNS，让查询进入虚拟网卡
- **与面板同步**：在面板中修改模式、切换节点等操作会同步回菜单栏，下次重启内核仍然保留
- **开机自启**

## 界面截图

使用示例配置的简体中文界面。

| 菜单栏 | 配置管理 |
| --- | --- |
| <img src="docs/screenshots/zh-Hans/menu-bar.png" alt="菜单栏" width="220"> | <img src="docs/screenshots/zh-Hans/profiles.png" alt="配置管理" width="400"> |

<details>
<summary>更多界面截图</summary>

### 策略组

<img src="docs/screenshots/zh-Hans/proxy-groups.png" alt="策略组" width="300">

### 添加订阅

<img src="docs/screenshots/zh-Hans/add-subscription.png" alt="添加订阅" width="420">

### 导入本地配置

<img src="docs/screenshots/zh-Hans/add-local.png" alt="导入本地配置" width="420">

### 编辑本地配置

<img src="docs/screenshots/zh-Hans/edit-profile.png" alt="编辑本地配置" width="760">

### 查看订阅配置

<img src="docs/screenshots/zh-Hans/view-profile.png" alt="查看订阅配置" width="760">

### 配置覆写

<img src="docs/screenshots/zh-Hans/profile-override.png" alt="配置覆写" width="760">

### 全局覆写

<img src="docs/screenshots/zh-Hans/global-override.png" alt="全局覆写" width="760">

### 运行时配置

<img src="docs/screenshots/zh-Hans/runtime-config.png" alt="运行时配置" width="760">

</details>

## 系统要求

- macOS 15 或更高版本
- Apple 芯片（M 系列），不支持 Intel

## 安装

1. 在 [Releases](../../releases) 下载最新版本，将 ClashLite 拖入「应用程序」。每个版本只提供一个 DMG：

   | 文件 | 说明 |
   | --- | --- |
   | `ClashLite-x.y.z-mihomo-alpha-<commit>-arm64.dmg` | 内置 mihomo alpha 内核，适用于 Apple 芯片 |

2. 应用未经公证，首次打开前需要移除隔离属性：

   ```sh
   xattr -cr /Applications/ClashLite.app
   ```

   或者首次打开被拦截后，在「系统设置 → 隐私与安全性」中点击「仍要打开」。

### 内核

DMG 内置的 alpha 内核在首次启动时会被复制到内核目录，无需其他操作。内核目录中已有内核时不会覆盖，所以之后更新 ClashLite 不会替换你自己的内核；想换成新版附带的内核，删掉内核目录中的 `mihomo` 再重新打开 ClashLite 即可。

想自己选择内核版本时，按以下步骤放入：

1. 从 [mihomo Releases](https://github.com/MetaCubeX/mihomo/releases) 下载 Apple 芯片内核（`mihomo-darwin-arm64-*.gz`）并解压
2. 在菜单栏中点击「更多 → 打开内核目录」，把解压出的文件放进去并**重命名为 `mihomo`**
3. 赋予执行权限并移除隔离属性：

   ```sh
   cd ~/Library/Application\ Support/com.oxi.ClashLite/Core
   chmod +x mihomo
   xattr -d com.apple.quarantine mihomo
   ```

4. 菜单栏中会显示内核版本，添加配置后内核就会自动启动

以后升级内核只需替换这个文件，然后点击「更多 → 重启内核」。如果开启了网卡代理，替换后会重新请求一次授权。

## 使用说明

### 配置覆写

覆写内容是一段 YAML 映射，会按以下顺序合并到配置上：

```
配置文件 → 配置覆写 → 全局覆写 → ClashLite 的设置（模式、TUN、控制接口等）
```

合并规则：

- 映射逐键递归合并，其余值直接替换
- 列表用 `+key` 插入到原列表之前，用 `key+` 追加到原列表之后

例如让自定义规则优先于订阅中的规则：

```yaml
+rules:
  - DOMAIN-SUFFIX,example.com,DIRECT
```

### 网卡代理

创建虚拟网卡需要 root 权限。首次开启时，ClashLite 会弹出系统的管理员授权对话框，把内核文件设为 root 所有并加上 setuid 位，之后不再需要授权。替换内核文件后权限会丢失，届时会再次请求。

macOS 无法通过虚拟网卡劫持发往局域网 DNS 的查询。开启网卡代理时，如果当前网络服务使用的是局域网、回环或链路本地 DNS，ClashLite 会移除这些服务器，让查询进入虚拟网卡；原有的公网 DNS 保留不动，没有可用公网 DNS 时使用 223.5.5.5 和 119.29.29.29。关闭网卡代理、内核停止或退出 ClashLite 时恢复原设置。菜单中的「接管系统 DNS」控制该行为，默认开启。

自行向局域网 DNS 直接发包的应用不受影响。开启网卡代理期间，split DNS 和只能由局域网 DNS 解析的内网域名可能失效，此时可以关闭「接管系统 DNS」。

### 文件位置

所有数据都在 `~/Library/Application Support/com.oxi.ClashLite/` 中：

| 路径 | 说明 |
| --- | --- |
| `Core/mihomo` | 内核可执行文件 |
| `Home/` | 内核工作目录，存放 Geo 数据、规则集、面板等 |
| `Home/mihomo.log` | 内核日志，每次启动时清空 |
| `Profiles/` | 配置文件，文件名即配置名称 |
| `Overrides/` | 配置覆写 |
| `Override.yaml` | 全局覆写 |

### 安全性

- 控制接口只监听 `127.0.0.1:9097`，密钥在首次启动时随机生成
- 面板路径同样随机生成
- 最终配置通过环境变量交给内核，密钥和节点信息不会出现在进程参数中

## 从源码构建

需要 Xcode 26 或更高版本（项目使用了 Swift 6.2 和 Icon Composer 图标）。

```sh
git clone <仓库地址>
cd ClashLite
open ClashLite.xcodeproj
```

依赖（[Yams](https://github.com/jpsim/Yams)）通过 Swift Package Manager 自动拉取。

### 本地化

界面文本位于字符串目录 `ClashLite/Localizable.xcstrings`，键名沿用英语，目前只提供简体中文翻译，应用固定使用简体中文界面。

### 发布

推送 `v` 开头的 tag 即会触发 GitHub Actions，自动构建 DMG 并创建 Release。构建时下载最新的 mihomo alpha 内核，只打包 Apple 芯片（arm64）版本：

```sh
git tag v1.0.0
git push origin v1.0.0
```

也可以在 Actions 页面手动运行，构建产物会作为 Artifact 上传。

## 致谢

- [mihomo](https://github.com/MetaCubeX/mihomo)
- [metacubexd](https://github.com/MetaCubeX/metacubexd)
- [Yams](https://github.com/jpsim/Yams)
- ClashBar、[clash-verge-rev](https://github.com/clash-verge-rev/clash-verge-rev)：参考了 TUN 授权与 DNS 处理的思路

## 许可证

[GPL-3.0](LICENSE)
