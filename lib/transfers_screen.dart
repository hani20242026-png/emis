import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'app_core.dart';

enum TransferDirection {
  outgoing,
  incoming,
}

class TransfersScreen extends StatefulWidget {
  final String token;
  final String schoolId;

  const TransfersScreen({
    super.key,
    required this.token,
    required this.schoolId,
  });

  @override
  State<TransfersScreen> createState() => _TransfersScreenState();
}

class _TransfersScreenState extends State<TransfersScreen>
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
        gradient: AppCore.isWindows
            ? null
            : RadialGradient(
                colors: [color, color.withOpacity(0.0)],
              ),
        color: AppCore.isWindows
            ? AppCore.windowsGradientFallback(
                RadialGradient(colors: [color, color.withOpacity(0.0)]),
              )
            : null,
      ),
    );
  }

  Widget _buildHeader({
    required bool isDark,
    required String title,
    required String subtitle,
    required Color accent,
    required IconData icon,
    required VoidCallback onBack,
  }) {
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final mutedColor =
        isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);

    return AnimatedBuilder(
      animation: _ambientController,
      builder: (context, _) {
        final pulse =
            0.5 + 0.5 * math.sin(_ambientController.value * 2 * math.pi);

        return Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            gradient: AppCore.isWindows
                ? null
                : isDark
                    ? LinearGradient(
                        begin: Alignment.topRight,
                        end: Alignment.bottomLeft,
                        colors: [
                          Color.lerp(const Color(0xFF141829), accent, 0.16)!,
                          const Color(0xFF12172A),
                          const Color(0xFF19162E),
                        ],
                      )
                    : LinearGradient(
                        begin: Alignment.topRight,
                        end: Alignment.bottomLeft,
                        colors: [
                          Colors.white,
                          Color.lerp(const Color(0xFFF8FAFC), accent, 0.08)!,
                        ],
                      ),
            color: AppCore.isWindows
                ? AppCore.windowsGradientFallback(
                    isDark
                        ? LinearGradient(
                            begin: Alignment.topRight,
                            end: Alignment.bottomLeft,
                            colors: [
                              Color.lerp(
                                  const Color(0xFF141829), accent, 0.16)!,
                              const Color(0xFF12172A),
                            ],
                          )
                        : const LinearGradient(
                            colors: [Colors.white, Color(0xFFF8FAFC)],
                          ),
                  )
                : null,
            borderRadius: BorderRadius.circular(28),
            border: Border.all(
              color: accent.withOpacity(isDark ? 0.45 : 0.30),
              width: 1.5,
            ),
            boxShadow: [
              BoxShadow(
                color: accent.withOpacity(0.12 + pulse * 0.08),
                blurRadius: 24,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Row(
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: accent.withOpacity(0.15),
                  border: Border.all(color: accent.withOpacity(0.5), width: 1.4),
                ),
                child: Icon(icon, color: accent, size: 28),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        color: textColor,
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      style: TextStyle(
                        color: mutedColor,
                        fontSize: 12,
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
                    color: isDark
                        ? Colors.white.withOpacity(0.08)
                        : accent.withOpacity(0.10),
                    border: Border.all(
                      color: isDark
                          ? Colors.white.withOpacity(0.18)
                          : accent.withOpacity(0.28),
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

  Widget _buildCategoryCard({
    required bool isDark,
    required String title,
    required String subtitle,
    required String badgeText,
    required IconData icon,
    required Color accent,
    required VoidCallback onTap,
  }) {
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final mutedColor =
        isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(26),
        child: Ink(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            gradient: AppCore.isWindows
                ? null
                : isDark
                    ? LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          const Color(0xFF141829).withOpacity(0.95),
                          Color.lerp(const Color(0xFF0E1220), accent, 0.12)!,
                        ],
                      )
                    : LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          Colors.white,
                          Color.lerp(const Color(0xFFF8FAFC), accent, 0.05)!,
                        ],
                      ),
            color: AppCore.isWindows
                ? AppCore.windowsGradientFallback(
                    isDark
                        ? const LinearGradient(
                            colors: [Color(0xFF141829), Color(0xFF0E1220)],
                          )
                        : const LinearGradient(
                            colors: [Colors.white, Color(0xFFF8FAFC)],
                          ),
                  )
                : null,
            borderRadius: BorderRadius.circular(26),
            border: Border.all(
              color: accent.withOpacity(isDark ? 0.48 : 0.32),
              width: 1.4,
            ),
            boxShadow: [
              BoxShadow(
                color: accent.withOpacity(isDark ? 0.15 : 0.08),
                blurRadius: 20,
                offset: const Offset(0, 7),
              ),
            ],
          ),
          child: Row(
            children: [
              Container(
                width: 58,
                height: 58,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: accent.withOpacity(0.15),
                  border: Border.all(color: accent.withOpacity(0.5), width: 1.4),
                ),
                child: Icon(icon, color: accent, size: 29),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            title,
                            style: TextStyle(
                              color: textColor,
                              fontSize: 16.5,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: accent.withOpacity(isDark ? 0.18 : 0.12),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: accent.withOpacity(0.4)),
                          ),
                          child: Text(
                            badgeText,
                            style: TextStyle(
                              color: accent,
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      subtitle,
                      style: TextStyle(
                        color: mutedColor,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Icon(
                Icons.chevron_left_rounded,
                color: accent,
                size: 26,
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _openStudentTransfers(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => StudentTransfersScreen(
          token: widget.token,
          schoolId: widget.schoolId,
        ),
      ),
    );
  }

  void _openEmployeeTransfers(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => EmployeeTransfersScreen(
          token: widget.token,
          schoolId: widget.schoolId,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    const blueNeon = Color(0xFF3B82F6);
    const purpleNeon = Color(0xFFA855F7);
    const goldNeon = Color(0xFFF59E0B);

    return ValueListenableBuilder<ThemeMode>(
      valueListenable: AppCore.themeNotifier,
      builder: (context, mode, _) {
        final isDark = mode == ThemeMode.dark;
        return Directionality(
          textDirection: TextDirection.rtl,
          child: Scaffold(
            backgroundColor:
                isDark ? const Color(0xFF070913) : const Color(0xFFF2F5FA),
            body: Stack(
              children: [
                Positioned(
                  top: -50,
                  right: -50,
                  child: _buildAmbientGlow(
                    color: blueNeon.withOpacity(isDark ? 0.18 : 0.12),
                    size: 250,
                  ),
                ),
                Positioned(
                  bottom: -60,
                  left: -60,
                  child: _buildAmbientGlow(
                    color: purpleNeon.withOpacity(isDark ? 0.16 : 0.11),
                    size: 260,
                  ),
                ),
                SafeArea(
                  child: ListView(
                    physics: const BouncingScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
                    children: [
                      _buildHeader(
                        isDark: isDark,
                        title: 'الانتقالات',
                        subtitle: 'إدارة انتقالات الطلاب والموظفين في المدرسة',
                        accent: goldNeon,
                        icon: Icons.swap_horiz_rounded,
                        onBack: () => Navigator.of(context).pop(),
                      ),
                      const SizedBox(height: 18),
                      _buildCategoryCard(
                        isDark: isDark,
                        title: 'انتقالات الطلاب',
                        subtitle: 'الانتقالات الصادرة والانتقالات الواردة للطلاب',
                        badgeText: 'صادرة / واردة',
                        icon: Icons.school_rounded,
                        accent: blueNeon,
                        onTap: () => _openStudentTransfers(context),
                      ),
                      const SizedBox(height: 14),
                      _buildCategoryCard(
                        isDark: isDark,
                        title: 'انتقالات الموظفين',
                        subtitle: 'الانتقالات الصادرة والانتقالات الواردة للموظفين',
                        badgeText: 'صادرة / واردة',
                        icon: Icons.badge_rounded,
                        accent: purpleNeon,
                        onTap: () => _openEmployeeTransfers(context),
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

class StudentTransfersScreen extends StatefulWidget {
  final String token;
  final String schoolId;

  const StudentTransfersScreen({
    super.key,
    required this.token,
    required this.schoolId,
  });

  @override
  State<StudentTransfersScreen> createState() => _StudentTransfersScreenState();
}

class _StudentTransfersScreenState extends State<StudentTransfersScreen>
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

  void _openDirection(BuildContext context, TransferDirection direction) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TransferDirectionScreen(
          token: widget.token,
          schoolId: widget.schoolId,
          targetLabel: 'الطلاب',
          direction: direction,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    const blueNeon = Color(0xFF3B82F6);
    const orangeNeon = Color(0xFFF97316);
    const emeraldNeon = Color(0xFF10B981);

    return ValueListenableBuilder<ThemeMode>(
      valueListenable: AppCore.themeNotifier,
      builder: (context, mode, _) {
        final isDark = mode == ThemeMode.dark;
        final parentState =
            context.findAncestorStateOfType<_TransfersScreenState>();

        return Directionality(
          textDirection: TextDirection.rtl,
          child: Scaffold(
            backgroundColor:
                isDark ? const Color(0xFF070913) : const Color(0xFFF2F5FA),
            body: SafeArea(
              child: ListView(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
                children: [
                  parentState?._buildHeader(
                        isDark: isDark,
                        title: 'انتقالات الطلاب',
                        subtitle: 'اختر الانتقالات الصادرة أو الانتقالات الواردة',
                        accent: blueNeon,
                        icon: Icons.school_rounded,
                        onBack: () => Navigator.of(context).pop(),
                      ) ??
                      const SizedBox.shrink(),
                  const SizedBox(height: 18),
                  parentState?._buildCategoryCard(
                        isDark: isDark,
                        title: 'الانتقالات الصادرة',
                        subtitle: 'طلاب منتقلون من المدرسة إلى مدارس أخرى',
                        badgeText: 'صادرة',
                        icon: Icons.call_made_rounded,
                        accent: orangeNeon,
                        onTap: () =>
                            _openDirection(context, TransferDirection.outgoing),
                      ) ??
                      const SizedBox.shrink(),
                  const SizedBox(height: 14),
                  parentState?._buildCategoryCard(
                        isDark: isDark,
                        title: 'الانتقالات الواردة',
                        subtitle: 'طلاب منتقلون إلى المدرسة من مدارس أخرى',
                        badgeText: 'واردة',
                        icon: Icons.call_received_rounded,
                        accent: emeraldNeon,
                        onTap: () =>
                            _openDirection(context, TransferDirection.incoming),
                      ) ??
                      const SizedBox.shrink(),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class EmployeeTransfersScreen extends StatefulWidget {
  final String token;
  final String schoolId;

  const EmployeeTransfersScreen({
    super.key,
    required this.token,
    required this.schoolId,
  });

  @override
  State<EmployeeTransfersScreen> createState() =>
      _EmployeeTransfersScreenState();
}

class _EmployeeTransfersScreenState extends State<EmployeeTransfersScreen>
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

  void _openDirection(BuildContext context, TransferDirection direction) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TransferDirectionScreen(
          token: widget.token,
          schoolId: widget.schoolId,
          targetLabel: 'الموظفين',
          direction: direction,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    const purpleNeon = Color(0xFFA855F7);
    const orangeNeon = Color(0xFFF97316);
    const emeraldNeon = Color(0xFF10B981);

    return ValueListenableBuilder<ThemeMode>(
      valueListenable: AppCore.themeNotifier,
      builder: (context, mode, _) {
        final isDark = mode == ThemeMode.dark;
        final parentState =
            context.findAncestorStateOfType<_TransfersScreenState>();

        return Directionality(
          textDirection: TextDirection.rtl,
          child: Scaffold(
            backgroundColor:
                isDark ? const Color(0xFF070913) : const Color(0xFFF2F5FA),
            body: SafeArea(
              child: ListView(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
                children: [
                  parentState?._buildHeader(
                        isDark: isDark,
                        title: 'انتقالات الموظفين',
                        subtitle: 'اختر الانتقالات الصادرة أو الانتقالات الواردة',
                        accent: purpleNeon,
                        icon: Icons.badge_rounded,
                        onBack: () => Navigator.of(context).pop(),
                      ) ??
                      const SizedBox.shrink(),
                  const SizedBox(height: 18),
                  parentState?._buildCategoryCard(
                        isDark: isDark,
                        title: 'الانتقالات الصادرة',
                        subtitle: 'موظفون منتقلون من المدرسة إلى جهات أخرى',
                        badgeText: 'صادرة',
                        icon: Icons.call_made_rounded,
                        accent: orangeNeon,
                        onTap: () =>
                            _openDirection(context, TransferDirection.outgoing),
                      ) ??
                      const SizedBox.shrink(),
                  const SizedBox(height: 14),
                  parentState?._buildCategoryCard(
                        isDark: isDark,
                        title: 'الانتقالات الواردة',
                        subtitle: 'موظفون منتقلون إلى المدرسة من جهات أخرى',
                        badgeText: 'واردة',
                        icon: Icons.call_received_rounded,
                        accent: emeraldNeon,
                        onTap: () =>
                            _openDirection(context, TransferDirection.incoming),
                      ) ??
                      const SizedBox.shrink(),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class TransferDirectionScreen extends StatelessWidget {
  final String token;
  final String schoolId;
  final String targetLabel;
  final TransferDirection direction;

  const TransferDirectionScreen({
    super.key,
    required this.token,
    required this.schoolId,
    required this.targetLabel,
    required this.direction,
  });

  @override
  Widget build(BuildContext context) {
    final isOutgoing = direction == TransferDirection.outgoing;
    final directionTitle =
        isOutgoing ? 'الانتقالات الصادرة' : 'الانتقالات الواردة';
    final screenTitle = '$directionTitle — $targetLabel';
    final accent =
        isOutgoing ? const Color(0xFFF97316) : const Color(0xFF10B981);

    return ValueListenableBuilder<ThemeMode>(
      valueListenable: AppCore.themeNotifier,
      builder: (context, mode, _) {
        final isDark = mode == ThemeMode.dark;
        final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
        final mutedColor =
            isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);

        return Directionality(
          textDirection: TextDirection.rtl,
          child: Scaffold(
            backgroundColor:
                isDark ? const Color(0xFF070913) : const Color(0xFFF2F5FA),
            body: SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        GestureDetector(
                          onTap: () => Navigator.of(context).pop(),
                          child: Container(
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: isDark
                                  ? Colors.white.withOpacity(0.08)
                                  : accent.withOpacity(0.10),
                              border: Border.all(
                                color: isDark
                                    ? Colors.white.withOpacity(0.18)
                                    : accent.withOpacity(0.28),
                              ),
                            ),
                            child: Icon(
                              Icons.arrow_back_ios_rounded,
                              size: 19,
                              color: isDark
                                  ? Colors.white
                                  : const Color(0xFF1E293B),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            screenTitle,
                            style: TextStyle(
                              color: textColor,
                              fontSize: 17.5,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    Expanded(
                      child: Center(
                        child: Container(
                          padding: const EdgeInsets.all(24),
                          decoration: BoxDecoration(
                            color: isDark
                                ? const Color(0xFF141829).withOpacity(0.92)
                                : Colors.white,
                            borderRadius: BorderRadius.circular(24),
                            border: Border.all(
                              color: accent.withOpacity(0.35),
                              width: 1.3,
                            ),
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                isOutgoing
                                    ? Icons.call_made_rounded
                                    : Icons.call_received_rounded,
                                color: accent,
                                size: 42,
                              ),
                              const SizedBox(height: 12),
                              Text(
                                screenTitle,
                                style: TextStyle(
                                  color: textColor,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                'تم تجهيز بطاقة $directionTitle الخاصة بـ$targetLabel (مدرسة: $schoolId).\nأرفق طلبات الشبكة (API) من ملف HAR الخاص بهذه الصفحة لربط البيانات مباشرة.',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: mutedColor,
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w600,
                                  height: 1.5,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
