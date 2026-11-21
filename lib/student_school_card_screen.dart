import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'school_card_detail_screen.dart';

class StudentSchoolCardScreen extends StatefulWidget {
  final String token;
  final String schoolId;

  const StudentSchoolCardScreen({
    super.key,
    required this.token,
    required this.schoolId,
  });

  @override
  State<StudentSchoolCardScreen> createState() => _StudentSchoolCardScreenState();
}

class _StudentSchoolCardScreenState extends State<StudentSchoolCardScreen> {
  static const String _base = 'https://emis.moedu.gov.iq/api';
  final TextEditingController _search = TextEditingController();
  List<Map<String, dynamic>> _students = <Map<String, dynamic>>[];
  String? _selectedStage;
  String? _selectedClassRoom;
  bool _loading = true;
  String? _error;

  Map<String, String> get _headers => {
        'Authorization': widget.token,
        'Accept': 'application/json',
      };

  @override
  void initState() {
    super.initState();
    _loadStudents();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  dynamic _unwrap(dynamic value) =>
      value is Map && value['data'] != null ? value['data'] : value;

  Future<void> _loadStudents() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      // EMIS paginates the endpoint even when rowsPerPage is set very high.
      // Read every page so stage/class selectors and student results are complete.
      const pageSize = 100;
      var page = 1;
      var totalCount = 0;
      final all = <Map<String, dynamic>>[];
      do {
        final uri = Uri.parse('$_base/student/getstudents').replace(
          queryParameters: {
            'page': '$page',
            'rowsPerPage': '$pageSize',
            'sortBy': 'id',
            'sortOrder': 'desc',
            'entityId': widget.schoolId,
          },
        );
        final response = await http.get(uri, headers: _headers)
            .timeout(const Duration(seconds: 30));
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw Exception('تعذر تحميل الطلاب (HTTP ${response.statusCode})');
        }
        final decoded = jsonDecode(utf8.decode(response.bodyBytes));
        final data = _unwrap(decoded);
        if (data is! List) throw Exception('استجابة قائمة الطلاب غير صالحة');
        all.addAll(data.whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e)));
        if (decoded is Map && decoded['meta'] is Map) {
          final meta = decoded['meta'] as Map;
          totalCount = int.tryParse('${meta['totalCount'] ?? ''}') ?? totalCount;
          final actualPageSize = int.tryParse('${meta['rowsPerPage'] ?? ''}') ?? pageSize;
          if (data.isEmpty) break;
          if (actualPageSize > 0 &&
              data.length < actualPageSize &&
              (totalCount == 0 || all.length >= totalCount)) {
            break;
          }
        } else if (data.length < pageSize) {
          break;
        }
        page++;
      } while (page <= 100 && (totalCount == 0 || all.length < totalCount));

      if (!mounted) return;
      setState(() {
        _students = all;
        final stages = _stageOptions;
        if (_selectedStage != null && !stages.contains(_selectedStage)) {
          _selectedStage = null;
          _selectedClassRoom = null;
        }
        if (_selectedStage != null &&
            !_classRoomOptions.contains(_selectedClassRoom)) {
          _selectedClassRoom = null;
        }
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  List<String> get _stageOptions {
    final values = _students
        .map((s) => '${s['studentStage'] ?? ''}'.trim())
        .where((s) => s.isNotEmpty)
        .toSet()
        .toList();
    values.sort();
    return values;
  }

  List<String> get _classRoomOptions {
    if (_selectedStage == null) return <String>[];
    final values = _students
        .where((s) => '${s['studentStage'] ?? ''}'.trim() == _selectedStage)
        .map((s) => '${s['classRoom'] ?? ''}'.trim())
        .where((s) => s.isNotEmpty)
        .toSet()
        .toList();
    values.sort();
    return values;
  }

  List<Map<String, dynamic>> get _filteredStudents {
    if (_selectedStage == null || _selectedClassRoom == null) {
      return <Map<String, dynamic>>[];
    }
    final q = _search.text.trim().toLowerCase();
    return _students.where((s) {
      if ('${s['studentStage'] ?? ''}'.trim() != _selectedStage) return false;
      if ('${s['classRoom'] ?? ''}'.trim() != _selectedClassRoom) return false;
      if (q.isEmpty) return true;
      final name = '${s['fullName'] ?? ''}'.toLowerCase();
      final national = '${s['nationalIdNumber'] ?? ''}'.toLowerCase();
      final id = '${s['id'] ?? ''}';
      return name.contains(q) || national.contains(q) || id.contains(q);
    }).toList();
  }

  void _selectStage(String? value) {
    setState(() {
      _selectedStage = value;
      _selectedClassRoom = null;
      _search.clear();
    });
  }

  void _selectClassRoom(String? value) {
    setState(() {
      _selectedClassRoom = value;
      _search.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filteredStudents;
    return Scaffold(
      appBar: AppBar(
        title: const Text('البطاقة المدرسية'),
        centerTitle: true,
        actions: [
          IconButton(
            tooltip: 'تحديث البيانات',
            onPressed: _loading ? null : _loadStudents,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _ErrorView(message: _error!, onRetry: _loadStudents)
              : Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                      child: DropdownButtonFormField<String>(
                        value: _selectedStage,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: 'اختر الصف',
                          prefixIcon: Icon(Icons.school_outlined),
                          border: OutlineInputBorder(),
                        ),
                        items: _stageOptions.map((stage) =>
                          DropdownMenuItem<String>(
                            value: stage,
                            child: Text(stage, textDirection: TextDirection.rtl,
                                overflow: TextOverflow.ellipsis),
                          )).toList(),
                        onChanged: _selectStage,
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
                      child: DropdownButtonFormField<String>(
                        value: _selectedClassRoom,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: 'اختر الشعبة',
                          prefixIcon: Icon(Icons.groups_outlined),
                          border: OutlineInputBorder(),
                        ),
                        items: _classRoomOptions.map((room) =>
                          DropdownMenuItem<String>(
                            value: room,
                            child: Text(room, textDirection: TextDirection.rtl),
                          )).toList(),
                        onChanged: _selectedStage == null ? null : _selectClassRoom,
                      ),
                    ),
                    if (_selectedStage != null && _selectedClassRoom != null) ...[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 2, 16, 8),
                        child: TextField(
                          controller: _search,
                          onChanged: (_) => setState(() {}),
                          textDirection: TextDirection.rtl,
                          decoration: InputDecoration(
                            hintText: 'ابحث باسم الطالب أو الرقم الوطني',
                            prefixIcon: const Icon(Icons.search),
                            suffixIcon: _search.text.isEmpty ? null : IconButton(
                              onPressed: () { _search.clear(); setState(() {}); },
                              icon: const Icon(Icons.clear),
                            ),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 4),
                        child: Row(
                          children: [
                            const Icon(Icons.people_alt_outlined, size: 18),
                            const SizedBox(width: 7),
                            Text('طلاب الشعبة: ${filtered.length}'),
                            const Spacer(),
                            Text('الصف: $_selectedStage / الشعبة: $_selectedClassRoom'),
                          ],
                        ),
                      ),
                      Expanded(
                        child: filtered.isEmpty
                            ? const Center(child: Text('لا يوجد طلاب في هذه الشعبة'))
                            : RefreshIndicator(
                                onRefresh: _loadStudents,
                                child: ListView.separated(
                                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 20),
                                  itemCount: filtered.length,
                                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                                  itemBuilder: (context, index) {
                                    final student = filtered[index];
                                    return Card(
                                      elevation: 1,
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(16),
                                      ),
                                      child: ListTile(
                                        contentPadding: const EdgeInsets.symmetric(
                                          horizontal: 14, vertical: 5),
                                        leading: CircleAvatar(
                                          backgroundColor: Theme.of(context)
                                              .colorScheme.primaryContainer,
                                          child: const Icon(Icons.badge_outlined),
                                        ),
                                        title: Text(
                                          '${student['fullName'] ?? 'بدون اسم'}',
                                          textDirection: TextDirection.rtl,
                                          style: const TextStyle(fontWeight: FontWeight.bold),
                                        ),
                                        subtitle: Text(
                                          'الرقم الوطني: ${student['nationalIdNumber'] ?? '-'}',
                                          textDirection: TextDirection.rtl,
                                        ),
                                        trailing: const Icon(Icons.chevron_left_rounded),
                                        onTap: () => Navigator.push(
                                          context,
                                          MaterialPageRoute(
                                            builder: (_) => SchoolCardDetailScreen(
                                              token: widget.token,
                                              schoolId: widget.schoolId,
                                              students: filtered,
                                              initialIndex: index,
                                            ),
                                          ),
                                        ),
                                      ),
                                    );
                                  },
                                ),
                              ),
                      ),
                    ] else
                      const Expanded(
                        child: Center(
                          child: Text('اختر الصف ثم الشعبة لعرض أسماء الطلاب',
                              style: TextStyle(fontWeight: FontWeight.w600)),
                        ),
                      ),
                  ],
                ),
    );
  }
}

class _CardSection {
  final String key;
  final String title;
  final Map<String, String> fields;

  const _CardSection(this.key, this.title, this.fields);
}

const List<_CardSection> _sections = [
  _CardSection('initialInformation', 'المعلومات الأولية', {
    'governorate': 'المحافظة', 'city': 'القضاء / المدينة',
    'guardianName': 'اسم ولي الأمر', 'guardianJob': 'مهنة ولي الأمر',
    'guardianPhone': 'هاتف ولي الأمر', 'guardianRelationship': 'صلة القرابة',
    'fatherIsAlive': 'حالة الأب', 'motherIsAlive': 'حالة الأم',
    'fatherEducation': 'تحصيل الأب الدراسي', 'motherEducation': 'تحصيل الأم الدراسي',
    'studentOrderAmongSiblings': 'تسلسل الطالب بين إخوته',
    'classPhotoUrl': 'رابط صورة الصف', 'familyAddress': 'عنوان الأسرة',
    'notes': 'ملاحظات',
  }),
  _CardSection('socialStatus', 'الحالة الاجتماعية', {
    'familyMemberCount': 'عدد أفراد الأسرة', 'brothersCount': 'عدد الإخوة',
    'sistersCount': 'عدد الأخوات', 'livingWith': 'يسكن مع',
    'monthlyIncome': 'الدخل الشهري', 'roomCount': 'عدد الغرف',
    'studyEnvironmentSuitability': 'ملاءمة بيئة الدراسة',
    'studentWorks': 'هل يعمل الطالب؟', 'notes': 'ملاحظات',
  }),
  _CardSection('healthAndPhysicalTraits', 'الحالة الصحية والصفات البدنية', {
    'height': 'الطول', 'weight': 'الوزن', 'visionReport': 'تقرير النظر',
    'rightEyeVisionDegree': 'درجة نظر العين اليمنى',
    'leftEyeVisionDegree': 'درجة نظر العين اليسرى',
    'hearingReport': 'تقرير السمع', 'hearingDegree': 'درجة السمع',
    'speech': 'النطق', 'dentalExaminationAtRegistration': 'فحص الأسنان عند التسجيل',
    'visitingHealthTeamDentalNotes': 'ملاحظات الفريق الصحي للأسنان',
    'completedRequiredVaccinations': 'إكمال اللقاحات المطلوبة',
    'vaccinations': 'اللقاحات', 'drugAllergy': 'الحساسية الدوائية',
    'drugAllergyCause': 'سبب الحساسية', 'physicalDisabilities': 'الإعاقات البدنية',
    'physicalDisabilitiesType': 'نوع الإعاقة', 'chronicDiseases': 'الأمراض المزمنة',
    'chronicDiseasesType': 'نوع المرض', 'previousAccidents': 'الحوادث السابقة',
    'previousAccidentsType': 'تفاصيل الحوادث', 'surgeries': 'العمليات الجراحية',
    'surgeriesType': 'تفاصيل العمليات', 'generalHealthStatus': 'الحالة الصحية العامة',
  }),
  _CardSection('personalTraits', 'الصفات الشخصية', {
    'traitsOften': 'صفات تظهر كثيراً', 'traitsSometimes': 'صفات تظهر أحياناً',
    'traitsRarely': 'صفات تظهر نادراً', 'traitsList': 'تفاصيل الصفات (JSON)',
    'traitDegree': 'درجة الصفات',
  }),
  _CardSection('interests', 'الميول والاهتمامات', {
    'interestsOften': 'اهتمامات كثيراً', 'interestsSometimes': 'اهتمامات أحياناً',
    'interestsRarely': 'اهتمامات نادراً', 'interestsList': 'تفاصيل الاهتمامات (JSON)',
    'interestDegree': 'درجة الاهتمامات',
  }),
  _CardSection('scientificInterests', 'الميول العلمية', {
    'subjectsExcelledIn': 'المواد التي يتميز بها', 'grade': 'الدرجة',
    'practicalParticipation': 'المشاركة العملية', 'participationDegree': 'درجة المشاركة',
    'talents': 'المواهب', 'scientificProgramCenterName': 'مركز البرنامج العلمي',
    'scientificProgramMembershipDate': 'تاريخ العضوية',
    'scientificExhibitionParticipationAndSuccess': 'المشاركة في المعارض العلمية',
    'createdDeviceTypes': 'الأجهزة التي صنعها', 'schoolGiftsAndRewards': 'هدايا ومكافآت المدرسة',
    'relatedEntityGiftsAndRewardsInIraq': 'مكافآت الجهات ذات العلاقة',
    'extracurricularScientificInterests': 'اهتمامات علمية خارج المنهج',
    'notes': 'ملاحظات',
  }),
  _CardSection('problems', 'المشكلات والإجراءات', {
    'problemType': 'نوع المشكلة', 'description': 'وصف المشكلة',
    'actionTaken': 'الإجراء المتخذ', 'actionTakenWithEntity': 'الإجراء مع الجهة',
  }),
  _CardSection('awardsAndPenalties', 'الجوائز والعقوبات', {
    'hasAwardsPenalties': 'توجد جوائز أو عقوبات', 'school': 'المدرسة',
    'honorCount': 'عدد كتب الشكر', 'penaltyCount': 'عدد العقوبات',
    'justificationAndSource': 'التبرير والمصدر', 'effectiveness': 'الأثر',
  }),
  _CardSection('generalStudentReport', 'التقرير العام للطالب', {
    'stageLabel': 'المرحلة الدراسية', 'report': 'التقرير',
  }),
];

class _StudentCardDetailScreen extends StatefulWidget {
  final String token;
  final String studentId;
  final String studentName;

  const _StudentCardDetailScreen({
    required this.token,
    required this.studentId,
    required this.studentName,
  });

  @override
  State<_StudentCardDetailScreen> createState() =>
      _StudentCardDetailScreenState();
}

class _StudentCardDetailScreenState extends State<_StudentCardDetailScreen> {
  static const String _base = 'https://emis.moedu.gov.iq/api/StudentSchoolCard';
  Map<String, dynamic>? _student;
  List<dynamic> _academicRecords = [];
  Map<String, dynamic>? _achievement;
  Map<String, dynamic>? _attendance;
  final Map<String, Map<String, TextEditingController>> _controllers = {};
  final Map<String, dynamic> _sectionData = {};
  final TextEditingController _registrationNumber = TextEditingController();
  final TextEditingController _rank = TextEditingController();
  bool _loading = true;
  String? _error;
  bool _saving = false;
  int? _stageId;
  int? _academicYearId;

  Map<String, String> get _headers => {
        'Authorization': widget.token,
        'Accept': 'application/json',
        'Content-Type': 'application/json',
      };

  @override
  void initState() {
    super.initState();
    _loadCard();
  }

  @override
  void dispose() {
    _registrationNumber.dispose();
    _rank.dispose();
    for (final group in _controllers.values) {
      for (final controller in group.values) {
        controller.dispose();
      }
    }
    super.dispose();
  }

  dynamic _unwrap(dynamic value) =>
      value is Map && value['data'] != null ? value['data'] : value;

  Future<dynamic> _get(String url) async {
    final response = await http.get(Uri.parse(url), headers: _headers)
        .timeout(const Duration(seconds: 25));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('HTTP ${response.statusCode}: ${utf8.decode(response.bodyBytes)}');
    }
    if (response.body.trim().isEmpty) return null;
    return _unwrap(jsonDecode(utf8.decode(response.bodyBytes)));
  }

  Future<void> _loadCard() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final student = await _get(
        'https://emis.moedu.gov.iq/api/student/getstudent/${widget.studentId}',
      );
      if (student is! Map) throw Exception('لم يتم العثور على بيانات الطالب');
      _student = Map<String, dynamic>.from(student);
      _stageId = int.tryParse('${_student!['stageId'] ?? ''}');
      if (_stageId == null) throw Exception('لا تتوفر المرحلة الدراسية للطالب');
      final results = await Future.wait<dynamic>([
        _get('$_base/academicrecord/${widget.studentId}'),
        _get('$_base/academicachievement/${widget.studentId}'),
        _get('$_base/attendance/${widget.studentId}'),
      ]);
      _academicRecords = results[0] is List ? results[0] as List : [];
      _achievement = results[1] is Map
          ? Map<String, dynamic>.from(results[1] as Map)
          : (results[1] is List && (results[1] as List).isNotEmpty
              ? Map<String, dynamic>.from((results[1] as List).first as Map)
              : null);
      _attendance = results[2] is Map
          ? Map<String, dynamic>.from(results[2] as Map)
          : null;
      if (_academicRecords.isNotEmpty && _academicRecords.first is Map) {
        _academicYearId = int.tryParse(
          '${(_academicRecords.first as Map)['academicYearId'] ?? ''}',
        );
      }
      _registrationNumber.text = _academicRecords.isNotEmpty &&
              _academicRecords.first is Map
          ? '${(_academicRecords.first as Map)['studentRegistrationNumber'] ?? ''}'
          : '';
      _rank.text = '${_achievement?['successRankInClassroom'] ?? ''}';
      for (final section in _sections) {
        final data = await _get(
          '$_base/section?studentId=${widget.studentId}'
          '&sectionKey=${Uri.encodeQueryComponent(section.key)}&stageId=$_stageId',
        );
        Map<String, dynamic> decoded = {};
        if (data is Map) {
          final raw = data['dataJson'];
          if (raw is String && raw.isNotEmpty) {
            final parsed = jsonDecode(raw);
            if (parsed is Map) decoded = Map<String, dynamic>.from(parsed);
          } else if (raw is Map) {
            decoded = Map<String, dynamic>.from(raw);
          }
        }
        _sectionData[section.key] = decoded;
        final group = <String, TextEditingController>{};
        for (final entry in section.fields.entries) {
          group[entry.key] = TextEditingController(
            text: decoded[entry.key]?.toString() ?? '',
          );
        }
        _controllers[section.key] = group;
      }
    } catch (e) {
      _error = e.toString();
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _saveSection(_CardSection section) async {
    if (_stageId == null) return;
    setState(() => _saving = true);
    try {
      final data = Map<String, dynamic>.from(
        _sectionData[section.key] is Map
            ? _sectionData[section.key] as Map
            : <String, dynamic>{},
      );
      for (final entry in _controllers[section.key]!.entries) {
        data[entry.key] = entry.value.text.trim();
      }
      final response = await http.post(
        Uri.parse('$_base/savesection'),
        headers: _headers,
        body: jsonEncode({
          'studentId': int.parse(widget.studentId),
          'sectionKey': section.key,
          'stageId': _stageId,
          'dataJson': jsonEncode(data),
          'changeReason': '',
        }),
      ).timeout(const Duration(seconds: 25));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception('HTTP ${response.statusCode}: ${utf8.decode(response.bodyBytes)}');
      }
      _sectionData[section.key] = data;
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تم حفظ ${section.title} بنجاح')),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('فشل الحفظ: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _saveAcademicRecord() async {
    final year = _academicYearId;
    final student = _student;
    if (year == null || student == null || _stageId == null) {
      _message('بيانات السجل الدراسي غير مكتملة');
      return;
    }
    await _postAction('updateacademicrecord', {
      'studentId': int.parse(widget.studentId),
      'academicYearId': year,
      'stageId': _stageId,
      'schoolId': student['schoolId'],
      'studentRegistrationNumber': _registrationNumber.text.trim(),
    }, 'تم حفظ رقم التسجيل الدراسي');
  }

  Future<void> _saveRank() async {
    final student = _student;
    if (student == null || _academicYearId == null || _stageId == null) return;
    await _postAction('updateachievementrank', {
      'studentId': int.parse(widget.studentId),
      'academicYearId': _academicYearId,
      'stageId': _stageId,
      'schoolId': student['schoolId'],
      'successRankInClassroom': _rank.text.trim(),
    }, 'تم حفظ ترتيب الطالب');
  }

  Future<void> _postAction(
    String action,
    Map<String, dynamic> body,
    String success,
  ) async {
    setState(() => _saving = true);
    try {
      final response = await http.post(
        Uri.parse('$_base/$action'),
        headers: _headers,
        body: jsonEncode(body),
      ).timeout(const Duration(seconds: 25));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception('HTTP ${response.statusCode}: ${utf8.decode(response.bodyBytes)}');
      }
      _message(success);
    } catch (e) {
      _message('فشل الحفظ: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _message(String value) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(value)),
      );
    }
  }

  Widget _field(String label, TextEditingController controller) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: controller,
        minLines: 1,
        maxLines: 3,
        textDirection: TextDirection.rtl,
        decoration: InputDecoration(
          labelText: label,
          alignLabelWithHint: true,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
        ),
      ),
    );
  }

  Widget _sectionCard(_CardSection section) {
    final group = _controllers[section.key] ?? {};
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        initiallyExpanded: section.key == 'initialInformation',
        leading: const Icon(Icons.article_outlined),
        title: Text(section.title, style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Text('${group.length} حقلاً'),
        childrenPadding: const EdgeInsets.fromLTRB(14, 4, 14, 14),
        children: [
          ...section.fields.entries.map(
            (entry) => _field(entry.value, group[entry.key]!),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              onPressed: _saving ? null : () => _saveSection(section),
              icon: const Icon(Icons.save_outlined),
              label: const Text('حفظ القسم'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _studentHeader() {
    final s = _student ?? {};
    final photo = '${s['imageUrl'] ?? ''}';
    final imageUrl = photo.startsWith('http')
        ? photo
        : 'https://emis.moedu.gov.iq${photo.startsWith('/') ? '' : '/'}$photo';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            CircleAvatar(
              radius: 34,
              backgroundImage: photo.isNotEmpty && photo != 'null'
                  ? NetworkImage(imageUrl)
                  : null,
              child: photo.isEmpty || photo == 'null'
                  ? const Icon(Icons.person, size: 32)
                  : null,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(widget.studentName,
                      textAlign: TextAlign.right,
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 17)),
                  Text('${s['schoolName'] ?? ''}', textAlign: TextAlign.right),
                  Text('${s['stageName'] ?? ''} - ${s['classRoomName'] ?? ''}',
                      textAlign: TextAlign.right),
                  Text('العام الدراسي: ${s['academicYearName'] ?? '-'}',
                      textAlign: TextAlign.right),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _academicCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('السجل الدراسي', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 12),
            _field('رقم تسجيل الطالب', _registrationNumber),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                onPressed: _saving ? null : _saveAcademicRecord,
                icon: const Icon(Icons.save),
                label: const Text('حفظ السجل الدراسي'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _achievementCard() {
    final a = _achievement ?? {};
    final attendance = _attendance ?? {};
    final records = attendance['records'] is List
        ? attendance['records'] as List
        : const [];
    final record = records.isNotEmpty && records.first is Map
        ? records.first as Map
        : <String, dynamic>{};
    final subjects = a['subjectResults'] is List
        ? a['subjectResults'] as List
        : const [];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('التحصيل الدراسي والغيابات',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 10),
            Text('المعدل: ${a['averageScore'] ?? '-'}  •  الدرجة الكلية: ${a['totalScore'] ?? '-'}'),
            Text('الحالة: ${a['finalMarkStatus'] ?? '-'}'),
            Text('أيام الغياب بعذر: ${record['excusedAbsenceDays'] ?? '-'}'),
            Text('أيام الغياب بدون عذر: ${record['unexcusedAbsenceDays'] ?? '-'}'),
            Text('مجموع أيام الغياب: ${record['totalAbsenceDays'] ?? '-'}'),
            const Divider(height: 22),
            _field('ترتيب النجاح في الصف', _rank),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                onPressed: _saving ? null : _saveRank,
                icon: const Icon(Icons.save),
                label: const Text('حفظ الترتيب'),
              ),
            ),
            if (subjects.isNotEmpty) ...[
              const Divider(height: 22),
              const Text('نتائج المواد', style: TextStyle(fontWeight: FontWeight.bold)),
              ...subjects.map((item) {
                if (item is! Map) return const SizedBox.shrink();
                return ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text('${item['subjectName'] ?? ''}'),
                  subtitle: Text('السعي السنوي: ${item['yearEffortMark'] ?? '-'}'
                      '  •  النهائي: ${item['effectingFinalMark'] ?? '-'}'),
                );
              }),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('البطاقة المدرسية'),
        centerTitle: true,
        actions: [
          IconButton(
            onPressed: _loading ? null : _loadCard,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _ErrorView(message: _error!, onRetry: _loadCard)
              : ListView(
                  padding: const EdgeInsets.all(12),
                  children: [
                    _studentHeader(),
                    _academicCard(),
                    _achievementCard(),
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 10),
                      child: Text('بيانات البطاقة المدرسية',
                          textAlign: TextAlign.right,
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                    ),
                    ..._sections.map(_sectionCard),
                  ],
                ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _ErrorView({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_rounded, size: 44),
            const SizedBox(height: 12),
            const Text('تعذر تحميل البيانات', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 14),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('إعادة المحاولة'),
            ),
          ],
        ),
      ),
    );
  }
}
