package com.example.wifi_analyzer
import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import android.net.wifi.WifiManager
import androidx.annotation.RequiresApi
import androidx.core.app.ActivityCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {
    private val CHANNEL = "wifi_std"

    @RequiresApi(Build.VERSION_CODES.M)
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getScanStandards" -> {
                        try {
                            // 权限检查（Android 13+ 用 NEARBY_WIFI_DEVICES；更低版本用 FINE_LOCATION）
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                                if (checkSelfPermission(Manifest.permission.NEARBY_WIFI_DEVICES)
                                    != PackageManager.PERMISSION_GRANTED) {
                                    result.error("PERM", "NEARBY_WIFI_DEVICES not granted", null)
                                    return@setMethodCallHandler
                                }
                            } else {
                                if (ActivityCompat.checkSelfPermission(this,
                                        Manifest.permission.ACCESS_FINE_LOCATION) != PackageManager.PERMISSION_GRANTED) {
                                    result.error("PERM", "ACCESS_FINE_LOCATION not granted", null)
                                    return@setMethodCallHandler
                                }
                            }

                            val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
                            val scans = wifi.scanResults
                            val out = scans.map { sr ->
                                val std = if (Build.VERSION.SDK_INT >= 30) sr.wifiStandard else -1
                                mapOf(
                                    "ssid" to (sr.SSID ?: ""),
                                    "bssid" to (sr.BSSID ?: ""),
                                    "frequency" to sr.frequency,
                                    "level" to sr.level,
                                    "channelWidth" to sr.channelWidth, // 0=20,1=40,2=80,3=160,4=80+80,5=320
                                    "centerFreq0" to sr.centerFreq0,
                                    "centerFreq1" to sr.centerFreq1,
                                    "wifiStandard" to std,              // 1=legacy,4=11n,5=11ac,6=11ax,7=11be
                                )
                            }
                            result.success(out)
                        } catch (t: Throwable) {
                            Log.e("wifi_std", "error", t)
                            result.error("ERR", t.toString(), null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }
}

