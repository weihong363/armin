import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Interface for secure password storage (allows mocking in tests).
abstract class SecureStorageInterface {
  Future<void> write({required String key, String? value});
  Future<String?> read({required String key});
  Future<void> delete({required String key});
  Future<void> deleteAll();
}

/// Production implementation using FlutterSecureStorage.
class ProductionSecureStorage implements SecureStorageInterface {
  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  @override
  Future<void> write({required String key, String? value}) async {
    await _storage.write(key: key, value: value);
  }

  @override
  Future<String?> read({required String key}) async {
    return await _storage.read(key: key);
  }

  @override
  Future<void> delete({required String key}) async {
    await _storage.delete(key: key);
  }

  @override
  Future<void> deleteAll() async {
    await _storage.deleteAll();
  }
}

/// Secure storage service for host passwords using platform keystore.
/// 
/// - Android: AndroidKeystore
/// - iOS: Keychain
/// - macOS: Keychain
/// - Linux: libsecret
/// - Windows: Credential Vault
class SecurePasswordStore {
  SecurePasswordStore({SecureStorageInterface? storage})
      : _storage = storage ?? ProductionSecureStorage();

  final SecureStorageInterface _storage;

  static const String _keyPrefix = 'host_password_';

  /// Save password for a host identified by [hostId].
  Future<void> savePassword(String hostId, String password) async {
    if (password.isEmpty) {
      await deletePassword(hostId);
      return;
    }
    await _storage.write(key: _buildKey(hostId), value: password);
  }

  /// Load password for a host identified by [hostId].
  /// Returns empty string if no password is stored.
  Future<String> loadPassword(String hostId) async {
    final password = await _storage.read(key: _buildKey(hostId));
    return password ?? '';
  }

  /// Delete password for a host identified by [hostId].
  Future<void> deletePassword(String hostId) async {
    await _storage.delete(key: _buildKey(hostId));
  }

  /// Delete all stored passwords.
  Future<void> deleteAllPasswords() async {
    await _storage.deleteAll();
  }

  String _buildKey(String hostId) => '$_keyPrefix$hostId';
}
