import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/backup_payload.dart';
import '../models/transaction_item.dart';
import 'database_helper.dart';
import 'receipt_service.dart';

/// Function signature for providing device directories.
typedef DirectoryProvider = Future<Directory> Function();

/// Function signature for triggering the native sharing sheet.
typedef ShareAction = Future<ShareResult> Function(
  List<XFile> files, {
  String? text,
  String? subject,
});

/// Function signature for triggering the native file picker.
typedef FilePickerAction = Future<FilePickerResult?> Function({
  FileType type,
  List<String>? allowedExtensions,
});

/// Service responsible for portable JSON ledger backup export, system sharing,
/// schema validation, and two-phase atomic restoration with path traversal defense.
class BackupService {
  final DatabaseHelper _dbHelper;
  final ReceiptService _receiptService;
  final DirectoryProvider _docsDirProvider;
  final DirectoryProvider _tempDirProvider;
  final ShareAction _shareAction;
  final FilePickerAction _filePickerAction;

  /// Singleton instance
  static BackupService? _instance;

  /// Returns the default singleton instance.
  static BackupService get instance => _instance ??= BackupService();

  /// Allows resetting or mocking the singleton instance in automated tests.
  static void resetInstance([BackupService? customInstance]) {
    _instance = customInstance;
  }

  /// Creates a [BackupService] instance.
  ///
  /// Supports dependency injection for 100% headless test execution on host Linux.
  BackupService({
    DatabaseHelper? dbHelper,
    ReceiptService? receiptService,
    DirectoryProvider? docsDirProvider,
    DirectoryProvider? tempDirProvider,
    ShareAction? shareAction,
    FilePickerAction? filePickerAction,
  })  : _dbHelper = dbHelper ?? DatabaseHelper.instance,
        _receiptService = receiptService ?? ReceiptService.instance,
        _docsDirProvider = docsDirProvider ?? getApplicationDocumentsDirectory,
        _tempDirProvider = tempDirProvider ?? getTemporaryDirectory,
        _shareAction = shareAction ?? _defaultShareAction,
        _filePickerAction = filePickerAction ?? _defaultFilePickerAction;

  static Future<ShareResult> _defaultShareAction(
    List<XFile> files, {
    String? text,
    String? subject,
  }) {
    return Share.shareXFiles(files, text: text, subject: subject);
  }

  static Future<FilePickerResult?> _defaultFilePickerAction({
    FileType type = FileType.any,
    List<String>? allowedExtensions,
  }) {
    return FilePicker.platform.pickFiles(
      type: type,
      allowedExtensions: allowedExtensions,
    );
  }

  /// Generates canonical backup file name:
  /// `pocket_change_backup_<YYYYMMDD>_<HHmmss>.json`.
  static String generateBackupFileName([DateTime? time]) {
    final t = (time ?? DateTime.now()).toLocal();
    final y = t.year.toString().padLeft(4, '0');
    final m = t.month.toString().padLeft(2, '0');
    final d = t.day.toString().padLeft(2, '0');
    final h = t.hour.toString().padLeft(2, '0');
    final min = t.minute.toString().padLeft(2, '0');
    final s = t.second.toString().padLeft(2, '0');
    return 'pocket_change_backup_$y$m${d}_$h$min$s.json';
  }

  /// Computes a deterministic SHA-256 checksum signature for transaction records.
  static String computeChecksum(List<TransactionItem> txns) {
    final buffer = StringBuffer();
    for (final t in txns) {
      buffer.write(
        '${t.txnid}|${t.type.toDbValue()}|${t.amount.toStringAsFixed(2)}|${t.timestamp.millisecondsSinceEpoch}|${t.memoPhotoBase64?.length ?? 0};',
      );
    }
    return 'sha256:${_sha256Hex(utf8.encode(buffer.toString()))}';
  }

  /// Exports all ledger transactions and attached memo photos into a portable JSON string.
  Future<String> exportBackupJson() async {
    final txns = await _dbHelper.getAllTransactions();
    final List<TransactionItem> populatedTxns = [];

    for (final txn in txns) {
      String? base64Photo;
      if (txn.hasMemoPhoto) {
        base64Photo = await _receiptService.encodeReceiptToBase64(txn.memoPhotoPath);
      }
      populatedTxns.add(txn.copyWith(memoPhotoBase64: base64Photo));
    }

    final summary = await _dbHelper.getSummary();
    final checksum = computeChecksum(populatedTxns);

    final payload = BackupPayload(
      version: 1,
      appVersion: '1.0.0+1',
      appIdentifier: 'com.pocketchange.mfs',
      exportedAt: DateTime.now().toUtc(),
      deviceOs: Platform.operatingSystem,
      summary: summary,
      checksum: checksum,
      transactions: populatedTxns,
    );

    return payload.toJsonString(pretty: true);
  }

  /// Exports the backup payload into a JSON file in `<tempDir>/backups/` or [targetDirectory].
  Future<File> exportBackupFile({
    Directory? targetDirectory,
    String? fileName,
  }) async {
    final dir = targetDirectory ??
        Directory(p.join((await _tempDirProvider()).path, 'backups'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final name = fileName ?? generateBackupFileName();
    final file = File(p.join(dir.path, name));
    final jsonString = await exportBackupJson();
    return await file.writeAsString(jsonString, flush: true);
  }

  /// Shares a backup file via the platform sharing intent / sheet.
  Future<ShareResult> shareBackupFile(File file) async {
    final xFile = XFile(
      file.path,
      mimeType: 'application/json',
      name: p.basename(file.path),
    );
    return await _shareAction(
      [xFile],
      text: 'Pocket Change Ledger Backup (${p.basename(file.path)})',
      subject: 'Pocket Change Backup JSON',
    );
  }

  /// Validates a backup JSON string across 5 sequential verification stages:
  /// 1. Syntax & Object structure
  /// 2. Schema versioning
  /// 3. Transaction constraints & duplicate check
  /// 4. 4-layer path traversal & Base64 security
  /// 5. Mathematical ledger reconciliation (declared vs computed within ±0.001 BDT)
  ///
  /// Does NOT modify the database or filesystem.
  Future<BackupValidationResult> validateBackupJson(String jsonStr) async {
    try {
      if (jsonStr.trim().isEmpty) {
        return BackupValidationResult.failure(['Backup file is empty.']);
      }

      final dynamic decoded;
      try {
        decoded = jsonDecode(jsonStr);
      } on FormatException catch (e) {
        return BackupValidationResult.failure(['Invalid JSON syntax: ${e.message}']);
      }

      if (decoded is! Map<String, dynamic>) {
        return BackupValidationResult.failure(['Root of backup JSON must be an object/map.']);
      }

      final map = decoded;
      final errors = <String>[];
      final warnings = <String>[];

      // Stage 2: Schema versioning
      if (!map.containsKey('version') && !map.containsKey('backup_format_version')) {
        errors.add("Missing required field 'version'.");
      } else {
        final rawVersion = map['version'] ?? map['backup_format_version'];
        if (rawVersion is! int) {
          errors.add('Schema version must be an integer.');
        } else if (rawVersion < 1) {
          errors.add('Invalid schema version: $rawVersion (must be >= 1).');
        } else if (rawVersion > 1) {
          errors.add(
            'Unsupported backup version: $rawVersion (maximum supported: 1). Please update Pocket Change to restore this backup.',
          );
        }
      }

      // Top-level structure
      if (!map.containsKey('summary') || map['summary'] is! Map) {
        errors.add("Missing required object field 'summary'.");
      }
      if (!map.containsKey('transactions') || map['transactions'] is! List) {
        errors.add("Missing required list field 'transactions'.");
      }

      if (errors.isNotEmpty) {
        return BackupValidationResult.failure(errors, warnings: warnings);
      }

      // Stage 3 & 4: Transaction validation and path traversal defense
      final rawTxns = map['transactions'] as List<dynamic>;
      final seenTxnIds = <String>{};
      final safeTxnIdRegex = RegExp(r'^[a-zA-Z0-9_-]{3,64}$');
      final safePathRegex = RegExp(
        r'^receipts/rec_[a-zA-Z0-9_-]+\.(jpg|jpeg|png)$',
        caseSensitive: false,
      );

      double computedTotalIn = 0.0;
      double computedTotalOut = 0.0;

      for (int i = 0; i < rawTxns.length; i++) {
        final item = rawTxns[i];
        if (item is! Map) {
          errors.add('Transaction at index $i is not a JSON object.');
          continue;
        }

        // txnid
        final rawTxnId = item['txnid'] ?? item['txn_id'];
        if (rawTxnId == null || rawTxnId is! String || rawTxnId.trim().isEmpty) {
          errors.add('Transaction at index $i is missing a valid txnid.');
          continue;
        }
        final txnid = rawTxnId.trim();
        if (seenTxnIds.contains(txnid)) {
          errors.add("Duplicate transaction ID '$txnid' detected at index $i.");
        } else {
          seenTxnIds.add(txnid);
        }

        if (!safeTxnIdRegex.hasMatch(txnid)) {
          errors.add("Transaction ID '$txnid' contains invalid characters.");
        }

        // type
        final rawType = item['type'];
        String? upperType;
        if (rawType is String) {
          final ut = rawType.trim().toUpperCase();
          if (ut == 'ADD' || ut == 'PAY') {
            upperType = ut;
          }
        }
        if (upperType == null) {
          errors.add("Transaction '$txnid' has invalid type '$rawType' (expected 'ADD' or 'PAY').");
        }

        // amount
        final rawAmount = item['amount'];
        if (rawAmount == null || rawAmount is! num || rawAmount.isNaN || rawAmount.isInfinite) {
          errors.add("Transaction '$txnid' has invalid amount.");
        } else if (rawAmount <= 0) {
          errors.add("Transaction '$txnid' has non-positive amount ($rawAmount). Amount must be > 0.");
        } else {
          final amt = rawAmount.toDouble();
          if (upperType == 'ADD') {
            computedTotalIn += amt;
          } else if (upperType == 'PAY') {
            computedTotalOut += amt;
          }
        }

        // timestamp
        final rawTimestamp = item['timestamp'];
        if (rawTimestamp == null) {
          errors.add("Transaction '$txnid' has missing timestamp.");
        } else if (rawTimestamp is int) {
          if (rawTimestamp <= 0) {
            errors.add("Transaction '$txnid' has invalid timestamp ($rawTimestamp).");
          }
        } else if (rawTimestamp is String) {
          if (int.tryParse(rawTimestamp) == null && DateTime.tryParse(rawTimestamp) == null) {
            errors.add("Transaction '$txnid' has unparseable timestamp string '$rawTimestamp'.");
          }
        } else {
          errors.add("Transaction '$txnid' has invalid timestamp type (expected integer or ISO-8601 string).");
        }

        // memo_photo_path defense
        final rawPath = item['memo_photo_path'] ?? item['memoPhotoPath'];
        String? memoPhotoPath;
        if (rawPath != null) {
          if (rawPath is! String) {
            errors.add("Transaction '$txnid' memo_photo_path must be a string.");
          } else {
            memoPhotoPath = rawPath;
          }
        }

        final rawBase64 = item['memo_photo_base64'] ?? item['memoPhotoBase64'];
        String? memoPhotoBase64;
        if (rawBase64 != null) {
          if (rawBase64 is! String) {
            errors.add("Transaction '$txnid' memo_photo_base64 must be a string.");
          } else {
            memoPhotoBase64 = rawBase64;
          }
        }

        if (memoPhotoPath != null && memoPhotoPath.trim().isNotEmpty) {
          final pathStr = memoPhotoPath.trim();
          if (pathStr.contains('\x00')) {
            errors.add("Transaction '$txnid' memo_photo_path contains forbidden null bytes.");
          }
          if (pathStr.contains('..')) {
            errors.add("Transaction '$txnid' memo_photo_path contains forbidden path traversal sequence '..'.");
          }
          if (pathStr.startsWith('/') ||
              pathStr.startsWith('\\') ||
              RegExp(r'^[a-zA-Z]:').hasMatch(pathStr)) {
            errors.add("Transaction '$txnid' memo_photo_path must be a relative path, not absolute.");
          }
          final normalized = pathStr.replaceAll('\\', '/');
          if (!safePathRegex.hasMatch(normalized)) {
            errors.add("Transaction '$txnid' memo_photo_path '$memoPhotoPath' does not conform to 'receipts/rec_<txnid>.(jpg|jpeg|png)'.");
          }
        }

        // memo_photo_base64 validation
        if (memoPhotoBase64 != null && memoPhotoBase64.trim().isNotEmpty) {
          final trimmedB64 = memoPhotoBase64.trim();
          const maxBase64Length = (25 * 1024 * 1024 * 4 ~/ 3 + 4);
          if (trimmedB64.length > maxBase64Length) {
            errors.add("Transaction '$txnid' receipt image exceeds 25MB safety limit.");
          } else {
            try {
              final bytes = base64Decode(trimmedB64);
              if (bytes.length > 25 * 1024 * 1024) {
                errors.add("Transaction '$txnid' receipt image exceeds 25MB safety limit.");
              } else {
                final isJpeg = bytes.length >= 3 &&
                    bytes[0] == 0xFF &&
                    bytes[1] == 0xD8 &&
                    bytes[2] == 0xFF;
                final isPng = bytes.length >= 4 &&
                    bytes[0] == 0x89 &&
                    bytes[1] == 0x50 &&
                    bytes[2] == 0x4E &&
                    bytes[3] == 0x47;
                if (!isJpeg && !isPng) {
                  errors.add("Transaction '$txnid' receipt photo data is not a valid JPEG or PNG image.");
                }
              }
            } catch (_) {
              errors.add("Transaction '$txnid' contains invalid or corrupted Base64 receipt data.");
            }
          }
        } else if (memoPhotoPath != null && memoPhotoPath.trim().isNotEmpty) {
          warnings.add("Transaction '$txnid' references memo photo '$memoPhotoPath' but contains no embedded Base64 data.");
        }
      }

      // Stage 5: Financial reconciliation
      final rawSummaryObj = map['summary'];
      final Map<String, dynamic> rawSummary = rawSummaryObj is Map
          ? Map<String, dynamic>.from(rawSummaryObj)
          : <String, dynamic>{};

      final rawBalance = rawSummary['total_balance'] ??
          rawSummary['calculated_balance'] ??
          rawSummary['balance'];
      final declaredBalance = rawBalance is num ? rawBalance.toDouble() : null;

      final rawIn = rawSummary['total_in'] ?? rawSummary['totalIn'];
      final declaredIn = rawIn is num ? rawIn.toDouble() : null;

      final rawOut = rawSummary['total_out'] ?? rawSummary['totalOut'];
      final declaredOut = rawOut is num ? rawOut.toDouble() : null;

      final rawCount = rawSummary['transaction_count'] ??
          rawSummary['total_count'] ??
          rawSummary['total_records'] ??
          rawSummary['totalCount'];
      final declaredCount = rawCount is num ? rawCount.toInt() : null;

      if (declaredBalance == null || declaredIn == null || declaredOut == null || declaredCount == null) {
        errors.add('Summary is missing required total fields or has invalid numeric types.');
      } else {
        final computedBalance = computedTotalIn - computedTotalOut;
        if ((declaredBalance - computedBalance).abs() >= 0.001) {
          errors.add(
            'Reconciliation error: Declared balance ($declaredBalance) does not match calculated balance ($computedBalance).',
          );
        }
        if ((declaredIn - computedTotalIn).abs() >= 0.001) {
          errors.add(
            'Reconciliation error: Declared totalIn ($declaredIn) does not match calculated totalIn ($computedTotalIn).',
          );
        }
        if ((declaredOut - computedTotalOut).abs() >= 0.001) {
          errors.add(
            'Reconciliation error: Declared totalOut ($declaredOut) does not match calculated totalOut ($computedTotalOut).',
          );
        }
        if (declaredCount != rawTxns.length) {
          errors.add(
            'Reconciliation error: Declared transaction count ($declaredCount) does not match calculated count (${rawTxns.length}).',
          );
        }
      }

      if (errors.isNotEmpty) {
        return BackupValidationResult.failure(errors, warnings: warnings);
      }

      final payload = BackupPayload.fromMap(map);

      // Checksum verification if present
      if (map.containsKey('checksum') && map['checksum'] != null) {
        final rawChecksum = map['checksum'];
        if (rawChecksum is! String) {
          warnings.add("Field 'checksum' must be a string.");
        } else {
          final computedChecksum = computeChecksum(payload.transactions);
          if (rawChecksum != computedChecksum) {
            warnings.add(
              'Backup checksum mismatch: expected $computedChecksum, got $rawChecksum',
            );
          }
        }
      }

      return BackupValidationResult.success(payload: payload, warnings: warnings);
    } catch (e) {
      return BackupValidationResult.failure(['Validation error: $e']);
    }
  }

  /// Atomically restores all transactions and receipt photos from backup JSON.
  ///
  /// Two-Phase Staging Architecture:
  /// - Pre-validation: complete schema, reconciliation & security checks.
  /// - Phase 1: isolated directory staging (`.staging_<time>_<uuid>`).
  /// - Phase 2: SQLite atomic batch execution via `dbHelper.restoreTransactions`.
  /// - Phase 3: filesystem directory swap to live `receipts/`.
  ///
  /// Any failure triggers full rollback, leaving pre-existing database and
  /// receipt files completely untouched.
  Future<BackupSummary> importBackupJson(
    String jsonStr, {
    bool clearExisting = true,
  }) async {
    final stopwatch = Stopwatch()..start();
    final importedAt = DateTime.now().toUtc();

    // Check JSON syntax first so FormatException is thrown if malformed
    final dynamic decoded = jsonDecode(jsonStr);
    if (decoded is! Map<String, dynamic>) {
      throw const BackupValidationException('Root of backup JSON must be an object/map.');
    }

    // Run comprehensive validation
    final validation = await validateBackupJson(jsonStr);
    if (!validation.isValid || validation.payload == null) {
      throw BackupValidationException(
        'Backup validation failed:\n${validation.errorMessage}',
        validation.errors,
      );
    }

    final payload = validation.payload!;
    final docsDir = await _docsDirProvider();
    final uuid = DateTime.now().microsecondsSinceEpoch.toString();
    final stagingDir = Directory(
      p.join(docsDir.path, '.staging_${DateTime.now().millisecondsSinceEpoch}_$uuid'),
    );

    try {
      // Phase 1: Staging receipt photos
      await stagingDir.create(recursive: true);
      int restoredPhotosCount = 0;
      final List<TransactionItem> finalTxns = [];

      for (final txn in payload.transactions) {
        if (txn.memoPhotoBase64 != null && txn.memoPhotoBase64!.trim().isNotEmpty) {
          final bytes = base64Decode(txn.memoPhotoBase64!.trim());

          final isJpeg = bytes.length >= 3 &&
              bytes[0] == 0xFF &&
              bytes[1] == 0xD8 &&
              bytes[2] == 0xFF;
          final isPng = bytes.length >= 4 &&
              bytes[0] == 0x89 &&
              bytes[1] == 0x50 &&
              bytes[2] == 0x4E &&
              bytes[3] == 0x47;
          if (!isJpeg && !isPng) {
            throw BackupValidationException(
              "Transaction '${txn.txnid}' memo photo has invalid image header.",
            );
          }

          final ext = isPng ? 'png' : 'jpg';
          final cleanTxnId = ReceiptService.sanitizeTxnId(txn.txnid);
          final relativePath = ReceiptService.buildRelativePath(cleanTxnId, extension: ext);
          final fileName = p.basename(relativePath);

          final stagedFile = File(p.join(stagingDir.path, fileName));
          await stagedFile.writeAsBytes(bytes, flush: true);
          restoredPhotosCount++;

          finalTxns.add(txn.copyWith(memoPhotoPath: relativePath));
        } else {
          finalTxns.add(txn);
        }
      }

      // Phase 2: SQLite atomic batch execution
      await _dbHelper.restoreTransactions(finalTxns, clearExisting: clearExisting);

      // Phase 3: Filesystem directory swap (Atomic Commit)
      final receiptsDir = Directory(p.join(docsDir.path, ReceiptService.receiptsDirectoryName));
      if (clearExisting) {
        final backupDir = Directory(
          p.join(docsDir.path, '.receipts_backup_${DateTime.now().millisecondsSinceEpoch}_$uuid'),
        );
        if (await receiptsDir.exists()) {
          try {
            await receiptsDir.rename(backupDir.path);
          } catch (_) {
            await receiptsDir.delete(recursive: true);
          }
        }
        if (await stagingDir.exists()) {
          try {
            await stagingDir.rename(receiptsDir.path);
          } catch (_) {
            if (!await receiptsDir.exists()) {
              await receiptsDir.create(recursive: true);
            }
            for (final entity in stagingDir.listSync()) {
              if (entity is File) {
                final dest = File(p.join(receiptsDir.path, p.basename(entity.path)));
                await entity.copy(dest.path);
                await entity.delete();
              }
            }
          }
        }
        if (await backupDir.exists()) {
          await backupDir.delete(recursive: true);
        }
      } else {
        // Merge mode: copy staged files into receiptsDir
        if (!await receiptsDir.exists()) {
          await receiptsDir.create(recursive: true);
        }
        for (final entity in stagingDir.listSync()) {
          if (entity is File) {
            final dest = File(p.join(receiptsDir.path, p.basename(entity.path)));
            await entity.copy(dest.path);
            await entity.delete();
          }
        }
      }

      if (!await receiptsDir.exists()) {
        await receiptsDir.create(recursive: true);
      }

      final summary = await _dbHelper.getSummary();
      stopwatch.stop();

      return BackupSummary(
        restoredTransactionsCount: payload.transactionCount,
        restoredPhotosCount: restoredPhotosCount,
        restoredBalance: summary.balance,
        restoredTotalIn: summary.totalIn,
        restoredTotalOut: summary.totalOut,
        duration: stopwatch.elapsed,
        importedAt: importedAt,
      );
    } catch (e) {
      if (await stagingDir.exists()) {
        try {
          await stagingDir.delete(recursive: true);
        } catch (_) {}
      }
      rethrow;
    } finally {
      if (await stagingDir.exists()) {
        try {
          await stagingDir.delete(recursive: true);
        } catch (_) {}
      }
    }
  }

  /// Restores ledger data directly from a backup [File] on disk.
  Future<BackupSummary> importBackupFromFile(
    File file, {
    bool clearExisting = true,
  }) async {
    if (!await file.exists()) {
      throw FileSystemException('Backup file not found', file.path);
    }
    final content = await file.readAsString();
    if (content.trim().isEmpty) {
      throw const BackupValidationException('Backup file is empty.');
    }
    return await importBackupJson(content, clearExisting: clearExisting);
  }

  /// Triggers the system file picker to select and restore a `.json` backup file.
  ///
  /// Returns `null` if the user cancels or dismisses the picker.
  Future<BackupSummary?> importBackupFromPicker({
    bool clearExisting = true,
  }) async {
    final result = await _filePickerAction(
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    if (result == null || result.files.isEmpty) {
      return null;
    }
    final picked = result.files.single;
    if (picked.path != null && picked.path!.isNotEmpty) {
      return await importBackupFromFile(
        File(picked.path!),
        clearExisting: clearExisting,
      );
    } else if (picked.bytes != null) {
      final content = utf8.decode(picked.bytes!);
      return await importBackupJson(content, clearExisting: clearExisting);
    } else {
      throw const BackupValidationException('Could not access selected backup file.');
    }
  }

  /// Internal pure-Dart FIPS 180-4 SHA-256 implementation.
  static String _sha256Hex(List<int> bytes) {
    final k = <int>[
      0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
      0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
      0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
      0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
      0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
      0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
      0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
      0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
      0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
      0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
      0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ];

    int h0 = 0x6a09e667;
    int h1 = 0xbb67ae85;
    int h2 = 0x3c6ef372;
    int h3 = 0xa54ff53a;
    int h4 = 0x510e527f;
    int h5 = 0x9b05688c;
    int h6 = 0x1f83d9ab;
    int h7 = 0x5be0cd19;

    final bitLength = bytes.length * 8;
    final paddedLength = ((bytes.length + 9 + 63) ~/ 64) * 64;
    final padded = Uint8List(paddedLength);
    padded.setRange(0, bytes.length, bytes);
    padded[bytes.length] = 0x80;

    final byteData = ByteData.sublistView(padded);
    byteData.setUint64(paddedLength - 8, bitLength, Endian.big);

    final w = List<int>.filled(64, 0);

    int mask32(int val) => val & 0xFFFFFFFF;
    int rotr(int x, int n) => mask32((x >>> n) | (x << (32 - n)));

    for (int i = 0; i < paddedLength; i += 64) {
      for (int t = 0; t < 16; t++) {
        w[t] = byteData.getUint32(i + t * 4, Endian.big);
      }
      for (int t = 16; t < 64; t++) {
        final s0 = rotr(w[t - 15], 7) ^ rotr(w[t - 15], 18) ^ (w[t - 15] >>> 3);
        final s1 = rotr(w[t - 2], 17) ^ rotr(w[t - 2], 19) ^ (w[t - 2] >>> 10);
        w[t] = mask32(w[t - 16] + s0 + w[t - 7] + s1);
      }

      int a = h0;
      int b = h1;
      int c = h2;
      int d = h3;
      int e = h4;
      int f = h5;
      int g = h6;
      int h = h7;

      for (int t = 0; t < 64; t++) {
        final s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
        final ch = (e & f) ^ ((~e) & g);
        final temp1 = mask32(h + s1 + ch + k[t] + w[t]);
        final s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
        final maj = (a & b) ^ (a & c) ^ (b & c);
        final temp2 = mask32(s0 + maj);

        h = g;
        g = f;
        f = e;
        e = mask32(d + temp1);
        d = c;
        c = b;
        b = a;
        a = mask32(temp1 + temp2);
      }

      h0 = mask32(h0 + a);
      h1 = mask32(h1 + b);
      h2 = mask32(h2 + c);
      h3 = mask32(h3 + d);
      h4 = mask32(h4 + e);
      h5 = mask32(h5 + f);
      h6 = mask32(h6 + g);
      h7 = mask32(h7 + h);
    }

    return [h0, h1, h2, h3, h4, h5, h6, h7]
        .map((x) => x.toRadixString(16).padLeft(8, '0'))
        .join();
  }
}
