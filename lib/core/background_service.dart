import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_background_service_android/flutter_background_service_android.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'obd_service.dart';

// ─── Clés SharedPreferences partagées entre service et UI ────────────────────
class SparkServiceKeys {
  static const String rpm       = 'svc_rpm';
  static const String speed     = 'svc_speed';
  static const String temp      = 'svc_temp';
  static const String voltage   = 'svc_voltage';
  static const String map_kpa   = 'svc_map_kpa';
  static const String iat_k     = 'svc_iat_k';
  static const String connected = 'svc_connected';
  static const String fuelLph   = 'svc_fuel_lph';
  static const String rawTelegram = 'svc_raw_telegram';
  static const String lastUpdate= 'svc_last_update';
}

// ─── Initialisation du service (à appeler dans main()) ───────────────────────
Future<void> initBackgroundService() async {
  final service = FlutterBackgroundService();

  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onServiceStart,
      autoStart: true,
      isForegroundMode: true,
      notificationChannelId: 'mimo_spark_obd',
      initialNotificationTitle: 'Mimo Spark',
      initialNotificationContent: '🔴 Scanner OBD déconnecté',
      foregroundServiceNotificationId: 888,
    ),
    iosConfiguration: IosConfiguration(
      autoStart: false,
      onForeground: onServiceStart,
      onBackground: iosBackground,
    ),
  );

  await service.startService();
}

// ─── iOS background handler (minimal) ────────────────────────────────────────
@pragma('vm:entry-point')
Future<bool> iosBackground(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  return true;
}

// ─── Point d'entrée du service (isolate séparé) ───────────────────────────────
@pragma('vm:entry-point')
void onServiceStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();

  final obd = ObdService();
  if (service is AndroidServiceInstance) {
    // Écoute le signal "passer en background/foreground" depuis l'UI
    service.on('setAsForeground').listen((_) => service.setAsForegroundService());
    service.on('setAsBackground').listen((_) => service.setAsBackgroundService());
    service.on('stopService').listen((_) => service.stopSelf());

    // Proxy de commandes pour Scan DTC / Mileage
    service.on('sendCommand').listen((data) {
      if (data != null && data['command'] != null) {
        obd.sendCommand(data['command']);
      }
    });
  }

  bool wasConnected = false;

  // Relay du stream vers SharedPreferences pour l'UI Isolate
  obd.dataStream.listen((data) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(SparkServiceKeys.rawTelegram, data);
  });

  // ─── Boucle principale du service ────────────────────────────────────────
  // Lance la connexion OBD et maintient un timer de sync vers SharedPreferences
  _connectWithRetry(obd, service);

  // Sync des données OBD → SharedPreferences toutes les 300ms (lu par l'UI)
  Timer.periodic(const Duration(milliseconds: 300), (_) async {
    final prefs = await SharedPreferences.getInstance();
    final isNowConnected = obd.isConnected;

    if (isNowConnected != wasConnected) {
      wasConnected = isNowConnected;
      if (service is AndroidServiceInstance) {
        service.setForegroundNotificationInfo(
          title: 'Mimo Spark',
          content: isNowConnected
              ? '🟢 OBD connecté — Scanner actif'
              : '🔴 OBD déconnecté — Reconnexion...',
        );
      }
      await prefs.setBool(SparkServiceKeys.connected, isNowConnected);
    }

    // Écriture des valeurs temps réel (lues par le Dashboard)
    await prefs.setDouble(SparkServiceKeys.rpm,    obd.lastRpm);
    await prefs.setDouble(SparkServiceKeys.speed,  obd.lastSpeed);
    await prefs.setDouble(SparkServiceKeys.temp,   obd.lastTemp);
    await prefs.setDouble(SparkServiceKeys.voltage,obd.lastVoltage);
    await prefs.setDouble(SparkServiceKeys.map_kpa,obd.lastMapKpa);
    await prefs.setDouble(SparkServiceKeys.iat_k,  obd.lastIatKelvin);
    await prefs.setDouble(SparkServiceKeys.fuelLph,obd.lastFuelLph);
    await prefs.setInt(SparkServiceKeys.lastUpdate, DateTime.now().millisecondsSinceEpoch);
  });
}

// ─── Connexion OBD avec retry infini dans le service ─────────────────────────
void _connectWithRetry(ObdService obd, ServiceInstance service) async {
  while (true) {
    if (!obd.isConnected) {
      await obd.connect();
    }
    await Future.delayed(const Duration(seconds: 10));
  }
}
