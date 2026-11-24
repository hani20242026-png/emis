import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'student_management_screen.dart';
import 'student_school_card_screen.dart';
import 'teachers_list_screen.dart';
import 'employees_list_screen.dart';
import 'settings_screen.dart';
import 'app_core.dart';
import 'grades_screen.dart';
import 'daily_absence_screen.dart';
import 'add_student_screen.dart';
import 'add_teacher_screen.dart';
import 'transfers_screen.dart';
import 'ai_assistant/ai_assistant_controller.dart';
import 'ai_assistant/ai_command_parser.dart';

typedef JsonMap = Map<String, dynamic>;
typedef StageSubjectsMap = Map<String, List<JsonMap>>;

class DashboardScreen extends StatefulWidget {
  final String token;
  final String schoolId;
  final String schoolName;
  final String userName;
  final String? employeeId;
  final List<dynamic> allStudents;
  final List<dynamic> allTeachers;
  final List<JsonMap> stages;
  final StageSubjectsMap subjectsByStage;
  final StageSubjectsMap examsBySubject;

  const DashboardScreen({
    super.key,
    required this.token,
    required this.schoolId,
    required this.schoolName,
    required this.userName,
    this.employeeId,
    required this.allStudents,
    required this.allTeachers,
    required this.stages,
    required this.subjectsByStage,
    required this.examsBySubject,
  });

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen>
    with TickerProviderStateMixin {
  String _userImageUrl = '';
  late int _studentCount;
  late int _teacherCount;
  late int _employeeCount;
  bool _refreshingCounts = false;
  late final AnimationController _ambientController;
  late final AnimationController _entryController;

  String get _imageCacheStorageKey =>
      'emis_teacher_images_cache_${widget.schoolId}';

  String get _studentCountCacheKey =>
      'emis_student_count_cache_${widget.schoolId}';

  String get _teacherCountCacheKey =>
      'emis_teacher_count_cache_${widget.schoolId}';

  String get _employeeCountCacheKey =>
      'emis_employee_count_cache_${widget.schoolId}';

  Map<String, String> get _headers => {
        'Authorization': widget.token,
        'Accept': 'application/json',
      };

  @override
  void initState() {
    super.initState();
    if (AppCore.kLocalAiBuildEnabled) {
      AppCore.aiAssistantAvailableNotifier.value = true;
      AiAssistantController.instance.dispatcher.onCommand = _handleAiCommand;
    }
    _studentCount = widget.allStudents.whereType>().length;
    _teacherCount = widget.allTeachers.whereType>().length;
    _employeeCount = 0;
    _restoreCachedCounts();
    _refreshDashboardCounts();
    _ambientController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 6),
    )..repeat();

    _entryController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..forward();

    _loadCurrentUserImage();
  }

  Future<void> _restoreCachedCounts() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cachedStudents = prefs.getInt(_studentCountCacheKey);
      final cachedTeachers = prefs.getInt(_teacherCountCacheKey);
      final cachedEmployees = prefs.getInt(_employeeCountCacheKey);
      if (!mounted) return;
      setState(() {
        if (cachedStudents != null && cachedStudents > 0) {
          _studentCount = cachedStudents;
        }
        if (cachedTeachers != null && cachedTeachers > 0) {
          _teacherCount = cachedTeachers;
        }
        if (cachedEmployees != null && cachedEmployees >= 0) {
          _employeeCount = cachedEmployees;
        }
      });
    } catch (_) {}
  }

  dynamic _unwrap(dynamic d) => d is Map && d['data'] != null ? d['data'] : d;

  int _asInt(dynamic value) =>
      value is num ? value.toInt() : int.tryParse('$value') ?? 0;

  /// جلب عدد وقائمة الطلاب بنفس منطق ملف قائمة الطلاب (SelectStudentScreen)
  Future<int?> _fetchStudentCountFromListEndpoint() async {
    try {
      final r = await http
          .get(
            Uri.parse(
              'https://emis.moedu.gov.iq/api/student/getstudents?page=1&rowsPerPage=3000&sortBy=id&sortOrder=desc&entityId=${widget.schoolId}',
            ),
            headers: _headers,
          )
          .timeout(const Duration(seconds: 20));

      if (r.statusCode < 200 || r.statusCode >= 300) return null;

      final data = _unwrap(jsonDecode(utf8.decode(r.bodyBytes)));
      if (data is List) {
        final students = data
            .whereType>()
            .map((e) => JsonMap.from(e))
            .toList();

        try {
          widget.allStudents
            ..clear()
            ..addAll(students);
        } catch (_) {}

        final prefs = await SharedPreferences.getInstance();
        await prefs.setInt(_studentCountCacheKey, students.length);

        return students.length;
      }
    } catch (_) {}
    return null;
  }

  /// جلب عدد وقائمة المعلمين بنفس منطق ملف قائمة المعلمين (TeachersListScreen)
  Future<int?> _fetchTeacherCountFromListEndpoint() async {
    try {
      final uri = Uri.parse(
        'https://emis.moedu.gov.iq/api/employee/getemployeesbyentities'
        '?page=1&rowsPerPage=1000&sortBy=id&sortOrder=desc'
        '&entityId=${Uri.encodeQueryComponent(widget.schoolId)}&isTeacher=true',
      );
      final summaryUri = Uri.parse(
        'https://emis.moedu.gov.iq/api/employee/getemployeessummary'
        '?entityId=${Uri.encodeQueryComponent(widget.schoolId)}&isTeacher=true',
      );

      final results = await Future.wait([
        http.get(uri, headers: _headers).timeout(const Duration(seconds: 20)),
        http
            .get(summaryUri, headers: _headers)
            .timeout(const Duration(seconds: 20)),
      ]);

      final listResponse = results[0];
      final summaryResponse = results[1];

      var teachers = <JsonMap>[];
      if (listResponse.statusCode == 200) {
        final decoded = jsonDecode(utf8.decode(listResponse.bodyBytes));
        final data = decoded is Map ? decoded['data'] : null;
        if (data is List) {
          teachers = data
              .whereType>()
              .map((e) => JsonMap.from(e))
              .toList();

          try {
            widget.allTeachers
              ..clear()
              ..addAll(teachers);
          } catch (_) {}
        }
      }

      int totalActive = 0;
      if (summaryResponse.statusCode == 200) {
        final summary = jsonDecode(utf8.decode(summaryResponse.bodyBytes));
        totalActive = _asInt(summary['totalActive']);
      }

      final count = totalActive == 0 ? teachers.length : totalActive;

      if (listResponse.statusCode == 200 || summaryResponse.statusCode == 200) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setInt(_teacherCountCacheKey, count);
        return count;
      }
    } catch (_) {}
    return null;
  }

  /// جلب العدد من نفس واجهة قائمة الموظفين مع isTeacher=false.
  Future<int?> _fetchEmployeeCountFromListEndpoint() async {
    try {
      final uri = Uri.parse(
        'https://emis.moedu.gov.iq/api/employee/getemployeesbyentities'
        '?page=1&rowsPerPage=1000&sortBy=id&sortOrder=desc'
        '&entityId=${Uri.encodeQueryComponent(widget.schoolId)}&isTeacher=false',
      );
      final summaryUri = Uri.parse(
        'https://emis.moedu.gov.iq/api/employee/getemployeessummary'
        '?entityId=${Uri.encodeQueryComponent(widget.schoolId)}&isTeacher=false',
      );
      final results = await Future.wait([
        http.get(uri, headers: _headers).timeout(const Duration(seconds: 20)),
        http.get(summaryUri, headers: _headers).timeout(const Duration(seconds: 20)),
      ]);
      final listResponse = results[0];
      final summaryResponse = results[1];
      var employees = <JsonMap>[];
      if (listResponse.statusCode == 200) {
        final decoded = jsonDecode(utf8.decode(listResponse.bodyBytes));
        final data = decoded is Map ? decoded['data'] : null;
        if (data is List) {
          employees = data.whereType>().map((e) => JsonMap.from(e)).toList();
        }
      }
      int count = employees.length;
      if (summaryResponse.statusCode == 200) {
        final summary = jsonDecode(utf8.decode(summaryResponse.bodyBytes));
        final candidates = [
          summary is Map ? summary['total'] : null,
          summary is Map ? summary['totalEmployees'] : null,
          summary is Map ? summary['totalCount'] : null,
          summary is Map ? summary['totalActive'] : null,
        ];
        for (final value in candidates) {
          final parsed = _asInt(value);
          if (parsed > 0) { count = parsed; break; }
        }
      }
      if (listResponse.statusCode == 200 || summaryResponse.statusCode == 200) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setInt(_employeeCountCacheKey, count);
        return count;
      }
    } catch (_) {}
    return null;
  }

  Future<void> _refreshDashboardCounts() async {
    await _restoreCachedCounts();

    if (_refreshingCounts) return;
    _refreshingCounts = true;
    try {
      final results = await Future.wait<int?>([
        _fetchStudentCountFromListEndpoint(),
        _fetchTeacherCountFromListEndpoint(),
        _fetchEmployeeCountFromListEndpoint(),
      ]);

      if (!mounted) return;
      setState(() {
        if (results[0] != null) _studentCount = results[0]!;
        if (results[1] != null) _teacherCount = results[1]!;
        if (results[2] != null) _employeeCount = results[2]!;
      });
    } catch (_) {
    } finally {
      _refreshingCounts = false;
    }
  }

  Future<String> _handleAiCommand(AiCommand command) async {
    WidgetBuilder? page;
    switch (command.intent) {
      case AiIntent.addStudent:
        final draftCallback =
            AiAssistantController.instance.onStudentDraftUpdated;
        if (draftCallback != null) {
          return 'أضفت المعلومات الجديدة إلى مسودة الطالب. يمكنك متابعة الكلام، ولن أحفظ قبل موافقتك.';
        }
        AppCore.aiAssistantAvailableNotifier.value = true;
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => AddStudentScreen(
              token: widget.token,
              schoolId: widget.schoolId,
              initialAiValues: command.entities,
            ),
          ),
        ).then((_) => _refreshDashboardCounts());
        return 'فتحت استمارة إضافة الطالب وبدأت تعبئة المعلومات التي التقطتها. أكمل بقية البيانات صوتياً؛ لن يتم الحفظ دون موافقتك.';
      case AiIntent.openStudents:
        page = (_) => StudentManagementScreen(
              token: widget.token,
              schoolId: widget.schoolId,
              allStudents: widget.allStudents,
            );
        break;
      case AiIntent.addTeacher:
        if (AiAssistantController.instance.onTeacherDraftUpdated != null) {
          return 'أضفت المعلومات الجديدة إلى مسودة المعلم. يمكنك متابعة الكلام؛ لن يتم الحفظ دون موافقتك.';
        }
        AppCore.aiAssistantAvailableNotifier.value = true;
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => AddTeacherScreen(
              token: widget.token,
              schoolId: widget.schoolId,
              initialAiValues: command.entities,
            ),
          ),
        ).then((_) => _refreshDashboardCounts());
        return 'فتحت استمارة إضافة المعلم وبدأت تعبئة المعلومات التي التقطتها. أكمل بقية البيانات؛ لن يتم الحفظ دون موافقتك.';
      case AiIntent.openTeachers:
        page = (_) => TeachersListScreen(
              token: widget.token,
              schoolId: widget.schoolId,
              initialTeachers: widget.allTeachers,
            );
        break;
      case AiIntent.openAttendance:
        page = (_) => DailyAbsenceScreen(
              token: widget.token,
              schoolId: widget.schoolId,
              teachingAssignments: const [],
            );
        break;
      case AiIntent.openGrades:
        page = (_) => GradesScreen(
              token: widget.token,
              schoolId: widget.schoolId,
              stages: widget.stages,
              subjectsByStage: widget.subjectsByStage,
              examsBySubject: widget.examsBySubject,
            );
        break;
      case AiIntent.unknown:
        return 'لم أفهم الأمر. يمكنك طلب فتح الطلاب أو المعلمين أو الغيابات أو الدرجات.';
    }
    final routeBuilder = page;
    if (routeBuilder == null) return 'تعذر تحديد القسم المطلوب.';
    if (AppCore.kLocalAiBuildEnabled) {
      AppCore.aiAssistantAvailableNotifier.value = false;
    }
    Navigator.push(context, MaterialPageRoute(builder: routeBuilder)).then((_) {
      if (mounted) {
        if (AppCore.kLocalAiBuildEnabled) {
          AppCore.aiAssistantAvailableNotifier.value = true;
        }
        _refreshDashboardCounts();
      }
    });
    switch (command.intent) {
      case AiIntent.addStudent:
        return 'فتحت إدارة الطلاب. اختر إضافة طالب لإدخال بياناته ومراجعتها قبل الحفظ.';
      case AiIntent.addTeacher:
        return 'فتحت إدارة المعلمين. اختر إضافة معلم لإدخال بياناته ومراجعتها قبل الحفظ.';
      case AiIntent.openStudents:
        return 'تم فتح إدارة الطلاب.';
      case AiIntent.openTeachers:
        return 'تم فتح إدارة المعلمين.';
      case AiIntent.openAttendance:
        return 'تم فتح تسجيل الغيابات.';
      case AiIntent.openGrades:
        return 'تم فتح قسم الدرجات.';
      case AiIntent.unknown:
        return 'لم يتم تنفيذ الأمر.';
    }
  }

  @override
  void dispose() {
    if (AppCore.kLocalAiBuildEnabled) {
      AppCore.aiAssistantAvailableNotifier.value = false;
      AiAssistantController.instance.dispatcher.onCommand = null;
    }
    _ambientController.dispose();
    _entryController.dispose();
    super.dispose();
  }

  String _normalizeArabicName(String text) {
    return text
        .replaceAll(RegExp(r'[ًٌٍَُِّْـ]'), '')
        .replaceAll('أ', 'ا')
        .replaceAll('إ', 'ا')
        .replaceAll('آ', 'ا')
        .replaceAll('ة', 'ه')
        .replaceAll('ى', 'ي')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  String _formatFullImageUrl(String raw) {
    String clean = raw.trim();
    if (clean.isEmpty || clean == '-' || clean == 'null') return '';
    if (!clean.startsWith('http')) {
      if (!clean.startsWith('/')) clean = '/$clean';
      return 'https://emis.moedu.gov.iq$clean';
    }
    return clean;
  }

  Future<void> _loadCurrentUserImage() async {
    try {
      JsonMap? matchedTeacher;

      if (widget.employeeId != null && widget.employeeId!.isNotEmpty) {
        for (final item in widget.allTeachers) {
          if (item is! Map) continue;
          final map = JsonMap.from(item);
          final itemId = '${map['id'] ?? ''}'.trim();
          if (itemId == widget.employeeId) {
            matchedTeacher = map;
            break;
          }
        }
      }

      if (matchedTeacher == null) {
        final targetName = _normalizeArabicName(widget.userName);
        if (targetName.isNotEmpty) {
          for (final item in widget.allTeachers) {
            if (item is! Map) continue;
            final map = JsonMap.from(item);
            final fullName = _normalizeArabicName(
              '${map['employeeFullName'] ?? map['fullName'] ?? map['name'] ?? ''}',
            );
            if (fullName.isEmpty) continue;

            if (fullName == targetName ||
                fullName.contains(targetName) ||
                targetName.contains(fullName)) {
              matchedTeacher = map;
              break;
            }
          }
        }
      }

      if (matchedTeacher == null) return;

      final directImg =
          '${matchedTeacher['imageUrl'] ?? matchedTeacher['ImageUrl'] ?? ''}'
              .trim();
      if (directImg.isNotEmpty && directImg != 'null' && directImg != '-') {
        if (mounted) {
          setState(() => _userImageUrl = _formatFullImageUrl(directImg));
        }
        return;
      }

      final teacherId = '${matchedTeacher['id'] ?? ''}'.trim();
      if (teacherId.isEmpty) return;

      final prefs = await SharedPreferences.getInstance();
      final rawCache = prefs.getString(_imageCacheStorageKey);
      var cacheMap = <String, dynamic>{};
      if (rawCache != null && rawCache.isNotEmpty) {
        final decoded = jsonDecode(rawCache);
        if (decoded is Map) {
          cacheMap = JsonMap.from(decoded);
        }
      }

      final cachedImg = '${cacheMap[teacherId] ?? ''}'.trim();
      if (cachedImg.isNotEmpty && cachedImg != '-' && cachedImg != 'null') {
        if (mounted) {
          setState(() => _userImageUrl = _formatFullImageUrl(cachedImg));
        }
        return;
      }

      final response = await http
          .get(
            Uri.parse(
              'https://emis.moedu.gov.iq/api/employee/getemployee/$teacherId',
            ),
            headers: _headers,
          )
          .timeout(const Duration(seconds: 12));

      if (response.statusCode == 200) {
        final decoded = jsonDecode(utf8.decode(response.bodyBytes));
        final data = decoded is Map && decoded['data'] != null
            ? decoded['data']
            : decoded;
        if (data is Map) {
          final serverImg =
              '${data['imageUrl'] ?? data['ImageUrl'] ?? ''}'.trim();
          if (serverImg.isNotEmpty && serverImg != 'null') {
            cacheMap[teacherId] = serverImg;
            await prefs.setString(_imageCacheStorageKey, jsonEncode(cacheMap));
            if (mounted) {
              setState(() => _userImageUrl = _formatFullImageUrl(serverImg));
            }
          }
        }
      }
    } catch (_) {}
  }

  void _previewUserImage() {
    if (_userImageUrl.isEmpty) return;
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(22),
              child: Container(
                color: Colors.white,
                constraints:
                    const BoxConstraints(maxHeight: 380, maxWidth: 320),
                child: InteractiveViewer(
                  child: Image.network(
                    _userImageUrl,
                    headers: {'Authorization': widget.token},
                    fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) => const Padding(
                      padding: EdgeInsets.all(40),
                      child: Icon(
                        Icons.broken_image,
                        size: 60,
                        color: Colors.grey,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFF0B0F1A).withOpacity(0.9),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: const Color(0xFF10B981).withOpacity(0.4),
                ),
              ),
              child: Text(
                widget.userName,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: AppCore.themeNotifier,
      builder: (context, currentMode, child) {
        final isDark = currentMode == ThemeMode.dark;

        const emeraldNeon = Color(0xFF10B981);
        const goldNeon = Color(0xFFF59E0B);
        const purpleNeon = Color(0xFFA855F7);
        const blueNeon = Color(0xFF3B82F6);
        const orangeNeon = Color(0xFFF97316);

        return Directionality(
          textDirection: TextDirection.rtl,
          child: Scaffold(
            backgroundColor:
                isDark ? const Color(0xFF070913) : const Color(0xFFF2F5FA),
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
                            top: -60 + shift,
                            right: -50,
                            child: _buildAmbientGlow(
                              color: isDark
                                  ? emeraldNeon.withOpacity(0.18)
                                  : purpleNeon.withOpacity(0.12),
                              size: 260,
                            ),
                          ),
                          Positioned(
                            top: 220 - shift,
                            left: -70,
                            child: _buildAmbientGlow(
                              color: isDark
                                  ? purpleNeon.withOpacity(0.16)
                                  : blueNeon.withOpacity(0.10),
                              size: 280,
                            ),
                          ),
                          Positioned(
                            bottom: -80 + shift,
                            right: 20,
                            child: _buildAmbientGlow(
                              color: isDark
                                  ? goldNeon.withOpacity(0.12)
                                  : emeraldNeon.withOpacity(0.10),
                              size: 240,
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
                SafeArea(
                  bottom: false,
                  child: RefreshIndicator(
                    onRefresh: _refreshDashboardCounts,
                    child: SingleChildScrollView(
                      physics: const AlwaysScrollableScrollPhysics(
                        parent: BouncingScrollPhysics(),
                      ),
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 30),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _buildModel1Header(
                            isDark: isDark,
                            userName: widget.userName,
                            schoolName: widget.schoolName,
                            onSettings: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => SettingsScreen(
                                  token: widget.token,
                                  schoolId: widget.schoolId,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 16),
                          _buildAnimatedWaveStatBar(
                            isDark: isDark,
                            title: 'إجمالي الطلاب',
                            count: _studentCount.toString(),
                            icon: Icons.groups_rounded,
                            accentColor: isDark ? emeraldNeon : blueNeon,
                            waveColor: emeraldNeon,
                            isReversed: false,
                            withBars: true,
                          ),
                          const SizedBox(height: 12),
                          _buildTeacherEmployeeCombinedBar(isDark),
                          const SizedBox(height: 20),
                          LayoutBuilder(
                            builder: (context, constraints) {
                              const gap = 14.0;
                              final cardWidth =
                                  (constraints.maxWidth - gap) / 2;
                              final cardHeight =
                                  (cardWidth * 1.05).clamp(170.0, 205.0);

                              return Wrap(
                                spacing: gap,
                                runSpacing: gap,
                                children: [
                                  SizedBox(
                                    width: cardWidth,
                                    height: cardHeight,
                                    child: _AnimatedServiceCard(
                                      title: 'إدارة المعلمين',
                                      icon: Icons.workspace_premium_rounded,
                                      accentColor: purpleNeon,
                                      secondaryColor: goldNeon,
                                      isDark: isDark,
                                      animation: _ambientController,
                                      effectType: _IconEffectType.pulsingMedal,
                                      onTap: () => Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                          builder: (_) => TeachersListScreen(
                                            token: widget.token,
                                            schoolId: widget.schoolId,
                                            initialTeachers: widget.allTeachers,
                                          ),
                                        ),
                                      ).then((_) {
                                        _loadCurrentUserImage();
                                        _refreshDashboardCounts();
                                      }),
                                    ),
                                  ),
                                  SizedBox(
                                    width: cardWidth,
                                    height: cardHeight,
                                    child: _AnimatedServiceCard(
                                      title: 'إدارة الموظفين',
                                      icon: Icons.badge_rounded,
                                      accentColor: emeraldNeon,
                                      secondaryColor: const Color(0xFF14B8A6),
                                      isDark: isDark,
                                      animation: _ambientController,
                                      effectType: _IconEffectType.pulsingMedal,
                                      onTap: () => Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                          builder: (_) => EmployeesListScreen(
                                            token: widget.token,
                                            schoolId: widget.schoolId,
                                            initialEmployees: const <dynamic>[],
                                          ),
                                        ),
                                      ).then((_) {
                                        _loadCurrentUserImage();
                                        _refreshDashboardCounts();
                                      }),
                                    ),
                                  ),
                                  SizedBox(
                                    width: cardWidth,
                                    height: cardHeight,
                                    child: _AnimatedServiceCard(
                                      title: 'إدارة الطلاب',
                                      icon: Icons.school_rounded,
                                      accentColor: blueNeon,
                                      secondaryColor: const Color(0xFF06B6D4),
                                      isDark: isDark,
                                      animation: _ambientController,
                                      effectType: _IconEffectType.orbitalSwirl,
                                      onTap: () => Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                          builder: (_) =>
                                              StudentManagementScreen(
                                            token: widget.token,
                                            schoolId: widget.schoolId,
                                            allStudents: widget.allStudents,
                                          ),
                                        ),
                                      ).then((_) {
                                        _refreshDashboardCounts();
                                      }),
                                    ),
                                  ),
                                  SizedBox(
                                    width: cardWidth,
                                    height: cardHeight,
                                    child: _AnimatedServiceCard(
                                      title: 'البطاقة المدرسية',
                                      icon: Icons.badge_rounded,
                                      accentColor: purpleNeon,
                                      secondaryColor: const Color(0xFFA78BFA),
                                      isDark: isDark,
                                      animation: _ambientController,
                                      effectType: _IconEffectType.pulsingMedal,
                                      onTap: () => Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                          builder: (_) =>
                                              StudentSchoolCardScreen(
                                            token: widget.token,
                                            schoolId: widget.schoolId,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                  SizedBox(
                                    width: cardWidth,
                                    height: cardHeight,
                                    child: _AnimatedServiceCard(
                                      title: 'تسجيل الغيابات',
                                      icon: Icons.event_note_rounded,
                                      accentColor: orangeNeon,
                                      secondaryColor: goldNeon,
                                      isDark: isDark,
                                      animation: _ambientController,
                                      effectType: _IconEffectType.atomicOrbits,
                                      onTap: () => Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                          builder: (_) => DailyAbsenceScreen(
                                            token: widget.token,
                                            schoolId: widget.schoolId,
                                            teachingAssignments: const [],
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                  SizedBox(
                                    width: cardWidth,
                                    height: cardHeight,
                                    child: _AnimatedServiceCard(
                                      title: 'الدرجات',
                                      icon: Icons.assignment_turned_in_rounded,
                                      accentColor: emeraldNeon,
                                      secondaryColor: const Color(0xFF34D399),
                                      isDark: isDark,
                                      animation: _ambientController,
                                      effectType: _IconEffectType.sonarWaves,
                                      onTap: () => Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                          builder: (_) => GradesScreen(
                                            token: widget.token,
                                            schoolId: widget.schoolId,
                                            stages: widget.stages,
                                            subjectsByStage:
                                                widget.subjectsByStage,
                                            examsBySubject:
                                                widget.examsBySubject,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                  SizedBox(
                                    width: cardWidth,
                                    height: cardHeight,
                                    child: _AnimatedServiceCard(
                                      title: 'الانتقالات',
                                      icon: Icons.swap_horiz_rounded,
                                      accentColor: goldNeon,
                                      secondaryColor: blueNeon,
                                      isDark: isDark,
                                      animation: _ambientController,
                                      effectType: _IconEffectType.orbitalSwirl,
                                      onTap: () => Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                          builder: (_) => TransfersScreen(
                                            token: widget.token,
                                            schoolId: widget.schoolId,
                                          ),
                                        ),
                                      ).then((_) {
                                        _refreshDashboardCounts();
                                      }),
                                    ),
                                  ),
                                ],
                              );
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildAmbientGlow({required Color color, required double size}) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: AppCore.isWindows
            ? null
            : RadialGradient(
                colors: [color, color.withOpacity(0.0)],
              ),
        color: AppCore.isWindows
            ? AppCore.windowsGradientFallback(RadialGradient(
                colors: [color, color.withOpacity(0.0)],
              ))
            : null,
      ),
    );
  }

  Widget _buildModel1Header({
    required bool isDark,
    required String userName,
    required String schoolName,
    required VoidCallback onSettings,
  }) {
    final borderGlow = isDark
        ? const Color(0xFF10B981).withOpacity(0.45)
        : const Color(0xFFA855F7).withOpacity(0.28);

    return AnimatedBuilder(
      animation: _ambientController,
      builder: (context, child) {
        final glowPulse =
            0.5 + 0.5 * math.sin(_ambientController.value * 2 * math.pi);

        return Container(
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 18),
          decoration: BoxDecoration(
            gradient: AppCore.isWindows
                ? null
                : isDark
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
            color: AppCore.isWindows
                ? AppCore.windowsGradientFallback(isDark
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
                      ))
                : null,
            borderRadius: BorderRadius.circular(28),
            border: Border.all(
              color: borderGlow,
              width: 1.5,
            ),
            boxShadow: [
              BoxShadow(
                color: isDark
                    ? const Color(0xFF10B981)
                        .withOpacity(0.12 + glowPulse * 0.08)
                    : const Color(0xFF8B5CF6).withOpacity(0.12),
                blurRadius: 24,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Row(
            children: [
              GestureDetector(
                onTap: _userImageUrl.isNotEmpty ? _previewUserImage : null,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Container(
                      width: 78,
                      height: 78,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: (isDark
                                    ? const Color(0xFF10B981)
                                    : const Color(0xFFA855F7))
                                .withOpacity(0.35 + glowPulse * 0.25),
                            blurRadius: 18,
                            spreadRadius: 2,
                          ),
                        ],
                      ),
                    ),
                    Container(
                      width: 74,
                      height: 74,
                      padding: const EdgeInsets.all(3),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: AppCore.isWindows
                            ? null
                            : LinearGradient(
                                colors: isDark
                                    ? [
                                        const Color(0xFF10B981),
                                        const Color(0xFF06B6D4),
                                        const Color(0xFFA855F7),
                                      ]
                                    : [
                                        const Color(0xFFA855F7),
                                        const Color(0xFF6366F1),
                                        const Color(0xFF3B82F6),
                                      ],
                              ),
                        color: AppCore.isWindows
                            ? AppCore.windowsGradientFallback(LinearGradient(
                                colors: isDark
                                    ? [
                                        const Color(0xFF10B981),
                                        const Color(0xFF06B6D4),
                                        const Color(0xFFA855F7),
                                      ]
                                    : [
                                        const Color(0xFFA855F7),
                                        const Color(0xFF6366F1),
                                        const Color(0xFF3B82F6),
                                      ],
                              ))
                            : null,
                      ),
                      child: ClipOval(
                        child: Container(
                          color: isDark
                              ? const Color(0xFF0F172A)
                              : const Color(0xFFEEF2FF),
                          child: _userImageUrl.isNotEmpty
                              ? Image.network(
                                  _userImageUrl,
                                  headers: {'Authorization': widget.token},
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, __, ___) => Icon(
                                    Icons.person_rounded,
                                    color: isDark
                                        ? const Color(0xFF6EE7B7)
                                        : const Color(0xFF7C3AED),
                                    size: 38,
                                  ),
                                )
                              : Icon(
                                  Icons.person_rounded,
                                  color: isDark
                                      ? const Color(0xFF6EE7B7)
                                      : const Color(0xFF7C3AED),
                                  size: 38,
                                ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'مرحباً أستاذ،',
                      style: TextStyle(
                        color: isDark
                            ? const Color(0xFF94A3B8)
                            : const Color(0xFF64748B),
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      userName,
                      maxLines: 3,
                      overflow: TextOverflow.visible,
                      softWrap: true,
                      style: TextStyle(
                        color: isDark ? Colors.white : const Color(0xFF0F172A),
                        fontSize: 17.5,
                        height: 1.25,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: isDark
                            ? Colors.white.withOpacity(0.08)
                            : const Color(0xFF6366F1).withOpacity(0.10),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: isDark
                              ? Colors.white.withOpacity(0.16)
                              : const Color(0xFF6366F1).withOpacity(0.25),
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.school_rounded,
                            color: isDark
                                ? const Color(0xFF34D399)
                                : const Color(0xFF4F46E5),
                            size: 15,
                          ),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              schoolName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: isDark
                                    ? const Color(0xFFE2E8F0)
                                    : const Color(0xFF334155),
                                fontSize: 11.5,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              GestureDetector(
                onTap: onSettings,
                child: Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: AppCore.isWindows
                        ? null
                        : LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: isDark
                                ? [
                                    const Color(0xFF3B3024),
                                    const Color(0xFF221D1A),
                                  ]
                                : [
                                    const Color(0xFFFEF3C7),
                                    const Color(0xFFFDE68A),
                                  ],
                          ),
                    color: AppCore.isWindows
                        ? AppCore.windowsGradientFallback(LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: isDark
                                ? [
                                    const Color(0xFF3B3024),
                                    const Color(0xFF221D1A),
                                  ]
                                : [
                                    const Color(0xFFFEF3C7),
                                    const Color(0xFFFDE68A),
                                  ],
                          ))
                        : null,
                    border: Border.all(
                      color: const Color(0xFFF59E0B).withOpacity(0.6),
                      width: 1.3,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFFF59E0B).withOpacity(0.2),
                        blurRadius: 12,
                      ),
                    ],
                  ),
                  child: Transform.rotate(
                    angle: _ambientController.value * 0.5 * math.pi,
                    child: const Icon(
                      Icons.settings_rounded,
                      size: 23,
                      color: Color(0xFFF59E0B),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildTeacherEmployeeCombinedBar(bool isDark) {
    Widget item({
      required String title,
      required String count,
      required IconData icon,
      required Color color,
    }) {
      return Expanded(
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: color.withOpacity(0.14),
                border: Border.all(color: color.withOpacity(0.45), width: 1.3),
              ),
              child: Icon(icon, color: color, size: 21),
            ),
            const SizedBox(width: 9),
            Flexible(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    count,
                    style: TextStyle(
                      color: isDark ? Colors.white : const Color(0xFF0F172A),
                      fontSize: 23,
                      height: 1.05,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: isDark
                          ? const Color(0xFF94A3B8)
                          : const Color(0xFF64748B),
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
      decoration: BoxDecoration(
        gradient: AppCore.isWindows
            ? null
            : isDark
                ? LinearGradient(colors: [
                    const Color(0xFF121829).withOpacity(0.92),
                    const Color(0xFF1A1F35).withOpacity(0.88),
                  ])
                : LinearGradient(colors: [
                    Colors.white.withOpacity(0.95),
                    const Color(0xFFF8FAFC).withOpacity(0.90),
                  ]),
        color: AppCore.isWindows
            ? AppCore.windowsGradientFallback(isDark
                ? LinearGradient(colors: [
                    const Color(0xFF121829).withOpacity(0.92),
                    const Color(0xFF1A1F35).withOpacity(0.88),
                  ])
                : LinearGradient(colors: [
                    Colors.white.withOpacity(0.95),
                    const Color(0xFFF8FAFC).withOpacity(0.90),
                  ]))
            : null,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
            color: const Color(0xFFF59E0B).withOpacity(0.30), width: 1.2),
        boxShadow: [
          BoxShadow(
              color: const Color(0xFFF59E0B).withOpacity(isDark ? 0.08 : 0.06),
              blurRadius: 18,
              offset: const Offset(0, 6)),
        ],
      ),
      child: Row(
        children: [
          item(
              title: 'إجمالي المعلمين',
              count: _teacherCount.toString(),
              icon: Icons.badge_rounded,
              color: const Color(0xFFF59E0B)),
          Container(
              width: 1,
              height: 48,
              margin: const EdgeInsets.symmetric(horizontal: 8),
              color: isDark ? Colors.white12 : Colors.black12),
          item(
              title: 'إجمالي الموظفين',
              count: _employeeCount.toString(),
              icon: Icons.groups_2_rounded,
              color: const Color(0xFF10B981)),
        ],
      ),
    );
  }

  Widget _buildAnimatedWaveStatBar({
    required bool isDark,
    required String title,
    required String count,
    required IconData icon,
    required Color accentColor,
    required Color waveColor,
    required bool isReversed,
    required bool withBars,
  }) {
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final mutedColor =
        isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);

    final statInfoWidget = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: accentColor.withOpacity(0.15),
            border: Border.all(
              color: accentColor.withOpacity(0.5),
              width: 1.5,
            ),
            boxShadow: [
              BoxShadow(
                color: accentColor.withOpacity(isDark ? 0.3 : 0.15),
                blurRadius: 14,
              ),
            ],
          ),
          child: Icon(icon, color: accentColor, size: 24),
        ),
        const SizedBox(width: 12),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              count,
              style: TextStyle(
                color: textColor,
                fontSize: 25,
                height: 1.05,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              title,
              style: TextStyle(
                color: mutedColor,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ],
    );

    final sparklineWidget = Expanded(
      child: SizedBox(
        height: 44,
        child: AnimatedBuilder(
          animation: _ambientController,
          builder: (context, _) {
            return CustomPaint(
              painter: _SparklineWavePainter(
                phase: _ambientController.value * 2 * math.pi,
                color: waveColor,
                isDark: isDark,
                withBars: withBars,
              ),
            );
          },
        ),
      ),
    );

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        gradient: AppCore.isWindows
            ? null
            : isDark
                ? LinearGradient(
                    colors: [
                      const Color(0xFF121829).withOpacity(0.92),
                      const Color(0xFF1A1F35).withOpacity(0.88),
                    ],
                  )
                : LinearGradient(
                    colors: [
                      Colors.white.withOpacity(0.95),
                      const Color(0xFFF8FAFC).withOpacity(0.90),
                    ],
                  ),
        color: AppCore.isWindows
            ? AppCore.windowsGradientFallback(isDark
                ? LinearGradient(
                    colors: [
                      const Color(0xFF121829).withOpacity(0.92),
                      const Color(0xFF1A1F35).withOpacity(0.88),
                    ],
                  )
                : LinearGradient(
                    colors: [
                      Colors.white.withOpacity(0.95),
                      const Color(0xFFF8FAFC).withOpacity(0.90),
                    ],
                  ))
            : null,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: waveColor.withOpacity(isDark ? 0.40 : 0.30),
          width: 1.2,
        ),
        boxShadow: [
          BoxShadow(
            color: waveColor.withOpacity(isDark ? 0.08 : 0.06),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Row(
        children: isReversed
            ? [
                sparklineWidget,
                const SizedBox(width: 16),
                statInfoWidget,
              ]
            : [
                statInfoWidget,
                const SizedBox(width: 16),
                sparklineWidget,
              ],
      ),
    );
  }
}

enum _IconEffectType {
  pulsingMedal,
  orbitalSwirl,
  atomicOrbits,
  sonarWaves,
}

class _AnimatedServiceCard extends StatefulWidget {
  final String title;
  final IconData icon;
  final Color accentColor;
  final Color secondaryColor;
  final bool isDark;
  final Animation<double> animation;
  final _IconEffectType effectType;
  final VoidCallback onTap;

  const _AnimatedServiceCard({
    required this.title,
    required this.icon,
    required this.accentColor,
    required this.secondaryColor,
    required this.isDark,
    required this.animation,
    required this.effectType,
    required this.onTap,
  });

  @override
  State<_AnimatedServiceCard> createState() => _AnimatedServiceCardState();
}

class _AnimatedServiceCardState extends State<_AnimatedServiceCard> {
  bool _isPressed = false;

  @override
  Widget build(BuildContext context) {
    final textColor = widget.isDark ? Colors.white : const Color(0xFF0F172A);

    return GestureDetector(
      onTapDown: (_) => setState(() => _isPressed = true),
      onTapUp: (_) {
        setState(() => _isPressed = false);
        widget.onTap();
      },
      onTapCancel: () => setState(() => _isPressed = false),
      child: AnimatedScale(
        scale: _isPressed ? 0.95 : 1.0,
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOutCubic,
        child: AnimatedBuilder(
          animation: widget.animation,
          builder: (context, _) {
            final t = widget.animation.value;
            final floatOffset = math.sin(t * 2 * math.pi) * 4.5;

            return Container(
              decoration: BoxDecoration(
                gradient: AppCore.isWindows
                    ? null
                    : widget.isDark
                        ? LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              const Color(0xFF15192B),
                              Color.lerp(
                                const Color(0xFF101322),
                                widget.accentColor,
                                0.12,
                              )!,
                            ],
                          )
                        : LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              Colors.white,
                              Color.lerp(
                                const Color(0xFFF8FAFC),
                                widget.accentColor,
                                0.06,
                              )!,
                            ],
                          ),
                color: AppCore.isWindows
                    ? AppCore.windowsGradientFallback(widget.isDark
                        ? LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              const Color(0xFF15192B),
                              Color.lerp(
                                const Color(0xFF101322),
                                widget.accentColor,
                                0.12,
                              )!,
                            ],
                          )
                        : LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              Colors.white,
                              Color.lerp(
                                const Color(0xFFF8FAFC),
                                widget.accentColor,
                                0.06,
                              )!,
                            ],
                          ))
                    : null,
                borderRadius: BorderRadius.circular(26),
                border: Border.all(
                  color: widget.accentColor
                      .withOpacity(widget.isDark ? 0.55 : 0.35),
                  width: 1.5,
                ),
                boxShadow: [
                  BoxShadow(
                    color: widget.accentColor
                        .withOpacity(widget.isDark ? 0.18 : 0.12),
                    blurRadius: 20,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(26),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Positioned(
                      top: 18,
                      child: Container(
                        width: 95,
                        height: 95,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: AppCore.isWindows
                              ? null
                              : RadialGradient(
                                  colors: [
                                    widget.accentColor.withOpacity(
                                        widget.isDark ? 0.28 : 0.16),
                                    widget.accentColor.withOpacity(0.0),
                                  ],
                                ),
                          color: AppCore.isWindows
                              ? AppCore.windowsGradientFallback(RadialGradient(
                                  colors: [
                                    widget.accentColor.withOpacity(
                                        widget.isDark ? 0.28 : 0.16),
                                    widget.accentColor.withOpacity(0.0),
                                  ],
                                ))
                              : null,
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 14,
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          SizedBox(
                            width: 100,
                            height: 100,
                            child: Stack(
                              alignment: Alignment.center,
                              children: [
                                Positioned.fill(
                                  child: CustomPaint(
                                    painter: _IconOrbitEffectPainter(
                                      progress: t,
                                      primaryColor: widget.accentColor,
                                      secondaryColor: widget.secondaryColor,
                                      effectType: widget.effectType,
                                      isDark: widget.isDark,
                                    ),
                                  ),
                                ),
                                Transform.translate(
                                  offset: Offset(0, floatOffset),
                                  child: Container(
                                    width: 62,
                                    height: 62,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      gradient: AppCore.isWindows
                                          ? null
                                          : LinearGradient(
                                              begin: Alignment.topLeft,
                                              end: Alignment.bottomRight,
                                              colors: [
                                                widget.accentColor,
                                                Color.lerp(
                                                  widget.accentColor,
                                                  Colors.black,
                                                  0.25,
                                                )!,
                                              ],
                                            ),
                                      color: AppCore.isWindows
                                          ? AppCore.windowsGradientFallback(
                                              LinearGradient(
                                              begin: Alignment.topLeft,
                                              end: Alignment.bottomRight,
                                              colors: [
                                                widget.accentColor,
                                                Color.lerp(
                                                  widget.accentColor,
                                                  Colors.black,
                                                  0.25,
                                                )!,
                                              ],
                                            ))
                                          : null,
                                      border: Border.all(
                                        color: Colors.white.withOpacity(0.45),
                                        width: 1.5,
                                      ),
                                      boxShadow: [
                                        BoxShadow(
                                          color: widget.accentColor
                                              .withOpacity(0.45),
                                          blurRadius: 16,
                                          offset: const Offset(0, 6),
                                        ),
                                      ],
                                    ),
                                    child: Icon(
                                      widget.icon,
                                      size: 32,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 10),
                          Text(
                            widget.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: textColor,
                              fontSize: 16.5,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _SparklineWavePainter extends CustomPainter {
  final double phase;
  final Color color;
  final bool isDark;
  final bool withBars;

  _SparklineWavePainter({
    required this.phase,
    required this.color,
    required this.isDark,
    required this.withBars,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paintLine = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.6
      ..strokeCap = StrokeCap.round;

    final glowPaint = Paint()
      ..color = color.withOpacity(isDark ? 0.45 : 0.25)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6.0
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);

    final path = Path();
    final startX = withBars ? size.width * 0.35 : 0.0;
    final waveWidth = size.width - startX;

    for (double x = startX; x <= size.width; x += 2) {
      final normalized = (x - startX) / waveWidth;
      final y = size.height * 0.55 +
          math.sin(normalized * 3.5 * math.pi + phase) * (size.height * 0.25) +
          math.cos(normalized * 2.0 * math.pi - phase) * (size.height * 0.12);
      if (x == startX) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }

    canvas.drawPath(path, glowPaint);
    canvas.drawPath(path, paintLine);

    if (withBars) {
      final barPaint = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.0
        ..strokeCap = StrokeCap.round;

      const barCount = 5;
      final barSpacing = (size.width * 0.28) / barCount;
      for (int i = 0; i < barCount; i++) {
        final bx = i * barSpacing + 6;
        final factor = 0.35 + 0.45 * math.sin(phase + i * 1.1).abs();
        final barHeight = size.height * factor;
        final topY = (size.height - barHeight) / 2;
        canvas.drawLine(
          Offset(bx, topY),
          Offset(bx, topY + barHeight),
          barPaint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _SparklineWavePainter oldDelegate) =>
      oldDelegate.phase != phase || oldDelegate.isDark != isDark;
}

class _IconOrbitEffectPainter extends CustomPainter {
  final double progress;
  final Color primaryColor;
  final Color secondaryColor;
  final _IconEffectType effectType;
  final bool isDark;

  _IconOrbitEffectPainter({
    required this.progress,
    required this.primaryColor,
    required this.secondaryColor,
    required this.effectType,
    required this.isDark,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final angle = progress * 2 * math.pi;

    switch (effectType) {
      case _IconEffectType.pulsingMedal:
        for (int i = 1; i <= 2; i++) {
          final radius = 34.0 + i * 7.0 + math.sin(angle + i) * 2.5;
          final arcPaint = Paint()
            ..color = primaryColor.withOpacity(0.45 - i * 0.12)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.0
            ..strokeCap = StrokeCap.round;

          canvas.drawArc(
            Rect.fromCircle(center: center, radius: radius),
            -0.6,
            1.2,
            false,
            arcPaint,
          );
          canvas.drawArc(
            Rect.fromCircle(center: center, radius: radius),
            math.pi - 0.6,
            1.2,
            false,
            arcPaint,
          );
        }
        _drawSparkles(canvas, center, angle, secondaryColor);
        break;

      case _IconEffectType.orbitalSwirl:
        canvas.save();
        canvas.translate(center.dx, center.dy);
        canvas.rotate(-0.35);
        final rect = Rect.fromCenter(
          center: Offset.zero,
          width: 88,
          height: 36,
        );
        final orbitPaint = Paint()
          ..color = secondaryColor.withOpacity(0.55)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.0;
        canvas.drawOval(rect, orbitPaint);

        final dotX = 44 * math.cos(angle);
        final dotY = 18 * math.sin(angle);
        canvas.drawCircle(
          Offset(dotX, dotY),
          4.0,
          Paint()..color = secondaryColor,
        );
        canvas.restore();
        _drawSparkles(canvas, center, -angle, primaryColor);
        break;

      case _IconEffectType.atomicOrbits:
        for (final tilt in [0.45, -0.45]) {
          canvas.save();
          canvas.translate(center.dx, center.dy);
          canvas.rotate(tilt);
          final rect = Rect.fromCenter(
            center: Offset.zero,
            width: 86,
            height: 34,
          );
          final orbitPaint = Paint()
            ..color = primaryColor.withOpacity(0.45)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.6;
          canvas.drawOval(rect, orbitPaint);

          final dir = tilt > 0 ? angle : -angle + 1.5;
          final dx = 43 * math.cos(dir);
          final dy = 17 * math.sin(dir);
          canvas.drawCircle(
            Offset(dx, dy),
            3.5,
            Paint()..color = secondaryColor,
          );
          canvas.restore();
        }
        break;

      case _IconEffectType.sonarWaves:
        for (int i = 0; i < 3; i++) {
          final waveProgress = (progress + i / 3) % 1.0;
          final radius = 28.0 + waveProgress * 22.0;
          final opacity = (1.0 - waveProgress).clamp(0.0, 1.0) * 0.6;
          final wavePaint = Paint()
            ..color = primaryColor.withOpacity(opacity)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.0;
          canvas.drawCircle(center, radius, wavePaint);
        }
        _drawSparkles(canvas, center, angle, secondaryColor);
        break;
    }
  }

  void _drawSparkles(
    Canvas canvas,
    Offset center,
    double angle,
    Color color,
  ) {
    final paint = Paint()..color = color.withOpacity(0.85);
    for (int i = 0; i < 4; i++) {
      final a = angle + (i * math.pi / 2);
      final r = 40.0 + math.sin(angle * 2 + i) * 4.0;
      final pos = Offset(
        center.dx + r * math.cos(a),
        center.dy + r * math.sin(a),
      );
      canvas.drawCircle(pos, 2.2, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _IconOrbitEffectPainter oldDelegate) =>
      oldDelegate.progress != progress || oldDelegate.isDark != isDark;
}
