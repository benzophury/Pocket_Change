import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';

/// Represents a single identified physical banknote.
class BanknoteItem {
  /// Face value denomination (e.g. 10, 20, 50, 100, 200, 500, 1000).
  final double denomination;

  /// Extracted unique banknote serial number (e.g. "8K4920194", "ছদ6282066", "কখ1234567").
  final String? serialNumber;

  /// Detection confidence rating between 0.0 and 1.0.
  final double confidence;

  /// Raw matched token from OCR text.
  final String matchedToken;

  const BanknoteItem({
    required this.denomination,
    this.serialNumber,
    this.confidence = 0.9,
    this.matchedToken = '',
  });

  @override
  String toString() => 'BanknoteItem(৳$denomination, serial: $serialNumber, conf: $confidence)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BanknoteItem &&
          runtimeType == other.runtimeType &&
          denomination == other.denomination &&
          serialNumber == other.serialNumber;

  @override
  int get hashCode => denomination.hashCode ^ (serialNumber?.hashCode ?? 0);
}

/// Consolidated scan result produced by the local ML/AI money scanner.
class BanknoteScanResult {
  /// List of distinct physical banknotes recognized.
  final List<BanknoteItem> detectedNotes;

  /// Primary or aggregated total monetary amount scanned.
  final double totalAmount;

  /// Primary banknote serial number (if found) to be used as Transaction ID.
  final String? primarySerialNumber;

  /// Raw OCR text extracted from the physical bill.
  final String rawText;

  /// Indicates whether at least one valid banknote denomination or serial was detected.
  final bool hasDetection;

  const BanknoteScanResult({
    required this.detectedNotes,
    required this.totalAmount,
    this.primarySerialNumber,
    required this.rawText,
    required this.hasDetection,
  });

  factory BanknoteScanResult.empty({String rawText = ''}) {
    return BanknoteScanResult(
      detectedNotes: const [],
      totalAmount: 0.0,
      primarySerialNumber: null,
      rawText: rawText,
      hasDetection: false,
    );
  }

  @override
  String toString() =>
      'BanknoteScanResult(total: ৳$totalAmount, serial: $primarySerialNumber, count: ${detectedNotes.length})';
}

/// Abstract contract for OCR text extraction to allow headless testing on Linux host
/// without native Android Google Play Services.
abstract class BanknoteOcrEngine {
  Future<String> extractText(XFile imageFile);
  Future<void> dispose() async {}
}

/// Production implementation of [BanknoteOcrEngine] powered by Google ML Kit on Android.
/// Employs dual recognizers (Devanagari script + Latin script) to achieve high-accuracy
/// recognition of Bengali banknote serial letters and Latin numbers.
class MlKitBanknoteOcrEngine implements BanknoteOcrEngine {
  final TextRecognizer _latinRecognizer;
  final TextRecognizer _devanagariRecognizer;

  MlKitBanknoteOcrEngine({
    TextRecognizer? customLatinRecognizer,
    TextRecognizer? customDevanagariRecognizer,
  })  : _latinRecognizer = customLatinRecognizer ??
            TextRecognizer(script: TextRecognitionScript.latin),
        _devanagariRecognizer = customDevanagariRecognizer ??
            TextRecognizer(script: TextRecognitionScript.devanagiri);

  @override
  Future<String> extractText(XFile imageFile) async {
    final inputImage = InputImage.fromFilePath(imageFile.path);
    final results = await Future.wait([
      _devanagariRecognizer
          .processImage(inputImage)
          .then((r) => r.text)
          .catchError((e) {
        debugPrint('[MlKit] Devanagari OCR error (falling back): $e');
        return '';
      }),
      _latinRecognizer
          .processImage(inputImage)
          .then((r) => r.text)
          .catchError((e) {
        debugPrint('[MlKit] Latin OCR error: $e');
        return '';
      }),
    ]);
    return '${results[0]}\n${results[1]}';
  }

  @override
  Future<void> dispose() async {
    await Future.wait([
      _latinRecognizer.close().catchError((_) {}),
      _devanagariRecognizer.close().catchError((_) {}),
    ]);
  }
}

/// Mockable OCR engine for automated headless testing.
class MockBanknoteOcrEngine implements BanknoteOcrEngine {
  final String mockText;

  const MockBanknoteOcrEngine({this.mockText = ''});

  @override
  Future<String> extractText(XFile imageFile) async {
    return mockText;
  }

  @override
  Future<void> dispose() async {}
}

/// Local On-Device ML/AI Money Scanner Service optimized exclusively for Bangladesh Bank notes.
///
/// Features:
/// - Classifies physical Bangladesh Bank denominations (10, 20, 50, 100, 200, 500, 1000).
/// - Extracts unique banknote serial numbers (two Bangla alphabets followed by 7 numbers).
/// - Fully supports partial notes: as long as the serial number is in view, detection succeeds.
/// - Banknote serial numbers serve directly as Transaction IDs (`txnid`).
/// - Completely offline, private, and on-device.
class MoneyScannerService {
  final BanknoteOcrEngine _ocrEngine;

  /// Valid physical currency denominations for Bangladesh Bank
  static final Set<double> validDenominations = {
    10.0,
    20.0,
    50.0,
    100.0,
    200.0,
    500.0,
    1000.0,
  };

  /// Bengali numeral to English digit conversion map
  static const Map<String, String> _bengaliToEnglishDigits = {
    '০': '0',
    '১': '1',
    '২': '2',
    '৩': '3',
    '৪': '4',
    '৫': '5',
    '৬': '6',
    '৭': '7',
    '৮': '8',
    '৯': '9',
  };

  /// Direct 1-to-1 Unicode transliteration map from Devanagari glyphs to Bengali script.
  /// Used because ML Kit's Devanagari model detects Brahmi/Bengali consonant shapes with high fidelity.
  static const Map<int, int> _devanagariToBengaliMap = {
    // Consonants
    0x0915: 0x0995, // क -> ক
    0x0916: 0x0996, // ख -> খ
    0x0917: 0x0997, // ग -> গ
    0x0918: 0x0998, // घ -> ঘ
    0x0919: 0x0999, // ङ -> ঙ
    0x091A: 0x099A, // च -> চ
    0x091B: 0x099B, // छ -> ছ
    0x091C: 0x099C, // ज -> জ
    0x091D: 0x099D, // झ -> ঝ
    0x091E: 0x099E, // ञ -> ঞ
    0x091F: 0x099F, // ट -> ট
    0x0920: 0x09A0, // ठ -> ঠ
    0x0921: 0x09A1, // ड -> ড
    0x0922: 0x09A2, // ढ -> ঢ
    0x0923: 0x09A3, // ण -> ণ
    0x0924: 0x09A4, // त -> ত
    0x0925: 0x09A5, // थ -> থ
    0x0926: 0x09A6, // द -> দ
    0x0927: 0x09A7, // ध -> ধ
    0x0928: 0x09A8, // न -> ন
    0x092A: 0x09AA, // प -> প
    0x092B: 0x09AB, // फ -> ফ
    0x092C: 0x09AC, // ब -> ব
    0x092D: 0x09AD, // भ -> ভ
    0x092E: 0x09AE, // म -> ম
    0x092F: 0x09AF, // य -> য
    0x0930: 0x09B0, // र -> র
    0x0932: 0x09B2, // ल -> ল
    0x0935: 0x09AC, // व -> ব
    0x0936: 0x09B6, // श -> শ
    0x0937: 0x09B7, // ष -> ষ
    0x0938: 0x09B8, // स -> স
    0x0939: 0x09B9, // ह -> হ
    // Additional Devanagari consonants with nukta
    0x0958: 0x0995, // क़ -> ক
    0x0959: 0x0996, // ख़ -> খ
    0x095A: 0x0997, // ग़ -> গ
    0x095B: 0x099C, // ज़ -> জ
    0x095C: 0x09DC, // ड़ -> ড়
    0x095D: 0x09DD, // ढ़ -> ঢ়
    0x095E: 0x09AB, // फ़ -> ফ
    0x095F: 0x09DF, // य़ -> য়
    // Independent Vowels
    0x0904: 0x098F, // ऄ -> এ
    0x0905: 0x0985, // अ -> অ
    0x0906: 0x0986, // आ -> আ
    0x0907: 0x0987, // इ -> ই
    0x0908: 0x0988, // ई -> ঈ
    0x0909: 0x0989, // उ -> উ
    0x090A: 0x098A, // ऊ -> ঊ
    0x090B: 0x098B, // ऋ -> ঋ
    0x090C: 0x098C, // ऌ -> ঌ
    0x090D: 0x098F, // ऍ -> এ
    0x090E: 0x098F, // ऎ -> এ
    0x090F: 0x098F, // ए -> এ
    0x0910: 0x0990, // ऐ -> ঐ
    0x0911: 0x0993, // ऑ -> ও
    0x0912: 0x0993, // ऒ -> ও
    0x0913: 0x0993, // ओ -> ও
    0x0914: 0x0994, // औ -> ঔ
    // Dependent Vowel Signs (Matras) & Modifiers
    0x0901: 0x0981, // ँ -> ঁ (candrabindu)
    0x0902: 0x0982, // ं -> ং (anusvara)
    0x0903: 0x0983, // ः -> ঃ (visarga)
    0x093C: 0x09BC, // ़ -> ় (nukta)
    0x093D: 0x09BD, // ऽ -> ঽ (avagraha)
    0x093E: 0x09BE, // ा -> া (aa kar)
    0x093F: 0x09BF, // ि -> ি (i kar)
    0x0940: 0x09C0, // ी -> ী (ee kar)
    0x0941: 0x09C1, // ु -> ু (u kar)
    0x0942: 0x09C2, // ू -> ূ (oo kar)
    0x0943: 0x09C3, // ृ -> ৃ (ri kar)
    0x0944: 0x09C4, // ॄ -> ৄ (rri kar)
    0x0945: 0x09C7, // ॅ -> ে
    0x0946: 0x09C7, // ॆ -> ে
    0x0947: 0x09C7, // े -> ে (e kar)
    0x0948: 0x09C8, // ै -> ৈ (oi kar)
    0x0949: 0x09CB, // ॉ -> ো
    0x094A: 0x09CB, // ॊ -> ো
    0x094B: 0x09CB, // ो -> ো (o kar)
    0x094C: 0x09CC, // ौ -> ৌ (ou kar)
    0x094D: 0x09CD, // ् -> ্ (virama/hasant)
    // Numerals
    0x0966: 0x09E6, // ० -> ০
    0x0967: 0x09E7, // १ -> ১
    0x0968: 0x09E8, // २ -> ২
    0x0969: 0x09E9, // ३ -> ৩
    0x096A: 0x09EA, // ४ -> ৪
    0x096B: 0x09EB, // ५ -> ৫
    0x096C: 0x09EC, // ६ -> ৬
    0x096D: 0x09ED, // ७ -> ৭
    0x096E: 0x09EE, // ८ -> ৮
    0x096F: 0x09EF, // ९ -> ৯
  };

  /// Text-based denomination representations on Bangladesh Bank notes
  static const Map<String, double> _textDenominations = {
    'ONE THOUSAND': 1000,
    'THOUSAND TAKA': 1000,
    'FIVE HUNDRED': 500,
    'TWO HUNDRED': 200,
    'ONE HUNDRED': 100,
    'FIFTY TAKA': 50,
    'TWENTY TAKA': 20,
    'TEN TAKA': 10,
    'একহাজার': 1000,
    'এক হাজার': 1000,
    'পাঁচশত': 500,
    'পাঁচ শত': 500,
    'দুইশত': 200,
    'দুই শত': 200,
    'একশত': 100,
    'এক শত': 100,
    'পঞ্চাশ': 50,
    'বিশ': 20,
    'দশ': 10,
  };

  MoneyScannerService({BanknoteOcrEngine? ocrEngine})
      : _ocrEngine = ocrEngine ?? MlKitBanknoteOcrEngine();

  /// Scans physical money from an [imageFile] and returns structured [BanknoteScanResult].
  /// Runs multi-orientation recognition if portrait photo contains horizontal cash.
  Future<BanknoteScanResult> scanBanknote(XFile imageFile) async {
    try {
      // Pass 1: Original image orientation
      final text0 = await _ocrEngine.extractText(imageFile);
      final result0 = parseBanknoteText(text0);

      // If detection found with serial number (even for partial notes), return immediately
      if (result0.hasDetection && result0.primarySerialNumber != null) {
        return result0;
      }

      // Pass 2: Rotated orientation if photo is vertical (portrait phone capturing horizontal cash)
      try {
        final file = File(imageFile.path);
        if (await file.exists()) {
          final bytes = await file.readAsBytes();
          final decoded = img.decodeImage(bytes);
          if (decoded != null && decoded.height > decoded.width) {
            // Rotate 90 degrees clockwise
            final rotated90 = img.copyRotate(decoded, angle: 90);
            final tempFile90 = File(
              '${Directory.systemTemp.path}/PC_rot90_${DateTime.now().millisecondsSinceEpoch}.jpg',
            );
            await tempFile90.writeAsBytes(img.encodeJpg(rotated90, quality: 90));

            final text90 = await _ocrEngine.extractText(XFile(tempFile90.path));
            await tempFile90.delete().catchError((_) => tempFile90);

            final result90 = parseBanknoteText(text90);
            if (result90.hasDetection) {
              return result90;
            }

            // Also try 270 degrees (90 counter-clockwise)
            final rotated270 = img.copyRotate(decoded, angle: 270);
            final tempFile270 = File(
              '${Directory.systemTemp.path}/PC_rot270_${DateTime.now().millisecondsSinceEpoch}.jpg',
            );
            await tempFile270.writeAsBytes(img.encodeJpg(rotated270, quality: 90));

            final text270 = await _ocrEngine.extractText(XFile(tempFile270.path));
            await tempFile270.delete().catchError((_) => tempFile270);

            final result270 = parseBanknoteText(text270);
            if (result270.hasDetection) {
              return result270;
            }
          }
        }
      } catch (rotError) {
        debugPrint('MoneyScannerService multi-rotation warning: $rotError');
      }

      return result0;
    } catch (e) {
      debugPrint('MoneyScannerService error: $e');
      return BanknoteScanResult.empty(rawText: 'Error: $e');
    }
  }

  /// Parses raw text extracted from a physical Bangladesh Bank banknote or partial note image.
  BanknoteScanResult parseBanknoteText(String rawText) {
    if (rawText.trim().isEmpty) {
      return BanknoteScanResult.empty();
    }

    debugPrint('[MoneyScanner] Raw OCR Text:\n$rawText');

    // 1. Convert any Devanagari script output from OCR to standard Bengali script
    final bengaliScriptText = convertDevanagariToBengali(rawText);

    // 2. Extract potential serial numbers (two Bangla alphabets + 7 numbers prioritized)
    final detectedSerials = _extractSerialNumbers(bengaliScriptText);

    // 3. Normalize Bengali digits to English digits for consistent denomination extraction
    final normalizedText = _normalizeBengaliDigits(bengaliScriptText);

    // 4. Classify Bangladesh Bank denominations
    var detectedDenominations = _extractDenominations(normalizedText);

    // 5. If neither denominations nor serial numbers were detected:
    if (detectedDenominations.isEmpty && detectedSerials.isEmpty) {
      return BanknoteScanResult.empty(rawText: rawText);
    }

    // 6. Non-currency noise rejection:
    // If only small numbers like 10 or 20 are found without any serial, check if context exists
    if (detectedSerials.isEmpty && detectedDenominations.isNotEmpty) {
      final bool hasBanknoteIndicator = detectedDenominations.any((d) => d >= 50) ||
          RegExp(r'(?:BANGLADESH|BANK|TAKA|TK|বাংলাদেশ|ব্যাংক|টাকা|৳)', caseSensitive: false)
              .hasMatch(bengaliScriptText);

      if (!hasBanknoteIndicator) {
        return BanknoteScanResult.empty(rawText: rawText);
      }
    }

    // 7. Handle cashier bundle ink marks (e.g. red "20" on a 1000 note)
    // A single note scan has exactly ONE denomination (the highest detected face value)
    if (detectedDenominations.length > 1 && detectedSerials.length <= 1) {
      final double primaryDenom =
          detectedDenominations.reduce((a, b) => a > b ? a : b);
      detectedDenominations = [primaryDenom];
    }

    // 8. Correlate notes
    final List<BanknoteItem> notes = [];
    if (detectedDenominations.isNotEmpty) {
      for (int i = 0; i < detectedDenominations.length; i++) {
        final denom = detectedDenominations[i];
        final serial = i < detectedSerials.length
            ? detectedSerials[i]
            : (detectedSerials.isNotEmpty ? detectedSerials.first : null);
        notes.add(BanknoteItem(
          denomination: denom,
          serialNumber: serial,
          confidence: 0.95,
          matchedToken: denom.toStringAsFixed(0),
        ));
      }
    } else if (detectedSerials.isNotEmpty) {
      // Partial note detected: note serial number is clearly visible, denomination was cropped/folded
      notes.add(BanknoteItem(
        denomination: 0.0,
        serialNumber: detectedSerials.first,
        confidence: 0.90,
        matchedToken: detectedSerials.first,
      ));
    }

    final double totalAmount =
        notes.isEmpty ? 0.0 : notes.fold(0.0, (sum, n) => sum + n.denomination);
    final String? primarySerial =
        detectedSerials.isNotEmpty ? detectedSerials.first : null;

    final bool hasDetection = notes.isNotEmpty || primarySerial != null;

    debugPrint(
      '[MoneyScanner] Result: Total=$totalAmount, Serial=$primarySerial, Notes=${notes.length}, Detected=$hasDetection',
    );

    return BanknoteScanResult(
      detectedNotes: notes,
      totalAmount: totalAmount,
      primarySerialNumber: primarySerial,
      rawText: rawText,
      hasDetection: hasDetection,
    );
  }

  /// Converts Devanagari script characters into Bengali script characters.
  static String convertDevanagariToBengali(String input) {
    final buffer = StringBuffer();
    for (int i = 0; i < input.length; i++) {
      final codeUnit = input.codeUnitAt(i);
      final mapped = _devanagariToBengaliMap[codeUnit];
      if (mapped != null) {
        buffer.writeCharCode(mapped);
      } else {
        buffer.writeCharCode(codeUnit);
      }
    }
    return buffer.toString();
  }

  /// Converts English ASCII digits ('0'-'9') into Bengali numerals ('০'-'৯').
  static String toBengaliDigits(String input) {
    String output = input;
    const englishToBengali = {
      '0': '০',
      '1': '১',
      '2': '২',
      '3': '৩',
      '4': '৪',
      '5': '৫',
      '6': '৬',
      '7': '৭',
      '8': '৮',
      '9': '৯',
    };
    englishToBengali.forEach((en, bn) {
      output = output.replaceAll(en, bn);
    });
    return output;
  }

  /// Normalizes any Bengali numeral characters in [input] to standard Latin ASCII digits.
  static String _normalizeBengaliDigits(String input) {
    String output = input;
    _bengaliToEnglishDigits.forEach((bengali, english) {
      output = output.replaceAll(bengali, english);
    });
    return output;
  }

  /// Extracts banknote serial numbers from [text], optimized exclusively for Bangladesh Bank notes.
  /// Standard Bangladesh Bank banknote serial anatomy:
  /// Exactly TWO Bengali alphabets followed by 7 Bengali numbers (e.g. "ছদ ৬২৮২০৬৬", "কখ ১২৩৪৫৬৭").
  List<String> _extractSerialNumbers(String text) {
    final List<String> results = [];

    // Priority 1: Exact Bangladesh Bank banknote pattern:
    // Two Bangla alphabets followed by 7 numbers (English or Bengali digits, flexible digit spacing)
    // Allows optional combining vowel signs/nuktas during OCR match which are then cleanly normalized.
    final bangla2LetterPattern = RegExp(
      r'([\u0985-\u09B9\u09CE\u09DC-\u09DF][\u09BE-\u09CD\u09BC]?\s*[\u0985-\u09B9\u09CE\u09DC-\u09DF][\u09BE-\u09CD\u09BC]?)[\s\-:]*([0-9\u09E6-\u09EF\s\-]{7,15})',
      unicode: true,
    );

    for (final match in bangla2LetterPattern.allMatches(text)) {
      var letters = match.group(1)?.replaceAll(RegExp(r'\s+'), '') ?? '';
      // Normalize composite vowels (e.g. অ + া -> আ)
      letters = letters.replaceAll('\u0985\u09BE', '\u0986');
      letters = letters.replaceAll('\u0985\u09C7', '\u098F');
      letters = letters.replaceAll('\u0985\u09CB', '\u0993');
      // Strip any stray vowel signs/matras (e.g. accidental া, ি, ী, ু, ূ, ে, ৈ, ো, ৌ, ্)
      letters = letters.replaceAll(RegExp(r'[\u09BE-\u09CD]'), '');
      // Compose decomposed nukta characters if present
      letters = letters.replaceAll('\u09A1\u09BC', '\u09DC'); // ড + ় -> ড়
      letters = letters.replaceAll('\u09A2\u09BC', '\u09DD'); // ঢ + ় -> ঢ়
      letters = letters.replaceAll('\u09AF\u09BC', '\u09DF'); // য + ় -> য়

      final rawDigits = match.group(2)?.replaceAll(RegExp(r'[\s\-]+'), '') ?? '';
      final digits = _normalizeBengaliDigits(rawDigits);
      if (letters.length == 2 && digits.length == 7) {
        final bnDigits = toBengaliDigits(digits);
        final serial = '$letters $bnDigits';
        if (!results.contains(serial)) {
          results.add(serial);
        }
      }
    }

    // Priority 2: Single Bangla alphabet + 7 numbers (in case 1 letter was cropped in partial note)
    final bangla1LetterPattern = RegExp(
      r'(?<![\u0985-\u09B9\u09CE\u09DC-\u09DF])([\u0985-\u09B9\u09CE\u09DC-\u09DF][\u09BE-\u09CD\u09BC]?)[\s\-:]*([0-9\u09E6-\u09EF\s\-]{7,15})',
      unicode: true,
    );

    for (final match in bangla1LetterPattern.allMatches(text)) {
      var letter = match.group(1)?.trim() ?? '';
      letter = letter.replaceAll('\u0985\u09BE', '\u0986');
      letter = letter.replaceAll(RegExp(r'[\u09BE-\u09CD]'), '');
      letter = letter.replaceAll('\u09A1\u09BC', '\u09DC');
      letter = letter.replaceAll('\u09A2\u09BC', '\u09DD');
      letter = letter.replaceAll('\u09AF\u09BC', '\u09DF');

      final rawDigits = match.group(2)?.replaceAll(RegExp(r'[\s\-]+'), '') ?? '';
      final digits = _normalizeBengaliDigits(rawDigits);
      if (letter.length == 1 && digits.length == 7) {
        final bnDigits = toBengaliDigits(digits);
        final serial = '$letter $bnDigits';
        final alreadyMatched = results.any((s) => s.contains(bnDigits) || s.contains(digits));
        if (!alreadyMatched && !results.contains(serial)) {
          results.add(serial);
        }
      }
    }

    // Priority 3: Latin serial prefixes (e.g. "8K4920194", "E6282066")
    final latinSerialPattern = RegExp(
      r'(?:^|[\s\n\r])([A-Za-z0-9]{1,3})[\s\-:]*([0-9]{6,8})(?:$|[\s\n\r.,;])',
    );

    for (final match in latinSerialPattern.allMatches(text)) {
      final rawPrefix = match.group(1)?.trim().toUpperCase() ?? '';
      final rawDigits = match.group(2)?.trim() ?? '';
      if (RegExp(r'[A-Za-z]').hasMatch(rawPrefix) &&
          (rawDigits.length >= 6 && rawDigits.length <= 8)) {
        final serial = '$rawPrefix$rawDigits';
        final alreadyMatched = results.any((s) => s.contains(rawDigits));
        if (!alreadyMatched && !results.contains(serial)) {
          results.add(serial);
        }
      }
    }

    // Priority 4: Standalone 7-digit numbers (when prefix letters are completely out of frame in partial note)
    final standalone7Pattern = RegExp(
      r'(?<![-/0-9\u09E6-\u09EF])\b([0-9\u09E6-\u09EF\s\-]{7,15})\b(?![-/0-9\u09E6-\u09EF])',
      unicode: true,
    );

    for (final match in standalone7Pattern.allMatches(text)) {
      final rawDigits = match.group(1)?.replaceAll(RegExp(r'[\s\-]+'), '');
      if (rawDigits != null) {
        final normalized = _normalizeBengaliDigits(rawDigits);
        if (normalized.length == 7) {
          final bnDigits = toBengaliDigits(normalized);
          final alreadyContained = results.any((s) => s.contains(bnDigits) || s.contains(normalized));
          if (!alreadyContained && !results.contains(bnDigits)) {
            results.add(bnDigits);
          }
        }
      }
    }

    return results;
  }

  /// Classifies denominations present in [normalizedText], optimized for Bangladesh Bank notes.
  /// Handles common on-device OCR visual substitutions (e.g. "S000", "s000", "2S000" for 1000).
  List<double> _extractDenominations(String normalizedText) {
    final List<double> denominations = [];
    final upperText = normalizedText.toUpperCase();

    // 1. Check textual denomination keywords
    _textDenominations.forEach((keyword, value) {
      if (upperText.contains(keyword)) {
        if (!denominations.contains(value)) {
          denominations.add(value);
        }
      }
    });

    // 2. 1000 Taka note: handles "1000", "১০০০", and OCR font confusions "S000", "s000", "2S000", "I000", "1OOO"
    if (RegExp(r'(?<![0-9])\b(?:1000|[SsIil|]000|2[Ss]000|1[Oo0]{3})\b(?![0-9])')
        .hasMatch(normalizedText)) {
      if (!denominations.contains(1000.0)) denominations.add(1000.0);
    }

    // 3. 500 Taka note: handles "500", "৫০০", "5OO"
    if (RegExp(r'(?<![0-9])\b(?:500|5[Oo0]{2})\b(?![0-9])').hasMatch(normalizedText)) {
      if (!denominations.contains(500.0)) denominations.add(500.0);
    }

    // 4. 200 Taka note: handles "200", "২০০", "2OO"
    if (RegExp(r'(?<![0-9])\b(?:200|2[Oo0]{2})\b(?![0-9])').hasMatch(normalizedText)) {
      if (!denominations.contains(200.0)) denominations.add(200.0);
    }

    // 5. 100 Taka note: handles "100", "১০০", "1OO", "S00", "I00"
    if (RegExp(r'(?<![0-9])\b(?:100|[SsIil|]00|1[Oo0]{2})\b(?![0-9])')
        .hasMatch(normalizedText)) {
      if (!denominations.contains(100.0)) denominations.add(100.0);
    }

    // 6. 50 Taka note: handles "50", "৫০"
    if (RegExp(r'(?<![0-9])\b50\b(?![0-9])').hasMatch(normalizedText)) {
      if (!denominations.contains(50.0)) denominations.add(50.0);
    }

    // 7. 20 Taka note: handles "20", "২০"
    if (RegExp(r'(?<![0-9])\b20\b(?![0-9])').hasMatch(normalizedText)) {
      if (!denominations.contains(20.0)) denominations.add(20.0);
    }

    // 8. 10 Taka note: handles "10", "১০", "I0"
    if (RegExp(r'(?<![0-9])\b(?:10|[SsIil|]0)\b(?![0-9])').hasMatch(normalizedText)) {
      if (!denominations.contains(10.0)) denominations.add(10.0);
    }

    // Sort descending (highest denomination first)
    denominations.sort((a, b) => b.compareTo(a));
    return denominations;
  }

  Future<void> dispose() async {
    await _ocrEngine.dispose();
  }
}
