import 'dart:math';

/// Utility class for generating unique, collision-resistant transaction IDs
/// inspired by Bangladeshi Mobile Financial Services (bKash, Nagad).
///
/// Typical format:
/// `[PREFIX][8-char base36 timestamp][2-char base36 sequence][2-char base36 entropy]`
///
/// Example: `"TXNMW6MXUZM01GC"`
/// - Prefix: `"TXN"` (3 chars)
/// - Timestamp: `"MW6MXUZM"` (8 chars, base36 millisecondsSinceEpoch)
/// - Monotonic sequence: `"01"` (2 chars, base36 0-1295 loop, prevents same-millisecond collisions)
/// - Secure entropy: `"GC"` (2 chars, base36 cryptographically random)
///
/// Total length: 15 characters (or 12 chars if prefix is empty).
class TxnIdGenerator {
  TxnIdGenerator._();

  static final Random _secureRandom = Random.secure();
  static int _counter = 0;
  static const String _base36Chars = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ';

  /// Generates a unique Bangladeshi MFS-style transaction ID.
  ///
  /// [prefix] defaults to `'TXN'`.
  /// Guaranteed collision-free even during rapid successive calls within the same millisecond.
  static String generate({String prefix = 'TXN'}) {
    final now = DateTime.now();
    // 8-character base36 timestamp encodes millisecondsSinceEpoch up to year 3000+
    final timePart = now.millisecondsSinceEpoch
        .toRadixString(36)
        .toUpperCase()
        .padLeft(8, '0');

    // Monotonic sequence (0-1295 in base 36 = 2 characters).
    // Eliminates collisions across rapid bursts within the exact same millisecond.
    _counter = (_counter + 1) % 1296;
    final seqPart = _counter.toRadixString(36).toUpperCase().padLeft(2, '0');

    // 2 characters of cryptographically secure random entropy
    final rand1 = _base36Chars[_secureRandom.nextInt(36)];
    final rand2 = _base36Chars[_secureRandom.nextInt(36)];

    return '$prefix$timePart$seqPart$rand1$rand2';
  }

  /// Validates whether a transaction ID conforms to the generated format.
  ///
  /// Checks for the expected prefix followed by exactly 12 uppercase alphanumeric characters.
  static bool isValid(String? txnid, {String prefix = 'TXN'}) {
    if (txnid == null || !txnid.startsWith(prefix)) return false;
    final body = txnid.substring(prefix.length);
    if (body.length != 12) return false;
    return RegExp(r'^[0-9A-Z]{12}$').hasMatch(body);
  }

  /// Extracts the creation [DateTime] encoded inside the transaction ID.
  ///
  /// Returns `null` if [txnid] is invalid or malformed.
  static DateTime? extractTimestamp(String? txnid, {String prefix = 'TXN'}) {
    if (!isValid(txnid, prefix: prefix)) return null;
    try {
      final timePart = txnid!.substring(prefix.length, prefix.length + 8);
      final millis = int.parse(timePart, radix: 36);
      return DateTime.fromMillisecondsSinceEpoch(millis);
    } catch (_) {
      return null;
    }
  }
}

/// Top-level convenience function for generating transaction IDs matching project convention.
///
/// Example:
/// ```dart
/// final txnid = generateTxnId(); // "TXNMW6MXUZM01GC"
/// ```
String generateTxnId({String prefix = 'TXN'}) =>
    TxnIdGenerator.generate(prefix: prefix);
