import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'ride_model.dart';

class DatabaseHelper {
  static final DatabaseHelper _instance = DatabaseHelper._internal();
  factory DatabaseHelper() => _instance;
  DatabaseHelper._internal();

  Database? _db;

  Future<Database> get database async {
    _db ??= await _initDb();
    return _db!;
  }

  Future<Database> _initDb() async {
    final path = join(await getDatabasesPath(), 'mimo_spark.db');
    return openDatabase(
      path,
      version: 2, // Montée de version pour la table expenses
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE rides (
            id           INTEGER PRIMARY KEY AUTOINCREMENT,
            date         TEXT NOT NULL,
            start_time   INTEGER NOT NULL,
            end_time     INTEGER NOT NULL,
            fuel_liters  REAL NOT NULL,
            fuel_cost_da REAL NOT NULL,
            earned_da    REAL NOT NULL,
            profit_da    REAL NOT NULL,
            distance_km  REAL NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE expenses (
            id           INTEGER PRIMARY KEY AUTOINCREMENT,
            date         TEXT NOT NULL,
            type         TEXT NOT NULL, -- 'FUEL' ou 'CREDIT'
            amount_da    REAL NOT NULL,
            timestamp    INTEGER NOT NULL
          )
        ''');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute('''
            CREATE TABLE expenses (
              id           INTEGER PRIMARY KEY AUTOINCREMENT,
              date         TEXT NOT NULL,
              type         TEXT NOT NULL,
              amount_da    REAL NOT NULL,
              timestamp    INTEGER NOT NULL
            )
          ''');
        }
      },
    );
  }

  Future<int> insertRide(Ride ride) async {
    final db = await database;
    return db.insert('rides', ride.toMap());
  }

  Future<List<Ride>> getRidesForDate(String date) async {
    final db = await database;
    final maps = await db.query('rides', where: 'date = ?', whereArgs: [date], orderBy: 'start_time ASC');
    return maps.map((m) => Ride.fromMap(m)).toList();
  }

  Future<List<Ride>> getAllRides() async {
    final db = await database;
    final maps = await db.query('rides', orderBy: 'start_time DESC');
    return maps.map((m) => Ride.fromMap(m)).toList();
  }

  Future<void> deleteRide(int id) async {
    final db = await database;
    await db.delete('rides', where: 'id = ?', whereArgs: [id]);
  }

  // ── Gestion des dépenses ────────────────────────────────────────────────
  Future<int> insertExpense(String type, double amount) async {
    final db = await database;
    final now = DateTime.now();
    final dateStr = '${now.year}-${now.month.toString().padLeft(2,'0')}-${now.day.toString().padLeft(2,'0')}';
    return db.insert('expenses', {
      'date': dateStr,
      'type': type,
      'amount_da': amount,
      'timestamp': now.millisecondsSinceEpoch,
    });
  }

  Future<List<Map<String, dynamic>>> getExpensesForDate(String date) async {
    final db = await database;
    return db.query('expenses', where: 'date = ?', whereArgs: [date]);
  }

  Future<void> deleteExpense(int id) async {
    final db = await database;
    await db.delete('expenses', where: 'id = ?', whereArgs: [id]);
  }
}
