import 'package:flutter/material.dart';

import 'app_state.dart';
import 'ui/home_page.dart';

final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final state = AppState();
  await state.init();

  // Ask the user before accepting incoming files.
  state.confirmIncoming = (from, names, total) async {
    final ctx = navKey.currentContext;
    if (ctx == null) return const IncomingDecision(accept: false);
    var trust = false;
    final ok = await showDialog<bool>(
      context: ctx,
      barrierDismissible: false,
      builder: (dctx) => StatefulBuilder(
        builder: (dctx, setS) => AlertDialog(
          title: Text('Receive from $from?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${names.length} item(s), ${fmtBytes(total)}'),
              const SizedBox(height: 8),
              Text(names.take(5).join('\n') + (names.length > 5 ? '\n…' : '')),
              CheckboxListTile(
                value: trust,
                onChanged: (v) => setS(() => trust = v ?? false),
                title: const Text('Always accept from this device'),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dctx, false),
                child: const Text('Decline')),
            FilledButton(
                onPressed: () => Navigator.pop(dctx, true),
                child: const Text('Accept')),
          ],
        ),
      ),
    );
    return IncomingDecision(accept: ok == true, trust: trust && ok == true);
  };

  runApp(ShareLanApp(state: state));
}

class ShareLanApp extends StatelessWidget {
  final AppState state;
  const ShareLanApp({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) => MaterialApp(
        navigatorKey: navKey,
        title: 'ShareLAN',
        debugShowCheckedModeBanner: false,
        themeMode: state.themeMode,
        theme: ThemeData(
          colorSchemeSeed: const Color(0xFF2563EB),
          useMaterial3: true,
        ),
        darkTheme: ThemeData(
          colorSchemeSeed: const Color(0xFF2563EB),
          brightness: Brightness.dark,
          useMaterial3: true,
        ),
        home: HomePage(state: state),
      ),
    );
  }
}
