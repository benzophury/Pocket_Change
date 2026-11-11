import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../services/money_scanner_service.dart';
import '../theme/currency_formatter.dart';
import '../theme/mfs_colors.dart';

/// Modal bottom sheet for scanning physical banknotes with local on-device ML/AI.
/// Detects physical money denominations and extracts banknote serial numbers
/// to automatically populate the amount and transaction ID.
class MoneyScannerSheet extends StatefulWidget {
  final MoneyScannerService scannerService;
  final ImagePicker? imagePicker;
  final void Function(double amount, String? noteNumber, XFile? photo) onBanknoteDetected;

  const MoneyScannerSheet({
    super.key,
    required this.scannerService,
    required this.onBanknoteDetected,
    this.imagePicker,
  });

  /// Displays the [MoneyScannerSheet] in a modal bottom sheet.
  static Future<void> show(
    BuildContext context, {
    required MoneyScannerService scannerService,
    required void Function(double amount, String? noteNumber, XFile? photo) onBanknoteDetected,
    ImagePicker? imagePicker,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => MoneyScannerSheet(
        scannerService: scannerService,
        onBanknoteDetected: onBanknoteDetected,
        imagePicker: imagePicker,
      ),
    );
  }

  @override
  State<MoneyScannerSheet> createState() => _MoneyScannerSheetState();
}

class _MoneyScannerSheetState extends State<MoneyScannerSheet> {
  late final ImagePicker _picker;
  XFile? _capturedImage;
  BanknoteScanResult? _scanResult;
  bool _isProcessing = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _picker = widget.imagePicker ?? ImagePicker();
  }

  Future<void> _captureFromCamera() async {
    await _processImageSource(ImageSource.camera);
  }

  Future<void> _pickFromGallery() async {
    await _processImageSource(ImageSource.gallery);
  }

  Future<void> _processImageSource(ImageSource source) async {
    setState(() {
      _isProcessing = true;
      _errorMessage = null;
    });

    try {
      final XFile? photo = await _picker.pickImage(
        source: source,
        maxWidth: 2560,
        maxHeight: 2560,
        imageQuality: 92,
      );

      if (photo == null) {
        setState(() => _isProcessing = false);
        return;
      }

      setState(() => _capturedImage = photo);

      // Run on-device local AI banknote scan
      final result = await widget.scannerService.scanBanknote(photo);

      setState(() {
        _scanResult = result;
        _isProcessing = false;
        if (!result.hasDetection) {
          _errorMessage = 'No physical banknote detected. Hold note flat and fill the frame.';
        }
      });
    } catch (e) {
      setState(() {
        _isProcessing = false;
        _errorMessage = 'Scan error: $e';
      });
    }
  }

  void _applyResult() {
    if (_scanResult != null && _scanResult!.hasDetection) {
      Navigator.of(context).pop();
      widget.onBanknoteDetected(
        _scanResult!.totalAmount,
        _scanResult!.primarySerialNumber,
        _capturedImage,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
      decoration: const BoxDecoration(
        color: MfsColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        border: Border(top: BorderSide(color: MfsColors.primary, width: 2.5)),
        boxShadow: [
          BoxShadow(
            color: Color(0x66DC143C),
            blurRadius: 24,
            spreadRadius: 2,
            offset: Offset(0, -4),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Drag handle
          Center(
            child: Container(
              width: 48,
              height: 4,
              decoration: BoxDecoration(
                color: MfsColors.border,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Header
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: MfsColors.primaryLight,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: MfsColors.primary.withValues(alpha: 0.4)),
                ),
                child: const Icon(Icons.document_scanner_rounded, color: MfsColors.primary, size: 22),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'AI Banknote Scanner',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
                    ),
                    Text(
                      'Scan physical cash bill to detect amount and note number',
                      style: TextStyle(fontSize: 12, color: MfsColors.textSecondary),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close_rounded, color: Colors.white70),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
          const SizedBox(height: 20),

          // Viewfinder / Image Preview Area
          Container(
            height: 200,
            decoration: BoxDecoration(
              color: MfsColors.surfaceVariant,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: _scanResult?.hasDetection == true ? MfsColors.cashIn : MfsColors.border,
                width: 1.5,
              ),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(19),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  if (_capturedImage != null)
                    Image.file(
                      File(_capturedImage!.path),
                      width: double.infinity,
                      height: double.infinity,
                      fit: BoxFit.cover,
                    )
                  else
                    Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.crop_free_rounded,
                          size: 64,
                          color: MfsColors.primary.withValues(alpha: 0.8),
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          'Align physical banknote inside frame',
                          style: TextStyle(color: MfsColors.textSecondary, fontSize: 13),
                        ),
                      ],
                    ),

                  // Scanning spinner overlay
                  if (_isProcessing)
                    Container(
                      color: Colors.black.withValues(alpha: 0.65),
                      child: const Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            CircularProgressIndicator(color: MfsColors.primary, strokeWidth: 3),
                            SizedBox(height: 12),
                            Text(
                              'Analyzing physical cash with on-device AI...',
                              style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Error / Guidance Banner
          if (_errorMessage != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              margin: const EdgeInsets.only(bottom: 14),
              decoration: BoxDecoration(
                color: const Color(0x33DC143C),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: MfsColors.primary.withValues(alpha: 0.5)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.info_outline_rounded, color: MfsColors.primary, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _errorMessage!,
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),

          // Detection Results View
          if (_scanResult != null && _scanResult!.hasDetection) ...[
            Container(
              padding: const EdgeInsets.all(16),
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: const Color(0xFF1B1B1B),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: MfsColors.primary.withValues(alpha: 0.4)),
              ),
              child: Column(
                children: [
                  if (_scanResult!.totalAmount > 0)
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Total Cash Detected',
                          style: TextStyle(fontSize: 13, color: MfsColors.textSecondary),
                        ),
                        Text(
                          CurrencyFormatter.formatBdt(_scanResult!.totalAmount),
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            color: MfsColors.cashIn,
                          ),
                        ),
                      ],
                    )
                  else
                    const Row(
                      children: [
                        Icon(Icons.crop_free_rounded, color: MfsColors.primary, size: 16),
                        SizedBox(width: 8),
                        Text(
                          'Partial Note Detected (Serial Found)',
                          style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white70),
                        ),
                      ],
                    ),
                  if (_scanResult!.primarySerialNumber != null) ...[
                    if (_scanResult!.totalAmount > 0)
                      const Divider(height: 20, color: MfsColors.border),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Row(
                          children: [
                            Icon(Icons.tag_rounded, color: MfsColors.primary, size: 16),
                            SizedBox(width: 6),
                            Text(
                              'Banknote Number',
                              style: TextStyle(fontSize: 12, color: MfsColors.textSecondary),
                            ),
                          ],
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: MfsColors.surfaceVariant,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: MfsColors.border),
                          ),
                          child: Text(
                            _scanResult!.primarySerialNumber!,
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],

          // Action Buttons
          if (_scanResult == null || !_scanResult!.hasDetection)
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    key: const Key('camera_scan_button'),
                    onPressed: _isProcessing ? null : _captureFromCamera,
                    icon: const Icon(Icons.camera_alt_outlined),
                    label: const Text('Camera Scan'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: MfsColors.primary,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    key: const Key('gallery_scan_button'),
                    onPressed: _isProcessing ? null : _pickFromGallery,
                    icon: const Icon(Icons.photo_library_outlined, color: Colors.white),
                    label: const Text('Pick Image', style: TextStyle(color: Colors.white)),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: MfsColors.border),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                  ),
                ),
              ],
            )
          else ...[
            ElevatedButton.icon(
              key: const Key('apply_scanned_money_button'),
              onPressed: _applyResult,
              icon: const Icon(Icons.check_circle_rounded),
              label: Text(
                _scanResult!.totalAmount > 0 && _scanResult!.primarySerialNumber != null
                    ? 'Apply ${CurrencyFormatter.formatBdt(_scanResult!.totalAmount)} & Note #'
                    : _scanResult!.primarySerialNumber != null
                        ? 'Apply Note # (${_scanResult!.primarySerialNumber})'
                        : 'Apply ${CurrencyFormatter.formatBdt(_scanResult!.totalAmount)} to Ledger',
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: MfsColors.primary,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              ),
            ),
            const SizedBox(height: 10),
            TextButton(
              onPressed: _captureFromCamera,
              child: const Text('Scan Another Note', style: TextStyle(color: MfsColors.textSecondary)),
            ),
          ],
        ],
      ),
    );
  }
}
