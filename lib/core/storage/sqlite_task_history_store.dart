import 'dart:convert';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../../features/hosts/models/host_config.dart';
import '../../features/projects/models/project_path_config.dart';
import '../../features/runtime/services/sqlite_runtime_persistence_store.dart';
import '../../features/tasks/models/task_session.dart';
import 'secure_password_store.dart';
import 'task_history_store.dart';

/// SQLite-backed implementation of [TaskHistoryStore].
///
/// Shares the `armin_runtime.db` database owned by
/// [SQLiteRuntimePersistenceStore]. The runtime store must be initialized
/// first so the history tables already exist.
class SQLiteTaskHistoryStore extends TaskHistoryStore {
  SQLiteTaskHistoryStore({
    required SQLiteRuntimePersistenceStore runtimeStore,
    SecurePasswordStore? passwordStore,
  })  : _runtimeStore = runtimeStore,
        _passwordStore = passwordStore ?? SecurePasswordStore();

  final SQLiteRuntimePersistenceStore _runtimeStore;
  final SecurePasswordStore _passwordStore;

  /// The underlying runtime persistence store (shared with BridgeRuntime).
  SQLiteRuntimePersistenceStore get runtimeStore => _runtimeStore;
  Database? _cachedDb;

  Future<Database> _db() async {
    if (_cachedDb != null) return _cachedDb!;
    _cachedDb = await _runtimeStore.sharedDb();
    return _cachedDb!;
  }

  // ─── Hosts ─────────────────────────────────────────────────────────

  @override
  Future<List<HostConfig>> loadHosts() async {
    final rows = await _dbQuery('hosts', orderBy: 'updated_at DESC');
    if (rows.isEmpty) return const [];
    final hosts = rows.map(_decodePayload).map(HostConfig.fromJson).toList();
    return Future.wait(hosts.map((host) async {
      final password = await _passwordStore.loadPassword(host.id);
      if (password.isNotEmpty) return host.copyWith(password: password);
      return host;
    }));
  }

  @override
  Future<void> saveHost(HostConfig host) async {
    final db = await _db();
    await db.insert(
        'hosts',
        {
          'host_id': host.id,
          'updated_at': host.updatedAt.toIso8601String(),
          'payload': jsonEncode(host.toJson()),
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
    await _passwordStore.savePassword(host.id, host.password);
  }

  @override
  Future<void> deleteHost(String hostId) async {
    final db = await _db();
    await db.delete('hosts', where: 'host_id = ?', whereArgs: [hostId]);
    await _passwordStore.deletePassword(hostId);
  }

  // ─── [DEV-ONLY] Emulator seed password import ───────────────────────
  //
  // This is NOT a production feature. It only runs on Android when
  // seed-config.sh has pushed a temporary password file to the emulator.
  // See TaskHistoryStore.importSeedPasswords() for the full contract.
  @override
  Future<void> importSeedPasswords() async {
    // Only supported on Android (emulator dev workflow).
    if (!Platform.isAndroid) return;

    final supportDirectory = await getApplicationSupportDirectory();
    final seedFile = File(
      '${supportDirectory.path}/armin_seed_passwords.json',
    );
    if (!await seedFile.exists()) return;

    try {
      final content = await seedFile.readAsString();
      final map = jsonDecode(content) as Map<String, dynamic>;
      for (final entry in map.entries) {
        final hostId = entry.key;
        final password = entry.value as String;
        if (password.isNotEmpty) {
          await _passwordStore.savePassword(hostId, password);
        }
      }
      // Delete the seed file after successful import.
      await seedFile.delete();
    } catch (e) {
      // Seed file is malformed or inaccessible.
      // Log the error so CI/emulator tests can detect credential failures.
      debugPrint('importSeedPasswords failed: $e');
    }
  }

  // ─── Task Sessions ─────────────────────────────────────────────────

  @override
  Future<List<TaskSession>> loadTasks() async {
    final rows = await _dbQuery('task_sessions', orderBy: 'updated_at DESC');
    return rows.map(_decodePayload).map(TaskSession.fromJson).toList();
  }

  @override
  Future<void> saveTask(TaskSession task) async {
    final db = await _db();
    await db.insert(
        'task_sessions',
        {
          'task_id': task.id,
          'updated_at': task.updatedAt.toIso8601String(),
          'payload': jsonEncode(task.toJson()),
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<void> deleteTask(String taskId) async {
    final db = await _db();
    await db.delete('task_sessions', where: 'task_id = ?', whereArgs: [taskId]);
  }

  // ─── Project Paths ─────────────────────────────────────────────────

  @override
  Future<List<ProjectPathConfig>> loadProjectPaths() async {
    final rows = await _dbQuery('project_paths', orderBy: 'updated_at DESC');
    return rows.map(_decodePayload).map(ProjectPathConfig.fromJson).toList();
  }

  @override
  Future<void> saveProjectPath(ProjectPathConfig projectPath) async {
    final db = await _db();
    await db.insert(
        'project_paths',
        {
          'project_path_id': projectPath.id,
          'updated_at': projectPath.updatedAt.toIso8601String(),
          'payload': jsonEncode(projectPath.toJson()),
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<void> deleteProjectPath(String projectPathId) async {
    final db = await _db();
    await db.delete('project_paths',
        where: 'project_path_id = ?', whereArgs: [projectPathId]);
  }

  // ─── Helpers ──────────────────────────────────────────────────────

  Future<List<Map<String, Object?>>> _dbQuery(
    String table, {
    String? where,
    List<Object?>? whereArgs,
    String? orderBy,
    int? limit,
  }) async {
    final db = await _db();
    return db.query(table,
        where: where, whereArgs: whereArgs, orderBy: orderBy, limit: limit);
  }

  Map<String, Object?> _decodePayload(Map<String, Object?> row) {
    final payload = row['payload'];
    if (payload is! String || payload.trim().isEmpty) return const {};
    final decoded = jsonDecode(payload);
    if (decoded is Map) return _normalizeMap(decoded);
    return const {};
  }

  Map<String, Object?> _normalizeMap(Map<Object?, Object?> map) {
    return map
        .map((key, value) => MapEntry(key.toString(), _normalizeValue(value)));
  }

  Object? _normalizeValue(Object? value) {
    if (value is Map) return _normalizeMap(value);
    if (value is List) {
      return value.map(_normalizeValue).toList(growable: false);
    }
    return value;
  }
}
