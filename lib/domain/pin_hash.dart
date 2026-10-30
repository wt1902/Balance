import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// App lock PIN: 4–8 digits, kept only as a salted PBKDF2-HMAC-SHA256 hash
/// in secure storage. The lock hides the interface; it does not encrypt data.
class PinHash {
  static bool isValid(String pin) => RegExp(r'^\d{4,8}$').hasMatch(pin);

  static Map<String, Object> create(
    String pin, {
    required int iterations,
    Random? random,
  }) {
    final rng = random ?? Random.secure();
    final salt = List<int>.generate(16, (_) => rng.nextInt(256));
    return {
      'version': 1,
      'iterations': iterations,
      'salt': base64Encode(salt),
      'hash': base64Encode(pbkdf2(utf8.encode(pin), salt, iterations)),
    };
  }

  static bool verify(String pin, Map<String, dynamic> stored) {
    final iterations = stored['iterations'];
    final salt = stored['salt'];
    final hash = stored['hash'];
    if (iterations is! int || salt is! String || hash is! String) {
      throw const FormatException('Invalid PIN record');
    }
    final expected = base64Decode(hash);
    final actual = pbkdf2(utf8.encode(pin), base64Decode(salt), iterations);
    // Constant time over the full length.
    var diff = expected.length ^ actual.length;
    for (var i = 0; i < expected.length && i < actual.length; i++) {
      diff |= expected[i] ^ actual[i];
    }
    return diff == 0;
  }

  /// RFC 8018 PBKDF2 with HMAC-SHA256, one 32-byte block.
  static List<int> pbkdf2(List<int> password, List<int> salt, int iterations) {
    if (iterations < 1) throw ArgumentError.value(iterations, 'iterations');
    final hmac = Hmac(sha256, password);
    var block = hmac.convert([...salt, 0, 0, 0, 1]).bytes;
    final result = List<int>.of(block);
    for (var i = 1; i < iterations; i++) {
      block = hmac.convert(block).bytes;
      for (var j = 0; j < result.length; j++) {
        result[j] ^= block[j];
      }
    }
    return result;
  }
}
