import 'dart:async';
import 'dart:math' as math;
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'emis_webview_screen.dart';
import 'app_core.dart';
import 'google_speech_service.dart';
import 'platform_permissions.dart';

class SettingsScreen extends StatefulWidget {
  final String? token;
  final String? schoolId;

  const SettingsScreen({super.key, this.token, this.schoolId});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with SingleTickerProviderStateMixin {
  List<Map<String, dynamic>> _studentStages = [];
  List<Map<String, dynamic>> _studentClassRooms = [];
  bool _loadingStudentStages = false;

  bool _checkingGoogleSpeech = true;
  bool _googleSpeechAvailable = false;
  String _googleSpeechMessage = 'جاري فحص خدمة Google...';

  // خيار المعالجة السريعة والطوابير الذكية (اختياري ومستحسن لحل مشاكل الأداء)
  bool _fastProcessingQueueEnabled = true;

  late final AnimationController _ambientController;

  late final TextEditingController _countryCtrl;
  late final TextEditingController _govCtrl;
  late final TextEditingController _districtCtrl;
  late final TextEditingController _townCtrl;
  late final TextEditingController _areaCtrl;
  late final TextEditingController _homeTownCtrl;
  late final TextEditingController _address1Ctrl;
  late final TextEditingController _address2Ctrl;
  late final TextEditingController _closestLocationCtrl;

  static const List<String> _iraqGovernorates = [
    'نينوى',
    'صلاح الدين',
    'كركوك',
    'ديالى',
    'بغداد',
    'الأنبار',
    'بابل',
    'كربلاء',
    'النجف',
    'القادسية',
    'المثنى',
    'واسط',
    'ذي قار',
    'ميسان',
    'البصرة',
    'أربيل',
    'دهوك',
    'السليمانية',
    'حلبجة',
  ];

  static const List<Map<String, dynamic>> _economicLevelOptions = [
    {'value': 'الطبقة تحت خط الفقر', 'label': 'الطبقة تحت خط الفقر'},
    {'value': 'الطبقة الفقيرة', 'label': 'الطبقة الفقيرة'},
    {'value': 'الطبقة الوسطى', 'label': 'الطبقة الوسطى'},
    {'value': 'الطبقة العليا', 'label': 'الطبقة العليا'},
  ];

  static const List<Map<String, dynamic>> _employmentTypeOptions = [
    {'value': 'ملاك', 'label': 'ملاك دائم'},
    {'value': 'عقد', 'label': 'عقد'},
    {'value': 'محاضر', 'label': 'محاضر'},
    {'value': 'أجر يومي', 'label': 'أجر يومي'},
  ];

  static const List<Map<String, dynamic>> _teacherStatusOptions = [
    {'value': 'مستمر', 'label': 'مستمر'},
    {'value': 'متقاعد', 'label': 'متقاعد'},
    {'value': 'مفصول', 'label': 'مفصول'},
    {'value': 'متوفى', 'label': 'متوفى'},
    {'value': 'استقالة', 'label': 'استقالة'},
    {'value': 'منقول الى وزارة أخرى', 'label': 'منقول الى وزارة أخرى'},
    {'value': 'العزل', 'label': 'العزل'},
    {
      'value': 'مكلف او منسبي من خارج الوزاراة',
      'label': 'مكلف او منسبي من خارج الوزاراة'
    },
    {
      'value': 'مكلف او منسب من وزارة التربية الى جهات أخرى',
      'label': 'مكلف او منسب من وزارة التربية الى جهات أخرى'
    },
    {'value': 'في إجازة دراسية', 'label': 'في إجازة دراسية'},
    {'value': 'في إجازة أمومة', 'label': 'في إجازة أمومة'},
    {'value': 'أخرى', 'label': 'أخرى'},
    {'value': 'مجاز', 'label': 'مجاز'},
    {'value': 'منسب', 'label': 'منسب'},
    {'value': 'سحب يد', 'label': 'سحب يد'},
    {'value': 'مستقيل', 'label': 'مستقيل'},
  ];

  static const List<Map<String, dynamic>> _educationLevelOptions = [
    {'value': 'إعدادية', 'label': 'إعدادية'},
    {'value': 'إعدادية مهنية', 'label': 'إعدادية مهنية'},
    {'value': 'إعدادية دورة تأهيلية', 'label': 'إعدادية دورة تأهيلية'},
    {'value': 'دبلوم عالي', 'label': 'دبلوم عالي'},
    {'value': 'دبلوم معهد تطوير', 'label': 'دبلوم معهد تطوير'},
    {'value': 'دبلوم', 'label': 'دبلوم'},
    {'value': 'بكالوريوس', 'label': 'بكالوريوس'},
    {'value': 'ماجستير', 'label': 'ماجستير'},
    {'value': 'دكتوراه', 'label': 'دكتوراه'},
    {'value': 'دار المعلمين', 'label': 'دار المعلمين'},
    {'value': 'خريج ابتدائية', 'label': 'خريج ابتدائية'},
    {'value': 'خريج متوسطة', 'label': 'خريج متوسطة'},
    {'value': 'أخرى', 'label': 'أخرى'},
    {'value': 'يقرأ ويكتب', 'label': 'يقرأ ويكتب'},
    {'value': 'أمي', 'label': 'أمي'},
    {'value': 'مجهول', 'label': 'مجهول'},
    {'value': 'ابتدائية', 'label': 'ابتدائية'},
    {'value': 'متوسطة', 'label': 'متوسطة'},
  ];

  @override
  void initState() {
    super.initState();
    _ambientController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 6),
    )..repeat();

    _countryCtrl = TextEditingController(text: AppCore.defaultCountry);
    _govCtrl = TextEditingController(text: AppCore.defaultGovernorate);
    _districtCtrl = TextEditingController(text: AppCore.defaultDistrict);
    _townCtrl = TextEditingController(text: AppCore.defaultTown);
    _areaCtrl = TextEditingController(text: AppCore.defaultArea);
    _homeTownCtrl = TextEditingController(text: AppCore.defaultHomeTown);
    _address1Ctrl = TextEditingController(text: AppCore.defaultAddress1);
    _address2Ctrl = TextEditingController(text: AppCore.defaultAddress2);
    _closestLocationCtrl =
        TextEditingController(text: AppCore.defaultClosestLocation);
    _loadSavedSettings();
    _checkGoogleSpeech();
  }

  String _academicOptionValue(Map<String, dynamic> item) =>
      '${item['value'] ?? item['id'] ?? item['code'] ?? ''}';

  String _academicOptionLabel(Map<String, dynamic> item) =>
      '${item['displayName'] ?? item['label'] ?? item['name'] ?? item['text'] ?? _academicOptionValue(item)}';

  dynamic _unwrapAcademic(dynamic value) =>
      value is Map && value['data'] != null ? value['data'] : value;

  Future<List<Map<String, dynamic>>> _fetchAcademicOptions(String endpoint) async {
    final response = await http.get(
      Uri.parse('https://emis.moedu.gov.iq/api$endpoint'),
      headers: {
        if ((widget.token ?? '').isNotEmpty) 'Authorization': widget.token!,
        'Accept': 'application/json',
      },
    ).timeout(const Duration(seconds: 15));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('HTTP ${response.statusCode}');
    }
    final raw = _unwrapAcademic(jsonDecode(utf8.decode(response.bodyBytes)));
    if (raw is! List) return [];
    return [
      for (final item in raw)
        if (item is Map) Map<String, dynamic>.from(item),
    ];
  }

  Future<void> _loadStudentAcademicDefaults() async {
    await AppCore.ensureLoaded();
    final schoolId = widget.schoolId;
    if (schoolId == null || schoolId.isEmpty || (widget.token ?? '').isEmpty) return;
    if (mounted) setState(() => _loadingStudentStages = true);
    try {
      final stages = await _fetchAcademicOptions(
        '/selectoption/getAvailableStagesForStudent?schoolId=$schoolId');
      final stageId = AppCore.defaultStudentStageId;
      final validStage = stages.any((e) => _academicOptionValue(e) == stageId);
      var rooms = <Map<String, dynamic>>[];
      if (validStage) {
        rooms = await _fetchAcademicOptions(
          '/selectoption/getClassRooms?schoolId=$schoolId&stageId=$stageId');
      }
      final validRoom = rooms.any((e) =>
          _academicOptionValue(e) == AppCore.defaultStudentClassRoomId);
      if (!validStage && AppCore.defaultStudentStageId.isNotEmpty) {
        await AppCore.saveDefaultFieldValues(studentStageId: '', studentClassRoomId: '');
      } else if (!validRoom && AppCore.defaultStudentClassRoomId.isNotEmpty) {
        await AppCore.saveDefaultFieldValues(studentClassRoomId: '');
      }
      if (!mounted) return;
      setState(() {
        _studentStages = stages;
        _studentClassRooms = rooms;
        _loadingStudentStages = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingStudentStages = false);
    }
  }

  Future<void> _onDefaultStudentStageChanged(String? value) async {
    if (value == null) return;
    await AppCore.saveDefaultFieldValues(
      studentStageId: value, studentClassRoomId: '');
    if (widget.schoolId == null || widget.schoolId!.isEmpty) return;
    try {
      final rooms = await _fetchAcademicOptions(
        '/selectoption/getClassRooms?schoolId=${widget.schoolId}&stageId=$value');
      if (!mounted) return;
      setState(() => _studentClassRooms = rooms);
    } catch (_) {
      if (mounted) setState(() => _studentClassRooms = []);
    }
    if (mounted) setState(() {});
  }

  Future<void> _loadSavedSettings() async {
    await AppCore.initPreferences();
    _countryCtrl.text = AppCore.defaultCountry;
    _govCtrl.text = AppCore.defaultGovernorate;
    _districtCtrl.text = AppCore.defaultDistrict;
    _townCtrl.text = AppCore.defaultTown;
    _areaCtrl.text = AppCore.defaultArea;
    _homeTownCtrl.text = AppCore.defaultHomeTown;
    _address1Ctrl.text = AppCore.defaultAddress1;
    _address2Ctrl.text = AppCore.defaultAddress2;
    _closestLocationCtrl.text = AppCore.defaultClosestLocation;
    
    // تحميل حالة الطوابير الذكية والمعالجة السريعة (المستحسن افتراضياً: صحيح)
    _fastProcessingQueueEnabled = AppCore.prefs.getBool('fast_processing_queue_enabled') ?? true;

    if (mounted) setState(() {});
    await _loadStudentAcademicDefaults();
  }

  Future<void> _toggleFastProcessingQueue(bool value) async {
    setState(() {
      _fastProcessingQueueEnabled = value;
    });
    await AppCore.prefs.setBool('fast_processing_queue_enabled', value);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          value
              ? 'تم تفعيل المعالجة السريعة والطوابير الذكية (الوضع المستحسن).'
              : 'تم إيقاف المعالجة السريعة.',
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        backgroundColor: const Color(0xFF10B981),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    );
  }

  @override
  void dispose() {
    _ambientController.dispose();
    _countryCtrl.dispose();
    _govCtrl.dispose();
    _districtCtrl.dispose();
    _townCtrl.dispose();
    _areaCtrl.dispose();
    _homeTownCtrl.dispose();
    _address1Ctrl.dispose();
    _address2Ctrl.dispose();
    _closestLocationCtrl.dispose();
    super.dispose();
  }

  Future<void> _checkGoogleSpeech() async {
    if (mounted) {
      setState(() {
        _checkingGoogleSpeech = true;
        _googleSpeechMessage = 'جاري فحص خدمة Google...';
      });
    }
    try {
      final info = await GoogleSpeechService.getInfo()
          .timeout(const Duration(seconds: 3));
      final available = info['available'] == true;
      final googleAvailable = info['googleAvailable'] == true;
      final provider = '${info['provider'] ?? ''}'.trim();
      final defaultPackage = '${info['defaultPackage'] ?? ''}'.trim();
      if (!mounted) return;
      setState(() {
        _googleSpeechAvailable = available;
        _checkingGoogleSpeech = false;
        if (!available) {
          _googleSpeechMessage =
              'لا توجد خدمة تعرف صوتي افتراضية متاحة في Android. افتح إعدادات إدخال الصوت وتأكد من تفعيل خدمة التعرف.';
        } else if (googleAvailable) {
          _googleSpeechMessage =
              'Google متاحة مباشرة. مزود التعرف الحالي: ${provider.isEmpty ? 'Google' : provider}.';
        } else {
          _googleSpeechMessage =
              'تطبيق Google مثبت، لكن Android لا يعرضه كخدمة مستقلة. سيتم استخدام خدمة التعرف الافتراضية${defaultPackage.isEmpty ? '' : ' ($defaultPackage)'}، وقد تكون Google.';
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _checkingGoogleSpeech = false;
        _googleSpeechAvailable = false;
        _googleSpeechMessage = 'تعذر فحص خدمات التعرف الصوتي في Android.';
      });
    }
  }

  Future<void> _setVoiceSetting({
    bool? autoRestart,
    int? possibleSilenceMs,
    int? completeSilenceMs,
    int? minimumSpeechMs,
    int? restartDelayMs,
    int? finalizationTimeoutMs,
    double? arrowOpacity,
    bool? muteIntermediateBeeps,
    bool? continuousSingleSession,
    bool? iraqiFastDigitsMode,
    bool? autoStopOnTargetLength,
  }) async {
    await AppCore.saveVoiceSettings(
      autoRestart: autoRestart,
      possibleSilenceMs: possibleSilenceMs,
      completeSilenceMs: completeSilenceMs,
      minimumSpeechMs: minimumSpeechMs,
      restartDelayMs: restartDelayMs,
      finalizationTimeoutMs: finalizationTimeoutMs,
      arrowOpacity: arrowOpacity,
      muteIntermediateBeeps: muteIntermediateBeeps,
      continuousSingleSession: continuousSingleSession,
      iraqiFastDigitsMode: iraqiFastDigitsMode,
      autoStopOnTargetLength: autoStopOnTargetLength,
    );
    if (mounted) setState(() {});
  }

  Future<void> _resetVoiceSettings() async {
    await AppCore.resetVoiceSettings();
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text(
          'تمت استعادة الإعدادات الافتراضية للمايكروفون بنجاح.',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        backgroundColor: const Color(0xFF10B981),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    );
  }

  Future<void> _resetDefaultFields() async {
    await AppCore.resetDefaultFieldValues();
    _countryCtrl.text = AppCore.defaultCountry;
    _govCtrl.text = AppCore.defaultGovernorate;
    _districtCtrl.text = AppCore.defaultDistrict;
    _townCtrl.text = AppCore.defaultTown;
    _areaCtrl.text = AppCore.defaultArea;
    _homeTownCtrl.text = AppCore.defaultHomeTown;
    _address1Ctrl.text = AppCore.defaultAddress1;
    _address2Ctrl.text = AppCore.defaultAddress2;
    _closestLocationCtrl.text = AppCore.defaultClosestLocation;
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text(
          'تمت استعادة القيم الافتراضية الأصلية للمدرسة والحقول.',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        backgroundColor: const Color(0xFF10B981),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    );
  }

  Future<void> _setVoiceEnabled(bool enabled) async {
    if (enabled) {
      try {
        final microphoneAllowed = await ensureEmisMicrophonePermission()
            .timeout(const Duration(seconds: 5));
        if (!microphoneAllowed) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text(
                'يجب السماح باستخدام الميكروفون من إعدادات النظام أولاً.',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              backgroundColor: const Color(0xFFF97316),
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16)),
            ),
          );
          return;
        }
      } catch (e) {
        debugPrint('Permission request error: $e');
      }
    }

    await AppCore.setVoiceInputEnabled(enabled);
    if (mounted) setState(() {});
  }

  Future<void> _logout() async {
    final isDark = AppCore.themeNotifier.value == ThemeMode.dark;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          backgroundColor:
              isDark ? const Color(0xFF141829) : const Color(0xFFFFFFFF),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
            side: BorderSide(
              color: const Color(0xFFEF4444).withOpacity(0.45),
              width: 1.4,
            ),
          ),
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: const Color(0xFFEF4444).withOpacity(0.15),
                ),
                child: const Icon(
                  Icons.logout_rounded,
                  color: Color(0xFFEF4444),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                'تسجيل الخروج',
                style: TextStyle(
                  color: isDark ? Colors.white : const Color(0xFF0F172A),
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
          content: Text(
            'سيتم حذف جلسة EMIS المحفوظة وملفات تعريف الارتباط وبيانات الدخول المحلية، ثم فتح صفحة تسجيل الدخول من جديد. هل تريد المتابعة؟',
            style: TextStyle(
              color: isDark ? const Color(0xFFCBD5E1) : const Color(0xFF475569),
              height: 1.45,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
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
                backgroundColor: const Color(0xFFEF4444),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text(
                'تسجيل الخروج',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(
        child: CircularProgressIndicator(color: Color(0xFF10B981)),
      ),
    );

    final cookieManager = WebViewCookieManager();
    try {
      await cookieManager.clearCookies().timeout(const Duration(seconds: 2));
    } catch (e) {
      debugPrint('تعذر حذف Cookies قبل تسجيل الخروج: $e');
    }

    try {
      final pageLoaded = Completer<void>();
      final cleanupController = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setNavigationDelegate(
          NavigationDelegate(
            onPageFinished: (_) {
              if (!pageLoaded.isCompleted) pageLoaded.complete();
            },
          ),
        );
      await cleanupController.loadRequest(
        Uri.parse('https://emis.moedu.gov.iq/auth/login?logout_cleanup=1'),
      );
      await pageLoaded.future.timeout(const Duration(seconds: 3));
      await cleanupController.runJavaScript(r'''(async function() {
        try { localStorage.clear(); } catch (_) {}
        try { sessionStorage.clear(); } catch (_) {}
        try {
          if (window.indexedDB && indexedDB.databases) {
            const dbs = await indexedDB.databases();
            await Promise.all(dbs.map(db => db.name ? new Promise(resolve => {
              const req = indexedDB.deleteDatabase(db.name);
              req.onsuccess = req.onerror = req.onblocked = () => resolve();
            }) : Promise.resolve()));
          }
        } catch (_) {}
        try {
          if (navigator.serviceWorker && navigator.serviceWorker.getRegistrations) {
            const registrations = await navigator.serviceWorker.getRegistrations();
            await Promise.all(registrations.map(reg => reg.unregister()));
          }
        } catch (_) {}
        try {
          if (window.caches && caches.keys) {
            const keys = await caches.keys();
            await Promise.all(keys.map(key => caches.delete(key)));
          }
        } catch (_) {}
        try {
          document.querySelectorAll('input').forEach(input => {
            if (/password|username|user|email|login/i.test(
              [input.name, input.id, input.autocomplete, input.type].join(' '))) {
              input.value = '';
            }
          });
        } catch (_) {}
      })();''').timeout(const Duration(seconds: 2));
      await cookieManager.clearCookies().timeout(const Duration(seconds: 2));
    } catch (e) {
      debugPrint('تعذر مسح بعض بيانات متصفح EMIS: $e');
      try {
        await cookieManager.clearCookies().timeout(const Duration(seconds: 1));
      } catch (_) {}
    }

    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(
        builder: (_) => const EmisWebviewScreen(startAtLogin: true),
      ),
      (route) => false,
    );
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

  Widget _buildModel1TopHeader({
    required bool isDark,
    required VoidCallback onBack,
  }) {
    const emeraldNeon = Color(0xFF10B981);
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
            borderRadius: BorderRadius.circular(28),
            border: Border.all(
              color: (isDark ? emeraldNeon : purpleNeon)
                  .withOpacity(isDark ? 0.45 : 0.30),
              width: 1.5,
            ),
            boxShadow: [
              BoxShadow(
                color: (isDark ? emeraldNeon : purpleNeon)
                    .withOpacity(0.12 + pulse * 0.08),
                blurRadius: 24,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Row(
            children: [
              _AnimatedOrbIcon(
                icon: Icons.settings_suggest_rounded,
                primaryColor: goldNeon,
                secondaryColor: emeraldNeon,
                animation: _ambientController,
                effectType: _OrbEffectType.atomicOrbits,
                size: 62,
                rotateIcon: true,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'لوحة التحكم المتقدمة',
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
                      'إعدادات التطبيق والنظام',
                      style: TextStyle(
                        color: isDark ? Colors.white : const Color(0xFF0F172A),
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'تخصيص المظهر، الصوت، القيم الافتراضية والمايكروفون الذكي',
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
                onTap: onBack,
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: isDark
                        ? Colors.white.withOpacity(0.08)
                        : const Color(0xFF6366F1).withOpacity(0.10),
                    border: Border.all(
                      color: isDark
                          ? Colors.white.withOpacity(0.18)
                          : const Color(0xFF6366F1).withOpacity(0.28),
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

  Widget _buildGlowingCard({
    required bool isDark,
    required Color accentColor,
    required Widget child,
    EdgeInsetsGeometry padding = const EdgeInsets.all(16),
  }) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        gradient: isDark
            ? LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  const Color(0xFF141829).withOpacity(0.95),
                  Color.lerp(
                    const Color(0xFF0E1220),
                    accentColor,
                    0.09,
                  )!,
                ],
              )
            : LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Colors.white.withOpacity(0.96),
                  Color.lerp(
                    const Color(0xFFF8FAFC),
                    accentColor,
                    0.05,
                  )!,
                ],
              ),
        borderRadius: BorderRadius.circular(26),
        border: Border.all(
          color: accentColor.withOpacity(isDark ? 0.45 : 0.30),
          width: 1.4,
        ),
        boxShadow: [
          BoxShadow(
            color: accentColor.withOpacity(isDark ? 0.14 : 0.08),
            blurRadius: 20,
            offset: const Offset(0, 7),
          ),
        ],
      ),
      child: child,
    );
  }

  Widget _voiceSlider(
    BuildContext context, {
    required String label,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String Function(double) formatter,
    required ValueChanged<double> onChanged,
    required bool isDark,
    required Color accentColor,
  }) {
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final clampedVal = value.clamp(min, max);
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    color: textColor,
                    fontWeight: FontWeight.w700,
                    fontSize: 13.5,
                  ),
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                decoration: BoxDecoration(
                  color: accentColor.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: accentColor.withOpacity(0.4)),
                ),
                child: Text(
                  formatter(clampedVal),
                  style: TextStyle(
                    color: accentColor,
                    fontWeight: FontWeight.w900,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: accentColor,
              inactiveTrackColor: accentColor.withOpacity(0.2),
              thumbColor: accentColor,
              overlayColor: accentColor.withOpacity(0.15),
            ),
            child: Slider(
              value: clampedVal,
              min: min,
              max: max,
              divisions: divisions,
              label: formatter(clampedVal),
              onChanged: onChanged,
            ),
          ),
        ],
      ),
    );
  }

  Widget _defaultDropdown({
    required String label,
    required String currentValue,
    required List<Map<String, dynamic>> items,
    required ValueChanged<String?> onChanged,
    required bool isDark,
    Color accentColor = const Color(0xFF3B82F6),
  }) {
    final hasValue = items.any((e) => e['value'] == currentValue);
    final effectiveItems = [
      if (!hasValue && currentValue.isNotEmpty)
        {'value': currentValue, 'label': currentValue},
      ...items,
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: DropdownButtonFormField<String>(
        value: currentValue.isEmpty ? null : currentValue,
        isExpanded: true,
        dropdownColor: isDark ? const Color(0xFF181D32) : Colors.white,
        iconEnabledColor: accentColor,
        decoration: InputDecoration(
          labelText: label,
          labelStyle: TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 12.5,
            color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF475569),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide(
              color: accentColor.withOpacity(isDark ? 0.32 : 0.25),
              width: 1.2,
            ),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide(color: accentColor, width: 1.8),
          ),
          filled: true,
          fillColor: isDark
              ? const Color(0xFF0B0E1A).withOpacity(0.65)
              : const Color(0xFFF1F5F9),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        ),
        items: effectiveItems
            .map((item) => DropdownMenuItem<String>(
                  value: item['value'],
                  child: Text(
                    item['label']!,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 13.5,
                      color: isDark ? Colors.white : const Color(0xFF0F172A),
                    ),
                  ),
                ))
            .toList(),
        onChanged: onChanged,
      ),
    );
  }

  Widget _defaultTextField({
    required String label,
    required TextEditingController controller,
    required ValueChanged<String> onChanged,
    required bool isDark,
    Color accentColor = const Color(0xFF3B82F6),
    String? hint,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextFormField(
        controller: controller,
        textDirection: TextDirection.rtl,
        style: TextStyle(
          fontWeight: FontWeight.w800,
          fontSize: 13.5,
          color: isDark ? Colors.white : const Color(0xFF0F172A),
        ),
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          hintStyle: TextStyle(
            color: isDark ? Colors.white38 : Colors.black38,
            fontSize: 12,
          ),
          labelStyle: TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 12.5,
            color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF475569),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide(
              color: accentColor.withOpacity(isDark ? 0.32 : 0.25),
              width: 1.2,
            ),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide(color: accentColor, width: 1.8),
          ),
          filled: true,
          fillColor: isDark
              ? const Color(0xFF0B0E1A).withOpacity(0.65)
              : const Color(0xFFF1F5F9),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        ),
        onChanged: onChanged,
      ),
    );
  }

  Widget _subHeader(String title, IconData icon, Color color, bool isDark) {
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: color.withOpacity(isDark ? 0.14 : 0.09),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: color.withOpacity(0.35)),
        ),
        child: Row(
          children: [
            Icon(icon, color: color, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                title,
                style: TextStyle(
                  color: isDark ? Colors.white : const Color(0xFF0F172A),
                  fontWeight: FontWeight.w800,
                  fontSize: 13,
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
      builder: (context, currentMode, child) {
        final isDark = currentMode == ThemeMode.dark;
        final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
        final mutedColor =
            isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);

        const emeraldNeon = Color(0xFF10B981);
        const goldNeon = Color(0xFFF59E0B);
        const purpleNeon = Color(0xFFA855F7);
        const blueNeon = Color(0xFF3B82F6);
        const orangeNeon = Color(0xFFF97316);
        const redNeon = Color(0xFFEF4444);

        return Directionality(
          textDirection: TextDirection.rtl,
          child: Scaffold(
            backgroundColor:
                isDark ? const Color(0xFF070913) : const Color(0xFFF2F5FA),
            body: Stack(
              children: [
                Positioned.fill(
                  child: AnimatedBuilder(
                    animation: _ambientController,
                    builder: (context, _) {
                      final shift =
                          math.sin(_ambientController.value * 2 * math.pi) * 22;
                      return Stack(
                        children: [
                          Positioned(
                            top: -50 + shift,
                            right: -60,
                            child: _buildAmbientGlow(
                              color: isDark
                                  ? emeraldNeon.withOpacity(0.18)
                                  : purpleNeon.withOpacity(0.12),
                              size: 260,
                            ),
                          ),
                          Positioned(
                            top: 260 - shift,
                            left: -70,
                            child: _buildAmbientGlow(
                              color: isDark
                                  ? purpleNeon.withOpacity(0.15)
                                  : blueNeon.withOpacity(0.10),
                              size: 280,
                            ),
                          ),
                          Positioned(
                            bottom: -70 + shift,
                            right: 10,
                            child: _buildAmbientGlow(
                              color: isDark
                                  ? goldNeon.withOpacity(0.12)
                                  : emeraldNeon.withOpacity(0.10),
                              size: 240,
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),

                SafeArea(
                  bottom: false,
                  child: ListView(
                    physics: const BouncingScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
                    children: [
                      // 1. الهيدر العلوي الفاخر
                      _buildModel1TopHeader(
                        isDark: isDark,
                        onBack: () => Navigator.of(context).pop(),
                      ),
                      const SizedBox(height: 16),

                      // بطاقة تفعيل الطوابير الذكية والمعالجة السريعة (اختياري ومستحسن لحل مشاكل الأداء)
                      _buildGlowingCard(
                        isDark: isDark,
                        accentColor: orangeNeon,
                        child: Row(
                          children: [
                            _AnimatedOrbIcon(
                              icon: Icons.bolt_rounded,
                              primaryColor: orangeNeon,
                              secondaryColor: goldNeon,
                              animation: _ambientController,
                              effectType: _OrbEffectType.pulsingMedal,
                              size: 58,
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'المعالجة السريعة والطوابير الذكية',
                                    style: TextStyle(
                                      color: textColor,
                                      fontWeight: FontWeight.w900,
                                      fontSize: 15.5,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    'إدارة الطلبات المتتالية لتفادي بطء الأداء أو التوقف (مستحسن بشدة)',
                                    style: TextStyle(
                                      color: mutedColor,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Switch.adaptive(
                              value: _fastProcessingQueueEnabled,
                              activeColor: orangeNeon,
                              onChanged: _toggleFastProcessingQueue,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 14),

                      // 2. بطاقة الوضع الليلي والنهاري التفاعلية مع الحفظ الفوري
                      _buildGlowingCard(
                        isDark: isDark,
                        accentColor: isDark ? goldNeon : purpleNeon,
                        child: Row(
                          children: [
                            _AnimatedOrbIcon(
                              icon: isDark
                                  ? Icons.dark_mode_rounded
                                  : Icons.light_mode_rounded,
                              primaryColor: isDark ? goldNeon : orangeNeon,
                              secondaryColor: purpleNeon,
                              animation: _ambientController,
                              effectType: _OrbEffectType.orbitalSwirl,
                              size: 58,
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    isDark
                                        ? 'الوضع الليلي الفاخر (مُفعّل)'
                                        : 'الوضع النهاري المشرق (مُفعّل)',
                                    style: TextStyle(
                                      color: textColor,
                                      fontWeight: FontWeight.w900,
                                      fontSize: 15.5,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    'تبديل فوري وحفظ تلقائي للمظهر في جميع صفحات التطبيق',
                                    style: TextStyle(
                                      color: mutedColor,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Switch.adaptive(
                              value: isDark,
                              activeColor: goldNeon,
                              onChanged: (val) async {
                                await AppCore.saveThemePreference(val);
                                if (mounted) setState(() {});
                              },
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 14),

                      // 3. بطاقة الموسيقى الهادئة مع الموجة الصوتية الحية
                      _buildGlowingCard(
                        isDark: isDark,
                        accentColor: blueNeon,
                        child: Column(
                          children: [
                            Row(
                              children: [
                                _AnimatedOrbIcon(
                                  icon: AppCore.isAudioMuted
                                      ? Icons.volume_off_rounded
                                      : Icons.music_note_rounded,
                                  primaryColor: blueNeon,
                                  secondaryColor: emeraldNeon,
                                  animation: _ambientController,
                                  effectType: _OrbEffectType.sonarWaves,
                                  size: 58,
                                ),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'الموسيقى الهادئة',
                                        style: TextStyle(
                                          color: textColor,
                                          fontWeight: FontWeight.w900,
                                          fontSize: 15.5,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        AppCore.isAudioMuted
                                            ? 'متوقفة حالياً'
                                            : 'تعمل في الخلفية بمستوى ${(AppCore.currentVolume * 100).round()}%',
                                        style: TextStyle(
                                          color: mutedColor,
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                Switch.adaptive(
                                  value: !AppCore.isAudioMuted,
                                  activeColor: blueNeon,
                                  onChanged: (val) async {
                                    await AppCore.toggleAudio();
                                    if (mounted) setState(() {});
                                  },
                                ),
                              ],
                            ),
                            if (!AppCore.isAudioMuted) ...[
                              const SizedBox(height: 12),
                              SizedBox(
                                height: 34,
                                width: double.infinity,
                                child: AnimatedBuilder(
                                  animation: _ambientController,
                                  builder: (context, _) {
                                    return CustomPaint(
                                      painter: _SettingsWavePainter(
                                        phase: _ambientController.value *
                                            2 *
                                            math.pi,
                                        color: blueNeon,
                                        isDark: isDark,
                                      ),
                                    );
                                  },
                                ),
                              ),
                              Row(
                                children: [
                                  Icon(Icons.volume_down_rounded,
                                      color: mutedColor),
                                  Expanded(
                                    child: SliderTheme(
                                      data: SliderTheme.of(context).copyWith(
                                        activeTrackColor: blueNeon,
                                        thumbColor: blueNeon,
                                      ),
                                      child: Slider(
                                        value: AppCore.currentVolume,
                                        min: 0.0,
                                        max: 1.0,
                                        divisions: 10,
                                        label:
                                            '${(AppCore.currentVolume * 100).round()}%',
                                        onChanged: (val) {
                                          setState(
                                              () => AppCore.currentVolume = val);
                                          AppCore.setVolume(val);
                                        },
                                      ),
                                    ),
                                  ),
                                  Icon(Icons.volume_up_rounded,
                                      color: blueNeon),
                                ],
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(height: 14),

                      // 4. إطار القيم الافتراضية للمدرسة والحقول
                      _buildGlowingCard(
                        isDark: isDark,
                        accentColor: purpleNeon,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              children: [
                                _AnimatedOrbIcon(
                                  icon: Icons.school_rounded,
                                  primaryColor: purpleNeon,
                                  secondaryColor: goldNeon,
                                  animation: _ambientController,
                                  effectType: _OrbEffectType.pulsingMedal,
                                  size: 58,
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'القيم الافتراضية للمدرسة والحقول',
                                        style: TextStyle(
                                          color: textColor,
                                          fontWeight: FontWeight.w900,
                                          fontSize: 15.5,
                                        ),
                                      ),
                                      const SizedBox(height: 3),
                                      Text(
                                        'تُعبأ تلقائياً عند إضافة طالب أو معلم جديد بحسب مدرستك',
                                        style: TextStyle(
                                          color: mutedColor,
                                          fontSize: 11.5,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                TextButton.icon(
                                  style: TextButton.styleFrom(
                                    foregroundColor: goldNeon,
                                    backgroundColor:
                                        goldNeon.withOpacity(0.12),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(14),
                                    ),
                                  ),
                                  onPressed: _resetDefaultFields,
                                  icon: const Icon(Icons.restore_rounded,
                                      size: 18),
                                  label: const Text(
                                    'الافتراضي',
                                    style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 12),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Divider(
                              color: isDark
                                  ? Colors.white.withOpacity(0.1)
                                  : Colors.black12,
                            ),

                            _subHeader(
                              'البيانات الجغرافية والموقع (الدولة والمحافظة والمدينة والحي)',
                              Icons.location_on_rounded,
                              blueNeon,
                              isDark,
                            ),
                            Row(
                              children: [
                                Expanded(
                                  child: _defaultTextField(
                                    label: 'الدولة / الجنسية / بلد الإصدار',
                                    controller: _countryCtrl,
                                    isDark: isDark,
                                    accentColor: blueNeon,
                                    onChanged: (v) =>
                                        AppCore.saveDefaultFieldValues(
                                            country: v),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: _defaultDropdown(
                                    label: 'المحافظة الافتراضية',
                                    currentValue: AppCore.defaultGovernorate,
                                    isDark: isDark,
                                    accentColor: blueNeon,
                                    items: _iraqGovernorates
                                        .map((g) => {'value': g, 'label': g})
                                        .toList(),
                                    onChanged: (v) {
                                      if (v == null) return;
                                      _govCtrl.text = v;
                                      AppCore.saveDefaultFieldValues(
                                          governorate: v);
                                      setState(() {});
                                    },
                                  ),
                                ),
                              ],
                            ),
                            Row(
                              children: [
                                Expanded(
                                  child: _defaultTextField(
                                    label: 'القضاء / الناحية الافتراضية',
                                    controller: _districtCtrl,
                                    hint: 'مثال: الديوانية',
                                    isDark: isDark,
                                    accentColor: blueNeon,
                                    onChanged: (v) =>
                                        AppCore.saveDefaultFieldValues(
                                            district: v),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: _defaultTextField(
                                    label: 'المدينة / القرية (نص العنوان)',
                                    controller: _townCtrl,
                                    hint: 'مثال: الديوانية',
                                    isDark: isDark,
                                    accentColor: blueNeon,
                                    onChanged: (v) =>
                                        AppCore.saveDefaultFieldValues(town: v),
                                  ),
                                ),
                              ],
                            ),
                            _defaultTextField(
                              label: 'الحي',
                              controller: _areaCtrl,
                              hint: 'اتركه فارغاً أو أدخل اسم الحي الافتراضي',
                              isDark: isDark,
                              accentColor: blueNeon,
                              onChanged: (v) =>
                                  AppCore.saveDefaultFieldValues(area: v),
                            ),

                            _subHeader(
                              'بيانات المدرسة والوثائق الشخصية (طالب ومعلم)',
                              Icons.badge_rounded,
                              orangeNeon,
                              isDark,
                            ),
                            if ((widget.schoolId ?? '').isNotEmpty) ...[
                              _subHeader(
                                'الإعدادات الافتراضية للطلاب',
                                Icons.school_rounded,
                                orangeNeon,
                                isDark,
                              ),
                              if (_loadingStudentStages)
                                const Padding(
                                  padding: EdgeInsets.all(12),
                                  child: LinearProgressIndicator(),
                                )
                              else ...[
                                _defaultDropdown(
                                  label: 'الصف الدراسي الافتراضي للطالب',
                                  currentValue: AppCore.defaultStudentStageId,
                                  isDark: isDark,
                                  accentColor: orangeNeon,
                                  items: _studentStages.map((e) => {
                                    'value': _academicOptionValue(e),
                                    'label': _academicOptionLabel(e),
                                  }).toList(),
                                  onChanged: _onDefaultStudentStageChanged,
                                ),
                                _defaultDropdown(
                                  label: 'الشعبة الدراسية الافتراضية للطالب',
                                  currentValue: AppCore.defaultStudentClassRoomId,
                                  isDark: isDark,
                                  accentColor: orangeNeon,
                                  items: _studentClassRooms.map((e) => {
                                    'value': _academicOptionValue(e),
                                    'label': _academicOptionLabel(e),
                                  }).toList(),
                                  onChanged: (v) {
                                    if (v == null) return;
                                    AppCore.saveDefaultFieldValues(studentClassRoomId: v);
                                    setState(() {});
                                  },
                                ),
                              ],
                            ],
                            Row(
                              children: [
                                Expanded(
                                  child: _defaultDropdown(
                                    label: 'الجنس الافتراضي (نوع المدرسة)',
                                    currentValue: AppCore.defaultGender,
                                    isDark: isDark,
                                    accentColor: orangeNeon,
                                    items: const [
                                      {
                                        'value': '1',
                                        'label': 'ذكر (مدارس البنين)'
                                      },
                                      {
                                        'value': '2',
                                        'label': 'أنثى (مدارس البنات)'
                                      },
                                    ],
                                    onChanged: (v) {
                                      if (v == null) return;
                                      AppCore.saveDefaultFieldValues(gender: v);
                                      setState(() {});
                                    },
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: _defaultDropdown(
                                    label: 'نوع الهوية الافتراضي',
                                    currentValue: AppCore.defaultIdType,
                                    isDark: isDark,
                                    accentColor: orangeNeon,
                                    items: const [
                                      {
                                        'value': '12',
                                        'label': 'البطاقة الوطنية الموحدة'
                                      },
                                      {
                                        'value': '3',
                                        'label': 'هوية الأحوال المدنية'
                                      },
                                      {'value': '22', 'label': 'شهادة الولادة'},
                                      {'value': '16', 'label': 'أخرى'},
                                    ],
                                    onChanged: (v) {
                                      if (v == null) return;
                                      AppCore.saveDefaultFieldValues(idType: v);
                                      setState(() {});
                                    },
                                  ),
                                ),
                              ],
                            ),
                            Row(
                              children: [
                                Expanded(
                                  child: _defaultDropdown(
                                    label: 'اللغة الأم',
                                    currentValue: AppCore.defaultMotherTongue,
                                    isDark: isDark,
                                    accentColor: orangeNeon,
                                    items: const [
                                      {'value': 'العربية', 'label': 'العربية'},
                                      {'value': 'الكردية', 'label': 'الكردية'},
                                      {
                                        'value': 'التركمانية',
                                        'label': 'التركمانية'
                                      },
                                      {
                                        'value': 'السريانية',
                                        'label': 'السريانية'
                                      },
                                      {'value': 'أخرى', 'label': 'أخرى'},
                                    ],
                                    onChanged: (v) {
                                      if (v == null) return;
                                      AppCore.saveDefaultFieldValues(
                                          motherTongue: v);
                                      setState(() {});
                                    },
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: _defaultDropdown(
                                    label: 'لغة الدراسة',
                                    currentValue: AppCore.defaultStudyLanguage,
                                    isDark: isDark,
                                    accentColor: orangeNeon,
                                    items: const [
                                      {'value': 'العربية', 'label': 'العربية'},
                                      {
                                        'value': 'الإنكليزية',
                                        'label': 'الإنكليزية'
                                      },
                                      {'value': 'الكردية', 'label': 'الكردية'},
                                      {
                                        'value': 'التركمانية',
                                        'label': 'التركمانية'
                                      },
                                      {
                                        'value': 'السريانية',
                                        'label': 'السريانية'
                                      },
                                      {'value': 'أخرى', 'label': 'أخرى'},
                                    ],
                                    onChanged: (v) {
                                      if (v == null) return;
                                      AppCore.saveDefaultFieldValues(
                                          studyLanguage: v);
                                      setState(() {});
                                    },
                                  ),
                                ),
                              ],
                            ),
                            Row(
                              children: [
                                Expanded(
                                  child: _defaultDropdown(
                                    label: 'الديانة الافتراضية',
                                    currentValue: AppCore.defaultReligion,
                                    isDark: isDark,
                                    accentColor: orangeNeon,
                                    items: const [
                                      {'value': 'الإسلام', 'label': 'الإسلام'},
                                      {
                                        'value': 'المسيحية',
                                        'label': 'المسيحية'
                                      },
                                      {
                                        'value': 'الأزيدية',
                                        'label': 'الأزيدية'
                                      },
                                      {
                                        'value': 'الصابئة المندائية',
                                        'label': 'الصابئة المندائية'
                                      },
                                      {'value': 'أخرى', 'label': 'أخرى'},
                                    ],
                                    onChanged: (v) {
                                      if (v == null) return;
                                      AppCore.saveDefaultFieldValues(
                                          religion: v);
                                      setState(() {});
                                    },
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: _defaultDropdown(
                                    label: 'فصيلة الدم الافتراضية',
                                    currentValue: AppCore.defaultBloodGroup,
                                    isDark: isDark,
                                    accentColor: orangeNeon,
                                    items: const [
                                      {'value': 'O+', 'label': 'O+'},
                                      {'value': 'O-', 'label': 'O-'},
                                      {'value': 'A+', 'label': 'A+'},
                                      {'value': 'A-', 'label': 'A-'},
                                      {'value': 'B+', 'label': 'B+'},
                                      {'value': 'B-', 'label': 'B-'},
                                      {'value': 'AB+', 'label': 'AB+'},
                                      {'value': 'AB-', 'label': 'AB-'},
                                    ],
                                    onChanged: (v) {
                                      if (v == null) return;
                                      AppCore.saveDefaultFieldValues(
                                          bloodGroup: v);
                                      setState(() {});
                                    },
                                  ),
                                ),
                              ],
                            ),
                            _defaultTextField(
                              label: 'مسقط الرأس',
                              controller: _homeTownCtrl,
                              hint: 'اتركه فارغاً أو أدخل مسقط الرأس الافتراضي',
                              isDark: isDark,
                              accentColor: orangeNeon,
                              onChanged: (v) =>
                                  AppCore.saveDefaultFieldValues(homeTown: v),
                            ),

                            _subHeader(
                              'القيم الافتراضية الخاصة بالطالب والعنوان',
                              Icons.person_rounded,
                              emeraldNeon,
                              isDark,
                            ),
                            _defaultDropdown(
                              label: 'المستوى المعيشي للطالب',
                              currentValue: AppCore.defaultEconomicLevel,
                              isDark: isDark,
                              accentColor: emeraldNeon,
                              items: _economicLevelOptions,
                              onChanged: (v) {
                                if (v == null) return;
                                AppCore.saveDefaultFieldValues(
                                    economicLevel: v);
                                setState(() {});
                              },
                            ),
                            Row(
                              children: [
                                Expanded(
                                  child: _defaultTextField(
                                    label: 'عنوان 1 الافتراضي',
                                    controller: _address1Ctrl,
                                    isDark: isDark,
                                    accentColor: emeraldNeon,
                                    onChanged: (v) =>
                                        AppCore.saveDefaultFieldValues(
                                            address1: v),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: _defaultTextField(
                                    label: 'عنوان 2 الافتراضي',
                                    controller: _address2Ctrl,
                                    isDark: isDark,
                                    accentColor: emeraldNeon,
                                    onChanged: (v) =>
                                        AppCore.saveDefaultFieldValues(
                                            address2: v),
                                  ),
                                ),
                              ],
                            ),
                            _defaultTextField(
                              label: 'أقرب نقطة دالة افتراضية',
                              controller: _closestLocationCtrl,
                              isDark: isDark,
                              accentColor: emeraldNeon,
                              onChanged: (v) => AppCore.saveDefaultFieldValues(
                                  closestLocation: v),
                            ),

                            _subHeader(
                              'القيم الافتراضية الخاصة بالمعلم / المدرس',
                              Icons.work_rounded,
                              purpleNeon,
                              isDark,
                            ),
                            Row(
                              children: [
                                Expanded(
                                  child: _defaultDropdown(
                                    label: 'نوع التوظيف',
                                    currentValue: AppCore.defaultEmploymentType,
                                    isDark: isDark,
                                    accentColor: purpleNeon,
                                    items: _employmentTypeOptions,
                                    onChanged: (v) {
                                      if (v == null) return;
                                      AppCore.saveDefaultFieldValues(
                                          employmentType: v);
                                      setState(() {});
                                    },
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: _defaultDropdown(
                                    label: 'نوع الموظف',
                                    currentValue:
                                        AppCore.defaultEmployeeCategory,
                                    isDark: isDark,
                                    accentColor: purpleNeon,
                                    items: const [
                                      {'value': 'تدريسي', 'label': 'تدريسي'},
                                      {'value': 'إداري', 'label': 'إداري'},
                                      {'value': 'خدمي', 'label': 'خدمي'},
                                    ],
                                    onChanged: (v) {
                                      if (v == null) return;
                                      AppCore.saveDefaultFieldValues(
                                          employeeCategory: v);
                                      setState(() {});
                                    },
                                  ),
                                ),
                              ],
                            ),
                            Row(
                              children: [
                                Expanded(
                                  child: _defaultDropdown(
                                    label: 'التصنيف الوظيفي',
                                    currentValue: AppCore.defaultClassification,
                                    isDark: isDark,
                                    accentColor: purpleNeon,
                                    items: const [
                                      {'value': 'معلم', 'label': 'معلم'},
                                      {
                                        'value': 'معلم جامعي',
                                        'label': 'معلم جامعي'
                                      },
                                      {'value': 'مدرس', 'label': 'مدرس'},
                                      {
                                        'value': 'مرشد تربوي',
                                        'label': 'مرشد تربوي'
                                      },
                                      {
                                        'value': 'معلم مهني',
                                        'label': 'معلم مهني'
                                      },
                                      {
                                        'value': 'مدرب مهني',
                                        'label': 'مدرب مهني'
                                      },
                                      {
                                        'value': 'موظف بعقد',
                                        'label': 'موظف بعقد'
                                      },
                                      {
                                        'value': 'محاضر بعقد',
                                        'label': 'محاضر بعقد'
                                      },
                                      {'value': 'إداري', 'label': 'إداري'},
                                      {
                                        'value': 'موظف خدمة',
                                        'label': 'موظف خدمة'
                                      },
                                      {'value': 'حارس', 'label': 'حارس'},
                                    ],
                                    onChanged: (v) {
                                      if (v == null) return;
                                      AppCore.saveDefaultFieldValues(
                                          classification: v);
                                      setState(() {});
                                    },
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: _defaultDropdown(
                                    label: 'المنصب الحالي',
                                    currentValue:
                                        AppCore.defaultCurrentPosition,
                                    isDark: isDark,
                                    accentColor: purpleNeon,
                                    items: const [
                                      {'value': 'مدير', 'label': 'مدير'},
                                      {'value': 'معاون', 'label': 'معاون'},
                                      {'value': 'معلم', 'label': 'معلم'},
                                      {'value': 'مدرس', 'label': 'مدرس'},
                                      {
                                        'value': 'مرشد تربوي',
                                        'label': 'مرشد تربوي'
                                      },
                                      {'value': 'كاتب', 'label': 'كاتب'},
                                      {
                                        'value': 'أمين مكتبة',
                                        'label': 'أمين مكتبة'
                                      },
                                      {'value': 'محاسب', 'label': 'محاسب'},
                                      {
                                        'value': 'موظف خدمة',
                                        'label': 'موظف خدمة'
                                      },
                                      {
                                        'value': 'حارس ليلي',
                                        'label': 'حارس ليلي'
                                      },
                                    ],
                                    onChanged: (v) {
                                      if (v == null) return;
                                      AppCore.saveDefaultFieldValues(
                                          currentPosition: v);
                                      setState(() {});
                                    },
                                  ),
                                ),
                              ],
                            ),
                            _defaultDropdown(
                              label: 'التحصيل الدراسي',
                              currentValue: AppCore.defaultEducationLevel,
                              isDark: isDark,
                              accentColor: purpleNeon,
                              items: _educationLevelOptions,
                              onChanged: (v) {
                                if (v == null) return;
                                AppCore.saveDefaultFieldValues(
                                    educationLevel: v);
                                setState(() {});
                              },
                            ),
                            _defaultDropdown(
                              label: 'الحالة الوظيفية',
                              currentValue: AppCore.defaultTeacherStatus,
                              isDark: isDark,
                              accentColor: purpleNeon,
                              items: _teacherStatusOptions,
                              onChanged: (v) {
                                if (v == null) return;
                                AppCore.saveDefaultFieldValues(
                                    teacherStatus: v);
                                setState(() {});
                              },
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 14),

                      // 5. بطاقة الميكروفون والتنقل الصوتي والنظام المركزي للكيبورد
                      _buildGlowingCard(
                        isDark: isDark,
                        accentColor: emeraldNeon,
                        child: Column(
                          children: [
                            Row(
                              children: [
                                _AnimatedOrbIcon(
                                  icon: AppCore.voiceInputEnabled
                                      ? Icons.mic_rounded
                                      : Icons.mic_off_rounded,
                                  primaryColor: AppCore.voiceInputEnabled
                                      ? emeraldNeon
                                      : redNeon,
                                  secondaryColor: goldNeon,
                                  animation: _ambientController,
                                  effectType: _OrbEffectType.sonarWaves,
                                  size: 58,
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'الميكروفون والتعرف الصوتي',
                                        style: TextStyle(
                                          color: textColor,
                                          fontWeight: FontWeight.w900,
                                          fontSize: 15.5,
                                        ),
                                      ),
                                      const SizedBox(height: 3),
                                      Text(
                                        'محرك Google SpeechRecognizer (نموذج البحث الصوتي)',
                                        style: TextStyle(
                                          color: mutedColor,
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                Switch.adaptive(
                                  value: AppCore.voiceInputEnabled,
                                  activeColor: emeraldNeon,
                                  onChanged: _setVoiceEnabled,
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            Divider(
                              color: isDark
                                  ? Colors.white.withOpacity(0.1)
                                  : Colors.black12,
                            ),
                            if (AppCore.kLocalAiBuildEnabled) ...[
                              SwitchListTile.adaptive(
                                contentPadding: EdgeInsets.zero,
                                secondary: const Icon(
                                  Icons.auto_awesome_rounded,
                                  color: Color(0xFFA855F7),
                                  size: 26,
                                ),
                                title: Text(
                                  'المساعد الذكي الصوتي (Siri Orb)',
                                  style: TextStyle(
                                    color: textColor,
                                    fontWeight: FontWeight.w900,
                                    fontSize: 14,
                                  ),
                                ),
                                subtitle: Text(
                                  'إظهار أو إخفاء المساعد الذكي العائم في أقسام التطبيق. يبدأ معطلاً، ولا يؤثر إيقافه على ميكروفونات الحقول الحالية.',
                                  style: TextStyle(
                                    color: mutedColor,
                                    fontSize: 12,
                                    height: 1.4,
                                  ),
                                ),
                                value: AppCore.aiAssistantEnabled,
                                activeColor: purpleNeon,
                                onChanged: (value) async {
                                  await AppCore.setAiAssistantEnabled(value);
                                  if (mounted) setState(() {});
                                  if (mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text(
                                          value
                                              ? 'تم تفعيل المساعد الذكي. ستظهر أيقونته عند توفر واجهته.'
                                              : 'تم إيقاف المساعد الذكي.',
                                        ),
                                        behavior: SnackBarBehavior.floating,
                                      ),
                                    );
                                  }
                                },
                              ),
                              Divider(
                                color: isDark
                                    ? Colors.white.withOpacity(0.1)
                                    : Colors.black12,
                              ),
                            ],
                            SwitchListTile.adaptive(
                              contentPadding: EdgeInsets.zero,
                              title: Text(
                                'التفعيل الافتراضي للتنقل الصوتي بين الحقول',
                                style: TextStyle(
                                  color: textColor,
                                  fontWeight: FontWeight.w800,
                                  fontSize: 14,
                                ),
                              ),
                              subtitle: Text(
                                'يبدأ التنقل الصوتي تلقائياً عند فتح صفحة إضافة طالب جديد أو الدرجات.',
                                style: TextStyle(
                                  color: mutedColor,
                                  fontSize: 12,
                                  height: 1.35,
                                ),
                              ),
                              value: AppCore.voiceSequentialAutoStart,
                              activeColor: emeraldNeon,
                              onChanged: (value) async {
                                await AppCore.setVoiceSequentialAutoStart(
                                    value);
                                if (mounted) setState(() {});
                              },
                            ),
                            Divider(
                              color: isDark
                                  ? Colors.white.withOpacity(0.1)
                                  : Colors.black12,
                            ),
                            SwitchListTile.adaptive(
                              contentPadding: EdgeInsets.zero,
                              title: Text(
                                'النظام المركزي للتنقل بأزرار الكيبورد (Enter / التالي)',
                                style: TextStyle(
                                  color: textColor,
                                  fontWeight: FontWeight.w800,
                                  fontSize: 14,
                                ),
                              ),
                              subtitle: Text(
                                'الانتقال المباشر بين الحقول النصية وفتح القوائم المنسدلة تلقائياً عند الضغط على زر التالي أو علامة الصح في الكيبورد مع تجاهل أزرار المايكروفون.',
                                style: TextStyle(
                                  color: mutedColor,
                                  fontSize: 12,
                                  height: 1.35,
                                ),
                              ),
                              value: AppCore.centralKeyboardNavigationEnabled,
                              activeColor: emeraldNeon,
                              onChanged: (value) async {
                                await AppCore
                                    .setCentralKeyboardNavigationEnabled(value);
                                if (mounted) setState(() {});
                              },
                            ),
                            const SizedBox(height: 8),
                            _defaultDropdown(
                              label: 'مسار محرك التعرف الصوتي',
                              currentValue: AppCore.voiceRecognitionEngine,
                              isDark: isDark,
                              accentColor: emeraldNeon,
                              items: const [
                                {
                                  'value': 'google',
                                  'label':
                                      'Google / خدمة النظام الافتراضية (الموصى به)'
                                },
                                {
                                  'value': 'legacy',
                                  'label': 'المسار الاحتياطي (Legacy)'
                                },
                              ],
                              onChanged: (val) async {
                                if (val == null) return;
                                await AppCore.setVoiceRecognitionEngine(val);
                                if (mounted) setState(() {});
                              },
                            ),
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: emeraldNeon
                                    .withOpacity(isDark ? 0.12 : 0.08),
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(
                                  color: emeraldNeon.withOpacity(0.35),
                                ),
                              ),
                              child: Text(
                                'يستخدم التطبيق نموذج البحث الصوتي (web_search) لخدمة Google SpeechRecognizer مع اللهجة العراقية (ar-IQ) لضمان أعلى دقة في فهم الأسماء والأرقام.',
                                style: TextStyle(
                                  color: textColor,
                                  fontWeight: FontWeight.w600,
                                  height: 1.45,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                            const SizedBox(height: 10),
                            Row(
                              children: [
                                Icon(
                                  _checkingGoogleSpeech
                                      ? Icons.sync_rounded
                                      : (_googleSpeechAvailable
                                          ? Icons.cloud_done_rounded
                                          : Icons.warning_amber_rounded),
                                  color: _checkingGoogleSpeech
                                      ? blueNeon
                                      : (_googleSpeechAvailable
                                          ? emeraldNeon
                                          : orangeNeon),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    _googleSpeechMessage,
                                    style: TextStyle(
                                      color: mutedColor,
                                      fontWeight: FontWeight.w600,
                                      fontSize: 12,
                                    ),
                                  ),
                                ),
                                IconButton(
                                  tooltip: 'إعادة الفحص',
                                  onPressed: _checkingGoogleSpeech
                                      ? null
                                      : _checkGoogleSpeech,
                                  icon: Icon(
                                    Icons.refresh_rounded,
                                    color: emeraldNeon,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 14),

                      // 6. إعدادات التعرف الصوتي والتوقيت (بحدود موسعة تصل لـ 90 ثانية)
                      _buildGlowingCard(
                        isDark: isDark,
                        accentColor: goldNeon,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              children: [
                                _AnimatedOrbIcon(
                                  icon: Icons.graphic_eq_rounded,
                                  primaryColor: goldNeon,
                                  secondaryColor: emeraldNeon,
                                  animation: _ambientController,
                                  effectType: _OrbEffectType.atomicOrbits,
                                  size: 58,
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'إعدادات التوقيت والصمت للمايكروفون',
                                        style: TextStyle(
                                          color: textColor,
                                          fontWeight: FontWeight.w900,
                                          fontSize: 15,
                                        ),
                                      ),
                                      const SizedBox(height: 3),
                                      Text(
                                        'نطاق موسّع حتى 90 ثانية للتحكم بمهلة الصمت والوقفات أثناء القراءة',
                                        style: TextStyle(
                                          color: mutedColor,
                                          fontSize: 11.5,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                TextButton.icon(
                                  style: TextButton.styleFrom(
                                    foregroundColor: emeraldNeon,
                                    backgroundColor:
                                        emeraldNeon.withOpacity(0.12),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(14),
                                    ),
                                  ),
                                  onPressed: _resetVoiceSettings,
                                  icon: const Icon(Icons.restore_rounded,
                                      size: 18),
                                  label: const Text(
                                    'القياسي',
                                    style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 12),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            SizedBox(
                              height: 34,
                              child: AnimatedBuilder(
                                animation: _ambientController,
                                builder: (context, _) {
                                  return CustomPaint(
                                    painter: _SettingsWavePainter(
                                      phase: _ambientController.value *
                                          2 *
                                          math.pi,
                                      color: goldNeon,
                                      isDark: isDark,
                                      withBars: true,
                                    ),
                                  );
                                },
                              ),
                            ),
                            Divider(
                              color: isDark
                                  ? Colors.white.withOpacity(0.1)
                                  : Colors.black12,
                            ),
                            SwitchListTile.adaptive(
                              contentPadding: EdgeInsets.zero,
                              title: Text(
                                'إعادة تشغيل الاستماع تلقائياً (Auto Restart)',
                                style: TextStyle(
                                  color: textColor,
                                  fontWeight: FontWeight.w800,
                                  fontSize: 14,
                                ),
                              ),
                              subtitle: Text(
                                'إعادة فتح المايكروفون تلقائياً بعد انتهاء الجملة أو عند حدوث خطأ.',
                                style: TextStyle(
                                  color: mutedColor,
                                  fontSize: 12,
                                ),
                              ),
                              value: AppCore.voiceAutoRestart,
                              activeColor: goldNeon,
                              onChanged: (v) =>
                                  _setVoiceSetting(autoRestart: v),
                            ),
                            SwitchListTile.adaptive(
                              contentPadding: EdgeInsets.zero,
                              title: Text(
                                'المطابقة الصوتية الذكية للأرقام العراقية',
                                style: TextStyle(
                                  color: textColor,
                                  fontWeight: FontWeight.w800,
                                  fontSize: 14,
                                ),
                              ),
                              subtitle: Text(
                                'تصحيح تلقائي للأرقام المنطوقة بسرعة أو بلهجة دارجة دون تخطي أي مرتبة رقمية.',
                                style: TextStyle(
                                  color: mutedColor,
                                  fontSize: 12,
                                ),
                              ),
                              value: AppCore.voiceIraqiFastDigitsMode,
                              activeColor: goldNeon,
                              onChanged: (v) =>
                                  _setVoiceSetting(iraqiFastDigitsMode: v),
                            ),
                            const SizedBox(height: 6),
                            _voiceSlider(
                              context,
                              label: 'مهلة الصمت المحتمل (Possible Silence)',
                              value: AppCore.voicePossibleSilenceMs.toDouble(),
                              min: 1000,
                              max: 90000,
                              divisions: 89,
                              isDark: isDark,
                              accentColor: emeraldNeon,
                              formatter: (v) =>
                                  '${(v / 1000).toStringAsFixed(1)} ثانية',
                              onChanged: (v) {
                                _setVoiceSetting(
                                  possibleSilenceMs: v.round(),
                                );
                              },
                            ),
                            _voiceSlider(
                              context,
                              label: 'مهلة الصمت الكامل (Complete Silence)',
                              value: AppCore.voiceCompleteSilenceMs.toDouble(),
                              min: 1000,
                              max: 90000,
                              divisions: 89,
                              isDark: isDark,
                              accentColor: goldNeon,
                              formatter: (v) =>
                                  '${(v / 1000).toStringAsFixed(1)} ثانية',
                              onChanged: (v) {
                                _setVoiceSetting(
                                  completeSilenceMs: v.round(),
                                );
                              },
                            ),
                            _voiceSlider(
                              context,
                              label: 'الحد الأدنى لطول الكلام (Minimum Speech)',
                              value: AppCore.voiceMinimumSpeechMs.toDouble(),
                              min: 100,
                              max: 9000,
                              divisions: 89,
                              isDark: isDark,
                              accentColor: blueNeon,
                              formatter: (v) =>
                                  '${(v / 1000).toStringAsFixed(2)} ثانية',
                              onChanged: (v) {
                                _setVoiceSetting(
                                  minimumSpeechMs: v.round(),
                                );
                              },
                            ),
                            _voiceSlider(
                              context,
                              label: 'تأخير إعادة التشغيل (Restart Delay)',
                              value: AppCore.voiceRestartDelayMs.toDouble(),
                              min: 0,
                              max: 5000,
                              divisions: 50,
                              isDark: isDark,
                              accentColor: purpleNeon,
                              formatter: (v) =>
                                  '${(v / 1000).toStringAsFixed(1)} ثانية',
                              onChanged: (v) {
                                _setVoiceSetting(
                                  restartDelayMs: v.round(),
                                );
                              },
                            ),
                            _voiceSlider(
                              context,
                              label:
                                  'مهلة الاعتماد النهائي للنص (Finalization Timeout)',
                              value:
                                  AppCore.voiceFinalizationTimeoutMs.toDouble(),
                              min: 500,
                              max: 5000,
                              divisions: 45,
                              isDark: isDark,
                              accentColor: orangeNeon,
                              formatter: (v) =>
                                  '${(v / 1000).toStringAsFixed(1)} ثانية',
                              onChanged: (v) {
                                _setVoiceSetting(
                                  finalizationTimeoutMs: v.round(),
                                );
                              },
                            ),
                            _voiceSlider(
                              context,
                              label: 'شفافية أزرار التنقل الصوتي',
                              value: AppCore.voiceArrowOpacity,
                              min: 0.20,
                              max: 0.90,
                              divisions: 14,
                              isDark: isDark,
                              accentColor: emeraldNeon,
                              formatter: (v) => '${(v * 100).round()}%',
                              onChanged: (v) {
                                _setVoiceSetting(
                                  arrowOpacity: v,
                                );
                              },
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 14),

                      // 7. بطاقة تسجيل الخروج من EMIS
                      GestureDetector(
                        onTap: _logout,
                        child: _buildGlowingCard(
                          isDark: isDark,
                          accentColor: redNeon,
                          child: Row(
                            children: [
                              _AnimatedOrbIcon(
                                icon: Icons.logout_rounded,
                                primaryColor: redNeon,
                                secondaryColor: orangeNeon,
                                animation: _ambientController,
                                effectType: _OrbEffectType.pulsingMedal,
                                size: 56,
                              ),
                              const SizedBox(width: 14),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'تسجيل الخروج من EMIS',
                                      style: TextStyle(
                                        color: textColor,
                                        fontWeight: FontWeight.w900,
                                        fontSize: 15.5,
                                      ),
                                    ),
                                    const SizedBox(height: 3),
                                    Text(
                                      'إنهاء الجلسة الحالية والعودة إلى شاشة تسجيل الدخول',
                                      style: TextStyle(
                                        color: mutedColor,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Container(
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: redNeon.withOpacity(0.15),
                                ),
                                child: const Icon(
                                  Icons.chevron_right_rounded,
                                  color: redNeon,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 28),

                      // 8. تذييل الصفحة (Footer)
                      Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 12,
                          ),
                          decoration: BoxDecoration(
                            color: isDark
                                ? Colors.white.withOpacity(0.04)
                                : Colors.black.withOpacity(0.03),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: isDark
                                  ? Colors.white.withOpacity(0.08)
                                  : Colors.black.withOpacity(0.06),
                            ),
                          ),
                          child: Column(
                            children: [
                              Text(
                                'نسخة غير رسمية',
                                style: TextStyle(
                                  color: isDark
                                      ? const Color(0xFF6EE7B7)
                                      : const Color(0xFF4F46E5),
                                  fontSize: 15,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'تصميم/ علي الفتلاوي / ثانوية الديوانية للمتميزين',
                                style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  color: mutedColor,
                                  fontSize: 13,
                                ),
                                textAlign: TextAlign.center,
                              ),
                            ],
                          ),
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
}

enum _OrbEffectType {
  pulsingMedal,
  orbitalSwirl,
  atomicOrbits,
  sonarWaves,
}

class _AnimatedOrbIcon extends StatelessWidget {
  final IconData icon;
  final Color primaryColor;
  final Color secondaryColor;
  final Animation<double> animation;
  final _OrbEffectType effectType;
  final double size;
  final bool rotateIcon;

  const _AnimatedOrbIcon({
    required this.icon,
    required this.primaryColor,
    required this.secondaryColor,
    required this.animation,
    required this.effectType,
    this.size = 58,
    this.rotateIcon = false,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      builder: (context, _) {
        final t = animation.value;
        final floatOffset = math.sin(t * 2 * math.pi) * 2.5;

        return SizedBox(
          width: size,
          height: size,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Positioned.fill(
                child: CustomPaint(
                  painter: _OrbEffectPainter(
                    progress: t,
                    primaryColor: primaryColor,
                    secondaryColor: secondaryColor,
                    effectType: effectType,
                  ),
                ),
              ),
              Transform.translate(
                offset: Offset(0, floatOffset),
                child: Transform.rotate(
                  angle: rotateIcon ? t * 0.5 * math.pi : 0.0,
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
                          Color.lerp(primaryColor, Colors.black, 0.28)!,
                        ],
                      ),
                      border: Border.all(
                        color: Colors.white.withOpacity(0.45),
                        width: 1.2,
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
              ),
            ],
          ),
        );
      },
    );
  }
}

class _OrbEffectPainter extends CustomPainter {
  final double progress;
  final Color primaryColor;
  final Color secondaryColor;
  final _OrbEffectType effectType;

  _OrbEffectPainter({
    required this.progress,
    required this.primaryColor,
    required this.secondaryColor,
    required this.effectType,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final angle = progress * 2 * math.pi;
    final maxR = size.width / 2;

    switch (effectType) {
      case _OrbEffectType.pulsingMedal:
        for (int i = 1; i <= 2; i++) {
          final radius = maxR * 0.65 + i * 4.0 + math.sin(angle + i) * 1.5;
          final arcPaint = Paint()
            ..color = primaryColor.withOpacity(0.45 - i * 0.12)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.6
            ..strokeCap = StrokeCap.round;

          canvas.drawArc(
            Rect.fromCircle(center: center, radius: radius),
            -0.6,
            1.2,
            false,
            arcPaint,
          );
          canvas.drawArc(
            Rect.fromCircle(center: center, radius: radius),
            math.pi - 0.6,
            1.2,
            false,
            arcPaint,
          );
        }
        break;

      case _OrbEffectType.orbitalSwirl:
        canvas.save();
        canvas.translate(center.dx, center.dy);
        canvas.rotate(-0.35);
        final rect = Rect.fromCenter(
          center: Offset.zero,
          width: size.width * 0.94,
          height: size.height * 0.42,
        );
        final orbitPaint = Paint()
          ..color = secondaryColor.withOpacity(0.55)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5;
        canvas.drawOval(rect, orbitPaint);

        final dotX = (size.width * 0.47) * math.cos(angle);
        final dotY = (size.height * 0.21) * math.sin(angle);
        canvas.drawCircle(
          Offset(dotX, dotY),
          2.8,
          Paint()..color = secondaryColor,
        );
        canvas.restore();
        break;

      case _OrbEffectType.atomicOrbits:
        for (final tilt in [0.45, -0.45]) {
          canvas.save();
          canvas.translate(center.dx, center.dy);
          canvas.rotate(tilt);
          final rect = Rect.fromCenter(
            center: Offset.zero,
            width: size.width * 0.92,
            height: size.height * 0.38,
          );
          final orbitPaint = Paint()
            ..color = primaryColor.withOpacity(0.45)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.3;
          canvas.drawOval(rect, orbitPaint);

          final dir = tilt > 0 ? angle : -angle + 1.5;
          final dx = (size.width * 0.46) * math.cos(dir);
          final dy = (size.height * 0.19) * math.sin(dir);
          canvas.drawCircle(
            Offset(dx, dy),
            2.5,
            Paint()..color = secondaryColor,
          );
          canvas.restore();
        }
        break;

      case _OrbEffectType.sonarWaves:
        for (int i = 0; i < 2; i++) {
          final waveProgress = (progress + i / 2) % 1.0;
          final radius = maxR * 0.55 + waveProgress * (maxR * 0.45);
          final opacity = (1.0 - waveProgress).clamp(0.0, 1.0) * 0.55;
          final wavePaint = Paint()
            ..color = primaryColor.withOpacity(opacity)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.6;
          canvas.drawCircle(center, radius, wavePaint);
        }
        break;
    }
  }

  @override
  bool shouldRepaint(covariant _OrbEffectPainter oldDelegate) =>
      oldDelegate.progress != progress;
}

class _SettingsWavePainter extends CustomPainter {
  final double phase;
  final Color color;
  final bool isDark;
  final bool withBars;

  _SettingsWavePainter({
    required this.phase,
    required this.color,
    required this.isDark,
    this.withBars = false,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paintLine = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round;

    final glowPaint = Paint()
      ..color = color.withOpacity(isDark ? 0.40 : 0.22)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5.0
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5);

    final path = Path();
    final startX = withBars ? size.width * 0.25 : 0.0;
    final waveWidth = size.width - startX;

    for (double x = startX; x <= size.width; x += 2) {
      final normalized = (x - startX) / waveWidth;
      final y = size.height * 0.5 +
          math.sin(normalized * 4 * math.pi + phase) * (size.height * 0.28) +
          math.cos(normalized * 2 * math.pi - phase) * (size.height * 0.12);
      if (x == startX) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }

    canvas.drawPath(path, glowPaint);
    canvas.drawPath(path, paintLine);

    if (withBars) {
      final barPaint = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.8
        ..strokeCap = StrokeCap.round;

      const barCount = 5;
      final barSpacing = (size.width * 0.20) / barCount;
      for (int i = 0; i < barCount; i++) {
        final bx = i * barSpacing + 6;
        final factor = 0.30 + 0.50 * math.sin(phase + i * 1.1).abs();
        final barHeight = size.height * factor;
        final topY = (size.height - barHeight) / 2;
        canvas.drawLine(
          Offset(bx, topY),
          Offset(bx, topY + barHeight),
          barPaint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _SettingsWavePainter oldDelegate) =>
      oldDelegate.phase != phase || oldDelegate.isDark != isDark;
}
