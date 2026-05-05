import 'package:flutter/material.dart';
import '../data/database_helper.dart';
import '../data/ride_model.dart';
import 'package:intl/intl.dart';

class ExpensesPage extends StatefulWidget {
  final bool isRideActive;
  final VoidCallback onToggleRide;

  const ExpensesPage({
    super.key,
    required this.isRideActive,
    required this.onToggleRide,
  });

  @override
  State<ExpensesPage> createState() => _ExpensesPageState();
}

class _ExpensesPageState extends State<ExpensesPage> {
  final TextEditingController _amountController = TextEditingController();
  List<Map<String, dynamic>> _expenses = [];
  List<Ride> _rides = [];
  List<Map<String, dynamic>> _sessions = [];
  double _totalExpenses = 0.0;
  double _totalEarned = 0.0;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final expenses = await DatabaseHelper().getActiveExpenses();
    final rides = await DatabaseHelper().getActiveRides();
    final sessions = await DatabaseHelper().getAllSessions();

    double tExp = 0;
    for (var e in expenses) tExp += e['amount_da'];
    double tEarned = 0;
    for (var r in rides) tEarned += r.earnedDa;

    setState(() {
      _expenses = expenses;
      _rides = rides;
      _sessions = sessions;
      _totalExpenses = tExp;
      _totalEarned = tEarned;
    });
  }

  void _archiveSession() async {
    if (_rides.isEmpty && _expenses.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Rien à sauvegarder pour l'instant")));
      return;
    }

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF151828),
        title: const Text("Clôturer la session ?", style: TextStyle(color: Colors.white)),
        content: const Text("Toutes les données actuelles seront archivées dans l'historique et le compteur reviendra à zéro.", style: TextStyle(color: Colors.white70)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("ANNULER")),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            child: const Text("CLÔTURER"),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await DatabaseHelper().closeCurrentSession();
      _refresh();
    }
  }

  void _addExpense(String type) async {
    final amount = double.tryParse(_amountController.text) ?? 0;
    if (amount > 0) {
      await DatabaseHelper().insertExpense(type, amount);
      _amountController.clear();
      _refresh();
      if (mounted) Navigator.pop(context);
    }
  }

  void _showAddExpenseDialog() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF151828),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(25))),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
            bottom: MediaQuery.of(ctx).viewInsets.bottom,
            left: 20,
            right: 20,
            top: 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text("NOUVELLE DÉPENSE",
                style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 18)),
            const SizedBox(height: 20),
            TextField(
              controller: _amountController,
              keyboardType: TextInputType.number,
              autofocus: true,
              style: const TextStyle(color: Colors.white, fontSize: 28),
              textAlign: TextAlign.center,
              decoration: const InputDecoration(
                hintText: "0 DA",
                hintStyle: TextStyle(color: Colors.white24),
                enabledBorder: UnderlineInputBorder(
                    borderSide: BorderSide(color: const Color(0xFFFF3333))),
                focusedBorder: UnderlineInputBorder(
                    borderSide:
                        BorderSide(color: const Color(0xFFFF3333), width: 2)),
              ),
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () => _addExpense('FUEL'),
                    icon: const Icon(Icons.local_gas_station),
                    label: const Text("PLEIN ESSENCE"),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.orangeAccent,
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () => _addExpense('CREDIT'),
                    icon: const Icon(Icons.account_balance_wallet),
                    label: const Text("CRÉDIT INDRIVE"),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.greenAccent,
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final netProfit = _totalEarned - _totalExpenses;
    final totalKm =
        _rides.fold<double>(0, (sum, r) => sum + r.distanceKm);
    final totalFuel =
        _rides.fold<double>(0, (sum, r) => sum + r.fuelLiters);

    return Scaffold(
      backgroundColor: const Color(0xFF050505),
      appBar: AppBar(
        title: const Text("Business du Jour",
            style: TextStyle(color: Colors.white, fontSize: 16)),
        backgroundColor: const Color(0xFF0F0F0F),
        iconTheme: const IconThemeData(color: const Color(0xFFFF3333)),
        actions: [
          IconButton(
              onPressed: _archiveSession,
              icon: const Icon(Icons.save_alt, color: Colors.orangeAccent),
              tooltip: "Clôturer et Archiver"),
          IconButton(
              onPressed: _refresh,
              icon: const Icon(Icons.refresh, color: const Color(0xFFFF3333)))
        ],
      ),
      body: Column(
        children: [
          // ─── Bouton Course ───────────────────────────────────────────
          Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: ElevatedButton.icon(
              onPressed: () {
                widget.onToggleRide();
                Navigator.pop(context);
              },
              icon: Icon(widget.isRideActive
                  ? Icons.stop_circle_outlined
                  : Icons.play_circle_fill),
              label: Text(
                widget.isRideActive
                    ? "TERMINER LA COURSE"
                    : "DÉMARRER UNE COURSE",
                style: const TextStyle(
                    fontWeight: FontWeight.bold, letterSpacing: 1),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor:
                    widget.isRideActive ? Colors.redAccent : Colors.greenAccent,
                foregroundColor: Colors.black,
                minimumSize: const Size(double.infinity, 52),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
              ),
            ),
          ),

          // ─── Résumé Financier ────────────────────────────────────────
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF101520),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.greenAccent.withOpacity(0.2)),
            ),
            child: Column(
              children: [
                const Text("BÉNÉFICE NET DU JOUR",
                    style: TextStyle(
                        color: Colors.grey, fontSize: 10, letterSpacing: 3)),
                const SizedBox(height: 6),
                Text(
                  "${netProfit >= 0 ? '+' : ''}${netProfit.toStringAsFixed(0)} DA",
                  style: TextStyle(
                    color: netProfit >= 0 ? Colors.greenAccent : Colors.redAccent,
                    fontSize: 40,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    _buildStat("ENCAISSÉ",
                        "+${_totalEarned.toStringAsFixed(0)} DA", Colors.white),
                    _buildDivider(),
                    _buildStat("DÉPENSES",
                        "-${_totalExpenses.toStringAsFixed(0)} DA",
                        Colors.redAccent),
                    _buildDivider(),
                    _buildStat(
                        "COURSES", "${_rides.length}", const Color(0xFFFF3333)),
                    _buildDivider(),
                    _buildStat(
                        "KM", totalKm.toStringAsFixed(1), Colors.purpleAccent),
                    _buildDivider(),
                    _buildStat("CARBURANT",
                        "${totalFuel.toStringAsFixed(1)} L", Colors.orangeAccent),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // ─── Onglets Courses / Dépenses ──────────────────────────────
          Expanded(
            child: DefaultTabController(
              length: 2,
              child: Column(
                children: [
                  TabBar(
                    labelColor: const Color(0xFFFF3333),
                    unselectedLabelColor: Colors.grey,
                    indicatorColor: const Color(0xFFFF3333),
                    tabs: [
                      Tab(text: "COURSES (${_rides.length})"),
                      Tab(text: "DÉPENSES (${_expenses.length})"),
                    ],
                  ),
                  Expanded(
                    child: TabBarView(
                      children: [
                        _buildRidesList(),
                        _buildExpensesList(),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),

          // ─── Historique des Sessions ─────────────────────────────────
          if (_sessions.isNotEmpty) ...[
            const Divider(color: Colors.white10, height: 1),
            Container(
              height: 180,
              color: Colors.black,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Text("SESSIONS ARCHIVÉES",
                        style: TextStyle(
                            color: Colors.grey,
                            fontSize: 10,
                            letterSpacing: 2,
                            fontWeight: FontWeight.bold)),
                  ),
                  Expanded(
                    child: ListView.builder(
                      itemCount: _sessions.length,
                      itemBuilder: (context, index) {
                        final s = _sessions[index];
                        final start = DateTime.fromMillisecondsSinceEpoch(
                            s['start_timestamp']);
                        final end = DateTime.fromMillisecondsSinceEpoch(
                            s['end_timestamp']);
                        final profit = s['total_earned'] - s['total_spent'];

                        return Container(
                          margin: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 4),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: const Color(0xFF0F0F0F),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Colors.white10),
                          ),
                          child: Row(
                            children: [
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                      DateFormat('dd MMM HH:mm').format(start) +
                                          " ➔ " +
                                          DateFormat('HH:mm').format(end),
                                      style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 12,
                                          fontWeight: FontWeight.bold)),
                                  Text(
                                      "${s['total_km'].toStringAsFixed(1)} KM • ${s['total_fuel'].toStringAsFixed(1)} L",
                                      style: const TextStyle(
                                          color: Colors.white38, fontSize: 10)),
                                ],
                              ),
                              const Spacer(),
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Text("${profit.toStringAsFixed(0)} DA",
                                      style: TextStyle(
                                          color: profit >= 0
                                              ? Colors.greenAccent
                                              : Colors.redAccent,
                                          fontWeight: FontWeight.bold)),
                                  Text(
                                      "${s['total_earned'].toStringAsFixed(0)} DA encaissés",
                                      style: const TextStyle(
                                          color: Colors.white24, fontSize: 9)),
                                ],
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showAddExpenseDialog,
        backgroundColor: const Color(0xFFFF3333),
        foregroundColor: Colors.black,
        icon: const Icon(Icons.add),
        label: const Text("DÉPENSE",
            style: TextStyle(fontWeight: FontWeight.bold)),
      ),
    );
  }

  Widget _buildStat(String label, String value, Color color) {
    return Expanded(
      child: Column(
        children: [
          Text(label,
              style: const TextStyle(
                  color: Colors.grey, fontSize: 8, letterSpacing: 1)),
          const SizedBox(height: 3),
          Text(value,
              style: TextStyle(
                  color: color,
                  fontSize: 12,
                  fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  Widget _buildDivider() {
    return Container(width: 1, height: 28, color: Colors.white10);
  }

  Widget _buildRidesList() {
    if (_rides.isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.directions_car_outlined,
                color: Colors.white24, size: 48),
            SizedBox(height: 12),
            Text("Aucune course aujourd'hui",
                style: TextStyle(color: Colors.white24)),
          ],
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 90, top: 8),
      itemCount: _rides.length,
      itemBuilder: (ctx, i) {
        final r = _rides[i];
        final start = DateTime.fromMillisecondsSinceEpoch(r.startTime);
        final end = DateTime.fromMillisecondsSinceEpoch(r.endTime);
        final dur = end.difference(start).inMinutes;
        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          decoration: BoxDecoration(
            color: const Color(0xFF0E1220),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.greenAccent.withOpacity(0.12)),
          ),
          child: ListTile(
            leading: CircleAvatar(
              backgroundColor: Colors.greenAccent.withOpacity(0.1),
              child: Text('${i + 1}',
                  style: const TextStyle(
                      color: Colors.greenAccent,
                      fontWeight: FontWeight.bold)),
            ),
            title: Text(
              '${DateFormat('HH:mm').format(start)} → ${DateFormat('HH:mm').format(end)}  ($dur min)',
              style: const TextStyle(color: Colors.white, fontSize: 13),
            ),
            subtitle: Text(
              '${r.distanceKm.toStringAsFixed(1)} km  •  ${r.fuelLiters.toStringAsFixed(2)} L carburant',
              style: const TextStyle(color: Colors.grey, fontSize: 11),
            ),
            trailing: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text('+${r.earnedDa.toStringAsFixed(0)} DA',
                    style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 15)),
                Text(
                    'Net: ${r.profitDa >= 0 ? '+' : ''}${r.profitDa.toStringAsFixed(0)} DA',
                    style: TextStyle(
                        color: r.profitDa >= 0
                            ? Colors.greenAccent
                            : Colors.redAccent,
                        fontSize: 11)),
              ],
            ),
            onLongPress: () async {
              final confirm = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  backgroundColor: const Color(0xFF151828),
                  title: const Text('Supprimer cette course ?',
                      style: TextStyle(color: Colors.white)),
                  content: const Text(
                      'Appui long pour supprimer. Cette action est irréversible.',
                      style: TextStyle(color: Colors.grey, fontSize: 12)),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('ANNULER',
                            style: TextStyle(color: Colors.grey))),
                    TextButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: const Text('SUPPRIMER',
                            style: TextStyle(color: Colors.redAccent))),
                  ],
                ),
              );
              if (confirm == true) {
                await DatabaseHelper().deleteRide(r.id!);
                _refresh();
              }
            },
          ),
        );
      },
    );
  }

  Widget _buildExpensesList() {
    if (_expenses.isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.receipt_long_outlined,
                color: Colors.white24, size: 48),
            SizedBox(height: 12),
            Text("Aucune dépense enregistrée",
                style: TextStyle(color: Colors.white24)),
          ],
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 90, top: 8),
      itemCount: _expenses.length,
      itemBuilder: (ctx, i) {
        final e = _expenses[i];
        final isFuel = e['type'] == 'FUEL';
        return ListTile(
          leading: CircleAvatar(
            backgroundColor:
                (isFuel ? Colors.orangeAccent : Colors.greenAccent)
                    .withOpacity(0.15),
            child: Icon(
              isFuel
                  ? Icons.local_gas_station
                  : Icons.account_balance_wallet,
              color:
                  isFuel ? Colors.orangeAccent : Colors.greenAccent,
              size: 20,
            ),
          ),
          title: Text(isFuel ? "Plein d'essence" : "Recharge inDrive",
              style: const TextStyle(color: Colors.white)),
          subtitle: Text(
            DateFormat('HH:mm').format(
                DateTime.fromMillisecondsSinceEpoch(e['timestamp'])),
            style: const TextStyle(color: Colors.white38, fontSize: 11),
          ),
          trailing: Text(
            "- ${e['amount_da'].toStringAsFixed(0)} DA",
            style: const TextStyle(
                color: Colors.redAccent,
                fontWeight: FontWeight.bold,
                fontSize: 16),
          ),
          onLongPress: () async {
            await DatabaseHelper().deleteExpense(e['id']);
            _refresh();
          },
        );
      },
    );
  }
}
