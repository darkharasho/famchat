// Key-value storage for secrets (refresh token, key seeds).
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

abstract interface class SecureKv {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// In-memory storage for tests.
class MemorySecureKv implements SecureKv {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}

/// The OS keychain/keystore (Keychain, Android Keystore, libsecret, Credential Manager).
/// On the web it is WebCrypto-wrapped localStorage, readable by any script on the origin;
/// see the spec's "Known limits".
class FlutterSecureKv implements SecureKv {
  FlutterSecureKv([FlutterSecureStorage? storage]) : _s = storage ?? _default;

  // Device keys must never leave this device through backups, hence *_this_device.
  // Android: the plugin's default resetOnError would silently wipe every key on a
  //   decryption error, losing the identity key; surface the error instead.
  // macOS: the data-protection keychain needs a keychain-access-groups entitlement and
  //   a signed build; the legacy login keychain works for unsigned dev and CI builds.
  static const _default = FlutterSecureStorage(
    aOptions: AndroidOptions(resetOnError: false),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
    mOptions: MacOsOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
      usesDataProtectionKeychain: false,
    ),
  );

  final FlutterSecureStorage _s;

  @override
  Future<String?> read(String key) => _s.read(key: key);

  @override
  Future<void> write(String key, String value) => _s.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _s.delete(key: key);
}
