import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'app_core.dart';

/// واجهة Flutter للتعرف الصوتي: تستخدم قنوات Android SpeechRecognizer على أندرويد،
/// وتستخدم `speech_to_text` على Windows وسطح المكتب دون كسر استدعاءات المنصة[span_2](start_span)[span_2](end_span)[span_3](start_span)[span_3](end_span).
class GoogleSpeechService {
  static const MethodChannel _method = MethodChannel('emis.google_speech');
  static const EventChannel _events = EventChannel('emis.google_speech/events');

  static int _globalSessionCounter = 0;
  static int? _activeSessionId;
  static StreamSubscription<dynamic>? _platformSubscription;
  static final StreamController<Map<String, dynamic>> _eventsController =
      StreamController<Map<String, dynamic>>.broadcast(
    onListen: _ensurePlatformStreamSubscribed,
  );

  // دعم Windows / سطح المكتب عبر speech_to_text
  static final SpeechToText _desktopStt = SpeechToText();
  static bool _desktopInitialized = false;
  static int? _desktopSessionId;
  static String? _desktopArabicLocaleId;
  static String? _desktopLocaleError;
  static HttpServer? _chromeSpeechServer;
  static Process? _chromeSpeechProcess;
  static String? _chromeSpeechExecutable;
  static String? _chromeSpeechCommand;
  static bool _chromeSpeechPageReady = false;
  static Completer<void>? _chromeSpeechReady;

  static String _normalizeLocaleId(String value) =>
      value.trim().replaceAll('_', '-').toLowerCase();

  /// Windows speech recognition only supports languages installed in Windows.
  /// Never allow the recognizer to silently fall back to English.
  static Future<String?> _resolveDesktopArabicLocale(String requested) async {
    if (_desktopArabicLocaleId != null) return _desktopArabicLocaleId;

    try {
      final locales = await _desktopStt.locales();
      final available = locales
          .map((locale) => locale.localeId.trim())
          .where((id) => id.isNotEmpty)
          .toList(growable: false);

      final requestedNormalized = _normalizeLocaleId(requested);
      String? selected;

      for (final id in available) {
        if (_normalizeLocaleId(id) == requestedNormalized) {
          selected = id;
          break;
        }
      }

      // Iraqi Arabic is preferred. If Windows does not provide it, use an
      // installed Arabic locale rather than accepting an English fallback.
      if (selected == null) {
        for (final id in available) {
          if (_normalizeLocaleId(id).startsWith('ar-')) {
            selected = id;
            break;
          }
        }
      }

      if (selected == null) {
        _desktopLocaleError =
            'لا توجد حزمة تعرف صوتي باللغة العربية مثبتة في Windows. '
            'أضف اللغة العربية مع ميزة Speech recognition من إعدادات Windows.';
        return null;
      }

      _desktopArabicLocaleId = selected;
      _desktopLocaleError = null;
      return selected;
    } catch (error) {
      _desktopLocaleError = 'تعذر قراءة لغات التعرف الصوتي المثبتة في Windows: $error';
      return null;
    }
  }

  static bool _containsLatinLetters(String value) =>
      RegExp(r'[A-Za-z]').hasMatch(value);

  static bool _containsArabicLetters(String value) =>
      RegExp(r'[\u0600-\u06FF]').hasMatch(value);

  static bool get _useWindowsChromeSpeech => Platform.isWindows;

  static bool get _useDesktopSpeech =>
      Platform.isLinux || Platform.isMacOS;

  static Future<String?> _findChromeExecutable() async {
    if (_chromeSpeechExecutable != null &&
        await File(_chromeSpeechExecutable!).exists()) {
      return _chromeSpeechExecutable;
    }
    final candidates = <String>[
      if (Platform.environment['PROGRAMFILES'] != null)
        '${Platform.environment['PROGRAMFILES']}\\Google\\Chrome\\Application\\chrome.exe',
      if (Platform.environment['PROGRAMFILES(X86)'] != null)
        '${Platform.environment['PROGRAMFILES(X86)']}\\Google\\Chrome\\Application\\chrome.exe',
      if (Platform.environment['LOCALAPPDATA'] != null)
        '${Platform.environment['LOCALAPPDATA']}\\Google\\Chrome\\Application\\chrome.exe',
    ];
    for (final path in candidates) {
      if (await File(path).exists()) return _chromeSpeechExecutable = path;
    }
    for (final key in <String>[
      r'HKCU\Software\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe',
      r'HKLM\Software\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe',
      r'HKLM\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe',
    ]) {
      try {
        final result = await Process.run('reg', ['query', key, '/ve']);
        final output = '${result.stdout}';
        final match = RegExp(r'(?im)^\s*\(Default\)\s+REG_SZ\s+(.+chrome\.exe)\s*$')
            .firstMatch(output);
        final path = match?.group(1)?.trim();
        if (path != null && await File(path).exists()) {
          return _chromeSpeechExecutable = path;
        }
      } catch (_) {}
    }
    return null;
  }

  static String _chromeSpeechPage(String token) => r'''<!doctype html>
<html lang="ar" dir="rtl"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>EMIS Voice Service</title>
<style>html,body{margin:0;background:transparent;color:transparent;overflow:hidden}</style></head><body>
<script>
(()=>{
const token=''' + jsonEncode(token) + r''';
const SR=window.SpeechRecognition||window.webkitSpeechRecognition;
let rec=null, running=false, shouldRun=false, restarting=false, lastError='', serverFailures=0;
async function send(type,text='',extra={}){try{await fetch('/event?token='+encodeURIComponent(token),{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({type,text,...extra})});}catch(e){}}
async function poll(){try{const r=await fetch('/control?token='+encodeURIComponent(token),{cache:'no-store'});if(!r.ok)throw new Error('server');serverFailures=0;const c=await r.json();if(c.action==='start'&&!shouldRun){shouldRun=true;start();}else if(c.action==='stop'&&shouldRun){shouldRun=false;try{rec&&rec.stop();}catch(e){}}}catch(e){serverFailures++;if(serverFailures>12){try{shouldRun=false;rec&&rec.stop();window.close();}catch(_){}return;}}setTimeout(poll,250);}
function start(){if(!SR){send('error','هذا الإصدار من Chrome لا يدعم التعرف الصوتي.');return;}if(!rec){rec=new SR();rec.lang='ar-KW';rec.continuous=true;rec.interimResults=false;rec.maxAlternatives=3;
rec.onstart=()=>{running=true;send('ready','');};
rec.onresult=e=>{for(let i=e.resultIndex;i<e.results.length;i++){const item=e.results[i];if(!item.isFinal)continue;const text=(item[0]?.transcript||'').trim();if(text)send('result',text,{alternates:Array.from(item).slice(1).map(x=>x.transcript).filter(Boolean)});}};
rec.onerror=e=>{lastError=e.error||'unknown';send('error',lastError);};
rec.onend=()=>{running=false;if(shouldRun){setTimeout(()=>{if(shouldRun&&!running){try{restarting=true;rec.start();}catch(e){send('error',String(e));}}},700);}else send('stopped','');};}
try{rec.start();}catch(e){if(!restarting)send('error',String(e));}restarting=false;}
send('page-ready','');
poll();
})();
</script></body></html>''';

  static Future<bool> _ensureChromeSpeechServer() async {
    if (_chromeSpeechServer != null && _chromeSpeechProcess != null) return true;
    final chrome = await _findChromeExecutable();
    if (chrome == null) {
      _emitDesktopEvent('error', _activeSessionId, {
        'message': 'لم يتم العثور على Google Chrome. يرجى تثبيت Chrome ثم إعادة المحاولة.',
      });
      return false;
    }
    final appData = Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path;
    final profile = Directory('$appData\\EMIS\\ChromeSpeechProfile');
    await profile.create(recursive: true);
    final permissionMarker = File('${profile.path}\\microphone-permission-granted.marker');
    final token = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _chromeSpeechServer = server;
    _chromeSpeechCommand = 'idle';
    _chromeSpeechPageReady = false;
    _chromeSpeechReady = Completer<void>();
    server.listen((request) async {
      request.response.headers
        ..set(HttpHeaders.cacheControlHeader, 'no-store')
        ..set(HttpHeaders.accessControlAllowOriginHeader, '*');
      final queryToken = request.uri.queryParameters['token'];
      if (queryToken != token) {
        request.response.statusCode = HttpStatus.forbidden;
        await request.response.close();
        return;
      }
      if (request.method == 'GET' && request.uri.path == '/') {
        request.response.headers.contentType = ContentType.html;
        request.response.write(_chromeSpeechPage(token));
      } else if (request.method == 'GET' && request.uri.path == '/control') {
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'action': _chromeSpeechCommand}));
      } else if (request.method == 'POST' && request.uri.path == '/event') {
        final body = await utf8.decoder.bind(request).join();
        try {
          final event = jsonDecode(body) as Map<String, dynamic>;
          final type = '${event['type'] ?? ''}';
          final text = '${event['text'] ?? ''}';
          if (type == 'page-ready') {
            _chromeSpeechPageReady = true;
            if (!(_chromeSpeechReady?.isCompleted ?? true)) _chromeSpeechReady!.complete();
          }
          if (type == 'ready') {
            if (!permissionMarker.existsSync()) {
              try { permissionMarker.writeAsStringSync('granted'); } catch (_) {}
            }
            if (!(_chromeSpeechReady?.isCompleted ?? true)) _chromeSpeechReady!.complete();
          }
          if (_activeSessionId != null &&
              (type == 'ready' || type == 'stopped' || type == 'error' || type == 'result')) {
            _emitDesktopEvent(type, _activeSessionId, {
              'text': text,
              'segment': text,
              'isFinal': type == 'result',
              'alternates': (event['alternates'] is List) ? event['alternates'] : <String>[],
              if (type == 'error') 'message': text,
            });
          }
        } catch (_) {}
        request.response.headers.contentType = ContentType.json;
        request.response.write('{"ok":true}');
      } else {
        request.response.statusCode = HttpStatus.notFound;
      }
      await request.response.close();
    }, onError: (Object error) {
      _emitDesktopEvent('error', _activeSessionId, {'message': '$error'});
    });
    final url = 'http://127.0.0.1:${server.port}/?token=$token';
    try {
      _chromeSpeechProcess = await Process.start(chrome, [
        '--no-first-run', '--no-default-browser-check', '--disable-background-mode',
        '--disable-session-crashed-bubble', '--noerrdialogs',
        '--user-data-dir=${profile.path}', '--new-window', '--app=$url',
        // Keep the helper app window off-screen on every launch.
        // Microphone permission is persisted in the dedicated Chrome profile.
        '--window-position=-32000,-32000',
        '--window-size=900,650',
        '--start-minimized',
      ], mode: ProcessStartMode.detached);
    } catch (error) {
      await server.close(force: true);
      _chromeSpeechServer = null;
      _chromeSpeechProcess = null;
      _emitDesktopEvent('error', _activeSessionId, {'message': 'تعذر تشغيل Chrome: $error'});
      return false;
    }
    // First run is visible so the user can explicitly approve microphone access.
    // Once Chrome reports listening, later launches can stay off-screen.
    try {
      await _chromeSpeechReady!.future.timeout(const Duration(seconds: 25));
    } on TimeoutException {
      await server.close(force: true);
      _chromeSpeechServer = null;
      _chromeSpeechProcess = null;
      _emitDesktopEvent('error', _activeSessionId, {
        'message': 'لم يبدأ Chrome خدمة الميكروفون خلال المهلة. تحقق من إذن الميكروفون في Chrome.',
      });
      return false;
    }
    return true;
  }

  static int nextSessionId() => ++_globalSessionCounter;

  static int? get activeSessionId => _activeSessionId;

  static void _ensurePlatformStreamSubscribed() {
    if (_useDesktopSpeech || _useWindowsChromeSpeech) return;
    if (_platformSubscription != null) return;
    _platformSubscription = _events.receiveBroadcastStream().listen(
      (event) {
        final parsed = _parseEvent(event);
        final type = parsed['type'];
        final eventSessionId = int.tryParse('${parsed['sessionId'] ?? ''}');
        if ((type == 'stopped' || type == 'error') &&
            eventSessionId != null &&
            eventSessionId == _activeSessionId) {
          _activeSessionId = null;
        }
        if (!_eventsController.isClosed) {
          _eventsController.add(parsed);
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!_eventsController.isClosed) {
          _eventsController.add(<String, dynamic>{
            'type': 'error',
            'sessionId': _activeSessionId,
            'message': '$error',
          });
        }
      },
    );
  }

  static void _emitDesktopEvent(String type, int? sessionId, Map<String, dynamic> extra) {
    if (_eventsController.isClosed) return;
    _eventsController.add(<String, dynamic>{
      'type': type,
      'sessionId': sessionId,
      'text': '',
      'segment': '',
      'isSegment': false,
      'isInitial': false,
      'alternates': const <String>[],
      'segmentAlternates': const <String>[],
      'confidences': const <double>[],
      ...extra,
    });
  }

  static Map<String, dynamic> _parseEvent(dynamic event) {
    if (event is! Map) return <String, dynamic>{};

    final payload = Map<String, dynamic>.from(event);
    final text = '${payload['text'] ?? ''}';
    final segment = '${payload['segment'] ?? text}';

    payload['type'] = '${payload['type'] ?? ''}';
    payload['sessionId'] = payload['sessionId'];
    payload['text'] = text;
    payload['segment'] = segment;
    payload['isSegment'] = payload['isSegment'] == true;
    payload['isInitial'] = payload['isInitial'] == true;

    if (payload['rms'] is num) {
      payload['rms'] = (payload['rms'] as num).toDouble();
    }

    final parsedAlternates = (payload['alternates'] is List)
        ? (payload['alternates'] as List)
            .map((value) => '$value'.trim())
            .where((value) => value.isNotEmpty)
            .toList(growable: false)
        : <String>[];
    payload['alternates'] = parsedAlternates;

    if (payload['segmentAlternates'] is List) {
      payload['segmentAlternates'] = (payload['segmentAlternates'] as List)
          .map((value) => '$value'.trim())
          .where((value) => value.isNotEmpty)
          .toList(growable: false);
    } else {
      payload['segmentAlternates'] = parsedAlternates;
    }

    if (payload['confidences'] is List) {
      payload['confidences'] = (payload['confidences'] as List)
          .whereType<num>()
          .map((value) => value.toDouble())
          .toList(growable: false);
    } else {
      payload['confidences'] = <double>[];
    }

    return payload;
  }

  static Stream<Map<String, dynamic>> get events {
    if (!_useDesktopSpeech && !_useWindowsChromeSpeech) {
      _ensurePlatformStreamSubscribed();
    }
    return _eventsController.stream;
  }

  static Map<String, dynamic> _buildVoiceSettingsPayload() {
    return <String, dynamic>{
      'engine': AppCore.voiceRecognitionEngine,
      'autoRestart': AppCore.voiceAutoRestart,
      'possibleSilenceMs': AppCore.voicePossibleSilenceMs,
      'completeSilenceMs': AppCore.voiceCompleteSilenceMs,
      'minimumSpeechMs': AppCore.voiceMinimumSpeechMs,
      'restartDelayMs': AppCore.voiceRestartDelayMs,
    };
  }

  static Future<Map<String, dynamic>> getInfo() async {
    if (_useWindowsChromeSpeech) {
      final chrome = await _findChromeExecutable();
      return <String, dynamic>{
        'available': chrome != null,
        'provider': 'Google Chrome Speech',
        'locale': 'ar-KW',
        if (chrome == null) 'message': 'لم يتم العثور على Google Chrome في هذا الجهاز.',
      };
    }
    if (_useDesktopSpeech) {
      try {
        _desktopInitialized = await _desktopStt.initialize(
          onError: (SpeechRecognitionError err) {
            _emitDesktopEvent('error', _desktopSessionId, {
              'message': err.errorMsg.isNotEmpty
                  ? err.errorMsg
                  : 'خطأ في خدمة التعرف الصوتي على Windows.',
            });
          },
          onStatus: (String status) {
            if (status == 'done' || status == 'notListening') {
              _emitDesktopEvent('stopped', _desktopSessionId, {});
            } else if (status == 'listening') {
              _emitDesktopEvent('ready', _desktopSessionId, {});
            }
          },
        );
        if (!_desktopInitialized) {
          return <String, dynamic>{
            'available': false,
            'provider': 'Windows Speech',
            'message': 'تعذر تشغيل خدمة التعرف الصوتي في Windows.',
          };
        }
        final arabicLocale = await _resolveDesktopArabicLocale('ar-IQ');
        return <String, dynamic>{
          'available': arabicLocale != null,
          'frameworkAvailable': _desktopInitialized,
          'provider': 'Windows Speech',
          'locale': arabicLocale,
          if (_desktopLocaleError != null) 'message': _desktopLocaleError,
        };
      } catch (error) {
        return <String, dynamic>{
          'available': false,
          'provider': 'Windows Speech',
          'message': 'تعذر تهيئة التعرف الصوتي: $error',
        };
      }
    }

    final result = await _method.invokeMethod<dynamic>('getInfo');
    if (result is Map) return Map<String, dynamic>.from(result);
    return <String, dynamic>{'available': false};
  }

  static Future<bool> startListening({
    required int sessionId,
    String locale = 'ar-IQ',
    String? fieldKey,
    String? fieldType,
    bool? autoRestart,
    int? possibleSilenceMs,
    int? completeSilenceMs,
    int? minimumSpeechMs,
    int? restartDelayMs,
  }) async {
    await AppCore.ensureLoaded();
    _activeSessionId = sessionId;

    if (_useWindowsChromeSpeech) {
      final ready = await _ensureChromeSpeechServer();
      if (!ready) { _activeSessionId = null; return false; }
      _chromeSpeechCommand = 'start';
      return true;
    }

    if (_useDesktopSpeech) {
      _desktopSessionId = sessionId;
      try {
        if (!_desktopInitialized) {
          _desktopInitialized = await _desktopStt.initialize(
            onError: (SpeechRecognitionError err) {
              if (_desktopSessionId != sessionId) return;
              _emitDesktopEvent('error', sessionId, {
                'message': err.errorMsg.isNotEmpty
                    ? err.errorMsg
                    : 'تعذر التعرف على الكلام على سطح المكتب.',
              });
            },
            onStatus: (String status) {
              if (_desktopSessionId != sessionId) return;
              if (status == 'done' || status == 'notListening') {
                _activeSessionId = null;
                _emitDesktopEvent('stopped', sessionId, {});
              } else if (status == 'listening') {
                _emitDesktopEvent('ready', sessionId, {});
              }
            },
          );
        }
        if (!_desktopInitialized) {
          _activeSessionId = null;
          return false;
        }

        final arabicLocale = await _resolveDesktopArabicLocale(locale);
        if (arabicLocale == null) {
          _activeSessionId = null;
          _emitDesktopEvent('error', sessionId, {
            'message': _desktopLocaleError ??
                'لم يتم العثور على لغة عربية للتعرف الصوتي في Windows.',
          });
          return false;
        }

        await _desktopStt.listen(
          localeId: arabicLocale,
          // Do not publish unstable partial hypotheses to form fields.
          // Only a completed recognition result is allowed to update EMIS.
          partialResults: false,
          listenFor: const Duration(seconds: 30),
          pauseFor: Duration(
            milliseconds: (possibleSilenceMs ?? AppCore.voicePossibleSilenceMs)
                .clamp(1200, 5000),
          ),
          onResult: (SpeechRecognitionResult res) {
            if (_desktopSessionId != sessionId || !res.finalResult) return;
            final words = res.recognizedWords.trim();
            if (words.isEmpty || _containsLatinLetters(words)) return;

            // Ignore empty/noise hypotheses. Arabic words or numeric-only
            // values are accepted; English fallback output is never inserted.
            final hasArabic = _containsArabicLetters(words);
            final hasDigits = RegExp(r'[0-9٠-٩۰-۹]').hasMatch(words);
            if (!hasArabic && !hasDigits) return;

            final alts = res.alternates
                .map((a) => a.recognizedWords.trim())
                .where((w) =>
                    w.isNotEmpty &&
                    !_containsLatinLetters(w) &&
                    (_containsArabicLetters(w) ||
                        RegExp(r'[0-9٠-٩۰-۹]').hasMatch(w)))
                .toList(growable: false);
            _emitDesktopEvent('result', sessionId, {
              'text': words,
              'segment': words,
              'alternates': alts.isEmpty ? <String>[words] : alts,
              'segmentAlternates': alts.isEmpty ? <String>[words] : alts,
              'isFinal': true,
            });
          },
        );
        return true;
      } catch (_) {
        _activeSessionId = null;
        return false;
      }
    }

    _ensurePlatformStreamSubscribed();
    final result = await _method.invokeMethod<dynamic>('start', {
      'sessionId': sessionId,
      'locale': locale,
      ..._buildVoiceSettingsPayload(),
      if (autoRestart != null) 'autoRestart': autoRestart,
      if (possibleSilenceMs != null) 'possibleSilenceMs': possibleSilenceMs,
      if (completeSilenceMs != null) 'completeSilenceMs': completeSilenceMs,
      if (minimumSpeechMs != null) 'minimumSpeechMs': minimumSpeechMs,
      if (restartDelayMs != null) 'restartDelayMs': restartDelayMs,
    });
    if (result != true && _activeSessionId == sessionId) {
      _activeSessionId = null;
    }
    return result == true;
  }

  static Future<void> syncLiveSettings({
    String? fieldKey,
    String? fieldType,
  }) async {
    if (_useDesktopSpeech || _useWindowsChromeSpeech) return;
    try {
      await _method.invokeMethod<dynamic>(
        'updateSettings',
        _buildVoiceSettingsPayload(),
      );
    } catch (_) {}
  }

  static Future<void> stopListening() async {
    if (_useWindowsChromeSpeech) {
      final session = _activeSessionId;
      _chromeSpeechCommand = 'stop';
      _activeSessionId = null;
      _emitDesktopEvent('stopped', session, {});
      return;
    }
    if (_useDesktopSpeech) {
      try {
        await _desktopStt.stop();
      } catch (_) {}
      _activeSessionId = null;
      _emitDesktopEvent('stopped', _desktopSessionId, {});
      return;
    }
    return _method.invokeMethod('stop');
  }

  static Future<void> cancelListening() async {
    if (_useWindowsChromeSpeech) {
      final session = _activeSessionId;
      _activeSessionId = null;
      _chromeSpeechCommand = 'stop';
      _emitDesktopEvent('stopped', session, {});
      return;
    }
    if (_useDesktopSpeech) {
      try {
        await _desktopStt.cancel();
      } catch (_) {}
      _emitDesktopEvent('stopped', _desktopSessionId, {});
      return;
    }
    return _method.invokeMethod('cancel');
  }

  static Future<void> cancelListeningForSession(int? sessionId) async {
    if (sessionId == null || _activeSessionId != sessionId) return;
    _activeSessionId = null;
    try {
      if (_useWindowsChromeSpeech) {
        _chromeSpeechCommand = 'stop';
        _emitDesktopEvent('stopped', sessionId, {});
      } else if (_useDesktopSpeech) {
        await _desktopStt.cancel();
        _emitDesktopEvent('stopped', sessionId, {});
      } else {
        await _method.invokeMethod('cancel');
      }
    } catch (_) {}
  }
}
