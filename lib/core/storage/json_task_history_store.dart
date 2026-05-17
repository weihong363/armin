import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../../features/hosts/models/host_config.dart';
import '../../features/tasks/models/task_session.dart';
import 'secure_password_store.dart';
import 'task_history_store.dart';

class JsonTaskHistoryStore implements TaskHistoryStore {
  JsonTaskHistoryStore({File? file, SecurePasswordStore? passwordStore})
      : _fileOverride = file,
        _passwordStore = passwordStore ?? SecurePasswordStore();

  final File? _fileOverride;
  final SecurePasswordStore _passwordStore;

  List<HostConfig>? _hosts;
  List<TaskSession>? _tasks;

  @override
  Future<List<HostConfig>> loadHosts() async {
    await _ensureLoaded();
    // Load passwords from secure storage for each host
    final hosts = <HostConfig>[];
    for (final host in _hosts!) {
      final password = await _passwordStore.loadPassword(host.id);
      if (password.isNotEmpty) {
        hosts.add(host.copyWith(password: password));
      } else {
        hosts.add(host);
      }
    }
    return List.unmodifiable(hosts);
  }

  @override
  Future<List<TaskSession>> loadTasks() async {
    await _ensureLoaded();
    return List.unmodifiable(_tasks!);
  }

  @override
  Future<void> saveHost(HostConfig host) async {
    await _ensureLoaded();
    final index = _hosts!.indexWhere((item) => item.id == host.id);
    if (index >= 0) {
      _hosts![index] = host;
    } else {
      _hosts!.add(host);
    }
    // Save password to secure storage
    await _passwordStore.savePassword(host.id, host.password);
    await _persist();
  }

  @override
  Future<void> saveTask(TaskSession task) async {
    await _ensureLoaded();
    final index = _tasks!.indexWhere((item) => item.id == task.id);
    if (index >= 0) {
      _tasks![index] = task;
    } else {
      _tasks!.insert(0, task);
    }
    await _persist();
  }

  Future<void> _ensureLoaded() async {
    if (_hosts != null && _tasks != null) {
      return;
    }

    final file = await _file();
    if (!await file.exists()) {
      _hosts = [];
      _tasks = [];
      await _persist();
      return;
    }

    final content = await file.readAsString();
    if (content.trim().isEmpty) {
      _hosts = [];
      _tasks = [];
      return;
    }

    final json = jsonDecode(content);
    if (json is! Map<String, Object?>) {
      throw const FormatException('Invalid Armin history JSON root.');
    }

    _hosts = _decodeList(json['hosts'], HostConfig.fromJson);
    _tasks = _decodeList(json['tasks'], TaskSession.fromJson);
  }

  Future<void> _persist() async {
    final file = await _file();
    await file.parent.create(recursive: true);
    final content = const JsonEncoder.withIndent('  ').convert({
      'schemaVersion': 1,
      'hosts': _hosts!.map((host) => host.toJson()).toList(),
      'tasks': _tasks!.map((task) => task.toJson()).toList(),
    });
    await file.writeAsString(content);
  }

  Future<File> _file() async {
    if (_fileOverride != null) {
      return _fileOverride;
    }
    final directory = await getApplicationDocumentsDirectory();
    return File('${directory.path}/armin_history.json');
  }

  List<T> _decodeList<T>(
    Object? value,
    T Function(Map<String, Object?> json) fromJson,
  ) {
    if (value is! List) {
      return [];
    }
    return value
        .whereType<Map<String, Object?>>()
        .map(fromJson)
        .toList(growable: true);
  }
}
