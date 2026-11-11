# Pocket Change 💸

> A local-first, privacy-first digital **cash ledger** for Bangladesh Bank notes — with on-device AI banknote scanning.

[![Flutter](https://img.shields.io/badge/Flutter-3.22+-02569B?logo=flutter)](https://flutter.dev)
[![Dart](https://img.shields.io/badge/Dart-3.5+-0175C2?logo=dart)](https://dart.dev)
[![License](https://img.shields.io/badge/license-MIT-crimson)](LICENSE)
[![Tests](https://img.shields.io/badge/tests-172%20passing-brightgreen)]()

---

## Features

- **📷 1-Tap Banknote Scanning** — Tap "Add Money" on the home screen and point the camera at any Bangladesh Bank note. The on-device ML Kit OCR reads the note number and denomination automatically and adds it to your wallet. Falls back to manual entry if detection is uncertain.
- **🔢 Note Numbers as Transaction IDs** — Every scanned note's serial number (e.g. `জ ৬৯৩১৯০৬১`) is preserved as the transaction ID for full traceability.
- **🏦 Wallet Ledger** — Track your physical cash balance in BDT with a date-grouped transaction feed. Swipe to delete any transaction.
- **💳 Pay with Banknotes** — When paying, choose specific banknotes from your wallet to deduct. Notes are removed from your wallet automatically.
- **🔒 Privacy Mode** — Balance is hidden by default. Tap to reveal for 4 seconds, then auto-conceals.
- **💾 Backup & Restore** — Export your full ledger (including receipt photos) as a portable JSON file. Restore from backup with atomic rollback on failure.
- **📸 Receipt Photos** — Attach a camera memo to any payment for record-keeping.
- **🗑️ Delete Transactions** — Swipe-to-dismiss or open the receipt lightbox and delete from there.

---

## Screenshots

| Home — Balance Card | Scan Banknote | Transaction Feed |
|---|---|---|
| Matte Black + Crimson Red theme | OCR detects Bengali script numerals | Date-grouped with swipe-to-delete |

---

## Tech Stack

| Layer | Technology |
|---|---|
| UI | Flutter (Material 3, Matte Black `#0D0D0D` + Crimson `#DC143C`) |
| OCR / ML | Google ML Kit Text Recognition (on-device, no cloud) |
| Persistence | SQLite via `sqflite` |
| Backup | JSON export/import with atomic rollback |
| Testing | 172 unit + widget tests |

---

## Getting Started

### Prerequisites

- Flutter ≥ 3.22.0
- Android SDK (target API 35)
- Java 21+

### Run

```bash
flutter pub get
flutter run
```

### Build Release APK

```bash
flutter build apk --release --split-per-abi
# ARM64 output: build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
```

### Run Tests

```bash
flutter test
```

---

## Supported Banknotes

Optimized exclusively for **Bangladesh Bank** notes (৳ BDT):

- ৳10, ৳20, ৳50, ৳100, ৳200, ৳500, ৳1000

Bengali script serial numbers are detected using the full Unicode block (U+0980–U+09FF) including vowel matras and compound characters.

---

## Version History

| Version | Changes |
|---|---|
| `v1.1.0` | 1-tap add money, Bengali OCR fix, pay-with-notes, swipe-to-delete, BDT Taka `৳` app icon |
| `v1.0.0` | Initial release: ledger, backup/restore, receipt photos, ML Kit scanning |

---

## License

MIT © benzophury
