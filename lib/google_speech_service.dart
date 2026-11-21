import 'dart:async';
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

  static bool get _useDesktopSpeech =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  static int nextSessionId() => ++_globalSessionCounter;

  static int? get activeSessionId => _activeSessionId;

  static void _ensurePlatformStreamSubscribed() {
    if (_useDesktopSpeech) return;
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
    if (!_useDesktopSpeech) {
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
                    : 'تعذر التعرف على الكلام على Windows.',
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
    if (_useDesktopSpeech) return;
    try {
      await _method.invokeMethod<dynamic>(
        'updateSettings',
        _buildVoiceSettingsPayload(),
      );
    } catch (_) {}
  }

  static Future<void> stopListening() async {
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
    _activeSessionId = null;
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
      if (_useDesktopSpeech) {
        await _desktopStt.cancel();
        _emitDesktopEvent('stopped', sessionId, {});
      } else {
        await _method.invokeMethod('cancel');
      }
    } catch (_) {}
  }
}
