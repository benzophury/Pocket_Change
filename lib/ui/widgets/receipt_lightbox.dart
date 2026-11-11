import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';

import '../../models/transaction_item.dart';
import '../../services/receipt_service.dart';

/// Fullscreen lightbox dialog for viewing receipt memo photos with InteractiveViewer
/// pinch-to-zoom, transaction metadata header/footer, copy txnid, and share action.
class ReceiptLightbox extends StatefulWidget {
  final TransactionItem transaction;
  final File? imageFile;
  final Uint8List? imageBytes;
  final ReceiptService? receiptService;
  final Future<void> Function(String filePath, String text)? onShare;
  final Future<void> Function(TransactionItem txn)? onDelete;

  const ReceiptLightbox({
    super.key,
    required this.transaction,
    this.imageFile,
    this.imageBytes,
    this.receiptService,
    this.onShare,
    this.onDelete,
  });

  /// Static presentation helper.
  static Future<void> show(
    BuildContext context, {
    required TransactionItem transaction,
    File? imageFile,
    Uint8List? imageBytes,
    ReceiptService? receiptService,
    Future<void> Function(String filePath, String text)? onShare,
    Future<void> Function(TransactionItem txn)? onDelete,
  }) {
    return showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.92),
      builder: (ctx) => ReceiptLightbox(
        transaction: transaction,
        imageFile: imageFile,
        imageBytes: imageBytes,
        receiptService: receiptService,
        onShare: onShare,
        onDelete: onDelete,
      ),
    );
  }

  @override
  State<ReceiptLightbox> createState() => _ReceiptLightboxState();
}

class _ReceiptLightboxState extends State<ReceiptLightbox> {
  final TransformationController _transformationController = TransformationController();
  File? _resolvedFile;
  bool _isLoading = true;
  bool _loadFailed = false;

  @override
  void initState() {
    super.initState();
    _resolveImage();
  }

  @override
  void didUpdateWidget(ReceiptLightbox oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.imageBytes != oldWidget.imageBytes ||
        widget.imageFile != oldWidget.imageFile ||
        widget.transaction.memoPhotoPath != oldWidget.transaction.memoPhotoPath) {
      _resolveImage();
    }
  }

  @override
  void dispose() {
    _transformationController.dispose();
    super.dispose();
  }

  Future<void> _resolveImage() async {
    if (widget.imageBytes != null || widget.imageFile != null) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _loadFailed = false;
        });
      }
      return;
    }

    final path = widget.transaction.memoPhotoPath;
    if (path == null || path.trim().isEmpty) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _loadFailed = true;
        });
      }
      return;
    }

    try {
      final service = widget.receiptService ?? ReceiptService.instance;
      final file = await service.getReceiptFile(path);
      if (mounted) {
        setState(() {
          _resolvedFile = file;
          _isLoading = false;
          _loadFailed = file == null || !file.existsSync();
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _loadFailed = true;
        });
      }
    }
  }

  void _copyTxnId() {
    Clipboard.setData(ClipboardData(text: widget.transaction.txnid));
    HapticFeedback.selectionClick();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Transaction ID copied: ${widget.transaction.txnid}'),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _handleShare() async {
    final filePath = _resolvedFile?.path ?? widget.imageFile?.path;
    final shareText =
        'Pocket Change Receipt - TxnID: ${widget.transaction.txnid}, Amount: ৳${widget.transaction.amount.toStringAsFixed(2)}';

    if (widget.onShare != null) {
      if (filePath != null) {
        await widget.onShare!(filePath, shareText);
      }
      return;
    }

    if (filePath != null && File(filePath).existsSync()) {
      try {
        await Share.shareXFiles([XFile(filePath)], text: shareText);
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Share failed: $e')),
          );
        }
      }
    } else {
      await Share.share(shareText);
    }
  }

  void _resetZoom() {
    _transformationController.value = Matrix4.identity();
  }

  @override
  Widget build(BuildContext context) {
    final txn = widget.transaction;
    final isAdd = txn.type == TransactionType.add;
    final formattedTime = DateFormat('dd MMM yyyy, hh:mm a').format(txn.timestamp);

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          key: const Key('lightbox_close_button'),
          icon: const Icon(Icons.close_rounded, color: Colors.white, size: 28),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text(
          'Receipt Memo',
          style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w600),
        ),
        actions: [
          IconButton(
            key: const Key('lightbox_reset_zoom_button'),
            icon: const Icon(Icons.fit_screen_rounded, color: Colors.white),
            tooltip: 'Reset Zoom',
            onPressed: _resetZoom,
          ),
          IconButton(
            key: const Key('lightbox_share_button'),
            icon: const Icon(Icons.share_rounded, color: Colors.white),
            tooltip: 'Share Receipt',
            onPressed: _handleShare,
          ),
          if (widget.onDelete != null)
            IconButton(
              key: const Key('lightbox_delete_button'),
              icon: const Icon(Icons.delete_outline_rounded, color: Colors.white70),
              tooltip: 'Delete Transaction',
              onPressed: () async {
                final confirm = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    backgroundColor: const Color(0xFF1E1E1E),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                      side: const BorderSide(color: Colors.white24),
                    ),
                    title: const Text(
                      'Delete Transaction?',
                      style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                    ),
                    content: Text(
                      'Permanently delete transaction ${txn.txnid}?',
                      style: const TextStyle(color: Colors.white70),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.of(ctx).pop(false),
                        child: const Text('Cancel', style: TextStyle(color: Colors.white60)),
                      ),
                      ElevatedButton(
                        key: const Key('lightbox_confirm_delete_button'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFDC143C),
                          foregroundColor: Colors.white,
                        ),
                        onPressed: () => Navigator.of(ctx).pop(true),
                        child: const Text('Delete'),
                      ),
                    ],
                  ),
                );
                if (confirm == true && context.mounted) {
                  Navigator.of(context).pop();
                  await widget.onDelete!(txn);
                }
              },
            ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            // Center: Interactive Viewer with Pinch-to-Zoom
            Expanded(
              child: Center(
                child: _isLoading
                    ? const CircularProgressIndicator(color: Colors.white)
                    : _loadFailed
                        ? _buildCorruptedFallback(txn)
                        : InteractiveViewer(
                            key: const Key('receipt_interactive_viewer'),
                            transformationController: _transformationController,
                            minScale: 0.5,
                            maxScale: 5.0,
                            clipBehavior: Clip.none,
                            child: _buildImageWidget(),
                          ),
              ),
            ),

            // Bottom: Transaction Details Footer Card
            Container(
              margin: const EdgeInsets.all(16),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF1E1E1E).withValues(alpha: 0.95),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.white12),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Row 1: TxnID Chip with Copy Button & Type Badge
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      InkWell(
                        key: const Key('lightbox_copy_txnid_chip'),
                        onTap: _copyTxnId,
                        borderRadius: BorderRadius.circular(8),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                          decoration: BoxDecoration(
                            color: Colors.white10,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.tag_rounded, color: Colors.white70, size: 14),
                              const SizedBox(width: 4),
                              Text(
                                txn.txnid,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontFamily: 'monospace',
                                  fontSize: 13,
                                ),
                              ),
                              const SizedBox(width: 6),
                              const Icon(Icons.copy_rounded, color: Colors.white54, size: 14),
                            ],
                          ),
                        ),
                      ),
                      // Type Badge
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: isAdd ? const Color(0xFF2E7D32) : const Color(0xFFD32F2F),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          isAdd ? 'ADD MONEY' : 'PAYMENT',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),

                  // Row 2: Amount & Timestamp
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        '${isAdd ? '+' : '-'}৳${txn.amount.toStringAsFixed(2)}',
                        style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                          color: isAdd ? const Color(0xFF81C784) : const Color(0xFFE57373),
                        ),
                      ),
                      Text(
                        formattedTime,
                        style: const TextStyle(color: Colors.white60, fontSize: 12),
                      ),
                    ],
                  ),

                  // Row 3: Category & Notes (if available)
                  if (txn.category != null || txn.notes != null) ...[
                    const Divider(color: Colors.white12, height: 20),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (txn.category != null)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                            margin: const EdgeInsets.only(right: 8),
                            decoration: BoxDecoration(
                              color: Colors.white12,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              txn.category!,
                              style: const TextStyle(color: Colors.white70, fontSize: 11),
                            ),
                          ),
                        if (txn.notes != null)
                          Expanded(
                            child: Text(
                              txn.notes!,
                              style: const TextStyle(color: Colors.white, fontSize: 13),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildImageWidget() {
    if (widget.imageBytes != null) {
      return Image.memory(
        widget.imageBytes!,
        fit: BoxFit.contain,
        errorBuilder: (_, __, ___) => _buildCorruptedFallback(widget.transaction),
      );
    }

    final file = _resolvedFile ?? widget.imageFile;
    if (file != null && file.existsSync()) {
      return Image.file(
        file,
        fit: BoxFit.contain,
        errorBuilder: (_, __, ___) => _buildCorruptedFallback(widget.transaction),
      );
    }

    return _buildCorruptedFallback(widget.transaction);
  }

  Widget _buildCorruptedFallback(TransactionItem txn) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 32),
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white10,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white24),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.broken_image_rounded,
            color: Colors.amber,
            size: 64,
          ),
          const SizedBox(height: 16),
          const Text(
            'Receipt Image Unavailable',
            style: TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            'The receipt photo for transaction ${txn.txnid} could not be loaded or was removed from local storage.',
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 13,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}
