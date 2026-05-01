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
      version: 3, // Montée en version pour le système de Sessions
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE sessions (
            id              INTEGER PRIMARY KEY AUTOINCREMENT,
            start_timestamp INTEGER NOT NULL,
            end_timestamp   INTEGER NOT NULL,
            total_earned    REAL NOT NULL,
            total_spent     REAL NOT NULL,
            total_km        REAL NOT NULL,
            total_fuel      REAL NOT NULL
          )
        ''');
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
            distance_km  REAL NOT NULL,
            session_id   INTEGER -- Pour l'archivage
          )
        ''');
        await db.execute('''
          CREATE TABLE expenses (
            id           INTEGER PRIMARY KEY AUTOINCREMENT,
            date         TEXT NOT NULL,
            type         TEXT NOT NULL,
            amount_da    REAL NOT NULL,
            timestamp    INTEGER NOT NULL,
            session_id   INTEGER -- Pour l'archivage
          )
        ''');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute('CREATE TABLE expenses (id INTEGER PRIMARY KEY AUTOINCREMENT, date TEXT NOT NULL, type TEXT NOT NULL, amount_da REAL NOT NULL, timestamp INTEGER NOT NULL)');
        }
        if (oldVersion < 3) {
          await db.execute('CREATE TABLE sessions (id INTEGER PRIMARY KEY AUTOINCREMENT, start_timestamp INTEGER NOT NULL, end_timestamp INTEGER NOT NULL, total_earned REAL NOT NULL, total_spent REAL NOT NULL, total_km REAL NOT NULL, total_fuel REAL NOT NULL)');
          await db.execute('ALTER TABLE rides ADD COLUMN session_id INTEGER');
          await db.execute('ALTER TABLE expenses ADD COLUMN session_id INTEGER');
        }
      },
    );
  }

  Future<int> insertRide(Ride ride) async {
    final db = await database;
    return db.insert('rides', ride.toMap());
  }

  Future<List<Ride>> getActiveRides() async {
    final db = await database;
    final maps = await db.query('rides', where: 'session_id IS NULL', orderBy: 'start_time ASC');
    return maps.map((m) => Ride.fromMap(m)).toList();
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

  Future<List<Map<String, dynamic>>> getActiveExpenses() async {
    final db = await database;
    return db.query('expenses', where: 'session_id IS NULL', orderBy: 'timestamp ASC');
  }

  Future<List<Map<String, dynamic>>> getExpensesForDate(String date) async {
    final db = await database;
    return db.query('expenses', where: 'date = ?', whereArgs: [date]);
  }

  // ── Session Archiving ───────────────────────────────────────────────────
  Future<void> closeCurrentSession() async {
    final db = await database;
    
    // 1. Calculer les totaux de la session active
    final rides = await getActiveRides();
    final expenses = await getActiveExpenses();
    
    if (rides.isEmpty && expenses.isEmpty) return; // Rien à clôturer
    
    double totalEarned = 0;
    double totalKm = 0;
    double totalFuel = 0;
    for (var r in rides) {
      totalEarned += r.earnedDa;
      totalKm += r.distanceKm;
      totalFuel += r.fuelLiters;
    }
    
    double totalSpent = 0;
    for (var e in expenses) {
      totalSpent += e['amount_da'];
    }
    
    int startTs = rides.isNotEmpty ? rides.first.startTime : (expenses.isNotEmpty ? expenses.first['timestamp'] : DateTime.now().millisecondsSinceEpoch);
    int endTs = DateTime.now().millisecondsSinceEpoch;

    // 2. Créer l'entrée de session
    int sessionId = await db.insert('sessions', {
      'start_timestamp': startTs,
      'end_timestamp': endTs,
      'total_earned': totalEarned,
      'total_spent': totalSpent,
      'total_km': totalKm,
      'total_fuel': totalFuel,
    });

    // 3. Lier les records à cette session
    await db.update('rides', {'session_id': sessionId}, where: 'session_id IS NULL');
    await db.update('expenses', {'session_id': sessionId}, where: 'session_id IS NULL');
  }

  Future<List<Map<String, dynamic>>> getAllSessions() async {
    final db = await database;
    return db.query('sessions', orderBy: 'end_timestamp DESC');
  }

  Future<List<Ride>> getRidesForSession(int sessionId) async {
    final db = await database;
    final maps = await db.query('rides', where: 'session_id = ?', whereArgs: [sessionId]);
    return maps.map((m) => Ride.fromMap(m)).toList();
  }

  Future<List<Map<String, dynamic>>> getExpensesForSession(int sessionId) async {
    final db = await database;
    return db.query('expenses', where: 'session_id = ?', whereArgs: [sessionId]);
  }

  Future<void> deleteExpense(int id) async {
    final db = await database;
    await db.delete('expenses', where: 'id = ?', whereArgs: [id]);
  }
}
