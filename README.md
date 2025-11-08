# Wi‑Fi Analyzer

一个用 Flutter 构建的跨平台 Wi‑Fi 扫描与分析工具（核心功能目前支持 Android）。

通过系统 API 与 `wifi_scan` 插件采集周边 AP 信息，并结合自定义算法解析 802.11 标准、信道与带宽，支持筛选、图表可视化，以及将扫描结果以 JSON 保存、打开、分享和导出。

## 主要特性

- 扫描周边 Wi‑Fi 网络：采集 `SSID / BSSID / RSSI / 频率(MHz)` 等核心字段。
- 终极标准判断（多源校验）：
  - 优先使用系统 `wifiStandard` 常量（Android 11+）。
  - 回退解析 `capabilities` 字符串（如 EHT/HE/VHT/HT）。
  - 再根据频段与带宽兜底（2.4G/5G/6G + 20/40/80/160/320MHz）。
- 频段筛选与搜索：快速按 `2.4G / 5G / 6G / 全部` 过滤，并支持按 `SSID/BSSID` 搜索。
- 详情面板：查看系统原始字段（`wifiStandardCode / channelWidthRaw / centerFreq0/1`）及 `capabilities` 原文。
- 信道占用图表：以平顶台形展示各 AP 的中心信道与估算带宽，直观识别拥塞区间。
- JSON 管理：
  - 保存：将当前扫描结果附带备注与时间戳写入 `wifi_scans.json`。
  - 打开：直接用系统应用打开 JSON 文件。
  - 分享：通过系统分享面板分发 JSON。
  - 导出：保存到系统 `Downloads`（Android 使用 MediaStore/SAF；iOS/桌面使用保存面板）。
  - 历史页：查看、删除单条记录或清空全部记录。

## 平台支持与限制

- Android（完整支持）：
  - 依赖 `wifi_scan` 插件与原生 `WifiManager` 广播扫描；通过自定义 MethodChannel(`wifi_std`) 补充 `wifiStandard / channelWidth / centerFreq` 等原始字段。
  - Android 13+ 需要 `NEARBY_WIFI_DEVICES` 权限（已声明）。部分 API 仍可能要求定位权限（`ACCESS_FINE_LOCATION`）。
  - 部分厂商对扫描频率有限制；若结果为空或变化缓慢属于正常现象。
- iOS：系统不提供周边 AP 扫描能力，实际扫描功能不可用。应用可运行，图表/历史仅能展示已有 JSON 数据。
- Web / macOS / Windows / Linux：当前不支持主动扫描。应用可运行，用于查看/管理历史 JSON 与图表展示。

## 安装与运行

前置要求：

- Flutter（stable 通道）与 Dart ≥ `3.6`。
- Android 环境（Android SDK / 模拟器或真机）。

步骤：

1. 安装依赖：
   - `flutter pub get`
2. （可选）生成应用图标：
   - `flutter pub run flutter_launcher_icons`
3. 运行到 Android 设备：
   - 连接真机并开启开发者模式，或打开模拟器。
   - `flutter run -d android`

首次扫描时会请求所需权限，请全部允许（具体见下文“权限说明”）。

## 构建与发布（Android）

- 生成 APK：`flutter build apk`
- 生成 App Bundle：`flutter build appbundle`
- 应用的包名、版本等位于 `android/app/build.gradle` 与 `pubspec.yaml`。

## 使用说明

- 顶部工具栏：
  - 输入“备注（可选）”，点击“扫描”开始一次扫描。
  - 选择频段（全部 / 2.4G / 5G / 6G），或在搜索框中输入 `SSID/BSSID` 过滤。
  - 右上角按钮依次为：历史、打开 JSON、分享 JSON、导出到 Downloads、保存 JSON、重新扫描。
- 表格区域：
  - 展示名称、设备、强度、频率、信道、带宽与标准。
  - 点击“标准”右侧的 ℹ️ 进入详情面板，查看系统原始字段与 `capabilities`。
- 图表区域：
  - 展示当前数据的信道分布与带宽占用，帮助选择干扰更少的信道。
- 历史记录：
  - 在“历史记录”页面可查看每次保存的条目，支持滑动删除、清空全部。

## 权限说明（Android）

应用已在 `AndroidManifest.xml` 中声明：

- `android.permission.NEARBY_WIFI_DEVICES`（Android 13+，设置 `neverForLocation`）。
- `android.permission.ACCESS_FINE_LOCATION`（部分 Wi‑Fi API 仍要求）。
- `android.permission.ACCESS_WIFI_STATE` / `android.permission.CHANGE_WIFI_STATE`。

在 Android 设备上：

- 请确保打开 Wi‑Fi 与定位服务，并在系统弹窗中允许相关权限。
- 若扫描结果为空或提示速率受限，稍候重试或切换位置设置。

## 数据与存储

- 扫描结果保存在应用文档目录的 `wifi_scans.json`，仅本地存储，不上传网络。
- 仓库内提供 `data/standards-oui.ieee.org.txt` 与 `data/convert.py`，用于将 IEEE OUI 数据转换为 `oui_vendor.json`（可选）：
  - `cd data && python3 convert.py`
  - 目前应用未在 UI 中展示厂商映射，后续如需可在 `lib/` 中接入读取逻辑。

## 技术栈与关键文件

- Flutter（Material 3）
- 依赖：`wifi_scan`、`permission_handler`、`path_provider`、`share_plus`、`open_filex`、`file_saver`
- 主要代码：
  - `lib/main.dart`：UI、扫描合并与标准判断、图表绘制、JSON 管理。
  - `android/app/src/main/kotlin/.../MainActivity.kt`：原生扫描结果补充（`wifi_std` 方法通道）。

## 常见问题

- 没有结果或列表为空：
  - 请确认已授予权限、开启 Wi‑Fi 与定位；部分设备对扫描频率有限制。
- iOS 与桌面平台无法扫描：
  - 属于平台限制，应用仅用于查看历史与图表展示。
- 打开/分享 JSON 弹窗无响应：
  - 请确保系统存在可处理 JSON 的应用，或先使用“导出到 Downloads”。

## 许可证

本仓库尚未声明开源许可证。如需分发或商用，请先补充 License。
