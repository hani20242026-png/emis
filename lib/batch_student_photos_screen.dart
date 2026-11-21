import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:google_mlkit_selfie_segmentation/google_mlkit_selfie_segmentation.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'platform_image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'selfie_background_remover.dart';
import 'app_core.dart';

class BatchStudentPhotosScreen extends StatefulWidget {
  final String token;
  final String schoolId;
  final List<dynamic> allStudents;

  const BatchStudentPhotosScreen({
    super.key,
    required this.token,
    required this.schoolId,
    required this.allStudents,
  });

  @override
  State<BatchStudentPhotosScreen> createState() =>
      _BatchStudentPhotosScreenState();
}

class _BatchStudentPhotosScreenState extends State<BatchStudentPhotosScreen>
    with SingleTickerProviderStateMixin {
  late List<Map<String, dynamic>> _allStudentsList;
  final Map<String, String> _imageCache = <String, String>{};
  final Set<String> _existingPhotoIds = <String>{};

  String? _selectedStage;
  String? _selectedClassRoom;
  List<Map<String, dynamic>> _students = <Map<String, dynamic>>[];
  int _currentIndex = 0;

  final Set<String> _photographed = <String>{};
  final Set<String> _notPhotographed = <String>{};
  final Set<String> _skipped = <String>{};

  File? _currentImage;
  bool _processing = false;
  bool _saving = false;
  bool _backgroundRemovedForCurrentImage = false;
  SelfieSegmenter? _segmenter;
  bool _restoringSession = false;

  // متغيرات الستارة وفحص سجلات الصور
  bool _isCurtainOpen = true;
  bool _scanningRecords = false;
  int _scanLoadedCount = 0;
  int _scanTotalCount = 0;
  int _scanGeneration = 0;
  bool _onlyMissingPhotosMode = false;
  bool _loadingAllStudents = false;
  bool _disposed = false;

  late final AnimationController _ambientController;

  // مفتاح كاش جديد مخصص للصور المتحقق من وجودها فعلياً على الخادم
  String get _imageCacheStorageKey =>
      'emis_verified_student_images_v2_${widget.schoolId}';

  Map<String, String> get _headers => {
        'Authorization': widget.token,
        'Accept': 'application/json',
      };

  String _sessionKey(String? stage, String? classroom) {
    final a = Uri.encodeComponent(stage ?? '');
    final b = Uri.encodeComponent(classroom ?? '');
    return 'batch_student_photo_session_${widget.schoolId}_${a}_${b}';
  }

  @override
  void initState() {
    super.initState();
    _ambientController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 6),
    )..repeat();

    _allStudentsList = widget.allStudents
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();

    _initScreen();
  }

  Future<void> _initScreen() async {
    await _restoreImageCache();
    if (_allStudentsList.isEmpty) {
      await _fetchAllStudentsFromServer();
    }
    await _restoreLastSession();
  }

  Future<void> _restoreImageCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
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
      _applyCachedImagesToStudents(_allStudentsList);
    } catch (_) {}
  }

  Future<void> _persistImageCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_imageCacheStorageKey, jsonEncode(_imageCache));
    } catch (_) {}
  }

  void _clearStudentImageFields(Map<String, dynamic> s) {
    s.remove('imageUrl');
    s.remove('avatarUrl');
    s.remove('photoUrl');
    s.remove('image');
    s.remove('photo');
  }

  void _applyCachedImagesToStudents(List<Map<String, dynamic>> list) {
    for (final s in list) {
      final id = _studentId(s);
      if (id.isEmpty) continue;
      if (_imageCache.containsKey(id)) {
        final cachedImage = _imageCache[id]!;
        if (cachedImage.isNotEmpty && cachedImage != '-') {
          s['imageUrl'] = cachedImage;
        } else if (cachedImage == '-') {
          _clearStudentImageFields(s);
        }
      }
    }
  }

  dynamic _unwrap(dynamic d) => d is Map && d['data'] != null ? d['data'] : d;

  Future<void> _fetchAllStudentsFromServer() async {
    if (mounted) setState(() => _loadingAllStudents = true);
    try {
      final r = await http.get(
        Uri.parse(
          'https://emis.moedu.gov.iq/api/student/getstudents?page=1&rowsPerPage=3000&sortBy=id&sortOrder=desc&entityId=${widget.schoolId}',
        ),
        headers: _headers,
      );
      if (r.statusCode >= 200 && r.statusCode < 300) {
        final data = _unwrap(jsonDecode(utf8.decode(r.bodyBytes)));
        if (data is List) {
          _allStudentsList = data
              .whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e))
              .toList();
          _applyCachedImagesToStudents(_allStudentsList);
        }
      }
    } catch (e) {
      debugPrint('Fetch all students error: $e');
    } finally {
      if (mounted) setState(() => _loadingAllStudents = false);
    }
  }

  String _extractStage(Map<String, dynamic> s) =>
      (s['studentStage'] ?? s['stageName'] ?? s['stage'] ?? '')
          .toString()
          .trim();

  String _extractClassRoom(Map<String, dynamic> s) =>
      (s['classRoomName'] ?? s['classRoom'] ?? s['classroom'] ?? '')
          .toString()
          .trim();

  bool _isInvalidImageString(String value) {
    final lower = value.trim().toLowerCase();
    if (lower.isEmpty ||
        lower == 'null' ||
        lower == 'false' ||
        lower == 'true' ||
        lower == '0' ||
        lower == '-' ||
        lower == '/' ||
        lower == 'none' ||
        lower == 'undefined' ||
        lower == 'string' ||
        lower.startsWith('{') ||
        lower.startsWith('[')) {
      return true;
    }
    const invalidKeywords = [
      'default',
      'placeholder',
      'no-image',
      'no_image',
      'noimage',
      'empty',
      'blank',
      'anonymous',
    ];
    for (final kw in invalidKeywords) {
      if (lower.contains(kw)) return true;
    }
    return false;
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
      if (value is! String) continue;
      final img = value.trim();
      if (!_isInvalidImageString(img)) return img;
    }
    return '';
  }

  String _buildFullImageUrl(String raw) {
    String cleaned = raw.trim();
    if (_isInvalidImageString(cleaned)) return '';
    if (!cleaned.startsWith('http')) {
      if (!cleaned.startsWith('/')) cleaned = '/$cleaned';
      return 'https://emis.moedu.gov.iq$cleaned';
    }
    return cleaned;
  }

  // فحص بايتات الملف للتأكد من أنه صورة حقيقية (JPEG / PNG / WebP / GIF / BMP)
  bool _isValidImageBytes(Uint8List bytes) {
    if (bytes.length < 200) return false;
    // JPEG: FF D8 FF
    if (bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) return true;
    // PNG: 89 50 4E 47
    if (bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return true;
    }
    // GIF: 47 49 46
    if (bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46) return true;
    // WebP: RIFF....WEBP
    if (bytes.length > 12 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return true;
    }
    // BMP: 42 4D
    if (bytes[0] == 0x42 && bytes[1] == 0x4D) return true;

    return false;
  }

  // التحقق من أن رابط الصورة يعمل ويرجع صورة فعلية من خادم EMIS
  Future<bool> _verifyImageUrlExists(String rawUrl) async {
    final fullUrl = _buildFullImageUrl(rawUrl);
    if (fullUrl.isEmpty) return false;
    try {
      final response = await http.get(
        Uri.parse(fullUrl),
        headers: {'Authorization': widget.token},
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) return false;
      return _isValidImageBytes(response.bodyBytes);
    } catch (_) {
      return false;
    }
  }

  bool _hasValidImage(Map<String, dynamic> s) {
    final id = _studentId(s);
    if (id.isEmpty) return false;
    if (_existingPhotoIds.contains(id)) return true;
    if (_imageCache.containsKey(id)) {
      final cached = _imageCache[id]!;
      return !_isInvalidImageString(cached);
    }
    return false;
  }

  List<String> get _stages => _allStudentsList
      .map(_extractStage)
      .where((s) => s.isNotEmpty)
      .toSet()
      .toList();

  List<String> get _classRooms {
    if (_selectedStage == null) return <String>[];
    return _allStudentsList
        .where((s) => _extractStage(s) == _selectedStage)
        .map(_extractClassRoom)
        .where((s) => s.isNotEmpty)
        .toSet()
        .toList();
  }

  String _studentId(Map<String, dynamic> s) => s['id']?.toString().trim() ?? '';

  String _studentName(Map<String, dynamic> s) {
    final direct = s['fullName'] ?? s['studentName'];
    if (direct != null && direct.toString().trim().isNotEmpty) {
      return direct.toString().trim();
    }
    final parts = [
      s['name'],
      s['firstName'],
      s['fatherName'],
      s['grandFatherName'],
      s['surName']
    ]
        .map((e) => e?.toString().trim() ?? '')
        .where((e) => e.isNotEmpty)
        .toList();
    return parts.isEmpty ? 'بدون اسم' : parts.join(' ');
  }

  Future<void> _persistSession() async {
    if (_selectedStage == null ||
        _selectedClassRoom == null ||
        _students.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = _sessionKey(_selectedStage, _selectedClassRoom);
      final payload = {
        'stage': _selectedStage,
        'classRoom': _selectedClassRoom,
        'photographed': _photographed.toList(),
        'skipped': _skipped.toList(),
        'notPhotographed': _notPhotographed.toList(),
        'onlyMissingPhotosMode': _onlyMissingPhotosMode,
        'currentIndex': _currentIndex,
        'updatedAt': DateTime.now().toIso8601String(),
      };
      await prefs.setString(key, jsonEncode(payload));
      await prefs.setString(
          'batch_student_last_session_${widget.schoolId}', key);
    } catch (e) {
      debugPrint('Persist student batch session error: $e');
    }
  }

  Future<void> _restoreSessionForCurrentSelection() async {
    if (_selectedStage == null ||
        _selectedClassRoom == null ||
        _students.isEmpty) return;
    _restoringSession = true;
    if (mounted) setState(() {});
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = _sessionKey(_selectedStage, _selectedClassRoom);
      final raw = prefs.getString(key);
      _photographed.clear();
      _notPhotographed.clear();
      _skipped.clear();
      if (raw != null && raw.isNotEmpty) {
        final data = jsonDecode(raw);
        if (data is Map) {
          final validIds = _students.map(_studentId).toSet();
          _photographed.addAll((data['photographed'] as List? ?? const [])
              .map((e) => '$e')
              .where(validIds.contains));
          _skipped.addAll((data['skipped'] as List? ?? const [])
              .map((e) => '$e')
              .where(validIds.contains));
          _notPhotographed.addAll((data['notPhotographed'] as List? ?? const [])
              .map((e) => '$e')
              .where(validIds.contains));
          _onlyMissingPhotosMode = data['onlyMissingPhotosMode'] == true;
          _notPhotographed.addAll(_skipped);
          _notPhotographed.removeAll(_photographed);
        }
      }
      _currentIndex = _firstPendingIndex(_students);
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('Restore student batch session error: $e');
      _currentIndex = _firstPendingIndex(_students);
    } finally {
      _restoringSession = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _clearPersistedCurrentSession() async {
    if (_selectedStage == null || _selectedClassRoom == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_sessionKey(_selectedStage, _selectedClassRoom));
      final lastKey = 'batch_student_last_session_${widget.schoolId}';
      if (prefs.getString(lastKey) ==
          _sessionKey(_selectedStage, _selectedClassRoom)) {
        await prefs.remove(lastKey);
      }
    } catch (e) {
      debugPrint('Clear student batch session error: $e');
    }
  }

  Future<void> _restoreLastSession() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key =
          prefs.getString('batch_student_last_session_${widget.schoolId}');
      if (key == null || key.isEmpty || !mounted) return;
      final raw = prefs.getString(key);
      if (raw == null) return;
      final data = jsonDecode(raw);
      if (data is! Map) return;
      final stage = data['stage']?.toString();
      final classroom = data['classRoom']?.toString();
      if (stage == null || classroom == null || !_stages.contains(stage)) return;
      final filtered = _allStudentsList
          .where((s) =>
              _extractStage(s) == stage && _extractClassRoom(s) == classroom)
          .map((s) => Map<String, dynamic>.from(s))
          .toList();
      if (filtered.isEmpty || !mounted) return;

      _existingPhotoIds.clear();
      for (final s in filtered) {
        final id = _studentId(s);
        if (id.isNotEmpty &&
            _imageCache.containsKey(id) &&
            !_isInvalidImageString(_imageCache[id]!)) {
          _existingPhotoIds.add(id);
        }
      }

      setState(() {
        _selectedStage = stage;
        _selectedClassRoom = classroom;
        _students = filtered;
      });
      await _restoreSessionForCurrentSelection();
    } catch (e) {
      debugPrint('Restore last student session error: $e');
    }
  }

  void _selectStage(String? value) {
    _scanGeneration++;
    setState(() {
      _selectedStage = value;
      _selectedClassRoom = null;
      _students = <Map<String, dynamic>>[];
      _currentIndex = 0;
      _photographed.clear();
      _notPhotographed.clear();
      _skipped.clear();
      _existingPhotoIds.clear();
      _currentImage = null;
      _backgroundRemovedForCurrentImage = false;
      _scanningRecords = false;
    });
  }

  void _selectClassRoom(String? value) {
    if (value == null) return;
    final filtered = _allStudentsList
        .where((s) =>
            _extractStage(s) == _selectedStage && _extractClassRoom(s) == value)
        .map((s) => Map<String, dynamic>.from(s))
        .toList();

    setState(() {
      _selectedClassRoom = value;
      _students = filtered;
      _currentIndex = 0;
      _photographed.clear();
      _notPhotographed.clear();
      _skipped.clear();
      _existingPhotoIds.clear();
      _currentImage = null;
      _backgroundRemovedForCurrentImage = false;
    });

    _scanClassroomStudentPhotos(forceNetworkCheck: true);
  }

  // جلب سجل الطالب والتحقق الفعلي من وجود ملف الصورة على الخادم
  Future<String?> _fetchAndVerifyStudentImageFromServer(String id) async {
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
        final rawImage = _extractImageFromMap(fullMap);
        if (rawImage.isEmpty) return '-';

        // التحقق الفعلي من أن الرابط يرجع صورة صالحة وليس 404 أو نصاً فارغاً
        final isRealPhoto = await _verifyImageUrlExists(rawImage);
        return isRealPhoto ? rawImage : '-';
      }
    } catch (_) {}
    return null;
  }

  Future<void> _scanClassroomStudentPhotos(
      {bool forceNetworkCheck = false}) async {
    if (_students.isEmpty) return;

    final currentGen = ++_scanGeneration;
    setState(() {
      _scanningRecords = true;
      _scanLoadedCount = 0;
      _scanTotalCount = _students.length;
    });

    // قراءة خيار المعالجة السريعة والطوابير الذكية من الإعدادات
    await AppCore.initPreferences();
    final fastQueueEnabled = AppCore.prefs.getBool('fast_processing_queue_enabled') ?? true;

    // تحديد التزامن بناءً على الإعداد (3 عند التفعيل لمنع إرهاق السيرفر، أو 8 كافتراضي)
    final int concurrency = fastQueueEnabled ? 3 : 8;
    int nextIndex = 0;
    int completed = 0;

    Future<void> worker() async {
      while (!_disposed && currentGen == _scanGeneration) {
        final idx = nextIndex++;
        if (idx >= _students.length) return;

        final student = _students[idx];
        final id = _studentId(student);
        if (id.isEmpty) {
          completed++;
          continue;
        }

        try {
          String? imageResult;

          if (!forceNetworkCheck && _imageCache.containsKey(id)) {
            imageResult = _imageCache[id];
          } else {
            imageResult = await _fetchAndVerifyStudentImageFromServer(id);
          }

          if (_disposed || currentGen != _scanGeneration) return;

          final resolved = (imageResult != null &&
                  imageResult != '-' &&
                  !_isInvalidImageString(imageResult))
              ? imageResult
              : '-';

          _imageCache[id] = resolved;

          if (resolved != '-') {
            student['imageUrl'] = resolved;
            final mainIdx =
                _allStudentsList.indexWhere((s) => _studentId(s) == id);
            if (mainIdx >= 0) {
              _allStudentsList[mainIdx]['imageUrl'] = resolved;
            }
          } else {
            _clearStudentImageFields(student);
            final mainIdx =
                _allStudentsList.indexWhere((s) => _studentId(s) == id);
            if (mainIdx >= 0) {
              _clearStudentImageFields(_allStudentsList[mainIdx]);
            }
          }
        } finally {
          completed++;
          // إضافة فترة راحة ذكية عند تفعيل الطوابير لمنع ضغط السيرفر
          if (fastQueueEnabled) {
            await Future.delayed(const Duration(milliseconds: 100));
          }
          if (!_disposed && currentGen == _scanGeneration && mounted) {
            setState(() {
              _scanLoadedCount = completed;
            });
          }
        }
      }
    }

    final workersCount =
        _students.length < concurrency ? _students.length : concurrency;
    await Future.wait(List.generate(workersCount, (_) => worker()));

    if (_disposed || currentGen != _scanGeneration || !mounted) return;

    await _persistImageCache();

    final withPhotoIds = <String>[];
    final withoutPhotoIds = <String>[];
    _existingPhotoIds.clear();

    for (final s in _students) {
      final id = _studentId(s);
      if (id.isEmpty) continue;
      final cached = _imageCache[id] ?? '-';
      if (cached != '-' && !_isInvalidImageString(cached)) {
        withPhotoIds.add(id);
        _existingPhotoIds.add(id);
      } else {
        withoutPhotoIds.add(id);
      }
    }

    setState(() {
      _scanningRecords = false;
    });

    await _showScanResultDialog(withPhotoIds, withoutPhotoIds);
  }

  Future<void> _showScanResultDialog(
    List<String> withPhotoIds,
    List<String> withoutPhotoIds,
  ) async {
    if (!mounted) return;
    final isDark = AppCore.themeNotifier.value == ThemeMode.dark;
    const purpleNeon = Color(0xFFA855F7);
    const emeraldNeon = Color(0xFF10B981);
    const goldNeon = Color(0xFFF59E0B);

    final choice = await showDialog<String>(
      context: context,
      barrierDismissible: true,
      builder: (dialogContext) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          backgroundColor:
              isDark ? const Color(0xFF141829) : const Color(0xFFFFFFFF),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
            side: BorderSide(
              color: purpleNeon.withOpacity(0.5),
              width: 1.5,
            ),
          ),
          title: Row(
            children: [
              const Icon(Icons.fact_check_rounded, color: purpleNeon, size: 26),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'نتيجة فحص سجلات الشعبة',
                  style: TextStyle(
                    color: isDark ? Colors.white : const Color(0xFF0F172A),
                    fontWeight: FontWeight.w900,
                    fontSize: 17,
                  ),
                ),
              ),
              IconButton(
                onPressed: () => Navigator.pop(dialogContext, 'cancel'),
                icon: Icon(
                  Icons.close_rounded,
                  color: isDark
                      ? const Color(0xFF94A3B8)
                      : const Color(0xFF64748B),
                ),
                tooltip: 'إغلاق',
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'اكتمل فحص طلاب الصف ($_selectedStage - شعبة $_selectedClassRoom):',
                style: TextStyle(
                  color:
                      isDark ? const Color(0xFFCBD5E1) : const Color(0xFF475569),
                  fontWeight: FontWeight.bold,
                  fontSize: 13.5,
                ),
              ),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: isDark
                      ? const Color(0xFF0B0E1A)
                      : const Color(0xFFF8FAFC),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: purpleNeon.withOpacity(0.25)),
                ),
                child: Column(
                  children: [
                    _scanStatRow(
                      'إجمالي طلاب الشعبة',
                      '${_students.length}',
                      purpleNeon,
                      isDark,
                    ),
                    const Divider(height: 16),
                    _scanStatRow(
                      'لديهم صورة مضافة في السجل',
                      '${withPhotoIds.length}',
                      emeraldNeon,
                      isDark,
                    ),
                    const Divider(height: 16),
                    _scanStatRow(
                      'ليس لديهم صورة في السجل',
                      '${withoutPhotoIds.length}',
                      goldNeon,
                      isDark,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'اختر طريقة المتابعة:',
                style: TextStyle(
                  color: isDark ? Colors.white : const Color(0xFF0F172A),
                  fontWeight: FontWeight.w900,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 10),
              FilledButton.icon(
                onPressed: withoutPhotoIds.isEmpty
                    ? null
                    : () => Navigator.pop(dialogContext, 'missing_only'),
                icon: const Icon(Icons.person_add_alt_1_rounded,
                    color: Colors.white),
                label: Text(
                  withoutPhotoIds.isEmpty
                      ? 'جميع الطلاب لديهم صور مسبقاً'
                      : 'التقاط صور للذين ليس لديهم صور (${withoutPhotoIds.length})',
                  style: const TextStyle(
                    fontWeight: FontWeight.w900,
                    fontSize: 13,
                    color: Colors.white,
                  ),
                ),
                style: FilledButton.styleFrom(
                  backgroundColor: emeraldNeon,
                  minimumSize: const Size.fromHeight(48),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () => Navigator.pop(dialogContext, 'all'),
                icon: const Icon(Icons.camera_enhance_rounded, size: 19),
                label: Text(
                  'إعادة التقاط صور لكل الطلاب (${_students.length})',
                  style: const TextStyle(
                    fontWeight: FontWeight.w900,
                    fontSize: 13,
                  ),
                ),
                style: OutlinedButton.styleFrom(
                  foregroundColor: purpleNeon,
                  minimumSize: const Size.fromHeight(48),
                  side: const BorderSide(color: purpleNeon, width: 1.4),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: () => Navigator.pop(dialogContext, 'cancel'),
                icon: const Icon(Icons.arrow_back_rounded, size: 19),
                label: const Text(
                  'إغلاق والعودة',
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    fontSize: 13.5,
                  ),
                ),
                style: TextButton.styleFrom(
                  foregroundColor: isDark
                      ? const Color(0xFF94A3B8)
                      : const Color(0xFF64748B),
                  minimumSize: const Size.fromHeight(44),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    if (!mounted) return;

    if (choice == 'missing_only') {
      await _clearPersistedCurrentSession();
      setState(() {
        _onlyMissingPhotosMode = true;
        _photographed
          ..clear()
          ..addAll(withPhotoIds);
        _skipped.clear();
        _notPhotographed
          ..clear()
          ..addAll(withoutPhotoIds);
        _currentIndex = _firstPendingIndex(_students);
        _isCurtainOpen = false;
      });
      await _persistSession();
    } else if (choice == 'all') {
      await _clearPersistedCurrentSession();
      setState(() {
        _onlyMissingPhotosMode = false;
        _photographed.clear();
        _skipped.clear();
        _notPhotographed.clear();
        _currentIndex = 0;
        _isCurtainOpen = false;
      });
      await _persistSession();
    } else {
      await _restoreSessionForCurrentSelection();
    }
  }

  Widget _scanStatRow(
      String label, String count, Color color, bool isDark) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: TextStyle(
            color: isDark ? Colors.white : const Color(0xFF1E293B),
            fontWeight: FontWeight.w800,
            fontSize: 13,
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
          decoration: BoxDecoration(
            color: color.withOpacity(0.15),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: color.withOpacity(0.4)),
          ),
          child: Text(
            count,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w900,
              fontSize: 14,
            ),
          ),
        ),
      ],
    );
  }

  int _firstPendingIndex(List<Map<String, dynamic>> list) {
    for (var i = 0; i < list.length; i++) {
      final id = _studentId(list[i]);
      if (!_photographed.contains(id) && !_skipped.contains(id)) return i;
    }
    return list.length;
  }

  int _nextPendingIndexFrom(int startIndex) {
    for (var i = startIndex; i < _students.length; i++) {
      final id = _studentId(_students[i]);
      if (!_photographed.contains(id) && !_skipped.contains(id)) return i;
    }
    return _students.length;
  }

  int _previousPendingIndexFrom(int startIndex) {
    for (var i = startIndex; i >= 0; i--) {
      final id = _studentId(_students[i]);
      if (!_onlyMissingPhotosMode || !_existingPhotoIds.contains(id)) {
        return i;
      }
    }
    return startIndex >= 0 ? startIndex : 0;
  }

  Future<void> _initializeSegmenter() async {
    _segmenter ??=
        SelfieSegmenter(mode: SegmenterMode.single, enableRawSizeMask: false);
  }

  Future<File> _removeBackground(File imageFile) async {
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      return await SelfieBackgroundRemover.removeBackground(imageFile) ?? imageFile;
    }
    await _initializeSegmenter();
    final segmenter = _segmenter;
    if (segmenter == null) throw Exception('تعذر تهيئة أداة إزالة الخلفية');

    final bytes = await imageFile.readAsBytes();
    var source = img.decodeImage(bytes);
    if (source == null) throw Exception('تعذر قراءة الصورة');
    source = img.bakeOrientation(source);

    const maxDimension = 512;
    if (source.width > maxDimension || source.height > maxDimension) {
      source = img.copyResize(
        source,
        width: source.width >= source.height ? maxDimension : null,
        height: source.height > source.width ? maxDimension : null,
        interpolation: img.Interpolation.linear,
      );
    }

    final inputPath =
        '${imageFile.path}_seg_${DateTime.now().millisecondsSinceEpoch}.jpg';
    final inputFile = File(inputPath);
    await inputFile.writeAsBytes(img.encodeJpg(source, quality: 90),
        flush: true);

    try {
      final mask =
          await segmenter.processImage(InputImage.fromFilePath(inputFile.path));
      if (mask == null ||
          mask.width <= 0 ||
          mask.height <= 0 ||
          mask.confidences.isEmpty) {
        throw Exception('لم يتم الحصول على قناع صالح للشخص');
      }
      if (mask.width != source.width || mask.height != source.height) {
        throw Exception('أبعاد قناع إزالة الخلفية غير متطابقة');
      }

      final result =
          img.Image(width: source.width, height: source.height, numChannels: 4);
      final count = source.width * source.height;
      if (mask.confidences.length < count) {
        throw Exception('بيانات القناع غير مكتملة');
      }

      for (var y = 0; y < source.height; y++) {
        for (var x = 0; x < source.width; x++) {
          final i = y * source.width + x;
          final confidence = mask.confidences[i].clamp(0.0, 1.0);
          final alpha =
              ((confidence - 0.35) / 0.40 * 255.0).round().clamp(0, 255);
          final pixel = source.getPixel(x, y);
          result.setPixelRgba(x, y, pixel.r, pixel.g, pixel.b, alpha);
        }
      }

      final output = File(
          '${imageFile.path}_nobg_${DateTime.now().millisecondsSinceEpoch}.png');
      await output.writeAsBytes(img.encodePng(result, level: 6), flush: true);
      return output;
    } finally {
      try {
        if (await inputFile.exists()) await inputFile.delete();
      } catch (_) {}
    }
  }

  Future<void> _pickImage(ImageSource source) async {
    if (_students.isEmpty ||
        _currentIndex >= _students.length ||
        _processing ||
        _saving) {
      return;
    }

    try {
      final picked = await pickEmisImage(
        source: source,
        imageQuality: 90,
        maxWidth: 2500,
        maxHeight: 2500,
      );
      if (picked == null || !mounted) return;

      final originalFile = File(picked.path);

      setState(() {
        _currentImage = originalFile;
        _backgroundRemovedForCurrentImage = false;
      });
    } catch (e) {
      debugPrint('Batch photo processing error: $e');
      if (mounted) {
        setState(() => _processing = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('تعذر معالجة الصورة: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _removeBackgroundFromCurrentImage() async {
    if (_currentImage == null ||
        _processing ||
        _saving ||
        _backgroundRemovedForCurrentImage) {
      return;
    }

    final currentImage = _currentImage!;
    setState(() => _processing = true);

    try {
      final processed = await _removeBackground(currentImage);
      if (!mounted) return;

      setState(() {
        _currentImage = processed;
        _backgroundRemovedForCurrentImage = true;
        _processing = false;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('تمت إزالة الخلفية من صورة الطالب'),
        ),
      );
    } catch (e) {
      debugPrint('Manual background removal error: $e');
      if (!mounted) return;

      setState(() => _processing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('تعذر إزالة الخلفية: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _takePhoto() => _pickImage(ImageSource.camera);

  Future<void> _pickFromGallery() => _pickImage(ImageSource.gallery);

  Future<void> _showImagePreview() async {
    final image = _currentImage;
    if (image == null || !mounted) return;

    await showDialog<void>(
      context: context,
      barrierColor: Colors.black87,
      builder: (dialogContext) {
        return Dialog(
          insetPadding: const EdgeInsets.all(10),
          backgroundColor: Colors.black,
          child: Stack(
            children: [
              Positioned.fill(
                child: InteractiveViewer(
                  minScale: 0.5,
                  maxScale: 6.0,
                  boundaryMargin: const EdgeInsets.all(100),
                  panEnabled: true,
                  scaleEnabled: true,
                  child: Center(
                    child: Image.file(
                      image,
                      fit: BoxFit.contain,
                    ),
                  ),
                ),
              ),
              Positioned(
                top: 8,
                right: 8,
                child: Material(
                  color: Colors.black54,
                  shape: const CircleBorder(),
                  child: IconButton(
                    onPressed: () => Navigator.of(dialogContext).pop(),
                    icon: const Icon(Icons.close, color: Colors.white),
                    tooltip: 'إغلاق',
                  ),
                ),
              ),
              const Positioned(
                left: 0,
                right: 0,
                bottom: 10,
                child: IgnorePointer(
                  child: Center(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.all(Radius.circular(20)),
                      ),
                      child: Padding(
                        padding:
                            EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                        child: Text(
                          'قرّب أو أبعد بإصبعين واسحب الصورة للتحريك',
                          style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                              fontSize: 12),
                        ),
                      ),
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

  void _skipCurrentStudent() {
    if (_students.isEmpty ||
        _currentIndex >= _students.length ||
        _processing ||
        _saving) {
      return;
    }

    final student = _students[_currentIndex];
    final id = _studentId(student);
    if (id.isEmpty) return;

    setState(() {
      _skipped.add(id);
      _notPhotographed.add(id);
      _currentImage = null;
      _backgroundRemovedForCurrentImage = false;
      _currentIndex = _onlyMissingPhotosMode
          ? _nextPendingIndexFrom(_currentIndex + 1)
          : (_currentIndex == _students.length - 1
              ? _students.length
              : _currentIndex + 1);
    });

    _persistSession();

    if (_currentIndex >= _students.length && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('تم الانتهاء من القائمة المحددة. يمكنك مراجعة التقرير.'),
        ),
      );
    }
  }

  Future<String?> _uploadImage(File imageFile) async {
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('https://emis.moedu.gov.iq/api/student/uploadimage'),
    );
    request.headers['Authorization'] = widget.token;
    request.headers['Accept'] = 'application/json';
    request.files.add(await http.MultipartFile.fromPath('image', imageFile.path,
        filename: 'avatar.png'));

    final response = await request.send();
    final body = await response.stream.bytesToString();
    if (response.statusCode != 200) {
      debugPrint('Image upload failed ${response.statusCode}: $body');
      return null;
    }
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) return decoded['imageUrl']?.toString();
    } catch (_) {}
    return null;
  }

  Future<Map<String, dynamic>> _fetchFullStudent(String id) async {
    final response = await http.get(
      Uri.parse('https://emis.moedu.gov.iq/api/student/getstudent/$id'),
      headers: _headers,
    );

    final body = utf8.decode(response.bodyBytes);
    if (response.statusCode != 200) {
      throw Exception('تعذر جلب بيانات الطالب الكاملة (${response.statusCode})');
    }

    final decoded = jsonDecode(body);
    if (decoded is Map<String, dynamic>) {
      final data = decoded['data'];
      if (data is Map) return Map<String, dynamic>.from(data);
      return Map<String, dynamic>.from(decoded);
    }

    throw Exception('استجابة بيانات الطالب غير صالحة');
  }

  Future<bool> _saveCurrentStudent() async {
    if (_students.isEmpty ||
        _currentIndex >= _students.length ||
        _currentImage == null) return false;
    final listedStudent = _students[_currentIndex];
    final id = _studentId(listedStudent);
    if (id.isEmpty) return false;

    setState(() => _saving = true);
    try {
      final fullStudent = await _fetchFullStudent(id);

      final imageUrl = await _uploadImage(_currentImage!);
      if (imageUrl == null || imageUrl.isEmpty) {
        throw Exception('تعذر رفع الصورة إلى EMIS');
      }

      fullStudent['imageUrl'] = imageUrl;

      final response = await http.post(
        Uri.parse('https://emis.moedu.gov.iq/api/student/updatestudent'),
        headers: {
          'Authorization': widget.token,
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
        body: jsonEncode(fullStudent),
      );

      final responseBody = utf8.decode(response.bodyBytes);

      if (response.statusCode != 200 && response.statusCode != 204) {
        String details = responseBody.trim();
        if (details.length > 500) details = details.substring(0, 500);
        throw Exception(
          details.isEmpty
              ? 'فشل حفظ بيانات الطالب (${response.statusCode})'
              : 'فشل حفظ بيانات الطالب (${response.statusCode}): $details',
        );
      }

      listedStudent['imageUrl'] = imageUrl;
      _imageCache[id] = imageUrl;
      _existingPhotoIds.add(id);
      unawaited(_persistImageCache());

      final originalIndex = _allStudentsList.indexWhere(
        (s) => _studentId(s) == id,
      );
      if (originalIndex >= 0) {
        _allStudentsList[originalIndex]['imageUrl'] = imageUrl;
      }

      final widgetIdx = widget.allStudents.indexWhere(
        (s) => s is Map && s['id']?.toString() == id,
      );
      if (widgetIdx >= 0 && widget.allStudents[widgetIdx] is Map) {
        widget.allStudents[widgetIdx]['imageUrl'] = imageUrl;
      }

      _photographed.add(id);
      _notPhotographed.remove(id);
      _skipped.remove(id);
      await _persistSession();
      return true;
    } catch (e) {
      debugPrint('Batch save error: $e');
      _notPhotographed.add(id);
      await _persistSession();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('فشل حفظ الطالب: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
      return false;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _previousStudent() {
    if (_currentIndex <= 0 || _saving || _processing || _students.isEmpty) {
      return;
    }
    setState(() {
      _currentIndex = _previousPendingIndexFrom(_currentIndex - 1);
      _currentImage = null;
      _backgroundRemovedForCurrentImage = false;
    });
  }

  Future<void> _nextStudent() async {
    if (_currentImage == null || _saving || _processing) return;
    final saved = await _saveCurrentStudent();
    if (!saved || !mounted) return;

    setState(() {
      _currentImage = null;
      _backgroundRemovedForCurrentImage = false;
      _currentIndex = _onlyMissingPhotosMode
          ? _nextPendingIndexFrom(_currentIndex + 1)
          : (_currentIndex == _students.length - 1
              ? _students.length
              : _currentIndex + 1);
    });
  }

  Future<void> _restart() async {
    if (_students.isEmpty) return;
    await _scanClassroomStudentPhotos(forceNetworkCheck: false);
  }

  void _resume() {
    setState(() {
      _currentIndex = _firstPendingIndex(_students);
      _currentImage = null;
      _backgroundRemovedForCurrentImage = false;
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _scanGeneration++;
    _ambientController.dispose();
    _segmenter?.close();
    super.dispose();
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

    return AnimatedBuilder(
      animation: _ambientController,
      builder: (context, _) {
        final pulse =
            0.5 + 0.5 * math.sin(_ambientController.value * 2 * math.pi);

        return Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
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
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: purpleNeon.withOpacity(isDark ? 0.50 : 0.32),
              width: 1.5,
            ),
            boxShadow: [
              BoxShadow(
                color: purpleNeon.withOpacity(0.12 + pulse * 0.08),
                blurRadius: 20,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Row(
            children: [
              _AnimatedBatchPhotosOrbIcon(
                icon: Icons.camera_front_rounded,
                primaryColor: purpleNeon,
                secondaryColor: goldNeon,
                animation: _ambientController,
                size: 52,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'أدوات ذكية متقدمة',
                      style: TextStyle(
                        color: isDark ? goldNeon : purpleNeon,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'إضافة صور الطلاب جماعيًا',
                      style: TextStyle(
                        color: isDark ? Colors.white : const Color(0xFF0F172A),
                        fontSize: 16.5,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              GestureDetector(
                onTap: () => Navigator.of(context).pop(),
                child: Container(
                  width: 40,
                  height: 40,
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
                    size: 18,
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

  // الستارة القابلة للطي والفتح المختصة بالصف والشعبة والتقرير والإحصائيات
  Widget _buildCollapsibleCurtain(
    bool isDark,
    Color text,
    int photographedCount,
    int skippedCount,
    int remaining,
  ) {
    const purpleNeon = Color(0xFFA855F7);
    const emeraldNeon = Color(0xFF10B981);
    const goldNeon = Color(0xFFF59E0B);
    const blueNeon = Color(0xFF3B82F6);

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: BoxDecoration(
        gradient: isDark
            ? LinearGradient(
                colors: [
                  const Color(0xFF141829).withOpacity(0.96),
                  Color.lerp(const Color(0xFF0F1322), purpleNeon, 0.08)!,
                ],
              )
            : LinearGradient(
                colors: [
                  Colors.white.withOpacity(0.98),
                  const Color(0xFFF8FAFC).withOpacity(0.95),
                ],
              ),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: purpleNeon.withOpacity(isDark ? 0.45 : 0.30),
          width: 1.3,
        ),
        boxShadow: [
          BoxShadow(
            color: purpleNeon.withOpacity(isDark ? 0.12 : 0.06),
            blurRadius: 14,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(22),
            onTap: () => setState(() => _isCurtainOpen = !_isCurtainOpen),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: purpleNeon.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      _isCurtainOpen
                          ? Icons.keyboard_arrow_up_rounded
                          : Icons.keyboard_arrow_down_rounded,
                      color: purpleNeon,
                      size: 22,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _selectedStage == null || _selectedClassRoom == null
                              ? 'ستارة الصف والشعبة والتقرير'
                              : '$_selectedStage - شعبة $_selectedClassRoom',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: text,
                            fontWeight: FontWeight.w900,
                            fontSize: 13.5,
                          ),
                        ),
                        if (!_isCurtainOpen && _students.isNotEmpty)
                          Text(
                            'المجموع: ${_students.length} | مصور: $photographedCount | متبقٍ: $remaining',
                            style: TextStyle(
                              color: isDark
                                  ? const Color(0xFF94A3B8)
                                  : const Color(0xFF64748B),
                              fontWeight: FontWeight.w700,
                              fontSize: 11,
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (_students.isNotEmpty) ...[
                    TextButton.icon(
                      onPressed: _scanningRecords
                          ? null
                          : () => _scanClassroomStudentPhotos(
                              forceNetworkCheck: true),
                      style: TextButton.styleFrom(
                        foregroundColor: blueNeon,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      icon: const Icon(Icons.sync_rounded, size: 17),
                      label: const Text(
                        'فحص',
                        style: TextStyle(
                            fontWeight: FontWeight.w900, fontSize: 12),
                      ),
                    ),
                    const SizedBox(width: 4),
                    TextButton.icon(
                      onPressed: _showReport,
                      style: TextButton.styleFrom(
                        foregroundColor: purpleNeon,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      icon: const Icon(Icons.assessment_outlined, size: 17),
                      label: const Text(
                        'التقرير',
                        style: TextStyle(
                            fontWeight: FontWeight.w900, fontSize: 12),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          AnimatedCrossFade(
            duration: const Duration(milliseconds: 250),
            crossFadeState: _isCurtainOpen
                ? CrossFadeState.showFirst
                : CrossFadeState.showSecond,
            secondChild: const SizedBox(width: double.infinity, height: 0),
            firstChild: Padding(
              padding: const EdgeInsets.fromLTRB(14, 2, 14, 14),
              child: Column(
                children: [
                  const Divider(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: _drop(
                          'اختر الصف',
                          _selectedStage,
                          _stages
                              .map((s) => {'value': s, 'label': s})
                              .toList(),
                          _processing || _saving || _scanningRecords
                              ? null
                              : _selectStage,
                          isDark,
                          text,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _drop(
                          'اختر الشعبة',
                          _selectedClassRoom,
                          _classRooms
                              .map((s) => {'value': s, 'label': s})
                              .toList(),
                          _selectedStage == null ||
                                  _processing ||
                                  _saving ||
                                  _scanningRecords
                              ? null
                              : _selectClassRoom,
                          isDark,
                          text,
                        ),
                      ),
                    ],
                  ),
                  if (_students.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          vertical: 10, horizontal: 8),
                      decoration: BoxDecoration(
                        color: isDark
                            ? const Color(0xFF0B0E1A).withOpacity(0.6)
                            : const Color(0xFFF1F5F9),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                            color:
                                purpleNeon.withOpacity(isDark ? 0.25 : 0.18)),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                              child: _counter('المجموع', '${_students.length}',
                                  purpleNeon)),
                          Expanded(
                              child: _counter('تم التصوير',
                                  '$photographedCount', emeraldNeon)),
                          Expanded(
                              child:
                                  _counter('متبقٍ', '$remaining', goldNeon)),
                          Expanded(
                              child: _counter('متجاهل', '$skippedCount',
                                  const Color(0xFFEF4444))),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: AppCore.themeNotifier,
      builder: (context, mode, child) {
        final isDark = mode == ThemeMode.dark;
        final bg = isDark ? const Color(0xFF070913) : const Color(0xFFF2F5FA);
        final text = isDark ? Colors.white : const Color(0xFF0F172A);
        final selectedStudent =
            _students.isNotEmpty && _currentIndex < _students.length
                ? _students[_currentIndex]
                : null;
        final photographedCount = _photographed.length;
        final skippedCount = _skipped.length;
        final remaining =
            (_students.length - photographedCount - skippedCount)
                .clamp(0, _students.length);

        const purpleNeon = Color(0xFFA855F7);
        const emeraldNeon = Color(0xFF10B981);
        const goldNeon = Color(0xFFF59E0B);
        const blueNeon = Color(0xFF3B82F6);

        return Directionality(
          textDirection: TextDirection.rtl,
          child: Scaffold(
            backgroundColor: bg,
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
                        padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
                        child: _buildTopHeader(isDark),
                      ),
                      _buildCollapsibleCurtain(
                        isDark,
                        text,
                        photographedCount,
                        skippedCount,
                        remaining,
                      ),
                      if (_restoringSession || _loadingAllStudents)
                        const Padding(
                          padding:
                              EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                          child: LinearProgressIndicator(
                              minHeight: 3, color: purpleNeon),
                        ),
                      if (_scanningRecords)
                        Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 6),
                          child: Container(
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: isDark
                                  ? const Color(0xFF141829)
                                  : Colors.white,
                              borderRadius: BorderRadius.circular(18),
                              border: Border.all(
                                  color: blueNeon.withOpacity(0.45)),
                            ),
                            child: Column(
                              children: [
                                Row(
                                  children: [
                                    const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2.2, color: blueNeon),
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Text(
                                        'جاري فحص والتحقق من صور طلاب الشعبة... ($_scanLoadedCount / $_scanTotalCount)',
                                        style: TextStyle(
                                          color: text,
                                          fontWeight: FontWeight.w900,
                                          fontSize: 12.5,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: LinearProgressIndicator(
                                    value: _scanTotalCount > 0
                                        ? _scanLoadedCount / _scanTotalCount
                                        : null,
                                    minHeight: 6,
                                    color: emeraldNeon,
                                    backgroundColor:
                                        blueNeon.withOpacity(0.15),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      Expanded(
                        child: _scanningRecords
                            ? Center(
                                child: Text(
                                  'يرجى الانتظار لحين اكتمال فحص صور طلاب الشعبة...',
                                  style: TextStyle(
                                    fontWeight: FontWeight.w900,
                                    color: isDark
                                        ? const Color(0xFF94A3B8)
                                        : const Color(0xFF64748B),
                                    fontSize: 14,
                                  ),
                                ),
                              )
                            : selectedStudent == null
                                ? Center(
                                    child: Padding(
                                      padding: const EdgeInsets.all(24),
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(
                                            _students.isEmpty
                                                ? Icons.class_outlined
                                                : Icons
                                                    .check_circle_outline_rounded,
                                            size: 64,
                                            color: _students.isEmpty
                                                ? purpleNeon.withOpacity(0.6)
                                                : emeraldNeon,
                                          ),
                                          const SizedBox(height: 12),
                                          Text(
                                            _students.isEmpty
                                                ? 'اختر الصف والشعبة من الستارة أعلاه لبدء فحص وتصوير الطلاب'
                                                : 'اكتملت معالجة الطلاب المحددين في هذه الشعبة.',
                                            textAlign: TextAlign.center,
                                            style: TextStyle(
                                              fontWeight: FontWeight.w900,
                                              color: isDark
                                                  ? const Color(0xFF94A3B8)
                                                  : const Color(0xFF64748B),
                                              fontSize: 15,
                                            ),
                                          ),
                                          if (_students.isNotEmpty) ...[
                                            const SizedBox(height: 16),
                                            Wrap(
                                              spacing: 10,
                                              runSpacing: 10,
                                              alignment: WrapAlignment.center,
                                              children: [
                                                FilledButton.icon(
                                                  onPressed: _showReport,
                                                  icon: const Icon(Icons
                                                      .assessment_outlined),
                                                  label: const Text(
                                                    'عرض التقرير',
                                                    style: TextStyle(
                                                        fontWeight:
                                                            FontWeight.bold),
                                                  ),
                                                  style: FilledButton.styleFrom(
                                                    backgroundColor: purpleNeon,
                                                  ),
                                                ),
                                                OutlinedButton.icon(
                                                  onPressed: _restart,
                                                  icon: const Icon(
                                                      Icons.restart_alt_rounded),
                                                  label: const Text(
                                                    'خيارات الفحص والتصوير',
                                                    style: TextStyle(
                                                        fontWeight:
                                                            FontWeight.bold),
                                                  ),
                                                  style:
                                                      OutlinedButton.styleFrom(
                                                    foregroundColor: goldNeon,
                                                    side: const BorderSide(
                                                        color: goldNeon),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ],
                                        ],
                                      ),
                                    ),
                                  )
                                : ListView(
                                    padding: const EdgeInsets.fromLTRB(
                                        16, 4, 16, 28),
                                    physics: const BouncingScrollPhysics(),
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.all(18),
                                        decoration: BoxDecoration(
                                          gradient: isDark
                                              ? LinearGradient(
                                                  begin: Alignment.topLeft,
                                                  end: Alignment.bottomRight,
                                                  colors: [
                                                    const Color(0xFF141829)
                                                        .withOpacity(0.95),
                                                    Color.lerp(
                                                        const Color(0xFF0F1322),
                                                        blueNeon,
                                                        0.08)!,
                                                  ],
                                                )
                                              : LinearGradient(
                                                  begin: Alignment.topLeft,
                                                  end: Alignment.bottomRight,
                                                  colors: [
                                                    Colors.white
                                                        .withOpacity(0.96),
                                                    Color.lerp(
                                                        const Color(0xFFF8FAFC),
                                                        blueNeon,
                                                        0.04)!,
                                                  ],
                                                ),
                                          borderRadius:
                                              BorderRadius.circular(24),
                                          border: Border.all(
                                            color: blueNeon.withOpacity(
                                                isDark ? 0.45 : 0.30),
                                            width: 1.3,
                                          ),
                                        ),
                                        child: Column(
                                          children: [
                                            Row(
                                              mainAxisAlignment:
                                                  MainAxisAlignment.center,
                                              children: [
                                                Text(
                                                  'الطالب ${_currentIndex + 1} من ${_students.length}',
                                                  style: TextStyle(
                                                    color: isDark
                                                        ? const Color(
                                                            0xFF94A3B8)
                                                        : const Color(
                                                            0xFF64748B),
                                                    fontWeight: FontWeight.w900,
                                                    fontSize: 12.5,
                                                  ),
                                                ),
                                                const SizedBox(width: 8),
                                                Container(
                                                  padding: const EdgeInsets
                                                      .symmetric(
                                                      horizontal: 8,
                                                      vertical: 2),
                                                  decoration: BoxDecoration(
                                                    color: (_hasValidImage(
                                                                selectedStudent)
                                                            ? emeraldNeon
                                                            : goldNeon)
                                                        .withOpacity(0.15),
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                            10),
                                                  ),
                                                  child: Text(
                                                    _hasValidImage(
                                                            selectedStudent)
                                                        ? 'لديه صورة بالسجل'
                                                        : 'بدون صورة بالسجل',
                                                    style: TextStyle(
                                                      color: _hasValidImage(
                                                              selectedStudent)
                                                          ? emeraldNeon
                                                          : goldNeon,
                                                      fontWeight:
                                                          FontWeight.w900,
                                                      fontSize: 10.5,
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ),
                                            const SizedBox(height: 6),
                                            Text(
                                              _studentName(selectedStudent),
                                              textAlign: TextAlign.center,
                                              style: TextStyle(
                                                color: text,
                                                fontSize: 20,
                                                fontWeight: FontWeight.w900,
                                              ),
                                            ),
                                            const SizedBox(height: 14),
                                            Container(
                                              height: 270,
                                              width: double.infinity,
                                              decoration: BoxDecoration(
                                                color: isDark
                                                    ? const Color(0xFF0B0E1A)
                                                    : const Color(0xFFF1F5F9),
                                                borderRadius:
                                                    BorderRadius.circular(18),
                                                border: Border.all(
                                                  color: purpleNeon
                                                      .withOpacity(0.3),
                                                ),
                                              ),
                                              child: _processing
                                                  ? Center(
                                                      child: Column(
                                                        mainAxisSize:
                                                            MainAxisSize.min,
                                                        children: [
                                                          const CircularProgressIndicator(
                                                              color:
                                                                  purpleNeon),
                                                          const SizedBox(
                                                              height: 12),
                                                          Text(
                                                            'جاري إزالة الخلفية محليًا...',
                                                            style: TextStyle(
                                                              fontWeight:
                                                                  FontWeight
                                                                      .w900,
                                                              color: text,
                                                            ),
                                                          ),
                                                        ],
                                                      ),
                                                    )
                                                  : _currentImage == null
                                                      ? const Center(
                                                          child: Icon(
                                                            Icons
                                                                .person_outline_rounded,
                                                            size: 90,
                                                            color: Colors.grey,
                                                          ),
                                                        )
                                                      : ClipRRect(
                                                          borderRadius:
                                                              BorderRadius
                                                                  .circular(18),
                                                          child:
                                                              GestureDetector(
                                                            behavior:
                                                                HitTestBehavior
                                                                    .opaque,
                                                            onDoubleTap:
                                                                _showImagePreview,
                                                            child:
                                                                InteractiveViewer(
                                                              minScale: 1.0,
                                                              maxScale: 4.0,
                                                              panEnabled: true,
                                                              scaleEnabled:
                                                                  true,
                                                              boundaryMargin:
                                                                  const EdgeInsets
                                                                      .all(40),
                                                              child: Image.file(
                                                                _currentImage!,
                                                                fit: BoxFit
                                                                    .contain,
                                                              ),
                                                            ),
                                                          ),
                                                        ),
                                            ),
                                            const SizedBox(height: 16),
                                            Row(
                                              children: [
                                                Expanded(
                                                  child: FilledButton.icon(
                                                    onPressed: _processing ||
                                                            _saving
                                                        ? null
                                                        : _takePhoto,
                                                    icon: const Icon(
                                                        Icons
                                                            .camera_alt_rounded,
                                                        color: Colors.white,
                                                        size: 20),
                                                    label: Text(
                                                      _currentImage == null
                                                          ? 'الكاميرا'
                                                          : 'إعادة التصوير',
                                                      style: const TextStyle(
                                                        color: Colors.white,
                                                        fontSize: 15,
                                                        fontWeight:
                                                            FontWeight.w900,
                                                      ),
                                                    ),
                                                    style:
                                                        FilledButton.styleFrom(
                                                      backgroundColor: blueNeon,
                                                      minimumSize:
                                                          const Size.fromHeight(
                                                              50),
                                                      shape:
                                                          RoundedRectangleBorder(
                                                        borderRadius:
                                                            BorderRadius
                                                                .circular(16),
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                                const SizedBox(width: 10),
                                                Expanded(
                                                  child: OutlinedButton.icon(
                                                    onPressed: _processing ||
                                                            _saving
                                                        ? null
                                                        : _pickFromGallery,
                                                    icon: const Icon(
                                                        Icons
                                                            .photo_library_outlined,
                                                        size: 20),
                                                    label: const Text(
                                                      'من الجهاز',
                                                      style: TextStyle(
                                                        fontSize: 15,
                                                        fontWeight:
                                                            FontWeight.w900,
                                                      ),
                                                    ),
                                                    style: OutlinedButton
                                                        .styleFrom(
                                                      foregroundColor:
                                                          purpleNeon,
                                                      minimumSize:
                                                          const Size.fromHeight(
                                                              50),
                                                      side: BorderSide(
                                                          color: purpleNeon
                                                              .withOpacity(
                                                                  0.4)),
                                                      shape:
                                                          RoundedRectangleBorder(
                                                        borderRadius:
                                                            BorderRadius
                                                                .circular(16),
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ),
                                            const SizedBox(height: 12),
                                            SizedBox(
                                              width: double.infinity,
                                              height: 52,
                                              child: FilledButton.icon(
                                                onPressed: _currentImage ==
                                                            null ||
                                                        _processing ||
                                                        _saving ||
                                                        _backgroundRemovedForCurrentImage
                                                    ? null
                                                    : _removeBackgroundFromCurrentImage,
                                                icon: const Icon(
                                                  Icons.auto_fix_high_rounded,
                                                  color: Colors.white,
                                                  size: 20,
                                                ),
                                                label: Text(
                                                  _backgroundRemovedForCurrentImage
                                                      ? 'تمت إزالة الخلفية'
                                                      : 'إزالة الخلفية',
                                                  style: const TextStyle(
                                                    color: Colors.white,
                                                    fontSize: 15,
                                                    fontWeight:
                                                        FontWeight.w900,
                                                  ),
                                                ),
                                                style: FilledButton.styleFrom(
                                                  backgroundColor: purpleNeon,
                                                  disabledBackgroundColor:
                                                      isDark
                                                          ? Colors.white12
                                                          : Colors
                                                              .grey.shade300,
                                                  disabledForegroundColor:
                                                      Colors.grey,
                                                  shape: RoundedRectangleBorder(
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                            16),
                                                  ),
                                                ),
                                              ),
                                            ),
                                            if (_currentImage != null) ...[
                                              const SizedBox(height: 10),
                                              SizedBox(
                                                width: double.infinity,
                                                height: 52,
                                                child: FilledButton.icon(
                                                  onPressed: _saving ||
                                                          _processing
                                                      ? null
                                                      : _nextStudent,
                                                  icon: _saving
                                                      ? const SizedBox(
                                                          width: 20,
                                                          height: 20,
                                                          child:
                                                              CircularProgressIndicator(
                                                            strokeWidth: 2,
                                                            color: Colors.white,
                                                          ),
                                                        )
                                                      : const Icon(
                                                          Icons
                                                              .arrow_forward_rounded,
                                                          color: Colors.white,
                                                          size: 20,
                                                        ),
                                                  label: Text(
                                                    _saving
                                                        ? 'جاري الحفظ...'
                                                        : 'حفظ الطالب والانتقال للتالي',
                                                    style: const TextStyle(
                                                      color: Colors.white,
                                                      fontSize: 15,
                                                      fontWeight:
                                                          FontWeight.w900,
                                                    ),
                                                  ),
                                                  style: FilledButton.styleFrom(
                                                    backgroundColor:
                                                        emeraldNeon,
                                                    shape:
                                                        RoundedRectangleBorder(
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                              16),
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            ],
                                            const SizedBox(height: 10),
                                            OutlinedButton.icon(
                                              onPressed: _currentIndex <= 0 ||
                                                      _processing ||
                                                      _saving
                                                  ? null
                                                  : _previousStudent,
                                              icon: const Icon(
                                                  Icons.arrow_back_rounded,
                                                  size: 18),
                                              label: const Text(
                                                'الرجوع إلى الطالب السابق',
                                                style: TextStyle(
                                                    fontSize: 14.5,
                                                    fontWeight:
                                                        FontWeight.w900),
                                              ),
                                              style: OutlinedButton.styleFrom(
                                                foregroundColor: text,
                                                minimumSize:
                                                    const Size.fromHeight(48),
                                                side: BorderSide(
                                                    color: Colors.grey
                                                        .withOpacity(0.3)),
                                                shape: RoundedRectangleBorder(
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                            16)),
                                              ),
                                            ),
                                            const SizedBox(height: 10),
                                            OutlinedButton.icon(
                                              onPressed: _processing || _saving
                                                  ? null
                                                  : _skipCurrentStudent,
                                              icon: const Icon(
                                                Icons.skip_next_rounded,
                                                color: Color(0xFFEF4444),
                                                size: 20,
                                              ),
                                              label: const Text(
                                                'تجاهل الطالب (غائب)',
                                                style: TextStyle(
                                                  color: Color(0xFFEF4444),
                                                  fontSize: 15,
                                                  fontWeight: FontWeight.w900,
                                                ),
                                              ),
                                              style: OutlinedButton.styleFrom(
                                                minimumSize:
                                                    const Size.fromHeight(48),
                                                side: const BorderSide(
                                                    color: Color(0xFFEF4444)),
                                                shape: RoundedRectangleBorder(
                                                  borderRadius:
                                                      BorderRadius.circular(16),
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      const SizedBox(height: 14),
                                      Row(
                                        children: [
                                          Expanded(
                                            child: OutlinedButton.icon(
                                              onPressed: photographedCount ==
                                                          0 &&
                                                      skippedCount == 0
                                                  ? null
                                                  : _resume,
                                              icon: const Icon(
                                                  Icons.play_arrow_rounded,
                                                  size: 18),
                                              label: const Text('استكمال',
                                                  style: TextStyle(
                                                      fontWeight:
                                                          FontWeight.w900)),
                                              style: OutlinedButton.styleFrom(
                                                foregroundColor: emeraldNeon,
                                                side: BorderSide(
                                                    color: emeraldNeon
                                                        .withOpacity(0.4)),
                                                shape: RoundedRectangleBorder(
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                            16)),
                                              ),
                                            ),
                                          ),
                                          const SizedBox(width: 10),
                                          Expanded(
                                            child: OutlinedButton.icon(
                                              onPressed: _students.isEmpty
                                                  ? null
                                                  : _restart,
                                              icon: const Icon(
                                                  Icons.restart_alt_rounded,
                                                  size: 18),
                                              label: const Text(
                                                  'خيارات الفحص والبدء',
                                                  style: TextStyle(
                                                      fontWeight:
                                                          FontWeight.w900)),
                                              style: OutlinedButton.styleFrom(
                                                foregroundColor: goldNeon,
                                                side: BorderSide(
                                                    color: goldNeon
                                                        .withOpacity(0.4)),
                                                shape: RoundedRectangleBorder(
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                            16)),
                                              ),
                                            ),
                                          ),
                                        ],
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

  Widget _drop(
    String label,
    String? value,
    List<Map<String, dynamic>> data,
    ValueChanged<String?>? onChanged,
    bool isDark,
    Color textColor,
  ) {
    const purpleNeon = Color(0xFFA855F7);
    final mutedColor =
        isDark ? const Color(0xFF94A3B8) : const Color(0xFF475569);

    return DropdownButtonFormField<String>(
      value: data.any((x) => x['value'] == value) ? value : null,
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
            const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
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
          .map((x) => DropdownMenuItem(
                value: x['value']?.toString(),
                child: Text(
                  x['label']?.toString() ?? '',
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
      onChanged: onChanged,
    );
  }

  Widget _counter(String title, String value, Color color) => Column(
        children: [
          Text(
            value,
            style: TextStyle(
              color: color,
              fontSize: 19,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            title,
            style: const TextStyle(
              fontWeight: FontWeight.w700,
              color: Colors.grey,
              fontSize: 11,
            ),
          ),
        ],
      );

  Future<void> _showReport() async {
    final photographed = _students
        .where((s) => _photographed.contains(_studentId(s)))
        .toList();
    final skipped =
        _students.where((s) => _skipped.contains(_studentId(s))).toList();
    final notPhotographed = _students
        .where(
          (s) =>
              !_photographed.contains(_studentId(s)) &&
              !_skipped.contains(_studentId(s)),
        )
        .toList();
    final isDark = AppCore.themeNotifier.value == ThemeMode.dark;

    await showDialog<void>(
      context: context,
      builder: (context) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          backgroundColor:
              isDark ? const Color(0xFF141829) : const Color(0xFFFFFFFF),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
            side: BorderSide(
              color: const Color(0xFFA855F7).withOpacity(0.45),
              width: 1.5,
            ),
          ),
          title: Text(
            'تقرير التصوير (${_selectedStage ?? ''} - ${_selectedClassRoom ?? ''})',
            style: TextStyle(
              color: isDark ? Colors.white : const Color(0xFF0F172A),
              fontWeight: FontWeight.w900,
              fontSize: 16,
            ),
          ),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'لديهم صور / تم تصويرهم: ${photographed.length}',
                    style: const TextStyle(
                      color: Color(0xFF10B981),
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 8),
                  ...photographed.map((s) => Text(
                        '✓ ${_studentName(s)}',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: isDark
                              ? const Color(0xFFCBD5E1)
                              : const Color(0xFF475569),
                        ),
                      )),
                  const Divider(height: 25),
                  Text(
                    'تم تجاهلهم (غائب): ${skipped.length}',
                    style: const TextStyle(
                      color: Color(0xFFEF4444),
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 8),
                  ...skipped.map((s) => Text(
                        '⏭ ${_studentName(s)}',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: isDark
                              ? const Color(0xFFCBD5E1)
                              : const Color(0xFF475569),
                        ),
                      )),
                  const Divider(height: 25),
                  Text(
                    'لم يتم تصويرهم بعد: ${notPhotographed.length}',
                    style: const TextStyle(
                      color: Color(0xFFF59E0B),
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 8),
                  ...notPhotographed.map((s) => Text(
                        '• ${_studentName(s)}',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: isDark
                              ? const Color(0xFFCBD5E1)
                              : const Color(0xFF475569),
                        ),
                      )),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(
                'إغلاق',
                style: TextStyle(
                  color: isDark
                      ? const Color(0xFF94A3B8)
                      : const Color(0xFF64748B),
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AnimatedBatchPhotosOrbIcon extends StatelessWidget {
  final IconData icon;
  final Color primaryColor;
  final Color secondaryColor;
  final Animation<double> animation;
  final double size;

  const _AnimatedBatchPhotosOrbIcon({
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
                  painter: _BatchPhotosAtomOrbitPainter(
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

class _BatchPhotosAtomOrbitPainter extends CustomPainter {
  final double progress;
  final Color primaryColor;
  final Color secondaryColor;

  _BatchPhotosAtomOrbitPainter({
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
  bool shouldRepaint(covariant _BatchPhotosAtomOrbitPainter oldDelegate) =>
      oldDelegate.progress != progress;
}
