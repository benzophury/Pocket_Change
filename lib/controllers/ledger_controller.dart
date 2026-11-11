import 'dart:collection';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:share_plus/share_plus.dart';

import '../models/backup_payload.dart';
import '../models/ledger_summary.dart';
import '../models/transaction_item.dart';
import '../services/backup_service.dart';
import '../services/database_helper.dart';
import '../services/receipt_service.dart';
import '../utils/txnid_generator.dart';

/// Central reactive state controller managing transactions, balances,
/// receipts, and backup import/export for the Pocket Change MFS app.
class LedgerController extends ChangeNotifier {
  final DatabaseHelper _dbHelper;
  final ReceiptService _receiptService;
  final BackupService _backupService;
  final DateTime Function() _nowProvider;

  List<TransactionItem> _transactions = [];
  LedgerSummary _summary = LedgerSummary.zero;
  bool _isLoading = false;
  String? _errorMessage;
  int _photoCount = 0;

  LedgerController({
    DatabaseHelper? dbHelper,
    ReceiptService? receiptService,
    BackupService? backupService,
    DateTime Function()? nowProvider,
  })  : _dbHelper = dbHelper ?? DatabaseHelper.instance,
        _receiptService = receiptService ?? ReceiptService.instance,
        _backupService = backupService ?? BackupService.instance,
        _nowProvider = nowProvider ?? DateTime.now;

  // --- Exposed Services (for screen injection) ---
  DatabaseHelper get dbHelper => _dbHelper;
  ReceiptService get receiptService => _receiptService;
  BackupService get backupService => _backupService;

  // --- Reactive Getters ---
  UnmodifiableListView<TransactionItem> get transactions =>
      UnmodifiableListView(_transactions);

  LedgerSummary get summary => _summary;
  double get balance => _summary.balance;
  double get totalIn => _summary.totalIn;
  double get totalOut => _summary.totalOut;
  int get totalCount => _summary.totalCount;
  int get photoCount => _photoCount;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;
  bool get hasError => _errorMessage != null;
  bool get isEmpty => _transactions.isEmpty;

  /// Loads all transactions and calculates ledger summary from SQLite.
  Future<void> loadLedger() async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      _transactions = await _dbHelper.getAllTransactions();
      _summary = await _dbHelper.getSummary();
      _photoCount = _transactions.where((t) => t.hasMemoPhoto).length;
    } catch (e) {
      _errorMessage = 'Failed to load ledger: $e';
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Records cash addition ("Add Money") into the ledger.
  Future<TransactionItem> addMoney({
    required double amount,
    String? notes,
    String? category,
  }) async {
    if (amount <= 0) {
      throw ArgumentError('Amount must be strictly positive (> 0)');
    }

    final txnid = TxnIdGenerator.generate();
    final txn = TransactionItem(
      txnid: txnid,
      type: TransactionType.add,
      amount: amount,
      timestamp: _nowProvider(),
      notes: notes?.trim().isEmpty == true ? null : notes?.trim(),
      category: category?.trim().isEmpty == true ? null : category?.trim(),
    );

    await _dbHelper.insertTransaction(txn);
    await loadLedger();
    return txn;
  }

  /// Records cash payment ("Pay") with optional memo receipt photo.
  Future<TransactionItem> recordPayment({
    required double amount,
    String? notes,
    String? category,
    XFile? receiptImage,
    Uint8List? receiptBytes,
    String? receiptExtension,
  }) async {
    if (amount <= 0) {
      throw ArgumentError('Amount must be strictly positive (> 0)');
    }

    final txnid = TxnIdGenerator.generate();
    String? memoPath;

    if (receiptImage != null) {
      memoPath = await _receiptService.saveReceiptImage(receiptImage, txnid);
    } else if (receiptBytes != null && receiptBytes.isNotEmpty) {
      memoPath = await _receiptService.saveReceiptBytes(
        receiptBytes,
        txnid,
        extension: receiptExtension ?? 'jpg',
      );
    }

    final txn = TransactionItem(
      txnid: txnid,
      type: TransactionType.pay,
      amount: amount,
      timestamp: _nowProvider(),
      memoPhotoPath: memoPath,
      notes: notes?.trim().isEmpty == true ? null : notes?.trim(),
      category: category?.trim().isEmpty == true ? null : category?.trim(),
    );

    await _dbHelper.insertTransaction(txn);
    await loadLedger();
    return txn;
  }

  /// Deletes a transaction from the SQLite ledger and removes associated memo photo if present.
  Future<bool> deleteTransaction(TransactionItem txn) async {
    try {
      int deleted = 0;
      if (txn.id != null) {
        deleted = await _dbHelper.deleteTransaction(txn.id!);
      } else {
        deleted = await _dbHelper.deleteTransactionByTxnId(txn.txnid);
      }

      if (deleted > 0) {
        if (txn.hasMemoPhoto && txn.memoPhotoPath != null) {
          try {
            await _receiptService.deleteReceiptImage(txn.memoPhotoPath!);
          } catch (_) {}
        }
        await loadLedger();
        return true;
      }
      return false;
    } catch (e) {
      _errorMessage = 'Failed to delete transaction: $e';
      notifyListeners();
      return false;
    }
  }

  /// Exports ledger to a temporary JSON backup file.
  Future<File> exportBackup() async {
    return await _backupService.exportBackupFile();
  }

  /// Shares backup file via native share sheet.
  Future<ShareResult> shareBackup(File file) async {
    return await _backupService.shareBackupFile(file);
  }

  /// Validates backup JSON string prior to restoration.
  Future<BackupValidationResult> validateBackup(String jsonStr) async {
    return await _backupService.validateBackupJson(jsonStr);
  }

  /// Restores backup from JSON string.
  Future<BackupSummary> restoreBackup(
    String jsonStr, {
    bool clearExisting = true,
  }) async {
    _isLoading = true;
    notifyListeners();

    try {
      final summary = await _backupService.importBackupJson(
        jsonStr,
        clearExisting: clearExisting,
      );
      await loadLedger();
      return summary;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Clears all database records and deletes stored receipts.
  Future<void> clearAll() async {
    await _dbHelper.clearAll();
    await _receiptService.deleteAllReceipts();
    await loadLedger();
  }

  /// Resolves absolute file path for a receipt image.
  Future<File?> getReceiptFile(String? relativePath) async {
    return await _receiptService.getReceiptFile(relativePath);
  }
}

/// InheritedWidget providing [LedgerController] down the widget tree.
class LedgerScope extends InheritedNotifier<LedgerController> {
  const LedgerScope({
    super.key,
    required LedgerController controller,
    required super.child,
  }) : super(notifier: controller);

  static LedgerController of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<LedgerScope>();
    assert(scope != null, 'No LedgerScope found in context hierarchy.');
    return scope!.notifier!;
  }

  static LedgerController? maybeOf(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<LedgerScope>();
    return scope?.notifier;
  }
}
