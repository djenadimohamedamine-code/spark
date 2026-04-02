import 'package:shared_preferences/shared_preferences.dart';
import '../vocal/tts_service.dart';

class FuelCalculator {
  double currentLiters = 35.0;
  final TtsService _ttsService = TtsService();
  bool lowFuelAlerted = false;
  int _lastAlertedKm = -1;

  static const double _consumptionL100 = 9.5;
  static const double _tankCapacity = 35.0;
  static const double _fuelDensity = 750.0;  // g/L essence SP95
  static const double _afr = 14.7;           // Air-Fuel Ratio stœchiométrique
  DateTime _lastSave = DateTime.fromMillisecondsSinceEpoch(0);

  // Initialise en chargeant la dernière valeur sauvegardée
  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final savedFuel = prefs.getDouble('last_fuel_level');
    final lastOdoKm = prefs.getDouble('last_odometer_km') ?? 0.0;
    final lastTimestamp = prefs.getInt('last_session_timestamp') ?? 0;

    if (savedFuel != null) {
      currentLiters = savedFuel.clamp(0.0, _tankCapacity);
    }
    await _save();
  }

  // Calibrage manuel par l'utilisateur (bouton dans le menu)
  Future<void> calibrate(double liters) async {
    currentLiters = liters.clamp(0.0, _tankCapacity);
    lowFuelAlerted = false;
    _lastAlertedKm = -1;
    await _save();
    _ttsService.speak("Niveau essence calé à ${liters.toStringAsFixed(1)} litres.");
  }

  // Mise à jour par la consommation calculée (MAF ou MAP)
  void updateVirtualFuel(double lph, double secondsPassed) {
    if (lph <= 0 || secondsPassed <= 0) return;
    double consumedLiters = (lph / 3600.0) * secondsPassed;
    currentLiters = (currentLiters - consumedLiters).clamp(0.0, _tankCapacity);
    _saveAsync();

    // Alerte originale si 0 L
    if (currentLiters <= 5.0 && !lowFuelAlerted) {
      _ttsService.speakAlert('Critique, carburant très bas !');
      lowFuelAlerted = true;
    } else if (currentLiters > 5.0) {
      lowFuelAlerted = false;
    }

    // Nouvelles Alertes KMs (Sous 100 km, tous les 10 km)
    int km = kmRestants;
    if (km <= 100 && km > 0) {
      int alertDecade = (km / 10).floor() * 10;
      if (_lastAlertedKm == -1 || alertDecade < _lastAlertedKm) {
        _ttsService.speakAlert('Mimo, autonomie basse à $alertDecade kilomètres.');
        _lastAlertedKm = alertDecade;
      }
    } else if (km > 110) {
      _lastAlertedKm = -1;
    }
  }

  // MAF (g/s) → L/h
  double calculateConsumptionLph(double mafGs) {
    if (mafGs <= 0) return 0.0;
    return (mafGs / (_afr * _fuelDensity)) * 3600.0;
  }

  // Mise à jour directe si le PID 012F répond (rare sur Spark)
  void updateRealFuelLevel(double levelPercent, double capacity) {
    currentLiters = (levelPercent / 100.0) * capacity;
    _saveAsync();
  }

  // Km restants estimés selon la consommation configurée
  int get kmRestants => (currentLiters / _consumptionL100 * 100).toInt();

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('last_fuel_level', currentLiters);
    await prefs.setInt('last_session_timestamp', DateTime.now().millisecondsSinceEpoch);
  }

  void _saveAsync() {
    final now = DateTime.now();
    if (now.difference(_lastSave).inSeconds >= 30) {
      _lastSave = now;
      _save();
    }
  }
}
