import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:pocket_change/controllers/ledger_controller.dart';
import 'package:pocket_change/models/backup_payload.dart';
import 'package:pocket_change/models/ledger_summary.dart';
import 'package:pocket_change/models/transaction_item.dart';
import 'package:pocket_change/services/backup_service.dart';
import 'package:pocket_change/services/database_helper.dart';
import 'package:pocket_change/services/money_scanner_service.dart';
import 'package:pocket_change/services/receipt_service.dart';
import 'package:pocket_change/ui/screens/add_money_sheet.dart';
import 'package:pocket_change/ui/screens/backup_restore_screen.dart';
import 'package:pocket_change/ui/screens/dashboard_screen.dart';
import 'package:pocket_change/ui/screens/pay_sheet.dart';
import 'package:pocket_change/ui/theme/currency_formatter.dart';
import 'package:pocket_change/ui/theme/mfs_colors.dart';
import 'package:pocket_change/ui/widgets/mfs_balance_card.dart';
import 'package:pocket_change/ui/widgets/receipt_lightbox.dart';
import 'package:pocket_change/ui/widgets/transaction_tile.dart';
import 'test_helper.dart';

void main() {
  late Directory globalTestDir;
  late ReceiptService globalReceiptService;

  setUpAll(() async {
    initTestDatabaseFactory();
    globalTestDir = await createTestTempDir(prefix: 'mfs_ui_all_');
    globalReceiptService = createTestReceiptService(globalTestDir);
    ReceiptService.resetInstance(globalReceiptService);
  });

  tearDownAll(() async {
    ReceiptService.resetInstance(null);
    if (await globalTestDir.exists()) {
      await globalTestDir.delete(recursive: true);
    }
  });

  group('Dimension 1: MFS Colors & BDT Currency Formatter', () {
    test('MfsColors tokens and ThemeData configurations', () {
      expect(MfsColors.primary, equals(const Color(0xFFDC143C)));
      expect(MfsColors.accent, equals(const Color(0xFFFF1E4B)));
      expect(MfsColors.cashIn, equals(const Color(0xFF00E676)));
      expect(MfsColors.cashOut, equals(const Color(0xFFDC143C)));
      expect(MfsColors.background, equals(const Color(0xFF0D0D0D)));
      expect(MfsColors.surface, equals(const Color(0xFF171717)));

      final lightTheme = MfsColors.buildLightTheme();
      expect(lightTheme.useMaterial3, isTrue);
      expect(lightTheme.colorScheme.primary, equals(MfsColors.primary));

      final darkTheme = MfsColors.buildDarkTheme();
      expect(darkTheme.useMaterial3, isTrue);
      expect(darkTheme.brightness, equals(Brightness.dark));
    });

    test('CurrencyFormatter formats BDT with Lakh-Crore grouping', () {
      expect(CurrencyFormatter.formatBdt(0), equals('৳ 0.00'));
      expect(CurrencyFormatter.formatBdt(1500.5), equals('৳ 1,500.50'));
      expect(CurrencyFormatter.formatBdt(125000), equals('৳ 1,25,000.00'));
      expect(CurrencyFormatter.formatBdt(10000000), equals('৳ 1,00,00,000.00'));
      expect(CurrencyFormatter.formatBdt(-250.75), equals('-৳ 250.75'));
      expect(
        CurrencyFormatter.formatBdt(125000, useIndianGrouping: false),
        equals('৳ 125,000.00'),
      );
    });

    test('CurrencyFormatter Bengali digits conversion and parsing', () {
      final bengaliStr = CurrencyFormatter.formatBdt(1500.5, useBengaliDigits: true);
      expect(bengaliStr, equals('৳ ১,৫০০.৫০'));

      expect(CurrencyFormatter.toBengaliDigits('0123456789'), equals('০১২৩৪৫৬৭৮৯'));
      expect(CurrencyFormatter.toAsciiDigits('০১২৩৪৫৬৭৮৯'), equals('0123456789'));

      expect(CurrencyFormatter.tryParse('৳ 1,500.50'), equals(1500.50));
      expect(CurrencyFormatter.tryParse('৳ ১,৫০০.৫০'), equals(1500.50));
      expect(CurrencyFormatter.tryParse('- ৳ 250.00'), equals(-250.0));
      expect(CurrencyFormatter.tryParse(''), isNull);
      expect(CurrencyFormatter.tryParse(null), isNull);
      expect(CurrencyFormatter.tryParse('abc'), isNull);
    });

    test('CurrencyFormatter signed BDT formatting for Add and Pay', () {
      expect(
        CurrencyFormatter.formatSignedBdt(1500, type: TransactionType.add),
        equals('+ ৳ 1,500.00'),
      );
      expect(
        CurrencyFormatter.formatSignedBdt(350, type: TransactionType.pay),
        equals('- ৳ 350.00'),
      );
    });
  });

  group('Dimension 2: "Tap for Balance" MFS Privacy Card & Timer', () {
    testWidgets('Initial card conceals balance with Tap for Balance pill', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: MfsBalanceCard(
              balance: 5420.50,
              totalIn: 10000.0,
              totalOut: 4579.50,
            ),
          ),
        ),
      );

      // Verify pill in hidden state
      expect(find.byKey(const ValueKey('pill_hidden')), findsOneWidget);
      expect(find.text('Tap for Balance'), findsOneWidget);
      expect(find.text('৳ 5,420.50'), findsNothing);

      // Verify summary chips
      expect(find.text('Total In'), findsOneWidget);
      expect(find.text('Total Out'), findsOneWidget);
      expect(find.text('+ ৳ 10,000.00'), findsOneWidget);
      expect(find.text('- ৳ 4,579.50'), findsOneWidget);
    });

    testWidgets('Tapping pill reveals balance with animated transition', (tester) async {
      bool revealedCallbackFired = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MfsBalanceCard(
              balance: 5420.50,
              enableHaptics: false,
              onBalanceRevealed: () => revealedCallbackFired = true,
            ),
          ),
        ),
      );

      // Tap privacy pill
      await tester.tap(find.byKey(const ValueKey('mfs_tap_for_balance_pill')));
      await tester.pump(); // Start animation
      await tester.pump(const Duration(milliseconds: 300)); // Complete animation

      expect(revealedCallbackFired, isTrue);
      expect(find.byKey(const ValueKey('pill_revealed')), findsOneWidget);
      expect(find.text('৳ 5,420.50'), findsOneWidget);
      expect(find.byKey(const ValueKey('pill_hidden')), findsNothing);
    });

    testWidgets('Revealed balance auto-hides after exactly 4.0 seconds', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: MfsBalanceCard(
              balance: 2500.0,
              autoHideDuration: Duration(seconds: 4),
              enableHaptics: false,
            ),
          ),
        ),
      );

      // Reveal balance
      await tester.tap(find.byKey(const ValueKey('mfs_tap_for_balance_pill')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('৳ 2,500.00'), findsOneWidget);

      // Advance 2 seconds -> still visible
      await tester.pump(const Duration(seconds: 2));
      expect(find.text('৳ 2,500.00'), findsOneWidget);

      // Advance remaining 2 seconds (total 4.0s) + 300ms animation
      await tester.pump(const Duration(seconds: 2));
      await tester.pump(const Duration(milliseconds: 300));

      // Balance automatically conceals back
      expect(find.byKey(const ValueKey('pill_hidden')), findsOneWidget);
      expect(find.text('Tap for Balance'), findsOneWidget);
      expect(find.text('৳ 2,500.00'), findsNothing);
    });

    testWidgets('Re-tapping revealed pill resets 4-second timer', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: MfsBalanceCard(
              balance: 1000.0,
              autoHideDuration: Duration(seconds: 4),
              enableHaptics: false,
            ),
          ),
        ),
      );

      // 1. Initial reveal
      await tester.tap(find.byKey(const ValueKey('mfs_tap_for_balance_pill')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('৳ 1,000.00'), findsOneWidget);

      // 2. Advance 2.5 seconds (1.5s remaining on timer)
      await tester.pump(const Duration(milliseconds: 2500));
      expect(find.text('৳ 1,000.00'), findsOneWidget);

      // 3. Re-tap pill while revealed -> resets timer for another 4.0s
      await tester.tap(find.byKey(const ValueKey('mfs_tap_for_balance_pill')));
      await tester.pump(const Duration(milliseconds: 50));

      // 4. Advance 2.5 seconds (total 5s since first tap, but only 2.5s since re-tap)
      await tester.pump(const Duration(milliseconds: 2500));
      expect(find.text('৳ 1,000.00'), findsOneWidget); // Still visible!

      // 5. Advance another 2 seconds + animation -> now auto-hides
      await tester.pump(const Duration(seconds: 2));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const ValueKey('pill_hidden')), findsOneWidget);
    });
  });

  group('Dimension 3: Add Money Flow & Input Validation', () {
    testWidgets('AddMoneySheet quick chips and projected balance calculation', (tester) async {
      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      TransactionItem? addedTxn;
      late Directory tempDir;
      late DatabaseHelper dbHelper;

      await tester.runAsync(() async {
        tempDir = Directory.systemTemp.createTempSync('add_money_test_');
        dbHelper = DatabaseHelper(
          databaseFactory: databaseFactoryFfi,
          databasePath: p.join(tempDir.path, 'test_ledger.db'),
        );
        await dbHelper.database; // Ensure initialized
      });
      addTearDown(() async {
        await dbHelper.close();
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      });

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () {
                  AddMoneySheet.show(
                    context,
                    currentBalance: 500.0,
                    databaseHelper: dbHelper,
                    onAddCompleted: (txn) async => addedTxn = txn,
                  );
                },
                child: const Text('Open Sheet'),
              ),
            ),
          ),
        ),
      );

      // Open bottom sheet
      await tester.tap(find.text('Open Sheet'));
      await tester.pumpAndSettle();

      // Check current and initial projected balance
      expect(find.text('Current Balance'), findsOneWidget);
      expect(find.text('৳ 500.00'), findsWidgets);

      // Tap +৳1000 quick chip
      await tester.tap(find.byKey(const Key('quick_chip_1000')));
      await tester.pump();

      // Input should reflect 1000 and projected balance should be ৳ 1,500.00
      expect(find.text('1000'), findsOneWidget);
      expect(find.text('৳ 1,500.00'), findsOneWidget);

      // Tap +৳500 quick chip -> accumulates to 1500
      await tester.tap(find.byKey(const Key('quick_chip_500')));
      await tester.pump();
      expect(find.text('1500'), findsOneWidget);
      expect(find.text('৳ 2,000.00'), findsOneWidget);

      // Verify banknote scanner button and note number field
      expect(find.byKey(const Key('scan_physical_money_button')), findsOneWidget);
      expect(find.byKey(const Key('add_money_note_number_field')), findsOneWidget);

      // Enter physical banknote serial number to serve directly as txnid
      await tester.enterText(
        find.byKey(const Key('add_money_note_number_field')),
        '8K4920194',
      );
      await tester.pump();

      // Enter note
      await tester.enterText(find.byKey(const Key('add_money_notes_field')), 'Monthly Income');
      await tester.pump();

      // Tap confirm button
      await tester.ensureVisible(find.byKey(const Key('confirm_add_money_button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirm_add_money_button')));
      await tester.pump();
      await tester.runAsync(() async {
        for (int i = 0; i < 50; i++) {
          if (addedTxn != null) break;
          await Future.delayed(const Duration(milliseconds: 20));
        }
      });
      await tester.pumpAndSettle();

      // Verify transaction recorded with banknote number as txnid
      expect(addedTxn, isNotNull);
      expect(addedTxn!.amount, equals(1500.0));
      expect(addedTxn!.type, equals(TransactionType.add));
      expect(addedTxn!.txnid, equals('8K4920194'));
      expect(addedTxn!.notes, equals('Monthly Income'));
    });

    testWidgets('AddMoneySheet validates zero and negative amounts', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: AddMoneySheet(currentBalance: 100.0),
          ),
        ),
      );

      // Initially amount is 0, confirm button should be disabled
      final confirmBtn = tester.widget<ElevatedButton>(
        find.byKey(const Key('confirm_add_money_button')),
      );
      expect(confirmBtn.onPressed, isNull);

      // Enter 0 -> should show error
      await tester.enterText(find.byKey(const Key('add_money_amount_field')), '0');
      await tester.pump();
      expect(find.text('Please enter a valid amount greater than 0'), findsOneWidget);
    });
  });

  group('Dimension 4: Pay Flow with Camera Memo & Balance Warning', () {
    testWidgets('PaySheet displays warning banner when payment exceeds balance', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: PaySheet(currentBalance: 500.0),
          ),
        ),
      );

      // Enter amount exceeding balance (800 > 500)
      await tester.enterText(find.byKey(const Key('pay_amount_field')), '800');
      await tester.pump();

      // Warning banner should appear
      expect(find.byKey(const Key('balance_warning_banner')), findsOneWidget);
      expect(find.text('Insufficient Balance Warning'), findsOneWidget);
      expect(find.textContaining('exceeds current balance of ৳500.00 by ৳300.00'), findsOneWidget);

      // Submit button should be disabled by default
      var confirmBtn = tester.widget<ElevatedButton>(find.byKey(const Key('confirm_payment_button')));
      expect(confirmBtn.onPressed, isNull);

      // Toggle allow negative balance override
      await tester.tap(find.byKey(const Key('negative_balance_override_toggle')));
      await tester.pump();

      // Submit button should now be enabled
      confirmBtn = tester.widget<ElevatedButton>(find.byKey(const Key('confirm_payment_button')));
      expect(confirmBtn.onPressed, isNotNull);
    });

    testWidgets('PaySheet camera capture, live thumbnail preview, and submission', (tester) async {
      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      TransactionItem? paidTxn;
      late Directory tempDir;
      late ReceiptService receiptService;
      late DatabaseHelper dbHelper;

      await tester.runAsync(() async {
        tempDir = Directory.systemTemp.createTempSync('pay_test_');
        receiptService = createTestReceiptService(tempDir);
        dbHelper = DatabaseHelper(
          databaseFactory: databaseFactoryFfi,
          databasePath: p.join(tempDir.path, 'test_ledger.db'),
        );
        await dbHelper.database;
      });
      addTearDown(() async {
        await dbHelper.close();
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      });

      // Mock camera capture provider returning minimal JPEG
      Future<XFile?> mockCameraProvider() async => XFile.fromData(
            kMinimal1x1JpegBytes,
            name: 'receipt_camera_mock.jpg',
          );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () {
                  PaySheet.show(
                    context,
                    currentBalance: 1000.0,
                    databaseHelper: dbHelper,
                    receiptService: receiptService,
                    photoCaptureProvider: mockCameraProvider,
                    onPaymentSubmitted: (txn) async => paidTxn = txn,
                  );
                },
                child: const Text('Open Pay'),
              ),
            ),
          ),
        ),
      );

      // Open sheet
      await tester.tap(find.text('Open Pay'));
      await tester.pumpAndSettle();

      // Enter amount 350
      await tester.enterText(find.byKey(const Key('pay_amount_field')), '350');
      await tester.enterText(find.byKey(const Key('pay_recipient_field')), 'Shwapno Supermarket');
      await tester.pump();

      // Initially no thumbnail, take photo button is visible
      expect(find.byKey(const Key('take_receipt_photo_button')), findsOneWidget);
      expect(find.byKey(const Key('receipt_thumbnail_preview_card')), findsNothing);

      // Tap take photo button
      await tester.ensureVisible(find.byKey(const Key('take_receipt_photo_button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('take_receipt_photo_button')));
      await tester.pump();
      await tester.runAsync(() async {
        await Future.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();

      // Thumbnail preview card should now be displayed
      expect(find.byKey(const Key('receipt_thumbnail_preview_card')), findsOneWidget);
      expect(find.text('Receipt Memo Attached'), findsOneWidget);
      expect(find.byKey(const Key('retake_photo_button')), findsOneWidget);
      expect(find.byKey(const Key('remove_photo_button')), findsOneWidget);

      // Submit payment
      await tester.ensureVisible(find.byKey(const Key('confirm_payment_button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirm_payment_button')));
      for (int step = 0; step < 20; step++) {
        await tester.pump(const Duration(milliseconds: 50));
        await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 50)));
        if (paidTxn != null) {
          await tester.pump(const Duration(milliseconds: 50));
          await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 50)));
          break;
        }
      }
      await tester.pumpAndSettle();

      // Verify transaction recorded with memo photo
      expect(paidTxn, isNotNull);
      expect(paidTxn!.amount, equals(350.0));
      expect(paidTxn!.type, equals(TransactionType.pay));
      expect(paidTxn!.hasMemoPhoto, isTrue);
      expect(paidTxn!.memoPhotoPath, startsWith('receipts/rec_'));
      expect(paidTxn!.notes, contains('Recipient: Shwapno Supermarket'));

      // Verify file written to disk using real I/O inside runAsync
      File? savedFile;
      await tester.runAsync(() async {
        savedFile = await receiptService.getReceiptFile(paidTxn!.memoPhotoPath);
      });
      expect(savedFile, isNotNull);
      expect(savedFile!.existsSync(), isTrue);
    });

    testWidgets('PaySheet allows selecting available banknotes to deduct from wallet', (tester) async {
      late Directory tempDir;
      late DatabaseHelper dbHelper;

      final sampleNotes = [
        sampleAddTransaction(
          txnid: 'ছদ ৬২৮২০৬৬',
          amount: 1000.0,
        ),
        sampleAddTransaction(
          txnid: 'কখ ১২৩৪৫৬৭',
          amount: 500.0,
        ),
      ];

      await tester.runAsync(() async {
        tempDir = Directory.systemTemp.createTempSync('pay_note_test_');
        dbHelper = DatabaseHelper(
          databaseFactory: databaseFactoryFfi,
          databasePath: p.join(tempDir.path, 'test_ledger.db'),
        );
        await dbHelper.database;
        // Insert 2 available banknotes
        await dbHelper.insertTransaction(sampleNotes[0]);
        await dbHelper.insertTransaction(sampleNotes[1]);
      });
      addTearDown(() async {
        await tester.runAsync(() async {
          await dbHelper.close();
        });
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      });

      TransactionItem? paidTxn;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () {
                  PaySheet.show(
                    context,
                    currentBalance: 1500.0,
                    databaseHelper: dbHelper,
                    availableNotes: sampleNotes,
                    onPaymentSubmitted: (txn) async => paidTxn = txn,
                  );
                },
                child: const Text('Open Pay'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open Pay'));
      await tester.pumpAndSettle();

      // Verify the available banknote chips are visible
      expect(find.byKey(const Key('note_chip_ছদ ৬২৮২০৬৬')), findsOneWidget);
      expect(find.byKey(const Key('note_chip_কখ ১২৩৪৫৬৭')), findsOneWidget);

      // Tap note 'ছদ ৬২৮২০৬৬' (৳ 1,000)
      await tester.tap(find.byKey(const Key('note_chip_ছদ ৬২৮২০৬৬')));
      await tester.pumpAndSettle();

      // Amount field should now automatically equal 1000
      final amountField = tester.widget<TextFormField>(find.byKey(const Key('pay_amount_field')));
      expect(amountField.controller?.text, equals('1000'));

      // Confirm payment
      await tester.ensureVisible(find.byKey(const Key('confirm_payment_button')));
      await tester.tap(find.byKey(const Key('confirm_payment_button')));
      for (int step = 0; step < 20; step++) {
        await tester.pump(const Duration(milliseconds: 50));
        await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 50)));
        if (paidTxn != null) {
          await tester.pump(const Duration(milliseconds: 50));
          break;
        }
      }

      expect(paidTxn, isNotNull);
      expect(paidTxn!.amount, equals(1000.0));
      expect(paidTxn!.type, equals(TransactionType.pay));

      // After payment, note 'ছদ ৬২৮২০৬৬' should now be deducted from available banknotes!
      late List<TransactionItem> remaining;
      await tester.runAsync(() async {
        remaining = await dbHelper.getAvailableBanknotes();
      });
      expect(remaining.length, equals(1));
      expect(remaining.first.txnid, equals('কখ ১২৩৪৫৬৭'));
    });
  });

  group('Dimension 5: Date-Grouped Transaction Feed, Lightbox & Tile', () {
    test('DateGroupedTransactions correctly groups Today, Yesterday, and dates', () {
      final now = DateTime(2026, 11, 7, 15, 30);
      final todayTxn = TransactionItem(
        txnid: 'TXN1',
        type: TransactionType.add,
        amount: 1000.0,
        timestamp: DateTime(2026, 11, 7, 10, 0),
      );
      final yesterdayTxn = TransactionItem(
        txnid: 'TXN2',
        type: TransactionType.pay,
        amount: 250.0,
        timestamp: DateTime(2026, 11, 6, 14, 0),
      );
      final olderTxn = TransactionItem(
        txnid: 'TXN3',
        type: TransactionType.pay,
        amount: 500.0,
        timestamp: DateTime(2026, 11, 1, 9, 0),
      );

      final groups = DateGroupedTransactions.fromList(
        [todayTxn, yesterdayTxn, olderTxn],
        now: now,
      );

      expect(groups.length, equals(3));
      expect(groups[0].label, equals('Today'));
      expect(groups[0].transactions.length, equals(1));
      expect(groups[0].netCashFlow, equals(1000.0));

      expect(groups[1].label, equals('Yesterday'));
      expect(groups[1].transactions.length, equals(1));
      expect(groups[1].netCashFlow, equals(-250.0));

      expect(groups[2].label, equals('01 Nov 2026'));
      expect(groups[2].transactions.length, equals(1));
      expect(groups[2].netCashFlow, equals(-500.0));
    });

    testWidgets('TransactionTile renders type icon, copyable TrxID chip, and thumb', (tester) async {
      final txn = TransactionItem(
        txnid: 'TXNTEST12345678',
        type: TransactionType.pay,
        amount: 450.0,
        timestamp: DateTime(2026, 11, 7, 16, 45),
        notes: 'Rickshaw & Bazaar',
        memoPhotoPath: 'receipts/rec_sample.jpg',
      );

      bool receiptTapped = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TransactionTile(
              transaction: txn,
              onTapReceipt: () => receiptTapped = true,
            ),
          ),
        ),
      );

      // Verify content
      expect(find.text('Rickshaw & Bazaar'), findsOneWidget);
      expect(find.text('TXNTEST12345678'), findsOneWidget);
      expect(find.text('- ৳ 450.00'), findsOneWidget);
      expect(find.byKey(const ValueKey('copy_txnid_TXNTEST12345678')), findsOneWidget);
      expect(find.byKey(const ValueKey('receipt_thumb_TXNTEST12345678')), findsOneWidget);

      // Tap TrxID copy chip -> triggers SnackBar
      await tester.tap(find.byKey(const ValueKey('copy_txnid_TXNTEST12345678')));
      await tester.pump();
      expect(find.text('Copied TrxID: TXNTEST12345678'), findsOneWidget);

      // Tap receipt thumbnail
      await tester.tap(find.byKey(const ValueKey('receipt_thumb_TXNTEST12345678')));
      expect(receiptTapped, isTrue);
    });

    testWidgets('ReceiptLightbox zoom, copy txnid, and corrupted photo fallback', (tester) async {
      final txn = TransactionItem(
        txnid: 'TXNLIGHTBOX001',
        type: TransactionType.pay,
        amount: 850.0,
        timestamp: DateTime(2026, 11, 7, 12, 0),
        notes: 'Corrupted photo test',
        memoPhotoPath: 'receipts/non_existent.jpg',
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReceiptLightbox(
              transaction: txn,
              receiptService: globalReceiptService,
            ),
          ),
        ),
      );
      for (int step = 0; step < 5; step++) {
        await tester.pump(const Duration(milliseconds: 50));
        await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 50)));
      }
      await tester.pump();

      // Corrupted fallback displayed because file doesn't exist
      expect(find.text('Receipt Image Unavailable'), findsOneWidget);
      expect(find.byIcon(Icons.broken_image_rounded), findsOneWidget);

      // Monospace TrxID chip
      expect(find.text('TXNLIGHTBOX001'), findsOneWidget);

      // Tap copy chip
      await tester.tap(find.byKey(const Key('lightbox_copy_txnid_chip')));
      await tester.pump();
      expect(find.text('Transaction ID copied: TXNLIGHTBOX001'), findsOneWidget);

      // Lightbox InteractiveViewer rendered
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReceiptLightbox(
              transaction: txn,
              imageBytes: kMinimal1x1JpegBytes,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('receipt_interactive_viewer')), findsOneWidget);
      expect(find.byKey(const Key('lightbox_reset_zoom_button')), findsOneWidget);
      expect(find.byKey(const Key('lightbox_share_button')), findsOneWidget);
    });
  });

  group('Dimension 6: Backup & Restore Screen Operations', () {
    testWidgets('BackupRestoreScreen displays live stats and triggers export', (tester) async {
      late Directory tempDir;
      late DatabaseHelper dbHelper;
      late LedgerController controller;
      File? sharedFile;

      await tester.runAsync(() async {
        tempDir = Directory.systemTemp.createTempSync('backup_screen_test_');
        dbHelper = DatabaseHelper(
          databaseFactory: databaseFactoryFfi,
          databasePath: p.join(tempDir.path, 'test_ledger.db'),
        );
        final receiptService = createTestReceiptService(tempDir);
        final backupService = BackupService(
          dbHelper: dbHelper,
          receiptService: receiptService,
          tempDirProvider: () async => tempDir,
          docsDirProvider: () async => tempDir,
          shareAction: (files, {subject, text}) async {
            sharedFile = File(files.first.path);
            return const ShareResult('ok', ShareResultStatus.success);
          },
        );
        controller = LedgerController(
          dbHelper: dbHelper,
          receiptService: receiptService,
          backupService: backupService,
        );
        // Pre-populate with 1 transaction
        await controller.addMoney(amount: 1500.0, category: 'Deposit');
      });
      addTearDown(() async {
        await dbHelper.close();
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      });

      await tester.pumpWidget(
        MaterialApp(
          home: BackupRestoreScreen(controller: controller),
        ),
      );
      await tester.pump();

      // Verify statistics card
      expect(find.text('Ledger Statistics'), findsOneWidget);
      expect(find.text('৳ 1,500.00'), findsWidgets);
      expect(find.text('1 records'), findsOneWidget);

      // Tap Export button
      await tester.ensureVisible(find.byKey(const ValueKey('export_backup_button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('export_backup_button')));
      for (int step = 0; step < 20; step++) {
        await tester.pump(const Duration(milliseconds: 50));
        await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 50)));
        if (sharedFile != null) break;
      }
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // Verify file exported and shared
      expect(sharedFile, isNotNull);
      expect(sharedFile!.existsSync(), isTrue);
      expect(find.textContaining('Backup exported successfully!'), findsOneWidget);
    });

    testWidgets('BackupRestoreScreen validates and restores via preview dialog', (tester) async {
      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      late DatabaseHelper dbHelper;
      late LedgerController controller;

      // Prepare a valid backup JSON payload
      final backupSummary = LedgerSummary(balance: 500.0, totalIn: 500.0, totalOut: 0.0, totalCount: 1);
      final validPayload = BackupPayload(
        version: 1,
        appVersion: '1.0.0+1',
        appIdentifier: 'com.pocketchange.mfs',
        exportedAt: DateTime.now().toUtc(),
        deviceOs: 'linux',
        summary: backupSummary,
        transactions: [
          TransactionItem(
            txnid: 'TXNRESTORE12345',
            type: TransactionType.add,
            amount: 500.0,
            timestamp: DateTime.now(),
            notes: 'Restored Item',
            category: 'Salary',
          ),
        ],
      );
      final jsonString = validPayload.toJsonString();

      late Directory tempDir;
      await tester.runAsync(() async {
        tempDir = Directory.systemTemp.createTempSync('restore_screen_test_');
        dbHelper = DatabaseHelper(
          databaseFactory: databaseFactoryFfi,
          databasePath: p.join(tempDir.path, 'test_ledger.db'),
        );
        final receiptService = createTestReceiptService(tempDir);
        final backupService = BackupService(
          dbHelper: dbHelper,
          receiptService: receiptService,
          tempDirProvider: () async => tempDir,
          docsDirProvider: () async => tempDir,
        );
        controller = LedgerController(
          dbHelper: dbHelper,
          receiptService: receiptService,
          backupService: backupService,
        );
        await controller.loadLedger();
      });
      addTearDown(() async {
        await dbHelper.close();
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      });

      await tester.pumpWidget(
        MaterialApp(
          home: BackupRestoreScreen(
            controller: controller,
            filePickerOverride: () async => jsonString,
          ),
        ),
      );
      await tester.pump();

      // Tap import button
      await tester.ensureVisible(find.byKey(const ValueKey('select_backup_file_button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('select_backup_file_button')));
      await tester.pumpAndSettle();

      // Pre-Validation Preview Dialog should open
      expect(find.text('Restore Preview'), findsOneWidget);
      expect(find.text('৳ 500.00'), findsWidgets);
      expect(find.text('1 transactions'), findsOneWidget);
      expect(find.text('Replace all existing data'), findsOneWidget);

      // Confirm restoration
      await tester.ensureVisible(find.byKey(const ValueKey('confirm_restore_button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('confirm_restore_button')));
      for (int step = 0; step < 20; step++) {
        await tester.pump(const Duration(milliseconds: 50));
        await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 50)));
        if (controller.totalCount == 1) break;
      }
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // Verify SnackBar success message
      expect(find.textContaining('Restored 1 transactions & 0 receipt photos!'), findsOneWidget);
      expect(controller.balance, equals(500.0));
      expect(controller.totalCount, equals(1));
    });
  });

  group('Dimension 7: Full Dashboard & User Flow Integration', () {
    testWidgets('Dashboard empty state -> Add Money -> Pay with Receipt -> Balance update', (tester) async {
      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      late DatabaseHelper dbHelper;
      late LedgerController controller;
      late Directory tempDir;
      late ReceiptService receiptService;

      await tester.runAsync(() async {
        tempDir = Directory.systemTemp.createTempSync('e2e_dashboard_test_');
        receiptService = createTestReceiptService(tempDir);
        dbHelper = DatabaseHelper(
          databaseFactory: databaseFactoryFfi,
          databasePath: p.join(tempDir.path, 'test_ledger.db'),
        );
        controller = LedgerController(
          dbHelper: dbHelper,
          receiptService: receiptService,
        );
        await controller.loadLedger();
      });
      addTearDown(() async {
        await dbHelper.close();
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      });

      int captureCallCount = 0;
      Future<XFile?> testCaptureProvider() async {
        captureCallCount++;
        if (captureCallCount == 1) {
          // Call 1: Add Money -> simulate cancelled camera, opens manual AddMoneySheet
          return null;
        }
        // Call 2: PaySheet receipt camera
        return XFile.fromData(
          kMinimal1x1JpegBytes,
          name: 'e2e_receipt.jpg',
        );
      }

      await tester.pumpWidget(
        MaterialApp(
          home: DashboardScreen(
            controller: controller,
            photoCaptureProvider: testCaptureProvider,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 1. Initially Empty State
      expect(find.text('No transactions yet'), findsOneWidget);
      expect(find.byKey(const ValueKey('pill_hidden')), findsOneWidget);

      // 2. Tap Add Money Action Button
      await tester.tap(find.byKey(const ValueKey('action_add_money')));
      await tester.pumpAndSettle();

      // 3. Add ৳ 2000 in AddMoneySheet
      await tester.tap(find.byKey(const Key('quick_chip_1000')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('quick_chip_1000')));
      await tester.pump();
      expect(find.text('2000'), findsOneWidget);

      await tester.ensureVisible(find.byKey(const Key('confirm_add_money_button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirm_add_money_button')));
      for (int step = 0; step < 20; step++) {
        await tester.pump(const Duration(milliseconds: 50));
        await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 50)));
        if (controller.transactions.isNotEmpty) {
          await tester.pump(const Duration(milliseconds: 50));
          await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 50)));
          break;
        }
      }
      await tester.pumpAndSettle();

      // 4. Verify Dashboard updated: Empty state gone, Today group present
      expect(find.text('No transactions yet'), findsNothing);
      expect(find.text('Today'), findsOneWidget);
      expect(find.text('+ ৳ 2,000.00'), findsWidgets);

      // 5. Reveal Balance
      await tester.tap(find.byKey(const ValueKey('mfs_tap_for_balance_pill')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('৳ 2,000.00'), findsWidgets);

      // 6. Record Payment of ৳ 500 with Receipt Photo
      await tester.tap(find.byKey(const ValueKey('action_pay')));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const Key('pay_amount_field')), '500');
      await tester.enterText(find.byKey(const Key('pay_notes_field')), 'Grocery Shopping');
      await tester.pump();

      // Take receipt photo
      await tester.ensureVisible(find.byKey(const Key('take_receipt_photo_button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('take_receipt_photo_button')));
      await tester.pump();
      await tester.runAsync(() async {
        await Future.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('receipt_thumbnail_preview_card')), findsOneWidget);

      // Confirm payment
      await tester.ensureVisible(find.byKey(const Key('confirm_payment_button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirm_payment_button')));
      for (int step = 0; step < 20; step++) {
        await tester.pump(const Duration(milliseconds: 50));
        await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 50)));
        if (controller.transactions.length == 2) {
          await tester.pump(const Duration(milliseconds: 50));
          await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 50)));
          break;
        }
      }
      await tester.pumpAndSettle();

      // 7. Verify Net Balance updated to ৳ 1,500.00
      expect(controller.balance, equals(1500.0));
      expect(controller.totalCount, equals(2));
      expect(find.text('Grocery Shopping'), findsOneWidget);
      expect(find.text('- ৳ 500.00'), findsWidgets);
    });

    testWidgets('Dashboard 1-click Add Money auto-adds banknote and supports undo', (tester) async {
      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      late DatabaseHelper dbHelper;
      late LedgerController controller;
      late Directory tempDir;
      late ReceiptService receiptService;

      await tester.runAsync(() async {
        tempDir = Directory.systemTemp.createTempSync('auto_add_test_');
        receiptService = createTestReceiptService(tempDir);
        dbHelper = DatabaseHelper(
          databaseFactory: databaseFactoryFfi,
          databasePath: p.join(tempDir.path, 'test_ledger.db'),
        );
        controller = LedgerController(
          dbHelper: dbHelper,
          receiptService: receiptService,
        );
        await controller.loadLedger();
      });
      addTearDown(() async {
        await dbHelper.close();
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      });

      // Mock scanner that detects a 1000 Taka note with Bengali serial
      final mockScanner = MoneyScannerService(
        ocrEngine: const MockBanknoteOcrEngine(
          mockText: 'BANGLADESH BANK 1000 ছ দ 6282066 একহাজার টাকা',
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: DashboardScreen(
            controller: controller,
            moneyScannerService: mockScanner,
            photoCaptureProvider: () async => XFile.fromData(
              kMinimal1x1JpegBytes,
              name: 'camera_banknote.jpg',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Tap Add Money button -> directly opens camera and auto-adds
      await tester.tap(find.byKey(const ValueKey('action_add_money')));
      for (int step = 0; step < 30; step++) {
        await tester.pump(const Duration(milliseconds: 50));
        await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 50)));
        if (find.byType(SnackBar).evaluate().isNotEmpty) {
          await tester.pump(const Duration(milliseconds: 100));
          break;
        }
      }
      await tester.pump();

      // Successfully auto-added itself without manual entry!
      expect(controller.totalCount, equals(1));
      expect(controller.balance, equals(1000.0));
      expect(find.textContaining('Added ৳ 1,000.00'), findsOneWidget);
      expect(find.text('UNDO'), findsOneWidget);

      // Tap UNDO
      final undoBtn = find.byType(SnackBarAction);
      expect(undoBtn, findsOneWidget);
      final action = tester.widget<SnackBarAction>(undoBtn);
      await tester.runAsync(() async {
        action.onPressed();
        for (int step = 0; step < 30; step++) {
          if (controller.transactions.isEmpty) break;
          await Future.delayed(const Duration(milliseconds: 50));
        }
      });
      await tester.pumpAndSettle();

      // Transaction was deleted!
      expect(controller.totalCount, equals(0));
      expect(controller.balance, equals(0.0));
      expect(find.text('No transactions yet'), findsOneWidget);
    });

    testWidgets('Dashboard allows deleting transactions via Dismissible and via Lightbox', (tester) async {
      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      late DatabaseHelper dbHelper;
      late LedgerController controller;
      late Directory tempDir;
      late ReceiptService receiptService;

      await tester.runAsync(() async {
        tempDir = Directory.systemTemp.createTempSync('delete_test_');
        receiptService = createTestReceiptService(tempDir);
        dbHelper = DatabaseHelper(
          databaseFactory: databaseFactoryFfi,
          databasePath: p.join(tempDir.path, 'test_ledger.db'),
        );
        controller = LedgerController(
          dbHelper: dbHelper,
          receiptService: receiptService,
        );
        await controller.loadLedger();
        await controller.addMoney(amount: 500.0, notes: 'Wrong Deposit');
      });
      addTearDown(() async {
        await dbHelper.close();
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      });

      await tester.pumpWidget(
        MaterialApp(
          home: DashboardScreen(
            controller: controller,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Wrong Deposit'), findsOneWidget);
      expect(controller.totalCount, equals(1));

      // Swipe to delete
      await tester.drag(find.text('Wrong Deposit'), const Offset(-500, 0));
      await tester.pumpAndSettle();

      // Confirmation dialog displayed
      expect(find.text('Delete Transaction?'), findsOneWidget);
      expect(find.byKey(const ValueKey('confirm_delete_transaction_button')), findsOneWidget);

      // Confirm deletion
      await tester.tap(find.byKey(const ValueKey('confirm_delete_transaction_button')));
      for (int step = 0; step < 20; step++) {
        await tester.pump(const Duration(milliseconds: 50));
        await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 50)));
        if (controller.transactions.isEmpty) {
          await tester.pump(const Duration(milliseconds: 50));
          break;
        }
      }
      await tester.pumpAndSettle();

      // Transaction was deleted!
      expect(controller.totalCount, equals(0));
      expect(controller.balance, equals(0.0));
      expect(find.text('No transactions yet'), findsOneWidget);
    });
  });
}
