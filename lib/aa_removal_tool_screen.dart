import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'app_core.dart';

class AARemovalToolScreen extends StatefulWidget {
  final String token;
  final String schoolId;
  final List<dynamic> allStudents;

  const AARemovalToolScreen({
    super.key,
    required this.token,
    required this.schoolId,
    required this.allStudents,
  });

  @override
  State<AARemovalToolScreen> createState() => _AARemovalToolScreenState();
}

class _AARemovalToolScreenState extends State<AARemovalToolScreen>
    with SingleTickerProviderStateMixin {
  bool _isWorking = false;
  final Set<String> _successfulIds = <String>{};
  final Set<String> _failedIds = <String>{};
  final Set<String> _skippedIds = <String>{};

  late final AnimationController _ambientCollectionController;

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
    super.dispose();
  }

  String _nameOf(dynamic student) {
    if (student is! Map) return 'بدون اسم';
    final direct = student['fullName'] ?? student['studentName'] ?? student['displayName'];
    if (direct != null && direct.toString().trim().isNotEmpty) {
      return direct.toString().trim();
    }
    final parts = [
      student['firstName'],
      student['name'],
      student['fatherName'],
      student['grandFatherName'],
      student['fathersGrandFatherName'],
      student['surName'],
    ]
        .map((e) => e?.toString().trim() ?? '')
        .where((e) => e.isNotEmpty)
        .toList();
    return parts.isEmpty ? 'بدون اسم' : parts.join(' ');
  }

  String? _nationalId(dynamic student) {
    if (student is! Map) return null;
    final candidates = [
      student['nationalIdNumber'],
      if (student['identification'] is Map)
        (student['identification'] as Map)['idNumber'],
      student['idNumber'],
    ];
    for (final value in candidates) {
      final text = value?.toString().trim() ?? '';
      if (text.isNotEmpty) return text;
    }
    return null;
  }

  bool _hasAA(String? id) {
    return RegExp(r'^AA', caseSensitive: false).hasMatch(id?.trim() ?? '');
  }

  String _newId(String oldId) {
    var result = oldId.replaceFirst(RegExp(r'^AA', caseSensitive: false), '');
    result = result.replaceFirst(RegExp(r'^0+'), '');
    return result;
  }

  String _studentKey(dynamic student) =>
      (student is Map ? student['id'] : null)?.toString() ?? '';

  List<Map<String, dynamic>> get _targets {
    final result = <Map<String, dynamic>>[];
    for (final item in widget.allStudents) {
      if (item is! Map) continue;
      final oldId = _nationalId(item);
      if (oldId != null && _hasAA(oldId)) {
        result.add({
          'student': item,
          'oldId': oldId,
          'newId': _newId(oldId),
        });
      }
    }
    return result;
  }

  Future<Map<String, dynamic>?> _fetchFullStudent(String studentId) async {
    try {
      final response = await http.get(
        Uri.parse('https://emis.moedu.gov.iq/api/student/getstudent/${Uri.encodeComponent(studentId)}'),
        headers: {
          'Authorization': widget.token,
          'Accept': 'application/json',
        },
      );
      if (response.statusCode == 200 && response.body.isNotEmpty) {
        final decoded = jsonDecode(response.body);
        if (decoded is Map && decoded['data'] is Map) {
          return Map<String, dynamic>.from(decoded['data']);
        } else if (decoded is Map) {
          return Map<String, dynamic>.from(decoded);
        }
      }
    } catch (e) {
      debugPrint('Error fetching full student $studentId: $e');
    }
    return null;
  }

  Map<String, dynamic> _buildUpdateDTO(Map<String, dynamic> student) {
    final identification = student['identification'] is Map
        ? Map<String, dynamic>.from(student['identification'])
        : <String, dynamic>{};
    
    final address = student['address'] is Map
        ? Map<String, dynamic>.from(student['address'])
        : <String, dynamic>{};

    Map<String, dynamic>? fatherIdentification;
    if (student['fatherIdentification'] is Map) {
      final fIdent = student['fatherIdentification'] as Map;
      fatherIdentification = {
        'idNumber': fIdent['idNumber'] ?? '',
        'issuingCountry': fIdent['issuingCountry'] ?? '',
        'idType': fIdent['idType'],
        'nameOfDocument': fIdent['nameOfDocument'] ?? '',
        'recordNumber': fIdent['recordNumber'] ?? '',
        'pageNumber': fIdent['pageNumber'] ?? '',
        'issuer': fIdent['issuer'] ?? '',
        'issuingDate': fIdent['issuingDate'],
      };
    }

    final oldIdentId = identification['idNumber']?.toString() ?? _nationalId(student) ?? '';
    final newIdNumber = _newId(oldIdentId);

    return {
      'id': student['id'],
      'name': student['name'] ?? '',
      'fatherName': student['fatherName'] ?? '',
      'grandFatherName': student['grandFatherName'] ?? '',
      'fathersGrandFatherName': student['fathersGrandFatherName'] ?? '',
      'surName': student['surName'] ?? '',
      'motherName': student['motherName'] ?? '',
      'mothersFatherName': student['mothersFatherName'] ?? '',
      'mothersGrandFatherName': student['mothersGrandFatherName'] ?? '',
      'imageUrl': student['imageUrl'] ?? '',
      'dateOfBirth': student['dateOfBirth'],
      'gender': student['gender'],
      'nationality': student['nationality'] ?? '',
      'countryOfBirth': student['countryOfBirth'] ?? '',
      'homeTown': student['homeTown'] ?? '',
      'motherTongue': student['motherTongue'] ?? '',
      'maritalStatus': student['maritalStatus'] ?? '',
      'bloodGroup': student['bloodGroup'] ?? '',
      'religion': student['religion'] ?? '',
      'homePhoneNumber': student['homePhoneNumber'] ?? '',
      'notes': student['notes'] ?? '',
      'censusNumber': student['censusNumber'] ?? '',
      'isDisabled': student['isDisabled'] == true,
      'identification': {
        'idNumber': newIdNumber,
        'issuingCountry': identification['issuingCountry'] ?? '',
        'idType': identification['idType'],
        'nameOfDocument': identification['nameOfDocument'] ?? '',
        'recordNumber': identification['recordNumber'] ?? '',
        'pageNumber': identification['pageNumber'] ?? '',
        'issuer': identification['issuer'] ?? '',
        'issuingDate': identification['issuingDate'],
      },
      'fatherIdentification': fatherIdentification,
      'specialNeeds': student['specialNeeds'] is List ? student['specialNeeds'] : [''],
      'studyLanguage': student['studyLanguage'] ?? '',
      'economicLevel': student['economicLevel'] ?? '',
      'isCoveredBySocialWelfare': student['isCoveredBySocialWelfare'] == true,
      'isDroppedOutFromSchool': student['isDroppedOutFromSchool'] == true,
      'lastYearResult': student['lastYearResult'],
      'schoolId': int.tryParse(student['schoolId']?.toString() ?? '') ?? int.parse(widget.schoolId),
      'stageId': student['stageId'],
      'classRoomId': student['classRoomId'],
      'ageExceptionReason': student['ageExceptionReason'],
      'genderExceptionReason': student['genderExceptionReason'],
      'address': {
        'addressType': address['addressType'] ?? 1,
        'countryStructureId': address['countryStructureId'],
        'town': address['town'] ?? '0',
        'area': address['area'] ?? '0',
        'quarter': address['quarter'] ?? '0',
        'street': address['street'] ?? '0',
        'apartmentNumber': address['apartmentNumber'] ?? '',
        'buildingNumber': address['buildingNumber'] ?? '',
        'address1': address['address1'] ?? '0',
        'address2': address['address2'] ?? '',
        'closestLocation': address['closestLocation'] ?? '1',
        'latitude': address['latitude'] ?? 0,
        'longitude': address['longitude'] ?? 0,
        'schoolPhoneNumber': address['schoolPhoneNumber'] ?? '',
        'mobilePhoneNumber': address['mobilePhoneNumber'] ?? '',
        'email': address['email'] ?? '',
        'website': address['website'] ?? '',
      }
    };
  }

  Future<bool> _updateStudent(dynamic studentBasic) async {
    final studentId = _studentKey(studentBasic);
    if (studentId.isEmpty) return false;

    final fullStudent = await _fetchFullStudent(studentId);
    if (fullStudent == null || fullStudent['identification'] == null) {
      return false;
    }

    final oldId = (fullStudent['identification'] as Map)['idNumber']?.toString().trim() ?? '';
    if (!_hasAA(oldId)) {
      return true; 
    }

    final newId = _newId(oldId);
    if (newId.length != 12 || !RegExp(r'^\d{12}$').hasMatch(newId)) {
      return false;
    }

    final dto = _buildUpdateDTO(fullStudent);

    final response = await http.post(
      Uri.parse('https://emis.moedu.gov.iq/api/student/updatestudent'),
      headers: {
        'Authorization': widget.token,
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      },
      body: jsonEncode(dto),
    );

    if (response.statusCode != 200 && response.statusCode != 204) {
      debugPrint('AA update failed ${response.statusCode}: ${response.body}');
      return false;
    }

    final verifyStudent = await _fetchFullStudent(studentId);
    final verifyId = (verifyStudent?['identification'] is Map)
        ? (verifyStudent!['identification'] as Map)['idNumber']?.toString().trim()
        : null;

    return verifyId == newId;
  }

  Future<void> _run() async {
    final isDark = AppCore.themeNotifier.value == ThemeMode.dark;
    final targets = _targets;
    if (targets.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text(
            'لا يوجد طالب يبدأ رقم هويته بـ AA.',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          backgroundColor: const Color(0xFFF97316),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
      );
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          backgroundColor: isDark ? const Color(0xFF141829) : const Color(0xFFFFFFFF),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
            side: BorderSide(
              color: const Color(0xFFF97316).withOpacity(0.45),
              width: 1.5,
            ),
          ),
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: const Color(0xFFF97316).withOpacity(0.15),
                ),
                child: const Icon(
                  Icons.auto_fix_high_rounded,
                  color: Color(0xFFF97316),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'تأكيد تعديل أرقام الهوية',
                  style: TextStyle(
                    color: isDark ? Colors.white : const Color(0xFF0F172A),
                    fontWeight: FontWeight.w900,
                    fontSize: 17,
                  ),
                ),
              ),
            ],
          ),
          content: Text(
            'سيتم تعديل ${targets.length} طالباً باستخدام الفحص الكامل وتأكيد السيرفر.\n\nلن يتم إعادة تحميل قائمة الطلاب تلقائياً.',
            style: TextStyle(
              color: isDark ? const Color(0xFFCBD5E1) : const Color(0xFF475569),
              height: 1.5,
              fontWeight: FontWeight.w600,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(
                'إلغاء',
                style: TextStyle(
                  color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFF97316),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text(
                'متابعة التنفيذ',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true) return;

    setState(() {
      _isWorking = true;
      _successfulIds.clear();
      _failedIds.clear();
      _skippedIds.clear();
    });

    // قراءة خيار الإعدادات: هل الطوابير الذكية والمعالجة السريعة مفعلة؟ (الافتراضي مفعل والمستحسن)
    await AppCore.initPreferences();
    final fastQueueEnabled = AppCore.prefs.getBool('fast_processing_queue_enabled') ?? true;

    // إذا كانت مفعلة، نطبق نظام الطوابير الذكية والتدفق المتزامن المقيد لمنع إرهاق السيرفر
    // وإذا كانت معطلة، نعمل بالتدفق العادي
    final concurrency = fastQueueEnabled ? 2 : 5;
    int currentIndex = 0;

    Future<void> worker() async {
      while (true) {
        int index;
        synchronizedAccess: {
          if (currentIndex >= targets.length) return;
          index = currentIndex++;
        }

        final target = targets[index];
        final student = target['student'] as Map<String, dynamic>;
        final id = _studentKey(student);
        final oldId = target['oldId'] as String;
        final newId = target['newId'] as String;

        if (newId.length != 12 || !RegExp(r'^\d{12}$').hasMatch(newId)) {
          _skippedIds.add(id);
          if (mounted) setState(() {});
          continue;
        }

        try {
          final ok = await _updateStudent(student);
          if (ok) {
            _successfulIds.add(id);
          } else {
            _failedIds.add(id);
          }
        } catch (e) {
          debugPrint('AA update error for $oldId: $e');
          _failedIds.add(id);
        }

        // إضافة فترة راحة ذكية قصيرة عند تفعيل الطوابير لمنع حظر الطلبات السريعة
        if (fastQueueEnabled) {
          await Future.delayed(const Duration(milliseconds: 150));
        }

        if (mounted) setState(() {});
      }
    }

    final workers = List.generate(
      math.min(concurrency, targets.length),
      (_) => worker(),
    );
    await Future.wait(workers);

    if (mounted) {
      setState(() => _isWorking = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'اكتمل التنفيذ: ${_successfulIds.length} نجاح، ${_failedIds.length} فشل، ${_skippedIds.length} تجاوز.',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          backgroundColor: _failedIds.isEmpty
              ? const Color(0xFF10B981)
              : const Color(0xFFF97316),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
      );
    }
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

  Widget _buildTopHeader({
    required bool isDark,
    required VoidCallback onBack,
  }) {
    const orangeNeon = Color(0xFFF97316);
    const goldNeon = Color(0xFFF59E0B);
    const purpleNeon = Color(0xFFA855F7);

    return AnimatedBuilder(
      animation: _ambientCollectionController,
      builder: (context, _) {
        final pulse = 0.5 + 0.5 * math.sin(_ambientCollectionController.value * 2 * math.pi);

        return Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            gradient: isDark
                ? const LinearGradient(
                    begin: Alignment.topRight,
                    end: Alignment.bottomLeft,
                    colors: [
                      Color(0xFF27171C),
                      Color(0xFF161A30),
                      Color(0xFF241734),
                    ],
                  )
                : const LinearGradient(
                    begin: Alignment.topRight,
                    end: Alignment.bottomLeft,
                    colors: [
                      Color(0xFFFFFFFF),
                      Color(0xFFFFF7ED),
                      Color(0xFFEDE9FE),
                    ],
                  ),
            borderRadius: BorderRadius.circular(28),
            border: Border.all(
              color: (isDark ? orangeNeon : purpleNeon).withOpacity(isDark ? 0.45 : 0.30),
              width: 1.5,
            ),
            boxShadow: [
              BoxShadow(
                color: (isDark ? orangeNeon : purpleNeon).withOpacity(0.12 + pulse * 0.08),
                blurRadius: 24,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Row(
            children: [
              _AnimatedToolOrbIcon(
                icon: Icons.auto_fix_high_rounded,
                primaryColor: orangeNeon,
                secondaryColor: goldNeon,
                animation: _ambientCollectionController,
                size: 60,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'أدوات المعالجة الذكية المطورة',
                      style: TextStyle(
                        color: isDark ? goldNeon : orangeNeon,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'حذف البادئة AA والأصفار',
                      style: TextStyle(
                        color: isDark ? Colors.white : const Color(0xFF0F172A),
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'مطابق لكفاءة السكربت مع الفحص والتحقق الكامل',
                      style: TextStyle(
                        color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: onBack,
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: isDark ? Colors.white.withOpacity(0.08) : orangeNeon.withOpacity(0.10),
                    border: Border.all(
                      color: isDark ? Colors.white.withOpacity(0.18) : orangeNeon.withOpacity(0.28),
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

  Widget _buildWaveStatsCard({
    required bool isDark,
    required int totalCount,
  }) {
    const orangeNeon = Color(0xFFF97316);
    const goldNeon = Color(0xFFF59E0B);
    const emeraldNeon = Color(0xFF10B981);
    const redNeon = Color(0xFFEF4444);

    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final mutedColor = isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);

    final hasStats = _successfulIds.isNotEmpty ||
        _failedIds.isNotEmpty ||
        _skippedIds.isNotEmpty;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        gradient: isDark
            ? LinearGradient(
                colors: [
                  const Color(0xFF141829).withOpacity(0.95),
                  const Color(0xFF1E172A).withOpacity(0.90),
                ],
              )
            : LinearGradient(
                colors: [
                  Colors.white.withOpacity(0.96),
                  const Color(0xFFFFF7ED).withOpacity(0.92),
                ],
              ),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: orangeNeon.withOpacity(isDark ? 0.45 : 0.32),
          width: 1.3,
        ),
        boxShadow: [
          BoxShadow(
            color: orangeNeon.withOpacity(isDark ? 0.12 : 0.08),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                width: 50,
                height: 50,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: orangeNeon.withOpacity(0.15),
                  border: Border.all(
                    color: orangeNeon.withOpacity(0.55),
                    width: 1.5,
                  ),
                ),
                child: const Icon(
                  Icons.badge_rounded,
                  color: orangeNeon,
                  size: 26,
                ),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '$totalCount',
                    style: TextStyle(
                      color: textColor,
                      fontSize: 26,
                      height: 1.05,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'طلاب يحتاجون التعديل',
                    style: TextStyle(
                      color: mutedColor,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 16),
              Expanded(
                child: SizedBox(
                  height: 44,
                  child: AnimatedBuilder(
                    animation: _ambientCollectionController,
                    builder: (context, _) {
                      return CustomPaint(
                        painter: _AAWavePainter(
                          phase: _ambientCollectionController.value * 2 * math.pi,
                          color: goldNeon,
                          isDark: isDark,
                        ),
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
          if (hasStats) ...[
            const SizedBox(height: 12),
            Divider(
              height: 1,
              color: isDark ? Colors.white12 : Colors.black12,
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _buildMiniStatPill(
                  label: 'نجاح',
                  count: _successfulIds.length,
                  color: emeraldNeon,
                  isDark: isDark,
                ),
                _buildMiniStatPill(
                  label: 'فشل',
                  count: _failedIds.length,
                  color: redNeon,
                  isDark: isDark,
                ),
                _buildMiniStatPill(
                  label: 'تجاوز',
                  count: _skippedIds.length,
                  color: goldNeon,
                  isDark: isDark,
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildMiniStatPill({
    required String label,
    required int count,
    required Color color,
    required bool isDark,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        color: color.withOpacity(isDark ? 0.15 : 0.10),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withOpacity(0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            '$label: $count',
            style: TextStyle(
              color: isDark ? Colors.white : const Color(0xFF0F172A),
              fontWeight: FontWeight.w800,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionButton({required bool isDark, required bool isEmpty}) {
    const orangeNeon = Color(0xFFF97316);
    const goldNeon = Color(0xFFF59E0B);

    return GestureDetector(
      onTap: (_isWorking || isEmpty) ? null : _run,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        height: 56,
        decoration: BoxDecoration(
          gradient: (_isWorking || isEmpty)
              ? LinearGradient(
                  colors: [Colors.grey.shade700, Colors.grey.shade600],
                )
              : const LinearGradient(
                  begin: Alignment.topRight,
                  end: Alignment.bottomLeft,
                  colors: [orangeNeon, goldNeon],
                ),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: Colors.white.withOpacity(0.35),
            width: 1.2,
          ),
          boxShadow: (_isWorking || isEmpty)
              ? []
              : [
                  BoxShadow(
                    color: orangeNeon.withOpacity(isDark ? 0.35 : 0.25),
                    blurRadius: 18,
                    offset: const Offset(0, 6),
                  ),
                ],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (_isWorking)
              const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: Colors.white,
                ),
              )
            else
              const Icon(
                Icons.auto_fix_high_rounded,
                color: Colors.white,
                size: 24,
              ),
            const SizedBox(width: 10),
            Text(
              _isWorking ? 'جاري التعديل والفحص الذكي...' : 'حذف AA والأصفار الآن',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16.5,
                fontWeight: FontWeight.w900,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStudentItemCard({
    required Map<String, dynamic> target,
    required bool isDark,
  }) {
    final student = target['student'] as Map<String, dynamic>;
    final id = _studentKey(student);
    final oldId = target['oldId'] as String;
    final newId = target['newId'] as String;

    final ok = _successfulIds.contains(id);
    final failed = _failedIds.contains(id);
    final skipped = _skippedIds.contains(id);

    const emeraldNeon = Color(0xFF10B981);
    const redNeon = Color(0xFFEF4444);
    const goldNeon = Color(0xFFF59E0B);
    const blueNeon = Color(0xFF3B82F6);

    final String statusText = ok
        ? 'تم التحديث والتحقق بنجاح'
        : failed
            ? 'فشل التحديث أو التحقق'
            : skipped
                ? 'تم التجاوز (غير مطابق لـ 12 رقماً)'
                : 'بانتظار التنفيذ';

    final Color statusColor = ok
        ? emeraldNeon
        : failed
            ? redNeon
            : skipped
                ? goldNeon
                : blueNeon;

    final IconData statusIcon = ok
        ? Icons.check_circle_rounded
        : failed
            ? Icons.error_rounded
            : skipped
                ? Icons.warning_amber_rounded
                : Icons.person_rounded;

    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        gradient: isDark
            ? LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  const Color(0xFF141829).withOpacity(0.95),
                  Color.lerp(const Color(0xFF0F1322), statusColor, 0.08)!,
                ],
              )
            : LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Colors.white,
                  Color.lerp(const Color(0xFFF8FAFC), statusColor, 0.04)!,
                ],
              ),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: statusColor.withOpacity(isDark ? 0.45 : 0.30),
          width: 1.3,
        ),
        boxShadow: [
          BoxShadow(
            color: statusColor.withOpacity(isDark ? 0.10 : 0.06),
            blurRadius: 14,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: statusColor.withOpacity(0.15),
              border: Border.all(
                color: statusColor.withOpacity(0.5),
                width: 1.3,
              ),
            ),
            child: Icon(statusIcon, color: statusColor, size: 25),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _nameOf(student),
                  style: TextStyle(
                    color: textColor,
                    fontWeight: FontWeight.w900,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: redNeon.withOpacity(0.12),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: redNeon.withOpacity(0.35)),
                      ),
                      child: Text(
                        oldId,
                        textDirection: TextDirection.ltr,
                        style: TextStyle(
                          color: isDark ? const Color(0xFFFCA5A5) : const Color(0xFFB91C1C),
                          fontWeight: FontWeight.w800,
                          fontSize: 12,
                        ),
                      ),
                    ),
                    Icon(
                      Icons.arrow_back_rounded,
                      size: 16,
                      color: statusColor,
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: emeraldNeon.withOpacity(0.14),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: emeraldNeon.withOpacity(0.40)),
                      ),
                      child: Text(
                        newId,
                        textDirection: TextDirection.ltr,
                        style: TextStyle(
                          color: isDark ? const Color(0xFF6EE7B7) : const Color(0xFF047857),
                          fontWeight: FontWeight.w900,
                          fontSize: 12.5,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: statusColor,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        statusText,
                        style: TextStyle(
                          color: statusColor,
                          fontWeight: FontWeight.w800,
                          fontSize: 12,
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
        final targets = _targets;

        const emeraldNeon = Color(0xFF10B981);
        const goldNeon = Color(0xFFF59E0B);
        const orangeNeon = Color(0xFFF97316);
        const purpleNeon = Color(0xFFA855F7);

        return Directionality(
          textDirection: TextDirection.rtl,
          child: Scaffold(
            backgroundColor: isDark ? const Color(0xFF070913) : const Color(0xFFF2F5FA),
            body: Stack(
              children: [
                Positioned.fill(
                  child: AnimatedBuilder(
                    animation: _ambientCollectionController,
                    builder: (context, _) {
                      final shift = math.sin(_ambientCollectionController.value * 2 * math.pi) * 20;
                      return Stack(
                        children: [
                          Positioned(
                            top: -50 + shift,
                            right: -50,
                            child: _buildAmbientGlow(
                              color: isDark ? orangeNeon.withOpacity(0.18) : orangeNeon.withOpacity(0.12),
                              size: 250,
                            ),
                          ),
                          Positioned(
                            top: 240 - shift,
                            left: -70,
                            child: _buildAmbientGlow(
                              color: isDark ? purpleNeon.withOpacity(0.15) : goldNeon.withOpacity(0.12),
                              size: 270,
                            ),
                          ),
                          Positioned(
                            bottom: -60 + shift,
                            right: 20,
                            child: _buildAmbientGlow(
                              color: isDark ? emeraldNeon.withOpacity(0.12) : purpleNeon.withOpacity(0.10),
                              size: 230,
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
                SafeArea(
                  bottom: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _buildTopHeader(
                          isDark: isDark,
                          onBack: () => Navigator.of(context).pop(),
                        ),
                        const SizedBox(height: 14),
                        _buildWaveStatsCard(
                          isDark: isDark,
                          totalCount: targets.length,
                        ),
                        const SizedBox(height: 14),
                        _buildActionButton(
                          isDark: isDark,
                          isEmpty: targets.isEmpty,
                        ),
                        const SizedBox(height: 14),
                        Expanded(
                          child: targets.isEmpty
                              ? Center(
                                  child: Container(
                                    padding: const EdgeInsets.all(28),
                                    decoration: BoxDecoration(
                                      color: isDark ? const Color(0xFF141829).withOpacity(0.85) : Colors.white.withOpacity(0.9),
                                      borderRadius: BorderRadius.circular(26),
                                      border: Border.all(
                                        color: emeraldNeon.withOpacity(0.4),
                                        width: 1.4,
                                      ),
                                    ),
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        _AnimatedToolOrbIcon(
                                          icon: Icons.verified_rounded,
                                          primaryColor: emeraldNeon,
                                          secondaryColor: goldNeon,
                                          animation: _ambientCollectionController,
                                          size: 72,
                                        ),
                                        const SizedBox(height: 14),
                                        Text(
                                          'لا توجد سجلات تبدأ بـ AA',
                                          style: TextStyle(
                                            fontWeight: FontWeight.w900,
                                            color: textColor,
                                            fontSize: 17,
                                          ),
                                        ),
                                        const SizedBox(height: 6),
                                        Text(
                                          'جميع أرقام الهويات الوطنية للطلاب خالية من البادئة AA حالياً.',
                                          textAlign: TextAlign.center,
                                          style: TextStyle(
                                            color: mutedColor,
                                            fontWeight: FontWeight.w600,
                                            fontSize: 13,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                )
                              : ListView.builder(
                                  physics: const BouncingScrollPhysics(),
                                  padding: const EdgeInsets.only(bottom: 28),
                                  itemCount: targets.length,
                                  itemBuilder: (context, index) {
                                    return _buildStudentItemCard(
                                      target: targets[index],
                                      isDark: isDark,
                                    );
                                  },
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
      },
    );
  }
}

class _AnimatedToolOrbIcon extends StatelessWidget {
  final IconData icon;
  final Color primaryColor;
  final Color secondaryColor;
  final Animation<double> animation;
  final double size;

  const _AnimatedToolOrbIcon({
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
                  painter: _ToolAtomOrbitPainter(
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

class _ToolAtomOrbitPainter extends CustomPainter {
  final double progress;
  final Color primaryColor;
  final Color secondaryColor;

  _ToolAtomOrbitPainter({
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
  bool shouldRepaint(covariant _ToolAtomOrbitPainter oldDelegate) =>
      oldDelegate.progress != progress;
}

class _AAWavePainter extends CustomPainter {
  final double phase;
  final Color color;
  final bool isDark;

  _AAWavePainter({
    required this.phase,
    required this.color,
    required this.isDark,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paintLine = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.4
      ..strokeCap = StrokeCap.round;

    final glowPaint = Paint()
      ..color = color.withOpacity(isDark ? 0.45 : 0.25)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5.5
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5);

    final path = Path();
    final startX = size.width * 0.28;
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

    final barPaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.8
      ..strokeCap = StrokeCap.round;

    const barCount = 4;
    final barSpacing = (size.width * 0.22) / barCount;
    for (int i = 0; i < barCount; i++) {
      final bx = i * barSpacing + 6;
      final factor = 0.32 + 0.48 * math.sin(phase + i * 1.2).abs();
      final barHeight = size.height * factor;
      final topY = (size.height - barHeight) / 2;
      canvas.drawLine(
        Offset(bx, topY),
        Offset(bx, topY + barHeight),
        barPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _AAWavePainter oldDelegate) =>
      oldDelegate.phase != phase || oldDelegate.isDark != isDark;
}
