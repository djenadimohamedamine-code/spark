class GearCalculator {
  // Ratios pour Spark 2009 manuelle (exemple de logique approximative)
  static String calculateGear(int rpm, int speed) {
    if (speed < 3 || rpm < 400) return 'N';

    double ratio = rpm.toDouble() / speed.toDouble();

    // Ratios calibrés Chevrolet Spark 2009 1.0L manuelle
    // 1ère : ~90-130  |  2ème : ~55-90  |  3ème : ~38-55
    // 4ème : ~27-38   |  5ème : ~20-27
    if (ratio >= 90) return '1';
    if (ratio >= 55) return '2';
    if (ratio >= 38) return '3';
    if (ratio >= 27) return '4';
    if (ratio >= 15) return '5';
    
    return '?';
  }

}
