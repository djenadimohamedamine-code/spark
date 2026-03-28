class GearCalculator {
  // Ratios pour Spark 2009 manuelle (exemple de logique approximative)
  static String calculateGear(int rpm, int speed) {
    if (speed == 0) return 'N';
    if (rpm == 0) return 'N';

    double ratio = rpm / speed;

    if (ratio > 120) return '1';
    if (ratio > 80 && ratio <= 120) return '2';
    if (ratio > 55 && ratio <= 80) return '3';
    if (ratio > 40 && ratio <= 55) return '4';
    if (ratio > 0 && ratio <= 40) return '5';
    
    return '?';
  }
}
