import 'package:shared_preferences/shared_preferences.dart';
import '../data/database_helper.dart';
import '../data/ride_model.dart';

// ─── Résumé d'une journée ────────────────────────────────────────────────────
class DailySummary {
  final int rideCount;
  final double totalEarnedDa;
  final double totalFuelLiters;
  final double totalFuelCostDa;
  final double totalProfitDa;
  final double totalDistanceKm;

  const DailySummary({
    required this.rideCount,
    required this.totalEarnedDa,
    required this.totalFuelLiters,
    required this.totalFuelCostDa,
    required this.totalProfitDa,
    required this.totalDistanceKm,
  });
}

// ─── Moteur analytique ───────────────────────────────────────────────────────
class AnalyticsEngine {
  static final AnalyticsEngine _instance = AnalyticsEngine._internal();
  factory AnalyticsEngine() => _instance;
  AnalyticsEngine._internal();

  static const String _priceKey = 'fuel_price_da';
  static const double _defaultPriceDa = 50.0; // 50 DA / litre par défaut

  // ── Prix du litre ────────────────────────────────────────────────────────
  Future<double> getFuelPriceDa() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getDouble(_priceKey) ?? _defaultPriceDa;
  }

  Future<void> setFuelPriceDa(double price) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_priceKey, price);
  }

  // ── Calcul bénéfice net d'une course ────────────────────────────────────
  // fuelLiters : litres consommés pendant la course
  // earnedDa   : montant encaissé saisi par Mimo
  // Retourne (fuelCostDa, profitDa)
  Future<(double, double)> computeRideProfit(double fuelLiters, double earnedDa) async {
    final price = await getFuelPriceDa();
    final fuelCost = fuelLiters * price;
    final profit = earnedDa - fuelCost;
    return (fuelCost, profit);
  }

  // ── Sauvegarde d'une course terminée ────────────────────────────────────
  Future<Ride> saveRide({
    required int startTime,
    required int endTime,
    required double fuelLiters,
    required double earnedDa,
    required double distanceKm,
  }) async {
    final (fuelCost, profit) = await computeRideProfit(fuelLiters, earnedDa);
    final date = DateTime.fromMillisecondsSinceEpoch(startTime);
    final dateStr = '${date.year}-${date.month.toString().padLeft(2,'0')}-${date.day.toString().padLeft(2,'0')}';

    final ride = Ride(
      date: dateStr,
      startTime: startTime,
      endTime: endTime,
      fuelLiters: fuelLiters,
      fuelCostDa: fuelCost,
      earnedDa: earnedDa,
      profitDa: profit,
      distanceKm: distanceKm,
    );
    await DatabaseHelper().insertRide(ride);
    return ride;
  }

  // ── Bilan journalier ─────────────────────────────────────────────────────
  Future<DailySummary> getDailySummary(String date) async {
    final rides = await DatabaseHelper().getRidesForDate(date);
    if (rides.isEmpty) {
      return const DailySummary(
        rideCount: 0, totalEarnedDa: 0, totalFuelLiters: 0,
        totalFuelCostDa: 0, totalProfitDa: 0, totalDistanceKm: 0,
      );
    }
    return DailySummary(
      rideCount: rides.length,
      totalEarnedDa: rides.fold(0, (s, r) => s + r.earnedDa),
      totalFuelLiters: rides.fold(0, (s, r) => s + r.fuelLiters),
      totalFuelCostDa: rides.fold(0, (s, r) => s + r.fuelCostDa),
      totalProfitDa: rides.fold(0, (s, r) => s + r.profitDa),
      totalDistanceKm: rides.fold(0, (s, r) => s + r.distanceKm),
    );
  }
}
