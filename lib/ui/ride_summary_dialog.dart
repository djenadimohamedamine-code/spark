import 'package:flutter/material.dart';

class RideSummaryDialog extends StatefulWidget {
  final double fuelLiters;
  final double distanceKm;
  final Function(double) onValidate;

  const RideSummaryDialog({
    super.key,
    required this.fuelLiters,
    required this.distanceKm,
    required this.onValidate,
  });

  @override
  State<RideSummaryDialog> createState() => _RideSummaryDialogState();
}

class _RideSummaryDialogState extends State<RideSummaryDialog> {
  final TextEditingController _controller = TextEditingController();

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
      title: const Text('Course Terminée', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Carburant consommé :', style: TextStyle(color: Colors.grey)),
              Text('${widget.fuelLiters.toStringAsFixed(2)} L', style: const TextStyle(color: Colors.orangeAccent, fontWeight: FontWeight.bold)),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Distance (approx) :', style: TextStyle(color: Colors.grey)),
              Text('${widget.distanceKm.toStringAsFixed(1)} Km', style: const TextStyle(color: Colors.cyanAccent, fontWeight: FontWeight.bold)),
            ],
          ),
          const SizedBox(height: 24),
          TextField(
            controller: _controller,
            keyboardType: TextInputType.number,
            style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold),
            decoration: InputDecoration(
              labelText: 'Montant encaissé (DA)',
              labelStyle: const TextStyle(color: Colors.greenAccent),
              enabledBorder: OutlineInputBorder(borderSide: const BorderSide(color: Colors.greenAccent), borderRadius: BorderRadius.circular(10)),
              focusedBorder: OutlineInputBorder(borderSide: const BorderSide(color: Colors.greenAccent, width: 2), borderRadius: BorderRadius.circular(10)),
            ),
            autofocus: true,
            onSubmitted: (_) => _submit(),
          )
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('ANNULER', style: TextStyle(color: Colors.grey))),
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: Colors.greenAccent, foregroundColor: Colors.black),
          onPressed: _submit,
          child: const Text('VALIDER', style: TextStyle(fontWeight: FontWeight.bold)),
        )
      ],
    );
  }
}
