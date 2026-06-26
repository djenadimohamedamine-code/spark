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

  // Données moteur
  double tps = 0;       // Papillon (Throttle Position) %
  double maf = 0;       // Débit masse air g/s
  double map = 0;       // Pression collecteur kPa
  double iat = 0;       // Température air admission °C
  double ect = 0;       // Température liquide °C
  double rpm = 0;
  double speed = 0;
  double voltage = 0;
  double ftrimST = 0;   // Fuel Trim CT %
  double ftrimLT = 0;   // Fuel Trim LT %
  double load = 0;      // Charge moteur %
  double timing = 0;    // Avance allumage °
  double o2 = 0;        // Sonde Lambda V
  double fuelPct = 0;   // Niveau carburant %
  double baroPres = 0;  // Pression baro kPa

  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    _sub = widget.obdService.dataStream.listen(_parse);
    _startPolling();
  }

  void _startPolling() {
    _pollTimer = Timer.periodic(const Duration(milliseconds: 400), (t) async {
      final cmds = [
        '0111', // TPS
        '0110', // MAF
        '010B', // MAP
        '010F', // IAT
        '0105', // ECT
        '010C', // RPM
        '010D', // Speed
        '0104', // Load
        '010E', // Timing
        '0106', // Short FT
        '0107', // Long FT
        '012F', // Fuel Level
        '0133', // Baro
        '0117', // O2 B1S2
        'ATRV',  // Voltage
      ];
      for (final cmd in cmds) {
        widget.obdService.sendCommand(cmd);
        await Future.delayed(const Duration(milliseconds: 20));
      }
    });
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
            _buildTile('PAPILLON', '${tps.toStringAsFixed(1)}%', Icons.air, Colors.orangeAccent, tps / 100, _getColor(tps, 70, 90)),
            _buildTile('MAF', '${maf.toStringAsFixed(2)} g/s', Icons.wind_power, Colors.lightBlueAccent, maf / 40, _getColor(maf, 25, 35)),
            _buildTile('PRESSION MAP', '${map.toStringAsFixed(0)} kPa', Icons.compress, Colors.purpleAccent, map / 120, _getColor(map, 90, 110)),
            _buildTile('TEMP. AIR', '${iat.toStringAsFixed(0)}°C', Icons.thermostat_outlined, Colors.lightGreenAccent, (iat + 20) / 80, _getColor(iat, 45, 60)),
            _buildTile('TEMP. EAU', '${ect.toStringAsFixed(0)}°C', Icons.thermostat, Colors.redAccent, ect / 120, _getColor(ect, 95, 105)),
            _buildTile('CHARGE MOT.', '${load.toStringAsFixed(1)}%', Icons.speed, Colors.amberAccent, load / 100, _getColor(load, 75, 90)),
            _buildTile('AVANCE ALLUM.', '${timing.toStringAsFixed(1)}°', Icons.bolt, const Color(0xFFFFD700), (timing + 64) / 128, null),
            _buildTile('FUEL TRIM CT', '${ftrimST.toStringAsFixed(1)}%', Icons.local_gas_station, Colors.greenAccent, (ftrimST + 100) / 200, _getTrimColor(ftrimST)),
            _buildTile('FUEL TRIM LT', '${ftrimLT.toStringAsFixed(1)}%', Icons.local_gas_station_outlined, Colors.tealAccent, (ftrimLT + 100) / 200, _getTrimColor(ftrimLT)),
            _buildTile('SONDE O2', '${o2.toStringAsFixed(3)} V', Icons.scatter_plot, Colors.pinkAccent, o2 / 1.2, null),
            _buildTile('BARO.', '${baroPres.toStringAsFixed(0)} kPa', Icons.landscape, Colors.cyanAccent, baroPres / 105, null),
            _buildTile('BATTERIE', '${voltage.toStringAsFixed(2)} V', Icons.battery_charging_full, Colors.greenAccent, (voltage - 10) / 6, _getColor(voltage, 14.5, 15.5, invert: true)),
            _buildTile('NIVEAU CARB.', '${fuelPct.toStringAsFixed(1)}%', Icons.local_gas_station, Colors.orangeAccent, fuelPct / 100, _getColor(fuelPct, 20, 10, invert: true)),
            _buildTile('VITESSE OBD', '${speed.toStringAsFixed(0)} km/h', Icons.speed, Colors.white, speed / 200, null),
            _buildTile('RPM', '${rpm.toStringAsFixed(0)}', Icons.rotate_right, const Color(0xFFFF3333), rpm / 8000, _getColor(rpm, 5500, 6500)),
          ],
        ),
      ),
    );
  }

  Color _getColor(double v, double warn, double crit, {bool invert = false}) {
    if (invert) {
      if (v <= crit) return Colors.redAccent;
      if (v <= warn) return Colors.orangeAccent;
      return Colors.greenAccent;
    }
    if (v >= crit) return Colors.redAccent;
    if (v >= warn) return Colors.orangeAccent;
    return Colors.greenAccent;
  }

  Color? _getTrimColor(double v) {
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
