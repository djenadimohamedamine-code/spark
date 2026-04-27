import 'package:flutter/material.dart';
import '../logic/analytics_engine.dart';
import '../data/database_helper.dart';
import '../data/ride_model.dart';

class DailyReportPage extends StatefulWidget {
  const DailyReportPage({super.key});

  @override
  State<DailyReportPage> createState() => _DailyReportPageState();
}

class _DailyReportPageState extends State<DailyReportPage> {
  bool _isLoading = true;
  DailySummary? _summary;
  List<Ride> _rides = [];

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    final now = DateTime.now();
    final dateStr = '${now.year}-${now.month.toString().padLeft(2,'0')}-${now.day.toString().padLeft(2,'0')}';
    
    final summary = await AnalyticsEngine().getDailySummary(dateStr);
    final rides = await DatabaseHelper().getRidesForDate(dateStr);

    if (mounted) {
      setState(() {
        _summary = summary;
        _rides = rides;
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF050505),
      appBar: AppBar(
        title: const Text('Bilan Journalier', style: TextStyle(color: Colors.greenAccent)),
        backgroundColor: Colors.black,
      ),
      body: _isLoading 
        ? const Center(child: CircularProgressIndicator())
        : Column(
            children: [
              _buildSummaryCard(),
              Expanded(child: _buildRidesList()),
            ],
          ),
    );
  }

  Widget _buildSummaryCard() {
    if (_summary == null) return const SizedBox.shrink();
    
    return Container(
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF151828),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.greenAccent.withOpacity(0.3)),
      ),
      child: Column(
        children: [
          Text('Bénéfice Net', style: TextStyle(color: Colors.greenAccent.shade100, fontSize: 14)),
          const SizedBox(height: 8),
          Text('${_summary!.totalProfitDa.toStringAsFixed(0)} DA', style: const TextStyle(color: Colors.greenAccent, fontSize: 36, fontWeight: FontWeight.bold)),
          const Divider(color: Colors.white24, height: 30),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _buildMetric('Gains Brut', '${_summary!.totalEarnedDa.toStringAsFixed(0)} DA', Colors.white),
              _buildMetric('Coût Carburant', '-${_summary!.totalFuelCostDa.toStringAsFixed(0)} DA', Colors.redAccent),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _buildMetric('Courses', '${_summary!.rideCount}', Colors.cyanAccent),
              _buildMetric('Carburant', '${_summary!.totalFuelLiters.toStringAsFixed(2)} L', Colors.orangeAccent),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMetric(String label, String value, Color color) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(color: Colors.grey, fontSize: 12)),
        Text(value, style: TextStyle(color: color, fontSize: 16, fontWeight: FontWeight.bold)),
      ],
    );
  }

  Widget _buildRidesList() {
    if (_rides.isEmpty) {
      return const Center(child: Text("Aucune course aujourd'hui.", style: TextStyle(color: Colors.grey)));
    }

    return ListView.builder(
      itemCount: _rides.length,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemBuilder: (context, index) {
        final r = _rides[index];
        final start = DateTime.fromMillisecondsSinceEpoch(r.startTime);
        final timeStr = '${start.hour.toString().padLeft(2,'0')}:${start.minute.toString().padLeft(2,'0')}';
        
        return Card(
          color: const Color(0xFF101010),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: Colors.white10)),
          child: ListTile(
            leading: const Icon(Icons.directions_car, color: Colors.cyanAccent),
            title: Text('Course de $timeStr', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            subtitle: Text('Carburant: ${r.fuelLiters.toStringAsFixed(2)} L', style: const TextStyle(color: Colors.grey, fontSize: 12)),
            trailing: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text('+${r.earnedDa.toStringAsFixed(0)} DA', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                Text('Net: ${r.profitDa.toStringAsFixed(0)} DA', style: const TextStyle(color: Colors.greenAccent, fontSize: 12)),
              ],
            ),
          ),
        );
      },
    );
  }
}
