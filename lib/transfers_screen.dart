import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import 'package:flutter/material.dart';

import 'app_core.dart';


Widget _transferMenuHeader({
  required bool isDark,
  required String title,
  required String subtitle,
  required Color accent,
  required IconData icon,
  required VoidCallback onBack,
}) {
  final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
  final mutedColor = isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);
  return Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      gradient: isDark
          ? const LinearGradient(colors: [Color(0xFF141829), Color(0xFF19162E)])
          : const LinearGradient(colors: [Colors.white, Color(0xFFF8FAFC)]),
      borderRadius: BorderRadius.circular(26),
      border: Border.all(color: accent.withOpacity(0.32), width: 1.3),
      boxShadow: [
        BoxShadow(color: accent.withOpacity(0.10), blurRadius: 20, offset: const Offset(0, 7)),
      ],
    ),
    child: Row(
      children: [
        Container(
          width: 54,
          height: 54,
          decoration: BoxDecoration(shape: BoxShape.circle, color: accent.withOpacity(0.14)),
          child: Icon(icon, color: accent, size: 28),
        ),
        const SizedBox(width: 13),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: TextStyle(color: textColor, fontSize: 18, fontWeight: FontWeight.w900)),
              const SizedBox(height: 4),
              Text(subtitle, style: TextStyle(color: mutedColor, fontSize: 11.5, fontWeight: FontWeight.w600)),
            ],
          ),
        ),
        const SizedBox(width: 8),
        IconButton(
          onPressed: onBack,
          icon: Icon(Icons.arrow_back_ios_new_rounded, color: textColor, size: 19),
          style: IconButton.styleFrom(
            backgroundColor: accent.withOpacity(0.10),
            side: BorderSide(color: accent.withOpacity(0.25)),
            fixedSize: const Size(44, 44),
          ),
        ),
      ],
    ),
  );
}

Widget _transferMenuCard({
  required bool isDark,
  required String title,
  required String subtitle,
  required String badgeText,
  required IconData icon,
  required Color accent,
  required VoidCallback onTap,
}) {
  final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
  final mutedColor = isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);
  return Material(
    color: Colors.transparent,
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(24),
      child: Ink(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          gradient: isDark
              ? LinearGradient(colors: [const Color(0xFF141829), Color.lerp(const Color(0xFF101525), accent, 0.12)!])
              : const LinearGradient(colors: [Colors.white, Color(0xFFF8FAFC)]),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: accent.withOpacity(isDark ? 0.38 : 0.28), width: 1.2),
          boxShadow: [BoxShadow(color: accent.withOpacity(0.08), blurRadius: 16, offset: const Offset(0, 5))],
        ),
        child: Row(
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(shape: BoxShape.circle, color: accent.withOpacity(0.14)),
              child: Icon(icon, color: accent, size: 26),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: TextStyle(color: textColor, fontSize: 15.5, fontWeight: FontWeight.w900)),
                  const SizedBox(height: 5),
                  Text(subtitle, style: TextStyle(color: mutedColor, fontSize: 11.5, fontWeight: FontWeight.w600)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(color: accent.withOpacity(0.13), borderRadius: BorderRadius.circular(20)),
                  child: Text(badgeText, style: TextStyle(color: accent, fontSize: 10.5, fontWeight: FontWeight.w900)),
                ),
                const SizedBox(height: 8),
                Icon(Icons.chevron_left_rounded, color: accent, size: 25),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

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
                  _transferMenuHeader(
                        isDark: isDark,
                        title: 'انتقالات الطلاب',
                        subtitle: 'اختر الانتقالات الصادرة أو الانتقالات الواردة',
                        accent: blueNeon,
                        icon: Icons.school_rounded,
                        onBack: () => Navigator.of(context).pop(),
                      ),
                  const SizedBox(height: 18),
                  _transferMenuCard(
                        isDark: isDark,
                        title: 'الانتقالات الصادرة',
                        subtitle: 'طلاب منتقلون من المدرسة إلى مدارس أخرى',
                        badgeText: 'صادرة',
                        icon: Icons.call_made_rounded,
                        accent: orangeNeon,
                        onTap: () =>
                            _openDirection(context, TransferDirection.outgoing),
                      ),
                  const SizedBox(height: 14),
                  _transferMenuCard(
                        isDark: isDark,
                        title: 'الانتقالات الواردة',
                        subtitle: 'طلاب منتقلون إلى المدرسة من مدارس أخرى',
                        badgeText: 'واردة',
                        icon: Icons.call_received_rounded,
                        accent: emeraldNeon,
                        onTap: () =>
                            _openDirection(context, TransferDirection.incoming),
                      ),
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
                  _transferMenuHeader(
                        isDark: isDark,
                        title: 'انتقالات الموظفين',
                        subtitle: 'اختر الانتقالات الصادرة أو الانتقالات الواردة',
                        accent: purpleNeon,
                        icon: Icons.badge_rounded,
                        onBack: () => Navigator.of(context).pop(),
                      ),
                  const SizedBox(height: 18),
                  _transferMenuCard(
                        isDark: isDark,
                        title: 'الانتقالات الصادرة',
                        subtitle: 'موظفون منتقلون من المدرسة إلى جهات أخرى',
                        badgeText: 'صادرة',
                        icon: Icons.call_made_rounded,
                        accent: orangeNeon,
                        onTap: () =>
                            _openDirection(context, TransferDirection.outgoing),
                      ),
                  const SizedBox(height: 14),
                  _transferMenuCard(
                        isDark: isDark,
                        title: 'الانتقالات الواردة',
                        subtitle: 'موظفون منتقلون إلى المدرسة من جهات أخرى',
                        badgeText: 'واردة',
                        icon: Icons.call_received_rounded,
                        accent: emeraldNeon,
                        onTap: () =>
                            _openDirection(context, TransferDirection.incoming),
                      ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}


class TransferDirectionScreen extends StatefulWidget {
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
  State<TransferDirectionScreen> createState() => _TransferDirectionScreenState();
}

class _TransferDirectionScreenState extends State<TransferDirectionScreen> {
  bool loading = true;
  String? error;
  List<Map<String, dynamic>> transfers = [];

  bool get isStudent => widget.targetLabel == 'الطلاب';
  bool get isOutgoing => widget.direction == TransferDirection.outgoing;

  String get title =>
      '${isOutgoing ? 'الانتقالات الصادرة' : 'الانتقالات الواردة'} — ${widget.targetLabel}';

  Color get accent =>
      isOutgoing ? const Color(0xFFF97316) : const Color(0xFF10B981);

  Map<String, String> get _headers => {
        'Authorization': widget.token,
        'Accept': 'application/json',
      };

  String get _endpoint {
    if (isStudent) {
      return isOutgoing
          ? '/studentTransfer/getstudenttransfers'
          : '/studentTransfer/getstudenttransferrequests';
    }
    return isOutgoing
        ? '/employeeTransfer/getoutgoingemployeetransfers'
        : '/employeeTransfer/getSchoolincomingemployeetransfers';
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        loading = true;
        error = null;
      });
    }
    try {
      final uri = Uri.https(
        'emis.moedu.gov.iq',
        '/api$_endpoint',
        {
          'page': '1',
          'rowsPerPage': '20',
          'sortBy': 'id',
          'sortOrder': 'desc',
          'entityId': widget.schoolId,
        },
      );
      final response = await http.get(uri, headers: _headers);
      final body = utf8.decode(response.bodyBytes);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception('HTTP ${response.statusCode}: $body');
      }
      final decoded = jsonDecode(body);
      dynamic raw = decoded is Map ? decoded['data'] : decoded;
      if (raw is! List) {
        throw Exception('صيغة استجابة الانتقالات غير متوقعة.');
      }
      final parsed = raw
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList();
      if (!mounted) return;
      setState(() {
        transfers = parsed;
        loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        error = e.toString().replaceFirst('Exception: ', '');
        loading = false;
      });
    }
  }

  String _value(Map<String, dynamic> item, String key) =>
      (item[key] ?? '').toString().trim();

  String _personName(Map<String, dynamic> item) => _value(
        item,
        isStudent ? 'studentFullName' : 'employeeFullName',
      );

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: AppCore.themeNotifier,
      builder: (context, mode, _) {
        final dark = mode == ThemeMode.dark;
        final foreground = dark ? Colors.white : const Color(0xFF0F172A);
        final muted = dark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);
        return Directionality(
          textDirection: TextDirection.rtl,
          child: Scaffold(
            backgroundColor: dark ? const Color(0xFF070913) : const Color(0xFFF2F5FA),
            body: SafeArea(
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
                    child: Row(
                      children: [
                        IconButton(
                          onPressed: () => Navigator.of(context).pop(),
                          icon: Icon(Icons.arrow_back_ios_new_rounded, color: foreground),
                          style: IconButton.styleFrom(
                            backgroundColor: accent.withOpacity(0.10),
                            fixedSize: const Size(44, 44),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(title, style: TextStyle(color: foreground, fontSize: 17, fontWeight: FontWeight.w900)),
                        ),
                        IconButton(
                          onPressed: loading ? null : _load,
                          icon: Icon(Icons.refresh_rounded, color: accent),
                          tooltip: 'تحديث',
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: loading
                        ? Center(child: CircularProgressIndicator(color: accent))
                        : error != null
                            ? Center(
                                child: Padding(
                                  padding: const EdgeInsets.all(24),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.cloud_off_rounded, color: accent, size: 42),
                                      const SizedBox(height: 12),
                                      Text('تعذر تحميل بيانات الانتقالات', style: TextStyle(color: foreground, fontWeight: FontWeight.w900, fontSize: 16)),
                                      const SizedBox(height: 8),
                                      Text(error!, textAlign: TextAlign.center, style: TextStyle(color: muted, fontSize: 12)),
                                      const SizedBox(height: 16),
                                      FilledButton.icon(onPressed: _load, icon: const Icon(Icons.refresh), label: const Text('إعادة المحاولة')),
                                    ],
                                  ),
                                ),
                              )
                            : transfers.isEmpty
                                ? Center(
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(Icons.swap_horiz_rounded, color: accent, size: 48),
                                        const SizedBox(height: 12),
                                        Text('لا توجد انتقالات لعرضها حالياً', style: TextStyle(color: foreground, fontWeight: FontWeight.w800)),
                                      ],
                                    ),
                                  )
                                : RefreshIndicator(
                                    onRefresh: _load,
                                    color: accent,
                                    child: ListView.separated(
                                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                                      itemCount: transfers.length,
                                      separatorBuilder: (_, __) => const SizedBox(height: 10),
                                      itemBuilder: (context, index) {
                                        final item = transfers[index];
                                        final name = _personName(item);
                                        final from = _value(item, 'fromEntity');
                                        final to = _value(item, 'toEntity');
                                        final date = _value(item, 'date');
                                        final status = _value(item, 'status');
                                        final reason = _value(item, 'rejectionReason');
                                        final transferType = _value(item, 'transferType');
                                        return Container(
                                          padding: const EdgeInsets.all(15),
                                          decoration: BoxDecoration(
                                            color: dark ? const Color(0xFF141829) : Colors.white,
                                            borderRadius: BorderRadius.circular(20),
                                            border: Border.all(color: accent.withOpacity(0.22)),
                                            boxShadow: [BoxShadow(color: accent.withOpacity(0.05), blurRadius: 14, offset: const Offset(0, 4))],
                                          ),
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Row(
                                                children: [
                                                  Expanded(
                                                    child: Text(name.isEmpty ? '—' : name, style: TextStyle(color: foreground, fontSize: 14, fontWeight: FontWeight.w900)),
                                                  ),
                                                  if (status.isNotEmpty)
                                                    Container(
                                                      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                                                      decoration: BoxDecoration(color: accent.withOpacity(0.12), borderRadius: BorderRadius.circular(20)),
                                                      child: Text(status, style: TextStyle(color: accent, fontSize: 10.5, fontWeight: FontWeight.w800)),
                                                    ),
                                                ],
                                              ),
                                              if (transferType.isNotEmpty) ...[
                                                const SizedBox(height: 7),
                                                Text('نوع الانتقال: $transferType', style: TextStyle(color: muted, fontSize: 11.5, fontWeight: FontWeight.w700)),
                                              ],
                                              const SizedBox(height: 10),
                                              _detailLine('من', from, foreground, muted),
                                              const SizedBox(height: 5),
                                              _detailLine('إلى', to, foreground, muted),
                                              if (date.isNotEmpty) ...[
                                                const SizedBox(height: 8),
                                                _detailLine('التاريخ', date, foreground, muted),
                                              ],
                                              if (reason.isNotEmpty) ...[
                                                const SizedBox(height: 8),
                                                _detailLine('الملاحظات', reason, foreground, muted),
                                              ],
                                            ],
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
        );
      },
    );
  }

  Widget _detailLine(String label, String value, Color foreground, Color muted) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: 54, child: Text('$label:', style: TextStyle(color: muted, fontSize: 11.5, fontWeight: FontWeight.w700))),
        Expanded(child: Text(value.isEmpty ? '—' : value, style: TextStyle(color: foreground, fontSize: 11.5, fontWeight: FontWeight.w700))),
      ],
    );
  }
}
