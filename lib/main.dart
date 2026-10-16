// FILE PATH: lib/main.dart

import 'package:explorer/core/app/app_bloc_observer.dart';
import 'package:explorer/core/services/incoming_files.dart';
import 'package:explorer/core/services/webview_warmup.dart';
import 'package:explorer/core/theme/app_theme.dart';
import 'package:explorer/core/theme/app_theme_settings.dart';
import 'package:explorer/core/theme/theme_cubit.dart';
import 'package:explorer/features/file_explorere/screens/file_explorer_screen.dart';
import 'package:explorer/features/incoming/incoming_file_screen.dart';
import 'package:explorer/shared/widgets/explorer_screen_background.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

final _navigatorKey = GlobalKey<NavigatorState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  Bloc.observer = const AppBlocObserver();

  // Launched from another app's "Open with": go straight to the viewer.
  final launchFile = await IncomingFiles.takeInitial();
  IncomingFiles.onIncoming.listen((incoming) {
    _navigatorKey.currentState?.push(MaterialPageRoute(
      builder: (_) =>
          IncomingFileScreen(incoming: incoming, closeAppWhenDone: false),
    ));
  });

  runApp(App(launchFile: launchFile));

  // Load the system WebView engine while idle so the first e-book, web
  // page, Markdown preview or 3D model opens without that cost. A file
  // opened from another app starts its own WebView right away instead.
  if (launchFile == null) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future.delayed(const Duration(seconds: 3), WebViewWarmup.warmUp);
    });
  }
}

class App extends StatelessWidget {
  const App({super.key, this.launchFile});

  final IncomingFile? launchFile;

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => ThemeCubit(),
      child: BlocBuilder<ThemeCubit, AppThemeSettings>(
        builder: (context, settings) {
          return MaterialApp(
            navigatorKey: _navigatorKey,
            title: 'Explorer',
            theme: AppTheme.forSettings(
              settings,
              brightness: Brightness.light,
            ),
            darkTheme: AppTheme.forSettings(
              settings,
              brightness: Brightness.dark,
            ),
            themeMode: settings.themeMode,
            debugShowCheckedModeBanner: false,
            supportedLocales: const [Locale('en')],
            localizationsDelegates: const [],
            builder: (context, child) => ExplorerScreenBackground(
              child: child ?? const SizedBox.shrink(),
            ),
            home: launchFile == null
                ? const FileExplorerScreen()
                : IncomingFileScreen(
                    incoming: launchFile!,
                    closeAppWhenDone: true,
                  ),
          );
        },
      ),
    );
  }
}
