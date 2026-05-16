// FILE PATH: lib/main.dart

import 'package:explorer/core/app/app_bloc_observer.dart';
import 'package:explorer/core/theme/app_theme.dart';
import 'package:explorer/core/theme/app_theme_settings.dart';
import 'package:explorer/core/theme/theme_cubit.dart';
import 'package:explorer/features/file_explorere/screens/file_explorer_screen.dart';
import 'package:explorer/shared/widgets/explorer_screen_background.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  Bloc.observer = const AppBlocObserver();

  runApp(const App());
}

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => ThemeCubit(),
      child: BlocBuilder<ThemeCubit, AppThemeSettings>(
        builder: (context, settings) {
          return MaterialApp(
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
            home: const FileExplorerScreen(),
          );
        },
      ),
    );
  }
}
