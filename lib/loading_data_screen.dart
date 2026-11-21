import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:lottie/lottie.dart';
import 'dashboard_screen.dart';
import 'app_core.dart';
import 'emis_webview_screen.dart';

class LoadingDataScreen extends StatefulWidget {
  final String token;
  final String? refreshToken;
  final String schoolId;

  const LoadingDataScreen({
    super.key,
    required this.token,
    this.refreshToken,
    required this.schoolId,
  });

  @override
  State<LoadingDataScreen> createState() => _LoadingDataScreenState();
}

class _SessionExpired implements Exception {}

class _LoadingDataScreenState extends State<LoadingDataScreen> {
  String _statusText = 'جاري الاتصال بخوادم EMIS...';
  double _progressValue = .08;
  late String _activeToken;

  Future<bool>? _refreshingTokenFuture;
  bool _hasTriedRefreshOn403 = false;

  List<Map<String, dynamic>> _stages = [];
  final Map<String, List<Map<String, dynamic>>> _subjectsByStage = {};
  final Map<String, List<Map<String, dynamic>>> _examsBySubject = {};

  @override
  void initState() {
    super.initState();
    _activeToken = widget.token;
    AppCore.playRelaxMusic();
    _startFetchingData();
  }

  @override
  void dispose() {
    super.dispose();
  }


  Map<String, String> get _headers => {
        'Authorization': _activeToken.toLowerCase().startsWith('bearer ')
            ? _activeToken
            : 'Bearer $_activeToken',
        'Accept': 'application/json, text/plain, */*',
        'User-Agent':
            'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
      };

  Future<bool> _refreshAccessToken() async {
    if (_refreshingTokenFuture != null) {
      return await _refreshingTokenFuture!;
    }
    _refreshingTokenFuture = _doRefreshToken();
    try {
      return await _refreshingTokenFuture!;
    } finally {
      _refreshingTokenFuture = null;
    }
  }

  Future<bool> _doRefreshToken() async {
    final refresh = widget.refreshToken?.trim();
    if (refresh == null || refresh.isEmpty) return false;
    try {
      final current = _activeToken.replaceFirst(
        RegExp(r'^Bearer\s+', caseSensitive: false),
        '',
      );
      final response = await http
          .post(
            Uri.parse('https://emis.moedu.gov.iq/api/account/refresh'),
            headers: const {
              'Accept': 'application/json',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              'accessToken': current,
              'refreshToken': refresh,
            }),
          )
          .timeout(const Duration(seconds: 15));

      if (response.statusCode != 200) return false;
      final decoded = _decode(response);
      if (decoded is Map) {
        final next = (decoded['accessToken'] ??
                decoded['token'] ??
                (decoded['data'] is Map ? decoded['data']['accessToken'] : null))
            ?.toString();
        if (next != null && next.trim().isEmpty == false) {
          _activeToken = next.trim();
          return true;
        }
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  Future<http.Response> _get(Uri uri, {int retries = 2}) async {
    http.Response? last;
    for (int attempt = 0; attempt < retries; attempt++) {
      try {
        final response = await http
            .get(uri, headers: _headers)
            .timeout(const Duration(seconds: 15));
        last = response;

        if (response.statusCode >= 200 && response.statusCode < 300) {
          return response;
        }

        if (response.statusCode == 401) {
          if (await _refreshAccessToken()) {
            await Future<void>.delayed(const Duration(milliseconds: 300));
            continue;
          }
          throw _SessionExpired();
        }

        if (response.statusCode == 403) {
          if (!_hasTriedRefreshOn403) {
            _hasTriedRefreshOn403 = true;
            if (await _refreshAccessToken()) {
              await Future<void>.delayed(const Duration(milliseconds: 400));
              continue;
            }
          }
          break;
        }

        if (attempt < retries - 1) {
          await Future<void>.delayed(Duration(milliseconds: 800 * (attempt + 1)));
        }
      } on _SessionExpired {
        rethrow;
      } catch (_) {
        if (attempt == retries - 1) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 700));
      }
    }
    throw Exception('EMIS HTTP ${last?.statusCode ?? 0}');
  }

  Future<dynamic> _safeGetDecoded(Uri uri, {String debugLabel = ''}) async {
    try {
      final response = await _get(uri);
      return _decode(response);
    } on _SessionExpired {
      rethrow;
    } catch (e) {
      debugPrint('⚠️ تم تخطي خطأ في [$debugLabel] ($uri): $e');
      return null;
    }
  }

  dynamic _decode(http.Response response) {
    try {
      final text = utf8.decode(response.bodyBytes, allowMalformed: true).trim();
      if (text.isEmpty) return <String, dynamic>{};
      return jsonDecode(text);
    } catch (e) {
      debugPrint('⚠️ تعذر قراءة JSON: $e');
      return <String, dynamic>{};
    }
  }

  List<dynamic> _smartExtractList(dynamic decoded) {
    if (decoded == null) return <dynamic>[];
    if (decoded is List) return decoded;
    if (decoded is Map) {
      const candidateKeys = [
        'data', 'items', 'result', 'results', 'records', 'value', 'exams', 'students', 'employees', 'stages', 'subjects', 'list',
      ];
      for (final key in candidateKeys) {
        final val = decoded[key];
        if (val is List) return val;
        if (val is Map) {
          for (final subKey in candidateKeys) {
            if (val[subKey] is List) return val[subKey] as List;
          }
        }
      }
      for (final val in decoded.values) {
        if (val is List) return val;
      }
    }
    return <dynamic>[];
  }

  List<Map<String, dynamic>> _smartMaps(dynamic value) {
    final list = _smartExtractList(value);
    return [
      for (final item in list)
        if (item is Map) Map<String, dynamic>.from(item),
    ];
  }

  Map<String, dynamic> _smartExtractMap(dynamic decoded) {
    if (decoded == null) return <String, dynamic>{};
    if (decoded is Map) {
      if (decoded['data'] is Map) {
        return Map<String, dynamic>.from(decoded['data'] as Map);
      }
      if (decoded['result'] is Map) {
        return Map<String, dynamic>.from(decoded['result'] as Map);
      }
      return Map<String, dynamic>.from(decoded);
    }
    if (decoded is List && decoded.isNotEmpty && decoded.first is Map) {
      return Map<String, dynamic>.from(decoded.first as Map);
    }
    return <String, dynamic>{};
  }

  String _cleanNamePart(dynamic value) {
    final text = value?.toString().trim() ?? '';
    if (text.isEmpty || text.toLowerCase() == 'null') return '';
    return text.replaceAll(RegExp(r'\s+'), ' ');
  }

  String _resolveUserName(Map<String, dynamic> userData) {
    // API versions use different spellings for the same name components.
    final candidates = <String>[
      _cleanNamePart(userData['employeeName']),
      _cleanNamePart(userData['employeeFullName']),
      _cleanNamePart(userData['fullName']),
      _cleanNamePart(userData['userName']),
      _cleanNamePart(userData['name']),
    ].where((value) => value.isNotEmpty).toList();

    final parts = <String>[
      _cleanNamePart(userData['firstName']),
      _cleanNamePart(userData['fatherName'] ?? userData['secondName']),
      _cleanNamePart(userData['grandFatherName'] ?? userData['thirdName']),
      _cleanNamePart(userData['lastName'] ?? userData['surname'] ?? userData['sureName']),
    ].where((value) => value.isNotEmpty).toList();

    // Build a component-based name as a fallback and avoid adjacent duplicate parts.
    final uniqueParts = <String>[];
    for (final part in parts) {
      if (uniqueParts.isEmpty || uniqueParts.last != part) uniqueParts.add(part);
    }
    final assembled = uniqueParts.join(' ');
    if (assembled.isNotEmpty) candidates.add(assembled);

    // Prefer the candidate with the most name tokens. This avoids selecting a
    // non-empty but abbreviated employeeName when a fuller name is also present.
    candidates.sort((a, b) {
      final aCount = a.split(RegExp(r'\s+')).length;
      final bCount = b.split(RegExp(r'\s+')).length;
      if (aCount != bCount) return bCount.compareTo(aCount);
      return b.length.compareTo(a.length);
    });
    return candidates.isNotEmpty ? candidates.first : 'مستخدم النظام';
  }

  String _catalogId(Map<String, dynamic> item) {
    final id = item['value'] ?? item['id'] ?? item['stageId'] ?? item['subjectId'] ?? item['key'] ?? item['code'] ?? '';
    return id.toString().trim();
  }

  Future<void> _runConcurrent<T>(
    List<T> items,
    Future<void> Function(T item) task, {
    int maxConcurrent = 2,
  }) async {
    if (items.isEmpty) return;
    var nextIndex = 0;
    final safeConcurrency = maxConcurrent > 2 ? 2 : maxConcurrent;
    final workerCount = items.length < safeConcurrency ? items.length : safeConcurrency;

    Future<void> worker() async {
      while (true) {
        final index = nextIndex++;
        if (index >= items.length) return;
        try {
          await task(items[index]);
        } on _SessionExpired {
          rethrow;
        } catch (e) {
          debugPrint('⚠️ تم تخطي عنصر أثناء المزامنة: $e');
        }
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
    }

    await Future.wait(List.generate(workerCount, (_) => worker()));
  }

  Future<void> _loadAcademicCatalog() async {
    if (!mounted) return;
    setState(() {
      _statusText = 'جاري استيراد الصفوف الدراسية والشعب...';
      _progressValue = .44;
    });

    final stagesResults = await Future.wait([
      _safeGetDecoded(
        Uri.parse('https://emis.moedu.gov.iq/api/selectoption/getschoolstages/${widget.schoolId}'),
        debugLabel: 'الصفوف الدراسية',
      ),
      _safeGetDecoded(
        Uri.parse('https://emis.moedu.gov.iq/api/selectoption/getAvailableStagesForStudent?schoolId=${widget.schoolId}'),
        debugLabel: 'صفوف الطلاب المتاحة',
      ),
    ]);

    _stages = _smartMaps(stagesResults[0]);
    final availableStudentStages = _smartMaps(stagesResults[1]);
    if (_stages.isEmpty && availableStudentStages.isNotEmpty) {
      _stages = availableStudentStages;
    }

    final stagesToCache = availableStudentStages.isNotEmpty ? availableStudentStages : _stages;
    if (stagesToCache.isEmpty && _stages.isEmpty) return;

    final allStageIds = <String>{
      ..._stages.map(_catalogId),
      ...stagesToCache.map(_catalogId),
    }.where((id) => id.isNotEmpty).toList();

    final cachedRoomsByStage = <String, List<Map<String, dynamic>>>{};
    final cachedDetailsByStage = <String, Map<String, dynamic>>{};

    if (!mounted) return;
    setState(() {
      _statusText = 'جاري استيراد الشعب والمواد المرتبطة بالصفوف...';
      _progressValue = .50;
    });

    await _runConcurrent(allStageIds, (stageId) async {
      final results = await Future.wait([
        _safeGetDecoded(
          Uri.parse('https://emis.moedu.gov.iq/api/selectoption/getClassRooms?schoolId=${widget.schoolId}&stageId=$stageId'),
          debugLabel: 'شعب الصف $stageId',
        ),
        _safeGetDecoded(
          Uri.parse('https://emis.moedu.gov.iq/api/selectoption/getstagedetails/$stageId'),
          debugLabel: 'تفاصيل الصف $stageId',
        ),
        _safeGetDecoded(
          Uri.parse('https://emis.moedu.gov.iq/api/subject/getsubjectsselect?stageId=$stageId&schoolId=${widget.schoolId}'),
          debugLabel: 'مواد الصف $stageId',
        ),
      ]);

      cachedRoomsByStage[stageId] = _smartMaps(results[0]);
      final detailsMap = _smartExtractMap(results[1]);
      if (detailsMap.isNotEmpty) {
        cachedDetailsByStage[stageId] = detailsMap;
      }
      _subjectsByStage[stageId] = _smartMaps(results[2]);
    });

    AppCore.setAcademicStagesCache(
      stages: stagesToCache,
      roomsByStage: cachedRoomsByStage,
      detailsByStage: cachedDetailsByStage,
    );

    final subjectKeys = <String>[];
    for (final entry in _subjectsByStage.entries) {
      for (final subject in entry.value) {
        final subjectId = _catalogId(subject);
        if (subjectId.isNotEmpty) {
          subjectKeys.add('${entry.key}:$subjectId');
        }
      }
    }

    if (subjectKeys.isEmpty) return;

    if (!mounted) return;
    setState(() {
      _statusText = 'جاري استيراد الفصول الدراسية من EMIS...';
      _progressValue = .56;
    });

    int completedExams = 0;
    await _runConcurrent(subjectKeys, (key) async {
      final parts = key.split(':');
      if (parts.length != 2) return;
      final stageId = parts[0];
      final subjectId = parts[1];

      final decoded = await _safeGetDecoded(
        Uri.parse('https://emis.moedu.gov.iq/api/examscore/getexamsformarks?schoolId=${widget.schoolId}&stageId=$stageId&subjectId=$subjectId'),
        debugLabel: 'امتحانات $key',
      );

      final rawExams = (decoded is Map && decoded['exams'] != null) ? decoded['exams'] : decoded;
      _examsBySubject[key] = _smartMaps(rawExams);

      completedExams++;
      if (mounted && subjectKeys.isNotEmpty) {
        setState(() {
          _progressValue = .56 + (.06 * (completedExams / subjectKeys.length));
            });
      }
    });
  }

  Future<void> _startFetchingData() async {
    try {
      _hasTriedRefreshOn403 = false;

      if (!mounted) return;
      setState(() {
        _statusText = 'جاري جلب بيانات المستخدم...';
        _progressValue = .20;
        });
      final userDecoded = await _safeGetDecoded(
        Uri.parse('https://emis.moedu.gov.iq/api/account/getloggedinuser'),
        debugLabel: 'بيانات المستخدم',
      );
      final userData = _smartExtractMap(userDecoded);
      final realUserName = _resolveUserName(userData);

      if (!mounted) return;
      setState(() {
        _statusText = 'جاري جلب بيانات المدرسة...';
        _progressValue = .38;
        });
      String schoolName = 'المدرسة';
      final schoolDecoded = await _safeGetDecoded(
        Uri.parse('https://emis.moedu.gov.iq/api/school/getschoolinformation/${widget.schoolId}'),
        debugLabel: 'بيانات المدرسة',
      );
      final schoolData = _smartExtractMap(schoolDecoded);
      final extractedSchoolName = (schoolData['schoolName'] ?? schoolData['name'] ?? schoolData['entityName'] ?? schoolData['title'] ?? '').toString().trim();
      if (extractedSchoolName.isNotEmpty) schoolName = extractedSchoolName;

      await _loadAcademicCatalog();

      if (!mounted) return;
      setState(() {
        _statusText = 'جاري تحميل سجلات الطلاب...';
        _progressValue = .72;
        });
      final studentsDecoded = await _safeGetDecoded(
        Uri.parse('https://emis.moedu.gov.iq/api/student/getstudents?page=1&rowsPerPage=3000&sortBy=id&sortOrder=desc&entityId=${widget.schoolId}'),
        debugLabel: 'سجلات الطلاب',
      );
      final studentsData = _smartExtractList(studentsDecoded);

      if (!mounted) return;
      setState(() {
        _statusText = 'جاري تحميل سجلات المعلمين...';
        _progressValue = .88;
        });
      final teachersDecoded = await _safeGetDecoded(
        Uri.parse('https://emis.moedu.gov.iq/api/employee/getemployeesbyentities?page=1&rowsPerPage=1000&sortBy=id&sortOrder=desc&entityId=${widget.schoolId}&isTeacher=true'),
        debugLabel: 'سجلات المعلمين',
      );
      final teachersData = _smartExtractList(teachersDecoded);

      if (!mounted) return;
      setState(() {
        _statusText = 'اكتملت المزامنة — تم الوصول بنجاح!';
        _progressValue = 1.0;
      });
      
      // مهلة قصيرة لعرض لقطة الفرح ووصول الطالب إلى نهاية الكلمة قبل الانتقال
      await Future<void>.delayed(const Duration(milliseconds: 1200));

      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => DashboardScreen(
            token: _headers['Authorization']!,
            schoolId: widget.schoolId,
            schoolName: schoolName,
            userName: realUserName,
            allStudents: studentsData,
            allTeachers: teachersData,
            stages: _stages,
            subjectsByStage: _subjectsByStage,
            examsBySubject: _examsBySubject,
          ),
        ),
      );
    } on _SessionExpired {
      if (!mounted) return;
      setState(() {
        _statusText = 'انتهت جلسة EMIS. إعادة فتح جلسة الدخول...';
        _progressValue = .12;
      });
      await Future<void>.delayed(const Duration(milliseconds: 700));
      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const EmisWebviewScreen()),
      );
    } catch (e) {
      debugPrint('EMIS fatal loading error: $e');
      if (!mounted) return;
      setState(() {
        _statusText = 'تعذر تحميل بيانات المدرسة. أعد المحاولة.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    bool isCompleted = _progressValue >= 1.0;

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF1A237E), Color(0xFF283593), Color(0xFF42A5F5), Color(0xFF81C784)],
            stops: [0.0, 0.35, 0.7, 1.0],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 20),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // Lottie animation supplied by the user.
                  SizedBox(
                    height: 220,
                    width: double.infinity,
                    child: Lottie.asset(
                      'assets/animations/emis_assistant_workplace.json',
                      fit: BoxFit.contain,
                      repeat: !isCompleted,
                      animate: true,
                    ),
                  ),
                  const SizedBox(height: 5),
                  const Text(
                    'مساعد EMIS الذكي',
                    style: TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.w900),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'مساعد الإدارة المدرسية',
                    style: TextStyle(color: Colors.white70, fontSize: 14),
                  ),
                  const SizedBox(height: 24),
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(.15),
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(color: Colors.white24),
                    ),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.sync_rounded, color: Colors.white, size: 22),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                _statusText,
                                textAlign: TextAlign.right,
                                style: const TextStyle(color: Colors.white, fontSize: 14, height: 1.4, fontWeight: FontWeight.w600),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: LinearProgressIndicator(
                            value: _progressValue,
                            minHeight: 9,
                            backgroundColor: Colors.white24,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              isCompleted ? Colors.greenAccent : Colors.amberAccent,
                            ),
                          ),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          '${(_progressValue * 100).round()}%',
                          style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
