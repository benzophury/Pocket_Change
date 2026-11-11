import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';

import 'package:pocket_change/services/receipt_service.dart';
import 'test_helper.dart';

void main() {
  group('ReceiptService Unit Tests', () {
    late Directory tempDir;
    late ReceiptService receiptService;

    setUp(() async {
      tempDir = await createTestTempDir(prefix: 'receipt_unit_test_');
      receiptService = createTestReceiptService(tempDir);
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('buildRelativePath enforces relative path discipline and sanitization', () {
      final path1 = ReceiptService.buildRelativePath('TXN12345');
      expect(path1, equals('receipts/rec_TXN12345.jpg'));

      // Sanitization of illegal file system characters
      final path2 = ReceiptService.buildRelativePath('TXN/99:00?*<>|"');
      expect(path2, equals('receipts/rec_TXN_99_00______.jpg'));

      // Whitespace trimming
      final path3 = ReceiptService.buildRelativePath('  TXN_SPACE  ');
      expect(path3, equals('receipts/rec_TXN_SPACE.jpg'));
    });

    test('saveReceiptBytes writes file to documents directory and returns relative path', () async {
      final sampleBytes = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);
      final relativePath = await receiptService.saveReceiptBytes(
        sampleBytes,
        'TXN_BYTES_TEST',
      );

      expect(relativePath, equals('receipts/rec_TXN_BYTES_TEST.jpg'));

      final file = await receiptService.getReceiptFile(relativePath);
      expect(file, isNotNull);
      expect(await file!.exists(), isTrue);
      expect(await file.readAsBytes(), equals(sampleBytes));
    });

    test('saveReceiptImage reads XFile and saves as .jpg', () async {
      final sampleBytes = Uint8List.fromList([10, 20, 30, 40]);
      final xFile = XFile.fromData(sampleBytes, name: 'camera_capture.jpg');

      final relativePath = await receiptService.saveReceiptImage(
        xFile,
        'TXN_XFILE_TEST',
      );

      expect(relativePath, equals('receipts/rec_TXN_XFILE_TEST.jpg'));

      final file = await receiptService.getReceiptFile(relativePath);
      expect(file, isNotNull);
      expect(await file!.readAsBytes(), equals(sampleBytes));
    });

    test('encodeReceiptToBase64 and restoreReceiptFromBase64 round trip', () async {
      final originalData = utf8.encode('TEST_RECEIPT_IMAGE_CONTENT');
      final relativePath = await receiptService.saveReceiptBytes(
        Uint8List.fromList(originalData),
        'TXN_B64_TEST',
      );

      // Encode to base64
      final base64String = await receiptService.encodeReceiptToBase64(relativePath);
      expect(base64String, isNotNull);
      expect(base64Decode(base64String!), equals(originalData));

      // Restore to a new relative path
      const restoredPath = 'receipts/rec_TXN_RESTORED_TARGET.jpg';
      final returnedPath = await receiptService.restoreReceiptFromBase64(
        base64String,
        restoredPath,
      );
      expect(returnedPath, equals(restoredPath));

      final restoredFile = await receiptService.getReceiptFile(restoredPath);
      expect(restoredFile, isNotNull);
      expect(await restoredFile!.readAsBytes(), equals(originalData));
    });

    test('getReceiptFile returns null for invalid or non-existent paths', () async {
      expect(await receiptService.getReceiptFile(null), isNull);
      expect(await receiptService.getReceiptFile(''), isNull);
      expect(await receiptService.getReceiptFile('   '), isNull);
      expect(await receiptService.getReceiptFile('receipts/rec_missing.jpg'), isNull);
    });

    test('receiptExists returns true only when file is on disk', () async {
      expect(await receiptService.receiptExists('receipts/rec_none.jpg'), isFalse);

      final path = await receiptService.saveReceiptBytes(
        Uint8List.fromList([1, 2]),
        'TXN_EXISTS',
      );
      expect(await receiptService.receiptExists(path), isTrue);
    });

    test('deleteReceiptImage deletes file and returns true; returns false if absent', () async {
      final path = await receiptService.saveReceiptBytes(
        Uint8List.fromList([1, 2, 3]),
        'TXN_DELETE',
      );
      expect(await receiptService.receiptExists(path), isTrue);

      final deleted = await receiptService.deleteReceiptImage(path);
      expect(deleted, isTrue);
      expect(await receiptService.receiptExists(path), isFalse);

      final deletedAgain = await receiptService.deleteReceiptImage(path);
      expect(deletedAgain, isFalse);
    });

    test('deleteAllReceipts removes all stored receipt images', () async {
      await receiptService.saveReceiptBytes(Uint8List.fromList([1]), 'TXN_MULTI_1');
      await receiptService.saveReceiptBytes(Uint8List.fromList([2]), 'TXN_MULTI_2');
      await receiptService.saveReceiptBytes(Uint8List.fromList([3]), 'TXN_MULTI_3');

      final count = await receiptService.deleteAllReceipts();
      expect(count, equals(3));

      expect(await receiptService.receiptExists('receipts/rec_TXN_MULTI_1.jpg'), isFalse);
      expect(await receiptService.receiptExists('receipts/rec_TXN_MULTI_2.jpg'), isFalse);
      expect(await receiptService.receiptExists('receipts/rec_TXN_MULTI_3.jpg'), isFalse);
    });

    test('Validation errors thrown on empty arguments', () async {
      expect(
        () async => await receiptService.saveReceiptBytes(Uint8List(0), 'TXN1'),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () async => await receiptService.saveReceiptBytes(Uint8List(5), '   '),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () async => await receiptService.restoreReceiptFromBase64('', 'receipts/rec.jpg'),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () async => await receiptService.restoreReceiptFromBase64('AAAA', ''),
        throwsA(isA<ArgumentError>()),
      );
    });
  });
}
