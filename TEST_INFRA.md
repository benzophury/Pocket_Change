# E2E Test Infra: Pocket Change (Bangladeshi MFS Cash Ledger)

## Test Philosophy
- Opaque-box, requirement-driven derived strictly from `ORIGINAL_REQUEST.md`.
- No internal private member coupling; tests interact with public services, repositories, and UI widgets.
- Headless execution enabled by `sqflite_common_ffi` with in-memory databases and mockable image capture abstraction.
- Methodology: Category-Partition + Boundary Value Analysis (BVA) + Pairwise Combinatorial Testing + Real-World Workload Testing.

## Feature Inventory & Target Coverage
| # | Feature | Source (requirement) | Tier 1 (>=5) | Tier 2 (>=5) | Tier 3 (Pairwise) | Tier 4 (Scenario) |
|---|---------|---------------------|:------------:|:------------:|:-----------------:|:-----------------:|
| F1 | Add Money (Cash In) | R1, Acceptance Core Ledger | 5 | 5 | ✓ | ✓ |
| F2 | Pay with Receipt Memo Photo | R1, Acceptance Core Ledger | 5 | 5 | ✓ | ✓ |
| F3 | Dynamic Balance Computation | R1, R4, Acceptance Core Ledger | 5 | 5 | ✓ | ✓ |
| F4 | Transaction History & TxnID Uniqueness | R1, R2, Acceptance Core Ledger | 5 | 5 | ✓ | ✓ |
| F5 | Bangladeshi MFS Dashboard & Balance Card | R2, Acceptance UI & Styling | 5 | 5 | ✓ | ✓ |
| F6 | SQLite Local Persistence & Lifecycle | R3, Acceptance Local Persistence | 5 | 5 | ✓ | ✓ |
| F7 | Backup Export & File Sharing | R3, Acceptance Local Persistence | 5 | 5 | ✓ | ✓ |
| F8 | Backup Import & Data Restoration | R3, Acceptance Local Persistence | 5 | 5 | ✓ | ✓ |

## Test Architecture
- **Runner**: `flutter test`
- **Database Engine for Tests**: `sqflite_common_ffi` with `databaseFactory = databaseFactoryFfi;`
- **Location**: `test/e2e/`
- **Directory Layout**:
  - `test/test_helper.dart`: Common setup (`sqfliteFfiInit()`, in-memory database factories, sample receipts)
  - `test/e2e/tier1_feature_test.dart`: Isolated happy-path tests for each feature (F1-F8, >=40 tests)
  - `test/e2e/tier2_boundary_test.dart`: Limits, empty inputs, large numbers, precision, corrupt JSON, missing images (>=40 tests)
  - `test/e2e/tier3_combination_test.dart`: Pairwise feature interactions (Add then Pay, Export then Add then Import, etc.)
  - `test/e2e/tier4_application_scenario_test.dart`: Complete realistic user day-in-the-life journeys

## Real-World Application Scenarios (Tier 4)
| # | Scenario | Features Exercised | Complexity |
|---|----------|--------------------|------------|
| S1 | Month-Start Salary Deposit & Daily Bazaar Expenses | F1, F2, F3, F4, F5 | High |
| S2 | Multi-Item Shopping with Paper Receipt Capture | F2, F3, F4 | Medium |
| S3 | Device Migration via JSON Backup & Restore | F1, F2, F6, F7, F8 | High |
| S4 | Zero Balance Overdraft Attempt & Resolution | F1, F2, F3, F5 | Medium |
| S5 | High-Volume Transaction Month with Export Archive | F1, F2, F3, F4, F6, F7 | High |

## Coverage Thresholds
- Tier 1: ≥5 per feature (Total: ≥40 tests)
- Tier 2: ≥5 per feature (Total: ≥40 tests)
- Tier 3: Pairwise coverage of all major feature pairs (≥15 tests)
- Tier 4: ≥5 realistic real-world application scenarios
- **Total Minimum Target**: ≥100 automated test cases running cleanly to completion.
