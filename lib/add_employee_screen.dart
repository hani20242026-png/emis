import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'platform_permissions.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'google_speech_service.dart';
import 'selfie_background_remover.dart';
import 'voice_result_processor.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'platform_image_picker.dart';

import 'app_core.dart';
import 'employment_status_options.dart';
import 'central_keyboard_navigation.dart';
import 'emis_live_sync.dart';
import 'emis_options.dart';
import 'ai_assistant/ai_assistant_controller.dart';
import 'ai_assistant/ai_command_parser.dart';

class AddEmployeeScreen extends StatefulWidget {
  final String token;
  final String schoolId;
  final Map<String, String> initialAiValues;

  const AddEmployeeScreen({
    super.key,
    required this.token,
    required this.schoolId,
    this.initialAiValues = const <String, String>{},
  });

  @override
  State<AddEmployeeScreen> createState() => _AddEmployeeScreenState();
}

class _AddEmployeeScreenState extends State<AddEmployeeScreen>
    with SingleTickerProviderStateMixin {
  final _formKey = GlobalKey<FormState>();
  final Map<String, TextEditingController> c = {};
  final Map<String, List<dynamic>> options = {};

  late final AnimationController _ambientController;
  late final CentralKeyboardNavigator _centralNav;

  List<dynamic> _addressCountries = [];
  List<dynamic> _addressGovernorates = [];
  List<dynamic> _addressDistricts = [];
  List<dynamic> _addressTowns = [];
  String? _addressCountryId;
  String? _addressGovernorateId;
  String? _addressDistrictId;
  String? _addressTownId;

  File? _pickedImage;
  String _uploadedImageUrl = '';

  bool loading = true;
  bool saving = false;
  String? error;

  final GlobalKey<EmisLiveSyncState> _liveSyncKey =
      GlobalKey<EmisLiveSyncState>();
  Timer? _liveTimer;
  final Map<String, DateTime> _aiFieldWriteTimes = <String, DateTime>{};
  String _liveStatus = 'المزامنة الحية مع EMIS قيد التشغيل';

  bool _employeeVoiceListening = false;
  int _employeeVoiceSession = 0;
  int _employeeVoiceNextSession = 0;
  String? _employeeVoiceField;
  String _employeeVoiceAccumulated = '';
  static const Set<String> _employeeNumericVoiceFields = {
    'nationalId',
    'recordNumber',
    'pageNumber',
    'employeeIdNumber',
    'familyNumber',
    'weeklyTeachingQuota',
    'graduationYear',
    'mobilePhoneNumber',
    'emergencyContactPhoneNumber',
  };
  StreamSubscription<dynamic>? _employeeVoiceSubscription;
  VoidCallback? _employeeVoiceSettingsListener;
  bool _employeeVoiceSequential = false;
  int _employeeVoiceSequenceIndex = 0;
  int _employeeVoiceAdvancedSession = -1;
  bool _employeeVoiceArrowPointerDown = false;
  double _employeeVoiceArrowLeft = AppCore.voiceArrowLeft;
  double? _employeeVoiceArrowTop = AppCore.voiceArrowTop;

  static const Set<String> _employeeFieldsWithDefaults = {
    'nationality', 'issuingCountry', 'countryOfBirth', 'idType', 'gender',
    'motherTongue', 'religion', 'bloodGroup', 'status', 'employeeCategory',
    'employmentType', 'classification', 'currentPosition', 'educationLevel',
    'employmentGrade', 'specialization', 'positionType', 'maritalStatus',
    'town', 'area', 'homeTown', 'address1', 'address2', 'closestLocation',
    'specialNeedsInformation', 'notes', 'emergencyContactName',
    'emergencyContactRelationship', 'emergencyContactPhoneNumber', 'email',
  };

  List<String> _employeeVoiceSequence() =>
      _buildCentralKeyboardSequence()
          .where((key) => labels.containsKey(key) &&
              !_employeeFieldsWithDefaults.contains(key) &&
              !AppCore.hasConfiguredDefaultForStudentField(key) &&
              c.containsKey(key))
          .toList(growable: false);

  Future<void> _toggleEmployeeVoice(String key) async {
    if (saving || !AppCore.voiceInputEnabled) {
      _showEmployeeVoiceMessage('الإدخال الصوتي مغلق من الإعدادات.');
      return;
    }
    if (_employeeVoiceListening && _employeeVoiceField == key) {
      await GoogleSpeechService.stopListening();
      return;
    }
    if (_employeeVoiceListening) await GoogleSpeechService.stopListening();
    if (!await ensureEmisMicrophonePermission()) {
      _showEmployeeVoiceMessage('يرجى السماح باستخدام الميكروفون.');
      return;
    }
    final info = await GoogleSpeechService.getInfo();
    if (info['available'] != true) {
      _showEmployeeVoiceMessage('خدمة التعرف الصوتي غير متاحة على الجهاز.');
      return;
    }
    final session = GoogleSpeechService.nextSessionId();
    _employeeVoiceNextSession = session;
    _employeeVoiceSession = session;
    _employeeVoiceField = key;
    _employeeVoiceAccumulated = '';
    if (mounted) setState(() => _employeeVoiceListening = true);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    if (!mounted) return;
    await _centralNav.scrollToField(key);
    final started = await GoogleSpeechService.startListening(
      sessionId: session, locale: 'ar-IQ',
    );
    if (!started && mounted && _employeeVoiceSession == session) {
      setState(() => _employeeVoiceListening = false);
      _showEmployeeVoiceMessage('تعذر تشغيل الميكروفون.');
    }
  }

  void _handleEmployeeVoiceEvent(Map<String, dynamic> event) {
    if (!mounted || int.tryParse('${event['sessionId']}') != _employeeVoiceSession) return;
    final type = '${event['type'] ?? ''}';
    if (type == 'stopped' || type == 'error') {
      setState(() => _employeeVoiceListening = false);
      if (_employeeVoiceSequential && type == 'stopped') {
        _advanceEmployeeVoiceSequence();
      }
      return;
    }
    if (type != 'partial' && type != 'result') return;
    if (type == 'result') unawaited(GoogleSpeechService.stopListening());
    final key = _employeeVoiceField;
    if (key == null) return;
    final full = <String>[
      '${event['text'] ?? ''}',
      if (event['alternates'] is List) ...((event['alternates'] as List).map((e) => '$e')),
    ].where((e) => e.trim().isNotEmpty).toList();
    final segments = <String>[
      '${event['segment'] ?? ''}',
      if (event['segmentAlternates'] is List) ...((event['segmentAlternates'] as List).map((e) => '$e')),
    ].where((e) => e.trim().isNotEmpty).toList();
    final isNumeric = _employeeNumericVoiceFields.contains(key);
    final resolved = isNumeric
        ? VoiceResultProcessor.resolveNumeric(
            segmentCandidates: segments,
            fullCandidates: full,
            accumulated: _employeeVoiceAccumulated,
            fieldKey: key,
          )
        : VoiceResultProcessor.resolveText(
            segmentCandidates: segments,
            fullCandidates: full,
            accumulated: _employeeVoiceAccumulated,
          );
    final text = isNumeric
        ? AppCore.normalizeDigitsOnly(resolved).replaceAll(RegExp(r'[^0-9]'), '')
        : resolved;
    if (text.isEmpty) return;
    _employeeVoiceAccumulated = text;

    if (<String>{'dateOfBirth', 'dateOfStartWorking', 'statusDate', 'issuingDate'}.contains(key)) {
      final parsedDate = VoiceResultProcessor.resolveSpokenDate(text, fieldKey: key);
      if (parsedDate != null) {
        c[key]?.value = TextEditingValue(
          text: parsedDate,
          selection: TextSelection.collapsed(offset: parsedDate.length),
        );
        _focusLive(key);
        _liveSyncKey.currentState?.pushValues(_liveValues());
        if (type == 'result') {
          setState(() => _employeeVoiceListening = false);
          if (_employeeVoiceSequential) _advanceEmployeeVoiceSequence();
        } else {
          setState(() {});
        }
      } else if (type == 'result') {
        _showEmployeeVoiceMessage('يرجى نطق اليوم ثم الشهر ثم السنة بشكل واضح لتسجيل التاريخ بصيغة YYYY-MM-DD.');
        setState(() => _employeeVoiceListening = false);
        if (_employeeVoiceSequential) _advanceEmployeeVoiceSequence();
      }
      return;
    }

    final available = options[key] ?? const <dynamic>[];
    if (available.isEmpty) {
      c[key]?.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
      _focusLive(key);
      _liveSyncKey.currentState?.pushValues(_liveValues());
      if (type == 'result') {
        setState(() => _employeeVoiceListening = false);
        if (_employeeVoiceSequential) _advanceEmployeeVoiceSequence();
      } else {
        setState(() {});
      }
      return;
    }
    Map<String, dynamic>? matched;
    String norm(String value) => AppCore.normalizeIraqiSpokenText(value)
        .replaceAll(RegExp(r'\s+'), '');
    final spoken = norm(text);
    for (final rawOption in available.whereType<Map>()) {
      final option = Map<String, dynamic>.from(rawOption);
      final value = '${option['value'] ?? ''}';
      final label = '${option['displayName'] ?? option['name'] ?? option['label'] ?? value}';
      if (norm(label) == spoken || norm(value) == spoken ||
          (spoken.length >= 3 && (norm(label).contains(spoken) || spoken.contains(norm(label))))) {
        matched = Map<String, dynamic>.from(option);
        break;
      }
    }
    if (matched != null) {
      c[key]?.text = _value(matched);
      _focusLive(key);
      _liveSyncKey.currentState?.pushValues(_liveValues());
      if (type == 'result') {
        setState(() => _employeeVoiceListening = false);
        if (_employeeVoiceSequential) _advanceEmployeeVoiceSequence();
      } else {
        setState(() {});
      }
    } else if (RegExp(r'^[0-9٠-٩۰-۹]+$').hasMatch(text)) {
      c[key]?.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
      _focusLive(key);
      _liveSyncKey.currentState?.pushValues(_liveValues());
      if (type == 'result') {
        setState(() => _employeeVoiceListening = false);
        if (_employeeVoiceSequential) _advanceEmployeeVoiceSequence();
      } else {
        setState(() {});
      }
    } else if (type == 'result') {
      _showEmployeeVoiceMessage('لم أتمكن من مطابقة النطق مع خيارات ${labels[key] ?? key}.');
      setState(() => _employeeVoiceListening = false);
      if (_employeeVoiceSequential) _advanceEmployeeVoiceSequence();
    }
  }

  void _showEmployeeVoiceMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  Future<void> _startEmployeeVoiceNavigation() async {
    final sequence = _employeeVoiceSequence();
    if (sequence.isEmpty) {
      _showEmployeeVoiceMessage('لا توجد حقول إعدادات متاحة للتنقل الصوتي.');
      return;
    }
    if (saving || !AppCore.voiceInputEnabled) {
      _showEmployeeVoiceMessage('الإدخال الصوتي مغلق من الإعدادات أو أن الحفظ جارٍ.');
      return;
    }
    setState(() {
      _employeeVoiceSequential = true;
      _employeeVoiceSequenceIndex = 0;
    });
    await _toggleEmployeeVoice(sequence.first);
    if (mounted && !_employeeVoiceListening) {
      setState(() => _employeeVoiceSequential = false);
    }
  }

  Future<void> _advanceEmployeeVoiceSequence() async {
    if (!_employeeVoiceSequential || !mounted || _employeeVoiceAdvancedSession == _employeeVoiceSession) return;
    _employeeVoiceAdvancedSession = _employeeVoiceSession;
    final sequence = _employeeVoiceSequence();
    if (sequence.isEmpty) return;
    _employeeVoiceSequenceIndex++;
    if (_employeeVoiceSequenceIndex >= sequence.length) {
      setState(() => _employeeVoiceSequential = false);
      _showEmployeeVoiceMessage('اكتمل التنقل الصوتي بين الحقول.');
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 250));
    if (mounted && _employeeVoiceSequential) {
      await _toggleEmployeeVoice(sequence[_employeeVoiceSequenceIndex]);
      if (mounted && _employeeVoiceSequential) {
        await _centralNav.scrollToField(sequence[_employeeVoiceSequenceIndex]);
      }
    }
  }

  Widget _employeeVoiceMic(String key, Color accentColor) {
    final active = _employeeVoiceListening && _employeeVoiceField == key;
    return IconButton(
      tooltip: 'إدخال ${labels[key] ?? key} بالصوت',
      onPressed: () => _toggleEmployeeVoice(key),
      icon: Icon(active ? Icons.mic_rounded : Icons.mic_none_rounded,
        color: active ? const Color(0xFFEF4444) : accentColor),
    );
  }

  Future<void> _stopEmployeeVoiceNavigation() async {
    if (!_employeeVoiceSequential) return;
    setState(() => _employeeVoiceSequential = false);
    await GoogleSpeechService.stopListening();
  }

  Future<void> _retreatEmployeeVoiceSequence() async {
    if (!_employeeVoiceSequential || saving) return;
    final sequence = _employeeVoiceSequence();
    if (sequence.isEmpty || _employeeVoiceSequenceIndex <= 0) return;
    final previous = --_employeeVoiceSequenceIndex;
    _employeeVoiceAdvancedSession = _employeeVoiceSession;
    if (mounted && _employeeVoiceSequential) {
      await _toggleEmployeeVoice(sequence[previous]);
    }
  }

  void _markEmployeeVoiceArrowPointerDown() {
    _employeeVoiceArrowPointerDown = true;
    Future<void>.microtask(() => _employeeVoiceArrowPointerDown = false);
  }

  Widget _employeeVoiceNavigationControl(bool isDark) {
    final enabled = _employeeVoiceSequential;
    const emeraldNeon = Color(0xFF10B981);
    const goldNeon = Color(0xFFF59E0B);
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final mutedColor = isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);

    return ExcludeFocus(
      child: Container(
        margin: const EdgeInsets.only(top: 12, bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          gradient: AppCore.isWindows ? null : isDark
              ? LinearGradient(colors: [
                  const Color(0xFF141829).withOpacity(0.95),
                  Color.lerp(const Color(0xFF0F1322), emeraldNeon, 0.10)!,
                ])
              : LinearGradient(colors: [
                  Colors.white,
                  Color.lerp(const Color(0xFFF8FAFC), emeraldNeon, 0.05)!,
                ]),
          color: AppCore.isWindows ? AppCore.windowsGradientFallback(isDark
              ? LinearGradient(colors: [
                  const Color(0xFF141829).withOpacity(0.95),
                  Color.lerp(const Color(0xFF0F1322), emeraldNeon, 0.10)!,
                ])
              : LinearGradient(colors: [
                  Colors.white,
                  Color.lerp(const Color(0xFFF8FAFC), emeraldNeon, 0.05)!,
                ])) : null,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(
            color: (enabled ? emeraldNeon : goldNeon).withOpacity(isDark ? 0.45 : 0.32),
            width: 1.4,
          ),
          boxShadow: [BoxShadow(
            color: (enabled ? emeraldNeon : goldNeon).withOpacity(isDark ? 0.14 : 0.08),
            blurRadius: 18,
            offset: const Offset(0, 6),
          )],
        ),
        child: Column(children: [
          Row(children: [
            _AnimatedEmployeeOrbIcon(
              icon: enabled ? Icons.keyboard_double_arrow_down_rounded : Icons.mic_none_rounded,
              primaryColor: enabled ? emeraldNeon : goldNeon,
              secondaryColor: const Color(0xFF3B82F6),
              animation: _ambientController,
              size: 52,
            ),
            const SizedBox(width: 12),
            Expanded(child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('التنقل الصوتي بين الحقول', style: TextStyle(
                  fontWeight: FontWeight.w900, fontSize: 15, color: textColor,
                )),
                const SizedBox(height: 3),
                Text(
                  _employeeVoiceField != null
                      ? 'الحقل النشط: ${labels[_employeeVoiceField!] ?? _employeeVoiceField!}'
                      : 'عند التفعيل تظهر أسهم التنقل الصوتي بجوار الحقول.',
                  style: TextStyle(
                    color: _employeeVoiceField != null ? emeraldNeon : mutedColor,
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
              ],
            )),
            Switch.adaptive(
              value: enabled,
              activeColor: emeraldNeon,
              onChanged: (value) async {
                if (value) {
                  await _startEmployeeVoiceNavigation();
                } else {
                  await _stopEmployeeVoiceNavigation();
                }
              },
            ),
          ]),
          if (enabled || _employeeVoiceListening) ...[
            const SizedBox(height: 10),
            SizedBox(
              height: 28,
              width: double.infinity,
              child: AnimatedBuilder(
                animation: _ambientController,
                builder: (context, _) => CustomPaint(
                  painter: _EmployeeWavePainter(
                    phase: _ambientController.value * 2 * math.pi,
                    color: _employeeVoiceListening ? const Color(0xFFEF4444) : emeraldNeon,
                    isDark: isDark,
                  ),
                ),
              ),
            ),
          ],
        ]),
      ),
    );
  }

  Widget _fixedEmployeeVoiceArrow(bool isDark) {
    if (!_employeeVoiceSequential) return const SizedBox.shrink();
    final sequence = _employeeVoiceSequence();
    final atFirst = _employeeVoiceSequenceIndex <= 0 || sequence.isEmpty;
    final atLast = sequence.isEmpty || _employeeVoiceSequenceIndex >= sequence.length - 1;
    final media = MediaQuery.of(context);
    final maxWidth = media.size.width - 62;
    final maxHeight = media.size.height - media.padding.top - kToolbarHeight - 165;
    final currentTop = (_employeeVoiceArrowTop ?? media.size.height * .32).clamp(8.0, maxHeight > 8 ? maxHeight : 8.0).toDouble();
    final currentLeft = _employeeVoiceArrowLeft.clamp(0.0, maxWidth > 0 ? maxWidth : 0.0).toDouble();
    final dockLeft = currentLeft <= 4;
    final dockRight = currentLeft >= maxWidth - 4;
    final radius = dockLeft ? const BorderRadius.horizontal(right: Radius.circular(24)) : (dockRight ? const BorderRadius.horizontal(left: Radius.circular(24)) : BorderRadius.circular(24));
    const emerald = Color(0xFF10B981);
    Widget arrowButton({required IconData icon, required VoidCallback? onTap, required bool disabled, required String tooltip}) => Tooltip(
      message: tooltip,
      child: Material(color: Colors.transparent, child: InkWell(
        borderRadius: BorderRadius.circular(20), onTap: disabled ? null : onTap,
        child: SizedBox(width: 58, height: 62, child: Icon(icon, size: 48, color: disabled ? (isDark ? Colors.white24 : Colors.grey.shade400) : emerald)),
      )),
    );
    return Positioned(left: currentLeft, top: currentTop, child: ExcludeFocus(child: Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (_) => _markEmployeeVoiceArrowPointerDown(),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (_) => _markEmployeeVoiceArrowPointerDown(),
        onPanUpdate: (details) {
          _markEmployeeVoiceArrowPointerDown();
          setState(() {
            _employeeVoiceArrowLeft = (currentLeft + details.delta.dx).clamp(0.0, maxWidth > 0 ? maxWidth : 0.0).toDouble();
            _employeeVoiceArrowTop = (currentTop + details.delta.dy).clamp(8.0, maxHeight > 8 ? maxHeight : 8.0).toDouble();
          });
        },
        onPanEnd: (_) => AppCore.saveVoiceSettings(arrowLeft: _employeeVoiceArrowLeft, arrowTop: _employeeVoiceArrowTop),
        child: Material(color: Colors.transparent, child: Container(
          width: 62, padding: const EdgeInsets.symmetric(vertical: 4),
          decoration: BoxDecoration(
            color: (isDark ? const Color(0xFF141829) : Colors.white).withOpacity(AppCore.voiceArrowOpacity.clamp(.45, .95)),
            borderRadius: radius, border: Border.all(color: emerald, width: 1.8),
            boxShadow: [BoxShadow(blurRadius: 16, offset: const Offset(0, 4), color: emerald.withOpacity(.28))],
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            arrowButton(icon: Icons.keyboard_arrow_up_rounded, onTap: _retreatEmployeeVoiceSequence, disabled: atFirst, tooltip: 'السابق'),
            Padding(padding: const EdgeInsets.symmetric(vertical: 2), child: Icon(Icons.drag_indicator_rounded, size: 18, color: emerald.withOpacity(.75))),
            arrowButton(icon: Icons.keyboard_arrow_down_rounded, onTap: _advanceEmployeeVoiceSequence, disabled: atLast, tooltip: 'التالي'),
          ]),
        )),
      ),
    )));
  }

  static const Map<String, String> _optionEndpoints = {
    'countryOfBirth': '/selectoption/بلد الولادة',
    'nationality': '/selectoption/الجنسية',
    'issuingCountry': '/selectoption/بلد الإصدار',
    'idType': '/selectoption/IdentificationType',
    'gender': '/selectoption/Gender',
    'motherTongue': '/selectoption/لغة',
    'maritalStatus': '/selectoption/الحالة الاجتماعية',
    'bloodGroup': '/selectoption/فصيلة الدم',
    'religion': '/selectoption/الديانة',
    'educationLevel': '/selectoption/تحصیل الدراسي',
    'positionType': '/SelectOption/نوع الوظيفة',
    'specialization': '/selectoption/الإختصاص',
  };

  final labels = const <String, String>{
    'name': 'الإسم *',
    'fatherName': 'إسم الأب *',
    'grandFatherName': 'اسم والد الأب *',
    'fathersGrandFatherName': 'اسم جد الأب *',
    'surName': 'اللقب *',
    'motherName': 'إسم الأم *',
    'mothersFatherName': 'اسم والد الأم *',
    'mothersGrandFatherName': 'اسم جد الأم *',
    'nationalId': 'رقم الوثيقة / البطاقة الوطنية *',
    'nameOfDocument': 'نوع الوثيقة *',
    'recordNumber': 'رقم السجل *',
    'pageNumber': 'رقم الصحيفة *',
    'issuer': 'جهة الإصدار',
    'issuingDate': 'تاريخ الإصدار *',
    'employeeIdNumber': 'الرقم الوظيفي',
    'familyNumber': 'الرقم العائلي',
    'idType': 'نوع الهوية *',
    'issuingCountry': 'بلد الإصدار *',
    'dateOfBirth': 'تاريخ التولد *',
    'gender': 'الجنس *',
    'nationality': 'الجنسية *',
    'countryOfBirth': 'محل الولادة',
    'homeTown': 'مسقط الرأس',
    'motherTongue': 'اللغة الأم *',
    'maritalStatus': 'الحالة الاجتماعية',
    'bloodGroup': 'فئة الدم',
    'religion': 'الديانة *',
    'employmentType': 'نوع التوظيف *',
    'employeeCategory': 'نوع الموظف *',
    'classification': 'التصنيف *',
    'jobDesignation': 'المسمى الوظيفي',
    'positionType': 'العنوان الوظيفي *',
    'employmentGrade': 'الدرجة الوظيفية',
    'weeklyTeachingQuota': 'النصاب الأسبوعي للحصص',
    'dateOfStartWorking': 'تاريخ أول تعيين للموظف *',
    'currentPosition': 'المنصب الحالي *',
    'status': 'الحالة الوظيفية *',
    'statusDate': 'تاريخ سريان الحالة الوظيفية',
    'statusReason': 'سبب الحالة الوظيفية *',
    'assignedEntityName': 'الجهة المنسب أو المكلف إليها *',
    'educationLevel': 'التحصيل الدراسي *',
    'universityName': 'إسم الكلية / المعهد',
    'graduationYear': 'سنة التخرج',
    'specialization': 'الإختصاص *',
    'specialNeedsInformation': 'معلومات ذوي الاحتياجات الخاصة إن وجدت',
    'emergencyContactName': 'اسم جهة الاتصال في الحالات الطارئة',
    'emergencyContactRelationship': 'صلة جهة الاتصال',
    'emergencyContactPhoneNumber': 'رقم هاتف جهة الاتصال في الحالات الطارئة',
    'town': 'المدينة / القرية *',
    'area': 'الحي *',
    'quarter': 'المحلة *',
    'street': 'الزقاق *',
    'address1': 'عنوان 1 *',
    'address2': 'عنوان 2',
    'closestLocation': 'أقرب نقطة دالة *',
    'mobilePhoneNumber': 'رقم هاتف الموظف *',
    'email': 'البريد الإلكتروني',
    'notes': 'ملاحظات',
    'addressCountry': 'الدولة',
    'addressGovernorate': 'المحافظة',
    'addressDistrict': 'القضاء / الناحية *',
    'addressTown': 'الناحية *',
  };

  bool _shouldSkipEmployeeField(String fieldId) => false;

  List<String> _buildCentralKeyboardSequence() {
    final seq = <String>[
      'name',
      'fatherName',
      'grandFatherName',
      'fathersGrandFatherName',
      'surName',
      'motherName',
      'mothersFatherName',
      'mothersGrandFatherName',
      'gender',
      'dateOfBirth',
      'countryOfBirth',
      'nationality',
      'homeTown',
      'idType',
      'issuingCountry',
    ];

    final idType =
        int.tryParse(c['idType']?.text.trim() ?? AppCore.defaultIdType) ?? 12;
    if (idType == 3) {
      seq.addAll([
        'nationalId',
        'recordNumber',
        'pageNumber',
        'issuer',
      ]);
    } else if (idType == 22) {
      seq.addAll([
        'nationalId',
        'issuingDate',
        'recordNumber',
        'pageNumber',
      ]);
    } else if (idType == 16) {
      seq.addAll([
        'nameOfDocument',
        'nationalId',
      ]);
    } else {
      seq.add('nationalId');
    }

    seq.addAll([
      'employeeIdNumber',
      'familyNumber',
      'employmentType',
      'employeeCategory',
      'classification',
      'jobDesignation',
      'employmentGrade',
      'weeklyTeachingQuota',
      'positionType',
      'currentPosition',
      'dateOfStartWorking',
      'status',
    ]);

    final empStatus = c['status']?.text.trim() ?? '';
    if (empStatus != 'مستمر') {
      seq.add('statusReason');
    }
    if (empStatus == 'مكلف او منسب من وزارة التربية الى جهات أخرى') {
      seq.add('assignedEntityName');
    }

    seq.add('educationLevel');
    final eduLevel = c['educationLevel']?.text.trim() ?? '';
    final showUniv = eduLevel == 'دبلوم' || eduLevel == 'بكالوريوس';
    final showSpec =
        !const ['ابتدائية', 'متوسطة', 'إعدادية'].contains(eduLevel);

    if (showUniv) {
      seq.addAll([
        'universityName',
        'graduationYear',
      ]);
    }
    if (showSpec) {
      seq.add('specialization');
    }

    seq.addAll([
      'motherTongue',
      'maritalStatus',
      'bloodGroup',
      'religion',
      'mobilePhoneNumber',
      'specialNeedsInformation',
      'notes',
      'emergencyContactName',
      'emergencyContactRelationship',
      'emergencyContactPhoneNumber',
      'addressCountry',
      'addressGovernorate',
      'addressDistrict',
      'addressTown',
      'town',
      'area',
      'quarter',
      'street',
      'address1',
      'address2',
      'closestLocation',
      'email',
    ]);

    return seq;
  }

  Map<String, String> get h => {
        'Authorization': widget.token,
        'Accept': 'application/json',
      };

  @override
  void initState() {
    super.initState();
    if (AppCore.kLocalAiBuildEnabled) {
      AiAssistantController.instance.onEmployeeDraftUpdated =
          _applyAiEmployeeValues;
    }
    _ambientController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 6),
    )..repeat();

    _centralNav = CentralKeyboardNavigator(
      sequenceBuilder: _buildCentralKeyboardSequence,
      onFieldFocused: _focusLive,
      shouldSkipField: _shouldSkipEmployeeField,
    );

    _employeeVoiceSubscription =
        GoogleSpeechService.events.listen(_handleEmployeeVoiceEvent);
    _employeeVoiceSettingsListener = () {
      if (mounted) setState(() {});
    };
    AppCore.voiceSettingsRevision.addListener(_employeeVoiceSettingsListener!);

    for (final key in labels.keys) {
      c[key] = TextEditingController();
    }
    _applyCurrentAppCoreDefaultsToControllers();

    _liveTimer =
        Timer.periodic(const Duration(milliseconds: 700), (_) => _pushLive());
    _load();
  }

  void _applyAiEmployeeValues(Map<String, String> values) {
    if (!mounted || saving) return;
    var changed = false;
    for (final entry in values.entries) {
      if (!labels.containsKey(entry.key) ||
          entry.key.startsWith('addressCountry') ||
          entry.key.startsWith('addressGovernorate') ||
          entry.key.startsWith('addressDistrict') ||
          entry.key.startsWith('addressTown')) continue;
      final controller = c[entry.key];
      final raw = entry.value.trim();
      if (controller == null || raw.isEmpty) continue;
      var value = raw;
      final availableOptions = options[entry.key] ?? _values(entry.key);
      if (availableOptions.isNotEmpty) {
        final wanted = AiCommandParser.normalize(raw);
        Map<String, dynamic>? match;
        for (final option in availableOptions) {
          if (AiCommandParser.normalize(_value(option)) == wanted ||
              AiCommandParser.normalize(_text(option)) == wanted) {
            match = option;
            break;
          }
        }
        if (match == null) continue;
        value = _value(match);
      }
      if (controller.text.trim() != value) {
        controller.value = TextEditingValue(
          text: value,
          selection: TextSelection.collapsed(offset: value.length),
        );
        _aiFieldWriteTimes[entry.key] = DateTime.now();
        changed = true;
      }
    }
    if (changed) {
      setState(() { error = null; });
      _pushLive();
    }
  }

  void _applyCurrentAppCoreDefaultsToControllers() {
    c['town']!.text = AppCore.defaultTown;
    c['area']!.text = AppCore.defaultArea;
    c['homeTown']!.text = AppCore.defaultHomeTown;
    c['address1']!.text = AppCore.defaultAddress1;
    c['address2']!.text = AppCore.defaultAddress2;
    c['closestLocation']!.text = AppCore.defaultClosestLocation;
  }

  @override
  void dispose() {
    if (AppCore.kLocalAiBuildEnabled &&
        AiAssistantController.instance.onEmployeeDraftUpdated != null) {
      AiAssistantController.instance.endEmployeeCreation();
    }
    _ambientController.dispose();
    _centralNav.dispose();
    _liveTimer?.cancel();
    unawaited(GoogleSpeechService.cancelListeningForSession(_employeeVoiceSession));
    _employeeVoiceSubscription?.cancel();
    _employeeVoiceSubscription = null;
    if (_employeeVoiceSettingsListener != null) {
      AppCore.voiceSettingsRevision.removeListener(_employeeVoiceSettingsListener!);
      _employeeVoiceSettingsListener = null;
    }
    SelfieBackgroundRemover.dispose();
    for (final controller in c.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Map<String, List<String>> _liveAliases() => {
        for (final entry in labels.entries)
          entry.key: <String>[
            entry.key,
            entry.value.replaceAll(' *', '').trim(),
            entry.value,
          ],
        'idNumber': ['nationalId', 'رقم البطاقة الوطنية الموحدة', 'رقم الوثيقة'],
        'addressCountry': ['addressCountry', 'الدولة', 'country'],
        'addressGovernorate': ['addressGovernorate', 'المحافظة', 'governorate'],
        'addressDistrict': ['addressDistrict', 'القضاء', 'district'],
        'countryStructureId': ['countryStructureId', 'الموقع الجغرافي'],
      };

  Map<String, String> _liveValues() => {
        for (final entry in c.entries) entry.key: entry.value.text,
        'idNumber': c['nationalId']?.text ?? '',
        'addressCountry': _addressCountryId ?? '',
        'addressGovernorate': _addressGovernorateId ?? '',
        'addressDistrict': _addressDistrictId ?? '',
        'countryStructureId': _addressTownId ?? _addressDistrictId ?? '',
      };

  void _focusLive(String key) {
    _liveSyncKey.currentState?.focusField(key);
    _liveSyncKey.currentState?.pushValues(_liveValues());
    unawaited(_centralNav.scrollToField(key));
  }

  void _pushLive() {
    _liveSyncKey.currentState?.pushValues(_liveValues());
  }

  void _applyLiveSnapshot(Map<String, String> values) {
    bool changed = false;
    for (final entry in values.entries) {
      if (entry.value.trim().isEmpty) continue;
      final targetKey = entry.key == 'idNumber' ? 'nationalId' : entry.key;
      final lastAiWrite = _aiFieldWriteTimes[targetKey];
      if (lastAiWrite != null &&
          DateTime.now().difference(lastAiWrite) <
              const Duration(seconds: 2)) {
        continue;
      }
      final controller = c[targetKey];
      if (controller != null && controller.text != entry.value) {
        controller.value = TextEditingValue(
          text: entry.value,
          selection: TextSelection.collapsed(offset: entry.value.length),
        );
        changed = true;
      }
    }
    if (changed && mounted) setState(() {});
  }

  void _applyLiveOptions(Map<String, List<dynamic>> incoming) {
    bool changed = false;
    incoming.forEach((key, values) {
      if (values.isEmpty) return;
      options[key] = EmisOptions.mergeLive(options[key] ?? <dynamic>[], values);
      changed = true;
    });
    if (changed && mounted) setState(() {});
  }

  dynamic _unwrap(dynamic d) => d is Map && d['data'] != null ? d['data'] : d;

  Future<dynamic> _get(String endpoint) async {
    final encodedUrl = Uri.encodeFull('https://emis.moedu.gov.iq/api$endpoint');
    final response = await http.get(
      Uri.parse(encodedUrl),
      headers: {...h, 'Cache-Control': 'no-cache', 'Pragma': 'no-cache'},
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('HTTP ${response.statusCode}');
    }
    return jsonDecode(utf8.decode(response.bodyBytes));
  }

  Future<List<dynamic>> _list(String endpoint) async {
    try {
      final raw = _unwrap(await _get(endpoint));
      if (raw is! List) return <dynamic>[];
      final result = <dynamic>[];
      for (final item in raw) {
        if (item is Map) {
          result.add(item.map((k, v) => MapEntry(k.toString(), v)));
        } else if (item != null) {
          final s = item.toString().trim();
          if (s.isNotEmpty) {
            result.add(<String, dynamic>{'value': s, 'displayName': s});
          }
        }
      }
      return result;
    } catch (e) {
      debugPrint('EMIS select list failed: $endpoint -> $e');
      return <dynamic>[];
    }
  }

  String _value(Map<String, dynamic> x) =>
      '${x['value'] ?? x['id'] ?? x['code'] ?? ''}'.trim();

  String _text(Map<String, dynamic> x) =>
      '${x['displayName'] ?? x['label'] ?? x['name'] ?? x['text'] ?? _value(x)}'
          .trim();

  Future<void> _load() async {
    try {
      await AppCore.ensureLoaded();
      _applyCurrentAppCoreDefaultsToControllers();
      if (mounted) setState(() => loading = false);

      for (final entry in _optionEndpoints.entries) {
        final fetched = await _list(entry.key == 'positionType'
            ? '/SelectOption/نوع الوظيفة'
            : entry.value);
        if (fetched.isNotEmpty) {
          options[entry.key] = fetched;
        }
      }

      await _loadEmployeesOptions();
      await _loadCountryStructure();
      if (AppCore.kLocalAiBuildEnabled) {
        final latestAiDraft =
            AiAssistantController.instance.employeeDraft.isNotEmpty
                ? Map<String, String>.from(
                    AiAssistantController.instance.employeeDraft)
                : widget.initialAiValues;
        _applyAiEmployeeValues(latestAiDraft);
      }

      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('خطأ أثناء تحميل الخيارات المساندة: $e');
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> _loadEmployeesOptions() async {
    options.remove('status');
    try {
      final decoded = await _get('/employee/getemployeesoptions');
      if (decoded is! Map) return;
      final source = <String, dynamic>{
        for (final entry in decoded.entries)
          entry.key.toString().toLowerCase(): entry.value,
      };

      List<dynamic> parseOptions(dynamic raw) {
        if (raw is Map && raw['data'] is List) raw = raw['data'];
        if (raw is Map && raw['items'] is List) raw = raw['items'];
        if (raw is! List) return <dynamic>[];
        final parsed = <dynamic>[];
        final seen = <String>{};
        for (final item in raw) {
          dynamic value;
          dynamic label;
          if (item is Map) {
            final normalized = <String, dynamic>{
              for (final entry in item.entries)
                entry.key.toString().toLowerCase(): entry.value,
            };
            value = normalized['value'] ?? normalized['id'] ??
                normalized['code'] ?? normalized['label'] ??
                normalized['displayname'] ?? normalized['name'];
            label = normalized['label'] ?? normalized['displayname'] ??
                normalized['name'] ?? value;
          } else {
            value = item;
            label = item;
          }
          final v = '$value'.trim();
          final title = '$label'.trim();
          if (v.isEmpty || title.isEmpty || !seen.add(v)) continue;
          parsed.add(<String, dynamic>{'value': value, 'displayName': title});
        }
        return parsed;
      }

      dynamic findSource(List<String> keys) {
        for (final key in keys) {
          if (source.containsKey(key.toLowerCase())) return source[key.toLowerCase()];
        }
        return null;
      }

      final statuses = EmisEmploymentStatusOptions.extract(decoded);
      final classifications = parseOptions(findSource(['classification']));
      if (statuses != null) {
        options['status'] = List<dynamic>.from(statuses);
      }
      if (classifications.isNotEmpty) options['classification'] = classifications;
      EmisOptions.extractCatalog(decoded).forEach((key, list) {
        if (list.isNotEmpty) options[key] = list;
      });
      if (mounted) setState(() {});
    } catch (_) {}
  }

  Future<void> _loadCountryStructure() async {
    try {
      final list = await _list('/CountryStructure/getcountrystructure');
      if (list.isEmpty) return;
      _addressCountries = list;

      final targetCountry = AppCore.defaultCountry.trim();
      final targetGov = AppCore.defaultGovernorate.trim();
      final targetDist = AppCore.defaultDistrict.trim();

      Map<String, dynamic>? selectedCountry;
      for (final item in list) {
        if ((targetCountry.isNotEmpty && _text(item).contains(targetCountry)) ||
            _text(item).toLowerCase() == 'iraq') {
          selectedCountry = item;
          break;
        }
      }
      final country = selectedCountry ?? (list.first as Map<String, dynamic>);
      _addressCountryId = _value(country);
      _addressGovernorates = _childrenOf(country);

      for (final gov in _addressGovernorates) {
        if (targetGov.isNotEmpty && _text(gov).contains(targetGov)) {
          _addressGovernorateId = _value(gov);
          _addressDistricts = _childrenOf(gov);
          if (_addressDistricts.isNotEmpty) {
            final matchedDist = _addressDistricts
                .where((d) =>
                    targetDist.isNotEmpty && _text(d).contains(targetDist))
                .toList();
            final chosenDist = matchedDist.isNotEmpty
                ? matchedDist.first
                : _addressDistricts.first;
            _addressDistrictId = _value(chosenDist);
            _addressTowns = _childrenOf(chosenDist);
          }
          break;
        }
      }
      if (mounted) setState(() {});
    } catch (_) {}
  }

  List<dynamic> _childrenOf(Map<String, dynamic> node) {
    final raw =
        node['children'] ?? node['items'] ?? node['subItems'] ?? node['childs'];
    if (raw is! List) return <dynamic>[];
    return raw
        .whereType<Map>()
        .map((e) => e.map((k, v) => MapEntry(k.toString(), v)))
        .toList();
  }

  void _setAddressGovernorates(Map<String, dynamic> country) {
    _addressGovernorates = _childrenOf(country);
    _addressGovernorateId = null;
    _addressDistricts = [];
    _addressDistrictId = null;
    _addressTowns = [];
    _addressTownId = null;
  }

  void _setAddressDistricts(Map<String, dynamic> governorate) {
    _addressDistricts = _childrenOf(governorate);
    _addressDistrictId =
        _addressDistricts.isNotEmpty ? _value(_addressDistricts.first) : null;
    _addressTowns = _addressDistrictId == null
        ? <dynamic>[]
        : _childrenOf(_addressDistricts.first);
    _addressTownId = null;
  }

  Future<void> _pickImage(ImageSource source) async {
    try {
      final picked = await pickEmisImage(
        source: source,
        imageQuality: 90,
        maxWidth: 2000,
        maxHeight: 2000,
      );
      if (picked != null && mounted) {
        await _showImagePreviewDialog(File(picked.path));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'تعذر اختيار الصورة: $e',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            backgroundColor: const Color(0xFFEF4444),
            behavior: SnackBarBehavior.floating,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          ),
        );
      }
    }
  }

  Future<void> _showImagePreviewDialog(File imageFile) async {
    File currentImage = imageFile;
    bool processing = false;
    final isDark = AppCore.themeNotifier.value == ThemeMode.dark;

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return Directionality(
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
                  'معاينة صورة الموظف',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    color: isDark ? Colors.white : const Color(0xFF0F172A),
                  ),
                ),
                content: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        height: 220,
                        width: double.infinity,
                        decoration: BoxDecoration(
                          color: isDark
                              ? const Color(0xFF0B0E1A)
                              : const Color(0xFFF8FAFC),
                          border: Border.all(
                            color: const Color(0xFFA855F7).withOpacity(0.35),
                          ),
                          borderRadius: BorderRadius.circular(18),
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(18),
                          child: Image.file(currentImage, fit: BoxFit.contain),
                        ),
                      ),
                      const SizedBox(height: 16),
                      if (processing)
                        const CircularProgressIndicator(
                          color: Color(0xFFF59E0B),
                        )
                      else
                        SizedBox(
                          width: double.infinity,
                          height: 46,
                          child: ElevatedButton.icon(
                            onPressed: () async {
                              setDialogState(() => processing = true);
                              try {
                                final processed =
                                    await SelfieBackgroundRemover.removeBackground(
                                        currentImage);
                                if (processed != null && mounted) {
                                  setDialogState(() {
                                    currentImage = processed;
                                    processing = false;
                                  });
                                }
                              } catch (e) {
                                if (!mounted) return;
                                setDialogState(() => processing = false);
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text('تعذر إزالة الخلفية: $e'),
                                    backgroundColor: const Color(0xFFEF4444),
                                  ),
                                );
                              }
                            },
                            icon: const Icon(
                              Icons.auto_fix_high_rounded,
                              color: Colors.black87,
                            ),
                            label: const Text(
                              'حذف الخلفية بالذكاء الاصطناعي',
                              style: TextStyle(
                                color: Colors.black87,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFFF59E0B),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed:
                        processing ? null : () => Navigator.pop(dialogContext),
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
                    onPressed: processing
                        ? null
                        : () {
                            setState(() => _pickedImage = currentImage);
                            Navigator.pop(dialogContext);
                          },
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF10B981),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    child: const Text(
                      'اعتماد الصورة',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Future<String?> _uploadImageToEmisServer(File imageFile) async {
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('https://emis.moedu.gov.iq/api/employee/uploadimage'),
    );
    request.headers['Authorization'] = widget.token;
    request.headers['Accept'] = 'application/json';
    request.files.add(await http.MultipartFile.fromPath(
      'image',
      imageFile.path,
      filename: 'employee.png',
    ));
    try {
      final streamed = await request.send();
      final responseData = await streamed.stream.bytesToString();
      if (streamed.statusCode == 200) {
        final jsonResponse = jsonDecode(responseData);
        if (jsonResponse is Map) return jsonResponse['imageUrl']?.toString();
      }
    } catch (e) {
      debugPrint('خطأ في رفع الصورة: $e');
    }
    return null;
  }

  String _formatTypedDate(String value) {
    final digits = value
        .replaceAll(RegExp(r'[^0-9٠-٩۰-۹]'), '')
        .replaceAllMapped(RegExp('[٠-٩]'),
            (m) => String.fromCharCode(m.group(0)!.codeUnitAt(0) - 0x0660 + 48))
        .replaceAllMapped(
            RegExp('[۰-۹]'),
            (m) =>
                String.fromCharCode(m.group(0)!.codeUnitAt(0) - 0x06F0 + 48));
    final limited = digits.length > 8 ? digits.substring(0, 8) : digits;
    var out = limited.substring(0, limited.length >= 4 ? 4 : limited.length);
    if (limited.length > 4) {
      out +=
          '-${limited.substring(4, limited.length >= 6 ? 6 : limited.length)}';
    }
    if (limited.length > 6) out += '-${limited.substring(6)}';
    return out;
  }

  bool _isDateKey(String key) => <String>{
        'dateOfBirth',
        'dateOfStartWorking',
        'statusDate',
        'issuingDate',
        'graduationYear',
      }.contains(key);

  InputDecoration _fieldDecoration({
    required String label,
    required bool isDark,
    required Color accentColor,
    String? hint,
    Widget? suffixIcon,
  }) {
    final borderCol = accentColor.withOpacity(isDark ? 0.35 : 0.25);

    return InputDecoration(
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
      filled: true,
      fillColor: isDark
          ? const Color(0xFF0B0E1A).withOpacity(0.68)
          : const Color(0xFFF1F5F9),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      suffixIcon: suffixIcon,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: borderCol, width: 1.2),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: borderCol, width: 1.2),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: accentColor, width: 1.8),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: Color(0xFFEF4444), width: 1.4),
      ),
    );
  }

  Widget _addressDropdown({
    required String label,
    required String fieldId,
    required String? value,
    required List<dynamic> items,
    required ValueChanged<String?> onChanged,
    Color accentColor = const Color(0xFFF97316),
  }) {
    final isDark = AppCore.themeNotifier.value == ThemeMode.dark;
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final safe = items.any((x) => _value(x) == value) ? value : null;

    final fieldKey = _centralNav.keyForField(
      fieldId,
      NavigableFieldType.dropdown,
      isAvailable: () => items.isNotEmpty,
    );

    return DropdownButtonFormField<String>(
      key: fieldKey,
      onTap: () {
        FocusManager.instance.primaryFocus?.unfocus();
        _centralNav.notifyManualDropdownTap(fieldId, fieldKey.currentContext);
      },
      value: safe,
      isExpanded: true,
      dropdownColor: isDark ? const Color(0xFF181D32) : Colors.white,
      iconEnabledColor: accentColor,
      decoration: _fieldDecoration(
        label: label,
        isDark: isDark,
        accentColor: accentColor,
        suffixIcon: (_employeeFieldsWithDefaults.contains(fieldId) ||
                AppCore.hasConfiguredDefaultForStudentField(fieldId))
            ? null
            : ExcludeFocus(child: _employeeVoiceMic(fieldId, accentColor)),
      ),
      style: TextStyle(
        fontWeight: FontWeight.w800,
        fontSize: 13.5,
        color: textColor,
      ),
      selectedItemBuilder: (context) => items
          .map(
            (x) => Text(
              _text(x),
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 13.5,
                color: textColor,
              ),
            ),
          )
          .toList(),
      items: items
          .map(
            (x) => DropdownMenuItem<String>(
              value: _value(x),
              child: Text(
                _text(x),
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 13.5,
                  color: textColor,
                ),
              ),
            ),
          )
          .toList(),
      onChanged: onChanged,
    );
  }

  List<dynamic> _values(String key) {
    final raw = options[key] ?? <dynamic>[];
    final unique = <Map<String, dynamic>>[];

    for (final item in raw) {
      final v = _value(item);
      if (v.isNotEmpty && !unique.any((u) => _value(u) == v)) {
        unique.add(item);
      }
    }

    final current = c[key]?.text.trim() ?? '';
    if (current.isNotEmpty && !unique.any((x) => _value(x) == current)) {
      unique.insert(0, <String, dynamic>{
        'value': current,
        'displayName': current,
      });
    }
    return unique;
  }

  Widget _textField(
    String key, {
    bool required = false,
    TextInputType? keyboard,
    int maxLines = 1,
    Color accentColor = const Color(0xFFA855F7),
  }) {
    final isDark = AppCore.themeNotifier.value == ThemeMode.dark;
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final isDate = _isDateKey(key);
    final centralEnabled = AppCore.centralKeyboardNavigationEnabled;

    final fieldKey = _centralNav.keyForField(
      key,
      NavigableFieldType.text,
    );
    final focusNode = _centralNav.focusNodeForText(key);

    final effectiveKeyboard = isDate
        ? TextInputType.number
        : (keyboard ??
            (maxLines > 1 && !centralEnabled
                ? TextInputType.multiline
                : TextInputType.text));

    return TextFormField(
      key: fieldKey,
      focusNode: focusNode,
      controller: c[key],
      keyboardType: effectiveKeyboard,
      textInputAction:
          centralEnabled ? TextInputAction.next : TextInputAction.done,
      maxLines: maxLines,
      textDirection: (_employeeNumericVoiceFields.contains(key) ||
              RegExp(r'[0-9٠-٩۰-۹]').hasMatch(c[key]?.text ?? ''))
          ? TextDirection.ltr
          : TextDirection.rtl,
      textAlign: (_employeeNumericVoiceFields.contains(key) ||
              RegExp(r'[0-9٠-٩۰-۹]').hasMatch(c[key]?.text ?? ''))
          ? TextAlign.left
          : TextAlign.start,
      inputFormatters: [
        if (isDate)
          TextInputFormatter.withFunction((oldVal, newVal) {
            final formatted = _formatTypedDate(newVal.text);
            return TextEditingValue(
              text: formatted,
              selection: TextSelection.collapsed(offset: formatted.length),
            );
          }),
        if (maxLines > 1) _centralNav.buildEnterInterceptorFormatter(key),
      ],
      onFieldSubmitted: (_) {
        if (centralEnabled) {
          _centralNav.handleFieldSubmitted(key);
        }
      },
      onEditingComplete: () {
        if (centralEnabled) {
          _centralNav.handleFieldSubmitted(key);
        } else {
          FocusManager.instance.primaryFocus?.unfocus();
        }
      },
      decoration: _fieldDecoration(
        label: labels[key] ?? key,
        hint: isDate ? 'YYYY-MM-DD' : null,
        isDark: isDark,
        accentColor: accentColor,
        suffixIcon: ExcludeFocus(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isDate)
                IconButton(
                  tooltip: 'اختر من التقويم',
                  icon: Icon(Icons.calendar_month_rounded, color: accentColor),
                  onPressed: () => _pickDate(key),
                ),
              if (!_employeeFieldsWithDefaults.contains(key) &&
                  !AppCore.hasConfiguredDefaultForStudentField(key))
                _employeeVoiceMic(key, accentColor),
            ],
          ),
        ),
      ),
      style: TextStyle(
        fontWeight: FontWeight.w800,
        fontSize: 13.5,
        color: textColor,
      ),
      validator: required
          ? (v) => (v == null || v.trim().isEmpty) ? 'هذا الحقل مطلوب' : null
          : null,
      onChanged: (_) => _liveSyncKey.currentState?.pushValues(_liveValues()),
      onTap: () => _focusLive(key),
    );
  }

  Future<void> _pickDate(String key) async {
    final raw = c[key]?.text.trim() ?? '';
    final parsed = DateTime.tryParse(raw);
    final initial = parsed != null &&
            parsed.isAfter(DateTime(1900)) &&
            parsed.isBefore(DateTime(2100))
        ? parsed
        : DateTime(1990, 1, 1);

    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(1900),
      lastDate: DateTime.now(),
      helpText: labels[key],
      locale: const Locale('ar'),
    );
    if (picked == null || !mounted) return;
    c[key]!.text =
        '${picked.year.toString().padLeft(4, '0')}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}';
    _focusLive(key);
    setState(() {});
    if (AppCore.centralKeyboardNavigationEnabled) {
      _centralNav.handleFieldSubmitted(key);
    }
  }

  Widget _select(
    String key, {
    bool required = false,
    List<String> fallback = const [],
    Color accentColor = const Color(0xFFA855F7),
  }) {
    final isDark = AppCore.themeNotifier.value == ThemeMode.dark;
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final values = _values(key);
    for (final x in fallback) {
      if (!values.any((v) => _value(v) == x)) {
        values.add(<String, dynamic>{'value': x, 'displayName': x});
      }
    }

    final validValues =
        values.where((x) => _value(x).isNotEmpty).toList(growable: false);
    final current = c[key]!.text.trim();
    final safeValue =
        validValues.any((x) => _value(x) == current) ? current : null;

    final fieldKey = _centralNav.keyForField(
      key,
      NavigableFieldType.dropdown,
      isAvailable: () => validValues.isNotEmpty,
    );

    return DropdownButtonFormField<String>(
      key: fieldKey,
      onTap: () {
        FocusManager.instance.primaryFocus?.unfocus();
        _centralNav.notifyManualDropdownTap(key, fieldKey.currentContext);
      },
      value: safeValue,
      isExpanded: true,
      dropdownColor: isDark ? const Color(0xFF181D32) : Colors.white,
      iconEnabledColor: accentColor,
      style: TextStyle(
        fontWeight: FontWeight.w800,
        fontSize: 13.5,
        color: textColor,
      ),
      decoration: _fieldDecoration(
        label: labels[key] ?? key,
        isDark: isDark,
        accentColor: accentColor,
      ),
      selectedItemBuilder: (context) => validValues
          .map(
            (x) => Text(
              _text(x),
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 13.5,
                color: textColor,
              ),
            ),
          )
          .toList(),
      items: validValues
          .map(
            (x) => DropdownMenuItem<String>(
              value: _value(x),
              child: Text(
                _text(x),
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 13.5,
                  color: textColor,
                ),
              ),
            ),
          )
          .toList(),
      onChanged: (v) {
        setState(() {
          c[key]!.text = v ?? '';
        });
        _focusLive(key);
        if (key == 'employmentType') {
          for (final ms in const <int>[900, 2200]) {
            Future<void>.delayed(Duration(milliseconds: ms), () {
              if (mounted) {
                _liveSyncKey.currentState?.refreshOptions(['classification']);
              }
            });
          }
        }
      },
      validator: required
          ? (v) => (v == null || v.trim().isEmpty) ? 'هذا الحقل مطلوب' : null
          : null,
    );
  }

  Widget _section({
    required String title,
    required IconData icon,
    required Color accentColor,
    required bool isDark,
    required List<Widget> children,
  }) {
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: AppCore.isWindows ? null : isDark
            ? LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  const Color(0xFF141829).withOpacity(0.95),
                  Color.lerp(const Color(0xFF0E1220), accentColor, 0.08)!,
                ],
              )
            : LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Colors.white.withOpacity(0.96),
                  Color.lerp(const Color(0xFFF8FAFC), accentColor, 0.04)!,
                ],
              ),
        color: AppCore.isWindows ? AppCore.windowsGradientFallback(isDark
            ? LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  const Color(0xFF141829).withOpacity(0.95),
                  Color.lerp(const Color(0xFF0E1220), accentColor, 0.08)!,
                ],
              )
            : LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Colors.white.withOpacity(0.96),
                  Color.lerp(const Color(0xFFF8FAFC), accentColor, 0.04)!,
                ],
              )) : null,
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: accentColor.withOpacity(0.15),
                  border: Border.all(
                    color: accentColor.withOpacity(0.5),
                    width: 1.3,
                  ),
                ),
                child: Icon(icon, color: accentColor, size: 22),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    fontSize: 16.5,
                    fontWeight: FontWeight.w900,
                    color: textColor,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Divider(
            height: 1,
            color: isDark ? Colors.white.withOpacity(0.08) : Colors.black12,
          ),
          const SizedBox(height: 14),
          ...children,
        ],
      ),
    );
  }

  void _flattenToFormFields(
    Map<String, String> target,
    String prefix,
    dynamic value,
  ) {
    if (value == null) return;
    if (value is Map) {
      value.forEach((k, v) {
        final nextKey =
            prefix.isEmpty ? k.toString() : '$prefix.${k.toString()}';
        _flattenToFormFields(target, nextKey, v);
      });
    } else if (value is List) {
      for (var i = 0; i < value.length; i++) {
        _flattenToFormFields(target, '$prefix[$i]', value[i]);
      }
    } else {
      target[prefix] = value.toString();
    }
  }

  Future<http.Response> _sendAddRequest(Map<String, dynamic> payload) async {
    final uri = Uri.parse('https://emis.moedu.gov.iq/api/employee/addemployee');
    final jsonString = jsonEncode(payload);

    var response = await http.post(
      uri,
      headers: {
        'Authorization': widget.token,
        'Accept': 'application/json',
        'Content-Type': 'application/json; charset=utf-8',
      },
      body: jsonString,
    );
    if (response.statusCode != 415 && response.statusCode != 405) {
      return response;
    }

    final multipart = http.MultipartRequest('POST', uri);
    multipart.headers['Authorization'] = widget.token;
    multipart.headers['Accept'] = 'application/json';
    _flattenToFormFields(multipart.fields, '', payload);
    multipart.fields['emp'] = jsonString;
    final streamed = await multipart.send();
    return await http.Response.fromStream(streamed);
  }

  String? _dateOnly(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    final v = raw.trim();
    final iso = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})').firstMatch(v);
    if (iso != null) {
      return '${iso.group(1)!.padLeft(4, '0')}-${iso.group(2)!.padLeft(2, '0')}-${iso.group(3)!.padLeft(2, '0')}';
    }
    if (RegExp(r'^\d{4}$').hasMatch(v)) {
      return '$v-01-01';
    }
    return null;
  }

  Future<void> _save({bool addAnother = false}) async {
    if (!(_formKey.currentState?.validate() ?? false)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text(
            'يرجى إكمال جميع الحقول المطلوبة المعلّمة بـ (*)',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          backgroundColor: const Color(0xFFF97316),
          behavior: SnackBarBehavior.floating,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
      );
      return;
    }

    if (_employeeVoiceListening || _employeeVoiceSequential) {
      _employeeVoiceSequential = false;
      _employeeVoiceListening = false;
      await GoogleSpeechService.cancelListeningForSession(_employeeVoiceSession);
    }

    setState(() {
      saving = true;
      error = null;
    });

    try {
      if (_pickedImage != null) {
        final uploaded = await _uploadImageToEmisServer(_pickedImage!);
        if (uploaded != null && uploaded.isNotEmpty) {
          _uploadedImageUrl = uploaded;
        }
      }

      final idNumber = c['nationalId']!.text.trim();
      final idType = int.tryParse(c['idType']!.text.trim()) ??
          int.tryParse(AppCore.defaultIdType) ??
          12;

      if (idType == 12 && idNumber.isNotEmpty) {
        try {
          final check = await _get(
            '/employee/checknationalidnumber?value=${Uri.encodeQueryComponent(idNumber)}',
          );
          if (check is Map && check['isUnique'] == false) {
            throw Exception('رقم البطاقة الوطنية الموحدة مسجل مسبقاً لموظف آخر');
          }
        } catch (e) {
          if (e.toString().contains('مسجل مسبقاً')) rethrow;
        }
      }

      final empIdNum = c['employeeIdNumber']!.text.trim();
      if (empIdNum.isNotEmpty) {
        try {
          final checkEmp = await _get(
            '/employee/checkemployeeidnumber?employeeIdNumber=${Uri.encodeQueryComponent(empIdNum)}',
          );
          if (checkEmp is Map && checkEmp['isUnique'] == false) {
            throw Exception('الرقم الوظيفي مسجل مسبقاً لموظف آخر');
          }
        } catch (e) {
          if (e.toString().contains('مسجل مسبقاً')) rethrow;
        }
      }

      final todayIso = DateTime.now().toIso8601String().split('T').first;
      final quota = int.tryParse(c['weeklyTeachingQuota']?.text.trim() ?? '');
      final empStatus = _n('status') ?? '';
      final schoolIdInt = int.tryParse(widget.schoolId) ?? 1;
      final structureIdInt = int.tryParse(_addressTownId ??
              _addressDistrictId ??
              _addressGovernorateId ??
              '1') ??
          1;

      final payload = <String, dynamic>{
        'EmployeeIdNumber': empIdNum,
        'FamilyNumber': _n('familyNumber'),
        'IsTeacher': false,
        'EmploymentType': _n('employmentType') ?? AppCore.defaultEmploymentType,
        'EmployeeCategory': _n('employeeCategory') ?? 'إداري',
        'Classification': _n('classification') ?? 'موظف',
        'JobDesignation': _n('jobDesignation'),
        'EmploymentGrade': _n('employmentGrade'),
        'WeeklyTeachingQuota': quota,
        'DateOfStartWorking': _dateOnly(_n('dateOfStartWorking')) ?? todayIso,
        'EducationLevel': _n('educationLevel') ?? AppCore.defaultEducationLevel,
        'GraduationYear': _dateOnly(_n('graduationYear')),
        'UniversityName': _n('universityName'),
        'Specialization': _n('specialization') ?? '',
        'Name': _n('name') ?? '',
        'FatherName': _n('fatherName') ?? '',
        'GrandFatherName': _n('grandFatherName') ?? '',
        'FathersGrandFatherName': _n('fathersGrandFatherName') ?? '',
        'SurName': _n('surName') ?? '',
        'MotherName': _n('motherName') ?? '',
        'MothersFatherName': _n('mothersFatherName') ?? '',
        'MothersGrandFatherName': _n('mothersGrandFatherName') ?? '',
        'ImageUrl': _uploadedImageUrl,
        'DateOfBirth': _dateOnly(_n('dateOfBirth')) ?? todayIso,
        'Gender': int.tryParse(c['gender']!.text.trim()) ??
            int.tryParse(AppCore.defaultGender) ??
            1,
        'Nationality': _n('nationality') ?? AppCore.defaultCountry,
        'CountryOfBirth': _n('countryOfBirth') ?? AppCore.defaultCountry,
        'HomeTown': _n('homeTown') ?? AppCore.defaultHomeTown,
        'IdentificationId': 0,
        'Identification': <String, dynamic>{
          'IdNumber': idNumber,
          'IssuingCountry': _n('issuingCountry') ?? AppCore.defaultCountry,
          'IdType': idType,
          'nameOfDocument': _n('nameOfDocument'),
          'recordNumber': _n('recordNumber'),
          'pageNumber': _n('pageNumber'),
          'issuer': _n('issuer'),
          'issuingDate': _dateOnly(_n('issuingDate')),
        },
        'FatherIdentificationId': null,
        'FatherIdentification': null,
        'MotherTongue': _n('motherTongue') ?? AppCore.defaultMotherTongue,
        'MaritalStatus': _n('maritalStatus') ?? '',
        'BloodGroup': _n('bloodGroup') ?? AppCore.defaultBloodGroup,
        'Religion': _n('religion') ?? AppCore.defaultReligion,
        'HomePhoneNumber': '',
        'Status': 1,
        'Notes': _n('notes') ?? '',
        'SpecialNeedsInformation': _n('specialNeedsInformation'),
        'EmergencyContactName': _n('emergencyContactName'),
        'EmergencyContactRelationship': _n('emergencyContactRelationship'),
        'EmergencyContactPhoneNumber': _n('emergencyContactPhoneNumber'),
        'Address': <String, dynamic>{
          'AddressType': 1,
          'Town': _n('town') ?? AppCore.defaultTown,
          'Area': _n('area') ?? AppCore.defaultArea,
          'Quarter': _n('quarter') ?? '',
          'Street': _n('street') ?? '',
          'ClosestLocation':
              _n('closestLocation') ?? AppCore.defaultClosestLocation,
          'countryStructureId': structureIdInt,
          'Latitude': '0',
          'Longitude': '0',
          'ApartmentNumber': '',
          'BuildingNumber': '',
          'Address1': _n('address1') ?? AppCore.defaultAddress1,
          'Address2': _n('address2') ?? AppCore.defaultAddress2,
          'SchoolPhoneNumber': '',
          'MobilePhoneNumber': _n('mobilePhoneNumber') ?? '',
          'Email': _n('email') ?? '',
          'Fax': '',
          'Website': '',
        },
        'AgeExceptionReason': null,
        'AgeExceptionAttachmentUrl': null,
        'ageExceptionAttachment': null,
        'InitiateDate': _dateOnly(_n('dateOfStartWorking')) ?? todayIso,
        'EmploymentStatuses': <Map<String, dynamic>>[
          <String, dynamic>{
            'StatusType': empStatus,
            'DisEngagementDate': null,
            'MinistryOfficialDocumentNumber': null,
            'Reason': _n('statusReason'),
            'AssignedEntityName': _n('assignedEntityName'),
            'CurrentBelongToEntityId': schoolIdInt,
          }
        ],
        'IsCurrentlyActive': empStatus == 'مستمر',
        'CurrentBelongToEntityId': schoolIdInt,
        'CurrentEmploymentPosition': _n('positionType') ?? '',
        'CurrentPosition':
            _n('currentPosition') ?? AppCore.defaultCurrentPosition,
      };

      final response = await _sendAddRequest(payload);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception(
          'فشل الإضافة (HTTP ${response.statusCode}):\n${utf8.decode(response.bodyBytes)}',
        );
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text(
            'تمت إضافة الموظف بنجاح!',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          backgroundColor: const Color(0xFF10B981),
          behavior: SnackBarBehavior.floating,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
      );
      if (addAnother && mounted) {
        await _employeeVoiceSubscription?.cancel();
        _employeeVoiceSubscription = null;
        await GoogleSpeechService.cancelListeningForSession(_employeeVoiceSession);
        if (!mounted) return;
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) => AddEmployeeScreen(
              token: widget.token,
              schoolId: widget.schoolId,
            ),
          ),
        );
      } else {
        Navigator.pop(context, true);
      }
    } catch (e) {
      if (mounted) {
        setState(() => error = '$e');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            duration: const Duration(seconds: 10),
            content: Text(
              '$e',
              maxLines: 5,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            backgroundColor: const Color(0xFFEF4444),
            behavior: SnackBarBehavior.floating,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  String? _n(String key) {
    final value = c[key]?.text.trim() ?? '';
    return value.isEmpty ? null : value;
  }

  List<Widget> _buildDynamicIdFields(Color accentColor) {
    final idType =
        int.tryParse(c['idType']?.text.trim() ?? AppCore.defaultIdType) ?? 12;
    if (idType == 3) {
      return [
        _textField('nationalId', required: true, accentColor: accentColor),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _textField('recordNumber',
                  required: true, accentColor: accentColor),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _textField('pageNumber',
                  required: true, accentColor: accentColor),
            ),
          ],
        ),
        const SizedBox(height: 10),
        _textField('issuer', accentColor: accentColor),
      ];
    } else if (idType == 22) {
      return [
        _textField('nationalId',
            required: true,
            keyboard: TextInputType.number,
            accentColor: accentColor),
        const SizedBox(height: 10),
        _textField('issuingDate', required: true, accentColor: accentColor),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _textField('recordNumber',
                  required: true, accentColor: accentColor),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _textField('pageNumber',
                  required: true, accentColor: accentColor),
            ),
          ],
        ),
      ];
    } else if (idType == 16) {
      return [
        _textField('nameOfDocument', required: true, accentColor: accentColor),
        const SizedBox(height: 10),
        _textField('nationalId',
            required: true,
            keyboard: TextInputType.number,
            accentColor: accentColor),
      ];
    } else {
      return [
        _textField(
          'nationalId',
          required: true,
          keyboard: TextInputType.number,
          accentColor: accentColor,
        ),
      ];
    }
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
    const emeraldNeon = Color(0xFF10B981);

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
          child: Column(
            children: [
              Row(
                children: [
                  _AnimatedEmployeeOrbIcon(
                    icon: Icons.workspace_premium_rounded,
                    primaryColor: purpleNeon,
                    secondaryColor: goldNeon,
                    animation: _ambientController,
                    size: 62,
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              width: 8,
                              height: 8,
                              decoration: const BoxDecoration(
                                shape: BoxShape.circle,
                                color: emeraldNeon,
                              ),
                            ),
                            const SizedBox(width: 6),
                            Flexible(
                              child: Text(
                                _liveStatus,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: isDark
                                      ? const Color(0xFF6EE7B7)
                                      : const Color(0xFF047857),
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 3),
                        Text(
                          'إضافة موظف / مدرس جديد',
                          style: TextStyle(
                            color:
                                isDark ? Colors.white : const Color(0xFF0F172A),
                            fontSize: 18.5,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          'جميع الحقول والقوائم مطابقة لنظام EMIS الرسمي',
                          style: TextStyle(
                            color: isDark
                                ? const Color(0xFF94A3B8)
                                : const Color(0xFF64748B),
                            fontSize: 12,
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
              const SizedBox(height: 12),
              SizedBox(
                height: 26,
                width: double.infinity,
                child: CustomPaint(
                  painter: _EmployeeWavePainter(
                    phase: _ambientController.value * 2 * math.pi,
                    color: goldNeon,
                    isDark: isDark,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildAvatarPickerCard(bool isDark) {
    const purpleNeon = Color(0xFFA855F7);
    const blueNeon = Color(0xFF3B82F6);
    const emeraldNeon = Color(0xFF10B981);
    const goldNeon = Color(0xFFF59E0B);

    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final mutedColor =
        isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);

    return ExcludeFocus(
      child: Container(
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
        decoration: BoxDecoration(
          gradient: AppCore.isWindows ? null : isDark
              ? LinearGradient(
                  colors: [
                    const Color(0xFF141829).withOpacity(0.95),
                    const Color(0xFF1E1732).withOpacity(0.90),
                  ],
                )
              : LinearGradient(
                  colors: [
                    Colors.white.withOpacity(0.96),
                    const Color(0xFFF5F3FF).withOpacity(0.92),
                  ],
                ),
          color: AppCore.isWindows ? AppCore.windowsGradientFallback(isDark
              ? LinearGradient(
                  colors: [
                    const Color(0xFF141829).withOpacity(0.95),
                    const Color(0xFF1E1732).withOpacity(0.90),
                  ],
                )
              : LinearGradient(
                  colors: [
                    Colors.white.withOpacity(0.96),
                    const Color(0xFFF5F3FF).withOpacity(0.92),
                  ],
                )) : null,
          borderRadius: BorderRadius.circular(26),
          border: Border.all(
            color: purpleNeon.withOpacity(isDark ? 0.45 : 0.30),
            width: 1.4,
          ),
          boxShadow: [
            BoxShadow(
              color: purpleNeon.withOpacity(isDark ? 0.14 : 0.08),
              blurRadius: 20,
              offset: const Offset(0, 7),
            ),
          ],
        ),
        child: Column(
          children: [
            AnimatedBuilder(
              animation: _ambientController,
              builder: (context, _) {
                return SizedBox(
                  width: 150,
                  height: 150,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Positioned.fill(
                        child: CustomPaint(
                          painter: _EmployeeOrbPainter(
                            progress: _ambientController.value,
                            primaryColor: purpleNeon,
                            secondaryColor: goldNeon,
                          ),
                        ),
                      ),
                      Container(
                        width: 122,
                        height: 122,
                        padding: const EdgeInsets.all(3.5),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: AppCore.isWindows ? null : const LinearGradient(
                            colors: [purpleNeon, blueNeon, emeraldNeon],
                          ),
                          color: AppCore.isWindows ? AppCore.windowsGradientFallback(const LinearGradient(
                            colors: [purpleNeon, blueNeon, emeraldNeon],
                          )) : null,
                          boxShadow: [
                            BoxShadow(
                              color: purpleNeon.withOpacity(0.35),
                              blurRadius: 16,
                              spreadRadius: 2,
                            ),
                          ],
                        ),
                        child: ClipOval(
                          child: Container(
                            color: isDark
                                ? const Color(0xFF0F172A)
                                : const Color(0xFFF1F5F9),
                            child: _pickedImage != null
                                ? Image.file(_pickedImage!, fit: BoxFit.cover)
                                : Icon(
                                    Icons.person_rounded,
                                    size: 68,
                                    color: isDark
                                        ? const Color(0xFFC4B5FD)
                                        : const Color(0xFF7C3AED),
                                  ),
                          ),
                        ),
                      ),
                      Positioned(
                        bottom: 4,
                        right: 6,
                        child: GestureDetector(
                          onTap: () => _pickImage(ImageSource.camera),
                          child: Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: AppCore.isWindows ? null : const LinearGradient(
                                colors: [blueNeon, Color(0xFF2563EB)],
                              ),
                              color: AppCore.isWindows ? AppCore.windowsGradientFallback(const LinearGradient(
                                colors: [blueNeon, Color(0xFF2563EB)],
                              )) : null,
                              border:
                                  Border.all(color: Colors.white, width: 1.5),
                              boxShadow: [
                                BoxShadow(
                                  color: blueNeon.withOpacity(0.45),
                                  blurRadius: 10,
                                ),
                              ],
                            ),
                            child: const Icon(
                              Icons.camera_alt_rounded,
                              color: Colors.white,
                              size: 19,
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        bottom: 4,
                        left: 6,
                        child: GestureDetector(
                          onTap: () => _pickImage(ImageSource.gallery),
                          child: Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: AppCore.isWindows ? null : const LinearGradient(
                                colors: [emeraldNeon, Color(0xFF059669)],
                              ),
                              color: AppCore.isWindows ? AppCore.windowsGradientFallback(const LinearGradient(
                                colors: [emeraldNeon, Color(0xFF059669)],
                              )) : null,
                              border:
                                  Border.all(color: Colors.white, width: 1.5),
                              boxShadow: [
                                BoxShadow(
                                  color: emeraldNeon.withOpacity(0.45),
                                  blurRadius: 10,
                                ),
                              ],
                            ),
                            child: const Icon(
                              Icons.photo_library_rounded,
                              color: Colors.white,
                              size: 19,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
            const SizedBox(height: 8),
            Text(
              _pickedImage != null
                  ? 'تم تجهيز صورة الموظف بنجاح'
                  : 'الصورة الرسمية للموظف (اختياري)',
              style: TextStyle(
                color: textColor,
                fontWeight: FontWeight.w900,
                fontSize: 14.5,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              'التقط صورة بالكاميرا أو اختر من المعرض مع دعم إزالة الخلفية الذكية',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: mutedColor,
                fontWeight: FontWeight.w600,
                fontSize: 11.5,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSaveButton(bool isDark) {
    const purpleNeon = Color(0xFFA855F7);
    const goldNeon = Color(0xFFF59E0B);

    return ExcludeFocus(
      child: GestureDetector(
        onTap: saving ? null : () => _save(),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          height: 58,
          decoration: BoxDecoration(
            gradient: AppCore.isWindows ? null : saving
                ? LinearGradient(
                    colors: [
                      Colors.grey.shade700,
                      Colors.grey.shade600,
                    ],
                  )
                : const LinearGradient(
                    begin: Alignment.topRight,
                    end: Alignment.bottomLeft,
                    colors: [
                      purpleNeon,
                      Color(0xFF6366F1),
                      goldNeon,
                    ],
                  ),
            color: AppCore.isWindows ? AppCore.windowsGradientFallback(saving
                ? LinearGradient(
                    colors: [
                      Colors.grey.shade700,
                      Colors.grey.shade600,
                    ],
                  )
                : const LinearGradient(
                    begin: Alignment.topRight,
                    end: Alignment.bottomLeft,
                    colors: [
                      purpleNeon,
                      Color(0xFF6366F1),
                      goldNeon,
                    ],
                  )) : null,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(
              color: Colors.white.withOpacity(0.35),
              width: 1.3,
            ),
            boxShadow: saving
                ? []
                : [
                    BoxShadow(
                      color: purpleNeon.withOpacity(isDark ? 0.35 : 0.25),
                      blurRadius: 20,
                      offset: const Offset(0, 7),
                    ),
                  ],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (saving)
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
                  Icons.person_add_alt_1_rounded,
                  color: Colors.white,
                  size: 24,
                ),
              const SizedBox(width: 10),
              Text(
                saving ? 'جاري حفظ بيانات الموظف...' : 'حفظ الموظف في EMIS',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w900,
                  fontSize: 17,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSaveAndAddButton() {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: saving ? null : () => _save(addAnother: true),
        icon: const Icon(Icons.add_circle_outline_rounded),
        label: const Text('حفظ + إضافة موظف جديد'),
        style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(52),
          foregroundColor: const Color(0xFF10B981),
          side: const BorderSide(color: Color(0xFF10B981), width: 1.5),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          textStyle: const TextStyle(fontWeight: FontWeight.w900, fontSize: 15),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final eduLevel = c['educationLevel']?.text.trim() ?? '';
    final showUniv = eduLevel == 'دبلوم' || eduLevel == 'بكالوريوس';
    final showSpec =
        !const ['ابتدائية', 'متوسطة', 'إعدادية'].contains(eduLevel);
    final empStatus = c['status']?.text.trim() ?? '';

    return ValueListenableBuilder<ThemeMode>(
      valueListenable: AppCore.themeNotifier,
      builder: (context, currentMode, _) {
        final isDark = currentMode == ThemeMode.dark;
        final textColor = isDark ? Colors.white : const Color(0xFF0F172A);

        const emeraldNeon = Color(0xFF10B981);
        const goldNeon = Color(0xFFF59E0B);
        const purpleNeon = Color(0xFFA855F7);
        const blueNeon = Color(0xFF3B82F6);
        const orangeNeon = Color(0xFFF97316);
        const cyanNeon = Color(0xFF06B6D4);

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
                            right: -50,
                            child: _buildAmbientGlow(
                              color: isDark
                                  ? purpleNeon.withOpacity(0.18)
                                  : purpleNeon.withOpacity(0.12),
                              size: 260,
                            ),
                          ),
                          Positioned(
                            top: 260 - shift,
                            left: -70,
                            child: _buildAmbientGlow(
                              color: isDark
                                  ? goldNeon.withOpacity(0.14)
                                  : blueNeon.withOpacity(0.10),
                              size: 280,
                            ),
                          ),
                          Positioned(
                            bottom: -70 + shift,
                            right: 20,
                            child: _buildAmbientGlow(
                              color: isDark
                                  ? emeraldNeon.withOpacity(0.12)
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
                  child: loading
                      ? Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _AnimatedEmployeeOrbIcon(
                                icon: Icons.workspace_premium_rounded,
                                primaryColor: purpleNeon,
                                secondaryColor: goldNeon,
                                animation: _ambientController,
                                size: 76,
                              ),
                              const SizedBox(height: 16),
                              Text(
                                'جاري تحميل بيانات وخيارات الكادر...',
                                style: TextStyle(
                                  color: textColor,
                                  fontWeight: FontWeight.w800,
                                  fontSize: 15,
                                ),
                              ),
                            ],
                          ),
                        )
                      : Form(
                          key: _formKey,
                          child: ListView(
                            physics: const BouncingScrollPhysics(),
                            cacheExtent: 5000,
                            padding: const EdgeInsets.fromLTRB(16, 12, 16, 35),
                            children: [
                              _buildTopHeader(isDark),
                              _employeeVoiceNavigationControl(isDark),
                              if (error != null) ...[
                                const SizedBox(height: 12),
                                _error(error!, isDark),
                              ],
                              const SizedBox(height: 14),
                              _buildAvatarPickerCard(isDark),
                              _section(
                                title: 'البيانات الشخصية والاسم الكامل',
                                icon: Icons.person_rounded,
                                accentColor: purpleNeon,
                                isDark: isDark,
                                children: [
                                  _textField('name',
                                      required: true, accentColor: purpleNeon),
                                  const SizedBox(height: 10),
                                  _textField('fatherName',
                                      required: true, accentColor: purpleNeon),
                                  const SizedBox(height: 10),
                                  _textField('grandFatherName',
                                      required: true, accentColor: purpleNeon),
                                  const SizedBox(height: 10),
                                  _textField('fathersGrandFatherName',
                                      required: true, accentColor: purpleNeon),
                                  const SizedBox(height: 10),
                                  _textField('surName',
                                      required: true, accentColor: purpleNeon),
                                  const SizedBox(height: 10),
                                  _textField('motherName',
                                      required: true, accentColor: purpleNeon),
                                  const SizedBox(height: 10),
                                  _textField('mothersFatherName',
                                      required: true, accentColor: purpleNeon),
                                  const SizedBox(height: 10),
                                  _textField('mothersGrandFatherName',
                                      required: true, accentColor: purpleNeon),
                                  const SizedBox(height: 10),
                                  Row(
                                    children: [
                                      Expanded(
                                        child: _select('gender',
                                            required: true,
                                            accentColor: purpleNeon),
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: _textField('dateOfBirth',
                                            required: true,
                                            accentColor: purpleNeon),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 10),
                                  Row(
                                    children: [
                                      Expanded(
                                        child: _select('countryOfBirth',
                                            accentColor: purpleNeon),
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: _select('nationality',
                                            required: true,
                                            accentColor: purpleNeon),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 10),
                                  _textField('homeTown',
                                      accentColor: purpleNeon),
                                ],
                              ),
                              _section(
                                title: 'الهوية والوثائق الرسمية',
                                icon: Icons.badge_rounded,
                                accentColor: blueNeon,
                                isDark: isDark,
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: _select('idType',
                                            required: true,
                                            accentColor: blueNeon),
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: _select(
                                          'issuingCountry',
                                          required: true,
                                          accentColor: blueNeon,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 10),
                                  ..._buildDynamicIdFields(blueNeon),
                                  const SizedBox(height: 10),
                                  Row(
                                    children: [
                                      Expanded(
                                        child: _textField('employeeIdNumber',
                                            accentColor: blueNeon),
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: _textField('familyNumber',
                                            accentColor: blueNeon),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                              _section(
                                title: 'البيانات الوظيفية والأكاديمية',
                                icon: Icons.work_rounded,
                                accentColor: goldNeon,
                                isDark: isDark,
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: _select('employmentType',
                                            required: true,
                                            accentColor: goldNeon),
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: _select('employeeCategory',
                                            required: true,
                                            accentColor: goldNeon),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 10),
                                  Row(
                                    children: [
                                      Expanded(
                                        child: _select('classification',
                                            required: true,
                                            accentColor: goldNeon),
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: _textField('jobDesignation',
                                            accentColor: goldNeon),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 10),
                                  Row(
                                    children: [
                                      Expanded(
                                        child: _select('employmentGrade',
                                            accentColor: goldNeon),
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: _textField(
                                          'weeklyTeachingQuota',
                                          keyboard: TextInputType.number,
                                          accentColor: goldNeon,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 10),
                                  Row(
                                    children: [
                                      Expanded(
                                        child: _select('positionType',
                                            required: true,
                                            accentColor: goldNeon),
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: _select('currentPosition',
                                            required: true,
                                            accentColor: goldNeon),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 10),
                                  _textField('dateOfStartWorking',
                                      required: true, accentColor: goldNeon),
                                  const SizedBox(height: 14),
                                  Container(
                                    padding: const EdgeInsets.all(14),
                                    decoration: BoxDecoration(
                                      color: goldNeon
                                          .withOpacity(isDark ? 0.08 : 0.05),
                                      borderRadius: BorderRadius.circular(18),
                                      border: Border.all(
                                        color: goldNeon.withOpacity(0.30),
                                      ),
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: [
                                        Row(
                                          children: [
                                            const Icon(
                                              Icons.verified_user_rounded,
                                              color: goldNeon,
                                              size: 20,
                                            ),
                                            const SizedBox(width: 8),
                                            Text(
                                              'الحالة الوظيفية',
                                              style: TextStyle(
                                                color: textColor,
                                                fontWeight: FontWeight.w900,
                                                fontSize: 14.5,
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 10),
                                        _select('status',
                                            required: true,
                                            accentColor: goldNeon),
                                        if (empStatus != 'مستمر') ...[
                                          const SizedBox(height: 10),
                                          _textField('statusReason',
                                              required: true,
                                              maxLines: 2,
                                              accentColor: goldNeon),
                                        ],
                                        if (empStatus ==
                                            'مكلف او منسب من وزارة التربية الى جهات أخرى') ...[
                                          const SizedBox(height: 10),
                                          _textField('assignedEntityName',
                                              required: true,
                                              accentColor: goldNeon),
                                        ],
                                      ],
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                  _select('educationLevel',
                                      required: true, accentColor: goldNeon),
                                  if (showUniv) ...[
                                    const SizedBox(height: 10),
                                    Row(
                                      children: [
                                        Expanded(
                                          child: _textField('universityName',
                                              accentColor: goldNeon),
                                        ),
                                        const SizedBox(width: 10),
                                        Expanded(
                                          child: _textField('graduationYear',
                                              accentColor: goldNeon),
                                        ),
                                      ],
                                    ),
                                  ],
                                  if (showSpec) ...[
                                    const SizedBox(height: 10),
                                    _select('specialization',
                                        required: true, accentColor: goldNeon),
                                  ],
                                ],
                              ),
                              _section(
                                title: 'البيانات الاجتماعية والاتصال',
                                icon: Icons.diversity_3_rounded,
                                accentColor: emeraldNeon,
                                isDark: isDark,
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: _select('motherTongue',
                                            required: true,
                                            accentColor: emeraldNeon),
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: _select('maritalStatus',
                                            accentColor: emeraldNeon),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 10),
                                  Row(
                                    children: [
                                      Expanded(
                                        child: _select('bloodGroup',
                                            accentColor: emeraldNeon),
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: _select('religion',
                                            required: true,
                                            accentColor: emeraldNeon),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 10),
                                  _textField('mobilePhoneNumber',
                                      required: true,
                                      keyboard: TextInputType.phone,
                                      accentColor: emeraldNeon),
                                  const SizedBox(height: 10),
                                  _textField('specialNeedsInformation',
                                      maxLines: 2, accentColor: emeraldNeon),
                                  const SizedBox(height: 10),
                                  _textField('notes',
                                      maxLines: 3, accentColor: emeraldNeon),
                                ],
                              ),
                              _section(
                                title: 'بيانات الاتصال في الحالات الطارئة',
                                icon: Icons.contact_phone_rounded,
                                accentColor: cyanNeon,
                                isDark: isDark,
                                children: [
                                  _textField('emergencyContactName',
                                      accentColor: cyanNeon),
                                  const SizedBox(height: 10),
                                  Row(
                                    children: [
                                      Expanded(
                                        child: _textField(
                                            'emergencyContactRelationship',
                                            accentColor: cyanNeon),
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: _textField(
                                          'emergencyContactPhoneNumber',
                                          keyboard: TextInputType.phone,
                                          accentColor: cyanNeon,
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                              _section(
                                title: 'العنوان والموقع الجغرافي',
                                icon: Icons.location_on_rounded,
                                accentColor: orangeNeon,
                                isDark: isDark,
                                children: [
                                  _addressDropdown(
                                    label: 'الدولة',
                                    fieldId: 'addressCountry',
                                    value: _addressCountryId,
                                    items: _addressCountries,
                                    accentColor: orangeNeon,
                                    onChanged: (v) {
                                      final item = _addressCountries
                                          .where((x) => _value(x) == v)
                                          .toList();
                                      if (item.isEmpty) return;
                                      setState(() {
                                        _addressCountryId = v;
                                        _setAddressGovernorates(item.first);
                                      });
                                      _focusLive('addressCountry');
                                    },
                                  ),
                                  const SizedBox(height: 10),
                                  _addressDropdown(
                                    label: 'المحافظة',
                                    fieldId: 'addressGovernorate',
                                    value: _addressGovernorateId,
                                    items: _addressGovernorates,
                                    accentColor: orangeNeon,
                                    onChanged: (v) {
                                      final item = _addressGovernorates
                                          .where((x) => _value(x) == v)
                                          .toList();
                                      if (item.isEmpty) return;
                                      setState(() {
                                        _addressGovernorateId = v;
                                        _setAddressDistricts(item.first);
                                      });
                                      _focusLive('addressGovernorate');
                                    },
                                  ),
                                  const SizedBox(height: 10),
                                  _addressDropdown(
                                    label: 'القضاء *',
                                    fieldId: 'addressDistrict',
                                    value: _addressDistrictId,
                                    items: _addressDistricts,
                                    accentColor: orangeNeon,
                                    onChanged: (v) {
                                      final selected = _addressDistricts
                                          .where((x) => _value(x) == v)
                                          .toList();
                                      setState(() {
                                        _addressDistrictId = v;
                                        _addressTowns = selected.isEmpty
                                            ? <dynamic>[]
                                            : _childrenOf(selected.first);
                                        _addressTownId = null;
                                      });
                                      _focusLive('addressDistrict');
                                    },
                                  ),
                                  const SizedBox(height: 10),
                                  _addressDropdown(
                                    label: 'الناحية *',
                                    fieldId: 'addressTown',
                                    value: _addressTownId,
                                    items: _addressTowns,
                                    accentColor: orangeNeon,
                                    onChanged: (v) {
                                      setState(() => _addressTownId = v);
                                      _liveSyncKey.currentState
                                          ?.pushValues(_liveValues());
                                    },
                                  ),
                                  const SizedBox(height: 10),
                                  _textField('town',
                                      required: true, accentColor: orangeNeon),
                                  const SizedBox(height: 10),
                                  _textField('area',
                                      required: true,
                                      accentColor: orangeNeon),
                                  const SizedBox(height: 10),
                                  _textField('quarter',
                                      required: true,
                                      accentColor: orangeNeon),
                                  const SizedBox(height: 10),
                                  _textField('street',
                                      required: true, accentColor: orangeNeon),
                                  const SizedBox(height: 10),
                                  Row(
                                    children: [
                                      Expanded(
                                        child: _textField('address1',
                                            required: true,
                                            accentColor: orangeNeon),
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: _textField('address2',
                                            accentColor: orangeNeon),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 10),
                                  _textField('closestLocation',
                                      required: true, accentColor: orangeNeon),
                                  const SizedBox(height: 10),
                                  _textField(
                                    'email',
                                    keyboard: TextInputType.emailAddress,
                                    accentColor: orangeNeon,
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              _buildSaveButton(isDark),
                              const SizedBox(height: 10),
                              _buildSaveAndAddButton(),
                              const SizedBox(height: 25),
                            ],
                          ),
                        ),
                ),
                _fixedEmployeeVoiceArrow(isDark),
                if (!loading)
                  Positioned(
                    left: 0,
                    bottom: 0,
                    child: EmisLiveSync(
                      ignoreInitialSnapshot: true,
                      key: _liveSyncKey,
                      url:
                          'https://emis.moedu.gov.iq/centers/schools/${widget.schoolId}/individuals/employees/management/add',
                      mode: 'add',
                      entity: 'employee',
                      token: widget.token,
                      aliases: _liveAliases(),
                      onSnapshot: _applyLiveSnapshot,
                      onOptions: _applyLiveOptions,
                      onStatus: (v) {
                        if (mounted) setState(() => _liveStatus = v);
                      },
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _error(String text, bool isDark) => Container(
        padding: const EdgeInsets.all(13),
        decoration: BoxDecoration(
          color: const Color(0xFFEF4444).withOpacity(isDark ? 0.15 : 0.09),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFFEF4444).withOpacity(0.45)),
        ),
        child: Row(
          children: [
            const Icon(Icons.error_outline_rounded, color: Color(0xFFEF4444)),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                text,
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  color: isDark ? Colors.white : const Color(0xFFB91C1C),
                ),
              ),
            ),
          ],
        ),
      );
}

class _AnimatedEmployeeOrbIcon extends StatelessWidget {
  final IconData icon;
  final Color primaryColor;
  final Color secondaryColor;
  final Animation<double> animation;
  final double size;

  const _AnimatedEmployeeOrbIcon({
    required this.icon,
    required this.primaryColor,
    required this.secondaryColor,
    required this.animation,
    this.size = 62,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      builder: (context, _) {
        final t = animation.value;
        final floatOffset = math.sin(t * 2 * math.pi) * 3.0;

        return SizedBox(
          width: size,
          height: size,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Positioned.fill(
                child: CustomPaint(
                  painter: _EmployeeOrbPainter(
                    progress: t,
                    primaryColor: primaryColor,
                    secondaryColor: secondaryColor,
                  ),
                ),
              ),
              Transform.translate(
                offset: Offset(0, floatOffset),
                child: Container(
                  width: size * 0.62,
                  height: size * 0.62,
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
                    size: size * 0.32,
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

class _EmployeeOrbPainter extends CustomPainter {
  final double progress;
  final Color primaryColor;
  final Color secondaryColor;

  _EmployeeOrbPainter({
    required this.progress,
    required this.primaryColor,
    required this.secondaryColor,
  });

  @override
  void paint(Canvas sizeCanvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final angle = progress * 2 * math.pi;

    for (final tilt in [0.45, -0.45]) {
      sizeCanvas.save();
      sizeCanvas.translate(center.dx, center.dy);
      sizeCanvas.rotate(tilt);
      final rect = Rect.fromCenter(
        center: Offset.zero,
        width: size.width * 0.94,
        height: size.height * 0.38,
      );
      final orbitPaint = Paint()
        ..color = primaryColor.withOpacity(0.45)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4;
      sizeCanvas.drawOval(rect, orbitPaint);

      final dir = tilt > 0 ? angle : -angle + 1.5;
      final dx = (size.width * 0.47) * math.cos(dir);
      final dy = (size.height * 0.19) * math.sin(dir);
      sizeCanvas.drawCircle(
        Offset(dx, dy),
        2.6,
        Paint()..color = secondaryColor,
      );
      sizeCanvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant _EmployeeOrbPainter oldDelegate) =>
      oldDelegate.progress != progress;
}

class _EmployeeWavePainter extends CustomPainter {
  final double phase;
  final Color color;
  final bool isDark;

  _EmployeeWavePainter({
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
  bool shouldRepaint(covariant _EmployeeWavePainter oldDelegate) =>
      oldDelegate.phase != phase || oldDelegate.isDark != isDark;
}
