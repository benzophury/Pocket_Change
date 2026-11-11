import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Function signature for providing the root documents directory.
/// Enables injecting a mock or temporary directory during headless tests.
typedef DirectoryProvider = Future<Directory> Function();

/// Service responsible for managing receipt photo storage on disk.
/// Enforces relative path discipline (`receipts/rec_<txnid>.jpg`) so that
/// database records remain portable across devices, OS migrations, and backup restores.
class ReceiptService {
  final DirectoryProvider _docsDirProvider;

  /// Default receipts directory name relative to documents directory
  static const String receiptsDirectoryName = 'receipts';

  /// Standard receipt image file extension
  static const String defaultExtension = 'jpg';

  /// Singleton instance
  static ReceiptService? _instance;

  /// Returns the singleton instance, initialized with the platform's
  /// [getApplicationDocumentsDirectory].
  static ReceiptService get instance => _instance ??= ReceiptService();

  /// Creates a new [ReceiptService].
  ///
  /// Optionally accepts [docsDirProvider] for headless testing with temporary directories.
  ReceiptService({DirectoryProvider? docsDirProvider})
      : _docsDirProvider = docsDirProvider ?? getApplicationDocumentsDirectory;

  /// Allows resetting or mocking the singleton instance in automated tests.
  @visibleForTesting
  static void resetInstance([ReceiptService? customInstance]) {
    _instance = customInstance;
  }

  /// Sanitizes transaction ID for safe use in file system paths.
  /// Replaces any non-alphanumeric character (except hyphen and underscore) with underscore.
  static String sanitizeTxnId(String txnid) {
    return txnid.trim().replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
  }

  /// Constructs a normalized relative path for a given [txnid] and [extension].
  /// Always uses forward slash `/` separators for cross-platform SQLite compatibility.
  ///
  /// Example: `buildRelativePath("TXN12345")` -> `"receipts/rec_TXN12345.jpg"`
  static String buildRelativePath(String txnid, {String extension = defaultExtension}) {
    final cleanTxnId = sanitizeTxnId(txnid);
    final ext = extension.startsWith('.') ? extension.substring(1) : extension;
    return '$receiptsDirectoryName/rec_$cleanTxnId.$ext';
  }

  /// Gets the documents directory via the configured [DirectoryProvider].
  Future<Directory> get documentsDirectory async => await _docsDirProvider();

  /// Gets the receipts subfolder directory, creating it if it does not exist.
  Future<Directory> get receiptsDirectory async {
    final docsDir = await documentsDirectory;
    final dir = Directory(p.join(docsDir.path, receiptsDirectoryName));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// Resolves the absolute path for a given [relativePath].
  Future<String> resolveFullPath(String relativePath) async {
    final docsDir = await documentsDirectory;
    final cleanRelative = relativePath.trim().replaceAll('\\', '/');
    return p.join(docsDir.path, cleanRelative);
  }

  /// Resolves a relative path (e.g. `receipts/rec_TXN123.jpg`) to an existing [File].
  ///
  /// Returns `null` if [relativePath] is null, blank, or if the file does not exist on disk.
  Future<File?> getReceiptFile(String? relativePath) async {
    if (relativePath == null || relativePath.trim().isEmpty) {
      return null;
    }
    final fullPath = await resolveFullPath(relativePath);
    final file = File(fullPath);
    return (await file.exists()) ? file : null;
  }

  /// Checks whether a receipt image exists on disk for the given [relativePath].
  Future<bool> receiptExists(String? relativePath) async {
    final file = await getReceiptFile(relativePath);
    return file != null;
  }

  /// Saves an image captured via [XFile] (from `image_picker`) into the app's documents directory.
  ///
  /// Enforces relative path discipline: returns relative path `receipts/rec_<txnid>.jpg`.
  Future<String> saveReceiptImage(XFile image, String txnid) async {
    final bytes = await image.readAsBytes();
    return await saveReceiptBytes(bytes, txnid, extension: defaultExtension);
  }

  /// Saves raw image [bytes] to the documents directory under `receipts/rec_<txnid>.<ext>`.
  ///
  /// Returns the normalized relative path for SQLite storage.
  Future<String> saveReceiptBytes(
    Uint8List bytes,
    String txnid, {
    String extension = defaultExtension,
  }) async {
    if (txnid.trim().isEmpty) {
      throw ArgumentError('Transaction ID cannot be empty when saving receipt.');
    }
    if (bytes.isEmpty) {
      throw ArgumentError('Receipt byte data cannot be empty.');
    }

    final relativePath = buildRelativePath(txnid, extension: extension);
    final fullPath = await resolveFullPath(relativePath);
    final file = File(fullPath);

    // Ensure parent directory exists
    final parentDir = file.parent;
    if (!await parentDir.exists()) {
      await parentDir.create(recursive: true);
    }

    // Write bytes with flush for durability
    await file.writeAsBytes(bytes, flush: true);
    return relativePath;
  }

  /// Reads a receipt image file from disk and encodes it into a Base64 string
  /// for inclusion in portable JSON backup files.
  ///
  /// Returns `null` if [relativePath] is null or the file does not exist.
  Future<String?> encodeReceiptToBase64(String? relativePath) async {
    final file = await getReceiptFile(relativePath);
    if (file == null) {
      return null;
    }
    try {
      final bytes = await file.readAsBytes();
      return base64Encode(bytes);
    } catch (_) {
      return null;
    }
  }

  /// Restores a receipt photo from a [base64Data] string back into the documents
  /// directory at [relativePath] during backup restoration.
  ///
  /// Returns the relative path.
  Future<String> restoreReceiptFromBase64(String base64Data, String relativePath) async {
    if (base64Data.trim().isEmpty) {
      throw ArgumentError('Base64 receipt data cannot be empty.');
    }
    if (relativePath.trim().isEmpty) {
      throw ArgumentError('Relative path cannot be empty.');
    }

    final bytes = base64Decode(base64Data.trim());
    final fullPath = await resolveFullPath(relativePath);
    final file = File(fullPath);

    final parentDir = file.parent;
    if (!await parentDir.exists()) {
      await parentDir.create(recursive: true);
    }

    await file.writeAsBytes(bytes, flush: true);
    return relativePath.trim().replaceAll('\\', '/');
  }

  /// Deletes a receipt photo from disk when a transaction is deleted.
  ///
  /// Returns `true` if the file was found and deleted, `false` otherwise.
  Future<bool> deleteReceiptImage(String? relativePath) async {
    final file = await getReceiptFile(relativePath);
    if (file != null) {
      try {
        await file.delete();
        return true;
      } catch (_) {
        return false;
      }
    }
    return false;
  }

  /// Deletes all receipt photos in the `receipts` directory.
  /// Useful during database wipe or full backup restore.
  ///
  /// Returns the number of files deleted.
  Future<int> deleteAllReceipts() async {
    final docsDir = await documentsDirectory;
    final receiptsDir = Directory(p.join(docsDir.path, receiptsDirectoryName));
    if (!await receiptsDir.exists()) {
      return 0;
    }

    int count = 0;
    final entities = receiptsDir.listSync(recursive: true);
    for (final entity in entities) {
      if (entity is File) {
        try {
          await entity.delete();
          count++;
        } catch (_) {}
      }
    }
    return count;
  }
}
