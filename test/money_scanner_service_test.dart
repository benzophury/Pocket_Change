import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:pocket_change/services/money_scanner_service.dart';

void main() {
  group('MoneyScannerService: Local ML/AI Banknote & Serial Recognition', () {
    late MoneyScannerService scanner;

    setUp(() {
      scanner = MoneyScannerService(ocrEngine: const MockBanknoteOcrEngine());
    });

    test('Parses 1000 Taka note with Latin serial number', () {
      const ocrText = '''
        BANGLADESH BANK
        8K 4920194
        ONE THOUSAND TAKA
        1000
        GOVERNOR
      ''';

      final result = scanner.parseBanknoteText(ocrText);

      expect(result.hasDetection, isTrue);
      expect(result.totalAmount, equals(1000.0));
      expect(result.detectedNotes.length, equals(1));
      expect(result.detectedNotes.first.denomination, equals(1000.0));
      expect(result.primarySerialNumber, equals('8K4920194'));
    });

    test('Parses 500 Taka note with Bengali serial and numerals', () {
      const ocrText = '''
        বাংলাদেশ ব্যাংক
        কখ ১২৩৪৫৬৭
        ৫০০
        পাঁচশত টাকা
      ''';

      final result = scanner.parseBanknoteText(ocrText);

      expect(result.hasDetection, isTrue);
      expect(result.totalAmount, equals(500.0));
      expect(result.detectedNotes.length, equals(1));
      expect(result.detectedNotes.first.denomination, equals(500.0));
      expect(result.primarySerialNumber, equals('কখ ১২৩৪৫৬৭'));
    });

    test('Parses 100, 200, 50, 20, 10 Taka denominations accurately', () {
      final samples = <String, double>{
        '100 TAKA BANGLADESH BANK 9A 1234567': 100.0,
        'TWO HUNDRED TAKA 200 BANGLADESH BANK 7B 4910291': 200.0,
        'FIFTY TAKA 50 BB 9988776': 50.0,
        'TWENTY TAKA 20 CC 5544332': 20.0,
        'TEN TAKA 10 DD 1122334': 10.0,
      };

      for (final entry in samples.entries) {
        final result = scanner.parseBanknoteText(entry.key);
        expect(result.hasDetection, isTrue);
        expect(result.totalAmount, equals(entry.value));
        expect(result.primarySerialNumber, isNotNull);
      }
    });

    test('Multi-note detection aggregates total amount correctly', () {
      const multiNoteOcrText = '''
        BANGLADESH BANK
        1000 TAKA
        SN: 8K 4920194
        ---
        BANGLADESH BANK
        500 TAKA
        SN: 7J 8192031
      ''';

      final result = scanner.parseBanknoteText(multiNoteOcrText);

      expect(result.hasDetection, isTrue);
      expect(result.detectedNotes.length, equals(2));
      expect(result.totalAmount, equals(1500.0));
      expect(result.primarySerialNumber, equals('8K4920194'));
    });

    test('Handles noisy and non-currency text gracefully', () {
      const noisyText = '''
        Random receipt from grocery store
        Milk: 120
        Bread: 65
        Eggs: 140
        Date: 2024-11-10
      ''';

      final result = scanner.parseBanknoteText(noisyText);

      // Non-banknote denominations (120, 65, 140) should not match physical note denominations
      expect(result.hasDetection, isFalse);
      expect(result.totalAmount, equals(0.0));
      expect(result.detectedNotes, isEmpty);
    });

    test('Parses 1000 Taka note with spaced Bengali prefix and Latin serial (ছ দ 6282066)', () {
      const realNoteOcr = '''
        BANGLADESH BANK
        ছ দ 6282066
        1000
        ১০০০
      ''';

      final result = scanner.parseBanknoteText(realNoteOcr);

      expect(result.hasDetection, isTrue);
      expect(result.totalAmount, equals(1000.0));
      expect(result.primarySerialNumber, equals('ছদ ৬২৮২০৬৬'));
    });

    test('Filters out handwritten cashier markings (red pen 20 on a 1000 Taka note)', () {
      const realNoteWithPenMark = '''
        BANGLADESH BANK
        1000
        ছ দ 6282066
        20
      ''';

      final result = scanner.parseBanknoteText(realNoteWithPenMark);

      expect(result.hasDetection, isTrue);
      // Denomination must be 1000.0, NOT 1020.0 and NOT 20.0
      expect(result.totalAmount, equals(1000.0));
      expect(result.detectedNotes.first.denomination, equals(1000.0));
      expect(result.primarySerialNumber, equals('ছদ ৬২৮২০৬৬'));
    });

    test('Extracts standalone 7-digit banknote serial number when OCR misses prefix', () {
      const ocrWithoutPrefix = '''
        BANGLADESH BANK
        1000
        6282066
      ''';

      final result = scanner.parseBanknoteText(ocrWithoutPrefix);

      expect(result.hasDetection, isTrue);
      expect(result.totalAmount, equals(1000.0));
      expect(result.primarySerialNumber, equals('৬২৮২০৬৬'));
    });

    test('Detects note number even when denomination is absent or occluded', () {
      const serialOnlyOcr = '''
        BANGLADESH BANK
        ছ দ 6282066
      ''';

      final result = scanner.parseBanknoteText(serialOnlyOcr);

      // Must succeed and provide note number even if amount was not visible
      expect(result.hasDetection, isTrue);
      expect(result.primarySerialNumber, equals('ছদ ৬২৮২০৬৬'));
      expect(result.totalAmount, equals(0.0));
      expect(result.detectedNotes.length, equals(1));
      expect(result.detectedNotes.first.serialNumber, equals('ছদ ৬২৮২০৬৬'));
    });

    test('Partial note scan: succeeds when only the banknote serial number is visible', () {
      // Partial note with ONLY the serial number visible, no headers or denominations
      const partialNoteOnlySerial = 'ছ দ 6282066';

      final result = scanner.parseBanknoteText(partialNoteOnlySerial);

      expect(result.hasDetection, isTrue);
      expect(result.primarySerialNumber, equals('ছদ ৬২৮২০৬৬'));
      expect(result.totalAmount, equals(0.0));
      expect(result.detectedNotes.length, equals(1));
      expect(result.detectedNotes.first.serialNumber, equals('ছদ ৬২৮২০৬৬'));
    });

    test('Detects two Bangla alphabets then 7 numbers with various scripts and digit formats', () {
      // Bengali digits with internal space (captured directly from user device)
      final r0 = scanner.parseBanknoteText('ছ দ ৬২ ৮২০৬৬');
      expect(r0.hasDetection, isTrue);
      expect(r0.primarySerialNumber, equals('ছদ ৬২৮২০৬৬'));

      // Bengali digits
      final r1 = scanner.parseBanknoteText('কখ ১২৩৪৫৬৭');
      expect(r1.hasDetection, isTrue);
      expect(r1.primarySerialNumber, equals('কখ ১২৩৪৫৬৭'));

      // Spaced Bangla letters with English digits
      final r2 = scanner.parseBanknoteText('গ ঘ 7654321');
      expect(r2.hasDetection, isTrue);
      expect(r2.primarySerialNumber, equals('গঘ ৭৬৫৪৩২১'));

      // Split 7 digits
      final r3 = scanner.parseBanknoteText('ট ঠ 554 4332');
      expect(r3.hasDetection, isTrue);
      expect(r3.primarySerialNumber, equals('টঠ ৫৫৪৪৩৩২'));
    });

    test('Transliterates Devanagari OCR glyphs to Bengali script (छ द 6282066 -> ছদ6282066)', () {
      // ML Kit Devanagari recognizer outputs Devanagari glyphs for Bengali script
      const devanagariOcrText = 'छ द 6282066 S000 BANGLADESH BANK';

      final result = scanner.parseBanknoteText(devanagariOcrText);

      expect(result.hasDetection, isTrue);
      expect(result.primarySerialNumber, equals('ছদ ৬২৮২০৬৬'));
      expect(result.totalAmount, equals(1000.0));
    });

    test('Recognizes 1000 Taka note when OCR reads 1000 as S000, s000, or 2S000', () {
      const userDeviceSample = '''
        BANGYAbSANK
        S000
        ছ দ 6282066
        66000
        s000
      ''';

      final result = scanner.parseBanknoteText(userDeviceSample);

      expect(result.hasDetection, isTrue);
      expect(result.totalAmount, equals(1000.0));
      expect(result.primarySerialNumber, equals('ছদ ৬২৮২০৬৬'));
    });

    test('Recognizes Bengali vowel alphabets and Devanagari vowel equivalents', () {
      // Independent vowels: অ, আ, ই, উ, এ, ও
      final r1 = scanner.parseBanknoteText('BANGLADESH BANK 1000 TAKA অক 1234567');
      expect(r1.hasDetection, isTrue);
      expect(r1.primarySerialNumber, equals('অক ১২৩৪৫৬৭'));

      // Decomposed/Devanagari composite: अा (अ + ा) -> আ
      final r2 = scanner.parseBanknoteText('BANGLADESH BANK 500 TAKA अाख 7654321');
      expect(r2.hasDetection, isTrue);
      expect(r2.primarySerialNumber, equals('আখ ৭৬৫৪৩২১'));

      // Vowel ই and এ
      final r3 = scanner.parseBanknoteText('BANGLADESH BANK 100 TAKA इ ग 9876543');
      expect(r3.hasDetection, isTrue);
      expect(r3.primarySerialNumber, equals('ইগ ৯৮৭৬৫৪৩'));

      final r4 = scanner.parseBanknoteText('BANGLADESH BANK 200 TAKA এ চ 1122334');
      expect(r4.hasDetection, isTrue);
      expect(r4.primarySerialNumber, equals('এচ ১১২২৩৩৪'));

      // Stray vowel signs/matras (e.g. accidental া on base letters) stripped
      final r5 = scanner.parseBanknoteText('BANGLADESH BANK 50 TAKA কখা 5544332');
      expect(r5.hasDetection, isTrue);
      expect(r5.primarySerialNumber, equals('কখ ৫৫৪৪৩৩২'));
    });

    test('Scans via mock OCR engine using XFile', () async {
      const sampleText = 'BANGLADESH BANK 500 TAKA 4A 1234567';
      final mockEngine = MockBanknoteOcrEngine(mockText: sampleText);
      final service = MoneyScannerService(ocrEngine: mockEngine);

      final dummyFile = XFile.fromData(Uint8List.fromList([]), name: 'dummy_note.jpg');
      final result = await service.scanBanknote(dummyFile);

      expect(result.hasDetection, isTrue);
      expect(result.totalAmount, equals(500.0));
      expect(result.primarySerialNumber, equals('4A1234567'));
    });
  });
}
