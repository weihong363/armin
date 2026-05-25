import 'package:armin/core/storage/secure_password_store.dart';

/// Mock implementation of SecureStorageInterface for testing.
class MockSecureStorage implements SecureStorageInterface {
  final Map<String, String?> _storage = {};

  @override
  Future<void> write({required String key, String? value}) async {
    _storage[key] = value;
  }

  @override
  Future<String?> read({required String key}) async {
    return _storage[key];
  }

  @override
  Future<void> delete({required String key}) async {
    _storage.remove(key);
  }

  @override
  Future<void> deleteAll() async {
    _storage.clear();
  }
}
