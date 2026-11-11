import 'dart:convert';
import 'package:flutter/foundation.dart';

import 'ledger_summary.dart';
import 'transaction_item.dart';

/// Exception thrown when backup JSON fails structural, constraint, reconciliation,
/// or security validation checks.
class BackupValidationException implements Exception {
  /// Primary error description.
  final String message;

  /// Optional detailed list of all validation error messages.
  final List<String> errors;

  const BackupValidationException(this.message, [this.errors = const []]);

  @override
  String toString() {
    if (errors.isNotEmpty) {
      return 'BackupValidationException: $message\n- ${errors.join('\n- ')}';
    }
    return 'BackupValidationException: $message';
  }
}

/// Exception thrown when an unexpected failure occurs during atomic database
/// or filesystem restoration.
class BackupRestorationException implements Exception {
  /// Description of what failed during restoration.
  final String message;

  /// Underlying error or cause if available.
  final dynamic cause;

  const BackupRestorationException(this.message, [this.cause]);

  @override
  String toString() {
    if (cause != null) {
      return 'BackupRestorationException: $message (Caused by: $cause)';
    }
    return 'BackupRestorationException: $message';
  }
}

/// Domain model representing the complete, portable JSON backup payload.
///
/// Encapsulates version metadata, ledger summary, cryptographic checksum,
/// and transaction records with embedded Base64 memo photos.
@immutable
class BackupPayload {
  /// Canonical backup schema format version (currently 1).
  final int version;

  /// Application version string (e.g. "1.0.0+1").
  final String appVersion;

  /// Application identifier / bundle ID (e.g. "com.pocketchange.mfs").
  final String appIdentifier;

  /// UTC timestamp when backup was generated.
  final DateTime exportedAt;

  /// Operating system where export occurred (e.g. "android", "linux").
  final String deviceOs;

  /// Declared ledger summary snapshot at time of export.
  final LedgerSummary summary;

  /// Optional SHA-256 integrity checksum signature.
  final String? checksum;

  /// List of transactions contained in this backup.
  final List<TransactionItem> transactions;

  const BackupPayload({
    required this.version,
    required this.appVersion,
    required this.appIdentifier,
    required this.exportedAt,
    required this.deviceOs,
    required this.summary,
    this.checksum,
    required this.transactions,
  });

  /// Total number of transactions in this payload.
  int get transactionCount => transactions.length;

  /// Number of transactions containing embedded Base64 receipt photos.
  int get photoCount => transactions
      .where((t) => t.memoPhotoBase64 != null && t.memoPhotoBase64!.isNotEmpty)
      .length;

  /// Converts this payload to a serializable map matching the canonical schema.
  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'version': version,
      'app_version': appVersion,
      'app_identifier': appIdentifier,
      'exported_at': exportedAt.toUtc().toIso8601String(),
      'device_os': deviceOs,
      'summary': <String, dynamic>{
        'total_balance': summary.balance,
        'total_in': summary.totalIn,
        'total_out': summary.totalOut,
        'transaction_count': summary.totalCount,
      },
      if (checksum != null) 'checksum': checksum,
      'transactions': transactions.map((t) => t.toJson()).toList(),
    };
  }

  /// Serializes payload to JSON string, optionally with 2-space pretty indentation.
  String toJsonString({bool pretty = false}) {
    final map = toMap();
    if (pretty) {
      return const JsonEncoder.withIndent('  ').convert(map);
    }
    return jsonEncode(map);
  }

  /// Constructs a [BackupPayload] from a raw decoded JSON map.
  factory BackupPayload.fromMap(Map<String, dynamic> map) {
    final dynamic summaryVal = map['summary'];
    final Map<String, dynamic> rawSummary;
    if (summaryVal is Map<String, dynamic>) {
      rawSummary = summaryVal;
    } else if (summaryVal is Map) {
      rawSummary = Map<String, dynamic>.from(summaryVal);
    } else {
      rawSummary = <String, dynamic>{};
    }

    final dynamic txnsVal = map['transactions'];
    final List<dynamic> rawTxns = txnsVal is List ? txnsVal : [];

    final rawVersion = map['version'] ?? map['backup_format_version'] ?? 1;
    final int version = rawVersion is int ? rawVersion : int.parse(rawVersion.toString());

    final rawExportedAt = map['exported_at'];
    final DateTime exportedAt;
    if (rawExportedAt is String) {
      exportedAt = DateTime.parse(rawExportedAt);
    } else if (rawExportedAt is int) {
      exportedAt = DateTime.fromMillisecondsSinceEpoch(rawExportedAt);
    } else {
      exportedAt = DateTime.now().toUtc();
    }

    return BackupPayload(
      version: version,
      appVersion: (map['app_version'] ?? '1.0.0+1').toString(),
      appIdentifier: (map['app_identifier'] ?? 'com.pocketchange.mfs').toString(),
      exportedAt: exportedAt,
      deviceOs: (map['device_os'] ?? 'android').toString(),
      summary: LedgerSummary.fromMap(rawSummary),
      checksum: map['checksum'] as String?,
      transactions: rawTxns
          .whereType<Map>()
          .map((item) => TransactionItem.fromJson(Map<String, dynamic>.from(item)))
          .toList(),
    );
  }

  /// Deserializes a [BackupPayload] from a JSON string.
  factory BackupPayload.fromJsonString(String jsonStr) {
    final dynamic decoded = jsonDecode(jsonStr);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Expected root JSON Object for BackupPayload.');
    }
    return BackupPayload.fromMap(decoded);
  }
}

/// Encapsulates the complete result of validating a backup JSON payload.
@immutable
class BackupValidationResult {
  /// Whether the backup is valid and eligible for restoration.
  final bool isValid;

  /// Fatal error messages preventing restoration.
  final List<String> errors;

  /// Non-fatal warning messages detected during analysis.
  final List<String> warnings;

  /// Parsed payload if validation succeeded; null if fatal errors occurred.
  final BackupPayload? payload;

  /// Total transaction count verified in payload.
  final int transactionCount;

  /// Net balance verified in payload.
  final double calculatedBalance;

  /// Number of receipt photos present in payload.
  final int photoCount;

  const BackupValidationResult({
    required this.isValid,
    this.errors = const [],
    this.warnings = const [],
    this.payload,
    this.transactionCount = 0,
    this.calculatedBalance = 0.0,
    this.photoCount = 0,
  });

  /// Creates a successful validation result.
  factory BackupValidationResult.success({
    required BackupPayload payload,
    List<String> warnings = const [],
  }) {
    return BackupValidationResult(
      isValid: true,
      errors: const [],
      warnings: List.unmodifiable(warnings),
      payload: payload,
      transactionCount: payload.transactionCount,
      calculatedBalance: payload.summary.balance,
      photoCount: payload.photoCount,
    );
  }

  /// Creates a failed validation result with fatal errors.
  factory BackupValidationResult.failure(
    List<String> errors, {
    List<String> warnings = const [],
  }) {
    return BackupValidationResult(
      isValid: false,
      errors: List.unmodifiable(errors),
      warnings: List.unmodifiable(warnings),
      payload: null,
      transactionCount: 0,
      calculatedBalance: 0.0,
      photoCount: 0,
    );
  }

  /// True if any fatal errors were encountered.
  bool get hasErrors => errors.isNotEmpty;

  /// True if any non-fatal warnings were recorded.
  bool get hasWarnings => warnings.isNotEmpty;

  /// Formatted single-string display of all validation errors.
  String get errorMessage => errors.join('\n');
}

/// Detailed outcome summary produced upon successful atomic backup restoration.
@immutable
class BackupSummary {
  /// Number of transactions successfully inserted into SQLite.
  final int restoredTransactionsCount;

  /// Number of receipt photos written to documents directory.
  final int restoredPhotosCount;

  /// Restored net cash balance in BDT.
  final double restoredBalance;

  /// Restored total cash additions in BDT.
  final double restoredTotalIn;

  /// Restored total cash payments in BDT.
  final double restoredTotalOut;

  /// Wall-clock duration elapsed during the restoration process.
  final Duration duration;

  /// Timestamp when restoration completed.
  final DateTime importedAt;

  const BackupSummary({
    required this.restoredTransactionsCount,
    required this.restoredPhotosCount,
    required this.restoredBalance,
    required this.restoredTotalIn,
    required this.restoredTotalOut,
    required this.duration,
    required this.importedAt,
  });

  @override
  String toString() {
    return 'BackupSummary(restored: $restoredTransactionsCount txns, $restoredPhotosCount photos, balance: ৳$restoredBalance in ${duration.inMilliseconds}ms)';
  }
}
