import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'app_core.dart';
import 'central_keyboard_navigation.dart';
import 'emis_live_sync.dart';
import 'google_speech_service.dart';
import 'voice_result_processor.dart';
import 'ai_assistant/ai_assistant_controller.dart';
import 'ai_assistant/ai_command_parser.dart';
import 'legacy_speech_service.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'platform_permissions.dart';

class AddStudentScreen extends StatefulWidget {
  final String token;
  final String schoolId;
  final Map<String, String> initialAiValues;

  const AddStudentScreen({
    super.key,
    required this.token,
    required this.schoolId,
    this.initialAiValues = const <String, String>{},
  });

  @override
  State<AddStudentScreen> createState() => _AddStudentScreenState();
}

class _AddStudentScreenState extends State<AddStudentScreen>
    with SingleTickerProviderStateMixin {
  final _form = GlobalKey<FormState>();
  final Map<String, TextEditingController> c = {};
  final Map<String, List<dynamic>> options = {};

  late final AnimationController _ambientController;
  late final CentralKeyboardNavigator _centralNav;

  bool loading = true, saving = false;
  bool _loadingRoomsForStage = false;
  bool _speechListening = false;
  String? _speechError;
  String? _activeVoiceField;
  String? _pendingVoiceField;
  int? _activeVoiceSessionId;
  int _nextVoiceSessionId = 0;
  bool _speechStopRequested = false;
  bool _micPointerDown = false;
  bool _voiceArrowPointerDown = false;
  bool _voiceSequentialMode = AppCore.voiceSequentialAutoStart;
  int _sequentialVoiceIndex = 0;

  // حفظ النص المتراكم بين الأنفاس في المحرك الاحتياطي (legacy) ومحرك Google للأرقام والنصوص
  String _accumulatedLegacyText = '';
  String _accumulatedGoogleDigits = '';
  String _accumulatedGoogleText = '';

  double _voiceArrowLeft = AppCore.voiceArrowLeft;
  double? _voiceArrowTop = AppCore.voiceArrowTop;
  String? _voiceDropdownTarget;
  bool _voiceDropdownDialogOpen = false;
  bool _specialVoiceFailureShown = false;
  StreamSubscription<dynamic>? _googleSpeechSubscription;
  VoidCallback? _appCoreSettingsListener;
  bool _legacySpeechInitialized = false;
  bool _legacySpeechAvailable = false;
  Timer? _legacyFinalizationTimer;
  Timer? _googleFinalizationTimer;

  // متغير تفعيل إضافة تفاصيل هوية الأب
  bool _includeFatherId = false;

  void _scrollVoiceFieldIntoView(String key) {
    if (!mounted) return;
    final fieldType = _isDropdownNavField(key)
        ? NavigableFieldType.dropdown
        : NavigableFieldType.text;
    final fieldKey = _centralNav.keyForField(key, fieldType);
    final fieldContext = fieldKey.currentContext;
    if (fieldContext == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final retryContext =
            _centralNav.keyForField(key, fieldType).currentContext;
        if (retryContext != null) {
          Scrollable.ensureVisible(
            retryContext,
            duration: const Duration(milliseconds: 420),
            curve: Curves.easeOutCubic,
            alignment: 0.16,
            alignmentPolicy: ScrollPositionAlignmentPolicy.explicit,
          );
        }
      });
      return;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final context = _centralNav.keyForField(key, fieldType).currentContext;
      if (context == null) return;
      Scrollable.ensureVisible(
        context,
        duration: const Duration(milliseconds: 420),
        curve: Curves.easeOutCubic,
        alignment: 0.16,
        alignmentPolicy: ScrollPositionAlignmentPolicy.explicit,
      );
    });
  }

  String? error;
  String? _saveStatus;
  bool _saveStatusIsError = false;
  final GlobalKey<EmisLiveSyncState> _liveSyncKey =
      GlobalKey<EmisLiveSyncState>();
  Timer? _liveTimer;
  final Map<String, DateTime> _aiFieldWriteTimes = <String, DateTime>{};
  String _liveStatus = 'المزامنة الحية مع EMIS قيد التشغيل';
  String? stageId, roomId;
  List<dynamic> stages = [], rooms = [];
  Map<String, dynamic>? stageDetails;

  List<dynamic> _addressCountries = [];
  List<dynamic> _addressGovernorates = [];
  List<dynamic> _addressDistricts = [];
  List<dynamic> _addressTowns = [];
  String? _addressCountryId;
  String? _addressGovernorateId;
  String? _addressDistrictId;
  String? _addressTownId;

  final Map<String, String> endpoints = const {
    'gender': '/selectoption/Gender',
    'countryOfBirth': '/selectoption/بلد الولادة',
    'idType': '/selectoption/IdentificationType',
    'issuingCountry': '/selectoption/بلد الإصدار',
    'motherTongue': '/selectoption/لغة',
    'bloodGroup': '/selectoption/فصيلة الدم',
    'religion': '/selectoption/الديانة',
    'economicLevel': '/selectoption/حالة الاقتصادية',
    'specialNeeds': '/selectoption/ذوي الإحتياجات الخاصة',
  };

  static const Set<String> _voiceFields = {
    'name',
    'fatherName',
    'grandFatherName',
    'fathersGrandFatherName',
    'surName',
    'motherName',
    'mothersFatherName',
    'mothersGrandFatherName',
    'issuer',
    'nameOfDocument',
    'town',
    'area',
    'quarter',
    'street',
    'address1',
    'address2',
    'closestLocation',
    'fatherIssuer',
    'fatherNameOfDocument',
  };

  static const Set<String> _numericVoiceFields = {
    'nationalId',
    'idNumber',
    'jinsiyaIdNumber',
    'recordNumber',
    'pageNumber',
    'birthCertificateNumber',
    'otherIdNumber',
    'homePhoneNumber',
    'censusNumber',
    'fatherNationalId',
    'fatherIdNumber',
    'fatherRecordNumber',
    'fatherPageNumber',
    'fatherBirthCertificateNumber',
    'fatherOtherIdNumber',
  };

  static const Set<String> _dropdownVoiceFields = {
    // Gender and academic stage are selected manually/defaulted; no microphone.
    'issuingCountry',
    'fatherIdType',
    'fatherIssuingCountry',
  };

  static const Set<String> _allDropdownNavFields = {
    'gender',
    'countryOfBirth',
    'nationality',
    'idType',
    'issuingCountry',
    'fatherIssuingCountry',
    'fatherIdType',
    'motherTongue',
    'studyLanguage',
    'maritalStatus',
    'bloodGroup',
    'religion',
    'economicLevel',
    'specialNeeds',
    'isCoveredBySocialWelfare',
    'stageId',
    'classRoomId',
    'addressCountry',
    'addressGovernorate',
    'addressDistrict',
    'addressTown',
  };

  bool _isDropdownNavField(String key) => _allDropdownNavFields.contains(key);

  static const Set<String> _dateVoiceFields = {
    'dateOfBirth',
    'issuingDate',
    'fatherIssuingDate',
  };

  // ترتيب التنقل الصوتي بعد وضع رقم الهاتف أسفل الديانة مباشرة وإزالة المايك من الملاحظات
  static const List<String> _voiceSequentialOrder = [
    'name',
    'fatherName',
    'grandFatherName',
    'fathersGrandFatherName',
    'surName',
    'motherName',
    'mothersFatherName',
    'mothersGrandFatherName',
    'dateOfBirth',
    'gender',
    'countryOfBirth',
    'nationality',
    'homeTown',
    'idType',
    'nationalId',
    'idNumber',
    'jinsiyaIdNumber',
    'issuer',
    'recordNumber',
    'pageNumber',
    'issuingCountry',
    'issuingDate',
    'nameOfDocument',
    'birthCertificateNumber',
    'otherIdNumber',
    'fatherIssuingCountry',
    'fatherIdType',
    'fatherNationalId',
    'fatherIdNumber',
    'fatherRecordNumber',
    'fatherPageNumber',
    'fatherIssuer',
    'fatherBirthCertificateNumber',
    'fatherIssuingDate',
    'fatherNameOfDocument',
    'fatherOtherIdNumber',
    'motherTongue',
    'studyLanguage',
    'maritalStatus',
    'bloodGroup',
    'religion',
    'homePhoneNumber',
    'economicLevel',
    'specialNeeds',
    'isCoveredBySocialWelfare',
    'stageId',
    'classRoomId',
    'addressCountry',
    'addressGovernorate',
    'addressDistrict',
    'town',
    'area',
    'quarter',
    'street',
    'address1',
    'address2',
    'closestLocation',
  ];

  /// بناء التسلسل الديناميكي للحقول المرئية لنظام التنقل المركزي بالكيبورد
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
      'dateOfBirth',
      'gender',
      'countryOfBirth',
      'nationality',
      'homeTown',
      'idType',
    ];

    if (_isNationalId) {
      seq.add('nationalId');
    } else if (_isCivilId) {
      seq.addAll([
        'idNumber',
        'jinsiyaIdNumber',
        'issuer',
        'recordNumber',
        'pageNumber',
        'issuingCountry',
        'issuingDate',
      ]);
    } else if (_isBirthCertificate) {
      seq.addAll([
        'birthCertificateNumber',
        'issuer',
        'issuingCountry',
        'issuingDate',
        'nameOfDocument',
      ]);
    } else if (_isOtherId) {
      seq.addAll([
        'otherIdNumber',
        'issuer',
        'issuingCountry',
        'issuingDate',
        'nameOfDocument',
      ]);
    }

    if (_includeFatherId) {
      seq.addAll([
        'fatherIssuingCountry',
        'fatherIdType',
      ]);
      if (_isFatherNationalId) {
        seq.add('fatherNationalId');
      } else if (_isFatherCivilId) {
        seq.addAll([
          'fatherIdNumber',
          'fatherRecordNumber',
          'fatherPageNumber',
          'fatherIssuer',
        ]);
      } else if (_isFatherBirthCertificate) {
        seq.addAll([
          'fatherBirthCertificateNumber',
          'fatherIssuingDate',
          'fatherRecordNumber',
          'fatherPageNumber',
        ]);
      } else if (_isFatherOtherId) {
        seq.addAll([
          'fatherNameOfDocument',
          'fatherOtherIdNumber',
        ]);
      }
    }

    seq.addAll([
      'motherTongue',
      'studyLanguage',
      'maritalStatus',
      'bloodGroup',
      'religion',
      'homePhoneNumber',
      'notes',
      'economicLevel',
      'specialNeeds',
      'isCoveredBySocialWelfare',
      'stageId',
      'classRoomId',
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
    ]);

    return seq;
  }

  bool _isDropdownAvailableForCentralNav(String key) {
    switch (key) {
      case 'stageId':
        return stages.isNotEmpty;
      case 'classRoomId':
        return rooms.isNotEmpty;
      case 'addressCountry':
        return _addressCountries.isNotEmpty;
      case 'addressGovernorate':
        return _addressGovernorates.isNotEmpty;
      case 'addressDistrict':
        return _addressDistricts.isNotEmpty;
      case 'addressTown':
        return _addressTowns.isNotEmpty;
      case 'isCoveredBySocialWelfare':
        return true;
      case 'fatherIdType':
        return _includeFatherId && (options['idType']?.isNotEmpty ?? false);
      case 'fatherIssuingCountry':
        return _includeFatherId &&
            ((options['issuingCountry']?.isNotEmpty ?? false) ||
                AppCore.defaultCountry.isNotEmpty);
      case 'studyLanguage':
        return (options['motherTongue']?.isNotEmpty ?? false) ||
            AppCore.defaultStudyLanguage.isNotEmpty;
      default:
        final list = options[key];
        final current = c[key]?.text.trim() ?? '';
        return (list != null && list.isNotEmpty) || current.isNotEmpty;
    }
  }

  Future<void> _waitForRoomsIfLoading() async {
    int attempts = 0;
    while (_loadingRoomsForStage && mounted && attempts < 25) {
      await Future<void>.delayed(const Duration(milliseconds: 60));
      attempts++;
    }
  }

  final labels = const <String, String>{
    'name': 'الإسم',
    'fatherName': 'إسم الأب',
    'grandFatherName': 'اسم والد الأب',
    'fathersGrandFatherName': 'اسم جد الأب',
    'surName': 'اللقب',
    'motherName': 'إسم الأم',
    'mothersFatherName': 'اسم والد الأم',
    'mothersGrandFatherName': 'اسم جد الأم',
    'nationalId': 'رقم البطاقة الوطنية الموحدة',
    'idNumber': 'رقم هوية الأحوال المدنية',
    'idType': 'نوع الهوية',
    'issuingCountry': 'بلد الإصدار',
    'dateOfBirth': 'تاريخ التولد',
    'gender': 'الجنس',
    'nationality': 'الجنسية',
    'countryOfBirth': 'بلد الولادة',
    'homeTown': 'مسقط الرأس',
    'motherTongue': 'اللغة الأم',
    'studyLanguage': 'لغة الدراسة',
    'maritalStatus': 'الحالة الاجتماعية',
    'bloodGroup': 'فئة الدم',
    'religion': 'الديانة',
    'economicLevel': 'المستوى المعيشي',
    'specialNeeds': 'الاحتياجات الخاصة',
    'notes': 'ملاحظات',
    'jinsiyaIdNumber': 'رقم شهادة الجنسية',
    'issuer': 'جهة الإصدار',
    'recordNumber': 'رقم السجل',
    'pageNumber': 'رقم الصحيفة',
    'issuingDate': 'تاريخ الإصدار',
    'nameOfDocument': 'نوع الوثيقة',
    'birthCertificateNumber': 'رقم شهادة الولادة',
    'otherIdNumber': 'رقم الهوية الأخرى',
    'fatherIdType': 'نوع هوية الأب',
    'fatherIssuingCountry': 'بلد إصدار هوية الأب',
    'fatherNationalId': 'رقم البطاقة الوطنية الموحدة للأب',
    'fatherIdNumber': 'رقم هوية الأحوال المدنية للأب',
    'fatherRecordNumber': 'رقم السجل لهوية الأب',
    'fatherPageNumber': 'رقم الصحيفة لهوية الأب',
    'fatherIssuer': 'جهة إصدار هوية الأب',
    'fatherBirthCertificateNumber': 'رقم شهادة الولادة للأب',
    'fatherIssuingDate': 'تاريخ إصدار هوية الأب',
    'fatherNameOfDocument': 'نوع وثيقة الأب',
    'fatherOtherIdNumber': 'رقم وثيقة الأب الأخرى',
    'town': 'المدينة / القرية',
    'area': 'الحي',
    'quarter': 'المحلة',
    'street': 'الزقاق',
    'address1': 'عنوان 1',
    'address2': 'عنوان 2',
    'closestLocation': 'أقرب نقطة دالة',
    'homePhoneNumber': 'رقم الهاتف',
    'addressCountry': 'الدولة',
    'addressGovernorate': 'المحافظة',
    'addressDistrict': 'القضاء',
    'addressTown': 'الناحية',
    'stageId': 'الصف الدراسي',
    'classRoomId': 'الشعبة',
    'isCoveredBySocialWelfare': 'مشمول بمنحة الرعاية الاجتماعية؟',
    'censusNumber': 'رقم الإحصاء',
  };

  Map<String, String> get h => {
        'Authorization': widget.token,
        'Accept': 'application/json',
        'Content-Type': 'application/json',
      };

  @override
  void initState() {
    super.initState();
    if (AppCore.kLocalAiBuildEnabled) {
      AiAssistantController.instance.onStudentDraftUpdated =
          _applyAiStudentValues;
    }
    _ambientController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 6),
    )..repeat();

    _centralNav = CentralKeyboardNavigator(
      sequenceBuilder: _buildCentralKeyboardSequence,
      onFieldFocused: _focusLive,
      shouldSkipField: AppCore.hasConfiguredDefaultForStudentField,
    );

    _voiceSequentialMode =
        AppCore.voiceInputEnabled && AppCore.voiceSequentialAutoStart;
    _voiceArrowLeft = AppCore.voiceArrowLeft;
    _voiceArrowTop = AppCore.voiceArrowTop;

    for (final key in [
      'name',
      'fatherName',
      'grandFatherName',
      'fathersGrandFatherName',
      'surName',
      'motherName',
      'mothersFatherName',
      'mothersGrandFatherName',
      'nationalId',
      'idNumber',
      'idType',
      'issuingCountry',
      'dateOfBirth',
      'gender',
      'nationality',
      'countryOfBirth',
      'homeTown',
      'motherTongue',
      'studyLanguage',
      'maritalStatus',
      'bloodGroup',
      'religion',
      'economicLevel',
      'specialNeeds',
      'notes',
      'jinsiyaIdNumber',
      'issuer',
      'recordNumber',
      'pageNumber',
      'issuingDate',
      'nameOfDocument',
      'birthCertificateNumber',
      'otherIdNumber',
      'fatherIdType',
      'fatherIssuingCountry',
      'fatherNationalId',
      'fatherIdNumber',
      'fatherRecordNumber',
      'fatherPageNumber',
      'fatherIssuer',
      'fatherBirthCertificateNumber',
      'fatherIssuingDate',
      'fatherNameOfDocument',
      'fatherOtherIdNumber',
      'town',
      'area',
      'quarter',
      'street',
      'address1',
      'address2',
      'closestLocation',
      'homePhoneNumber',
      'censusNumber',
    ]) {
      c[key] = TextEditingController();
    }

    _applyCurrentAppCoreDefaultsToControllers();

    _googleSpeechSubscription =
        GoogleSpeechService.events.listen(_handleGoogleSpeechEvent);
    _appCoreSettingsListener = () {
      if (mounted) setState(() {});
    };
    AppCore.voiceSettingsRevision.addListener(_appCoreSettingsListener!);

    _liveTimer =
        Timer.periodic(const Duration(milliseconds: 700), (_) => _pushLive());
    _load();
  }

  void _applyAiStudentValues(Map<String, String> values) {
    if (!mounted || saving) return;
    var changed = false;
    final allowed = labels.keys.toSet();
    for (final entry in values.entries) {
      if (!allowed.contains(entry.key)) continue;
      final controller = c[entry.key];
      final raw = entry.value.trim();
      if (controller == null || raw.isEmpty) continue;
      var value = raw;
      final availableOptions = options[entry.key];
      if (availableOptions != null && availableOptions.isNotEmpty) {
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
      } else if (_allDropdownNavFields.contains(entry.key)) {
        continue;
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

    final requestedStage = values['stageId']?.trim();
    if (requestedStage != null && requestedStage.isNotEmpty && stages.isNotEmpty) {
      final wanted = AiCommandParser.normalize(requestedStage);
      final match = stages.where((item) {
        final label = AiCommandParser.normalize(_text(item));
        return AiCommandParser.normalize(_value(item)) == wanted ||
            label == wanted || label.contains(wanted) || wanted.contains(label);
      }).toList();
      if (match.length == 1 && stageId != _value(match.first)) {
        unawaited(_stageChanged(_value(match.first)).then((_) {
          final requestedRoom = values['classRoomId']?.trim();
          if (!mounted || requestedRoom == null || requestedRoom.isEmpty) return;
          final roomLabel = AiCommandParser.normalize(requestedRoom);
          final roomMatches = rooms.where((item) {
            final label = AiCommandParser.normalize(_text(item));
            return AiCommandParser.normalize(_value(item)) == roomLabel ||
                label == roomLabel || label.contains(roomLabel) || roomLabel.contains(label);
          }).toList();
          if (roomMatches.length == 1) setState(() => roomId = _value(roomMatches.first));
        }));
        changed = true;
      }
    } else if (values['classRoomId'] != null && rooms.isNotEmpty) {
      final wanted = AiCommandParser.normalize(values['classRoomId']!);
      final matches = rooms.where((item) {
        final label = AiCommandParser.normalize(_text(item));
        return AiCommandParser.normalize(_value(item)) == wanted ||
            label == wanted || label.contains(wanted) || wanted.contains(label);
      }).toList();
      if (matches.length == 1 && roomId != _value(matches.first)) {
        roomId = _value(matches.first);
        changed = true;
      }
    }

    if (changed) {
      setState(() {
        _saveStatus = 'تم تحديث مسودة الطالب من المحادثة الصوتية. راجع البيانات قبل الحفظ.';
        _saveStatusIsError = false;
      });
      _pushLive();
    }
  }

  void _applyCurrentAppCoreDefaultsToControllers() {
    // Defaults are applied defensively: optional/dynamic form fields must never
    // crash the whole Add Student screen if a controller is absent.
    final defaults = <String, String>{
      'gender': AppCore.defaultGender,
      'nationality': AppCore.defaultCountry,
      'countryOfBirth': AppCore.defaultCountry,
      'issuingCountry': AppCore.defaultCountry,
      'idType': AppCore.defaultIdType,
      'fatherIssuingCountry': AppCore.defaultCountry,
      'fatherIdType': AppCore.defaultIdType,
      'studyLanguage': AppCore.defaultStudyLanguage,
      'motherTongue': AppCore.defaultMotherTongue,
      'bloodGroup': AppCore.defaultBloodGroup,
      'religion': AppCore.defaultReligion,
      'economicLevel': AppCore.defaultEconomicLevel,
      'address1': AppCore.defaultAddress1,
      'address2': AppCore.defaultAddress2,
      'closestLocation': AppCore.defaultClosestLocation,
      'town': AppCore.defaultTown,
      'area': AppCore.defaultArea,
      'homeTown': AppCore.defaultHomeTown,
    };
    for (final entry in defaults.entries) {
      final controller = c[entry.key];
      if (controller != null) controller.text = entry.value;
    }
  }

  @override
  void dispose() {
    if (AppCore.kLocalAiBuildEnabled &&
        AiAssistantController.instance.onStudentDraftUpdated != null) {
      AiAssistantController.instance.endStudentCreation();
    }
    _ambientController.dispose();
    _centralNav.dispose();
    _liveTimer?.cancel();
    unawaited(GoogleSpeechService.cancelListening());
    _googleSpeechSubscription?.cancel();
    if (_appCoreSettingsListener != null) {
      AppCore.voiceSettingsRevision.removeListener(_appCoreSettingsListener!);
      _appCoreSettingsListener = null;
    }
    _legacyFinalizationTimer?.cancel();
    _googleFinalizationTimer?.cancel();
    unawaited(LegacySpeechService.cancel());
    for (final controller in c.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Map<String, List<String>> _liveAliases() => {
        for (final entry in labels.entries)
          entry.key: <String>[entry.key, entry.value],
        'stageId': ['stageId', 'الصف الدراسي'],
        'classRoomId': ['classRoomId', 'الشعبة'],
        'addressCountry': ['addressCountry', 'الدولة', 'country'],
        'addressGovernorate': ['addressGovernorate', 'المحافظة', 'governorate'],
        'addressDistrict': ['addressDistrict', 'القضاء', 'district'],
        'countryStructureId': ['countryStructureId', 'الموقع الجغرافي'],
        'isCoveredBySocialWelfare': [
          'isCoveredBySocialWelfare',
          'مشمول بمنحة الرعاية الاجتماعية'
        ],
      };

  Map<String, String> _liveValues() => {
        for (final entry in c.entries) entry.key: entry.value.text,
        'stageId': stageId ?? '',
        'classRoomId': roomId ?? '',
        'addressCountry': _addressCountryId ?? '',
        'addressGovernorate': _addressGovernorateId ?? '',
        'addressDistrict': _addressDistrictId ?? '',
        'countryStructureId': _addressTownId ?? _addressDistrictId ?? '',
        'isCoveredBySocialWelfare': _socialWelfare ? 'true' : 'false',
      };

  void _pushLive() {
    if (saving) return;
    _liveSyncKey.currentState?.pushValues(_liveValues());
  }

  void _focusLive(String key) {
    _liveSyncKey.currentState?.focusField(key);
    _liveSyncKey.currentState?.pushValues(_liveValues());
  }

  void _applyLiveOptions(Map<String, List<dynamic>> incoming) {
    if (saving) return;
    bool changed = false;
    incoming.forEach((key, values) {
      if (values.isEmpty) return;
      final existing = options[key] ?? <dynamic>[];
      final merged = <dynamic>[
        ...existing.where((option) =>
            option is! Map || option['_liveOnly'] != true),
      ];
      for (final option in values) {
        if (option is! Map) continue;
        final value = option['value'] ??
            option['id'] ??
            option['displayName'] ??
            option['label'];
        final label = option['displayName'] ??
            option['label'] ??
            option['text'] ??
            value;
        if ('$value'.trim().isEmpty) continue;
        final alreadyExists = merged.any((item) {
          if (item is! Map) return false;
          return '${item['value'] ?? item['id'] ?? ''}' == '$value' ||
              '${item['displayName'] ?? item['label'] ?? ''}' == '$label';
        });
        if (!alreadyExists) {
          merged.add(<String, dynamic>{
            'value': value,
            'displayName': label,
            '_liveOnly': true,
          });
        }
      }
      options[key] = merged;
      changed = true;
    });
    if (changed && mounted) setState(() {});
  }

  void _applyLiveSnapshot(Map<String, String> values) {
    if (saving) return;
    bool changed = false;
    for (final entry in values.entries) {
      if (entry.value.trim().isEmpty) continue;
      final lastAiWrite = _aiFieldWriteTimes[entry.key];
      if (lastAiWrite != null &&
          DateTime.now().difference(lastAiWrite) <
              const Duration(seconds: 2)) {
        continue;
      }
      final controller = c[entry.key];
      if (controller != null && controller.text != entry.value) {
        controller.value = TextEditingValue(
          text: entry.value,
          selection: TextSelection.collapsed(offset: entry.value.length),
        );
        changed = true;
      }
    }
    if (values.containsKey('stageId') && stages.isNotEmpty) {
      final v = values['stageId']!;
      final match =
          stages.where((x) => _value(x) == v || _text(x) == v).toList();
      if (match.isNotEmpty && stageId != _value(match.first)) {
        _stageChanged(_value(match.first));
        changed = true;
      }
    }
    if (values.containsKey('classRoomId') && rooms.isNotEmpty) {
      final v = values['classRoomId']!;
      final match =
          rooms.where((x) => _value(x) == v || _text(x) == v).toList();
      if (match.isNotEmpty && roomId != _value(match.first)) {
        roomId = _value(match.first);
        changed = true;
      }
    }
    if (values.containsKey('addressCountry') && _addressCountries.isNotEmpty) {
      final v = values['addressCountry']!;
      final match = _addressCountries
          .where((x) => _value(x) == v || _text(x) == v)
          .toList();
      if (match.isNotEmpty) {
        _addressCountryId = _value(match.first);
        _setAddressGovernorates(match.first);
        changed = true;
      }
    }
    if (values.containsKey('addressGovernorate') &&
        _addressGovernorates.isNotEmpty) {
      final v = values['addressGovernorate']!;
      final match = _addressGovernorates
          .where((x) => _value(x) == v || _text(x) == v)
          .toList();
      if (match.isNotEmpty) {
        _addressGovernorateId = _value(match.first);
        _setAddressDistricts(match.first);
        changed = true;
      }
    }
    if (values.containsKey('isCoveredBySocialWelfare')) {
      final v = values['isCoveredBySocialWelfare']!.trim().toLowerCase();
      final next = v == 'true' || v == 'نعم' || v == 'yes';
      if (_socialWelfare != next) {
        _socialWelfare = next;
        changed = true;
      }
    }
    if (values.containsKey('addressDistrict') && _addressDistricts.isNotEmpty) {
      final v = values['addressDistrict']!;
      final match = _addressDistricts
          .where((x) => _value(x) == v || _text(x) == v)
          .toList();
      if (match.isNotEmpty) {
        _addressDistrictId = _value(match.first);
        _addressTowns = _children(match.first);
        _addressTownId = null;
        changed = true;
      }
    }
    if (changed && mounted) setState(() {});
  }

  dynamic _unwrap(dynamic value) =>
      value is Map && value['data'] != null ? value['data'] : value;

  Future<dynamic> _get(String endpoint) async {
    final response = await http
        .get(
          Uri.parse('https://emis.moedu.gov.iq/api$endpoint'),
          headers: h,
        )
        .timeout(
          const Duration(seconds: 15),
          onTimeout: () =>
              throw TimeoutException('انتهت مهلة الاتصال بخادم EMIS.'),
        );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
          'HTTP ${response.statusCode}: ${utf8.decode(response.bodyBytes)}');
    }
    return jsonDecode(utf8.decode(response.bodyBytes));
  }

  Future<List<dynamic>> _list(String endpoint) async {
    final raw = _unwrap(await _get(endpoint));
    if (raw is! List) return [];
    return [
      for (final item in raw)
        if (item is Map) Map<String, dynamic>.from(item),
    ];
  }

  String _value(Map<String, dynamic> x) =>
      '${x['value'] ?? x['id'] ?? x['code'] ?? ''}';

  String _text(Map<String, dynamic> x) =>
      '${x['displayName'] ?? x['label'] ?? x['name'] ?? x['text'] ?? _value(x)}';

  Future<void> _load() async {
    try {
      await AppCore.ensureLoaded();
      _voiceArrowLeft = AppCore.voiceArrowLeft;
      _voiceArrowTop = AppCore.voiceArrowTop;
      _applyCurrentAppCoreDefaultsToControllers();

      if (AppCore.cachedAvailableStages.isNotEmpty) {
        stages = AppCore.cachedAvailableStages;
      }

      final futures = <String, Future<List<dynamic>>>{};
      for (final e in endpoints.entries) {
        futures[e.key] = _list(e.value);
      }
      if (stages.isEmpty) {
        futures['stageId'] = _list(
          '/selectoption/getAvailableStagesForStudent?schoolId=${widget.schoolId}',
        );
      }

      final results = <String, List<dynamic>>{};
      for (final e in futures.entries) {
        results[e.key] = await e.value;
      }

      if (results.containsKey('stageId')) {
        stages = results.remove('stageId') ?? [];
      }
      AppCore.setAcademicStagesCache(stages: [
        for (final item in stages) Map<String, dynamic>.from(item),
      ]);
      options.addAll(results);
      options['fatherIdType'] =
          List<dynamic>.from(options['idType'] ?? const []);
      options['fatherIssuingCountry'] = List<dynamic>.from(
          options['issuingCountry'] ?? const []);

      await _loadAddressStructure();
      _applyDefaultAddressValues();
      options['nationality'] =
          List<dynamic>.from(options['countryOfBirth'] ?? const []);
      options['studyLanguage'] =
          List<dynamic>.from(options['motherTongue'] ?? const []);

      final genderItems = options['gender'] ?? const <dynamic>[];
      final targetGenderVal = AppCore.defaultGender;
      final targetGenderLabel = targetGenderVal == '2' ? 'أنثى' : 'ذكر';
      Map<String, dynamic>? matchedGender;
      for (final item in genderItems) {
        final label = _normalizeArabicForMatch(_text(item));
        if (_value(item) == targetGenderVal ||
            label == _normalizeArabicForMatch(targetGenderLabel) ||
            label.contains(_normalizeArabicForMatch(targetGenderLabel))) {
          matchedGender = item;
          break;
        }
      }
      if (matchedGender != null) {
        c['gender']!.text = _value(matchedGender);
      } else if (c['gender']!.text.trim().isEmpty) {
        c['gender']!.text = targetGenderVal;
      }

      // Apply the student-only academic defaults saved in Settings.
      // If no saved stage exists, preserve the previous first-stage fallback.
      if (stages.isNotEmpty && stageId == null) {
        final configuredStageId = AppCore.defaultStudentStageId.trim();
        if (configuredStageId.isEmpty &&
            AppCore.defaultStudentClassRoomId.isNotEmpty) {
          await AppCore.saveDefaultFieldValues(studentClassRoomId: '');
        }
        final configuredStage = stages.where((item) =>
            _value(item) == configuredStageId).toList();
        final selectedStageId = configuredStage.isNotEmpty
            ? configuredStageId
            : _value(stages.first);
        if (selectedStageId.isNotEmpty) {
          await _stageChanged(selectedStageId);
          if (configuredStage.isEmpty && configuredStageId.isNotEmpty) {
            await AppCore.saveDefaultFieldValues(
              studentStageId: '', studentClassRoomId: '');
          }
          final configuredRoomId = AppCore.defaultStudentClassRoomId.trim();
          if (configuredRoomId.isNotEmpty &&
              rooms.any((item) => _value(item) == configuredRoomId)) {
            roomId = configuredRoomId;
          } else if (configuredRoomId.isNotEmpty &&
              selectedStageId == configuredStageId) {
            await AppCore.saveDefaultFieldValues(studentClassRoomId: '');
          }
        }
      }

      if (!mounted) return;
      setState(() {
        loading = false;
        _voiceSequentialMode =
            AppCore.voiceInputEnabled && AppCore.voiceSequentialAutoStart;
      });
      if (AppCore.kLocalAiBuildEnabled) {
        final latestAiDraft =
            AiAssistantController.instance.studentDraft.isNotEmpty
                ? Map<String, String>.from(
                    AiAssistantController.instance.studentDraft)
                : widget.initialAiValues;
        _applyAiStudentValues(latestAiDraft);
      }

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            !saving &&
            AppCore.voiceInputEnabled &&
            AppCore.voiceSequentialAutoStart) {
          _startSequentialVoiceMode();
        }
      });
    } catch (e, stackTrace) {
      debugPrint('AddStudentScreen._load failed: $e');
      debugPrintStack(stackTrace: stackTrace);
      if (!mounted) return;
      setState(() {
        loading = false;
        error = '$e';
      });
    }
  }

  Future<void> _loadAddressStructure() async {
    try {
      final raw = _unwrap(await _get('/CountryStructure/getcountrystructure'));
      if (raw is! List) return;
      final nodes =
          raw.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
      if (nodes.isEmpty) return;

      _addressCountries = nodes;
      final targetCountry = AppCore.defaultCountry.trim();
      Map<String, dynamic>? selectedCountry;
      for (final item in nodes) {
        final name = _text(item);
        if ((targetCountry.isNotEmpty && name.contains(targetCountry)) ||
            name.contains('العراق') ||
            name.toLowerCase() == 'iraq') {
          selectedCountry = item;
          break;
        }
      }
      selectedCountry ??= nodes.first;
      _addressCountryId = _value(selectedCountry);
      _setAddressGovernorates(selectedCountry);
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('تعذر تحميل هيكل العنوان من EMIS: $e');
    }
  }

  List<dynamic> _children(Map<String, dynamic> node) {
    final raw =
        node['children'] ?? node['items'] ?? node['subItems'] ?? node['childs'];
    if (raw is! List) return [];
    return raw.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
  }

  void _applyDefaultAddressValues() {
    if (_addressGovernorates.isEmpty) return;

    final targetGov = AppCore.defaultGovernorate.trim();
    final targetDist = AppCore.defaultDistrict.trim();

    Map<String, dynamic>? governorate;
    for (final item in _addressGovernorates) {
      final name = _text(item).trim();
      if (targetGov.isNotEmpty &&
          (name == targetGov ||
              name.contains(targetGov) ||
              _normalizeArabicForMatch(name)
                  .contains(_normalizeArabicForMatch(targetGov)))) {
        governorate = item;
        break;
      }
    }
    if (governorate == null || governorate.isEmpty) return;

    _addressGovernorateId = _value(governorate);
    _setAddressDistricts(governorate);

    Map<String, dynamic>? district;
    for (final item in _addressDistricts) {
      final name = _text(item).trim();
      if (targetDist.isNotEmpty &&
          (name == targetDist ||
              name.contains(targetDist) ||
              _normalizeArabicForMatch(name)
                  .contains(_normalizeArabicForMatch(targetDist)))) {
        district = item;
        break;
      }
    }
    district ??= _addressDistricts.isNotEmpty ? _addressDistricts.first : null;
    if (district != null) {
      _addressDistrictId = _value(district);
      _addressTowns = _children(district);
      final subdistrict = _addressTowns
          .where((x) =>
              targetDist.isNotEmpty &&
              (_text(x).trim() == targetDist ||
                  _text(x).trim().contains(targetDist)))
          .toList();
      _addressTownId = subdistrict.isEmpty ? null : _value(subdistrict.first);
    }
    c['town']!.text = AppCore.defaultTown;
    c['area']!.text = AppCore.defaultArea;
  }

  void _setAddressGovernorates(Map<String, dynamic> country) {
    _addressGovernorates = _children(country);
    _addressGovernorateId = null;
    _addressDistricts = [];
    _addressDistrictId = null;
    _addressTowns = [];
    _addressTownId = null;
  }

  void _setAddressDistricts(Map<String, dynamic> governorate) {
    _addressDistricts = _children(governorate);
    _addressDistrictId = null;
    _addressTowns = [];
    _addressTownId = null;
  }

  void _setAddressTowns(Map<String, dynamic> district) {
    _addressTowns = _children(district);
    _addressTownId = null;
  }

  Future<void> _stageChanged(String? value) async {
    setState(() {
      stageId = value;
      roomId = null;
      rooms = [];
      stageDetails = null;
      _loadingRoomsForStage = value != null;
    });
    if (value == null) return;

    // A cache key may survive an older/partial cache refresh. Never use a
    // forced null assertion when reading optional cached API data.
    final cachedRooms = AppCore.cachedClassRoomsByStage[value];
    if (cachedRooms != null) {
      rooms = List<dynamic>.from(cachedRooms);
    }
    stageDetails = AppCore.cachedStageDetailsByStage[value];
    if (rooms.isNotEmpty) {
      _loadingRoomsForStage = false;
    }
    if (mounted) setState(() {});

    try {
      final result = await Future.wait([
        rooms.isEmpty
            ? _list(
                '/selectoption/getClassRooms?schoolId=${widget.schoolId}&stageId=$value')
            : Future.value(rooms),
        stageDetails == null
            ? _get('/selectoption/getstagedetails/$value')
            : Future.value(stageDetails),
      ]);
      if (!mounted) return;
      setState(() {
        rooms = result[0] as List<dynamic>;
        AppCore.setAcademicStagesCache(roomsByStage: {
          value: [for (final item in rooms) Map<String, dynamic>.from(item)],
        });
        final raw = _unwrap(result[1]);
        stageDetails =
            raw is Map ? Map<String, dynamic>.from(raw) : stageDetails;
        _loadingRoomsForStage = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _loadingRoomsForStage = false;
          error = '$e';
        });
      }
    }
  }

  bool get _isNationalId => c['idType']!.text == '12';
  bool get _isCivilId => c['idType']!.text == '3';
  bool get _isBirthCertificate => c['idType']!.text == '22';
  bool get _isOtherId => c['idType']!.text == '16';

  bool get _isFatherNationalId => c['fatherIdType']!.text == '12';
  bool get _isFatherCivilId => c['fatherIdType']!.text == '3';
  bool get _isFatherBirthCertificate => c['fatherIdType']!.text == '22';
  bool get _isFatherOtherId => c['fatherIdType']!.text == '16';

  void _showVoiceMessage(String message) {
    if (!mounted) return;
    setState(() => _speechError = message);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        backgroundColor: const Color(0xFFF97316),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    );
  }

  String _normalizeArabicForMatch(String value) {
    var out = value.toLowerCase().trim();
    out = out.replaceAll(RegExp(r'[\u064B-\u065F\u0670\u0640]'), '');
    out = out.replaceAll('أ', 'ا').replaceAll('إ', 'ا').replaceAll('آ', 'ا');
    out = out.replaceAll('ى', 'ي').replaceAll('ة', 'ه');
    out = out.replaceAll(RegExp(r'[^\u0600-\u06FFa-z0-9 ]'), ' ');
    out = out.replaceAll(RegExp(r'\s+'), ' ').trim();
    return out;
  }

  List<dynamic> _dropdownOptionsForVoice(String key) {
    final all = <dynamic>[];
    switch (key) {
      case 'stageId':
        all.addAll(stages);
        break;
      case 'classRoomId':
        all.addAll(rooms);
        break;
      case 'addressCountry':
        all.addAll(_addressCountries);
        break;
      case 'addressGovernorate':
        all.addAll(_addressGovernorates);
        break;
      case 'addressDistrict':
        all.addAll(_addressDistricts);
        break;
      case 'isCoveredBySocialWelfare':
        all.addAll(const [
          {'value': false, 'displayName': 'لا'},
          {'value': true, 'displayName': 'نعم'},
        ]);
        break;
      case 'fatherIdType':
        all.addAll(options['idType'] ?? []);
        break;
      case 'fatherIssuingCountry':
        all.addAll(options['issuingCountry'] ?? []);
        break;
      default:
        all.addAll(options[key] ?? []);
    }
    if (key == 'studyLanguage') {
      all.add({
        'value': AppCore.defaultStudyLanguage,
        'displayName': AppCore.defaultStudyLanguage
      });
    }
    final current = switch (key) {
      'stageId' => stageId ?? '',
      'classRoomId' => roomId ?? '',
      'addressCountry' => _addressCountryId ?? '',
      'addressGovernorate' => _addressGovernorateId ?? '',
      'addressDistrict' => _addressDistrictId ?? '',
      'isCoveredBySocialWelfare' => _socialWelfare.toString(),
      _ => c[key]?.text.trim() ?? '',
    };
    if (current.isNotEmpty && !all.any((item) => _value(item) == current)) {
      all.add({'value': current, 'displayName': current});
    }
    final seen = <String>{};
    return all.where((item) {
      final value = _value(item).trim();
      return value.isNotEmpty && seen.add(value);
    }).toList();
  }

  void _applyDropdownVoiceChoice(String key, Map<String, dynamic> item) {
    final value = _value(item);
    switch (key) {
      case 'stageId':
        unawaited(_stageChanged(value));
        break;
      case 'classRoomId':
        roomId = value;
        _focusLive('classRoomId');
        break;
      case 'addressCountry':
        _addressCountryId = value;
        _setAddressGovernorates(item);
        _focusLive('addressCountry');
        break;
      case 'addressGovernorate':
        _addressGovernorateId = value;
        _setAddressDistricts(item);
        _focusLive('addressGovernorate');
        break;
      case 'addressDistrict':
        _addressDistrictId = value;
        _focusLive('addressDistrict');
        break;
      case 'isCoveredBySocialWelfare':
        _socialWelfare = value == 'true' ||
            _normalizeArabicForMatch(_text(item)) ==
                _normalizeArabicForMatch('نعم');
        _focusLive('isCoveredBySocialWelfare');
        break;
      default:
        c[key]?.text = value;
        _focusLive(key);
    }
    _liveSyncKey.currentState?.pushValues(_liveValues());
    if (mounted) setState(() {});
  }

  Widget _dropdownVoiceMic(String key, {Color? accentColor}) {
    final active = _speechListening && _activeVoiceField == key;
    return ExcludeFocus(
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (_) => _markMicPointerDown(),
        child: IconButton(
          tooltip: 'اختيار ${labels[key] ?? key} بالصوت',
          onPressed: () => _startDropdownVoice(key),
          icon: Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: active
                  ? const Color(0xFFEF4444).withOpacity(0.18)
                  : (accentColor ?? const Color(0xFF3B82F6)).withOpacity(0.10),
            ),
            child: Icon(
              active ? Icons.mic_rounded : Icons.mic_none_rounded,
              size: 20,
              color: active
                  ? const Color(0xFFEF4444)
                  : (accentColor ?? const Color(0xFF3B82F6)),
            ),
          ),
        ),
      ),
    );
  }

  Map<String, dynamic>? _matchDropdownOption(String key, String spoken) {
    var target = _normalizeArabicForMatch(spoken);
    if (target.isEmpty) return null;
    target =
        target.replaceAll(RegExp(r'^(?:اختيار|القيمة|هي|هو)\s+'), '').trim();
    final items = _dropdownOptionsForVoice(key);
    if (items.isEmpty) return null;

    String compact(String value) => _normalizeArabicForMatch(value)
        .replaceAll(RegExp(r'\bال'), '')
        .replaceAll(' ', '');

    final exact = items.where((item) {
      final label = _normalizeArabicForMatch(_text(item));
      final value = _normalizeArabicForMatch(_value(item));
      return label == target ||
          value == target ||
          compact(label) == compact(target);
    }).toList();
    if (exact.length == 1) return exact.first;
    if (exact.length > 1) return exact.first;

    final targetTokens = target.split(' ').where((x) => x.length >= 2).toSet();
    if (targetTokens.isEmpty) return items.firstOrNull;

    int bestScore = 0;
    Map<String, dynamic>? best;
    for (final item in items) {
      final label = _normalizeArabicForMatch(_text(item));
      final value = _normalizeArabicForMatch(_value(item));
      if (label.isEmpty) continue;
      final labelCompact = compact(label);
      final targetCompact = compact(target);
      int score = 0;
      if (labelCompact.length >= 3 &&
          targetCompact.length >= 3 &&
          (labelCompact.contains(targetCompact) ||
              targetCompact.contains(labelCompact))) {
        score = 100 +
            (labelCompact.length < targetCompact.length
                ? labelCompact.length
                : targetCompact.length);
      } else {
        final tokens = label.split(' ').where((x) => x.length >= 2).toSet();
        final overlap = targetTokens.intersection(tokens).length;
        if (overlap > 0) {
          score = overlap * 10 + ((overlap == tokens.length) ? 3 : 0);
        }
        if (value.isNotEmpty && compact(value) == targetCompact) score += 100;
      }
      if (score > bestScore) {
        bestScore = score;
        best = item;
      }
    }
    return best ?? (items.isNotEmpty ? items.first : null);
  }

  void _applySpokenDate(String key, String parsedDate) {
    c[key]?.value = TextEditingValue(
      text: parsedDate,
      selection: TextSelection.collapsed(offset: parsedDate.length),
    );
    _liveSyncKey.currentState?.pushValues(_liveValues());
    if (mounted) setState(() {});
  }

  String? _dateForApi(String? raw) {
    final value = (raw ?? '').trim();
    if (value.isEmpty) return null;
    final iso = RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value);
    if (iso) return value;
    final display =
        RegExp(r'^(\d{1,2})[-/](\d{1,2})[-/](\d{4})$').firstMatch(value);
    if (display != null) {
      return '${display.group(3)}-${display.group(2)!.padLeft(2, '0')}-${display.group(1)!.padLeft(2, '0')}';
    }
    return value.replaceAll('/', '-');
  }

  bool _handleSpecialVoiceResult(String key, String raw,
      {required bool isFinal}) {
    if (_dropdownVoiceFields.contains(key)) {
      final matched = _matchDropdownOption(key, raw);
      if (matched == null) return true;
      _applyDropdownVoiceChoice(key, matched);
      _voiceDropdownTarget = null;
      _specialVoiceFailureShown = false;
      if (_voiceDropdownDialogOpen && mounted) {
        Navigator.of(context, rootNavigator: true).pop();
      }
      _requestSpeechStop();
      if (mounted) setState(() {});
      return true;
    }
    if (_dateVoiceFields.contains(key)) {
      final parsed = VoiceResultProcessor.resolveSpokenDate(raw, fieldKey: key);
      if (parsed == null) {
        if (isFinal && !_specialVoiceFailureShown) {
          _specialVoiceFailureShown = true;
          _showVoiceMessage(
              'يرجى نطق اليوم ثم الشهر ثم السنة بشكل واضح لتسجيل التاريخ.');
        }
        return true;
      }
      _specialVoiceFailureShown = false;
      _applySpokenDate(key, parsed);
      _requestSpeechStop();
      return true;
    }
    return false;
  }

  Future<void> _startDropdownVoice(String key) async {
    if (_activeVoiceField == key && _activeVoiceSessionId != null) {
      _voiceDropdownTarget = null;
      if (_voiceDropdownDialogOpen && mounted) {
        Navigator.of(context, rootNavigator: true).pop();
      }
      _requestSpeechStop();
      return;
    }
    if (!await _ensureMicrophoneAccess() || !mounted) return;
    final items = _dropdownOptionsForVoice(key);
    if (items.isEmpty) {
      _showVoiceMessage('لا توجد قيم متاحة في قائمة ${labels[key] ?? key}.');
      return;
    }
    _voiceDropdownTarget = key;
    _specialVoiceFailureShown = false;
    _voiceDropdownDialogOpen = true;
    final isDark = AppCore.themeNotifier.value == ThemeMode.dark;
    unawaited(showDialog<void>(
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
              color: const Color(0xFF10B981).withOpacity(0.45),
              width: 1.5,
            ),
          ),
          title: Text(
            'انطق قيمة ${labels[key] ?? key}',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: isDark ? Colors.white : const Color(0xFF0F172A),
              fontWeight: FontWeight.w900,
              fontSize: 17,
            ),
          ),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'انطق الاسم الكامل أو جزءاً منه.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: isDark
                        ? const Color(0xFF94A3B8)
                        : const Color(0xFF64748B),
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  height: 300,
                  child: ListView(
                    shrinkWrap: true,
                    children: items
                        .map(
                          (item) => ListTile(
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            title: Text(
                              _text(item),
                              textAlign: TextAlign.right,
                              style: TextStyle(
                                color: isDark
                                    ? Colors.white
                                    : const Color(0xFF0F172A),
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            onTap: () {
                              _applyDropdownVoiceChoice(key, item);
                              _voiceDropdownTarget = null;
                              _voiceDropdownDialogOpen = false;
                              Navigator.of(dialogContext).pop();
                              _requestSpeechStop();
                              if (mounted) setState(() {});
                            },
                          ),
                        )
                        .toList(),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text(
                'إلغاء',
                style: TextStyle(
                  color: Color(0xFFEF4444),
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
      ),
    ).then<void>((_) {
      _voiceDropdownDialogOpen = false;
      if (_voiceDropdownTarget == key) {
        _voiceDropdownTarget = null;
        if (_activeVoiceField == key) _requestSpeechStop();
      }
    }));
    await Future<void>.delayed(const Duration(milliseconds: 250));
    if (mounted && _voiceDropdownTarget == key) await _toggleVoiceInput(key);
  }

  bool get _voiceAvailableBySetting => AppCore.voiceInputEnabled;

  Future<bool> _ensureMicrophoneAccess() async {
    if (!_voiceAvailableBySetting) {
      _showVoiceMessage('الميكروفون مغلق من الإعدادات.');
      return false;
    }
    if (await ensureEmisMicrophonePermission()) return true;
    _showVoiceMessage('لم يتم منح صلاحية الميكروفون.');
    return false;
  }

  bool get _usingLegacyVoice => AppCore.voiceRecognitionEngine == 'legacy';

  Future<bool> _initLegacySpeech() async {
    if (_legacySpeechInitialized) return _legacySpeechAvailable;
    _legacySpeechAvailable = await LegacySpeechService.initialize(
      onStatus: (status) {
        if (!mounted || !_usingLegacyVoice) return;
        final listening = status == 'listening';
        if (listening) {
          setState(() => _speechListening = true);
          return;
        }
        if (_speechStopRequested) {
          _scheduleLegacyFinalization();
        } else if (_activeVoiceSessionId != null &&
            _activeVoiceField != null &&
            AppCore.voiceAutoRestart) {
          final currentField = _activeVoiceField!;
          final currentId = _activeVoiceSessionId!;
          Future<void>.delayed(
            Duration(milliseconds: AppCore.voiceRestartDelayMs),
            () {
              if (mounted &&
                  _usingLegacyVoice &&
                  !_speechStopRequested &&
                  _activeVoiceSessionId == currentId &&
                  _activeVoiceField == currentField) {
                _resumeLegacyListening(currentField, currentId);
              }
            },
          );
        } else if (_activeVoiceSessionId != null) {
          _scheduleLegacyFinalization();
        }
      },
      onError: (SpeechRecognitionError error) {
        if (!mounted || !_usingLegacyVoice) return;
        if (_speechStopRequested || !AppCore.voiceAutoRestart) {
          setState(() {
            _speechListening = false;
            _speechError = error.errorMsg;
          });
          _scheduleLegacyFinalization();
        }
      },
    );
    _legacySpeechInitialized = true;
    return _legacySpeechAvailable;
  }

  void _scheduleLegacyFinalization() {
    _legacyFinalizationTimer?.cancel();
    _legacyFinalizationTimer = Timer(const Duration(milliseconds: 350), () {
      if (!mounted || !_usingLegacyVoice) return;
      _finishLegacyVoiceSessionAndStartPending();
    });
  }

  Future<void> _finishLegacyVoiceSessionAndStartPending() async {
    _legacyFinalizationTimer?.cancel();
    _legacyFinalizationTimer = null;
    final pending = _pendingVoiceField;
    _pendingVoiceField = null;
    _speechStopRequested = false;
    _activeVoiceSessionId = null;
    _activeVoiceField = null;
    _accumulatedLegacyText = '';
    _accumulatedGoogleDigits = '';
    _accumulatedGoogleText = '';
    if (mounted) setState(() => _speechListening = false);
    if (pending != null && mounted && _usingLegacyVoice) {
      await Future<void>.delayed(const Duration(milliseconds: 80));
      if (mounted) await _startVoiceSession(pending);
    }
  }

  Future<void> _resumeLegacyListening(String key, int sessionId) async {
    if (!mounted || saving || _speechStopRequested) return;
    if (_activeVoiceSessionId != sessionId) return;
    try {
      await LegacySpeechService.listen(
        onResult: (dynamic result) => _onLegacyResult(key, sessionId, result),
      );
    } catch (_) {}
  }

  void _onLegacyResult(String key, int sessionId, dynamic result) {
    if (!mounted ||
        !_usingLegacyVoice ||
        _activeVoiceSessionId != sessionId) return;
    final raw = '${result.recognizedWords ?? ''}'.trim();
    if (raw.isEmpty) return;
    final isFinal = result.finalResult == true;

    if (_handleSpecialVoiceResult(key, raw, isFinal: isFinal)) {
      if (isFinal && _speechStopRequested) {
        _finishLegacyVoiceSessionAndStartPending();
      }
      return;
    }

    final isNumeric = _numericVoiceFields.contains(key);
    final previous = _accumulatedLegacyText;

    final segment = isNumeric ? AppCore.extractSpokenDigits(raw) : raw;
    if (segment.isEmpty) return;

    final fullText = isNumeric
        ? VoiceResultProcessor.resolveNumeric(
            segmentCandidates: [segment],
            fullCandidates: [raw],
            accumulated: previous,
            fieldKey: key,
          )
        : VoiceResultProcessor.resolveText(
            segmentCandidates: [segment],
            fullCandidates: [raw],
            accumulated: previous,
          );

    if (fullText.isEmpty) return;

    final controller = c[key];
    if (controller != null) {
      controller.value = TextEditingValue(
        text: fullText,
        selection: TextSelection.collapsed(offset: fullText.length),
      );
      _liveSyncKey.currentState?.pushValues(_liveValues());
    }

    if (isNumeric) {
      _accumulatedLegacyText = fullText;
      if (VoiceResultProcessor.shouldAutoStopForField(key, fullText)) {
        _requestLegacySpeechStop();
        return;
      }
    } else {
      _accumulatedLegacyText = fullText;
    }

    if (isFinal) {
      if (_speechStopRequested || !AppCore.voiceAutoRestart) {
        _finishLegacyVoiceSessionAndStartPending();
      }
    }
  }

  Future<void> _startLegacyVoiceSession(String key) async {
    if (!mounted || saving) return;
    final available = await _initLegacySpeech();
    if (!available || !mounted) return;

    final sessionId = ++_nextVoiceSessionId;
    _activeVoiceSessionId = sessionId;
    _activeVoiceField = key;
    _accumulatedLegacyText = '';
    _accumulatedGoogleDigits = '';
    _accumulatedGoogleText = '';
    _specialVoiceFailureShown = false;
    _scrollVoiceFieldIntoView(key);
    _speechStopRequested = false;
    if (mounted) {
      setState(() {
        _speechError = null;
        _speechListening = true;
      });
    }

    try {
      await LegacySpeechService.listen(
        onResult: (dynamic result) => _onLegacyResult(key, sessionId, result),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _speechError = '$e');
      _scheduleLegacyFinalization();
    }
  }

  void _requestLegacySpeechStop({String? nextField}) {
    if (nextField != null) _pendingVoiceField = nextField;
    if (_activeVoiceSessionId == null) return;
    if (_speechStopRequested) return;
    _speechStopRequested = true;
    if (mounted) setState(() => _speechListening = false);
    unawaited(
        LegacySpeechService.stop().whenComplete(_scheduleLegacyFinalization));
  }

  void _scheduleGoogleFinalizationFallback() {
    _googleFinalizationTimer?.cancel();
    _googleFinalizationTimer =
        Timer(Duration(milliseconds: AppCore.voiceFinalizationTimeoutMs), () {
      if (!mounted || _usingLegacyVoice) return;
      if (_activeVoiceSessionId != null && _speechStopRequested) {
        _finishVoiceSessionAndStartPending();
      }
    });
  }

  void _handleGoogleSpeechEvent(Map<String, dynamic> event) {
    if (!mounted) return;
    final sessionId = int.tryParse('${event['sessionId'] ?? ''}');
    if (sessionId == null || sessionId != _activeVoiceSessionId) return;

    final type = '${event['type'] ?? ''}';
    final key = _activeVoiceField;
    if (key == null) return;

    if (type == 'listening' ||
        type == 'ready' ||
        type == 'begin' ||
        type == 'partial') {
      if (!_speechListening && !_speechStopRequested) {
        setState(() => _speechListening = true);
      }
    }

    if (type == 'partial' || type == 'result') {
      final alternates = (event['alternates'] is List)
          ? (event['alternates'] as List).map((e) => '$e').toList()
          : <String>[];
      final segmentAlternates = (event['segmentAlternates'] is List)
          ? (event['segmentAlternates'] as List).map((e) => '$e').toList()
          : <String>[];
      final eventText = '${event['text'] ?? ''}'.trim();
      final segment = '${event['segment'] ?? ''}'.trim();

      final fullCandidates = <String>[
        if (eventText.isNotEmpty) eventText,
        ...alternates,
        if (segment.isNotEmpty) segment,
      ].map((e) => e.trim()).where((e) => e.isNotEmpty).toList();

      if (_dropdownVoiceFields.contains(key) ||
          _dateVoiceFields.contains(key)) {
        if (fullCandidates.isNotEmpty) {
          for (final candidate in fullCandidates) {
            if (_handleSpecialVoiceResult(key, candidate,
                isFinal: type == 'result')) {
              break;
            }
          }
        }
        if (type == 'result' && _speechStopRequested) {
          _finishVoiceSessionAndStartPending();
        }
        return;
      }

      String text = '';
      if (_numericVoiceFields.contains(key)) {
        final currentSegmentCandidates = <String>[
          if (segment.isNotEmpty) segment,
          ...segmentAlternates,
        ].map((e) => e.trim()).where((e) => e.isNotEmpty).toList();

        text = VoiceResultProcessor.resolveNumeric(
          segmentCandidates: currentSegmentCandidates,
          fullCandidates: fullCandidates,
          accumulated: _accumulatedGoogleDigits,
          fieldKey: key,
        );

        if (text.isNotEmpty) {
          _accumulatedGoogleDigits = text;
        }

        if (VoiceResultProcessor.shouldAutoStopForField(key, text)) {
          _requestSpeechStop();
        }
      } else {
        final currentSegmentCandidates = <String>[
          if (segment.isNotEmpty) segment,
          ...segmentAlternates,
        ].map((e) => e.trim()).where((e) => e.isNotEmpty).toList();

        text = VoiceResultProcessor.resolveText(
          segmentCandidates: currentSegmentCandidates,
          fullCandidates: fullCandidates,
          accumulated: _accumulatedGoogleText,
        );

        if (text.isNotEmpty) {
          _accumulatedGoogleText = text;
        }
      }

      if (text.isNotEmpty) {
        final controller = c[key];
        if (controller != null) {
          controller.value = TextEditingValue(
            text: text,
            selection: TextSelection.collapsed(offset: text.length),
          );
          _liveSyncKey.currentState?.pushValues(_liveValues());
        }
      }
    }

    if (type == 'error') {
      final message = '${event['message'] ?? ''}'.trim();
      final code = event['code'];
      if (message.isNotEmpty && code != 7 && code != 6) {
        setState(() => _speechError = message);
      }
      if (_speechStopRequested) {
        _finishVoiceSessionAndStartPending();
      }
      return;
    }

    if (type == 'result') {
      if (_speechStopRequested) {
        _finishVoiceSessionAndStartPending();
      }
    }

    if (type == 'stopped') {
      if (_speechStopRequested || !AppCore.voiceAutoRestart) {
        _finishVoiceSessionAndStartPending();
      }
    }
  }

  Future<void> _startVoiceSession(String key) async {
    if (!mounted || saving) return;
    if (!await _ensureMicrophoneAccess()) return;
    if (_usingLegacyVoice) {
      await _startLegacyVoiceSession(key);
      return;
    }

    final info = await GoogleSpeechService.getInfo();
    if (info['available'] != true) {
      _showVoiceMessage('خدمة Google للتعرف على الكلام غير متوفرة.');
      return;
    }

    final sessionId = ++_nextVoiceSessionId;
    _activeVoiceSessionId = sessionId;
    _activeVoiceField = key;
    _accumulatedGoogleDigits = '';
    _accumulatedGoogleText = '';
    _specialVoiceFailureShown = false;
    _scrollVoiceFieldIntoView(key);
    _speechStopRequested = false;
    if (mounted) {
      setState(() {
        _speechError = null;
        _speechListening = true;
      });
    }

    final started = await GoogleSpeechService.startListening(
      sessionId: sessionId,
      locale: 'ar-IQ',
    );
    if (!started && mounted && _activeVoiceSessionId == sessionId) {
      setState(() => _speechListening = false);
    }
  }

  void _requestSpeechStop({String? nextField}) {
    if (_usingLegacyVoice) {
      _requestLegacySpeechStop(nextField: nextField);
      return;
    }
    if (nextField != null) _pendingVoiceField = nextField;
    if (_activeVoiceSessionId == null) {
      final pending = _pendingVoiceField;
      if (pending != null) {
        _pendingVoiceField = null;
        _startVoiceSession(pending);
      }
      return;
    }
    if (_speechStopRequested) return;

    _speechStopRequested = true;
    setState(() => _speechListening = false);
    _scheduleGoogleFinalizationFallback();
    unawaited(GoogleSpeechService.stopListening());
  }

  Future<void> _finishVoiceSessionAndStartPending() async {
    _googleFinalizationTimer?.cancel();
    _googleFinalizationTimer = null;
    final pending = _pendingVoiceField;
    _pendingVoiceField = null;
    _speechStopRequested = false;
    _activeVoiceSessionId = null;
    _activeVoiceField = null;
    _accumulatedLegacyText = '';
    _accumulatedGoogleDigits = '';
    _accumulatedGoogleText = '';
    if (mounted) setState(() => _speechListening = false);

    if (pending != null && mounted) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      if (mounted) await _startVoiceSession(pending);
    }
  }

  void _stopVoiceFromPointer() {
    if (_voiceArrowPointerDown || _micPointerDown) {
      _voiceArrowPointerDown = false;
      _micPointerDown = false;
      return;
    }
    if (_voiceSequentialMode) return;
    if (_activeVoiceSessionId != null) {
      _pendingVoiceField = null;
      _requestSpeechStop();
    }
  }

  void _markMicPointerDown() {
    _micPointerDown = true;
    Future<void>.microtask(() => _micPointerDown = false);
  }

  bool _isVoiceFieldCurrentlyVisible(String key) {
    if (!_voiceFields.contains(key) &&
        !_numericVoiceFields.contains(key) &&
        !_dropdownVoiceFields.contains(key) &&
        !_dateVoiceFields.contains(key)) return false;
    if (key == 'nationalId') return _isNationalId;
    if (key == 'idNumber' ||
        key == 'jinsiyaIdNumber' ||
        key == 'recordNumber' ||
        key == 'pageNumber') return _isCivilId;
    if (key == 'birthCertificateNumber') return _isBirthCertificate;
    if (key == 'otherIdNumber') return _isOtherId;
    if (key == 'nameOfDocument') {
      return _isBirthCertificate || _isOtherId || _isCivilId;
    }
    if (key == 'issuingDate' ||
        key == 'issuingCountry' ||
        key == 'issuer' ||
        key == 'recordNumber' ||
        key == 'pageNumber' ||
        key == 'jinsiyaIdNumber' ||
        key == 'nameOfDocument') {
      return _isCivilId || _isBirthCertificate || _isOtherId;
    }

    if (key.startsWith('father') &&
        key != 'fatherName' &&
        key != 'fathersGrandFatherName') {
      if (!_includeFatherId) return false;
      if (key == 'fatherIssuingCountry' || key == 'fatherIdType') return true;
      if (key == 'fatherNationalId') return _isFatherNationalId;
      if (key == 'fatherIdNumber' || key == 'fatherIssuer') {
        return _isFatherCivilId;
      }
      if (key == 'fatherRecordNumber' || key == 'fatherPageNumber') {
        return _isFatherCivilId || _isFatherBirthCertificate;
      }
      if (key == 'fatherBirthCertificateNumber' || key == 'fatherIssuingDate') {
        return _isFatherBirthCertificate;
      }
      if (key == 'fatherNameOfDocument' || key == 'fatherOtherIdNumber') {
        return _isFatherOtherId;
      }
      return false;
    }

    if (key == 'stageId') return stages.isNotEmpty;
    if (key == 'classRoomId') return rooms.isNotEmpty;
    if (key == 'addressCountry') return _addressCountries.isNotEmpty;
    if (key == 'addressGovernorate') return _addressGovernorates.isNotEmpty;
    if (key == 'addressDistrict') return _addressDistricts.isNotEmpty;
    return c.containsKey(key) || key == 'isCoveredBySocialWelfare';
  }

  List<String> _currentVoiceSequence() => _voiceSequentialOrder
      .where(_isVoiceFieldCurrentlyVisible)
      .toList(growable: false);

  Future<void> _startSequentialVoiceMode() async {
    if (saving || !AppCore.voiceInputEnabled) return;
    if (!await _ensureMicrophoneAccess()) {
      if (mounted) setState(() => _voiceSequentialMode = false);
      return;
    }
    final sequence = _currentVoiceSequence();
    if (sequence.isEmpty) return;
    setState(() {
      _voiceSequentialMode = true;
      _sequentialVoiceIndex = 0;
    });
    await _startVoiceSession(sequence.first);
  }

  void _stopSequentialVoiceMode() {
    if (!_voiceSequentialMode) return;
    setState(() => _voiceSequentialMode = false);
    _pendingVoiceField = null;
    if (_activeVoiceSessionId != null) _requestSpeechStop();
  }

  Future<void> _activateSequentialVoiceField(String key) async {
    if (_dropdownVoiceFields.contains(key)) {
      await _startDropdownVoice(key);
      return;
    }
    if (_activeVoiceSessionId != null) {
      _pendingVoiceField = key;
      _requestSpeechStop(nextField: key);
    } else {
      await _startVoiceSession(key);
    }
  }

  Future<void> _advanceSequentialVoice() async {
    if (!_voiceSequentialMode || saving) return;
    final sequence = _currentVoiceSequence();
    if (sequence.isEmpty) return;
    var index = _sequentialVoiceIndex;
    if (index >= sequence.length - 1) return;
    final nextIndex = index + 1;
    setState(() => _sequentialVoiceIndex = nextIndex);
    await _activateSequentialVoiceField(sequence[nextIndex]);
  }

  Future<void> _retreatSequentialVoice() async {
    if (!_voiceSequentialMode || saving) return;
    final sequence = _currentVoiceSequence();
    if (sequence.isEmpty) return;
    var index = _sequentialVoiceIndex;
    if (index <= 0) return;
    final previousIndex = index - 1;
    setState(() => _sequentialVoiceIndex = previousIndex);
    await _activateSequentialVoiceField(sequence[previousIndex]);
  }

  void _markVoiceArrowPointerDown() {
    _voiceArrowPointerDown = true;
    Future<void>.microtask(() => _voiceArrowPointerDown = false);
  }

  Future<void> _toggleSequentialModeFromButton() async {
    if (_voiceSequentialMode) {
      _stopSequentialVoiceMode();
    } else {
      await _startSequentialVoiceMode();
    }
  }

  Widget _sequentialVoiceControl(bool isDark) {
    final enabled = _voiceSequentialMode;
    const emeraldNeon = Color(0xFF10B981);
    const goldNeon = Color(0xFFF59E0B);
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final mutedColor =
        isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);

    return ExcludeFocus(
      child: Container(
        margin: const EdgeInsets.only(top: 12, bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          gradient: isDark
              ? LinearGradient(
                  colors: [
                    const Color(0xFF141829).withOpacity(0.95),
                    Color.lerp(const Color(0xFF0F1322), emeraldNeon, 0.10)!,
                  ],
                )
              : LinearGradient(
                  colors: [
                    Colors.white,
                    Color.lerp(const Color(0xFFF8FAFC), emeraldNeon, 0.05)!,
                  ],
                ),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(
            color: (enabled ? emeraldNeon : goldNeon)
                .withOpacity(isDark ? 0.45 : 0.32),
            width: 1.4,
          ),
          boxShadow: [
            BoxShadow(
              color: (enabled ? emeraldNeon : goldNeon)
                  .withOpacity(isDark ? 0.14 : 0.08),
              blurRadius: 18,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Column(
          children: [
            Row(
              children: [
                _AnimatedStudentOrbIcon(
                  icon: enabled
                      ? Icons.keyboard_double_arrow_down_rounded
                      : Icons.mic_none_rounded,
                  primaryColor: enabled ? emeraldNeon : goldNeon,
                  secondaryColor: const Color(0xFF3B82F6),
                  animation: _ambientController,
                  size: 52,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'التنقل الصوتي بين الحقول',
                        style: TextStyle(
                          fontWeight: FontWeight.w900,
                          fontSize: 15,
                          color: textColor,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        _activeVoiceField != null
                            ? 'الحقل النشط: ${labels[_activeVoiceField!] ?? _activeVoiceField!}'
                            : 'عند التفعيل يظهر سهمان للتنقل الصوتي السريع بين الحقول.',
                        style: TextStyle(
                          color: _activeVoiceField != null
                              ? emeraldNeon
                              : mutedColor,
                          fontWeight: FontWeight.w700,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                Switch.adaptive(
                  value: enabled,
                  activeColor: emeraldNeon,
                  onChanged: (_) => _toggleSequentialModeFromButton(),
                ),
              ],
            ),
            if (enabled || _speechListening) ...[
              const SizedBox(height: 10),
              SizedBox(
                height: 28,
                width: double.infinity,
                child: AnimatedBuilder(
                  animation: _ambientController,
                  builder: (context, _) {
                    return CustomPaint(
                      painter: _StudentWavePainter(
                        phase: _ambientController.value * 2 * math.pi,
                        color: _speechListening
                            ? const Color(0xFFEF4444)
                            : emeraldNeon,
                        isDark: isDark,
                      ),
                    );
                  },
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _fixedSequentialArrow(bool isDark) {
    if (!_voiceSequentialMode) return const SizedBox.shrink();
    final sequence = _currentVoiceSequence();
    final atFirst = _sequentialVoiceIndex <= 0 || sequence.isEmpty;
    final atLast =
        sequence.isEmpty || _sequentialVoiceIndex >= sequence.length - 1;

    final media = MediaQuery.of(context);
    final maxWidth = media.size.width - 62;
    final maxHeight =
        media.size.height - media.padding.top - kToolbarHeight - 165;
    final currentTop = (_voiceArrowTop ?? media.size.height * 0.32)
        .clamp(8.0, maxHeight > 8.0 ? maxHeight : 8.0)
        .toDouble();
    final currentLeft = _voiceArrowLeft
        .clamp(0.0, maxWidth > 0.0 ? maxWidth : 0.0)
        .toDouble();

    final isDockedLeft = currentLeft <= 4.0;
    final isDockedRight = currentLeft >= maxWidth - 4.0;
    final borderRadius = isDockedLeft
        ? const BorderRadius.horizontal(right: Radius.circular(24))
        : (isDockedRight
            ? const BorderRadius.horizontal(left: Radius.circular(24))
            : BorderRadius.circular(24));

    const emeraldNeon = Color(0xFF10B981);

    Widget arrowButton({
      required IconData icon,
      required VoidCallback? onTap,
      required bool disabled,
      required String tooltip,
    }) {
      return Tooltip(
        message: tooltip,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: disabled ? null : onTap,
            child: SizedBox(
              width: 58,
              height: 62,
              child: Icon(
                icon,
                size: 48,
                color: disabled
                    ? (isDark ? Colors.white24 : Colors.grey.shade400)
                    : emeraldNeon,
              ),
            ),
          ),
        ),
      );
    }

    return Positioned(
      left: currentLeft,
      top: currentTop,
      child: ExcludeFocus(
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (_) => _markVoiceArrowPointerDown(),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: (_) => _markVoiceArrowPointerDown(),
            onPanUpdate: (details) {
              _markVoiceArrowPointerDown();
              setState(() {
                _voiceArrowLeft = (currentLeft + details.delta.dx)
                    .clamp(0.0, maxWidth > 0.0 ? maxWidth : 0.0)
                    .toDouble();
                _voiceArrowTop = (currentTop + details.delta.dy)
                    .clamp(8.0, maxHeight > 8.0 ? maxHeight : 8.0)
                    .toDouble();
              });
            },
            onPanEnd: (_) {
              AppCore.saveVoiceSettings(
                arrowLeft: _voiceArrowLeft,
                arrowTop: _voiceArrowTop,
              );
            },
            child: Material(
              color: Colors.transparent,
              child: Container(
                width: 62,
                padding: const EdgeInsets.symmetric(vertical: 4),
                decoration: BoxDecoration(
                  color: (isDark ? const Color(0xFF141829) : Colors.white)
                      .withOpacity(AppCore.voiceArrowOpacity.clamp(0.45, 0.95)),
                  borderRadius: borderRadius,
                  boxShadow: [
                    BoxShadow(
                      blurRadius: 16,
                      offset: const Offset(0, 4),
                      color: emeraldNeon.withOpacity(0.28),
                    )
                  ],
                  border: Border.all(color: emeraldNeon, width: 1.8),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    arrowButton(
                      icon: Icons.keyboard_arrow_up_rounded,
                      onTap: _retreatSequentialVoice,
                      disabled: atFirst,
                      tooltip: 'السابق',
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Icon(
                        Icons.drag_indicator_rounded,
                        size: 18,
                        color: emeraldNeon.withOpacity(0.75),
                      ),
                    ),
                    arrowButton(
                      icon: Icons.keyboard_arrow_down_rounded,
                      onTap: _advanceSequentialVoice,
                      disabled: atLast,
                      tooltip: 'التالي',
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _toggleVoiceInput(String key) async {
    if (saving) return;
    if (!_voiceAvailableBySetting) {
      _showVoiceMessage('الميكروفون مغلق من الإعدادات.');
      return;
    }
    if (_activeVoiceField == key && _activeVoiceSessionId != null) {
      _pendingVoiceField = null;
      _requestSpeechStop();
      return;
    }
    if (_activeVoiceSessionId != null) {
      _pendingVoiceField = key;
      _requestSpeechStop(nextField: key);
      return;
    }
    await _startVoiceSession(key);
  }

  void _onDateTextChanged(String key, String value) {
    final clean =
        AppCore.normalizeDigitsOnly(value).replaceAll(RegExp(r'[^\d]'), '');
    final limited = clean.length > 8 ? clean.substring(0, 8) : clean;
    var formatted =
        limited.substring(0, limited.length >= 4 ? 4 : limited.length);
    if (limited.length > 4) {
      formatted +=
          '-${limited.substring(4, limited.length >= 6 ? 6 : limited.length)}';
    }
    if (limited.length > 6) formatted += '-${limited.substring(6)}';
    if (formatted != value) {
      c[key]?.value = TextEditingValue(
          text: formatted,
          selection: TextSelection.collapsed(offset: formatted.length));
    }
    _liveSyncKey.currentState?.pushValues(_liveValues());
  }

  Widget _textField(
    String key, {
    bool required = false,
    int maxLines = 1,
    TextInputType? keyboard,
    Color accentColor = const Color(0xFF3B82F6),
  }) {
    final isDark = AppCore.themeNotifier.value == ThemeMode.dark;
    final isDate = _dateVoiceFields.contains(key);
    final isActiveVoice = _speechListening && _activeVoiceField == key;
    final effectiveAccent =
        isActiveVoice ? const Color(0xFFEF4444) : accentColor;
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
      maxLines: maxLines,
      keyboardType: effectiveKeyboard,
      textInputAction:
          centralEnabled ? TextInputAction.next : TextInputAction.done,
      inputFormatters: [
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
      style: TextStyle(
        fontWeight: FontWeight.w800,
        fontSize: 14,
        color: isDark ? Colors.white : const Color(0xFF0F172A),
      ),
      textDirection: TextDirection.rtl,
      onChanged: (val) {
        if (isDate) {
          _onDateTextChanged(key, val);
        } else {
          _liveSyncKey.currentState?.pushValues(_liveValues());
        }
      },
      onTap: () => _focusLive(key),
      decoration: _decoration(
        labels[key] ?? key,
        isDark: isDark,
        accentColor: effectiveAccent,
        isActiveVoice: isActiveVoice,
      ).copyWith(
        suffixIcon: (_voiceFields.contains(key) ||
                _numericVoiceFields.contains(key) ||
                isDate)
            ? ExcludeFocus(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Listener(
                      behavior: HitTestBehavior.opaque,
                      onPointerDown: (_) => _markMicPointerDown(),
                      child: IconButton(
                        tooltip: 'الإدخال الصوتي',
                        onPressed: () => _toggleVoiceInput(key),
                        icon: Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: isActiveVoice
                                ? const Color(0xFFEF4444).withOpacity(0.18)
                                : accentColor.withOpacity(0.12),
                          ),
                          child: Icon(
                            isActiveVoice
                                ? Icons.mic_rounded
                                : Icons.mic_none_rounded,
                            size: 20,
                            color: isActiveVoice
                                ? const Color(0xFFEF4444)
                                : accentColor,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              )
            : null,
      ),
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
        gradient: isDark
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

  void _setSaveStatus(String message, {bool isError = false}) {
    if (!mounted) return;
    setState(() {
      _saveStatus = message;
      _saveStatusIsError = isError;
    });
  }

  void _showSaveMessage(String message, {required bool isError}) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          message,
          textDirection: TextDirection.rtl,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        backgroundColor:
            isError ? const Color(0xFFEF4444) : const Color(0xFF10B981),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    );
  }

  Map<String, dynamic>? _buildFatherIdentificationPayload() {
    if (!_includeFatherId) return null;
    final fatherIdType = int.tryParse(c['fatherIdType']!.text) ??
        int.tryParse(AppCore.defaultIdType);
    if (fatherIdType == null) return null;

    final fatherIdentificationNumber = _isFatherNationalId
        ? AppCore.normalizeDigitsOnly(_n('fatherNationalId') ?? '')
        : (_isFatherCivilId
            ? (_n('fatherIdNumber') ?? '')
            : (_isFatherBirthCertificate
                ? (_n('fatherBirthCertificateNumber') ?? '')
                : (_isFatherOtherId ? (_n('fatherOtherIdNumber') ?? '') : '')));

    return {
      'idNumber': fatherIdentificationNumber,
      'issuingCountry': _n('fatherIssuingCountry') ?? AppCore.defaultCountry,
      'idType': fatherIdType,
      'nameOfDocument': _n('fatherNameOfDocument') ?? '',
      'recordNumber': _n('fatherRecordNumber') ?? '',
      'pageNumber': _n('fatherPageNumber') ?? '',
      'issuer': _n('fatherIssuer') ?? '',
      'issuingDate': _dateForApi(_n('fatherIssuingDate')),
    };
  }

  Future<void> _stopActiveVoiceForSave() async {
    // لا تسمح بانتقال الميكروفون إلى حقل آخر أثناء تجهيز عملية الحفظ.
    _pendingVoiceField = null;
    if (_activeVoiceSessionId == null) return;

    _speechStopRequested = true;
    if (mounted) setState(() => _speechListening = false);

    try {
      if (_usingLegacyVoice) {
        await LegacySpeechService.stop();
        _scheduleLegacyFinalization();
      } else {
        await GoogleSpeechService.stopListening();
        _scheduleGoogleFinalizationFallback();
      }
    } catch (_) {
      // تتم متابعة الإنهاء محلياً حتى لا يتعطل الحفظ بسبب خطأ في خدمة الصوت.
    }

    // انتظر وصول حدث الإنهاء الطبيعي كي لا نفقد آخر نتيجة صوتية.
    for (var attempt = 0;
        attempt < 25 && _activeVoiceSessionId != null && mounted;
        attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }

    // احتياطاً، أنهِ الجلسة إذا لم ترسل خدمة الصوت حدث الإنهاء.
    if (_activeVoiceSessionId != null && mounted) {
      _pendingVoiceField = null;
      if (_usingLegacyVoice) {
        await _finishLegacyVoiceSessionAndStartPending();
      } else {
        await _finishVoiceSessionAndStartPending();
      }
    }
  }

  Future<void> _save({bool addAnother = false}) async {
    if (saving) return;
    try {
      if (!mounted) return;
      setState(() {
        saving = true;
        error = null;
        _saveStatus = 'جارٍ إيقاف الميكروفون وتجهيز الحفظ...';
        _saveStatusIsError = false;
      });

      await _stopActiveVoiceForSave();
      if (!mounted) return;
      setState(() {
        _saveStatus = 'بدأت عملية حفظ الطالب...';
      });
      FocusScope.of(context).unfocus();

      final validationError = _validateBeforeSave();
      if (validationError != null) throw Exception(validationError);

      _setSaveStatus('جاري التحقق من البيانات...', isError: false);
      final idType = int.tryParse(c['idType']!.text) ??
          int.tryParse(AppCore.defaultIdType) ??
          12;
      final identificationNumber = _isNationalId
          ? AppCore.normalizeDigitsOnly(_n('nationalId') ?? '')
          : (_isCivilId
              ? (_n('idNumber') ?? '')
              : (_isBirthCertificate
                  ? (_n('birthCertificateNumber') ?? '')
                  : (_isOtherId ? (_n('otherIdNumber') ?? '') : '')));

      if (_isNationalId) {
        final check = await _get(
            '/student/checknationalidnumber?value=${Uri.encodeQueryComponent(identificationNumber)}');
        if (check is Map && check['isUnique'] == false) {
          throw Exception('رقم البطاقة الوطنية مستخدم مسبقاً في EMIS');
        }
      }

      final payload = <String, dynamic>{
        'name': _n('name') ?? '',
        'fatherName': _n('fatherName') ?? '',
        'grandFatherName': _n('grandFatherName') ?? '',
        'fathersGrandFatherName': _n('fathersGrandFatherName') ?? '',
        'surName': _n('surName') ?? '',
        'motherName': _n('motherName') ?? '',
        'mothersFatherName': _n('mothersFatherName') ?? '',
        'mothersGrandFatherName': _n('mothersGrandFatherName') ?? '',
        'imageUrl': '',
        'dateOfBirth': _dateForApi(_n('dateOfBirth')),
        'gender': int.tryParse(c['gender']!.text) ??
            int.tryParse(AppCore.defaultGender) ??
            1,
        'nationality': _n('nationality') ?? AppCore.defaultCountry,
        'countryOfBirth': _n('countryOfBirth') ?? AppCore.defaultCountry,
        'homeTown': _n('homeTown') ?? AppCore.defaultHomeTown,
        'motherTongue': _n('motherTongue') ?? AppCore.defaultMotherTongue,
        'maritalStatus': _n('maritalStatus') ?? '',
        'bloodGroup': _n('bloodGroup') ?? AppCore.defaultBloodGroup,
        'religion': _n('religion') ?? AppCore.defaultReligion,
        'homePhoneNumber': _n('homePhoneNumber') ?? '',
        'notes': _n('notes') ?? '',
        'censusNumber': _n('censusNumber') ?? '',
        'isDisabled': false,
        'identification': {
          'idNumber': identificationNumber,
          'issuingCountry': _n('issuingCountry') ?? AppCore.defaultCountry,
          'idType': idType,
          'nameOfDocument': _n('nameOfDocument') ?? '',
          'recordNumber': _n('recordNumber') ?? '',
          'pageNumber': _n('pageNumber') ?? '',
          'issuer': _n('issuer') ?? '',
          'issuingDate': _dateForApi(_n('issuingDate')),
        },
        'fatherIdentification': _buildFatherIdentificationPayload(),
        'specialNeeds':
            _n('specialNeeds') == null ? null : <String>[_n('specialNeeds')!],
        'studyLanguage': _n('studyLanguage') ?? AppCore.defaultStudyLanguage,
        'economicLevel': _n('economicLevel') ?? AppCore.defaultEconomicLevel,
        'isCoveredBySocialWelfare': _socialWelfare,
        'isDroppedOutFromSchool': false,
        'lastYearResult': 3,
        'schoolId': int.parse(widget.schoolId),
        'stageId': int.parse(stageId!),
        'classRoomId':
            (roomId != null && roomId!.isNotEmpty) ? int.parse(roomId!) : null,
        'ageExceptionReason': null,
        'genderExceptionReason': null,
        'address': {
          'addressType': 1,
          'countryStructureId': int.parse(_addressTownId ?? _addressDistrictId!),
          'town': _n('town') ?? AppCore.defaultTown,
          'area': _n('area') ?? AppCore.defaultArea,
          'quarter': _n('quarter') ?? '',
          'street': _n('street') ?? '',
          'apartmentNumber': '',
          'buildingNumber': '',
          'address1': _n('address1') ?? AppCore.defaultAddress1,
          'address2': _n('address2') ?? AppCore.defaultAddress2,
          'closestLocation':
              _n('closestLocation') ?? AppCore.defaultClosestLocation,
          'latitude': 0,
          'longitude': 0,
          'schoolPhoneNumber': '',
          'mobilePhoneNumber': '',
          'email': '',
          'website': '',
        },
      };

      final response = await http
          .post(
            Uri.parse('https://emis.moedu.gov.iq/api/student/addstudent'),
            headers: h,
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 15));

      final responseText = utf8.decode(response.bodyBytes);
      dynamic responseJson;
      try {
        responseJson = jsonDecode(responseText);
      } catch (_) {}

      if (response.statusCode < 200 || response.statusCode >= 300) {
        final serverMessage = responseJson is Map
            ? '${responseJson['message'] ?? responseJson['error'] ?? responseText}'
            : responseText;
        throw Exception('رفض EMIS الطلب: $serverMessage');
      }

      final successMessage = responseJson is Map &&
              '${responseJson['message'] ?? ''}'.trim().isNotEmpty
          ? '${responseJson['message']}'
          : 'تمت إضافة الطالب بنجاح';

      if (!mounted) return;
      setState(() {
        error = null;
        _saveStatus = successMessage;
        _saveStatusIsError = false;
      });
      _showSaveMessage(successMessage, isError: false);

      await Future<void>.delayed(const Duration(milliseconds: 700));
      if (!mounted) return;
      if (addAnother) {
        _voiceSequentialMode = false;
        _pendingVoiceField = null;
        await _googleSpeechSubscription?.cancel();
        _googleSpeechSubscription = null;
        await GoogleSpeechService.cancelListening();
        _activeVoiceSessionId = null;
        if (!mounted) return;
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => AddStudentScreen(
              token: widget.token,
              schoolId: widget.schoolId,
            ),
          ),
        );
      } else {
        Navigator.pop(context, true);
      }
    } catch (e) {
      final friendly = _friendlyError(e);
      if (mounted) {
        setState(() {
          error = friendly;
          _saveStatus = friendly;
          _saveStatusIsError = true;
        });
        _showSaveMessage(friendly, isError: true);
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  bool _socialWelfare = false;

  String? _n(String key) {
    final v = c[key]?.text.trim() ?? '';
    return v.isEmpty ? null : v;
  }

  String? _validateBeforeSave() {
    if ((_n('name') ?? '').isEmpty) return 'يرجى إدخال الإسم';
    if ((_n('fatherName') ?? '').isEmpty) return 'يرجى إدخال إسم الأب';
    if ((_n('grandFatherName') ?? '').isEmpty) {
      return 'يرجى إدخال اسم والد الأب';
    }
    if ((_n('dateOfBirth') ?? '').isEmpty) return 'يرجى إدخال تاريخ التولد';
    if (stageId == null || stageId!.isEmpty) return 'يرجى اختيار الصف الدراسي';
    if (_addressDistrictId == null || _addressDistrictId!.isEmpty) {
      return 'يرجى اختيار القضاء في العنوان';
    }
    return null;
  }

  String _friendlyError(Object error) {
    final message = '$error';
    if (message.contains('SocketException')) return 'تعذر الاتصال بخادم EMIS.';
    return message.startsWith('Exception: ')
        ? message.substring('Exception: '.length)
        : message;
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
    const emeraldNeon = Color(0xFF10B981);
    const blueNeon = Color(0xFF3B82F6);
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
              _AnimatedStudentOrbIcon(
                icon: Icons.person_add_alt_1_rounded,
                primaryColor: blueNeon,
                secondaryColor: emeraldNeon,
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
                      'إضافة طالب جديد',
                      style: TextStyle(
                        color: isDark ? Colors.white : const Color(0xFF0F172A),
                        fontSize: 18.5,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      'الخيارات والصفوف والشعب تُقرأ مباشرة من EMIS',
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
      builder: (context, currentMode, _) {
        final isDark = currentMode == ThemeMode.dark;
        final textColor = isDark ? Colors.white : const Color(0xFF0F172A);

        const emeraldNeon = Color(0xFF10B981);
        const goldNeon = Color(0xFFF59E0B);
        const purpleNeon = Color(0xFFA855F7);
        const blueNeon = Color(0xFF3B82F6);
        const orangeNeon = Color(0xFFF97316);
        const cyanNeon = Color(0xFF06B6D4);

        return Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (_) => _stopVoiceFromPointer(),
          child: Directionality(
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
                            math.sin(_ambientController.value * 2 * math.pi) *
                                22;
                        return Stack(
                          children: [
                            Positioned(
                              top: -50 + shift,
                              right: -50,
                              child: _buildAmbientGlow(
                                color: isDark
                                    ? emeraldNeon.withOpacity(0.18)
                                    : purpleNeon.withOpacity(0.12),
                                size: 260,
                              ),
                            ),
                            Positioned(
                              top: 250 - shift,
                              left: -70,
                              child: _buildAmbientGlow(
                                color: isDark
                                    ? blueNeon.withOpacity(0.15)
                                    : blueNeon.withOpacity(0.10),
                                size: 280,
                              ),
                            ),
                            Positioned(
                              bottom: -70 + shift,
                              right: 20,
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
                    child: loading
                        ? Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                _AnimatedStudentOrbIcon(
                                  icon: Icons.person_add_alt_1_rounded,
                                  primaryColor: emeraldNeon,
                                  secondaryColor: blueNeon,
                                  animation: _ambientController,
                                  size: 76,
                                ),
                                const SizedBox(height: 16),
                                Text(
                                  'جاري تحميل قوائم وخيارات EMIS...',
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
                            key: _form,
                            child: ListView(
                              physics: const BouncingScrollPhysics(),
                              cacheExtent: 5000,
                              padding: const EdgeInsets.fromLTRB(16, 12, 16, 35),
                              children: [
                                _buildTopHeader(isDark),
                                _sequentialVoiceControl(isDark),
                                if (!AppCore.voiceInputEnabled) ...[
                                  const SizedBox(height: 8),
                                  _buildBannerBox(
                                    text: 'الميكروفون مغلق من الإعدادات.',
                                    color: orangeNeon,
                                    icon: Icons.mic_off_rounded,
                                    isDark: isDark,
                                  ),
                                ],
                                if (_speechError != null) ...[
                                  const SizedBox(height: 8),
                                  _buildBannerBox(
                                    text: _speechError!,
                                    color: orangeNeon,
                                    icon: Icons.record_voice_over_rounded,
                                    isDark: isDark,
                                  ),
                                ],
                                if (error != null) ...[
                                  const SizedBox(height: 12),
                                  _error(error!, isDark),
                                ],
                                const SizedBox(height: 14),

                                _section(
                                  title: 'البيانات الأساسية',
                                  icon: Icons.badge_rounded,
                                  accentColor: blueNeon,
                                  isDark: isDark,
                                  children: [
                                    _textField('name',
                                        required: true, accentColor: blueNeon),
                                    const SizedBox(height: 10),
                                    _textField('fatherName',
                                        required: true, accentColor: blueNeon),
                                    const SizedBox(height: 10),
                                    _textField('grandFatherName',
                                        required: true, accentColor: blueNeon),
                                    const SizedBox(height: 10),
                                    _textField('fathersGrandFatherName',
                                        accentColor: blueNeon),
                                    const SizedBox(height: 10),
                                    _textField('surName',
                                        accentColor: blueNeon),
                                    const SizedBox(height: 10),
                                    _textField('motherName',
                                        accentColor: blueNeon),
                                    const SizedBox(height: 10),
                                    _textField('mothersFatherName',
                                        accentColor: blueNeon),
                                    const SizedBox(height: 10),
                                    _textField('mothersGrandFatherName',
                                        accentColor: blueNeon),
                                    const SizedBox(height: 10),
                                    SizedBox(
                                      width: double.infinity,
                                      child: _textField('dateOfBirth',
                                          accentColor: blueNeon),
                                    ),
                                    const SizedBox(height: 10),
                                    SizedBox(
                                      width: double.infinity,
                                      child: _select('gender',
                                          required: true,
                                          accentColor: blueNeon),
                                    ),
                                    const SizedBox(height: 10),
                                    Row(
                                      children: [
                                        Expanded(
                                          child: _select('countryOfBirth',
                                              accentColor: blueNeon),
                                        ),
                                        const SizedBox(width: 10),
                                        Expanded(
                                          child: _select('nationality',
                                              accentColor: blueNeon),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 10),
                                    _textField('homeTown',
                                        accentColor: blueNeon),
                                  ],
                                ),

                                _section(
                                  title: 'وثيقة التعريف',
                                  icon: Icons.credit_card_rounded,
                                  accentColor: purpleNeon,
                                  isDark: isDark,
                                  children: [
                                    _select('idType',
                                        required: true,
                                        accentColor: purpleNeon),
                                    const SizedBox(height: 10),
                                    if (_isNationalId)
                                      _textField('nationalId',
                                          required: true,
                                          keyboard: TextInputType.number,
                                          accentColor: purpleNeon),
                                    if (_isCivilId) ...[
                                      _textField('idNumber',
                                          required: true,
                                          keyboard: TextInputType.number,
                                          accentColor: purpleNeon),
                                      const SizedBox(height: 10),
                                      _textField('jinsiyaIdNumber',
                                          keyboard: TextInputType.number,
                                          accentColor: purpleNeon),
                                      const SizedBox(height: 10),
                                      _textField('issuer',
                                          accentColor: purpleNeon),
                                      const SizedBox(height: 10),
                                      _textField('recordNumber',
                                          keyboard: TextInputType.number,
                                          accentColor: purpleNeon),
                                      const SizedBox(height: 10),
                                      _textField('pageNumber',
                                          keyboard: TextInputType.number,
                                          accentColor: purpleNeon),
                                      const SizedBox(height: 10),
                                      _select('issuingCountry',
                                          accentColor: purpleNeon),
                                      const SizedBox(height: 10),
                                      _textField('issuingDate',
                                          accentColor: purpleNeon),
                                    ],
                                    if (_isBirthCertificate) ...[
                                      _textField('birthCertificateNumber',
                                          required: true,
                                          accentColor: purpleNeon),
                                      const SizedBox(height: 10),
                                      _textField('issuer',
                                          accentColor: purpleNeon),
                                      const SizedBox(height: 10),
                                      _select('issuingCountry',
                                          accentColor: purpleNeon),
                                      const SizedBox(height: 10),
                                      _textField('issuingDate',
                                          accentColor: purpleNeon),
                                      const SizedBox(height: 10),
                                      _textField('nameOfDocument',
                                          accentColor: purpleNeon),
                                    ],
                                    if (_isOtherId) ...[
                                      _textField('otherIdNumber',
                                          required: true,
                                          accentColor: purpleNeon),
                                      const SizedBox(height: 10),
                                      _textField('issuer',
                                          accentColor: purpleNeon),
                                      const SizedBox(height: 10),
                                      _select('issuingCountry',
                                          accentColor: purpleNeon),
                                      const SizedBox(height: 10),
                                      _textField('issuingDate',
                                          accentColor: purpleNeon),
                                      const SizedBox(height: 10),
                                      _textField('nameOfDocument',
                                          accentColor: purpleNeon),
                                    ],
                                  ],
                                ),

                                _section(
                                  title: 'هوية الأب',
                                  icon: Icons.family_restroom_rounded,
                                  accentColor: goldNeon,
                                  isDark: isDark,
                                  children: [
                                    ExcludeFocus(
                                      child: CheckboxListTile(
                                        contentPadding: EdgeInsets.zero,
                                        title: Text(
                                          'إضافة تفاصيل هوية الأب',
                                          style: TextStyle(
                                            fontWeight: FontWeight.w800,
                                            color: textColor,
                                          ),
                                        ),
                                        value: _includeFatherId,
                                        activeColor: goldNeon,
                                        checkColor: Colors.black,
                                        onChanged: (v) {
                                          setState(() {
                                            _includeFatherId = v ?? false;
                                            if (_includeFatherId) {
                                              if (c['fatherIssuingCountry']!
                                                  .text
                                                  .trim()
                                                  .isEmpty) {
                                                c['fatherIssuingCountry']!
                                                        .text =
                                                    AppCore.defaultCountry;
                                              }
                                              if (c['fatherIdType']!
                                                  .text
                                                  .trim()
                                                  .isEmpty) {
                                                c['fatherIdType']!.text =
                                                    AppCore.defaultIdType;
                                              }
                                            }
                                          });
                                        },
                                      ),
                                    ),
                                    if (_includeFatherId) ...[
                                      const SizedBox(height: 8),
                                      Row(
                                        children: [
                                          Expanded(
                                            child: _select(
                                              'fatherIssuingCountry',
                                              fallback: [AppCore.defaultCountry],
                                              accentColor: goldNeon,
                                            ),
                                          ),
                                          const SizedBox(width: 10),
                                          Expanded(
                                            child: _select('fatherIdType',
                                                accentColor: goldNeon),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 10),
                                      if (_isFatherNationalId)
                                        _textField('fatherNationalId',
                                            keyboard: TextInputType.number,
                                            accentColor: goldNeon),
                                      if (_isFatherCivilId) ...[
                                        _textField('fatherIdNumber',
                                            keyboard: TextInputType.number,
                                            accentColor: goldNeon),
                                        const SizedBox(height: 10),
                                        Row(
                                          children: [
                                            Expanded(
                                              child: _textField(
                                                  'fatherRecordNumber',
                                                  keyboard:
                                                      TextInputType.number,
                                                  accentColor: goldNeon),
                                            ),
                                            const SizedBox(width: 10),
                                            Expanded(
                                              child: _textField(
                                                  'fatherPageNumber',
                                                  keyboard:
                                                      TextInputType.number,
                                                  accentColor: goldNeon),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 10),
                                        _textField('fatherIssuer',
                                            accentColor: goldNeon),
                                      ],
                                      if (_isFatherBirthCertificate) ...[
                                        _textField(
                                            'fatherBirthCertificateNumber',
                                            accentColor: goldNeon),
                                        const SizedBox(height: 10),
                                        _textField('fatherIssuingDate',
                                            accentColor: goldNeon),
                                        const SizedBox(height: 10),
                                        Row(
                                          children: [
                                            Expanded(
                                              child: _textField(
                                                  'fatherRecordNumber',
                                                  keyboard:
                                                      TextInputType.number,
                                                  accentColor: goldNeon),
                                            ),
                                            const SizedBox(width: 10),
                                            Expanded(
                                              child: _textField(
                                                  'fatherPageNumber',
                                                  keyboard:
                                                      TextInputType.number,
                                                  accentColor: goldNeon),
                                            ),
                                          ],
                                        ),
                                      ],
                                      if (_isFatherOtherId) ...[
                                        _textField('fatherNameOfDocument',
                                            accentColor: goldNeon),
                                        const SizedBox(height: 10),
                                        _textField('fatherOtherIdNumber',
                                            accentColor: goldNeon),
                                      ],
                                    ],
                                  ],
                                ),

                                _section(
                                  title: 'البيانات الدراسية والاجتماعية',
                                  icon: Icons.diversity_3_rounded,
                                  accentColor: emeraldNeon,
                                  isDark: isDark,
                                  children: [
                                    Row(
                                      children: [
                                        Expanded(
                                          child: _select('motherTongue',
                                              accentColor: emeraldNeon),
                                        ),
                                        const SizedBox(width: 10),
                                        Expanded(
                                          child: _select(
                                            'studyLanguage',
                                            fallback: [
                                              AppCore.defaultStudyLanguage
                                            ],
                                            accentColor: emeraldNeon,
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 10),
                                    Row(
                                      children: [
                                        Expanded(
                                          child: _select('maritalStatus',
                                              accentColor: emeraldNeon),
                                        ),
                                        const SizedBox(width: 10),
                                        Expanded(
                                          child: _select('bloodGroup',
                                              accentColor: emeraldNeon),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 10),
                                    _select('religion',
                                        accentColor: emeraldNeon),
                                    const SizedBox(height: 10),
                                    _textField('homePhoneNumber',
                                        required: true,
                                        keyboard: TextInputType.phone,
                                        accentColor: emeraldNeon),
                                    const SizedBox(height: 10),
                                    _textField('notes',
                                        maxLines: 3, accentColor: emeraldNeon),
                                    const SizedBox(height: 10),
                                    _select('economicLevel',
                                        accentColor: emeraldNeon),
                                    const SizedBox(height: 10),
                                    _select('specialNeeds',
                                        accentColor: emeraldNeon),
                                    const SizedBox(height: 10),
                                    _socialWelfareSelect(isDark, emeraldNeon),
                                  ],
                                ),

                                _section(
                                  title: 'التسجيل الدراسي',
                                  icon: Icons.school_rounded,
                                  accentColor: cyanNeon,
                                  isDark: isDark,
                                  children: [
                                    _selectStage(isDark, cyanNeon),
                                    const SizedBox(height: 10),
                                    _selectRoom(isDark, cyanNeon),
                                    if (stageDetails != null) ...[
                                      const SizedBox(height: 10),
                                      _stageInfo(isDark, cyanNeon),
                                    ],
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
                                      voiceKey: 'addressCountry',
                                      value: _addressCountryId,
                                      items: _addressCountries,
                                      showMic: false,
                                      isDark: isDark,
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
                                      voiceKey: 'addressGovernorate',
                                      value: _addressGovernorateId,
                                      items: _addressGovernorates,
                                      showMic: false,
                                      isDark: isDark,
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
                                      label: 'القضاء',
                                      voiceKey: 'addressDistrict',
                                      value: _addressDistrictId,
                                      items: _addressDistricts,
                                      showMic: false,
                                      isDark: isDark,
                                      accentColor: orangeNeon,
                                      onChanged: (v) {
                                        final selected = _addressDistricts
                                            .where((x) => _value(x) == v)
                                            .toList();
                                        setState(() {
                                          _addressDistrictId = v;
                                          _addressTowns = selected.isEmpty
                                              ? <dynamic>[]
                                              : _children(selected.first);
                                          _addressTownId = null;
                                        });
                                        _focusLive('addressDistrict');
                                      },
                                    ),
                                    const SizedBox(height: 10),
                                    _addressDropdown(
                                      label: 'الناحية',
                                      voiceKey: 'addressTown',
                                      value: _addressTownId,
                                      items: _addressTowns,
                                      showMic: false,
                                      isDark: isDark,
                                      accentColor: orangeNeon,
                                      onChanged: (v) {
                                        setState(() => _addressTownId = v);
                                        _liveSyncKey.currentState
                                            ?.pushValues(_liveValues());
                                      },
                                    ),
                                    const SizedBox(height: 10),
                                    _textField('town', accentColor: orangeNeon),
                                    const SizedBox(height: 10),
                                    _textField('area',
                                        accentColor: orangeNeon),
                                    const SizedBox(height: 10),
                                    _textField('quarter',
                                        accentColor: orangeNeon),
                                    const SizedBox(height: 10),
                                    _textField('street',
                                        accentColor: orangeNeon),
                                    const SizedBox(height: 10),
                                    Row(
                                      children: [
                                        Expanded(
                                          child: _textField('address1',
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
                                        accentColor: orangeNeon),
                                  ],
                                ),

                                if (_saveStatus != null) ...[
                                  const SizedBox(height: 6),
                                  _buildBannerBox(
                                    text: _saveStatus!,
                                    color: _saveStatusIsError
                                        ? const Color(0xFFEF4444)
                                        : emeraldNeon,
                                    icon: _saveStatusIsError
                                        ? Icons.error_outline_rounded
                                        : Icons.check_circle_outline_rounded,
                                    isDark: isDark,
                                  ),
                                ],
                                const SizedBox(height: 16),

                                _buildSaveButton(isDark),
                                const SizedBox(height: 10),
                                _buildSaveButton(isDark, addAnother: true),
                                const SizedBox(height: 25),
                              ],
                            ),
                          ),
                  ),
                  _fixedSequentialArrow(isDark),
                  if (!loading)
                    Positioned(
                      left: 0,
                      bottom: 0,
                      child: EmisLiveSync(
                        ignoreInitialSnapshot: true,
                        key: _liveSyncKey,
                        url:
                            'https://emis.moedu.gov.iq/centers/schools/${widget.schoolId}/individuals/students/management/add',
                        mode: 'add',
                        entity: 'student',
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
          ),
        );
      },
    );
  }

  Widget _buildSaveButton(bool isDark, {bool addAnother = false}) {
    // يبقى زر الحفظ فعالاً أثناء الاستماع؛ الضغط عليه يوقف الميكروفون تلقائياً.
    final disabled = saving;
    const emeraldNeon = Color(0xFF10B981);
    const blueNeon = Color(0xFF3B82F6);

    return ExcludeFocus(
      child: GestureDetector(
        onTap: disabled ? null : () => _save(addAnother: addAnother),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          height: 58,
          decoration: BoxDecoration(
            gradient: disabled
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
                      emeraldNeon,
                      blueNeon,
                    ],
                  ),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(
              color: Colors.white.withOpacity(0.35),
              width: 1.3,
            ),
            boxShadow: disabled
                ? []
                : [
                    BoxShadow(
                      color: emeraldNeon.withOpacity(isDark ? 0.35 : 0.25),
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
                Icon(
                  saving
                      ? Icons.hourglass_top_rounded
                      : Icons.person_add_alt_1_rounded,
                  color: Colors.white,
                  size: 24,
                ),
              const SizedBox(width: 10),
              Text(
                saving
                    ? (_activeVoiceSessionId != null
                        ? 'جاري إيقاف الميكروفون...'
                        : 'جاري حفظ بيانات الطالب...')
                    : (addAnother ? 'حفظ + إضافة طالب جديد' : 'حفظ الطالب في EMIS'),
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

  Widget _select(
    String key, {
    bool required = false,
    List<String>? fallback,
    Color accentColor = const Color(0xFF3B82F6),
  }) {
    final isDark = AppCore.themeNotifier.value == ThemeMode.dark;
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final isActiveVoice = _speechListening && _activeVoiceField == key;

    final sourceKey = switch (key) {
      'fatherIdType' => 'idType',
      'fatherIssuingCountry' => 'issuingCountry',
      _ => key,
    };
    final values = <dynamic>[
      ...(options[sourceKey] ?? []),
      ...((fallback ?? []).map((x) => {'value': x, 'displayName': x})),
    ];
    final current = c[key]!.text.trim();
    if (current.isNotEmpty && !values.any((x) => _value(x) == current)) {
      values.insert(0, {'value': current, 'displayName': current});
    }
    if (key == 'specialNeeds') {
      values.removeWhere((x) => _value(x).isEmpty);
      values.insert(0, {'value': '', 'displayName': ''});
    }

    final fieldKey = _centralNav.keyForField(
      key,
      NavigableFieldType.dropdown,
      isAvailable: () => values.isNotEmpty && _isDropdownAvailableForCentralNav(key),
    );

    return DropdownButtonFormField<String>(
      key: fieldKey,
      onTap: () {
        FocusManager.instance.primaryFocus?.unfocus();
      },
      value: current.isEmpty ? null : current,
      isExpanded: true,
      dropdownColor: isDark ? const Color(0xFF181D32) : Colors.white,
      iconEnabledColor: accentColor,
      decoration: _decoration(
        labels[key] ?? key,
        isDark: isDark,
        accentColor: accentColor,
        isActiveVoice: isActiveVoice,
      ).copyWith(
        suffixIcon: _dropdownVoiceFields.contains(key)
            ? _dropdownVoiceMic(key, accentColor: accentColor)
            : null,
      ),
      style: TextStyle(
        fontWeight: FontWeight.w800,
        fontSize: 13.5,
        color: textColor,
      ),
      selectedItemBuilder: (context) => values
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
      items: values
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
          if (key == 'fatherIssuingCountry') {
            if ((v ?? '') != 'العراق') {
              c['fatherIdType']!.text = '16';
            }
          }
        });
        _focusLive(key);
      },
    );
  }

  Widget _socialWelfareSelect(bool isDark, Color accentColor) {
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final fieldKey = _centralNav.keyForField(
      'isCoveredBySocialWelfare',
      NavigableFieldType.dropdown,
      isAvailable: () => true,
    );

    return DropdownButtonFormField<bool>(
      key: fieldKey,
      onTap: () {
        FocusManager.instance.primaryFocus?.unfocus();
      },
      value: _socialWelfare,
      isExpanded: true,
      dropdownColor: isDark ? const Color(0xFF181D32) : Colors.white,
      iconEnabledColor: accentColor,
      decoration: _decoration(
        'مشمول بمنحة الرعاية الاجتماعية؟',
        isDark: isDark,
        accentColor: accentColor,
      ),
      style: TextStyle(
        fontWeight: FontWeight.w800,
        fontSize: 13.5,
        color: textColor,
      ),
      selectedItemBuilder: (context) => [
        Text('لا',
            style: TextStyle(fontWeight: FontWeight.w800, color: textColor)),
        Text('نعم',
            style: TextStyle(fontWeight: FontWeight.w800, color: textColor)),
      ],
      items: [
        DropdownMenuItem<bool>(
          value: false,
          child: Text('لا',
              style: TextStyle(fontWeight: FontWeight.w800, color: textColor)),
        ),
        DropdownMenuItem<bool>(
          value: true,
          child: Text('نعم',
              style: TextStyle(fontWeight: FontWeight.w800, color: textColor)),
        ),
      ],
      onChanged: (value) {
        if (value == null) return;
        setState(() => _socialWelfare = value);
        _focusLive('isCoveredBySocialWelfare');
      },
    );
  }

  Widget _addressDropdown({
    required String label,
    required String voiceKey,
    required String? value,
    required List<dynamic> items,
    required ValueChanged<String?> onChanged,
    required bool isDark,
    required Color accentColor,
    bool showMic = true,
  }) {
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final safe = items.any((x) => _value(x) == value) ? value : null;
    final isActiveVoice = _speechListening && _activeVoiceField == voiceKey;

    final fieldKey = _centralNav.keyForField(
      voiceKey,
      NavigableFieldType.dropdown,
      isAvailable: () => items.isNotEmpty,
    );

    return DropdownButtonFormField<String>(
      key: fieldKey,
      onTap: () {
        FocusManager.instance.primaryFocus?.unfocus();
      },
      value: safe,
      isExpanded: true,
      dropdownColor: isDark ? const Color(0xFF181D32) : Colors.white,
      iconEnabledColor: accentColor,
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
      decoration: _decoration(
        label,
        isDark: isDark,
        accentColor: accentColor,
        isActiveVoice: isActiveVoice,
      ).copyWith(
        suffixIcon: showMic && _dropdownVoiceFields.contains(voiceKey)
            ? _dropdownVoiceMic(voiceKey, accentColor: accentColor)
            : null,
      ),
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

  Widget _selectStage(bool isDark, Color accentColor) {
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final isActiveVoice = _speechListening && _activeVoiceField == 'stageId';

    final fieldKey = _centralNav.keyForField(
      'stageId',
      NavigableFieldType.dropdown,
      isAvailable: () => stages.isNotEmpty,
    );

    return DropdownButtonFormField<String>(
      key: fieldKey,
      onTap: () {
        FocusManager.instance.primaryFocus?.unfocus();
      },
      value: stageId,
      isExpanded: true,
      dropdownColor: isDark ? const Color(0xFF181D32) : Colors.white,
      iconEnabledColor: accentColor,
      decoration: _decoration(
        'الصف الدراسي',
        isDark: isDark,
        accentColor: accentColor,
        isActiveVoice: isActiveVoice,
      ),
      style: TextStyle(
        fontWeight: FontWeight.w800,
        fontSize: 13.5,
        color: textColor,
      ),
      selectedItemBuilder: (context) => stages
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
      items: stages
          .map(
            (x) => DropdownMenuItem(
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
        _stageChanged(v);
        _focusLive('stageId');
      },
    );
  }

  Widget _selectRoom(bool isDark, Color accentColor) {
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final fieldKey = _centralNav.keyForField(
      'classRoomId',
      NavigableFieldType.dropdown,
      isAvailable: () => rooms.isNotEmpty,
      waitBeforeActivate: _waitForRoomsIfLoading,
    );

    return DropdownButtonFormField<String>(
      key: fieldKey,
      onTap: () {
        FocusManager.instance.primaryFocus?.unfocus();
      },
      value: roomId,
      isExpanded: true,
      dropdownColor: isDark ? const Color(0xFF181D32) : Colors.white,
      iconEnabledColor: accentColor,
      decoration: _decoration(
        'الشعبة',
        isDark: isDark,
        accentColor: accentColor,
      ),
      style: TextStyle(
        fontWeight: FontWeight.w800,
        fontSize: 13.5,
        color: textColor,
      ),
      selectedItemBuilder: (context) => rooms
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
      items: rooms
          .map(
            (x) => DropdownMenuItem(
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
        setState(() => roomId = v);
        _focusLive('classRoomId');
      },
    );
  }

  Widget _stageInfo(bool isDark, Color accentColor) {
    final d = stageDetails;
    if (d == null) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: accentColor.withOpacity(isDark ? 0.14 : 0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: accentColor.withOpacity(0.35)),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline_rounded, color: accentColor, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'العمر المسموح: ${d['minAge'] ?? '-'} إلى ${d['maxAge'] ?? '-'} سنة',
              textAlign: TextAlign.right,
              style: TextStyle(
                fontWeight: FontWeight.w800,
                color: isDark ? Colors.white : const Color(0xFF0F172A),
              ),
            ),
          ),
        ],
      ),
    );
  }

  InputDecoration _decoration(
    String label, {
    required bool isDark,
    Color accentColor = const Color(0xFF3B82F6),
    bool isActiveVoice = false,
  }) {
    final borderCol = isActiveVoice
        ? const Color(0xFFEF4444)
        : accentColor.withOpacity(isDark ? 0.35 : 0.25);

    return InputDecoration(
      labelText: label,
      labelStyle: TextStyle(
        fontWeight: FontWeight.bold,
        fontSize: 12.5,
        color: isActiveVoice
            ? const Color(0xFFEF4444)
            : (isDark ? const Color(0xFF94A3B8) : const Color(0xFF475569)),
      ),
      filled: true,
      fillColor: isDark
          ? const Color(0xFF0B0E1A).withOpacity(0.68)
          : const Color(0xFFF1F5F9),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: borderCol, width: 1.3),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(
          color: borderCol,
          width: isActiveVoice ? 1.8 : 1.2,
        ),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(
          color: isActiveVoice ? const Color(0xFFEF4444) : accentColor,
          width: 1.8,
        ),
      ),
    );
  }

  Widget _buildBannerBox({
    required String text,
    required Color color,
    required IconData icon,
    required bool isDark,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withOpacity(isDark ? 0.14 : 0.09),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withOpacity(0.45)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontWeight: FontWeight.w800,
                color: isDark ? Colors.white : const Color(0xFF0F172A),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _error(String text, bool isDark) => _buildBannerBox(
        text: text,
        color: const Color(0xFFEF4444),
        icon: Icons.warning_amber_rounded,
        isDark: isDark,
      );
}

class _AnimatedStudentOrbIcon extends StatelessWidget {
  final IconData icon;
  final Color primaryColor;
  final Color secondaryColor;
  final Animation<double> animation;
  final double size;

  const _AnimatedStudentOrbIcon({
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
                  painter: _StudentOrbPainter(
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

class _StudentOrbPainter extends CustomPainter {
  final double progress;
  final Color primaryColor;
  final Color secondaryColor;

  _StudentOrbPainter({
    required this.progress,
    required this.primaryColor,
    required this.secondaryColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final angle = progress * 2 * math.pi;

    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(-0.35);
    final rect = Rect.fromCenter(
      center: Offset.zero,
      width: size.width * 0.94,
      height: size.height * 0.40,
    );
    final orbitPaint = Paint()
      ..color = secondaryColor.withOpacity(0.55)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawOval(rect, orbitPaint);

    final dotX = (size.width * 0.47) * math.cos(angle);
    final dotY = (size.height * 0.20) * math.sin(angle);
    canvas.drawCircle(
      Offset(dotX, dotY),
      2.8,
      Paint()..color = secondaryColor,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _StudentOrbPainter oldDelegate) =>
      oldDelegate.progress != progress;
}

class _StudentWavePainter extends CustomPainter {
  final double phase;
  final Color color;
  final bool isDark;

  _StudentWavePainter({
    required this.phase,
    required this.color,
    required this.isDark,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paintLine = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round;

    final glowPaint = Paint()
      ..color = color.withOpacity(isDark ? 0.42 : 0.24)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5.0
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5);

    final path = Path();
    for (double x = 0; x <= size.width; x += 2) {
      final normalized = x / size.width;
      final y = size.height * 0.5 +
          math.sin(normalized * 4 * math.pi + phase) * (size.height * 0.28) +
          math.cos(normalized * 2 * math.pi - phase) * (size.height * 0.12);
      if (x == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }

    canvas.drawPath(path, glowPaint);
    canvas.drawPath(path, paintLine);
  }

  @override
  bool shouldRepaint(covariant _StudentWavePainter oldDelegate) =>
      oldDelegate.phase != phase ||
      oldDelegate.color != color ||
      oldDelegate.isDark != isDark;
}
