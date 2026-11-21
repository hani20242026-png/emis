import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'intro_screen.dart';
import 'app_core.dart';
import 'app_navigator.dart';
import 'widgets/siri_orb.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // تهيئة وحفظ قراءة الإعدادات المحلية مع مهلة أمان لمنع تعليق التطبيق على الشاشة البيضاء[span_2](start_span)[span_2](end_span)[span_3](start_span)[span_3](end_span)
  try {
    await AppCore.initPreferences().timeout(const Duration(seconds: 2));
  } catch (e) {
    debugPrint('InitPreferences timeout or error: $e');
  }

  if (!Platform.isWindows && !Platform.isLinux && !Platform.isMacOS) {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: AppCore.themeNotifier,
      builder: (context, currentMode, child) {
        return MaterialApp(
          navigatorKey: emisNavigatorKey,
          title: 'مساعد EMIS',
          debugShowCheckedModeBanner: false,
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: const [Locale('ar', 'IQ')],
          locale: const Locale('ar', 'IQ'),
          themeMode: currentMode,
          theme: ThemeData(
            fontFamily: 'Tajawal',
            brightness: Brightness.light,
            primarySwatch: Colors.blue,
            textTheme: const TextTheme(
              displayLarge: TextStyle(fontWeight: FontWeight.bold),
              displayMedium: TextStyle(fontWeight: FontWeight.bold),
              displaySmall: TextStyle(fontWeight: FontWeight.bold),
              headlineLarge: TextStyle(fontWeight: FontWeight.bold),
              headlineMedium: TextStyle(fontWeight: FontWeight.bold),
              headlineSmall: TextStyle(fontWeight: FontWeight.bold),
              titleLarge: TextStyle(fontWeight: FontWeight.bold),
              titleMedium: TextStyle(fontWeight: FontWeight.bold),
              titleSmall: TextStyle(fontWeight: FontWeight.bold),
              bodyLarge: TextStyle(fontWeight: FontWeight.bold),
              bodyMedium: TextStyle(fontWeight: FontWeight.bold),
              bodySmall: TextStyle(fontWeight: FontWeight.bold),
              labelLarge: TextStyle(fontWeight: FontWeight.bold),
              labelMedium: TextStyle(fontWeight: FontWeight.bold),
              labelSmall: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          darkTheme: ThemeData(
            fontFamily: 'Tajawal',
            brightness: Brightness.dark,
            primarySwatch: Colors.blue,
            textTheme: const TextTheme(
              displayLarge: TextStyle(fontWeight: FontWeight.bold),
              displayMedium: TextStyle(fontWeight: FontWeight.bold),
              displaySmall: TextStyle(fontWeight: FontWeight.bold),
              headlineLarge: TextStyle(fontWeight: FontWeight.bold),
              headlineMedium: TextStyle(fontWeight: FontWeight.bold),
              headlineSmall: TextStyle(fontWeight: FontWeight.bold),
              titleLarge: TextStyle(fontWeight: FontWeight.bold),
              titleMedium: TextStyle(fontWeight: FontWeight.bold),
              titleSmall: TextStyle(fontWeight: FontWeight.bold),
              bodyLarge: TextStyle(fontWeight: FontWeight.bold),
              bodyMedium: TextStyle(fontWeight: FontWeight.bold),
              bodySmall: TextStyle(fontWeight: FontWeight.bold),
              labelLarge: TextStyle(fontWeight: FontWeight.bold),
              labelMedium: TextStyle(fontWeight: FontWeight.bold),
              labelSmall: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          home: const IntroScreen(),
          builder: (context, child) {
            return Stack(
              children: [
                child ?? const SizedBox.shrink(),
                if (AppCore.kLocalAiBuildEnabled)
                  ValueListenableBuilder<bool>(
                    valueListenable: AppCore.aiAssistantEnabledNotifier,
                    builder: (context, enabled, _) {
                      if (!enabled) return const SizedBox.shrink();
                      return ValueListenableBuilder<bool>(
                        valueListenable: AppCore.aiAssistantAvailableNotifier,
                        builder: (context, available, _) => available
                            ? const SiriOrb()
                            : const SizedBox.shrink(),
                      );
                    },
                  ),
              ],
            );
          },
        );
      },
    );
  }
}
