import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../models/runtime_task_snapshot.dart';
import '../models/work_state.dart';
import 'runtime_event_bus.dart';
import 'runtime_task_store.dart';

class SQLiteRuntimePersistenceStore implements RuntimePersistenceStore {
  SQLiteRuntimePersistenceStore({Database? database})
      : _databaseOverride = database;

  final Database? _databaseOverride;
  Database? _database;

  @override
  Future<RuntimeTaskSnapshot?> loadTask(String taskId) async {
    final rows = await _dbQuery(
      'runtime_tasks',
      where: 'task_id = ?',
      whereArgs: [taskId],
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }
    return RuntimeTaskSnapshot.fromJson(_decodePayload(rows.single));
  }

  @override
  Future<List<RuntimeTaskSnapshot>> loadTasks() async {
    final rows = await _dbQuery(
      'runtime_tasks',
      orderBy: 'updated_at DESC',
    );
    return rows
        .map(_decodePayload)
        .map(RuntimeTaskSnapshot.fromJson)
        .toList(growable: false);
  }

  @override
  Future<void> saveTask(RuntimeTaskSnapshot task) async {
    final db = await _db();
    await db.insert(
      'runtime_tasks',
      {
        'task_id': task.taskId,
        'updated_at': task.updatedAt.toIso8601String(),
        'payload': jsonEncode(task.toJson()),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<void> saveEvent(RuntimeEvent event) async {
    final db = await _db();
    await db.insert('runtime_events', {
      'task_id': event.taskId,
      'type': event.type.wireName,
      'created_at': event.createdAt.toIso8601String(),
      'payload': jsonEncode(event.toJson()),
    });
  }

  @override
  Future<List<RuntimeEvent>> loadEvents({String? taskId, int? limit}) async {
    final rows = await _dbQuery(
      'runtime_events',
      where: taskId == null ? null : 'task_id = ?',
      whereArgs: taskId == null ? null : [taskId],
      orderBy: 'id DESC',
      limit: limit,
    );
    return rows.reversed
        .map(_decodePayload)
        .map(RuntimeEvent.fromJson)
        .toList(growable: false);
  }

  @override
  Future<void> saveWorkState(WorkState state) async {
    final task = await loadTask(state.taskId);
    if (task != null) await saveTask(task.copyWith(workState: state));
  }

  @override
  Future<WorkState?> loadWorkState(String taskId) async {
    return (await loadTask(taskId))?.workState;
  }

  @override
  Future<List<WorkState>> loadWorkStates() async {
    return (await loadTasks())
        .map((task) => task.workState)
        .whereType<WorkState>()
        .toList(growable: false);
  }

  Future<List<Map<String, Object?>>> _dbQuery(
    String table, {
    String? where,
    List<Object?>? whereArgs,
    String? orderBy,
    int? limit,
  }) async {
    final db = await _db();
    return db.query(
      table,
      where: where,
      whereArgs: whereArgs,
      orderBy: orderBy,
      limit: limit,
    );
  }

  Future<Database> _db() async {
    if (_databaseOverride != null) {
      return _databaseOverride;
    }
    if (_database != null) {
      return _database!;
    }
    final root = await getDatabasesPath();
    final separator = root.endsWith('/') ? '' : '/';
    _database = await openDatabase(
      '$root${separator}armin_runtime.db',
      version: 4,
      onCreate: (db, _) async {
        await _createSchema(db);
      },
      onUpgrade: (db, _, __) => _resetSchema(db),
    );
    return _database!;
  }

  Future<void> _createSchema(Database db) async {
    await db.execute('''
CREATE TABLE IF NOT EXISTS runtime_tasks (
  task_id TEXT PRIMARY KEY,
  updated_at TEXT NOT NULL,
  payload TEXT NOT NULL
)
''');
    await db.execute('''
CREATE TABLE IF NOT EXISTS runtime_events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  task_id TEXT NOT NULL,
  type TEXT NOT NULL,
  created_at TEXT NOT NULL,
  payload TEXT NOT NULL
)
''');
    await _createHistoryTables(db);
  }

  Future<void> _resetSchema(Database db) async {
    for (final table in [
      'runtime_tasks',
      'runtime_events',
      'runtime_work_states',
      'hosts',
      'task_sessions',
      'project_paths',
    ]) {
      await db.execute('DROP TABLE IF EXISTS $table');
    }
    await _createSchema(db);
  }

  Future<void> _createHistoryTables(Database db) async {
    await db.execute('''
CREATE TABLE IF NOT EXISTS hosts (
  host_id TEXT PRIMARY KEY,
  updated_at TEXT NOT NULL,
  payload TEXT NOT NULL
)
''');
    await db.execute('''
CREATE TABLE IF NOT EXISTS task_sessions (
  task_id TEXT PRIMARY KEY,
  updated_at TEXT NOT NULL,
  payload TEXT NOT NULL
)
''');
    await db.execute('''
CREATE TABLE IF NOT EXISTS project_paths (
  project_path_id TEXT PRIMARY KEY,
  updated_at TEXT NOT NULL,
  payload TEXT NOT NULL
)
''');
  }

  /// Exposed for composite stores sharing the same database.
  Future<Database> sharedDb() => _db();

  Map<String, Object?> _decodePayload(Map<String, Object?> row) {
    final payload = row['payload'];
    if (payload is! String || payload.trim().isEmpty) {
      return const {};
    }
    final decoded = jsonDecode(payload);
    if (decoded is Map) {
      return _normalizeMap(decoded);
    }
    return const {};
  }

  Map<String, Object?> _normalizeMap(Map<Object?, Object?> map) {
    return map.map((key, value) {
      return MapEntry(key.toString(), _normalizeValue(value));
    });
  }

  Object? _normalizeValue(Object? value) {
    if (value is Map) {
      return _normalizeMap(value);
    }
    if (value is List) {
      return value.map(_normalizeValue).toList(growable: false);
    }
    return value;
  }
}
