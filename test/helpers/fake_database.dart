import 'dart:async';
import 'package:sqflite/sqflite.dart';

/// Simulateur SQLite haute-fidélité en mémoire pure Dart.
/// Permet de tester unitairement et exhaustivement les transactions, les migrations
/// et la cohérence de DatabaseHelper sans dépendance binaire externe.
class FakeDatabase implements Database {
  final Map<String, List<Map<String, dynamic>>> tables = {};
  final Map<String, int> autoIncrements = {};

  FakeDatabase() {
    tables['rides'] = [];
    tables['expenses'] = [];
    tables['sessions'] = [];
    tables['fuel_refills'] = [];
    tables['fuel_state'] = [];
    autoIncrements['rides'] = 1;
    autoIncrements['expenses'] = 1;
    autoIncrements['sessions'] = 1;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  @override
  Future<void> execute(String sql, [List<Object?>? arguments]) async {
    if (sql.contains('CREATE TABLE IF NOT EXISTS fuel_state') || sql.contains('CREATE TABLE fuel_state')) {
      tables.putIfAbsent('fuel_state', () => []);
    } else if (sql.contains('CREATE TABLE fuel_refills')) {
      tables.putIfAbsent('fuel_refills', () => []);
    } else if (sql.contains('ALTER TABLE fuel_refills ADD COLUMN status')) {
      tables['_has_status_col'] = [];
      for (var row in tables['fuel_refills'] ?? []) {
        row.putIfAbsent('status', () => 'committed');
      }
    } else if (sql.contains("UPDATE fuel_refills SET status = 'canceled' WHERE canceled = 1")) {
      for (var row in tables['fuel_refills'] ?? []) {
        if (row['canceled'] == 1) {
          row['status'] = 'canceled';
        }
      }
    } else if (sql.contains('ALTER TABLE fuel_state ADD COLUMN is_calibrated')) {
      tables['_has_is_calibrated_col'] = [];
      for (var row in tables['fuel_state'] ?? []) {
        row.putIfAbsent('is_calibrated', () => 0);
      }
    } else if (sql.contains('UPDATE fuel_state SET is_calibrated = CASE WHEN event_type =')) {
      for (var row in tables['fuel_state'] ?? []) {
        if (row['event_type'] == 'UNCALIBRATED') {
          row['is_calibrated'] = 0;
        } else {
          row['is_calibrated'] = 1;
        }
      }
    }
  }

  @override
  Future<List<Map<String, Object?>>> rawQuery(String sql, [List<Object?>? arguments]) async {
    if (sql.contains('PRAGMA table_info(fuel_refills)')) {
      final sample = tables['fuel_refills']?.isNotEmpty == true ? tables['fuel_refills']!.first : <String, dynamic>{};
      final cols = <Map<String, Object?>>[
        {'name': 'id'},
        {'name': 'timestamp'},
        {'name': 'liters'},
        {'name': 'price_per_liter'},
        {'name': 'total_amount'},
        {'name': 'level_before'},
        {'name': 'level_after'},
        {'name': 'canceled'},
      ];
      if (sample.containsKey('status') || tables.containsKey('_has_status_col')) {
        cols.add({'name': 'status'});
      }
      return cols;
    } else if (sql.contains('PRAGMA table_info(fuel_state)')) {
      final sample = tables['fuel_state']?.isNotEmpty == true ? tables['fuel_state']!.first : <String, dynamic>{};
      final cols = <Map<String, Object?>>[
        {'name': 'id'},
        {'name': 'liters'},
        {'name': 'updated_at'},
        {'name': 'event_type'},
        {'name': 'reference_id'},
        {'name': 'last_calib_ts'},
      ];
      if (sample.containsKey('is_calibrated') || tables.containsKey('_has_is_calibrated_col')) {
        cols.add({'name': 'is_calibrated'});
      }
      return cols;
    }
    return [];
  }

  @override
  Future<int> rawUpdate(String sql, [List<Object?>? arguments]) async {
    if (sql.contains('UPDATE sessions SET total_spent = total_spent - ? WHERE id = ?')) {
      final amount = (arguments![0] as num).toDouble();
      final id = arguments[1] as int;
      for (var s in tables['sessions'] ?? []) {
        if (s['id'] == id) {
          s['total_spent'] = (s['total_spent'] as num).toDouble() - amount;
          return 1;
        }
      }
    } else if (sql.contains('UPDATE fuel_state')) {
      final list = tables['fuel_state'] ?? [];
      for (var row in list) {
        if (row['id'] == 1) {
          final existingTs = row['updated_at'] as int? ?? 0;
          final existingEvent = row['event_type'] as String? ?? '';
          final newLiters = (arguments![0] as num).toDouble();
          final newTs = arguments[1] as int;
          final newEvent = arguments[2] as String;
          final newRef = arguments[3] as String?;
          final calibArg = arguments[4] as int?;
          final isCalibratedArg = arguments[6] as int?;

          bool allowed = false;
          if (newTs > existingTs) {
            allowed = true;
          } else if (newTs == existingTs) {
            final isNewPriority = (newEvent == 'REFILL' || newEvent == 'CALIBRATION');
            final isExistingPriority = (existingEvent == 'REFILL' || existingEvent == 'CALIBRATION');
            if (isNewPriority || !isExistingPriority) {
              allowed = true;
            }
          }

          if (allowed) {
            row['liters'] = newLiters;
            row['updated_at'] = newTs;
            row['event_type'] = newEvent;
            row['reference_id'] = newRef;
            if (calibArg != null) {
              row['last_calib_ts'] = calibArg;
            }
            if (isCalibratedArg != null) {
              row['is_calibrated'] = isCalibratedArg;
            }
            return 1;
          }
          return 0;
        }
      }
    }
    return 0;
  }

  @override
  Future<int> insert(
    String table,
    Map<String, Object?> values, {
    String? nullColumnHack,
    ConflictAlgorithm? conflictAlgorithm,
  }) async {
    final list = tables.putIfAbsent(table, () => []);
    final row = Map<String, dynamic>.from(values);
    if (!row.containsKey('id') && autoIncrements.containsKey(table)) {
      row['id'] = autoIncrements[table]!;
      autoIncrements[table] = autoIncrements[table]! + 1;
    }

    if (conflictAlgorithm == ConflictAlgorithm.replace || table == 'fuel_state') {
      final key = row.containsKey('id') ? 'id' : null;
      if (key != null) {
        final idx = list.indexWhere((r) => r[key] == row[key]);
        if (idx != -1) {
          list[idx] = row;
          return (row['id'] is int) ? row['id'] as int : 1;
        }
      }
    }
    list.add(row);
    return (row['id'] is int) ? row['id'] as int : list.length;
  }

  @override
  Future<List<Map<String, Object?>>> query(
    String table, {
    bool? distinct,
    List<String>? columns,
    String? where,
    List<Object?>? whereArgs,
    String? groupBy,
    String? having,
    String? orderBy,
    int? limit,
    int? offset,
  }) async {
    final list = tables[table] ?? [];
    var results = list.where((row) {
      if (where == null) return true;
      if (where == 'id = 1') return row['id'] == 1;
      if (where == 'id = ?') return row['id'] == whereArgs![0];
      if (where == 'expense_id = ?') return row['expense_id'] == whereArgs![0];
      if (where == 'session_id IS NULL') return row['session_id'] == null;
      if (where == 'session_id = ?') return row['session_id'] == whereArgs![0];
      if (where == 'canceled = 0') return row['canceled'] == 0;
      if (where == 'id = ? AND canceled = 0') {
        return row['id'] == whereArgs![0] && row['canceled'] == 0;
      }
      if (where == 'date = ?') return row['date'] == whereArgs![0];
      return true;
    }).map((r) => Map<String, Object?>.from(r)).toList();

    if (limit != null && results.length > limit) {
      results = results.sublist(0, limit);
    }

    return results;
  }

  @override
  Future<int> update(
    String table,
    Map<String, Object?> values, {
    String? where,
    List<Object?>? whereArgs,
    ConflictAlgorithm? conflictAlgorithm,
  }) async {
    final list = tables[table] ?? [];
    int count = 0;
    for (var row in list) {
      bool matches = false;
      if (where == null) {
        matches = true;
      } else if (where == 'id = ? AND canceled = 0') {
        matches = row['id'] == whereArgs![0] && row['canceled'] == 0;
      } else if (where == 'session_id IS NULL') {
        matches = row['session_id'] == null;
      } else if (where == 'id = ?') {
        matches = row['id'] == whereArgs![0];
      } else if (where == 'canceled = 1') {
        matches = row['canceled'] == 1;
      }
      if (matches) {
        row.addAll(values);
        count++;
      }
    }
    return count;
  }

  @override
  Future<int> delete(String table, {String? where, List<Object?>? whereArgs}) async {
    final list = tables[table] ?? [];
    int initialLen = list.length;
    list.removeWhere((row) {
      if (where == 'id = ?') return row['id'] == whereArgs![0];
      return false;
    });
    return initialLen - list.length;
  }

  @override
  Future<T> transaction<T>(Future<T> Function(Transaction txn) action, {bool? exclusive}) async {
    final fakeTxn = FakeTransaction(this);
    return await action(fakeTxn);
  }
}

class FakeTransaction implements Transaction {
  final FakeDatabase db;
  FakeTransaction(this.db);

  @override
  dynamic noSuchMethod(Invocation invocation) => db.noSuchMethod(invocation);

  @override
  Future<int> insert(
    String table,
    Map<String, Object?> values, {
    String? nullColumnHack,
    ConflictAlgorithm? conflictAlgorithm,
  }) => db.insert(table, values, nullColumnHack: nullColumnHack, conflictAlgorithm: conflictAlgorithm);

  @override
  Future<List<Map<String, Object?>>> query(
    String table, {
    bool? distinct,
    List<String>? columns,
    String? where,
    List<Object?>? whereArgs,
    String? groupBy,
    String? having,
    String? orderBy,
    int? limit,
    int? offset,
  }) => db.query(
        table,
        distinct: distinct,
        columns: columns,
        where: where,
        whereArgs: whereArgs,
        groupBy: groupBy,
        having: having,
        orderBy: orderBy,
        limit: limit,
        offset: offset,
      );

  @override
  Future<int> update(
    String table,
    Map<String, Object?> values, {
    String? where,
    List<Object?>? whereArgs,
    ConflictAlgorithm? conflictAlgorithm,
  }) => db.update(table, values, where: where, whereArgs: whereArgs, conflictAlgorithm: conflictAlgorithm);

  @override
  Future<int> delete(String table, {String? where, List<Object?>? whereArgs}) =>
      db.delete(table, where: where, whereArgs: whereArgs);

  @override
  Future<int> rawUpdate(String sql, [List<Object?>? arguments]) =>
      db.rawUpdate(sql, arguments);

  @override
  Future<List<Map<String, Object?>>> rawQuery(String sql, [List<Object?>? arguments]) =>
      db.rawQuery(sql, arguments);

  @override
  Future<void> execute(String sql, [List<Object?>? arguments]) =>
      db.execute(sql, arguments);
}
