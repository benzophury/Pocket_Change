import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/transaction_item.dart';
import '../../services/database_helper.dart';
import '../../services/money_scanner_service.dart';
import '../../utils/txnid_generator.dart';
import '../theme/currency_formatter.dart';
import '../theme/mfs_colors.dart';
import '../widgets/money_scanner_sheet.dart';

/// Modal bottom sheet for recording cash inflow ("Add Money") into the digital ledger.
/// Supports scanning physical banknotes using on-device ML/AI to auto-fill the
/// monetary amount and set the physical banknote serial number as the Transaction ID.
class AddMoneySheet extends StatefulWidget {
  final double currentBalance;
  final Future<void> Function(TransactionItem txn)? onAddCompleted;
  final DatabaseHelper? databaseHelper;
  final MoneyScannerService? moneyScannerService;
  final double? initialAmount;
  final String? initialNoteNumber;

  const AddMoneySheet({
    super.key,
    required this.currentBalance,
    this.onAddCompleted,
    this.databaseHelper,
    this.moneyScannerService,
    this.initialAmount,
    this.initialNoteNumber,
  });

  /// Static helper to display the sheet modally.
  static Future<TransactionItem?> show(
    BuildContext context, {
    required double currentBalance,
    Future<void> Function(TransactionItem txn)? onAddCompleted,
    DatabaseHelper? databaseHelper,
    MoneyScannerService? moneyScannerService,
    double? initialAmount,
    String? initialNoteNumber,
  }) {
    return showModalBottomSheet<TransactionItem>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => AddMoneySheet(
        currentBalance: currentBalance,
        onAddCompleted: onAddCompleted,
        databaseHelper: databaseHelper,
        moneyScannerService: moneyScannerService,
        initialAmount: initialAmount,
        initialNoteNumber: initialNoteNumber,
      ),
    );
  }

  @override
  State<AddMoneySheet> createState() => _AddMoneySheetState();
}

class _AddMoneySheetState extends State<AddMoneySheet> {
  final _formKey = GlobalKey<FormState>();
  final _amountController = TextEditingController();
  final _noteNumberController = TextEditingController();
  final _notesController = TextEditingController();

  static const List<int> _quickChips = [100, 500, 1000, 5000];

  double _parsedAmount = 0.0;
  bool _isSubmitting = false;
  String? _errorMessage;
  bool _isAiScanned = false;

  @override
  void initState() {
    super.initState();
    _amountController.addListener(_onAmountChanged);
    if (widget.initialAmount != null && widget.initialAmount! > 0) {
      final amt = widget.initialAmount!;
      _amountController.text =
          amt % 1 == 0 ? amt.toInt().toString() : amt.toStringAsFixed(2);
      _parsedAmount = amt;
      _isAiScanned = true;
    }
    if (widget.initialNoteNumber != null && widget.initialNoteNumber!.isNotEmpty) {
      _noteNumberController.text = widget.initialNoteNumber!;
    }
  }

  @override
  void dispose() {
    _amountController.removeListener(_onAmountChanged);
    _amountController.dispose();
    _noteNumberController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  void _onAmountChanged() {
    final text = _amountController.text.trim();
    final val = double.tryParse(text);
    setState(() {
      if (val != null && val > 0 && !val.isNaN && !val.isInfinite) {
        _parsedAmount = val;
        _errorMessage = null;
      } else {
        _parsedAmount = 0.0;
        if (text.isNotEmpty && (val == null || val <= 0)) {
          _errorMessage = 'Please enter a valid amount greater than 0';
        } else {
          _errorMessage = null;
        }
      }
    });
  }

  void _applyQuickChip(int chipAmount) {
    HapticFeedback.lightImpact();
    final current = double.tryParse(_amountController.text.trim()) ?? 0.0;
    final updated = current + chipAmount;
    _amountController.text =
        updated % 1 == 0 ? updated.toInt().toString() : updated.toStringAsFixed(2);
    _amountController.selection = TextSelection.fromPosition(
      TextPosition(offset: _amountController.text.length),
    );
  }

  void _clearAmount() {
    HapticFeedback.selectionClick();
    _amountController.clear();
    setState(() => _isAiScanned = false);
  }

  void _openMoneyScanner() {
    final scanner = widget.moneyScannerService ?? MoneyScannerService();
    MoneyScannerSheet.show(
      context,
      scannerService: scanner,
      onBanknoteDetected: (amount, noteNumber, photo) {
        setState(() {
          if (amount > 0) {
            _amountController.text =
                amount % 1 == 0 ? amount.toInt().toString() : amount.toStringAsFixed(2);
          }
          if (noteNumber != null && noteNumber.isNotEmpty) {
            _noteNumberController.text = noteNumber;
          }
          _isAiScanned = true;
        });
      },
    );
  }

  Future<void> _submitAddMoney() async {
    if (_isSubmitting) return;
    if (_parsedAmount <= 0) {
      setState(() => _errorMessage = 'Please enter a valid amount greater than 0');
      return;
    }

    setState(() => _isSubmitting = true);

    try {
      // Use banknote serial number as transaction ID if present, otherwise fallback to cryptosecure ID
      final userNoteNumber = _noteNumberController.text.trim();
      final txnid = userNoteNumber.isNotEmpty
          ? userNoteNumber
          : TxnIdGenerator.generate(prefix: 'TXN');

      final txn = TransactionItem(
        txnid: txnid,
        type: TransactionType.add,
        amount: _parsedAmount,
        timestamp: DateTime.now(),
        notes: _notesController.text.trim().isEmpty ? null : _notesController.text.trim(),
      );

      final dbHelper = widget.databaseHelper ?? DatabaseHelper.instance;
      await dbHelper.insertTransaction(txn);

      if (widget.onAddCompleted != null) {
        await widget.onAddCompleted!(txn);
      }

      if (mounted) {
        setState(() => _isSubmitting = false);
        Navigator.of(context).pop(txn);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Added ৳${_parsedAmount.toStringAsFixed(2)} to Cash Ledger (TxnID: $txnid)',
            ),
            backgroundColor: MfsColors.primary,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = 'Failed to record transaction: $e';
          _isSubmitting = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final projectedBalance = widget.currentBalance + _parsedAmount;

    return Container(
      decoration: const BoxDecoration(
        color: MfsColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        border: Border(top: BorderSide(color: MfsColors.border, width: 1.5)),
      ),
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 12,
        bottom: mediaQuery.viewInsets.bottom + 24,
      ),
      child: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 1. Drag Handle
              Center(
                child: Container(
                  width: 48,
                  height: 4,
                  decoration: BoxDecoration(
                    color: MfsColors.border,
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // 2. Header
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: MfsColors.primaryLight,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(
                      Icons.arrow_downward_rounded,
                      color: MfsColors.primary,
                      size: 22,
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Add Cash',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: MfsColors.textPrimary,
                          ),
                        ),
                        Text(
                          'Record physical cash deposit to ledger',
                          style: TextStyle(fontSize: 12, color: MfsColors.textSecondary),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded, color: MfsColors.textSecondary),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // 3. Projected Balance Card (Matte Black with Subtle Crimson Border)
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: MfsColors.surfaceVariant,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: MfsColors.border),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Current Balance',
                            style: TextStyle(fontSize: 12, color: MfsColors.textSecondary)),
                        const SizedBox(height: 2),
                        Text(
                          CurrencyFormatter.formatBdt(widget.currentBalance),
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: MfsColors.textPrimary,
                          ),
                        ),
                      ],
                    ),
                    const Icon(Icons.arrow_forward_rounded, color: MfsColors.primary, size: 20),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        const Text('Projected Balance',
                            style: TextStyle(fontSize: 12, color: MfsColors.primary)),
                        const SizedBox(height: 2),
                        Text(
                          CurrencyFormatter.formatBdt(projectedBalance),
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: MfsColors.primary,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              // 4. AI Banknote Scanner Trigger Button
              OutlinedButton.icon(
                key: const Key('scan_physical_money_button'),
                onPressed: _openMoneyScanner,
                icon: const Icon(Icons.document_scanner_rounded, color: MfsColors.primary, size: 20),
                label: Text(
                  _isAiScanned ? 'Rescan Banknote (AI)' : 'Scan Physical Banknote (AI)',
                  style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
                ),
                style: OutlinedButton.styleFrom(
                  backgroundColor: MfsColors.surfaceVariant,
                  side: const BorderSide(color: MfsColors.primary, width: 1.2),
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
              ),
              const SizedBox(height: 16),

              // 5. Amount Input Field
              TextFormField(
                controller: _amountController,
                key: const Key('add_money_amount_field'),
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}')),
                ],
                style: const TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.bold,
                  color: MfsColors.textPrimary,
                ),
                decoration: InputDecoration(
                  prefixIcon: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    child: Text(
                      CurrencyFormatter.takaSymbol,
                      style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.bold,
                        color: MfsColors.primary,
                      ),
                    ),
                  ),
                  suffixIcon: _amountController.text.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear_rounded, color: MfsColors.textSecondary),
                          onPressed: _clearAmount,
                        )
                      : null,
                  hintText: '0.00',
                  hintStyle: const TextStyle(color: MfsColors.textMuted, fontSize: 26),
                  errorText: _errorMessage,
                ),
              ),
              const SizedBox(height: 12),

              // 6. Quick Amount Increment Chips
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final amount in _quickChips)
                    ActionChip(
                      key: Key('quick_chip_$amount'),
                      label: Text('+৳$amount', style: const TextStyle(fontWeight: FontWeight.w600)),
                      backgroundColor: MfsColors.surfaceVariant,
                      labelStyle: const TextStyle(color: Colors.white),
                      side: const BorderSide(color: MfsColors.border),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      onPressed: () => _applyQuickChip(amount),
                    ),
                ],
              ),
              const SizedBox(height: 18),

              // 7. Banknote Serial Number (Transaction ID) Field
              TextFormField(
                controller: _noteNumberController,
                key: const Key('add_money_note_number_field'),
                maxLength: 32,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
                decoration: InputDecoration(
                  labelText: 'Banknote Serial Number (TxnID)',
                  hintText: 'e.g. 8K 4920194 or Auto-Generated',
                  prefixIcon: const Icon(Icons.tag_rounded, color: MfsColors.primary),
                  counterText: '',
                  suffixIcon: _isAiScanned
                      ? Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          margin: const EdgeInsets.only(right: 8),
                          decoration: BoxDecoration(
                            color: MfsColors.primaryLight,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.auto_awesome_rounded, color: MfsColors.primary, size: 14),
                              SizedBox(width: 4),
                              Text('AI Scanned', style: TextStyle(color: MfsColors.primary, fontSize: 11)),
                            ],
                          ),
                        )
                      : IconButton(
                          icon: const Icon(Icons.document_scanner_outlined, color: MfsColors.primary, size: 20),
                          tooltip: 'Scan Banknote Number',
                          onPressed: _openMoneyScanner,
                        ),
                ),
              ),
              const SizedBox(height: 14),

              // 8. Optional Note Field
              TextFormField(
                controller: _notesController,
                key: const Key('add_money_notes_field'),
                maxLength: 120,
                decoration: const InputDecoration(
                  labelText: 'Note / Memo (Optional)',
                  hintText: 'e.g. Cash in hand or wallet refill',
                  prefixIcon: Icon(Icons.edit_note_rounded),
                  counterText: '',
                ),
              ),
              const SizedBox(height: 24),

              // 9. Confirm Action Button (Crimson Red)
              ElevatedButton(
                key: const Key('confirm_add_money_button'),
                onPressed: (_parsedAmount > 0 && !_isSubmitting) ? _submitAddMoney : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: MfsColors.primary,
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: MfsColors.border,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  elevation: 2,
                ),
                child: _isSubmitting
                    ? const SizedBox(
                        height: 22,
                        width: 22,
                        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5),
                      )
                    : const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.check_circle_outline_rounded, size: 20),
                          SizedBox(width: 8),
                          Text(
                            'Confirm Add Cash',
                            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
