import 'package:flutter/foundation.dart';

/// Represents the type of a financial transaction in the digital cash ledger.
///
/// Corresponds directly to the SQLite CHECK constraint:
/// `CHECK(type IN ('ADD', 'PAY'))`
enum TransactionType {
  /// Cash added to wallet (e.g. cash deposit, ATM withdrawal, salary).
  /// Increases the cash ledger balance.
  add,

  /// Cash paid out (e.g. bazaar, shopping, utility bills).
  /// Decreases the cash ledger balance.
  pay;

  /// Serializes enum to database/JSON string value ('ADD' or 'PAY').
  String toDbValue() {
    switch (this) {
      case TransactionType.add:
        return 'ADD';
      case TransactionType.pay:
        return 'PAY';
    }
  }

  /// Deserializes database/JSON string value into [TransactionType].
  ///
  /// Supports case-insensitive input ('ADD', 'add', 'PAY', 'pay').
  /// Throws [ArgumentError] if the input does not match known types.
  static TransactionType fromDbValue(String value) {
    switch (value.trim().toUpperCase()) {
      case 'ADD':
        return TransactionType.add;
      case 'PAY':
        return TransactionType.pay;
      default:
        throw ArgumentError.value(
          value,
          'value',
          'Unknown TransactionType. Expected "ADD" or "PAY".',
        );
    }
  }

  /// Human-readable English display label for MFS UI.
  String get displayName {
    switch (this) {
      case TransactionType.add:
        return 'Add Money';
      case TransactionType.pay:
        return 'Pay';
    }
  }

  /// Human-readable Bengali display label for Bangladeshi MFS UI.
  String get bengaliDisplayName {
    switch (this) {
      case TransactionType.add:
        return 'টাকা যোগ';
      case TransactionType.pay:
        return 'পেমেন্ট';
    }
  }

  /// Whether this transaction represents cash inflow.
  bool get isCredit => this == TransactionType.add;

  /// Whether this transaction represents cash outflow.
  bool get isDebit => this == TransactionType.pay;

  /// Display sign prefix ('+' for ADD, '-' for PAY).
  String get sign => this == TransactionType.add ? '+' : '-';
}

/// Represents an individual transaction entry in the digital cash ledger.
///
/// Stored in the SQLite `transactions` table and serializable to JSON
/// for portable backup export and import.
@immutable
class TransactionItem {
  /// Internal SQLite primary key (`AUTOINCREMENT`).
  /// Null for newly created items prior to database insertion.
  final int? id;

  /// Distinctive, globally unique transaction ID inspired by Bangladeshi MFS apps.
  /// Example: `"TXNMW6MXUZM01GC"`
  final String txnid;

  /// The flow direction of the transaction (credit [TransactionType.add] or debit [TransactionType.pay]).
  final TransactionType type;

  /// The transaction amount in Bangladeshi Taka (BDT).
  /// Must be strictly positive (> 0) as enforced by database constraints.
  final double amount;

  /// Exact date and time when the transaction took place.
  final DateTime timestamp;

  /// Relative path to receipt memo image within app documents directory.
  /// Example: `"receipts/rec_TXNMW6MXUZM01GC.jpg"`.
  /// Null if no memo photo is attached.
  final String? memoPhotoPath;

  /// User notes or description (e.g. "Weekly grocery bazaar").
  final String? notes;

  /// Category classification (e.g. "Groceries", "Salary", "Cash Deposit", "Utilities").
  final String? category;

  /// Transient Base64 encoded memo photo string used during JSON backup export/import.
  /// Not persisted in SQLite table columns directly.
  final String? memoPhotoBase64;

  /// Creates an immutable [TransactionItem] instance.
  const TransactionItem({
    this.id,
    required this.txnid,
    required this.type,
    required this.amount,
    required this.timestamp,
    this.memoPhotoPath,
    this.notes,
    this.category,
    this.memoPhotoBase64,
  }) : assert(amount > 0, 'Transaction amount must be strictly positive');

  /// Whether this transaction has an attached memo photo path.
  bool get hasMemoPhoto =>
      memoPhotoPath != null && memoPhotoPath!.trim().isNotEmpty;

  /// Whether this transaction is an Add Money transaction.
  bool get isAdd => type == TransactionType.add;

  /// Whether this transaction is a Pay transaction.
  bool get isPay => type == TransactionType.pay;

  /// Signed amount: positive for Add Money (+amount), negative for Pay (-amount).
  double get signedAmount => isAdd ? amount : -amount;

  /// Converts this transaction item into an SQLite row map matching table schema.
  ///
  /// Column mapping:
  /// - `id`: INTEGER PRIMARY KEY (omitted if null)
  /// - `txnid`: TEXT NOT NULL UNIQUE
  /// - `type`: TEXT NOT NULL CHECK(type IN ('ADD', 'PAY'))
  /// - `amount`: REAL NOT NULL CHECK(amount > 0)
  /// - `timestamp`: INTEGER NOT NULL (millisecondsSinceEpoch)
  /// - `memo_photo_path`: TEXT
  /// - `notes`: TEXT
  /// - `category`: TEXT
  Map<String, dynamic> toMap() {
    final map = <String, dynamic>{
      'txnid': txnid,
      'type': type.toDbValue(),
      'amount': amount,
      'timestamp': timestamp.millisecondsSinceEpoch,
      'memo_photo_path': memoPhotoPath,
      'notes': notes,
      'category': category,
    };
    if (id != null) {
      map['id'] = id;
    }
    return map;
  }

  /// Creates a [TransactionItem] from an SQLite row query result or generic map.
  ///
  /// Resiliently parses column names in snake_case or camelCase, numeric amounts,
  /// and timestamp representations (int milliseconds, ISO8601 string, or DateTime).
  factory TransactionItem.fromMap(Map<String, dynamic> map) {
    // 1. Parse TransactionType
    final dynamic rawType = map['type'];
    final TransactionType parsedType;
    if (rawType is TransactionType) {
      parsedType = rawType;
    } else if (rawType is String) {
      parsedType = TransactionType.fromDbValue(rawType);
    } else {
      throw ArgumentError.value(
        rawType,
        'type',
        'Invalid transaction type representation',
      );
    }

    // 2. Parse timestamp
    final dynamic rawTime = map['timestamp'];
    final DateTime parsedTimestamp;
    if (rawTime is int) {
      parsedTimestamp = DateTime.fromMillisecondsSinceEpoch(rawTime);
    } else if (rawTime is DateTime) {
      parsedTimestamp = rawTime;
    } else if (rawTime is String) {
      final intVal = int.tryParse(rawTime);
      if (intVal != null) {
        parsedTimestamp = DateTime.fromMillisecondsSinceEpoch(intVal);
      } else {
        parsedTimestamp = DateTime.parse(rawTime);
      }
    } else {
      throw ArgumentError.value(
        rawTime,
        'timestamp',
        'Invalid timestamp format. Expected int, DateTime, or ISO-8601 string.',
      );
    }

    // 3. Parse amount
    final dynamic rawAmount = map['amount'];
    if (rawAmount == null || rawAmount is! num) {
      throw ArgumentError.value(
        rawAmount,
        'amount',
        'Transaction amount must be a non-null number.',
      );
    }
    final parsedAmount = rawAmount.toDouble();
    if (parsedAmount <= 0) {
      throw ArgumentError.value(
        parsedAmount,
        'amount',
        'Transaction amount must be strictly positive (> 0).',
      );
    }

    final rawTxnId = map['txnid'] ?? map['txn_id'];
    if (rawTxnId == null || rawTxnId is! String || rawTxnId.trim().isEmpty) {
      throw ArgumentError.value(
        rawTxnId,
        'txnid',
        'Transaction ID must be a non-empty string.',
      );
    }

    return TransactionItem(
      id: map['id'] as int?,
      txnid: rawTxnId,
      type: parsedType,
      amount: parsedAmount,
      timestamp: parsedTimestamp,
      memoPhotoPath: (map['memo_photo_path'] ?? map['memoPhotoPath']) as String?,
      notes: map['notes'] as String?,
      category: map['category'] as String?,
      memoPhotoBase64:
          (map['memo_photo_base64'] ?? map['memoPhotoBase64']) as String?,
    );
  }

  /// Serializes transaction into JSON format for portable backup export.
  Map<String, dynamic> toJson() {
    final map = <String, dynamic>{
      if (id != null) 'id': id,
      'txnid': txnid,
      'type': type.toDbValue(),
      'amount': amount,
      'timestamp': timestamp.millisecondsSinceEpoch,
      'memo_photo_path': memoPhotoPath,
      if (memoPhotoBase64 != null) 'memo_photo_base64': memoPhotoBase64,
      'notes': notes,
      'category': category,
    };
    return map;
  }

  /// Deserializes a transaction item from JSON backup structure.
  factory TransactionItem.fromJson(Map<String, dynamic> json) =>
      TransactionItem.fromMap(json);

  /// Creates a copy of this [TransactionItem] with optional replacement fields.
  ///
  /// To explicitly reset nullable fields ([memoPhotoPath], [notes], [category],
  /// [memoPhotoBase64]) to `null`, pass corresponding `clear*` flag as `true`.
  TransactionItem copyWith({
    int? id,
    String? txnid,
    TransactionType? type,
    double? amount,
    DateTime? timestamp,
    String? memoPhotoPath,
    bool clearMemoPhotoPath = false,
    String? notes,
    bool clearNotes = false,
    String? category,
    bool clearCategory = false,
    String? memoPhotoBase64,
    bool clearMemoPhotoBase64 = false,
  }) {
    return TransactionItem(
      id: id ?? this.id,
      txnid: txnid ?? this.txnid,
      type: type ?? this.type,
      amount: amount ?? this.amount,
      timestamp: timestamp ?? this.timestamp,
      memoPhotoPath:
          clearMemoPhotoPath ? null : (memoPhotoPath ?? this.memoPhotoPath),
      notes: clearNotes ? null : (notes ?? this.notes),
      category: clearCategory ? null : (category ?? this.category),
      memoPhotoBase64: clearMemoPhotoBase64
          ? null
          : (memoPhotoBase64 ?? this.memoPhotoBase64),
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is TransactionItem &&
        other.id == id &&
        other.txnid == txnid &&
        other.type == type &&
        other.amount == amount &&
        other.timestamp.millisecondsSinceEpoch ==
            timestamp.millisecondsSinceEpoch &&
        other.memoPhotoPath == memoPhotoPath &&
        other.notes == notes &&
        other.category == category &&
        other.memoPhotoBase64 == memoPhotoBase64;
  }

  @override
  int get hashCode => Object.hash(
        id,
        txnid,
        type,
        amount,
        timestamp.millisecondsSinceEpoch,
        memoPhotoPath,
        notes,
        category,
        memoPhotoBase64,
      );

  @override
  String toString() {
    return 'TransactionItem(id: $id, txnid: $txnid, type: ${type.toDbValue()}, amount: $amount, timestamp: ${timestamp.toIso8601String()}, memoPhotoPath: $memoPhotoPath, notes: $notes, category: $category)';
  }
}
