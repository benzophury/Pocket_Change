import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../../models/transaction_item.dart';
import '../../services/receipt_service.dart';
import '../theme/currency_formatter.dart';
import '../theme/mfs_colors.dart';

/// Single transaction tile displaying type avatar, note description,
/// copyable monospace Note Number / TxnID chip, receipt thumbnail with camera badge,
/// and formatted BDT amount. Styled in Matte Black & Crimson Red.
class TransactionTile extends StatelessWidget {
  final TransactionItem transaction;
  final VoidCallback? onTap;
  final VoidCallback? onTapReceipt;
  final Future<File?> Function(String? path)? fileResolver;

  const TransactionTile({
    super.key,
    required this.transaction,
    this.onTap,
    this.onTapReceipt,
    this.fileResolver,
  });

  @override
  Widget build(BuildContext context) {
    final isAdd = transaction.isAdd;
    final colorScheme = isAdd ? MfsColors.cashIn : MfsColors.primary;
    final bgColor = isAdd ? MfsColors.cashInLight : MfsColors.primaryLight;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            // 1. Type indicator avatar
            CircleAvatar(
              radius: 20,
              backgroundColor: bgColor,
              child: Icon(
                isAdd ? Icons.south_west_rounded : Icons.north_east_rounded,
                color: colorScheme,
                size: 20,
              ),
            ),
            const SizedBox(width: 12),

            // 2. Title, Note/TxnID chip, and Timestamp
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    transaction.notes?.isNotEmpty == true
                        ? transaction.notes!
                        : (isAdd ? 'Cash Deposit' : 'Cash Expense'),
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 15,
                      color: Colors.white,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      // Monospace Banknote Serial Number / TxnID Chip with tap-to-copy
                      InkWell(
                        key: ValueKey('copy_txnid_${transaction.txnid}'),
                        onTap: () {
                          Clipboard.setData(ClipboardData(text: transaction.txnid));
                          HapticFeedback.selectionClick();
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text('Copied TrxID: ${transaction.txnid}'),
                              duration: const Duration(seconds: 2),
                              behavior: SnackBarBehavior.floating,
                            ),
                          );
                        },
                        borderRadius: BorderRadius.circular(4),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: MfsColors.surfaceVariant,
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(color: MfsColors.border, width: 0.8),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                transaction.txnid,
                                style: const TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 11,
                                  color: Colors.white70,
                                ),
                              ),
                              const SizedBox(width: 4),
                              const Icon(Icons.copy_rounded, size: 11, color: MfsColors.textSecondary),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '• ${DateFormat('hh:mm a').format(transaction.timestamp)}',
                        style: const TextStyle(fontSize: 12, color: MfsColors.textSecondary),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),

            // 3. Receipt thumbnail (if present)
            if (transaction.hasMemoPhoto) ...[
              GestureDetector(
                key: ValueKey('receipt_thumb_${transaction.txnid}'),
                onTap: onTapReceipt,
                child: Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: MfsColors.border),
                    color: MfsColors.surfaceVariant,
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: FutureBuilder<File?>(
                          future: fileResolver != null
                              ? fileResolver!(transaction.memoPhotoPath)
                              : ReceiptService.instance.getReceiptFile(transaction.memoPhotoPath),
                          builder: (context, snapshot) {
                            if (snapshot.connectionState == ConnectionState.done &&
                                snapshot.data != null &&
                                snapshot.data!.existsSync()) {
                              return Image.file(
                                snapshot.data!,
                                fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) =>
                                    const Icon(Icons.receipt_long, color: MfsColors.textSecondary, size: 20),
                              );
                            }
                            return const Center(
                              child: Icon(Icons.receipt_long, color: MfsColors.textSecondary, size: 20),
                            );
                          },
                        ),
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
                          child: const Icon(Icons.camera_alt, color: Colors.white, size: 8),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 10),
            ],

            // 4. Amount with sign and BDT symbol
            Text(
              CurrencyFormatter.formatSignedBdt(
                transaction.amount,
                type: transaction.type,
              ),
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 15,
                color: colorScheme,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
