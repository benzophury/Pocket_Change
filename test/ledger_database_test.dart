import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:pocket_change/models/transaction_item.dart';
import 'package:pocket_change/models/ledger_summary.dart';
import 'package:pocket_change/services/database_helper.dart';
import 'package:pocket_change/services/receipt_service.dart';
import 'test_helper.dart';

void main() {
  setUpAll(() {
    initTestDatabaseFactory();
  });

  group('Ledger Database: Schema, Constraints & Dynamic View Tests', () {
    late DatabaseHelper dbHelper;

    setUp(() async {
      dbHelper = DatabaseHelper(
        databaseFactory: databaseFactoryFfi,
        databasePath: inMemoryDatabasePath,
      );
    });

    tearDown(() async {
      await dbHelper.close();
    });

    test('Initial database state has 0.0 balance and zeroed summary', () async {
      final balance = await dbHelper.getBalance();
      final LedgerSummary summary = await dbHelper.getSummary();
      final count = await dbHelper.getTransactionCount();

      expect(balance, equals(0.0));
      expect(summary.balance, equals(0.0));
      expect(summary.totalIn, equals(0.0));
      expect(summary.totalOut, equals(0.0));
      expect(summary.totalCount, equals(0));
      expect(count, equals(0));
      expect(summary.isEmpty, isTrue);
    });

    test('Inserting ADD transactions increases balance and total_in', () async {
      final item1 = sampleAddTransaction(
        txnid: 'TXN_ADD_001',
        amount: 1500.0,
        notes: 'ATM Withdrawal',
      );
      final id1 = await dbHelper.insertTransaction(item1);
      expect(id1, greaterThan(0));

      var summary = await dbHelper.getSummary();
      expect(summary.balance, equals(1500.0));
      expect(summary.totalIn, equals(1500.0));
      expect(summary.totalOut, equals(0.0));
      expect(summary.totalCount, equals(1));

      // Add a second credit transaction
      final item2 = sampleAddTransaction(
        txnid: 'TXN_ADD_002',
        amount: 500.0,
        notes: 'Bonus',
      );
      await dbHelper.insertTransaction(item2);

      summary = await dbHelper.getSummary();
      expect(summary.balance, equals(2000.0));
      expect(summary.totalIn, equals(2000.0));
      expect(summary.totalOut, equals(0.0));
      expect(summary.totalCount, equals(2));
      expect(await dbHelper.getBalance(), equals(2000.0));
    });

    test('Inserting PAY transactions decreases balance and increases total_out', () async {
      // Seed fund
      await dbHelper.insertTransaction(sampleAddTransaction(
        txnid: 'TXN_SEED_01',
        amount: 3000.0,
      ));

      // Debit with attached camera receipt
      final payItem = samplePayTransaction(
        txnid: 'TXN_PAY_001',
        amount: 850.50,
        memoPhotoPath: 'receipts/rec_TXN_PAY_001.jpg',
        notes: 'Supermarket Bazaar',
        category: 'Groceries',
      );
      final payId = await dbHelper.insertTransaction(payItem);
      expect(payId, greaterThan(0));

      final balance = await dbHelper.getBalance();
      final summary = await dbHelper.getSummary();

      expect(balance, closeTo(2149.50, 0.001));
      expect(summary.balance, closeTo(2149.50, 0.001));
      expect(summary.totalIn, equals(3000.0));
      expect(summary.totalOut, equals(850.50));
      expect(summary.totalCount, equals(2));
    });

    test('Unique txnid constraint throws DatabaseException on duplicate', () async {
      final item = sampleAddTransaction(txnid: 'TXN_UNIQUE_KEY');
      await dbHelper.insertTransaction(item);

      // Attempt to insert duplicate txnid with different type and amount
      final duplicate = samplePayTransaction(txnid: 'TXN_UNIQUE_KEY');
      expect(
        () async => await dbHelper.insertTransaction(duplicate),
        throwsA(isA<DatabaseException>()),
      );
    });

    test('Amount > 0 CHECK constraint rejects zero or negative amounts', () async {
      final db = await dbHelper.database;

      // Zero amount
      expect(
        () async => await db.insert('transactions', {
          'txnid': 'TXN_ZERO_AMT',
          'type': 'ADD',
          'amount': 0.0,
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        }),
        throwsA(isA<DatabaseException>()),
      );

      // Negative amount
      expect(
        () async => await db.insert('transactions', {
          'txnid': 'TXN_NEG_AMT',
          'type': 'PAY',
          'amount': -150.0,
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        }),
        throwsA(isA<DatabaseException>()),
      );
    });

    test('Type CHECK constraint rejects invalid transaction types', () async {
      final db = await dbHelper.database;

      expect(
        () async => await db.insert('transactions', {
          'txnid': 'TXN_INVALID_TYPE',
          'type': 'TRANSFER', // Allowed only 'ADD' or 'PAY'
          'amount': 250.0,
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        }),
        throwsA(isA<DatabaseException>()),
      );
    });

    test('Transactions listing ordered by timestamp DESC, id DESC', () async {
      final base = DateTime(2026, 11, 7, 12, 0, 0);
      final t1 = base.add(const Duration(minutes: 5));
      final t2 = base.add(const Duration(minutes: 15));
      final t3 = base.add(const Duration(minutes: 30));

      await dbHelper.insertTransaction(sampleAddTransaction(
        txnid: 'TXN_FIRST',
        amount: 100.0,
        timestamp: t1,
      ));
      await dbHelper.insertTransaction(sampleAddTransaction(
        txnid: 'TXN_SECOND',
        amount: 200.0,
        timestamp: t2,
      ));
      await dbHelper.insertTransaction(samplePayTransaction(
        txnid: 'TXN_THIRD',
        amount: 50.0,
        timestamp: t3,
      ));

      final txns = await dbHelper.getAllTransactions();
      expect(txns.length, equals(3));
      expect(txns[0].txnid, equals('TXN_THIRD'));  // Most recent
      expect(txns[1].txnid, equals('TXN_SECOND'));
      expect(txns[2].txnid, equals('TXN_FIRST'));  // Oldest
    });

    test('getTransactionByTxnId retrieves exact transaction or null', () async {
      final item = samplePayTransaction(
        txnid: 'TXN_SEARCH_TARGET',
        amount: 720.0,
        notes: 'Medicines',
      );
      await dbHelper.insertTransaction(item);

      final found = await dbHelper.getTransactionByTxnId('TXN_SEARCH_TARGET');
      expect(found, isNotNull);
      expect(found!.txnid, equals('TXN_SEARCH_TARGET'));
      expect(found.amount, equals(720.0));
      expect(found.notes, equals('Medicines'));

      final notFound = await dbHelper.getTransactionByTxnId('TXN_NON_EXISTENT');
      expect(notFound, isNull);
    });

    test('getTransactionsByType filters by flow direction correctly', () async {
      await dbHelper.insertTransaction(sampleAddTransaction(txnid: 'ADD_1', amount: 1000.0));
      await dbHelper.insertTransaction(sampleAddTransaction(txnid: 'ADD_2', amount: 2000.0));
      await dbHelper.insertTransaction(samplePayTransaction(txnid: 'PAY_1', amount: 500.0));

      final addList = await dbHelper.getTransactionsByType(TransactionType.add);
      final payList = await dbHelper.getTransactionsByType(TransactionType.pay);

      expect(addList.length, equals(2));
      expect(payList.length, equals(1));
      expect(addList.every((t) => t.isAdd), isTrue);
      expect(payList.every((t) => t.isPay), isTrue);
    });

    test('Deleting transaction updates dynamic summary view accordingly', () async {
      final id1 = await dbHelper.insertTransaction(sampleAddTransaction(
        txnid: 'DEL_ADD',
        amount: 5000.0,
      ));
      final id2 = await dbHelper.insertTransaction(samplePayTransaction(
        txnid: 'DEL_PAY',
        amount: 1500.0,
      ));

      expect(await dbHelper.getBalance(), equals(3500.0));

      // 1. Delete PAY transaction -> balance should increase back to 5000.0
      final deletedPay = await dbHelper.deleteTransaction(id2);
      expect(deletedPay, equals(1));

      var summary = await dbHelper.getSummary();
      expect(summary.balance, equals(5000.0));
      expect(summary.totalOut, equals(0.0));
      expect(summary.totalCount, equals(1));

      // 2. Delete ADD transaction -> balance should drop to 0.0
      final deletedAdd = await dbHelper.deleteTransaction(id1);
      expect(deletedAdd, equals(1));

      summary = await dbHelper.getSummary();
      expect(summary.balance, equals(0.0));
      expect(summary.totalIn, equals(0.0));
      expect(summary.totalCount, equals(0));
    });

    test('clearAll wipes transactions and resets balance', () async {
      await dbHelper.insertTransaction(sampleAddTransaction(txnid: 'CLR_1', amount: 1000.0));
      await dbHelper.insertTransaction(samplePayTransaction(txnid: 'CLR_2', amount: 300.0));

      await dbHelper.clearAll();

      final balance = await dbHelper.getBalance();
      final summary = await dbHelper.getSummary();
      final all = await dbHelper.getAllTransactions();

      expect(balance, equals(0.0));
      expect(summary.isEmpty, isTrue);
      expect(all.isEmpty, isTrue);
    });

    test('Atomic batch restoration replaces records and preserves consistency', () async {
      // Existing data
      await dbHelper.insertTransaction(sampleAddTransaction(
        txnid: 'PRE_RESTORE_01',
        amount: 800.0,
      ));

      // Restored dataset
      final restoredList = [
        sampleAddTransaction(
          txnid: 'RESTORE_001',
          amount: 12000.0,
          timestamp: DateTime.fromMillisecondsSinceEpoch(10000),
          notes: 'Salary transfer',
        ),
        samplePayTransaction(
          txnid: 'RESTORE_002',
          amount: 2500.0,
          timestamp: DateTime.fromMillisecondsSinceEpoch(20000),
          memoPhotoPath: 'receipts/rec_RESTORE_002.jpg',
          notes: 'House rent',
        ),
        samplePayTransaction(
          txnid: 'RESTORE_003',
          amount: 1500.0,
          timestamp: DateTime.fromMillisecondsSinceEpoch(30000),
          memoPhotoPath: 'receipts/rec_RESTORE_003.jpg',
          notes: 'Electricity bill',
        ),
      ];

      await dbHelper.restoreTransactions(restoredList);

      final balance = await dbHelper.getBalance();
      final summary = await dbHelper.getSummary();
      final txns = await dbHelper.getAllTransactions();

      expect(balance, equals(8000.0));
      expect(summary.balance, equals(8000.0));
      expect(summary.totalIn, equals(12000.0));
      expect(summary.totalOut, equals(4000.0));
      expect(summary.totalCount, equals(3));
      expect(txns.length, equals(3));
      expect(txns[0].txnid, equals('RESTORE_003')); // Ordered by timestamp DESC
    });

    test('Atomic batch restoration rolls back completely on constraint failure', () async {
      // Existing transaction
      await dbHelper.insertTransaction(sampleAddTransaction(
        txnid: 'SAFE_TXN_01',
        amount: 1000.0,
      ));

      final db = await dbHelper.database;
      bool caughtError = false;

      try {
        await db.transaction((txn) async {
          await txn.delete('transactions');
          // Valid row
          await txn.insert('transactions', {
            'txnid': 'BATCH_VALID',
            'type': 'ADD',
            'amount': 5000.0,
            'timestamp': 1000,
          });
          // Invalid row (negative amount) - fails CHECK constraint!
          await txn.insert('transactions', {
            'txnid': 'BATCH_INVALID',
            'type': 'PAY',
            'amount': -999.0,
            'timestamp': 2000,
          });
        });
      } catch (_) {
        caughtError = true;
      }

      expect(caughtError, isTrue);

      // Verify that rollback preserved the original state!
      final summary = await dbHelper.getSummary();
      expect(summary.balance, equals(1000.0));
      expect(summary.totalCount, equals(1));
      final original = await dbHelper.getTransactionByTxnId('SAFE_TXN_01');
      expect(original, isNotNull);
    });

    test('Decimal precision handles fractional BDT accurately without floating drift', () async {
      await dbHelper.insertTransaction(sampleAddTransaction(
        txnid: 'DEC_IN_1',
        amount: 1250.75,
      ));
      await dbHelper.insertTransaction(sampleAddTransaction(
        txnid: 'DEC_IN_2',
        amount: 349.25,
      ));
      await dbHelper.insertTransaction(samplePayTransaction(
        txnid: 'DEC_OUT_1',
        amount: 600.50,
      ));

      final summary = await dbHelper.getSummary();
      expect(summary.balance, closeTo(999.50, 0.0001));
      expect(summary.totalIn, closeTo(1600.00, 0.0001));
      expect(summary.totalOut, closeTo(600.50, 0.0001));
    });
  });

  group('Receipt Photo Service Integration with Database Records', () {
    late Directory tempDir;
    late ReceiptService receiptService;
    late DatabaseHelper dbHelper;

    setUp(() async {
      tempDir = await createTestTempDir();
      receiptService = createTestReceiptService(tempDir);
      dbHelper = DatabaseHelper(
        databaseFactory: databaseFactoryFfi,
        databasePath: inMemoryDatabasePath,
      );
    });

    tearDown(() async {
      await dbHelper.close();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('Pay transaction links to permanent receipt file on disk', () async {
      const payTxnId = 'TXN_RECEIPT_LINK_1';
      final relativePath = await receiptService.saveReceiptBytes(
        kMinimal1x1JpegBytes,
        payTxnId,
      );

      expect(relativePath, equals('receipts/rec_TXN_RECEIPT_LINK_1.jpg'));

      final payTxn = samplePayTransaction(
        txnid: payTxnId,
        amount: 450.0,
        memoPhotoPath: relativePath,
        notes: 'Pharmacy memo',
      );
      await dbHelper.insertTransaction(payTxn);

      final fetchedTxn = await dbHelper.getTransactionByTxnId(payTxnId);
      expect(fetchedTxn, isNotNull);
      expect(fetchedTxn!.hasMemoPhoto, isTrue);
      expect(fetchedTxn.memoPhotoPath, equals(relativePath));

      // Resolve file via ReceiptService
      final file = await receiptService.getReceiptFile(fetchedTxn.memoPhotoPath);
      expect(file, isNotNull);
      expect(await file!.exists(), isTrue);
      expect(await file.readAsBytes(), equals(kMinimal1x1JpegBytes));
    });

    test('Deleting transaction and associated receipt cleanly removes both', () async {
      const txnid = 'TXN_CLEANUP_01';
      final relativePath = await receiptService.saveReceiptBytes(
        kMinimal1x1JpegBytes,
        txnid,
      );

      final id = await dbHelper.insertTransaction(samplePayTransaction(
        txnid: txnid,
        amount: 200.0,
        memoPhotoPath: relativePath,
      ));

      expect(await receiptService.receiptExists(relativePath), isTrue);

      // Delete from DB and disk
      await dbHelper.deleteTransaction(id);
      await receiptService.deleteReceiptImage(relativePath);

      expect(await dbHelper.getTransactionById(id), isNull);
      expect(await receiptService.receiptExists(relativePath), isFalse);
    });

    test('getAvailableBanknotes tracks physical notes deposited and spent', () async {
      // 1. Add 3 physical banknotes into wallet
      await dbHelper.insertTransaction(sampleAddTransaction(
        txnid: 'ছদ ৬২৮২০৬৬',
        amount: 1000.0,
      ));
      await dbHelper.insertTransaction(sampleAddTransaction(
        txnid: 'কখ ১২৩৪৫৬৭',
        amount: 500.0,
      ));
      await dbHelper.insertTransaction(sampleAddTransaction(
        txnid: 'গঘ ৭৬৫৪৩২১',
        amount: 100.0,
      ));

      var available = await dbHelper.getAvailableBanknotes();
      expect(available.length, equals(3));
      expect(available.map((n) => n.txnid), containsAll(['ছদ ৬২৮২০৬৬', 'কখ ১২৩৪৫৬৭', 'গঘ ৭৬৫৪৩২১']));

      // 2. Spend note 'ছদ ৬২৮২০৬৬' via PAY transaction
      await dbHelper.insertTransaction(samplePayTransaction(
        txnid: 'PAY-ছদ৬২৮২০৬৬',
        amount: 1000.0,
        notes: 'Deducted note: ছদ ৬২৮২০৬৬',
      ));

      available = await dbHelper.getAvailableBanknotes();
      expect(available.length, equals(2));
      expect(available.map((n) => n.txnid), isNot(contains('ছদ ৬২৮২০৬৬')));
      expect(available.map((n) => n.txnid), containsAll(['কখ ১২৩৪৫৬৭', 'গঘ ৭৬৫৪৩২১']));
      expect(await dbHelper.getBalance(), equals(600.0));
    });
  });
}
