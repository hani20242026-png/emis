import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'app_core.dart';
import 'grade_smart_tools_card.dart';

class GradeSmartToolsScreen extends StatefulWidget {
  final String token;
  final String schoolId;
  final List<Map<String, dynamic>> stages;
  final Map<String, List<Map<String, dynamic>>> subjectsByStage;
  final Map<String, List<Map<String, dynamic>>> examsBySubject;

  const GradeSmartToolsScreen({
    super.key,
    required this.token,
    required this.schoolId,
    required this.stages,
    required this.subjectsByStage,
    required this.examsBySubject,
  });

  @override
  State<GradeSmartToolsScreen> createState() => _GradeSmartToolsScreenState();
}

class _GradeSmartToolsScreenState extends State<GradeSmartToolsScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ambientController;

  @override
  void initState() {
    super.initState();
    _ambientController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 6),
    )..repeat();
  }

  @override
  void dispose() {
    _ambientController.dispose();
    super.dispose();
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
              _AnimatedToolsOrbIcon(
                icon: Icons.auto_awesome_rounded,
                primaryColor: blueNeon,
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
                      'الأدوات الذكية للدرجات',
                      style: TextStyle(
                        color: isDark ? Colors.white : const Color(0xFF0F172A),
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'إدارة العمليات المتقدمة للامتحانات والفصول الدراسية',
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
      builder: (context, mode, child) {
        final isDark = mode == ThemeMode.dark;
        const blueNeon = Color(0xFF3B82F6);
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
                SafeArea(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                    physics: const BouncingScrollPhysics(),
                    children: [
                      _buildTopHeader(isDark),
                      const SizedBox(height: 14),
                      GradeSmartToolsCard(
                        token: widget.token,
                        schoolId: widget.schoolId,
                        stages: widget.stages,
                        subjectsByStage: widget.subjectsByStage,
                        examsBySubject: widget.examsBySubject,
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
}

class _AnimatedToolsOrbIcon extends StatelessWidget {
  final IconData icon;
  final Color primaryColor;
  final Color secondaryColor;
  final Animation<double> animation;
  final double size;

  const _AnimatedToolsOrbIcon({
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
                  painter: _ToolsAtomOrbitPainter(
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

class _ToolsAtomOrbitPainter extends CustomPainter {
  final double progress;
  final Color primaryColor;
  final Color secondaryColor;

  _ToolsAtomOrbitPainter({
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
  bool shouldRepaint(covariant _ToolsAtomOrbitPainter oldDelegate) =>
      oldDelegate.progress != progress;
}
