import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'platform_permissions.dart';

import 'package:image/image.dart' as img;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'google_speech_service.dart';
import 'voice_result_processor.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'platform_image_picker.dart';
import 'package:google_mlkit_selfie_segmentation/google_mlkit_selfie_segmentation.dart';

import 'selfie_background_remover.dart';
import 'app_core.dart';
import 'employment_status_options.dart';
import 'emis_live_sync.dart';
import 'emis_options.dart';

class EditTeacherScreen extends StatefulWidget {
  final String token;
  final String schoolId;
  final String teacherId;

  const EditTeacherScreen({
    super.key,
    required this.token,
    required this.schoolId,
    required this.teacherId,
  });

  @override
  State<EditTeacherScreen> createState() => _EditTeacherScreenState();
}

class _EditTeacherScreenState extends State<EditTeacherScreen>
    with SingleTickerProviderStateMixin {
  bool _isLoading = true;
  bool _isSaving = false;
  final GlobalKey<EmisLiveSyncState> _liveSyncKey = GlobalKey<EmisLiveSyncState>();
  Timer? _liveTimer;
  String _liveStatus = 'المزامنة الحية مع EMIS قيد التشغيل';
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();

  Map<String, dynamic>? _teacherData;
  File? _pickedImage;
  final Map<String, TextEditingController> _dateControllers = {};

  final Map<String, List<Map<String, dynamic>>> _options = {};
  final Set<String> _loadingOptions = <String>{};
  bool _employmentStatusCatalogLoaded = false;

  List<Map<String, dynamic>> _addressCountries = [];
  List<Map<String, dynamic>> _addressGovernorates = [];
  List<Map<String, dynamic>> _addressDistricts = [];
  List<Map<String, dynamic>> _addressTowns = [];
  String? _addressCountryId;
  String? _addressGovernorateId;
  String? _addressDistrictId;
  String? _addressTownId;

  late final AnimationController _ambientController;
  bool _teacherVoiceListening = false;
  int _teacherVoiceSession = 0;
  int _teacherVoiceNextSession = 0;
  String? _teacherVoiceField;
  Map<String, dynamic>? _teacherVoiceOwner;
  String _teacherVoiceAccumulated = '';
  StreamSubscription<Map<String, dynamic>>? _teacherVoiceSubscription;
  VoidCallback? _teacherVoiceSettingsListener;

  static const Set<String> _teacherFieldsWithDefaults = {
    'nationality', 'issuingCountry', 'countryOfBirth', 'idType', 'gender',
    'motherTongue', 'religion', 'bloodGroup', 'status', 'employeeCategory',
    'employmentType', 'classification', 'currentPosition', 'educationLevel',
    'town', 'area', 'homeTown', 'address1', 'address2', 'closestLocation',
  };

  Future<void> _toggleTeacherVoice(String key, Map<String, dynamic> owner) async {
    if (!AppCore.voiceInputEnabled) {
      _showTeacherVoiceMessage('الإدخال الصوتي مغلق من الإعدادات.');
      return;
    }
    if (_teacherVoiceListening && _teacherVoiceField == key) {
      await GoogleSpeechService.stopListening();
      return;
    }
    if (_teacherVoiceListening) await GoogleSpeechService.stopListening();
    final microphoneAllowed = await ensureEmisMicrophonePermission();
    if (!microphoneAllowed) {
      _showTeacherVoiceMessage('يرجى السماح باستخدام الميكروفون.');
      return;
    }
    final info = await GoogleSpeechService.getInfo();
    if (info['available'] != true) {
      _showTeacherVoiceMessage('خدمة التعرف الصوتي غير متاحة على الجهاز.');
      return;
    }
    final session = ++_teacherVoiceNextSession;
    _teacherVoiceSession = session;
    _teacherVoiceField = key;
    _teacherVoiceOwner = owner;
    _teacherVoiceAccumulated = '';
    if (mounted) setState(() => _teacherVoiceListening = true);
    final started = await GoogleSpeechService.startListening(
      sessionId: session, locale: 'ar-IQ',
    );
    if (!started && mounted && _teacherVoiceSession == session) {
      setState(() => _teacherVoiceListening = false);
      _showTeacherVoiceMessage('تعذر تشغيل الميكروفون.');
    }
  }

  void _handleTeacherVoiceEvent(Map<String, dynamic> event) {
    if (!mounted || int.tryParse('${event['sessionId']}') != _teacherVoiceSession) return;
    final type = '${event['type'] ?? ''}';
    if (type == 'stopped' || type == 'error') {
      setState(() => _teacherVoiceListening = false);
      return;
    }
    if (type != 'partial' && type != 'result') return;
    if (type == 'result') unawaited(GoogleSpeechService.stopListening());
    final key = _teacherVoiceField;
    final owner = _teacherVoiceOwner;
    if (key == null || owner == null) return;
    final full = <String>[
      '${event['text'] ?? ''}',
      if (event['alternates'] is List) ...((event['alternates'] as List).map((e) => '$e')),
    ].where((e) => e.trim().isNotEmpty).toList();
    final segments = <String>[
      '${event['segment'] ?? ''}',
      if (event['segmentAlternates'] is List) ...((event['segmentAlternates'] as List).map((e) => '$e')),
    ].where((e) => e.trim().isNotEmpty).toList();
    final text = VoiceResultProcessor.resolveText(
      segmentCandidates: segments, fullCandidates: full,
      accumulated: _teacherVoiceAccumulated,
    );
    if (text.isEmpty) return;
    _teacherVoiceAccumulated = text;
    final available = _options[key] ?? const <Map<String, dynamic>>[];
    Map<String, dynamic>? matched;
    String norm(String value) => AppCore.normalizeIraqiSpokenText(value)
        .replaceAll(RegExp(r'\s+'), '');
    final spoken = norm(text);
    for (final option in available) {
      final value = '${_optionValue(option) ?? ''}';
      final label = _optionText(option);
      if (norm(label) == spoken || norm(value) == spoken ||
          (spoken.length >= 3 && (norm(label).contains(spoken) || spoken.contains(norm(label))))) {
        matched = option;
        break;
      }
    }
    if (matched != null) {
      setState(() => owner[key] = _optionValue(matched!));
      _focusLive(key);
      if (type == 'result') setState(() => _teacherVoiceListening = false);
    } else if (type == 'result') {
      setState(() => _teacherVoiceListening = false);
      _showTeacherVoiceMessage('لم أتمكن من مطابقة النطق مع خيارات ${_label(key)}.');
    }
  }

  void _showTeacherVoiceMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  Widget _teacherVoiceMic(String key, Map<String, dynamic> owner) =>
      const SizedBox.shrink();



  static const Map<String, String> _optionEndpoints = {
    'countryOfBirth': '/selectoption/بلد الولادة',
    'nationality': '/selectoption/الجنسية',
    'idType': '/selectoption/IdentificationType',
    'issuingCountry': '/selectoption/بلد الإصدار',
    'gender': '/selectoption/Gender',
    'motherTongue': '/selectoption/لغة',
    'maritalStatus': '/selectoption/الحالة الاجتماعية',
    'bloodGroup': '/selectoption/فصيلة الدم',
    'religion': '/selectoption/الديانة',
    'educationLevel': '/selectoption/تحصیل الدراسي',
    'positionType': '/SelectOption/نوع الوظيفة',
    'specialization': '/selectoption/الإختصاص',
  };

  static final Map<String, List<Map<String, dynamic>>> _defaultStaticOptions = const {};

  final Map<String, String> _officialArabicNames = {
    'name': 'الإسم *',
    'fatherName': 'إسم الأب *',
    'grandFatherName': 'اسم والد الأب *',
    'fathersGrandFatherName': 'اسم جد الأب *',
    'surName': 'اللقب *',
    'motherName': 'إسم الأم *',
    'mothersFatherName': 'اسم والد الأم *',
    'mothersGrandFatherName': 'اسم جد الأم *',
    'dateOfBirth': 'تاريخ التولّد *',
    'gender': 'الجنس *',
    'nationality': 'الجنسية *',
    'countryOfBirth': 'محل الولادة',
    'homeTown': 'مسقط الرأس',
    'motherTongue': 'اللغة الأم *',
    'maritalStatus': 'الحالة الاجتماعية',
    'bloodGroup': 'فئة الدم',
    'religion': 'الديانة *',
    'notes': 'ملاحظات',
    'idType': 'نوع الهوية *',
    'issuingCountry': 'بلد الإصدار *',
    'idNumber': 'رقم الوثيقة / البطاقة الوطنية *',
    'issuingDate': 'تاريخ الإصدار',
    'employeeIdNumber': 'الرقم الوظيفي',
    'familyNumber': 'الرقم العائلي',
    'nameOfDocument': 'نوع الوثيقة *',
    'issuer': 'جهة الإصدار',
    'recordNumber': 'رقم السجل *',
    'pageNumber': 'رقم الصحيفة *',
    'employmentType': 'نوع التوظيف *',
    'employeeCategory': 'نوع الموظف *',
    'classification': 'التصنيف *',
    'jobDesignation': 'المسمى الوظيفي',
    'employmentGrade': 'الدرجة الوظيفية',
    'weeklyTeachingQuota': 'النصاب الأسبوعي للحصص',
    'currentPosition': 'المنصب الحالي *',
    'positionType': 'العنوان الوظيفي *',
    'dateOfStartWorking': 'تاريخ أول تعيين للموظف *',
    'employmentStatus': 'الحالة الوظيفية *',
    'employmentStatusReason': 'سبب الحالة الوظيفية',
    'assignedEntityName': 'الجهة المنسب أو المكلف إليها',
    'status': 'حالة السجل',
    'educationLevel': 'التحصيل الدراسي *',
    'universityName': 'إسم الكلية / المعهد',
    'graduationYear': 'سنة التخرج',
    'specialization': 'الإختصاص *',
    'specialNeedsInformation': 'معلومات ذوي الاحتياجات الخاصة إن وجدت',
    'emergencyContactName': 'اسم جهة الاتصال في الحالات الطارئة',
    'emergencyContactRelationship': 'صلة جهة الاتصال',
    'emergencyContactPhoneNumber': 'رقم هاتف جهة الاتصال في الحالات الطارئة',
    'countryStructureId': 'الموقع الجغرافي *',
    'town': 'المدينة/القرية *',
    'area': 'الحي *',
    'quarter': 'المحلة *',
    'street': 'زقاق *',
    'address1': 'عنوان 1 *',
    'address2': 'عنوان 2',
    'closestLocation': 'أقرب نقطة دالة *',
    'email': 'البريد الإلكتروني',
    'mobilePhoneNumber': 'رقم هاتف المعلم *',
    'homePhoneNumber': 'رقم الهاتف الأرضي',
    'imageUrl': 'الصورة الشخصية',
  };

  Map<String, String> get h => {'Authorization': widget.token, 'Accept': 'application/json'};

  @override
  void initState() {
    super.initState();
    _ambientController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 6),
    )..repeat();

    _teacherVoiceSubscription = GoogleSpeechService.events.listen(_handleTeacherVoiceEvent);
    _teacherVoiceSettingsListener = () { if (mounted) setState(() {}); };
    AppCore.voiceSettingsRevision.addListener(_teacherVoiceSettingsListener!);
    _initStaticOptions();
    _liveTimer = Timer.periodic(const Duration(milliseconds: 700), (_) => _pushLive());
    _fetchTeacherData();
  }

  void _initStaticOptions() {}

  Map<String, List<String>> _liveAliases() => {
        for (final entry in _officialArabicNames.entries)
          entry.key: <String>[
            entry.key,
            entry.value.replaceAll(' *', '').trim(),
            entry.value,
          ],
      };

  Map<String, String> _liveValues() {
    final result = <String, String>{};
    final data = _teacherData;
    if (data == null) return result;
    final identification = data['identification'] is Map
        ? Map<String, dynamic>.from(data['identification'] as Map)
        : <String, dynamic>{};
    final address = data['address'] is Map
        ? Map<String, dynamic>.from(data['address'] as Map)
        : <String, dynamic>{};
    for (final key in _officialArabicNames.keys) {
      dynamic value;
      if (data.containsKey(key)) {
        value = data[key];
      } else if (identification.containsKey(key)) {
        value = identification[key];
      } else if (address.containsKey(key)) {
        value = address[key];
      }
      if (value is List) value = value.isEmpty ? '' : value.first;
      if (value is bool) value = value ? 'true' : 'false';
      if (value != null) result[key] = '$value';
    }
    return result;
  }

  void _pushLive() => _liveSyncKey.currentState?.pushValues(_liveValues());

  void _focusLive(String key) {
    _liveSyncKey.currentState?.focusField(key);
    _liveSyncKey.currentState?.pushValues(_liveValues());
  }

  dynamic _liveCoerce(dynamic old, String value) {
    if (old is bool) return value.toLowerCase() == 'true' || value == '1';
    if (old is int) return int.tryParse(value) ?? old;
    if (old is double) return double.tryParse(value) ?? old;
    if (old is List) return value.isEmpty ? <String>[] : <String>[value];
    return value;
  }

  /// خيارات التقطها جسر المزامنة من نموذج EMIS الحي. كانت تُهمَل بالكامل في شاشات
  /// التعديل لأن onOptions لم يكن موصولاً.
  void _applyLiveOptions(Map<String, List<dynamic>> incoming) {
    var changed = false;
    incoming.forEach((key, values) {
      if (values.isEmpty || !_isDropdownField(key)) return;
      _options[key] = EmisOptions.mergeLive(
        _options[key] ?? const <Map<String, dynamic>>[],
        values,
      );
      changed = true;
    });
    if (changed && mounted) setState(() {});
  }

  void _applyLiveSnapshot(Map<String, String> values) {
    final data = _teacherData;
    if (data == null) return;

    final identification = data['identification'] is Map
        ? Map<String, dynamic>.from(data['identification'] as Map)
        : <String, dynamic>{};
    final address = data['address'] is Map
        ? Map<String, dynamic>.from(data['address'] as Map)
        : <String, dynamic>{};

    const identificationKeys = <String>{
      'idNumber',
      'issuingCountry',
      'idType',
      'nameOfDocument',
      'recordNumber',
      'pageNumber',
      'issuer',
      'issuingDate',
    };
    const addressKeys = <String>{
      'countryStructureId',
      'town',
      'area',
      'quarter',
      'street',
      'address1',
      'address2',
      'closestLocation',
      'mobilePhoneNumber',
      'email',
    };

    bool changed = false;
    for (final entry in values.entries) {
      final key = entry.key;
      final value = entry.value;

      dynamic currentValue;
      if (data.containsKey(key)) {
        currentValue = data[key];
      } else if (identificationKeys.contains(key) || identification.containsKey(key)) {
        currentValue = identification[key];
      } else if (addressKeys.contains(key) || address.containsKey(key)) {
        currentValue = address[key];
      }

      final incomingIsEmpty = value.trim().isEmpty;
      final currentIsNonEmpty =
          currentValue != null && currentValue.toString().trim().isNotEmpty;
      if (incomingIsEmpty && currentIsNonEmpty) {
        continue;
      }

      if (data.containsKey(key)) {
        final next = _liveCoerce(data[key], value);
        if ('${data[key]}' != '$next') {
          data[key] = next;
          changed = true;
        }
      } else if (identificationKeys.contains(key) ||
          identification.containsKey(key)) {
        final next = _liveCoerce(identification[key], value);
        if ('${identification[key]}' != '$next') {
          identification[key] = next;
          changed = true;
        }
      } else if (addressKeys.contains(key) ||
          address.containsKey(key)) {
        final next = _liveCoerce(address[key], value);
        if ('${address[key]}' != '$next') {
          address[key] = next;
          changed = true;
        }
      } else {
        data[key] = value;
        changed = true;
      }
    }

    if (changed) {
      data['identification'] = identification;
      data['address'] = address;
      if (mounted) setState(() {});
    }
  }

  dynamic _normalizeApiValue(dynamic value) {
    if (value is Map) {
      final normalized = <String, dynamic>{};
      for (final entry in value.entries) {
        final rawKey = entry.key.toString();
        final key = rawKey.isEmpty
            ? rawKey
            : '${rawKey[0].toLowerCase()}${rawKey.substring(1)}';
        final normalizedValue = _normalizeApiValue(entry.value);
        if (!normalized.containsKey(key) || rawKey == key) {
          normalized[key] = normalizedValue;
        }
      }
      return normalized;
    }
    if (value is List) {
      return value.map(_normalizeApiValue).toList();
    }
    return value;
  }

  Map<String, dynamic> _unwrap(dynamic decoded) {
    final normalized = _normalizeApiValue(decoded);
    if (normalized is Map<String, dynamic>) {
      final data = normalized['data'];
      if (data is Map) return Map<String, dynamic>.from(data);
      return Map<String, dynamic>.from(normalized);
    }
    throw Exception('استجابة بيانات المعلم غير صالحة');
  }

  void _normalizeTeacherFields(Map<String, dynamic> teacher) {
    final rawId = teacher['identification'];
    final identification = rawId is Map
        ? rawId.map((k, v) => MapEntry(k.toString(), v))
        : <String, dynamic>{};
    identification['idNumber'] = (identification['idNumber'] ?? identification['IdNumber'] ?? '').toString();
    identification['issuingCountry'] = (identification['issuingCountry'] ?? identification['IssuingCountry'] ?? AppCore.defaultCountry).toString();
    identification['idType'] = identification['idType'] ?? identification['IdType'] ?? (int.tryParse(AppCore.defaultIdType) ?? 12);
    identification['nameOfDocument'] = (identification['nameOfDocument'] ?? '').toString();
    identification['recordNumber'] = (identification['recordNumber'] ?? '').toString();
    identification['pageNumber'] = (identification['pageNumber'] ?? '').toString();
    identification['issuer'] = (identification['issuer'] ?? '').toString();
    identification['issuingDate'] = _cleanDate(identification['issuingDate']);
    teacher['identification'] = identification;

    final rawEmp = teacher['employmentRecord'];
    final employment = rawEmp is Map
        ? rawEmp.map((k, v) => MapEntry(k.toString(), v))
        : <String, dynamic>{};

    final rawStatuses = teacher['employmentStatuses'] ??
        teacher['EmploymentStatuses'] ??
        employment['employmentStatuses'] ??
        employment['EmploymentStatuses'];
    final statuses = rawStatuses is List
        ? rawStatuses.whereType<Map<String, dynamic>>().map((x) => x.map((k, v) => MapEntry(k.toString(), v))).toList()
        : <Map<String, dynamic>>[];

    final rawPositions = teacher['employmentPositions'] ??
        teacher['EmploymentPositions'] ??
        employment['employmentPositions'] ??
        employment['EmploymentPositions'];
    final positions = rawPositions is List
        ? rawPositions.whereType<Map<String, dynamic>>().map((x) => x.map((k, v) => MapEntry(k.toString(), v))).toList()
        : <Map<String, dynamic>>[];

    Map<String, dynamic>? latestStatus = statuses.isNotEmpty ? statuses.first : null;
    Map<String, dynamic>? latestPosition = positions.isNotEmpty ? positions.first : null;

    final rawStatusType = (latestStatus?['statusType'] ?? latestStatus?['StatusType'] ?? '').toString();
    teacher['employmentStatus'] = rawStatusType == 'Active' ? 'مستمر' : rawStatusType;
    teacher['employmentStatusReason'] = (latestStatus?['reason'] ?? latestStatus?['Reason'] ?? '').toString();
    teacher['assignedEntityName'] = (latestStatus?['assignedEntityName'] ?? latestStatus?['AssignedEntityName'] ?? '').toString();

    // EMIS getemployee returns these two fields at the ROOT of the employee
    // object (not inside EmploymentRecord). Keep nested fallbacks for older API
    // responses, but prefer the actual top-level values.
    teacher['positionType'] = (teacher['currentEmploymentPosition'] ??
            teacher['CurrentEmploymentPosition'] ??
            employment['currentEmploymentPosition'] ??
            employment['CurrentEmploymentPosition'] ??
            teacher['positionType'] ??
            '')
        .toString();
    teacher['currentPosition'] = (teacher['currentPosition'] ??
            teacher['CurrentPosition'] ??
            latestPosition?['position'] ??
            latestPosition?['Position'] ??
            AppCore.defaultCurrentPosition)
        .toString();

    teacher['employmentRecord'] = employment;

    final rawAddr = teacher['address'];
    final address = rawAddr is Map
        ? rawAddr.map((k, v) => MapEntry(k.toString(), v))
        : <String, dynamic>{};
    address['addressType'] = address['addressType'] ?? 1;
    address['countryStructureId'] = address['countryStructureId'] ?? 1;

    final currentTown = (address['town'] ?? '').toString().trim();
    address['town'] = currentTown.isNotEmpty ? currentTown : AppCore.defaultTown;

    final currentArea = (address['area'] ?? '').toString().trim();
    address['area'] = currentArea.isNotEmpty ? currentArea : AppCore.defaultArea;

    address['quarter'] = (address['quarter'] ?? '').toString();
    address['street'] = (address['street'] ?? '').toString();
    address['address1'] = (address['branch'] ?? address['address1'] ?? '').toString();

    final currentAddr2 = (address['neighborhood'] ?? address['address2'] ?? '').toString().trim();
    address['address2'] = currentAddr2.isNotEmpty ? currentAddr2 : AppCore.defaultAddress2;

    final currentClosest = (address['closestLocation'] ?? '').toString().trim();
    address['closestLocation'] = currentClosest.isNotEmpty ? currentClosest : AppCore.defaultClosestLocation;

    address['mobilePhoneNumber'] = (address['mobilePhoneNumber'] ?? '').toString();
    address['email'] = (address['email'] ?? '').toString();
    teacher['address'] = address;

    teacher['name'] = (teacher['name'] ?? '').toString();
    teacher['fatherName'] = (teacher['fatherName'] ?? '').toString();
    teacher['grandFatherName'] = (teacher['grandFatherName'] ?? '').toString();
    teacher['fathersGrandFatherName'] = (teacher['fathersGrandFatherName'] ?? '').toString();
    teacher['surName'] = (teacher['surName'] ?? '').toString();
    teacher['motherName'] = (teacher['motherName'] ?? '').toString();
    teacher['mothersFatherName'] = (teacher['mothersFatherName'] ?? '').toString();
    teacher['mothersGrandFatherName'] = (teacher['mothersGrandFatherName'] ?? '').toString();
    teacher['dateOfBirth'] = _cleanDate(teacher['dateOfBirth']);
    teacher['gender'] = teacher['gender'] ?? (int.tryParse(AppCore.defaultGender) ?? 1);
    teacher['nationality'] = (teacher['nationality'] ?? AppCore.defaultCountry).toString();
    teacher['countryOfBirth'] = (teacher['countryOfBirth'] ?? AppCore.defaultCountry).toString();

    final currentHomeTown = (teacher['homeTown'] ?? '').toString().trim();
    teacher['homeTown'] = currentHomeTown.isNotEmpty ? currentHomeTown : AppCore.defaultHomeTown;

    teacher['motherTongue'] = (teacher['motherTongue'] ?? AppCore.defaultMotherTongue).toString();
    teacher['maritalStatus'] = (teacher['maritalStatus'] ?? '').toString();

    final currentBlood = (teacher['bloodGroup'] ?? '').toString().trim();
    teacher['bloodGroup'] = currentBlood.isNotEmpty ? currentBlood : AppCore.defaultBloodGroup;
    teacher['religion'] = (teacher['religion'] ?? AppCore.defaultReligion).toString();
    teacher['employeeIdNumber'] = (teacher['employeeIdNumber'] ?? '').toString();
    teacher['familyNumber'] = (teacher['familyNumber'] ?? '').toString();
    teacher['notes'] = (teacher['notes'] ?? '').toString();
    teacher['status'] = teacher['status'] ?? 1;

    final currentEmpType = (teacher['employmentType'] ?? teacher['EmploymentType'] ?? '').toString().trim();
    teacher['employmentType'] = currentEmpType.isNotEmpty ? currentEmpType : AppCore.defaultEmploymentType;
    final currentEmpCat = (teacher['employeeCategory'] ?? '').toString().trim();
    teacher['employeeCategory'] = currentEmpCat.isNotEmpty ? currentEmpCat : AppCore.defaultEmployeeCategory;
    final currentClass = (teacher['classification'] ?? teacher['Classification'] ?? '').toString().trim();
    teacher['classification'] = currentClass.isNotEmpty ? currentClass : AppCore.defaultClassification;
    teacher['jobDesignation'] = (teacher['jobDesignation'] ?? '').toString();
    teacher['employmentGrade'] = (teacher['employmentGrade'] ?? '').toString();
    teacher['weeklyTeachingQuota'] = (teacher['weeklyTeachingQuota'] ?? '').toString();
    teacher['dateOfStartWorking'] = _cleanDate(teacher['dateOfStartWorking']);
    teacher['educationLevel'] = (teacher['educationLevel'] ?? AppCore.defaultEducationLevel).toString();
    teacher['universityName'] = (teacher['universityName'] ?? '').toString();
    teacher['graduationYear'] = _cleanDate(teacher['graduationYear']);
    teacher['specialization'] = (teacher['specialization'] ?? '').toString();
    teacher['specialNeedsInformation'] = (teacher['specialNeedsInformation'] ?? '').toString();
    teacher['emergencyContactName'] = (teacher['emergencyContactName'] ?? '').toString();
    teacher['emergencyContactRelationship'] = (teacher['emergencyContactRelationship'] ?? '').toString();
    teacher['emergencyContactPhoneNumber'] = (teacher['emergencyContactPhoneNumber'] ?? '').toString();
  }

  String _cleanDate(dynamic raw) {
    if (raw == null) return '';
    final str = raw.toString().trim();
    if (str.isEmpty || str.startsWith('0001-01-01') || str == '1-01-01') return '';
    if (str.contains('T')) return str.split('T').first;
    return str;
  }

  Future<void> _fetchTeacherData() async {
    try {
      setState(() => _isLoading = true);

      await AppCore.ensureLoaded();

      final response = await http.get(
        Uri.parse('https://emis.moedu.gov.iq/api/employee/getemployee/${widget.teacherId}'),
        headers: {'Authorization': widget.token, 'Accept': 'application/json', 'Cache-Control': 'no-cache', 'Pragma': 'no-cache'},
      );
      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}');
      }

      final teacher = _unwrap(jsonDecode(utf8.decode(response.bodyBytes)));
      _normalizeTeacherFields(teacher);

      _teacherData = teacher;
      _ensureOptionIncludesCurrentValue(teacher);

      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }

      for (final key in _optionEndpoints.keys) {
        await _loadOptions(key);
      }
      await _loadEmployeesOptions();
      _ensureOptionIncludesCurrentValue(teacher);
      await _loadCountryStructure();

      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('خطأ في جلب بيانات المعلم: $e');
      if (mounted) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('فشل جلب بيانات المعلم: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  void _ensureOptionIncludesCurrentValue(Map<String, dynamic> teacher) {
    // اختبار المصدر الحقيقي فقط: لا نضيف قيمة السجل كخيار بديل عن كتالوج EMIS.
  }

  Future<List<Map<String, dynamic>>> _getOptions(String path) async {
    try {
      final encodedPath = Uri.encodeFull('https://emis.moedu.gov.iq/api$path');
      final response = await http.get(
        Uri.parse(encodedPath),
        headers: {'Authorization': widget.token, 'Accept': 'application/json'},
      );
      if (response.statusCode != 200) {
        debugPrint('EMIS select list HTTP ${response.statusCode}: $path');
        return <Map<String, dynamic>>[];
      }
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      // value الحقيقي يُقرأ بترتيب value/id/code/shortName (كان value/id فقط فتسقط
      // العناصر التي تحمل code أو shortName من القائمة بصمت).
      return EmisOptions.parseList(decoded);
    } catch (e) {
      debugPrint('تجاوز خطأ خيارات $path: $e');
      return <Map<String, dynamic>>[];
    }
  }

  Future<void> _loadOptions(String key) async {
    if (_loadingOptions.contains(key)) return;
    final endpoint = _optionEndpoints[key];
    if (endpoint == null) return;
    _loadingOptions.add(key);
    try {
      final fetched = await _getOptions(endpoint);
      // استبدال كامل بنتيجة EMIS، حتى لو كانت فارغة؛ لا نحتفظ بقيم قديمة.
      _options[key] = fetched;
    } catch (e) {
      debugPrint('تعذر تحميل خيارات $key: $e');
    } finally {
      _loadingOptions.remove(key);
    }
  }

  Future<void> _loadEmployeesOptions() async {
    _options.remove('employmentStatus');
    _employmentStatusCatalogLoaded = false;
    try {
      final response = await http.get(
        Uri.parse('https://emis.moedu.gov.iq/api/employee/getemployeesoptions'),
        headers: {'Authorization': widget.token, 'Accept': 'application/json', 'Cache-Control': 'no-cache', 'Pragma': 'no-cache'},
      ).timeout(const Duration(seconds: 25));
      if (response.statusCode != 200) return;
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! Map) return;

      // API keys have appeared with different casing across EMIS releases.
      final source = <String, dynamic>{
        for (final entry in decoded.entries)
          entry.key.toString().toLowerCase(): entry.value,
      };

      List<Map<String, dynamic>> parseOptions(dynamic raw) {
        if (raw is Map && raw['data'] is List) raw = raw['data'];
        if (raw is Map && raw['items'] is List) raw = raw['items'];
        if (raw is! List) return <Map<String, dynamic>>[];
        final parsed = <Map<String, dynamic>>[];
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
          parsed.add(<String, dynamic>{
            'value': value,
            'displayName': title,
          });
        }
        return parsed;
      }

      void replaceFromServer(String key, List<String> sourceKeys) {
        String? matchedKey;
        dynamic raw;
        for (final candidate in sourceKeys) {
          final normalizedKey = candidate.toLowerCase();
          if (source.containsKey(normalizedKey)) {
            matchedKey = normalizedKey;
            raw = source[normalizedKey];
            break;
          }
        }
        if (matchedKey == null) return;
        final parsed = parseOptions(raw);
        // The server response is authoritative, including an empty list.
        _options[key] = parsed;
      }

      final employmentStatuses = EmisEmploymentStatusOptions.extract(decoded);
      if (employmentStatuses != null) {
        // Replace, never merge with the bundled legacy status list.
        _employmentStatusCatalogLoaded = true;
        _options['employmentStatus'] = employmentStatuses;
      }
      replaceFromServer('classification', ['classification']);
      replaceFromServer('employeeCategory', [
        'employeecategory',
        'employeeCategory',
      ]);
      // باقي قوائم النموذج (نوع الملاك، الدرجة، المنصب الحالي، التحصيل، الاختصاص...)
      EmisOptions.extractCatalog(decoded).forEach((key, list) {
        if (list.isNotEmpty) _options[key] = list;
      });
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('تجاوز خطأ getemployeesoptions: $e');
    }
  }

  Future<void> _loadCountryStructure() async {
    try {
      final list = await _getOptions('/CountryStructure/getcountrystructure');
      if (list.isEmpty) return;
      _addressCountries = list;

      final address = _teacherData?['address'] is Map
          ? Map<String, dynamic>.from(_teacherData!['address'] as Map)
          : <String, dynamic>{};
      final stored = address['countryStructureId']?.toString();

      final targetCountry = AppCore.defaultCountry.trim();
      final targetGov = AppCore.defaultGovernorate.trim();
      final targetDist = AppCore.defaultDistrict.trim();

      Map<String, dynamic>? defaultCountryNode;
      for (final item in _addressCountries) {
        final text = _optionText(item);
        if ((targetCountry.isNotEmpty && text.contains(targetCountry)) ||
            text.contains('العراق') ||
            text.toLowerCase() == 'iraq') {
          defaultCountryNode = item;
          break;
        }
      }
      defaultCountryNode ??= _addressCountries.first;
      _addressCountryId = _optionValue(defaultCountryNode)?.toString();
      _addressGovernorates = _childrenOf(defaultCountryNode);

      var foundStoredLocation = false;
      if (stored != null && stored.isNotEmpty && stored != '1') {
        for (final country in _addressCountries) {
          for (final gov in _childrenOf(country)) {
            final districts = _childrenOf(gov);
            for (final district in districts) {
              final districtId = _optionValue(district)?.toString();
              final subdistricts = _childrenOf(district);
              final matchingSubdistrict = subdistricts.where(
                (item) => _optionValue(item)?.toString() == stored,
              ).toList();

              if (districtId == stored || matchingSubdistrict.isNotEmpty) {
                _addressCountryId = _optionValue(country)?.toString();
                _addressGovernorateId = _optionValue(gov)?.toString();
                _addressDistrictId = districtId;
                _addressGovernorates = _childrenOf(country);
                _addressDistricts = districts;
                _addressTowns = subdistricts;
                _addressTownId = matchingSubdistrict.isEmpty
                    ? null
                    : _optionValue(matchingSubdistrict.first)?.toString();
                foundStoredLocation = true;
                break;
              }
            }
            if (foundStoredLocation) break;
          }
          if (foundStoredLocation) break;
        }
      }

      if (!foundStoredLocation && _addressGovernorates.isNotEmpty) {
        for (final gov in _addressGovernorates) {
          if (targetGov.isNotEmpty && _optionText(gov).contains(targetGov)) {
            _addressGovernorateId = _optionValue(gov)?.toString();
            _addressDistricts = _childrenOf(gov);
            if (_addressDistricts.isNotEmpty) {
              final matchedDist = _addressDistricts
                  .where((d) => targetDist.isNotEmpty && _optionText(d).contains(targetDist))
                  .toList();
              final chosenDist = matchedDist.isNotEmpty
                  ? matchedDist.first
                  : _addressDistricts.first;
              _addressDistrictId = _optionValue(chosenDist)?.toString();
              _addressTowns = _childrenOf(chosenDist);
            }
            break;
          }
        }
      }

      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('تعذر تحميل هيكل العناوين: $e');
    }
  }

  List<Map<String, dynamic>> _childrenOf(Map<String, dynamic> node) {
    final raw = node['children'] ?? node['items'] ?? node['subItems'] ?? node['childs'];
    if (raw is! List) return <Map<String, dynamic>>[];
    return raw
        .whereType<Map<String, dynamic>>()
        .map((e) => e.map((k, v) => MapEntry(k.toString(), v)))
        .toList();
  }

  String _formatDateValue(String value) {
    final v = value.trim();
    final iso = RegExp(r'^(\d{4})[-/]?(\d{2})[-/]?(\d{2})$').firstMatch(v);
    if (iso != null) return '${iso.group(1)}-${iso.group(2)}-${iso.group(3)}';
    final dmy = RegExp(r'^(\d{1,2})[-/](\d{1,2})[-/](\d{4})$').firstMatch(v);
    if (dmy != null) {
      return '${dmy.group(3)}-${dmy.group(2)!.padLeft(2, '0')}-${dmy.group(1)!.padLeft(2, '0')}';
    }
    return v.replaceAll('/', '-');
  }

  String _formatTypedDate(String value) {
    final digits = value
        .replaceAll(RegExp(r'[^0-9٠-٩۰-۹]'), '')
        .replaceAllMapped(RegExp('[٠-٩]'),
            (m) => String.fromCharCode(m.group(0)!.codeUnitAt(0) - 0x0660 + 48))
        .replaceAllMapped(RegExp('[۰-۹]'),
            (m) => String.fromCharCode(m.group(0)!.codeUnitAt(0) - 0x06F0 + 48));
    final limited = digits.length > 8 ? digits.substring(0, 8) : digits;
    var out = limited.substring(0, limited.length >= 4 ? 4 : limited.length);
    if (limited.length > 4) {
      out += '-${limited.substring(4, limited.length >= 6 ? 6 : limited.length)}';
    }
    if (limited.length > 6) out += '-${limited.substring(6)}';
    return out;
  }

  String _label(String key) => _officialArabicNames[key] ?? key;

  bool _isDateField(String key) => <String>{
        'dateOfBirth',
        'issuingDate',
        'dateOfStartWorking',
        'graduationYear',
      }.contains(key);

  bool _isDropdownField(String key) =>
      _optionEndpoints.containsKey(key) ||
      _defaultStaticOptions.containsKey(key) ||
      <String>{
        'employmentType',
        'employeeCategory',
        'classification',
        'employmentGrade',
        'currentPosition',
        'positionType',
        'employmentStatus',
        'status',
        'educationLevel',
        'specialization',
      }.contains(key);

  dynamic _optionValue(Map<String, dynamic> option) =>
      option['value'] ?? option['id'] ?? option['code'] ?? option['shortName'];
  String _optionText(Map<String, dynamic> option) =>
      (option['displayName'] ??
              option['name'] ??
              option['label'] ??
              option['text'] ??
              _optionValue(option)?.toString() ??
              '')
          .toString();

  String _text(Map<String, dynamic> option) => _optionText(option);

  bool _sameValue(dynamic a, dynamic b) {
    if (a == null && b == null) return true;
    if (a == null || b == null) return false;
    return a.toString().trim() == b.toString().trim();
  }

  Widget _dropdownField({
    required String key,
    required Map<String, dynamic> owner,
    required bool isDark,
    required Color textColor,
  }) {
    final rawItems = _options[key] ?? const <Map<String, dynamic>>[];
    final value = owner[key];

    final uniqueItems = <Map<String, dynamic>>[];
    for (final item in rawItems) {
      final v = _optionValue(item);
      if (v != null &&
          v.toString().trim().isNotEmpty &&
          !uniqueItems.any((u) => _sameValue(_optionValue(u), v))) {
        uniqueItems.add(item);
      }
    }

    dynamic current = value;
    if (current != null &&
        current.toString().trim().isNotEmpty &&
        !uniqueItems.any((u) => _sameValue(_optionValue(u), current))) {
      // إن كان المخزّن نص الخيار (وليس معرّفه) نطابقه بالنص بدل إضافة خيار مكرر مزيّف.
      final byLabel = uniqueItems
          .where((u) =>
              EmisOptions.norm(_optionText(u)) == EmisOptions.norm(current))
          .toList();
      if (byLabel.isNotEmpty) {
        current = _optionValue(byLabel.first);
      } else {
        uniqueItems.add(<String, dynamic>{
          'value': current,
          'displayName': current.toString(),
        });
      }
    }

    dynamic safeValue;
    for (final item in uniqueItems) {
      if (_sameValue(_optionValue(item), current)) {
        safeValue = _optionValue(item);
        break;
      }
    }

    const blueNeon = Color(0xFF3B82F6);
    final mutedColor = isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);

    return Padding(
      padding: const EdgeInsets.only(bottom: 15),
      child: DropdownButtonFormField<dynamic>(
                 onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
        value: safeValue,
        isExpanded: true,
        dropdownColor: isDark ? const Color(0xFF181D32) : Colors.white,
        iconEnabledColor: blueNeon,
        decoration: InputDecoration(
          labelText: _label(key),
          suffixIcon: null,
          labelStyle: TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 12.5,
            color: mutedColor,
          ),
          filled: true,
          fillColor: isDark
              ? const Color(0xFF0B0E1A).withOpacity(0.68)
              : const Color(0xFFF1F5F9),
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide(
              color: blueNeon.withOpacity(isDark ? 0.35 : 0.25),
              width: 1.2,
            ),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide(
              color: blueNeon.withOpacity(isDark ? 0.35 : 0.25),
              width: 1.2,
            ),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: const BorderSide(color: blueNeon, width: 1.8),
          ),
        ),
        style: TextStyle(
          fontWeight: FontWeight.w800,
          color: isDark ? Colors.white : const Color(0xFF0F172A),
          fontSize: 13.5,
        ),
        items: uniqueItems.map((item) {
          return DropdownMenuItem<dynamic>(
            value: _optionValue(item),
            child: Text(
              _optionText(item),
              style: TextStyle(
                fontWeight: FontWeight.w800,
                color: isDark ? Colors.white : const Color(0xFF0F172A),
                fontSize: 13.5,
              ),
            ),
          );
        }).toList(),
      onChanged: (newValue) {
          setState(() => owner[key] = newValue);
          _focusLive(key);
        },
      ),
    );
  }

  Future<void> _pickDate(Map<String, dynamic> owner, String key) async {
    DateTime initial = DateTime.now();
    final raw = owner[key]?.toString();
    if (raw != null && raw.isNotEmpty) initial = DateTime.tryParse(raw) ?? initial;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial.isAfter(DateTime(2100)) || initial.isBefore(DateTime(1900))
          ? DateTime(1985, 1, 1)
          : initial,
      firstDate: DateTime(1900),
      lastDate: DateTime(2100),
      locale: const Locale('ar'),
    );
    if (picked != null && mounted) {
      final formatted =
          '${picked.year.toString().padLeft(4, '0')}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}';
      _dateControllers.putIfAbsent(key, () => TextEditingController()).value =
          TextEditingValue(
        text: formatted,
        selection: TextSelection.collapsed(offset: formatted.length),
      );
      setState(() => owner[key] = formatted);
      _focusLive(key);
    }
  }

  Widget _fieldFor(
    String key,
    dynamic value,
    Map<String, dynamic> owner,
    bool isDark,
    Color textColor,
  ) {
    if (_isDropdownField(key)) {
      return _dropdownField(
          key: key, owner: owner, isDark: isDark, textColor: textColor);
    }

    if (_isDateField(key)) {
      const blueNeon = Color(0xFF3B82F6);
      final mutedColor = isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);

      return Padding(
        padding: const EdgeInsets.only(bottom: 15),
        child: TextFormField(
          key: ValueKey('date-$key'),
          controller: _dateControllers.putIfAbsent(
            key,
            () => TextEditingController(
                text: _formatDateValue(value?.toString() ?? '')),
          ),
          keyboardType: TextInputType.number,
          inputFormatters: [
            TextInputFormatter.withFunction((oldValue, newValue) {
              final formatted = _formatTypedDate(newValue.text);
              return TextEditingValue(
                text: formatted,
                selection: TextSelection.collapsed(offset: formatted.length),
              );
            }),
          ],
          onChanged: (v) {
            owner[key] = v;
            _focusLive(key);
          },
          onTap: () => _focusLive(key),
          style: TextStyle(
            fontWeight: FontWeight.w800,
            color: isDark ? Colors.white : const Color(0xFF0F172A),
            fontSize: 13.5,
          ),
          decoration: InputDecoration(
            labelText: _label(key),
            labelStyle: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 12.5,
              color: mutedColor,
            ),
            suffixIcon: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: 'اختيار التاريخ',
                  onPressed: () => _pickDate(owner, key),
                  icon: const Icon(Icons.calendar_month_rounded, color: blueNeon),
                ),

              ],
            ),
            filled: true,
            fillColor: isDark
                ? const Color(0xFF0B0E1A).withOpacity(0.68)
                : const Color(0xFFF1F5F9),
            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: BorderSide(
                color: blueNeon.withOpacity(isDark ? 0.35 : 0.25),
                width: 1.2,
              ),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: BorderSide(
                color: blueNeon.withOpacity(isDark ? 0.35 : 0.25),
                width: 1.2,
              ),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: const BorderSide(color: blueNeon, width: 1.8),
            ),
          ),
        ),
      );
    }

    return PlainTextField(
      label: _label(key),
      initialValue: value,
      isDark: isDark,
      textColor: textColor,
      onChanged: (v) {
        owner[key] = v;
        _focusLive(key);
      },
      onTap: () => _focusLive(key),
    );
  }

  Widget _teacherSection(
    String title,
    List<Widget> children,
    bool isDark, {
    bool verticalFields = false,
  }) {
    const purpleNeon = Color(0xFFA855F7);
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        gradient: isDark
            ? LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  const Color(0xFF141829).withOpacity(0.95),
                  Color.lerp(const Color(0xFF0F1322), purpleNeon, 0.08)!,
                ],
              )
            : LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Colors.white.withOpacity(0.96),
                  Color.lerp(const Color(0xFFF8FAFC), purpleNeon, 0.04)!,
                ],
              ),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: purpleNeon.withOpacity(isDark ? 0.45 : 0.30),
          width: 1.3,
        ),
        boxShadow: [
          BoxShadow(
            color: purpleNeon.withOpacity(isDark ? 0.12 : 0.07),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w900,
                color: isDark ? const Color(0xFF6EE7B7) : purpleNeon,
              ),
            ),
            const SizedBox(height: 14),
            ...(verticalFields
                ? children.map((child) => SizedBox(width: double.infinity, child: child))
                : _studentGrid(children)),
          ],
        ),
      ),
    );
  }

  List<Widget> _studentGrid(List<Widget> children) {
    final rows = <Widget>[];
    for (var i = 0; i < children.length;) {
      final current = children[i];
      final isDate = current is Padding &&
          current.child is TextFormField &&
          (current.child as TextFormField).key is ValueKey &&
          ((current.child as TextFormField).key as ValueKey)
              .value
              .toString()
              .startsWith('date-');
      if (isDate) {
        rows.add(SizedBox(width: double.infinity, child: current));
        i++;
      } else {
        final next =
            i + 1 < children.length ? children[i + 1] : const SizedBox();
        final nextIsDate = next is Padding &&
            next.child is TextFormField &&
            (next.child as TextFormField).key is ValueKey &&
            ((next.child as TextFormField).key as ValueKey)
                .value
                .toString()
                .startsWith('date-');
        if (nextIsDate) {
          rows.add(SizedBox(width: double.infinity, child: current));
          i++;
        } else {
          rows.add(Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: current),
              const SizedBox(width: 10),
              Expanded(child: next),
            ],
          ));
          i += 2;
        }
      }
      if (i < children.length) rows.add(const SizedBox(height: 4));
    }
    return rows;
  }

  Widget _addressDropdown(
    String label,
    String? value,
    List<Map<String, dynamic>> items,
    bool isDark,
    Color textColor,
    ValueChanged<String?> onChanged,
  ) {
    final safe =
        items.any((x) => _optionValue(x)?.toString() == value) ? value : null;
    const purpleNeon = Color(0xFFA855F7);
    final mutedColor = isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);

    return Padding(
      padding: const EdgeInsets.only(bottom: 15),
      child: DropdownButtonFormField<String>(
                 onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
        value: safe,
        isExpanded: true,
        dropdownColor: isDark ? const Color(0xFF181D32) : Colors.white,
        iconEnabledColor: purpleNeon,
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
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
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
        style: TextStyle(
          fontWeight: FontWeight.w800,
          color: isDark ? Colors.white : const Color(0xFF0F172A),
          fontSize: 13.5,
        ),
        items: items
            .map((item) => DropdownMenuItem<String>(
                  value: _optionValue(item)?.toString(),
                  child: Text(
                    _optionText(item),
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      color: isDark ? Colors.white : const Color(0xFF0F172A),
                      fontSize: 13.5,
                    ),
                  ),
                ))
            .toList(),
        onChanged: onChanged,
      ),
    );
  }

  List<Widget> _buildIdentificationFields(
    Map<String, dynamic> identification,
    Map<String, dynamic> teacher,
    bool isDark,
    Color textColor,
  ) {
    final idType = int.tryParse(identification['idType']?.toString() ?? AppCore.defaultIdType) ?? 12;
    final widgets = <Widget>[
      _fieldFor('idType', identification['idType'], identification, isDark, textColor),
      _fieldFor('issuingCountry', identification['issuingCountry'], identification, isDark, textColor),
    ];

    if (idType == 3) {
      widgets.addAll([
        _fieldFor('idNumber', identification['idNumber'], identification, isDark, textColor),
        _fieldFor('recordNumber', identification['recordNumber'], identification, isDark, textColor),
        _fieldFor('pageNumber', identification['pageNumber'], identification, isDark, textColor),
        _fieldFor('issuer', identification['issuer'], identification, isDark, textColor),
      ]);
    } else if (idType == 12) {
      widgets.add(
        _fieldFor('idNumber', identification['idNumber'], identification, isDark, textColor),
      );
    } else if (idType == 22) {
      widgets.addAll([
        _fieldFor('idNumber', identification['idNumber'], identification, isDark, textColor),
        _fieldFor('issuingDate', identification['issuingDate'], identification, isDark, textColor),
        _fieldFor('recordNumber', identification['recordNumber'], identification, isDark, textColor),
        _fieldFor('pageNumber', identification['pageNumber'], identification, isDark, textColor),
      ]);
    } else if (idType == 16) {
      widgets.addAll([
        _fieldFor('nameOfDocument', identification['nameOfDocument'], identification, isDark, textColor),
        _fieldFor('idNumber', identification['idNumber'], identification, isDark, textColor),
      ]);
    } else {
      widgets.add(
        _fieldFor('idNumber', identification['idNumber'], identification, isDark, textColor),
      );
    }

    widgets.addAll([
      _fieldFor('employeeIdNumber', teacher['employeeIdNumber'], teacher, isDark, textColor),
      _fieldFor('familyNumber', teacher['familyNumber'], teacher, isDark, textColor),
    ]);

    return widgets;
  }

  List<Widget> _buildTeacherFormSections(bool isDark, Color textColor) {
    final teacher = _teacherData!;
    final identification = teacher['identification'] is Map
        ? Map<String, dynamic>.from(teacher['identification'] as Map)
        : <String, dynamic>{};
    final address = teacher['address'] is Map
        ? Map<String, dynamic>.from(teacher['address'] as Map)
        : <String, dynamic>{};
    final employment = teacher['employmentRecord'] is Map
        ? Map<String, dynamic>.from(teacher['employmentRecord'] as Map)
        : <String, dynamic>{};

    teacher['identification'] = identification;
    teacher['address'] = address;
    teacher['employmentRecord'] = employment;

    Widget field(String key, [Map<String, dynamic>? owner]) {
      final target = owner ?? teacher;
      return _fieldFor(key, target[key], target, isDark, textColor);
    }

    return <Widget>[
      _teacherSection(
        'الاسم الكامل',
        [
          field('name'),
          field('fatherName'),
          field('grandFatherName'),
          field('fathersGrandFatherName'),
          field('surName'),
          field('motherName'),
          field('mothersFatherName'),
          field('mothersGrandFatherName'),
        ],
        isDark,
      ),
      _teacherSection(
        'البيانات الشخصية',
        [
          field('dateOfBirth'),
          field('countryOfBirth'),
          field('gender'),
          field('nationality'),
          field('homeTown'),
          field('motherTongue'),
          field('maritalStatus'),
          field('bloodGroup'),
          field('religion'),
          field('mobilePhoneNumber', address),
          field('notes'),
        ],
        isDark,
      ),
      _teacherSection(
        'وثيقة التعريف والرقم الوظيفي',
        _buildIdentificationFields(identification, teacher, isDark, textColor),
        isDark,
        verticalFields: true,
      ),
      _teacherSection(
        'البيانات الوظيفية',
        [
          field('employmentType'),
          field('employeeCategory'),
          field('classification'),
          field('positionType'),
          field('currentPosition'),
          field('jobDesignation'),
          field('employmentGrade'),
          field('weeklyTeachingQuota'),
          field('dateOfStartWorking'),
        ],
        isDark,
      ),
      _teacherSection(
        'الحالة الوظيفية',
        [
          field('employmentStatus'),
          if (teacher['employmentStatus'] != 'مستمر')
            field('employmentStatusReason'),
          if (teacher['employmentStatus'] ==
              'مكلف او منسب من وزارة التربية الى جهات أخرى')
            field('assignedEntityName'),
          field('status'),
        ],
        isDark,
      ),
      _teacherSection(
        'التحصيل الدراسي والاختصاص',
        [
          field('educationLevel'),
          if (teacher['educationLevel'] == 'دبلوم' ||
              teacher['educationLevel'] == 'بكالوريوس') ...[
            field('universityName'),
            field('graduationYear'),
          ],
          if (!<String>['ابتدائية', 'متوسطة', 'إعدادية']
              .contains(teacher['educationLevel']))
            field('specialization'),
        ],
        isDark,
      ),
      _teacherSection(
        'ذوو الاحتياجات الخاصة والاتصال الطارئ',
        [
          field('specialNeedsInformation'),
          field('emergencyContactName'),
          field('emergencyContactRelationship'),
          field('emergencyContactPhoneNumber'),
        ],
        isDark,
      ),
      _teacherSection(
        'العنوان ومعلومات الاتصال',
        [
          _addressDropdown(
            'الدولة',
            _addressCountryId,
            _addressCountries,
            isDark,
            textColor,
            (v) {
              final country = _addressCountries
                  .where((x) => _sameValue(_optionValue(x), v))
                  .toList();
              if (country.isEmpty) return;
              setState(() {
                _addressCountryId = v;
                _addressGovernorates = _childrenOf(country.first);
                _addressGovernorateId = null;
                _addressDistricts = [];
                _addressDistrictId = null;
                _addressTowns = [];
                _addressTownId = null;
                address['countryStructureId'] = null;
              });
              _focusLive('countryStructureId');
            },
          ),
          _addressDropdown(
            'المحافظة',
            _addressGovernorateId,
            _addressGovernorates,
            isDark,
            textColor,
            (v) {
              final gov = _addressGovernorates
                  .where((x) => _sameValue(_optionValue(x), v))
                  .toList();
              if (gov.isEmpty) return;
              setState(() {
                _addressGovernorateId = v;
                _addressDistricts = _childrenOf(gov.first);
                _addressDistrictId = null;
                _addressTowns = [];
                _addressTownId = null;
                address['countryStructureId'] = null;
              });
              _focusLive('countryStructureId');
            },
          ),
          _addressDropdown(
            'القضاء',
            _addressDistrictId,
            _addressDistricts,
            isDark,
            textColor,
            (v) {
              final district = _addressDistricts
                  .where((x) => _optionValue(x)?.toString() == v)
                  .toList();
              setState(() {
                _addressDistrictId = v;
                _addressTowns =
                    district.isEmpty ? [] : _childrenOf(district.first);
                _addressTownId = null;
                address['countryStructureId'] =
                    v == null ? null : int.tryParse(v);
              });
              _focusLive('countryStructureId');
            },
          ),
          _addressDropdown(
            'الناحية',
            _addressTownId,
            _addressTowns,
            isDark,
            textColor,
            (v) {
              setState(() {
                _addressTownId = v;
                address['countryStructureId'] =
                    int.tryParse(v ?? _addressDistrictId ?? '');
              });
              _focusLive('countryStructureId');
            },
          ),
          field('town', address),
          field('area', address),
          SizedBox(width: double.infinity, child: field('quarter', address)),
          field('street', address),
          field('address1', address),
          field('address2', address),
          field('closestLocation', address),
          field('email', address),
        ],
        isDark,
      ),
    ];
  }

  SelfieSegmenter? _selfieSegmenter;

  Future<void> _initializeSelfieSegmenter() async {
    _selfieSegmenter ??= SelfieSegmenter(
      mode: SegmenterMode.single,
      enableRawSizeMask: false,
    );
  }

  Future<File?> _removeBackgroundUsingSelfieSegmentation(File imageFile) async {
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      return SelfieBackgroundRemover.removeBackground(imageFile);
    }
    File? normalizedFile;
    try {
      await _initializeSelfieSegmenter();
      final segmenter = _selfieSegmenter;
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

      normalizedFile = File(
          '${imageFile.path}_seg_${DateTime.now().millisecondsSinceEpoch}.jpg');
      await normalizedFile.writeAsBytes(img.encodeJpg(source, quality: 90),
          flush: true);

      final mask = await segmenter.processImage(
        InputImage.fromFilePath(normalizedFile.path),
      );
      if (mask == null ||
          mask.width <= 0 ||
          mask.height <= 0 ||
          mask.confidences.isEmpty) {
        throw Exception('لم يتم الحصول على قناع صالح للشخص');
      }
      if (mask.width != source.width || mask.height != source.height) {
        throw Exception('أبعاد القناع غير متطابقة');
      }

      final result =
          img.Image(width: source.width, height: source.height, numChannels: 4);
      final pixelCount = source.width * source.height;
      if (mask.confidences.length < pixelCount) {
        throw Exception('بيانات القناع غير مكتملة');
      }

      for (var y = 0; y < source.height; y++) {
        for (var x = 0; x < source.width; x++) {
          final index = y * source.width + x;
          final confidence = mask.confidences[index].clamp(0.0, 1.0);
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
      if (normalizedFile != null) {
        try {
          if (await normalizedFile.exists()) await normalizedFile.delete();
        } catch (_) {}
      }
    }
  }

  Future<void> _showImagePreviewDialog(File imageFile) async {
    File currentImage = imageFile;
    bool processing = false;

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20)),
              title: const Text('معاينة صورة المعلم',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontWeight: FontWeight.bold)),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      height: 240,
                      width: double.infinity,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        border: Border.all(color: Colors.grey.shade300),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: InteractiveViewer(
                          panEnabled: true,
                          boundaryMargin: const EdgeInsets.all(20),
                          minScale: 0.5,
                          maxScale: 4,
                          child: Image.file(currentImage, fit: BoxFit.contain),
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    const Text('يمكنك تقريب الصورة لمراجعتها قبل اعتمادها',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Colors.grey,
                            fontSize: 12)),
                    const SizedBox(height: 15),
                    if (processing)
                      const Column(
                        children: [
                          CircularProgressIndicator(),
                          SizedBox(height: 10),
                          Text('جاري إزالة الخلفية...'),
                        ],
                      )
                    else
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: () async {
                            setDialogState(() => processing = true);
                            try {
                              final processed =
                                  await _removeBackgroundUsingSelfieSegmentation(
                                      currentImage);
                              if (processed == null) {
                                throw Exception(
                                    'لم يتم الحصول على الصورة المعالجة');
                              }
                              if (!mounted) return;
                              setDialogState(() {
                                currentImage = processed;
                                processing = false;
                              });
                            } catch (e) {
                              if (!mounted) return;
                              setDialogState(() => processing = false);
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                    content: Text('تعذر إزالة الخلفية: $e'),
                                    backgroundColor: Colors.red),
                              );
                            }
                          },
                          icon: const Icon(Icons.auto_fix_high,
                              color: Colors.black87),
                          label: const Text('حذف الخلفية',
                              style: TextStyle(
                                  color: Colors.black87,
                                  fontWeight: FontWeight.bold)),
                          style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.amberAccent),
                        ),
                      ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed:
                      processing ? null : () => Navigator.pop(dialogContext),
                  child: const Text('إلغاء'),
                ),
                ElevatedButton(
                  onPressed: processing
                      ? null
                      : () {
                          setState(() => _pickedImage = currentImage);
                          Navigator.pop(dialogContext);
                        },
                  style:
                      ElevatedButton.styleFrom(backgroundColor: Colors.green),
                  child: const Text('اعتماد',
                      style: TextStyle(
                          fontWeight: FontWeight.bold, color: Colors.white)),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _pickImage(ImageSource source) async {
    try {
      final picked = await pickEmisImage(
        source: source,
        imageQuality: 90,
        maxWidth: 2500,
        maxHeight: 2500,
      );
      if (picked != null && mounted) {
        await _showImagePreviewDialog(File(picked.path));
      }
    } catch (e) {
      debugPrint('خطأ في اختيار الصورة: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('تعذر فتح الكاميرا أو معرض الصور'),
              backgroundColor: Colors.red),
        );
      }
    }
  }

  void _deleteCurrentPhoto() {
    setState(() {
      _pickedImage = null;
      if (_teacherData != null) _teacherData!['imageUrl'] = null;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('تم حذف صورة المعلم')),
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
      filename: 'teacher.png',
    ));
    try {
      final streamedResponse = await request.send();
      final responseData = await streamedResponse.stream.bytesToString();
      if (streamedResponse.statusCode == 200) {
        final jsonResponse = jsonDecode(responseData);
        if (jsonResponse is Map) return jsonResponse['imageUrl']?.toString();
      }
      debugPrint('استجابة رفع الصورة: $responseData');
    } catch (e) {
      debugPrint('خطأ في رفع الصورة إلى EMIS: $e');
    }
    return null;
  }

  void _flattenToFormFields(
    Map<String, String> target,
    String prefix,
    dynamic value,
  ) {
    if (value == null) return;
    if (value is Map) {
      value.forEach((k, v) {
        final nextKey = prefix.isEmpty ? k.toString() : '$prefix.${k.toString()}';
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

  Future<http.Response> _sendUpdateRequest(Map<String, dynamic> payload) async {
    final uri = Uri.parse('https://emis.moedu.gov.iq/api/employee/updateemployee');
    final jsonString = jsonEncode(payload);

    var response = await http.put(
      uri,
      headers: {
        'Authorization': widget.token,
        'Accept': 'application/json',
        'Content-Type': 'application/json; charset=utf-8',
      },
      body: jsonString,
    );
    if (response.statusCode != 405 && response.statusCode != 415) {
      return response;
    }

    response = await http.post(
      uri,
      headers: {
        'Authorization': widget.token,
        'Accept': 'application/json',
        'Content-Type': 'application/json; charset=utf-8',
      },
      body: jsonString,
    );
    if (response.statusCode != 405 && response.statusCode != 415) {
      return response;
    }

    final postMultipart = http.MultipartRequest('POST', uri);
    postMultipart.headers['Authorization'] = widget.token;
    postMultipart.headers['Accept'] = 'application/json';
    _flattenToFormFields(postMultipart.fields, '', payload);
    postMultipart.fields['emp'] = jsonString;
    var streamed = await postMultipart.send();
    response = await http.Response.fromStream(streamed);
    if (response.statusCode != 405 && response.statusCode != 415) {
      return response;
    }

    final putMultipart = http.MultipartRequest('PUT', uri);
    putMultipart.headers['Authorization'] = widget.token;
    putMultipart.headers['Accept'] = 'application/json';
    _flattenToFormFields(putMultipart.fields, '', payload);
    putMultipart.fields['emp'] = jsonString;
    streamed = await putMultipart.send();
    return await http.Response.fromStream(streamed);
  }

  Future<void> _saveTeacherData() async {
    if (_teacherData == null) return;
    setState(() => _isSaving = true);

    try {
      if (_pickedImage != null) {
        final newImageUrl = await _uploadImageToEmisServer(_pickedImage!);
        if (newImageUrl != null && newImageUrl.isNotEmpty) {
          _teacherData!['imageUrl'] = newImageUrl;
        } else {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                  content: Text('تعذر رفع صورة المعلم'),
                  backgroundColor: Colors.red),
            );
          }
          return;
        }
      }

      String? dateOnly(dynamic value) {
        if (value == null) return null;
        final raw = value.toString().trim();
        if (raw.isEmpty) return null;
        final iso = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})').firstMatch(raw);
        if (iso != null) {
          final year = int.parse(iso.group(1)!);
          final month = int.parse(iso.group(2)!);
          final day = int.parse(iso.group(3)!);
          return '${year.toString().padLeft(4, '0')}-${month.toString().padLeft(2, '0')}-${day.toString().padLeft(2, '0')}';
        }
        if (RegExp(r'^\d{4}$').hasMatch(raw)) {
          return '$raw-01-01';
        }
        return null;
      }

      final old = _teacherData!;
      final identification = old['identification'] is Map
          ? Map<String, dynamic>.from(old['identification'] as Map)
          : <String, dynamic>{};
      final oldAddress = old['address'] is Map
          ? Map<String, dynamic>.from(old['address'] as Map)
          : <String, dynamic>{};
      final oldEmployment = old['employmentRecord'] is Map
          ? Map<String, dynamic>.from(old['employmentRecord'] as Map)
          : <String, dynamic>{};

      String text(String key) {
        final v = old[key];
        return v == null ? '' : '$v'.trim();
      }

      final quota = int.tryParse(text('weeklyTeachingQuota'));
      final todayIso = DateTime.now().toIso8601String().split('T').first;
      final structureIdInt = int.tryParse(
            _addressTownId ??
                _addressDistrictId ??
                oldAddress['countryStructureId']?.toString() ??
                '1',
          ) ??
          1;

      final payload = <String, dynamic>{
        'Id': int.tryParse(widget.teacherId) ?? old['id'],
        'EmployeeIdNumber': text('employeeIdNumber'),
        'FamilyNumber': _nullable(text('familyNumber')),
        'IsTeacher': true,
        'EmploymentType': _nullable(text('employmentType')) ?? AppCore.defaultEmploymentType,
        'EmployeeCategory': _nullable(text('employeeCategory')) ?? AppCore.defaultEmployeeCategory,
        'Classification': _nullable(text('classification')) ?? AppCore.defaultClassification,
        'JobDesignation': _nullable(text('jobDesignation')),
        'EmploymentGrade': _nullable(text('employmentGrade')),
        'WeeklyTeachingQuota': quota,
        'DateOfStartWorking':
            dateOnly(text('dateOfStartWorking')) ?? todayIso,
        'EducationLevel': text('educationLevel').isNotEmpty
            ? text('educationLevel')
            : AppCore.defaultEducationLevel,
        'GraduationYear': _nullable(dateOnly(text('graduationYear'))),
        'UniversityName': _nullable(text('universityName')),
        'Specialization': text('specialization'),
        'Name': text('name'),
        'FatherName': text('fatherName'),
        'GrandFatherName': text('grandFatherName'),
        'FathersGrandFatherName': text('fathersGrandFatherName'),
        'SurName': text('surName'),
        'MotherName': text('motherName'),
        'MothersFatherName': text('mothersFatherName'),
        'MothersGrandFatherName': text('mothersGrandFatherName'),
        'ImageUrl': old['imageUrl']?.toString() ?? '',
        'DateOfBirth': dateOnly(text('dateOfBirth')) ?? todayIso,
        'Gender': _intOrNull(text('gender')) ??
            _intOrNull(AppCore.defaultGender) ??
            1,
        'Nationality': text('nationality').isNotEmpty
            ? text('nationality')
            : AppCore.defaultCountry,
        'CountryOfBirth': text('countryOfBirth').isNotEmpty
            ? text('countryOfBirth')
            : AppCore.defaultCountry,
        'HomeTown': text('homeTown'),
        'IdentificationId': 0,
        'Identification': <String, dynamic>{
          'IdNumber': (identification['idNumber'] ?? '').toString().trim(),
          'IssuingCountry':
              (identification['issuingCountry'] ?? AppCore.defaultCountry)
                  .toString()
                  .trim(),
          'IdType': _intOrNull(identification['idType']?.toString() ?? '') ??
              _intOrNull(AppCore.defaultIdType) ??
              12,
          'nameOfDocument':
              _nullable(identification['nameOfDocument']?.toString()),
          'recordNumber': _nullable(identification['recordNumber']?.toString()),
          'pageNumber': _nullable(identification['pageNumber']?.toString()),
          'issuer': _nullable(identification['issuer']?.toString()),
          'issuingDate': dateOnly(identification['issuingDate']),
        },
        'FatherIdentificationId': null,
        'FatherIdentification': null,
        'MotherTongue': text('motherTongue').isNotEmpty
            ? text('motherTongue')
            : AppCore.defaultMotherTongue,
        'MaritalStatus': text('maritalStatus'),
        'BloodGroup': text('bloodGroup').isNotEmpty
            ? text('bloodGroup')
            : AppCore.defaultBloodGroup,
        'Religion': text('religion').isNotEmpty
            ? text('religion')
            : AppCore.defaultReligion,
        'HomePhoneNumber': old['homePhoneNumber']?.toString() ?? '',
        'Status': _intOrNull(text('status')) ?? 1,
        'Notes': text('notes'),
        'SpecialNeedsInformation': _nullable(text('specialNeedsInformation')),
        'EmergencyContactName': _nullable(text('emergencyContactName')),
        'EmergencyContactRelationship':
            _nullable(text('emergencyContactRelationship')),
        'EmergencyContactPhoneNumber':
            _nullable(text('emergencyContactPhoneNumber')),
        'Address': <String, dynamic>{
          'AddressType': 1,
          'Town': (oldAddress['town'] ?? AppCore.defaultTown).toString().trim(),
          'Area': (oldAddress['area'] ?? AppCore.defaultArea).toString().trim(),
          'Quarter': (oldAddress['quarter'] ?? '').toString().trim(),
          'Street': (oldAddress['street'] ?? '').toString().trim(),
          'ClosestLocation':
              (oldAddress['closestLocation'] ?? AppCore.defaultClosestLocation)
                  .toString()
                  .trim(),
          'countryStructureId': structureIdInt,
          'Latitude': '0',
          'Longitude': '0',
          'ApartmentNumber': oldAddress['apartmentNumber']?.toString() ?? '',
          'BuildingNumber': oldAddress['buildingNumber']?.toString() ?? '',
          'Address1': (oldAddress['address1'] ?? '').toString().trim(),
          'Address2':
              (oldAddress['address2'] ?? AppCore.defaultAddress2).toString().trim(),
          'SchoolPhoneNumber':
              oldAddress['schoolPhoneNumber']?.toString() ?? '',
          'MobilePhoneNumber':
              (oldAddress['mobilePhoneNumber'] ?? '').toString().trim(),
          'Email': (oldAddress['email'] ?? '').toString().trim(),
          'Fax': '',
          'Website': oldAddress['website']?.toString() ?? '',
        },
        'AgeExceptionReason': old['ageExceptionReason'],
        'AgeExceptionAttachmentUrl': old['ageExceptionAttachmentUrl'],
        'ageExceptionAttachment': null,
        // Match the successful EMIS web request: employment fields are root
        // properties, not nested under EmploymentRecord.
        ..._buildEmploymentRecord(oldEmployment),
      };

      final response = await _sendUpdateRequest(payload);

      if (!mounted) return;

      if (response.statusCode == 200 || response.statusCode == 204) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('تم حفظ تعديلات المعلم بنجاح!'),
              backgroundColor: Colors.green),
        );
        Navigator.pop(context, true);
      } else {
        debugPrint('Update teacher status: ${response.statusCode}');
        debugPrint('Update teacher response: ${response.body}');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            duration: const Duration(seconds: 12),
            content: Text(
                'فشل الحفظ (HTTP ${response.statusCode})\n${response.body}',
                maxLines: 6,
                overflow: TextOverflow.ellipsis),
            backgroundColor: Colors.red,
          ),
        );
      }
    } catch (e) {
      debugPrint('خطأ في حفظ بيانات المعلم: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            duration: const Duration(seconds: 12),
            content: Text('تعذر إكمال الحفظ\n$e',
                maxLines: 6, overflow: TextOverflow.ellipsis),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Map<String, dynamic> _buildEmploymentRecord(Map<String, dynamic> old) {
    // Employment data may be nested under employmentRecord in the loaded
    // teacher payload. Keep the fallback local to this method; oldEmployment
    // is not in scope here.
    final employment = old['employmentRecord'] is Map
        ? Map<String, dynamic>.from(old['employmentRecord'] as Map)
        : <String, dynamic>{};
    final schoolIdInt = int.tryParse(widget.schoolId) ??
        (old['currentBelongToEntityId'] is int
            ? old['currentBelongToEntityId'] as int
            : (employment['currentBelongToEntityId'] is int
                ? employment['currentBelongToEntityId'] as int
                : int.tryParse(
                      employment['currentBelongToEntityId']?.toString() ??
                          old['currentBelongToEntityId']?.toString() ??
                          '',
                    ) ??
                    1));
    final empStatus =
        (_teacherData?['employmentStatus'] ?? '')
            .toString();
    final isCurrentlyActive = empStatus.isEmpty || empStatus == 'مستمر';
    final startWorking =
        _cleanDate(_teacherData?['dateOfStartWorking']).isNotEmpty
            ? _cleanDate(_teacherData?['dateOfStartWorking'])
            : DateTime.now().toIso8601String().split('T').first;

    return <String, dynamic>{
      'InitiateDate': startWorking,
      'EmploymentStatuses': <Map<String, dynamic>>[
        <String, dynamic>{
          'StatusType': empStatus,
          'DisEngagementDate': null,
          'MinistryOfficialDocumentNumber': null,
          'Reason':
              _nullable(_teacherData?['employmentStatusReason']?.toString()),
          'AssignedEntityName':
              _nullable(_teacherData?['assignedEntityName']?.toString()),
          'CurrentBelongToEntityId': schoolIdInt,
        }
      ],
      'EmploymentPositions': <Map<String, dynamic>>[
        <String, dynamic>{
          'Position': (_teacherData?['currentPosition'] ??
                  AppCore.defaultCurrentPosition)
              .toString(),
          'InitiateDate': startWorking,
        }
      ],
      'IsCurrentlyActive': isCurrentlyActive,
      'CurrentBelongToEntityId': schoolIdInt,
      'CurrentEmploymentPosition':
          (_teacherData?['positionType'] ?? old['currentEmploymentPosition'] ??
                  old['CurrentEmploymentPosition'] ?? '')
              .toString(),
      'CurrentPosition': (_teacherData?['currentPosition'] ??
              old['currentPosition'] ?? old['CurrentPosition'] ??
              AppCore.defaultCurrentPosition)
          .toString(),
    };
  }

  dynamic _nullable(dynamic value) {
    if (value == null) return null;
    final s = '$value'.trim();
    return s.isEmpty ? null : s;
  }

  int? _intOrNull(String value) => int.tryParse(value.trim());

  @override
  void dispose() {
    _liveTimer?.cancel();
    unawaited(GoogleSpeechService.cancelListening());
    _teacherVoiceSubscription?.cancel();
    if (_teacherVoiceSettingsListener != null) {
      AppCore.voiceSettingsRevision.removeListener(_teacherVoiceSettingsListener!);
      _teacherVoiceSettingsListener = null;
    }
    _ambientController.dispose();
    final segmenter = _selfieSegmenter;
    _selfieSegmenter = null;
    if (segmenter != null) segmenter.close();
    for (final controller in _dateControllers.values) {
      controller.dispose();
    }
    _dateControllers.clear();
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
    const blueNeon = Color(0xFF3B82F6);

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
          child: Row(
            children: [
              _AnimatedEditTeacherOrbIcon(
                icon: Icons.edit_note_rounded,
                primaryColor: purpleNeon,
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
                      'نظام إدارة المعلمين',
                      style: TextStyle(
                        color: isDark ? goldNeon : purpleNeon,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'تعديل بيانات المعلم',
                      style: TextStyle(
                        color: isDark ? Colors.white : const Color(0xFF0F172A),
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'تحديث السجلات والبيانات الشخصية والوظيفية في EMIS',
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
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? const Color(0xFF070913) : const Color(0xFFF2F5FA);
    final cardColor = isDark ? const Color(0xFF141829) : Colors.white;
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);

    const purpleNeon = Color(0xFFA855F7);
    const emeraldNeon = Color(0xFF10B981);
    const goldNeon = Color(0xFFF59E0B);
    const blueNeon = Color(0xFF3B82F6);

    String imgUrl = _teacherData?['imageUrl']?.toString() ?? '';
    if (imgUrl.isNotEmpty && !imgUrl.startsWith('http')) {
      imgUrl = 'https://emis.moedu.gov.iq$imgUrl';
    }

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: bgColor,
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
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator(color: purpleNeon))
                  : _teacherData == null
                      ? Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Text('فشل جلب البيانات',
                                  style: TextStyle(
                                      fontSize: 16, fontWeight: FontWeight.w900)),
                              const SizedBox(height: 12),
                              FilledButton.icon(
                                style: FilledButton.styleFrom(
                                  backgroundColor: purpleNeon,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                ),
                                onPressed: _fetchTeacherData,
                                icon: const Icon(Icons.refresh_rounded),
                                label: const Text('إعادة المحاولة',
                                    style: TextStyle(fontWeight: FontWeight.bold)),
                              ),
                            ],
                          ),
                        )
                      : Column(
                          children: [
                            Padding(
                              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                              child: _buildTopHeader(isDark),
                            ),
                            Expanded(
                              child: Form(
                                key: _formKey,
                                child: ListView(
                                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 28),
                                  physics: const BouncingScrollPhysics(),
                                  children: [
                                    Center(
                                      child: Stack(
                                        children: [
                                          Container(
                                            width: 140,
                                            height: 140,
                                            decoration: BoxDecoration(
                                              color: Colors.white,
                                              shape: BoxShape.circle,
                                              border: Border.all(
                                                  color: purpleNeon, width: 2.5),
                                              boxShadow: [
                                                BoxShadow(
                                                  color: purpleNeon.withOpacity(0.25),
                                                  blurRadius: 16,
                                                  offset: const Offset(0, 6),
                                                ),
                                              ],
                                            ),
                                            child: ClipOval(
                                              child: _pickedImage != null
                                                  ? Image.file(_pickedImage!,
                                                      fit: BoxFit.cover)
                                                  : imgUrl.isNotEmpty
                                                      ? Image.network(
                                                          imgUrl,
                                                          headers: {
                                                            'Authorization':
                                                                widget.token
                                                          },
                                                          fit: BoxFit.cover,
                                                          errorBuilder:
                                                              (_, __, ___) => Icon(
                                                                  Icons.person_rounded,
                                                                  size: 80,
                                                                  color: Colors
                                                                      .grey[400]),
                                                        )
                                                      : Icon(Icons.person_rounded,
                                                          size: 80,
                                                          color: Colors.grey[400]),
                                            ),
                                          ),
                                          Positioned(
                                            bottom: 0,
                                            right: 0,
                                            child: CircleAvatar(
                                              backgroundColor: blueNeon,
                                              radius: 20,
                                              child: IconButton(
                                                icon: const Icon(Icons.camera_alt_rounded,
                                                    color: Colors.white, size: 18),
                                                onPressed: () =>
                                                    _pickImage(ImageSource.camera),
                                              ),
                                            ),
                                          ),
                                          Positioned(
                                            bottom: 0,
                                            left: 0,
                                            child: CircleAvatar(
                                              backgroundColor: emeraldNeon,
                                              radius: 20,
                                              child: IconButton(
                                                icon: const Icon(
                                                    Icons.photo_library_rounded,
                                                    color: Colors.white,
                                                    size: 18),
                                                onPressed: () =>
                                                    _pickImage(ImageSource.gallery),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(height: 10),
                                    Center(
                                      child: TextButton.icon(
                                        onPressed: _deleteCurrentPhoto,
                                        icon: const Icon(Icons.delete_forever_rounded,
                                            color: Color(0xFFEF4444)),
                                        label: const Text('حذف الصورة الحالية',
                                            style: TextStyle(
                                                color: Color(0xFFEF4444),
                                                fontWeight: FontWeight.w900)),
                                      ),
                                    ),
                                    const SizedBox(height: 15),
                                    ..._buildTeacherFormSections(isDark, textColor),
                                  ],
                                ),
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                color: cardColor,
                                border: Border(
                                  top: BorderSide(
                                    color: purpleNeon.withOpacity(0.2),
                                  ),
                                ),
                              ),
                              child: SizedBox(
                                width: double.infinity,
                                height: 56,
                                child: FilledButton(
                                  onPressed: _isSaving ? null : _saveTeacherData,
                                  style: FilledButton.styleFrom(
                                    backgroundColor: emeraldNeon,
                                    shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(16)),
                                    elevation: 6,
                                    shadowColor: emeraldNeon.withOpacity(0.35),
                                  ),
                                  child: _isSaving
                                      ? const SizedBox(
                                          width: 22,
                                          height: 22,
                                          child: CircularProgressIndicator(
                                              strokeWidth: 2, color: Colors.white),
                                        )
                                      : const Text('حفظ التعديلات',
                                          style: TextStyle(
                                              fontSize: 17,
                                              color: Colors.white,
                                              fontWeight: FontWeight.w900)),
                                ),
                              ),
                            ),
                          ],
                        ),
            ),
            Positioned(
              left: 0,
              bottom: 0,
              child: EmisLiveSync(
                key: _liveSyncKey,
                url:
                    'https://emis.moedu.gov.iq/centers/schools/${widget.schoolId}/individuals/teachers/management/edit/${widget.teacherId}',
                mode: 'edit',
                entity: 'teacher',
                token: widget.token,
                recordId: widget.teacherId,
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
  }
}

class PlainTextField extends StatefulWidget {
  final String label;
  final dynamic initialValue;
  final bool isDark;
  final Color textColor;
  final Function(String) onChanged;
  final bool readOnly;
  final VoidCallback? onTap;
  final VoidCallback? onMic;
  final bool micActive;

  const PlainTextField({
    super.key,
    required this.label,
    required this.initialValue,
    required this.isDark,
    required this.textColor,
    required this.onChanged,
    this.readOnly = false,
    this.onTap,
    this.onMic,
    this.micActive = false,
  });

  @override
  State<PlainTextField> createState() => _PlainTextFieldState();
}

class _PlainTextFieldState extends State<PlainTextField> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller =
        TextEditingController(text: widget.initialValue?.toString() ?? '');
  }

  @override
  void didUpdateWidget(covariant PlainTextField oldWidget) {
    super.didUpdateWidget(oldWidget);
    final next = widget.initialValue?.toString() ?? '';
    if (next != _controller.text) {
      _controller.value = TextEditingValue(
        text: next,
        selection: TextSelection.collapsed(offset: next.length),
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const purpleNeon = Color(0xFFA855F7);
    final mutedColor = widget.isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);

    return Padding(
      padding: const EdgeInsets.only(bottom: 15),
      child: TextFormField(
        controller: _controller,
        readOnly: widget.readOnly,
        onChanged: widget.onChanged,
        onTap: widget.onTap,
        validator: null,
        style: TextStyle(
          fontWeight: FontWeight.w800,
          color: widget.isDark ? Colors.white : const Color(0xFF0F172A),
          fontSize: 13.5,
        ),
        decoration: InputDecoration(
          labelText: widget.label,
          labelStyle: TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 12.5,
            color: mutedColor,
          ),
          filled: true,
          fillColor: widget.isDark
              ? const Color(0xFF0B0E1A).withOpacity(0.68)
              : const Color(0xFFF1F5F9),
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
          suffixIcon: null,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide(
              color: purpleNeon.withOpacity(widget.isDark ? 0.35 : 0.25),
              width: 1.2,
            ),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide(
              color: purpleNeon.withOpacity(widget.isDark ? 0.35 : 0.25),
              width: 1.2,
            ),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: const BorderSide(color: purpleNeon, width: 1.8),
          ),
        ),
      ),
    );
  }
}

class _AnimatedEditTeacherOrbIcon extends StatelessWidget {
  final IconData icon;
  final Color primaryColor;
  final Color secondaryColor;
  final Animation<double> animation;
  final double size;

  const _AnimatedEditTeacherOrbIcon({
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
                  painter: _EditTeacherAtomOrbitPainter(
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

class _EditTeacherAtomOrbitPainter extends CustomPainter {
  final double progress;
  final Color primaryColor;
  final Color secondaryColor;

  _EditTeacherAtomOrbitPainter({
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
  bool shouldRepaint(covariant _EditTeacherAtomOrbitPainter oldDelegate) =>
      oldDelegate.progress != progress;
}
