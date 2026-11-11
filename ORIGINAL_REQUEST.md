# Original User Request

## Initial Request — 2026-11-07T15:14:14Z

A Flutter digital cash ledger application for Android inspired by Bangladeshi MFS apps (bKash, Nagad), providing physical cash recordkeeping, camera receipt capture, and local SQLite data portability.

Working directory: /home/sh/Pocket_Change
Integrity mode: development

## Requirements

### R1. Digital Cash Ledger & Transactions
The Flutter Android application must provide a ledger for physical cash recordkeeping. Users can add funds ("Add Money") by entering an amount, record cash payments ("Pay") with an integrated camera memo/receipt photo capture, and view a transaction history showing unique transaction IDs (txnid), amounts, types, timestamps, and attached memo photos.

### R2. Bangladeshi MFS-Inspired User Interface
The UI must be modeled on Bangladeshi Mobile Financial Services apps (such as bKash and Nagad), featuring an MFS-style dashboard with balance display, primary action buttons ("Add Money", "Pay"), and a clear transaction log.

### R3. Local SQLite Persistence and Portability
All ledger records and transaction history must be stored locally using SQLite. The application must provide functionality to export the SQLite database/data to a file and import data back to restore records.

### R4. Automated Verification & Android Build
The project must include automated Flutter tests covering ledger operations, balance tracking, and SQLite persistence/import-export, and must successfully build for Android.

## Acceptance Criteria

### Core Ledger & Transactions
- [ ] Users can enter an amount to record cash additions ("Add Money"), updating the total balance.
- [ ] Users can record cash payments ("Pay"), updating the balance and capturing a photo of a memo/receipt.
- [ ] Transaction history displays all transactions with unique transaction IDs, transaction type, amount, date/time, and attached memo photo.

### UI & Styling
- [ ] App dashboard reflects Bangladeshi MFS aesthetics (prominent balance card, quick actions, transaction feed).

### Local Persistence & Portability
- [ ] Transaction data and balance persist across app restarts via local SQLite.
- [ ] An export feature creates a restorable backup/export file of the ledger data.
- [ ] An import feature restores ledger transactions and state from an exported file.

### Verification
- [ ] Automated Flutter tests cover transaction logic, balance calculations, and SQLite persistence, running to completion with all tests passing.
- [ ] The Flutter project compiles and builds for Android (e.g. `flutter build apk`) without build errors.
