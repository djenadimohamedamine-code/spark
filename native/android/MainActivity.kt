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

    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "activateShield") {
                activateShield()
                result.success(true)
            } else {
                result.notImplemented()
            }
        }
    }

    private fun activateShield() {
        try {
            // 1. WakeLock (Garde le CPU éveillé)
            val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = powerManager.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "MimoSpark::WakeLock")
            wakeLock?.acquire()

            // 2. WifiLock (Garde l'antenne Wi-Fi à fond)
            val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            wifiLock = wifiManager.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "MimoSpark::WifiLock")
            wifiLock?.acquire()

            // 3. Network Binding (Force l'utilisation du Wi-Fi même sans internet)
            val connManager = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            val request = NetworkRequest.Builder()
                .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
                .build()

            connManager.requestNetwork(request, object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) {
                    super.onAvailable(network)
                    // Bind the entire process to this Wi-Fi network
                    connManager.bindProcessToNetwork(network)
                    println("MimoSpark: Process is now bound to Wi-Fi network!")
                }
            })
            
            println("MimoSpark: Shield Activated (WakeLock + WifiLock + NetworkRequest)")
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    override fun onDestroy() {
        wakeLock?.release()
        wifiLock?.release()
        super.onDestroy()
    }
}
