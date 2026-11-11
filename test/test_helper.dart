import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:pocket_change/models/transaction_item.dart';
import 'package:pocket_change/services/receipt_service.dart';

/// SQLite Database schema constants
const String kTransactionsTable = 'transactions';
const String kLedgerSummaryView = 'ledger_summary';

/// SQL DDL: transactions table with integrity constraints
const String kCreateTransactionsTableSql = '''
CREATE TABLE transactions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  txnid TEXT NOT NULL UNIQUE,
  type TEXT NOT NULL CHECK(type IN ('ADD', 'PAY')),
  amount REAL NOT NULL CHECK(amount > 0),
  timestamp INTEGER NOT NULL,
  memo_photo_path TEXT,
  notes TEXT,
  category TEXT
);
''';

/// Performance indexes on timestamp, txnid, and type
const List<String> kCreateIndexesSqlList = [
  'CREATE INDEX IF NOT EXISTS idx_transactions_timestamp ON transactions(timestamp DESC);',
  'CREATE INDEX IF NOT EXISTS idx_transactions_txnid ON transactions(txnid);',
  'CREATE INDEX IF NOT EXISTS idx_transactions_type ON transactions(type);',
];

/// Dynamic SQL View: computes real-time balance and cash flow totals
const String kCreateLedgerSummaryViewSql = '''
CREATE VIEW IF NOT EXISTS ledger_summary AS
SELECT
  COALESCE(SUM(CASE WHEN type = 'ADD' THEN amount WHEN type = 'PAY' THEN -amount ELSE 0 END), 0.0) AS balance,
  COALESCE(SUM(CASE WHEN type = 'ADD' THEN amount ELSE 0 END), 0.0) AS total_in,
  COALESCE(SUM(CASE WHEN type = 'PAY' THEN amount ELSE 0 END), 0.0) AS total_out,
  COUNT(*) AS total_count
FROM transactions;
''';

/// Initializes the headless SQLite FFI database factory for test execution on host/Linux.
void initTestDatabaseFactory() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
}

/// Creates a fresh, isolated in-memory SQLite database populated with schema, indexes, and views.
Future<Database> createInMemoryDatabase() async {
  initTestDatabaseFactory();
  return await databaseFactoryFfi.openDatabase(
    inMemoryDatabasePath,
    options: OpenDatabaseOptions(
      version: 1,
      onCreate: (db, version) async {
        await db.execute(kCreateTransactionsTableSql);
        for (final indexSql in kCreateIndexesSqlList) {
          await db.execute(indexSql);
        }
        await db.execute(kCreateLedgerSummaryViewSql);
      },
    ),
  );
}

/// Creates a temporary directory for file and receipt photo testing.
Future<Directory> createTestTempDir({String prefix = 'pocket_change_test_'}) async {
  final tempSystemDir = Directory.systemTemp;
  return await tempSystemDir.createTemp(prefix);
}

/// Creates a test [ReceiptService] instance bound to an isolated temporary directory.
ReceiptService createTestReceiptService(Directory tempDir) {
  return ReceiptService(docsDirProvider: () async => tempDir);
}

/// Minimal valid 1x1 pixel JPEG binary representation (631 bytes).
final Uint8List kMinimal1x1JpegBytes = base64Decode(
  '/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////wgALCAABAAEBAREA/8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQABPxA=',
);

/// Minimal valid 1x1 pixel PNG binary representation (68 bytes).
final Uint8List kMinimal1x1PngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
);

/// Standard base64 string for minimal 1x1 test image.
final String kMinimal1x1JpegBase64 = base64Encode(kMinimal1x1JpegBytes);

/// Factory helper to build a test [TransactionItem].
TransactionItem createTestTransaction({
  int? id,
  String? txnid,
  TransactionType type = TransactionType.add,
  double amount = 1000.0,
  DateTime? timestamp,
  String? memoPhotoPath,
  String? notes,
  String? category,
  String? memoPhotoBase64,
}) {
  final now = timestamp ?? DateTime.now();
  final uniqueTxnId = txnid ?? 'TXN_TEST_${now.microsecondsSinceEpoch}';
  return TransactionItem(
    id: id,
    txnid: uniqueTxnId,
    type: type,
    amount: amount,
    timestamp: now,
    memoPhotoPath: memoPhotoPath,
    notes: notes,
    category: category,
    memoPhotoBase64: memoPhotoBase64,
  );
}

/// Factory helper for an Add Money test transaction.
TransactionItem sampleAddTransaction({
  int? id,
  String? txnid,
  double amount = 1500.0,
  DateTime? timestamp,
  String? notes = 'Cash deposit',
  String? category = 'Deposit',
}) {
  return createTestTransaction(
    id: id,
    txnid: txnid,
    type: TransactionType.add,
    amount: amount,
    timestamp: timestamp,
    notes: notes,
    category: category,
  );
}

/// Factory helper for a Pay test transaction with receipt photo path.
TransactionItem samplePayTransaction({
  int? id,
  String? txnid,
  double amount = 350.0,
  DateTime? timestamp,
  String? memoPhotoPath = 'receipts/rec_sample.jpg',
  String? notes = 'Bazaar shopping',
  String? category = 'Groceries',
  String? memoPhotoBase64,
}) {
  return createTestTransaction(
    id: id,
    txnid: txnid,
    type: TransactionType.pay,
    amount: amount,
    timestamp: timestamp,
    memoPhotoPath: memoPhotoPath,
    notes: notes,
    category: category,
    memoPhotoBase64: memoPhotoBase64,
  );
}
