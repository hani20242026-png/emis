import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'app_core.dart';

class DeactivatedStudentsScreen extends StatefulWidget {
  final String token;
  final String schoolId;

  const DeactivatedStudentsScreen({
    super.key,
    required this.token,
    required this.schoolId,
  });

  @override
  State<DeactivatedStudentsScreen> createState() =>
      _DeactivatedStudentsScreenState();
}

class _DeactivatedStudentsScreenState extends State<DeactivatedStudentsScreen>
    with SingleTickerProviderStateMixin {
  List<Map<String, dynamic>> students = [];
  bool loading = true;
  String q = '';
  String? error;

  late final AnimationController _ambientController;

  Map<String, String> get h => {
        'Authorization': widget.token,
        'Accept': 'application/json',
        'Content-Type': 'application/json',
      };

  dynamic _unwrap(dynamic d) =>
      d is Map && d['data'] != null ? d['data'] : d;

  @override
  void initState() {
    super.initState();
    _ambientController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 6),
    )..repeat();
    load();
  }

  @override
  void dispose() {
    _ambientController.dispose();
    super.dispose();
  }

  Future<void> load() async {
    if (mounted) setState(() { loading = true; error = null; });
    try {
      final uri = Uri.parse(
        'https://emis.moedu.gov.iq/api/student/getstudents'
        '?page=1&rowsPerPage=20&sortBy=id&sortOrder=desc'
        '&entityId=${Uri.encodeQueryComponent(widget.schoolId)}'
        '&onlyDeactivated=true',
      );
      final response = await http.get(uri, headers: h);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception(
          'HTTP ${response.statusCode}: ${utf8.decode(response.bodyBytes)}',
        );
      }
      final decoded = _unwrap(jsonDecode(utf8.decode(response.bodyBytes)));
      final data = decoded is List ? decoded : const <dynamic>[];
      final list = data
          .whereType<Map<String, dynamic>>()
          .map((x) => Map<String, dynamic>.from(x))
          .toList();
      if (!mounted) return;
      setState(() {
        students = list;
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

  String name(Map<String, dynamic> s) {
    final direct = s['fullName'] ?? s['studentName'];
    if ('$direct'.trim().isNotEmpty) return '$direct';
    return [s['name'], s['fatherName'], s['grandFatherName'], s['surName']]
        .where((x) => x != null && '$x'.trim().isNotEmpty)
        .join(' ');
  }

  Future<void> _activateStudent(Map<String, dynamic> student) async {
    final id = student['id'];
    if (id == null) return;
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
              color: const Color(0xFF10B981).withOpacity(0.45),
              width: 1.5,
            ),
          ),
          title: Text(
            'تفعيل الطالب',
            style: TextStyle(
              color: isDark ? Colors.white : const Color(0xFF0F172A),
              fontWeight: FontWeight.w900,
            ),
          ),
          content: Text(
            'هل تريد تفعيل الطالب ${name(student)}؟',
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
                backgroundColor: const Color(0xFF10B981),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text(
                'تفعيل',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true) return;

    try {
      final uri = Uri.parse(
        'https://emis.moedu.gov.iq/api/student/activatestudent'
        '?id=${Uri.encodeQueryComponent('$id')}'
        '&schoolId=${Uri.encodeQueryComponent(widget.schoolId)}',
      );
      final response = await http.post(uri, headers: h);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception(
          'HTTP ${response.statusCode}: ${utf8.decode(response.bodyBytes)}',
        );
      }
      await load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'تم تفعيل الطالب بنجاح',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          backgroundColor: Color(0xFF10B981),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'فشل تفعيل الطالب: $e',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          backgroundColor: const Color(0xFFEF4444),
          behavior: SnackBarBehavior.floating,
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

  Widget _buildTopHeader(bool isDark) {
    const redNeon = Color(0xFFEF4444);
    const goldNeon = Color(0xFFF59E0B);
    const purpleNeon = Color(0xFFA855F7);

    return AnimatedBuilder(
      animation: _ambientController,
      builder: (context, _) {
        final pulse =
            0.5 + 0.5 * math.sin(_ambientController.value * 2 * math.pi);

        return Container(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
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
                      Color(0xFFFFF1F2),
                      Color(0xFFEDE9FE),
                    ],
                  ),
            borderRadius: BorderRadius.circular(28),
            border: Border.all(
              color: (isDark ? redNeon : purpleNeon)
                  .withOpacity(isDark ? 0.45 : 0.30),
              width: 1.5,
            ),
            boxShadow: [
              BoxShadow(
                color: (isDark ? redNeon : purpleNeon)
                    .withOpacity(0.12 + pulse * 0.08),
                blurRadius: 24,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Row(
            children: [
              _AnimatedDeactivatedOrbIcon(
                icon: Icons.person_off_rounded,
                primaryColor: redNeon,
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
                      'إدارة شؤون الطلاب',
                      style: TextStyle(
                        color: isDark ? goldNeon : redNeon,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'الطلبة غير المفعلين',
                      style: TextStyle(
                        color: isDark ? Colors.white : const Color(0xFF0F172A),
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'عرض وتفعيل الحسابات المتوقفة للطلاب في المدرسة',
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
                        : redNeon.withOpacity(0.10),
                    border: Border.all(
                      color: isDark
                          ? Colors.white.withOpacity(0.18)
                          : redNeon.withOpacity(0.28),
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
    final query = q.trim().toLowerCase();
    final filtered = students.where((student) {
      return name(student).toLowerCase().contains(query) ||
          '${student['id'] ?? ''}'.contains(q.trim());
    }).toList();

    return ValueListenableBuilder<ThemeMode>(
      valueListenable: AppCore.themeNotifier,
      builder: (context, mode, child) {
        final isDark = mode == ThemeMode.dark;
        final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
        final mutedColor =
            isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);

        const redNeon = Color(0xFFEF4444);
        const emeraldNeon = Color(0xFF10B981);
        const purpleNeon = Color(0xFFA855F7);
        const goldNeon = Color(0xFFF59E0B);

        return Directionality(
          textDirection: TextDirection.rtl,
          child: Scaffold(
            backgroundColor:
                isDark ? const Color(0xFF070913) : const Color(0xFFF2F5FA),
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
                                  ? redNeon.withOpacity(0.18)
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
                SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    child: Column(
                      children: [
                        _buildTopHeader(isDark),
                        const SizedBox(height: 14),

                        // حقل البحث المتوهج
                        TextField(
                          onChanged: (v) => setState(() => q = v),
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                            color: textColor,
                            fontSize: 13.5,
                          ),
                          decoration: InputDecoration(
                            labelText: 'بحث باسم الطالب أو الرقم',
                            labelStyle: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 12.5,
                              color: isDark
                                  ? const Color(0xFF94A3B8)
                                  : const Color(0xFF475569),
                            ),
                            prefixIcon:
                                const Icon(Icons.search_rounded, color: redNeon),
                            suffixIcon: q.isNotEmpty
                                ? IconButton(
                                    icon: const Icon(Icons.clear_rounded,
                                        size: 18),
                                    onPressed: () => setState(() => q = ''),
                                  )
                                : null,
                            filled: true,
                            fillColor: isDark
                                ? const Color(0xFF0B0E1A).withOpacity(0.68)
                                : const Color(0xFFF1F5F9),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(16),
                              borderSide: BorderSide(
                                color: redNeon.withOpacity(
                                    isDark ? 0.35 : 0.25),
                                width: 1.2,
                              ),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(16),
                              borderSide: BorderSide(
                                color: redNeon.withOpacity(
                                    isDark ? 0.35 : 0.25),
                                width: 1.2,
                              ),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(16),
                              borderSide: const BorderSide(color: redNeon, width: 1.8),
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),

                        if (error != null)
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: redNeon.withOpacity(0.12),
                              borderRadius: BorderRadius.circular(14),
                              border:
                                  Border.all(color: redNeon.withOpacity(0.4)),
                            ),
                            child: Text(
                              error!,
                              style: const TextStyle(
                                color: redNeon,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),

                        Expanded(
                          child: RefreshIndicator(
                            onRefresh: load,
                            color: redNeon,
                            child: loading
                                ? const Center(
                                    child: CircularProgressIndicator(
                                        color: redNeon),
                                  )
                                : filtered.isEmpty
                                    ? Center(
                                        child: Text(
                                          'لا يوجد طلبة غير مفعلين',
                                          style: TextStyle(
                                            fontWeight: FontWeight.w900,
                                            color: mutedColor,
                                            fontSize: 16,
                                          ),
                                        ),
                                      )
                                    : ListView.builder(
                                        physics:
                                            const AlwaysScrollableScrollPhysics(
                                          parent: BouncingScrollPhysics(),
                                        ),
                                        padding: const EdgeInsets.fromLTRB(
                                            0, 0, 0, 24),
                                        itemCount: filtered.length,
                                        itemBuilder: (context, index) {
                                          final student = filtered[index];
                                          return Container(
                                            margin: const EdgeInsets.only(
                                                bottom: 10),
                                            decoration: BoxDecoration(
                                              gradient: isDark
                                                  ? LinearGradient(
                                                      begin: Alignment.topLeft,
                                                      end: Alignment
                                                          .bottomRight,
                                                      colors: [
                                                        const Color(0xFF141829)
                                                            .withOpacity(0.95),
                                                        Color.lerp(
                                                            const Color(
                                                                0xFF0F1322),
                                                            redNeon,
                                                            0.07)!,
                                                      ],
                                                    )
                                                  : LinearGradient(
                                                      begin: Alignment.topLeft,
                                                      end: Alignment
                                                          .bottomRight,
                                                      colors: [
                                                        Colors.white,
                                                        Color.lerp(
                                                            const Color(
                                                                0xFFF8FAFC),
                                                            redNeon,
                                                            0.03)!,
                                                      ],
                                                    ),
                                              borderRadius:
                                                  BorderRadius.circular(20),
                                              border: Border.all(
                                                color: redNeon.withOpacity(
                                                    isDark ? 0.40 : 0.28),
                                                width: 1.3,
                                              ),
                                              boxShadow: [
                                                BoxShadow(
                                                  color: redNeon.withOpacity(
                                                      isDark ? 0.10 : 0.05),
                                                  blurRadius: 14,
                                                  offset: const Offset(0, 5),
                                                ),
                                              ],
                                            ),
                                            child: ListTile(
                                              contentPadding:
                                                  const EdgeInsets.symmetric(
                                                      horizontal: 14,
                                                      vertical: 4),
                                              leading: Container(
                                                width: 46,
                                                height: 46,
                                                decoration: BoxDecoration(
                                                  shape: BoxShape.circle,
                                                  color: redNeon
                                                      .withOpacity(0.15),
                                                ),
                                                child: const Icon(
                                                  Icons.person_off_rounded,
                                                  color: redNeon,
                                                  size: 22,
                                                ),
                                              ),
                                              title: Text(
                                                name(student),
                                                style: TextStyle(
                                                  color: textColor,
                                                  fontWeight: FontWeight.w900,
                                                  fontSize: 15,
                                                ),
                                              ),
                                              subtitle: Text(
                                                'رقم الطالب: ${student['id'] ?? ''}',
                                                style: TextStyle(
                                                  color: mutedColor,
                                                  fontWeight: FontWeight.w700,
                                                  fontSize: 12,
                                                ),
                                              ),
                                              trailing: Container(
                                                decoration: BoxDecoration(
                                                  shape: BoxShape.circle,
                                                  color: emeraldNeon
                                                      .withOpacity(0.15),
                                                ),
                                                child: IconButton(
                                                  onPressed: () =>
                                                      _activateStudent(student),
                                                  icon: const Icon(
                                                    Icons.person_add_alt_1_rounded,
                                                    color: emeraldNeon,
                                                    size: 20,
                                                  ),
                                                  tooltip: 'تفعيل الطالب',
                                                ),
                                              ),
                                            ),
                                          );
                                        },
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
      },
    );
  }
}

class _AnimatedDeactivatedOrbIcon extends StatelessWidget {
  final IconData icon;
  final Color primaryColor;
  final Color secondaryColor;
  final Animation<double> animation;
  final double size;

  const _AnimatedDeactivatedOrbIcon({
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
                  painter: _DeactivatedOrbPainter(
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

class _DeactivatedOrbPainter extends CustomPainter {
  final double progress;
  final Color primaryColor;
  final Color secondaryColor;

  _DeactivatedOrbPainter({
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
  bool shouldRepaint(covariant _DeactivatedOrbPainter oldDelegate) =>
      oldDelegate.progress != progress;
}
