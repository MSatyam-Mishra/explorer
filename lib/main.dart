// FILE PATH: lib/main.dart

import 'package:explorer/core/app/app_bloc_observer.dart';
import 'package:explorer/core/theme/app_theme.dart';
import 'package:explorer/core/theme/theme_cubit.dart';
import 'package:explorer/features/file_explorere/screens/file_explorer_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // await File.initialize(); // Init not found in this version/namespace
  Bloc.observer = const AppBlocObserver();

  runApp(const App());
}

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => ThemeCubit(),
      child: BlocBuilder<ThemeCubit, ThemeMode>(
        builder: (context, themeMode) {
          return MaterialApp(
            title: '3D Asset Manager',
            theme: AppTheme.lightTheme,
            darkTheme: AppTheme.darkTheme,
            themeMode: themeMode,
            debugShowCheckedModeBanner: false,

            // --- 2. ADD THESE LINES ---
            supportedLocales: const [Locale('en')],
            localizationsDelegates: [
              //...GlobalMaterialLocalizations.delegates,
              // FlutterQuillLocalizations.delegate,
            ],

            // -------------------------
            home: const FileExplorerScreen(),
          );
        },
      ),
    );
  }
}
