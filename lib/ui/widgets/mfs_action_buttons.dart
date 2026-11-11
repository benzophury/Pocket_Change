import 'package:flutter/material.dart';

import '../theme/mfs_colors.dart';

/// Quick action buttons bar (Add Money, Pay, Scan Banknote, Backup).
/// Styled in Matte Black with Crimson Red accents.
class MfsActionButtons extends StatelessWidget {
  final VoidCallback onAddMoney;
  final VoidCallback onPay;
  final VoidCallback onBackup;
  final VoidCallback? onScan;

  const MfsActionButtons({
    super.key,
    required this.onAddMoney,
    required this.onPay,
    required this.onBackup,
    this.onScan,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
      child: Row(
        children: [
          // 1. Add Cash Action Button
          Expanded(
            child: _buildActionButton(
              key: const ValueKey('action_add_money'),
              icon: Icons.add_circle_outline_rounded,
              label: 'Add Money',
              subtitle: 'Deposit',
              color: MfsColors.cashIn,
              bgColor: MfsColors.cashInLight,
              onTap: onAddMoney,
            ),
          ),
          const SizedBox(width: 8.0),

          // 2. Pay Action Button
          Expanded(
            child: _buildActionButton(
              key: const ValueKey('action_pay'),
              icon: Icons.payment_rounded,
              label: 'Pay',
              subtitle: 'Expense',
              color: MfsColors.primary,
              bgColor: MfsColors.primaryLight,
              onTap: onPay,
            ),
          ),
          const SizedBox(width: 8.0),

          // 3. Scan Banknote Button (if provided)
          if (onScan != null) ...[
            Expanded(
              child: _buildActionButton(
                key: const ValueKey('action_scan_banknote'),
                icon: Icons.document_scanner_rounded,
                label: 'Scan Note',
                subtitle: 'AI Reader',
                color: MfsColors.accent,
                bgColor: MfsColors.primaryLight,
                onTap: onScan!,
              ),
            ),
            const SizedBox(width: 8.0),
          ],

          // 4. Backup & Restore Action Button
          Expanded(
            child: _buildActionButton(
              key: const ValueKey('action_backup'),
              icon: Icons.cloud_sync_outlined,
              label: 'Backup',
              subtitle: 'Export',
              color: Colors.white70,
              bgColor: MfsColors.surfaceVariant,
              onTap: onBackup,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionButton({
    required Key key,
    required IconData icon,
    required String label,
    required String subtitle,
    required Color color,
    required Color bgColor,
    required VoidCallback onTap,
  }) {
    return Material(
      color: MfsColors.surface,
      borderRadius: BorderRadius.circular(16.0),
      elevation: 0,
      child: InkWell(
        key: key,
        onTap: onTap,
        borderRadius: BorderRadius.circular(16.0),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 14.0, horizontal: 6.0),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16.0),
            border: Border.all(color: MfsColors.border),
            boxShadow: MfsColors.cardShadow,
            color: MfsColors.surface,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(9.0),
                decoration: BoxDecoration(
                  color: bgColor,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  icon,
                  color: color,
                  size: 22.0,
                ),
              ),
              const SizedBox(height: 8.0),
              Text(
                label,
                style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 2.0),
              Text(
                subtitle,
                style: const TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w400,
                  color: MfsColors.textSecondary,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
