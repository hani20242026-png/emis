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

// Original mobile themes retained verbatim.
ThemeData _originalLightTheme() => ThemeData(
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
          );

ThemeData _originalDarkTheme() => ThemeData(
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
          );

ThemeData _windowsLightTheme() {
  const primary = Color(0xFF6250A4);
  const foreground = Color(0xFF182033);
  const background = Color(0xFFF4F6FA);
  final scheme = ColorScheme.fromSeed(
    seedColor: primary, brightness: Brightness.light,
    surface: Colors.white, onSurface: foreground,
  );
  return ThemeData(
    useMaterial3: true, fontFamily: 'Tajawal', brightness: Brightness.light,
    colorScheme: scheme, primaryColor: primary, scaffoldBackgroundColor: background,
    canvasColor: Colors.white, cardColor: Colors.white,
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.white, foregroundColor: foreground,
      surfaceTintColor: Colors.transparent, elevation: 0, iconTheme: IconThemeData(color: foreground),
      titleTextStyle: TextStyle(fontFamily: 'Tajawal', color: foreground, fontSize: 20, fontWeight: FontWeight.bold),
    ),
    iconTheme: const IconThemeData(color: foreground),
    textTheme: ThemeData.light().textTheme.apply(bodyColor: foreground, displayColor: foreground, fontFamily: 'Tajawal'),
    cardTheme: const CardThemeData(color: Colors.white, surfaceTintColor: Colors.transparent, elevation: 1),
    dialogTheme: const DialogThemeData(backgroundColor: Colors.white, surfaceTintColor: Colors.transparent),
    inputDecorationTheme: InputDecorationTheme(
      filled: true, fillColor: Colors.white,
      labelStyle: const TextStyle(color: Color(0xFF536078)),
      hintStyle: const TextStyle(color: Color(0xFF788399)),
      prefixIconColor: const Color(0xFF536078), suffixIconColor: const Color(0xFF536078),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFFD7DCE6))),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: primary, width: 1.6)),
    ),
    dividerColor: const Color(0xFFE1E5ED),
    popupMenuTheme: const PopupMenuThemeData(color: Colors.white, textStyle: TextStyle(color: foreground)),
    textSelectionTheme: const TextSelectionThemeData(cursorColor: primary, selectionColor: Color(0x336250A4), selectionHandleColor: primary),
  );
}

ThemeData _windowsDarkTheme() {
  const primary = Color(0xFFB6A5F2);
  const foreground = Color(0xFFE8EAF2);
  const background = Color(0xFF111522);
  const surface = Color(0xFF1B2232);
  final scheme = ColorScheme.fromSeed(
    seedColor: primary, brightness: Brightness.dark,
    surface: surface, onSurface: foreground,
  );
  return ThemeData(
    useMaterial3: true, fontFamily: 'Tajawal', brightness: Brightness.dark,
    colorScheme: scheme, primaryColor: primary, scaffoldBackgroundColor: background,
    canvasColor: surface, cardColor: surface,
    appBarTheme: const AppBarTheme(
      backgroundColor: surface, foregroundColor: foreground,
      surfaceTintColor: Colors.transparent, elevation: 0, iconTheme: IconThemeData(color: foreground),
      titleTextStyle: TextStyle(fontFamily: 'Tajawal', color: foreground, fontSize: 20, fontWeight: FontWeight.bold),
    ),
    iconTheme: const IconThemeData(color: foreground),
    textTheme: ThemeData.dark().textTheme.apply(bodyColor: foreground, displayColor: foreground, fontFamily: 'Tajawal'),
    cardTheme: const CardThemeData(color: surface, surfaceTintColor: Colors.transparent, elevation: 1),
    dialogTheme: const DialogThemeData(backgroundColor: surface, surfaceTintColor: Colors.transparent),
    inputDecorationTheme: InputDecorationTheme(
      filled: true, fillColor: surface,
      labelStyle: const TextStyle(color: Color(0xFFB7BED0)),
      hintStyle: const TextStyle(color: Color(0xFF929BB0)),
      prefixIconColor: const Color(0xFFB7BED0), suffixIconColor: const Color(0xFFB7BED0),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFF3A4358))),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: primary, width: 1.6)),
    ),
    dividerColor: const Color(0xFF343D51),
    popupMenuTheme: const PopupMenuThemeData(color: surface, textStyle: TextStyle(color: foreground)),
    textSelectionTheme: const TextSelectionThemeData(cursorColor: primary, selectionColor: Color(0x66B6A5F2), selectionHandleColor: primary),
  );
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
          // Windows receives an independent color system. Android keeps the
          // original themes unchanged to avoid altering the mobile application.
          theme: Platform.isWindows ? _windowsLightTheme() : _originalLightTheme(),
          darkTheme: Platform.isWindows ? _windowsDarkTheme() : _originalDarkTheme(),
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
