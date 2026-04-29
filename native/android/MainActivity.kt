package com.mimo.spark

import android.content.Context
import android.net.wifi.WifiManager
import android.os.PowerManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {
    private val CHANNEL = "mimo.spark/shield"

    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "activateShield") {
                val status = activateShield()
                result.success(status)
            } else {
                result.notImplemented()
            }
        }
    }

    private fun activateShield(): String {
        var log = "Shield: "

        try {
            if (wakeLock == null) {
                val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "MimoSpark::WakeLock")
                wakeLock?.acquire()
            }
            log += "WakeOK "
        } catch (e: Exception) {
            log += "WakeFail "
        }

        try {
            if (wifiLock == null) {
                val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
                wifiLock = wm.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "MimoSpark::WifiLock")
                wifiLock?.acquire()
            }
            log += "WifiOK "
        } catch (e: Exception) {
            log += "WifiFail "
        }

        // SUPPRESSION DU BIND RÉSEAU POUR LAISSER LA 4G ACTIVE
        log += "NetFree"

        return log
    }
}
