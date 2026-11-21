import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'app_core.dart';
import 'edit_student_screen.dart';
import 'add_student_screen.dart';

class SelectStudentScreen extends StatefulWidget {
  final String token;
  final String schoolId;
  final List<dynamic> preLoadedStudents;

  const SelectStudentScreen({
    super.key,
    required this.token,
    required this.schoolId,
    required this.preLoadedStudents,
  });

  @override
  State<SelectStudentScreen> createState() => _SelectStudentScreenState();
}

class _SelectStudentScreenState extends State<SelectStudentScreen> {
  late List<Map<String, dynamic>> _allStudents;
  final Map<String, String> _phoneCache = <String, String>{};
  final Map<String, String> _genderCache = <String, String>{};
  final Map<String, String> _imageCache = <String, String>{};
  final Set<String> _fetchingIds = <String>{};

  String _query = '';
  String? _selectedStage;
  String? _selectedClassRoom;
  bool _loading = false;
  bool _loadingPhones = false;
  int _phonesLoadedCount = 0;
  int _phonesTotalToLoad = 0;
  bool _disposed = false;
  int _scanGeneration = 0;
  String? _error;

  String get _cacheStorageKey => 'emis_student_phones_cache_${widget.schoolId}';
  String get _genderCacheStorageKey => 'emis_student_genders_cache_${widget.schoolId}';
  String get _imageCacheStorageKey => 'emis_student_images_cache_${widget.schoolId}';

  Map<String, String> get _headers => {
        'Authorization': widget.token,
        'Accept': 'application/json',
      };

  @override
  void initState() {
    super.initState();
    _allStudents = widget.preLoadedStudents
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    _initAndLoad();
  }

  @override
  void dispose() {
    _disposed = true;
    _scanGeneration++;
    super.dispose();
  }

  Future<void> _initAndLoad() async {
    await _restoreCaches();
    await _loadStudents();
  }

  Future<void> _restoreCaches() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      final rawPhones = prefs.getString(_cacheStorageKey);
      if (rawPhones != null && rawPhones.isNotEmpty) {
        final decoded = jsonDecode(rawPhones);
        if (decoded is Map) {
          decoded.forEach((k, v) {
            final key = k.toString().trim();
            final val = v?.toString().trim() ?? '';
            if (key.isNotEmpty && val.isNotEmpty) {
              _phoneCache[key] = val;
            }
          });
        }
      }

      final rawGenders = prefs.getString(_genderCacheStorageKey);
      if (rawGenders != null && rawGenders.isNotEmpty) {
        final decoded = jsonDecode(rawGenders);
        if (decoded is Map) {
          decoded.forEach((k, v) {
            final key = k.toString().trim();
            final val = v?.toString().trim() ?? '';
            if (key.isNotEmpty && val.isNotEmpty) {
              _genderCache[key] = val;
            }
          });
        }
      }

      final rawImages = prefs.getString(_imageCacheStorageKey);
      if (rawImages != null && rawImages.isNotEmpty) {
        final decoded = jsonDecode(rawImages);
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

      _applyCachedDataToStudents();
      if (mounted) setState(() {});
    } catch (_) {}
  }

  Future<void> _persistCaches() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_cacheStorageKey, jsonEncode(_phoneCache));
      await prefs.setString(_genderCacheStorageKey, jsonEncode(_genderCache));
      await prefs.setString(_imageCacheStorageKey, jsonEncode(_imageCache));
    } catch (_) {}
  }

  void _applyCachedDataToStudents() {
    for (final s in _allStudents) {
      final id = '${s['id'] ?? ''}'.trim();
      if (id.isEmpty) continue;

      if (_phoneCache.containsKey(id)) {
        final cachedPhone = _phoneCache[id]!;
        if (cachedPhone.isNotEmpty && cachedPhone != '-') {
          s['homePhoneNumber'] = cachedPhone;
        }
      }

      if (_genderCache.containsKey(id)) {
        final cachedGender = _genderCache[id]!;
        if (cachedGender.isNotEmpty && cachedGender != '-') {
          s['gender'] ??= cachedGender;
        }
      }

      if (_imageCache.containsKey(id)) {
        final cachedImage = _imageCache[id]!;
        if (cachedImage.isNotEmpty && cachedImage != '-') {
          final currentImg = s['imageUrl']?.toString().trim() ?? '';
          if (currentImg.isEmpty || currentImg == 'null') {
            s['imageUrl'] = cachedImage;
          }
        }
      }
    }
  }

  dynamic _unwrap(dynamic d) => d is Map && d['data'] != null ? d['data'] : d;

  String _extractPhoneFromMap(Map<String, dynamic> s) {
    final address = s['address'];
    final candidates = <dynamic>[
      if (address is Map) address['mobilePhoneNumber'],
      s['mobilePhoneNumber'],
      s['homePhoneNumber'],
      if (address is Map) address['homePhoneNumber'],
      if (address is Map) address['schoolPhoneNumber'],
      if (address is Map) address['phoneNumber'],
      s['phoneNumber'],
      s['phone'],
    ];
    for (final value in candidates) {
      final phone = value?.toString().trim() ?? '';
      if (phone.isNotEmpty && phone != 'null') return phone;
    }
    return '';
  }

  String _extractGenderFromMap(Map<String, dynamic> s) {
    final candidates = <dynamic>[
      s['genderName'],
      s['genderText'],
      s['genderDisplayName'],
      s['studentGender'],
      s['gender'],
      s['sex'],
    ];

    for (final raw in candidates) {
      if (raw == null) continue;
      if (raw is Map) {
        final nested = raw['displayName'] ?? raw['name'] ?? raw['text'] ?? raw['value'] ?? raw['id'];
        final parsed = _parseGenderValue(nested);
        if (parsed.isNotEmpty) return parsed;
      } else {
        final parsed = _parseGenderValue(raw);
        if (parsed.isNotEmpty) return parsed;
      }
    }
    return '';
  }

  String _parseGenderValue(dynamic val) {
    final str = val?.toString().trim().toLowerCase() ?? '';
    if (str.isEmpty || str == 'null') return '';
    if (str == '1' || str == 'ذكر' || str == 'male' || str == 'm' || str == 'بنين') {
      return 'ذكر';
    }
    if (str == '2' || str == 'أنثى' || str == 'انثى' || str == 'female' || str == 'f' || str == 'بنات') {
      return 'أنثى';
    }
    return '';
  }

  String _extractImageFromMap(Map<String, dynamic> s) {
    final candidates = <dynamic>[
      s['imageUrl'],
      s['avatarUrl'],
      s['photoUrl'],
      s['image'],
      s['photo'],
    ];
    for (final value in candidates) {
      final img = value?.toString().trim() ?? '';
      if (img.isNotEmpty && img != 'null') return img;
    }
    return '';
  }

  String _studentImageUrl(Map<String, dynamic> s) {
    String raw = _extractImageFromMap(s);
    if (raw.isEmpty) {
      final id = '${s['id'] ?? ''}'.trim();
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

  Future<void> _loadStudents() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final r = await http.get(
        Uri.parse(
          'https://emis.moedu.gov.iq/api/student/getstudents?page=1&rowsPerPage=3000&sortBy=id&sortOrder=desc&entityId=${widget.schoolId}',
        ),
        headers: _headers,
      );
      if (r.statusCode < 200 || r.statusCode >= 300) {
        throw Exception('HTTP ${r.statusCode}: ${utf8.decode(r.bodyBytes)}');
      }
      final data = _unwrap(jsonDecode(utf8.decode(r.bodyBytes)));
      if (data is List) {
        _allStudents = data
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
      }
      _applyCachedDataToStudents();
      if (mounted) setState(() => _loading = false);

      unawaited(_fetchMissingDetailsConcurrently());
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '$e';
        });
      }
    }
  }

  Future<Map<String, String>?> _fetchSingleStudentDetails(String id) async {
    try {
      final response = await http
          .get(
            Uri.parse('https://emis.moedu.gov.iq/api/student/getstudent/$id'),
            headers: _headers,
          )
          .timeout(const Duration(seconds: 12));

      if (response.statusCode != 200) return null;
      final decoded = _unwrap(jsonDecode(utf8.decode(response.bodyBytes)));
      if (decoded is Map) {
        final fullMap = decoded.map((k, v) => MapEntry(k.toString(), v));
        final phone = _extractPhoneFromMap(fullMap);
        final gender = _extractGenderFromMap(fullMap);
        final image = _extractImageFromMap(fullMap);
        return {
          'phone': phone.isEmpty ? '-' : phone,
          'gender': gender.isEmpty ? '-' : gender,
          'image': image.isEmpty ? '-' : image,
        };
      }
    } catch (_) {}
    return null;
  }

  Future<void> _fetchMissingDetailsConcurrently({bool forceRefreshAll = false}) async {
    final currentGen = ++_scanGeneration;

    if (forceRefreshAll) {
      _phoneCache.clear();
      _genderCache.clear();
      _imageCache.clear();
    }

    final filteredIds = _filteredStudents
        .map((s) => '${s['id'] ?? ''}'.trim())
        .where((id) => id.isNotEmpty)
        .toSet();

    final pendingStudents = <Map<String, dynamic>>[];
    for (final s in _allStudents) {
      final id = '${s['id'] ?? ''}'.trim();
      if (id.isEmpty) continue;

      final directPhone = _extractPhoneFromMap(s);
      if (directPhone.isNotEmpty) {
        _phoneCache[id] = directPhone;
      }

      final directGender = _extractGenderFromMap(s);
      if (directGender.isNotEmpty) {
        _genderCache[id] = directGender;
      }

      final directImage = _extractImageFromMap(s);
      if (directImage.isNotEmpty) {
        _imageCache[id] = directImage;
      }

      if (!_phoneCache.containsKey(id) ||
          !_genderCache.containsKey(id) ||
          !_imageCache.containsKey(id)) {
        pendingStudents.add(s);
      }
    }

    pendingStudents.sort((a, b) {
      final aInView = filteredIds.contains('${a['id'] ?? ''}') ? 0 : 1;
      final bInView = filteredIds.contains('${b['id'] ?? ''}') ? 0 : 1;
      return aInView.compareTo(bInView);
    });

    if (pendingStudents.isEmpty) {
      if (mounted) {
        setState(() {
          _loadingPhones = false;
        });
      }
      return;
    }

    if (mounted) {
      setState(() {
        _loadingPhones = true;
        _phonesLoadedCount = 0;
        _phonesTotalToLoad = pendingStudents.length;
      });
    }

    // قراءة حالة الطوابير الذكية والمعالجة السريعة من الإعدادات
    await AppCore.initPreferences();
    final fastQueueEnabled = AppCore.prefs.getBool('fast_processing_queue_enabled') ?? true;

    // تحديد التزامن بناءً على تفعيل المعالجة السريعة (3 عند التفعيل لمنع الضغط، أو 8 كافتراضي)
    final int concurrency = fastQueueEnabled ? 3 : 8;
    int nextIndex = 0;
    int completed = 0;

    Future<void> worker() async {
      while (!_disposed && currentGen == _scanGeneration) {
        final idx = nextIndex++;
        if (idx >= pendingStudents.length) return;

        final student = pendingStudents[idx];
        final id = '${student['id'] ?? ''}'.trim();
        if (id.isEmpty || _fetchingIds.contains(id)) continue;

        _fetchingIds.add(id);
        try {
          final details = await _fetchSingleStudentDetails(id);
          if (_disposed || currentGen != _scanGeneration) return;

          if (details != null) {
            final phoneResult = details['phone']!;
            final genderResult = details['gender']!;
            final imageResult = details['image']!;

            _phoneCache[id] = phoneResult;
            if (phoneResult != '-') {
              student['homePhoneNumber'] = phoneResult;
            }

            _genderCache[id] = genderResult;
            if (genderResult != '-') {
              student['gender'] = genderResult;
            }

            _imageCache[id] = imageResult;
            if (imageResult != '-') {
              student['imageUrl'] = imageResult;
            }
          }
        } finally {
          _fetchingIds.remove(id);
          completed++;
          // إضافة فترة راحة ذكية عند تفعيل الطوابير لمنع ضغط السيرفر
          if (fastQueueEnabled) {
            await Future.delayed(const Duration(milliseconds: 100));
          }
          if (!_disposed &&
              currentGen == _scanGeneration &&
              mounted &&
              (completed % 4 == 0 || completed == pendingStudents.length)) {
            setState(() {
              _phonesLoadedCount = completed;
            });
            unawaited(_persistCaches());
          }
        }
      }
    }

    final workersCount = pendingStudents.length < concurrency
        ? pendingStudents.length
        : concurrency;
    await Future.wait(List.generate(workersCount, (_) => worker()));

    if (!_disposed && currentGen == _scanGeneration) {
      await _persistCaches();
      if (mounted) {
        setState(() {
          _loadingPhones = false;
        });
      }
    }
  }

  List<String> get _stages => _allStudents
      .map((s) =>
          (s['studentStage'] ?? s['stageName'] ?? s['stage'] ?? '').toString())
      .where((s) => s.trim().isNotEmpty)
      .toSet()
      .toList();

  List<String> get _classRooms {
    if (_selectedStage == null) return [];
    return _allStudents
        .where((s) =>
            (s['studentStage'] ?? s['stageName'] ?? s['stage'])?.toString() ==
            _selectedStage)
        .map((s) =>
            (s['classRoomName'] ?? s['classRoom'] ?? s['classroom'] ?? '')
                .toString())
        .where((s) => s.isNotEmpty)
        .toSet()
        .toList();
  }

  String _studentName(Map<String, dynamic> s) {
    final direct = s['fullName'] ?? s['studentName'];
    if (direct != null && '$direct'.trim().isNotEmpty) return '$direct'.trim();
    final combined = [
      s['name'],
      s['fatherName'],
      s['grandFatherName'],
      s['surName']
    ].map((e) => e?.toString().trim() ?? '').where((e) => e.isNotEmpty).join(' ');
    return combined.trim().isEmpty ? 'بدون اسم' : combined;
  }

  String _studentGender(Map<String, dynamic> s) {
    final direct = _extractGenderFromMap(s);
    if (direct.isNotEmpty) return direct;

    final id = '${s['id'] ?? ''}'.trim();
    if (id.isNotEmpty && _genderCache.containsKey(id)) {
      final cached = _genderCache[id]!;
      if (cached.isNotEmpty && cached != '-') return cached;
      if (cached == '-') return 'غير محدد';
    }

    if (_loadingPhones) return 'جاري القراءة...';
    return 'غير محدد';
  }

  String _studentPhone(Map<String, dynamic> s) {
    final direct = _extractPhoneFromMap(s);
    if (direct.isNotEmpty) return direct;

    final id = '${s['id'] ?? ''}'.trim();
    if (id.isNotEmpty && _phoneCache.containsKey(id)) {
      final cached = _phoneCache[id]!;
      if (cached.isNotEmpty && cached != '-') return cached;
      if (cached == '-') return 'غير مسجل';
    }

    if (_loadingPhones) return 'جاري القراءة...';
    return 'غير مسجل';
  }

  List<Map<String, dynamic>> get _filteredStudents {
    final q = _query.trim().toLowerCase();
    return _allStudents.where((s) {
      final stage =
          (s['studentStage'] ?? s['stageName'] ?? s['stage'])?.toString();
      final room =
          (s['classRoomName'] ?? s['classRoom'] ?? s['classroom'])?.toString();
      if (_selectedStage != null && stage != _selectedStage) return false;
      if (_selectedClassRoom != null && room != _selectedClassRoom) return false;
      if (q.isEmpty) return true;
      return [
        _studentName(s),
        s['id'],
        s['nationalIdNumber'],
        s['idNumber'],
        _studentPhone(s),
        _studentGender(s),
      ].any((v) => '$v'.toLowerCase().contains(q));
    }).toList();
  }

  Future<void> _openStudent(Map<String, dynamic> student) async {
    final id = '${student['id'] ?? ''}'.trim();
    if (id.isEmpty) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => EditStudentScreen(token: widget.token, studentId: id),
      ),
    );
    _phoneCache.remove(id);
    _genderCache.remove(id);
    _imageCache.remove(id);
    await _loadStudents();
  }

  Future<void> _addStudent() async {
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) =>
            AddStudentScreen(token: widget.token, schoolId: widget.schoolId),
      ),
    );
    if (changed == true) await _loadStudents();
  }

  Future<void> _deactivateStudent(Map<String, dynamic> student) async {
    final id = student['id'];
    if (id == null) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('تعطيل الطالب', textDirection: TextDirection.rtl),
        content: Text(
          'هل أنت متأكد من تعطيل الطالب ${_studentName(student)}؟',
          textDirection: TextDirection.rtl,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('تعطيل'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    try {
      final uri = Uri.parse(
        'https://emis.moedu.gov.iq/api/student/removestudent'
        '?id=${Uri.encodeQueryComponent('$id')}'
        '&schoolId=${Uri.encodeQueryComponent(widget.schoolId)}',
      );
      final response = await http.post(uri, headers: _headers);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        final body = utf8.decode(response.bodyBytes);
        throw Exception(
          'HTTP ${response.statusCode}${body.isEmpty ? '' : ': $body'}',
        );
      }

      _phoneCache.remove('$id');
      _genderCache.remove('$id');
      _imageCache.remove('$id');
      await _loadStudents();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('تم تعطيل الطالب بنجاح'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('فشل تعطيل الطالب: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  void _previewStudentImage(String imageUrl, String studentName) {
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
                constraints: const BoxConstraints(maxHeight: 380, maxWidth: 320),
                child: InteractiveViewer(
                  child: Image.network(
                    imageUrl,
                    headers: {'Authorization': widget.token},
                    fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) => const Padding(
                      padding: EdgeInsets.all(40),
                      child: Icon(Icons.broken_image, size: 60, color: Colors.grey),
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
                studentName,
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
      builder: (context, mode, child) {
        final dark = mode == ThemeMode.dark;
        final bg = dark ? const Color(0xFF121212) : const Color(0xFFF5F7FA);
        final card = dark ? const Color(0xFF1E1E1E) : Colors.white;
        final text = dark ? Colors.white : Colors.black87;
        return Scaffold(
          backgroundColor: bg,
          appBar: AppBar(
            title: const Text(
              'تعديل الطلاب',
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
            ),
            centerTitle: true,
            flexibleSpace: Container(
              decoration: BoxDecoration(
                gradient: AppCore.isWindows ? null : LinearGradient(
                  colors: [Color(0xFF1A237E), Color(0xFF4A90E2)],
                ),
                color: AppCore.isWindows ? AppCore.windowsGradientFallback(LinearGradient(
                  colors: [Color(0xFF1A237E), Color(0xFF4A90E2)],
                )) : null,
              ),
            ),
            iconTheme: const IconThemeData(color: Colors.white),
            actions: [
              IconButton(
                tooltip: 'إضافة طالب جديد',
                onPressed: _addStudent,
                icon: const Icon(Icons.person_add_alt_1, color: Colors.white),
              ),
              IconButton(
                tooltip: 'تحديث القائمة والبيانات',
                onPressed: _loading
                    ? null
                    : () async {
                        await _loadStudents();
                        unawaited(_fetchMissingDetailsConcurrently(
                            forceRefreshAll: true));
                      },
                icon: const Icon(Icons.refresh, color: Colors.white),
              ),
            ],
          ),
          body: RefreshIndicator(
            onRefresh: _loadStudents,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
              children: [
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Text(
                      _error!,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Colors.red,
                      ),
                      textDirection: TextDirection.rtl,
                    ),
                  ),
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        value: _selectedStage,
                        isExpanded: true,
                        decoration: InputDecoration(
                          labelText: 'اختر الصف',
                          filled: true,
                          fillColor: card,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16),
                            borderSide: BorderSide.none,
                          ),
                        ),
                        dropdownColor: card,
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: text,
                        ),
                        items: _stages
                            .map((s) => DropdownMenuItem(
                                  value: s,
                                  child: Text(s, overflow: TextOverflow.ellipsis),
                                ))
                            .toList(),
                        onChanged: (v) {
                          setState(() {
                            _selectedStage = v;
                            _selectedClassRoom = null;
                          });
                          unawaited(_fetchMissingDetailsConcurrently());
                        },
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        value: _selectedClassRoom,
                        isExpanded: true,
                        decoration: InputDecoration(
                          labelText: 'اختر الشعبة',
                          filled: true,
                          fillColor: card,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16),
                            borderSide: BorderSide.none,
                          ),
                        ),
                        dropdownColor: card,
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: text,
                        ),
                        items: _classRooms
                            .map((s) => DropdownMenuItem(
                                  value: s,
                                  child: Text(s),
                                ))
                            .toList(),
                        onChanged: _selectedStage == null
                            ? null
                            : (v) {
                                setState(() => _selectedClassRoom = v);
                                unawaited(_fetchMissingDetailsConcurrently());
                              },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                TextField(
                  textDirection: TextDirection.rtl,
                  onChanged: (v) => setState(() => _query = v),
                  decoration: InputDecoration(
                    filled: true,
                    fillColor: card,
                    hintText: 'ابحث باسم الطالب أو الرقم أو الهاتف أو الجنس',
                    prefixIcon: const Icon(Icons.search),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(18),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: card,
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.people_alt_outlined, color: Colors.indigo),
                      const SizedBox(width: 10),
                      Text(
                        '${_filteredStudents.length} طالب',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: text,
                        ),
                      ),
                      const Spacer(),
                      if (_loadingPhones) ...[
                        Text(
                          'جلب البيانات: $_phonesLoadedCount / $_phonesTotalToLoad',
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: Colors.blueAccent,
                          ),
                        ),
                        const SizedBox(width: 8),
                      ],
                      if (_loading || _loadingPhones)
                        const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                if (_filteredStudents.isEmpty)
                  Container(
                    padding: const EdgeInsets.all(35),
                    decoration: BoxDecoration(
                      color: card,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Column(
                      children: [
                        const Icon(
                          Icons.person_search_outlined,
                          size: 55,
                          color: Colors.grey,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'لا توجد نتائج مطابقة للبحث',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: text,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  )
                else
                  ..._filteredStudents.map((s) => _studentCard(s, card, text, dark)),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildStudentAvatar(
    String imgUrl,
    String studentName,
    bool isMale,
    bool isFemale,
    Color genderColor, {
    double size = 78,
  }) {
    final fallbackIcon = Icon(
      isMale
          ? Icons.male_rounded
          : isFemale
              ? Icons.female_rounded
              : Icons.person_rounded,
      color: genderColor,
      size: size * .40,
    );

    return GestureDetector(
      onTap: imgUrl.isNotEmpty
          ? () => _previewStudentImage(imgUrl, studentName)
          : null,
      child: Container(
        width: size,
        height: size,
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: AppCore.isWindows ? null : const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF8B5CF6), Color(0xFF60A5FA), Color(0xFFDBEAFE)],
          ),
          color: AppCore.isWindows ? AppCore.windowsGradientFallback(const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF8B5CF6), Color(0xFF60A5FA), Color(0xFFDBEAFE)],
          )) : null,
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF6366F1).withOpacity(.22),
              blurRadius: 18,
              offset: const Offset(0, 7),
            ),
          ],
        ),
        child: Container(
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.white,
          ),
          child: ClipOval(
            child: imgUrl.isNotEmpty
                ? Image.network(
                    imgUrl,
                    headers: {'Authorization': widget.token},
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Container(
                      color: genderColor.withOpacity(.10),
                      child: Center(child: fallbackIcon),
                    ),
                  )
                : Container(
                    color: genderColor.withOpacity(.10),
                    child: Center(child: fallbackIcon),
                  ),
          ),
        ),
      ),
    );
  }

  Widget _studentCard(Map<String, dynamic> s, Color cardBg, Color textColor, bool isDarkMode) {
    final stage = '${s['studentStage'] ?? s['stageName'] ?? ''}'.trim();
    final room = '${s['classRoomName'] ?? s['classRoom'] ?? ''}'.trim();
    final phoneText = _studentPhone(s);
    final genderText = _studentGender(s);
    final imgUrl = _studentImageUrl(s);
    final nameText = _studentName(s);
    final hasValidPhone = phoneText != 'غير مسجل' &&
        phoneText != 'جاري القراءة...' && phoneText.trim().isNotEmpty;

    final isMale = genderText == 'ذكر';
    final isFemale = genderText == 'أنثى';
    final genderColor = isMale
        ? const Color(0xFF0EA765)
        : isFemale
            ? const Color(0xFFDB2777)
            : const Color(0xFF6478E8);
    final titleColor = isDarkMode ? const Color(0xFFF5F3FF) : const Color(0xFF14213D);
    final mutedColor = isDarkMode ? const Color(0xFFB8C2D8) : const Color(0xFF64748B);
    final panelColor = isDarkMode ? const Color(0xFF202236) : Colors.white;

    void copyPhoneToClipboard() {
      if (hasValidPhone) {
        Clipboard.setData(ClipboardData(text: phoneText));
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'تم نسخ رقم الهاتف ($phoneText) إلى الحافظة',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            backgroundColor: const Color(0xFF10B981),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final compact = width < 520;
        final avatarSize = compact ? 68.0 : 82.0;
        final sideWidth = compact ? 58.0 : 78.0;
        final nameSize = compact ? 15.0 : 18.0;
        final phoneSize = compact ? 13.0 : 16.0;
        final gap = compact ? 8.0 : 12.0;

        return Container(
          margin: EdgeInsets.only(bottom: compact ? 10 : 14),
          decoration: BoxDecoration(
            color: panelColor,
            borderRadius: BorderRadius.circular(compact ? 20 : 24),
            border: Border.all(
              color: isDarkMode ? const Color(0xFF343653) : const Color(0xFFE1E7F2),
              width: 1,
            ),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF5266A8).withOpacity(isDarkMode ? .10 : .10),
                blurRadius: compact ? 12 : 18,
                offset: const Offset(0, 5),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(compact ? 19 : 23),
            child: Stack(
              children: [
                Positioned(
                  top: -38,
                  right: -24,
                  child: Container(
                    width: compact ? 88 : 120,
                    height: compact ? 88 : 120,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: const Color(0xFF8B5CF6).withOpacity(isDarkMode ? .08 : .07),
                    ),
                  ),
                ),
                Positioned(
                  bottom: -46,
                  left: -25,
                  child: Container(
                    width: compact ? 95 : 130,
                    height: compact ? 95 : 130,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: const Color(0xFF60A5FA).withOpacity(isDarkMode ? .07 : .08),
                    ),
                  ),
                ),
                Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: compact ? 10 : 15,
                    vertical: compact ? 11 : 14,
                  ),
                  child: Row(
                    textDirection: TextDirection.rtl,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      _buildStudentAvatar(imgUrl, nameText, isMale, isFemale, genderColor, size: avatarSize),
                      SizedBox(width: gap),
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                              nameText,
                              textAlign: TextAlign.right,
                              textDirection: TextDirection.rtl,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: titleColor,
                                fontSize: nameSize,
                                height: 1.2,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                            SizedBox(height: compact ? 6 : 8),
                            Wrap(
                              alignment: WrapAlignment.end,
                              spacing: 5,
                              runSpacing: 5,
                              children: [
                                if (stage.isNotEmpty)
                                  _chip(stage, const Color(0xFF7048E8), compact: compact),
                                if (room.isNotEmpty)
                                  _chip('شعبة $room', const Color(0xFF168DE2), compact: compact),
                                _chip(genderText.isEmpty ? 'غير محدد' : genderText, genderColor, compact: compact),
                              ],
                            ),
                            SizedBox(height: compact ? 7 : 9),
                            Material(
                              color: Colors.transparent,
                              child: InkWell(
                                borderRadius: BorderRadius.circular(13),
                                onTap: hasValidPhone ? copyPhoneToClipboard : null,
                                child: Container(
                                  padding: EdgeInsets.symmetric(
                                    horizontal: compact ? 8 : 11,
                                    vertical: compact ? 6 : 8,
                                  ),
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(13),
                                    gradient: AppCore.isWindows ? null : LinearGradient(
                                      colors: isDarkMode
                                          ? [const Color(0xFF1D3B39), const Color(0xFF202E3B)]
                                          : [const Color(0xFFE8FBF2), const Color(0xFFEAF8FC)],
                                    ),
                                    color: AppCore.isWindows ? AppCore.windowsGradientFallback(LinearGradient(
                                      colors: isDarkMode
                                          ? [const Color(0xFF1D3B39), const Color(0xFF202E3B)]
                                          : [const Color(0xFFE8FBF2), const Color(0xFFEAF8FC)],
                                    )) : null,
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.max,
                                    textDirection: TextDirection.rtl,
                                    children: [
                                      Icon(
                                        Icons.phone_rounded,
                                        color: hasValidPhone ? const Color(0xFF0BAA69) : mutedColor,
                                        size: compact ? 16 : 19,
                                      ),
                                      const SizedBox(width: 6),
                                      Expanded(
                                        child: Align(
                                          alignment: Alignment.centerLeft,
                                          child: FittedBox(
                                            fit: BoxFit.scaleDown,
                                            alignment: Alignment.centerLeft,
                                            child: Text(
                                              phoneText,
                                              textAlign: TextAlign.left,
                                              textDirection: TextDirection.ltr,
                                              maxLines: 1,
                                              softWrap: false,
                                              style: TextStyle(
                                                fontWeight: FontWeight.w800,
                                                fontSize: phoneSize,
                                                color: hasValidPhone ? const Color(0xFF07966C) : mutedColor,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                      if (hasValidPhone) ...[
                                        const SizedBox(width: 4),
                                        Icon(
                                          Icons.copy_rounded,
                                          size: compact ? 13 : 15,
                                          color: const Color(0xFF0BAA69).withOpacity(0.7),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      SizedBox(width: gap),
                      SizedBox(
                        width: sideWidth,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _compactAction(
                              label: 'تعديل',
                              icon: Icons.edit_rounded,
                              color: const Color(0xFF4263EB),
                              compact: compact,
                              onPressed: () => _openStudent(s),
                            ),
                            SizedBox(height: compact ? 6 : 8),
                            _compactAction(
                              label: 'تعطيل',
                              icon: Icons.person_off_rounded,
                              color: const Color(0xFFE53945),
                              compact: compact,
                              onPressed: () => _deactivateStudent(s),
                            ),
                          ],
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
    );
  }

  Widget _compactAction({
    required String label,
    required IconData icon,
    required Color color,
    required bool compact,
    required VoidCallback onPressed,
  }) {
    return SizedBox(
      width: double.infinity,
      height: compact ? 39 : 44,
      child: ElevatedButton(
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: color,
          foregroundColor: Colors.white,
          elevation: 2,
          shadowColor: color.withOpacity(.18),
          padding: EdgeInsets.symmetric(horizontal: compact ? 3 : 7),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(compact ? 11 : 13),
          ),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          minimumSize: Size.zero,
        ),
        child: compact
            ? Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, size: 16),
                  const SizedBox(height: 1),
                  Text(label, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w800, height: 1)),
                ],
              )
            : Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, size: 17),
                  const SizedBox(width: 4),
                  Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800)),
                ],
              ),
      ),
    );
  }

  Widget _chip(String label, Color color, {bool compact = false}) => Container(
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 7 : 9,
          vertical: compact ? 4 : 5,
        ),
        decoration: BoxDecoration(
          color: color.withOpacity(.12),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: color.withOpacity(0.25), width: 1),
        ),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: compact ? 10 : 12,
            color: color,
            fontWeight: FontWeight.bold,
            height: 1.05,
          ),
        ),
      );
}
