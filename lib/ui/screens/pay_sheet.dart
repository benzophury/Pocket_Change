import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../../models/transaction_item.dart';
import '../../services/database_helper.dart';
import '../../services/money_scanner_service.dart';
import '../../services/receipt_service.dart';
import '../../utils/txnid_generator.dart';
import '../theme/currency_formatter.dart';
import '../theme/mfs_colors.dart';
import '../widgets/money_scanner_sheet.dart';
import '../widgets/receipt_lightbox.dart';

/// Typedef for acquiring a receipt photo via camera.
/// Injected for 100% headless widget testability.
typedef PhotoCaptureProvider = Future<XFile?> Function();

/// Default production camera capture implementation via [ImagePicker].
Future<XFile?> defaultCameraCaptureProvider() async {
  final picker = ImagePicker();
  return await picker.pickImage(
    source: ImageSource.camera,
    maxWidth: 1800,
    maxHeight: 1800,
    imageQuality: 85,
  );
}

/// Modal bottom sheet for recording cash payment with camera receipt capture,
/// live thumbnail preview, retake/delete controls, and balance check warning.
class PaySheet extends StatefulWidget {
  final double currentBalance;
  final PhotoCaptureProvider? photoCaptureProvider;
  final Future<void> Function(TransactionItem txn)? onPaymentSubmitted;
  final ReceiptService? receiptService;
  final DatabaseHelper? databaseHelper;
  final MoneyScannerService? moneyScannerService;
  final List<TransactionItem>? availableNotes;

  const PaySheet({
    super.key,
    required this.currentBalance,
    this.photoCaptureProvider,
    this.onPaymentSubmitted,
    this.receiptService,
    this.databaseHelper,
    this.moneyScannerService,
    this.availableNotes,
  });

  /// Static presentation helper.
  static Future<TransactionItem?> show(
    BuildContext context, {
    required double currentBalance,
    PhotoCaptureProvider? photoCaptureProvider,
    Future<void> Function(TransactionItem txn)? onPaymentSubmitted,
    ReceiptService? receiptService,
    DatabaseHelper? databaseHelper,
    MoneyScannerService? moneyScannerService,
    List<TransactionItem>? availableNotes,
  }) {
    return showModalBottomSheet<TransactionItem>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => PaySheet(
        currentBalance: currentBalance,
        photoCaptureProvider: photoCaptureProvider,
        onPaymentSubmitted: onPaymentSubmitted,
        receiptService: receiptService,
        databaseHelper: databaseHelper,
        moneyScannerService: moneyScannerService,
        availableNotes: availableNotes,
      ),
    );
  }

  @override
  State<PaySheet> createState() => _PaySheetState();
}

class _PaySheetState extends State<PaySheet> {
  final _amountController = TextEditingController();
  final _recipientController = TextEditingController();
  final _noteNumberController = TextEditingController();
  final _notesController = TextEditingController();

  double _parsedAmount = 0.0;
  bool _isSubmitting = false;
  bool _isCapturingPhoto = false;
  bool _allowNegativeOverride = false;
  String? _errorMessage;

  XFile? _capturedPhoto;
  Uint8List? _cachedPhotoBytes;

  List<TransactionItem> _availableNotes = [];
  final Set<String> _selectedNoteIds = {};

  @override
  void initState() {
    super.initState();
    _amountController.addListener(_onAmountChanged);
    if (widget.availableNotes != null) {
      _availableNotes = widget.availableNotes!;
    } else {
      _loadAvailableNotes();
    }
  }

  Future<void> _loadAvailableNotes() async {
    try {
      final dbHelper = widget.databaseHelper ?? DatabaseHelper.instance;
      final notes = await dbHelper.getAvailableBanknotes();
      if (mounted) {
        setState(() {
          _availableNotes = notes;
        });
      }
    } catch (_) {}
  }

  void _toggleNoteSelection(TransactionItem note) {
    HapticFeedback.selectionClick();
    setState(() {
      if (_selectedNoteIds.contains(note.txnid)) {
        _selectedNoteIds.remove(note.txnid);
      } else {
        _selectedNoteIds.add(note.txnid);
      }

      if (_selectedNoteIds.isNotEmpty) {
        final totalSelected = _availableNotes
            .where((n) => _selectedNoteIds.contains(n.txnid))
            .fold(0.0, (sum, n) => sum + n.amount);
        _parsedAmount = totalSelected;
        _amountController.text = totalSelected % 1 == 0
            ? totalSelected.toInt().toString()
            : totalSelected.toStringAsFixed(2);
        _noteNumberController.text = _selectedNoteIds.join(', ');
      } else {
        _parsedAmount = 0.0;
        _amountController.clear();
        _noteNumberController.clear();
      }
    });
  }

  @override
  void dispose() {
    _amountController.removeListener(_onAmountChanged);
    _amountController.dispose();
    _recipientController.dispose();
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
          _errorMessage = 'Please enter a valid payment amount greater than 0';
        } else {
          _errorMessage = null;
        }
      }
    });
  }

  bool get _isInsufficientBalance => _parsedAmount > widget.currentBalance;

  bool get _canSubmit {
    if (_parsedAmount <= 0 || _isSubmitting) return false;
    if (_isInsufficientBalance && !_allowNegativeOverride) return false;
    return true;
  }

  Future<void> _captureReceiptPhoto() async {
    if (_isCapturingPhoto) return;
    setState(() => _isCapturingPhoto = true);

    try {
      final provider = widget.photoCaptureProvider ?? defaultCameraCaptureProvider;
      final XFile? photo = await provider();

      if (photo != null) {
        final bytes = await photo.readAsBytes();
        setState(() {
          _capturedPhoto = photo;
          _cachedPhotoBytes = bytes;
        });
      }
    } on PlatformException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Camera unavailable or permission denied: ${e.message ?? e.code}'),
            backgroundColor: Colors.orange.shade800,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e, stack) {
      debugPrint('DEBUG _captureReceiptPhoto error: $e\n$stack');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to capture receipt: $e'),
            backgroundColor: Colors.red.shade800,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isCapturingPhoto = false);
      }
    }
  }

  void _openBanknoteScanner() {
    final scanner = widget.moneyScannerService ?? MoneyScannerService();
    MoneyScannerSheet.show(
      context,
      scannerService: scanner,
      onBanknoteDetected: (amount, noteNumber, photo) async {
        setState(() {
          if (amount > 0) {
            _amountController.text =
                amount % 1 == 0 ? amount.toInt().toString() : amount.toStringAsFixed(2);
          }
          if (noteNumber != null && noteNumber.isNotEmpty) {
            _noteNumberController.text = noteNumber;
          }
        });
        if (photo != null) {
          final bytes = await photo.readAsBytes();
          setState(() {
            _capturedPhoto = photo;
            _cachedPhotoBytes = bytes;
          });
        }
      },
    );
  }

  void _removeReceiptPhoto() {
    setState(() {
      _capturedPhoto = null;
      _cachedPhotoBytes = null;
    });
  }

  void _previewReceipt() {
    if (_cachedPhotoBytes == null) return;
    ReceiptLightbox.show(
      context,
      transaction: TransactionItem(
        txnid: _noteNumberController.text.trim().isNotEmpty
            ? _noteNumberController.text.trim()
            : 'PREVIEW',
        type: TransactionType.pay,
        amount: _parsedAmount > 0 ? _parsedAmount : 0.01,
        timestamp: DateTime.now(),
        notes: _notesController.text.trim().isEmpty ? null : _notesController.text.trim(),
      ),
      imageBytes: _cachedPhotoBytes,
    );
  }

  Future<void> _submitPayment() async {
    if (!_canSubmit) return;
    setState(() => _isSubmitting = true);

    try {
      final userNoteNumber = _noteNumberController.text.trim();
      final spentNoteRef = _selectedNoteIds.isNotEmpty
          ? _selectedNoteIds.join(', ')
          : userNoteNumber;

      final txnid = _selectedNoteIds.isNotEmpty
          ? 'PAY-${_selectedNoteIds.first.replaceAll(' ', '')}-${DateTime.now().millisecondsSinceEpoch % 100000}'
          : (userNoteNumber.isNotEmpty
              ? (userNoteNumber.startsWith('PAY-') ? userNoteNumber : 'PAY-${userNoteNumber.replaceAll(' ', '')}')
              : TxnIdGenerator.generate(prefix: 'TXN'));

      String? savedRelativePath;

      // Save receipt photo if attached
      if (_capturedPhoto != null && _cachedPhotoBytes != null) {
        final receiptService = widget.receiptService ?? ReceiptService.instance;
        savedRelativePath = await receiptService.saveReceiptBytes(
          _cachedPhotoBytes!,
          txnid,
          extension: 'jpg',
        );
      }

      // Combine recipient and notes if recipient provided
      final recipient = _recipientController.text.trim();
      final userNote = _notesController.text.trim();
      final combinedNotes = [
        if (spentNoteRef.isNotEmpty) 'Deducted note: $spentNoteRef',
        if (recipient.isNotEmpty) 'Recipient: $recipient',
        if (userNote.isNotEmpty) userNote,
      ].join(' • ');

      final txn = TransactionItem(
        txnid: txnid,
        type: TransactionType.pay,
        amount: _parsedAmount,
        timestamp: DateTime.now(),
        memoPhotoPath: savedRelativePath,
        notes: combinedNotes.isEmpty ? null : combinedNotes,
      );

      final dbHelper = widget.databaseHelper ?? DatabaseHelper.instance;
      await dbHelper.insertTransaction(txn);

      if (widget.onPaymentSubmitted != null) {
        await widget.onPaymentSubmitted!(txn);
      }

      if (mounted) {
        setState(() => _isSubmitting = false);
        Navigator.of(context).pop(txn);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _selectedNoteIds.isNotEmpty
                  ? 'Deducted ${CurrencyFormatter.formatBdt(_parsedAmount)} from wallet'
                  : 'Paid ৳${_parsedAmount.toStringAsFixed(2)} (TxnID: $txnid)',
            ),
            backgroundColor: MfsColors.primary,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = 'Payment recording failed: $e';
          _isSubmitting = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final remainingBalance = widget.currentBalance - _parsedAmount;

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
                    Icons.arrow_upward_rounded,
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
                        'Pay Cash',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: MfsColors.textPrimary,
                        ),
                      ),
                      Text(
                        'Record cash expense & receipt memo',
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

            // 3. Balance Context Card (Matte Black)
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
                          color: Colors.white,
                        ),
                      ),
                    ],
                  ),
                  const Icon(Icons.arrow_forward_rounded, color: MfsColors.primary, size: 20),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        'Remaining Balance',
                        style: TextStyle(
                          fontSize: 12,
                          color: remainingBalance < 0 ? MfsColors.primary : MfsColors.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        CurrencyFormatter.formatBdt(remainingBalance),
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: remainingBalance < 0 ? MfsColors.primary : Colors.white,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // 4. Balance Warning Banner (if amount > currentBalance)
            if (_isInsufficientBalance)
              Container(
                key: const Key('balance_warning_banner'),
                margin: const EdgeInsets.only(bottom: 16),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0x33DC143C),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: MfsColors.primary.withValues(alpha: 0.6)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.warning_amber_rounded, color: MfsColors.primary, size: 22),
                        SizedBox(width: 8),
                        Text(
                          'Insufficient Balance Warning',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Payment of ৳${_parsedAmount.toStringAsFixed(2)} exceeds current balance of ৳${widget.currentBalance.toStringAsFixed(2)} by ৳${(_parsedAmount - widget.currentBalance).toStringAsFixed(2)}.\nThis will cause a negative cash balance.',
                      style: const TextStyle(fontSize: 12.5, color: MfsColors.textSecondary),
                    ),
                    const SizedBox(height: 8),
                    InkWell(
                      key: const Key('negative_balance_override_toggle'),
                      onTap: () => setState(() => _allowNegativeOverride = !_allowNegativeOverride),
                      child: Row(
                        children: [
                          Checkbox(
                            value: _allowNegativeOverride,
                            activeColor: MfsColors.primary,
                            onChanged: (val) =>
                                setState(() => _allowNegativeOverride = val ?? false),
                          ),
                          const Expanded(
                            child: Text(
                              'I understand, allow negative ledger balance',
                              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.white),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

            // 5. Select Banknotes from Wallet
            if (_availableNotes.isNotEmpty) ...[
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.account_balance_wallet_outlined, color: MfsColors.primary, size: 18),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            'Select Note to Deduct (${_availableNotes.length} in wallet)',
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_selectedNoteIds.isNotEmpty)
                    TextButton(
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      onPressed: () {
                        setState(() {
                          _selectedNoteIds.clear();
                          _amountController.clear();
                          _noteNumberController.clear();
                          _parsedAmount = 0.0;
                        });
                      },
                      child: const Text('Clear', style: TextStyle(color: MfsColors.primary, fontSize: 12)),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _availableNotes.map((note) {
                  final isSelected = _selectedNoteIds.contains(note.txnid);
                  return InkWell(
                    key: Key('note_chip_${note.txnid}'),
                    onTap: () => _toggleNoteSelection(note),
                    borderRadius: BorderRadius.circular(14),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                        color: isSelected ? const Color(0x33DC143C) : MfsColors.surfaceVariant,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: isSelected ? MfsColors.primary : MfsColors.border,
                          width: isSelected ? 2.0 : 1.0,
                        ),
                        boxShadow: isSelected
                            ? [
                                const BoxShadow(
                                  color: Color(0x44DC143C),
                                  blurRadius: 8,
                                  spreadRadius: 1,
                                ),
                              ]
                            : null,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            isSelected ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                            color: isSelected ? MfsColors.primary : MfsColors.textSecondary,
                            size: 18,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            CurrencyFormatter.formatBdt(note.amount),
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                              color: isSelected ? Colors.white : MfsColors.cashIn,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.black45,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              note.txnid,
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 12,
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                }).toList(),
              ),
              const SizedBox(height: 16),
            ],

            // 6. Amount Input Field
            TextFormField(
              controller: _amountController,
              key: const Key('pay_amount_field'),
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
                hintText: '0.00',
                hintStyle: const TextStyle(color: MfsColors.textMuted, fontSize: 26),
                errorText: _errorMessage,
              ),
            ),
            const SizedBox(height: 16),

            // 7. Recipient Field
            TextFormField(
              controller: _recipientController,
              key: const Key('pay_recipient_field'),
              decoration: const InputDecoration(
                labelText: 'Recipient / Payee (Optional)',
                hintText: 'e.g. Rickshaw puller, Supermarket, Shop',
                prefixIcon: Icon(Icons.person_outline_rounded),
              ),
            ),
            const SizedBox(height: 14),

            // 8. Note Serial Number (TxnID) Field
            TextFormField(
              controller: _noteNumberController,
              key: const Key('pay_note_number_field'),
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
                suffixIcon: IconButton(
                  key: const Key('scan_banknote_pay_button'),
                  icon: const Icon(Icons.document_scanner_outlined, color: MfsColors.primary, size: 20),
                  tooltip: 'Scan Banknote Number',
                  onPressed: _openBanknoteScanner,
                ),
              ),
            ),
            const SizedBox(height: 16),

            // 9. Receipt Memo Photo Section
            const Text(
              'Receipt / Memo Photo',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.white),
            ),
            const SizedBox(height: 8),
            if (_capturedPhoto == null) ...[
              OutlinedButton.icon(
                key: const Key('take_receipt_photo_button'),
                onPressed: _isCapturingPhoto ? null : _captureReceiptPhoto,
                icon: _isCapturingPhoto
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2, color: MfsColors.primary),
                      )
                    : const Icon(Icons.camera_alt_outlined, color: MfsColors.primary),
                label: Text(
                  _isCapturingPhoto ? 'Opening Camera...' : 'Take Receipt / Memo Photo',
                  style: const TextStyle(fontWeight: FontWeight.w600, color: Colors.white),
                ),
                style: OutlinedButton.styleFrom(
                  backgroundColor: MfsColors.surfaceVariant,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  side: const BorderSide(color: MfsColors.border, width: 1.2),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
              ),
            ] else ...[
              Container(
                key: const Key('receipt_thumbnail_preview_card'),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: MfsColors.surfaceVariant,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: MfsColors.border),
                ),
                child: Row(
                  children: [
                    InkWell(
                      key: const Key('receipt_thumbnail_tap_target'),
                      onTap: _previewReceipt,
                      borderRadius: BorderRadius.circular(10),
                      child: SizedBox(
                        width: 72,
                        height: 72,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: Stack(
                            children: [
                              if (_cachedPhotoBytes != null)
                                Image.memory(
                                  _cachedPhotoBytes!,
                                  width: 72,
                                  height: 72,
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, __, ___) => Container(
                                    width: 72,
                                    height: 72,
                                    color: MfsColors.surface,
                                    child: const Icon(Icons.receipt_long, color: MfsColors.textSecondary),
                                  ),
                                )
                              else
                                Container(
                                  width: 72,
                                  height: 72,
                                  color: MfsColors.surface,
                                  child: const Icon(Icons.receipt_long, color: MfsColors.textSecondary),
                                ),
                              Positioned(
                                right: 2,
                                bottom: 2,
                                child: Container(
                                  padding: const EdgeInsets.all(2),
                                  decoration: const BoxDecoration(
                                    color: Colors.black87,
                                    shape: BoxShape.circle,
                                  ),
                                  child: const Icon(Icons.zoom_in, color: Colors.white, size: 14),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Row(
                            children: [
                              Icon(Icons.check_circle_rounded,
                                  color: MfsColors.cashIn, size: 16),
                              SizedBox(width: 6),
                              Text(
                                'Receipt Memo Attached',
                                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.white),
                              ),
                            ],
                          ),
                          if (_cachedPhotoBytes != null)
                            Text(
                              'Size: ${(_cachedPhotoBytes!.length / 1024).toStringAsFixed(1)} KB',
                              style: const TextStyle(fontSize: 11, color: MfsColors.textSecondary),
                            ),
                          const SizedBox(height: 6),
                          Row(
                            children: [
                              TextButton.icon(
                                key: const Key('retake_photo_button'),
                                onPressed: _isCapturingPhoto ? null : _captureReceiptPhoto,
                                icon: const Icon(Icons.refresh, size: 16, color: Colors.white),
                                label: const Text('Retake',
                                    style: TextStyle(fontSize: 12, color: Colors.white)),
                                style: TextButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                  minimumSize: Size.zero,
                                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                ),
                              ),
                              const SizedBox(width: 8),
                              TextButton.icon(
                                key: const Key('remove_photo_button'),
                                onPressed: _removeReceiptPhoto,
                                icon: const Icon(Icons.delete_outline,
                                    size: 16, color: MfsColors.primary),
                                label: const Text('Remove',
                                    style: TextStyle(fontSize: 12, color: MfsColors.primary)),
                                style: TextButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                  minimumSize: Size.zero,
                                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 16),

            // 10. Purpose Note Field
            TextFormField(
              controller: _notesController,
              key: const Key('pay_notes_field'),
              maxLength: 120,
              decoration: const InputDecoration(
                labelText: 'Purpose / Note (Optional)',
                hintText: 'e.g. Monthly bazaar or office lunch',
                prefixIcon: Icon(Icons.notes_rounded),
                counterText: '',
              ),
            ),
            const SizedBox(height: 24),

            // 11. Confirm Payment Button (Crimson Red)
            ElevatedButton(
              key: const Key('confirm_payment_button'),
              onPressed: _canSubmit ? _submitPayment : null,
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
                  : Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.payment_rounded, size: 20),
                        const SizedBox(width: 8),
                        Text(
                          _selectedNoteIds.isNotEmpty
                              ? 'Deduct ${_selectedNoteIds.length} Note(s) (${CurrencyFormatter.formatBdt(_parsedAmount)})'
                              : 'Confirm Payment',
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
