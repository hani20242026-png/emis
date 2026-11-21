import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:permission_handler/permission_handler.dart';

import '../google_speech_service.dart';
import 'ai_action_dispatcher.dart';
import 'ai_command_parser.dart';
import 'ai_context_memory.dart';
import 'ai_draft_validator.dart';
import 'ai_intent_engine.dart';
import 'ai_response_service.dart';

enum AiAssistantState { idle, listening, processing }

class AiAssistantController {
  AiAssistantController._();
  static final AiAssistantController instance = AiAssistantController._();

  final memory = AiContextMemory();
  final dispatcher = AiActionDispatcher();
  final engine = AiIntentEngine();
  final responses = AiResponseService();
  final StreamController<void> _changes = StreamController<void>.broadcast();

  Stream<void> get changes => _changes.stream;
  StreamSubscription<Map<String, dynamic>>? _subscription;

  AiAssistantState state = AiAssistantState.idle;
  String transcript = '';
  String lastProcessedText = '';
  String reply = 'أهلاً، آني مساعد EMIS. شلون أگدر أساعدك؟';
  int _sessionId = 700000;
  int? _activeSessionId;
  bool _processingFinalResult = false;
  final List<String> _capturedSegments = <String>[];
  String _partialText = '';
  bool _manualFinishInProgress = false;
  Completer<void>? _manualFinishCompleter;
  Completer<void>? _finalSpeechResultCompleter;
  bool _disposed = false;
  bool _starting = false;
  bool _processingCommand = false;
  AiIntent? _activeCreationIntent;
  final Map<String, String> studentDraft = <String, String>{};
  final Map<String, String> teacherDraft = <String, String>{};
  Map<String, String> get employeeDraft => teacherDraft;
  void Function(Map<String, String> values)? onStudentDraftUpdated;
  void Function(Map<String, String> values)? onTeacherDraftUpdated;
  void Function(Map<String, String> values)? onEmployeeDraftUpdated;

  void _notify() {
    if (!_disposed && !_changes.isClosed) _changes.add(null);
  }

  Future<void> startListening({bool preserveTranscript = false}) async {
    if (_starting || state == AiAssistantState.listening ||
        state == AiAssistantState.processing) {
      return;
    }
    _starting = true;
    try {
      if (!Platform.isWindows && !Platform.isLinux && !Platform.isMacOS) {
        final permission = await Permission.microphone.request();
        if (!permission.isGranted) {
          reply = 'لم يُسمح باستخدام الميكروفون. امنح تطبيق EMIS صلاحية الميكروفون ثم أعد المحاولة.';
          state = AiAssistantState.idle;
          _notify();
          return;
        }
      }

      try { await GoogleSpeechService.cancelListening(); } catch (_) {}
      await _cancelRecognitionSubscription();
      _activeSessionId = null;
      if (!preserveTranscript) {
        transcript = '';
        _capturedSegments.clear();
        _partialText = '';
      }
      _processingFinalResult = false;
      _manualFinishInProgress = false;

      final session = ++_sessionId;
      _activeSessionId = session;
      state = AiAssistantState.listening;
      reply = 'أستمع إليك الآن... تحدث براحتك، واضغط إيقاف عند الانتهاء.';
      _notify();

      _subscription = GoogleSpeechService.events.listen(
        _onSpeechEvent,
        onError: (Object error) {
          if (_activeSessionId != session) return;
          reply = 'تعذر استقبال نتائج الميكروفون: $error';
          state = AiAssistantState.idle;
          _activeSessionId = null;
          unawaited(_cancelRecognitionSubscription());
          _notify();
        },
      );

      final started = await GoogleSpeechService.startListening(
        sessionId: session,
        locale: 'ar-IQ',
        autoRestart: true,
        possibleSilenceMs: 5000,
        completeSilenceMs: 7500,
        minimumSpeechMs: 900,
        restartDelayMs: 500,
      );
      if (!started && _activeSessionId == session) {
        reply = 'لم تبدأ خدمة التعرف الصوتي. تحقق من صلاحية الميكروفون وخدمة التعرف على الكلام.';
        state = AiAssistantState.idle;
        _activeSessionId = null;
        await _cancelRecognitionSubscription();
      }
    } catch (error) {
      reply = 'تعذر تشغيل الميكروفون: $error';
      state = AiAssistantState.idle;
      _activeSessionId = null;
      await _cancelRecognitionSubscription();
      try { await GoogleSpeechService.cancelListening(); } catch (_) {}
    } finally {
      _starting = false;
      _notify();
    }
  }

  void _appendFinalSegment(String value) {
    final segment = value.trim();
    if (segment.isEmpty) return;

    if (_capturedSegments.isEmpty) {
      _capturedSegments.add(segment);
    } else {
      final current = _capturedSegments.join(' ').trim();
      final a = current.split(RegExp(r'\s+'));
      final b = segment.split(RegExp(r'\s+'));

      if (segment == current || current.endsWith(segment)) {
      } else if (segment.startsWith(current)) {
        _capturedSegments
          ..clear()
          ..add(segment);
      } else if (current.startsWith(segment)) {
      } else {
        var overlap = 0;
        final maxOverlap = math.min(a.length, b.length);
        for (var count = maxOverlap; count > 0; count--) {
          final suffix = a.skip(a.length - count).toList();
          final prefix = b.take(count).toList();
          if (suffix.join(' ').toLowerCase() ==
              prefix.join(' ').toLowerCase()) {
            overlap = count;
            break;
          }
        }
        final remainder = b.skip(overlap).join(' ').trim();
        if (remainder.isNotEmpty) _capturedSegments.add(remainder);
      }
    }

    transcript = _capturedSegments.join(' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    _partialText = '';
  }

  void _onSpeechEvent(Map<String, dynamic> event) {
    final eventSession = event['sessionId'];
    if (_activeSessionId != null &&
        eventSession is num &&
        eventSession.toInt() != _activeSessionId) {
      return;
    }

    final type = '${event['type'] ?? ''}';
    final text = '${event['text'] ?? event['segment'] ?? ''}'.trim();

    if (type == 'ready' || type == 'listening' || type == 'begin') {
      reply = 'أستمع إليك. خذ وقتك، ويمكنك التوقف لالتقاط أنفاسك.';
      _notify();
    } else if (type == 'partial') {
      _partialText = text;
      final completed = _capturedSegments.join(' ').trim();
      transcript = [completed, _partialText]
          .where((part) => part.isNotEmpty)
          .join(' ');
      _notify();
    } else if (type == 'result' || type == 'final' || event['isFinal'] == true) {
      _appendFinalSegment(text.isNotEmpty ? text : _partialText);
      if (!(_finalSpeechResultCompleter?.isCompleted ?? true)) {
        _finalSpeechResultCompleter!.complete();
      }
      reply = 'تم التقاط جزء من كلامك. أكمل متى ما أردت، واضغط إيقاف عند الانتهاء.';
      _notify();
    } else if (type == 'error') {
      final message = '${event['message'] ?? ''}'.trim();
      reply = message.isNotEmpty
          ? '$message يمكنك إكمال كلامك؛ سأواصل الاستماع.'
          : 'توقف التعرف لحظة. يمكنك إكمال كلامك.';
      _notify();
    } else if (type == 'stopped') {
      if (state == AiAssistantState.listening && !_manualFinishInProgress) {
        state = AiAssistantState.idle;
        if (transcript.isEmpty) reply = 'لم ألتقط كلاماً. حاول مرة أخرى.';
      }
      _notify();
    } else {
      _notify();
    }
  }

  Future<void> finishListening() async {
    if (_manualFinishInProgress) {
      await _manualFinishCompleter?.future;
      return;
    }
    if (state != AiAssistantState.listening) return;
    _manualFinishInProgress = true;
    final finishCompleter = Completer<void>();
    _manualFinishCompleter = finishCompleter;
    reply = 'تم إيقاف التقاط الصوت. اضغط سهم الإرسال لتنفيذ الأمر.';
    _notify();
    try {
      final finalResult = Completer<void>();
      _finalSpeechResultCompleter = finalResult;
      await GoogleSpeechService.stopListening();
      try {
        await finalResult.future.timeout(const Duration(milliseconds: 1600));
      } on TimeoutException {
      }
      _finalSpeechResultCompleter = null;
      await _cancelRecognitionSubscription();
      _activeSessionId = null;
      state = AiAssistantState.idle;
      if (transcript.trim().isEmpty) {
        reply = 'لم ألتقط كلاماً واضحاً. يمكنك تشغيل الميكروفون والمحاولة مجدداً.';
      }
      _notify();
    } catch (error) {
      _finalSpeechResultCompleter = null;
      reply = 'تعذر إيقاف التقاط الصوت: $error';
      state = AiAssistantState.idle;
      await _cancelRecognitionSubscription();
      _activeSessionId = null;
      _notify();
    } finally {
      _manualFinishInProgress = false;
      finishCompleter.complete();
      _manualFinishCompleter = null;
    }
  }

  Future<void> executeCapturedCommand() async {
    if (_processingCommand) return;
    if (state == AiAssistantState.listening) {
      await finishListening();
    }
    final value = transcript.trim();
    if (value.isEmpty) {
      reply = 'لا يوجد كلام لتنفيذه. ابدأ التسجيل أولاً.';
      state = AiAssistantState.idle;
      _notify();
      return;
    }
    await processText(value);
  }

  Future<void> processText(String text) async {
    final value = text.trim();
    if (value.isEmpty || _processingCommand) return;
    _processingCommand = true;
    transcript = value;
    memory.add('المستخدم: $value');
    state = AiAssistantState.processing;
    reply = 'أحلل الأمر...';
    _notify();

    try {
      final activeBeforeUnderstanding = _activeCreationIntent;
      final draftBeforeUnderstanding = activeBeforeUnderstanding == AiIntent.addTeacher
          ? Map<String, String>.from(teacherDraft)
          : Map<String, String>.from(studentDraft);
      var command = await engine.understand(
        value,
        activeIntent: activeBeforeUnderstanding,
        currentDraft: draftBeforeUnderstanding,
      );
      if (command.intent == AiIntent.addStudent || command.intent == AiIntent.addTeacher) {
        _activeCreationIntent = command.intent;
      }
      final activeIntent = _activeCreationIntent;
      if (activeIntent == AiIntent.addStudent) {
        studentDraft.addAll(command.entities);
        onStudentDraftUpdated?.call(Map<String, String>.from(command.entities));
        command = AiCommand(AiIntent.addStudent, value, entities: Map<String, String>.unmodifiable(studentDraft));
      } else if (activeIntent == AiIntent.addTeacher) {
        final teacherValues = Map<String, String>.from(command.entities);
        if (teacherValues.containsKey('homePhoneNumber') &&
            !teacherValues.containsKey('mobilePhoneNumber')) {
          teacherValues['mobilePhoneNumber'] = teacherValues.remove('homePhoneNumber')!;
        }
        teacherDraft.addAll(teacherValues);
        onTeacherDraftUpdated?.call(teacherValues);
        onEmployeeDraftUpdated?.call(teacherValues);
        command = AiCommand(AiIntent.addTeacher, value, entities: Map<String, String>.unmodifiable(teacherDraft));
      }
      reply = await dispatcher.dispatch(command);
      if (reply.isEmpty) reply = responses.responseFor(command);
      if (!engine.usedLlmLastTurn && engine.llm.lastError != null) {
        reply = '$reply\n\nملاحظة: نموذج الذكاء الاصطناعي المحلي لم يعمل، لذلك استُخدم المحلل الاحتياطي. تأكد من تضمين ملف GGUF في بناء التطبيق.';
      }

      if (activeIntent == AiIntent.addStudent) {
        final warning = AiDraftValidator.warningText(studentDraft);
        if (warning.isNotEmpty) reply = '$reply\n\n$warning';
      } else if (activeIntent == AiIntent.addTeacher) {
        final warning = AiDraftValidator.warningText(teacherDraft);
        if (warning.isNotEmpty) reply = '$reply\n\n$warning';
      }
      memory.add('المساعد: $reply');
      lastProcessedText = value;
      transcript = '';
      _capturedSegments.clear();
      _partialText = '';
      state = AiAssistantState.idle;
      await _stopAndDetach();
      _notify();
    } catch (error) {
      reply = 'حدث خطأ أثناء تنفيذ الأمر: $error';
      lastProcessedText = value;
      transcript = '';
      _capturedSegments.clear();
      _partialText = '';
      state = AiAssistantState.idle;
      await _stopAndDetach();
      _notify();
    } finally {
      _processingCommand = false;
    }
  }

  void endStudentCreation() {
    if (_activeCreationIntent == AiIntent.addStudent) _activeCreationIntent = null;
    studentDraft.clear();
    onStudentDraftUpdated = null;
  }

  void endTeacherCreation() {
    if (_activeCreationIntent == AiIntent.addTeacher) _activeCreationIntent = null;
    teacherDraft.clear();
    onTeacherDraftUpdated = null;
  }

  void endEmployeeCreation() {
    if (_activeCreationIntent == AiIntent.addTeacher) _activeCreationIntent = null;
    teacherDraft.clear();
    onEmployeeDraftUpdated = null;
  }

  void clearConversation() {
    memory.clear();
    _activeCreationIntent = null;
    studentDraft.clear();
    teacherDraft.clear();
    onEmployeeDraftUpdated = null;
    _capturedSegments.clear();
    _partialText = '';
    transcript = '';
    lastProcessedText = '';
    reply = 'تم مسح سياق المحادثة. يمكنك البدء بأمر جديد.';
    _notify();
  }

  Future<void> _cancelRecognitionSubscription() async {
    await _subscription?.cancel();
    _subscription = null;
  }

  Future<void> _stopAndDetach() async {
    try {
      await GoogleSpeechService.cancelListening();
    } catch (_) {
      try { await GoogleSpeechService.stopListening(); } catch (_) {}
    }
    await _cancelRecognitionSubscription();
    _activeSessionId = null;
    _processingFinalResult = false;
    _manualFinishInProgress = false;
    if (state == AiAssistantState.listening) state = AiAssistantState.idle;
  }

  Future<void> stopListening() async {
    await _stopAndDetach();
    _notify();
  }

  void dispose() {
    _disposed = true;
    _subscription?.cancel();
    _changes.close();
  }
}
