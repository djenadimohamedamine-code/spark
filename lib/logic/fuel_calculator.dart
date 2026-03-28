import '../vocal/tts_service.dart';

class FuelCalculator {
  double currentLiters = 35.0; // Jauge virtuelle par défaut
  final TtsService _ttsService = TtsService();
  bool lowFuelAlerted = false;

  // Calculer la consommation en L/h à partir du MAF en g/s (01 10)
  double calculateConsumptionLph(double mafGs) {
    if (mafGs <= 0) return 0.0;
    return (mafGs * 3600) / (14.7 * 737);
  }

  // Met à jour la jauge virtuelle
  void updateVirtualFuel(double lph, double secondsPassed) {
    double consumedLiters = (lph / 3600) * secondsPassed;
    currentLiters -= consumedLiters;
    
    if (currentLiters <= 5.0 && !lowFuelAlerted) {
      _ttsService.speak('Mimo, carburant bas');
      lowFuelAlerted = true;
    } else if (currentLiters > 5.0) {
      lowFuelAlerted = false;
    }
  }

  // Si OBD donne le niveau direct (PID 01 2F)
  void updateRealFuelLevel(double levelPercent, double capacity) {
    currentLiters = (levelPercent / 100) * capacity;
    if (currentLiters <= 5.0 && !lowFuelAlerted) {
      _ttsService.speak('Mimo, reserve de carburant');
      lowFuelAlerted = true;
    } else if (currentLiters > 5.0) {
      lowFuelAlerted = false;
    }
  }
}
