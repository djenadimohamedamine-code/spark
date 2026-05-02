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
    
    private var wifiNetwork: Network? = null
    private var connectivityManager: ConnectivityManager? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        connectivityManager = applicationContext.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        
        val networkRequest = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .build()
            
        connectivityManager?.requestNetwork(networkRequest, object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                wifiNetwork = network
                android.util.Log.d("MIMO", "WiFi disponible !")
            }
            override fun onLost(network: Network) {
                if (wifiNetwork == network) {
                    wifiNetwork = null
                    android.util.Log.d("MIMO", "WiFi perdu !")
                }
            }
        })

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "activateShield" -> {
                    val status = activateShield()
                    result.success(status)
                }
                "bindToWifi" -> {
                    if (wifiNetwork != null) {
                        connectivityManager?.bindProcessToNetwork(wifiNetwork)
                        result.success(true)
                    } else {
                        result.success(false)
                    }
                }
                "unbindWifi" -> {
                    connectivityManager?.bindProcessToNetwork(null)
                    result.success(true)
                }
                else -> result.notImplemented()
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

        log += "NetReady"

        return log
    }
}
