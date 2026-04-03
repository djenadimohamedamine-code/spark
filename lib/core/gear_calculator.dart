class GearCalculator {
  // Ratios pour Spark 2009 manuelle (exemple de logique approximative)
  static String calculateGear(int rpm, int speed) {
    if (speed < 3 || rpm < 400) return 'N';

    double ratio = rpm.toDouble() / speed.toDouble();

    // Ratios V4.28 (Tuned for Spark 1.0L)
    if (ratio > 115) return '1'; // Ajustement léger (120 -> 115) pour plus de souplesse
    if (ratio > 75) return '2';  // Ajustement (80 -> 75)
    if (ratio > 52) return '3';  // Ajustement (55 -> 52)
    if (ratio > 38) return '4';  // Ajustement (40 -> 38)
    if (ratio > 15) return '5';  
    
    return '?';
  }

}
