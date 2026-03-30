import 'package:shared_preferences/shared_preferences.dart';
import '../vocal/tts_service.dart';

class FuelCalculator {
  double currentLiters = 35.0;
  final TtsService _ttsService = TtsService();
  bool lowFuelAlerted = false;

  static const double _consumptionL100 = 9.5; // Conduite agressive (km/L)
  static const double _tankCapacity = 35.0;

  // Initialise en chargeant la dernière valeur sauvegardée
  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final savedFuel = prefs.getDouble('last_fuel_level');
    final lastOdoKm = prefs.getDouble('last_odometer_km') ?? 0.0;
    final lastTimestamp = prefs.getInt('last_session_timestamp') ?? 0;

    if (savedFuel != null) {
      currentLiters = savedFuel;
      // Le rattrapage temporel a été supprimé car il vidait l'essence quand la voiture était garée.
      // Si l'utilisateur conduit sans l'application, il devra recaler l'aiguille manuellement
      // via le menu "Calibrage Essence" (qui met à jour cette sauvegarde).
    }
    await _save();
  }

  // Calibrage manuel par l'utilisateur (bouton dans le menu)
  Future<void> calibrate(double liters) async {
    currentLiters = liters.clamp(0.0, _tankCapacity);
    await _save();
    _ttsService.speak("Niveau essence calé à ${liters.toStringAsFixed(1)} litres.");
  }

  // Mise à jour par la consommation calculée (MAF ou MAP)
  void updateVirtualFuel(double lph, double secondsPassed) {
    if (lph <= 0 || secondsPassed <= 0) return;
    double consumedLiters = (lph / 3600.0) * secondsPassed;
    currentLiters = (currentLiters - consumedLiters).clamp(0.0, _tankCapacity);
    _saveAsync();

    if (currentLiters <= 5.0 && !lowFuelAlerted) {
      _ttsService.speak('Mimo, carburant bas !');
      lowFuelAlerted = true;
    } else if (currentLiters > 5.0) {
      lowFuelAlerted = false;
    }
  }

  // Calcule L/h depuis le débit MAF (g/s)
  double calculateConsumptionLph(double mafGs) {
    if (mafGs <= 0) return 0.0;
    return (mafGs * 3600.0) / (14.7 * 737.0);
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
    _save(); // fire and forget
  }
}
