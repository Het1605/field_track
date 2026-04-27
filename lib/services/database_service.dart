import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

/// Service to handle local SQLite storage for offline tracking
class DatabaseService {
  static Database? _database;

  /// Singleton pattern to ensure only one database instance exists
  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB();
    return _database!;
  }

  /// Initialize the SQLite database
  Future<Database> _initDB() async {
    String path = join(await getDatabasesPath(), 'field_track.db');
    return await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        // Create table for storing location points locally
        await db.execute('''
          CREATE TABLE locations(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            journey_id TEXT NOT NULL,
            latitude REAL NOT NULL,
            longitude REAL NOT NULL,
            recorded_at TEXT NOT NULL
          )
        ''');
      },
    );
  }

  /// Saves a single location point to the local database
  Future<int> saveLocation({
    required String journeyId,
    required double latitude,
    required double longitude,
    required String recordedAt,
  }) async {
    final db = await database;
    return await db.insert('locations', {
      'journey_id': journeyId,
      'latitude': latitude,
      'longitude': longitude,
      'recorded_at': recordedAt,
    });
  }

  /// Retrieves all stored location points that haven't been synced
  Future<List<Map<String, dynamic>>> getAllStoredLocations() async {
    final db = await database;
    return await db.query('locations', orderBy: 'recorded_at ASC');
  }

  /// Deletes a batch of records from the database using their primary IDs
  Future<void> deleteSyncedRecords(List<int> ids) async {
    if (ids.isEmpty) return;
    final db = await database;
    await db.delete(
      'locations',
      where: 'id IN (${ids.join(',')})',
    );
  }

  /// Clears all records for a specific journey (optional cleanup)
  Future<void> clearJourneyData(String journeyId) async {
    final db = await database;
    await db.delete(
      'locations',
      where: 'journey_id = ?',
      whereArgs: [journeyId],
    );
  }
}
