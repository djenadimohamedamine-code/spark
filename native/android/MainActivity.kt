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
            
            // On définit une requête qui NE demande PAS forcément l'internet
            val networkRequest = NetworkRequest.Builder()
                .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
                .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                .build()
                
            // registerNetworkCallback : On écoute passivement
            connectivityManager?.registerNetworkCallback(networkRequest, object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) {
                    wifiNetwork = network
                    android.util.Log.d("MIMO", "Shield: WiFi détecté (onAvailable)")
                }
                override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) {
                    if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) {
                        wifiNetwork = network
                        android.util.Log.d("MIMO", "Shield: WiFi mis à jour (CapabilitiesChanged)")
                    }
                }
                override fun onLost(network: Network) {
                    if (wifiNetwork == network) wifiNetwork = null
                    android.util.Log.d("MIMO", "Shield: WiFi perdu")
                }
            })

            // requestNetwork : On demande activement au système de garder la connexion même sans internet
            connectivityManager?.requestNetwork(networkRequest, object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) {
                    wifiNetwork = network
                    android.util.Log.d("MIMO", "Shield: WiFi forcé (requestNetwork)")
                }
            })

        } catch (e: Exception) {
            android.util.Log.e("MIMO", "Shield: Erreur init Connectivity: ${e.message}")
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "activateShield" -> {
                    result.success(activateShield())
                }
                "bindToWifi" -> {
                    try {
                        val net = wifiNetwork
                        if (net != null) {
                            // C'est ici que la magie opère pour DHCP + 4G
                            connectivityManager?.bindProcessToNetwork(net)
                            android.util.Log.d("MIMO", "Shield: Processus lié au WiFi avec succès")
                            result.success(true)
                        } else {
                            android.util.Log.d("MIMO", "Shield: Échec bind (wifiNetwork est null)")
                            result.success(false)
                        }
                    } catch (e: Exception) {
                        android.util.Log.e("MIMO", "Shield: Exception pendant le bind: ${e.message}")
                        result.success(false)
                    }
                }
                "unbindWifi" -> {
                    try {
                        connectivityManager?.bindProcessToNetwork(null)
                        android.util.Log.d("MIMO", "Shield: Processus délié (Retour 4G globale)")
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
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
