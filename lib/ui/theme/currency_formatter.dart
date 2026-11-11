import '../../models/transaction_item.dart';

/// Formatter for Bangladeshi Taka (৳) currency values supporting English and Bengali numerals,
/// Indian Lakh-Crore grouping, and signed transaction amounts.
class CurrencyFormatter {
  CurrencyFormatter._();

  /// Bengali Taka currency symbol: Unicode U+09F3.
  static const String takaSymbol = '৳';

  /// Bengali numeral digits from 0 to 9.
  static const List<String> _bengaliDigits = [
    '০', '১', '২', '৩', '৪', '৫', '৬', '৭', '৮', '৯'
  ];

  /// Formats [amount] as a Bangladeshi Taka currency string.
  ///
  /// Examples:
  /// - `1500.5` -> `৳ 1,500.50`
  /// - `125000` -> `৳ 1,25,000.00` (Lakh-Crore grouping)
  /// - `125000` (thousands grouping) -> `৳ 125,000.00`
  /// - `1500.5` with `useBengaliDigits: true` -> `৳ ১,৫০০.৫০`
  static String formatBdt(
    double amount, {
    bool showDecimals = true,
    int decimalDigits = 2,
    bool useIndianGrouping = true,
    bool useBengaliDigits = false,
    bool withSpace = true,
    String symbol = takaSymbol,
  }) {
    final isNegative = amount < 0;
    final absAmount = amount.abs();
    final fixedStr = absAmount.toStringAsFixed(showDecimals ? decimalDigits : 0);
    final parts = fixedStr.split('.');
    final intPart = parts[0];
    final decPart = (showDecimals && parts.length > 1) ? '.${parts[1]}' : '';

    final groupedInt = useIndianGrouping
        ? _formatIndianGrouping(intPart)
        : _formatStandardGrouping(intPart);

    String result = '$groupedInt$decPart';

    if (useBengaliDigits) {
      result = toBengaliDigits(result);
    }

    final space = withSpace ? ' ' : '';
    final sign = isNegative ? '-' : '';

    return '$sign$symbol$space$result';
  }

  /// Formats signed amounts for transaction feed tiles:
  /// - `TransactionType.add`: `+ ৳ 1,500.00`
  /// - `TransactionType.pay`: `- ৳ 350.00`
  static String formatSignedBdt(
    double amount, {
    required TransactionType type,
    bool showDecimals = true,
    bool useBengaliDigits = false,
    bool useIndianGrouping = true,
  }) {
    final absAmount = amount.abs();
    final formatted = formatBdt(
      absAmount,
      showDecimals: showDecimals,
      useBengaliDigits: useBengaliDigits,
      useIndianGrouping: useIndianGrouping,
    );
    final prefix = type == TransactionType.add ? '+ ' : '- ';
    return '$prefix$formatted';
  }

  /// Converts ASCII numeric characters ('0'-'9') in [input] to Bengali numerals ('০'-'৯').
  static String toBengaliDigits(String input) {
    final sb = StringBuffer();
    for (int i = 0; i < input.length; i++) {
      final code = input.codeUnitAt(i);
      if (code >= 48 && code <= 57) {
        sb.write(_bengaliDigits[code - 48]);
      } else {
        sb.write(input[i]);
      }
    }
    return sb.toString();
  }

  /// Converts Bengali numerals ('০'-'৯') back to ASCII digits ('0'-'9').
  static String toAsciiDigits(String input) {
    final sb = StringBuffer();
    for (int i = 0; i < input.length; i++) {
      final code = input.codeUnitAt(i);
      // U+09E6 ('০') to U+09EF ('৯')
      if (code >= 0x09E6 && code <= 0x09EF) {
        sb.write(code - 0x09E6);
      } else {
        sb.write(input[i]);
      }
    }
    return sb.toString();
  }

  /// Resilient parser: cleans Bengali/English currency strings and extracts double value.
  ///
  /// Handles: `'৳ 1,500.50'`, `'৳ ১,৫০০.৫০'`, `'1500'`, `'- ৳ 250'` -> `250.0` or `-250.0`.
  static double? tryParse(String? input) {
    if (input == null) return null;
    final trimmed = input.trim();
    if (trimmed.isEmpty) return null;

    final isNegative = trimmed.startsWith('-');
    final ascii = toAsciiDigits(trimmed);

    // Strip currency symbol, commas, spaces, and signs
    final cleaned = ascii
        .replaceAll(takaSymbol, '')
        .replaceAll(',', '')
        .replaceAll(' ', '')
        .replaceAll('+', '')
        .replaceAll('-', '');

    final parsed = double.tryParse(cleaned);
    if (parsed == null) return null;
    return isNegative ? -parsed : parsed;
  }

  /// South Asian Lakh-Crore grouping: last 3 digits, then groups of 2.
  static String _formatIndianGrouping(String intPart) {
    if (intPart.length <= 3) return intPart;

    final last3 = intPart.substring(intPart.length - 3);
    final remaining = intPart.substring(0, intPart.length - 3);

    final chunks = <String>[];
    for (int i = remaining.length; i > 0; i -= 2) {
      final start = i - 2 < 0 ? 0 : i - 2;
      chunks.insert(0, remaining.substring(start, i));
    }

    return '${chunks.join(",")},$last3';
  }

  /// Standard International thousands grouping: groups of 3 digits.
  static String _formatStandardGrouping(String intPart) {
    if (intPart.length <= 3) return intPart;

    final buffer = StringBuffer();
    final len = intPart.length;
    for (int i = 0; i < len; i++) {
      if (i > 0 && (len - i) % 3 == 0) {
        buffer.write(',');
      }
      buffer.write(intPart[i]);
    }
    return buffer.toString();
  }
}
