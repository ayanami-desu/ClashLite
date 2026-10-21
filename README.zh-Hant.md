# ClashLite

[English](README.md) | [简体中文](README.zh-Hans.md) | **繁體中文** | [Русский](README.ru.md)

一個極簡的 macOS 選單列 [mihomo](https://github.com/MetaCubeX/mihomo) 用戶端。

## 為什麼做這個

mihomo 核心本身就能託管 Web 面板（`external-ui`），像 [metacubexd](https://github.com/MetaCubeX/metacubexd) 這樣的面板已經把節點、連線、規則、日誌都做得很好了。可現在的用戶端大多還要自己再造一個面板，功能重複，體積和複雜度也跟著上去了——核心：我自己有面板啊？

ClashLite 的想法很簡單：**只做核心做不了的事，其餘的交給核心和它內建的面板。**

- 管理核心處理程序、設定檔、訂閱更新、覆寫、TUN 授權這類「用戶端」的工作，由 ClashLite 負責
- 檢視連線、日誌、規則、測速這類「面板」的工作，一鍵打開核心託管的面板即可
- 日常最常用的操作（切換模式、切換節點、開關網卡代理）放在選單列裡，不用打開面板

沒有主視窗，沒有 Dock 圖示，只有一個選單列圖示。

## 功能

- **核心託管面板**：一鍵打開 mihomo 託管的面板，自動帶上位址和密鑰，無需手動填寫後端；預設使用 metacubexd，也可以透過設定檔中的 `external-ui-url` 換成其他面板，支援在選單中更新面板
- **設定檔管理**：支援訂閱連結和本機 YAML 檔案；訂閱可自動更新（預設採用訂閱提供的 `profile-update-interval`）；可在 App 內編輯本機設定檔、檢視訂閱設定檔
- **設定檔驗證**：匯入、編輯、更新設定檔以及儲存覆寫時，都會先用核心（`mihomo -t`）完整驗證，設定檔有問題不會被套用
- **覆寫**：分為「設定檔覆寫」（只對單一設定檔生效）和「全域覆寫」（對所有設定檔生效），按 YAML 深度合併
- **選單列快捷操作**：切換代理模式（規則／全域／直連）、在策略群組中切換節點（顯示延遲）、解除鎖定、關閉所有連線、重新啟動核心
- **網卡代理（TUN）**：只需授權一次；開啟時自動將 DNS 調整為 fake-ip 模式，並把區域網路 DNS 換成公用 DNS，讓查詢進入虛擬網卡
- **與面板同步**：在面板中修改模式、切換節點等操作會同步回選單列，下次重新啟動核心仍然保留
- **登入時啟動**
- **多語言**：支援英語、簡體中文、繁體中文和俄語，跟隨系統語言

## 介面截圖

使用範例設定檔的繁體中文介面。

| 選單列 | 設定檔管理 |
| --- | --- |
| <img src="docs/screenshots/zh-Hant/menu-bar.png" alt="選單列" width="220"> | <img src="docs/screenshots/zh-Hant/profiles.png" alt="設定檔管理" width="400"> |

<details>
<summary>更多介面截圖</summary>

### 策略群組

<img src="docs/screenshots/zh-Hant/proxy-groups.png" alt="策略群組" width="300">

### 新增訂閱

<img src="docs/screenshots/zh-Hant/add-subscription.png" alt="新增訂閱" width="420">

### 匯入本機設定檔

<img src="docs/screenshots/zh-Hant/add-local.png" alt="匯入本機設定檔" width="420">

### 編輯本機設定檔

<img src="docs/screenshots/zh-Hant/edit-profile.png" alt="編輯本機設定檔" width="760">

### 檢視訂閱設定檔

<img src="docs/screenshots/zh-Hant/view-profile.png" alt="檢視訂閱設定檔" width="760">

### 設定檔覆寫

<img src="docs/screenshots/zh-Hant/profile-override.png" alt="設定檔覆寫" width="760">

### 全域覆寫

<img src="docs/screenshots/zh-Hant/global-override.png" alt="全域覆寫" width="760">

### 執行時設定

<img src="docs/screenshots/zh-Hant/runtime-config.png" alt="執行時設定" width="760">

</details>

## 系統需求

- macOS 15 或更新版本
- Apple 晶片和 Intel 的 Mac 皆可（通用二進位檔）

## 安裝

1. 在 [Releases](../../releases) 下載最新版本，將 ClashLite 拖入「應用程式」。每個版本提供以下 DMG：

   | 檔案 | 說明 |
   | --- | --- |
   | `ClashLite-x.y.z-mihomo-vA.B.C-arm64.dmg` | 內建 mihomo 核心（打包時的最新正式版），適用於 Apple 晶片，推薦 |
   | `ClashLite-x.y.z-mihomo-vA.B.C-amd64.dmg` | 內建 mihomo 核心，適用於 Intel 晶片 |
   | `ClashLite-x.y.z.dmg` | 不含核心，需要自行放入 |

2. App 未經公證，首次打開前需要移除隔離屬性：

   ```sh
   xattr -cr /Applications/ClashLite.app
   ```

   或者首次打開被阻擋後，在「系統設定 → 隱私權與安全性」中點擊「強制打開」。

### 核心

內建核心的版本在首次啟動時會把核心複製到核心資料夾，無需其他操作。核心資料夾中已有核心時不會覆蓋，所以之後更新 ClashLite 不會取代你自己的核心；想換成新版附帶的核心，刪掉核心資料夾中的 `mihomo` 再重新打開 ClashLite 即可。

使用不含核心的版本，或者想自己選擇核心版本時，按以下步驟放入：

1. 從 [mihomo Releases](https://github.com/MetaCubeX/mihomo/releases) 下載對應架構的核心（Apple 晶片選 `mihomo-darwin-arm64-*.gz`，Intel 選 `mihomo-darwin-amd64-*.gz`）並解壓縮
2. 在選單列中點擊「更多 → 打開核心資料夾」，把解壓縮出的檔案放進去並**重新命名為 `mihomo`**
3. 賦予執行權限並移除隔離屬性：

   ```sh
   cd ~/Library/Application\ Support/com.oxi.ClashLite/Core
   chmod +x mihomo
   xattr -d com.apple.quarantine mihomo
   ```

4. 選單列中會顯示核心版本，新增設定檔後核心就會自動啟動

以後升級核心只需取代這個檔案，然後點擊「更多 → 重新啟動核心」。如果開啟了網卡代理，取代後會重新請求一次授權。

## 使用說明

### 設定檔覆寫

覆寫內容是一段 YAML 映射，會按以下順序合併到設定檔上：

```
設定檔 → 設定檔覆寫 → 全域覆寫 → ClashLite 的設定（模式、TUN、控制介面等）
```

合併規則：

- 映射逐鍵遞迴合併，其餘值直接取代
- 清單用 `+key` 插入到原清單之前，用 `key+` 附加到原清單之後

例如讓自訂規則優先於訂閱中的規則：

```yaml
+rules:
  - DOMAIN-SUFFIX,example.com,DIRECT
```

### 網卡代理

建立虛擬網卡需要 root 權限。首次開啟時，ClashLite 會跳出系統的管理者授權對話框，把核心檔案設為 root 所有並加上 setuid 位元，之後不再需要授權。取代核心檔案後權限會遺失，屆時會再次請求。

macOS 無法透過虛擬網卡劫持發往區域網路 DNS 的查詢。開啟網卡代理時，如果目前網路服務使用的是區域網路、回環或連結本機 DNS，ClashLite 會移除這些伺服器，讓查詢進入虛擬網卡；原有的公用 DNS 保留不動，沒有可用公用 DNS 時使用 223.5.5.5 和 119.29.29.29。關閉網卡代理、核心停止或結束 ClashLite 時恢復原設定。選單中的「接管系統 DNS」控制此行為，預設開啟。

自行向區域網路 DNS 直接傳送封包的應用程式不受影響。開啟網卡代理期間，split DNS 和只能由區域網路 DNS 解析的內網網域可能失效，此時可以關閉「接管系統 DNS」。

### 檔案位置

所有資料都在 `~/Library/Application Support/com.oxi.ClashLite/` 中：

| 路徑 | 說明 |
| --- | --- |
| `Core/mihomo` | 核心執行檔 |
| `Home/` | 核心工作目錄，存放 Geo 資料、規則集、面板等 |
| `Home/mihomo.log` | 核心日誌，每次啟動時清空 |
| `Profiles/` | 設定檔，檔名即設定檔名稱 |
| `Overrides/` | 設定檔覆寫 |
| `Override.yaml` | 全域覆寫 |

### 安全性

- 控制介面只監聽 `127.0.0.1:9097`，密鑰在首次啟動時隨機產生
- 面板路徑同樣隨機產生
- 最終設定透過環境變數交給核心，密鑰和節點資訊不會出現在處理程序參數中

## 從原始碼建置

需要 Xcode 26 或更新版本（專案使用了 Swift 6.2 和 Icon Composer 圖示）。

```sh
git clone <儲存庫位址>
cd ClashLite
open ClashLite.xcodeproj
```

相依套件（[Yams](https://github.com/jpsim/Yams)）透過 Swift Package Manager 自動取得。

### 在地化

介面文字位於字串目錄 `ClashLite/Localizable.xcstrings`，以英語為來源語言，在 Xcode 中編輯即可新增或修改翻譯。

### 發布

推送 `v` 開頭的 tag 即會觸發 GitHub Actions，自動建置 DMG 並建立 Release。內建核心的版本會在建置時下載 mihomo 最新的正式版，按 arm64 與 amd64 分別打包：

```sh
git tag v1.0.0
git push origin v1.0.0
```

也可以在 Actions 頁面手動執行，建置產物會作為 Artifact 上傳。

## 致謝

- [mihomo](https://github.com/MetaCubeX/mihomo)
- [metacubexd](https://github.com/MetaCubeX/metacubexd)
- [Yams](https://github.com/jpsim/Yams)
- ClashBar、[clash-verge-rev](https://github.com/clash-verge-rev/clash-verge-rev)：參考了 TUN 授權與 DNS 處理的思路

## 授權條款

[GPL-3.0](LICENSE)
