import 'package:flutter/material.dart';

import 'app.dart';
import 'services.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    final services = await AppServices.bootstrap();
    runApp(AurisApp(services: services));
  } catch (error, stack) {
    // Startup failures (no writable storage, unsupported platform) would
    // otherwise surface as a grey screen with no explanation.
    debugPrint('Auris failed to start: $error\n$stack');
    runApp(StartupFailureApp(error: error));
  }
}

/// Shown when the app cannot initialise at all.
class StartupFailureApp extends StatelessWidget {
  const StartupFailureApp({super.key, required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Auris',
        debugShowCheckedModeBanner: false,
        theme: AurisTheme.light(),
        home: Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.error_outline,
                      size: 48, color: AurisTheme.warning),
                  const SizedBox(height: 16),
                  const Text(
                    'Auris could not start',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    '$error',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontSize: 13, height: 1.5, color: AurisTheme.muted),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
}
