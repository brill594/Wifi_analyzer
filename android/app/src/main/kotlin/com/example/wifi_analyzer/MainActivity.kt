package com.example.wifi_analyzer
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.wifi.ScanResult
import android.net.wifi.WifiManager
import android.os.Build
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {
    private val CHANNEL = "wifi_std"
    private var channelResult: MethodChannel.Result? = null

    // 创建一个广播接收器来监听扫描结果
    private val wifiScanReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val success = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                intent.getBooleanExtra(WifiManager.EXTRA_RESULTS_UPDATED, false)
            } else {
                // 在旧版本上，我们只能假设成功
                true
            }

            if (success) {
                sendScanResults()
            } else {
                // 扫描失败，也尝试发送一次当前结果
                sendScanResults()
            }
            // 注销接收器，避免内存泄漏
            try {
                unregisterReceiver(this)
            } catch (e: Exception) {
                // 忽略可能出现的错误
            }
        }
    }

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler {
                call, result ->
            if (call.method == "getScanStandards") {
                this.channelResult = result
                startWifiScan()
            } else {
                result.notImplemented()
            }
        }
    }

    private fun startWifiScan() {
        val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager

        val intentFilter = IntentFilter()
        intentFilter.addAction(WifiManager.SCAN_RESULTS_AVAILABLE_ACTION)
        registerReceiver(wifiScanReceiver, intentFilter)

        val success = wifiManager.startScan()
        if (!success) {
            // 如果 startScan 直接失败，立即发送当前结果
            sendScanResults()
            try {
                unregisterReceiver(wifiScanReceiver)
            } catch (e: Exception) {
                // 忽略
            }
        }
    }

    private fun sendScanResults() {
        if (channelResult == null) return

        try {
            // 权限检查已由 dart 端 `wifi_scan` 插件完成，这里直接获取
            val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            // 必须用 @Suppress("DEPRECATION") 因为这是唯一能在所有版本上获取结果的方法
            @Suppress("DEPRECATION")
            val scanResults: List<ScanResult> = wifiManager.scanResults ?: emptyList()

            val resultsList = scanResults.map { scanResult ->
                val map = mutableMapOf<String, Any?>()
                map["bssid"] = scanResult.BSSID
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    map["wifiStandardCode"] = scanResult.wifiStandard
                }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    map["channelWidthCode"] = scanResult.channelWidth
                    map["centerFreq0"] = scanResult.centerFreq0
                    map["centerFreq1"] = scanResult.centerFreq1
                }
                map
            }
            channelResult?.success(resultsList)
        } catch (e: Exception) {
            channelResult?.error("NATIVE_ERROR", "Failed to get scan results.", e.message)
        } finally {
            channelResult = null
        }
    }
}