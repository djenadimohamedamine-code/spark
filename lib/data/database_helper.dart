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
      version: 1,
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
      },
    );
  }

  // ── Insérer une course ───────────────────────────────────────────────────
  Future<int> insertRide(Ride ride) async {
    final db = await database;
    return db.insert('rides', ride.toMap());
  }

  // ── Courses d'un jour donné ──────────────────────────────────────────────
  Future<List<Ride>> getRidesForDate(String date) async {
    final db = await database;
    final maps = await db.query('rides', where: 'date = ?', whereArgs: [date], orderBy: 'start_time ASC');
    return maps.map((m) => Ride.fromMap(m)).toList();
  }

  // ── Toutes les courses (pour historique) ────────────────────────────────
  Future<List<Ride>> getAllRides() async {
    final db = await database;
    final maps = await db.query('rides', orderBy: 'start_time DESC');
    return maps.map((m) => Ride.fromMap(m)).toList();
  }

  // ── Supprimer une course ─────────────────────────────────────────────────
  Future<void> deleteRide(int id) async {
    final db = await database;
    await db.delete('rides', where: 'id = ?', whereArgs: [id]);
  }
}
