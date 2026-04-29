import 'package:flutter/material.dart';
import '../data/database_helper.dart';
import 'package:intl/intl.dart';

class ExpensesPage extends StatefulWidget {
  const ExpensesPage({super.key});

  @override
  State<ExpensesPage> createState() => _ExpensesPageState();
}

class _ExpensesPageState extends State<ExpensesPage> {
  final TextEditingController _amountController = TextEditingController();
  List<Map<String, dynamic>> _expenses = [];
  double _total = 0.0;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final date = DateFormat('yyyy-MM-dd').format(DateTime.now());
    final data = await DatabaseHelper().getExpensesForDate(date);
    double t = 0;
    for (var e in data) {
      t += e['amount_da'];
    }
    setState(() {
      _expenses = data;
      _total = t;
    });
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

  void _showAddDialog() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF151828),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(25))),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom, left: 20, right: 20, top: 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text("NOUVELLE DÉPENSE", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18)),
            const SizedBox(height: 20),
            TextField(
              controller: _amountController,
              keyboardType: TextInputType.number,
              autofocus: true,
              style: const TextStyle(color: Colors.white, fontSize: 24),
              textAlign: TextAlign.center,
              decoration: const InputDecoration(
                hintText: "0 DA",
                hintStyle: TextStyle(color: Colors.white24),
                enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.cyanAccent)),
              ),
            ),
            const SizedBox(height: 30),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () => _addExpense('FUEL'),
                    icon: const Icon(Icons.local_gas_station),
                    label: const Text("PLEIN ESSENCE"),
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.orangeAccent, foregroundColor: Colors.black),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () => _addExpense('CREDIT'),
                    icon: const Icon(Icons.account_balance_wallet),
                    label: const Text("CRÉDIT INDRIVE"),
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.greenAccent, foregroundColor: Colors.black),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 30),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text("Dépenses du Jour"),
        backgroundColor: const Color(0xFF151828),
        actions: [
          IconButton(onPressed: _refresh, icon: const Icon(Icons.refresh))
        ],
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(30),
            decoration: const BoxDecoration(
              gradient: LinearGradient(colors: [Color(0xFF151828), Colors.black], begin: Alignment.topCenter, end: Alignment.bottomCenter),
            ),
            child: Column(
              children: [
                const Text("TOTAL DÉPENSÉ", style: TextStyle(color: Colors.grey, letterSpacing: 2)),
                const SizedBox(height: 10),
                Text("${_total.toStringAsFixed(0)} DA", style: const TextStyle(color: Colors.redAccent, fontSize: 48, fontWeight: FontWeight.bold)),
              ],
            ),
          ),
          Expanded(
            child: _expenses.isEmpty 
              ? const Center(child: Text("Aucune dépense aujourd'hui", style: TextStyle(color: Colors.white24)))
              : ListView.builder(
                  itemCount: _expenses.length,
                  itemBuilder: (ctx, i) {
                    final e = _expenses[i];
                    final isFuel = e['type'] == 'FUEL';
                    return ListTile(
                      leading: CircleAvatar(
                        backgroundColor: isFuel ? Colors.orangeAccent.withOpacity(0.2) : Colors.greenAccent.withOpacity(0.2),
                        child: Icon(isFuel ? Icons.local_gas_station : Icons.account_balance_wallet, color: isFuel ? Colors.orangeAccent : Colors.greenAccent),
                      ),
                      title: Text(isFuel ? "Plein d'essence" : "Recharge inDrive", style: const TextStyle(color: Colors.white)),
                      subtitle: Text(DateFormat('HH:mm').format(DateTime.fromMillisecondsSinceEpoch(e['timestamp'])), style: const TextStyle(color: Colors.white38)),
                      trailing: Text("- ${e['amount_da'].toStringAsFixed(0)} DA", style: const TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold, fontSize: 16)),
                      onLongPress: () async {
                        await DatabaseHelper().deleteExpense(e['id']);
                        _refresh();
                      },
                    );
                  },
                ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showAddDialog,
        backgroundColor: Colors.cyanAccent,
        foregroundColor: Colors.black,
        icon: const Icon(Icons.add),
        label: const Text("AJOUTER DÉPENSE", style: TextStyle(fontWeight: FontWeight.bold)),
      ),
    );
  }
}
