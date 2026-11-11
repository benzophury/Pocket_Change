import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';

import '../../controllers/ledger_controller.dart';
import '../../models/transaction_item.dart';
import '../../services/money_scanner_service.dart';
import '../../utils/txnid_generator.dart';
import '../theme/currency_formatter.dart';
import '../theme/mfs_colors.dart';
import '../widgets/mfs_action_buttons.dart';
import '../widgets/mfs_balance_card.dart';
import '../widgets/receipt_lightbox.dart';
import '../widgets/transaction_tile.dart';
import 'add_money_sheet.dart';
import 'backup_restore_screen.dart';
import 'pay_sheet.dart';

/// Represents a list of transactions grouped under a common date label.
class DateGroupedTransactions {
  final String label;
  final DateTime date;
  final List<TransactionItem> transactions;
  final double netCashFlow;

  const DateGroupedTransactions({
    required this.label,
    required this.date,
    required this.transactions,
    required this.netCashFlow,
  });

  /// Factory helper that groups a flat list of [transactions] into chronologically
  /// sorted date buckets ('Today', 'Yesterday', or 'dd MMM yyyy').
  static List<DateGroupedTransactions> fromList(
    List<TransactionItem> transactions, {
    DateTime? now,
  }) {
    if (transactions.isEmpty) return const [];

    final reference = now ?? DateTime.now();
    final today = DateTime(reference.year, reference.month, reference.day);
    final yesterday = today.subtract(const Duration(days: 1));

    // Sort transactions descending by timestamp
    final sorted = List<TransactionItem>.from(transactions)
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));

    final Map<DateTime, List<TransactionItem>> map = {};

    for (final txn in sorted) {
      final d = DateTime(txn.timestamp.year, txn.timestamp.month, txn.timestamp.day);
      map.putIfAbsent(d, () => []).add(txn);
    }

    final List<DateGroupedTransactions> groups = [];

    for (final entry in map.entries) {
      final dateKey = entry.key;
      final txns = entry.value;

      String label;
      if (dateKey == today) {
        label = 'Today';
      } else if (dateKey == yesterday) {
        label = 'Yesterday';
      } else {
        label = DateFormat('dd MMM yyyy').format(dateKey);
      }

      final netFlow = txns.fold<double>(0.0, (acc, item) {
        return acc + (item.isAdd ? item.amount : -item.amount);
      });

      groups.add(
        DateGroupedTransactions(
          label: label,
          date: dateKey,
          transactions: txns,
          netCashFlow: netFlow,
        ),
      );
    }

    return groups;
  }
}

/// Main dashboard screen for Pocket Change digital cash ledger.
/// Styled in Matte Black with Crimson Red accents.
class DashboardScreen extends StatefulWidget {
  final LedgerController? controller;
  final Future<File?> Function(String? path)? fileResolver;
  final PhotoCaptureProvider? photoCaptureProvider;
  final MoneyScannerService? moneyScannerService;

  const DashboardScreen({
    super.key,
    this.controller,
    this.fileResolver,
    this.photoCaptureProvider,
    this.moneyScannerService,
  });

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  LedgerController get _effectiveController {
    if (widget.controller != null) return widget.controller!;
    return LedgerScope.of(context);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        widget.controller?.loadLedger();
      }
    });
  }

  Future<void> _openAddMoney(BuildContext context, LedgerController controller) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final photoProvider = widget.photoCaptureProvider ?? defaultCameraCaptureProvider;
      final XFile? photo = await photoProvider();

      if (photo == null) {
        // User cancelled camera capture: present manual entry
        if (!context.mounted) return;
        await _showManualAddMoney(context, controller);
        return;
      }

      // Show quick scanning status
      messenger.showSnackBar(
        const SnackBar(
          content: Row(
            children: [
              Icon(Icons.document_scanner_rounded, size: 18, color: MfsColors.primary),
              SizedBox(width: 12),
              Text('Scanning banknote...'),
            ],
          ),
          duration: Duration(seconds: 4),
          behavior: SnackBarBehavior.floating,
          backgroundColor: Color(0xFF1F1F1F),
        ),
      );

      final scanner = widget.moneyScannerService ?? MoneyScannerService();
      final result = await scanner.scanBanknote(photo);

      messenger.removeCurrentSnackBar();

      if (result.hasDetection && result.totalAmount > 0) {
        // Detection successful: auto-add itself!
        final txnid = result.primarySerialNumber ?? TxnIdGenerator.generate(prefix: 'TXN');
        final txn = TransactionItem(
          txnid: txnid,
          type: TransactionType.add,
          amount: result.totalAmount,
          timestamp: DateTime.now(),
          notes: result.primarySerialNumber != null
              ? 'Banknote: ${result.primarySerialNumber}'
              : 'Cash Deposit',
        );

        await controller.dbHelper.insertTransaction(txn);
        await controller.loadLedger();
        HapticFeedback.mediumImpact();

        messenger.showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(Icons.check_circle_rounded, color: MfsColors.cashIn, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Added ${CurrencyFormatter.formatBdt(result.totalAmount)} (${txn.txnid})',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            action: SnackBarAction(
              label: 'UNDO',
              textColor: Colors.amber,
              onPressed: () async {
                await controller.deleteTransaction(txn);
              },
            ),
            backgroundColor: const Color(0xFF1F1F1F),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: const BorderSide(color: MfsColors.cashIn, width: 1.5),
            ),
            duration: const Duration(seconds: 4),
          ),
        );
      } else {
        // Scan not successful or partial 0 denomination: present manual entry with prefilled data
        messenger.showSnackBar(
          const SnackBar(
            content: Text('Could not auto-detect note. Please enter amount manually.'),
            duration: Duration(seconds: 3),
            behavior: SnackBarBehavior.floating,
          ),
        );
        if (context.mounted) {
          await _showManualAddMoney(
            context,
            controller,
            initialAmount: result.totalAmount > 0 ? result.totalAmount : null,
            initialNoteNumber: result.primarySerialNumber,
          );
        }
      }
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Camera error: $e')),
      );
      if (context.mounted) {
        await _showManualAddMoney(context, controller);
      }
    }
  }

  Future<void> _showManualAddMoney(
    BuildContext context,
    LedgerController controller, {
    double? initialAmount,
    String? initialNoteNumber,
  }) async {
    await AddMoneySheet.show(
      context,
      currentBalance: controller.balance,
      databaseHelper: controller.dbHelper,
      moneyScannerService: widget.moneyScannerService,
      initialAmount: initialAmount,
      initialNoteNumber: initialNoteNumber,
      onAddCompleted: (txn) async {
        await controller.loadLedger();
      },
    );
  }

  Future<bool> _confirmDeleteTransaction(
    BuildContext context,
    TransactionItem txn,
    LedgerController controller,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: MfsColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: const BorderSide(color: MfsColors.border),
        ),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: MfsColors.primaryLight,
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.delete_outline_rounded, color: MfsColors.primary, size: 22),
            ),
            const SizedBox(width: 12),
            const Text(
              'Delete Transaction?',
              style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ],
        ),
        content: Text(
          'Are you sure you want to delete this ${txn.isAdd ? 'deposit' : 'payment'} of ${CurrencyFormatter.formatBdt(txn.amount)}?\n\nTrxID: ${txn.txnid}',
          style: const TextStyle(color: Colors.white70, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel', style: TextStyle(color: Colors.white60)),
          ),
          ElevatedButton(
            key: const ValueKey('confirm_delete_transaction_button'),
            style: ElevatedButton.styleFrom(
              backgroundColor: MfsColors.primary,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await controller.deleteTransaction(txn);
      HapticFeedback.mediumImpact();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Deleted transaction ${txn.txnid}'),
            backgroundColor: const Color(0xFF262626),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return true;
    }
    return false;
  }

  void _showTransactionDetails(
    BuildContext context,
    TransactionItem txn,
    LedgerController controller,
  ) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
        decoration: const BoxDecoration(
          color: MfsColors.surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          border: Border(top: BorderSide(color: MfsColors.border, width: 1.5)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: MfsColors.border,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    CircleAvatar(
                      radius: 18,
                      backgroundColor: txn.isAdd ? MfsColors.cashInLight : MfsColors.primaryLight,
                      child: Icon(
                        txn.isAdd ? Icons.south_west_rounded : Icons.north_east_rounded,
                        color: txn.isAdd ? MfsColors.cashIn : MfsColors.primary,
                        size: 18,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      txn.isAdd ? 'Cash Deposit' : 'Cash Expense',
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
                    ),
                  ],
                ),
                Text(
                  CurrencyFormatter.formatSignedBdt(txn.amount, type: txn.type),
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: txn.isAdd ? MfsColors.cashIn : MfsColors.primary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: MfsColors.surfaceVariant,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: MfsColors.border),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('TrxID / Note #', style: TextStyle(fontSize: 12, color: MfsColors.textSecondary)),
                      InkWell(
                        onTap: () {
                          Clipboard.setData(ClipboardData(text: txn.txnid));
                          HapticFeedback.selectionClick();
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('Copied: ${txn.txnid}')),
                          );
                        },
                        child: Row(
                          children: [
                            Text(
                              txn.txnid,
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                                fontSize: 13,
                              ),
                            ),
                            const SizedBox(width: 4),
                            const Icon(Icons.copy_rounded, size: 13, color: Colors.white70),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Time', style: TextStyle(fontSize: 12, color: MfsColors.textSecondary)),
                      Text(
                        DateFormat('dd MMM yyyy, hh:mm a').format(txn.timestamp),
                        style: const TextStyle(fontSize: 12, color: Colors.white70),
                      ),
                    ],
                  ),
                  if (txn.notes != null && txn.notes!.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Notes', style: TextStyle(fontSize: 12, color: MfsColors.textSecondary)),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Text(
                            txn.notes!,
                            textAlign: TextAlign.right,
                            style: const TextStyle(fontSize: 12, color: Colors.white70),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 20),
            ElevatedButton.icon(
              key: const ValueKey('delete_transaction_tile_button'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0x33DC143C),
                foregroundColor: MfsColors.primary,
                side: const BorderSide(color: MfsColors.primary, width: 1.5),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              onPressed: () async {
                Navigator.of(ctx).pop();
                await _confirmDeleteTransaction(context, txn, controller);
              },
              icon: const Icon(Icons.delete_outline_rounded, size: 20),
              label: const Text('Delete Transaction', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
            ),
          ],
        ),
      ),
    );
  }

  void _openPay(BuildContext context, LedgerController controller) {
    PaySheet.show(
      context,
      currentBalance: controller.balance,
      photoCaptureProvider: widget.photoCaptureProvider,
      receiptService: controller.receiptService,
      databaseHelper: controller.dbHelper,
      moneyScannerService: widget.moneyScannerService,
      onPaymentSubmitted: (txn) async {
        await controller.loadLedger();
      },
    );
  }

  void _openBackup(BuildContext context, LedgerController controller) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => BackupRestoreScreen(controller: controller),
      ),
    );
  }

  void _openLightbox(BuildContext context, TransactionItem txn, LedgerController controller) {
    ReceiptLightbox.show(
      context,
      transaction: txn,
      receiptService: controller.receiptService,
      onDelete: (item) async {
        await controller.deleteTransaction(item);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Deleted transaction ${item.txnid}'),
              backgroundColor: const Color(0xFF262626),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = _effectiveController;

    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final grouped = DateGroupedTransactions.fromList(controller.transactions);

        return Scaffold(
          backgroundColor: MfsColors.background,
          appBar: AppBar(
            backgroundColor: MfsColors.surface,
            elevation: 0,
            title: const Row(
              children: [
                CircleAvatar(
                  radius: 16,
                  backgroundColor: MfsColors.primaryLight,
                  child: Icon(Icons.wallet, color: MfsColors.primary, size: 18),
                ),
                SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Pocket Change',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        'Digital Cash Ledger',
                        style: TextStyle(
                          fontSize: 11,
                          color: MfsColors.textSecondary,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            actions: [
              IconButton(
                key: const ValueKey('dashboard_backup_icon_button'),
                icon: const Icon(Icons.cloud_sync_outlined, color: Colors.white),
                tooltip: 'Backup & Restore',
                onPressed: () => _openBackup(context, controller),
              ),
            ],
          ),
          body: RefreshIndicator(
            onRefresh: () => controller.loadLedger(),
            color: MfsColors.primary,
            child: CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                // 1. Balance Privacy Card
                SliverToBoxAdapter(
                  child: MfsBalanceCard(
                    balance: controller.balance,
                    totalIn: controller.totalIn,
                    totalOut: controller.totalOut,
                  ),
                ),

                // 2. Action Buttons (Add Cash, Pay, Backup)
                SliverToBoxAdapter(
                  child: MfsActionButtons(
                    onAddMoney: () => _openAddMoney(context, controller),
                    onPay: () => _openPay(context, controller),
                    onBackup: () => _openBackup(context, controller),
                  ),
                ),

                // 3. Transactions Section Header
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Transactions',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: MfsColors.surfaceVariant,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: MfsColors.border),
                          ),
                          child: Text(
                            '${controller.totalCount} total',
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: MfsColors.textSecondary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                // 4. Empty State or Date-Grouped Transaction List
                if (controller.isEmpty)
                  SliverToBoxAdapter(
                    child: MfsEmptyFeedView(
                      onAddMoneyPressed: () => _openAddMoney(context, controller),
                    ),
                  )
                else
                  SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (context, groupIndex) {
                        final group = grouped[groupIndex];
                        return _buildDateGroup(context, group, controller);
                      },
                      childCount: grouped.length,
                    ),
                  ),

                const SliverToBoxAdapter(
                  child: SizedBox(height: 32),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildDateGroup(
    BuildContext context,
    DateGroupedTransactions group,
    LedgerController controller,
  ) {
    final isNetPositive = group.netCashFlow >= 0;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: BoxDecoration(
        color: MfsColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: MfsColors.border),
        boxShadow: MfsColors.cardShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Date Group Header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: const BoxDecoration(
              color: MfsColors.surfaceVariant,
              borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
              border: Border(bottom: BorderSide(color: MfsColors.border)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    const Icon(Icons.calendar_today_rounded, size: 14, color: MfsColors.textSecondary),
                    const SizedBox(width: 6),
                    Text(
                      group.label,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: isNetPositive ? MfsColors.cashInLight : MfsColors.primaryLight,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: isNetPositive
                          ? MfsColors.cashIn.withValues(alpha: 0.3)
                          : MfsColors.primary.withValues(alpha: 0.3),
                    ),
                  ),
                  child: Text(
                    'Net: ${isNetPositive ? '+' : '-'}${CurrencyFormatter.formatBdt(group.netCashFlow.abs())}',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: isNetPositive ? MfsColors.cashIn : MfsColors.primary,
                    ),
                  ),
                ),
              ],
            ),
          ),

          // Transaction items in this date group
          ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: group.transactions.length,
            separatorBuilder: (_, __) => const Divider(height: 1, color: MfsColors.divider),
            itemBuilder: (context, itemIndex) {
              final txn = group.transactions[itemIndex];
              return Dismissible(
                key: ValueKey('dismiss_txn_${txn.txnid}'),
                direction: DismissDirection.endToStart,
                confirmDismiss: (_) => _confirmDeleteTransaction(context, txn, controller),
                background: Container(
                  alignment: Alignment.centerRight,
                  padding: const EdgeInsets.only(right: 20),
                  color: MfsColors.primary,
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Icon(Icons.delete_sweep_rounded, color: Colors.white, size: 24),
                      SizedBox(width: 6),
                      Text('Delete', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                    ],
                  ),
                ),
                child: TransactionTile(
                  transaction: txn,
                  fileResolver: widget.fileResolver ?? controller.getReceiptFile,
                  onTap: () {
                    if (txn.hasMemoPhoto) {
                      _openLightbox(context, txn, controller);
                    } else {
                      _showTransactionDetails(context, txn, controller);
                    }
                  },
                  onTapReceipt: () => _openLightbox(context, txn, controller),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

/// Clean empty state card shown when transaction history has 0 records.
class MfsEmptyFeedView extends StatelessWidget {
  final VoidCallback onAddMoneyPressed;

  const MfsEmptyFeedView({super.key, required this.onAddMoneyPressed});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: MfsColors.primaryLight,
                shape: BoxShape.circle,
                border: Border.all(color: MfsColors.primary.withValues(alpha: 0.4)),
              ),
              child: const Icon(
                Icons.account_balance_wallet_outlined,
                size: 40,
                color: MfsColors.primary,
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'No transactions yet',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Your cash ledger is empty. Tap Add Cash to record physical cash in hand or scan a banknote bill.',
              textAlign: TextAlign.center,
              style: TextStyle(color: MfsColors.textSecondary, fontSize: 13),
            ),
            const SizedBox(height: 20),
            ElevatedButton.icon(
              onPressed: onAddMoneyPressed,
              icon: const Icon(Icons.add),
              label: const Text('Add Cash'),
              style: ElevatedButton.styleFrom(
                backgroundColor: MfsColors.primary,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
