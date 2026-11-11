import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pocket_change/models/backup_payload.dart';
import 'package:pocket_change/models/ledger_summary.dart';
import 'package:pocket_change/models/transaction_item.dart';
import 'package:pocket_change/services/backup_service.dart';
import 'package:pocket_change/services/database_helper.dart';
import 'package:pocket_change/services/receipt_service.dart';
import 'package:share_plus/share_plus.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'test_helper.dart';

/// Test mock that simulates an SQLite write error during restoreTransactions.
class FailingDatabaseHelper extends DatabaseHelper {
  FailingDatabaseHelper({
    required super.databaseFactory,
    required super.databasePath,
  });

  @override
  Future<void> restoreTransactions(
    List<TransactionItem> txns, {
    bool clearExisting = true,
  }) async {
    throw Exception('Simulated SQLite batch execution error on commit');
  }
}

void main() {
  setUpAll(() {
    initTestDatabaseFactory();
  });

  group('BackupService: Sharing, Storage & Headless Test Suite', () {
    late Directory testDocsDir;
    late Directory testTempDir;
    late DatabaseHelper dbHelper;
    late ReceiptService receiptService;
    late BackupService backupService;

    // Sharing & FilePicker mock variables
    XFile? capturedSharedFile;
    String? capturedShareSubject;
    FilePickerResult? mockPickerResult;

    setUp(() async {
      testDocsDir = await createTestTempDir(prefix: 'pc_test_docs_');
      testTempDir = await createTestTempDir(prefix: 'pc_test_temp_');

      dbHelper = DatabaseHelper(
        databaseFactory: databaseFactoryFfi,
        databasePath: inMemoryDatabasePath,
      );

      receiptService = ReceiptService(docsDirProvider: () async => testDocsDir);

      capturedSharedFile = null;
      capturedShareSubject = null;
      mockPickerResult = null;

      backupService = BackupService(
        dbHelper: dbHelper,
        receiptService: receiptService,
        docsDirProvider: () async => testDocsDir,
        tempDirProvider: () async => testTempDir,
        shareAction: (files, {subject, text}) async {
          capturedSharedFile = files.first;
          capturedShareSubject = subject;
          return const ShareResult('ok', ShareResultStatus.success);
        },
        filePickerAction: ({FileType type = FileType.any, allowedExtensions}) async => mockPickerResult,
      );
    });

    tearDown(() async {
      await dbHelper.close();
      if (await testDocsDir.exists()) {
        await testDocsDir.delete(recursive: true);
      }
      if (await testTempDir.exists()) {
        await testTempDir.delete(recursive: true);
      }
    });

    // -------------------------------------------------------------------------
    // Group 1: Export Specification & JSON Serialization (5 tests)
    // -------------------------------------------------------------------------
    test('T01: Empty database export produces valid JSON with version 1 and zeroed summary', () async {
      final jsonStr = await backupService.exportBackupJson();
      final decoded = jsonDecode(jsonStr) as Map<String, dynamic>;

      expect(decoded['version'], equals(1));
      expect(decoded['app_version'], equals('1.0.0+1'));
      expect(decoded['app_identifier'], equals('com.pocketchange.mfs'));
      expect(decoded['summary']['total_balance'], equals(0.0));
      expect(decoded['summary']['total_in'], equals(0.0));
      expect(decoded['summary']['total_out'], equals(0.0));
      expect(decoded['summary']['transaction_count'], equals(0));
      expect(decoded['transactions'], isEmpty);
      expect(decoded['checksum'], isNotNull);
    });

    test('T02: Mixed transactions export correctly serializes ADD, PAY, and receipt', () async {
      await dbHelper.insertTransaction(sampleAddTransaction(
        txnid: 'TXN_ADD_1',
        amount: 5000.0,
      ));
      final relPath = await receiptService.saveReceiptBytes(kMinimal1x1JpegBytes, 'TXN_PAY_REC');
      await dbHelper.insertTransaction(samplePayTransaction(
        txnid: 'TXN_PAY_REC',
        amount: 1200.0,
        memoPhotoPath: relPath,
      ));
      await dbHelper.insertTransaction(samplePayTransaction(
        txnid: 'TXN_PAY_NO_REC',
        amount: 350.0,
        memoPhotoPath: null,
      ));

      final jsonStr = await backupService.exportBackupJson();
      final decoded = jsonDecode(jsonStr) as Map<String, dynamic>;
      final txns = decoded['transactions'] as List<dynamic>;

      expect(txns.length, equals(3));
      expect(decoded['summary']['total_balance'], equals(3450.0));
      expect(decoded['summary']['total_in'], equals(5000.0));
      expect(decoded['summary']['total_out'], equals(1550.0));
      expect(decoded['summary']['transaction_count'], equals(3));
    });

    test('T03: Attached receipt photo is encoded to Base64 matching original bytes', () async {
      final relPath = await receiptService.saveReceiptBytes(kMinimal1x1JpegBytes, 'TXN_B64');
      await dbHelper.insertTransaction(samplePayTransaction(
        txnid: 'TXN_B64',
        amount: 500.0,
        memoPhotoPath: relPath,
      ));

      final jsonStr = await backupService.exportBackupJson();
      final decoded = jsonDecode(jsonStr) as Map<String, dynamic>;
      final txn = (decoded['transactions'] as List).first as Map<String, dynamic>;

      expect(txn['memo_photo_base64'], isNotNull);
      final decodedBytes = base64Decode(txn['memo_photo_base64'] as String);
      expect(decodedBytes, equals(kMinimal1x1JpegBytes));
    });

    test('T04: Missing receipt file on disk exports with null memo_photo_base64 gracefully', () async {
      await dbHelper.insertTransaction(samplePayTransaction(
        txnid: 'TXN_GHOST_PHOTO',
        amount: 250.0,
        memoPhotoPath: 'receipts/rec_ghost.jpg',
      ));

      final jsonStr = await backupService.exportBackupJson();
      final decoded = jsonDecode(jsonStr) as Map<String, dynamic>;
      final txn = (decoded['transactions'] as List).first as Map<String, dynamic>;

      expect(txn['memo_photo_base64'], isNull);
    });

    test('T05: exportBackupFile writes file conforming to naming convention', () async {
      final file = await backupService.exportBackupFile();
      expect(await file.exists(), isTrue);

      final fileName = p.basename(file.path);
      final nameRegex = RegExp(r'^pocket_change_backup_\d{8}_\d{6}\.json$');
      expect(nameRegex.hasMatch(fileName), isTrue);

      final content = await file.readAsString();
      final decoded = jsonDecode(content) as Map<String, dynamic>;
      expect(decoded['version'], equals(1));
      expect(decoded['app_identifier'], equals('com.pocketchange.mfs'));
      expect(decoded['summary']['total_balance'], equals(0.0));
      expect(decoded['transactions'], isEmpty);
    });

    // -------------------------------------------------------------------------
    // Group 2: Device File Sharing Integration (2 tests)
    // -------------------------------------------------------------------------
    test('T06: shareBackupFile invokes ShareAction with correct path and MIME type', () async {
      final file = await backupService.exportBackupFile();
      final result = await backupService.shareBackupFile(file);

      expect(result.status, equals(ShareResultStatus.success));
      expect(capturedSharedFile, isNotNull);
      expect(capturedSharedFile!.path, equals(file.path));
      expect(capturedSharedFile!.mimeType, equals('application/json'));
      expect(capturedShareSubject, equals('Pocket Change Backup JSON'));
    });

    test('T07: Share cancellation completes cleanly without error', () async {
      final dismissService = BackupService(
        dbHelper: dbHelper,
        receiptService: receiptService,
        docsDirProvider: () async => testDocsDir,
        tempDirProvider: () async => testTempDir,
        shareAction: (files, {subject, text}) async =>
            const ShareResult('dismissed', ShareResultStatus.dismissed),
      );

      final file = await dismissService.exportBackupFile();
      final result = await dismissService.shareBackupFile(file);
      expect(result.status, equals(ShareResultStatus.dismissed));
    });

    // -------------------------------------------------------------------------
    // Group 3: Import & Full Roundtrip Restoration (5 tests)
    // -------------------------------------------------------------------------
    test('T08: Full roundtrip restore into empty database restores transactions and balance', () async {
      await dbHelper.insertTransaction(sampleAddTransaction(txnid: 'ORIG_ADD', amount: 3000.0));
      final recPath = await receiptService.saveReceiptBytes(kMinimal1x1JpegBytes, 'ORIG_PAY');
      await dbHelper.insertTransaction(samplePayTransaction(
        txnid: 'ORIG_PAY',
        amount: 750.0,
        memoPhotoPath: recPath,
      ));

      final exportedJson = await backupService.exportBackupJson();

      await dbHelper.clearAll();
      await receiptService.deleteAllReceipts();
      expect(await dbHelper.getBalance(), equals(0.0));
      expect(await receiptService.receiptExists(recPath), isFalse);

      final summary = await backupService.importBackupJson(exportedJson);
      expect(summary.restoredTransactionsCount, equals(2));
      expect(summary.restoredPhotosCount, equals(1));
      expect(summary.restoredBalance, equals(2250.0));
      expect(summary.restoredTotalIn, equals(3000.0));
      expect(summary.restoredTotalOut, equals(750.0));

      expect(await dbHelper.getBalance(), equals(2250.0));
      final restoredTxns = await dbHelper.getAllTransactions();
      expect(restoredTxns.length, equals(2));
    });

    test('T09: Restored receipt photo binary matches original byte-for-byte and is viewable', () async {
      final recPath = await receiptService.saveReceiptBytes(kMinimal1x1JpegBytes, 'PHOTO_MATCH');
      await dbHelper.insertTransaction(samplePayTransaction(
        txnid: 'PHOTO_MATCH',
        amount: 800.0,
        memoPhotoPath: recPath,
      ));

      final exportedJson = await backupService.exportBackupJson();

      await dbHelper.clearAll();
      await receiptService.deleteAllReceipts();
      expect(await receiptService.receiptExists(recPath), isFalse);

      await backupService.importBackupJson(exportedJson);

      final restoredFile = await receiptService.getReceiptFile(recPath);
      expect(restoredFile, isNotNull);
      expect(await restoredFile!.readAsBytes(), equals(kMinimal1x1JpegBytes));
    });

    test('T10: Import with clearExisting=true replaces previous data and receipts completely', () async {
      await dbHelper.insertTransaction(sampleAddTransaction(txnid: 'OLD_TXN', amount: 999.0));
      final oldRec = await receiptService.saveReceiptBytes(kMinimal1x1PngBytes, 'OLD_TXN');

      final newPayload = BackupPayload(
        version: 1,
        appVersion: '1.0.0+1',
        appIdentifier: 'com.pocketchange.mfs',
        exportedAt: DateTime.now().toUtc(),
        deviceOs: 'android',
        summary: const LedgerSummary(balance: 500.0, totalIn: 500.0, totalOut: 0.0, totalCount: 1),
        transactions: [sampleAddTransaction(txnid: 'NEW_TXN', amount: 500.0)],
      );

      await backupService.importBackupJson(newPayload.toJsonString(), clearExisting: true);

      expect(await dbHelper.getBalance(), equals(500.0));
      expect(await dbHelper.getTransactionByTxnId('OLD_TXN'), isNull);
      expect(await dbHelper.getTransactionByTxnId('NEW_TXN'), isNotNull);
      expect(await receiptService.receiptExists(oldRec), isFalse);
    });

    test('T11: importBackupFromFile reads JSON from disk file and restores', () async {
      await dbHelper.insertTransaction(sampleAddTransaction(txnid: 'FILE_TXN', amount: 1500.0));
      final exportFile = await backupService.exportBackupFile();
      await dbHelper.clearAll();

      final summary = await backupService.importBackupFromFile(exportFile);
      expect(summary.restoredTransactionsCount, equals(1));
      expect(await dbHelper.getBalance(), equals(1500.0));
    });

    test('T12: importBackupFromPicker restores when picked; returns null on user cancel', () async {
      await dbHelper.insertTransaction(sampleAddTransaction(txnid: 'PICKER_TXN', amount: 2000.0));
      final file = await backupService.exportBackupFile();
      await dbHelper.clearAll();

      mockPickerResult = FilePickerResult([
        PlatformFile(name: p.basename(file.path), size: await file.length(), path: file.path),
      ]);
      final summary = await backupService.importBackupFromPicker();
      expect(summary, isNotNull);
      expect(summary!.restoredTransactionsCount, equals(1));
      expect(await dbHelper.getBalance(), equals(2000.0));

      mockPickerResult = null;
      final cancelled = await backupService.importBackupFromPicker();
      expect(cancelled, isNull);
    });

    // -------------------------------------------------------------------------
    // Group 4: Syntax & Schema Validation Rejection (4 tests)
    // -------------------------------------------------------------------------
    test('T13: Corrupted JSON syntax is rejected without altering database', () async {
      await dbHelper.insertTransaction(sampleAddTransaction(txnid: 'SAFE_1', amount: 1000.0));

      expect(
        () async => await backupService.importBackupJson('{"corrupted_json: true'),
        throwsA(isA<FormatException>()),
      );

      expect(await dbHelper.getBalance(), equals(1000.0));
    });

    test('T14: Missing required top-level keys throws BackupValidationException', () async {
      const invalidJson = '{"transactions": []}';
      expect(
        () async => await backupService.importBackupJson(invalidJson),
        throwsA(isA<BackupValidationException>()),
      );
    });

    test('T15: Unsupported schema version is rejected with version mismatch error', () async {
      const futureVersionJson = '{"version": 99, "summary": {}, "transactions": []}';
      expect(
        () async => await backupService.importBackupJson(futureVersionJson),
        throwsA(isA<BackupValidationException>()),
      );
    });

    test('T16: Invalid transaction type or duplicate txnid within backup is rejected', () async {
      final dupJson = jsonEncode({
        'version': 1,
        'summary': {'total_balance': 200.0, 'total_in': 200.0, 'total_out': 0.0, 'transaction_count': 2},
        'transactions': [
          {'txnid': 'TXN_SAME', 'type': 'ADD', 'amount': 100.0, 'timestamp': 1000},
          {'txnid': 'TXN_SAME', 'type': 'ADD', 'amount': 100.0, 'timestamp': 2000},
        ],
      });
      expect(
        () async => await backupService.importBackupJson(dupJson),
        throwsA(isA<BackupValidationException>()),
      );

      final invalidTypeJson = jsonEncode({
        'version': 1,
        'summary': {'total_balance': 100.0, 'total_in': 100.0, 'total_out': 0.0, 'transaction_count': 1},
        'transactions': [
          {'txnid': 'TXN_INVALID', 'type': 'TRANSFER', 'amount': 100.0, 'timestamp': 1000},
        ],
      });
      expect(
        () async => await backupService.importBackupJson(invalidTypeJson),
        throwsA(isA<BackupValidationException>()),
      );
    });

    // -------------------------------------------------------------------------
    // Group 5: Financial Reconciliation & Checksum Integrity (3 tests)
    // -------------------------------------------------------------------------
    test('T17: Negative or zero amount is rejected before touching SQLite', () async {
      final negJson = jsonEncode({
        'version': 1,
        'summary': {'total_balance': -50.0, 'total_in': 0.0, 'total_out': 50.0, 'transaction_count': 1},
        'transactions': [
          {'txnid': 'TXN_NEG', 'type': 'PAY', 'amount': -50.0, 'timestamp': 1000},
        ],
      });
      expect(
        () async => await backupService.importBackupJson(negJson),
        throwsA(isA<BackupValidationException>()),
      );

      final zeroJson = jsonEncode({
        'version': 1,
        'summary': {'total_balance': 0.0, 'total_in': 0.0, 'total_out': 0.0, 'transaction_count': 1},
        'transactions': [
          {'txnid': 'TXN_ZERO', 'type': 'ADD', 'amount': 0.0, 'timestamp': 1000},
        ],
      });
      expect(
        () async => await backupService.importBackupJson(zeroJson),
        throwsA(isA<BackupValidationException>()),
      );
    });

    test('T18: Declared balance mismatch fails validation with exact discrepancy', () async {
      final mismatchJson = jsonEncode({
        'version': 1,
        'summary': {'total_balance': 5000.0, 'total_in': 5000.0, 'total_out': 0.0, 'transaction_count': 1},
        'transactions': [
          {'txnid': 'TXN_REAL', 'type': 'ADD', 'amount': 1000.0, 'timestamp': 1000},
        ],
      });
      expect(
        () async => await backupService.importBackupJson(mismatchJson),
        throwsA(isA<BackupValidationException>()),
      );
    });

    test('T19: Transaction count mismatch fails validation', () async {
      final mismatchJson = jsonEncode({
        'version': 1,
        'summary': {'total_balance': 1000.0, 'total_in': 1000.0, 'total_out': 0.0, 'transaction_count': 5},
        'transactions': [
          {'txnid': 'TXN_REAL', 'type': 'ADD', 'amount': 1000.0, 'timestamp': 1000},
        ],
      });
      expect(
        () async => await backupService.importBackupJson(mismatchJson),
        throwsA(isA<BackupValidationException>()),
      );
    });

    // -------------------------------------------------------------------------
    // Group 6: Security & Path Traversal Attack Defense (3 tests)
    // -------------------------------------------------------------------------
    test('T20: Relative directory traversal in memo_photo_path is rejected', () async {
      final attackJson = jsonEncode({
        'version': 1,
        'summary': {'total_balance': 100.0, 'total_in': 100.0, 'total_out': 0.0, 'transaction_count': 1},
        'transactions': [
          {
            'txnid': 'TXN_TRAVERSAL',
            'type': 'ADD',
            'amount': 100.0,
            'timestamp': 1000,
            'memo_photo_path': '../../evil_escaped_receipt.jpg',
            'memo_photo_base64': kMinimal1x1JpegBase64,
          },
        ],
      });

      expect(
        () async => await backupService.importBackupJson(attackJson),
        throwsA(isA<BackupValidationException>()),
      );

      final evilFile = File(p.join(testDocsDir.parent.path, 'evil_escaped_receipt.jpg'));
      expect(evilFile.existsSync(), isFalse);
    });

    test('T21: Absolute path traversal is rejected as a security violation', () async {
      final attackJson = jsonEncode({
        'version': 1,
        'summary': {'total_balance': 100.0, 'total_in': 100.0, 'total_out': 0.0, 'transaction_count': 1},
        'transactions': [
          {
            'txnid': 'TXN_ABSOLUTE',
            'type': 'ADD',
            'amount': 100.0,
            'timestamp': 1000,
            'memo_photo_path': '/etc/shadow',
            'memo_photo_base64': kMinimal1x1JpegBase64,
          },
        ],
      });

      expect(
        () async => await backupService.importBackupJson(attackJson),
        throwsA(isA<BackupValidationException>()),
      );
    });

    test('T22: Null-byte injection in memo_photo_path is rejected without writing files', () async {
      final attackJson = jsonEncode({
        'version': 1,
        'summary': {'total_balance': 100.0, 'total_in': 100.0, 'total_out': 0.0, 'transaction_count': 1},
        'transactions': [
          {
            'txnid': 'TXN_NULL_BYTE',
            'type': 'ADD',
            'amount': 100.0,
            'timestamp': 1000,
            'memo_photo_path': 'receipts/rec.jpg\x00.sh',
            'memo_photo_base64': kMinimal1x1JpegBase64,
          },
        ],
      });

      expect(
        () async => await backupService.importBackupJson(attackJson),
        throwsA(isA<BackupValidationException>()),
      );
    });

    // -------------------------------------------------------------------------
    // Group 7: Atomic Two-Phase Rollback & Error Recovery (3 tests)
    // -------------------------------------------------------------------------
    test('T23: Corrupted Base64 photo in multi-transaction backup triggers complete atomic rollback', () async {
      await dbHelper.insertTransaction(sampleAddTransaction(txnid: 'BASE_1', amount: 1500.0));
      final baseRecPath = await receiptService.saveReceiptBytes(kMinimal1x1JpegBytes, 'BASE_1');

      final payloadWithCorruptPhoto = jsonEncode({
        'version': 1,
        'summary': {'total_balance': 1300.0, 'total_in': 2000.0, 'total_out': 700.0, 'transaction_count': 2},
        'transactions': [
          {
            'txnid': 'TXN_VAL_1',
            'type': 'ADD',
            'amount': 2000.0,
            'timestamp': 1000,
            'memo_photo_path': 'receipts/rec_TXN_VAL_1.jpg',
            'memo_photo_base64': kMinimal1x1JpegBase64,
          },
          {
            'txnid': 'TXN_CORRUPT_2',
            'type': 'PAY',
            'amount': 700.0,
            'timestamp': 2000,
            'memo_photo_path': 'receipts/rec_TXN_CORRUPT_2.jpg',
            'memo_photo_base64': '!!!NOT_A_VALID_BASE64_STRING???',
          },
        ],
      });

      bool failed = false;
      try {
        await backupService.importBackupJson(payloadWithCorruptPhoto);
      } catch (_) {
        failed = true;
      }
      expect(failed, isTrue);

      expect(await dbHelper.getBalance(), equals(1500.0));
      final allTxns = await dbHelper.getAllTransactions();
      expect(allTxns.length, equals(1));
      expect(allTxns.first.txnid, equals('BASE_1'));

      expect(await receiptService.receiptExists(baseRecPath), isTrue);
      expect(await receiptService.receiptExists('receipts/rec_TXN_VAL_1.jpg'), isFalse);
    });

    test('T24: Simulated SQLite write error during batch restore triggers full rollback', () async {
      await dbHelper.insertTransaction(sampleAddTransaction(txnid: 'PRE_EXISTING', amount: 1200.0));
      final preRecPath = await receiptService.saveReceiptBytes(kMinimal1x1JpegBytes, 'PRE_EXISTING');

      final failingDb = FailingDatabaseHelper(
        databaseFactory: databaseFactoryFfi,
        databasePath: inMemoryDatabasePath,
      );

      final failingService = BackupService(
        dbHelper: failingDb,
        receiptService: receiptService,
        docsDirProvider: () async => testDocsDir,
        tempDirProvider: () async => testTempDir,
      );

      final validPayload = jsonEncode({
        'version': 1,
        'summary': {'total_balance': 1000.0, 'total_in': 1000.0, 'total_out': 0.0, 'transaction_count': 1},
        'transactions': [
          {
            'txnid': 'FAIL_TXN_1',
            'type': 'ADD',
            'amount': 1000.0,
            'timestamp': 1000,
            'memo_photo_path': 'receipts/rec_FAIL_TXN_1.jpg',
            'memo_photo_base64': kMinimal1x1JpegBase64,
          },
        ],
      });

      bool failed = false;
      try {
        await failingService.importBackupJson(validPayload);
      } catch (_) {
        failed = true;
      }
      expect(failed, isTrue);

      expect(await dbHelper.getBalance(), equals(1200.0));
      expect(await receiptService.receiptExists(preRecPath), isTrue);
      expect(await receiptService.receiptExists('receipts/rec_FAIL_TXN_1.jpg'), isFalse);

      // Verify staging directory is cleaned up
      final entities = testDocsDir.listSync();
      final stagingEntities = entities.where((e) => p.basename(e.path).startsWith('.staging_'));
      expect(stagingEntities, isEmpty);

      await failingDb.close();
    });

    test('T25: Fractional BDT decimal amounts preserve exact precision', () async {
      await dbHelper.insertTransaction(sampleAddTransaction(txnid: 'DEC_1', amount: 1250.75));
      await dbHelper.insertTransaction(samplePayTransaction(txnid: 'DEC_2', amount: 349.25));

      final jsonStr = await backupService.exportBackupJson();
      await dbHelper.clearAll();

      await backupService.importBackupJson(jsonStr);

      final summary = await dbHelper.getSummary();
      expect(summary.balance, closeTo(901.50, 0.0001));
      expect(summary.totalIn, closeTo(1250.75, 0.0001));
      expect(summary.totalOut, closeTo(349.25, 0.0001));
      expect(summary.totalCount, equals(2));
    });

    // -------------------------------------------------------------------------
    // Group 8: Milestone 3 Remediation, Type Robustness & Checksum Verification (6 tests)
    // -------------------------------------------------------------------------
    test('T26: validateBackupJson directly returns isValid == true and genuine calculatedBalance', () async {
      final validJson = jsonEncode({
        'version': 1,
        'app_version': '1.0.0+1',
        'app_identifier': 'com.pocketchange.mfs',
        'exported_at': DateTime.now().toUtc().toIso8601String(),
        'device_os': 'android',
        'summary': {
          'total_balance': 5000.0,
          'total_in': 5000.0,
          'total_out': 0.0,
          'transaction_count': 1,
        },
        'transactions': [
          {
            'txnid': 'TXN_VALID_5000',
            'type': 'ADD',
            'amount': 5000.0,
            'timestamp': 1700000000000,
          },
        ],
      });

      final result = await backupService.validateBackupJson(validJson);
      expect(result.isValid, isTrue);
      expect(result.calculatedBalance, equals(5000.0));
      expect(result.transactionCount, equals(1));
      expect(result.payload, isNotNull);
      expect(result.payload!.summary.balance, equals(5000.0));
      expect(result.payload!.summary.totalCount, equals(1));
    });

    test('T27: BackupPayload.fromJsonString round-trips preserving summary.balance and totalCount', () {
      const originalSummary = LedgerSummary(
        balance: 3450.0,
        totalIn: 5000.0,
        totalOut: 1550.0,
        totalCount: 3,
      );
      final payload = BackupPayload(
        version: 1,
        appVersion: '1.0.0+1',
        appIdentifier: 'com.pocketchange.mfs',
        exportedAt: DateTime.now().toUtc(),
        deviceOs: 'android',
        summary: originalSummary,
        transactions: [
          sampleAddTransaction(txnid: 'TXN_R_1', amount: 5000.0),
          samplePayTransaction(txnid: 'TXN_R_2', amount: 1000.0),
          samplePayTransaction(txnid: 'TXN_R_3', amount: 550.0),
        ],
      );

      final jsonStr = payload.toJsonString();
      final roundTripped = BackupPayload.fromJsonString(jsonStr);

      expect(roundTripped.summary.balance, equals(3450.0));
      expect(roundTripped.summary.totalIn, equals(5000.0));
      expect(roundTripped.summary.totalOut, equals(1550.0));
      expect(roundTripped.summary.totalCount, equals(3));
      expect(roundTripped.transactionCount, equals(3));
    });

    test('T28: validateBackupJson rejects malformed primitive types (string balance, non-string photo path, double timestamp)', () async {
      // 1. String balance instead of num
      final stringBalanceJson = jsonEncode({
        'version': 1,
        'summary': {
          'total_balance': '5000.0', // invalid string
          'total_in': 5000.0,
          'total_out': 0.0,
          'transaction_count': 1,
        },
        'transactions': [
          {'txnid': 'TXN_1', 'type': 'ADD', 'amount': 5000.0, 'timestamp': 1000},
        ],
      });
      final res1 = await backupService.validateBackupJson(stringBalanceJson);
      expect(res1.isValid, isFalse);
      expect(res1.errors.any((e) => e.contains('Summary is missing required total fields or has invalid numeric types.')), isTrue);

      // 2. Integer memo_photo_path instead of string
      final intPhotoPathJson = jsonEncode({
        'version': 1,
        'summary': {'total_balance': 100.0, 'total_in': 100.0, 'total_out': 0.0, 'transaction_count': 1},
        'transactions': [
          {
            'txnid': 'TXN_2',
            'type': 'ADD',
            'amount': 100.0,
            'timestamp': 1000,
            'memo_photo_path': 12345, // invalid int
          },
        ],
      });
      final res2 = await backupService.validateBackupJson(intPhotoPathJson);
      expect(res2.isValid, isFalse);
      expect(res2.errors.any((e) => e.contains('memo_photo_path must be a string')), isTrue);

      // 3. Double timestamp instead of int or ISO string
      final doubleTimestampJson = jsonEncode({
        'version': 1,
        'summary': {'total_balance': 100.0, 'total_in': 100.0, 'total_out': 0.0, 'transaction_count': 1},
        'transactions': [
          {
            'txnid': 'TXN_3',
            'type': 'ADD',
            'amount': 100.0,
            'timestamp': 1700000000.55, // invalid double
          },
        ],
      });
      final res3 = await backupService.validateBackupJson(doubleTimestampJson);
      expect(res3.isValid, isFalse);
      expect(res3.errors.any((e) => e.contains('invalid timestamp type')), isTrue);
    });

    test('T29: Checksum verification detects tampered records when checksum is present', () async {
      await dbHelper.insertTransaction(sampleAddTransaction(
        txnid: 'TXN_CS_1',
        amount: 2000.0,
        timestamp: DateTime.fromMillisecondsSinceEpoch(1000000),
      ));
      await dbHelper.insertTransaction(sampleAddTransaction(
        txnid: 'TXN_CS_2',
        amount: 3000.0,
        timestamp: DateTime.fromMillisecondsSinceEpoch(2000000),
      ));

      final originalJson = await backupService.exportBackupJson();
      final decoded = jsonDecode(originalJson) as Map<String, dynamic>;
      final originalChecksum = decoded['checksum'] as String;

      // Legitimate validation has no warnings
      final legitResult = await backupService.validateBackupJson(originalJson);
      expect(legitResult.isValid, isTrue);
      expect(legitResult.hasWarnings, isFalse);

      // Offset tamper: change amounts 2000->2500 and 3000->2500. TotalIn is still 5000.0, balance is still 5000.0
      final tampered = Map<String, dynamic>.from(decoded);
      final txns = List<Map<String, dynamic>>.from(tampered['transactions'] as List);
      txns[0] = Map<String, dynamic>.from(txns[0])..['amount'] = 2500.0;
      txns[1] = Map<String, dynamic>.from(txns[1])..['amount'] = 2500.0;
      tampered['transactions'] = txns;
      tampered['checksum'] = originalChecksum; // original checksum for 2000|3000

      final tamperedResult = await backupService.validateBackupJson(jsonEncode(tampered));
      expect(tamperedResult.hasWarnings, isTrue);
      expect(tamperedResult.warnings.any((w) => w.contains('Backup checksum mismatch')), isTrue);
    });

    test('T30: Base64 pre-allocation guard rejects oversized image string before decode', () async {
      const oversizedLen = (25 * 1024 * 1024 * 4 ~/ 3 + 10);
      final hugeBase64 = 'A' * oversizedLen;

      final hugeJson = jsonEncode({
        'version': 1,
        'summary': {'total_balance': 100.0, 'total_in': 100.0, 'total_out': 0.0, 'transaction_count': 1},
        'transactions': [
          {
            'txnid': 'TXN_HUGE_PHOTO',
            'type': 'ADD',
            'amount': 100.0,
            'timestamp': 1000,
            'memo_photo_path': 'receipts/rec_TXN_HUGE_PHOTO.jpg',
            'memo_photo_base64': hugeBase64,
          },
        ],
      });

      final result = await backupService.validateBackupJson(hugeJson);
      expect(result.isValid, isFalse);
      expect(result.errors.any((e) => e.contains('exceeds 25MB safety limit')), isTrue);
    });

    test('T31: validateBackupJson top-level safety net returns failure on unexpected structures without throwing', () async {
      final malformedArrayJson = jsonEncode({
        'version': 1,
        'summary': {'total_balance': 100.0, 'total_in': 100.0, 'total_out': 0.0, 'transaction_count': 1},
        'transactions': [42],
      });

      final result = await backupService.validateBackupJson(malformedArrayJson);
      expect(result.isValid, isFalse);
      expect(result.errors.isNotEmpty, isTrue);
    });
  });
}
