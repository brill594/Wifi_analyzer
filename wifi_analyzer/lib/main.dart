import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:wifi_scan/wifi_scan.dart';
import 'package:share_plus/share_plus.dart';
import 'package:open_filex/open_filex.dart';
import 'package:file_saver/file_saver.dart';
import 'dart:ui' show FontFeature;
import 'package:flutter/services.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}
const _wifiStdChannel = MethodChannel('wifi_std');

Future<Map<String, Map<String, dynamic>>> fetchSystemScanStandards() async {
  try {
    final List<dynamic> raw =
        await _wifiStdChannel.invokeMethod<List<dynamic>>('getScanStandards')
            ?? const [];
    // 用 BSSID 做 key，便于和 wifi_scan 的结果合并
    final map = <String, Map<String, dynamic>>{};
    for (final e in raw) {
      final m = Map<String, dynamic>.from(e as Map);
      final bssid = (m['bssid'] as String?)?.toLowerCase() ?? '';
      if (bssid.isNotEmpty) map[bssid] = m;
    }
    return map;
  } catch (e) {
    debugPrint('fetchSystemScanStandards error: $e');
    return {};
  }
}

// 把系统常量转成人类可读
String labelFromWifiStandard(int? code, {required int freq, required int bw}) {
  switch (code) {
    case 7: return '802.11be';
    case 6: return '802.11ax';
    case 5: return '802.11ac';
    case 4: return '802.11n';
    case 1: return (freq < 2500) ? '802.11b/g' : '802.11a';
  }
  // 拿不到系统值：保守兜底
  if (freq >= 5955) return '802.11ax';
  if (bw >= 320) return '802.11be';
  if (bw >= 80)  return '802.11ac/ax';
  if (bw == 40)  return '802.11n';
  return (freq < 2500) ? '802.11b/g' : '802.11a';
}

// WifiManager 的 channelWidth 常量转 MHz
int channelWidthCodeToMhz(int? code) {
  switch (code) {
    case 5: return 320; // ANDROID 14+
    case 4: return 160; // 80+80 近似按160画
    case 3: return 160;
    case 2: return 80;
    case 1: return 40;
    case 0: return 20;
  }
  return 20;
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    const seed = Colors.teal;
    return MaterialApp(
      title: 'Wi-Fi Analyzer',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.system,
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: seed, brightness: Brightness.light),
      darkTheme: ThemeData(useMaterial3: true, colorSchemeSeed: seed, brightness: Brightness.dark),
      home: const HomePage(),
    );
  }
}

/* ------------------------------ 数据结构 ------------------------------ */

class AP {
  final String ssid;
  final String bssid;
  final int rssi;              // dBm
  final int frequency;         // MHz
  final int channel;           // 中心信道
  final int bandwidthMhz;      // 估算带宽（20/40/80/160/320）
  final String standard;       // 显示用：802.11ax / ac / ...
  final String capabilities;   // 仅展示

  // —— 系统 API 原始字段（用于详情弹窗）——
  final int? wifiStandardCode;     // 1/4/5/6/7（legacy/n/ac/ax/be）
  final String? wifiStandardRaw;   // e.g. WIFI_STANDARD_11AX
  final String? channelWidthRaw;   // e.g. WiFiChannelWidth.width80
  final int? centerFreq0;          // MHz
  final int? centerFreq1;          // MHz

  AP({
    required this.ssid,
    required this.bssid,
    required this.rssi,
    required this.frequency,
    required this.channel,
    required this.bandwidthMhz,
    required this.standard,
    required this.capabilities,
    this.wifiStandardCode,
    this.wifiStandardRaw,
    this.channelWidthRaw,
    this.centerFreq0,
    this.centerFreq1,
  });

  Map<String, dynamic> toJson() => {
    'ssid': ssid,
    'bssid': bssid,
    'rssi': rssi,
    'frequency_mhz': frequency,
    'channel': channel,
    'bandwidth_mhz': bandwidthMhz,
    'standard': standard,
    'wifiStandardCode': wifiStandardCode,
    'wifiStandardRaw': wifiStandardRaw,
    'channelWidthRaw': channelWidthRaw,
    'centerFreq0': centerFreq0,
    'centerFreq1': centerFreq1,
  };
}


enum Band { any, b24, b5, b6 }

bool _inBand(int f, Band b) {
  switch (b) {
    case Band.any:
      return true;
    case Band.b24:
      return f >= 2400 && f <= 2500;
    case Band.b5:
      return f >= 5000 && f < 5925;
    case Band.b6:
      return f >= 5925 && f <= 7125;
  }
}

/// 频率(MHz) -> 信道号（按常见定义）
/// 2.4G: 2412->1, 2484->14；5G: ch = freq/5 - 1000；6G: ch = (freq-5955)/5 + 1
int freqToChannel(int freq) {
  if (freq == 2484) return 14;
  if (freq >= 2412 && freq <= 2472) return ((freq - 2412) ~/ 5) + 1;
  if (freq >= 5000 && freq <= 5895) return (freq ~/ 5) - 1000;
  if (freq >= 5955 && freq <= 7115) return ((freq - 5955) ~/ 5) + 1;
  return -1;
}

// 从结果对象里尽可能推断带宽（优先 channelWidth，其次解析 capabilities 文本，最后按频段默认）
int _inferBandwidthMhz(dynamic e) {
  try {
    final cw = e.channelWidth; // 可能是枚举
    if (cw != null) {
      final s = cw.toString(); // e.g. WiFiChannelWidth.width80
      if (s.contains('320')) return 320;
      if (s.contains('160')) return 160;
      if (s.contains('80+80')) return 160; // 画图按160处理
      if (s.contains('80')) return 80;
      if (s.contains('40')) return 40;
      if (s.contains('20')) return 20;
    }
  } catch (_) {}
  try {
    final caps = (e.capabilities ?? '') as String;
    if (caps.contains('320')) return 320;
    if (caps.contains('80+80')) return 160;
    if (caps.contains('160')) return 160;
    if (caps.contains('80')) return 80;
    if (caps.contains('40')) return 40;
    if (caps.contains('20')) return 20;
  } catch (_) {}
  // 默认：2.4G -> 20，5/6G -> 20
  return 20;
}

String _inferStandard(String caps, int freq) {
  // 将 capabilities 字符串转为大写，方便比较
  final c = caps.toUpperCase();

  // 1. 检查 802.11ax (Wi-Fi 6/6E)
  // 'HE' 是 High Efficiency 的缩写。
  // freq >= 5925 是 Wi-Fi 6E 的 6GHz 频段，只有 ax 标准支持。
  if (c.contains('HE') || c.contains('11AX') || freq >= 5925) {
    return '802.11ax';
  }

  // 2. 检查 802.11ac (Wi-Fi 5)
  // 'VHT' 是 Very High Throughput 的缩写，是 ac 标准的独有特征。
  // 删除了原来有问题的频率判断。一个网络是 ac 当且仅当它支持 VHT。
  if (c.contains('VHT') || c.contains('11AC')) {
    return '802.11ac';
  }

  // 3. 检查 802.11n (Wi-Fi 4)
  // 'HT' 是 High Throughput 的缩写。
  // 注意：ax 和 ac 网络也支持 HT，所以这个检查必须放在它们之后。
  if (c.contains('HT') || c.contains('11N')) {
    return '802.11n';
  }

  // 4. 如果以上都不是，再根据频率判断是 a 还是 b/g
  // 此时可以确定网络不是 ax, ac, 或 n。
  if (freq >= 5000) {
    // 5GHz 频段的非 ax/ac/n 网络，基本就是 802.11a 了。
    return c;
  }

  if (freq > 2400 && freq < 2500) {
    // 2.4GHz 频段的非 ax/n 网络，就是 b/g。
    // 在只看 capabilities 和 frequency 的情况下，很难区分 b 和 g。
    return '802.11b/g';
  }

  // 5. 如果所有条件都不满足，返回未知
  return '?';
}

/* ------------------------------ 页面 ------------------------------ */

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  List<AP> aps = [];
  bool scanning = false;
  String status = '点击“扫描”获取周围 Wi-Fi';
  final remarkCtrl = TextEditingController();
  final searchCtrl = TextEditingController();
  Band band = Band.any;

  File? _lastJsonFile; // 最近保存的 JSON

  @override
  void dispose() {
    remarkCtrl.dispose();
    searchCtrl.dispose();
    super.dispose();
  }
  int? _wifiStandardCode(dynamic e) {
    // 直接 int
    try { final v = e.wifiStandard; if (v is int) return v; } catch (_) {}
    try { final v = e.standard;      if (v is int) return v; } catch (_) {}
    // 从枚举名/字符串名提取
    String? s;
    try { s ??= e.wifiStandard?.toString(); } catch (_) {}
    try { s ??= e.standard?.toString();      } catch (_) {}
    if (s != null) {
      final u = s.toUpperCase();
      if (u.contains('11BE') || u.contains('EHT')) return 7; // WIFI_STANDARD_11BE
      if (u.contains('11AX') || u.contains('HE'))  return 6; // WIFI_STANDARD_11AX
      if (u.contains('11AC') || u.contains('VHT')) return 5; // WIFI_STANDARD_11AC
      if (u.contains('11N')  || u.contains('HT'))  return 4; // WIFI_STANDARD_11N
      if (u.contains('LEGACY')||u.contains('11A')||u.contains('11G')||u.contains('11B')) return 1;
    }
    return null;
  }

  String _stdLabelFromCode(int? code, {required int freq, required int bandwidthMhz}) {
    switch (code) {
      case 7: return '802.11be';
      case 6: return '802.11ax';
      case 5: return '802.11ac';
      case 4: return '802.11n';
      case 1: return (freq < 2500) ? '802.11b/g' : '802.11a';
    }
    // 兜底（不再用 capabilities）：尽量保守避免误判
    if (freq >= 5955) return '802.11ax';       // 6GHz 属于 6E(ax)
    if (bandwidthMhz >= 320) return '802.11be';
    if (bandwidthMhz >= 80)  return '802.11ac/ax';
    if (bandwidthMhz == 40)  return '802.11n';
    return (freq < 2500) ? '802.11b/g' : '802.11a';
  }

  /* ---------- JSON 文件工具 ---------- */

  Future<File> _jsonFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/wifi_scans.json');
  }

  Future<List<dynamic>> _readAllEntries() async {
    final file = await _jsonFile();
    if (await file.exists()) {
      final t = await file.readAsString();
      if (t.trim().isNotEmpty) {
        try {
          final v = jsonDecode(t);
          if (v is List) return v;
        } catch (_) {}
      }
    }
    return [];
  }

  Future<void> _writeAllEntries(List<dynamic> all) async {
    final file = await _jsonFile();
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert(all), flush: true);
    _lastJsonFile = file;
  }

  /* ---------- 扫描 ---------- */

  Future<void> scanOnce() async {
    setState(() {
      scanning = true;
      status = '正在请求权限 / 检查环境…';
    });

    final can = await WiFiScan.instance.canGetScannedResults(askPermissions: true);
    if (can != CanGetScannedResults.yes) {
      setState(() {
        scanning = false;
        status = switch (can) {
          CanGetScannedResults.notSupported => '此设备不支持扫描。',
          CanGetScannedResults.noLocationPermissionDenied => '未授予必要权限（位置 / 附近 Wi-Fi）。',
          CanGetScannedResults.noLocationServiceDisabled => '请开启系统定位后重试。',
          _ => '无法扫描（状态：$can）',
        };
      });
      return;
    }

    setState(() => status = '正在扫描…');
    await WiFiScan.instance.startScan();
    final results = await WiFiScan.instance.getScannedResults();

    final mapped = results.map((e) {
      final bw = _inferBandwidthMhz(e);
      final ed = e as dynamic; // ← 关键：转 dynamic

      // 原始字段（系统API）
      String? stdRaw;
      try { stdRaw = (ed.wifiStandard ?? ed.standard)?.toString(); } catch (_) {}
      String? cwRaw;
      try { cwRaw = ed.channelWidth?.toString(); } catch (_) {}
      int? cf0; try { final v = ed.centerFrequency0; if (v is int) cf0 = v; } catch (_) {}
      int? cf1; try { final v = ed.centerFrequency1; if (v is int) cf1 = v; } catch (_) {}

      final code  = _wifiStandardCode(e);
      final label = _stdLabelFromCode(code, freq: e.frequency, bandwidthMhz: bw);

      return AP(
        ssid: e.ssid,
        bssid: e.bssid,
        rssi: e.level,
        frequency: e.frequency,
        channel: freqToChannel(e.frequency),
        bandwidthMhz: bw,
        standard: label,                    // ← 用系统值优先（经 _stdLabelFromCode）
        capabilities: (ed.capabilities ?? '').toString(),
        wifiStandardCode: code,
        wifiStandardRaw: stdRaw,
        channelWidthRaw: cwRaw,
        centerFreq0: cf0,
        centerFreq1: cf1,
      );
    }).toList()
      ..sort((a, b) => b.rssi.compareTo(a.rssi));


    setState(() {
      aps = mapped;
      scanning = false;
      status = '共发现 ${aps.length} 个网络';
    });
  }

  /* ---------- 保存 / 打开 / 分享 / 导出 ---------- */

  Future<void> saveToJson() async {
    if (aps.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('当前没有扫描结果可保存。')),
      );
      return;
    }

    final all = await _readAllEntries();
    final entry = {
      'timestamp': DateTime.now().toIso8601String(),
      'remark': remarkCtrl.text.trim(),
      'count': aps.length,
      'results': aps.map((e) => e.toJson()).toList(),
    };
    all.add(entry);
    await _writeAllEntries(all);

    if (!mounted) return;
    final f = _lastJsonFile!;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已保存到 ${f.path.split('/').last}（应用文档目录）'),
        action: SnackBarAction(label: '打开', onPressed: _openJson),
      ),
    );
  }

  Future<void> _openJson() async {
    final f = _lastJsonFile ?? await _jsonFile();
    if (await f.exists()) {
      final res = await OpenFilex.open(f.path, type: 'application/json');
      if (res.type != ResultType.done && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('无法打开，文件在：${f.path}')),
        );
      }
    } else {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('尚未生成 wifi_scans.json')));
    }
  }

  Future<void> _shareJson() async {
    final f = _lastJsonFile ?? await _jsonFile();
    if (await f.exists()) {
      await Share.shareXFiles([XFile(f.path)], text: 'Wi-Fi 扫描记录（JSON）');
    } else {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('尚未生成 wifi_scans.json')));
    }
  }

  /// 导出到「Downloads」（Android：MediaStore/SAF；iOS/桌面：系统保存面板）
  Future<void> _exportToDownloads() async {
    final f = _lastJsonFile ?? await _jsonFile();
    if (!await f.exists()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('尚未生成 wifi_scans.json')));
      return;
    }
    try {
      final bytes = await f.readAsBytes();
      final savedPath = await FileSaver.instance.saveFile(
        name: 'wifi_scans',
        bytes: bytes,
        fileExtension: 'json',
        mimeType: MimeType.other,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已导出：$savedPath')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('导出失败：$e')));
    }
  }

  /* ---------- 历史记录（查看/删除） ---------- */

  Future<void> _openHistory() async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const HistoryPage()),
    );
    if (changed == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('历史已更新')));
    }
  }

  /* ---------- 过滤 ---------- */

  List<AP> get _filtered {
    final q = searchCtrl.text.trim().toLowerCase();
    return aps.where((e) {
      final okBand = _inBand(e.frequency, band);
      final okQuery =
          q.isEmpty || e.ssid.toLowerCase().contains(q) || e.bssid.toLowerCase().contains(q);
      return okBand && okQuery;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final list = _filtered;
    final hasData = list.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Wi-Fi Analyzer'),
        actions: [
          IconButton(tooltip: '历史', onPressed: _openHistory, icon: const Icon(Icons.history)),
          IconButton(tooltip: '打开 JSON', onPressed: _openJson, icon: const Icon(Icons.insert_drive_file_outlined)),
          IconButton(tooltip: '分享 JSON', onPressed: _shareJson, icon: const Icon(Icons.ios_share)),
          IconButton(tooltip: '导出到 Downloads', onPressed: _exportToDownloads, icon: const Icon(Icons.download_outlined)),
          IconButton(tooltip: '保存 JSON', onPressed: hasData ? saveToJson : null, icon: const Icon(Icons.save_alt)),
          IconButton(tooltip: '重新扫描', onPressed: scanning ? null : scanOnce, icon: const Icon(Icons.refresh)),
        ],
      ),
      body: Column(
        children: [
          // 工具条
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: remarkCtrl,
                        decoration: const InputDecoration(
                          labelText: '备注（可选）',
                          hintText: '例如：客厅，10月7日上午',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      onPressed: scanning ? null : scanOnce,
                      icon: const Icon(Icons.wifi_tethering),
                      label: Text(scanning ? '扫描中…' : '扫描'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    SegmentedButton<Band>(
                      segments: const [
                        ButtonSegment(value: Band.any, label: Text('全部')),
                        ButtonSegment(value: Band.b24, label: Text('2.4G')),
                        ButtonSegment(value: Band.b5, label: Text('5G')),
                        ButtonSegment(value: Band.b6, label: Text('6G')),
                      ],
                      selected: {band},
                      onSelectionChanged: (s) => setState(() => band = s.first),
                      showSelectedIcon: false,
                      style: ButtonStyle(
                        visualDensity: VisualDensity.compact,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: searchCtrl,
                        onChanged: (_) => setState(() {}),
                        decoration: const InputDecoration(
                          prefixIcon: Icon(Icons.search),
                          hintText: '搜索 SSID 或 BSSID',
                          isDense: true,
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    status,
                    style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
                ),
              ],
            ),
          ),

          // 图表
          Expanded(
            flex: 6,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Theme.of(context).colorScheme.outlineVariant, width: 1),
                ),
                child: CustomPaint(
                  painter: WifiChartPainter(aps: list, brightness: Theme.of(context).brightness),
                  child: const SizedBox.expand(),
                ),
              ),
            ),
          ),

          // 表格（替代之前的横向卡片）
          Expanded(
            flex: 7,
            child: _ApTable(data: list),
          ),
        ],
      ),
    );
  }
}

/* ------------------------------ 表格控件 ------------------------------ */

class _ApTable extends StatelessWidget {
  final List<AP> data;
  const _ApTable({required this.data});

  void _showDetail(BuildContext context, AP ap) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) {
        final onBg = Theme.of(ctx).colorScheme.onSurfaceVariant;
        final mono = TextStyle(fontFeatures: const [FontFeature.tabularFigures()], color: onBg);
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 6),
              Text(ap.ssid.isEmpty ? '<隐藏SSID>' : ap.ssid,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Text(ap.bssid, style: mono),
              const Divider(height: 16),
              _kv('标准', ap.standard),
              _kv('系统 wifiStandardCode', ap.wifiStandardCode?.toString() ?? '—'),
              _kv('系统 wifiStandardRaw', ap.wifiStandardRaw?.toString() ?? '—'),
              _kv('channelWidthRaw', ap.channelWidthRaw ?? '—'),
              _kv('centerFreq0 / 1', '${ap.centerFreq0 ?? '—'} / ${ap.centerFreq1 ?? '—'} MHz'),
              _kv('频率 / 信道', '${ap.frequency} MHz / ch ${ap.channel}'),
              _kv('带宽(估)', '${ap.bandwidthMhz} MHz'),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                childrenPadding: EdgeInsets.zero,
                title: const Text('capabilities（仅展示，不参与判断）'),
                children: [
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      border: Border.all(color: Theme.of(ctx).dividerColor),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: SelectableText(
                      ap.capabilities.isEmpty ? '（空）' : ap.capabilities,
                      style: mono,
                    ),
                  )
                ],
              ),
              const SizedBox(height: 12),
            ],
          ),
        );
      },
    );
  }

  Widget _kv(String k, String v) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(width: 140, child: Text(k)),
          Expanded(child: Text(v, maxLines: 2, overflow: TextOverflow.ellipsis)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (data.isEmpty) return const Center(child: Text('没有数据'));

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final table = DataTable(
            headingRowHeight: 36,
            dataRowMinHeight: 32,
            dataRowMaxHeight: 44,
            columns: const [
              DataColumn(label: Text('名称')),
              DataColumn(label: Text('设备')),
              DataColumn(label: Text('强度')),
              DataColumn(label: Text('频率')),
              DataColumn(label: Text('信道')),
              DataColumn(label: Text('带宽')),
              DataColumn(label: Text('标准')), // ← 这里有 ℹ️
            ],
            rows: data.map((ap) {
              return DataRow(cells: [
                DataCell(SizedBox(width: 160, child: Text(ap.ssid.isEmpty ? '<隐藏SSID>' : ap.ssid, overflow: TextOverflow.ellipsis))),
                DataCell(SizedBox(width: 160, child: Text(ap.bssid, overflow: TextOverflow.ellipsis))),
                DataCell(Text('${ap.rssi} dBm')),
                DataCell(Text('${ap.frequency} MHz')),
                DataCell(Text('${ap.channel}')),
                DataCell(Text('${ap.bandwidthMhz} MHz')),
                DataCell(SizedBox(
                  width: 150,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(child: Text(ap.standard, overflow: TextOverflow.ellipsis)),
                      const SizedBox(width: 4),
                      IconButton(
                        tooltip: '查看系统字段',
                        icon: const Icon(Icons.info_outline, size: 18),
                        onPressed: () => _showDetail(context, ap),
                      ),
                    ],
                  ),
                )),
              ]);
            }).toList(),
          );

          // 纵向 + 横向双滚动
          return Scrollbar(
            thumbVisibility: true,
            child: SingleChildScrollView(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: ConstrainedBox(
                  constraints: BoxConstraints(minWidth: constraints.maxWidth),
                  child: table,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}



/* ------------------------------ 历史页：查看 + 删除 ------------------------------ */

class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});
  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  List<dynamic> entries = [];
  bool loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<File> _jsonFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/wifi_scans.json');
  }

  Future<void> _load() async {
    final f = await _jsonFile();
    if (await f.exists()) {
      final t = await f.readAsString();
      if (t.trim().isNotEmpty) {
        try {
          final v = jsonDecode(t);
          if (v is List) entries = v;
        } catch (_) {}
      }
    }
    setState(() => loading = false);
  }

  Future<void> _persist() async {
    final f = await _jsonFile();
    await f.writeAsString(const JsonEncoder.withIndent('  ').convert(entries), flush: true);
  }

  Future<void> _deleteAt(int index) async {
    final removed = entries.removeAt(index);
    await _persist();
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已删除：${_titleOf(removed)}')),
    );
    Navigator.of(context).pop(true);
  }

  Future<void> _clearAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('清空历史？'),
        content: const Text('这将删除 wifi_scans.json 中的所有记录，不可恢复。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('清空')),
        ],
      ),
    );
    if (ok != true) return;
    entries.clear();
    await _persist();
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已清空历史')));
    Navigator.of(context).pop(true);
  }

  String _titleOf(dynamic e) {
    try {
      final ts = DateTime.tryParse(e['timestamp'] ?? '')?.toLocal();
      final remark = (e['remark'] ?? '').toString();
      final count = e['count'] ?? (e['results'] as List?)?.length ?? 0;
      final timeStr = ts != null ? ts.toString().replaceFirst('T', ' ').split('.').first : '未知时间';
      return '$timeStr（$count 条）${remark.isEmpty ? '' : ' · $remark'}';
    } catch (_) {
      return '未知记录';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('历史记录'),
        actions: [
          IconButton(
            tooltip: '清空全部',
            onPressed: entries.isEmpty ? null : _clearAll,
            icon: const Icon(Icons.delete_forever),
          ),
        ],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : entries.isEmpty
          ? const Center(child: Text('暂无历史'))
          : ListView.separated(
        itemCount: entries.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (ctx, i) {
          final e = entries[i];
          final title = _titleOf(e);
          final results = (e['results'] as List?) ?? [];
          return Dismissible(
            key: ValueKey('hist_$i'),
            direction: DismissDirection.endToStart,
            background: Container(
              color: Theme.of(context).colorScheme.errorContainer,
              alignment: Alignment.centerRight,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Icon(Icons.delete, color: Theme.of(context).colorScheme.onErrorContainer),
            ),
            confirmDismiss: (_) async {
              return await showDialog<bool>(
                context: context,
                builder: (_) => AlertDialog(
                  title: const Text('删除这条记录？'),
                  content: Text(title),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
                    FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('删除')),
                  ],
                ),
              );
            },
            onDismissed: (_) => _deleteAt(i),
            child: ListTile(
              title: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
              subtitle: Text('包含 ${results.length} 个网络'),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline),
                onPressed: () async {
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (_) => AlertDialog(
                      title: const Text('删除这条记录？'),
                      content: Text(title),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
                        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('删除')),
                      ],
                    ),
                  );
                  if (ok == true) _deleteAt(i);
                },
              ),
            ),
          );
        },
      ),
    );
  }
}

/* ------------------------------ 绘图（平顶台形） ------------------------------ */

class WifiChartPainter extends CustomPainter {
  final List<AP> aps;
  final Brightness brightness;
  WifiChartPainter({required this.aps, required this.brightness});

  static const int minRssi = -100;
  static const int maxRssi = -30;

  @override
  void paint(Canvas canvas, Size size) {
    final padding = const EdgeInsets.fromLTRB(48, 16, 12, 40);
    final chart = Rect.fromLTWH(
      padding.left,
      padding.top,
      size.width - padding.left - padding.right,
      size.height - padding.top - padding.bottom,
    );

    final textColor = brightness == Brightness.dark ? Colors.white : Colors.black87;
    final gridColor = (brightness == Brightness.dark ? Colors.white70 : Colors.black87).withOpacity(0.22);
    final axisColor = gridColor.withOpacity(0.55);

    // 水平网格
    final grid = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.5
      ..color = gridColor;
    const rows = 7;
    for (int i = 0; i <= rows; i++) {
      final y = chart.top + i * chart.height / rows;
      canvas.drawLine(Offset(chart.left, y), Offset(chart.right, y), grid);
    }

    // 外框
    final axis = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = axisColor;
    canvas.drawRect(chart, axis);

    // 仅占用信道决定范围
    final occupied = aps.map((e) => e.channel).where((c) => c > 0).toSet().toList()..sort();
    int minCh, maxCh;
    if (occupied.isEmpty) {
      minCh = 1;
      maxCh = 165;
    } else {
      minCh = (occupied.first - 3).clamp(1, 1000);
      maxCh = (occupied.last + 3).clamp(minCh + 10, 1000);
    }

    double xOf(num ch) => chart.left + ((ch - minCh) / (maxCh - minCh)) * chart.width;
    double yOf(int rssi) {
      final rr = rssi.clamp(minRssi, maxRssi).toDouble();
      final t = (rr - minRssi) / (maxRssi - minRssi);
      return chart.bottom - t * chart.height;
    }

    // 刻度
    for (int r = -100; r <= -30; r += 10) {
      final y = yOf(r);
      _drawText(canvas, '$r dBm', Offset(padding.left - 44, y - 7),
          TextStyle(fontSize: 11, color: textColor.withOpacity(0.75)));
    }
    if (occupied.isNotEmpty) {
      final step = (occupied.length <= 18) ? 1 : (occupied.length / 18).ceil();
      for (int i = 0; i < occupied.length; i += step) {
        final ch = occupied[i];
        final x = xOf(ch);
        canvas.drawLine(Offset(x, chart.bottom), Offset(x, chart.bottom + 4), axis);
        _drawText(canvas, '$ch', Offset(x - 6, chart.bottom + 6),
            TextStyle(fontSize: 11, color: textColor.withOpacity(0.75)));
      }
    }

    // 调色板
    final palette = brightness == Brightness.dark
        ? [Colors.cyanAccent, Colors.orangeAccent, Colors.pinkAccent, Colors.lightGreenAccent, Colors.amberAccent, Colors.blueAccent, Colors.limeAccent, Colors.tealAccent]
        : [Colors.blue.shade800, Colors.red.shade700, Colors.green.shade700, Colors.purple.shade700, Colors.orange.shade800, Colors.indigo.shade800, Colors.teal.shade800, Colors.brown.shade700];

    // 平顶台形：左右斜边+平顶，脚落在底线
    int colorIdx = 0;
    int labelIdx = 0;
    final baseY = chart.bottom - 1;

    for (final ap in aps.where((e) => e.channel > 0)) {
      final color = palette[colorIdx++ % palette.length];

      final widthCh = (ap.bandwidthMhz / 5.0); // MHz -> 信道宽度
      final slopeCh = widthCh * 0.18;          // 斜边宽度（18%）
      final leftBase = ap.channel - widthCh / 2;
      final rightBase = ap.channel + widthCh / 2;
      final leftTop = leftBase + slopeCh;
      final rightTop = rightBase - slopeCh;

      final topY = yOf(ap.rssi);

      final path = Path()
        ..moveTo(xOf(leftBase), baseY)         // 左脚
        ..lineTo(xOf(leftTop), topY)           // 左斜边上升
        ..lineTo(xOf(rightTop), topY)          // 平顶
        ..lineTo(xOf(rightBase), baseY)        // 右斜边下降
        ..close();

      final bounds = Rect.fromLTRB(xOf(leftBase), topY, xOf(rightBase), baseY);
      final fill = Paint()
        ..style = PaintingStyle.fill
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color.withOpacity(0.28), color.withOpacity(0.06)],
        ).createShader(bounds);
      final stroke = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = color;

      canvas.drawPath(path, fill);
      canvas.drawPath(path, stroke);

      // 标签（半透明底）
      final label = ap.ssid.isEmpty ? ap.bssid : ap.ssid;
      final tp = _measure(label,
          const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Colors.white),
          maxWidth: 160);
      final cx = xOf(ap.channel.toDouble());
      final dy = 14 + (labelIdx++ % 3) * 10;
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(cx - tp.width / 2 - 6, topY - tp.height - dy, tp.width + 12, tp.height + 6),
        const Radius.circular(6),
      );
      final bg = Paint()..color = Colors.black.withOpacity(0.45);
      canvas.drawRRect(rect, bg);
      tp.paint(canvas, Offset(rect.left + 6, rect.top + 3));
    }

    _drawText(canvas, 'RSSI (dBm)', Offset(8, chart.top - 12),
        TextStyle(fontSize: 12, color: textColor));
    _drawText(canvas, '信道 (Channel)', Offset(chart.right - 110, chart.bottom + 22),
        TextStyle(fontSize: 12, color: textColor));
  }

  @override
  bool shouldRepaint(covariant WifiChartPainter old) =>
      old.aps != aps || old.brightness != brightness;

  TextPainter _measure(String s, TextStyle style, {double maxWidth = 200}) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: style),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(minWidth: 0, maxWidth: maxWidth);
    return tp;
  }

  void _drawText(Canvas canvas, String s, Offset p, TextStyle style) {
    final tp = _measure(s, style);
    tp.paint(canvas, p);
  }
}
