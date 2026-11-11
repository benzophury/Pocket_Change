import 'package:flutter/foundation.dart';

/// Represents aggregated financial totals from the digital cash ledger.
///
/// Corresponds directly to the dynamic SQLite view:
/// ```sql
/// CREATE VIEW ledger_summary AS
/// SELECT
///   COALESCE(SUM(CASE WHEN type = 'ADD' THEN amount WHEN type = 'PAY' THEN -amount ELSE 0 END), 0.0) AS balance,
///   COALESCE(SUM(CASE WHEN type = 'ADD' THEN amount ELSE 0 END), 0.0) AS total_in,
///   COALESCE(SUM(CASE WHEN type = 'PAY' THEN amount ELSE 0 END), 0.0) AS total_out,
///   COUNT(*) AS total_count
/// FROM transactions;
/// ```
@immutable
class LedgerSummary {
  /// Current net cash balance: totalIn minus totalOut.
  final double balance;

  /// Total cash added via Add Money transactions.
  final double totalIn;

  /// Total cash spent via Pay transactions.
  final double totalOut;

  /// Total count of all transactions recorded in the ledger.
  final int totalCount;

  /// Creates an immutable [LedgerSummary] instance.
  const LedgerSummary({
    required this.balance,
    required this.totalIn,
    required this.totalOut,
    required this.totalCount,
  });

  /// Canonical zero / empty summary instance.
  static const LedgerSummary zero = LedgerSummary(
    balance: 0.0,
    totalIn: 0.0,
    totalOut: 0.0,
    totalCount: 0,
  );

  /// Factory constructor providing an empty/zero state summary.
  factory LedgerSummary.empty() => zero;

  /// Whether the ledger contains zero transactions.
  bool get isEmpty => totalCount == 0;

  /// Whether the ledger contains at least one transaction.
  bool get isNotEmpty => totalCount > 0;

  /// Net savings / retained cash in wallet (identical to [balance]).
  double get netSavings => balance;

  /// Creates a [LedgerSummary] from an SQLite view row, JSON map, or generic dictionary.
  ///
  /// Resiliently accepts column names from:
  /// - SQLite `ledger_summary` view: `'balance'`, `'total_in'`, `'total_out'`, `'total_count'`
  /// - Backup JSON metadata: `'calculated_balance'`, `'total_in'`, `'total_out'`, `'total_records'`
  /// - CamelCase keys: `'balance'`, `'totalIn'`, `'totalOut'`, `'totalCount'`
  /// Safely handles nulls, int, and double values.
  factory LedgerSummary.fromMap(Map<String, dynamic> map) {
    final balanceVal = map['total_balance'] ??
        map['balance'] ??
        map['calculated_balance'] ??
        0.0;
    final inVal = map['total_in'] ?? map['totalIn'] ?? 0.0;
    final outVal = map['total_out'] ?? map['totalOut'] ?? 0.0;
    final countVal = map['transaction_count'] ??
        map['total_count'] ??
        map['totalCount'] ??
        map['total_records'] ??
        0;

    return LedgerSummary(
      balance: balanceVal is num
          ? balanceVal.toDouble()
          : (double.tryParse(balanceVal?.toString() ?? '') ?? 0.0),
      totalIn: inVal is num
          ? inVal.toDouble()
          : (double.tryParse(inVal?.toString() ?? '') ?? 0.0),
      totalOut: outVal is num
          ? outVal.toDouble()
          : (double.tryParse(outVal?.toString() ?? '') ?? 0.0),
      totalCount: countVal is num
          ? countVal.toInt()
          : (int.tryParse(countVal?.toString() ?? '') ?? 0),
    );
  }

  /// Converts this summary to a map matching the SQLite `ledger_summary` view column schema.
  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'balance': balance,
      'total_in': totalIn,
      'total_out': totalOut,
      'total_count': totalCount,
    };
  }

  /// Serializes summary into JSON map matching portable backup specification.
  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'calculated_balance': balance,
      'total_in': totalIn,
      'total_out': totalOut,
      'total_records': totalCount,
    };
  }

  /// Deserializes summary from JSON backup metadata.
  factory LedgerSummary.fromJson(Map<String, dynamic> json) =>
      LedgerSummary.fromMap(json);

  /// Creates a copy of this [LedgerSummary] with optional replacement fields.
  LedgerSummary copyWith({
    double? balance,
    double? totalIn,
    double? totalOut,
    int? totalCount,
  }) {
    return LedgerSummary(
      balance: balance ?? this.balance,
      totalIn: totalIn ?? this.totalIn,
      totalOut: totalOut ?? this.totalOut,
      totalCount: totalCount ?? this.totalCount,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is LedgerSummary &&
        other.balance == balance &&
        other.totalIn == totalIn &&
        other.totalOut == totalOut &&
        other.totalCount == totalCount;
  }

  @override
  int get hashCode => Object.hash(balance, totalIn, totalOut, totalCount);

  @override
  String toString() {
    return 'LedgerSummary(balance: $balance, totalIn: $totalIn, totalOut: $totalOut, totalCount: $totalCount)';
  }
}
