import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pocket_change/models/backup_payload.dart';
import 'package:pocket_change/models/transaction_item.dart';
import 'package:pocket_change/services/backup_service.dart';
import 'package:pocket_change/services/database_helper.dart';
import 'package:pocket_change/services/receipt_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'test_helper.dart';

final String kMinimal1x1PngBase64 = base64Encode(kMinimal1x1PngBytes);

/// Custom mock DatabaseHelper to simulate SQLite failure during restoreTransactions
class ConstraintFailingDatabaseHelper extends DatabaseHelper {
  ConstraintFailingDatabaseHelper({
    required super.databaseFactory,
    required super.databasePath,
  });

  @override
  Future<void> restoreTransactions(
    List<TransactionItem> txns, {
    bool clearExisting = true,
  }) async {
    throw Exception('UNIQUE constraint failed: transactions.txnid (simulated)');
  }
}

void main() {
  setUpAll(() {
    initTestDatabaseFactory();
  });

  group('Challenger M3.2: Path Traversal, Atomic Rollback & Payload Rejection Harness', () {
    late Directory testSandboxRoot;
    late Directory testDocsDir;
    late Directory testTempDir;
    late DatabaseHelper dbHelper;
    late ReceiptService receiptService;
    late BackupService backupService;

    setUp(() async {
      testSandboxRoot = await createTestTempDir(prefix: 'pc_m3_challenger_root_');
      testDocsDir = Directory(p.join(testSandboxRoot.path, 'docs'))..createSync();
      testTempDir = Directory(p.join(testSandboxRoot.path, 'temp'))..createSync();

      dbHelper = DatabaseHelper(
        databaseFactory: databaseFactoryFfi,
        databasePath: inMemoryDatabasePath,
      );

      receiptService = ReceiptService(docsDirProvider: () async => testDocsDir);

      backupService = BackupService(
        dbHelper: dbHelper,
        receiptService: receiptService,
        docsDirProvider: () async => testDocsDir,
        tempDirProvider: () async => testTempDir,
      );
    });

    tearDown(() async {
      await dbHelper.close();
      if (await testSandboxRoot.exists()) {
        await testSandboxRoot.delete(recursive: true);
      }
    });

    /// Helper to build balanced backup JSON with arbitrary transactions
    String buildBackupJson({
      required List<Map<String, dynamic>> transactions,
      int version = 1,
    }) {
      double totalIn = 0.0;
      double totalOut = 0.0;
      for (final t in transactions) {
        final type = (t['type'] as String).toUpperCase();
        final amt = (t['amount'] as num).toDouble();
        if (type == 'ADD') {
          totalIn += amt;
        } else if (type == 'PAY') {
          totalOut += amt;
        }
      }
      return jsonEncode({
        'version': version,
        'app_version': '1.0.0+1',
        'app_identifier': 'com.pocketchange.mfs',
        'exported_at': DateTime.now().toUtc().toIso8601String(),
        'device_os': 'linux',
        'summary': {
          'total_balance': totalIn - totalOut,
          'total_in': totalIn,
          'total_out': totalOut,
          'transaction_count': transactions.length,
        },
        'transactions': transactions,
      });
    }

    // =========================================================================
    // SECTION 1: Path Traversal Attack Variations (Empirical Verification)
    // =========================================================================
    group('Section 1: Path Traversal Attack Defense', () {
      test('T01: Standard relative escape (../../escaped.jpg) rejected, no file outside sandbox', () async {
        final payload = buildBackupJson(
          transactions: [
            {
              'txnid': 'TXN_TRAV_01',
              'type': 'ADD',
              'amount': 100.0,
              'timestamp': 1000,
              'memo_photo_path': '../../escaped_t01.jpg',
              'memo_photo_base64': kMinimal1x1JpegBase64,
            },
          ],
        );

        final validation = await backupService.validateBackupJson(payload);
        expect(validation.isValid, isFalse);
        expect(
          validation.errors.any((e) => e.contains('forbidden path traversal') || e.contains('does not conform')),
          isTrue,
        );

        expect(
          () async => await backupService.importBackupJson(payload),
          throwsA(isA<BackupValidationException>()),
        );

        final escapedFile = File(p.join(testDocsDir.parent.path, 'escaped_t01.jpg'));
        expect(escapedFile.existsSync(), isFalse);
      });

      test('T02: Deep multi-directory escape (../../../../../../../../tmp/escaped.jpg) rejected', () async {
        final payload = buildBackupJson(
          transactions: [
            {
              'txnid': 'TXN_TRAV_02',
              'type': 'ADD',
              'amount': 100.0,
              'timestamp': 1000,
              'memo_photo_path': '../../../../../../../../tmp/escaped_t02.jpg',
              'memo_photo_base64': kMinimal1x1JpegBase64,
            },
          ],
        );

        final validation = await backupService.validateBackupJson(payload);
        expect(validation.isValid, isFalse);
        expect(
          () async => await backupService.importBackupJson(payload),
          throwsA(isA<BackupValidationException>()),
        );

        final escapedFile = File('/tmp/escaped_t02.jpg');
        expect(escapedFile.existsSync(), isFalse);
      });

      test('T03: Embedded traversal within prefix (receipts/../../escaped.jpg) rejected', () async {
        final payload = buildBackupJson(
          transactions: [
            {
              'txnid': 'TXN_TRAV_03',
              'type': 'ADD',
              'amount': 100.0,
              'timestamp': 1000,
              'memo_photo_path': 'receipts/../../escaped_t03.jpg',
              'memo_photo_base64': kMinimal1x1JpegBase64,
            },
          ],
        );

        final validation = await backupService.validateBackupJson(payload);
        expect(validation.isValid, isFalse);
        expect(
          () async => await backupService.importBackupJson(payload),
          throwsA(isA<BackupValidationException>()),
        );
      });

      test('T04: Redundant traversal segments (receipts/../receipts/../escaped.jpg) rejected', () async {
        final payload = buildBackupJson(
          transactions: [
            {
              'txnid': 'TXN_TRAV_04',
              'type': 'ADD',
              'amount': 100.0,
              'timestamp': 1000,
              'memo_photo_path': 'receipts/../receipts/../escaped_t04.jpg',
              'memo_photo_base64': kMinimal1x1JpegBase64,
            },
          ],
        );

        final validation = await backupService.validateBackupJson(payload);
        expect(validation.isValid, isFalse);
        expect(
          () async => await backupService.importBackupJson(payload),
          throwsA(isA<BackupValidationException>()),
        );
      });

      test('T05: URL-encoded traversal (%2e%2e%2fescaped.jpg) rejected by strict whitelist', () async {
        final payload = buildBackupJson(
          transactions: [
            {
              'txnid': 'TXN_TRAV_05',
              'type': 'ADD',
              'amount': 100.0,
              'timestamp': 1000,
              'memo_photo_path': '%2e%2e%2fescaped_t05.jpg',
              'memo_photo_base64': kMinimal1x1JpegBase64,
            },
          ],
        );

        final validation = await backupService.validateBackupJson(payload);
        expect(validation.isValid, isFalse);
        expect(
          () async => await backupService.importBackupJson(payload),
          throwsA(isA<BackupValidationException>()),
        );
      });

      test('T06: URL-encoded traversal within path (receipts/%2e%2e/escaped.jpg) rejected', () async {
        final payload = buildBackupJson(
          transactions: [
            {
              'txnid': 'TXN_TRAV_06',
              'type': 'ADD',
              'amount': 100.0,
              'timestamp': 1000,
              'memo_photo_path': 'receipts/%2e%2e/escaped_t06.jpg',
              'memo_photo_base64': kMinimal1x1JpegBase64,
            },
          ],
        );

        final validation = await backupService.validateBackupJson(payload);
        expect(validation.isValid, isFalse);
        expect(
          () async => await backupService.importBackupJson(payload),
          throwsA(isA<BackupValidationException>()),
        );
      });

      test('T07: Null-byte injection with traversal (receipts/rec_123.jpg\\x00../../escaped.jpg) rejected', () async {
        final payload = buildBackupJson(
          transactions: [
            {
              'txnid': 'TXN_TRAV_07',
              'type': 'ADD',
              'amount': 100.0,
              'timestamp': 1000,
              'memo_photo_path': 'receipts/rec_123.jpg\x00../../escaped_t07.jpg',
              'memo_photo_base64': kMinimal1x1JpegBase64,
            },
          ],
        );

        final validation = await backupService.validateBackupJson(payload);
        expect(validation.isValid, isFalse);
        expect(validation.errors.any((e) => e.contains('forbidden null bytes')), isTrue);
        expect(
          () async => await backupService.importBackupJson(payload),
          throwsA(isA<BackupValidationException>()),
        );
      });

      test('T08: Null-byte injection with script extension (receipts/rec_123.jpg\\x00.sh) rejected', () async {
        final payload = buildBackupJson(
          transactions: [
            {
              'txnid': 'TXN_TRAV_08',
              'type': 'ADD',
              'amount': 100.0,
              'timestamp': 1000,
              'memo_photo_path': 'receipts/rec_123.jpg\x00.sh',
              'memo_photo_base64': kMinimal1x1JpegBase64,
            },
          ],
        );

        final validation = await backupService.validateBackupJson(payload);
        expect(validation.isValid, isFalse);
        expect(validation.errors.any((e) => e.contains('forbidden null bytes')), isTrue);
        expect(
          () async => await backupService.importBackupJson(payload),
          throwsA(isA<BackupValidationException>()),
        );
      });

      test('T09: Leading null-byte (\\x00receipts/rec_123.jpg) rejected', () async {
        final payload = buildBackupJson(
          transactions: [
            {
              'txnid': 'TXN_TRAV_09',
              'type': 'ADD',
              'amount': 100.0,
              'timestamp': 1000,
              'memo_photo_path': '\x00receipts/rec_123.jpg',
              'memo_photo_base64': kMinimal1x1JpegBase64,
            },
          ],
        );

        final validation = await backupService.validateBackupJson(payload);
        expect(validation.isValid, isFalse);
        expect(validation.errors.any((e) => e.contains('forbidden null bytes')), isTrue);
      });

      test('T10: Absolute path Linux root (/tmp/escaped.jpg) rejected as non-relative', () async {
        final payload = buildBackupJson(
          transactions: [
            {
              'txnid': 'TXN_TRAV_10',
              'type': 'ADD',
              'amount': 100.0,
              'timestamp': 1000,
              'memo_photo_path': '/tmp/escaped_t10.jpg',
              'memo_photo_base64': kMinimal1x1JpegBase64,
            },
          ],
        );

        final validation = await backupService.validateBackupJson(payload);
        expect(validation.isValid, isFalse);
        expect(validation.errors.any((e) => e.contains('must be a relative path, not absolute')), isTrue);
        expect(
          () async => await backupService.importBackupJson(payload),
          throwsA(isA<BackupValidationException>()),
        );
      });

      test('T11: Absolute path Linux system (/etc/shadow) rejected', () async {
        final payload = buildBackupJson(
          transactions: [
            {
              'txnid': 'TXN_TRAV_11',
              'type': 'ADD',
              'amount': 100.0,
              'timestamp': 1000,
              'memo_photo_path': '/etc/shadow',
              'memo_photo_base64': kMinimal1x1JpegBase64,
            },
          ],
        );

        final validation = await backupService.validateBackupJson(payload);
        expect(validation.isValid, isFalse);
        expect(validation.errors.any((e) => e.contains('must be a relative path, not absolute')), isTrue);
      });

      test('T12: Windows drive letter paths (C:\\escaped.jpg and D:/escaped.jpg) rejected', () async {
        for (final winPath in ['C:\\escaped_t12.jpg', 'D:/escaped_t12.jpg', 'c:/data/rec.png']) {
          final payload = buildBackupJson(
            transactions: [
              {
                'txnid': 'TXN_TRAV_12',
                'type': 'ADD',
                'amount': 100.0,
                'timestamp': 1000,
                'memo_photo_path': winPath,
                'memo_photo_base64': kMinimal1x1JpegBase64,
              },
            ],
          );

          final validation = await backupService.validateBackupJson(payload);
          expect(validation.isValid, isFalse, reason: 'Path $winPath should have been rejected');
          expect(
            validation.errors.any((e) => e.contains('relative') || e.contains('does not conform')),
            isTrue,
            reason: 'Path $winPath error missing relative/conform error',
          );
        }
      });

      test('T13: UNC network share path (\\\\attacker\\share\\rec.jpg) rejected', () async {
        final payload = buildBackupJson(
          transactions: [
            {
              'txnid': 'TXN_TRAV_13',
              'type': 'ADD',
              'amount': 100.0,
              'timestamp': 1000,
              'memo_photo_path': '\\\\attacker\\share\\rec.jpg',
              'memo_photo_base64': kMinimal1x1JpegBase64,
            },
          ],
        );

        final validation = await backupService.validateBackupJson(payload);
        expect(validation.isValid, isFalse);
      });

      test('T14: Malicious txnid containing directory climbing (../../EVIL) rejected', () async {
        final payload = buildBackupJson(
          transactions: [
            {
              'txnid': '../../EVIL_TXN',
              'type': 'ADD',
              'amount': 100.0,
              'timestamp': 1000,
              'memo_photo_path': 'receipts/rec_EVIL.jpg',
              'memo_photo_base64': kMinimal1x1JpegBase64,
            },
          ],
        );

        final validation = await backupService.validateBackupJson(payload);
        expect(validation.isValid, isFalse);
        expect(validation.errors.any((e) => e.contains('contains invalid characters')), isTrue);
        expect(
          () async => await backupService.importBackupJson(payload),
          throwsA(isA<BackupValidationException>()),
        );
      });

      test('T15: Backslash relative traversal (..\\..\\escaped.jpg) rejected', () async {
        final payload = buildBackupJson(
          transactions: [
            {
              'txnid': 'TXN_TRAV_15',
              'type': 'ADD',
              'amount': 100.0,
              'timestamp': 1000,
              'memo_photo_path': '..\\..\\escaped_t15.jpg',
              'memo_photo_base64': kMinimal1x1JpegBase64,
            },
          ],
        );

        final validation = await backupService.validateBackupJson(payload);
        expect(validation.isValid, isFalse);
      });

      test('T16: Extension bypass attempts (.jpg.sh, .exe, .php, shell injection) rejected', () async {
        final bypassPaths = [
          'receipts/rec_123.jpg.sh',
          'receipts/rec_123.exe',
          'receipts/rec_123.php',
          'receipts/rec_123.jpg;rm -rf /',
          'receipts/rec_123.jpg&calc.exe',
          'receipts/rec_123.html',
        ];

        for (final pth in bypassPaths) {
          final payload = buildBackupJson(
            transactions: [
              {
                'txnid': 'TXN_BYPASS',
                'type': 'ADD',
                'amount': 100.0,
                'timestamp': 1000,
                'memo_photo_path': pth,
                'memo_photo_base64': kMinimal1x1JpegBase64,
              },
            ],
          );

          final validation = await backupService.validateBackupJson(payload);
          expect(validation.isValid, isFalse, reason: 'Bypass path $pth should be invalid');
        }
      });

      test('T17: Empirical Sandbox Verification: no files created outside docsDir', () async {
        final sandboxParent = testDocsDir.parent;
        final initialFilesInParent = sandboxParent.listSync().map((e) => e.path).toSet();

        // Run multi-vector traversal assault
        final attackPayloads = [
          '../../sandbox_leak_1.jpg',
          '../../../sandbox_leak_2.jpg',
          '/tmp/sandbox_leak_3.jpg',
          'receipts/../../../sandbox_leak_4.jpg',
        ];

        for (int i = 0; i < attackPayloads.length; i++) {
          final jsonStr = buildBackupJson(
            transactions: [
              {
                'txnid': 'TXN_ASSAULT_$i',
                'type': 'ADD',
                'amount': 50.0,
                'timestamp': 1000 + i,
                'memo_photo_path': attackPayloads[i],
                'memo_photo_base64': kMinimal1x1JpegBase64,
              },
            ],
          );

          try {
            await backupService.importBackupJson(jsonStr);
          } catch (_) {
            // Expected rejection
          }
        }

        // Verify parent directory has no new files
        final currentFilesInParent = sandboxParent.listSync().map((e) => e.path).toSet();
        final newlyCreatedFiles = currentFilesInParent.difference(initialFilesInParent);
        expect(newlyCreatedFiles, isEmpty, reason: 'Files leaked to sandbox parent: $newlyCreatedFiles');

        // Verify /tmp has no leaked files
        expect(File('/tmp/sandbox_leak_3.jpg').existsSync(), isFalse);
      });
    });

    // =========================================================================
    // SECTION 2: Atomic Rollback Stress Testing
    // =========================================================================
    group('Section 2: Atomic Rollback Stress Testing', () {
      test('T18: Mid-stream corrupt Base64 on transaction 10 of 20 guarantees 100% rollback', () async {
        // 1. Establish pre-existing state
        await dbHelper.insertTransaction(sampleAddTransaction(txnid: 'PRE_1', amount: 5000.0));
        await dbHelper.insertTransaction(samplePayTransaction(txnid: 'PRE_2', amount: 1000.0));
        await dbHelper.insertTransaction(sampleAddTransaction(txnid: 'PRE_3', amount: 3500.0));
        final rec1 = await receiptService.saveReceiptBytes(kMinimal1x1JpegBytes, 'PRE_REC_1');
        final rec2 = await receiptService.saveReceiptBytes(kMinimal1x1PngBytes, 'PRE_REC_2');
        final rec3 = await receiptService.saveReceiptBytes(kMinimal1x1JpegBytes, 'PRE_REC_3');

        expect(await dbHelper.getBalance(), equals(7500.0));
        expect((await dbHelper.getAllTransactions()).length, equals(3));
        expect(await receiptService.receiptExists(rec1), isTrue);
        expect(await receiptService.receiptExists(rec2), isTrue);
        expect(await receiptService.receiptExists(rec3), isTrue);

        // 2. Build 20-transaction payload where txn 10 has corrupted Base64
        final List<Map<String, dynamic>> rawTxns = [];
        for (int i = 1; i <= 20; i++) {
          final txnid = 'BATCH_TXN_${i.toString().padLeft(2, '0')}';
          if (i == 10) {
            // Corrupted Base64 string
            rawTxns.add({
              'txnid': txnid,
              'type': 'PAY',
              'amount': 100.0,
              'timestamp': 10000 + i,
              'memo_photo_path': 'receipts/rec_$txnid.jpg',
              'memo_photo_base64': '!!!CORRUPT_BASE_64_DATA_NOT_VALID???==',
            });
          } else {
            rawTxns.add({
              'txnid': txnid,
              'type': i.isOdd ? 'ADD' : 'PAY',
              'amount': 150.0,
              'timestamp': 10000 + i,
              'memo_photo_path': 'receipts/rec_$txnid.jpg',
              'memo_photo_base64': i.isOdd ? kMinimal1x1JpegBase64 : kMinimal1x1PngBase64,
            });
          }
        }

        final attackJson = buildBackupJson(transactions: rawTxns);

        // 3. Attempt import — MUST throw
        bool threwException = false;
        try {
          await backupService.importBackupJson(attackJson);
        } on BackupValidationException {
          threwException = true;
        }
        expect(threwException, isTrue);

        // 4. Verify pre-existing SQLite state is 100% intact
        expect(await dbHelper.getBalance(), equals(7500.0));
        final postTxns = await dbHelper.getAllTransactions();
        expect(postTxns.length, equals(3));
        expect(postTxns.map((t) => t.txnid).toSet(), equals({'PRE_1', 'PRE_2', 'PRE_3'}));

        // 5. Verify pre-existing receipt files remain 100% intact
        expect(await receiptService.receiptExists(rec1), isTrue);
        expect(await receiptService.receiptExists(rec2), isTrue);
        expect(await receiptService.receiptExists(rec3), isTrue);

        // 6. Verify none of the 9 prior batch transactions leaked into receipts
        for (int i = 1; i <= 9; i++) {
          final leakedPath = 'receipts/rec_BATCH_TXN_${i.toString().padLeft(2, '0')}.jpg';
          expect(await receiptService.receiptExists(leakedPath), isFalse);
        }

        // 7. Verify zero staging directories remain
        final stagingDirs = testDocsDir.listSync().where((e) => p.basename(e.path).startsWith('.staging_'));
        expect(stagingDirs, isEmpty, reason: 'Staging directory was not cleaned up');
      });

      test('T19: Mid-stream truncated Base64 padding error triggers complete rollback', () async {
        await dbHelper.insertTransaction(sampleAddTransaction(txnid: 'INIT_ADD', amount: 2000.0));
        final initRec = await receiptService.saveReceiptBytes(kMinimal1x1JpegBytes, 'INIT_ADD');

        final List<Map<String, dynamic>> rawTxns = [];
        for (int i = 1; i <= 10; i++) {
          final txnid = 'TRUNC_TXN_$i';
          rawTxns.add({
            'txnid': txnid,
            'type': 'ADD',
            'amount': 100.0,
            'timestamp': 1000 + i,
            'memo_photo_path': 'receipts/rec_$txnid.jpg',
            // Truncated Base64 on index 5
            'memo_photo_base64': i == 5 ? kMinimal1x1JpegBase64.substring(0, 15) : kMinimal1x1JpegBase64,
          });
        }

        final payload = buildBackupJson(transactions: rawTxns);

        expect(
          () async => await backupService.importBackupJson(payload),
          throwsA(isA<BackupValidationException>()),
        );

        // Verify pre-existing state untouched
        expect(await dbHelper.getBalance(), equals(2000.0));
        expect(await receiptService.receiptExists(initRec), isTrue);

        // Staging clean
        final staging = testDocsDir.listSync().where((e) => p.basename(e.path).startsWith('.staging_'));
        expect(staging, isEmpty);
      });

      test('T20: Mid-stream non-image shell script on txn 10 of 20 triggers complete rollback', () async {
        await dbHelper.insertTransaction(sampleAddTransaction(txnid: 'STABLE_TXN', amount: 4000.0));

        final scriptBase64 = base64Encode(utf8.encode('#!/bin/bash\necho "exploit"\nexit 1\n'));

        final List<Map<String, dynamic>> rawTxns = [];
        for (int i = 1; i <= 20; i++) {
          final txnid = 'SCRIPT_BATCH_$i';
          rawTxns.add({
            'txnid': txnid,
            'type': 'ADD',
            'amount': 50.0,
            'timestamp': 2000 + i,
            'memo_photo_path': 'receipts/rec_$txnid.jpg',
            'memo_photo_base64': i == 10 ? scriptBase64 : kMinimal1x1JpegBase64,
          });
        }

        final payload = buildBackupJson(transactions: rawTxns);

        expect(
          () async => await backupService.importBackupJson(payload),
          throwsA(isA<BackupValidationException>()),
        );

        expect(await dbHelper.getBalance(), equals(4000.0));
        expect((await dbHelper.getAllTransactions()).length, equals(1));
        final staging = testDocsDir.listSync().where((e) => p.basename(e.path).startsWith('.staging_'));
        expect(staging, isEmpty);
      });

      test('T21: Simulated SQLite constraint failure during batch commit triggers full rollback', () async {
        await dbHelper.insertTransaction(sampleAddTransaction(txnid: 'PERSISTED_TXN', amount: 3300.0));
        final persistedRec = await receiptService.saveReceiptBytes(kMinimal1x1JpegBytes, 'PERSISTED_TXN');

        // Use custom failing database helper
        final failingDb = ConstraintFailingDatabaseHelper(
          databaseFactory: databaseFactoryFfi,
          databasePath: inMemoryDatabasePath,
        );

        final failingService = BackupService(
          dbHelper: failingDb,
          receiptService: receiptService,
          docsDirProvider: () async => testDocsDir,
          tempDirProvider: () async => testTempDir,
        );

        final payload = buildBackupJson(
          transactions: [
            {
              'txnid': 'FAIL_COMMIT_1',
              'type': 'ADD',
              'amount': 1000.0,
              'timestamp': 1000,
              'memo_photo_path': 'receipts/rec_FAIL_COMMIT_1.jpg',
              'memo_photo_base64': kMinimal1x1JpegBase64,
            },
          ],
        );

        bool threw = false;
        try {
          await failingService.importBackupJson(payload);
        } catch (_) {
          threw = true;
        }
        expect(threw, isTrue);

        // Pre-existing state preserved
        expect(await dbHelper.getBalance(), equals(3300.0));
        expect(await receiptService.receiptExists(persistedRec), isTrue);
        expect(await receiptService.receiptExists('receipts/rec_FAIL_COMMIT_1.jpg'), isFalse);

        // Staging cleaned up
        final staging = testDocsDir.listSync().where((e) => p.basename(e.path).startsWith('.staging_'));
        expect(staging, isEmpty);

        await failingDb.close();
      });

      test('T22: High-volume 50-transaction batch with failure at txn 49 rolls back atomically', () async {
        await dbHelper.insertTransaction(sampleAddTransaction(txnid: 'ORIGINAL_BASE', amount: 50000.0));
        final baseRec = await receiptService.saveReceiptBytes(kMinimal1x1JpegBytes, 'ORIGINAL_BASE');

        final List<Map<String, dynamic>> rawTxns = [];
        for (int i = 1; i <= 50; i++) {
          final txnid = 'HIGH_VOL_$i';
          rawTxns.add({
            'txnid': txnid,
            'type': 'ADD',
            'amount': 1000.0,
            'timestamp': 5000 + i,
            'memo_photo_path': 'receipts/rec_$txnid.jpg',
            // Corrupt on 49
            'memo_photo_base64': i == 49 ? 'NOT_VALID_BASE64' : kMinimal1x1JpegBase64,
          });
        }

        final payload = buildBackupJson(transactions: rawTxns);

        expect(
          () async => await backupService.importBackupJson(payload),
          throwsA(isA<BackupValidationException>()),
        );

        // Balance remains 50000, exactly 1 transaction
        expect(await dbHelper.getBalance(), equals(50000.0));
        final currentTxns = await dbHelper.getAllTransactions();
        expect(currentTxns.length, equals(1));
        expect(currentTxns.first.txnid, equals('ORIGINAL_BASE'));
        expect(await receiptService.receiptExists(baseRec), isTrue);

        // None of the 48 valid photos leaked
        for (int i = 1; i <= 48; i++) {
          expect(await receiptService.receiptExists('receipts/rec_HIGH_VOL_$i.jpg'), isFalse);
        }

        // Staging cleaned up
        final staging = testDocsDir.listSync().where((e) => p.basename(e.path).startsWith('.staging_'));
        expect(staging, isEmpty);
      });
    });

    // =========================================================================
    // SECTION 3: Non-Image File Rejection (Content & Magic Byte Inspection)
    // =========================================================================
    group('Section 3: Non-Image File Rejection', () {
      test('T23: Shell script payload (#!/bin/bash) masquerading as .jpg rejected', () async {
        final shellBytes = utf8.encode('#!/bin/bash\nrm -rf / \n');
        final payload = buildBackupJson(
          transactions: [
            {
              'txnid': 'TXN_SHELL',
              'type': 'ADD',
              'amount': 100.0,
              'timestamp': 1000,
              'memo_photo_path': 'receipts/rec_TXN_SHELL.jpg',
              'memo_photo_base64': base64Encode(shellBytes),
            },
          ],
        );

        final validation = await backupService.validateBackupJson(payload);
        expect(validation.isValid, isFalse);
        expect(
          validation.errors.any((e) => e.contains('not a valid JPEG or PNG image')),
          isTrue,
        );
        expect(
          () async => await backupService.importBackupJson(payload),
          throwsA(isA<BackupValidationException>()),
        );
      });

      test('T24: Windows PE executable (MZ header) masquerading as .jpg rejected', () async {
        final peBytes = Uint8List.fromList([
          0x4D, 0x5A, 0x90, 0x00, 0x03, 0x00, 0x00, 0x00,
          0x04, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00,
        ]);
        final payload = buildBackupJson(
          transactions: [
            {
              'txnid': 'TXN_EXE',
              'type': 'ADD',
              'amount': 100.0,
              'timestamp': 1000,
              'memo_photo_path': 'receipts/rec_TXN_EXE.jpg',
              'memo_photo_base64': base64Encode(peBytes),
            },
          ],
        );

        final validation = await backupService.validateBackupJson(payload);
        expect(validation.isValid, isFalse);
        expect(validation.errors.any((e) => e.contains('not a valid JPEG or PNG image')), isTrue);
      });

      test('T25: Linux ELF binary (\\x7fELF) masquerading as .png rejected', () async {
        final elfBytes = Uint8List.fromList([
          0x7F, 0x45, 0x4C, 0x46, 0x02, 0x01, 0x01, 0x00,
          0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        ]);
        final payload = buildBackupJson(
          transactions: [
            {
              'txnid': 'TXN_ELF',
              'type': 'ADD',
              'amount': 100.0,
              'timestamp': 1000,
              'memo_photo_path': 'receipts/rec_TXN_ELF.png',
              'memo_photo_base64': base64Encode(elfBytes),
            },
          ],
        );

        final validation = await backupService.validateBackupJson(payload);
        expect(validation.isValid, isFalse);
        expect(validation.errors.any((e) => e.contains('not a valid JPEG or PNG image')), isTrue);
      });

      test('T26: Plain ASCII text masquerading as .jpg rejected', () async {
        final textBytes = utf8.encode('Total Bazaar Expense: 1200 BDT. Paid via Cash.');
        final payload = buildBackupJson(
          transactions: [
            {
              'txnid': 'TXN_TEXT',
              'type': 'ADD',
              'amount': 100.0,
              'timestamp': 1000,
              'memo_photo_path': 'receipts/rec_TXN_TEXT.jpg',
              'memo_photo_base64': base64Encode(textBytes),
            },
          ],
        );

        final validation = await backupService.validateBackupJson(payload);
        expect(validation.isValid, isFalse);
        expect(validation.errors.any((e) => e.contains('not a valid JPEG or PNG image')), isTrue);
      });

      test('T27: HTML document masquerading as .jpg rejected', () async {
        final htmlBytes = utf8.encode('<!DOCTYPE html><html><body><script>alert("xss")</script></body></html>');
        final payload = buildBackupJson(
          transactions: [
            {
              'txnid': 'TXN_HTML',
              'type': 'ADD',
              'amount': 100.0,
              'timestamp': 1000,
              'memo_photo_path': 'receipts/rec_TXN_HTML.jpg',
              'memo_photo_base64': base64Encode(htmlBytes),
            },
          ],
        );

        final validation = await backupService.validateBackupJson(payload);
        expect(validation.isValid, isFalse);
        expect(validation.errors.any((e) => e.contains('not a valid JPEG or PNG image')), isTrue);
      });

      test('T28: PDF document (%PDF-1.4) masquerading as .jpg rejected', () async {
        final pdfBytes = utf8.encode('%PDF-1.4\n%âãÏÓ\n1 0 obj\n<<\n/Title (Receipt)\n>>\nendobj\ntrailer\n<<>>\n%%EOF');
        final payload = buildBackupJson(
          transactions: [
            {
              'txnid': 'TXN_PDF',
              'type': 'ADD',
              'amount': 100.0,
              'timestamp': 1000,
              'memo_photo_path': 'receipts/rec_TXN_PDF.jpg',
              'memo_photo_base64': base64Encode(pdfBytes),
            },
          ],
        );

        final validation = await backupService.validateBackupJson(payload);
        expect(validation.isValid, isFalse);
        expect(validation.errors.any((e) => e.contains('not a valid JPEG or PNG image')), isTrue);
      });

      test('T29: GIF image (GIF89a) rejected (only JPEG/PNG permitted)', () async {
        final gifBytes = Uint8List.fromList([
          0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0x01, 0x00, 0x01, 0x00, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00,
          0xFF, 0xFF, 0xFF, 0x21, 0xF9, 0x04, 0x01, 0x00, 0x00, 0x00, 0x00, 0x2C, 0x00, 0x00, 0x00, 0x00,
          0x01, 0x00, 0x01, 0x00, 0x00, 0x02, 0x02, 0x44, 0x01, 0x00, 0x3B,
        ]);
        final payload = buildBackupJson(
          transactions: [
            {
              'txnid': 'TXN_GIF',
              'type': 'ADD',
              'amount': 100.0,
              'timestamp': 1000,
              'memo_photo_path': 'receipts/rec_TXN_GIF.jpg',
              'memo_photo_base64': base64Encode(gifBytes),
            },
          ],
        );

        final validation = await backupService.validateBackupJson(payload);
        expect(validation.isValid, isFalse);
        expect(validation.errors.any((e) => e.contains('not a valid JPEG or PNG image')), isTrue);
      });

      test('T30: WebP image (RIFF....WEBP) rejected', () async {
        final webpBytes = Uint8List.fromList([
          0x52, 0x49, 0x46, 0x46, 0x1A, 0x00, 0x00, 0x00,
          0x57, 0x45, 0x42, 0x50, 0x56, 0x50, 0x38, 0x4C,
        ]);
        final payload = buildBackupJson(
          transactions: [
            {
              'txnid': 'TXN_WEBP',
              'type': 'ADD',
              'amount': 100.0,
              'timestamp': 1000,
              'memo_photo_path': 'receipts/rec_TXN_WEBP.jpg',
              'memo_photo_base64': base64Encode(webpBytes),
            },
          ],
        );

        final validation = await backupService.validateBackupJson(payload);
        expect(validation.isValid, isFalse);
        expect(validation.errors.any((e) => e.contains('not a valid JPEG or PNG image')), isTrue);
      });

      test('T31: Corrupted JPEG header (0xFF 0x00 0xFF) rejected', () async {
        final corruptJpeg = Uint8List.fromList([0xFF, 0x00, 0xFF, 0xE0, 0x00, 0x10]);
        final payload = buildBackupJson(
          transactions: [
            {
              'txnid': 'TXN_CORRUPT_JPEG',
              'type': 'ADD',
              'amount': 100.0,
              'timestamp': 1000,
              'memo_photo_path': 'receipts/rec_TXN_CORRUPT_JPEG.jpg',
              'memo_photo_base64': base64Encode(corruptJpeg),
            },
          ],
        );

        final validation = await backupService.validateBackupJson(payload);
        expect(validation.isValid, isFalse);
        expect(validation.errors.any((e) => e.contains('not a valid JPEG or PNG image')), isTrue);
      });

      test('T32: Corrupted PNG header (0x89 0x50 0x4E 0x00) rejected', () async {
        final corruptPng = Uint8List.fromList([0x89, 0x50, 0x4E, 0x00, 0x0D, 0x0A, 0x1A, 0x0A]);
        final payload = buildBackupJson(
          transactions: [
            {
              'txnid': 'TXN_CORRUPT_PNG',
              'type': 'ADD',
              'amount': 100.0,
              'timestamp': 1000,
              'memo_photo_path': 'receipts/rec_TXN_CORRUPT_PNG.png',
              'memo_photo_base64': base64Encode(corruptPng),
            },
          ],
        );

        final validation = await backupService.validateBackupJson(payload);
        expect(validation.isValid, isFalse);
        expect(validation.errors.any((e) => e.contains('not a valid JPEG or PNG image')), isTrue);
      });

      test('T33: Truncated 2-byte header (0xFF 0xD8) rejected', () async {
        final truncatedBytes = Uint8List.fromList([0xFF, 0xD8]);
        final payload = buildBackupJson(
          transactions: [
            {
              'txnid': 'TXN_TRUNC_HEADER',
              'type': 'ADD',
              'amount': 100.0,
              'timestamp': 1000,
              'memo_photo_path': 'receipts/rec_TXN_TRUNC_HEADER.jpg',
              'memo_photo_base64': base64Encode(truncatedBytes),
            },
          ],
        );

        final validation = await backupService.validateBackupJson(payload);
        expect(validation.isValid, isFalse);
        expect(validation.errors.any((e) => e.contains('not a valid JPEG or PNG image')), isTrue);
      });

      test('T34: Empty and whitespace-only Base64 strings handled cleanly', () async {
        final payloadEmpty = buildBackupJson(
          transactions: [
            {
              'txnid': 'TXN_EMPTY_B64',
              'type': 'ADD',
              'amount': 100.0,
              'timestamp': 1000,
              'memo_photo_path': 'receipts/rec_TXN_EMPTY_B64.jpg',
              'memo_photo_base64': '   ',
            },
          ],
        );

        // Blank base64 with a memo_photo_path generates a warning, but doesn't crash
        final validation = await backupService.validateBackupJson(payloadEmpty);
        expect(validation.isValid, isTrue);
        expect(validation.warnings.any((w) => w.contains('contains no embedded Base64 data')), isTrue);
      });
    });

    // =========================================================================
    // SECTION 4: Advanced Edge Cases, Boundary Limits & Merge Rollback
    // =========================================================================
    group('Section 4: Advanced Boundaries & Stress Rollback', () {
      test('T35: Disk write failure simulation during staging leaves pre-existing DB and receipts intact', () async {
        await dbHelper.insertTransaction(sampleAddTransaction(txnid: 'DISK_SAFE_1', amount: 8000.0));
        final safeRec = await receiptService.saveReceiptBytes(kMinimal1x1JpegBytes, 'DISK_SAFE_1');

        // Make docsDir read-only on Linux to simulate disk full / write error
        Process.runSync('chmod', ['555', testDocsDir.path]);

        final payload = buildBackupJson(
          transactions: [
            {
              'txnid': 'DISK_FAIL_TXN',
              'type': 'ADD',
              'amount': 500.0,
              'timestamp': 1000,
              'memo_photo_path': 'receipts/rec_DISK_FAIL_TXN.jpg',
              'memo_photo_base64': kMinimal1x1JpegBase64,
            },
          ],
        );

        bool threw = false;
        try {
          await backupService.importBackupJson(payload);
        } catch (_) {
          threw = true;
        }

        // Restore permissions for cleanup and assertions
        Process.runSync('chmod', ['755', testDocsDir.path]);
        expect(threw, isTrue);

        // Pre-existing SQLite database must remain completely intact
        expect(await dbHelper.getBalance(), equals(8000.0));
        expect((await dbHelper.getAllTransactions()).length, equals(1));
        expect(await receiptService.receiptExists(safeRec), isTrue);
      });

      test('T36: Merge mode (clearExisting: false) with corrupt Base64 preserves all existing data', () async {
        await dbHelper.insertTransaction(sampleAddTransaction(txnid: 'MERGE_BASE_1', amount: 1500.0));
        await dbHelper.insertTransaction(samplePayTransaction(txnid: 'MERGE_BASE_2', amount: 300.0));
        final baseRec = await receiptService.saveReceiptBytes(kMinimal1x1JpegBytes, 'MERGE_BASE_2');

        final payload = buildBackupJson(
          transactions: [
            {
              'txnid': 'MERGE_NEW_1',
              'type': 'ADD',
              'amount': 500.0,
              'timestamp': 1000,
              'memo_photo_path': 'receipts/rec_MERGE_NEW_1.jpg',
              'memo_photo_base64': kMinimal1x1JpegBase64,
            },
            {
              'txnid': 'MERGE_CORRUPT_2',
              'type': 'PAY',
              'amount': 200.0,
              'timestamp': 2000,
              'memo_photo_path': 'receipts/rec_MERGE_CORRUPT_2.jpg',
              'memo_photo_base64': '!!!INVALID_B64???',
            },
          ],
        );

        expect(
          () async => await backupService.importBackupJson(payload, clearExisting: false),
          throwsA(isA<BackupValidationException>()),
        );

        expect(await dbHelper.getBalance(), equals(1200.0));
        final all = await dbHelper.getAllTransactions();
        expect(all.length, equals(2));
        expect(await receiptService.receiptExists(baseRec), isTrue);
        expect(await receiptService.receiptExists('receipts/rec_MERGE_NEW_1.jpg'), isFalse);
      });

      test('T37: Discrepancy beyond ±0.001 BDT tolerance is rejected', () async {
        final payload = jsonEncode({
          'version': 1,
          'summary': {
            'total_balance': 100.002, // 0.002 off from 100.0
            'total_in': 100.0,
            'total_out': 0.0,
            'transaction_count': 1,
          },
          'transactions': [
            {'txnid': 'TOL_TXN', 'type': 'ADD', 'amount': 100.0, 'timestamp': 1000},
          ],
        });

        final validation = await backupService.validateBackupJson(payload);
        expect(validation.isValid, isFalse);
        expect(validation.errors.any((e) => e.contains('Reconciliation error')), isTrue);
      });

      test('T38: Discrepancy within ±0.001 BDT tolerance passes validation', () async {
        final payload = jsonEncode({
          'version': 1,
          'summary': {
            'total_balance': 100.0004, // 0.0004 off, within 0.001 tolerance
            'total_in': 100.0,
            'total_out': 0.0,
            'transaction_count': 1,
          },
          'transactions': [
            {'txnid': 'TOL_TXN_OK', 'type': 'ADD', 'amount': 100.0, 'timestamp': 1000},
          ],
        });

        final validation = await backupService.validateBackupJson(payload);
        expect(validation.isValid, isTrue);
      });

      test('T39: TxnId character boundary checks (too short, too long, special symbols)', () async {
        final badIds = ['ab', 'a' * 65, 'TXN#123', 'TXN;DROP TABLE', 'TXN\$EXP'];
        for (final badId in badIds) {
          final payload = buildBackupJson(
            transactions: [
              {'txnid': badId, 'type': 'ADD', 'amount': 10.0, 'timestamp': 1000},
            ],
          );

          final validation = await backupService.validateBackupJson(payload);
          expect(validation.isValid, isFalse, reason: 'Bad txnid $badId should be rejected');
        }
      });

      test('T40: Invalid timestamps (negative, 0, unparseable string) are rejected', () async {
        final badTimestamps = [-100, 0, 'not-a-date'];
        for (final ts in badTimestamps) {
          final payload = jsonEncode({
            'version': 1,
            'summary': {'total_balance': 10.0, 'total_in': 10.0, 'total_out': 0.0, 'transaction_count': 1},
            'transactions': [
              {'txnid': 'BAD_TS_TXN', 'type': 'ADD', 'amount': 10.0, 'timestamp': ts},
            ],
          });

          final validation = await backupService.validateBackupJson(payload);
          expect(validation.isValid, isFalse, reason: 'Bad timestamp $ts should be rejected');
        }
      });
    });
  });
}

