import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'app_core.dart';

class DailyAbsenceScreen extends StatefulWidget {
  final String token;
  final String schoolId;
  final List<Map<String, dynamic>> teachingAssignments;

  const DailyAbsenceScreen({
    super.key,
    required this.token,
    required this.schoolId,
    required this.teachingAssignments,
  });

  @override
  State<DailyAbsenceScreen> createState() => _DailyAbsenceScreenState();
}

class _DailyAbsenceScreenState extends State<DailyAbsenceScreen>
    with SingleTickerProviderStateMixin {
  List<Map<String, dynamic>> stages = [];
  List<Map<String, dynamic>> subjects = [];
  List<Map<String, dynamic>> rooms = [];
  List<Map<String, dynamic>> students = [];
  bool _sortStudentsAlphabetically = true;
  final Map<String, int> _studentApiOrder = {};

  String? stageId;
  String? subjectId;
  String? roomId;
  int? academicYearId;
  String academicYearLabel = '';
  DateTime selectedDate = DateTime.now();
  int recordId = 0;
  bool loading = true;
  bool loadingStudents = false;
  bool saving = false;
  String? error;

  late final AnimationController _ambientController;

  Map<String, String> get _headers => {
        'Authorization': widget.token.toLowerCase().startsWith('bearer ')
            ? widget.token
            : 'Bearer ${widget.token}',
        'Accept': 'application/json',
        'Content-Type': 'application/json',
      };

  String _id(Map<String, dynamic> x) =>
      '${x['value'] ?? x['id'] ?? x['stageId'] ?? x['subjectId'] ?? x['classroomId'] ?? x['classRoomId'] ?? x['classroomID'] ?? x['studentId'] ?? ''}';

  String _label(Map<String, dynamic> x) =>
      '${x['displayName'] ?? x['label'] ?? x['name'] ?? x['text'] ?? x['title'] ?? _id(x)}';

  bool _bool(dynamic value) =>
      value == true || value == 1 || '$value'.toLowerCase() == 'true';

  String _dateString(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

  Future<dynamic> _getJson(String endpoint) async {
    final response = await http.get(
      Uri.parse('https://emis.moedu.gov.iq/api$endpoint'),
      headers: _headers,
    ).timeout(const Duration(seconds: 25));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('HTTP ${response.statusCode}: ${utf8.decode(response.bodyBytes)}');
    }
    final body = utf8.decode(response.bodyBytes);
    return body.trim().isEmpty ? <String, dynamic>{} : jsonDecode(body);
  }

  Future<dynamic> _postJson(String endpoint, Map<String, dynamic> payload) async {
    final response = await http.post(
      Uri.parse('https://emis.moedu.gov.iq/api$endpoint'),
      headers: _headers,
      body: jsonEncode(payload),
    ).timeout(const Duration(seconds: 25));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('HTTP ${response.statusCode}: ${utf8.decode(response.bodyBytes)}');
    }
    final body = utf8.decode(response.bodyBytes);
    return body.trim().isEmpty ? <String, dynamic>{} : jsonDecode(body);
  }

  List<Map<String, dynamic>> _maps(dynamic raw) {
    for (var depth = 0; depth < 5; depth++) {
      if (raw is List) {
        return [
          for (final item in raw)
            if (item is Map) Map<String, dynamic>.from(item),
        ];
      }
      if (raw is Map) {
        if (raw['data'] is List) {
          raw = raw['data'];
          continue;
        }
        if (raw['data'] is Map) {
          raw = raw['data'];
          continue;
        }
        if (raw['items'] is List) {
          raw = raw['items'];
          continue;
        }
        if (raw['results'] is List) {
          raw = raw['results'];
          continue;
        }
      }
      break;
    }
    return [];
  }

  @override
  void initState() {
    super.initState();
    _ambientController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 6),
    )..repeat();
    _initialLoad();
  }

  @override
  void dispose() {
    _ambientController.dispose();
    super.dispose();
  }

  Future<void> _initialLoad() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final results = await Future.wait([
        _getJson('/selectoption/getschoolstages/${widget.schoolId}'),
        _getJson('/selectoption/getActiveAcademicYear'),
      ]);
      final loadedStages = _maps(results[0]);
      final years = _maps(results[1]);
      if (years.isNotEmpty) {
        academicYearId = int.tryParse('${years.first['value'] ?? years.first['id'] ?? ''}');
        academicYearLabel = '${years.first['displayName'] ?? years.first['label'] ?? ''}';
      }
      if (!mounted) return;
      setState(() {
        stages = loadedStages.where((x) => widget.teachingAssignments.isEmpty || widget.teachingAssignments.any((a) => '${a['stageId']}' == _id(x))).toList();
        loading = false;
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
    setState(() {
      stageId = value;
      subjectId = null;
      roomId = null;
      subjects = [];
      rooms = [];
      students = [];
      recordId = 0;
      error = null;
      loadingStudents = true;
    });
    try {
      final result = _maps(await _getJson(
        '/subject/getsubjectsselect?stageId=$value&schoolId=${widget.schoolId}',
      ));
      final available = result.where((x) => widget.teachingAssignments.isEmpty || widget.teachingAssignments.any((a) => '${a['stageId'] ?? a['stageID']}' == value && '${a['subjectId'] ?? a['subjectID']}' == _id(x))).toList();
      if (!mounted) return;
      setState(() {
        subjects = available;
        subjectId = available.isNotEmpty ? _id(available.first) : null;
        loadingStudents = false;
      });
      if (subjectId != null) await _subjectChanged(subjectId);
      else if (mounted) setState(() => error = 'لا توجد مادة مسندة لهذا الصف في حساب المعلم.');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        loadingStudents = false;
        error = '$e';
      });
    }
  }

  Future<void> _subjectChanged(String? value) async {
    if (value == null || stageId == null) return;
    setState(() {
      subjectId = value;
      roomId = null;
      rooms = [];
      students = [];
      recordId = 0;
      error = null;
      loadingStudents = true;
    });
    try {
      final result = _maps(await _getJson(
        '/selectoption/getClassRooms?stageId=$stageId&schoolId=${widget.schoolId}&subjectId=$value',
      ));
      if (!mounted) return;
      setState(() {
        rooms = result.where((x) {
          if (widget.teachingAssignments.isEmpty) return true;
          final roomIdFromOption = _id(x);
          return widget.teachingAssignments.any((a) {
            final assignmentStage = '${a['stageId'] ?? a['stageID'] ?? ''}';
            final assignmentSubject = '${a['subjectId'] ?? a['subjectID'] ?? ''}';
            final assignmentRoom = '${a['classRoomId'] ?? a['classroomId'] ?? a['classRoomID'] ?? a['classroomID'] ?? ''}';
            return assignmentStage == stageId &&
                assignmentSubject == value &&
                assignmentRoom == roomIdFromOption;
          });
        }).toList();
        loadingStudents = false;
        if (rooms.length == 1) {
          roomId = _id(rooms.first);
        }
      });
      if (rooms.length == 1) await _loadStudents();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        loadingStudents = false;
        error = '$e';
      });
    }
  }

  Future<void> _roomChanged(String? value) async {
    setState(() {
      roomId = value;
      students = [];
      recordId = 0;
      error = null;
    });
    await _loadStudents();
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
    return key.replaceAll(RegExp(r'[ًٌٍَُِّْـ]'), '');
  }

  String _studentIdentity(Map<String, dynamic> student) =>
      '${student['studentId'] ?? student['id'] ?? ''}';

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
    const emeraldNeon = Color(0xFF10B981);
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final mutedColor = isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);

    return Container(
      margin: const EdgeInsets.only(top: 12, bottom: 6),
      decoration: BoxDecoration(
        gradient: isDark
            ? LinearGradient(
                colors: [
                  const Color(0xFF141829).withOpacity(0.95),
                  Color.lerp(const Color(0xFF0F1322), emeraldNeon, 0.08)!,
                ],
              )
            : LinearGradient(
                colors: [
                  Colors.white.withOpacity(0.96),
                  const Color(0xFFF8FAFC).withOpacity(0.92),
                ],
              ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: emeraldNeon.withOpacity(isDark ? 0.40 : 0.28),
          width: 1.2,
        ),
      ),
      child: SwitchListTile.adaptive(
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
        value: _sortStudentsAlphabetically,
        onChanged: _setAlphabeticalSorting,
        activeColor: emeraldNeon,
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
            color: emeraldNeon.withOpacity(0.15),
          ),
          child: const Icon(
            Icons.sort_by_alpha_rounded,
            color: emeraldNeon,
            size: 20,
          ),
        ),
      ),
    );
  }

  Future<void> _loadStudents() async {
    if (stageId == null || subjectId == null || roomId == null) return;
    setState(() {
      loadingStudents = true;
      error = null;
    });
    try {
      var endpoint = '/SessionAbsence/GetSessionAbsences'
          '?schoolId=${widget.schoolId}&stageId=$stageId&subjectId=$subjectId';
      if (roomId != null && roomId!.isNotEmpty) {
        endpoint += '&classroomId=$roomId';
      }
      endpoint += '&page=1&rowsPerPage=20&sortBy=id&sortOrder=desc';
      final decoded = await _getJson(endpoint);
      dynamic wrapper = decoded;
      if (decoded is Map && decoded['data'] is Map) {
        wrapper = decoded['data'];
      }
      final parsed = _maps(decoded);
      if (wrapper is Map) {
        recordId = int.tryParse('${wrapper['id'] ?? 0}') ?? 0;
      }
      if (parsed.isEmpty) {
        var studentEndpoint = '/examscore/getstudentswithgrades'
            '?schoolId=${widget.schoolId}&stageId=$stageId&subjectId=$subjectId';
        if (roomId != null && roomId!.isNotEmpty) {
          studentEndpoint += '&classroomId=$roomId';
        }
        final fallback = _maps(await _getJson(studentEndpoint));
        parsed.addAll(fallback.map((s) => {
              'studentId': s['id'],
              'name': s['name'] ?? s['fullName'] ?? '',
              'isAbsent': false,
              'hasLeave': false,
            }));
      }
      if (!mounted) return;
      setState(() {
        students = parsed;
        _rememberStudentOrder(parsed);
        _applyStudentSorting();
        loadingStudents = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        loadingStudents = false;
        error = '$e';
      });
    }
  }

  void _toggleAbsent(int index, bool value) {
    setState(() => students[index]['isAbsent'] = value);
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: selectedDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(2035),
      locale: const Locale('ar', 'IQ'),
    );
    if (picked == null || !mounted) return;
    setState(() => selectedDate = picked);
  }

  Future<void> _saveAbsences() async {
    if (stageId == null || subjectId == null || roomId == null) {
      _message('اختر الصف والشعبة أولاً.');
      return;
    }
    if (rooms.isNotEmpty && (roomId == null || roomId!.isEmpty)) {
      _message('اختر الشعبة قبل تسجيل الغياب.');
      return;
    }
    if (academicYearId == null) {
      _message('تعذر تحديد السنة الدراسية الفعالة من EMIS.');
      return;
    }
    if (students.isEmpty) {
      _message('لا توجد قائمة طلاب لحفظ الغياب.');
      return;
    }
    final absentCount = students.where((student) => _bool(student['isAbsent'])).length;
    
    final isDark = AppCore.themeNotifier.value == ThemeMode.dark;

    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          backgroundColor:
              isDark ? const Color(0xFF141829) : const Color(0xFFFFFFFF),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
            side: BorderSide(
              color: const Color(0xFF10B981).withOpacity(0.45),
              width: 1.5,
            ),
          ),
          title: Text(
            'تأكيد حفظ الغياب',
            style: TextStyle(
              color: isDark ? Colors.white : const Color(0xFF0F172A),
              fontWeight: FontWeight.w900,
            ),
          ),
          content: Text(
            'هل تريد حفظ بيانات الغياب في EMIS؟\n\n'
            'التاريخ: ${_dateString(selectedDate)}\n'
            'عدد الطلاب: ${students.length}\n'
            'عدد الغائبين المحددّين: $absentCount',
            style: TextStyle(
              color: isDark ? const Color(0xFFCBD5E1) : const Color(0xFF475569),
              height: 1.45,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
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
                backgroundColor: const Color(0xFF10B981),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('تأكيد الحفظ', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() {
      saving = true;
      error = null;
    });
    try {
      final payload = <String, dynamic>{
        if (recordId > 0) 'id': recordId,
        'schoolId': int.tryParse(widget.schoolId) ?? widget.schoolId,
        'stageId': int.tryParse(stageId!) ?? stageId,
        'subjectId': int.tryParse(subjectId!) ?? subjectId,
        if (roomId != null && roomId!.isNotEmpty)
          'classroomId': int.tryParse(roomId!) ?? roomId,
        'absenceTaken': true,
        'academicYearId': academicYearId,
        'date': _dateString(selectedDate),
        'studentSessionAbsences': [
          for (final student in students)
            if (_bool(student['isAbsent']))
              {'studentId': int.tryParse('${student['studentId'] ?? student['id']}') ?? student['studentId'] ?? student['id']}
        ],
      };
      await _postJson('/SessionAbsence/AddSessionAbsences', payload);
      await _loadStudents();
      if (!mounted) return;
      _message('تم إرسال بيانات الغياب إلى EMIS.');
    } catch (e) {
      if (mounted) {
        setState(() => error = '$e');
        _message('تعذر حفظ الغياب: $e');
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  void _message(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, style: const TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: const Color(0xFF10B981),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Widget _selector({
    required String label,
    required String? value,
    required List<Map<String, dynamic>> items,
    required ValueChanged<String?> onChanged,
    required bool isDark,
  }) {
    final available = items.map(_id).where((x) => x.isNotEmpty).toSet();
    final safeValue = value != null && available.contains(value) ? value : null;
    const blueNeon = Color(0xFF3B82F6);
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final mutedColor = isDark ? const Color(0xFF94A3B8) : const Color(0xFF475569);

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: DropdownButtonFormField<String>(
        value: safeValue,
        isExpanded: true,
        dropdownColor: isDark ? const Color(0xFF181D32) : Colors.white,
        iconEnabledColor: blueNeon,
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
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide(
              color: blueNeon.withOpacity(isDark ? 0.35 : 0.25),
              width: 1.2,
            ),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide(
              color: blueNeon.withOpacity(isDark ? 0.35 : 0.25),
              width: 1.2,
            ),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: const BorderSide(color: blueNeon, width: 1.8),
          ),
        ),
        items: items
            .where((x) => _id(x).isNotEmpty)
            .map((x) => DropdownMenuItem<String>(
                  value: _id(x),
                  child: Text(
                    _label(x),
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      color: textColor,
                      fontSize: 13.5,
                    ),
                  ),
                ))
            .toList(),
        onChanged: onChanged,
      ),
    );
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
    const blueNeon = Color(0xFF3B82F6);
    const emeraldNeon = Color(0xFF10B981);
    const purpleNeon = Color(0xFFA855F7);
    const goldNeon = Color(0xFFF59E0B);

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
                      Color(0xFF112A2E),
                      Color(0xFF161A30),
                      Color(0xFF241734),
                    ],
                  )
                : const LinearGradient(
                    begin: Alignment.topRight,
                    end: Alignment.bottomLeft,
                    colors: [
                      Color(0xFFFFFFFF),
                      Color(0xFFF3F6FC),
                      Color(0xFFEDE9FE),
                    ],
                  ),
            borderRadius: BorderRadius.circular(28),
            border: Border.all(
              color: (isDark ? blueNeon : purpleNeon)
                  .withOpacity(isDark ? 0.45 : 0.30),
              width: 1.5,
            ),
            boxShadow: [
              BoxShadow(
                color: (isDark ? blueNeon : purpleNeon)
                    .withOpacity(0.12 + pulse * 0.08),
                blurRadius: 24,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Row(
            children: [
              _AnimatedAbsenceOrbIcon(
                icon: Icons.calendar_month_rounded,
                primaryColor: blueNeon,
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
                      'نظام الحضور والغياب',
                      style: TextStyle(
                        color: isDark
                            ? const Color(0xFF6EE7B7)
                            : const Color(0xFF7C3AED),
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'تسجيل الغياب اليومي',
                      style: TextStyle(
                        color: isDark ? Colors.white : const Color(0xFF0F172A),
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      academicYearLabel.isEmpty
                          ? 'السنة الدراسية من EMIS'
                          : 'السنة الدراسية: $academicYearLabel',
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
                        : blueNeon.withOpacity(0.10),
                    border: Border.all(
                      color: isDark
                          ? Colors.white.withOpacity(0.18)
                          : blueNeon.withOpacity(0.28),
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
      builder: (context, mode, _) {
        final dark = mode == ThemeMode.dark;
        final textColor = dark ? Colors.white : const Color(0xFF0F172A);
        final absentCount = students.where((s) => _bool(s['isAbsent'])).length;

        const blueNeon = Color(0xFF3B82F6);
        const emeraldNeon = Color(0xFF10B981);
        const purpleNeon = Color(0xFFA855F7);
        const goldNeon = Color(0xFFF59E0B);

        return Directionality(
          textDirection: TextDirection.rtl,
          child: Scaffold(
            backgroundColor:
                dark ? const Color(0xFF070913) : const Color(0xFFF2F5FA),
            appBar: null,
            bottomNavigationBar: SafeArea(
              minimum: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: SizedBox(
                height: 58,
                child: FilledButton.icon(
                  onPressed: loading || saving || loadingStudents || students.isEmpty
                      ? null
                      : _saveAbsences,
                  icon: saving
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.cloud_upload_rounded),
                  label: Text(
                    saving ? 'جاري حفظ الغياب...' : 'حفظ الغياب في EMIS',
                    style: const TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 16.5,
                    ),
                  ),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 15),
                    backgroundColor: blueNeon,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(18),
                    ),
                    elevation: 6,
                    shadowColor: blueNeon.withOpacity(0.35),
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
                              color: dark
                                  ? blueNeon.withOpacity(0.18)
                                  : purpleNeon.withOpacity(0.12),
                              size: 250,
                            ),
                          ),
                          Positioned(
                            top: 240 - shift,
                            left: -70,
                            child: _buildAmbientGlow(
                              color: dark
                                  ? purpleNeon.withOpacity(0.15)
                                  : goldNeon.withOpacity(0.12),
                              size: 270,
                            ),
                          ),
                          Positioned(
                            bottom: -60 + shift,
                            right: 20,
                            child: _buildAmbientGlow(
                              color: dark
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
                          child: CircularProgressIndicator(color: blueNeon),
                        )
                      : ListView(
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                          physics: const BouncingScrollPhysics(),
                          children: [
                            _buildTopHeader(dark),
                            const SizedBox(height: 14),
                            Container(
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                gradient: dark
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
                                borderRadius: BorderRadius.circular(22),
                                border: Border.all(
                                  color: blueNeon.withOpacity(
                                      dark ? 0.45 : 0.30),
                                  width: 1.3,
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: blueNeon.withOpacity(
                                        dark ? 0.12 : 0.08),
                                    blurRadius: 18,
                                    offset: const Offset(0, 6),
                                  ),
                                ],
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  OutlinedButton.icon(
                                    style: OutlinedButton.styleFrom(
                                      foregroundColor:
                                          dark ? Colors.white : const Color(0xFF0F172A),
                                      side: BorderSide(
                                          color: blueNeon.withOpacity(0.5)),
                                      padding: const EdgeInsets.symmetric(
                                          vertical: 13, horizontal: 14),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(16),
                                      ),
                                    ),
                                    onPressed: _pickDate,
                                    icon: const Icon(Icons.calendar_month_rounded,
                                        color: blueNeon),
                                    label: Text(
                                      'التاريخ: ${_dateString(selectedDate)}',
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w900,
                                          fontSize: 14),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 14),
                            _selector(
                                label: 'الصف الدراسي',
                                value: stageId,
                                items: stages,
                                onChanged: _stageChanged,
                                isDark: dark),
                            if (stageId != null && subjectId != null)
                              _selector(
                                  label: 'الشعبة',
                                  value: roomId,
                                  items: rooms,
                                  onChanged: _roomChanged,
                                  isDark: dark),
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
                            if (loadingStudents)
                              const Padding(
                                padding: EdgeInsets.all(32),
                                child: Center(
                                  child: CircularProgressIndicator(color: blueNeon),
                                ),
                              )
                            else if (stageId != null &&
                                subjectId != null &&
                                roomId != null) ...[
                              const SizedBox(height: 8),
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      'قائمة الطلاب (${students.length})',
                                      style: TextStyle(
                                        fontSize: 17,
                                        fontWeight: FontWeight.w900,
                                        color: textColor,
                                      ),
                                    ),
                                  ),
                                  Chip(
                                    backgroundColor:
                                        const Color(0xFFEF4444).withOpacity(0.15),
                                    side: BorderSide(
                                        color: const Color(0xFFEF4444)
                                            .withOpacity(0.35)),
                                    avatar: const Icon(Icons.person_off_rounded,
                                        size: 16, color: Color(0xFFEF4444)),
                                    label: Text(
                                      'الغائبون: $absentCount',
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w900,
                                        color: Color(0xFFEF4444),
                                        fontSize: 12,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              _studentSortingControl(dark),
                              const SizedBox(height: 8),
                              if (students.isEmpty)
                                Padding(
                                  padding: const EdgeInsets.all(30),
                                  child: Center(
                                    child: Text(
                                      'لم يعثر EMIS على طلاب لهذه الاختيارات.',
                                      style: TextStyle(
                                        fontWeight: FontWeight.w900,
                                        color: dark
                                            ? const Color(0xFF94A3B8)
                                            : const Color(0xFF64748B),
                                      ),
                                    ),
                                  ),
                                )
                              else
                                ...List.generate(students.length, (index) {
                                  final student = students[index];
                                  final absent = _bool(student['isAbsent']);
                                  final name =
                                      '${student['name'] ?? student['studentName'] ?? student['fullName'] ?? student['displayName'] ?? 'طالب'}'
                                          .trim();
                                  final studentId =
                                      '${student['studentId'] ?? student['id'] ?? ''}';
                                  return Container(
                                    margin: const EdgeInsets.only(bottom: 9),
                                    decoration: BoxDecoration(
                                      gradient: dark
                                          ? LinearGradient(
                                              colors: [
                                                const Color(0xFF141829)
                                                    .withOpacity(0.95),
                                                Color.lerp(
                                                    const Color(0xFF0F1322),
                                                    absent
                                                        ? const Color(
                                                            0xFFEF4444)
                                                        : blueNeon,
                                                    0.06)!,
                                              ],
                                            )
                                          : LinearGradient(
                                              colors: [
                                                Colors.white.withOpacity(0.96),
                                                Color.lerp(
                                                    const Color(0xFFF8FAFC),
                                                    absent
                                                        ? const Color(
                                                            0xFFEF4444)
                                                        : blueNeon,
                                                    0.03)!,
                                              ],
                                            ),
                                      borderRadius: BorderRadius.circular(18),
                                      border: Border.all(
                                        color: (absent
                                                ? const Color(0xFFEF4444)
                                                : blueNeon)
                                            .withOpacity(dark ? 0.35 : 0.22),
                                        width: 1.2,
                                      ),
                                    ),
                                    child: CheckboxListTile(
                                      value: absent,
                                      onChanged: (value) =>
                                          _toggleAbsent(index, value ?? false),
                                      activeColor: const Color(0xFFEF4444),
                                      checkColor: Colors.white,
                                      shape: RoundedRectangleBorder(
                                          borderRadius:
                                              BorderRadius.circular(18)),
                                      contentPadding:
                                          const EdgeInsets.symmetric(
                                              horizontal: 14, vertical: 4),
                                      secondary: Container(
                                        width: 42,
                                        height: 42,
                                        decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          color: (absent
                                                  ? const Color(0xFFEF4444)
                                                  : blueNeon)
                                              .withOpacity(0.15),
                                        ),
                                        child: Icon(
                                          absent
                                              ? Icons.person_off_rounded
                                              : Icons.person_rounded,
                                          color: absent
                                              ? const Color(0xFFEF4444)
                                              : blueNeon,
                                          size: 20,
                                        ),
                                      ),
                                      title: Text(
                                        name,
                                        style: TextStyle(
                                          fontWeight: FontWeight.w900,
                                          fontSize: 14.5,
                                          color: textColor,
                                        ),
                                      ),
                                      subtitle: Text(
                                        'رقم الطالب: $studentId',
                                        style: TextStyle(
                                          color: dark
                                              ? const Color(0xFF94A3B8)
                                              : const Color(0xFF64748B),
                                          fontSize: 12,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                      controlAffinity:
                                          ListTileControlAffinity.leading,
                                    ),
                                  );
                                }),
                            ],
                          ],
                        ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _AnimatedAbsenceOrbIcon extends StatelessWidget {
  final IconData icon;
  final Color primaryColor;
  final Color secondaryColor;
  final Animation<double> animation;
  final double size;

  const _AnimatedAbsenceOrbIcon({
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
                  painter: _AbsenceAtomOrbitPainter(
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

class _AbsenceAtomOrbitPainter extends CustomPainter {
  final double progress;
  final Color primaryColor;
  final Color secondaryColor;

  _AbsenceAtomOrbitPainter({
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
  bool shouldRepaint(covariant _AbsenceAtomOrbitPainter oldDelegate) =>
      oldDelegate.progress != progress;
}
