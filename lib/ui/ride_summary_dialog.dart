import 'package:flutter/material.dart';
import '../logic/analytics_engine.dart';

class RideSummaryDialog extends StatefulWidget {
  final double fuelLiters;
  final double distanceKm;
  final int durationMinutes;
  final Function(double) onValidate;

  const RideSummaryDialog({
    super.key,
    required this.fuelLiters,
    required this.distanceKm,
    required this.durationMinutes,
    required this.onValidate,
  });

  @override
  State<RideSummaryDialog> createState() => _RideSummaryDialogState();
}

class _RideSummaryDialogState extends State<RideSummaryDialog> {
  final TextEditingController _controller = TextEditingController();
  double _fuelPrice = 50.0;
  double _profit = 0.0;
  double _fuelCost = 0.0;

  @override
  void initState() {
    super.initState();
    _loadPrice();
    _controller.addListener(_calculateProfit);
  }

  Future<void> _loadPrice() async {
    final p = await AnalyticsEngine().getFuelPriceDa();
    setState(() {
      _fuelPrice = p;
      _fuelCost = widget.fuelLiters * _fuelPrice;
    });
    _calculateProfit();
  }

  void _calculateProfit() {
    final earned = double.tryParse(_controller.text) ?? 0;
    setState(() {
      _profit = earned - _fuelCost;
    });
  }

  void _submit() {
    final amount = double.tryParse(_controller.text) ?? 0;
    if (amount > 0) {
      widget.onValidate(amount);
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF151828),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), border: Border.all(color: Colors.greenAccent.withOpacity(0.3))),
      title: Column(
        children: [
          const Icon(Icons.Check_circle, color: Colors.greenAccent, size: 40),
          const SizedBox(height: 10),
          const Text('Bilan de Course', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildRow('Durée du trajet :', '${widget.durationMinutes} min', Colors.white),
          _buildRow('Distance :', '${widget.distanceKm.toStringAsFixed(1)} Km', Colors.cyanAccent),
          const Divider(color: Colors.white10, height: 24),
          _buildRow('Carburant perdu :', '- ${_fuelCost.toStringAsFixed(0)} DA', Colors.redAccent),
          const SizedBox(height: 12),
          if (_profit > 0) 
            _buildRow('Bénéfice Net :', '+ ${_profit.toStringAsFixed(0)} DA', Colors.greenAccent, isBold: true),
          const SizedBox(height: 24),
          TextField(
            controller: _controller,
            keyboardType: TextInputType.number,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white, fontSize: 32, fontWeight: FontWeight.bold),
            decoration: InputDecoration(
              hintText: '0 DA',
              hintStyle: const TextStyle(color: Colors.white24),
              labelText: 'Montant encaissé inDrive',
              labelStyle: const TextStyle(color: Colors.greenAccent, fontSize: 14),
              enabledBorder: UnderlineInputBorder(borderSide: const BorderSide(color: Colors.greenAccent)),
              focusedBorder: UnderlineInputBorder(borderSide: const BorderSide(color: Colors.greenAccent, width: 2)),
            ),
            autofocus: true,
            onSubmitted: (_) => _submit(),
          )
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('ANNULER', style: TextStyle(color: Colors.grey))),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.greenAccent, 
            foregroundColor: Colors.black,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12)
          ),
          onPressed: _submit,
          child: const Text('VALIDER LA COURSE', style: TextStyle(fontWeight: FontWeight.bold)),
        )
      ],
    );
  }

  Widget _buildRow(String label, String value, Color color, {bool isBold = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: Colors.grey, fontSize: 13)),
          Text(value, style: TextStyle(color: color, fontWeight: isBold ? FontWeight.bold : FontWeight.normal, fontSize: isBold ? 16 : 14)),
        ],
      ),
    );
  }
}
