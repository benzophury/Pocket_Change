# Project: Pocket Change — Bangladeshi MFS Digital Cash Ledger

## Architecture
- **Framework**: Flutter (Android target)
- **Language**: Dart
- **Local Persistence**: SQLite via `sqflite` (Android native) and `sqflite_common_ffi` (headless testing)
- **Architecture Pattern**: Clean Layered Architecture:
  - `lib/models/`: Domain entities (`TransactionItem`, `TransactionType`, `LedgerSummary`, `BackupPayload`)
  - `lib/services/`: Database helper, receipt photo storage service, backup import/export service, image capture service
  - `lib/providers/` or `lib/controllers/`: Ledger state management (balance, transactions, loading state)
  - `lib/ui/`:
    - `theme/`: MFS design tokens (bKash Pink `#E2136E`, Nagad Orange `#F7941D`, Emerald Green `#2E7D32`, BDT `৳` formatting)
    - `widgets/`: Balance card with "Tap for Balance" auto-hide pill, action buttons, transaction tile, receipt lightbox
    - `screens/`: Dashboard screen, Add Money sheet, Pay sheet with camera memo, Backup/Restore screen
  - `test/`: Automated unit, widget, and repository tests running via `sqflite_common_ffi`

## Feature Inventory
| # | Feature | Description | Milestone | Source |
|---|---------|-------------|-----------|--------|
| 1 | Flutter & Android Toolchain Setup | Setup Flutter SDK, JDK 21, Android SDK path, and initial project scaffold with required dependencies | M1 | Survey 1 |
| 2 | Android Permissions & Configuration | Configure Camera, storage, and manifest settings for APK compilation | M1 | Survey 1 |
| 3 | Ledger Data Model & TxnID Generator | Define TransactionItem, TransactionType (ADD/PAY), and unique bKash/Nagad-style txnid generator | M2 | Survey 2 |
| 4 | SQLite Database Schema & Dynamic Balance View | SQLite table with constraints, indexes, and dynamic `ledger_summary` SQL view for balance | M2 | Survey 2 |
| 5 | Ledger Core Operations | Add Money, Pay, retrieve transactions, compute balance and totals | M2 | Survey 2 |
| 6 | Receipt Image Storage Service | Manage relative path storage (`receipts/rec_<id>.jpg`) in app documents directory | M2 | Survey 2 |
| 7 | Portable JSON Backup Serialization | Export all ledger records with summary metadata and embedded Base64 receipt photos | M3 | Survey 2 |
| 8 | Atomic Backup Restoration & Validation | Validate JSON schema, atomically restore records into SQLite, reconstruct receipt images | M3 | Survey 2 |
| 9 | MFS Visual System & BDT Formatting | Theme tokens (bKash Pink, Nagad Orange, Emerald Green), Bengali Taka `৳` formatter | M4 | Survey 3 |
| 10 | "Tap for Balance" MFS Balance Card | Interactive pill with animation, haptic feedback, and 4-second auto-hide privacy timer | M4 | Survey 3 |
| 11 | "Add Money" Flow | Quick amount chips, input validation, confirmation, and balance update | M4 | Survey 3 |
| 12 | "Pay" Flow with Camera Receipt Capture | Integrated camera memo capture, live thumbnail preview, retake/delete, note entry | M4 | Survey 3 |
| 13 | Date-Grouped Transaction Feed | Transactions grouped by Today/Yesterday/Date with `+`/`-` styling, TrxID chips, receipt thumbnails | M4 | Survey 3 |
| 14 | Receipt Lightbox Modal | Modal bottom sheet with full details and InteractiveViewer pinch-to-zoom for receipt photos | M4 | Survey 3 |
| 15 | Backup & Restore UI Screen | UI for database statistics, Export with Android Share sheet, and Import via file picker | M4 | Survey 3 |
| 16 | Edge Case Safeguards & Validation | 12 safeguards (zero/negative values, decimals, camera cancellations, corrupt files, empty state) | M4 | Survey 3 |
| 17 | E2E Automated Test Suite (Tiers 1-4) | Comprehensive opaque-box test suite published via TEST_READY.md | E2E Track | ORIGINAL_REQUEST |
| 18 | Final Verification & Android APK Build | 100% test pass, adversarial hardening (Tier 5), and `flutter build apk` verification | M5 | ORIGINAL_REQUEST |

## Milestones
| # | Name | Scope | Dependencies | Status |
|---|------|-------|-------------|--------|
| 1 | Toolchain & Scaffolding | Install Flutter SDK, initialize Android project, setup dependencies & manifest, verify build | none | DONE |
| 2 | Persistence & Ledger Engine | SQLite database schema, CRUD operations, dynamic balance view, receipt photo service, unit tests | M1 | DONE |
| 3 | Backup Export & Import | Portable JSON export with Base64 photos, atomic import restoration, schema validation, unit tests | M2 | DONE |
| 4 | MFS UI & User Flows | Bangladeshi MFS design system, Balance card, Add Money, Pay with camera, transaction feed, Lightbox, Backup UI | M2, M3 | PLANNED |
| 5 | E2E Test Pass & APK Build | Pass 100% E2E tests (Tiers 1-4), adversarial hardening (Tier 5), clean Android APK build | M4, E2E Track | PLANNED |
| E2E | E2E Testing Track | Independent opaque-box test suite covering Tiers 1-4, publish TEST_READY.md | M1 | PLANNED |

## Interface Contracts
### LedgerDatabase ↔ UI & Services
- `Future<int> insertTransaction(TransactionItem txn)`
- `Future<List<TransactionItem>> getAllTransactions()`
- `Future<double> getBalance()`
- `Future<LedgerSummary> getSummary()`
- `Future<void> clearAll()`
- `Future<void> restoreTransactions(List<TransactionItem> txns)`

### ReceiptStorageService
- `Future<String> saveReceiptImage(XFile image, String txnid)` -> returns relative path `receipts/rec_<txnid>.jpg`
- `Future<File?> getReceiptFile(String? relativePath)` -> returns File or null
- `Future<String?> encodeReceiptToBase64(String? relativePath)` -> returns base64 string or null
- `Future<String> restoreReceiptFromBase64(String base64Data, String relativePath)` -> saves to disk

### BackupService
- `Future<String> exportBackupJson()` -> returns serialized JSON string
- `Future<BackupSummary> importBackupJson(String jsonString)` -> validates and atomically restores data

## Code Layout
```
/home/sh/Pocket_Change/
├── pubspec.yaml
├── android/
│   ├── app/
│   │   ├── build.gradle
│   │   └── src/main/AndroidManifest.xml
│   └── build.gradle
├── lib/
│   ├── main.dart
│   ├── models/
│   │   ├── transaction_item.dart
│   │   └── ledger_summary.dart
│   ├── services/
│   │   ├── database_helper.dart
│   │   ├── receipt_service.dart
│   │   └── backup_service.dart
│   ├── controllers/
│   │   └── ledger_controller.dart
│   ├── ui/
│   │   ├── theme/
│   │   │   ├── mfs_colors.dart
│   │   │   └── currency_formatter.dart
│   │   ├── widgets/
│   │   │   ├── mfs_balance_card.dart
│   │   │   ├── mfs_action_buttons.dart
│   │   │   ├── transaction_tile.dart
│   │   │   └── receipt_lightbox.dart
│   │   └── screens/
│   │       ├── dashboard_screen.dart
│   │       ├── add_money_sheet.dart
│   │       ├── pay_sheet.dart
│   │       └── backup_restore_screen.dart
│   └── utils/
│       └── txnid_generator.dart
└── test/
    ├── test_helper.dart
    ├── ledger_database_test.dart
    ├── backup_service_test.dart
    ├── mfs_ui_test.dart
    └── e2e/
        ├── tier1_feature_test.dart
        ├── tier2_boundary_test.dart
        ├── tier3_combination_test.dart
        └── tier4_application_scenario_test.dart
```
