import 'dart:async';
import 'package:flutter/material.dart';
import '../core/obd_service.dart';

class EngineDataPage extends StatefulWidget {
  final ObdService obdService;
  const EngineDataPage({super.key, required this.obdService});

  @override
  State<EngineDataPage> createState() => _EngineDataPageState();
}

class _EngineDataPageState extends State<EngineDataPage> {
  StreamSubscription<String>? _sub;

  // Données moteur (null = Pas de capteur / Non supporté)
  double? tps;       // Papillon (Throttle Position) %
  double? maf;       // Débit masse air g/s
  double? map;       // Pression collecteur kPa
  double? iat;       // Température air admission °C
  double? ect;       // Température liquide °C
  double? rpm;
  double? speed;
  double? voltage;
  double? ftrimST;   // Fuel Trim CT %
  double? ftrimLT;   // Fuel Trim LT %
  double? load;      // Charge moteur %
  double? timing;    // Avance allumage °
  double? o2;        // Sonde Lambda V
  double? fuelPct;   // Niveau carburant %
  double? baroPres;  // Pression baro kPa

  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    // Mode PASSIF : on écoute uniquement le flux existant du dashboard
    // On n'envoie AUCUNE commande supplémentaire pour ne pas surcharger l'ELM327
    _sub = widget.obdService.dataStream.listen(_parse);
  }

  void _parse(String data) {
    final parts = data.trim().toUpperCase().split(RegExp(r'\s+'));
    for (int i = 0; i < parts.length - 1; i++) {
      if (parts[i] == '41' && i + 1 < parts.length) {
        final pid = parts[i + 1];
        try {
          switch (pid) {
            case '11': if (i+2<parts.length) setState(() => tps   = (int.parse(parts[i+2], radix:16)/2.55)); break;
            case '10': if (i+3<parts.length) setState(() => maf   = ((int.parse(parts[i+2], radix:16)*256)+int.parse(parts[i+3], radix:16))/100.0); break;
            case '0B': if (i+2<parts.length) setState(() => map   = int.parse(parts[i+2], radix:16).toDouble()); break;
            case '0F': if (i+2<parts.length) setState(() => iat   = int.parse(parts[i+2], radix:16).toDouble() - 40); break;
            case '05': if (i+2<parts.length) setState(() => ect   = int.parse(parts[i+2], radix:16).toDouble() - 40); break;
            case '0C': if (i+3<parts.length) setState(() => rpm   = ((int.parse(parts[i+2], radix:16)*256)+int.parse(parts[i+3], radix:16))/4.0); break;
            case '0D': if (i+2<parts.length) setState(() => speed = int.parse(parts[i+2], radix:16).toDouble()); break;
            case '04': if (i+2<parts.length) setState(() => load  = (int.parse(parts[i+2], radix:16)/2.55)); break;
            case '0E': if (i+2<parts.length) setState(() => timing= (int.parse(parts[i+2], radix:16)/2.0)-64); break;
            case '06': if (i+2<parts.length) setState(() => ftrimST = (int.parse(parts[i+2], radix:16)/1.28)-100); break;
            case '07': if (i+2<parts.length) setState(() => ftrimLT = (int.parse(parts[i+2], radix:16)/1.28)-100); break;
            case '2F': if (i+2<parts.length) setState(() => fuelPct = (int.parse(parts[i+2], radix:16)/2.55)); break;
            case '33': if (i+2<parts.length) setState(() => baroPres = int.parse(parts[i+2], radix:16).toDouble()); break;
            case '17': if (i+3<parts.length) setState(() => o2 = ((int.parse(parts[i+2], radix:16)*256)+int.parse(parts[i+3], radix:16))*0.000122); break;
          }
        } catch (_) {}
      }
    }
    if (RegExp(r'\d+\.\d+V').hasMatch(data)) {
      try {
        double v = double.tryParse(data.replaceAll(RegExp(r'[^0-9.]'), '')) ?? 0;
        if (v > 5 && v < 16) setState(() => voltage = v);
      } catch (_) {}
    }
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0A0A),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Color(0xFFFF3333)),
          onPressed: () => Navigator.pop(context),
        ),
        title: Row(
          children: [
            Container(
              width: 8, height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: widget.obdService.isConnected ? Colors.greenAccent : Colors.redAccent,
                boxShadow: [BoxShadow(color: (widget.obdService.isConnected ? Colors.greenAccent : Colors.redAccent).withOpacity(0.5), blurRadius: 8)],
              ),
            ),
            const SizedBox(width: 10),
            const Text('MOTEUR / ENGINE DATA', style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold, letterSpacing: 2)),
          ],
        ),
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: RadialGradient(center: Alignment.topCenter, radius: 1.5, colors: [Color(0xFF150202), Colors.black]),
        ),
        child: GridView.count(
          crossAxisCount: 2,
          padding: const EdgeInsets.all(12),
          childAspectRatio: 1.4,
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          children: [
            _buildTile('PAPILLON', tps != null ? '${tps!.toStringAsFixed(1)}%' : 'N/A', Icons.air, Colors.orangeAccent, tps != null ? tps! / 100 : 0.0, _getColor(tps, 70, 90)),
            _buildTile('MAF', maf != null ? '${maf!.toStringAsFixed(2)} g/s' : 'N/A', Icons.wind_power, Colors.lightBlueAccent, maf != null ? maf! / 40 : 0.0, _getColor(maf, 25, 35)),
            _buildTile('PRESSION MAP', map != null ? '${map!.toStringAsFixed(0)} kPa' : 'N/A', Icons.compress, Colors.purpleAccent, map != null ? map! / 120 : 0.0, _getColor(map, 90, 110)),
            _buildTile('TEMP. AIR', iat != null ? '${iat!.toStringAsFixed(0)}°C' : 'N/A', Icons.thermostat_outlined, Colors.lightGreenAccent, iat != null ? (iat! + 20) / 80 : 0.0, _getColor(iat, 45, 60)),
            _buildTile('TEMP. EAU', ect != null ? '${ect!.toStringAsFixed(0)}°C' : 'N/A', Icons.thermostat, Colors.redAccent, ect != null ? ect! / 120 : 0.0, _getColor(ect, 95, 105)),
            _buildTile('CHARGE MOT.', load != null ? '${load!.toStringAsFixed(1)}%' : 'N/A', Icons.speed, Colors.amberAccent, load != null ? load! / 100 : 0.0, _getColor(load, 75, 90)),
            _buildTile('AVANCE ALLUM.', timing != null ? '${timing!.toStringAsFixed(1)}°' : 'N/A', Icons.bolt, const Color(0xFFFFD700), timing != null ? (timing! + 64) / 128 : 0.0, _getColor(timing, 100, 100)),
            _buildTile('FUEL TRIM CT', ftrimST != null ? '${ftrimST!.toStringAsFixed(1)}%' : 'N/A', Icons.local_gas_station, Colors.greenAccent, ftrimST != null ? (ftrimST! + 100) / 200 : 0.0, _getTrimColor(ftrimST)),
            _buildTile('FUEL TRIM LT', ftrimLT != null ? '${ftrimLT!.toStringAsFixed(1)}%' : 'N/A', Icons.local_gas_station_outlined, Colors.tealAccent, ftrimLT != null ? (ftrimLT! + 100) / 200 : 0.0, _getTrimColor(ftrimLT)),
            _buildTile('SONDE O2', o2 != null ? '${o2!.toStringAsFixed(3)} V' : 'N/A', Icons.scatter_plot, Colors.pinkAccent, o2 != null ? o2! / 1.2 : 0.0, _getColor(o2, 100, 100)),
            _buildTile('BARO.', baroPres != null ? '${baroPres!.toStringAsFixed(0)} kPa' : 'N/A', Icons.landscape, Colors.cyanAccent, baroPres != null ? baroPres! / 105 : 0.0, _getColor(baroPres, 200, 200)),
            _buildTile('BATTERIE', voltage != null ? '${voltage!.toStringAsFixed(2)} V' : 'N/A', Icons.battery_charging_full, Colors.greenAccent, voltage != null ? (voltage! - 10) / 6 : 0.0, _getColor(voltage, 14.5, 15.5, invert: true)),
            _buildTile('NIVEAU CARB.', fuelPct != null ? '${fuelPct!.toStringAsFixed(1)}%' : 'N/A', Icons.local_gas_station, Colors.orangeAccent, fuelPct != null ? fuelPct! / 100 : 0.0, _getColor(fuelPct, 20, 10, invert: true)),
            _buildTile('VITESSE OBD', speed != null ? '${speed!.toStringAsFixed(0)} km/h' : 'N/A', Icons.speed, Colors.white, speed != null ? speed! / 200 : 0.0, _getColor(speed, 200, 200)),
            _buildTile('RPM', rpm != null ? '${rpm!.toStringAsFixed(0)}' : 'N/A', Icons.rotate_right, const Color(0xFFFF3333), rpm != null ? rpm! / 8000 : 0.0, _getColor(rpm, 5500, 6500)),
          ],
        ),
      ),
    );
  }

  Color _getColor(double? v, double warn, double crit, {bool invert = false}) {
    if (v == null) return Colors.white12;
    if (invert) {
      if (v <= crit) return Colors.redAccent;
      if (v <= warn) return Colors.orangeAccent;
      return Colors.greenAccent;
    }
    if (v >= crit) return Colors.redAccent;
    if (v >= warn) return Colors.orangeAccent;
    return Colors.greenAccent;
  }

  Color? _getTrimColor(double? v) {
    if (v == null) return Colors.white12;
    if (v.abs() > 15) return Colors.redAccent;
    if (v.abs() > 8) return Colors.orangeAccent;
    return Colors.greenAccent;
  }

  Widget _buildTile(String label, String value, IconData icon, Color color, double progress, Color? statusColor) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF0A0A0A),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withOpacity(0.3), width: 1.5),
        boxShadow: [BoxShadow(color: color.withOpacity(0.06), blurRadius: 12)],
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Icon(icon, color: color, size: 16),
              const SizedBox(width: 6),
              Expanded(child: Text(label, style: TextStyle(color: Colors.white38, fontSize: 9, letterSpacing: 1.5, fontWeight: FontWeight.bold))),
              if (statusColor != null)
                Container(width: 7, height: 7, decoration: BoxDecoration(shape: BoxShape.circle, color: statusColor,
                  boxShadow: [BoxShadow(color: statusColor.withOpacity(0.6), blurRadius: 6)])),
            ],
          ),
          Text(value, style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w900, letterSpacing: -0.5)),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: progress.clamp(0.0, 1.0),
              minHeight: 4,
              backgroundColor: Colors.white12,
              valueColor: AlwaysStoppedAnimation<Color>(statusColor ?? color),
            ),
          ),
        ],
      ),
    );
  }
}
