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
        
        try {
            connectivityManager = getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
            
            val networkRequest = NetworkRequest.Builder()
                .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
                // On demande explicitement un réseau qui n'a PAS besoin d'internet
                .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                .build()
                
            // registerNetworkCallback : On écoute les changements
            connectivityManager?.registerNetworkCallback(networkRequest, object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) {
                    wifiNetwork = network
                    android.util.Log.d("MIMO", "Shield: WiFi détecté")
                }
                override fun onLost(network: Network) {
                    if (wifiNetwork == network) wifiNetwork = null
                    android.util.Log.d("MIMO", "Shield: WiFi perdu")
                }
            })

            // requestNetwork : C'est le "Bouclier". Il force Android à garder le Wi-Fi actif 
            // même si la 4G est là. On le met en "passive" ou local pour ne pas gêner le système.
            try {
                connectivityManager?.requestNetwork(networkRequest, object : ConnectivityManager.NetworkCallback() {
                    override fun onAvailable(network: Network) {
                        wifiNetwork = network
                        android.util.Log.d("MIMO", "Shield: Connexion WiFi verrouillée par le bouclier")
                    }
                }, 5000) // Timeout de 5s pour la recherche initiale
            } catch (e: Exception) {
                android.util.Log.e("MIMO", "Shield: Erreur requestNetwork: ${e.message}")
            }

        } catch (e: Exception) {
            android.util.Log.e("MIMO", "Shield: Erreur globale Connectivity: ${e.message}")
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "activateShield" -> {
                    result.success(activateShield())
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
