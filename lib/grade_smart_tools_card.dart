import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'app_core.dart';

class GradeSmartToolsCard extends StatefulWidget {
  final String token;
  final String schoolId;
  final List<Map<String, dynamic>> stages;
  final Map<String, List<Map<String, dynamic>>> subjectsByStage;
  final Map<String, List<Map<String, dynamic>>> examsBySubject;

  const GradeSmartToolsCard({
    super.key,
    required this.token,
    required this.schoolId,
    required this.stages,
    required this.subjectsByStage,
    required this.examsBySubject,
  });

  @override
  State<GradeSmartToolsCard> createState() => _GradeSmartToolsCardState();
}

class _GradeSmartToolsCardState extends State<GradeSmartToolsCard>
    with SingleTickerProviderStateMixin {
  late List<Map<String, dynamic>> stages;
  late Map<String, List<Map<String, dynamic>>> subjectsByStage;
  late Map<String, List<Map<String, dynamic>>> examsBySubject;

  final Set<String> selectedTerms = {};
  final Set<String> selectedStages = {};
  final Set<String> selectedSubjects = {};

  bool loadingCatalog = false;
  bool allStagesAndSubjects = false;
  bool running = false;
  String? error;
  String status = 'تم استيراد بيانات الصفوف والمواد والفصول الدراسية مسبقاً.';

  late final AnimationController _ambientController;

  Map<String, String> get _headers => {
        'Authorization': widget.token.toLowerCase().startsWith('bearer ')
            ? widget.token
            : 'Bearer ${widget.token}',
        'Accept': 'application/json',
        'Content-Type': 'application/json',
      };

  dynamic _unwrap(dynamic value) =>
      value is Map && value['data'] != null ? value['data'] : value;

  List<Map<String, dynamic>> _maps(dynamic value) {
    final raw = _unwrap(value);
    if (raw is! List) return [];
    return [
      for (final item in raw)
        if (item is Map) Map<String, dynamic>.from(item),
    ];
  }

  Future<dynamic> _get(String endpoint) async {
    final response = await http.get(
      Uri.parse('https://emis.moedu.gov.iq/api$endpoint'),
      headers: _headers,
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
        'HTTP ${response.statusCode}: ${utf8.decode(response.bodyBytes)}',
      );
    }
    return jsonDecode(utf8.decode(response.bodyBytes));
  }

  String _id(Map<String, dynamic> x) =>
      '${x['value'] ?? x['id'] ?? x['stageId'] ?? ''}';

  String _label(Map<String, dynamic> x) =>
      '${x['displayName'] ?? x['label'] ?? x['name'] ?? x['text'] ?? x['labelAr'] ?? _id(x)}';

  @override
  void initState() {
    super.initState();
    _ambientController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 6),
    )..repeat();

    stages = [
      for (final stage in widget.stages) Map<String, dynamic>.from(stage),
    ];
    subjectsByStage = {
      for (final entry in widget.subjectsByStage.entries)
        entry.key: [for (final item in entry.value) Map<String, dynamic>.from(item)],
    };
    examsBySubject = {
      for (final entry in widget.examsBySubject.entries)
        entry.key: [for (final item in entry.value) Map<String, dynamic>.from(item)],
    };
  }

  @override
  void dispose() {
    _ambientController.dispose();
    super.dispose();
  }

  Future<void> _loadSubjectsForStages(Iterable<String> stageIds) async {
    final ids = stageIds.where((x) => x.isNotEmpty).toSet();
    if (ids.isEmpty) return;
    setState(() { status = 'جاري تحميل مواد الصفوف المختارة فقط...'; });
    for (final stageId in ids) {
      if (subjectsByStage.containsKey(stageId)) continue;
      try {
        final raw = await _get('/subject/getsubjectsselect?stageId=$stageId&schoolId=${widget.schoolId}');
        subjectsByStage[stageId] = _maps(raw);
      } catch (e) {
        error = '$e';
      }
    }
    if (mounted) setState(() { status = 'تم تحميل مواد الصفوف المختارة.'; });
  }

  Future<void> _loadExamsForSubjects(Iterable<String> subjectKeys) async {
    for (final key in subjectKeys.toSet()) {
      if (examsBySubject.containsKey(key)) continue;
      final parts = key.split(':');
      if (parts.length != 2) continue;
      final stageId = parts[0], subjectId = parts[1];
      try {
        final raw = await _get('/examscore/getexamsformarks?schoolId=${widget.schoolId}&stageId=$stageId&subjectId=$subjectId');
        examsBySubject[key] = _maps(raw is Map ? raw['exams'] : raw);
      } catch (e) {
        error = '$e';
      }
    }
    if (mounted) setState(() {});
  }

  List<Map<String, dynamic>> get _selectedStageSubjects {
    final seen = <String>{};
    final result = <Map<String, dynamic>>[];
    for (final stageId in selectedStages) {
      for (final subject in subjectsByStage[stageId] ?? const []) {
        final id = _id(subject);
        if (id.isNotEmpty && seen.add('$stageId:$id')) {
          result.add({...subject, '_stageId': stageId});
        }
      }
    }
    return result;
  }

  List<String> get _termLabels {
    final result = <String>[];
    final seen = <String>{};
    for (final exams in examsBySubject.values) {
      for (final exam in exams) {
        final label = _label(exam).trim();
        if (label.isNotEmpty && seen.add(label)) result.add(label);
      }
    }
    return result;
  }

  Future<void> _setAllStagesAndSubjects(bool enabled) async {
    if (!enabled) {
      setState(() {
        allStagesAndSubjects = false;
        selectedStages.clear();
        selectedSubjects.clear();
        selectedTerms.clear();
      });
      return;
    }
    final ids = stages.map(_id).where((x) => x.isNotEmpty).toSet();
    setState(() { allStagesAndSubjects = true; selectedStages..clear()..addAll(ids); });
    await _loadSubjectsForStages(ids);
    final subjectKeys = <String>{
      for (final entry in subjectsByStage.entries)
        for (final subject in entry.value)
          if (_id(subject).isNotEmpty) '${entry.key}:${_id(subject)}',
    };
    setState(() => selectedSubjects..clear()..addAll(subjectKeys));
    await _loadExamsForSubjects(subjectKeys);
  }

  Future<void> _chooseTerms() async {
    await _multiChoice(
      title: 'اختيار فصل أو عدة فصول من EMIS',
      items: _termLabels,
      selected: selectedTerms,
      allLabel: 'اختيار كل الفصول',
      onApply: (values) => setState(() => selectedTerms
        ..clear()
        ..addAll(values)),
    );
  }

  Future<void> _chooseStages() async {
    final items = [
      for (final stage in stages) _label(stage),
    ];
    final idsByLabel = <String, String>{
      for (final stage in stages) _label(stage): _id(stage),
    };
    final selectedLabels = <String>{
      for (final stage in stages)
        if (selectedStages.contains(_id(stage))) _label(stage),
    };

    await _multiChoice(
      title: 'اختيار الصف الدراسي',
      items: items,
      selected: selectedLabels,
      allLabel: 'اختيار كل الصفوف',
      onApply: (values) async {
        final ids = values.map((x) => idsByLabel[x]).whereType<String>().toSet();
        setState(() {
          selectedStages
            ..clear()
            ..addAll(ids);
          selectedSubjects.removeWhere((key) => !ids.contains(key.split(':').first));
          selectedTerms.removeWhere((term) => !_termLabels.contains(term));
        });
        await _loadSubjectsForStages(ids);
      },
    );
  }

  Future<void> _chooseSubjects() async {
    final entries = _selectedStageSubjects;
    final labels = <String>[];
    final idsByLabel = <String, String>{};
    for (final subject in entries) {
      final stageId = '${subject['_stageId']}';
      final id = _id(subject);
      final label = '${_label(subject)} — ${_stageLabel(stageId)}';
      labels.add(label);
      idsByLabel[label] = '$stageId:$id';
    }
    final selectedLabels = <String>{
      for (final entry in idsByLabel.entries)
        if (selectedSubjects.contains(entry.value)) entry.key,
    };

    await _multiChoice(
      title: 'اختيار مادة دراسية أو عدة مواد',
      items: labels,
      selected: selectedLabels,
      allLabel: 'اختيار كل المواد',
      onApply: (values) async {
        final keys = values.map((x) => idsByLabel[x]).whereType<String>().toSet();
        setState(() {
          selectedSubjects
            ..clear()
            ..addAll(keys);
          selectedTerms.removeWhere((term) => !_termLabels.contains(term));
        });
        await _loadExamsForSubjects(keys);
      },
    );
  }

  String _stageLabel(String id) {
    for (final stage in stages) {
      if (_id(stage) == id) return _label(stage);
    }
    return id;
  }

  Future<void> _multiChoice({
    required String title,
    required List<String> items,
    required Set<String> selected,
    required String allLabel,
    required ValueChanged<Set<String>> onApply,
  }) async {
    final temp = {...selected};
    final isDark = AppCore.themeNotifier.value == ThemeMode.dark;

    final result = await showDialog<Set<String>>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialog) {
            final all = items.isNotEmpty && temp.length == items.length;
            return Directionality(
              textDirection: TextDirection.rtl,
              child: AlertDialog(
                backgroundColor:
                    isDark ? const Color(0xFF141829) : const Color(0xFFFFFFFF),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(24),
                  side: BorderSide(
                    color: const Color(0xFF3B82F6).withOpacity(0.45),
                    width: 1.5,
                  ),
                ),
                title: Text(title,
                    style: TextStyle(
                      color: isDark ? Colors.white : const Color(0xFF0F172A),
                      fontWeight: FontWeight.w900,
                    )),
                content: SizedBox(
                  width: double.maxFinite,
                  height: 420,
                  child: Column(
                    children: [
                      CheckboxListTile(
                        value: all,
                        activeColor: const Color(0xFF3B82F6),
                        title: Text(allLabel,
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: isDark ? Colors.white : const Color(0xFF0F172A),
                            )),
                        onChanged: items.isEmpty
                            ? null
                            : (v) => setDialog(() {
                                  temp.clear();
                                  if (v == true) temp.addAll(items);
                                }),
                      ),
                      const Divider(),
                      Expanded(
                        child: ListView.builder(
                          itemCount: items.length,
                          itemBuilder: (_, index) {
                            final item = items[index];
                            return CheckboxListTile(
                              dense: true,
                              activeColor: const Color(0xFF3B82F6),
                              value: temp.contains(item),
                              title: Text(item,
                                  style: TextStyle(
                                    fontWeight: FontWeight.w800,
                                    color: isDark ? Colors.white : const Color(0xFF0F172A),
                                  )),
                              onChanged: (v) => setDialog(() {
                                if (v == true) {
                                  temp.add(item);
                                } else {
                                  temp.remove(item);
                                }
                              }),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: Text('إلغاء',
                        style: TextStyle(
                          color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                          fontWeight: FontWeight.bold,
                        )),
                  ),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF3B82F6),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    onPressed: () => Navigator.pop(ctx, temp),
                    child: const Text('اعتماد الاختيار',
                        style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
    if (result != null) onApply(result);
  }

  Future<void> _run(bool ignore) async {
    if (selectedTerms.isEmpty || selectedStages.isEmpty || selectedSubjects.isEmpty) {
      _show('اختر الصفوف والمواد والفصول أولاً.', Colors.orange);
      return;
    }

    final selectedSubjectsData = <Map<String, dynamic>>[];
    for (final subject in _selectedStageSubjects) {
      final stageId = '${subject['_stageId']}';
      final subjectId = _id(subject);
      if (selectedSubjects.contains('$stageId:$subjectId')) {
        selectedSubjectsData.add(subject);
      }
    }

    final isDark = AppCore.themeNotifier.value == ThemeMode.dark;

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
              color: const Color(0xFF3B82F6).withOpacity(0.45),
              width: 1.5,
            ),
          ),
          title: Text(ignore ? 'إهمال الامتحان' : 'إلغاء إهمال الامتحان',
              style: TextStyle(
                color: isDark ? Colors.white : const Color(0xFF0F172A),
                fontWeight: FontWeight.w900,
              )),
          content: Text(
            'سيتم ${ignore ? 'إهمال' : 'إلغاء إهمال'} الفصول المحددة '
            'لـ ${selectedSubjectsData.length} اختيار مادة/صف. '
            'سيتم تنفيذ العملية على طلاب الصف للمادة كما يفعل EMIS.',
            style: TextStyle(
              color: isDark ? const Color(0xFFCBD5E1) : const Color(0xFF475569),
              height: 1.45,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text('إلغاء',
                  style: TextStyle(
                    color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                    fontWeight: FontWeight.bold,
                  )),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF3B82F6),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('تنفيذ', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true) return;

    setState(() {
      running = true;
      error = null;
      status = 'جاري تنفيذ العملية على EMIS...';
    });

    int ok = 0;
    int failed = 0;
    final failures = <String>[];

    try {
      for (final subject in selectedSubjectsData) {
        final stageId = '${subject['_stageId']}';
        final subjectId = _id(subject);
        final exams = examsBySubject['$stageId:$subjectId'] ?? [];

        final wantedExams = exams.where((exam) => selectedTerms.contains(_label(exam))).toList();
        if (wantedExams.isEmpty) continue;

        final studentsRaw = await _get(
          '/examscore/getstudentswithgrades?schoolId=${widget.schoolId}'
          '&stageId=$stageId&subjectId=$subjectId',
        );
        final students = _maps(studentsRaw);
        final ids = students
            .map((s) => int.tryParse('${s['id']}'))
            .whereType<int>()
            .toSet()
            .toList();
        if (ids.isEmpty) {
          failures.add('${_stageLabel(stageId)} / ${_label(subject)}: لا يوجد طلاب');
          continue;
        }

        for (final exam in wantedExams) {
          if (ignore && exam['isIgnorable'] == false) {
            failures.add('${_label(exam)}: EMIS يعتبره غير قابل للإهمال');
            continue;
          }
          final endpoint = ignore
              ? '/examscore/ignoreexamgrade'
              : '/examScore/unignoreexamgrade';
          final response = await http.post(
            Uri.parse('https://emis.moedu.gov.iq/api$endpoint'),
            headers: _headers,
            body: jsonEncode({
              'examId': int.tryParse(_id(exam)),
              'studentIds': ids,
            }),
          );
          if (response.statusCode >= 200 && response.statusCode < 300) {
            ok++;
          } else {
            failed++;
            failures.add(
              '${_stageLabel(stageId)} / ${_label(subject)} / ${_label(exam)}: '
              'HTTP ${response.statusCode} ${utf8.decode(response.bodyBytes)}',
            );
          }
        }
      }

      if (!mounted) return;
      setState(() {
        status = 'اكتملت العملية: نجاح $ok — فشل $failed';
      });
      final details = failures.isEmpty ? '' : '\n${failures.first}';
      _show(
        'تم ${ignore ? 'إهمال' : 'إلغاء إهمال'} $ok عملية${failed == 0 ? '' : ' — فشل $failed'}$details',
        failed == 0 ? const Color(0xFF10B981) : const Color(0xFFF97316),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => error = '$e');
      _show('فشلت العملية: $e', const Color(0xFFEF4444));
    } finally {
      if (mounted) setState(() => running = false);
    }
  }

  void _show(String message, Color color) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, style: const TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: color,
        behavior: SnackBarBehavior.floating,
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

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: AppCore.themeNotifier,
      builder: (context, mode, child) {
        final isDark = mode == ThemeMode.dark;
        final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
        final mutedColor = isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);

        const blueNeon = Color(0xFF3B82F6);
        const emeraldNeon = Color(0xFF10B981);
        const purpleNeon = Color(0xFFA855F7);
        const goldNeon = Color(0xFFF59E0B);
        const redNeon = Color(0xFFEF4444);

        return Directionality(
          textDirection: TextDirection.rtl,
          child: Stack(
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
                                ? blueNeon.withOpacity(0.18)
                                : purpleNeon.withOpacity(0.12),
                            size: 250,
                          ),
                        ),
                        Positioned(
                          top: 240 - shift,
                          left: -70,
                          child: _buildAmbientGlow(
                            color: isDark
                                ? purpleNeon.withOpacity(0.15)
                                : goldNeon.withOpacity(0.12),
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
              Card(
                elevation: 0,
                color: isDark ? const Color(0xFF141829).withOpacity(0.95) : Colors.white.withOpacity(0.96),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(26),
                  side: BorderSide(
                    color: blueNeon.withOpacity(isDark ? 0.45 : 0.30),
                    width: 1.4,
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 48,
                            height: 48,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: blueNeon.withOpacity(0.15),
                            ),
                            child: const Icon(Icons.auto_awesome_rounded, color: blueNeon, size: 24),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('الأدوات الذكية للدرجات',
                                    style: TextStyle(
                                      fontSize: 17.5,
                                      fontWeight: FontWeight.w900,
                                      color: textColor,
                                    )),
                                const SizedBox(height: 3),
                                Text('إهمال أو إلغاء إهمال الامتحانات مباشرة وفق بيانات EMIS.',
                                    style: TextStyle(
                                      fontWeight: FontWeight.w600,
                                      fontSize: 12,
                                      color: mutedColor,
                                    )),
                              ],
                            ),
                          ),
                          if (loadingCatalog)
                            const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2, color: blueNeon)),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Text(status, style: TextStyle(fontWeight: FontWeight.w700, color: mutedColor, fontSize: 12)),
                      if (error != null) ...[
                        const SizedBox(height: 8),
                        Text(error!, style: const TextStyle(fontWeight: FontWeight.bold, color: redNeon, fontSize: 12)),
                      ],
                      const SizedBox(height: 14),
                      _choiceButton(
                        label: 'الصف الدراسي',
                        value: selectedStages.isEmpty ? 'اختر صفاً أو عدة صفوف' : selectedStages.map(_stageLabel).join('، '),
                        icon: Icons.school_rounded,
                        enabled: !loadingCatalog && stages.isNotEmpty,
                        isDark: isDark,
                        textColor: textColor,
                        onTap: _chooseStages,
                      ),
                      const SizedBox(height: 10),
                      _choiceButton(
                        label: 'المادة الدراسية',
                        value: selectedSubjects.isEmpty ? 'اختر مادة أو عدة مواد' : '${selectedSubjects.length} مادة/صف',
                        icon: Icons.menu_book_rounded,
                        enabled: selectedStages.isNotEmpty,
                        isDark: isDark,
                        textColor: textColor,
                        onTap: _chooseSubjects,
                      ),
                      const SizedBox(height: 8),
                      Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        decoration: BoxDecoration(
                          color: isDark ? const Color(0xFF0B0E1A).withOpacity(0.68) : const Color(0xFFF1F5F9),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: blueNeon.withOpacity(isDark ? 0.35 : 0.25), width: 1.2),
                        ),
                        child: CheckboxListTile(
                          dense: true,
                          activeColor: blueNeon,
                          controlAffinity: ListTileControlAffinity.leading,
                          value: allStagesAndSubjects,
                          onChanged: loadingCatalog ? null : (v) => _setAllStagesAndSubjects(v == true),
                          title: Text(
                            'تطبيق العملية على جميع الصفوف والمواد الدراسية',
                            style: TextStyle(fontWeight: FontWeight.w900, fontSize: 13, color: textColor),
                          ),
                          subtitle: Text(
                            'عند التفعيل لن تحتاج لاختيار الصفوف والمواد يدوياً.',
                            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 11.5, color: mutedColor),
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      _choiceButton(
                        label: 'الفصول',
                        value: selectedTerms.isEmpty ? 'اختر فصلاً أو عدة فصول' : selectedTerms.join('، '),
                        icon: Icons.event_note_rounded,
                        enabled: !loadingCatalog && _termLabels.isNotEmpty,
                        isDark: isDark,
                        textColor: textColor,
                        onTap: _chooseTerms,
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: running ? null : () => _run(true),
                              icon: const Icon(Icons.visibility_off_rounded, size: 18),
                              label: const Text('إهمال الامتحان', style: TextStyle(fontWeight: FontWeight.w900)),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: redNeon,
                                side: BorderSide(color: redNeon.withOpacity(0.5)),
                                minimumSize: const Size.fromHeight(50),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: FilledButton.icon(
                              onPressed: running ? null : () => _run(false),
                              icon: const Icon(Icons.visibility_rounded, size: 18),
                              label: const Text('إلغاء الإهمال', style: TextStyle(fontWeight: FontWeight.w900)),
                              style: FilledButton.styleFrom(
                                backgroundColor: blueNeon,
                                minimumSize: const Size.fromHeight(50),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (running) ...[
                        const SizedBox(height: 12),
                        const LinearProgressIndicator(minHeight: 4, color: blueNeon),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _choiceButton({
    required String label,
    required String value,
    required IconData icon,
    required bool enabled,
    required bool isDark,
    required Color textColor,
    required VoidCallback onTap,
  }) {
    const blueNeon = Color(0xFF3B82F6);
    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        decoration: BoxDecoration(
          color: enabled
              ? (isDark ? const Color(0xFF0B0E1A).withOpacity(0.68) : const Color(0xFFF1F5F9))
              : Colors.grey.withOpacity(.08),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: blueNeon.withOpacity(isDark ? 0.35 : 0.25),
            width: 1.2,
          ),
        ),
        child: Row(
          children: [
            Icon(icon, color: blueNeon, size: 22),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                        color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF475569),
                      )),
                  const SizedBox(height: 3),
                  Text(value,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: FontWeight.w900,
                        fontSize: 13.5,
                        color: textColor,
                      )),
                ],
              ),
            ),
            Icon(Icons.arrow_drop_down_rounded, color: isDark ? Colors.white70 : Colors.black54),
          ],
        ),
      ),
    );
  }
}
