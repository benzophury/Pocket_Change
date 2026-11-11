import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:pocket_change/controllers/ledger_controller.dart';
import 'package:pocket_change/main.dart';
import 'package:pocket_change/services/database_helper.dart';
import 'package:pocket_change/services/receipt_service.dart';
import 'test_helper.dart';

void main() {
  setUpAll(() {
    initTestDatabaseFactory();
  });

  testWidgets('Pocket Change MFS App smoke test', (WidgetTester tester) async {
    late Directory tempDir;
    late ReceiptService receiptService;
    late DatabaseHelper dbHelper;
    late LedgerController controller;

    await tester.runAsync(() async {
      tempDir = Directory.systemTemp.createTempSync('widget_smoke_');
      receiptService = createTestReceiptService(tempDir);
      dbHelper = DatabaseHelper(
        databaseFactory: databaseFactoryFfi,
        databasePath: inMemoryDatabasePath,
      );
      controller = LedgerController(
        dbHelper: dbHelper,
        receiptService: receiptService,
      );
      await controller.loadLedger();
    });

    // Build our app and trigger a frame.
    await tester.pumpWidget(MyApp(controller: controller));
    await tester.pump();

    // Verify that the Bangladeshi MFS dashboard elements are present.
    expect(find.text('Pocket Change'), findsOneWidget);
    expect(find.text('Tap for Balance'), findsOneWidget);
    expect(find.text('Add Money'), findsWidgets);
    expect(find.text('Pay'), findsOneWidget);
  });
}
