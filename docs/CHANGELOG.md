# AutoSidecar Companion 版本紀錄

## 0.2.0 · 2026 年 11 月 25 日

- iPad 接收器回報面板像素、縮放、更新率及 HDR10 條件，主機據此調整串流。高刷或 HDR 無法啟動時會重試相容配置。
- MacBook 保留內建面板作主螢幕的配置，並修正虛擬螢幕成為主螢幕或進入鏡像的情況。
- Mac 安裝包及 iPad 專案提供獨立 App 識別、首次配對流程與接收器入口 `autosidecar-companion://usb`。
- USB 預設使用一條資料線承載加密的顯示、聲音與控制。增加已配對區網連線的實驗功能，支援以先前的有線會話記住的區網位址備援。
- iPad 音訊輸出可因應裝置切換，在單聲道輸出保留左右聲道內容。
- Mac App、Mac 選單列和 iPad 接收器採用 Companion 的雙螢幕圖示。
- Mac 發行模式整合 Developer ID 簽署、公證及接收器下載 QR 碼。開發預覽可用 Xcode 直接安裝 iPad 接收器。
- iPad 接收器的發行建置可匯出 App Store Connect IPA，Xcode 專案會在 App 中附上 GPL 授權。

GitHub 原始碼版修正 Mac 通用套件的雙架構檢查，並讓 iPad 模擬器編譯時略過裝置專用的 Metal 呈現量測。

基礎實作及較早的變更請參考 [WiredDisplay 上游版本紀錄](https://github.com/sibawono/WiredDisplay/blob/64180c7b9bed550bdd622e6c42c9d2e0773fc5ec/docs/CHANGELOG.md)。
