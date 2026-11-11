import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/currency_formatter.dart';
import '../theme/mfs_colors.dart';

/// "Tap for Balance" privacy card styled in Matte Black & Crimson Red.
///
/// Features:
/// - Sleek matte black surface with subtle crimson accent border.
/// - Privacy pill button hiding balance by default.
/// - Smooth animated reveal transition with haptic feedback.
/// - Exact 4-second auto-hide timer that resets on re-tap.
/// - Financial cash flow summary strip (Total In / Total Out).
/// - Clean English typography (no MFS or Bengali text).
class MfsBalanceCard extends StatefulWidget {
  /// Current net ledger balance.
  final double balance;

  /// Aggregated cash added to ledger.
  final double totalIn;

  /// Aggregated cash paid from ledger.
  final double totalOut;

  /// Duration before revealed balance automatically hides. Default: 4 seconds.
  final Duration autoHideDuration;

  /// Whether to trigger device vibration on pill tap.
  final bool enableHaptics;

  /// Optional callback invoked whenever balance is revealed.
  final VoidCallback? onBalanceRevealed;

  const MfsBalanceCard({
    super.key,
    required this.balance,
    this.totalIn = 0.0,
    this.totalOut = 0.0,
    this.autoHideDuration = const Duration(seconds: 4),
    this.enableHaptics = true,
    this.onBalanceRevealed,
  });

  @override
  State<MfsBalanceCard> createState() => _MfsBalanceCardState();
}

class _MfsBalanceCardState extends State<MfsBalanceCard> {
  bool _isRevealed = false;
  Timer? _autoHideTimer;

  @override
  void dispose() {
    _autoHideTimer?.cancel();
    super.dispose();
  }

  void _handlePillTap() {
    if (widget.enableHaptics) {
      HapticFeedback.lightImpact();
    }

    if (!_isRevealed) {
      widget.onBalanceRevealed?.call();
    }

    setState(() {
      _isRevealed = true;
    });

    // Reset or start 4-second auto-hide timer
    _autoHideTimer?.cancel();
    _autoHideTimer = Timer(widget.autoHideDuration, () {
      if (mounted) {
        setState(() {
          _isRevealed = false;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
      padding: const EdgeInsets.all(20.0),
      decoration: BoxDecoration(
        color: MfsColors.surface,
        borderRadius: BorderRadius.circular(20.0),
        border: Border.all(color: MfsColors.border, width: 1.2),
        boxShadow: MfsColors.cardElevatedShadow,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 1. Top Header Row: Wallet Icon & Title
          _buildHeaderRow(),

          const SizedBox(height: 18.0),

          // 2. Interactive "Tap for Balance" Pill Button
          _buildTapForBalancePill(),

          const SizedBox(height: 20.0),

          // 3. Bottom Summary Strip: Total In & Total Out
          _buildSummaryStrip(),
        ],
      ),
    );
  }

  Widget _buildHeaderRow() {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(8.0),
          decoration: BoxDecoration(
            color: MfsColors.primaryLight,
            shape: BoxShape.circle,
            border: Border.all(color: MfsColors.primary.withValues(alpha: 0.3)),
          ),
          child: const Icon(
            Icons.account_balance_wallet_rounded,
            color: MfsColors.primary,
            size: 20.0,
          ),
        ),
        const SizedBox(width: 12.0),
        const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Cash in Hand',
              style: TextStyle(
                color: Colors.white,
                fontSize: 16.0,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.2,
              ),
            ),
            Text(
              'Physical Cash Balance',
              style: TextStyle(
                color: MfsColors.textSecondary,
                fontSize: 12.0,
                fontWeight: FontWeight.w400,
              ),
            ),
          ],
        ),
        const Spacer(),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10.0, vertical: 4.0),
          decoration: BoxDecoration(
            color: MfsColors.surfaceVariant,
            borderRadius: BorderRadius.circular(12.0),
            border: Border.all(color: MfsColors.border),
          ),
          child: const Text(
            'Ledger',
            style: TextStyle(
              color: MfsColors.textSecondary,
              fontSize: 11.0,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTapForBalancePill() {
    return Semantics(
      button: true,
      label: _isRevealed
          ? 'Current cash balance: ${CurrencyFormatter.formatBdt(widget.balance)}'
          : 'Tap to reveal cash balance',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: const ValueKey('mfs_tap_for_balance_pill'),
          onTap: _handlePillTap,
          borderRadius: BorderRadius.circular(30.0),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOutCubic,
            padding: const EdgeInsets.symmetric(horizontal: 18.0, vertical: 10.0),
            decoration: BoxDecoration(
              color: MfsColors.surfaceVariant,
              borderRadius: BorderRadius.circular(30.0),
              border: Border.all(
                color: _isRevealed ? MfsColors.primary : MfsColors.border,
                width: 1.2,
              ),
              boxShadow: MfsColors.pillShadow,
            ),
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              transitionBuilder: (child, animation) {
                return FadeTransition(
                  opacity: animation,
                  child: ScaleTransition(
                    scale: Tween<double>(begin: 0.92, end: 1.0).animate(animation),
                    child: child,
                  ),
                );
              },
              child: _isRevealed ? _buildRevealedContent() : _buildHiddenContent(),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHiddenContent() {
    return Row(
      key: const ValueKey('pill_hidden'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 26.0,
          height: 26.0,
          decoration: const BoxDecoration(
            color: MfsColors.primary,
            shape: BoxShape.circle,
          ),
          alignment: Alignment.center,
          child: const Text(
            CurrencyFormatter.takaSymbol,
            style: TextStyle(
              color: Colors.white,
              fontSize: 15.0,
              fontWeight: FontWeight.bold,
              height: 1.1,
            ),
          ),
        ),
        const SizedBox(width: 10.0),
        const Text(
          'Tap for Balance',
          style: TextStyle(
            color: Colors.white,
            fontSize: 15.0,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.2,
          ),
        ),
      ],
    );
  }

  Widget _buildRevealedContent() {
    final isNegative = widget.balance < 0;
    final balanceColor = isNegative ? MfsColors.cashOut : MfsColors.primary;

    return Row(
      key: const ValueKey('pill_revealed'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 26.0,
          height: 26.0,
          decoration: BoxDecoration(
            color: isNegative ? MfsColors.cashOut : MfsColors.cashIn,
            shape: BoxShape.circle,
          ),
          alignment: Alignment.center,
          child: Icon(
            isNegative ? Icons.priority_high : Icons.account_balance_wallet,
            color: Colors.white,
            size: 15.0,
          ),
        ),
        const SizedBox(width: 10.0),
        Flexible(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              CurrencyFormatter.formatBdt(widget.balance),
              style: TextStyle(
                color: balanceColor,
                fontSize: 18.0,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.4,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSummaryStrip() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14.0, vertical: 10.0),
      decoration: BoxDecoration(
        color: MfsColors.surfaceVariant,
        borderRadius: BorderRadius.circular(14.0),
        border: Border.all(color: MfsColors.border),
      ),
      child: Row(
        children: [
          // Total Cash In Chip
          Expanded(
            child: _buildFlowStat(
              label: 'Total In',
              amount: widget.totalIn,
              icon: Icons.arrow_downward_rounded,
              iconColor: MfsColors.cashIn,
              isCredit: true,
            ),
          ),

          Container(
            height: 32.0,
            width: 1.0,
            color: MfsColors.border,
          ),

          // Total Cash Out Chip
          Expanded(
            child: _buildFlowStat(
              label: 'Total Out',
              amount: widget.totalOut,
              icon: Icons.arrow_upward_rounded,
              iconColor: MfsColors.primary,
              isCredit: false,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFlowStat({
    required String label,
    required double amount,
    required IconData icon,
    required Color iconColor,
    required bool isCredit,
  }) {
    final prefix = isCredit ? '+ ' : '- ';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: iconColor, size: 14.0),
              const SizedBox(width: 4.0),
              Text(
                label,
                style: const TextStyle(
                  color: MfsColors.textSecondary,
                  fontSize: 11.0,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          const SizedBox(height: 2.0),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              '$prefix${CurrencyFormatter.formatBdt(amount, showDecimals: true)}',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13.0,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
