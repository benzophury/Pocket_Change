import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';

import 'package:pocket_change/models/transaction_item.dart';
import 'package:pocket_change/models/ledger_summary.dart';
import 'package:pocket_change/utils/txnid_generator.dart';

void main() {
  group('TransactionType', () {
    test('toDbValue converts to exact SQLite CHECK constraint strings', () {
      expect(TransactionType.add.toDbValue(), equals('ADD'));
      expect(TransactionType.pay.toDbValue(), equals('PAY'));
    });

    test('fromDbValue correctly parses uppercase and lowercase', () {
      expect(TransactionType.fromDbValue('ADD'), equals(TransactionType.add));
      expect(TransactionType.fromDbValue('add'), equals(TransactionType.add));
      expect(TransactionType.fromDbValue('PAY'), equals(TransactionType.pay));
      expect(TransactionType.fromDbValue('pay'), equals(TransactionType.pay));
      expect(TransactionType.fromDbValue('  pay  '), equals(TransactionType.pay));
    });

    test('fromDbValue throws ArgumentError on invalid string', () {
      expect(() => TransactionType.fromDbValue('TRANSFER'), throwsArgumentError);
      expect(() => TransactionType.fromDbValue(''), throwsArgumentError);
    });

    test('UI getters return expected values', () {
      expect(TransactionType.add.displayName, equals('Add Money'));
      expect(TransactionType.pay.displayName, equals('Pay'));
      expect(TransactionType.add.bengaliDisplayName, equals('টাকা যোগ'));
      expect(TransactionType.pay.bengaliDisplayName, equals('পেমেন্ট'));
      expect(TransactionType.add.isCredit, isTrue);
      expect(TransactionType.add.isDebit, isFalse);
      expect(TransactionType.pay.isCredit, isFalse);
      expect(TransactionType.pay.isDebit, isTrue);
      expect(TransactionType.add.sign, equals('+'));
      expect(TransactionType.pay.sign, equals('-'));
    });
  });

  group('TransactionItem', () {
    final testDate = DateTime(2026, 11, 7, 15, 30, 45);

    test('toMap serializes correctly for SQLite insertion', () {
      final item = TransactionItem(
        txnid: 'TXN1234567890AB',
        type: TransactionType.add,
        amount: 2500.0,
        timestamp: testDate,
        notes: 'Monthly pocket money',
        category: 'Cash In',
      );

      final map = item.toMap();
      expect(map['id'], isNull); // omitted for autoincrement
      expect(map['txnid'], equals('TXN1234567890AB'));
      expect(map['type'], equals('ADD'));
      expect(map['amount'], equals(2500.0));
      expect(map['timestamp'], equals(testDate.millisecondsSinceEpoch));
      expect(map['memo_photo_path'], isNull);
      expect(map['notes'], equals('Monthly pocket money'));
      expect(map['category'], equals('Cash In'));
    });

    test('toMap includes id when present', () {
      final item = TransactionItem(
        id: 42,
        txnid: 'TXN1234567890AB',
        type: TransactionType.pay,
        amount: 150.75,
        timestamp: testDate,
        memoPhotoPath: 'receipts/rec_test.jpg',
      );

      final map = item.toMap();
      expect(map['id'], equals(42));
      expect(map['type'], equals('PAY'));
      expect(map['memo_photo_path'], equals('receipts/rec_test.jpg'));
    });

    test('fromMap deserializes SQLite row map (snake_case)', () {
      final dbRow = {
        'id': 1,
        'txnid': 'TXN8K9F201B7A2M',
        'type': 'PAY',
        'amount': 350.0,
        'timestamp': testDate.millisecondsSinceEpoch,
        'memo_photo_path': 'receipts/rec_1.jpg',
        'notes': 'Grocery bazaar',
        'category': 'Groceries',
      };

      final item = TransactionItem.fromMap(dbRow);
      expect(item.id, equals(1));
      expect(item.txnid, equals('TXN8K9F201B7A2M'));
      expect(item.type, equals(TransactionType.pay));
      expect(item.amount, equals(350.0));
      expect(item.timestamp.millisecondsSinceEpoch, equals(testDate.millisecondsSinceEpoch));
      expect(item.memoPhotoPath, equals('receipts/rec_1.jpg'));
      expect(item.notes, equals('Grocery bazaar'));
      expect(item.category, equals('Groceries'));
      expect(item.hasMemoPhoto, isTrue);
      expect(item.isPay, isTrue);
      expect(item.isAdd, isFalse);
      expect(item.signedAmount, equals(-350.0));
    });

    test('fromMap supports camelCase keys and integer amounts', () {
      final genericMap = {
        'id': 5,
        'txnid': 'TXNTEST1234567',
        'type': 'ADD',
        'amount': 500, // int type
        'timestamp': testDate.millisecondsSinceEpoch,
        'memoPhotoPath': null,
        'notes': null,
        'category': null,
      };

      final item = TransactionItem.fromMap(genericMap);
      expect(item.amount, equals(500.0));
      expect(item.hasMemoPhoto, isFalse);
      expect(item.isAdd, isTrue);
      expect(item.signedAmount, equals(500.0));
    });

    test('toJson and fromJson round-trip with embedded Base64 receipt', () {
      final original = TransactionItem(
        id: 7,
        txnid: 'TXNJSONTEST123',
        type: TransactionType.pay,
        amount: 120.0,
        timestamp: testDate,
        memoPhotoPath: 'receipts/rec_test.jpg',
        notes: 'Coffee with snacks',
        category: 'Food',
        memoPhotoBase64: 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk',
      );

      final jsonMap = original.toJson();
      final jsonString = jsonEncode(jsonMap);
      final decodedJson = jsonDecode(jsonString) as Map<String, dynamic>;
      final restored = TransactionItem.fromJson(decodedJson);

      expect(restored, equals(original));
      expect(restored.memoPhotoBase64, equals('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk'));
    });

    test('copyWith works correctly with field replacement and clearing', () {
      final original = TransactionItem(
        id: 1,
        txnid: 'TXN111',
        type: TransactionType.add,
        amount: 100.0,
        timestamp: testDate,
        memoPhotoPath: 'receipts/rec_1.jpg',
        notes: 'Old note',
        category: 'Old cat',
      );

      final modified = original.copyWith(
        amount: 200.0,
        clearMemoPhotoPath: true,
        notes: 'New note',
      );

      expect(modified.id, equals(1));
      expect(modified.txnid, equals('TXN111'));
      expect(modified.amount, equals(200.0));
      expect(modified.memoPhotoPath, isNull);
      expect(modified.notes, equals('New note'));
      expect(modified.category, equals('Old cat'));
    });

    test('equality and hashCode contract', () {
      final itemA = TransactionItem(
        id: 1,
        txnid: 'TXN_SAME',
        type: TransactionType.pay,
        amount: 50.0,
        timestamp: testDate,
      );
      final itemB = TransactionItem(
        id: 1,
        txnid: 'TXN_SAME',
        type: TransactionType.pay,
        amount: 50.0,
        timestamp: testDate,
      );

      expect(itemA, equals(itemB));
      expect(itemA.hashCode, equals(itemB.hashCode));
    });

    test('validation throws on non-positive amount in fromMap', () {
      final invalidMap = {
        'txnid': 'TXNINVALID',
        'type': 'ADD',
        'amount': -10.0,
        'timestamp': testDate.millisecondsSinceEpoch,
      };

      expect(() => TransactionItem.fromMap(invalidMap), throwsArgumentError);
    });
  });

  group('LedgerSummary', () {
    test('zero and empty factories return 0 values', () {
      expect(LedgerSummary.zero.balance, equals(0.0));
      expect(LedgerSummary.zero.totalIn, equals(0.0));
      expect(LedgerSummary.zero.totalOut, equals(0.0));
      expect(LedgerSummary.zero.totalCount, equals(0));
      expect(LedgerSummary.zero.isEmpty, isTrue);
      expect(LedgerSummary.zero.isNotEmpty, isFalse);
      expect(LedgerSummary.empty(), equals(LedgerSummary.zero));
    });

    test('fromMap parses SQLite view row', () {
      final viewRow = {
        'balance': 1250.50,
        'total_in': 2000.0,
        'total_out': 749.50,
        'total_count': 12,
      };

      final summary = LedgerSummary.fromMap(viewRow);
      expect(summary.balance, equals(1250.50));
      expect(summary.totalIn, equals(2000.0));
      expect(summary.totalOut, equals(749.50));
      expect(summary.totalCount, equals(12));
      expect(summary.isEmpty, isFalse);
      expect(summary.isNotEmpty, isTrue);
      expect(summary.netSavings, equals(1250.50));
    });

    test('fromMap parses backup JSON metadata keys', () {
      final backupJson = {
        'calculated_balance': 1500.0,
        'total_in': 2000.0,
        'total_out': 500.0,
        'total_records': 3,
      };

      final summary = LedgerSummary.fromJson(backupJson);
      expect(summary.balance, equals(1500.0));
      expect(summary.totalIn, equals(2000.0));
      expect(summary.totalOut, equals(500.0));
      expect(summary.totalCount, equals(3));
    });

    test('toMap matches SQLite view column names', () {
      const summary = LedgerSummary(
        balance: 100.0,
        totalIn: 300.0,
        totalOut: 200.0,
        totalCount: 5,
      );

      final map = summary.toMap();
      expect(map['balance'], equals(100.0));
      expect(map['total_in'], equals(300.0));
      expect(map['total_out'], equals(200.0));
      expect(map['total_count'], equals(5));
    });

    test('toJson matches backup schema metadata keys', () {
      const summary = LedgerSummary(
        balance: 100.0,
        totalIn: 300.0,
        totalOut: 200.0,
        totalCount: 5,
      );

      final json = summary.toJson();
      expect(json['calculated_balance'], equals(100.0));
      expect(json['total_in'], equals(300.0));
      expect(json['total_out'], equals(200.0));
      expect(json['total_records'], equals(5));
    });

    test('copyWith, equality, and hashCode', () {
      const s1 = LedgerSummary(balance: 10.0, totalIn: 20.0, totalOut: 10.0, totalCount: 2);
      final s2 = s1.copyWith(balance: 15.0);

      expect(s2.balance, equals(15.0));
      expect(s2.totalIn, equals(20.0));
      expect(s2.totalOut, equals(10.0));
      expect(s2.totalCount, equals(2));

      const s3 = LedgerSummary(balance: 10.0, totalIn: 20.0, totalOut: 10.0, totalCount: 2);
      expect(s1, equals(s3));
      expect(s1.hashCode, equals(s3.hashCode));
    });
  });

  group('TxnIdGenerator', () {
    test('generate produces valid ID with default TXN prefix', () {
      final id = generateTxnId();
      expect(id.startsWith('TXN'), isTrue);
      expect(id.length, equals(15));
      expect(TxnIdGenerator.isValid(id), isTrue);
    });

    test('generate respects custom prefix', () {
      final id = generateTxnId(prefix: 'BK');
      expect(id.startsWith('BK'), isTrue);
      expect(id.length, equals(14));
      expect(TxnIdGenerator.isValid(id, prefix: 'BK'), isTrue);
    });

    test('isValid correctly rejects malformed IDs', () {
      expect(TxnIdGenerator.isValid(null), isFalse);
      expect(TxnIdGenerator.isValid(''), isFalse);
      expect(TxnIdGenerator.isValid('TXN123'), isFalse);
      expect(TxnIdGenerator.isValid('TXN1234567890123456'), isFalse);
      expect(TxnIdGenerator.isValid('NOTTXN123456789012'), isFalse);
      expect(TxnIdGenerator.isValid('TXN1234567890!@'), isFalse); // non-alphanumeric
    });

    test('extractTimestamp extracts correct creation time', () {
      final before = DateTime.now();
      final id = generateTxnId();
      final after = DateTime.now();

      final extracted = TxnIdGenerator.extractTimestamp(id);
      expect(extracted, isNotNull);
      expect(extracted!.millisecondsSinceEpoch >= before.millisecondsSinceEpoch, isTrue);
      expect(extracted.millisecondsSinceEpoch <= after.millisecondsSinceEpoch, isTrue);
    });

    test('extractTimestamp returns null for invalid ID', () {
      expect(TxnIdGenerator.extractTimestamp('INVALID'), isNull);
      expect(TxnIdGenerator.extractTimestamp(null), isNull);
    });

    test('generates 10,000 unique IDs without collision in rapid succession', () {
      final set = <String>{};
      const count = 10000;
      for (int i = 0; i < count; i++) {
        final id = generateTxnId();
        final isUnique = set.add(id);
        expect(isUnique, isTrue, reason: 'Duplicate ID detected at index $i: $id');
      }
      expect(set.length, equals(count));
    });
  });
}
