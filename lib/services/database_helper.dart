import 'dart:async';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../models/ledger_summary.dart';
import '../models/transaction_item.dart';

/// Database Helper providing SQLite persistence, lifecycle management, and
/// dynamic cash balance computation for the Pocket Change digital ledger.
///
/// Features:
/// - Singleton pattern with dependency injection for headless test runners (`sqflite_common_ffi`).
/// - Full table DDL with strict integrity constraints (`CHECK(type IN ('ADD', 'PAY'))`, `CHECK(amount > 0)`).
/// - High-performance composite and single-column indexes on timestamp, txnid, and type.
/// - Dynamic `ledger_summary` SQL view calculating real-time balance and cash flow totals with zero desync risk.
/// - Atomic batch restore operations within protected SQLite transactions.
class DatabaseHelper {
  /// Active singleton instance for application runtime (can be overridden in tests).
  static DatabaseHelper instance = DatabaseHelper._internal();

  /// Resets the singleton instance back to the default internal instance.
  static void resetInstance() {
    instance = DatabaseHelper._internal();
  }

  // --- Database Metadata ---
  static const String databaseName = 'pocket_change.db';
  static const int databaseVersion = 1;

  // --- Table & View Names ---
  static const String tableTransactions = 'transactions';
  static const String viewLedgerSummary = 'ledger_summary';

  // --- Column Names ---
  static const String columnId = 'id';
  static const String columnTxnId = 'txnid';
  static const String columnType = 'type';
  static const String columnAmount = 'amount';
  static const String columnTimestamp = 'timestamp';
  static const String columnMemoPhotoPath = 'memo_photo_path';
  static const String columnNotes = 'notes';
  static const String columnCategory = 'category';

  Database? _database;
  DatabaseFactory? _customFactory;
  String? _customPath;
  Future<Database>? _openingFuture;

  /// Internal constructor for standard singleton.
  DatabaseHelper._internal();

  /// Creates a [DatabaseHelper] with optional dependency injection.
  ///
  /// For headless unit tests:
  /// ```dart
  /// final helper = DatabaseHelper(
  ///   databaseFactory: databaseFactoryFfi,
  ///   databasePath: inMemoryDatabasePath,
  /// );
  /// ```
  DatabaseHelper({
    DatabaseFactory? databaseFactory,
    String? databasePath,
    Database? database,
  })  : _customFactory = databaseFactory,
        _customPath = databasePath,
        _database = database;

  /// Creates a [DatabaseHelper] wrapping an existing open [Database] instance.
  factory DatabaseHelper.withDatabase(Database db) {
    return DatabaseHelper(database: db);
  }

  /// Reconfigures database factory and path for testing or tenant separation.
  void configure({DatabaseFactory? databaseFactory, String? databasePath}) {
    _customFactory = databaseFactory;
    _customPath = databasePath;
  }

  /// Resolves the absolute database file path, or returns `:memory:` for in-memory databases.
  Future<String> getDatabasePath() async {
    if (_customPath != null) {
      return _customPath!;
    }
    final factory = _customFactory ?? databaseFactory;
    final databasesPath = await factory.getDatabasesPath();
    return p.join(databasesPath, databaseName);
  }

  /// Returns the active [Database] instance, initializing it if not yet opened.
  /// Guarded against concurrent async opening race conditions.
  Future<Database> get database async {
    if (_database != null && _database!.isOpen) {
      return _database!;
    }
    _database = await (_openingFuture ??= _initDatabase());
    _openingFuture = null;
    return _database!;
  }

  /// Internal initializer for opening the SQLite database.
  Future<Database> _initDatabase() async {
    final path = await getDatabasePath();
    final factory = _customFactory ?? databaseFactory;
    return await factory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: databaseVersion,
        onCreate: _onCreate,
        onUpgrade: _onUpgrade,
        onConfigure: _onConfigure,
      ),
    );
  }

  /// SQLite configuration hook: enables foreign key constraint enforcement.
  Future<void> _onConfigure(Database db) async {
    await db.execute('PRAGMA foreign_keys = ON');
  }

  /// SQLite creation hook: creates tables, indexes, and dynamic views.
  Future<void> _onCreate(Database db, int version) async {
    // 1. Transactions Table
    await db.execute('''
      CREATE TABLE $tableTransactions (
        $columnId INTEGER PRIMARY KEY AUTOINCREMENT,
        $columnTxnId TEXT NOT NULL UNIQUE,
        $columnType TEXT NOT NULL CHECK($columnType IN ('ADD', 'PAY')),
        $columnAmount REAL NOT NULL CHECK($columnAmount > 0),
        $columnTimestamp INTEGER NOT NULL,
        $columnMemoPhotoPath TEXT,
        $columnNotes TEXT,
        $columnCategory TEXT
      );
    ''');

    // 2. Performance Indexes
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_transactions_timestamp 
      ON $tableTransactions($columnTimestamp DESC);
    ''');

    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_transactions_txnid 
      ON $tableTransactions($columnTxnId);
    ''');

    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_transactions_type 
      ON $tableTransactions($columnType);
    ''');

    // 3. Dynamic Balance & Summary View
    await db.execute('''
      CREATE VIEW IF NOT EXISTS $viewLedgerSummary AS
      SELECT
        COALESCE(SUM(CASE WHEN $columnType = 'ADD' THEN $columnAmount WHEN $columnType = 'PAY' THEN -$columnAmount ELSE 0 END), 0.0) AS balance,
        COALESCE(SUM(CASE WHEN $columnType = 'ADD' THEN $columnAmount ELSE 0 END), 0.0) AS total_in,
        COALESCE(SUM(CASE WHEN $columnType = 'PAY' THEN $columnAmount ELSE 0 END), 0.0) AS total_out,
        COUNT(*) AS total_count
      FROM $tableTransactions;
    ''');
  }

  /// SQLite upgrade hook: schema migration routing for future versions.
  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    // Future database schema migrations will be handled here sequentially
  }

  // ===========================================================================
  // CRUD & Ledger Operations
  // ===========================================================================

  /// Inserts a new [TransactionItem] into the ledger.
  ///
  /// Returns the generated primary key `id`.
  /// Throws [DatabaseException] if constraints (e.g. unique txnid, positive amount) are violated.
  Future<int> insertTransaction(TransactionItem txn) async {
    final db = await database;
    final map = txn.toMap();
    if (map[columnId] == null) {
      map.remove(columnId);
    }
    return await db.insert(
      tableTransactions,
      map,
      conflictAlgorithm: ConflictAlgorithm.abort,
    );
  }

  /// Retrieves all transactions ordered by timestamp DESC, then id DESC.
  ///
  /// Supports optional [limit] and [offset] parameters for paginated feeds.
  Future<List<TransactionItem>> getAllTransactions({
    int? limit,
    int? offset,
  }) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      tableTransactions,
      orderBy: '$columnTimestamp DESC, $columnId DESC',
      limit: limit,
      offset: offset,
    );
    return maps.map((map) => TransactionItem.fromMap(map)).toList();
  }

  /// Retrieves a single transaction by its unique [txnid].
  /// Returns `null` if not found.
  Future<TransactionItem?> getTransactionByTxnId(String txnid) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      tableTransactions,
      where: '$columnTxnId = ?',
      whereArgs: [txnid],
      limit: 1,
    );
    if (maps.isNotEmpty) {
      return TransactionItem.fromMap(maps.first);
    }
    return null;
  }

  /// Retrieves a single transaction by its primary key [id].
  /// Returns `null` if not found.
  Future<TransactionItem?> getTransactionById(int id) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      tableTransactions,
      where: '$columnId = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (maps.isNotEmpty) {
      return TransactionItem.fromMap(maps.first);
    }
    return null;
  }

  /// Retrieves transactions filtered by flow type ([TransactionType.add] or [TransactionType.pay]).
  Future<List<TransactionItem>> getTransactionsByType(
    TransactionType type, {
    int? limit,
    int? offset,
  }) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      tableTransactions,
      where: '$columnType = ?',
      whereArgs: [type.toDbValue()],
      orderBy: '$columnTimestamp DESC, $columnId DESC',
      limit: limit,
      offset: offset,
    );
    return maps.map((map) => TransactionItem.fromMap(map)).toList();
  }

  /// Retrieves list of physical banknotes currently available in the wallet.
  /// A banknote is considered available if it was deposited via an 'ADD' transaction
  /// and its banknote serial number has not yet been spent in a 'PAY' transaction.
  Future<List<TransactionItem>> getAvailableBanknotes() async {
    final allTxns = await getAllTransactions();

    // Collect all spent note references from PAY transactions
    final Set<String> spentNoteKeys = {};
    for (final txn in allTxns) {
      if (txn.type == TransactionType.pay) {
        if (txn.notes != null && txn.notes!.isNotEmpty) {
          final noteMatch = RegExp(r'Deducted note:\s*([^•\n]+)').firstMatch(txn.notes!);
          if (noteMatch != null) {
            final rawList = noteMatch.group(1)!;
            for (final item in rawList.split(',')) {
              final clean = item.trim().replaceAll(' ', '');
              if (clean.isNotEmpty) spentNoteKeys.add(clean);
            }
          }
          final parts = txn.notes!.split(RegExp(r'[,•\n]'));
          for (final p in parts) {
            var clean = p.trim().replaceAll(' ', '');
            final colonIdx = clean.indexOf(':');
            if (colonIdx != -1) {
              clean = clean.substring(colonIdx + 1);
            }
            if (clean.isNotEmpty) spentNoteKeys.add(clean);
          }
        }
        final cleanTxnId = txn.txnid.replaceAll(' ', '');
        if (cleanTxnId.startsWith('PAY-')) {
          final notePart = cleanTxnId.substring(4);
          spentNoteKeys.add(notePart);
          final dashIdx = notePart.lastIndexOf('-');
          if (dashIdx != -1) {
            spentNoteKeys.add(notePart.substring(0, dashIdx));
          }
        } else {
          spentNoteKeys.add(cleanTxnId);
        }
      }
    }

    // Available banknotes: ADD transactions whose txnid hasn't been spent
    final List<TransactionItem> available = [];
    for (final txn in allTxns) {
      if (txn.type == TransactionType.add) {
        final cleanNoteId = txn.txnid.replaceAll(' ', '');
        if (!spentNoteKeys.contains(cleanNoteId)) {
          available.add(txn);
        }
      }
    }
    return available;
  }

  /// Calculates and returns the current net cash balance directly from the
  /// dynamic `ledger_summary` SQL view.
  ///
  /// Balance = SUM(ADD amounts) - SUM(PAY amounts).
  /// Returns `0.0` when the ledger has no records.
  Future<double> getBalance() async {
    final db = await database;
    final List<Map<String, dynamic>> result = await db.rawQuery(
      'SELECT balance FROM $viewLedgerSummary',
    );
    if (result.isNotEmpty && result.first['balance'] != null) {
      return (result.first['balance'] as num).toDouble();
    }
    return 0.0;
  }

  /// Retrieves the aggregated financial summary from the dynamic `ledger_summary` SQL view.
  ///
  /// Includes net balance, total cash in, total cash out, and total record count.
  Future<LedgerSummary> getSummary() async {
    final db = await database;
    final List<Map<String, dynamic>> result = await db.rawQuery(
      'SELECT balance, total_in, total_out, total_count FROM $viewLedgerSummary',
    );
    if (result.isNotEmpty) {
      return LedgerSummary.fromMap(result.first);
    }
    return LedgerSummary.zero;
  }

  /// Returns the total count of recorded transactions.
  Future<int> getTransactionCount() async {
    final db = await database;
    final count = Sqflite.firstIntValue(
      await db.rawQuery('SELECT COUNT(*) FROM $tableTransactions'),
    );
    return count ?? 0;
  }

  /// Deletes a transaction by its primary key [id].
  ///
  /// Returns the count of deleted rows (1 if found and deleted, 0 otherwise).
  Future<int> deleteTransaction(int id) async {
    final db = await database;
    return await db.delete(
      tableTransactions,
      where: '$columnId = ?',
      whereArgs: [id],
    );
  }

  /// Deletes a transaction by its unique [txnid].
  ///
  /// Returns the count of deleted rows.
  Future<int> deleteTransactionByTxnId(String txnid) async {
    final db = await database;
    return await db.delete(
      tableTransactions,
      where: '$columnTxnId = ?',
      whereArgs: [txnid],
    );
  }

  /// Completely clears all transactions from the database and resets
  /// the SQLite autoincrement primary key counter.
  Future<void> clearAll() async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete(tableTransactions);
      try {
        await txn.delete(
          'sqlite_sequence',
          where: 'name = ?',
          whereArgs: [tableTransactions],
        );
      } catch (_) {
        // Table sqlite_sequence might not exist if autoincrement hasn't been triggered yet
      }
    });
  }

  /// Atomically restores a list of transactions into the database.
  ///
  /// - When [clearExisting] is `true` (default), purges all existing transactions first.
  /// - Executed within a single SQLite transaction: rolls back all operations if any error occurs.
  Future<void> restoreTransactions(
    List<TransactionItem> txns, {
    bool clearExisting = true,
  }) async {
    final db = await database;
    await db.transaction((txn) async {
      if (clearExisting) {
        await txn.delete(tableTransactions);
        try {
          await txn.delete(
            'sqlite_sequence',
            where: 'name = ?',
            whereArgs: [tableTransactions],
          );
        } catch (_) {}
      }

      final batch = txn.batch();
      for (final item in txns) {
        final map = item.toMap();
        if (map[columnId] == null) {
          map.remove(columnId);
        }
        batch.insert(
          tableTransactions,
          map,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
    });
  }

  /// Closes the active database connection if currently open.
  Future<void> close() async {
    if (_database != null && _database!.isOpen) {
      await _database!.close();
      _database = null;
    }
    _openingFuture = null;
  }

  /// Permanently deletes the database file from disk.
  Future<void> deleteDb() async {
    await close();
    final path = await getDatabasePath();
    final factory = _customFactory ?? databaseFactory;
    if (path != inMemoryDatabasePath) {
      await factory.deleteDatabase(path);
    }
  }

  /// Whether the database is currently open.
  bool get isOpen => _database != null && _database!.isOpen;
}
