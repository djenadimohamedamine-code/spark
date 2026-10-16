import 'package:flutter/material.dart';
import '../logic/fuel_calculator.dart';
import '../logic/analytics_engine.dart';
import '../data/database_helper.dart';
import '../data/fuel_refill_model.dart';
import 'package:intl/intl.dart';

class AddFuelDialog extends StatefulWidget {
  final FuelCalculator fuelCalculator;
  final VoidCallback onFuelUpdated;

  const AddFuelDialog({
    super.key,
    required this.fuelCalculator,
    required this.onFuelUpdated,
  });

  static Future<void> show(
    BuildContext context, {
    required FuelCalculator fuelCalculator,
    required VoidCallback onFuelUpdated,
  }) {
    return showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => AddFuelDialog(
        fuelCalculator: fuelCalculator,
        onFuelUpdated: onFuelUpdated,
      ),
    );
  }

  @override
  State<AddFuelDialog> createState() => _AddFuelDialogState();
}

class _AddFuelDialogState extends State<AddFuelDialog> {
  final TextEditingController _litersController = TextEditingController();
  final TextEditingController _priceController = TextEditingController();

  double _pricePerLiter = 50.0;
  bool _isLoadingPrice = true;
  bool _isSubmitting = false;
  String? _errorMessage;
  bool _showHistory = false;
  List<FuelRefill> _refillsHistory = [];
  bool _isFullTank = false;

  @override
  void initState() {
    super.initState();
    _loadInitialData();
  }

  Future<void> _loadInitialData() async {
    try {
      final defaultPrice = await AnalyticsEngine().getFuelPriceDa();
      final history = await DatabaseHelper().getAllFuelRefills();
      if (!mounted) return;
      setState(() {
        _pricePerLiter = defaultPrice;
        _priceController.text = defaultPrice.toStringAsFixed(0);
        _refillsHistory = history;
        _isLoadingPrice = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _priceController.text = "50";
        _isLoadingPrice = false;
      });
    }
  }

  double? _parseDecimal(String text) {
    if (text.trim().isEmpty) return null;
    final normalized = text.trim().replaceAll(',', '.');
    return double.tryParse(normalized);
  }

  double get _currentLiters => widget.fuelCalculator.currentLiters;

  double? get _litersAdded => _parseDecimal(_litersController.text);

  double get _currentPrice => _parseDecimal(_priceController.text) ?? _pricePerLiter;

  double get _projectedLiters {
    if (_isFullTank) return FuelCalculator.tankCapacity;
    if (!widget.fuelCalculator.isCalibrated) return 0.0;
    final added = _litersAdded;
    if (added == null || added <= 0) return _currentLiters;
    return _currentLiters + added;
  }

  double get _projectedCost {
    final added = _litersAdded;
    if (added == null || added <= 0) return 0.0;
    return added * _currentPrice;
  }

  int _estimateKm(double liters) {
    return (liters / 7.5 * 100).toInt();
  }

  bool get _isExceedingTank => widget.fuelCalculator.isCalibrated && _projectedLiters > FuelCalculator.tankCapacity + 1e-6;

  bool get _isValidInput {
    final added = _litersAdded;
    if (added == null || added <= 0 || !added.isFinite || added.isNaN) return false;
    if (_isExceedingTank) return false;
    final price = _currentPrice;
    if (price <= 0 || !price.isFinite || price.isNaN) return false;
    return true;
  }

  Future<void> _confirmRefill() async {
    final added = _litersAdded;
    final price = _currentPrice;

    if (added == null || added <= 0) {
      setState(() => _errorMessage = "Veuillez entrer une quantité positive en litres.");
      return;
    }

    if (_isExceedingTank) {
      final maxAddable = widget.fuelCalculator.maxAddableLiters;
      setState(() => _errorMessage =
          "Dépassement du réservoir (max 35 L).\nVous pouvez ajouter au maximum ${maxAddable.toStringAsFixed(1)} L.");
      return;
    }

    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
    });

    try {
      // Mise à jour atomique SQLite (fuel_refills + expenses + fuel_state) via FuelCalculator
      final levelAfter = await widget.fuelCalculator.addFuel(
        added,
        pricePerLiter: price,
        isFullTank: _isFullTank,
      );

      widget.onFuelUpdated();

      if (!mounted) return;
      Navigator.of(context).pop();

      final isNowCalibrated = _isFullTank || widget.fuelCalculator.isCalibrated;
      final String confirmationText = isNowCalibrated
          ? "⛽ Plein validé : +${added.toStringAsFixed(1)} L (${(added * price).toStringAsFixed(0)} DA) → Nouveau niveau : ${levelAfter.toStringAsFixed(1)} L"
          : "⛽ Plein enregistré : +${added.toStringAsFixed(1)} L (${(added * price).toStringAsFixed(0)} DA). Jauge non calibrée.";

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: const Color(0xFF1B5E20),
          content: Text(
            confirmationText,
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          duration: const Duration(seconds: 4),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isSubmitting = false;
        _errorMessage = "Erreur lors de l'enregistrement : $e";
      });
    }
  }


  Future<void> _cancelPreviousRefill(FuelRefill refill) async {
    final hasManualCalibAfter = widget.fuelCalculator.lastCalibTs > refill.timestamp;
    final isAmbiguous = widget.fuelCalculator.currentLiters < refill.liters;
    bool deductLiters = false; // Décochée par défaut

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: const Color(0xFF151828),
          title: const Text("Annuler ce plein ?", style: TextStyle(color: Colors.white)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                "Plein de ${refill.liters.toStringAsFixed(1)} L du ${refill.date} (${refill.totalAmount.toStringAsFixed(0)} DA).\n\nLa dépense financière sera retirée.",
                style: const TextStyle(color: Colors.white70),
              ),
              const SizedBox(height: 14),
              if (hasManualCalibAfter)
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.orange.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.orangeAccent.withOpacity(0.3)),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.info_outline, color: Colors.orangeAccent, size: 18),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          "Un calibrage manuel a été effectué après ce plein. La jauge ne sera pas modifiée.",
                          style: TextStyle(color: Colors.orangeAccent, fontSize: 11),
                        ),
                      ),
                    ],
                  ),
                )
              else if (isAmbiguous)
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.amber.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.amberAccent.withOpacity(0.3)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.warning_amber_rounded, color: Colors.amberAccent, size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          "Niveau actuel (${widget.fuelCalculator.currentLiters.toStringAsFixed(1)} L) inférieur au plein. La jauge est conservée (calibrage manuel recommandé si besoin).",
                          style: const TextStyle(color: Colors.amberAccent, fontSize: 11),
                        ),
                      ),
                    ],
                  ),
                )
              else
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  activeColor: Colors.orangeAccent,
                  title: Text(
                    "Corriger également la jauge (-${refill.liters.toStringAsFixed(1)} L)",
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                  ),
                  subtitle: const Text(
                    "Décoché par défaut : réservé si le plein n'a pas été consommé",
                    style: TextStyle(color: Colors.white38, fontSize: 10),
                  ),
                  value: deductLiters,
                  onChanged: (val) {
                    setDialogState(() {
                      deductLiters = val ?? false;
                    });
                  },
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text("NON", style: TextStyle(color: Colors.grey)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text("ANNULER LE PLEIN", style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      ),
    );

    if (confirm != true) return;

    try {
      await widget.fuelCalculator.cancelFuelRefill(
        refill.liters,
        deductLiters: deductLiters,
        refillId: refill.id,
        refillTimestamp: refill.timestamp,
      );

      widget.onFuelUpdated();

      final updatedHistory = await DatabaseHelper().getAllFuelRefills();
      if (!mounted) return;
      setState(() {
        _refillsHistory = updatedHistory;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.orangeAccent,
          content: Text(
            deductLiters
                ? "Plein annulé : dépense retirée et -${refill.liters.toStringAsFixed(1)} L sur la jauge."
                : "Plein annulé : dépense retirée (jauge de carburant inchangée).",
            style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold),
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(backgroundColor: Colors.redAccent, content: Text("Erreur lors de l'annulation: $e")),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoadingPrice) {
      return const AlertDialog(
        backgroundColor: Color(0xFF101010),
        content: SizedBox(
          height: 100,
          child: Center(child: CircularProgressIndicator(color: Color(0xFFFF3333))),
        ),
      );
    }

    return AlertDialog(
      backgroundColor: const Color(0xFF101010),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      title: Row(
        children: [
          const Icon(Icons.local_gas_station, color: Colors.orangeAccent, size: 24),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              "AJOUTER DU CARBURANT",
              style: TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.1,
              ),
            ),
          ),
          IconButton(
            icon: Icon(
              _showHistory ? Icons.edit : Icons.history,
              color: Colors.white70,
              size: 20,
            ),
            tooltip: _showHistory ? "Saisie plein" : "Historique pleins",
            onPressed: () => setState(() => _showHistory = !_showHistory),
          ),
        ],
      ),
      content: SizedBox(
        width: MediaQuery.of(context).size.width * 0.9,
        child: _showHistory ? _buildHistoryView() : _buildFormView(),
      ),
      actions: _showHistory
          ? [
              TextButton(
                onPressed: () => setState(() => _showHistory = false),
                child: const Text("RETOUR À LA SAISIE", style: TextStyle(color: Colors.orangeAccent)),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text("FERMER", style: TextStyle(color: Colors.grey)),
              ),
            ]
          : [
              TextButton(
                onPressed: _isSubmitting ? null : () => Navigator.of(context).pop(),
                child: const Text("ANNULER", style: TextStyle(color: Colors.grey)),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: _isValidInput ? const Color(0xFF1B5E20) : Colors.grey[800],
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                ),
                onPressed: (_isValidInput && !_isSubmitting) ? _confirmRefill : null,
                child: _isSubmitting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Text(
                        "CONFIRMER LE PLEIN",
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                      ),
              ),
            ],
    );
  }

  Widget _buildFormView() {
    final isCalibrated = widget.fuelCalculator.isCalibrated;
    final currentKm = _estimateKm(_currentLiters);
    final projectedKm = _estimateKm(_projectedLiters.clamp(0.0, FuelCalculator.tankCapacity));
    final maxAddable = widget.fuelCalculator.maxAddableLiters;

    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Récapitulatif niveau actuel
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF181818),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white10),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text("NIVEAU ACTUEL", style: TextStyle(color: Colors.white38, fontSize: 10, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 2),
                      Text(
                        isCalibrated ? "${_currentLiters.toStringAsFixed(1)} L" : "Inconnu",
                        style: TextStyle(
                          color: isCalibrated ? Colors.white : Colors.amberAccent,
                          fontSize: isCalibrated ? 20 : 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        isCalibrated ? "Autonomie : ~$currentKm km" : "Non calibré",
                        style: TextStyle(color: isCalibrated ? Colors.white54 : Colors.amberAccent.withOpacity(0.7), fontSize: 11),
                      ),
                    ],
                  ),
                ),
                Container(width: 1, height: 40, color: Colors.white12),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(isCalibrated ? "PLACE RESTANTE" : "CAPACITÉ", style: const TextStyle(color: Colors.white38, fontSize: 10, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 2),
                      Text(
                        isCalibrated ? "${maxAddable.toStringAsFixed(1)} L" : "35.0 L",
                        style: TextStyle(
                          color: isCalibrated ? (maxAddable > 5.0 ? Colors.greenAccent : Colors.orangeAccent) : Colors.white70,
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        isCalibrated ? "Réservoir : 35 L" : "Réservoir max",
                        style: const TextStyle(color: Colors.white54, fontSize: 11),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 14),

          // P1 : Si jauge non calibrée, option explicite de confirmation plein complet
          if (!isCalibrated)
            Container(
              margin: const EdgeInsets.only(bottom: 14),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.amber.withOpacity(0.12),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.amberAccent.withOpacity(0.4)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.info_outline, color: Colors.amberAccent, size: 16),
                      SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          "Niveau actuel inconnu : ajouter des litres sans plein complet n'établira pas d'autonomie fictive.",
                          style: TextStyle(color: Colors.amberAccent, fontSize: 11, fontWeight: FontWeight.bold),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    activeColor: Colors.greenAccent,
                    checkColor: Colors.black,
                    title: const Text(
                      "Le réservoir est maintenant plein (35 L)",
                      style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                    ),
                    subtitle: const Text(
                      "Cochez si vous avez fait le plein complet pour calibrer la jauge à 35.0 L.",
                      style: TextStyle(color: Colors.white54, fontSize: 10),
                    ),
                    value: _isFullTank,
                    onChanged: (val) {
                      setState(() {
                        _isFullTank = val ?? false;
                      });
                    },
                  ),
                ],
              ),
            ),


          const SizedBox(height: 16),

          // Champ Litres ajoutés
          const Text(
            "LITRES AJOUTÉS (ex: 10 ou 9,5)",
            style: TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: _litersController,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            autofocus: true,
            style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold),
            decoration: InputDecoration(
              hintText: "0.0",
              hintStyle: const TextStyle(color: Colors.white24),
              suffixText: "Litres",
              suffixStyle: const TextStyle(color: Colors.orangeAccent, fontSize: 14),
              filled: true,
              fillColor: const Color(0xFF1E1E1E),
              contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: Colors.orangeAccent, width: 1.5),
              ),
            ),
            onChanged: (_) => setState(() => _errorMessage = null),
          ),

          const SizedBox(height: 12),

          // Champ Prix du litre
          Row(
            children: [
              Expanded(
                flex: 2,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      "PRIX DU LITRE",
                      style: TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 6),
                    TextField(
                      controller: _priceController,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      style: const TextStyle(color: Colors.white, fontSize: 16),
                      decoration: InputDecoration(
                        suffixText: "DA/L",
                        suffixStyle: const TextStyle(color: Colors.white38, fontSize: 11),
                        filled: true,
                        fillColor: const Color(0xFF1E1E1E),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 3,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      "MONTANT TOTAL",
                      style: TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E1E1E),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        "${_projectedCost.toStringAsFixed(0)} DA",
                        style: const TextStyle(
                          color: Colors.greenAccent,
                          fontSize: 17,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),

          const SizedBox(height: 14),

          // Aperçu du nouveau niveau projeté
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: _isExceedingTank ? Colors.red.withOpacity(0.15) : const Color(0xFF142014),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: _isExceedingTank ? Colors.redAccent : Colors.greenAccent.withOpacity(0.3),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      _isFullTank ? "RÉSERVOIR PLEIN" : "NIVEAU PROJETÉ APRÈS PLEIN",
                      style: const TextStyle(color: Colors.white70, fontSize: 10, fontWeight: FontWeight.bold),
                    ),
                    Text(
                      _isFullTank
                          ? "35.0 / 35 L"
                          : (isCalibrated ? "${_projectedLiters.toStringAsFixed(1)} / 35 L" : "Inconnu (non calibré)"),
                      style: TextStyle(
                        color: _isExceedingTank ? Colors.redAccent : (_isFullTank || isCalibrated ? Colors.greenAccent : Colors.amberAccent),
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: _isFullTank ? 1.0 : (isCalibrated ? (_projectedLiters / 35.0).clamp(0.0, 1.0) : 0.0),
                    backgroundColor: Colors.white10,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      _isExceedingTank ? Colors.redAccent : Colors.greenAccent,
                    ),
                    minHeight: 6,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  _isFullTank
                      ? "Nouvelle autonomie estimée : ~466 km"
                      : (isCalibrated ? "Nouvelle autonomie estimée : ~$projectedKm km" : "Autonomie non calculable (jauge non calibrée)"),
                  style: TextStyle(color: isCalibrated || _isFullTank ? Colors.white54 : Colors.amberAccent.withOpacity(0.7), fontSize: 11),
                ),
              ],
            ),
          ),

          // Message d'erreur / Avertissement dépassement
          if (_isExceedingTank)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Row(
                children: [
                  const Icon(Icons.warning_amber_rounded, color: Colors.redAccent, size: 18),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      "Dépassement de capacité : le réservoir fait 35 L max. Vous pouvez ajouter au maximum ${maxAddable.toStringAsFixed(1)} L.",
                      style: const TextStyle(color: Colors.redAccent, fontSize: 11, fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
            )
          else if (_errorMessage != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                _errorMessage!,
                style: const TextStyle(color: Colors.redAccent, fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildHistoryView() {
    if (_refillsHistory.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 30),
        child: Center(
          child: Text(
            "Aucun plein enregistré pour le moment.",
            style: TextStyle(color: Colors.white38, fontSize: 13),
          ),
        ),
      );
    }

    return SizedBox(
      height: 300,
      child: ListView.separated(
        shrinkWrap: true,
        itemCount: _refillsHistory.length,
        separatorBuilder: (_, __) => const Divider(color: Colors.white10, height: 1),
        itemBuilder: (ctx, index) {
          final item = _refillsHistory[index];
          final timeStr = DateFormat('dd/MM HH:mm').format(DateTime.fromMillisecondsSinceEpoch(item.timestamp));
          final beforeStr = item.levelBefore != null ? "${item.levelBefore!.toStringAsFixed(1)} L" : "Inconnu";
          final afterStr = item.levelAfter != null ? "${item.levelAfter!.toStringAsFixed(1)} L" : "Inconnu";

          return ListTile(
            dense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            leading: Icon(
              Icons.local_gas_station,
              color: item.isCanceled ? Colors.white24 : Colors.orangeAccent,
              size: 22,
            ),
            title: Text(
              "+${item.liters.toStringAsFixed(1)} L (${item.totalAmount.toStringAsFixed(0)} DA)",
              style: TextStyle(
                color: item.isCanceled ? Colors.white38 : Colors.white,
                fontWeight: FontWeight.bold,
                decoration: item.isCanceled ? TextDecoration.lineThrough : null,
              ),
            ),
            subtitle: Text(
              "$timeStr • $beforeStr → $afterStr${item.isCanceled ? ' [ANNULÉ]' : ''}",
              style: TextStyle(
                color: item.isCanceled ? Colors.redAccent.withOpacity(0.6) : Colors.white54,
                fontSize: 10,
              ),
            ),
            trailing: item.isCanceled
                ? const Text("Annulé", style: TextStyle(color: Colors.white24, fontSize: 10))
                : IconButton(
                    icon: const Icon(Icons.undo, color: Colors.redAccent, size: 18),
                    tooltip: "Annuler ce plein",
                    onPressed: () => _cancelPreviousRefill(item),
                  ),
          );
        },
      ),
    );
  }

}
