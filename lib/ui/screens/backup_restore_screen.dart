import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../controllers/ledger_controller.dart';
import '../../models/backup_payload.dart';
import '../../services/backup_service.dart';
import '../theme/currency_formatter.dart';
import '../theme/mfs_colors.dart';

/// Screen managing database export via Android share sheet and safe pre-validated
/// JSON backup restoration with Replace vs Merge modes.
class BackupRestoreScreen extends StatefulWidget {
  final LedgerController? controller;
  final Future<String?> Function()? filePickerOverride;

  const BackupRestoreScreen({
    super.key,
    this.controller,
    this.filePickerOverride,
  });

  @override
  State<BackupRestoreScreen> createState() => _BackupRestoreScreenState();
}

class _BackupRestoreScreenState extends State<BackupRestoreScreen> {
  bool _isExporting = false;
  bool _isImporting = false;

  LedgerController get _effectiveController {
    if (widget.controller != null) return widget.controller!;
    return LedgerScope.of(context);
  }

  Future<void> _handleExport(LedgerController controller) async {
    if (_isExporting) return;
    setState(() => _isExporting = true);

    try {
      final file = await controller.exportBackup();
      await controller.shareBackup(file);

      if (mounted) {
        final checksum = BackupService.computeChecksum(controller.transactions);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Backup exported successfully!\nFile: ${file.path.split('/').last}\n$checksum',
            ),
            backgroundColor: MfsColors.cashIn,
            duration: const Duration(seconds: 4),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Export failed: $e'),
            backgroundColor: MfsColors.cashOut,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isExporting = false);
    }
  }

  Future<void> _handleImport(LedgerController controller) async {
    if (_isImporting) return;
    setState(() => _isImporting = true);

    try {
      String? jsonContent;

      if (widget.filePickerOverride != null) {
        jsonContent = await widget.filePickerOverride!();
      } else {
        final result = await FilePicker.platform.pickFiles(
          type: FileType.custom,
          allowedExtensions: ['json'],
        );

        if (result != null && result.files.isNotEmpty) {
          final path = result.files.first.path;
          if (path != null) {
            final file = File(path);
            if (await file.exists()) {
              jsonContent = await file.readAsString();
            }
          } else if (result.files.first.bytes != null) {
            jsonContent = String.fromCharCodes(result.files.first.bytes!);
          }
        }
      }

      if (jsonContent == null || jsonContent.trim().isEmpty) {
        if (mounted) setState(() => _isImporting = false);
        return;
      }

      // 5-Stage Pre-Validation
      final validation = await controller.validateBackup(jsonContent);

      if (!validation.isValid || validation.payload == null) {
        if (mounted) {
          setState(() => _isImporting = false);
          await _showValidationFailureDialog(validation.errors);
        }
        return;
      }

      if (mounted) {
        setState(() => _isImporting = false);
        await _showRestorePreviewDialog(
          validation: validation,
          onConfirmed: (clearExisting) async {
            try {
              final summary = await controller.restoreBackup(
                jsonContent!,
                clearExisting: clearExisting,
              );
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      'Restored ${summary.restoredTransactionsCount} transactions & ${summary.restoredPhotosCount} receipt photos!\nBalance: ${CurrencyFormatter.formatBdt(summary.restoredBalance)}',
                    ),
                    backgroundColor: MfsColors.cashIn,
                    duration: const Duration(seconds: 4),
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              }
            } catch (e) {
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Restoration failed: $e'),
                    backgroundColor: MfsColors.cashOut,
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              }
            }
          },
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Import error: $e'),
            backgroundColor: MfsColors.cashOut,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isImporting = false);
    }
  }

  Future<void> _showValidationFailureDialog(List<String> errors) async {
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.error_outline_rounded, color: MfsColors.cashOut),
            SizedBox(width: 8),
            Text('Invalid Backup File'),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'This backup file failed validation checks and cannot be restored safely:',
                style: TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 12),
              ...errors.map(
                (err) => Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('• ', style: TextStyle(color: MfsColors.cashOut, fontWeight: FontWeight.bold)),
                      Expanded(
                        child: Text(err, style: const TextStyle(fontSize: 12, color: Colors.black87)),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<void> _showRestorePreviewDialog({
    required BackupValidationResult validation,
    required ValueChanged<bool> onConfirmed,
  }) async {
    bool clearExisting = true;
    final payload = validation.payload!;

    return showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: const Row(
              children: [
                Icon(Icons.preview_outlined, color: MfsColors.primary),
                SizedBox(width: 8),
                Text('Restore Preview'),
              ],
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildPreviewRow('Declared Balance', CurrencyFormatter.formatBdt(payload.summary.balance)),
                  _buildPreviewRow('Total Records', '${payload.transactionCount} transactions'),
                  _buildPreviewRow('Attached Photos', '${payload.photoCount} photos'),
                  _buildPreviewRow('Exported On', DateFormat('dd MMM yyyy, hh:mm a').format(payload.exportedAt.toLocal())),
                  _buildPreviewRow('Source Device', '${payload.deviceOs} (${payload.appVersion})'),
                  const Divider(height: 20),
                  if (validation.hasWarnings) ...[
                    Container(
                      padding: const EdgeInsets.all(8),
                      margin: const EdgeInsets.only(bottom: 12),
                      decoration: BoxDecoration(
                        color: Colors.amber.shade50,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.amber.shade300),
                      ),
                      child: Text(
                        'Warnings:\n${validation.warnings.join('\n')}',
                        style: TextStyle(fontSize: 11, color: Colors.amber.shade900),
                      ),
                    ),
                  ],
                  const Text(
                    'Restore Mode:',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                  ),
                  RadioGroup<bool>(
                    groupValue: clearExisting,
                    onChanged: (val) => setDialogState(() => clearExisting = val ?? true),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: const [
                        RadioListTile<bool>(
                          contentPadding: EdgeInsets.zero,
                          dense: true,
                          title: Text('Replace all existing data', style: TextStyle(fontSize: 13)),
                          subtitle: Text('Clears current ledger and restores backup', style: TextStyle(fontSize: 11)),
                          value: true,
                        ),
                        RadioListTile<bool>(
                          contentPadding: EdgeInsets.zero,
                          dense: true,
                          title: Text('Merge with existing data', style: TextStyle(fontSize: 13)),
                          subtitle: Text('Overwrites matching items by TrxID', style: TextStyle(fontSize: 11)),
                          value: false,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                key: const ValueKey('confirm_restore_button'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: MfsColors.primary,
                  foregroundColor: Colors.white,
                ),
                onPressed: () {
                  Navigator.pop(ctx);
                  onConfirmed(clearExisting);
                },
                child: const Text('Confirm & Restore'),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildPreviewRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(fontSize: 12, color: Colors.black54)),
          Text(value, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  Future<void> _handleClearLedger(LedgerController controller) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Wipe All Ledger Data?'),
        content: const Text(
          'This will permanently delete all cash transactions and receipt photos. This action cannot be undone.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: MfsColors.cashOut, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Wipe Ledger'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await controller.clearAll();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Ledger data and receipts wiped successfully.'),
            backgroundColor: MfsColors.cashOut,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = _effectiveController;

    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        return Scaffold(
          backgroundColor: MfsColors.background,
          appBar: AppBar(
            backgroundColor: MfsColors.primary,
            foregroundColor: Colors.white,
            elevation: 0,
            title: const Text(
              'Backup & Restore',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
            ),
          ),
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 1. Live Statistics Card
                _buildLiveStatsCard(controller),
                const SizedBox(height: 16),

                // 2. Export Card
                _buildExportCard(controller),
                const SizedBox(height: 16),

                // 3. Import Card
                _buildImportCard(controller),
                const SizedBox(height: 24),

                // 4. Wipe Ledger Danger Zone
                _buildDangerZoneCard(controller),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildLiveStatsCard(LedgerController controller) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: MfsColors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: MfsColors.border),
        boxShadow: MfsColors.cardShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.analytics_outlined, color: MfsColors.primary, size: 20),
              SizedBox(width: 8),
              Text(
                'Ledger Statistics',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.white),
              ),
            ],
          ),
          const Divider(height: 20, color: MfsColors.border),
          _buildStatRow('Net Cash Balance', CurrencyFormatter.formatBdt(controller.balance), isBold: true),
          _buildStatRow('Total Inflow (+)', CurrencyFormatter.formatBdt(controller.totalIn), color: MfsColors.cashIn),
          _buildStatRow('Total Outflow (-)', CurrencyFormatter.formatBdt(controller.totalOut), color: MfsColors.primary),
          _buildStatRow('Total Transactions', '${controller.totalCount} records'),
          _buildStatRow('Attached Receipt Photos', '${controller.photoCount} photos'),
        ],
      ),
    );
  }

  Widget _buildStatRow(String label, String value, {bool isBold = false, Color? color}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(fontSize: 13, color: MfsColors.textSecondary)),
          Text(
            value,
            style: TextStyle(
              fontSize: 13,
              fontWeight: isBold ? FontWeight.bold : FontWeight.w600,
              color: color ?? Colors.white,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildExportCard(LedgerController controller) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: MfsColors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: MfsColors.border),
        boxShadow: MfsColors.cardShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.upload_file_rounded, color: MfsColors.primary, size: 20),
              SizedBox(width: 8),
              Text('Export Backup', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.white)),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'Export all cash transactions, notes, and attached receipt photos into a portable JSON backup file.',
            style: TextStyle(fontSize: 12, color: MfsColors.textSecondary),
          ),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            key: const ValueKey('export_backup_button'),
            onPressed: _isExporting ? null : () => _handleExport(controller),
            icon: _isExporting
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.share_rounded, size: 18),
            label: Text(_isExporting ? 'Exporting...' : 'Export & Share Backup'),
            style: ElevatedButton.styleFrom(
              backgroundColor: MfsColors.primary,
              foregroundColor: Colors.white,
              minimumSize: const Size.fromHeight(48),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildImportCard(LedgerController controller) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: MfsColors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: MfsColors.border),
        boxShadow: MfsColors.cardShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.download_rounded, color: MfsColors.primary, size: 20),
              SizedBox(width: 8),
              Text('Import & Restore', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.white)),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'Restore transactions and receipt photos from a previously exported JSON backup file with 5-stage pre-validation.',
            style: TextStyle(fontSize: 12, color: MfsColors.textSecondary),
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            key: const ValueKey('select_backup_file_button'),
            onPressed: _isImporting ? null : () => _handleImport(controller),
            icon: _isImporting
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: MfsColors.primary))
                : const Icon(Icons.folder_open_rounded, size: 18, color: MfsColors.primary),
            label: Text(
              _isImporting ? 'Validating...' : 'Select Backup File (.json)',
              style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
            ),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
              side: const BorderSide(color: MfsColors.primary, width: 1.5),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDangerZoneCard(LedgerController controller) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0x22DC143C),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: MfsColors.primary.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Danger Zone',
            style: TextStyle(fontWeight: FontWeight.bold, color: MfsColors.cashOut, fontSize: 13),
          ),
          const SizedBox(height: 4),
          const Text(
            'Purge all ledger records and delete all receipt photos from disk.',
            style: TextStyle(fontSize: 11, color: Colors.black54),
          ),
          const SizedBox(height: 12),
          TextButton.icon(
            key: const ValueKey('wipe_ledger_button'),
            onPressed: () => _handleClearLedger(controller),
            icon: const Icon(Icons.delete_forever_rounded, color: MfsColors.cashOut, size: 18),
            label: const Text('Wipe All Ledger Data', style: TextStyle(color: MfsColors.cashOut, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }
}
