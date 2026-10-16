class FuelRefill {
  final String id;
  final int timestamp;
  final String date;
  final double liters;
  final double pricePerLiter;
  final double totalAmount;
  final double? levelBefore;
  final double? levelAfter;
  final bool isCanceled;
  final String status;
  final int? expenseId;

  FuelRefill({
    required this.id,
    required this.timestamp,
    required this.date,
    required this.liters,
    required this.pricePerLiter,
    required this.totalAmount,
    this.levelBefore,
    this.levelAfter,
    this.isCanceled = false,
    String? status,
    this.expenseId,
  }) : status = status ?? (isCanceled ? 'canceled' : 'committed');

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'timestamp': timestamp,
      'date': date,
      'liters': liters,
      'price_per_liter': pricePerLiter,
      'total_amount': totalAmount,
      'level_before': levelBefore,
      'level_after': levelAfter,
      'canceled': (isCanceled || status == 'canceled') ? 1 : 0,
      'status': status,
      'expense_id': expenseId,
    };
  }

  factory FuelRefill.fromMap(Map<String, dynamic> map) {
    final canceledInt = map['canceled'] as int? ?? 0;
    final statusStr = map['status'] as String? ?? (canceledInt == 1 ? 'canceled' : 'committed');
    final isCanceledBool = canceledInt == 1 || statusStr == 'canceled';
    return FuelRefill(
      id: map['id'] as String,
      timestamp: map['timestamp'] as int,
      date: map['date'] as String,
      liters: (map['liters'] as num).toDouble(),
      pricePerLiter: (map['price_per_liter'] as num).toDouble(),
      totalAmount: (map['total_amount'] as num).toDouble(),
      levelBefore: map['level_before'] != null ? (map['level_before'] as num).toDouble() : null,
      levelAfter: map['level_after'] != null ? (map['level_after'] as num).toDouble() : null,
      isCanceled: isCanceledBool,
      status: statusStr,
      expenseId: map['expense_id'] as int?,
    );
  }
}
