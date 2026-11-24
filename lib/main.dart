import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:webview_windows/webview_windows.dart' as wv;

import 'app_core.dart';
import 'app_keyboard_navigation.dart';
import 'app_navigator.dart';
import 'dashboard_screen.dart';
import 'intro_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppCore.ensureLoaded();
  runApp(const EmisAssistantApp());
}

class EmisAssistantApp extends StatefulWidget {
  const EmisAssistantApp({super.key});

  @override
  State<EmisAssistantApp> createState() => _EmisAssistantAppState();
}

class _EmisAssistantAppState extends State<EmisAssistantApp>
    with WidgetsBindingObserver {
  final GlobalKey<NavigatorState> _navKey = appNavigatorKey;
  final GlobalKey<ScaffoldMessengerState> _messengerKey =
      GlobalKey<ScaffoldMessengerState>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(AppCore.persistSessionState());
    }
  }

  Widget _home() {
    if (AppCore.hasActiveSession) {
      return DashboardScreen(
        token: AppCore.token,
        schoolId: AppCore.schoolId,
        schoolName: AppCore.schoolName,
        userName: '',
        allStudents: const <dynamic>[],
        allTeachers: const <dynamic>[],
        stages: const >[],
        subjectsByStage: const <String, List>>{},
        examsBySubject: const <String, List>>{},
      );
    }
    if (!AppCore.introSeen) {
      return const IntroScreen();
    }
    return const IntroScreen();
  }

  ThemeData _lightTheme() {
    const seed = Color(0xFF1A4B8C);
    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: Brightness.light,
      surface: const Color(0xFFF6F8FC),
    );
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: scheme,
      scaffoldBackgroundColor: const Color(0xFFF6F8FC),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFF1A4B8C),
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      cardTheme: CardThemeData(
        color: Colors.white,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: const BorderSide(color: Color(0xFFE2E8F0)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: Color(0xFFCBD5E1)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: Color(0xFFCBD5E1)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: seed, width: 1.8),
        ),
      ),
      textTheme: const TextTheme().apply(
        bodyColor: const Color(0xFF0F172A),
        displayColor: const Color(0xFF0F172A),
      ),
    );
  }

  ThemeData _darkTheme() {
    const seed = Color(0xFF60A5FA);
    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: Brightness.dark,
      surface: const Color(0xFF0B1020),
    );
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: scheme,
      scaffoldBackgroundColor: const Color(0xFF0B1020),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFF111827),
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      cardTheme: CardThemeData(
        color: const Color(0xFF11192D),
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: const BorderSide(color: Color(0xFF1E293B)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFF11192D),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: Color(0xFF283548)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: Color(0xFF283548)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: seed, width: 1.8),
        ),
      ),
      textTheme: const TextTheme().apply(
        bodyColor: const Color(0xFFF1F5F9),
        displayColor: const Color(0xFFF1F5F9),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: AppCore.themeNotifier,
      builder: (context, mode, _) {
        return MaterialApp(
          navigatorKey: _navKey,
          scaffoldMessengerKey: _messengerKey,
          debugShowCheckedModeBanner: false,
          title: 'مساعد EMIS',
          themeMode: mode,
          theme: _lightTheme(),
          darkTheme: _darkTheme(),
          locale: const Locale('ar'),
          supportedLocales: const [
            Locale('ar'),
            Locale('en'),
          ],
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          builder: (context, child) {
            final safeChild = child ?? const SizedBox.shrink();
            return Directionality(
              textDirection: TextDirection.rtl,
              child: AppKeyboardNavigationPolicy(
                child: _WindowsWebViewOverlayHost(
                  child: safeChild,
                ),
              ),
            );
          },
          home: _home(),
        );
      },
    );
  }
}

class _WindowsWebViewOverlayHost extends StatefulWidget {
  final Widget child;

  const _WindowsWebViewOverlayHost({required this.child});

  @override
  State<_WindowsWebViewOverlayHost> createState() =>
      _WindowsWebViewOverlayHostState();
}

class _WindowsWebViewOverlayHostState
    extends State<_WindowsWebViewOverlayHost> {
  wv.WebviewController? _controller;
  StreamSubscription<String>? _urlSub;
  StreamSubscription<wv.WebErrorStatus>? _errorSub;
  bool _initialized = false;
  bool _loading = false;
  bool _active = false;
  String? _statusText;
  String? _currentUrl;
  String? _lastCallbackUrl;
  DateTime? _lastCallbackTime;
  Completer<String?>? _authCompleter;
  Timer? _pollTimer;

  static bool get _supported =>
      !kIsWeb && defaultTargetPlatformIsWindows();

  static bool defaultTargetPlatformIsWindows() {
    return AppCore.isWindows;
  }

  @override
  void initState() {
    super.initState();
    if (_supported) {
      AppCore.windowsWebViewAuthHandler = _authenticateInWebView;
    }
  }

  @override
  void dispose() {
    if (AppCore.windowsWebViewAuthHandler == _authenticateInWebView) {
      AppCore.windowsWebViewAuthHandler = null;
    }
    _pollTimer?.cancel();
    _urlSub?.cancel();
    _errorSub?.cancel();
    final c = _controller;
    _controller = null;
    if (c != null) {
      unawaited(c.dispose());
    }
    super.dispose();
  }

  Future<bool> _ensureController() async {
    if (!_supported) return false;
    if (_initialized && _controller != null) return true;
    try {
      final controller = wv.WebviewController();
      await controller.initialize();
      await controller.setPopupWindowPolicy(wv.WebviewPopupWindowPolicy.allow);
      _urlSub?.cancel();
      _errorSub?.cancel();
      _urlSub = controller.url.listen(_onUrlChanged);
      _errorSub = controller.onLoadError.listen((status) {
        if (!mounted || !_active) return;
        setState(() {
          _loading = false;
          _statusText = 'تعذر تحميل الصفحة ($status). يمكنك إعادة المحاولة.';
        });
      });
      _controller = controller;
      _initialized = true;
      return true;
    } catch (e) {
      _statusText = 'تعذر تهيئة متصفح Windows WebView2: $e';
      return false;
    }
  }

  void _onUrlChanged(String url) {
    if (url.isEmpty) return;
    _currentUrl = url;
    if (_authCompleter != null && !_authCompleter!.isCompleted) {
      if (url.contains('token=') ||
          url.contains('access_token=') ||
          url.contains('emis.moedu.gov.iq/centers') ||
          url.contains('emis.moedu.gov.iq/dashboard')) {
        final now = DateTime.now();
        if (_lastCallbackUrl == url &&
            _lastCallbackTime != null &&
            now.difference(_lastCallbackTime!).inMilliseconds < 500) {
          return;
        }
        _lastCallbackUrl = url;
        _lastCallbackTime = now;
        _finishAuth(url);
        return;
      }
    }
    if (mounted && _active) {
      setState(() {});
    }
  }

  void _startTokenPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(milliseconds: 700), (_) async {
      final completer = _authCompleter;
      final controller = _controller;
      if (completer == null || completer.isCompleted || controller == null) {
        _pollTimer?.cancel();
        return;
      }
      try {
        final raw = await controller.executeScript('''
          (() => {
            try {
              const keys = Object.keys(localStorage || {});
              for (const k of keys) {
                const v = localStorage.getItem(k) || '';
                if (v.includes('eyJ') || k.toLowerCase().includes('token') || k.toLowerCase().includes('auth')) {
                  return JSON.stringify({ href: location.href, key: k, val: v });
                }
              }
            } catch (_) {}
            return JSON.stringify({ href: location.href });
          })()
        ''');
        if (raw is String && raw.isNotEmpty) {
          if (raw.contains('eyJ') ||
              raw.contains('access_token') ||
              raw.contains('/centers/')) {
            _finishAuth(raw);
          }
        }
      } catch (_) {}
    });
  }

  void _finishAuth(String? resultUrl) {
    _pollTimer?.cancel();
    final completer = _authCompleter;
    _authCompleter = null;
    if (mounted) {
      setState(() {
        _active = false;
        _loading = false;
      });
    }
    if (completer != null && !completer.isCompleted) {
      completer.complete(resultUrl);
    }
  }

  Future<String?> _authenticateInWebView(String initialUrl) async {
    if (!_supported) return null;
    if (_authCompleter != null && !_authCompleter!.isCompleted) {
      _authCompleter!.complete(null);
    }
    final completer = Completer<String?>();
    _authCompleter = completer;

    setState(() {
      _active = true;
      _loading = true;
      _currentUrl = initialUrl;
      _statusText = 'جاري فتح بوابة تسجيل الدخول في EMIS...';
    });

    final ready = await _ensureController();
    if (!ready || _controller == null) {
      _finishAuth(null);
      return completer.future;
    }

    try {
      await _controller!.loadUrl(initialUrl);
      if (mounted) {
        setState(() {
          _loading = false;
          _statusText = null;
        });
      }
      _startTokenPolling();
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _statusText = 'تعذر فتح الرابط: $e';
        });
      }
    }

    return completer.future;
  }

  @override
  Widget build(BuildContext context) {
    if (!_supported || !_active) {
      return widget.child;
    }

    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Stack(
      children: [
        widget.child,
        Positioned.fill(
          child: Material(
            color: isDark ? const Color(0xFF0B1020) : const Color(0xFFF6F8FC),
            child: SafeArea(
              child: Column(
                children: [
                  Container(
                    height: 54,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(
                      color: isDark
                          ? const Color(0xFF111827)
                          : const Color(0xFF1A4B8C),
                      border: Border(
                        bottom: BorderSide(
                          color: isDark
                              ? const Color(0xFF1E293B)
                              : const Color(0xFF153E75),
                        ),
                      ),
                    ),
                    child: Row(
                      children: [
                        IconButton(
                          tooltip: 'إغلاق',
                          icon: const Icon(Icons.close_rounded,
                              color: Colors.white),
                          onPressed: () => _finishAuth(null),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _currentUrl ?? 'تسجيل الدخول إلى EMIS',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: 'إعادة تحميل',
                          icon: const Icon(Icons.refresh_rounded,
                              color: Colors.white),
                          onPressed: () async {
                            final c = _controller;
                            if (c != null) {
                              setState(() => _loading = true);
                              await c.reload();
                              if (mounted) setState(() => _loading = false);
                            }
                          },
                        ),
                      ],
                    ),
                  ),
                  if (_loading)
                    const LinearProgressIndicator(minHeight: 2.5),
                  if (_statusText != null)
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(
                        _statusText!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                  Expanded(
                    child: _controller != null
                        ? wv.Webview(_controller!)
                        : const SizedBox.shrink(),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
