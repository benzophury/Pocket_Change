import 'package:flutter/material.dart';

import 'controllers/ledger_controller.dart';
import 'ui/screens/dashboard_screen.dart';
import 'ui/theme/mfs_colors.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final controller = LedgerController();
  await controller.loadLedger();
  runApp(PocketChangeApp(controller: controller));
}

/// Root application widget for Pocket Change configured with Bangladeshi MFS design system.
class PocketChangeApp extends StatelessWidget {
  final LedgerController? controller;

  const PocketChangeApp({super.key, this.controller});

  @override
  Widget build(BuildContext context) {
    final effectiveController = controller ?? LedgerController();

    return LedgerScope(
      controller: effectiveController,
      child: MaterialApp(
        title: 'Pocket Change',
        debugShowCheckedModeBanner: false,
        theme: MfsColors.buildLightTheme(),
        darkTheme: MfsColors.buildDarkTheme(),
        themeMode: ThemeMode.light,
        home: DashboardScreen(controller: effectiveController),
      ),
    );
  }
}

/// Backward compatibility alias for default Flutter test bindings.
typedef MyApp = PocketChangeApp;
