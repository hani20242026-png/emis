import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'app_core.dart';
import 'employment_status_options.dart';
import 'emis_options.dart';
import 'employee_smart_tools_screen.dart';
import 'edit_employee_screen.dart';
import 'add_employee_screen.dart';

class EmployeesListScreen extends StatefulWidget {
  final String token;
  final String schoolId;
  final List<dynamic> initialEmployees;

  const EmployeesListScreen({
    super.key,
    required this.token,
    required this.schoolId,
    required this.initialEmployees,
  });

  @override
  State<EmployeesListScreen> createState() => _EmployeesListScreenState();
}

class _EmployeesListScreenState extends State<EmployeesListScreen>
    with SingleTickerProviderStateMixin {
  List<Map<String, dynamic>> _employees = [];
  final Map<String, String> _imageCache = <String, String>{};
  final Map<String, String> _phoneCache = <String, String>{};
  final Set<String> _fetchingIds = <String>{};

  bool _loading = true;
  bool _loadingImages = false;
  int _imagesLoadedCount = 0;
  int _imagesTotalToLoad = 0;
  bool _disposed = false;
  int _scanGeneration = 0;

  String _query = '';
  int _totalActive = 0;
  int _permanent = 0;
  int _contract = 0;
  String? _error;

  // خيارات الحالة الوظيفية الديناميكية المحدثة من السيرفر
  List<dynamic> _dynamicStatusOptions = [];
  static const String _statusOptionsCacheKey = 'employment_status_options_v1';

  late final AnimationController _ambientController;

  String get _imageCacheStorageKey =>
      'emis_employee_images_cache_${widget.schoolId}';

  String get _phoneCacheStorageKey =>
      'emis_employee_phone_cache_${widget.schoolId}';

  Map<String, String> get _headers => {
        'Authorization': widget.token,
        'Accept': 'application/json',
      };

  @override
  void initState() {
    super.initState();
    _ambientController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 6),
    )..repeat();

    _employees = widget.initialEmployees
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
      
    _initAndLoad();
  }

  @override
  void dispose() {
    _disposed = true;
    _scanGeneration++;
    _ambientController.dispose();
    super.dispose();
  }

  Future<void> _restoreStatusOptionsCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_statusOptionsCacheKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      final cached = <Map<String, dynamic>>[];
      for (final item in decoded) {
        if (item is Map) {
          cached.add(Map<String, dynamic>.from(item));
        }
      }
      if (cached.isNotEmpty) {
        if (mounted) {
          setState(() => _dynamicStatusOptions = cached);
        } else {
          _dynamicStatusOptions = cached;
        }
      }
    } catch (e) {
      debugPrint('تعذر استرجاع خيارات الحالة المخزنة: $e');
    }
  }

  Future<void> _initAndLoad() async {
    await _restoreCaches();
    // عرض آخر قائمة حالات تمت مزامنتها فوراً (تُستبدل بالكامل عند نجاح الجلب من EMIS).
    await _restoreStatusOptionsCache();
    // لا نستعيد أي خيارات محفوظة؛ نختبر جلب القائمة الحالية مباشرة من EMIS.
    await _loadStatusOptionsFromEmis();
    await _loadEmployees();
  }

  // جلب خيارات الحالة الوظيفية من سيرفر EMIS مباشرة (بدون أي قائمة ثابتة).
  // تعيد true فقط إذا نجحت المزامنة الفعلية مع EMIS.
  Future<bool> _loadStatusOptionsFromEmis() async {
    // لا نمسح القائمة قبل نجاح الطلب: الفشل المؤقت (مهلة/شبكة) كان يُفرغ القائمة فيستحيل
    // اختيار أي حالة، ويجعل رسالة "عرض آخر خيارات تمت مزامنتها" غير قابلة للوصول أصلاً.
    // النجاح يستبدل القائمة كلياً (بما فيه القائمة الفارغة الصريحة) دون أي قيم قديمة.
    for (var attempt = 1; attempt <= 3; attempt++) {
      try {
        final response = await http.get(
          Uri.parse('https://emis.moedu.gov.iq/api/employee/getemployeesoptions'),
          headers: {..._headers, 'Cache-Control': 'no-cache', 'Pragma': 'no-cache'},
        ).timeout(const Duration(seconds: 20));
        if (response.statusCode == 200) {
          final decoded = jsonDecode(utf8.decode(response.bodyBytes));
          final parsed = EmisEmploymentStatusOptions.extract(decoded);
          if (parsed == null) {
            debugPrint(
              'EMIS getemployeesoptions: currentemploymentstatus key missing '
              '(keys: ${decoded is Map ? decoded.keys.join(', ') : decoded.runtimeType})',
            );
            return false;
          }
          debugPrint('EMIS currentemploymentstatus: ${parsed.length} option(s) loaded');
          if (mounted) {
            setState(() => _dynamicStatusOptions = parsed);
          } else {
            _dynamicStatusOptions = parsed;
          }
          try {
            final prefs = await SharedPreferences.getInstance();
            if (parsed.isEmpty) {
              await prefs.remove(_statusOptionsCacheKey);
            } else {
              await prefs.setString(_statusOptionsCacheKey, jsonEncode(parsed));
            }
          } catch (_) {}
          return true;
        }
        debugPrint('EMIS getemployeesoptions: HTTP ${response.statusCode} (attempt $attempt)');
        // توكن منتهٍ/ممنوع: إعادة المحاولة لا تفيد.
        if (response.statusCode == 401 || response.statusCode == 403) return false;
      } catch (e) {
        debugPrint('تعذر تحديث خيارات الحالة الوظيفية من EMIS (محاولة $attempt): $e');
      }
      await Future<void>.delayed(Duration(milliseconds: 500 * attempt));
    }
    return false;
  }
  Future<void> _restoreCaches() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      
      final rawImg = prefs.getString(_imageCacheStorageKey);
      if (rawImg != null && rawImg.isNotEmpty) {
        final decoded = jsonDecode(rawImg);
        if (decoded is Map) {
          decoded.forEach((k, v) {
            final key = k.toString().trim();
            final val = v?.toString().trim() ?? '';
            if (key.isNotEmpty && val.isNotEmpty) {
              _imageCache[key] = val;
            }
          });
        }
      }

      final rawPhone = prefs.getString(_phoneCacheStorageKey);
      if (rawPhone != null && rawPhone.isNotEmpty) {
        final decodedPhone = jsonDecode(rawPhone);
        if (decodedPhone is Map) {
          decodedPhone.forEach((k, v) {
            final key = k.toString().trim();
            final val = v?.toString().trim() ?? '';
            if (key.isNotEmpty && val.isNotEmpty) {
              _phoneCache[key] = val;
            }
          });
        }
      }

      _applyCachedDataToEmployees();
      if (mounted) setState(() {});
    } catch (_) {}
  }

  Future<void> _persistCaches() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_imageCacheStorageKey, jsonEncode(_imageCache));
      await prefs.setString(_phoneCacheStorageKey, jsonEncode(_phoneCache));
    } catch (_) {}
  }

  void _applyCachedDataToEmployees() {
    for (final t in _employees) {
      final id = '${t['id'] ?? ''}'.trim();
      if (id.isEmpty) continue;

      if (_imageCache.containsKey(id)) {
        final cached = _imageCache[id]!;
        if (cached.isNotEmpty && cached != '-') {
          final currentImg = t['imageUrl']?.toString().trim() ?? '';
          if (currentImg.isEmpty || currentImg == 'null') {
            t['imageUrl'] = cached;
          }
        }
      }

      if (_phoneCache.containsKey(id)) {
        final cachedPhone = _phoneCache[id]!;
        if (cachedPhone.isNotEmpty && cachedPhone != '-') {
          final currentPhone = t['mobilePhoneNumber']?.toString().trim() ?? '';
          if (currentPhone.isEmpty || currentPhone == 'null') {
            t['mobilePhoneNumber'] = cachedPhone;
          }
        }
      }
    }
  }

  String _extractImageFromMap(Map<String, dynamic> t) {
    final candidates = <dynamic>[
      t['imageUrl'],
      t['ImageUrl'],
      t['avatarUrl'],
      t['photoUrl'],
      t['image'],
      t['photo'],
    ];
    for (final value in candidates) {
      final img = value?.toString().trim() ?? '';
      if (img.isNotEmpty && img != 'null') return img;
    }
    return '';
  }

  String _extractPhoneFromMap(Map<String, dynamic> t) {
    final candidates = <dynamic>[
      t['mobilePhoneNumber'],
      t['MobilePhoneNumber'],
      t['phoneNumber'],
      t['phone'],
      t['homePhoneNumber'],
    ];
    for (final value in candidates) {
      final p = value?.toString().trim() ?? '';
      if (p.isNotEmpty && p != 'null') return p;
    }
    final address = t['address'];
    if (address is Map) {
      final p = address['mobilePhoneNumber']?.toString().trim() ??
          address['MobilePhoneNumber']?.toString().trim() ?? '';
      if (p.isNotEmpty && p != 'null') return p;
    }
    return '';
  }

  String _employeeImageUrl(Map<String, dynamic> t) {
    String raw = _extractImageFromMap(t);
    if (raw.isEmpty) {
      final id = '${t['id'] ?? ''}'.trim();
      if (id.isNotEmpty && _imageCache.containsKey(id)) {
        final cached = _imageCache[id]!;
        if (cached != '-') raw = cached;
      }
    }
    if (raw.isEmpty || raw == '-' || raw == 'null') return '';
    if (!raw.startsWith('http')) {
      if (!raw.startsWith('/')) raw = '/$raw';
      return 'https://emis.moedu.gov.iq$raw';
    }
    return raw;
  }

  String _employeePhone(Map<String, dynamic> t) {
    String raw = _extractPhoneFromMap(t);
    if (raw.isEmpty) {
      final id = '${t['id'] ?? ''}'.trim();
      if (id.isNotEmpty && _phoneCache.containsKey(id)) {
        final cached = _phoneCache[id]!;
        if (cached != '-') raw = cached;
      }
    }
    return raw;
  }

  Future<Map<String, dynamic>> _fetchSingleEmployeeDetails(String id) async {
    try {
      final response = await http
          .get(
            Uri.parse('https://emis.moedu.gov.iq/api/employee/getemployee/$id'),
            headers: _headers,
          )
          .timeout(const Duration(seconds: 12));

      if (response.statusCode != 200) return {};
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      final data =
          decoded is Map && decoded['data'] != null ? decoded['data'] : decoded;
      if (data is Map) {
        final fullMap = data.map((k, v) => MapEntry(k.toString(), v));
        final img = _extractImageFromMap(fullMap);
        final phone = _extractPhoneFromMap(fullMap);
        return {
          'imageUrl': img.isEmpty ? '-' : img,
          'phone': phone.isEmpty ? '-' : phone,
        };
      }
    } catch (_) {}
    return {};
  }

  Future<void> _fetchMissingDetailsConcurrently({
    bool forceRefreshAll = false,
  }) async {
    final currentGen = ++_scanGeneration;

    if (forceRefreshAll) {
      _imageCache.clear();
      _phoneCache.clear();
    }

    final filteredIds = _filteredEmployees
        .map((t) => '${t['id'] ?? ''}'.trim())
        .where((id) => id.isNotEmpty)
        .toSet();

    final pendingEmployees = [];
    for (final t in _employees) {
      final id = '${t['id'] ?? ''}'.trim();
      if (id.isEmpty) continue;

      final directImg = _extractImageFromMap(t);
      if (directImg.isNotEmpty) _imageCache[id] = directImg;

      final directPhone = _extractPhoneFromMap(t);
      if (directPhone.isNotEmpty) _phoneCache[id] = directPhone;

      if (!_imageCache.containsKey(id) || !_phoneCache.containsKey(id)) {
        pendingEmployees.add(t);
      }
    }

    pendingEmployees.sort((a, b) {
      final aInView = filteredIds.contains('${a['id'] ?? ''}') ? 0 : 1;
      final bInView = filteredIds.contains('${b['id'] ?? ''}') ? 0 : 1;
      return aInView.compareTo(bInView);
    });

    if (pendingEmployees.isEmpty) {
      if (mounted) {
        setState(() => _loadingImages = false);
      }
      return;
    }

    if (mounted) {
      setState(() {
        _loadingImages = true;
        _imagesLoadedCount = 0;
        _imagesTotalToLoad = pendingEmployees.length;
      });
    }

    await AppCore.initPreferences();
    final fastQueueEnabled = AppCore.prefs.getBool('fast_processing_queue_enabled') ?? true;

    final int concurrency = fastQueueEnabled ? 3 : 6;
    int nextIndex = 0;
    int completed = 0;

    Future<void> worker() async {
      while (!_disposed && currentGen == _scanGeneration) {
        final idx = nextIndex++;
        if (idx >= pendingEmployees.length) return;

        final employee = pendingEmployees[idx];
        final id = '${employee['id'] ?? ''}'.trim();
        if (id.isEmpty || _fetchingIds.contains(id)) continue;

        _fetchingIds.add(id);
        try {
          final details = await _fetchSingleEmployeeDetails(id);
          if (_disposed || currentGen != _scanGeneration) return;

          final imgResult = details['imageUrl'];
          if (imgResult != null) {
            _imageCache[id] = imgResult;
            if (imgResult != '-') employee['imageUrl'] = imgResult;
          }

          final phoneResult = details['phone'];
          if (phoneResult != null) {
            _phoneCache[id] = phoneResult;
            if (phoneResult != '-') employee['mobilePhoneNumber'] = phoneResult;
          }
        } finally {
          _fetchingIds.remove(id);
          completed++;
          if (fastQueueEnabled) {
            await Future.delayed(const Duration(milliseconds: 100));
          }
          if (!_disposed &&
              currentGen == _scanGeneration &&
              mounted &&
              (completed % 4 == 0 || completed == pendingEmployees.length)) {
            setState(() {
              _imagesLoadedCount = completed;
            });
            unawaited(_persistCaches());
          }
        }
      }
    }

    final workersCount = pendingEmployees.length < concurrency
        ? pendingEmployees.length
        : concurrency;
    await Future.wait(List.generate(workersCount, (_) => worker()));

    if (!_disposed && currentGen == _scanGeneration) {
      await _persistCaches();
      if (mounted) {
        setState(() => _loadingImages = false);
      }
    }
  }

  Future<void> _openAddEmployee() async {
    final added = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => AddEmployeeScreen(
          token: widget.token,
          schoolId: widget.schoolId,
        ),
      ),
    );
    if (added == true && mounted) {
      await _loadEmployees();
    }
  }

  Future<void> _loadEmployees() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }

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
        http.get(uri, headers: _headers),
        http.get(summaryUri, headers: _headers),
      ]);

      final listResponse = results[0];
      final summaryResponse = results[1];

      if (listResponse.statusCode != 200) {
        throw Exception('HTTP ${listResponse.statusCode}');
      }

      final decoded = jsonDecode(utf8.decode(listResponse.bodyBytes));
      final data = decoded is Map ? decoded['data'] : null;
      final List<Map<String, dynamic>> employees = data is List
          ? data
              .whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e))
              .toList()
          : <Map<String, dynamic>>[];

      if (summaryResponse.statusCode == 200) {
        final summary = jsonDecode(utf8.decode(summaryResponse.bodyBytes));
        _totalActive = _asInt(summary['totalActive']);
        _permanent = _asInt(summary['permanent']);
        _contract = _asInt(summary['contract']);
      }

      if (!mounted) return;
      setState(() {
        _employees = employees;
        _applyCachedDataToEmployees();
        _loading = false;
      });

      unawaited(_fetchMissingDetailsConcurrently());
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'تعذر تحميل بيانات الموظفين: $e';
      });
    }
  }

  int _asInt(dynamic value) =>
      value is num ? value.toInt() : int.tryParse('$value') ?? 0;

  List<Map<String, dynamic>> get _filteredEmployees {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return _employees;
    return _employees.where((employee) {
      final values = [
        employee['employeeFullName'],
        employee['nationalIdNumber'],
        employee['employeeIdNumber'],
        employee['classification'],
        employee['employmentType'],
        employee['currentEmploymentStatus'],
        _employeePhone(employee),
      ];
      return values.any((v) => '$v'.toLowerCase().contains(q));
    }).toList();
  }

  String _value(Map<String, dynamic> x) =>
      '${x['value'] ?? x['id'] ?? x['code'] ?? ''}'.trim();

  String _text(Map<String, dynamic> x) =>
      '${x['displayName'] ?? x['label'] ?? x['name'] ?? x['text'] ?? _value(x)}'
          .trim();

  Future<void> _updateEmployeeStatus(Map<String, dynamic> employee) async {
    final employeeId = employee['id'];
    if (employeeId == null || '$employeeId'.trim().isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تعذر تحديد رقم الموظف.')),
      );
      return;
    }

    // مزامنة أحدث الخيارات من EMIS قبل فتح النافذة
    final synced = await _loadStatusOptionsFromEmis();
    if (!mounted) return;

    if (_dynamicStatusOptions.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'تعذر جلب خيارات الحالة الوظيفية من EMIS. تحقق من الاتصال وحاول مرة أخرى.',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          backgroundColor: Color(0xFFEF4444),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    if (!synced) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'تعذرت المزامنة الآن، تم عرض آخر خيارات تمت مزامنتها من EMIS.',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }

    // الحالة الحالية للموظف؛ إن لم تكن ضمن خيارات EMIS الحالية يُترك الاختيار فارغاً ليختار المستخدم صراحةً
    final validOptionValues =
        _dynamicStatusOptions.map((o) => _value(o)).toList();
    final currentStatusRaw =
        '${employee['currentEmploymentStatus'] ?? ''}'.trim();
    String? selectedStatus;
    if (validOptionValues.contains(currentStatusRaw)) {
      selectedStatus = currentStatusRaw;
    } else {
      // مطابقة الحالة الحالية بالنص المعروض أيضاً بعد توحيد الهمزات والتاء المربوطة.
      final wanted = EmisOptions.norm(currentStatusRaw);
      for (final option in _dynamicStatusOptions) {
        if (EmisOptions.norm(_value(option)) == wanted ||
            EmisOptions.norm(_text(option)) == wanted) {
          selectedStatus = _value(option);
          break;
        }
      }
    }

    final documentController = TextEditingController();
    final reasonController = TextEditingController();
    bool saving = false;
    String? dialogError;
    final isDark = AppCore.themeNotifier.value == ThemeMode.dark;

    try {
      final result = await showDialog<bool>(
        context: context,
        barrierDismissible: !saving,
        builder: (dialogContext) {
          return StatefulBuilder(
            builder: (context, setDialogState) {
              Future<void> save() async {
                final reason = reasonController.text.trim();
                if (selectedStatus == null) {
                  setDialogState(() {
                    dialogError = 'يرجى اختيار الحالة الوظيفية.';
                  });
                  return;
                }
                setDialogState(() {
                  saving = true;
                  dialogError = null;
                });

                try {
                  final uri = Uri.parse(
                    'https://emis.moedu.gov.iq/api/employee/updateemploymentstatus',
                  );
                  final body = <String, dynamic>{
                    'employeeId': employeeId is num
                        ? employeeId
                        : int.tryParse('$employeeId') ?? employeeId,
                    'statusType': selectedStatus,
                    'ministryOfficialDocumentNumber':
                        documentController.text.trim().isEmpty
                            ? null
                            : documentController.text.trim(),
                    'reason': reason.isEmpty ? null : reason,
                    'assignedEntityName': null,
                  };

                  final response = await http.post(
                    uri,
                    headers: {
                      ..._headers,
                      'Content-Type': 'application/json',
                    },
                    body: jsonEncode(body),
                  );

                  if (response.statusCode < 200 ||
                      response.statusCode >= 300) {
                    String details = utf8.decode(response.bodyBytes).trim();
                    if (details.isEmpty) {
                      details = 'HTTP ${response.statusCode}';
                    }
                    throw Exception(details);
                  }

                  if (!mounted) return;
                  Navigator.of(dialogContext).pop(true);
                } catch (e) {
                  setDialogState(() {
                    saving = false;
                    dialogError = 'فشل تحديث حالة الموظف: $e';
                  });
                }
              }

              return Directionality(
                textDirection: TextDirection.rtl,
                child: AlertDialog(
                  backgroundColor:
                      isDark ? const Color(0xFF141829) : const Color(0xFFFFFFFF),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(24),
                    side: BorderSide(
                      color: const Color(0xFFF59E0B).withOpacity(0.45),
                      width: 1.5,
                    ),
                  ),
                  title: Text(
                    'تحديث حالة الموظف',
                    style: TextStyle(
                      color: isDark ? Colors.white : const Color(0xFF0F172A),
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  content: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // القائمة المنسدلة مبنية بالكامل من خيارات EMIS الحالية
                        DropdownButtonFormField<String>(
                          isExpanded: true,
                          value: _dynamicStatusOptions
                                  .any((o) => _value(o) == selectedStatus)
                              ? selectedStatus
                              : null,
                          dropdownColor:
                              isDark ? const Color(0xFF181D32) : Colors.white,
                          decoration: InputDecoration(
                            labelText: 'الحالة الوظيفية',
                            labelStyle: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 12.5,
                              color: isDark
                                  ? const Color(0xFF94A3B8)
                                  : const Color(0xFF475569),
                            ),
                            filled: true,
                            fillColor: isDark
                                ? const Color(0xFF0B0E1A).withOpacity(0.68)
                                : const Color(0xFFF1F5F9),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                          items: _dynamicStatusOptions
                              .map(
                                (option) => DropdownMenuItem<String>(
                                  value: _value(option),
                                  child: Text(_text(option),
                                      style: TextStyle(
                                          fontWeight: FontWeight.w800,
                                          color: isDark
                                              ? Colors.white
                                              : const Color(0xFF0F172A))),
                                ),
                              )
                              .toList(),
                          onChanged: saving
                              ? null
                              : (value) {
                                  if (value == null) return;
                                  setDialogState(() {
                                    selectedStatus = value;
                                  });
                                },
                        ),
                        const SizedBox(height: 14),
                        TextField(
                          controller: documentController,
                          enabled: !saving,
                          style: TextStyle(
                              fontWeight: FontWeight.w800,
                              color: isDark
                                  ? Colors.white
                                  : const Color(0xFF0F172A)),
                          decoration: InputDecoration(
                            labelText: 'رقم الأمر الإداري / الوثيقة',
                            labelStyle: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 12.5,
                              color: isDark
                                  ? const Color(0xFF94A3B8)
                                  : const Color(0xFF475569),
                            ),
                            filled: true,
                            fillColor: isDark
                                ? const Color(0xFF0B0E1A).withOpacity(0.68)
                                : const Color(0xFFF1F5F9),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                        ),
                        const SizedBox(height: 14),
                        TextField(
                          controller: reasonController,
                          enabled: !saving,
                          maxLines: 3,
                          style: TextStyle(
                              fontWeight: FontWeight.w800,
                              color: isDark
                                  ? Colors.white
                                  : const Color(0xFF0F172A)),
                          decoration: InputDecoration(
                            labelText: 'سبب تغيير الحالة الوظيفية',
                            labelStyle: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 12.5,
                              color: isDark
                                  ? const Color(0xFF94A3B8)
                                  : const Color(0xFF475569),
                            ),
                            filled: true,
                            fillColor: isDark
                                ? const Color(0xFF0B0E1A).withOpacity(0.68)
                                : const Color(0xFFF1F5F9),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                        ),
                        if (dialogError != null) ...[
                          const SizedBox(height: 12),
                          Text(
                            dialogError!,
                            style: const TextStyle(
                              fontWeight: FontWeight.w900,
                              color: Color(0xFFEF4444),
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ],
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: saving
                          ? null
                          : () => Navigator.of(dialogContext).pop(false),
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
                    FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFFF59E0B),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      onPressed: saving ? null : save,
                      icon: saving
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white),
                            )
                          : const Icon(Icons.save_outlined, size: 18),
                      label: const Text('حفظ',
                          style: TextStyle(fontWeight: FontWeight.bold)),
                    ),
                  ],
                ),
              );
            },
          );
        },
      );

      if (result == true) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'تم تحديث حالة الموظف بنجاح.',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            backgroundColor: Color(0xFF10B981),
            behavior: SnackBarBehavior.floating,
          ),
        );
        await _loadEmployees();
      }
    } finally {
      documentController.dispose();
      reasonController.dispose();
    }
  }

  void _previewEmployeeImage(String imageUrl, String employeeName) {
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: Container(
                color: Colors.white,
                constraints:
                    const BoxConstraints(maxHeight: 380, maxWidth: 320),
                child: InteractiveViewer(
                  child: Image.network(
                    imageUrl,
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
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.black87,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                employeeName,
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

  Future<void> _openEditEmployee(String employeeId) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => EditEmployeeScreen(
          token: widget.token,
          schoolId: widget.schoolId,
          employeeId: employeeId,
        ),
      ),
    );
    _imageCache.remove(employeeId);
    _phoneCache.remove(employeeId);
    await _loadEmployees();
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
              _AnimatedEmployeeListOrbIcon(
                icon: Icons.badge_rounded,
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
                      'نظام إدارة المدرسة',
                      style: TextStyle(
                        color: isDark ? goldNeon : purpleNeon,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'إدارة الموظفين',
                      style: TextStyle(
                        color: isDark ? Colors.white : const Color(0xFF0F172A),
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'عرض وتعديل وتحديث حالة كادر التدريس في EMIS',
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
      builder: (context, mode, child) {
        final isDark = mode == ThemeMode.dark;
        final bg = isDark ? const Color(0xFF070913) : const Color(0xFFF2F5FA);
        final card = isDark ? const Color(0xFF141829) : Colors.white;
        final text = isDark ? Colors.white : const Color(0xFF0F172A);

        const purpleNeon = Color(0xFFA855F7);
        const emeraldNeon = Color(0xFF10B981);
        const goldNeon = Color(0xFFF59E0B);
        const blueNeon = Color(0xFF3B82F6);

        return Directionality(
          textDirection: TextDirection.rtl,
          child: Scaffold(
            backgroundColor: bg,
            appBar: null,
            floatingActionButton: FloatingActionButton.extended(
              onPressed: _openAddEmployee,
              backgroundColor: purpleNeon,
              icon: const Icon(Icons.person_add_alt_1_rounded, color: Colors.white),
              label: const Text(
                'إضافة موظف جديد',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900),
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
                  child: RefreshIndicator(
                    onRefresh: _loadEmployees,
                    color: purpleNeon,
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 85),
                      physics: const AlwaysScrollableScrollPhysics(
                        parent: BouncingScrollPhysics(),
                      ),
                      children: [
                        _buildTopHeader(isDark),
                        const SizedBox(height: 14),
                        _buildSummary(card, text, isDark),
                        if (_loadingImages) ...[
                          const SizedBox(height: 10),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 10),
                            decoration: BoxDecoration(
                              color: card,
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: purpleNeon.withOpacity(0.35),
                              ),
                            ),
                            child: Row(
                              children: [
                                const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2, color: purpleNeon),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    'جلب تفاصيل الموظفين: $_imagesLoadedCount / $_imagesTotalToLoad',
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w800,
                                      color: isDark
                                          ? const Color(0xFF6EE7B7)
                                          : purpleNeon,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                        const SizedBox(height: 14),

                        Container(
                          decoration: BoxDecoration(
                            gradient: AppCore.isWindows ? null : isDark
                                ? LinearGradient(
                                    begin: Alignment.topLeft,
                                    end: Alignment.bottomRight,
                                    colors: [
                                      const Color(0xFF141829).withOpacity(0.95),
                                      Color.lerp(const Color(0xFF0F1322),
                                          purpleNeon, 0.08)!,
                                    ],
                                  )
                                : LinearGradient(
                                    begin: Alignment.topLeft,
                                    end: Alignment.bottomRight,
                                    colors: [
                                      Colors.white.withOpacity(0.96),
                                      Color.lerp(const Color(0xFFF8FAFC),
                                          purpleNeon, 0.04)!,
                                    ],
                                  ),
                            color: AppCore.isWindows ? AppCore.windowsGradientFallback(isDark
                                ? LinearGradient(
                                    begin: Alignment.topLeft,
                                    end: Alignment.bottomRight,
                                    colors: [
                                      const Color(0xFF141829).withOpacity(0.95),
                                      Color.lerp(const Color(0xFF0F1322),
                                          purpleNeon, 0.08)!,
                                    ],
                                  )
                                : LinearGradient(
                                    begin: Alignment.topLeft,
                                    end: Alignment.bottomRight,
                                    colors: [
                                      Colors.white.withOpacity(0.96),
                                      Color.lerp(const Color(0xFFF8FAFC),
                                          purpleNeon, 0.04)!,
                                    ],
                                  )) : null,
                            borderRadius: BorderRadius.circular(22),
                            border: Border.all(
                              color:
                                  purpleNeon.withOpacity(isDark ? 0.45 : 0.30),
                              width: 1.3,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color:
                                    purpleNeon.withOpacity(isDark ? 0.12 : 0.07),
                                blurRadius: 18,
                                offset: const Offset(0, 6),
                              ),
                            ],
                          ),
                          child: Material(
                            color: Colors.transparent,
                            child: InkWell(
                              borderRadius: BorderRadius.circular(22),
                              onTap: () => Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => EmployeeSmartToolsScreen(
                                    token: widget.token,
                                    schoolId: widget.schoolId,
                                    allEmployees: _employees,
                                  ),
                                ),
                              ).then((_) => _loadEmployees()),
                              child: Padding(
                                padding: const EdgeInsets.all(16),
                                child: Row(
                                  children: [
                                    Container(
                                      width: 52,
                                      height: 52,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: purpleNeon.withOpacity(0.15),
                                        border: Border.all(
                                          color: purpleNeon.withOpacity(0.4),
                                          width: 1.2,
                                        ),
                                      ),
                                      child: const Icon(
                                        Icons.auto_awesome_rounded,
                                        color: purpleNeon,
                                        size: 26,
                                      ),
                                    ),
                                    const SizedBox(width: 14),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            'الأدوات الذكية للموظفين',
                                            style: TextStyle(
                                              fontWeight: FontWeight.w900,
                                              color: text,
                                              fontSize: 16,
                                            ),
                                          ),
                                          const SizedBox(height: 3),
                                          Text(
                                            'إضافة صور الموظفين جماعيًا مع حفظ سجل الجلسة',
                                            style: TextStyle(
                                              fontWeight: FontWeight.w700,
                                              color: isDark
                                                  ? const Color(0xFF94A3B8)
                                                  : const Color(0xFF64748B),
                                              fontSize: 11.5,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    Container(
                                      width: 36,
                                      height: 36,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: purpleNeon.withOpacity(0.12),
                                      ),
                                      child: const Icon(
                                        Icons.arrow_forward_ios_rounded,
                                        size: 16,
                                        color: purpleNeon,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 14),

                        TextField(
                          textDirection: TextDirection.rtl,
                          onChanged: (value) => setState(() => _query = value),
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                            color: text,
                            fontSize: 13.5,
                          ),
                          decoration: InputDecoration(
                            filled: true,
                            fillColor: isDark
                                ? const Color(0xFF0B0E1A).withOpacity(0.68)
                                : const Color(0xFFF1F5F9),
                            hintText:
                                'ابحث باسم الموظف، الاختصاص، الرقم الوظيفي، أو رقم الهاتف',
                            hintStyle: TextStyle(
                              color: isDark ? Colors.white38 : Colors.black38,
                              fontSize: 12,
                            ),
                            prefixIcon:
                                const Icon(Icons.search_rounded, color: purpleNeon),
                            suffixIcon: _query.isNotEmpty
                                ? IconButton(
                                    icon: const Icon(Icons.clear_rounded,
                                        size: 18),
                                    onPressed: () => setState(() => _query = ''),
                                  )
                                : null,
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(16),
                              borderSide: BorderSide(
                                color: purpleNeon.withOpacity(
                                    isDark ? 0.35 : 0.25),
                                width: 1.2,
                              ),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(16),
                              borderSide: BorderSide(
                                color: purpleNeon.withOpacity(
                                    isDark ? 0.35 : 0.25),
                                width: 1.2,
                              ),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(16),
                              borderSide: const BorderSide(color: purpleNeon, width: 1.8),
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),

                        if (_error != null)
                          _buildError(card, text, isDark)
                        else if (_loading && _employees.isEmpty)
                          const Padding(
                            padding: EdgeInsets.all(50),
                            child: Center(
                                child: CircularProgressIndicator(
                                    color: purpleNeon)),
                          )
                        else if (_filteredEmployees.isEmpty)
                          _buildEmpty(card, text, isDark)
                        else
                          ..._filteredEmployees.map((employee) =>
                              _buildEmployeeCard(employee, card, text, isDark)),
                      ],
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

  Widget _summaryCard(
    String title,
    String value,
    IconData icon,
    Color color,
    Color card,
    Color text,
    bool isDark,
  ) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
      decoration: BoxDecoration(
        gradient: AppCore.isWindows ? null : isDark
            ? LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  const Color(0xFF141829).withOpacity(0.95),
                  Color.lerp(const Color(0xFF0F1322), color, 0.08)!,
                ],
              )
            : LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Colors.white.withOpacity(0.96),
                  Color.lerp(const Color(0xFFF8FAFC), color, 0.04)!,
                ],
              ),
        color: AppCore.isWindows ? AppCore.windowsGradientFallback(isDark
            ? LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  const Color(0xFF141829).withOpacity(0.95),
                  Color.lerp(const Color(0xFF0F1322), color, 0.08)!,
                ],
              )
            : LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Colors.white.withOpacity(0.96),
                  Color.lerp(const Color(0xFFF8FAFC), color, 0.04)!,
                ],
              )) : null,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: color.withOpacity(isDark ? 0.45 : 0.30),
          width: 1.2,
        ),
        boxShadow: [
          BoxShadow(
            color: color.withOpacity(isDark ? 0.12 : 0.07),
            blurRadius: 16,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Column(
        children: [
          Icon(icon, color: color, size: 24),
          const SizedBox(height: 6),
          Text(
            value,
            style: TextStyle(
              fontSize: 21,
              fontWeight: FontWeight.w900,
              color: text,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            title,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 11.5,
              color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSummary(Color card, Color text, bool isDark) {
    return Row(
      children: [
        Expanded(
          child: _summaryCard(
            'الموظفون',
            '${_totalActive == 0 ? _employees.length : _totalActive}',
            Icons.people_rounded,
            const Color(0xFFA855F7),
            card,
            text,
            isDark,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _summaryCard(
            'ملاك',
            '$_permanent',
            Icons.badge_rounded,
            const Color(0xFF3B82F6),
            card,
            text,
            isDark,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _summaryCard(
            'عقد',
            '$_contract',
            Icons.assignment_ind_rounded,
            const Color(0xFFF59E0B),
            card,
            text,
            isDark,
          ),
        ),
      ],
    );
  }

  Widget _buildEmployeeAvatar(String imgUrl, String employeeName) {
    const fallbackIcon = Icon(
      Icons.person_rounded,
      color: Color(0xFFA855F7),
      size: 30,
    );

    return GestureDetector(
      onTap: imgUrl.isNotEmpty
          ? () => _previewEmployeeImage(imgUrl, employeeName)
          : null,
      child: Container(
        width: 56,
        height: 56,
        decoration: BoxDecoration(
          color: const Color(0xFFA855F7).withOpacity(0.15),
          shape: BoxShape.circle,
          border: Border.all(
            color: const Color(0xFFA855F7).withOpacity(0.5),
            width: 1.5,
          ),
        ),
        child: ClipOval(
          child: imgUrl.isNotEmpty
              ? Image.network(
                  imgUrl,
                  headers: {'Authorization': widget.token},
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stackTrace) =>
                      const Center(child: fallbackIcon),
                )
              : const Center(child: fallbackIcon),
        ),
      ),
    );
  }

  Widget _buildEmployeeCard(
    Map<String, dynamic> employee,
    Color card,
    Color text,
    bool isDark,
  ) {
    final name = '${employee['employeeFullName'] ?? 'بدون اسم'}';
    final specialization =
        '${employee['specialization'] ?? employee['Specialization'] ?? ''}';
    final employeeNo = '${employee['employeeIdNumber'] ?? ''}';
    final type = '${employee['employmentType'] ?? ''}';
    final classification = '${employee['classification'] ?? ''}';
    final status = '${employee['currentEmploymentStatus'] ?? 'غير محدد'}';
    final employeeId = '${employee['id'] ?? ''}';
    final imgUrl = _employeeImageUrl(employee);
    final phone = _employeePhone(employee);

    const purpleNeon = Color(0xFFA855F7);
    const blueNeon = Color(0xFF3B82F6);
    const tealNeon = Color(0xFF06B6D4);
    const emeraldNeon = Color(0xFF10B981);
    const goldNeon = Color(0xFFF59E0B);

    Widget infoRow({
      required IconData icon,
      required String label,
      required String value,
      required Color accent,
    }) {
      if (value.trim().isEmpty || value == '-') {
        return const SizedBox.shrink();
      }
      
      void copyToClipboard() {
        final isPhone = label.contains('رقم الهاتف');
        final isEmpNo = label.contains('الرقم الوظيفي');

        if (isPhone || isEmpNo) {
          Clipboard.setData(ClipboardData(text: value));
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                isPhone
                    ? 'تم نسخ رقم الهاتف ($value) إلى الحافظة'
                    : 'تم نسخ الرقم الوظيفي ($value) إلى الحافظة',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              backgroundColor: emeraldNeon,
              behavior: SnackBarBehavior.floating,
              duration: const Duration(seconds: 2),
            ),
          );
        }
      }

      final isInteractive = label.contains('رقم الهاتف') || label.contains('الرقم الوظيفي');

      return Container(
        margin: const EdgeInsets.only(top: 6),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: isInteractive ? copyToClipboard : null,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: accent.withOpacity(isDark ? 0.15 : 0.08),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                textDirection: TextDirection.rtl,
                children: [
                  Icon(icon, size: 16, color: accent),
                  const SizedBox(width: 6),
                  Text(
                    '$label:',
                    style: TextStyle(
                      color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerRight,
                        child: Text(
                          value,
                          maxLines: 1,
                          softWrap: false,
                          textDirection: TextDirection.ltr,
                          textAlign: TextAlign.right,
                          style: TextStyle(
                            color: isDark ? Colors.white : const Color(0xFF0F172A),
                            fontSize: 12,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (isInteractive) ...[
                    const SizedBox(width: 4),
                    Icon(Icons.copy_rounded, size: 14, color: accent.withOpacity(0.7)),
                  ],
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        gradient: AppCore.isWindows ? null : isDark
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
        color: AppCore.isWindows ? AppCore.windowsGradientFallback(isDark
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
              )) : null,
        borderRadius: BorderRadius.circular(24),
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
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          textDirection: TextDirection.rtl,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildEmployeeAvatar(imgUrl, name),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textDirection: TextDirection.rtl,
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      fontSize: 16,
                      height: 1.25,
                      fontWeight: FontWeight.w900,
                      color: text,
                    ),
                  ),
                  if (specialization.trim().isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      specialization,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textDirection: TextDirection.rtl,
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                  Wrap(
                    alignment: WrapAlignment.end,
                    spacing: 6,
                    runSpacing: 5,
                    children: [
                      if (classification.trim().isNotEmpty)
                        _chip(classification, purpleNeon),
                      if (type.trim().isNotEmpty) _chip(type, blueNeon),
                      _chip(
                        status,
                        status == 'مستمر' ? emeraldNeon : goldNeon,
                      ),
                    ],
                  ),
                  if (employeeNo.isNotEmpty)
                    infoRow(
                      icon: Icons.badge_rounded,
                      label: 'الرقم الوظيفي',
                      value: employeeNo,
                      accent: blueNeon,
                    ),
                  if (phone.isNotEmpty && phone != '-')
                    infoRow(
                      icon: Icons.phone_rounded,
                      label: 'رقم الهاتف',
                      value: phone,
                      accent: tealNeon,
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              children: [
                _employeeActionButton(
                  icon: Icons.sync_rounded,
                  tooltip: 'تحديث حالة الموظف',
                  color: goldNeon,
                  onPressed: () => _updateEmployeeStatus(employee),
                ),
                const SizedBox(height: 8),
                _employeeActionButton(
                  icon: Icons.edit_rounded,
                  tooltip: 'تعديل بيانات الموظف',
                  color: purpleNeon,
                  onPressed: () => _openEditEmployee(employeeId),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _employeeActionButton({
    required IconData icon,
    required String tooltip,
    required Color color,
    required VoidCallback onPressed,
  }) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onPressed,
          child: SizedBox(
            width: 38,
            height: 38,
            child: Icon(icon, color: color, size: 20),
          ),
        ),
      ),
    );
  }

  Widget _chip(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4.5),
      decoration: BoxDecoration(
        color: color.withOpacity(0.14),
        border: Border.all(color: color.withOpacity(0.35)),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11.5,
          color: color,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }

  Widget _buildError(Color card, Color text, bool isDark) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: card,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: const Color(0xFFEF4444).withOpacity(0.4)),
      ),
      child: Column(
        children: [
          const Icon(Icons.error_outline_rounded, color: Color(0xFFEF4444), size: 42),
          const SizedBox(height: 10),
          Text(
            _error!,
            style: TextStyle(fontWeight: FontWeight.w900, color: text),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 14),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFEF4444),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            onPressed: _loadEmployees,
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: const Text('إعادة المحاولة', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  Widget _buildEmpty(Color card, Color text, bool isDark) {
    final mutedColor = isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);
    return Container(
      padding: const EdgeInsets.all(35),
      decoration: BoxDecoration(
        color: card,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Colors.grey.withOpacity(0.2)),
      ),
      child: Column(
        children: [
          const Icon(Icons.people_outline_rounded, size: 55, color: Colors.grey),
          const SizedBox(height: 12),
          Text(
            _query.isEmpty
                ? 'لا توجد بيانات للموظفين'
                : 'لا توجد نتائج مطابقة للبحث',
            style: TextStyle(color: mutedColor, fontWeight: FontWeight.w900),
          ),
        ],
      ),
    );
  }
}

class _AnimatedEmployeeListOrbIcon extends StatelessWidget {
  final IconData icon;
  final Color primaryColor;
  final Color secondaryColor;
  final Animation<double> animation;
  final double size;

  const _AnimatedEmployeeListOrbIcon({
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
                  painter: _EmployeeListAtomOrbitPainter(
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

class _EmployeeListAtomOrbitPainter extends CustomPainter {
  final double progress;
  final Color primaryColor;
  final Color secondaryColor;

  _EmployeeListAtomOrbitPainter({
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
  bool shouldRepaint(covariant _EmployeeListAtomOrbitPainter oldDelegate) =>
      oldDelegate.progress != progress;
}
