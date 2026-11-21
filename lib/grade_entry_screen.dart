import 'dart:convert';
import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'app_core.dart';
import 'central_keyboard_navigation.dart';
import 'emis_live_sync.dart';
import 'google_speech_service.dart';
import 'voice_result_processor.dart';
import 'legacy_speech_service.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'platform_permissions.dart';

/// Allows a numeric grade, or one of the two EMIS special marks: م / غ.
/// Pressing '*' writes 'غ' (غائب) and pressing '#' writes 'م' (مجاز).
class GradeValueInputFormatter extends TextInputFormatter {
  const GradeValueInputFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final raw = newValue.text;
    if (raw.isEmpty) {
      return newValue;
    }

    // إذا ضغط المستخدم على زر '*' يتحول الحقل فوراً إلى 'غ' (غائب)
    if (raw.contains('*') || raw.contains('＊')) {
      return const TextEditingValue(
        text: 'غ',
        selection: TextSelection.collapsed(offset: 1),
      );
    }

    // إذا ضغط المستخدم على زر '#' يتحول الحقل فوراً إلى 'م' (مجاز)
    if (raw.contains('#') || raw.contains('＃')) {
      return const TextEditingValue(
        text: 'م',
        selection: TextSelection.collapsed(offset: 1),
      );
    }

    if (raw == 'م' || raw == 'غ') {
      return newValue;
    }

    // في حال كانت القيمة السابقة 'غ' أو 'م' وبدأ المستخدم بكتابة رقم جديد، يتم استبدال الحرف بالرقم الجديد
    var candidate = raw;
    if ((oldValue.text == 'غ' || oldValue.text == 'م') && raw.length > 1) {
      candidate = raw.replaceAll('غ', '').replaceAll('م', '');
    }

    final normalized = AppCore.normalizeDigitsOnly(candidate);
    if (RegExp(r'^\d+$').hasMatch(normalized)) {
      return TextEditingValue(
        text: normalized,
        selection: TextSelection.collapsed(offset: normalized.length),
      );
    }

    return oldValue;
  }
}

class GradeEntryScreen extends StatefulWidget {
  final String token;
  final String schoolId;
  final List<Map<String, dynamic>> teachingAssignments;
  const GradeEntryScreen({
    super.key,
    required this.token,
    required this.schoolId,
    this.teachingAssignments = const [],
  });

  @override
  State<GradeEntryScreen> createState() => _GradeEntryScreenState();
}

class _GradeEntryScreenState extends State<GradeEntryScreen>
    with SingleTickerProviderStateMixin {
  List<Map<String, dynamic>> stages = [];
  List<Map<String, dynamic>> subjects = [];
  List<Map<String, dynamic>> rooms = [];
  List<Map<String, dynamic>> exams = [];
  List<Map<String, dynamic>> students = [];
  bool _sortStudentsAlphabetically = true;
  final Map<String, int> _studentApiOrder = {};

  String? stageId, subjectId, roomId, examId;
  final Map<int, TextEditingController> grades = {};
  // Last values known to be stored by EMIS; used to distinguish an intentional
  // deletion from a field that was simply left empty.
  final Map<int, String> _originalGrades = {};
  final Map<int, GlobalKey> _voiceFieldKeys = {};

  bool loading = true;
  bool loadingStudents = false;
  bool saving = false;
  String? error;

  bool _speechListening = false;
  String? _speechError;
  int? _activeVoiceSessionId;
  int? _activeStudentVoiceId;
  int _nextVoiceSessionId = 0;
  bool _speechStopRequested = false;
  bool _micPointerDown = false;
  bool _voiceArrowPointerDown = false;
  bool _voiceSequentialMode = AppCore.voiceSequentialAutoStart;
  int _sequentialVoiceIndex = 0;
  double _voiceArrowLeft = AppCore.voiceArrowLeft;
  double? _voiceArrowTop = AppCore.voiceArrowTop;
  StreamSubscription<Map<String, dynamic>>? _googleSpeechSubscription;
  VoidCallback? _appCoreSettingsListener;
  bool _legacySpeechInitialized = false;
  bool _legacySpeechAvailable = false;
  Timer? _legacyFinalizationTimer;
  Timer? _googleFinalizationTimer;
  Timer? _liveTimer;
  final GlobalKey<EmisLiveSyncState> _liveSyncKey = GlobalKey<EmisLiveSyncState>();
  late final AnimationController _ambientController;
  late final CentralKeyboardNavigator _centralNav;

  // حفظ النص المتراكم بين الأنفاس لكل طالب في الجلسة الصوتية الحالية
  String _accumulatedGradeText = '';

  GlobalKey _voiceFieldKey(int studentId) =>
      _voiceFieldKeys.putIfAbsent(studentId, GlobalKey.new);

  Map<String, String> get h => {
        'Authorization': widget.token.toLowerCase().startsWith('bearer ')
            ? widget.token
            : 'Bearer ${widget.token}',
        'Accept': 'application/json',
        'Content-Type': 'application/json',
      };

  @override
  void initState() {
    super.initState();
    _ambientController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 6),
    )..repeat();

    _centralNav = CentralKeyboardNavigator(
      sequenceBuilder: _buildCentralKeyboardSequence,
      onFieldFocused: _focusLive,
      shouldSkipField: AppCore.hasConfiguredDefaultForStudentField,
    );

    _voiceSequentialMode = AppCore.voiceInputEnabled && AppCore.voiceSequentialAutoStart;
    _voiceArrowLeft = AppCore.voiceArrowLeft;
    _voiceArrowTop = AppCore.voiceArrowTop;
    _googleSpeechSubscription = GoogleSpeechService.events.listen(_handleGoogleSpeechEvent);
    _appCoreSettingsListener = () {
      if (mounted) setState(() {});
    };
    AppCore.voiceSettingsRevision.addListener(_appCoreSettingsListener!);
    _liveTimer = Timer.periodic(const Duration(milliseconds: 700), (_) => _pushLive());
    _loadStages();
  }

  @override
  void dispose() {
    _liveTimer?.cancel();
    _ambientController.dispose();
    _centralNav.dispose();
    unawaited(GoogleSpeechService.cancelListening());
    _googleSpeechSubscription?.cancel();
    if (_appCoreSettingsListener != null) {
      AppCore.voiceSettingsRevision.removeListener(_appCoreSettingsListener!);
      _appCoreSettingsListener = null;
    }
    _legacyFinalizationTimer?.cancel();
    _googleFinalizationTimer?.cancel();
    unawaited(LegacySpeechService.cancel());
    for (final c in grades.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _pushLive() {
    if (saving) return;
    _liveSyncKey.currentState?.pushValues(_liveValues());
  }

  void _focusLive(String key) {
    _liveSyncKey.currentState?.focusField(key);
    _liveSyncKey.currentState?.pushValues(_liveValues());
  }

  List<String> _buildCentralKeyboardSequence() {
    final seq = <String>[];
    if (stages.isNotEmpty) seq.add('stageId');
    if (subjects.isNotEmpty) seq.add('subjectId');
    if (rooms.isNotEmpty) seq.add('classRoomId');
    if (exams.isNotEmpty) seq.add('examId');
    for (final student in students) {
      final id = int.tryParse('${student['id']}');
      if (id != null) {
        seq.add('grade_$id');
      }
    }
    return seq;
  }

  Map<String, String> _liveValues() => {
        for (final entry in grades.entries) '${entry.key}': entry.value.text,
        'stageId': stageId ?? '',
        'subjectId': subjectId ?? '',
        'classRoomId': roomId ?? '',
        'examId': examId ?? '',
      };

  dynamic _unwrap(dynamic d) {
    if (d is Map && d.containsKey('data') && d['data'] != null) {
      return d['data'];
    }
    return d;
  }

  List<Map<String, dynamic>> _maps(dynamic value) {
    final raw = _unwrap(value);
    if (raw is! List) return <Map<String, dynamic>>[];
    return [
      for (final item in raw)
        if (item is Map) Map<String, dynamic>.from(item)
    ];
  }

  Future<dynamic> _getJson(String endpoint) async {
    final response = await http.get(
      Uri.parse('https://emis.moedu.gov.iq/api$endpoint'),
      headers: h,
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
        'HTTP ${response.statusCode}: ${utf8.decode(response.bodyBytes)}',
      );
    }
    return jsonDecode(utf8.decode(response.bodyBytes));
  }

  Future<List<Map<String, dynamic>>> _getList(String endpoint) async =>
      _maps(await _getJson(endpoint));

  String _id(Map<String, dynamic> x) =>
      '${x['id'] ?? x['examId'] ?? x['value'] ?? x['stageId'] ?? ''}';

  String _label(Map<String, dynamic> x) =>
      '${x['displayName'] ?? x['label'] ?? x['name'] ?? x['text'] ?? x['value'] ?? x['id'] ?? ''}';

  bool _bool(dynamic v) {
    if (v is bool) return v;
    if (v is num) return v != 0;
    return '$v'.toLowerCase() == 'true' || '$v' == '1';
  }

  Future<void> _loadStages() async {
    try {
      await AppCore.ensureLoaded();
      _voiceArrowLeft = AppCore.voiceArrowLeft;
      _voiceArrowTop = AppCore.voiceArrowTop;

      final result =
          await _getList('/selectoption/getschoolstages/${widget.schoolId}');
      if (!mounted) return;
      setState(() {
        stages = result.where((x) => widget.teachingAssignments.isEmpty || widget.teachingAssignments.any((a) => '${a['stageId']}' == _id(x))).toList();
        loading = false;
        error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        loading = false;
        error = '$e';
      });
    }
  }

  Future<void> _stageChanged(String? value) async {
    if (value == null) return;
    _clearStudents();
    setState(() {
      stageId = value;
      subjectId = null;
      roomId = null;
      examId = null;
      subjects = [];
      rooms = [];
      exams = [];
      students = [];
      error = null;
    });
    try {
      final result = await _getList(
        '/subject/getsubjectsselect?stageId=$value&schoolId=${widget.schoolId}',
      );
      if (mounted) setState(() => subjects = result.where((x) => widget.teachingAssignments.isEmpty || widget.teachingAssignments.any((a) => '${a['stageId']}' == stageId && '${a['subjectId']}' == _id(x))).toList());
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  Future<void> _subjectChanged(String? value) async {
    if (value == null || stageId == null) return;
    _clearStudents();
    setState(() {
      subjectId = value;
      roomId = null;
      examId = null;
      rooms = [];
      exams = [];
      students = [];
      error = null;
    });
    try {
      final roomResult = await _getList(
        '/selectoption/getClassRooms?stageId=$stageId&schoolId=${widget.schoolId}&subjectId=$value',
      );
      final raw = await _getJson(
        '/examscore/getexamsformarks?schoolId=${widget.schoolId}&stageId=$stageId&subjectId=$value',
      );
      final rawExams = raw is Map ? raw['exams'] : raw;
      final examResult = _maps(rawExams);
      if (!mounted) return;
      setState(() {
        rooms = roomResult.where((x) => widget.teachingAssignments.isEmpty || widget.teachingAssignments.any((a) => '${a['stageId']}' == stageId && '${a['subjectId']}' == value && '${a['classRoomId']}' == _id(x))).toList();
        exams = examResult;
      });
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  Future<void> _roomChanged(String? value) async {
    _clearStudents();
    setState(() {
      roomId = value;
      students = [];
      error = null;
    });
    if (examId != null) {
      await _loadStudents();
    }
  }

  Future<void> _examChanged(String? value) async {
    _clearStudents();
    setState(() {
      examId = value;
      students = [];
      error = null;
    });
    await _loadStudents();
  }

  Map<String, dynamic>? _findExamById(String id) {
    final target = id.trim();
    for (final exam in exams) {
      for (final key in const ['id', 'examId', 'exam_id', 'value']) {
        final val = exam[key];
        if (val != null && '$val'.trim() == target) {
          return exam;
        }
      }
    }
    return null;
  }

  Set<String> _examIdCandidatesForExam(Map<String, dynamic>? examObj, String fallbackId) {
    final candidates = <String>{fallbackId.trim()};
    if (examObj != null) {
      for (final key in const ['id', 'examId', 'exam_id', 'value']) {
        final value = examObj[key];
        if (value != null && '$value'.trim().isNotEmpty) {
          candidates.add('$value'.trim());
        }
      }
    }
    return candidates;
  }

  Set<String> _examIdCandidates(String selectedExamId) {
    return _examIdCandidatesForExam(_findExamById(selectedExamId), selectedExamId);
  }

  Map<dynamic, dynamic>? _findStudentGradeForExam(
    Map<String, dynamic> student,
    Set<String> selectedExamIds,
  ) {
    final rawGrades =
        student['grades'] ?? student['examScores'] ?? student['examGrades'] ?? student['scores'] ?? student['marks'];

    if (rawGrades is List) {
      for (final item in rawGrades) {
        if (item is! Map) continue;
        final gradeMap = Map<dynamic, dynamic>.from(item);
        final rawExamId = gradeMap['examId'] ??
            gradeMap['exam_id'] ?? gradeMap['examID'] ??
            gradeMap['exam'] ?? gradeMap['markId'] ?? gradeMap['id'];
        if (rawExamId != null && selectedExamIds.contains('$rawExamId'.trim())) {
          return gradeMap;
        }
      }
    } else if (rawGrades is Map) {
      for (final id in selectedExamIds) {
        if (rawGrades.containsKey(id)) {
          final val = rawGrades[id];
          if (val is Map) return Map<dynamic, dynamic>.from(val);
          return {'grade': val};
        }
      }
    }
    return null;
  }

  num? _resolveStudentGradeNumber(
    Map<String, dynamic> student,
    String targetExamId, [
    Set<String>? visited,
  ]) {
    visited ??= <String>{};
    final normalizedId = targetExamId.trim();
    if (visited.contains(normalizedId)) return null;
    visited.add(normalizedId);

    final examMeta = _findExamById(normalizedId);
    final candidateIds = _examIdCandidatesForExam(examMeta, normalizedId);

    final directMatch = _findStudentGradeForExam(student, candidateIds);
    if (directMatch != null) {
      final rawVal = directMatch['grade'] ??
          directMatch['score'] ??
          directMatch['mark'] ??
          directMatch['markScore'] ??
          directMatch['scoreValue'] ??
          directMatch['value'];
      if (rawVal != null) {
        final parsed = num.tryParse(_normalizeNumber('$rawVal'));
        if (parsed != null) return parsed;
      }
    }

    if (examMeta == null) return null;
    final typeObj = examMeta['type'];
    if (typeObj is Map) {
      final operation = '${typeObj['operation'] ?? ''}'.toUpperCase().trim();
      final dependsOn = typeObj['dependsOn'];

      if (dependsOn is List && dependsOn.isNotEmpty) {
        final depValues = <num>[];
        for (final depId in dependsOn) {
          final val = _resolveStudentGradeNumber(
            student,
            '$depId',
            Set<String>.from(visited),
          );
          if (val != null) {
            depValues.add(val);
          }
        }

        if (operation == 'AVERAGE') {
          if (depValues.length == dependsOn.length && depValues.isNotEmpty) {
            final sum = depValues.fold<num>(0, (a, b) => a + b);
            return (sum / depValues.length).round();
          }
        } else if (operation == 'MAX') {
          if (depValues.isNotEmpty) {
            return depValues.reduce((a, b) => a > b ? a : b);
          }
        }
      }
    }

    return null;
  }

  Map<String, dynamic>? get _currentExam {
    for (final exam in exams) {
      if (_id(exam) == examId) return exam;
    }
    return null;
  }

  String _normalizeExamLabel(String value) => value
      .replaceAll(RegExp(r'\s+'), '')
      .replaceAll('أ', 'ا')
      .replaceAll('إ', 'ا')
      .replaceAll('آ', 'ا')
      .replaceAll('ى', 'ي')
      .toLowerCase();

  bool get _isCalculatedExam {
    final exam = _currentExam;
    if (exam == null) return false;
    final calculation = exam['type'];
    if (calculation is Map && '${calculation['operation'] ?? ''}'.trim().isNotEmpty) {
      return true;
    }
    final label = _normalizeExamLabel(_label(exam));
    const calculatedLabels = [
      'معدل النصف الأول',
      'معدل النصف الثاني',
      'معدل السعي السنوي',
      'نتيجة امتحان نهائية',
      'الدرجة النهائية',
    ];
    return calculatedLabels.any((value) => label.contains(_normalizeExamLabel(value))) ||
        label.contains('finalresult') || label.contains('finalgrade') ||
        label.contains('firstsemesteraverage') || label.contains('secondsemesteraverage') ||
        label.contains('annualcourseworkaverage');
  }

  void _clearStudents() {
    for (final c in grades.values) {
      c.dispose();
    }
    grades.clear();
    _originalGrades.clear();
  }

  String _studentName(Map<String, dynamic> student) =>
      '${student['name'] ?? student['studentName'] ?? student['fullName'] ?? student['displayName'] ?? 'طالب'}'.trim();

  String _alphabeticalKey(String value) {
    var key = value.trim().toLowerCase();
    const replacements = {
      'أ': 'ا', 'إ': 'ا', 'آ': 'ا', 'ٱ': 'ا',
      'ى': 'ي', 'ؤ': 'و', 'ئ': 'ي',
    };
    replacements.forEach((from, to) => key = key.replaceAll(from, to));
    key = key.replaceAll(RegExp(r'[ًٌٍَُِّْـ]'), '');
    return key;
  }

  String _studentIdentity(Map<String, dynamic> student) =>
      '${student['id'] ?? student['studentId'] ?? ''}';

  void _rememberStudentOrder(List<Map<String, dynamic>> roster) {
    _studentApiOrder.clear();
    for (var i = 0; i < roster.length; i++) {
      _studentApiOrder[_studentIdentity(roster[i])] = i;
    }
  }

  void _applyStudentSorting() {
    if (_sortStudentsAlphabetically) {
      students.sort((a, b) => _alphabeticalKey(_studentName(a))
          .compareTo(_alphabeticalKey(_studentName(b))));
    } else {
      students.sort((a, b) =>
          (_studentApiOrder[_studentIdentity(a)] ?? 0)
              .compareTo(_studentApiOrder[_studentIdentity(b)] ?? 0));
    }
  }

  void _setAlphabeticalSorting(bool enabled) {
    setState(() {
      _sortStudentsAlphabetically = enabled;
      _applyStudentSorting();
    });
  }

  Widget _studentSortingControl(bool isDark) {
    const purpleNeon = Color(0xFFA855F7);
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final mutedColor = isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);

    return Container(
      margin: const EdgeInsets.only(top: 12, bottom: 6),
      decoration: BoxDecoration(
        gradient: AppCore.isWindows ? null : isDark
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
        color: AppCore.isWindows ? AppCore.windowsGradientFallback(isDark
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
              )) : null,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: purpleNeon.withOpacity(isDark ? 0.40 : 0.28),
          width: 1.2,
        ),
      ),
      child: SwitchListTile.adaptive(
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
        value: _sortStudentsAlphabetically,
        onChanged: _setAlphabeticalSorting,
        activeColor: purpleNeon,
        title: Text(
          'ترتيب أسماء الطلاب أبجديًا',
          style: TextStyle(
            fontWeight: FontWeight.w900,
            fontSize: 14,
            color: textColor,
          ),
        ),
        subtitle: Text(
          'يبدأ الترتيب مفعّلًا افتراضيًا',
          style: TextStyle(
            color: mutedColor,
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
          ),
        ),
        secondary: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: purpleNeon.withOpacity(0.15),
          ),
          child: const Icon(
            Icons.sort_by_alpha_rounded,
            color: purpleNeon,
            size: 20,
          ),
        ),
      ),
    );
  }

  Widget _keyboardShortcutNoticeCard(bool isDark) {
    const goldNeon = Color(0xFFF59E0B);
    const emeraldNeon = Color(0xFF10B981);
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);

    return Container(
      margin: const EdgeInsets.only(top: 6, bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        gradient: AppCore.isWindows ? null : isDark
            ? LinearGradient(
                colors: [
                  const Color(0xFF141829).withOpacity(0.95),
                  Color.lerp(const Color(0xFF1E1732), goldNeon, 0.12)!,
                ],
              )
            : LinearGradient(
                colors: [
                  const Color(0xFFFFFBEB),
                  Color.lerp(Colors.white, goldNeon, 0.08)!,
                ],
              ),
        color: AppCore.isWindows ? AppCore.windowsGradientFallback(isDark
            ? LinearGradient(
                colors: [
                  const Color(0xFF141829).withOpacity(0.95),
                  Color.lerp(const Color(0xFF1E1732), goldNeon, 0.12)!,
                ],
              )
            : LinearGradient(
                colors: [
                  const Color(0xFFFFFBEB),
                  Color.lerp(Colors.white, goldNeon, 0.08)!,
                ],
              )) : null,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: goldNeon.withOpacity(isDark ? 0.50 : 0.40),
          width: 1.3,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: goldNeon.withOpacity(0.18),
            ),
            child: const Icon(
              Icons.dialpad_rounded,
              color: goldNeon,
              size: 20,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: RichText(
              textDirection: TextDirection.rtl,
              text: TextSpan(
                style: TextStyle(
                  fontFamily: Theme.of(context).textTheme.bodyMedium?.fontFamily,
                  color: textColor,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  height: 1.45,
                ),
                children: const [
                  TextSpan(
                    text: 'ملاحظة اختصارات لوحة الأرقام: ',
                    style: TextStyle(
                      color: goldNeon,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  TextSpan(text: 'اضغط زر '),
                  TextSpan(
                    text: '( * )',
                    style: TextStyle(
                      color: Color(0xFFEF4444),
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  TextSpan(text: ' لكتابة حرف '),
                  TextSpan(
                    text: '"غ" (غائب)',
                    style: TextStyle(
                      color: Color(0xFFEF4444),
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  TextSpan(text: '، واضغط زر '),
                  TextSpan(
                    text: '( # )',
                    style: TextStyle(
                      color: emeraldNeon,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  TextSpan(text: ' لكتابة حرف '),
                  TextSpan(
                    text: '"م" (مجاز)',
                    style: TextStyle(
                      color: emeraldNeon,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  TextSpan(text: '.'),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _loadStudents() async {
    if (stageId == null || subjectId == null || examId == null) return;
    setState(() {
      loadingStudents = true;
      error = null;
    });
    try {
      var endpoint =
          '/examscore/getstudentswithgrades?schoolId=${widget.schoolId}&stageId=$stageId&subjectId=$subjectId';
      if (roomId != null && roomId!.isNotEmpty) {
        endpoint += '&classroomId=$roomId';
      }
      final result = await _getList(endpoint);
      _clearStudents();

      for (final student in result) {
        final id = int.tryParse('${student['id']}');
        if (id == null) continue;
        final existingValue = _resolveStudentGradeNumber(student, examId!);
        final initialText = existingValue == null ? '' : '$existingValue';
        _originalGrades[id] = initialText;
        grades[id] = TextEditingController(text: initialText);
      }

      if (mounted) {
        setState(() {
          students = result;
          _rememberStudentOrder(result);
          _applyStudentSorting();
          loadingStudents = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          loadingStudents = false;
          error = '$e';
        });
      }
    }
  }

  void _showVoiceMessage(String message) {
    if (!mounted) return;
    setState(() => _speechError = message);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message, style: const TextStyle(fontWeight: FontWeight.bold)), backgroundColor: const Color(0xFFF59E0B), behavior: SnackBarBehavior.floating),
    );
  }

  bool get _voiceAvailableBySetting => AppCore.voiceInputEnabled;

  Future<bool> _ensureMicrophoneAccess() async {
    if (!_voiceAvailableBySetting) {
      _showVoiceMessage('الميكروفون مغلق من الإعدادات.');
      return false;
    }
    if (await ensureEmisMicrophonePermission()) return true;
    _showVoiceMessage('لم يتم منح صلاحية الميكروفون.');
    return false;
  }

  bool get _usingLegacyVoice => AppCore.voiceRecognitionEngine == 'legacy';

  Future<bool> _initLegacySpeech() async {
    if (_legacySpeechInitialized) return _legacySpeechAvailable;
    _legacySpeechAvailable = await LegacySpeechService.initialize(
      onStatus: (status) {
        if (!mounted || !_usingLegacyVoice) return;
        final listening = status == 'listening';
        if (listening) {
          setState(() => _speechListening = true);
          return;
        }
        if (_speechStopRequested) {
          _scheduleLegacyFinalization();
        } else if (_activeVoiceSessionId != null &&
            _activeStudentVoiceId != null &&
            AppCore.voiceAutoRestart) {
          final currentId = _activeStudentVoiceId!;
          final currentSession = _activeVoiceSessionId!;
          Future<void>.delayed(
            Duration(milliseconds: AppCore.voiceRestartDelayMs),
            () {
              if (mounted &&
                  _usingLegacyVoice &&
                  !_speechStopRequested &&
                  _activeVoiceSessionId == currentSession &&
                  _activeStudentVoiceId == currentId) {
                _resumeLegacyListening(currentId, currentSession);
              }
            },
          );
        } else if (_activeVoiceSessionId != null) {
          _scheduleLegacyFinalization();
        }
      },
      onError: (SpeechRecognitionError error) {
        if (!mounted || !_usingLegacyVoice) return;
        if (_speechStopRequested || !AppCore.voiceAutoRestart) {
          setState(() {
            _speechListening = false;
            _speechError = error.errorMsg;
          });
          _scheduleLegacyFinalization();
        }
      },
    );
    _legacySpeechInitialized = true;
    return _legacySpeechAvailable;
  }

  void _scheduleLegacyFinalization() {
    _legacyFinalizationTimer?.cancel();
    _legacyFinalizationTimer = Timer(const Duration(milliseconds: 350), () {
      if (!mounted || !_usingLegacyVoice) return;
      _finishLegacyVoiceSessionAndStartPending();
    });
  }

  Future<void> _finishLegacyVoiceSessionAndStartPending() async {
    _legacyFinalizationTimer?.cancel();
    _legacyFinalizationTimer = null;
    _speechStopRequested = false;
    _activeVoiceSessionId = null;
    _activeStudentVoiceId = null;
    _accumulatedGradeText = '';
    if (mounted) setState(() => _speechListening = false);
  }

  Future<void> _resumeLegacyListening(int studentId, int sessionId) async {
    if (!mounted || saving || _speechStopRequested) return;
    if (_activeVoiceSessionId != sessionId) return;
    try {
      await LegacySpeechService.listen(
        onResult: (dynamic result) => _onLegacyResult(studentId, sessionId, result),
      );
    } catch (_) {}
  }

  void _onLegacyResult(int studentId, int sessionId, dynamic result) {
    if (!mounted || !_usingLegacyVoice || _activeVoiceSessionId != sessionId) return;
    final raw = '${result.recognizedWords ?? ''}'.trim();
    if (raw.isEmpty) return;
    final isFinal = result.finalResult == true;

    final segment = AppCore.extractSpokenDigits(raw, allowGradeMarks: true);
    if (segment.isEmpty) return;

    final text = VoiceResultProcessor.resolveNumeric(
      segmentCandidates: [segment],
      fullCandidates: [raw],
      accumulated: _accumulatedGradeText,
      allowGradeMarks: true,
      preferSingleNumber: true,
    );

    // لا يتم مسح القيمة المكتوبة في الحقل واستبدالها إلا عند التقاط حديث فعلي جديد غير فارغ
    final controller = grades[studentId];
    if (controller != null && text.isNotEmpty) {
      _accumulatedGradeText = text;
      controller.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
      _pushLive();
    }

    if (isFinal && (_speechStopRequested || !AppCore.voiceAutoRestart)) {
      _finishLegacyVoiceSessionAndStartPending();
    }
  }

  void _handleGoogleSpeechEvent(Map<String, dynamic> event) {
    if (!mounted) return;
    final sessionId = int.tryParse('${event['sessionId'] ?? ''}');
    if (sessionId == null || sessionId != _activeVoiceSessionId) return;

    final type = '${event['type'] ?? ''}';
    if (type == 'listening' || type == 'ready' || type == 'begin' || type == 'partial') {
      if (!_speechListening && !_speechStopRequested) {
        setState(() => _speechListening = true);
      }
    }

    if (type == 'partial' || type == 'result') {
      final alternates = (event['alternates'] is List)
          ? (event['alternates'] as List).map((e) => '$e').toList()
          : <String>[];
      final segment = '${event['segment'] ?? ''}'.trim();
      final candidates = <String>[
        if (segment.isNotEmpty) segment,
        '${event['text'] ?? ''}',
        ...alternates,
      ].map((e) => e.trim()).where((e) => e.isNotEmpty).toList();

      final text = VoiceResultProcessor.resolveNumeric(
        segmentCandidates: [if (segment.isNotEmpty) segment],
        fullCandidates: candidates,
        accumulated: _accumulatedGradeText,
        allowGradeMarks: true,
        preferSingleNumber: true,
      );

      // بمجرد التقاط حديث فعلي ينتج عنه درجة أو علامة، يتم استبدال القيمة المكتوبة في الحقل بالقيمة الجديدة
      if (text.isNotEmpty) {
        _accumulatedGradeText = text;
        final targetStudentId = _activeStudentVoiceId ??
            ((_sequentialVoiceIndex >= 0 && _sequentialVoiceIndex < grades.keys.length)
                ? grades.keys.elementAt(_sequentialVoiceIndex)
                : null);
        if (targetStudentId != null) {
          final controller = grades[targetStudentId];
          if (controller != null) {
            controller.value = TextEditingValue(
              text: text,
              selection: TextSelection.collapsed(offset: text.length),
            );
            _pushLive();
          }
        }
      }
    }

    if (type == 'error') {
      final code = event['code'];
      final message = '${event['message'] ?? ''}'.trim();
      if (message.isNotEmpty && code != 7 && code != 6) {
        setState(() => _speechError = message);
      }
      if (_speechStopRequested) {
        _finishGoogleVoiceSession();
      }
      return;
    }

    if (type == 'stopped') {
      if (_speechStopRequested || !AppCore.voiceAutoRestart) {
        _finishGoogleVoiceSession();
      }
    }
  }

  Future<void> _startLegacyVoiceSession(int studentId) async {
    if (!mounted || saving) return;
    final available = await _initLegacySpeech();
    if (!available || !mounted) return;

    final sessionId = ++_nextVoiceSessionId;
    _activeVoiceSessionId = sessionId;
    _activeStudentVoiceId = studentId;
    // تصفير المتراكم المؤقت للجلسة دون مسح الحقل حتى يبدأ التحدث الفعلي
    _accumulatedGradeText = '';
    _scrollGradeFieldIntoView(studentId);
    _speechStopRequested = false;
    if (mounted) {
      setState(() {
        _speechError = null;
        _speechListening = true;
      });
    }

    try {
      await LegacySpeechService.listen(
        onResult: (dynamic result) => _onLegacyResult(studentId, sessionId, result),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _speechError = '$e');
    }
  }

  Future<void> _startGoogleVoiceSession(int studentId) async {
    final info = await GoogleSpeechService.getInfo();
    if (info['available'] != true) {
      _showVoiceMessage('خدمة Google للتعرف على الكلام غير متوفرة.');
      return;
    }
    final sessionId = ++_nextVoiceSessionId;
    _activeVoiceSessionId = sessionId;
    _activeStudentVoiceId = studentId;
    // تصفير المتراكم المؤقت للجلسة دون مسح الحقل حتى يبدأ التحدث الفعلي
    _accumulatedGradeText = '';
    _scrollGradeFieldIntoView(studentId);
    _speechStopRequested = false;
    if (mounted) {
      setState(() {
        _speechError = null;
        _speechListening = true;
      });
    }
    await GoogleSpeechService.startListening(sessionId: sessionId, locale: 'ar-IQ');
  }

  void _finishGoogleVoiceSession() {
    _speechStopRequested = false;
    _activeVoiceSessionId = null;
    _activeStudentVoiceId = null;
    _accumulatedGradeText = '';
    if (mounted) setState(() => _speechListening = false);
  }

  Future<void> _toggleVoiceInput(int studentId) async {
    if (saving) return;
    if (!await _ensureMicrophoneAccess()) return;
    if (_usingLegacyVoice) {
      if (_activeVoiceSessionId != null && _activeStudentVoiceId == studentId) {
        _speechStopRequested = true;
        await LegacySpeechService.stop();
        _finishLegacyVoiceSessionAndStartPending();
      } else {
        if (_activeVoiceSessionId != null) {
          _speechStopRequested = true;
          await LegacySpeechService.stop();
        }
        await _startLegacyVoiceSession(studentId);
      }
      return;
    }
    if (_activeVoiceSessionId != null && _activeStudentVoiceId == studentId) {
      _speechStopRequested = true;
      await GoogleSpeechService.stopListening();
      _finishGoogleVoiceSession();
    } else {
      if (_activeVoiceSessionId != null) {
        _speechStopRequested = true;
        await GoogleSpeechService.stopListening();
      }
      await _startGoogleVoiceSession(studentId);
    }
  }

  void _scrollGradeFieldIntoView(int studentId) {
    if (!mounted) return;
    final fieldKey = _voiceFieldKeys[studentId];
    final context = fieldKey?.currentContext;
    if (context != null) {
      Scrollable.ensureVisible(
        context,
        duration: const Duration(milliseconds: 420),
        curve: Curves.easeOutCubic,
        alignment: 0.16,
      );
    }
  }

  void _stopVoiceFromPointer() {
    if (_voiceArrowPointerDown || _micPointerDown) {
      _voiceArrowPointerDown = false;
      _micPointerDown = false;
      return;
    }
    if (_voiceSequentialMode) return;
    if (_activeVoiceSessionId != null) {
      _speechStopRequested = true;
      _activeVoiceSessionId = null;
      _activeStudentVoiceId = null;
      _accumulatedGradeText = '';
      setState(() => _speechListening = false);
      if (_usingLegacyVoice) {
        unawaited(LegacySpeechService.stop());
      } else {
        unawaited(GoogleSpeechService.stopListening());
      }
    }
  }

  void _markMicPointerDown() {
    _micPointerDown = true;
    Future<void>.microtask(() => _micPointerDown = false);
  }

  void _markVoiceArrowPointerDown() {
    _voiceArrowPointerDown = true;
    Future<void>.microtask(() => _voiceArrowPointerDown = false);
  }

  Future<void> _toggleSequentialModeFromButton() async {
    setState(() => _voiceSequentialMode = !_voiceSequentialMode);
    if (_voiceSequentialMode && students.isNotEmpty) {
      _sequentialVoiceIndex = 0;
      final firstId = int.tryParse('${students.first['id']}');
      if (firstId != null) {
        await _toggleVoiceInput(firstId);
      }
    } else {
      _stopSequentialVoiceMode();
    }
  }

  void _stopSequentialVoiceMode() {
    if (!_voiceSequentialMode) return;
    setState(() => _voiceSequentialMode = false);
    if (_activeVoiceSessionId != null) {
      _speechStopRequested = true;
      _activeVoiceSessionId = null;
      _activeStudentVoiceId = null;
      _accumulatedGradeText = '';
      setState(() => _speechListening = false);
      if (_usingLegacyVoice) {
        unawaited(LegacySpeechService.stop());
      } else {
        unawaited(GoogleSpeechService.stopListening());
      }
    }
  }

  Future<void> _advanceSequentialVoice() async {
    if (!_voiceSequentialMode || students.isEmpty) return;
    if (_sequentialVoiceIndex < students.length - 1) {
      setState(() => _sequentialVoiceIndex++);
      final nextId = int.tryParse('${students[_sequentialVoiceIndex]['id']}');
      if (nextId != null) {
        _scrollGradeFieldIntoView(nextId);
        await _toggleVoiceInput(nextId);
      }
    }
  }

  Future<void> _retreatSequentialVoice() async {
    if (!_voiceSequentialMode || students.isEmpty) return;
    if (_sequentialVoiceIndex > 0) {
      setState(() => _sequentialVoiceIndex--);
      final prevId = int.tryParse('${students[_sequentialVoiceIndex]['id']}');
      if (prevId != null) {
        _scrollGradeFieldIntoView(prevId);
        await _toggleVoiceInput(prevId);
      }
    }
  }

  Widget _sequentialVoiceControl(bool isDark) {
    final enabled = _voiceSequentialMode;
    const purpleNeon = Color(0xFFA855F7);
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final mutedColor = isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);

    return Container(
      margin: const EdgeInsets.only(top: 12, bottom: 6),
      decoration: BoxDecoration(
        gradient: AppCore.isWindows ? null : isDark
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
        color: AppCore.isWindows ? AppCore.windowsGradientFallback(isDark
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
              )) : null,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: purpleNeon.withOpacity(isDark ? 0.40 : 0.28),
          width: 1.2,
        ),
      ),
      child: SwitchListTile.adaptive(
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
        value: enabled,
        onChanged: (_) => _toggleSequentialModeFromButton(),
        activeColor: purpleNeon,
        title: Text(
          'التنقل الصوتي بين حقول الدرجات',
          style: TextStyle(
            fontWeight: FontWeight.w900,
            fontSize: 14,
            color: textColor,
          ),
        ),
        subtitle: Text(
          'عند التفعيل يظهر سهمان للتنقل الصوتي السريع بين درجات الطلاب.',
          textDirection: TextDirection.rtl,
          style: TextStyle(
            color: mutedColor,
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
          ),
        ),
        secondary: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: purpleNeon.withOpacity(0.15),
          ),
          child: Icon(
            enabled ? Icons.keyboard_double_arrow_down_rounded : Icons.keyboard_arrow_down_rounded,
            color: purpleNeon,
            size: 22,
          ),
        ),
      ),
    );
  }

  Widget _fixedSequentialArrow() {
    if (!_voiceSequentialMode || students.isEmpty) return const SizedBox.shrink();
    final atFirst = _sequentialVoiceIndex <= 0;
    final atLast = _sequentialVoiceIndex >= students.length - 1;

    final media = MediaQuery.of(context);
    final maxWidth = media.size.width - 62;
    final maxHeight = media.size.height - media.padding.top - kToolbarHeight - 165;
    final currentTop = (_voiceArrowTop ?? media.size.height * 0.32)
        .clamp(8.0, maxHeight > 8.0 ? maxHeight : 8.0)
        .toDouble();
    final currentLeft = _voiceArrowLeft
        .clamp(0.0, maxWidth > 0.0 ? maxWidth : 0.0)
        .toDouble();

    final isDockedLeft = currentLeft <= 4.0;
    final isDockedRight = currentLeft >= maxWidth - 4.0;
    final borderRadius = isDockedLeft
        ? const BorderRadius.horizontal(right: Radius.circular(24))
        : (isDockedRight
            ? const BorderRadius.horizontal(left: Radius.circular(24))
            : BorderRadius.circular(24));

    Widget arrowButton({
      required IconData icon,
      required VoidCallback? onTap,
      required bool disabled,
      required String tooltip,
    }) {
      return Tooltip(
        message: tooltip,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: disabled ? null : onTap,
            child: SizedBox(
              width: 58,
              height: 64,
              child: Icon(
                icon,
                size: 50,
                color: disabled ? Colors.grey.shade400 : const Color(0xFFA855F7),
              ),
            ),
          ),
        ),
      );
    }

    return Positioned(
      left: currentLeft,
      top: currentTop,
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (_) => _markVoiceArrowPointerDown(),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (_) => _markVoiceArrowPointerDown(),
          onPanUpdate: (details) {
            _markVoiceArrowPointerDown();
            setState(() {
              _voiceArrowLeft = (currentLeft + details.delta.dx)
                  .clamp(0.0, maxWidth > 0.0 ? maxWidth : 0.0)
                  .toDouble();
              _voiceArrowTop = (currentTop + details.delta.dy)
                  .clamp(8.0, maxHeight > 8.0 ? maxHeight : 8.0)
                  .toDouble();
            });
          },
          onPanEnd: (_) {
            AppCore.saveVoiceSettings(
              arrowLeft: _voiceArrowLeft,
              arrowTop: _voiceArrowTop,
            );
          },
          child: Material(
            color: Colors.transparent,
            child: Container(
              width: 62,
              padding: const EdgeInsets.symmetric(vertical: 4),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(AppCore.voiceArrowOpacity),
                borderRadius: borderRadius,
                boxShadow: const [
                  BoxShadow(blurRadius: 9, offset: Offset(1, 2), color: Colors.black26)
                ],
                border: Border.all(color: const Color(0xFFA855F7), width: 2),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  arrowButton(
                    icon: Icons.keyboard_arrow_up_rounded,
                    onTap: _retreatSequentialVoice,
                    disabled: atFirst,
                    tooltip: 'السابق',
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Icon(
                      Icons.drag_indicator_rounded,
                      size: 18,
                      color: const Color(0xFFA855F7).withOpacity(0.7),
                    ),
                  ),
                  arrowButton(
                    icon: Icons.keyboard_arrow_down_rounded,
                    onTap: _advanceSequentialVoice,
                    disabled: atLast,
                    tooltip: 'التالي',
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _normalizeNumber(String value) => AppCore.normalizeDigitsOnly(value)
      .replaceAll(' ', '').replaceAll('،', '.').replaceAll(',', '.').replaceAll('٫', '.');

  Future<http.Response> _postGrade(
    int studentId,
    int examNumber,
    dynamic grade,
  ) async {
    return http.post(
      Uri.parse('https://emis.moedu.gov.iq/api/examscore/updateexamgrade'),
      headers: h,
      body: jsonEncode({
        'studentId': studentId,
        'examId': examNumber,
        'grade': grade,
      }),
    );
  }

  Future<void> _saveGrades() async {
    final exam = _currentExam;
    if (exam == null) return;
    if (_isCalculatedExam) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('هذا المعدل يُحتسب في EMIS ولا يمكن إدخال درجته يدويًا.')),
      );
      return;
    }

    final examNumber = int.tryParse(_id(exam));
    if (examNumber == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('معرف الامتحان غير صالح في بيانات EMIS'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    setState(() => saving = true);
    int ok = 0, failed = 0, unchanged = 0;
    final failures = <String>[];
    try {
      for (final student in students) {
        final studentId = int.tryParse('${student['id']}');
        if (studentId == null) continue;
        final raw = grades[studentId]?.text.trim() ?? '';
        final original = (_originalGrades[studentId] ?? '').trim();

        if (raw == original) {
          unchanged++;
          continue;
        }
        if (raw.isEmpty && original.isEmpty) {
          unchanged++;
          continue;
        }

        dynamic parsed;
        if (raw.isNotEmpty) {
          final special = raw.trim();
          if (special == 'م' || special == 'غ') {
            parsed = special;
          } else {
            final numeric = int.tryParse(_normalizeNumber(raw));
            final max = int.tryParse('${exam['maxAllowedGrade'] ?? exam['max'] ?? 100}') ?? 100;
            if (numeric == null || numeric < 0 || numeric > max) {
              failed++;
              failures.add('الطالب $studentId: الدرجة "$raw" غير صالحة؛ أدخل رقمًا من 0 إلى $max أو م أو غ');
              continue;
            }
            parsed = numeric;
          }
        }

        try {
          var response = await _postGrade(studentId, examNumber, parsed);
          var body = utf8.decode(response.bodyBytes).trim();
          if (response.statusCode == 400 && body.toLowerCase().contains('exam not found')) {
            final alternatives = <int>{};
            for (final k in const ['examId', 'id', 'value']) {
              final n = int.tryParse('${exam[k] ?? ''}');
              if (n != null) alternatives.add(n);
            }
            for (final alt in alternatives) {
              if (alt == examNumber) continue;
              response = await _postGrade(studentId, alt, parsed);
              body = utf8.decode(response.bodyBytes).trim();
              if (response.statusCode >= 200 && response.statusCode < 300) break;
            }
          }
          if (response.statusCode >= 200 && response.statusCode < 300) {
            ok++;
            _originalGrades[studentId] = raw;
          } else {
            failed++;
            failures.add('الطالب $studentId: HTTP ${response.statusCode}${body.isEmpty ? '' : ' — $body'}');
          }
        } catch (e) {
          failed++;
          failures.add('الطالب $studentId: $e');
        }
      }
      if (!mounted) return;
      setState(() => saving = false);
      final details = failures.isEmpty ? '' : '\n${failures.take(3).join('\n')}';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('تم إرسال $ok تغيير${failed == 0 ? '' : ' — فشل $failed'}${ok == 0 && unchanged > 0 ? ' — لا توجد تغييرات جديدة' : ''}$details', style: const TextStyle(fontWeight: FontWeight.bold)),
          backgroundColor: failed == 0 ? const Color(0xFF10B981) : const Color(0xFFF97316),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 8),
        ),
      );
      if (ok > 0 && mounted) {
        await _refreshGradesFromEmis();
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> _refreshGradesFromEmis() async {
    if (stageId == null || subjectId == null || examId == null) return;
    try {
      var endpoint = '/examscore/getstudentswithgrades?schoolId=${widget.schoolId}&stageId=$stageId&subjectId=$subjectId';
      if (roomId != null && roomId!.isNotEmpty) endpoint += '&classroomId=$roomId';
      final result = await _getList(endpoint);
      if (!mounted) return;
      setState(() {
        students = result;
        _rememberStudentOrder(result);
        _applyStudentSorting();
        for (final student in result) {
          final id = int.tryParse('${student['id']}');
          if (id == null || !grades.containsKey(id)) continue;
          final value = _resolveStudentGradeNumber(student, examId!);
          if (value != null) {
            grades[id]!.text = '$value';
            _originalGrades[id] = '$value';
          } else if ((_originalGrades[id] ?? '').isEmpty) {
            grades[id]!.text = '';
          }
        }
      });
    } catch (_) {}
  }

  Widget _buildAmbientGlow({required Color color, required double size}) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: AppCore.isWindows ? null : RadialGradient(
          colors: [color, color.withOpacity(0.0)],
        ),
        color: AppCore.isWindows ? AppCore.windowsGradientFallback(RadialGradient(
          colors: [color, color.withOpacity(0.0)],
        )) : null,
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
            gradient: AppCore.isWindows ? null : isDark
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
            color: AppCore.isWindows ? AppCore.windowsGradientFallback(isDark
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
                  )) : null,
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
              _AnimatedGradeEntryOrbIcon(
                icon: Icons.edit_note_rounded,
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
                      'نظام الامتحانات والدرجات',
                      style: TextStyle(
                        color: isDark ? goldNeon : purpleNeon,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'إدخال الدرجات',
                      style: TextStyle(
                        color: isDark ? Colors.white : const Color(0xFF0F172A),
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'قراءة مباشرة من EMIS وحفظ الدرجات',
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
    final exam = _currentExam;
    final max =
        int.tryParse('${exam?['maxAllowedGrade'] ?? exam?['max'] ?? 100}') ??
            100;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final dropdownTextColor = isDark ? Colors.white : const Color(0xFF0F172A);

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
          backgroundColor: isDark ? const Color(0xFF070913) : const Color(0xFFF2F5FA),
          appBar: null,
          bottomNavigationBar: SafeArea(
            minimum: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: SizedBox(
              height: 58,
              child: FilledButton.icon(
                onPressed: loading || saving || loadingStudents || students.isEmpty || examId == null || _isCalculatedExam
                    ? null
                    : _saveGrades,
                icon: saving
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : Icon(_isCalculatedExam ? Icons.lock_outline_rounded : Icons.save_rounded),
                label: Text(
                  saving ? 'جاري حفظ الدرجات...' : (_isCalculatedExam ? 'معدل مستورد من EMIS' : 'حفظ الدرجات'),
                  style: const TextStyle(
                    fontWeight: FontWeight.w900,
                    fontSize: 16.5,
                  ),
                ),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 15),
                  backgroundColor: purpleNeon,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18),
                  ),
                  elevation: 6,
                  shadowColor: purpleNeon.withOpacity(0.35),
                ),
              ),
            ),
          ),
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
                child: loading
                    ? const Center(
                        child: CircularProgressIndicator(color: purpleNeon),
                      )
                    : ListView(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                        physics: const BouncingScrollPhysics(),
                        children: [
                          _buildTopHeader(isDark),
                          const SizedBox(height: 14),
                          _sequentialVoiceControl(isDark),
                          const SizedBox(height: 14),
                          Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              gradient: AppCore.isWindows ? null : isDark
                                  ? const LinearGradient(
                                      colors: [
                                        Color(0xFF141829),
                                        Color(0xFF1E1732),
                                      ],
                                    )
                                  : const LinearGradient(
                                      colors: [
                                        Color(0xFFFFFFFF),
                                        Color(0xFFF8FAFC),
                                      ],
                                    ),
                              color: AppCore.isWindows ? AppCore.windowsGradientFallback(isDark
                                  ? const LinearGradient(
                                      colors: [
                                        Color(0xFF141829),
                                        Color(0xFF1E1732),
                                      ],
                                    )
                                  : const LinearGradient(
                                      colors: [
                                        Color(0xFFFFFFFF),
                                        Color(0xFFF8FAFC),
                                      ],
                                    )) : null,
                              borderRadius: BorderRadius.circular(22),
                              border: Border.all(
                                color: purpleNeon.withOpacity(
                                    isDark ? 0.45 : 0.30),
                                width: 1.3,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: purpleNeon.withOpacity(
                                      isDark ? 0.12 : 0.08),
                                  blurRadius: 18,
                                  offset: const Offset(0, 6),
                                ),
                              ],
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                _drop('stageId', 'الصف الدراسي', stageId, stages, _stageChanged, isDark, dropdownTextColor),
                                const SizedBox(height: 12),
                                _drop('subjectId', 'المادة', subjectId, subjects, _subjectChanged, isDark, dropdownTextColor),
                                const SizedBox(height: 12),
                                _drop('classRoomId', 'الشعبة', roomId, rooms, _roomChanged, isDark, dropdownTextColor),
                                const SizedBox(height: 12),
                                _drop(
                                  'examId',
                                  'فصل الدرجات / الامتحان',
                                  examId,
                                  exams,
                                  _examChanged,
                                  isDark,
                                  dropdownTextColor,
                                ),
                              ],
                            ),
                          ),
                          if (error != null) ...[
                            const SizedBox(height: 12),
                            Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: const Color(0xFFEF4444).withOpacity(0.12),
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(
                                    color: const Color(0xFFEF4444)
                                        .withOpacity(0.4)),
                              ),
                              child: Text(
                                error!,
                                style: const TextStyle(
                                  color: Color(0xFFEF4444),
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                          ],
                          if (exam != null) ...[
                            const SizedBox(height: 14),
                            _examCard(exam, max, isDark),
                          ],
                          if (loadingStudents) ...[
                            const SizedBox(height: 32),
                            const Center(
                              child: CircularProgressIndicator(color: purpleNeon),
                            ),
                          ] else if (students.isNotEmpty) ...[
                            const SizedBox(height: 14),
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    'الطلاب (${students.length})',
                                    style: TextStyle(
                                      fontSize: 17,
                                      fontWeight: FontWeight.w900,
                                      color: isDark ? Colors.white : const Color(0xFF0F172A),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            _studentSortingControl(isDark),
                            if (!_isCalculatedExam) _keyboardShortcutNoticeCard(isDark),
                            const SizedBox(height: 8),
                            ...students.map((student) => _studentCard(student, max, isDark)),
                          ],
                        ],
                      ),
              ),
              _fixedSequentialArrow(),
              if (!loading)
                Positioned(
                  left: 0,
                  bottom: 0,
                  child: EmisLiveSync(
                    key: _liveSyncKey,
                    url:
                        'https://emis.moedu.gov.iq/centers/schools/${widget.schoolId}/marks',
                    mode: 'edit',
                    entity: 'examscore',
                    token: widget.token,
                    aliases: {
                      'stageId': ['stageId', 'الصف الدراسي'],
                      'subjectId': ['subjectId', 'المادة'],
                      'classRoomId': ['classRoomId', 'الشعبة'],
                      'examId': ['examId', 'فصل الدرجات'],
                    },
                    onSnapshot: (values) {
                      if (saving) return;
                      for (final entry in values.entries) {
                        final studentId = int.tryParse(entry.key);
                        if (studentId != null && grades.containsKey(studentId)) {
                          final controller = grades[studentId];
                          if (controller != null && controller.text != entry.value) {
                            controller.value = TextEditingValue(
                              text: entry.value,
                              selection: TextSelection.collapsed(offset: entry.value.length),
                            );
                          }
                        }
                      }
                      if (mounted) setState(() {});
                    },
                    onStatus: (v) {},
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _drop(
    String fieldId,
    String label,
    String? value,
    List<Map<String, dynamic>> data,
    ValueChanged<String?> onChanged,
    bool isDark,
    Color textColor,
  ) {
    const purpleNeon = Color(0xFFA855F7);
    final mutedColor = isDark ? const Color(0xFF94A3B8) : const Color(0xFF475569);

    final fieldKey = _centralNav.keyForField(
      fieldId,
      NavigableFieldType.dropdown,
      isAvailable: () => data.isNotEmpty,
    );

    return DropdownButtonFormField<String>(
      key: fieldKey,
      onTap: () {
        FocusManager.instance.primaryFocus?.unfocus();
        _centralNav.notifyManualDropdownTap(fieldId, fieldKey.currentContext);
      },
      value: data.any((x) => _id(x) == value) ? value : null,
      isExpanded: true,
      dropdownColor: isDark ? const Color(0xFF181D32) : Colors.white,
      iconEnabledColor: purpleNeon,
      style: TextStyle(
        fontWeight: FontWeight.w800,
        color: textColor,
        fontSize: 13.5,
      ),
      decoration: InputDecoration(
        labelText: label,
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
            const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
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
      items: data
          .map(
            (x) => DropdownMenuItem<String>(
              value: _id(x),
              child: Text(
                _label(x),
                overflow: TextOverflow.ellipsis,
                textDirection: TextDirection.rtl,
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  color: textColor,
                  fontSize: 13.5,
                ),
              ),
            ),
          )
          .where((x) => x.value != null && x.value!.isNotEmpty)
          .toList(),
      onChanged: data.isEmpty ? null : onChanged,
    );
  }

  Widget _examCard(Map<String, dynamic> exam, int max, bool isDark) {
    final calculated = _isCalculatedExam;
    const purpleNeon = Color(0xFFA855F7);
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: AppCore.isWindows ? null : isDark
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
        color: AppCore.isWindows ? AppCore.windowsGradientFallback(isDark
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
              )) : null,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: purpleNeon.withOpacity(isDark ? 0.40 : 0.28),
          width: 1.2,
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: purpleNeon.withOpacity(0.15),
            ),
            child: Icon(
              calculated ? Icons.calculate_rounded : Icons.assignment_rounded,
              color: purpleNeon,
              size: 24,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _label(exam),
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    fontSize: 15.5,
                    color: textColor,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  calculated
                      ? 'معدل محسوب من نظام EMIS — للعرض فقط، تُستورد قيمه من النظام.'
                      : 'الدرجة القصوى: $max  •  الطلاب: ${students.length}  •  (* = غ غائب | # = م مجاز)',
                  style: TextStyle(
                    color: calculated
                        ? const Color(0xFF10B981)
                        : (isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B)),
                    fontWeight: FontWeight.w700,
                    fontSize: 11.5,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _studentCard(Map<String, dynamic> student, int max, bool isDark) {
    final id = int.tryParse('${student['id']}') ?? -1;
    final name =
        '${student['name'] ?? student['fullName'] ?? student['studentName'] ?? ''}';
    
    final isThisStudentActiveMic = _speechListening && _activeStudentVoiceId == id;
    const purpleNeon = Color(0xFFA855F7);
    const blueNeon = Color(0xFF3B82F6);
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final mutedColor = isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);
    final centralEnabled = AppCore.centralKeyboardNavigationEnabled;

    final fieldKey = _centralNav.keyForField(
      'grade_$id',
      NavigableFieldType.text,
    );
    final focusNode = _centralNav.focusNodeForText('grade_$id');

    return Container(
      margin: const EdgeInsets.only(bottom: 9),
      decoration: BoxDecoration(
        gradient: AppCore.isWindows ? null : isDark
            ? LinearGradient(
                colors: [
                  const Color(0xFF141829).withOpacity(0.95),
                  Color.lerp(const Color(0xFF0F1322), blueNeon, 0.06)!,
                ],
              )
            : LinearGradient(
                colors: [
                  Colors.white.withOpacity(0.96),
                  Color.lerp(const Color(0xFFF8FAFC), blueNeon, 0.03)!,
                ],
              ),
        color: AppCore.isWindows ? AppCore.windowsGradientFallback(isDark
            ? LinearGradient(
                colors: [
                  const Color(0xFF141829).withOpacity(0.95),
                  Color.lerp(const Color(0xFF0F1322), blueNeon, 0.06)!,
                ],
              )
            : LinearGradient(
                colors: [
                  Colors.white.withOpacity(0.96),
                  Color.lerp(const Color(0xFFF8FAFC), blueNeon, 0.03)!,
                ],
              )) : null,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: blueNeon.withOpacity(isDark ? 0.35 : 0.22),
          width: 1.2,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Row(
          key: _voiceFieldKey(id),
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: purpleNeon.withOpacity(0.15),
              ),
              child: const Icon(Icons.person_rounded, color: purpleNeon, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    style: TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 14.5,
                      color: textColor,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'رقم الطالب: ${student['id'] ?? ''}',
                    style: TextStyle(
                      color: mutedColor,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: (_) => _markMicPointerDown(),
                  child: IconButton(
                    tooltip: 'إدخال الدرجة بالصوت',
                    onPressed: _isCalculatedExam ? null : () => _toggleVoiceInput(id),
                    icon: Icon(
                      isThisStudentActiveMic
                          ? Icons.mic_rounded
                          : Icons.mic_none_rounded,
                      color: isThisStudentActiveMic
                          ? const Color(0xFFEF4444)
                          : purpleNeon,
                    ),
                  ),
                ),
                SizedBox(
                  width: 86,
                  child: TextField(
                    key: fieldKey,
                    focusNode: focusNode,
                    enabled: !loadingStudents,
                    readOnly: _isCalculatedExam,
                    controller: grades[id],
                    keyboardType: TextInputType.phone,
                    textInputAction: centralEnabled ? TextInputAction.next : TextInputAction.done,
                    inputFormatters: const [GradeValueInputFormatter()],
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontWeight: FontWeight.w900,
                      color: textColor,
                      fontSize: 14,
                    ),
                    onSubmitted: (_) {
                      if (centralEnabled) {
                        _centralNav.handleFieldSubmitted('grade_$id');
                      }
                    },
                    onEditingComplete: () {
                      if (centralEnabled) {
                        _centralNav.handleFieldSubmitted('grade_$id');
                      } else {
                        FocusManager.instance.primaryFocus?.unfocus();
                      }
                    },
                    onChanged: (_) => _pushLive(),
                    decoration: InputDecoration(
                      hintText: '',
                      filled: true,
                      fillColor: isDark
                          ? const Color(0xFF0B0E1A).withOpacity(0.68)
                          : const Color(0xFFF1F5F9),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
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
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _AnimatedGradeEntryOrbIcon extends StatelessWidget {
  final IconData icon;
  final Color primaryColor;
  final Color secondaryColor;
  final Animation<double> animation;
  final double size;

  const _AnimatedGradeEntryOrbIcon({
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
                  painter: _GradeEntryAtomOrbitPainter(
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
                    gradient: AppCore.isWindows ? null : LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        primaryColor,
                        Color.lerp(primaryColor, Colors.black, 0.25)!,
                      ],
                    ),
                    color: AppCore.isWindows ? AppCore.windowsGradientFallback(LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        primaryColor,
                        Color.lerp(primaryColor, Colors.black, 0.25)!,
                      ],
                    )) : null,
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

class _GradeEntryAtomOrbitPainter extends CustomPainter {
  final double progress;
  final Color primaryColor;
  final Color secondaryColor;

  _GradeEntryAtomOrbitPainter({
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
  bool shouldRepaint(covariant _GradeEntryAtomOrbitPainter oldDelegate) =>
      oldDelegate.progress != progress;
}
