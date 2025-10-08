import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:wifi_scan/wifi_scan.dart';
import 'dart:math' as math;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
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
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: seed,
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: seed,
        brightness: Brightness.dark,
      ),
      home: const HomePage(),
    );
  }
}

/* ------------------------------ 数据结构 ------------------------------ */

class AP {
  final String ssid;
  final String bssid;
  final int rssi;      // dBm（负数，越接近0越强）
  final int frequency; // MHz
  final int channel;

  AP({
    required this.ssid,
    required this.bssid,
    required this.rssi,
    required this.frequency,
    required this.channel,
  });

  Map<String, dynamic> toJson() => {
    'ssid': ssid,
    'bssid': bssid,
    'rssi': rssi,
    'frequency_mhz': frequency,
    'channel': channel,
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

  @override
  void dispose() {
    remarkCtrl.dispose();
    searchCtrl.dispose();
    super.dispose();
  }

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

    final mapped = results
        .map((e) => AP(
      ssid: e.ssid,
      bssid: e.bssid,
      rssi: e.level,
      frequency: e.frequency,
      channel: freqToChannel(e.frequency),
    ))
        .toList()
      ..sort((a, b) => b.rssi.compareTo(a.rssi)); // 强->弱

    setState(() {
      aps = mapped;
      scanning = false;
      status = '共发现 ${aps.length} 个网络';
    });
  }

  Future<void> saveToJson() async {
    if (aps.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('当前没有扫描结果可保存。')),
      );
      return;
    }
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/wifi_scans.json');

    // 读已有列表（如果没有则空列表）
    List<dynamic> all = [];
    if (await file.exists()) {
      final t = await file.readAsString();
      if (t.trim().isNotEmpty) {
        try { all = jsonDecode(t) as List; } catch (_) {}
      }
    }

    // 本次条目（已按 RSSI 排序）
    final entry = {
      'timestamp': DateTime.now().toIso8601String(),
      'remark': remarkCtrl.text.trim(),
      'count': aps.length,
      'results': aps.map((e) => e.toJson()).toList(),
    };
    all.add(entry);

    await file.writeAsString(const JsonEncoder.withIndent('  ').convert(all), flush: true);

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已保存到 ${file.path.split('/').last}（应用文档目录）')),
    );
  }

  List<AP> get _filtered {
    final q = searchCtrl.text.trim().toLowerCase();
    return aps.where((e) {
      final okBand = _inBand(e.frequency, band);
      final okQuery = q.isEmpty ||
          e.ssid.toLowerCase().contains(q) ||
          e.bssid.toLowerCase().contains(q);
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
          IconButton(
            tooltip: '重新扫描',
            onPressed: scanning ? null : scanOnce,
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: '保存 JSON（统一文件）',
            onPressed: hasData ? saveToJson : null,
            icon: const Icon(Icons.save_alt),
          ),
        ],
      ),
      body: Column(
        children: [
          // 工具条：备注 + 扫描 + 频段筛选 + 搜索
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
                    // 频段筛选
                    SegmentedButton<Band>(
                      segments: const [
                        ButtonSegment(value: Band.any, label: Text('全部')),
                        ButtonSegment(value: Band.b24, label: Text('2.4G')),
                        ButtonSegment(value: Band.b5,  label: Text('5G')),
                        ButtonSegment(value: Band.b6,  label: Text('6G')),
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
                    // 搜索
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
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),

          // 图表
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                      color: Theme.of(context).colorScheme.outlineVariant, width: 1),
                ),
                child: CustomPaint(
                  painter: WifiChartPainter(aps: list, brightness: Theme.of(context).brightness),
                  child: const SizedBox.expand(),
                ),
              ),
            ),
          ),

          // 底部卡片列表（横向）
          SizedBox(
            height: 140,
            child: hasData
                ? ListView.separated(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              scrollDirection: Axis.horizontal,
              itemBuilder: (_, i) {
                final ap = list[i];
                return Container(
                  width: 260,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Theme.of(context).dividerColor),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(ap.ssid.isEmpty ? '<隐藏SSID>' : ap.ssid,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w700)),
                      const SizedBox(height: 6),
                      Text('BSSID: ${ap.bssid}',
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      Text('信道: ${ap.channel}    频率: ${ap.frequency} MHz'),
                      Text('信号: ${ap.rssi} dBm'),
                    ],
                  ),
                );
              },
              separatorBuilder: (_, __) => const SizedBox(width: 10),
              itemCount: list.length,
            )
                : const Center(child: Text('没有数据')),
          ),
        ],
      ),
    );
  }
}

/* ------------------------------ 绘图 ------------------------------ */

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

    // 颜色
    final textColor =
    brightness == Brightness.dark ? Colors.white : Colors.black87;
    final gridColor =
    (brightness == Brightness.dark ? Colors.white70 : Colors.black87)
        .withOpacity(0.22);
    final axisColor = gridColor.withOpacity(0.55);

    // 背景网格（水平）
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

    // ===== 只用“被占用的信道”来决定范围与刻度 =====
    final occupied = aps.map((e) => e.channel).where((c) => c > 0).toSet().toList()
      ..sort();
    int minCh, maxCh;
    if (occupied.isEmpty) {
      minCh = 1;
      maxCh = 165;
    } else {
      minCh = (occupied.first - 3).clamp(1, 1000);
      maxCh = (occupied.last + 3).clamp(minCh + 10, 1000);
    }

    double xOf(num ch) =>
        chart.left + ((ch - minCh) / (maxCh - minCh)) * chart.width;

    double yOf(int rssi) {
      final rr = rssi.clamp(minRssi, maxRssi).toDouble();
      final t = (rr - minRssi) / (maxRssi - minRssi);
      return chart.bottom - t * chart.height;
    }

    // Y 轴刻度
    for (int r = -100; r <= -30; r += 10) {
      final y = yOf(r);
      _drawText(canvas, '$r dBm', Offset(padding.left - 44, y - 7),
          TextStyle(fontSize: 11, color: textColor.withOpacity(0.75)));
    }
    // X 轴刻度：仅显示“占用的信道”（过多时做抽样避免重叠）
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
        ? [
      Colors.cyanAccent,
      Colors.orangeAccent,
      Colors.pinkAccent,
      Colors.lightGreenAccent,
      Colors.amberAccent,
      Colors.blueAccent,
      Colors.limeAccent,
      Colors.tealAccent,
    ]
        : [
      Colors.blue.shade800,
      Colors.red.shade700,
      Colors.green.shade700,
      Colors.purple.shade700,
      Colors.orange.shade800,
      Colors.indigo.shade800,
      Colors.teal.shade800,
      Colors.brown.shade700,
    ];

    // ===== 钟形峰：从“底线”起，不再“漂浮” =====
    const samples = 48;
    int colorIdx = 0;
    int labelIdx = 0;
    final baseY = chart.bottom - 1; // 统一把峰脚落在底部

    for (final ap in aps.where((e) => e.channel > 0)) {
      final color = palette[colorIdx++ % palette.length];

      // 半宽：2.4G≈±2ch；5/6G≈±4ch
      final halfWidthCh = ap.frequency < 2500 ? 2.0 : 4.0;

      final mu = ap.channel.toDouble();
      final sigma = halfWidthCh / 2.0;
      final topY = yOf(ap.rssi);
      final amplitude = (baseY - topY).clamp(16.0, 160.0).toDouble();

      final leftCh = mu - 3 * sigma;
      final rightCh = mu + 3 * sigma;

      Path path = Path();
      for (int i = 0; i <= samples; i++) {
        final ch = leftCh + (rightCh - leftCh) * (i / samples);
        final x = xOf(ch);
        final g = math.exp(
            -0.5 * math.pow((ch - mu) / sigma, 2).toDouble());
        final y = (baseY - amplitude * g).toDouble();
        if (i == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }
      path
        ..lineTo(xOf(rightCh), baseY)
        ..lineTo(xOf(leftCh), baseY)
        ..close();

      final bounds = Rect.fromLTRB(xOf(leftCh), topY, xOf(rightCh), baseY);
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

      // 峰顶标签（轻微错位）
      final label = ap.ssid.isEmpty ? ap.bssid : ap.ssid;
      final tp = _measure(
        label,
        const TextStyle(
            fontSize: 11, fontWeight: FontWeight.w700, color: Colors.white),
        maxWidth: 160,
      );
      final cx = xOf(mu);
      final dy = 14 + (labelIdx++ % 3) * 10;
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(
            cx - tp.width / 2 - 6, topY - tp.height - dy, tp.width + 12, tp.height + 6),
        const Radius.circular(6),
      );
      final bg = Paint()..color = Colors.black.withOpacity(0.45);
      canvas.drawRRect(rect, bg);
      tp.paint(canvas, Offset(rect.left + 6, rect.top + 3));
    }

    // 标题
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
