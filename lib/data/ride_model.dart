// Modèle d'une course InDrive / taxi

class Ride {
  final int? id;
  final String date;        // 'YYYY-MM-DD'
  final int startTime;      // epoch ms
  final int endTime;        // epoch ms
  final double fuelLiters;  // litres consommés
  final double fuelCostDa;  // coût carburant en DA
  final double earnedDa;    // montant encaissé en DA
  final double profitDa;    // bénéfice net = earned - fuelCost
  final double distanceKm;  // distance estimée

  const Ride({
    this.id,
    required this.date,
    required this.startTime,
    required this.endTime,
    required this.fuelLiters,
    required this.fuelCostDa,
    required this.earnedDa,
    required this.profitDa,
    required this.distanceKm,
  });

  Duration get duration => Duration(milliseconds: endTime - startTime);

  Map<String, dynamic> toMap() => {
    'date': date,
    'start_time': startTime,
    'end_time': endTime,
    'fuel_liters': fuelLiters,
    'fuel_cost_da': fuelCostDa,
    'earned_da': earnedDa,
    'profit_da': profitDa,
    'distance_km': distanceKm,
  };

  factory Ride.fromMap(Map<String, dynamic> m) => Ride(
    id: m['id'] as int?,
    date: m['date'] as String,
    startTime: m['start_time'] as int,
    endTime: m['end_time'] as int,
    fuelLiters: (m['fuel_liters'] as num).toDouble(),
    fuelCostDa: (m['fuel_cost_da'] as num).toDouble(),
    earnedDa: (m['earned_da'] as num).toDouble(),
    profitDa: (m['profit_da'] as num).toDouble(),
    distanceKm: (m['distance_km'] as num).toDouble(),
  );
}
