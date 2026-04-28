package com.mimo.spark

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiManager
import android.os.PowerManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {
    private val CHANNEL = "mimo.spark/shield"

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
            val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
            val wakeLock = powerManager.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "MimoSpark::WakeLock")
            wakeLock.acquire(10*60*1000L)
            log += "WakeOK "
        } catch (e: Exception) {
            log += "WakeFail "
        }

        try {
            val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            val wifiLock = wifiManager.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "MimoSpark::WifiLock")
            wifiLock.acquire()
            log += "WifiOK "
        } catch (e: Exception) {
            log += "WifiFail "
        }

        try {
            val connManager = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            val request = NetworkRequest.Builder()
                .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
                .build()

            connManager.requestNetwork(request, object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) {
                    try {
                        connManager.bindProcessToNetwork(network)
                    } catch (e: Exception) {}
                }
            })
            log += "NetOK"
        } catch (e: Exception) {
            log += "NetFail "
        }

        return log
    }
}
