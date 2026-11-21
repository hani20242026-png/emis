import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'app_core.dart';

class StudentStageTransferScreen extends StatefulWidget {
  final String token;
  final String schoolId;
  final List<dynamic> allStudents;

  const StudentStageTransferScreen({
    super.key,
    required this.token,
    required this.schoolId,
    required this.allStudents,
  });

  @override
  State<StudentStageTransferScreen> createState() =>
      _StudentStageTransferScreenState();
}

class _StudentStageTransferScreenState
    extends State<StudentStageTransferScreen>
    with SingleTickerProviderStateMixin {
  List<Map<String, dynamic>> students = [];
  List<Map<String, dynamic>> stages = [];

  String? fromStage, toStage;
  final Set<int> selected = {};
  bool loading = true, loadingStudents = false, saving = false;
  String? error;

  late final AnimationController _ambientController;

  Map<String, String> get h => {
        'Authorization': widget.token,
        'Accept': 'application/json',
        'Content-Type': 'application/json',
      };

  dynamic _unwrap(dynamic d) =>
      d is Map && d['data'] != null ? d['data'] : d;

  List<Map<String, dynamic>> _maps(dynamic value) {
    final raw = _unwrap(value);
    if (raw is! List) return [];
    return [
      for (final x in raw)
        if (x is Map) Map<String, dynamic>.from(x),
    ];
  }

  Future<dynamic> _get(String endpoint) async {
    final r = await http.get(
      Uri.parse('https://emis.moedu.gov.iq/api$endpoint'),
      headers: h,
    );
    if (r.statusCode < 200 || r.statusCode >= 300) {
      throw Exception(
        'HTTP ${r.statusCode}: ${utf8.decode(r.bodyBytes)}',
      );
    }
    return jsonDecode(utf8.decode(r.bodyBytes));
  }

  Future<List<Map<String, dynamic>>> _list(String endpoint) async =>
      _maps(await _get(endpoint));

  String _id(Map<String, dynamic> x) =>
      '${x['id'] ?? x['value'] ?? x['stageId'] ?? ''}';

  String _label(Map<String, dynamic> x) =>
      '${x['displayName'] ?? x['name'] ?? x['label'] ?? x['text'] ?? x['value'] ?? ''}';

  String _studentName(Map<String, dynamic> s) {
    final direct = s['fullName'] ?? s['studentName'];
    if ('$direct'.trim().isNotEmpty) return '$direct';
    return [
      s['name'],
      s['fatherName'],
      s['grandFatherName'],
      s['surName'],
    ].where((x) => x != null && '$x'.trim().isNotEmpty).join(' ');
  }

  @override
  void initState() {
    super.initState();
    _ambientController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 6),
    )..repeat();
    _load();
  }

  @override
  void dispose() {
    _ambientController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final result = await _list(
        '/selectoption/getAvailableStagesForStudent?schoolId=${widget.schoolId}',
      );
      if (!mounted) return;
      setState(() {
        stages = result;
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

  Future<void> _fromChanged(String? value) async {
    if (value == null) return;
    setState(() {
      fromStage = value;
      selected.clear();
      loadingStudents = true;
      error = null;
    });

    try {
      Map<String, dynamic>? stage;
      for (final item in stages) {
        if (_id(item) == value) {
          stage = item;
          break;
        }
      }
      final stageName = stage == null ? '' : _label(stage);

      final result = await _list(
        '/student/getstudents?page=1&rowsPerPage=3000&sortBy=id'
        '&sortOrder=desc&entityId=${widget.schoolId}',
      );

      final filtered = result.where((student) {
        final sid =
            '${student['stageId'] ?? student['studentStageId'] ?? ''}';
        final name =
            '${student['studentStage'] ?? student['stageName'] ?? student['stage'] ?? ''}';
        return sid == value ||
            (stageName.isNotEmpty && name.trim() == stageName.trim());
      }).toList();

      if (!mounted) return;
      setState(() {
        students = filtered;
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

  Future<Map<String, dynamic>> _fullStudent(dynamic id) async {
    final raw = await _get('/student/getstudent/$id');
    final data = _unwrap(raw);
    if (data is! Map) {
      throw Exception('بيانات الطالب $id غير صالحة');
    }
    return Map<String, dynamic>.from(data);
  }

  Future<void> _run() async {
    if (fromStage == null ||
        toStage == null ||
        fromStage == toStage ||
        selected.isEmpty) {
      return;
    }

    final isDark = AppCore.themeNotifier.value == ThemeMode.dark;
    const goldNeon = Color(0xFFF59E0B);

    final confirmed = await showDialog<bool>(
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
            'ترحيل الطلاب',
            style: TextStyle(
              color: isDark ? Colors.white : const Color(0xFF0F172A),
              fontWeight: FontWeight.w900,
            ),
          ),
          content: Text(
            'سيتم ترحيل ${selected.length} طالب إلى الصف المحدد. متابعة؟',
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
              child: const Text(
                'تنفيذ',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true) return;

    setState(() {
      saving = true;
      error = null;
    });

    // قراءة خيار المعالجة السريعة والطوابير الذكية من الإعدادات
    await AppCore.initPreferences();
    final fastQueueEnabled = AppCore.prefs.getBool('fast_processing_queue_enabled') ?? true;

    int ok = 0, failed = 0;
    String? lastError;

    try {
      for (final id in selected.toList()) {
        try {
          final dto = await _fullStudent(id);

          dto['stageId'] = int.tryParse(toStage!);
          dto['classRoomId'] = null;

          final response = await http.post(
            Uri.parse('https://emis.moedu.gov.iq/api/student/updatestudent'),
            headers: h,
            body: jsonEncode(dto),
          );

          if (response.statusCode >= 200 && response.statusCode < 300) {
            ok++;
          } else {
            failed++;
            lastError =
                'الطالب $id: HTTP ${response.statusCode}: '
                '${utf8.decode(response.bodyBytes)}';
          }

          // إذا كانت المعالجة السريعة مفعلة، نضيف فترة راحة قصيرة لتجنب ضغط السيرفر
          if (fastQueueEnabled) {
            await Future.delayed(const Duration(milliseconds: 120));
          }
        } catch (e) {
          failed++;
          lastError = '$e';
        }
      }

      if (!mounted) return;
      selected.clear();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'تم ترحيل $ok من ${ok + failed} طالب'
            '${lastError == null ? '' : '\nآخر خطأ: $lastError'}',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          backgroundColor:
              failed == 0 ? const Color(0xFF10B981) : const Color(0xFFF97316),
          behavior: SnackBarBehavior.floating,
        ),
      );
      await _fromChanged(fromStage);
    } finally {
      if (mounted) setState(() => saving = false);
    }
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
            gradient: AppCore.isWindows ? null : isDark
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
            color: AppCore.isWindows ? AppCore.windowsGradientFallback(isDark
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
                  )) : null,
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
              _AnimatedTransferOrbIcon(
                icon: Icons.move_up_rounded,
                primaryColor: goldNeon,
                secondaryColor: emeraldNeon,
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
                        color: isDark
                            ? const Color(0xFF6EE7B7)
                            : const Color(0xFF7C3AED),
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'ترحيل الطلاب بين الصفوف',
                      style: TextStyle(
                        color: isDark ? Colors.white : const Color(0xFF0F172A),
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'قراءة مباشرة من EMIS ثم تحديث المرحلة للطلاب المحددين.',
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
                          child: CircularProgressIndicator(color: goldNeon),
                        )
                      : ListView(
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
                          physics: const BouncingScrollPhysics(),
                          children: [
                            _buildTopHeader(dark),
                            const SizedBox(height: 14),
                            Container(
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                gradient: AppCore.isWindows ? null : dark
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
                                color: AppCore.isWindows ? AppCore.windowsGradientFallback(dark
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
                                  color: goldNeon.withOpacity(
                                      dark ? 0.45 : 0.30),
                                  width: 1.3,
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: goldNeon.withOpacity(
                                        dark ? 0.12 : 0.08),
                                    blurRadius: 18,
                                    offset: const Offset(0, 6),
                                  ),
                                ],
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  _drop(
                                      'الصف الحالي',
                                      fromStage,
                                      stages,
                                      _fromChanged,
                                      dark),
                                  const SizedBox(height: 12),
                                  _drop(
                                    'الصف الدراسي المستهدف',
                                    toStage,
                                    stages
                                        .where((x) => _id(x) != fromStage)
                                        .toList(),
                                    (v) => setState(() => toStage = v),
                                    dark,
                                  ),
                                ],
                              ),
                            ),
                            if (error != null) ...[
                              const SizedBox(height: 12),
                              Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFEF4444)
                                      .withOpacity(0.12),
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
                            if (loadingStudents) ...[
                              const SizedBox(height: 32),
                              const Center(
                                child: CircularProgressIndicator(
                                    color: goldNeon),
                              ),
                            ] else if (fromStage != null) ...[
                              const SizedBox(height: 14),
                              _header(dark),
                              const SizedBox(height: 10),
                              ...students.map((s) => _studentTile(s, dark)),
                              if (students.isEmpty) _empty(dark),
                            ],
                          ],
                        ),
                ),
              ],
            ),
            bottomNavigationBar: selected.isEmpty
                ? null
                : SafeArea(
                    minimum: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                    child: SizedBox(
                      height: 58,
                      child: FilledButton.icon(
                        onPressed: saving ||
                                toStage == null ||
                                toStage == fromStage
                            ? null
                            : _run,
                        icon: saving
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(Icons.move_up_rounded),
                        label: Text(
                          'تنفيذ الترحيل (الطلاب المحددون: ${selected.length})',
                          style: const TextStyle(
                            fontWeight: FontWeight.w900,
                            fontSize: 16.5,
                          ),
                        ),
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 15),
                          backgroundColor: goldNeon,
                          foregroundColor: Colors.black,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(18),
                          ),
                          elevation: 6,
                          shadowColor: goldNeon.withOpacity(0.35),
                        ),
                      ),
                    ),
                  ),
          ),
        );
      },
    );
  }

  Widget _drop(
    String label,
    String? value,
    List<Map<String, dynamic>> data,
    ValueChanged<String?> onChanged,
    bool dark,
  ) {
    const goldNeon = Color(0xFFF59E0B);
    final textColor = dark ? Colors.white : const Color(0xFF0F172A);
    final mutedColor = dark ? const Color(0xFF94A3B8) : const Color(0xFF475569);

    return DropdownButtonFormField<String>(
      value: data.any((x) => _id(x) == value) ? value : null,
      isExpanded: true,
      dropdownColor: dark ? const Color(0xFF181D32) : Colors.white,
      iconEnabledColor: goldNeon,
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
        fillColor: dark
            ? const Color(0xFF0B0E1A).withOpacity(0.68)
            : const Color(0xFFF1F5F9),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(
            color: goldNeon.withOpacity(dark ? 0.35 : 0.25),
            width: 1.2,
          ),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(
            color: goldNeon.withOpacity(dark ? 0.35 : 0.25),
            width: 1.2,
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: goldNeon, width: 1.8),
        ),
      ),
      items: data
          .map((x) => DropdownMenuItem(
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
          .where((x) => x.value != null && x.value!.isNotEmpty)
          .toList(),
      onChanged: data.isEmpty ? null : onChanged,
    );
  }

  Widget _header(bool dark) {
    const goldNeon = Color(0xFFF59E0B);
    final textColor = dark ? Colors.white : const Color(0xFF0F172A);
    final mutedColor = dark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        gradient: AppCore.isWindows ? null : dark
            ? LinearGradient(
                colors: [
                  const Color(0xFF141829).withOpacity(0.95),
                  Color.lerp(const Color(0xFF0F1322), goldNeon, 0.08)!,
                ],
              )
            : LinearGradient(
                colors: [
                  Colors.white.withOpacity(0.96),
                  const Color(0xFFF8FAFC).withOpacity(0.92),
                ],
              ),
        color: AppCore.isWindows ? AppCore.windowsGradientFallback(dark
            ? LinearGradient(
                colors: [
                  const Color(0xFF141829).withOpacity(0.95),
                  Color.lerp(const Color(0xFF0F1322), goldNeon, 0.08)!,
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
          color: goldNeon.withOpacity(dark ? 0.40 : 0.28),
          width: 1.2,
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: goldNeon.withOpacity(0.15),
            ),
            child: const Icon(Icons.people_alt_rounded,
                color: goldNeon, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'طلاب الصف الحالي: ${students.length}',
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    fontSize: 14.5,
                    color: textColor,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'يمكن اختيار مجموعة من الطلاب أو اختيارهم جميعاً.',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 11.5,
                    color: mutedColor,
                  ),
                ),
              ],
            ),
          ),
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: goldNeon,
              backgroundColor: goldNeon.withOpacity(0.12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            onPressed: students.isEmpty
                ? null
                : () => setState(() {
                      if (selected.length == students.length) {
                        selected.clear();
                      } else {
                        selected
                          ..clear()
                          ..addAll(students
                              .map((s) => int.tryParse('${s['id']}') ?? -1)
                              .where((id) => id > 0));
                      }
                    }),
            child: Text(
              selected.length == students.length ? 'إلغاء الكل' : 'اختيار الكل',
              style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _studentTile(Map<String, dynamic> s, bool dark) {
    final id = int.tryParse('${s['id']}') ?? -1;
    final checked = selected.contains(id);
    const goldNeon = Color(0xFFF59E0B);
    const blueNeon = Color(0xFF3B82F6);
    final textColor = dark ? Colors.white : const Color(0xFF0F172A);
    final mutedColor = dark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        gradient: AppCore.isWindows ? null : dark
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
        color: AppCore.isWindows ? AppCore.windowsGradientFallback(dark
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
          color: (checked ? goldNeon : blueNeon).withOpacity(dark ? 0.35 : 0.22),
          width: 1.2,
        ),
      ),
      child: CheckboxListTile(
        value: checked,
        activeColor: goldNeon,
        checkColor: Colors.black,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        onChanged: id < 0
            ? null
            : (_) => setState(
                  () => checked ? selected.remove(id) : selected.add(id),
                ),
        title: Text(
          _studentName(s),
          style: TextStyle(
            fontWeight: FontWeight.w900,
            fontSize: 14.5,
            color: textColor,
          ),
        ),
        subtitle: Text(
          'رقم الطالب: ${s['id'] ?? ''}',
          style: TextStyle(
            color: mutedColor,
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
        ),
        controlAffinity: ListTileControlAffinity.leading,
      ),
    );
  }

  Widget _empty(bool dark) => Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: dark ? const Color(0xFF141829) : Colors.white,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: Colors.grey.withOpacity(0.2)),
        ),
        child: Text(
          'لا يوجد طلاب في الصف المحدد.',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontWeight: FontWeight.w800,
            color: dark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
          ),
        ),
      );
}

class _AnimatedTransferOrbIcon extends StatelessWidget {
  final IconData icon;
  final Color primaryColor;
  final Color secondaryColor;
  final Animation<double> animation;
  final double size;

  const _AnimatedTransferOrbIcon({
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
                  painter: _TransferAtomOrbitPainter(
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

class _TransferAtomOrbitPainter extends CustomPainter {
  final double progress;
  final Color primaryColor;
  final Color secondaryColor;

  _TransferAtomOrbitPainter({
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
  bool shouldRepaint(covariant _TransferAtomOrbitPainter oldDelegate) =>
      oldDelegate.progress != progress;
}
