import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:excel/excel.dart' hide Border;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'central_keyboard_navigation.dart';
import 'package:http/http.dart' as http;
import 'package:speech_to_text/speech_recognition_error.dart';
import 'app_core.dart';
import 'google_speech_service.dart';
import 'legacy_speech_service.dart';
import 'platform_permissions.dart';

class StudentDataAuditorScreen extends StatefulWidget {
  final String token;
  final String schoolId;
  final List<dynamic> allStudents;

  const StudentDataAuditorScreen({
    super.key,
    required this.token,
    required this.schoolId,
    required this.allStudents,
  });

  @override
  State<StudentDataAuditorScreen> createState() =>
      _StudentDataAuditorScreenState();
}

class _AddressFieldDef {
  final String key;
  final String label;
  const _AddressFieldDef(this.key, this.label);
}

const List<_AddressFieldDef> _addressTextFields = [
  _AddressFieldDef('town', 'المدينة/القرية'),
  _AddressFieldDef('area', 'الحي'),
  _AddressFieldDef('quarter', 'المحلة'),
  _AddressFieldDef('street', 'زقاق'),
  _AddressFieldDef('address1', 'عنوان 1'),
  _AddressFieldDef('address2', 'عنوان 2'),
  _AddressFieldDef('closestLocation', 'أقرب نقطة دالة'),
];

class _AuditItem {
  final Map<String, dynamic> student;
  final bool idMatched;
  final int idDigitsCount;
  final bool phoneMatched;
  final String phoneReason;
  final bool addrMatched;
  final int addrFilledCount;
  final List<String> addrFilledNames;

  _AuditItem({
    required this.student,
    required this.idMatched,
    required this.idDigitsCount,
    required this.phoneMatched,
    required this.phoneReason,
    required this.addrMatched,
    required this.addrFilledCount,
    required this.addrFilledNames,
  });
}

class _VoiceTargetInfo {
  final String fieldId;
  final Map<String, dynamic> student;
  final String sId;
  final String category; // 'student' | 'ident' | 'phone' | 'addr'
  final String key;
  final bool isNumeric;

  const _VoiceTargetInfo({
    required this.fieldId,
    required this.student,
    required this.sId,
    required this.category,
    required this.key,
    required this.isNumeric,
  });
}

class _StudentDataAuditorScreenState extends State<StudentDataAuditorScreen>
    with SingleTickerProviderStateMixin {
  bool _chkId = true;
  bool _chkPhone = true;
  bool _chkAddr = true;
  String _matchMode = 'OR';

  String _selectedStage = '';
  String _selectedRoom = '';
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();

  final Map<String, TextEditingController> _fieldControllers = {};

  bool _controlsCollapsed = false;
  bool _isScanning = false;
  bool _isSavingAll = false;
  double _progressValue = 0.0;
  String _progressText = '';

  final List<Map<String, dynamic>> _allFullStudents = [];
  List<_AuditItem> _matchedStudents = [];
  List<dynamic> _countryStructure = [];
  int _nationalCardTypeId = 12;

  final Set<String> _modifiedIds = {};
  final Map<String, String> _cardStatusText = {};
  final Map<String, bool> _cardStatusSuccess = {};
  final Set<String> _savingSingleIds = {};

  StreamSubscription<dynamic>? _googleSpeechSubscription;
  bool _speechListening = false;
  String? _activeVoiceField;
  _VoiceTargetInfo? _activeVoiceTarget;
  _VoiceTargetInfo? _pendingVoiceTarget;
  int? _activeVoiceSessionId;
  int _nextVoiceSessionId = 0;
  String _sessionRecognizedText = '';
  bool _speechStopRequested = false;
  bool _micPointerDown = false;
  bool _legacySpeechInitialized = false;
  bool _legacySpeechAvailable = false;
  Timer? _legacyFinalizationTimer;
  Timer? _googleFinalizationTimer;
  late final AnimationController _ambientController;
  late final CentralKeyboardNavigator _centralNav;

  Map<String, String> get _headers => {
        'Authorization': widget.token.toLowerCase().startsWith('bearer ')
            ? widget.token
            : 'Bearer ${widget.token}',
        'Accept': 'application/json, text/plain, */*',
        'Content-Type': 'application/json',
        'User-Agent':
            'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
      };

  List<String> _buildCentralKeyboardSequence() {
    final seq = <String>[
      'search_query',
    ];
    for (final item in _matchedStudents) {
      final sId = item.student['id'].toString();
      seq.addAll([
        '${sId}_student_fathersGrandFatherName',
        '${sId}_student_surName',
        '${sId}_ident_idNumber',
        '${sId}_phone_homePhoneNumber',
        ..._addressTextFields.map((f) => '${sId}_addr_${f.key}'),
      ]);
    }
    return seq;
  }

  @override
  void initState() {
    super.initState();
    _ambientController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 6),
    )..repeat();

    _centralNav = CentralKeyboardNavigator(
      sequenceBuilder: _buildCentralKeyboardSequence,
      onFieldFocused: (_) {},
      shouldSkipField: AppCore.hasConfiguredDefaultForStudentField,
    );

    AppCore.ensureLoaded();
    _googleSpeechSubscription =
        GoogleSpeechService.events.listen(_handleGoogleSpeechEvent);
  }

  @override
  void dispose() {
    _ambientController.dispose();
    _centralNav.dispose();
    _searchController.dispose();
    for (final ctrl in _fieldControllers.values) {
      ctrl.dispose();
    }
    _fieldControllers.clear();
    _googleSpeechSubscription?.cancel();
    _legacyFinalizationTimer?.cancel();
    _googleFinalizationTimer?.cancel();
    unawaited(GoogleSpeechService.cancelListening());
    unawaited(LegacySpeechService.cancel());
    super.dispose();
  }

  TextEditingController _getController(String fieldId, String currentValue) {
    return _fieldControllers.putIfAbsent(
      fieldId,
      () => TextEditingController(text: currentValue),
    );
  }

  void _clearFieldControllers() {
    for (final ctrl in _fieldControllers.values) {
      ctrl.dispose();
    }
    _fieldControllers.clear();
  }

  bool get _voiceAvailableBySetting => AppCore.voiceInputEnabled;
  bool get _usingLegacyVoice => AppCore.voiceRecognitionEngine == 'legacy';

  void _showVoiceMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message, style: const TextStyle(fontWeight: FontWeight.bold)), backgroundColor: const Color(0xFFF59E0B), behavior: SnackBarBehavior.floating),
    );
  }

  Future<bool> _ensureMicrophoneAccess() async {
    await AppCore.ensureLoaded();
    if (!_voiceAvailableBySetting) {
      _showVoiceMessage('الميكروفون مغلق من الإعدادات.');
      return false;
    }
    if (await ensureEmisMicrophonePermission()) return true;
    _showVoiceMessage('لم يتم منح صلاحية الميكروفون.');
    return false;
  }

  String _cleanArabicSpeech(String value) {
    var out = value.replaceAll(RegExp(r'[A-Za-z]'), '');
    out = out.replaceAll(RegExp(r'[\u0000-\u001F]'), '');
    out = out.replaceAll(RegExp(r'\s+'), ' ').trim();
    return out;
  }

  String _cleanNumericSpeech(String value) {
    const arabicIndic = '٠١٢٣٤٥٦٧٨٩';
    const easternArabicIndic = '۰۱۲۳۴۵۶۷۸۹';
    const wordDigits = <String, String>{
      'صفر': '0',
      'واحد': '1',
      'واحدة': '1',
      'اثنان': '2',
      'اثنين': '2',
      'اثنتان': '2',
      'اثنتين': '2',
      'ثلاثة': '3',
      'ثلاث': '3',
      'أربعة': '4',
      'اربعة': '4',
      'خمسة': '5',
      'خمس': '5',
      'ستة': '6',
      'ست': '6',
      'سبعة': '7',
      'سبع': '7',
      'ثمانية': '8',
      'ثماني': '8',
      'تسعة': '9',
      'تسع': '9',
    };

    final normalized = value.replaceAll('،', ' ').replaceAll(',', ' ');
    final words = normalized.split(RegExp(r'\s+')).where((x) => x.isNotEmpty);
    final out = StringBuffer();
    for (final raw in words) {
      final word = raw.replaceAll(RegExp(r'[.\-_/]'), '');
      if (word.isEmpty) continue;
      final mapped = wordDigits[word.toLowerCase()];
      if (mapped != null) {
        out.write(mapped);
        continue;
      }
      for (final rune in word.runes) {
        final ch = String.fromCharCode(rune);
        final a = arabicIndic.indexOf(ch);
        if (a >= 0) {
          out.write(a);
          continue;
        }
        final e = easternArabicIndic.indexOf(ch);
        if (e >= 0) {
          out.write(e);
          continue;
        }
        if (RegExp(r'[0-9]').hasMatch(ch)) out.write(ch);
      }
    }
    return out.toString();
  }

  void _updateStudentPhoneData(Map<String, dynamic> student, String cleanPhone) {
    student['homePhoneNumber'] = cleanPhone;
    if (student.containsKey('mobilePhoneNumber')) {
      student['mobilePhoneNumber'] = cleanPhone;
    }
    if (student.containsKey('phoneNumber')) {
      student['phoneNumber'] = cleanPhone;
    }
    if (student.containsKey('phone')) {
      student['phone'] = cleanPhone;
    }
    if (student['address'] is! Map<String, dynamic>) {
      student['address'] = student['address'] is Map
          ? Map<String, dynamic>.from(student['address'])
          : <String, dynamic>{};
    }
    final addr = student['address'] as Map<String, dynamic>;
    addr['homePhoneNumber'] = cleanPhone;
    if (addr.containsKey('mobilePhoneNumber')) {
      addr['mobilePhoneNumber'] = cleanPhone;
    }
    if (addr.containsKey('phoneNumber')) {
      addr['phoneNumber'] = cleanPhone;
    }
    if (addr.containsKey('schoolPhoneNumber') &&
        addr['schoolPhoneNumber']?.toString().trim().isNotEmpty == true) {
      addr['schoolPhoneNumber'] = cleanPhone;
    }
  }

  void _applyRecognizedText(_VoiceTargetInfo target, String text) {
    final student = target.student;
    final sId = target.sId;
    final key = target.key;

    final ctrl = _fieldControllers[target.fieldId];
    if (ctrl != null) {
      ctrl.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
    }

    setState(() {
      if (target.category == 'student') {
        student[key] = text;
      } else if (target.category == 'ident') {
        if (student['identification'] is! Map<String, dynamic>) {
          student['identification'] = student['identification'] is Map
              ? Map<String, dynamic>.from(student['identification'])
              : <String, dynamic>{};
        }
        student['identification']['idType'] = _nationalCardTypeId;
        student['identification']['idNumber'] = text;
        student['idNumber'] = text;
      } else if (target.category == 'phone') {
        _updateStudentPhoneData(student, text);
      } else if (target.category == 'addr') {
        if (student['address'] is! Map<String, dynamic>) {
          student['address'] = student['address'] is Map
              ? Map<String, dynamic>.from(student['address'])
              : <String, dynamic>{};
        }
        student['address'][key] = text;
      }
      _modifiedIds.add(sId);
    });
  }

  Future<bool> _initLegacySpeech() async {
    if (_legacySpeechInitialized) return _legacySpeechAvailable;
    _legacySpeechAvailable = await LegacySpeechService.initialize(
      onStatus: (status) {
        if (!mounted || !_usingLegacyVoice) return;
        final listening = status == 'listening';
        setState(() => _speechListening = listening);
        if (!listening &&
            (_activeVoiceSessionId != null || _speechStopRequested)) {
          _scheduleLegacyFinalization();
        }
      },
      onError: (SpeechRecognitionError error) {
        if (!mounted || !_usingLegacyVoice) return;
        setState(() => _speechListening = false);
        _scheduleLegacyFinalization();
      },
    );
    _legacySpeechInitialized = true;
    return _legacySpeechAvailable;
  }

  void _scheduleLegacyFinalization() {
    _legacyFinalizationTimer?.cancel();
    _legacyFinalizationTimer = Timer(const Duration(milliseconds: 450), () {
      if (!mounted || !_usingLegacyVoice) return;
      _finishLegacyVoiceSessionAndStartPending();
    });
  }

  Future<void> _finishLegacyVoiceSessionAndStartPending() async {
    _legacyFinalizationTimer?.cancel();
    _legacyFinalizationTimer = null;
    final pending = _pendingVoiceTarget;
    _pendingVoiceTarget = null;
    _speechStopRequested = false;
    _activeVoiceSessionId = null;
    _activeVoiceField = null;
    _activeVoiceTarget = null;
    _sessionRecognizedText = '';
    if (mounted) setState(() => _speechListening = false);
    if (pending != null && mounted && _usingLegacyVoice) {
      await Future<void>.delayed(const Duration(milliseconds: 80));
      if (mounted) await _startVoiceSession(pending);
    }
  }

  Future<void> _startLegacyVoiceSession(_VoiceTargetInfo target) async {
    if (!mounted) return;
    final available = await _initLegacySpeech();
    if (!available || !mounted) {
      _showVoiceMessage('خدمة التعرف الصوتي غير متوفرة على هذا الجهاز.');
      return;
    }

    final sessionId = ++_nextVoiceSessionId;
    _activeVoiceSessionId = sessionId;
    _activeVoiceField = target.fieldId;
    _activeVoiceTarget = target;
    _sessionRecognizedText = '';
    _speechStopRequested = false;
    setState(() => _speechListening = true);

    try {
      await LegacySpeechService.listen(
        onResult: (dynamic result) {
          if (!mounted ||
              !_usingLegacyVoice ||
              _activeVoiceSessionId != sessionId) return;
          final raw = '${result.recognizedWords ?? ''}'.trim();
          if (raw.isEmpty) return;
          final text = target.isNumeric
              ? _cleanNumericSpeech(raw)
              : _cleanArabicSpeech(raw);
          if (text.isEmpty) return;
          _sessionRecognizedText = text;
          _applyRecognizedText(target, text);
          if (result.finalResult == true) {
            _finishLegacyVoiceSessionAndStartPending();
          }
        },
      );
    } catch (e) {
      if (!mounted) return;
      _scheduleLegacyFinalization();
    }
  }

  void _requestLegacySpeechStop({_VoiceTargetInfo? nextTarget}) {
    if (nextTarget != null) _pendingVoiceTarget = nextTarget;
    if (_activeVoiceSessionId == null) return;
    if (_speechStopRequested) return;
    _speechStopRequested = true;
    if (mounted) setState(() => _speechListening = false);
    unawaited(
        LegacySpeechService.stop().whenComplete(_scheduleLegacyFinalization));
  }

  void _scheduleGoogleFinalizationFallback() {
    _googleFinalizationTimer?.cancel();
    _googleFinalizationTimer =
        Timer(Duration(milliseconds: AppCore.voiceFinalizationTimeoutMs), () {
      if (!mounted || _usingLegacyVoice) return;
      if (_activeVoiceSessionId != null && _speechStopRequested) {
        _finishVoiceSessionAndStartPending();
      }
    });
  }

  void _handleGoogleSpeechEvent(Map<String, dynamic> event) {
    if (!mounted) return;
    final sessionId = int.tryParse('${event['sessionId'] ?? ''}');
    if (sessionId == null || sessionId != _activeVoiceSessionId) return;

    final type = '${event['type'] ?? ''}';
    final target = _activeVoiceTarget;
    if (target == null) return;

    if (type == 'listening' ||
        type == 'ready' ||
        type == 'begin' ||
        type == 'partial') {
      if (!_speechListening) setState(() => _speechListening = true);
    }

    if (type == 'partial' || type == 'result') {
      final alternates = (event['alternates'] is List)
          ? (event['alternates'] as List).map((e) => '$e').toList()
          : <String>[];
      final candidates = <String>[
        '${event['text'] ?? event['result'] ?? event['transcript'] ?? ''}',
        ...alternates,
      ].map((e) => e.trim()).where((e) => e.isNotEmpty).toList();

      String text = '';
      for (final raw in candidates) {
        final cleaned = target.isNumeric
            ? _cleanNumericSpeech(raw)
            : _cleanArabicSpeech(raw);
        if (cleaned.isNotEmpty) {
          text = cleaned;
          break;
        }
      }

      if (text.isNotEmpty) {
        final shouldApply = type == 'result' ||
            !_speechStopRequested ||
            _sessionRecognizedText.isEmpty ||
            text.length >= _sessionRecognizedText.length;
        if (shouldApply) {
          _sessionRecognizedText = text;
          _applyRecognizedText(target, text);
        }
      }
    }

    if (type == 'error') {
      if (_speechStopRequested) {
        _finishVoiceSessionAndStartPending();
      } else if (!AppCore.voiceAutoRestart) {
        setState(() => _speechListening = false);
      }
      return;
    }

    if (type == 'result') {
      if (_speechStopRequested) {
        _finishVoiceSessionAndStartPending();
      }
    }

    if (type == 'stopped' && !_speechStopRequested) {
      setState(() {
        _speechListening = false;
        _activeVoiceSessionId = null;
        _activeVoiceField = null;
        _activeVoiceTarget = null;
        _sessionRecognizedText = '';
      });
    }
  }

  Future<void> _startVoiceSession(_VoiceTargetInfo target) async {
    if (!mounted) return;
    if (!await _ensureMicrophoneAccess()) return;
    if (_usingLegacyVoice) {
      await _startLegacyVoiceSession(target);
      return;
    }

    final info = await GoogleSpeechService.getInfo();
    if (info['available'] != true) {
      _showVoiceMessage('خدمة Google للتعرف على الكلام غير متوفرة.');
      return;
    }

    final sessionId = ++_nextVoiceSessionId;
    _activeVoiceSessionId = sessionId;
    _activeVoiceField = target.fieldId;
    _activeVoiceTarget = target;
    _sessionRecognizedText = '';
    _speechStopRequested = false;
    if (mounted) {
      setState(() => _speechListening = true);
    }

    final started = await GoogleSpeechService.startListening(
      sessionId: sessionId,
      locale: 'ar-IQ',
    );
    if (!started && mounted && _activeVoiceSessionId == sessionId) {
      setState(() {
        _speechListening = false;
        _activeVoiceSessionId = null;
        _activeVoiceField = null;
        _activeVoiceTarget = null;
        _sessionRecognizedText = '';
      });
    }
  }

  void _requestSpeechStop({_VoiceTargetInfo? nextTarget}) {
    if (_usingLegacyVoice) {
      _requestLegacySpeechStop(nextTarget: nextTarget);
      return;
    }
    if (nextTarget != null) _pendingVoiceTarget = nextTarget;
    if (_activeVoiceSessionId == null) {
      final pending = _pendingVoiceTarget;
      if (pending != null) {
        _pendingVoiceTarget = null;
        _startVoiceSession(pending);
      }
      return;
    }
    if (_speechStopRequested) return;

    _speechStopRequested = true;
    setState(() => _speechListening = false);
    _scheduleGoogleFinalizationFallback();
    unawaited(GoogleSpeechService.stopListening());
  }

  Future<void> _finishVoiceSessionAndStartPending() async {
    _googleFinalizationTimer?.cancel();
    _googleFinalizationTimer = null;
    final pending = _pendingVoiceTarget;
    _pendingVoiceTarget = null;
    _speechStopRequested = false;
    _activeVoiceSessionId = null;
    _activeVoiceField = null;
    _activeVoiceTarget = null;
    _sessionRecognizedText = '';
    if (mounted) setState(() => _speechListening = false);

    if (pending != null && mounted) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      if (mounted) await _startVoiceSession(pending);
    }
  }

  Future<void> _toggleAuditMic({
    required Map<String, dynamic> student,
    required String sId,
    required String category,
    required String key,
    bool isNumeric = false,
  }) async {
    final fieldId = '${sId}_${category}_$key';
    if (!_voiceAvailableBySetting) {
      _showVoiceMessage('الميكروفون مغلق من الإعدادات.');
      return;
    }

    final target = _VoiceTargetInfo(
      fieldId: fieldId,
      student: student,
      sId: sId,
      category: category,
      key: key,
      isNumeric: isNumeric,
    );

    if (_activeVoiceField == fieldId && _activeVoiceSessionId != null) {
      _pendingVoiceTarget = null;
      _requestSpeechStop();
      return;
    }
    if (_activeVoiceSessionId != null) {
      _pendingVoiceTarget = target;
      _requestSpeechStop(nextTarget: target);
      return;
    }
    await _startVoiceSession(target);
  }

  void _markMicPointerDown() {
    _micPointerDown = true;
    Future<void>.microtask(() => _micPointerDown = false);
  }

  void _stopVoiceFromPointer() {
    if (_micPointerDown) {
      _micPointerDown = false;
      return;
    }
    if (_activeVoiceSessionId != null) {
      _pendingVoiceTarget = null;
      _requestSpeechStop();
    }
  }

  Widget _buildMicIconButton({
    required Map<String, dynamic> student,
    required String sId,
    required String category,
    required String key,
    bool isNumeric = false,
    double iconSize = 22,
  }) {
    final fieldId = '${sId}_${category}_$key';
    final isActive = _speechListening && _activeVoiceField == fieldId;
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (_) => _markMicPointerDown(),
      child: IconButton(
        tooltip: 'الإدخال الصوتي',
        icon: Icon(
          isActive ? Icons.mic_rounded : Icons.mic_none_rounded,
          size: iconSize,
          color: isActive
              ? Colors.red
              : (AppCore.voiceInputEnabled
                  ? const Color(0xFFA855F7)
                  : Colors.grey.shade400),
        ),
        onPressed: () => _toggleAuditMic(
          student: student,
          sId: sId,
          category: category,
          key: key,
          isNumeric: isNumeric,
        ),
      ),
    );
  }

  Widget _collapsedControlsHandle(Color cardColor, bool isDark) {
    const purpleNeon = Color(0xFFA855F7);
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 6),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: purpleNeon.withOpacity(isDark ? 0.35 : 0.25)),
      ),
      child: Center(
        child: IconButton(
          tooltip: 'إظهار أدوات البحث',
          icon: Icon(Icons.keyboard_arrow_down_rounded,
              size: 32,
              color: isDark ? Colors.white : const Color(0xFF0F172A)),
          onPressed: () => setState(() => _controlsCollapsed = false),
        ),
      ),
    );
  }

  String _normalizeDigits(dynamic input) {
    if (input == null) return '';
    const arabicIndic = '٠١٢٣٤٥٦٧٨٩';
    const easternArabicIndic = '۰۱۲۳۴۵۶۷۸۹';
    final s = input.toString();
    final buffer = StringBuffer();
    for (int i = 0; i < s.length; i++) {
      final ch = s[i];
      final aIdx = arabicIndic.indexOf(ch);
      if (aIdx >= 0) {
        buffer.write(aIdx);
        continue;
      }
      final eIdx = easternArabicIndic.indexOf(ch);
      if (eIdx >= 0) {
        buffer.write(eIdx);
        continue;
      }
      buffer.write(ch);
    }
    return buffer.toString();
  }

  String _extractDigitsOnly(dynamic input) {
    return _normalizeDigits(input).replaceAll(RegExp(r'[^0-9]'), '');
  }

  String _getStudentFullName(Map<String, dynamic> s) {
    final direct = (s['fullName'] ?? s['studentName'] ?? '').toString().trim();
    if (direct.isNotEmpty) return direct;
    final parts = [
      s['name'],
      s['firstName'],
      s['fatherName'],
      s['grandFatherName'],
      s['fathersGrandFatherName'],
      s['surName'],
    ]
        .map((x) => x == null ? '' : x.toString().trim())
        .where((x) => x.isNotEmpty)
        .toList();
    return parts.isNotEmpty ? parts.join(' ') : 'بدون اسم';
  }

  String _extractStudentPhone(Map<String, dynamic> s) {
    final addr =
        s['address'] is Map ? Map<String, dynamic>.from(s['address']) : {};
    final candidates = [
      s['homePhoneNumber'],
      addr['mobilePhoneNumber'],
      s['mobilePhoneNumber'],
      addr['homePhoneNumber'],
      addr['schoolPhoneNumber'],
      addr['phoneNumber'],
      s['phoneNumber'],
      s['phone'],
    ];
    for (final c in candidates) {
      if (c != null) {
        final trimmed = c.toString().trim();
        if (trimmed.isNotEmpty &&
            trimmed.toLowerCase() != 'null' &&
            trimmed != '-') {
          return trimmed;
        }
      }
    }
    return '';
  }

  Map<String, dynamic> _extractStudentIdInfo(Map<String, dynamic> s) {
    final ident = s['identification'] is Map
        ? Map<String, dynamic>.from(s['identification'])
        : <String, dynamic>{};
    final idType = ident['idType'] ?? s['idType'];
    final rawNumber = ident['idNumber'] ??
        s['idNumber'] ??
        s['nationalIdNumber'] ??
        ident['jinsiyaIdNumber'] ??
        ident['birthCertificateNumber'] ??
        ident['otherIdNumber'] ??
        '';
    final cleanDigits = _extractDigitsOnly(rawNumber);
    return {
      'idType': idType,
      'rawNumber': rawNumber.toString().trim(),
      'cleanDigits': cleanDigits,
    };
  }

  String? _normalizeDateForSave(dynamic value) {
    if (value == null) return null;
    final raw = value.toString().trim();
    if (raw.isEmpty) return null;
    final iso = RegExp(r'^(\d{4})[-/](\d{1,2})[-/](\d{1,2})').firstMatch(raw);
    if (iso != null) {
      return '${iso.group(1)!.padLeft(4, '0')}-${iso.group(2)!.padLeft(2, '0')}-${iso.group(3)!.padLeft(2, '0')}';
    }
    final dmy = RegExp(r'^(\d{1,2})[-/](\d{1,2})[-/](\d{4})$').firstMatch(raw);
    if (dmy != null) {
      return '${dmy.group(3)!.padLeft(4, '0')}-${dmy.group(2)!.padLeft(2, '0')}-${dmy.group(1)!.padLeft(2, '0')}';
    }
    return raw.split('T').first;
  }

  Map<String, dynamic> _checkIdCondition(Map<String, dynamic> s) {
    final info = _extractStudentIdInfo(s);
    final digits = info['cleanDigits'] as String;
    final len = digits.length;
    return {
      'matched': len != 12,
      'digitsCount': len,
    };
  }

  Map<String, dynamic> _checkPhoneCondition(Map<String, dynamic> s) {
    final rawPhone = _extractStudentPhone(s);
    final digits = _extractDigitsOnly(rawPhone);
    if (digits.isEmpty) {
      return {
        'matched': true,
        'reason': 'لا يوجد رقم هاتف',
      };
    }
    final zeroCount = '0'.allMatches(digits).length;
    if (zeroCount >= 5) {
      return {
        'matched': true,
        'reason': 'يحتوي على $zeroCount أصفار',
      };
    }
    return {
      'matched': false,
      'reason': '',
    };
  }

  Map<String, dynamic> _checkAddressCondition(Map<String, dynamic> s) {
    final addr = s['address'] is Map
        ? Map<String, dynamic>.from(s['address'])
        : <String, dynamic>{};
    int filledCount = 0;
    int textOnlyCount = 0;
    final List<String> filledNames = [];

    final csId = addr['countryStructureId']?.toString().trim() ?? '';
    if (csId.isNotEmpty && csId != '0' && csId.toLowerCase() != 'null') {
      filledCount++;
      filledNames.add('الموقع الجغرافي');
    }

    for (final f in _addressTextFields) {
      final val = addr[f.key]?.toString().trim() ?? '';
      // Treat null, empty strings, and the placeholder value 0 consistently
      // across the audit screen and the exported Excel report.
      if (val.isNotEmpty &&
          val != '0' &&
          val.toLowerCase() != 'null') {
        filledCount++;
        textOnlyCount++;
        filledNames.add(f.label);
      }
    }

    final isMatched = (filledCount >= 1 && filledCount <= 3) ||
        (textOnlyCount >= 1 && textOnlyCount <= 3);

    return {
      'matched': isMatched,
      'filledCount': filledCount,
      'filledNames': filledNames,
    };
  }

  dynamic _decodeResponse(http.Response res) {
    try {
      final text = utf8.decode(res.bodyBytes, allowMalformed: true).trim();
      if (text.isEmpty) return {};
      return jsonDecode(text);
    } catch (_) {
      return {};
    }
  }

  List<dynamic> _unwrapList(dynamic decoded) {
    if (decoded == null) return [];
    if (decoded is List) return decoded;
    if (decoded is Map) {
      const keys = [
        'data',
        'items',
        'result',
        'results',
        'records',
        'value',
        'students',
        'list'
      ];
      for (final k in keys) {
        if (decoded[k] is List) return decoded[k] as List;
        if (decoded[k] is Map) {
          for (final sub in keys) {
            if (decoded[k][sub] is List) return decoded[k][sub] as List;
          }
        }
      }
      for (final v in decoded.values) {
        if (v is List) return v;
      }
    }
    return [];
  }

  Map<String, dynamic> _unwrapMap(dynamic decoded) {
    if (decoded is Map) {
      if (decoded['data'] is Map) {
        return Map<String, dynamic>.from(decoded['data']);
      }
      if (decoded['result'] is Map) {
        return Map<String, dynamic>.from(decoded['result']);
      }
      return Map<String, dynamic>.from(decoded);
    }
    return {};
  }

  Future<void> _loadReferenceCatalogs() async {
    try {
      final resId = await http
          .get(
            Uri.parse(
                'https://emis.moedu.gov.iq/api/selectoption/IdentificationType'),
            headers: _headers,
          )
          .timeout(const Duration(seconds: 15));
      if (resId.statusCode == 200) {
        final list = _unwrapList(_decodeResponse(resId));
        for (final item in list) {
          if (item is Map) {
            final txt = (item['displayName'] ??
                    item['name'] ??
                    item['label'] ??
                    item['text'] ??
                    '')
                .toString();
            final val =
                int.tryParse((item['value'] ?? item['id'] ?? '').toString()) ??
                    0;
            if (txt.contains('وطنية') || txt.contains('موحدة') || val == 12) {
              if (val > 0) _nationalCardTypeId = val;
              break;
            }
          }
        }
      }
    } catch (_) {}

    try {
      final resTree = await http
          .get(
            Uri.parse(
                'https://emis.moedu.gov.iq/api/CountryStructure/getcountrystructure'),
            headers: _headers,
          )
          .timeout(const Duration(seconds: 20));
      if (resTree.statusCode == 200) {
        final tree = _unwrapList(_decodeResponse(resTree));
        if (tree.isNotEmpty) {
          _countryStructure = tree;
        }
      }
    } catch (_) {}
  }

  Future<void> _scanAllStudents() async {
    if (_isScanning) return;
    if (!_chkId && !_chkPhone && !_chkAddr) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('يرجى اختيار شرط واحد على الأقل من الشروط الثلاثة.'),
          backgroundColor: Colors.redAccent,
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    _clearFieldControllers();

    setState(() {
      _isScanning = true;
      _progressValue = 0.05;
      _progressText = 'جاري تحميل المراجع وهيكل العناوين...';
      _modifiedIds.clear();
      _cardStatusText.clear();
      _cardStatusSuccess.clear();
    });

    try {
      await _loadReferenceCatalogs();

      List<dynamic> summaries = widget.allStudents;
      if (summaries.isEmpty) {
        if (mounted) {
          setState(() {
            _progressValue = 0.12;
            _progressText = 'جاري جلب قائمة طلاب المدرسة...';
          });
        }
        final listRes = await http
            .get(
              Uri.parse(
                  'https://emis.moedu.gov.iq/api/student/getstudents?page=1&rowsPerPage=5000&sortBy=id&sortOrder=desc&entityId=${widget.schoolId}'),
              headers: _headers,
            )
            .timeout(const Duration(seconds: 25));
        if (listRes.statusCode == 200) {
          summaries = _unwrapList(_decodeResponse(listRes));
        }
      }

      if (summaries.isEmpty) {
        if (mounted) {
          setState(() {
            _isScanning = false;
            _allFullStudents.clear();
            _matchedStudents.clear();
          });
        }
        return;
      }

      // قراءة حالة الطوابير الذكية والمعالجة السريعة من الإعدادات
      await AppCore.initPreferences();
      final fastQueueEnabled = AppCore.prefs.getBool('fast_processing_queue_enabled') ?? true;

      final List<Map<String, dynamic>> fetchedRecords = [];
      final int total = summaries.length;
      int completed = 0;
      int nextIdx = 0;
      // إذا كانت المعالجة السريعة مفعلة، نحدد مستوى التزامن بـ 3 لتقليل الضغط ومنع التعليق
      final int concurrency = fastQueueEnabled ? 3 : 6;

      Future<void> worker() async {
        while (true) {
          final idx = nextIdx++;
          if (idx >= total) return;
          final rawSummary = summaries[idx];
          if (rawSummary is! Map) {
            completed++;
            continue;
          }
          final summary = Map<String, dynamic>.from(rawSummary);
          final studentId = summary['id'];
          if (studentId == null) {
            completed++;
            continue;
          }

          try {
            final detailRes = await http
                .get(
                  Uri.parse(
                      'https://emis.moedu.gov.iq/api/student/getstudent/$studentId'),
                  headers: _headers,
                )
                .timeout(const Duration(seconds: 15));

            if (detailRes.statusCode == 200) {
              final fullStudent = _unwrapMap(_decodeResponse(detailRes));
              if (fullStudent.isNotEmpty && fullStudent['id'] != null) {
                fullStudent['_stageName'] = (summary['studentStage'] ??
                        summary['stageName'] ??
                        fullStudent['stageName'] ??
                        '')
                    .toString();
                fullStudent['_classRoomName'] = (summary['classRoomName'] ??
                        summary['classRoom'] ??
                        fullStudent['classRoomName'] ??
                        '')
                    .toString();
                fetchedRecords.add(fullStudent);
              }
            }
          } catch (_) {
          } finally {
            completed++;
            // إضافة مهلة بسيطة إذا كانت الطوابير مفعلة لتجنب إرهاق السيرفر
            if (fastQueueEnabled) {
              await Future.delayed(const Duration(milliseconds: 60));
            }
            if (mounted) {
              setState(() {
                _progressValue = 0.15 + ((completed / total) * 0.85);
                _progressText =
                    'جاري فحص بيانات الطلاب الكاملة: $completed من $total...';
              });
            }
          }
        }
      }

      final workersCount = total < concurrency ? total : concurrency;
      await Future.wait(List.generate(workersCount, (_) => worker()));

      if (!mounted) return;
      _allFullStudents
        ..clear()
        ..addAll(fetchedRecords);

      _applyCriteria();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('حدث خطأ أثناء الفحص: $e'),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isScanning = false;
        });
      }
    }
  }

  void _applyCriteria() {
    final List<_AuditItem> results = [];
    final q = _searchQuery.trim().toLowerCase();

    for (final student in _allFullStudents) {
      final stageName = (student['_stageName'] ?? '').toString();
      final roomName = (student['_classRoomName'] ?? '').toString();

      if (_selectedStage.isNotEmpty && stageName != _selectedStage) continue;
      if (_selectedRoom.isNotEmpty && roomName != _selectedRoom) continue;

      final fullName = _getStudentFullName(student);
      if (q.isNotEmpty) {
        final hay =
            '$fullName ${student['name'] ?? ''} ${student['firstName'] ?? ''} ${student['fatherName'] ?? ''} ${student['grandFatherName'] ?? ''} ${student['fathersGrandFatherName'] ?? ''} ${student['surName'] ?? ''} ${student['id']} ${_extractStudentPhone(student)} ${_extractStudentIdInfo(student)['rawNumber']}'
                .toLowerCase();
        if (!hay.contains(q)) continue;
      }

      final idCheck = _checkIdCondition(student);
      final phoneCheck = _checkPhoneCondition(student);
      final addrCheck = _checkAddressCondition(student);

      final List<bool> activeChecks = [];
      if (_chkId) activeChecks.add(idCheck['matched'] as bool);
      if (_chkPhone) activeChecks.add(phoneCheck['matched'] as bool);
      if (_chkAddr) activeChecks.add(addrCheck['matched'] as bool);

      if (activeChecks.isEmpty) continue;

      final bool isMatch = _matchMode == 'AND'
          ? activeChecks.every((b) => b)
          : activeChecks.any((b) => b);

      if (!isMatch) continue;

      if (_chkId && (idCheck['matched'] as bool)) {
        if (student['identification'] is! Map<String, dynamic>) {
          student['identification'] = student['identification'] is Map
              ? Map<String, dynamic>.from(student['identification'])
              : <String, dynamic>{};
        }
        if (student['identification']['idType'] != _nationalCardTypeId) {
          student['identification']['idType'] = _nationalCardTypeId;
          _modifiedIds.add(student['id'].toString());
        }
      }

      results.add(
        _AuditItem(
          student: student,
          idMatched: idCheck['matched'] as bool,
          idDigitsCount: idCheck['digitsCount'] as int,
          phoneMatched: phoneCheck['matched'] as bool,
          phoneReason: phoneCheck['reason'] as String,
          addrMatched: addrCheck['matched'] as bool,
          addrFilledCount: addrCheck['filledCount'] as int,
          addrFilledNames: List<String>.from(addrCheck['filledNames'] as List),
        ),
      );
    }

    setState(() {
      _matchedStudents = results;
    });
  }

  String _studentMissingFields(Map<String, dynamic> student) {
    final missing = <String>[];
    final firstName = (student['name'] ?? student['firstName'] ?? '').toString().trim();
    final fatherName = (student['fatherName'] ?? '').toString().trim();
    final grandfatherName = (student['grandFatherName'] ?? '').toString().trim();
    final greatGrandfatherName = (student['fathersGrandFatherName'] ?? '').toString().trim();
    final nameParts = [firstName, fatherName, grandfatherName, greatGrandfatherName];
    if (nameParts.any((part) => part.isEmpty || part.toLowerCase() == 'null')) {
      missing.add('جد الأب');
    }

    final surname = (student['surName'] ?? '').toString().trim();
    if (surname.isEmpty || surname.toLowerCase() == 'null') {
      missing.add('اللقب');
    }

    final idInfo = _extractStudentIdInfo(student);
    if ((idInfo['cleanDigits'] as String).length != 12) {
      missing.add('رقم البطاقة الوطنية الموحدة');
    }

    // Use the exact same condition functions as the audit screen so the
    // exported report cannot disagree with the findings shown to the user.
    final phoneCheck = _checkPhoneCondition(student);
    if (phoneCheck['matched'] == true) {
      missing.add('رقم الهاتف');
    }

    final addressCheck = _checkAddressCondition(student);
    if (addressCheck['matched'] == true) {
      missing.add('العنوان');
    }

    return missing.join('، ');
  }

  Future<void> _exportAuditReport() async {
    if (_isScanning || _matchedStudents.isEmpty) return;
    try {
      final rows = _matchedStudents.map((item) {
        final student = item.student;
        return <String>[
          _getStudentFullName(student),
          (student['_stageName'] ?? '').toString().trim(),
          (student['_classRoomName'] ?? '').toString().trim(),
          _studentMissingFields(student),
        ];
      }).toList();

      rows.sort((a, b) {
        final stage = a[1].compareTo(b[1]);
        if (stage != 0) return stage;
        final room = a[2].compareTo(b[2]);
        if (room != 0) return room;
        return a[0].compareTo(b[0]);
      });

      final excel = Excel.createExcel();
      final sheet = excel['تقرير نواقص بيانات الطلاب'];
      sheet.isRTL = true;
      sheet.appendRow([
        TextCellValue('اسم الطالب'),
        TextCellValue('الصف'),
        TextCellValue('الشعبة'),
        TextCellValue('النواقص المكتشفة'),
      ]);

      final headerStyle = CellStyle(
        bold: true,
        fontSize: 12,
        fontColorHex: ExcelColor.fromHexString('FFFFFFFF'),
        backgroundColorHex: ExcelColor.fromHexString('FF4338CA'),
        horizontalAlign: HorizontalAlign.Center,
        verticalAlign: VerticalAlign.Center,
        textWrapping: TextWrapping.WrapText,
      );
      final dataStyle = CellStyle(
        fontSize: 11,
        fontColorHex: ExcelColor.fromHexString('FF1F2937'),
        backgroundColorHex: ExcelColor.fromHexString('FFF8FAFC'),
        horizontalAlign: HorizontalAlign.Right,
        verticalAlign: VerticalAlign.Center,
        textWrapping: TextWrapping.WrapText,
      );
      final alternateStyle = CellStyle(
        fontSize: 11,
        fontColorHex: ExcelColor.fromHexString('FF1F2937'),
        backgroundColorHex: ExcelColor.fromHexString('FFEDE9FE'),
        horizontalAlign: HorizontalAlign.Right,
        verticalAlign: VerticalAlign.Center,
        textWrapping: TextWrapping.WrapText,
      );

      for (var column = 0; column < 4; column++) {
        sheet.cell(CellIndex.indexByColumnRow(columnIndex: column, rowIndex: 0)).cellStyle = headerStyle;
      }
      for (var index = 0; index < rows.length; index++) {
        final row = rows[index];
        sheet.appendRow(row.map((value) => TextCellValue(value)).toList());
        final style = index.isEven ? dataStyle : alternateStyle;
        for (var column = 0; column < 4; column++) {
          sheet.cell(CellIndex.indexByColumnRow(columnIndex: column, rowIndex: index + 1)).cellStyle = style;
        }
      }
      sheet.setColumnWidth(0, 32);
      sheet.setColumnWidth(1, 18);
      sheet.setColumnWidth(2, 18);
      sheet.setColumnWidth(3, 48);
      sheet.setRowHeight(0, 30);
      for (var index = 1; index <= rows.length; index++) {
        sheet.setRowHeight(index, 32);
      }

      final bytes = excel.encode();
      if (bytes == null) throw Exception('تعذر إنشاء ملف Excel.');
      final directory = await getTemporaryDirectory();
      final stamp = DateTime.now();
      final fileName = 'تقرير_نواقص_الطلاب_${stamp.year}-${stamp.month.toString().padLeft(2, '0')}-${stamp.day.toString().padLeft(2, '0')}.xlsx';
      final file = File('${directory.path}/$fileName');
      await file.writeAsBytes(bytes, flush: true);

      if (!mounted) return;
      if (rows.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('اكتمل الفحص، لكن لم تُكتشف نواقص ضمن الطلاب المعروضين.')),
        );
        return;
      }
      await Share.shareXFiles(
        [XFile(file.path, mimeType: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet')],
        text: 'تقرير نواقص بيانات الطلاب - ${rows.length} طالب',
        subject: 'تقرير نواقص بيانات الطلاب',
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تعذر إنشاء التقرير: $e'), backgroundColor: Colors.redAccent),
      );
    }
  }

  Future<bool> _saveSingleStudent(Map<String, dynamic> student) async {
    final sId = student['id'].toString();
    setState(() {
      _savingSingleIds.add(sId);
      _cardStatusText[sId] = '⏳ جاري الحفظ...';
      _cardStatusSuccess[sId] = true;
    });

    try {
      final payload = jsonDecode(jsonEncode(student)) as Map<String, dynamic>;
      payload.remove('_stageName');
      payload.remove('_classRoomName');

      if (payload['dateOfBirth'] != null) {
        payload['dateOfBirth'] = _normalizeDateForSave(payload['dateOfBirth']);
      }
      if (payload['identification'] is Map) {
        final ident = Map<String, dynamic>.from(payload['identification']);
        if (ident['issuingDate'] != null) {
          ident['issuingDate'] = _normalizeDateForSave(ident['issuingDate']);
        }
        if (_chkId) {
          ident['idType'] = _nationalCardTypeId;
        }
        payload['identification'] = ident;
      }

      final res = await http
          .post(
            Uri.parse('https://emis.moedu.gov.iq/api/student/updatestudent'),
            headers: _headers,
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 20));

      if (res.statusCode >= 200 && res.statusCode < 300) {
        for (int i = 0; i < widget.allStudents.length; i++) {
          final item = widget.allStudents[i];
          if (item is Map && item['id']?.toString() == sId) {
            item['homePhoneNumber'] = student['homePhoneNumber'];
            if (student['identification'] is Map) {
              item['idNumber'] = student['identification']['idNumber'];
            }
            break;
          }
        }

        if (mounted) {
          setState(() {
            _modifiedIds.remove(sId);
            _cardStatusText[sId] = '✅ تم الحفظ بنجاح';
            _cardStatusSuccess[sId] = true;
          });
        }
        return true;
      } else {
        throw Exception('HTTP ${res.statusCode}');
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _cardStatusText[sId] = '❌ فشل الحفظ: $e';
          _cardStatusSuccess[sId] = false;
        });
      }
      return false;
    } finally {
      if (mounted) {
        setState(() {
          _savingSingleIds.remove(sId);
        });
      }
    }
  }

  Future<void> _saveAllMatchedStudents() async {
    if (_isSavingAll || _matchedStudents.isEmpty) return;

    final modifiedList = _matchedStudents
        .where((item) => _modifiedIds.contains(item.student['id'].toString()))
        .map((item) => item.student)
        .toList();

    final listToSave = modifiedList.isNotEmpty
        ? modifiedList
        : _matchedStudents.map((e) => e.student).toList();

    final isDark = AppCore.themeNotifier.value == ThemeMode.dark;
    const goldNeon = Color(0xFFF59E0B);

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          backgroundColor:
              isDark ? const Color(0xFF141829) : const Color(0xFFFFFFFF),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
            side: BorderSide(
              color: goldNeon.withOpacity(0.45),
              width: 1.5,
            ),
          ),
          title: Text(
            'تأكيد الحفظ الجماعي',
            style: TextStyle(
              color: isDark ? Colors.white : const Color(0xFF0F172A),
              fontWeight: FontWeight.w900,
            ),
          ),
          content: Text(
            'هل تريد حفظ التعديلات لـ (${listToSave.length}) طالب في منصة EMIS؟',
            style: TextStyle(
              color: isDark ? const Color(0xFFCBD5E1) : const Color(0xFF475569),
              height: 1.45,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(
                'إلغاء',
                style: TextStyle(
                  color: isDark
                      ? const Color(0xFF94A3B8)
                      : const Color(0xFF64748B),
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: goldNeon,
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('حفظ الكل', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );

    if (confirm != true) return;

    setState(() {
      _isSavingAll = true;
    });

    // قراءة خيار المعالجة السريعة والطوابير الذكية
    await AppCore.initPreferences();
    final fastQueueEnabled = AppCore.prefs.getBool('fast_processing_queue_enabled') ?? true;

    int okCount = 0;
    int failCount = 0;

    for (int i = 0; i < listToSave.length; i++) {
      final st = listToSave[i];
      if (mounted) {
        setState(() {
          _progressValue = (i + 1) / listToSave.length;
          _progressText =
              'جاري حفظ (${i + 1}/${listToSave.length}): ${_getStudentFullName(st)}';
        });
      }
      final ok = await _saveSingleStudent(st);
      if (ok) {
        okCount++;
      } else {
        failCount++;
      }
      // إذا كانت المعالجة السريعة مفعلة، نضيف فترة راحة قصيرة لتجنب ضغط السيرفر
      if (fastQueueEnabled) {
        await Future.delayed(const Duration(milliseconds: 120));
      }
    }

    if (!mounted) return;
    setState(() {
      _isSavingAll = false;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'اكتمل الحفظ الجماعي — نجح: $okCount | فشل: $failCount',
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        backgroundColor:
            failCount == 0 ? const Color(0xFF10B981) : const Color(0xFFF97316),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  String _optVal(dynamic node) {
    if (node is Map) {
      return (node['value'] ?? node['id'] ?? '').toString();
    }
    return '';
  }

  String _optTxt(dynamic node) {
    if (node is Map) {
      return (node['displayName'] ??
              node['name'] ??
              node['label'] ??
              node['text'] ??
              _optVal(node))
          .toString();
    }
    return '';
  }

  List<dynamic> _childrenOf(dynamic node) {
    if (node is Map) {
      final raw = node['children'] ??
          node['items'] ??
          node['subItems'] ??
          node['childs'];
      if (raw is List) return raw;
    }
    return [];
  }

  Map<String, String> _resolveLocationPath(dynamic countryStructureId) {
    final stored = countryStructureId?.toString().trim() ?? '';
    dynamic defaultCountry;
    for (final c in _countryStructure) {
      if (_optTxt(c).contains('العراق') ||
          _optTxt(c).toLowerCase() == 'iraq') {
        defaultCountry = c;
        break;
      }
    }
    defaultCountry ??=
        _countryStructure.isNotEmpty ? _countryStructure.first : null;

    final result = <String, String>{
      'countryId': defaultCountry != null ? _optVal(defaultCountry) : '',
      'govId': '',
      'distId': '',
      'townId': '',
    };

    if (stored.isEmpty || stored == '0' || stored == 'null') return result;

    for (final country in _countryStructure) {
      for (final gov in _childrenOf(country)) {
        for (final dist in _childrenOf(gov)) {
          final dId = _optVal(dist);
          final towns = _childrenOf(dist);
          dynamic matchTown;
          for (final t in towns) {
            if (_optVal(t) == stored) {
              matchTown = t;
              break;
            }
          }
          if (dId == stored || matchTown != null) {
            return {
              'countryId': _optVal(country),
              'govId': _optVal(gov),
              'distId': dId,
              'townId': matchTown != null ? _optVal(matchTown) : '',
            };
          }
        }
      }
    }
    return result;
  }

  List<String> get _availableStages {
    return _allFullStudents
        .map((s) => (s['_stageName'] ?? '').toString())
        .where((s) => s.isNotEmpty)
        .toSet()
        .toList();
  }

  List<String> get _availableRooms {
    return _allFullStudents
        .where((s) =>
            _selectedStage.isEmpty ||
            (s['_stageName'] ?? '').toString() == _selectedStage)
        .map((s) => (s['_classRoomName'] ?? '').toString())
        .where((r) => r.isNotEmpty)
        .toSet()
        .toList();
  }

  Widget _buildAmbientGlow({required Color color, required double size}) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: [color, color.withOpacity(0.0)],
        ),
      ),
    );
  }

  Widget _buildTopHeader(bool isDark) {
    const purpleNeon = Color(0xFFA855F7);
    const goldNeon = Color(0xFFF59E0B);
    const blueNeon = Color(0xFF3B82F6);

    return AnimatedBuilder(
      animation: _ambientController,
      builder: (context, _) {
        final pulse =
            0.5 + 0.5 * math.sin(_ambientController.value * 2 * math.pi);

        return Container(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
          decoration: BoxDecoration(
            gradient: isDark
                ? const LinearGradient(
                    begin: Alignment.topRight,
                    end: Alignment.bottomLeft,
                    colors: [
                      Color(0xFF221535),
                      Color(0xFF161A30),
                      Color(0xFF112A2E),
                    ],
                  )
                : const LinearGradient(
                    begin: Alignment.topRight,
                    end: Alignment.bottomLeft,
                    colors: [
                      Color(0xFFFFFFFF),
                      Color(0xFFF5F3FF),
                      Color(0xFFEDE9FE),
                    ],
                  ),
            borderRadius: BorderRadius.circular(28),
            border: Border.all(
              color: purpleNeon.withOpacity(isDark ? 0.50 : 0.32),
              width: 1.5,
            ),
            boxShadow: [
              BoxShadow(
                color: purpleNeon.withOpacity(0.12 + pulse * 0.08),
                blurRadius: 24,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Row(
            children: [
              _AnimatedAuditorOrbIcon(
                icon: Icons.fact_check_rounded,
                primaryColor: purpleNeon,
                secondaryColor: goldNeon,
                animation: _ambientController,
                size: 60,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'أدوات ذكية متقدمة',
                      style: TextStyle(
                        color: isDark ? goldNeon : purpleNeon,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'التعديل السريع لبيانات الطلاب',
                      style: TextStyle(
                        color: isDark ? Colors.white : const Color(0xFF0F172A),
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'فحص وتدقيق وتعديل بيانات الهواتف والهويات والعناوين فوراً',
                      style: TextStyle(
                        color: isDark
                            ? const Color(0xFF94A3B8)
                            : const Color(0xFF64748B),
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: () => Navigator.of(context).pop(),
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: isDark
                        ? Colors.white.withOpacity(0.08)
                        : purpleNeon.withOpacity(0.10),
                    border: Border.all(
                      color: isDark
                          ? Colors.white.withOpacity(0.18)
                          : purpleNeon.withOpacity(0.28),
                    ),
                  ),
                  child: Icon(
                    Icons.arrow_back_ios_rounded,
                    size: 19,
                    color: isDark ? Colors.white : const Color(0xFF1E293B),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: AppCore.themeNotifier,
      builder: (context, currentMode, _) {
        final isDark = currentMode == ThemeMode.dark;
        final bgColor =
            isDark ? const Color(0xFF070913) : const Color(0xFFF2F5FA);
        final cardColor = isDark ? const Color(0xFF141829) : Colors.white;
        final textColor = isDark ? Colors.white : const Color(0xFF0F172A);

        const purpleNeon = Color(0xFFA855F7);
        const emeraldNeon = Color(0xFF10B981);
        const goldNeon = Color(0xFFF59E0B);
        const blueNeon = Color(0xFF3B82F6);

        return Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (_) => _stopVoiceFromPointer(),
          child: Directionality(
            textDirection: TextDirection.rtl,
            child: Scaffold(
              backgroundColor: bgColor,
              appBar: null,
              body: Stack(
                children: [
                  Positioned.fill(
                    child: AnimatedBuilder(
                      animation: _ambientController,
                      builder: (context, _) {
                        final shift =
                            math.sin(_ambientController.value * 2 * math.pi) * 20;
                        return Stack(
                          children: [
                            Positioned(
                              top: -50 + shift,
                              right: -50,
                              child: _buildAmbientGlow(
                                color: isDark
                                    ? purpleNeon.withOpacity(0.18)
                                    : purpleNeon.withOpacity(0.12),
                                size: 250,
                              ),
                            ),
                            Positioned(
                              top: 240 - shift,
                              left: -70,
                              child: _buildAmbientGlow(
                                color: isDark
                                    ? goldNeon.withOpacity(0.15)
                                    : blueNeon.withOpacity(0.12),
                                size: 270,
                              ),
                            ),
                            Positioned(
                              bottom: -60 + shift,
                              right: 20,
                              child: _buildAmbientGlow(
                                color: isDark
                                    ? emeraldNeon.withOpacity(0.12)
                                    : purpleNeon.withOpacity(0.10),
                                size: 230,
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                  SafeArea(
                    child: Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                          child: _buildTopHeader(isDark),
                        ),
                        AnimatedSize(
                          duration: const Duration(milliseconds: 420),
                          curve: Curves.easeInOutCubic,
                          alignment: Alignment.topCenter,
                          child: _controlsCollapsed && _allFullStudents.isNotEmpty
                              ? _collapsedControlsHandle(cardColor, isDark)
                              : _buildControlsPanel(cardColor, textColor, isDark),
                        ),
                        if (_isScanning || _isSavingAll) _buildProgressBar(),
                        Expanded(
                          child: _matchedStudents.isEmpty
                              ? _buildEmptyState(cardColor, textColor, isDark)
                              : ListView.builder(
                                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
                                  physics: const BouncingScrollPhysics(),
                                  itemCount: _matchedStudents.length,
                                  itemBuilder: (context, index) {
                                    return _buildStudentAuditCard(
                                      _matchedStudents[index],
                                      cardColor,
                                      textColor,
                                      isDark,
                                    );
                                  },
                                ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildControlsPanel(Color cardColor, Color textColor, bool isDark) {
    final stages = _availableStages;
    final rooms = _availableRooms;
    const purpleNeon = Color(0xFFA855F7);
    const blueNeon = Color(0xFF3B82F6);
    final mutedColor = isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 6),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: isDark
            ? LinearGradient(
                colors: [
                  const Color(0xFF141829).withOpacity(0.95),
                  Color.lerp(const Color(0xFF0F1322), purpleNeon, 0.08)!,
                ],
              )
            : LinearGradient(
                colors: [
                  Colors.white.withOpacity(0.96),
                  const Color(0xFFF8FAFC).withOpacity(0.92),
                ],
              ),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: purpleNeon.withOpacity(isDark ? 0.45 : 0.30),
          width: 1.3,
        ),
        boxShadow: [
          BoxShadow(
            color: purpleNeon.withOpacity(isDark ? 0.12 : 0.07),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_allFullStudents.isNotEmpty)
            Align(
              alignment: Alignment.center,
              child: IconButton(
                tooltip: 'إخفاء أدوات البحث',
                icon: const Icon(Icons.keyboard_arrow_up_rounded, size: 30, color: purpleNeon),
                onPressed: () => setState(() => _controlsCollapsed = true),
              ),
            ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilterChip(
                label: const Text('١- الهوية ≠ 12 رقم (إجبار وطنية)', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12)),
                selected: _chkId,
                onSelected: (v) {
                  setState(() => _chkId = v);
                  if (_allFullStudents.isNotEmpty) _applyCriteria();
                },
                selectedColor: const Color(0xFFF59E0B).withOpacity(0.25),
                checkmarkColor: const Color(0xFFF59E0B),
              ),
              FilterChip(
                label: const Text('٢- بدون هاتف أو 5 أصفار', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12)),
                selected: _chkPhone,
                onSelected: (v) {
                  setState(() => _chkPhone = v);
                  if (_allFullStudents.isNotEmpty) _applyCriteria();
                },
                selectedColor: const Color(0xFFEF4444).withOpacity(0.25),
                checkmarkColor: const Color(0xFFEF4444),
              ),
              FilterChip(
                label: const Text('٣- العنوان مملوء (1 إلى 3 حقول)', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12)),
                selected: _chkAddr,
                onSelected: (v) {
                  setState(() => _chkAddr = v);
                  if (_allFullStudents.isNotEmpty) _applyCriteria();
                },
                selectedColor: purpleNeon.withOpacity(0.25),
                checkmarkColor: purpleNeon,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  value: _matchMode,
                  isExpanded: true,
                  dropdownColor: isDark ? const Color(0xFF181D32) : Colors.white,
                  iconEnabledColor: purpleNeon,
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    color: textColor,
                    fontSize: 13,
                  ),
                  decoration: InputDecoration(
                    labelText: 'طريقة دمج الشروط',
                    labelStyle: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 12.5,
                      color: mutedColor,
                    ),
                    filled: true,
                    fillColor: isDark
                        ? const Color(0xFF0B0E1A).withOpacity(0.68)
                        : const Color(0xFFF1F5F9),
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: BorderSide(
                        color: purpleNeon.withOpacity(isDark ? 0.35 : 0.25),
                        width: 1.2,
                      ),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: BorderSide(
                        color: purpleNeon.withOpacity(isDark ? 0.35 : 0.25),
                        width: 1.2,
                      ),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: const BorderSide(color: purpleNeon, width: 1.8),
                    ),
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: 'OR',
                      child: Text('مطابقة أي شرط (أو)',
                          style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
                    ),
                    DropdownMenuItem(
                      value: 'AND',
                      child: Text('جميع الشروط معاً (و)',
                          style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
                    ),
                  ],
                  onChanged: (v) {
                    if (v == null) return;
                    setState(() => _matchMode = v);
                    if (_allFullStudents.isNotEmpty) _applyCriteria();
                  },
                ),
              ),
              const SizedBox(width: 10),
              FilledButton.icon(
                onPressed: _isScanning ? null : _scanAllStudents,
                style: FilledButton.styleFrom(
                  backgroundColor: purpleNeon,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  elevation: 4,
                  shadowColor: purpleNeon.withOpacity(0.35),
                ),
                icon: const Icon(Icons.manage_search_rounded, size: 20),
                label: const Text(
                  'بدء فحص الطلاب',
                  style: TextStyle(fontWeight: FontWeight.w900),
                ),
              ),
            ],
          ),
          if (_allFullStudents.isNotEmpty) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    value:
                        stages.contains(_selectedStage) ? _selectedStage : '',
                    isExpanded: true,
                    dropdownColor: isDark ? const Color(0xFF181D32) : Colors.white,
                    iconEnabledColor: blueNeon,
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      color: textColor,
                      fontSize: 12,
                    ),
                    decoration: InputDecoration(
                      labelText: 'الصف الدراسي',
                      labelStyle: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                        color: mutedColor,
                      ),
                      filled: true,
                      fillColor: isDark
                          ? const Color(0xFF0B0E1A).withOpacity(0.68)
                          : const Color(0xFFF1F5F9),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 8),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide(
                          color: blueNeon.withOpacity(isDark ? 0.35 : 0.25),
                          width: 1.2,
                        ),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide(
                          color: blueNeon.withOpacity(isDark ? 0.35 : 0.25),
                          width: 1.2,
                        ),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: const BorderSide(color: blueNeon, width: 1.8),
                      ),
                    ),
                    items: [
                      DropdownMenuItem(
                        value: '',
                        child: Text('كل الصفوف (${stages.length})',
                            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12)),
                      ),
                      ...stages.map(
                        (st) => DropdownMenuItem(
                          value: st,
                          child: Text(st, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12)),
                        ),
                      ),
                    ],
                    onChanged: (v) {
                      setState(() {
                        _selectedStage = v ?? '';
                        _selectedRoom = '';
                      });
                      _applyCriteria();
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    value: rooms.contains(_selectedRoom) ? _selectedRoom : '',
                    isExpanded: true,
                    dropdownColor: isDark ? const Color(0xFF181D32) : Colors.white,
                    iconEnabledColor: blueNeon,
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      color: textColor,
                      fontSize: 12,
                    ),
                    decoration: InputDecoration(
                      labelText: 'الشعبة',
                      labelStyle: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                        color: mutedColor,
                      ),
                      filled: true,
                      fillColor: isDark
                          ? const Color(0xFF0B0E1A).withOpacity(0.68)
                          : const Color(0xFFF1F5F9),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 8),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide(
                          color: blueNeon.withOpacity(isDark ? 0.35 : 0.25),
                          width: 1.2,
                        ),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide(
                          color: blueNeon.withOpacity(isDark ? 0.35 : 0.25),
                          width: 1.2,
                        ),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: const BorderSide(color: blueNeon, width: 1.8),
                      ),
                    ),
                    items: [
                      DropdownMenuItem(
                        value: '',
                        child: Text('كل الشعب (${rooms.length})',
                            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12)),
                      ),
                      ...rooms.map(
                        (rm) => DropdownMenuItem(
                          value: rm,
                          child: Text(rm, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12)),
                        ),
                      ),
                    ],
                    onChanged: (v) {
                      setState(() => _selectedRoom = v ?? '');
                      _applyCriteria();
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: _centralNav.keyForField('search_query', NavigableFieldType.text),
                    focusNode: _centralNav.focusNodeForText('search_query'),
                    textInputAction: TextInputAction.next,
                    controller: _searchController,
                    onSubmitted: (_) => _centralNav.handleFieldSubmitted('search_query'),
                    onChanged: (val) {
                      _searchQuery = val;
                      _applyCriteria();
                    },
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      color: textColor,
                      fontSize: 13,
                    ),
                    decoration: InputDecoration(
                      hintText: 'بحث بالاسم أو الرقم...',
                      hintStyle: TextStyle(
                        color: isDark ? Colors.white38 : Colors.black38,
                        fontSize: 12,
                      ),
                      prefixIcon: const Icon(Icons.search_rounded, size: 20, color: purpleNeon),
                      suffixIcon: _searchQuery.isNotEmpty
                          ? IconButton(
                              tooltip: 'مسح البحث',
                              icon: const Icon(Icons.clear_rounded, size: 18),
                              onPressed: () {
                                _searchController.clear();
                                _searchQuery = '';
                                _applyCriteria();
                              },
                            )
                          : null,
                      isDense: true,
                      filled: true,
                      fillColor: isDark
                          ? const Color(0xFF0B0E1A).withOpacity(0.68)
                          : const Color(0xFFF1F5F9),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide(
                          color: purpleNeon.withOpacity(isDark ? 0.35 : 0.25),
                          width: 1.2,
                        ),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide(
                          color: purpleNeon.withOpacity(isDark ? 0.35 : 0.25),
                          width: 1.2,
                        ),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: const BorderSide(color: purpleNeon, width: 1.8),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: purpleNeon.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: purpleNeon.withOpacity(0.35)),
                  ),
                  child: Text(
                    'المطابق: ${_matchedStudents.length} / ${_allFullStudents.length}',
                    style: TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 12,
                      color: isDark ? const Color(0xFF6EE7B7) : purpleNeon,
                    ),
                  ),
                ),
              ],
            ),
          ],
          if (_matchedStudents.isNotEmpty) ...[
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _isScanning ? null : _exportAuditReport,
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF4338CA),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(15),
                  ),
                ),
                icon: const Icon(Icons.description_rounded),
                label: const Text('تقرير Excel', style: TextStyle(fontWeight: FontWeight.w900)),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildProgressBar() {
    const purpleNeon = Color(0xFFA855F7);
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: purpleNeon.withOpacity(0.12),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: purpleNeon.withOpacity(0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _progressText,
            style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 12.5),
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: _progressValue,
              minHeight: 8,
              backgroundColor: Colors.grey.shade300,
              valueColor:
                  const AlwaysStoppedAnimation<Color>(purpleNeon),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(Color cardColor, Color textColor, bool isDark) {
    const purpleNeon = Color(0xFFA855F7);
    return Center(
      child: Container(
        margin: const EdgeInsets.all(24),
        padding: const EdgeInsets.all(28),
        decoration: BoxDecoration(
          gradient: isDark
              ? LinearGradient(
                  colors: [
                    const Color(0xFF141829).withOpacity(0.95),
                    Color.lerp(const Color(0xFF0F1322), purpleNeon, 0.08)!,
                  ],
                )
              : LinearGradient(
                  colors: [
                    Colors.white.withOpacity(0.96),
                    const Color(0xFFF8FAFC).withOpacity(0.92),
                  ],
                ),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(
            color: purpleNeon.withOpacity(isDark ? 0.45 : 0.30),
            width: 1.3,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.fact_check_outlined,
                size: 56, color: purpleNeon),
            const SizedBox(height: 14),
            Text(
              _allFullStudents.isEmpty
                  ? 'اختر الشروط المطلوبة من الأعلى ثم اضغط على "بدء فحص الطلاب" ليقوم التطبيق بجلب وفحص الملف الكامل لكل طالب.'
                  : 'لا يوجد طلاب مطابقون للشروط والفلاتر المحددة حالياً.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: textColor,
                fontSize: 14,
                fontWeight: FontWeight.w900,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStudentAuditCard(
    _AuditItem item,
    Color cardColor,
    Color textColor,
    bool isDark,
  ) {
    final student = item.student;
    final sId = student['id'].toString();
    final isSaving = _savingSingleIds.contains(sId);
    final statusMsg = _cardStatusText[sId];
    final isStatusOk = _cardStatusSuccess[sId] ?? true;
    const purpleNeon = Color(0xFFA855F7);

    return Container(
      key: ValueKey('audit_card_$sId'),
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        gradient: isDark
            ? LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  const Color(0xFF141829).withOpacity(0.95),
                  Color.lerp(const Color(0xFF0F1322), purpleNeon, 0.08)!,
                ],
              )
            : LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Colors.white.withOpacity(0.96),
                  Color.lerp(const Color(0xFFF8FAFC), purpleNeon, 0.04)!,
                ],
              ),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: statusMsg != null
              ? (isStatusOk ? const Color(0xFF10B981) : const Color(0xFFEF4444))
              : (_modifiedIds.contains(sId)
                  ? const Color(0xFFF59E0B)
                  : purpleNeon.withOpacity(isDark ? 0.45 : 0.30)),
          width: 1.3,
        ),
        boxShadow: [
          BoxShadow(
            color: purpleNeon.withOpacity(isDark ? 0.12 : 0.07),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${_getStudentFullName(student)} (#$sId)',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w900,
                          color: textColor,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          if ((student['_stageName'] ?? '')
                              .toString()
                              .isNotEmpty)
                            _buildBadge(student['_stageName'].toString(),
                                const Color(0xFF3B82F6)),
                          if ((student['_classRoomName'] ?? '')
                              .toString()
                              .isNotEmpty)
                            _buildBadge('شعبة ${student['_classRoomName']}',
                                const Color(0xFF06B6D4)),
                          if (_chkId && item.idMatched)
                            _buildBadge('⚠️ الهوية: ${item.idDigitsCount} رقم',
                                const Color(0xFFF59E0B)),
                          if (_chkPhone && item.phoneMatched)
                            _buildBadge(
                                '📵 ${item.phoneReason}', const Color(0xFFEF4444)),
                          if (_chkAddr && item.addrMatched)
                            _buildBadge(
                                '📍 العنوان: مملوء (${item.addrFilledCount})',
                                purpleNeon),
                        ],
                      ),
                    ],
                  ),
                ),
                FilledButton.icon(
                  onPressed:
                      isSaving ? null : () => _saveSingleStudent(student),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF10B981),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    elevation: 4,
                    shadowColor: const Color(0xFF10B981).withOpacity(0.35),
                  ),
                  icon: isSaving
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(Icons.save_rounded, size: 18),
                  label: const Text('حفظ',
                      style:
                          TextStyle(fontSize: 13, fontWeight: FontWeight.w900)),
                ),
              ],
            ),

            if (statusMsg != null) ...[
              const SizedBox(height: 10),
              Text(
                statusMsg,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w900,
                  color: isStatusOk ? const Color(0xFF10B981) : const Color(0xFFEF4444),
                ),
              ),
            ],

            const Divider(height: 24),
            Row(children: [
              Expanded(
                  child: _buildQuickTextField(
                      student, 'fathersGrandFatherName', 'جد الأب', sId)),
              const SizedBox(width: 10),
              Expanded(
                  child: _buildQuickTextField(student, 'surName', 'اللقب', sId)),
            ]),
            const SizedBox(height: 12),

            if (_chkId && item.idMatched) _buildIdSection(student, sId),

            if (_chkPhone && item.phoneMatched)
              _buildPhoneSection(student, sId, item.phoneReason),

            if (_chkAddr && item.addrMatched)
              _buildAddressSection(student, sId, item, isDark, textColor),
          ],
        ),
      ),
    );
  }

  Widget _buildBadge(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4.5),
      decoration: BoxDecoration(
        color: color.withOpacity(0.14),
        border: Border.all(color: color.withOpacity(0.35)),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Text(
        text,
        style:
            TextStyle(color: color, fontSize: 11.5, fontWeight: FontWeight.w900),
      ),
    );
  }

  Widget _buildQuickTextField(
      Map<String, dynamic> student, String key, String label, String sId) {
    final fieldId = '${sId}_student_$key';
    final ctrl = _getController(fieldId, (student[key] ?? '').toString());
    const purpleNeon = Color(0xFFA855F7);
    final isDark = AppCore.themeNotifier.value == ThemeMode.dark;
    final mutedColor = isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);
    final centralEnabled = AppCore.centralKeyboardNavigationEnabled;

    final fieldKey = _centralNav.keyForField(fieldId, NavigableFieldType.text);
    final focusNode = _centralNav.focusNodeForText(fieldId);

    return TextFormField(
      key: fieldKey,
      focusNode: focusNode,
      controller: ctrl,
      textInputAction: centralEnabled ? TextInputAction.next : TextInputAction.done,
      onFieldSubmitted: (_) {
        if (centralEnabled) {
          _centralNav.handleFieldSubmitted(fieldId);
        }
      },
      onEditingComplete: () {
        if (centralEnabled) {
          _centralNav.handleFieldSubmitted(fieldId);
        } else {
          FocusManager.instance.primaryFocus?.unfocus();
        }
      },
      style: TextStyle(
        fontWeight: FontWeight.w800,
        color: isDark ? Colors.white : const Color(0xFF0F172A),
        fontSize: 13.5,
      ),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(
          fontWeight: FontWeight.bold,
          fontSize: 12.5,
          color: mutedColor,
        ),
        isDense: true,
        filled: true,
        fillColor: isDark
            ? const Color(0xFF0B0E1A).withOpacity(0.68)
            : const Color(0xFFF1F5F9),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(
            color: purpleNeon.withOpacity(isDark ? 0.35 : 0.25),
            width: 1.2,
          ),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(
            color: purpleNeon.withOpacity(isDark ? 0.35 : 0.25),
            width: 1.2,
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: purpleNeon, width: 1.8),
        ),
        suffixIcon: _buildMicIconButton(
          student: student,
          sId: sId,
          category: 'student',
          key: key,
          isNumeric: false,
        ),
      ),
      onChanged: (value) {
        setState(() {
          student[key] = value;
          _modifiedIds.add(sId);
        });
      },
    );
  }

  Widget _buildIdSection(Map<String, dynamic> student, String sId) {
    if (student['identification'] is! Map<String, dynamic>) {
      student['identification'] = student['identification'] is Map
          ? Map<String, dynamic>.from(student['identification'])
          : <String, dynamic>{};
    }
    final ident = student['identification'] as Map<String, dynamic>;
    ident['idType'] = _nationalCardTypeId;

    final currentNum =
        (ident['idNumber'] ?? student['idNumber'] ?? '').toString();
    final fieldId = '${sId}_ident_idNumber';
    final ctrl = _getController(fieldId, currentNum);
    final digitsLen = _extractDigitsOnly(ctrl.text).length;
    const goldNeon = Color(0xFFF59E0B);
    final isDark = AppCore.themeNotifier.value == ThemeMode.dark;
    final mutedColor = isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);
    final centralEnabled = AppCore.centralKeyboardNavigationEnabled;

    final fieldKey = _centralNav.keyForField(fieldId, NavigableFieldType.text);
    final focusNode = _centralNav.focusNodeForText(fieldId);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: goldNeon.withOpacity(0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: goldNeon.withOpacity(0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Flexible(
                child: Text(
                  '🪪 ١- تصحيح الهوية (نوع الهوية: البطاقة الوطنية الموحدة)',
                  style: TextStyle(fontWeight: FontWeight.w900, fontSize: 13),
                ),
              ),
              Text(
                'الأرقام: $digitsLen / 12',
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 12,
                  color: digitsLen == 12 ? const Color(0xFF10B981) : const Color(0xFFEF4444),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          TextFormField(
            key: fieldKey,
            focusNode: focusNode,
            controller: ctrl,
            keyboardType: TextInputType.number,
            maxLength: 14,
            textInputAction: centralEnabled ? TextInputAction.next : TextInputAction.done,
            onFieldSubmitted: (_) {
              if (centralEnabled) {
                _centralNav.handleFieldSubmitted(fieldId);
              }
            },
            onEditingComplete: () {
              if (centralEnabled) {
                _centralNav.handleFieldSubmitted(fieldId);
              } else {
                FocusManager.instance.primaryFocus?.unfocus();
              }
            },
            style: TextStyle(
              fontWeight: FontWeight.w800,
              color: isDark ? Colors.white : const Color(0xFF0F172A),
              fontSize: 13.5,
            ),
            decoration: InputDecoration(
              labelText: 'رقم البطاقة الوطنية الموحدة (12 رقماً)',
              labelStyle: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 12.5,
                color: mutedColor,
              ),
              counterText: '',
              filled: true,
              fillColor: isDark
                  ? const Color(0xFF0B0E1A).withOpacity(0.68)
                  : const Color(0xFFF1F5F9),
              contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
              suffixIcon: _buildMicIconButton(
                student: student,
                sId: sId,
                category: 'ident',
                key: 'idNumber',
                isNumeric: true,
              ),
              isDense: true,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: BorderSide(
                  color: goldNeon.withOpacity(isDark ? 0.35 : 0.25),
                  width: 1.2,
                ),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: BorderSide(
                  color: goldNeon.withOpacity(isDark ? 0.35 : 0.25),
                  width: 1.2,
                ),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: const BorderSide(color: goldNeon, width: 1.8),
              ),
            ),
            onChanged: (val) {
              final clean = _extractDigitsOnly(val);
              if (ctrl.text != clean) {
                ctrl.value = TextEditingValue(
                  text: clean,
                  selection: TextSelection.collapsed(offset: clean.length),
                );
              }
              setState(() {
                ident['idType'] = _nationalCardTypeId;
                ident['idNumber'] = clean;
                student['idNumber'] = clean;
                _modifiedIds.add(sId);
              });
            },
          ),
        ],
      ),
    );
  }

  Widget _buildPhoneSection(
      Map<String, dynamic> student, String sId, String reason) {
    final currentPhone = _extractStudentPhone(student);
    final fieldId = '${sId}_phone_homePhoneNumber';
    final ctrl = _getController(fieldId, currentPhone);
    final digits = _extractDigitsOnly(ctrl.text);
    final zeros = '0'.allMatches(digits).length;
    const redNeon = Color(0xFFEF4444);
    const goldNeon = Color(0xFFF59E0B);
    final isDark = AppCore.themeNotifier.value == ThemeMode.dark;
    final mutedColor = isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);
    final centralEnabled = AppCore.centralKeyboardNavigationEnabled;

    final fieldKey = _centralNav.keyForField(fieldId, NavigableFieldType.text);
    final focusNode = _centralNav.focusNodeForText(fieldId);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: redNeon.withOpacity(0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: redNeon.withOpacity(0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Flexible(
                child: Text(
                  '📞 ٢- تعديل رقم الهاتف ($reason)',
                  style: const TextStyle(
                      fontWeight: FontWeight.w900, fontSize: 13),
                ),
              ),
              Text(
                digits.isEmpty
                    ? 'فارغ'
                    : 'الأرقام: ${digits.length} (الأصفار: $zeros)',
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w900,
                  color: (digits.length >= 10 && zeros < 5)
                      ? const Color(0xFF10B981)
                      : goldNeon,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          TextFormField(
            key: fieldKey,
            focusNode: focusNode,
            controller: ctrl,
            keyboardType: TextInputType.phone,
            textInputAction: centralEnabled ? TextInputAction.next : TextInputAction.done,
            onFieldSubmitted: (_) {
              if (centralEnabled) {
                _centralNav.handleFieldSubmitted(fieldId);
              }
            },
            onEditingComplete: () {
              if (centralEnabled) {
                _centralNav.handleFieldSubmitted(fieldId);
              } else {
                FocusManager.instance.primaryFocus?.unfocus();
              }
            },
            style: TextStyle(
              fontWeight: FontWeight.w800,
              color: isDark ? Colors.white : const Color(0xFF0F172A),
              fontSize: 13.5,
            ),
            decoration: InputDecoration(
              labelText: 'رقم الهاتف الجديد / المعدل (07XXXXXXXXX)',
              labelStyle: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 12.5,
                color: mutedColor,
              ),
              isDense: true,
              filled: true,
              fillColor: isDark
                  ? const Color(0xFF0B0E1A).withOpacity(0.68)
                  : const Color(0xFFF1F5F9),
              contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
              suffixIcon: _buildMicIconButton(
                student: student,
                sId: sId,
                category: 'phone',
                key: 'homePhoneNumber',
                isNumeric: true,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: BorderSide(
                  color: redNeon.withOpacity(isDark ? 0.35 : 0.25),
                  width: 1.2,
                ),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: BorderSide(
                  color: redNeon.withOpacity(isDark ? 0.35 : 0.25),
                  width: 1.2,
                ),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: const BorderSide(color: redNeon, width: 1.8),
              ),
            ),
            onChanged: (val) {
              final clean = _extractDigitsOnly(val);
              if (ctrl.text != clean) {
                ctrl.value = TextEditingValue(
                  text: clean,
                  selection: TextSelection.collapsed(offset: clean.length),
                );
              }
              setState(() {
                _updateStudentPhoneData(student, clean);
                _modifiedIds.add(sId);
              });
            },
          ),
        ],
      ),
    );
  }

  Widget _buildAddressSection(
      Map<String, dynamic> student, String sId, _AuditItem item, bool isDark, Color textColor) {
    if (student['address'] is! Map<String, dynamic>) {
      student['address'] = student['address'] is Map
          ? Map<String, dynamic>.from(student['address'])
          : <String, dynamic>{};
    }
    final addr = student['address'] as Map<String, dynamic>;

    final loc = _resolveLocationPath(addr['countryStructureId']);
    final selectedCountryId = loc['countryId'] ?? '';
    final selectedGovId = loc['govId'] ?? '';
    final selectedDistId = loc['distId'] ?? '';
    final selectedTownId = loc['townId'] ?? '';

    dynamic countryNode;
    for (final c in _countryStructure) {
      if (_optVal(c) == selectedCountryId) {
        countryNode = c;
        break;
      }
    }
    final govList = _childrenOf(countryNode);

    dynamic govNode;
    for (final g in govList) {
      if (_optVal(g) == selectedGovId) {
        govNode = g;
        break;
      }
    }
    final distList = _childrenOf(govNode);

    dynamic distNode;
    for (final d in distList) {
      if (_optVal(d) == selectedDistId) {
        distNode = d;
        break;
      }
    }
    final townList = _childrenOf(distNode);
    const purpleNeon = Color(0xFFA855F7);
    final centralEnabled = AppCore.centralKeyboardNavigationEnabled;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: purpleNeon.withOpacity(0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: purpleNeon.withOpacity(0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '📍 ٣- استكمال عنوان الطالب (المملوء حالياً: ${item.addrFilledCount} حقول: ${item.addrFilledNames.isEmpty ? "لا يوجد" : item.addrFilledNames.join("، ")})',
            style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 13),
          ),
          const SizedBox(height: 10),
          if (_countryStructure.isNotEmpty) ...[
            Row(
              children: [
                Expanded(
                  child: _buildLocDropdown(
                    label: 'المحافظة',
                    value: selectedGovId,
                    items: govList,
                    isDark: isDark,
                    textColor: textColor,
                    onChanged: (val) {
                      setState(() {
                        final g = govList.firstWhere((x) => _optVal(x) == val,
                            orElse: () => null);
                        final dList = _childrenOf(g);
                        final firstDist =
                            dList.isNotEmpty ? _optVal(dList.first) : null;
                        addr['countryStructureId'] =
                            firstDist != null ? int.tryParse(firstDist) : null;
                        _modifiedIds.add(sId);
                      });
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _buildLocDropdown(
                    label: 'القضاء',
                    value: selectedDistId,
                    items: distList,
                    isDark: isDark,
                    textColor: textColor,
                    onChanged: (val) {
                      setState(() {
                        addr['countryStructureId'] =
                            val != null ? int.tryParse(val) : null;
                        _modifiedIds.add(sId);
                      });
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _buildLocDropdown(
                    label: 'الناحية',
                    value: selectedTownId,
                    items: townList,
                    isDark: isDark,
                    textColor: textColor,
                    onChanged: (val) {
                      setState(() {
                        final chosen = (val != null && val.isNotEmpty)
                            ? val
                            : selectedDistId;
                        addr['countryStructureId'] =
                            chosen.isNotEmpty ? int.tryParse(chosen) : null;
                        _modifiedIds.add(sId);
                      });
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
          ],
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _addressTextFields.map((f) {
              final fieldId = '${sId}_addr_${f.key}';
              final ctrl =
                  _getController(fieldId, (addr[f.key] ?? '').toString());
              final mutedColor = isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);

              final fieldKey = _centralNav.keyForField(fieldId, NavigableFieldType.text);
              final focusNode = _centralNav.focusNodeForText(fieldId);

              return SizedBox(
                width: 160,
                child: TextFormField(
                  key: fieldKey,
                  focusNode: focusNode,
                  controller: ctrl,
                  textInputAction: centralEnabled ? TextInputAction.next : TextInputAction.done,
                  onFieldSubmitted: (_) {
                    if (centralEnabled) {
                      _centralNav.handleFieldSubmitted(fieldId);
                    }
                  },
                  onEditingComplete: () {
                    if (centralEnabled) {
                      _centralNav.handleFieldSubmitted(fieldId);
                    } else {
                      FocusManager.instance.primaryFocus?.unfocus();
                    }
                  },
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    color: isDark ? Colors.white : const Color(0xFF0F172A),
                    fontSize: 13,
                  ),
                  decoration: InputDecoration(
                    labelText: f.label,
                    labelStyle: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                      color: mutedColor,
                    ),
                    isDense: true,
                    filled: true,
                    fillColor: isDark
                        ? const Color(0xFF0B0E1A).withOpacity(0.68)
                        : const Color(0xFFF1F5F9),
                    suffixIcon: _buildMicIconButton(
                      student: student,
                      sId: sId,
                      category: 'addr',
                      key: f.key,
                      isNumeric: false,
                      iconSize: 18,
                    ),
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide(
                        color: purpleNeon.withOpacity(isDark ? 0.35 : 0.25),
                        width: 1.2,
                      ),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide(
                        color: purpleNeon.withOpacity(isDark ? 0.35 : 0.25),
                        width: 1.2,
                      ),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: const BorderSide(color: purpleNeon, width: 1.8),
                    ),
                  ),
                  onChanged: (val) {
                    setState(() {
                      addr[f.key] = val;
                      _modifiedIds.add(sId);
                    });
                  },
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  Widget _buildLocDropdown({
    required String label,
    required String value,
    required List<dynamic> items,
    required bool isDark,
    required Color textColor,
    required ValueChanged<String?> onChanged,
  }) {
    final validValues = items.map((e) => _optVal(e)).toSet();
    final safeValue = validValues.contains(value) ? value : '';
    const purpleNeon = Color(0xFFA855F7);
    final mutedColor = isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);

    return DropdownButtonFormField<String>(
      value: safeValue,
      isExpanded: true,
      dropdownColor: isDark ? const Color(0xFF181D32) : Colors.white,
      iconEnabledColor: purpleNeon,
      style: TextStyle(
        fontWeight: FontWeight.w800,
        color: textColor,
        fontSize: 12.5,
      ),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(
          fontWeight: FontWeight.bold,
          fontSize: 12,
          color: mutedColor,
        ),
        isDense: true,
        filled: true,
        fillColor: isDark
            ? const Color(0xFF0B0E1A).withOpacity(0.68)
            : const Color(0xFFF1F5F9),
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(
            color: purpleNeon.withOpacity(isDark ? 0.35 : 0.25),
            width: 1.2,
          ),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(
            color: purpleNeon.withOpacity(isDark ? 0.35 : 0.25),
            width: 1.2,
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: purpleNeon, width: 1.8),
        ),
      ),
      items: [
        const DropdownMenuItem<String>(
          value: '',
          child: Text('-- اختر --', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 11.5)),
        ),
        ...items.map((node) {
          final v = _optVal(node);
          return DropdownMenuItem<String>(
            value: v,
            child: Text(
              _optTxt(node),
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 11.5, color: textColor),
              overflow: TextOverflow.ellipsis,
            ),
          );
        }),
      ],
      onChanged: onChanged,
    );
  }
}

class _AnimatedAuditorOrbIcon extends StatelessWidget {
  final IconData icon;
  final Color primaryColor;
  final Color secondaryColor;
  final Animation<double> animation;
  final double size;

  const _AnimatedAuditorOrbIcon({
    required this.icon,
    required this.primaryColor,
    required this.secondaryColor,
    required this.animation,
    this.size = 60,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      builder: (context, _) {
        final t = animation.value;
        final floatOffset = math.sin(t * 2 * math.pi) * 2.8;

        return SizedBox(
          width: size,
          height: size,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Positioned.fill(
                child: CustomPaint(
                  painter: _AuditorAtomOrbitPainter(
                    progress: t,
                    primaryColor: primaryColor,
                    secondaryColor: secondaryColor,
                  ),
                ),
              ),
              Transform.translate(
                offset: Offset(0, floatOffset),
                child: Container(
                  width: size * 0.64,
                  height: size * 0.64,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        primaryColor,
                        Color.lerp(primaryColor, Colors.black, 0.25)!,
                      ],
                    ),
                    border: Border.all(
                      color: Colors.white.withOpacity(0.45),
                      width: 1.3,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: primaryColor.withOpacity(0.45),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Icon(
                    icon,
                    size: size * 0.34,
                    color: Colors.white,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _AuditorAtomOrbitPainter extends CustomPainter {
  final double progress;
  final Color primaryColor;
  final Color secondaryColor;

  _AuditorAtomOrbitPainter({
    required this.progress,
    required this.primaryColor,
    required this.secondaryColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final angle = progress * 2 * math.pi;

    for (final tilt in [0.45, -0.45]) {
      canvas.save();
      canvas.translate(center.dx, center.dy);
      canvas.rotate(tilt);
      final rect = Rect.fromCenter(
        center: Offset.zero,
        width: size.width * 0.94,
        height: size.height * 0.38,
      );
      final orbitPaint = Paint()
        ..color = primaryColor.withOpacity(0.45)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4;
      canvas.drawOval(rect, orbitPaint);

      final dir = tilt > 0 ? angle : -angle + 1.5;
      final dx = (size.width * 0.47) * math.cos(dir);
      final dy = (size.height * 0.19) * math.sin(dir);
      canvas.drawCircle(
        Offset(dx, dy),
        2.6,
        Paint()..color = secondaryColor,
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant _AuditorAtomOrbitPainter oldDelegate) =>
      oldDelegate.progress != progress;
}
