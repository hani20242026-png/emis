import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';

import 'app_core.dart';
import 'selfie_background_remover.dart';

class BatchTeacherPhotosScreen extends StatefulWidget {
  final String token;
  final String schoolId;
  final List<dynamic> allTeachers;

  const BatchTeacherPhotosScreen({
    super.key,
    required this.token,
    required this.schoolId,
    required this.allTeachers,
  });

  @override
  State<BatchTeacherPhotosScreen> createState() =>
      _BatchTeacherPhotosScreenState();
}

enum _TeacherPhotoStatus {
  waiting,
  processing,
  uploading,
  success,
  failed,
}

class _TeacherPhotoItem {
  final Map<String, dynamic> teacher;
  final String fullName;
  final String identifier;
  final String currentImageUrl;
  final File originalFile;
  File? processedFile;
  bool removeBackground;
  _TeacherPhotoStatus status;
  String? statusMessage;

  _TeacherPhotoItem({
    required this.teacher,
    required this.fullName,
    required this.identifier,
    required this.currentImageUrl,
    required this.originalFile,
    this.processedFile,
    this.removeBackground = false,
    this.status = _TeacherPhotoStatus.waiting,
    this.statusMessage,
  });
}

class _BatchTeacherPhotosScreenState extends State<BatchTeacherPhotosScreen>
    with SingleTickerProviderStateMixin {
  final List<_TeacherPhotoItem> _items = [];
  final Map<String, String> _fullTeacherCache = {};

  bool _isSelectionMode = false;
  final Set<int> _selectedIndices = {};

  bool _isBatchWorking = false;
  int _completedCount = 0;
  int _failedCount = 0;
  bool _cancelRequested = false;

  late final AnimationController _ambientCollectionController;

  bool get _isDesktop =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  @override
  void initState() {
    super.initState();
    _ambientCollectionController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 6),
    )..repeat();
  }

  @override
  void dispose() {
    _ambientCollectionController.dispose();
    SelfieBackgroundRemover.dispose();
    super.dispose();
  }

  String _extractTeacherId(dynamic teacher) {
    if (teacher is! Map) return '';
    for (final k in ['id', 'teacherId', 'employeeId', 'userId', 'personId']) {
      final v = teacher[k];
      if (v != null && v.toString().trim().isNotEmpty && v.toString() != 'null') {
        return v.toString().trim();
      }
    }
    return '';
  }

  String _extractTeacherName(dynamic teacher) {
    if (teacher is! Map) return 'معلم غير معروف';
    final direct = teacher['fullName'] ??
        teacher['teacherName'] ??
        teacher['displayName'] ??
        teacher['name'];
    if (direct != null && direct.toString().trim().isNotEmpty) {
      return direct.toString().trim();
    }
    final parts = [
      teacher['firstName'],
      teacher['name'],
      teacher['fatherName'],
      teacher['grandFatherName'],
      teacher['fathersGrandFatherName'],
      teacher['surName'],
    ]
        .map((e) => e?.toString().trim() ?? '')
        .where((e) => e.isNotEmpty)
        .toList();
    return parts.isEmpty ? 'معلم غير معروف' : parts.join(' ');
  }

  String _extractTeacherIdentifier(dynamic teacher) {
    if (teacher is! Map) return '';
    for (final k in [
      'nationalIdNumber',
      'employeeIdNumber',
      'idNumber',
      'jobNumber',
      'code',
    ]) {
      final v = teacher[k];
      if (v != null && v.toString().trim().isNotEmpty && v.toString() != 'null') {
        return v.toString().trim();
      }
    }
    if (teacher['identification'] is Map) {
      final idNum = (teacher['identification'] as Map)['idNumber'];
      if (idNum != null && idNum.toString().trim().isNotEmpty) {
        return idNum.toString().trim();
      }
    }
    return '';
  }

  String _extractTeacherImageUrl(dynamic teacher) {
    if (teacher is! Map) return '';
    for (final k in [
      'imageUrl',
      'photoUrl',
      'avatarUrl',
      'pictureUrl',
      'image',
    ]) {
      final v = teacher[k];
      if (v != null && v.toString().trim().isNotEmpty && v.toString() != 'null') {
        return v.toString().trim();
      }
    }
    return '';
  }

  String _normalizeArabic(String input) {
    return input
        .replaceAll(RegExp(r'[أإآا]'), 'ا')
        .replaceAll('ى', 'ي')
        .replaceAll('ة', 'ه')
        .replaceAll('ؤ', 'و')
        .replaceAll('ئ', 'ي')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim()
        .toLowerCase();
  }

  List<dynamic> _matchTeachersFromFileName(String fileName) {
    final baseName = fileName.replaceAll(RegExp(r'\.[^.]+$'), '').trim();
    if (baseName.isEmpty) return [];

    final normalizedFile = _normalizeArabic(baseName);
    final digitsOnly = baseName.replaceAll(RegExp(r'[^0-9]'), '');

    final exactMatches = <dynamic>[];
    for (final teacher in widget.allTeachers) {
      final idNum = _extractTeacherIdentifier(teacher);
      final teacherId = _extractTeacherId(teacher);
      final fullName = _extractTeacherName(teacher);
      final normName = _normalizeArabic(fullName);

      if (digitsOnly.isNotEmpty &&
          (idNum == digitsOnly || teacherId == digitsOnly)) {
        exactMatches.add(teacher);
      } else if (normName.isNotEmpty && normName == normalizedFile) {
        exactMatches.add(teacher);
      }
    }
    if (exactMatches.isNotEmpty) return exactMatches;

    final partialMatches = <dynamic>[];
    for (final teacher in widget.allTeachers) {
      final idNum = _extractTeacherIdentifier(teacher);
      final teacherId = _extractTeacherId(teacher);
      final fullName = _extractTeacherName(teacher);
      final normName = _normalizeArabic(fullName);

      if (digitsOnly.isNotEmpty &&
          ((idNum.isNotEmpty && idNum.contains(digitsOnly)) ||
              (teacherId.isNotEmpty && teacherId.contains(digitsOnly)))) {
        partialMatches.add(teacher);
      } else if (normName.isNotEmpty &&
          (normName.contains(normalizedFile) ||
              normalizedFile.contains(normName))) {
        partialMatches.add(teacher);
      }
    }
    return partialMatches;
  }

  Future<void> _pickPhotosFromGallery() async {
    if (_isBatchWorking) return;

    if (!_isDesktop) {
      final status = await Permission.photos.request();
      if (!status.isGranted && !status.isLimited) {
        final storageStatus = await Permission.storage.request();
        if (!storageStatus.isGranted && !storageStatus.isLimited) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                    'يرجى منح صلاحية الوصول إلى الصور لاختيار صور المعلمين'),
                backgroundColor: Colors.red,
              ),
            );
          }
          return;
        }
      }
    }

    try {
      List<String> filePaths = [];
      if (_isDesktop) {
        final result = await FilePicker.platform.pickFiles(
          type: FileType.image,
          allowMultiple: true,
        );
        if (result != null) {
          filePaths = result.files
              .map((f) => f.path)
              .whereType<String>()
              .where((p) => p.isNotEmpty)
              .toList();
        }
      } else {
        final picker = ImagePicker();
        final pickedFiles = await picker.pickMultiImage(imageQuality: 90);
        filePaths = pickedFiles.map((x) => x.path).toList();
      }
      if (filePaths.isEmpty) return;

      int addedCount = 0;
      for (final path in filePaths) {
        final file = File(path);
        final fileName = file.path.split(RegExp(r'[/\\]')).last;
        final matches = _matchTeachersFromFileName(fileName);

        dynamic chosenTeacher;
        if (matches.length == 1) {
          chosenTeacher = matches.first;
        } else if (matches.length > 1) {
          if (!mounted) return;
          chosenTeacher = await _showTeacherPickerDialog(
            fileName: fileName,
            candidates: matches,
          );
        } else {
          if (!mounted) return;
          chosenTeacher = await _showTeacherPickerDialog(
            fileName: fileName,
            candidates: widget.allTeachers,
            noAutomaticMatch: true,
          );
        }

        if (chosenTeacher != null && mounted) {
          setState(() {
            _items.add(
              _TeacherPhotoItem(
                teacher: Map<String, dynamic>.from(chosenTeacher as Map),
                fullName: _extractTeacherName(chosenTeacher),
                identifier: _extractTeacherIdentifier(chosenTeacher),
                currentImageUrl: _extractTeacherImageUrl(chosenTeacher),
                originalFile: file,
                removeBackground: false,
              ),
            );
            addedCount++;
          });
        }
      }

      if (addedCount > 0 && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('تمت إضافة $addedCount صورة إلى قائمة المعالجة'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('حدث خطأ أثناء اختيار الصور: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<dynamic> _showTeacherPickerDialog({
    required String fileName,
    required List<dynamic> candidates,
    bool noAutomaticMatch = false,
  }) async {
    String query = '';
    return showDialog<dynamic>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final filtered = query.trim().isEmpty
                ? candidates
                : candidates.where((t) {
                    final name = _normalizeArabic(_extractTeacherName(t));
                    final idNum = _extractTeacherIdentifier(t).toLowerCase();
                    final q = _normalizeArabic(query);
                    return name.contains(q) || idNum.contains(q);
                  }).toList();

            return Directionality(
              textDirection: TextDirection.rtl,
              child: AlertDialog(
                title: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      noAutomaticMatch
                          ? 'لم يتم العثور على تطابق تلقائي'
                          : 'اختر المعلم المطابق للصورة',
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'الملف: $fileName',
                      style: const TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  ],
                ),
                content: SizedBox(
                  width: double.maxFinite,
                  height: 360,
                  child: Column(
                    children: [
                      TextField(
                        decoration: const InputDecoration(
                          hintText:
                              'ابحث باسم المعلم أو الرقم الوظيفي / الوطني...',
                          prefixIcon: Icon(Icons.search),
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        onChanged: (val) => setDialogState(() => query = val),
                      ),
                      const SizedBox(height: 10),
                      Expanded(
                        child: filtered.isEmpty
                            ? const Center(child: Text('لا توجد نتائج مطابقة'))
                            : ListView.separated(
                                itemCount: filtered.length,
                                separatorBuilder: (_, __) =>
                                    const Divider(height: 1),
                                itemBuilder: (context, idx) {
                                  final t = filtered[idx];
                                  final name = _extractTeacherName(t);
                                  final ident = _extractTeacherIdentifier(t);
                                  return ListTile(
                                    leading: const CircleAvatar(
                                      child: Icon(Icons.person),
                                    ),
                                    title: Text(
                                      name,
                                      style: const TextStyle(
                                          fontWeight: FontWeight.bold),
                                    ),
                                    subtitle: ident.isNotEmpty
                                        ? Text('الرقم: $ident')
                                        : null,
                                    onTap: () => Navigator.pop(context, t),
                                  );
                                },
                              ),
                      ),
                    ],
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context, null),
                    child: const Text('تخطي هذه الصورة'),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Future<File> _prepareImageFile(_TeacherPhotoItem item) async {
    File workingFile = item.originalFile;

    final bytes = await workingFile.readAsBytes();
    img.Image? decoded = img.decodeImage(bytes);
    if (decoded != null) {
      decoded = img.bakeOrientation(decoded);
      if (decoded.width > 1024 || decoded.height > 1024) {
        decoded = img.copyResize(
          decoded,
          width: decoded.width >= decoded.height ? 1024 : null,
          height: decoded.height > decoded.width ? 1024 : null,
        );
      }
      final tempPre = File(
        '${workingFile.path}_prep_${DateTime.now().millisecondsSinceEpoch}.jpg',
      );
      await tempPre.writeAsBytes(img.encodeJpg(decoded, quality: 88));
      workingFile = tempPre;
    }

    if (item.removeBackground) {
      if (mounted) {
        setState(() {
          item.status = _TeacherPhotoStatus.processing;
          item.statusMessage = 'جاري إزالة الخلفية...';
        });
      }
      final bgRemoved = await SelfieBackgroundRemover.removeBackground(workingFile);
      if (bgRemoved != null && await bgRemoved.exists()) {
        workingFile = bgRemoved;
      }
    }

    item.processedFile = workingFile;
    return workingFile;
  }

  Future<String?> _uploadImageToServer(File imageFile) async {
    final uri =
        Uri.parse('https://emis.moedu.gov.iq/api/employee/uploadimage');
    final request = http.MultipartRequest('POST', uri);
    request.headers['Authorization'] = widget.token.startsWith('Bearer ')
        ? widget.token
        : 'Bearer ${widget.token}';
    request.headers['Accept'] = 'application/json';

    request.files.add(
      await http.MultipartFile.fromPath(
        'file',
        imageFile.path,
        filename: imageFile.path.split(RegExp(r'[/\\]')).last,
      ),
    );

    final streamedResponse = await request.send();
    final response = await http.Response.fromStream(streamedResponse);

    if (response.statusCode >= 200 && response.statusCode < 300) {
      try {
        final body = jsonDecode(response.body);
        if (body is String && body.trim().isNotEmpty) return body.trim();
        if (body is Map) {
          for (final k in ['url', 'imageUrl', 'fileUrl', 'path', 'data']) {
            final val = body[k];
            if (val is String && val.trim().isNotEmpty) return val.trim();
            if (val is Map) {
              for (final nk in ['url', 'imageUrl', 'fileUrl', 'path']) {
                if (val[nk] is String && val[nk].toString().trim().isNotEmpty) {
                  return val[nk].toString().trim();
                }
              }
            }
          }
        }
      } catch (_) {
        final raw = response.body.trim().replaceAll('"', '');
        if (raw.startsWith('http') || raw.startsWith('/')) return raw;
      }
    }
    return null;
  }

  Future<Map<String, dynamic>?> _fetchFullTeacher(String teacherId) async {
    if (_fullTeacherCache.containsKey(teacherId)) {
      try {
        return jsonDecode(_fullTeacherCache[teacherId]!)
            as Map<String, dynamic>;
      } catch (_) {}
    }

    final uri = Uri.parse(
        'https://emis.moedu.gov.iq/api/employee/getemployee/$teacherId');
    final res = await http.get(
      uri,
      headers: {
        'Authorization': widget.token.startsWith('Bearer ')
            ? widget.token
            : 'Bearer ${widget.token}',
        'Accept': 'application/json',
      },
    );

    if (res.statusCode >= 200 && res.statusCode < 300) {
      final decoded = jsonDecode(res.body);
      Map<String, dynamic>? map;
      if (decoded is Map && decoded['data'] is Map) {
        map = Map<String, dynamic>.from(decoded['data'] as Map);
      } else if (decoded is Map) {
        map = Map<String, dynamic>.from(decoded);
      }
      if (map != null) {
        _fullTeacherCache[teacherId] = jsonEncode(map);
        return map;
      }
    }
    return null;
  }

  Future<bool> _updateTeacherImageOnServer(
    _TeacherPhotoItem item,
    String newImageUrl,
  ) async {
    final teacherId = _extractTeacherId(item.teacher);
    if (teacherId.isEmpty) return false;

    Map<String, dynamic> payload = await _fetchFullTeacher(teacherId) ??
        Map<String, dynamic>.from(item.teacher);

    payload['imageUrl'] = newImageUrl;
    payload['photoUrl'] = newImageUrl;
    payload['schoolId'] =
        payload['schoolId'] ?? int.tryParse(widget.schoolId) ?? widget.schoolId;

    final uri =
        Uri.parse('https://emis.moedu.gov.iq/api/employee/updateemployee');
    final res = await http.post(
      uri,
      headers: {
        'Authorization': widget.token.startsWith('Bearer ')
            ? widget.token
            : 'Bearer ${widget.token}',
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      },
      body: jsonEncode(payload),
    );

    if (res.statusCode >= 200 && res.statusCode < 300) {
      _fullTeacherCache.remove(teacherId);
      return true;
    }
    return false;
  }

  Future<void> _processSingleItem(int index) async {
    if (index < 0 || index >= _items.length) return;
    final item = _items[index];

    setState(() {
      item.status = _TeacherPhotoStatus.processing;
      item.statusMessage = 'جاري تجهيز الصورة...';
    });

    try {
      final fileToUpload = await _prepareImageFile(item);

      if (!mounted) return;
      setState(() {
        item.status = _TeacherPhotoStatus.uploading;
        item.statusMessage = 'جاري الرفع إلى السيرفر...';
      });

      final uploadedUrl = await _uploadImageToServer(fileToUpload);
      if (uploadedUrl == null || uploadedUrl.isEmpty) {
        throw Exception('فشل رفع الصورة إلى السيرفر');
      }

      final updated = await _updateTeacherImageOnServer(item, uploadedUrl);
      if (!updated) {
        throw Exception('تم رفع الصورة ولكن فشل تحديث بيانات المعلم');
      }

      if (!mounted) return;
      setState(() {
        item.status = _TeacherPhotoStatus.success;
        item.statusMessage = 'تم التحديث بنجاح';
        _completedCount++;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        item.status = _TeacherPhotoStatus.failed;
        item.statusMessage = e.toString().replaceFirst('Exception: ', '');
        _failedCount++;
      });
    }
  }

  Future<void> _startBatchUpload({List<int>? targetIndices}) async {
    if (_isBatchWorking || _items.isEmpty) return;

    final indices = targetIndices ??
        List<int>.generate(_items.length, (i) => i)
            .where((i) => _items[i].status != _TeacherPhotoStatus.success)
            .toList();

    if (indices.isEmpty) return;

    await AppCore.initPreferences();
    final fastQueueEnabled =
        AppCore.prefs.getBool('fast_processing_queue_enabled') ?? true;

    setState(() {
      _isBatchWorking = true;
      _cancelRequested = false;
      _completedCount = 0;
      _failedCount = 0;
    });

    if (fastQueueEnabled) {
      const concurrency = 2;
      int ptr = 0;
      Future<void> worker() async {
        while (!_cancelRequested) {
          int idx;
          synchronizedAccess: {
            if (ptr >= indices.length) return;
            idx = indices[ptr++];
          }
          await _processSingleItem(idx);
          await Future.delayed(const Duration(milliseconds: 150));
        }
      }

      await Future.wait(
        List.generate(math.min(concurrency, indices.length), (_) => worker()),
      );
    } else {
      for (final idx in indices) {
        if (_cancelRequested) break;
        await _processSingleItem(idx);
      }
    }

    if (!mounted) return;
    setState(() {
      _isBatchWorking = false;
      _isSelectionMode = false;
      _selectedIndices.clear();
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          _cancelRequested
              ? 'تم إيقاف المعالجة (نجاح: $_completedCount، فشل: $_failedCount)'
              : 'اكتملت المعالجة (نجاح: $_completedCount، فشل: $_failedCount)',
        ),
        backgroundColor: _failedCount > 0 ? Colors.orange : Colors.green,
      ),
    );
  }

  void _toggleSelection(int index) {
    setState(() {
      if (_selectedIndices.contains(index)) {
        _selectedIndices.remove(index);
        if (_selectedIndices.isEmpty) _isSelectionMode = false;
      } else {
        _selectedIndices.add(index);
      }
    });
  }

  void _applyBackgroundRemovalToSelected(bool value) {
    setState(() {
      for (final idx in _selectedIndices) {
        if (idx >= 0 && idx < _items.length) {
          _items[idx].removeBackground = value;
        }
      }
    });
  }

  void _deleteSelectedItems() {
    setState(() {
      final sorted = _selectedIndices.toList()
        ..sort((a, b) => b.compareTo(a));
      for (final idx in sorted) {
        if (idx >= 0 && idx < _items.length) {
          _items.removeAt(idx);
        }
      }
      _selectedIndices.clear();
      _isSelectionMode = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            _isSelectionMode
                ? 'تم تحديد ${_selectedIndices.length}'
                : 'رفع صور المعلمين دفعة واحدة',
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 17),
          ),
          actions: [
            if (_isSelectionMode) ...[
              IconButton(
                tooltip: 'تفعيل إزالة الخلفية للمحدد',
                icon: const Icon(Icons.auto_fix_high),
                onPressed: _isBatchWorking
                    ? null
                    : () => _applyBackgroundRemovalToSelected(true),
              ),
              IconButton(
                tooltip: 'إلغاء إزالة الخلفية للمحدد',
                icon: const Icon(Icons.image_not_supported_outlined),
                onPressed: _isBatchWorking
                    ? null
                    : () => _applyBackgroundRemovalToSelected(false),
              ),
              IconButton(
                tooltip: 'حذف المحدد',
                icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                onPressed: _isBatchWorking ? null : _deleteSelectedItems,
              ),
            ] else if (_items.isNotEmpty && !_isBatchWorking) ...[
              IconButton(
                tooltip: 'مسح الكل',
                icon: const Icon(Icons.clear_all),
                onPressed: () => setState(() => _items.clear()),
              ),
            ],
          ],
        ),
        body: Column(
          children: [
            Container(
              width: double.infinity,
              margin: const EdgeInsets.all(12),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: isDark
                    ? Colors.blueGrey.withOpacity(0.18)
                    : Colors.blue.withOpacity(0.06),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: Colors.blueAccent.withOpacity(0.3),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.info_outline,
                          color: Colors.blueAccent, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'يتم مطابقة اسم ملف الصورة تلقائياً مع اسم المعلم أو رقمه الوظيفي/الوطني.',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: isDark ? Colors.white70 : Colors.black87,
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (_isBatchWorking) ...[
                    const SizedBox(height: 10),
                    LinearProgressIndicator(
                      value: _items.isEmpty
                          ? null
                          : ((_completedCount + _failedCount) / _items.length)
                              .clamp(0.0, 1.0),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'تم إنجاز: $_completedCount | فشل: $_failedCount من أصل ${_items.length}',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ],
                ],
              ),
            ),
            Expanded(
              child: _items.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.photo_library_outlined,
                            size: 64,
                            color: Colors.grey.withOpacity(0.6),
                          ),
                          const SizedBox(height: 12),
                          const Text(
                            'لم يتم اختيار صور بعد',
                            style: TextStyle(
                                fontSize: 16, fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 6),
                          const Text(
                            'اضغط على زر "اختيار صور المعلمين" بالأسفل للبدء',
                            style: TextStyle(color: Colors.grey),
                          ),
                        ],
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      itemCount: _items.length,
                      itemBuilder: (context, index) {
                        final item = _items[index];
                        final isSelected = _selectedIndices.contains(index);

                        Color badgeColor = Colors.grey;
                        String badgeText = 'بانتظار الرفع';
                        if (item.status == _TeacherPhotoStatus.processing) {
                          badgeColor = Colors.amber;
                          badgeText = 'معالجة...';
                        } else if (item.status == _TeacherPhotoStatus.uploading) {
                          badgeColor = Colors.blue;
                          badgeText = 'جاري الرفع...';
                        } else if (item.status == _TeacherPhotoStatus.success) {
                          badgeColor = Colors.green;
                          badgeText = 'مكتمل';
                        } else if (item.status == _TeacherPhotoStatus.failed) {
                          badgeColor = Colors.red;
                          badgeText = 'فشل';
                        }

                        return Card(
                          margin: const EdgeInsets.only(bottom: 10),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                            side: isSelected
                                ? const BorderSide(
                                    color: Colors.blueAccent, width: 2)
                                : BorderSide.none,
                          ),
                          child: ListTile(
                            onLongPress: _isBatchWorking
                                ? null
                                : () {
                                    setState(() {
                                      _isSelectionMode = true;
                                      _selectedIndices.add(index);
                                    });
                                  },
                            onTap: _isSelectionMode
                                ? () => _toggleSelection(index)
                                : null,
                            leading: Stack(
                              children: [
                                CircleAvatar(
                                  radius: 26,
                                  backgroundImage: FileImage(
                                    item.processedFile ?? item.originalFile,
                                  ),
                                ),
                                if (_isSelectionMode)
                                  Positioned(
                                    right: 0,
                                    bottom: 0,
                                    child: CircleAvatar(
                                      radius: 10,
                                      backgroundColor: isSelected
                                          ? Colors.blueAccent
                                          : Colors.grey,
                                      child: Icon(
                                        isSelected
                                            ? Icons.check
                                            : Icons.circle_outlined,
                                        size: 14,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                            title: Text(
                              item.fullName,
                              style:
                                  const TextStyle(fontWeight: FontWeight.bold),
                            ),
                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (item.identifier.isNotEmpty)
                                  Text('الرقم: ${item.identifier}',
                                      style: const TextStyle(fontSize: 12)),
                                const SizedBox(height: 4),
                                Row(
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 8, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: badgeColor.withOpacity(0.15),
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: Text(
                                        item.statusMessage ?? badgeText,
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: badgeColor,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    InkWell(
                                      onTap: _isBatchWorking
                                          ? null
                                          : () => setState(() =>
                                              item.removeBackground =
                                                  !item.removeBackground),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(
                                            item.removeBackground
                                                ? Icons.check_box
                                                : Icons.check_box_outline_blank,
                                            size: 16,
                                            color: item.removeBackground
                                                ? Colors.teal
                                                : Colors.grey,
                                          ),
                                          const SizedBox(width: 4),
                                          const Text(
                                            'إزالة الخلفية',
                                            style: TextStyle(fontSize: 11),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed:
                            _isBatchWorking ? null : _pickPhotosFromGallery,
                        icon: const Icon(Icons.add_photo_alternate_outlined),
                        label: const Text('اختيار صور المعلمين'),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _isBatchWorking
                          ? ElevatedButton.icon(
                              onPressed: () =>
                                  setState(() => _cancelRequested = true),
                              icon: const Icon(Icons.stop),
                              label: const Text('إيقاف'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.red,
                                foregroundColor: Colors.white,
                                padding:
                                    const EdgeInsets.symmetric(vertical: 14),
                              ),
                            )
                          : ElevatedButton.icon(
                              onPressed: _items.isEmpty
                                  ? null
                                  : () => _startBatchUpload(
                                        targetIndices: _isSelectionMode
                                            ? _selectedIndices.toList()
                                            : null,
                                      ),
                              icon: const Icon(Icons.cloud_upload_outlined),
                              label: Text(
                                _isSelectionMode
                                    ? 'رفع المحدد (${_selectedIndices.length})'
                                    : 'بدء الرفع (${_items.length})',
                              ),
                              style: ElevatedButton.styleFrom(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 14),
                              ),
                            ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
