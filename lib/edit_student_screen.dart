import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'platform_permissions.dart';

import 'selfie_background_remover.dart';
import 'app_core.dart';
import 'google_speech_service.dart';
import 'voice_result_processor.dart';
import 'package:image/image.dart' as img;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'platform_image_picker.dart';
import 'package:google_mlkit_selfie_segmentation/google_mlkit_selfie_segmentation.dart';
import 'emis_live_sync.dart';

class EditStudentScreen extends StatefulWidget {
  final String token;
  final String studentId;

  const EditStudentScreen({
    super.key,
    required this.token,
    required this.studentId,
  });

  @override
  State<EditStudentScreen> createState() => _EditStudentScreenState();
}

class _EditStudentScreenState extends State<EditStudentScreen>
    with SingleTickerProviderStateMixin {
  bool _isLoading = true;
  bool _isSaving = false;
  final GlobalKey<EmisLiveSyncState> _liveSyncKey = GlobalKey<EmisLiveSyncState>();
  Timer? _liveTimer;
  String _liveStatus = 'المزامنة الحية مع EMIS قيد التشغيل';
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();

  Map<String, dynamic>? _studentData;
  File? _pickedImage;
  StreamSubscription<Map<String, dynamic>>? _speechSubscription;
  VoidCallback? _appCoreSettingsListener;
  int _speechSessionCounter = 0;
  int? _activeSpeechSession;
  Map<String, dynamic>? _activeSpeechOwner;
  String? _activeSpeechKey;
  bool _speechListening = false;
  String? _speechError;
  final Map<String, TextEditingController> _dateControllers = {};
  String _accumulatedGoogleDigits = '';
  String _accumulatedGoogleText = '';

  // متغير تفعيل قسم هوية الأب في شاشة التعديل
  bool _includeFatherId = false;

  late final AnimationController _ambientController;

  final Set<String> _speechEnabledFields = {
    'name', 'fatherName', 'grandFatherName', 'fathersGrandFatherName',
    'surName', 'motherName', 'mothersFatherName', 'mothersGrandFatherName',
    'homeTown', 'notes', 'issuer', 'nameOfDocument', 'town', 'area', 'quarter',
    'street', 'address1', 'address2', 'closestLocation', 'homePhoneNumber',
    'censusNumber', 'dateOfBirth', 'issuingDate', 'idNumber', 'jinsiyaIdNumber',
    'recordNumber', 'pageNumber', 'birthCertificateNumber', 'otherIdNumber'
  };

  final Set<String> _numericSpeechFields = {
    'homePhoneNumber', 'idNumber', 'recordNumber', 'pageNumber',
    'jinsiyaIdNumber', 'censusNumber', 'birthCertificateNumber', 'otherIdNumber'
  };

  // ============================================================
  // EMIS LIVE REFERENCE DATA
  // ============================================================

  final Map<String, List<Map<String, dynamic>>> _options = {};
  final Set<String> _loadingOptions = <String>{};

  List<Map<String, dynamic>> _addressCountries = [];
  List<Map<String, dynamic>> _addressGovernorates = [];
  List<Map<String, dynamic>> _addressDistricts = [];
  List<Map<String, dynamic>> _addressTowns = [];
  String? _addressCountryId;
  String? _addressGovernorateId;
  String? _addressDistrictId;
  String? _addressTownId;

  static const Map<String, String> _optionEndpoints = {
    'countryOfBirth': '/selectoption/بلد الولادة',
    'nationality': '/selectoption/بلد الولادة',
    'idType': '/selectoption/IdentificationType',
    'issuingCountry': '/selectoption/بلد الإصدار',
    'gender': '/selectoption/Gender',
    'motherTongue': '/selectoption/لغة',
    'studyLanguage': '/selectoption/لغة',
    'maritalStatus': '/selectoption/الحالة الاجتماعية',
    'bloodGroup': '/selectoption/فصيلة الدم',
    'religion': '/selectoption/الديانة',
    'specialNeeds': '/selectoption/ذوي الإحتياجات الخاصة',
    'economicLevel': '/selectoption/حالة الاقتصادية',
    'academicYearId': '/selectoption/getActiveAcademicYear',
  };

  final Map<String, String> _officialArabicNames = {
    'name': 'الإسم', 'fatherName': 'إسم الأب',
    'grandFatherName': 'اسم والد الأب',
    'fathersGrandFatherName': 'اسم جد الأب', 'surName': 'اللقب',
    'motherName': 'إسم الأم', 'mothersFatherName': 'اسم والد الأم',
    'mothersGrandFatherName': 'اسم جد الأم',
    'dateOfBirth': 'تاريخ التولّد', 'gender': 'الجنس',
    'nationality': 'الجنسية', 'countryOfBirth': 'محل الولادة',
    'homeTown': 'مسقط الرأس', 'motherTongue': 'اللغة الأم',
    'maritalStatus': 'الحالة الاجتماعية', 'bloodGroup': 'فئة الدم',
    'religion': 'الديانة', 'homePhoneNumber': 'رقم الهاتف',
    'notes': 'ملاحظات', 'censusNumber': 'رقم الإحصاء',
    'identification': 'وثيقة التعريف', 'idNumber': 'رقم الهوية / الوثيقة',
    'issuingCountry': 'بلد الإصدار', 'idType': 'نوع الهوية',
    'jinsiyaIdNumber': 'رقم شهادة الجنسية', 'issuer': 'جهة الإصدار',
    'recordNumber': 'رقم السجل', 'pageNumber': 'رقم الصحيفة',
    'issuingDate': 'تاريخ الإصدار', 'nameOfDocument': 'نوع الوثيقة',
    'birthCertificateNumber': 'رقم شهادة الولادة',
    'otherIdNumber': 'رقم الهوية الأخرى',
    'fatherIdentification': 'هوية الأب',
    'motherIdentification': 'هوية الأم', 'specialNeeds': 'الاحتياجات الخاصة، إن وجدت',
    'studyLanguage': 'لغة الدراسة', 'economicLevel': 'المستوى المعيشي',
    'isCoveredBySocialWelfare': 'مشمول بمنحة الرعاية الاجتماعية؟',
    'isDroppedOutFromSchool': 'متسرّب من المدرسة؟',
    'lastYearResult': 'نتيجة العام الدراسي السابق',
    'lastAcademicYearId': 'العام الدراسي السابق',
    'lastCompletedStageId': 'المرحلة الدراسية السابقة',
    'lastSchoolId': 'المدرسة السابقة', 'academicYearId': 'العام الدراسي',
    'stageId': 'الصف الدراسي', 'schoolId': 'المدرسة',
    'classRoomId': 'الشعبة', 'studentStatus': 'حالة الطالب',
    'studentStatusName': 'حالة الطالب', 'address': 'العنوان',
    'addressType': 'نوع العنوان', 'countryStructureId': 'الموقع الجغرافي',
    'town': 'المدينة/القرية', 'area': 'الحي', 'quarter': 'المحلة',
    'street': 'زقاق', 'apartmentNumber': 'رقم الشقة',
    'buildingNumber': 'رقم البناية', 'address1': 'عنوان 1',
    'address2': 'عنوان 2', 'closestLocation': 'أقرب نقطة دالة',
    'schoolPhoneNumber': 'رقم هاتف مدير المدرسة',
    'mobilePhoneNumber': 'رقم هاتف المعلم',
    'employeePhoneNumber': 'رقم هاتف الموظف', 'email': 'البريد الإلكتروني',
    'website': 'الموقع الإلكتروني', 'latitude': 'خط العرض',
    'longitude': 'خط الطول', 'imageUrl': 'الصورة',
    'ageExceptionReason': 'سبب استثناء العمر',
    'genderExceptionReason': 'سبب استثناء الجنس',
    'classificationName': 'التصنيف', 'classification': 'التصنيف',
    'schoolName': 'المدرسة', 'stageName': 'الصف الدراسي',
    'classRoomName': 'الشعبة', 'academicYearName': 'العام الدراسي',
  };

  @override
  void initState() {
    super.initState();
    _ambientController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 6),
    )..repeat();

    _speechSubscription = GoogleSpeechService.events.listen(_handleGoogleSpeechEvent);
    _appCoreSettingsListener = () {
      if (mounted) setState(() {});
    };
    AppCore.voiceSettingsRevision.addListener(_appCoreSettingsListener!);
    _liveTimer = Timer.periodic(const Duration(milliseconds: 700), (_) => _pushLive());
    _fetchStudentData();
  }

  Map<String, List<String>> _liveAliases() => {
        for (final entry in _officialArabicNames.entries)
          entry.key: <String>[entry.key, entry.value],
      };

  Map<String, String> _liveValues() {
    final result = <String, String>{};
    final data = _studentData;
    if (data == null) return result;
    final identification = data['identification'] is Map ? Map<String, dynamic>.from(data['identification']) : <String, dynamic>{};
    final address = data['address'] is Map ? Map<String, dynamic>.from(data['address']) : <String, dynamic>{};
    for (final key in _officialArabicNames.keys) {
      dynamic value;
      if (data.containsKey(key)) value = data[key];
      else if (identification.containsKey(key)) value = identification[key];
      else if (address.containsKey(key)) value = address[key];
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

  void _applyLiveSnapshot(Map<String, String> values) {
    final data = _studentData;
    if (data == null) return;
    final identification = data['identification'] is Map ? Map<String, dynamic>.from(data['identification']) : <String, dynamic>{};
    final address = data['address'] is Map ? Map<String, dynamic>.from(data['address']) : <String, dynamic>{};
    bool changed = false;
    for (final entry in values.entries) {
      final key = entry.key;
      if (data.containsKey(key)) {
        final next = _liveCoerce(data[key], entry.value);
        if ('${data[key]}' != '$next') { data[key] = next; changed = true; }
      } else if (identification.containsKey(key)) {
        final next = _liveCoerce(identification[key], entry.value);
        if ('${identification[key]}' != '$next') { identification[key] = next; changed = true; }
      } else if (address.containsKey(key)) {
        final next = _liveCoerce(address[key], entry.value);
        if ('${address[key]}' != '$next') { address[key] = next; changed = true; }
      }
    }
    if (changed) {
      data['identification'] = identification;
      data['address'] = address;
      if (mounted) setState(() {});
    }
  }

  Map<String, dynamic> _unwrap(dynamic decoded) {
    if (decoded is Map<String, dynamic>) {
      final data = decoded['data'];
      if (data is Map) return Map<String, dynamic>.from(data);
      return decoded;
    }
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
    throw Exception('استجابة بيانات الطالب غير صالحة');
  }

  Future<void> _fetchStudentData() async {
    try {
      await AppCore.ensureLoaded();

      final response = await http.get(
        Uri.parse('https://emis.moedu.gov.iq/api/student/getstudent/${widget.studentId}'),
        headers: {'Authorization': widget.token, 'Accept': 'application/json'},
      );
      if (response.statusCode != 200) throw Exception('HTTP ${response.statusCode}');
      final student = _unwrap(jsonDecode(utf8.decode(response.bodyBytes)));

      for (final key in _optionEndpoints.keys) {
        await _loadOptions(key);
      }
      
      if (AppCore.cachedAvailableStages.isNotEmpty) {
        _options['stageId'] = AppCore.cachedAvailableStages
            .whereType<Map>()
            .map((item) => Map<String, dynamic>.from(item))
            .toList();
      } else {
        await _loadStageOptions(student['schoolId']?.toString());
      }
      
      final currentStageId = student['stageId']?.toString();
      if (currentStageId != null && AppCore.cachedClassRoomsByStage.containsKey(currentStageId)) {
        _options['classRoomId'] = AppCore.cachedClassRoomsByStage[currentStageId]!
            .whereType<Map>()
            .map((item) => Map<String, dynamic>.from(item))
            .toList();
      } else {
        await _loadClassroomOptions(
          student['schoolId']?.toString(),
          currentStageId,
        );
      }

      student['gender'] ??= int.tryParse(AppCore.defaultGender) ?? 1;
      student['nationality'] ??= AppCore.defaultCountry;
      student['countryOfBirth'] ??= AppCore.defaultCountry;
      if ((student['homeTown']?.toString().trim() ?? '').isEmpty) {
        student['homeTown'] = AppCore.defaultHomeTown;
      }
      student['motherTongue'] ??= AppCore.defaultMotherTongue;
      student['studyLanguage'] ??= AppCore.defaultStudyLanguage;
      student['religion'] ??= AppCore.defaultReligion;
      student['bloodGroup'] ??= AppCore.defaultBloodGroup;
      student['economicLevel'] ??= AppCore.defaultEconomicLevel;

      if (student['identification'] is Map) {
        final identification = Map<String, dynamic>.from(student['identification']);
        identification['idType'] ??= int.tryParse(AppCore.defaultIdType) ?? 12;
        identification['issuingCountry'] ??= AppCore.defaultCountry;
        student['identification'] = identification;
      }

      if (student['fatherIdentification'] is Map) {
        final fatherId = Map<String, dynamic>.from(student['fatherIdentification']);
        final hasExistingFatherId =
            (fatherId['idNumber']?.toString().trim() ?? '').isNotEmpty ||
            fatherId['idType'] != null;
        _includeFatherId = hasExistingFatherId;
        fatherId['idType'] ??= int.tryParse(AppCore.defaultIdType) ?? 12;
        fatherId['issuingCountry'] =
            (fatherId['issuingCountry']?.toString().trim().isNotEmpty ?? false)
                ? fatherId['issuingCountry']
                : AppCore.defaultCountry;
        fatherId['idNumber'] ??= '';
        fatherId['nameOfDocument'] ??= '';
        fatherId['recordNumber'] ??= '';
        fatherId['pageNumber'] ??= '';
        fatherId['issuer'] ??= '';
        fatherId['issuingDate'] ??= '';
        student['fatherIdentification'] = fatherId;
      } else {
        _includeFatherId = false;
        student['fatherIdentification'] = <String, dynamic>{
          'idType': int.tryParse(AppCore.defaultIdType) ?? 12,
          'issuingCountry': AppCore.defaultCountry,
          'idNumber': '',
          'nameOfDocument': '',
          'recordNumber': '',
          'pageNumber': '',
          'issuer': '',
          'issuingDate': '',
        };
      }

      if (student['address'] is Map) {
        final address = Map<String, dynamic>.from(student['address']);
        if ((address['town']?.toString().trim() ?? '').isEmpty) {
          address['town'] = AppCore.defaultTown;
        }
        if ((address['area']?.toString().trim() ?? '').isEmpty) {
          address['area'] = AppCore.defaultArea;
        }
        if ((address['address1']?.toString().trim() ?? '').isEmpty) {
          address['address1'] = AppCore.defaultAddress1;
        }
        student['address'] = address;
      }

      _studentData = student;
      await _loadCountryStructure();

      if (!mounted) return;
      setState(() {
        _studentData = student;
        _isLoading = false;
      });
    } catch (e) {
      debugPrint('خطأ في جلب بيانات الطالب: $e');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<List<Map<String, dynamic>>> _getOptions(String path) async {
    final response = await http.get(
      Uri.parse('https://emis.moedu.gov.iq/api$path'),
      headers: {'Authorization': widget.token, 'Accept': 'application/json'},
    );
    if (response.statusCode != 200) return <Map<String, dynamic>>[];
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    dynamic value = decoded;
    if (value is Map) value = value['data'] ?? value['items'] ?? value['results'] ?? value;
    if (value is! List) return <Map<String, dynamic>>[];
    return value.whereType<Map<String, dynamic>>().map((e) => Map<String, dynamic>.from(e)).toList();
  }

  Future<void> _loadOptions(String key) async {
    if (_options.containsKey(key) || _loadingOptions.contains(key)) return;
    final endpoint = _optionEndpoints[key];
    if (endpoint == null) return;
    _loadingOptions.add(key);
    try {
      final list = await _getOptions(endpoint);
      if (list.isNotEmpty) _options[key] = list;
    } catch (e) {
      debugPrint('تعذر تحميل خيارات $key: $e');
    } finally {
      _loadingOptions.remove(key);
    }
  }

  Future<void> _loadStageOptions(String? schoolId) async {
    if (schoolId == null || schoolId.isEmpty) return;
    try {
      final list = await _getOptions('/selectoption/getAvailableStagesForStudent?schoolId=$schoolId');
      if (list.isNotEmpty) _options['stageId'] = list;
    } catch (e) { debugPrint('تعذر تحميل الصفوف: $e'); }
  }

  Future<void> _loadClassroomOptions(String? schoolId, String? stageId) async {
    if (schoolId == null || stageId == null || schoolId.isEmpty || stageId.isEmpty) return;
    try {
      final list = await _getOptions('/selectoption/getClassRooms?schoolId=$schoolId&stageId=$stageId');
      _options['classRoomId'] = list;
    } catch (e) { debugPrint('تعذر تحميل الشعب: $e'); }
  }

  Future<void> _loadCountryStructure() async {
    try {
      final list = await _getOptions('/CountryStructure/getcountrystructure');
      if (list.isEmpty) return;
      _addressCountries = list;

      final address = _studentData?['address'] is Map
          ? Map<String, dynamic>.from(_studentData!['address'])
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
      if (stored != null && stored.isNotEmpty) {
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
    if (raw is! List) return [];
    return raw.whereType<Map<String, dynamic>>().map((e) => Map<String, dynamic>.from(e)).toList();
  }

  void _handleGoogleSpeechEvent(Map<String, dynamic> event) {
    if (!mounted) return;
    final sessionId = int.tryParse('${event['sessionId'] ?? ''}');
    if (sessionId == null || sessionId != _activeSpeechSession) return;

    final type = '${event['type'] ?? ''}';
    final key = _activeSpeechKey;
    if (key == null) return;

    if (type == 'listening' ||
        type == 'ready' ||
        type == 'begin' ||
        type == 'partial') {
      if (!_speechListening) {
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

      if (_isDateField(key)) {
        if (fullCandidates.isNotEmpty) {
          for (final candidate in fullCandidates) {
            final normalized = VoiceResultProcessor.resolveSpokenDate(candidate, fieldKey: key);
            if (normalized != null) {
              final controllerKey = '${identityHashCode(_activeSpeechOwner!)}-$key';
              final controller = _dateControllers[controllerKey] ?? _dateControllers[key];
              if (controller != null) {
                controller.value = TextEditingValue(
                  text: normalized,
                  selection: TextSelection.collapsed(offset: normalized.length),
                );
              }
              setState(() {
                _activeSpeechOwner![key] = normalized;
                _speechError = null;
              });
              break;
            }
          }
        }
        return;
      }

      String text = '';
      if (_numericSpeechFields.contains(key)) {
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
          unawaited(GoogleSpeechService.stopListening());
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
        if (_activeSpeechOwner != null) {
          setState(() {
            _activeSpeechOwner![key] = text;
            _speechError = null;
          });
          _pushLive();
        }
      }
    }

    if (type == 'error') {
      final message = '${event['message'] ?? ''}'.trim();
      final code = event['code'];
      if (message.isNotEmpty && code != 7 && code != 6) {
        setState(() => _speechError = message);
      }
      return;
    }

    if (type == 'stopped') {
      setState(() => _speechListening = false);
      _activeSpeechSession = null;
    }
  }

  Future<void> _stopActiveMic() async {
    if (_activeSpeechSession == null && !_speechListening) return;
    // Invalidate the active session first so late recognition events are ignored.
    _activeSpeechSession = null;
    if (mounted) setState(() => _speechListening = false);
    try {
      await GoogleSpeechService.stopListening();
    } catch (_) {
      // Keep the UI responsive even if the platform service has already stopped.
    }
  }

  Future<void> _toggleFieldMic(Map<String, dynamic> owner, String key) async {
    if (!AppCore.voiceInputEnabled) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('الميكروفون مغلق من الإعدادات.')));
      return;
    }
    if (_activeSpeechSession != null || _speechListening) {
      final sameField = _activeSpeechKey == key && identical(_activeSpeechOwner, owner);
      await _stopActiveMic();
      if (sameField) return;
    }
    final microphoneAllowed = await ensureEmisMicrophonePermission();
    if (!microphoneAllowed) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('يرجى السماح للتطبيق باستخدام الميكروفون.')));
      return;
    }
    try {
      final info = await GoogleSpeechService.getInfo();
      if (info['available'] == false) throw Exception('خدمة التعرف الصوتي غير متاحة على الجهاز.');
      final id = ++_speechSessionCounter;
      _activeSpeechSession = id;
      _activeSpeechOwner = owner;
      _activeSpeechKey = key;
      // نبدأ المتراكمات المؤقتة للجلسة فارغة لكي تستبدل القيمة القديمة فور التقاط أول حديث جديد فقط
      _accumulatedGoogleDigits = '';
      _accumulatedGoogleText = '';
      final started = await GoogleSpeechService.startListening(sessionId: id, locale: 'ar-IQ');
      if (!started) {
        _activeSpeechSession = null;
        throw Exception('تعذر بدء الاستماع. تحقق من خدمة التعرف الصوتي على الهاتف.');
      }
      if (mounted) setState(() { _speechListening = true; _speechError = null; });
    } catch (e) {
      if (mounted) {
        setState(() { _speechListening = false; _speechError = e.toString(); });
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('تعذر تشغيل الميكروفون: $e')));
      }
    }
  }

  String _formatDateValue(String value) {
    final v = value.trim();
    if (v.isEmpty || v.startsWith('0001-01-01')) return '';
    final cleanV = v.contains('T') ? v.split('T').first : v;
    final iso = RegExp(r'^(\d{4})[-/]?(\d{2})[-/]?(\d{2})$').firstMatch(cleanV);
    if (iso != null) return '${iso.group(1)}-${iso.group(2)}-${iso.group(3)}';
    final dmy = RegExp(r'^(\d{1,2})[-/](\d{1,2})[-/](\d{4})$').firstMatch(cleanV);
    if (dmy != null) return '${dmy.group(3)}-${dmy.group(2)!.padLeft(2, '0')}-${dmy.group(1)!.padLeft(2, '0')}';
    return cleanV.replaceAll('/', '-');
  }

  String _formatTypedDate(String value) {
    final digits = AppCore.normalizeDigitsOnly(value).replaceAll(RegExp(r'[^0-9]'), '');
    final limited = digits.length > 8 ? digits.substring(0, 8) : digits;
    var out = limited.substring(0, limited.length >= 4 ? 4 : limited.length);
    if (limited.length > 4) out += '-${limited.substring(4, limited.length >= 6 ? 6 : limited.length)}';
    if (limited.length > 6) out += '-${limited.substring(6)}';
    return out;
  }

  String _label(String key) => _officialArabicNames[key] ?? key;

  bool _isDateField(String key) => <String>{
    'dateOfBirth', 'issuingDate', 'effectiveDate', 'startDate', 'endDate',
  }.contains(key);

  bool _isRequired(String key, [Map<String, dynamic>? parent]) => false;

  dynamic _optionValue(Map<String, dynamic> option) => option['value'] ?? option['id'];
  String _optionText(Map<String, dynamic> option) => (option['displayName'] ?? option['name'] ?? option['label'] ?? option['text'] ?? _optionValue(option)?.toString() ?? '').toString();

  bool _sameValue(dynamic a, dynamic b) => a?.toString() == b?.toString();

  Widget _dropdownField({
    required String key,
    required Map<String, dynamic> owner,
    required bool isDark,
    required Color textColor,
    String? customLabel,
  }) {
    final items = _options[key] ?? const <Map<String, dynamic>>[];
    final value = owner[key];
    Map<String, dynamic>? selected;
    for (final item in items) {
      if (_sameValue(_optionValue(item), value)) { selected = item; break; }
    }
    final safeValue = selected == null ? null : _optionValue(selected);
    final requiredField = _isRequired(key, owner);
    final displayLabel = customLabel ?? (requiredField ? '${_label(key)} *' : _label(key));

    const purpleNeon = Color(0xFFA855F7);
    final mutedColor = isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);

    return Padding(
      padding: const EdgeInsets.only(bottom: 15),
      child: DropdownButtonFormField<dynamic>(
        onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
        value: safeValue,
        isExpanded: true,
        dropdownColor: isDark ? const Color(0xFF181D32) : Colors.white,
        iconEnabledColor: purpleNeon,
        style: TextStyle(
          fontWeight: FontWeight.w800,
          color: isDark ? Colors.white : const Color(0xFF0F172A),
          fontSize: 13.5,
        ),
        decoration: InputDecoration(
          labelText: displayLabel,
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
        items: items.map((item) => DropdownMenuItem<dynamic>(
          value: _optionValue(item),
          child: Text(
            _optionText(item),
            style: TextStyle(
              fontWeight: FontWeight.w800,
              color: isDark ? Colors.white : const Color(0xFF0F172A),
              fontSize: 13.5,
            ),
          ),
        )).toList(),
        validator: null,
        onChanged: (newValue) async {
          setState(() {
            owner[key] = newValue;
            if (key == 'stageId') owner['classRoomId'] = null;
          });
          if (key == 'stageId') {
            await _loadClassroomOptions(_studentData?['schoolId']?.toString(), newValue?.toString());
            if (mounted) setState(() {});
          }
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
      initialDate: initial,
      firstDate: DateTime(1900),
      lastDate: DateTime(2100),
      locale: const Locale('ar'),
    );
    if (picked != null && mounted) {
      final formatted = '${picked.year.toString().padLeft(4, '0')}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}';
      final controllerKey = '${identityHashCode(owner)}-$key';
      _dateControllers.putIfAbsent(controllerKey, () => TextEditingController()).value = TextEditingValue(
        text: formatted,
        selection: TextSelection.collapsed(offset: formatted.length),
      );
      setState(() => owner[key] = formatted);
    }
  }

  Widget _fieldFor(
    String key,
    dynamic value,
    Map<String, dynamic> owner,
    bool isDark,
    Color textColor, {
    String? customLabel,
  }) {
    if (_hiddenStudentResponseFields.contains(key) ||
        _hiddenAddressResponseFields.contains(key)) {
      return const SizedBox.shrink();
    }

    if (_optionEndpoints.containsKey(key) || key == 'stageId' || key == 'classRoomId') {
      return _dropdownField(
        key: key,
        owner: owner,
        isDark: isDark,
        textColor: textColor,
        customLabel: customLabel,
      );
    }

    if (_isDateField(key)) {
      final controllerKey = '${identityHashCode(owner)}-$key';
      const purpleNeon = Color(0xFFA855F7);
      final mutedColor = isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);

      return Padding(
        padding: const EdgeInsets.only(bottom: 15),
        child: TextFormField(
          key: ValueKey('date-$controllerKey'),
          controller: _dateControllers.putIfAbsent(
            controllerKey,
            () => TextEditingController(text: _formatDateValue(value?.toString() ?? '')),
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
          onChanged: (v) => owner[key] = v,
          onTap: () => _focusLive(key),
          style: TextStyle(
            fontWeight: FontWeight.w800,
            color: isDark ? Colors.white : const Color(0xFF0F172A),
            fontSize: 13.5,
          ),
          decoration: InputDecoration(
            labelText: customLabel ?? (_isRequired(key, owner) ? '${_label(key)} *' : _label(key)),
            labelStyle: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 12.5,
              color: mutedColor,
            ),
            suffixIcon: Row(mainAxisSize: MainAxisSize.min, children: [
              IconButton(
                tooltip: 'الإدخال الصوتي',
                onPressed: () => _toggleFieldMic(owner, key),
                icon: Icon(
                  _speechListening && _activeSpeechKey == key && identical(_activeSpeechOwner, owner)
                      ? Icons.mic_rounded
                      : Icons.mic_none_rounded,
                  color: _speechListening && _activeSpeechKey == key && identical(_activeSpeechOwner, owner)
                      ? const Color(0xFFEF4444)
                      : purpleNeon,
                ),
              ),
              IconButton(
                tooltip: 'اختيار التاريخ',
                onPressed: () => _pickDate(owner, key),
                icon: const Icon(Icons.calendar_month_rounded, color: purpleNeon),
              ),
            ]),
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
        ),
      );
    }

    if (value is bool) {
      return SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(
          customLabel ?? _label(key),
          style: TextStyle(
            color: isDark ? Colors.white : const Color(0xFF0F172A),
            fontWeight: FontWeight.w900,
          ),
        ),
        value: value,
        activeColor: const Color(0xFFA855F7),
        onChanged: (v) => setState(() => owner[key] = v),
      );
    }

    if (value is List) {
      if (key == 'specialNeeds') {
        const purpleNeon = Color(0xFFA855F7);
        final mutedColor = isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);

        return Padding(
          padding: const EdgeInsets.only(bottom: 15),
          child: DropdownButtonFormField<String>(
            onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
            value: value.isNotEmpty && value.first.toString().isNotEmpty ? value.first.toString() : null,
            isExpanded: true,
            dropdownColor: isDark ? const Color(0xFF181D32) : Colors.white,
            iconEnabledColor: purpleNeon,
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
            items: (_options[key] ?? const []).map((o) => DropdownMenuItem<String>(
              value: _optionValue(o)?.toString(),
              child: Text(
                _optionText(o),
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  color: isDark ? Colors.white : const Color(0xFF0F172A),
                  fontSize: 13.5,
                ),
              ),
            )).toList(),
            onChanged: (v) => setState(() => owner[key] = v == null ? <String>[] : <String>[v]),
          ),
        );
      }
      return const SizedBox.shrink();
    }

    return PlainTextField(
      label: customLabel ?? (_isRequired(key, owner) ? '${_label(key)} *' : _label(key)),
      initialValue: value,
      isDark: isDark,
      textColor: textColor,
      textDirection: <String>{'homePhoneNumber', 'idNumber'}.contains(key)
          ? TextDirection.ltr
          : null,
      readOnly: false,
      requiredField: _isRequired(key, owner),
      onChanged: (v) => owner[key] = v,
      onMic: _speechEnabledFields.contains(key) ? () => _toggleFieldMic(owner, key) : null,
      micActive: _speechListening && _activeSpeechKey == key && identical(_activeSpeechOwner, owner),
    );
  }

  static const Set<String> _hiddenStudentResponseFields = {
    'id', 'createdAt', 'updatedAt', 'imageUrl', 'schoolId', 'schoolName', 'schoolCensusNumber', 'stageName', 'classRoomName', 'academicYearName', 'studentStatusName', 'studentStatus', 'classificationName', 'classification', 'classifications', 'lastSchoolClassifications', 'lastSchoolClassification', 'lastSchoolName', 'lastCompletedStageName', 'lastAcademicYearName', 'lastYearResult', 'lastAcademicYearId', 'lastCompletedStageId', 'lastSchoolId', 'censusNumber',
  };

  static const Set<String> _hiddenAddressResponseFields = {
    'apartmentNumber', 'buildingNumber', 'latitude', 'longitude', 'schoolPhoneNumber', 'mobilePhoneNumber', 'employeePhoneNumber', 'email', 'website',
  };

  Widget _addressDropdown(String label, String? value, List<Map<String, dynamic>> items, ValueChanged<String?> onChanged, bool isDark, Color textColor) {
    final safe = items.any((x) => _optionValue(x)?.toString() == value) ? value : null;
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
        style: TextStyle(
          fontWeight: FontWeight.w800,
          color: isDark ? Colors.white : const Color(0xFF0F172A),
          fontSize: 13.5,
        ),
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
        items: items.map((item) => DropdownMenuItem<String>(
          value: _optionValue(item)?.toString(),
          child: Text(
            _optionText(item),
            style: TextStyle(
              fontWeight: FontWeight.w800,
              color: isDark ? Colors.white : const Color(0xFF0F172A),
              fontSize: 13.5,
            ),
          ),
        )).toList(),
        onChanged: onChanged,
      ),
    );
  }

  Widget _studentSection(
    String title,
    List<Widget> children,
    bool isDark,
  ) {
    const purpleNeon = Color(0xFFA855F7);

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
            ..._studentGrid(children),
          ],
        ),
      ),
    );
  }

  List<Widget> _studentGrid(List<Widget> children) {
    final rows = <Widget>[];
    for (var i = 0; i < children.length;) {
      final current = children[i];
      final isFullWidth = current is SizedBox || (current is Padding &&
          current.child is TextFormField &&
          (current.child as TextFormField).key is ValueKey &&
          ((current.child as TextFormField).key as ValueKey).value.toString().startsWith('date-'));
      if (isFullWidth) {
        rows.add(current is SizedBox ? current : SizedBox(width: double.infinity, child: current));
        i++;
      } else {
        final next = i + 1 < children.length ? children[i + 1] : const SizedBox();
        final nextIsFullWidth = next is SizedBox || (next is Padding &&
            next.child is TextFormField &&
            (next.child as TextFormField).key is ValueKey &&
            ((next.child as TextFormField).key as ValueKey).value.toString().startsWith('date-'));
        if (nextIsFullWidth) {
          rows.add(SizedBox(width: double.infinity, child: current));
          i++;
        } else {
          rows.add(Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: current), const SizedBox(width: 10), Expanded(child: next),
          ]));
          i += 2;
        }
      }
      if (i < children.length) rows.add(const SizedBox(height: 4));
    }
    return rows;
  }

  Widget _buildFatherIdentificationSection(
    Map<String, dynamic> fatherId,
    bool isDark,
    Color textColor,
  ) {
    final idType = int.tryParse(fatherId['idType']?.toString() ?? AppCore.defaultIdType) ?? 12;
    final dynamicFields = <Widget>[];

    if (_includeFatherId) {
      dynamicFields.addAll([
        _dropdownField(
          key: 'idType',
          owner: fatherId,
          isDark: isDark,
          textColor: textColor,
          customLabel: 'نوع هوية الأب',
        ),
        _dropdownField(
          key: 'issuingCountry',
          owner: fatherId,
          isDark: isDark,
          textColor: textColor,
          customLabel: 'بلد إصدار هوية الأب',
        ),
      ]);

      if (idType == 12) {
        dynamicFields.add(
          SizedBox(
            width: double.infinity,
            child: _fieldFor(
              'idNumber',
              fatherId['idNumber'],
              fatherId,
              isDark,
              textColor,
              customLabel: 'رقم البطاقة الوطنية الموحدة للأب',
            ),
          ),
        );
      } else if (idType == 3) {
        dynamicFields.addAll([
          SizedBox(
            width: double.infinity,
            child: _fieldFor(
              'idNumber',
              fatherId['idNumber'],
              fatherId,
              isDark,
              textColor,
              customLabel: 'رقم هوية الأحوال المدنية للأب',
            ),
          ),
          _fieldFor(
            'recordNumber',
            fatherId['recordNumber'],
            fatherId,
            isDark,
            textColor,
            customLabel: 'رقم السجل لهوية الأب',
          ),
          _fieldFor(
            'pageNumber',
            fatherId['pageNumber'],
            fatherId,
            isDark,
            textColor,
            customLabel: 'رقم الصحيفة لهوية الأب',
          ),
          _fieldFor(
            'issuer',
            fatherId['issuer'],
            fatherId,
            isDark,
            textColor,
            customLabel: 'جهة إصدار هوية الأب',
          ),
        ]);
      } else if (idType == 22) {
        dynamicFields.addAll([
          SizedBox(
            width: double.infinity,
            child: _fieldFor(
              'idNumber',
              fatherId['idNumber'],
              fatherId,
              isDark,
              textColor,
              customLabel: 'رقم شهادة الولادة للأب',
            ),
          ),
          _fieldFor(
            'issuingDate',
            fatherId['issuingDate'],
            fatherId,
            isDark,
            textColor,
            customLabel: 'تاريخ إصدار هوية الأب',
          ),
          _fieldFor(
            'recordNumber',
            fatherId['recordNumber'],
            fatherId,
            isDark,
            textColor,
            customLabel: 'رقم السجل لهوية الأب',
          ),
          _fieldFor(
            'pageNumber',
            fatherId['pageNumber'],
            fatherId,
            isDark,
            textColor,
            customLabel: 'رقم الصحيفة لهوية الأب',
          ),
        ]);
      } else if (idType == 16) {
        dynamicFields.addAll([
          _fieldFor(
            'nameOfDocument',
            fatherId['nameOfDocument'],
            fatherId,
            isDark,
            textColor,
            customLabel: 'نوع وثيقة الأب',
          ),
          SizedBox(
            width: double.infinity,
            child: _fieldFor(
              'idNumber',
              fatherId['idNumber'],
              fatherId,
              isDark,
              textColor,
              customLabel: 'رقم وثيقة الأب الأخرى',
            ),
          ),
        ]);
      }
    }

    const purpleNeon = Color(0xFFA855F7);

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
              'هوية الأب',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w900,
                color: isDark ? const Color(0xFF6EE7B7) : purpleNeon,
              ),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                'إضافة / تعديل تفاصيل هوية الأب',
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                  color: textColor,
                ),
              ),
              value: _includeFatherId,
              activeColor: purpleNeon,
              onChanged: (v) {
                setState(() {
                  _includeFatherId = v ?? false;
                  if (_includeFatherId) {
                    fatherId['idType'] ??=
                        int.tryParse(AppCore.defaultIdType) ?? 12;
                    if ((fatherId['issuingCountry']?.toString().trim() ?? '')
                        .isEmpty) {
                      fatherId['issuingCountry'] = AppCore.defaultCountry;
                    }
                  }
                });
              },
            ),
            if (_includeFatherId) ...[
              const SizedBox(height: 8),
              ..._studentGrid(dynamicFields),
            ],
          ],
        ),
      ),
    );
  }

  List<Widget> _buildStudentFormSections(bool isDark, Color textColor) {
    final student = _studentData!;
    final identification = student['identification'] is Map<String, dynamic>
        ? student['identification'] as Map<String, dynamic>
        : student['identification'] is Map
            ? Map<String, dynamic>.from(student['identification'] as Map)
            : <String, dynamic>{};
    final fatherIdentification = student['fatherIdentification'] is Map<String, dynamic>
        ? student['fatherIdentification'] as Map<String, dynamic>
        : student['fatherIdentification'] is Map
            ? Map<String, dynamic>.from(student['fatherIdentification'] as Map)
            : <String, dynamic>{
                'idType': int.tryParse(AppCore.defaultIdType) ?? 12,
                'issuingCountry': AppCore.defaultCountry,
                'idNumber': '',
                'nameOfDocument': '',
                'recordNumber': '',
                'pageNumber': '',
                'issuer': '',
                'issuingDate': '',
              };
    final address = student['address'] is Map<String, dynamic>
        ? student['address'] as Map<String, dynamic>
        : student['address'] is Map
            ? Map<String, dynamic>.from(student['address'] as Map)
            : <String, dynamic>{};
    student['identification'] = identification;
    student['fatherIdentification'] = fatherIdentification;
    student['address'] = address;

    Widget field(String key, [Map<String, dynamic>? owner]) {
      final target = owner ?? student;
      if (!target.containsKey(key)) return const SizedBox.shrink();
      return _fieldFor(key, target[key], target, isDark, textColor);
    }

    final idType = int.tryParse(identification['idType']?.toString() ?? AppCore.defaultIdType) ?? 12;
    final identificationWidgets = <Widget>[];
    if (identification.isNotEmpty) {
      if (identification.containsKey('idType')) {
        identificationWidgets.add(
          _dropdownField(key: 'idType', owner: identification, isDark: isDark, textColor: textColor),
        );
      }
      
      final idNumberWidgets = identification.entries
          .where((entry) => entry.key != 'idType' && _identityFieldVisible(entry.key, identification['idType']))
          .map((entry) {
            final w = _fieldFor(entry.key, entry.value, identification, isDark, textColor);
            if (entry.key == 'idNumber' || entry.key == 'otherIdNumber' || entry.key == 'birthCertificateNumber') {
              return SizedBox(width: double.infinity, child: w);
            }
            return w;
          }).toList();
          
      idNumberWidgets.sort((a, b) {
        if (a is SizedBox) return -1;
        if (b is SizedBox) return 1;
        return 0;
      });

      identificationWidgets.addAll(idNumberWidgets);
    }

    final result = <Widget>[
      _studentSection('الاسم الكامل', [
        field('name'),
        field('fatherName'),
        field('grandFatherName'),
        field('fathersGrandFatherName'),
        field('surName'),
        field('motherName'),
        field('mothersFatherName'),
        field('mothersGrandFatherName'),
      ], isDark),
      _studentSection('البيانات الشخصية', [
        field('dateOfBirth'),
      ], isDark),
      _studentSection('الجنس', [
        field('gender'),
      ], isDark),
      _studentSection('البيانات الشخصية', [
        field('nationality'),
        field('countryOfBirth'),
        field('homeTown'),
      ], isDark),
      _studentSection('وثيقة التعريف', identificationWidgets, isDark),
      _buildFatherIdentificationSection(fatherIdentification, isDark, textColor),
      _studentSection('البيانات الشخصية (تتمة)', [
        field('motherTongue'),
        field('maritalStatus'),
        field('bloodGroup'),
        field('religion'),
        SizedBox(width: double.infinity, child: field('homePhoneNumber')),
        SizedBox(width: double.infinity, child: field('notes')),
        field('economicLevel'),
        field('specialNeeds'),
        field('studyLanguage'),
        field('isCoveredBySocialWelfare'),
        field('isDroppedOutFromSchool'),
      ], isDark),
      _studentSection('البيانات الدراسية', [
        field('academicYearId'),
        field('stageId'),
        field('classRoomId'),
      ], isDark),
      _studentSection('العنوان', [
        _addressDropdown('الدولة', _addressCountryId, _addressCountries, (v) {
          final country = _addressCountries.where((x) => _optionValue(x)?.toString() == v).toList();
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
        }, isDark, textColor),
        _addressDropdown('المحافظة', _addressGovernorateId, _addressGovernorates, (v) {
          final gov = _addressGovernorates.where((x) => _optionValue(x)?.toString() == v).toList();
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
        }, isDark, textColor),
        _addressDropdown('القضاء', _addressDistrictId, _addressDistricts, (v) {
          final district = _addressDistricts
              .where((x) => _optionValue(x)?.toString() == v)
              .toList();
          setState(() {
            _addressDistrictId = v;
            _addressTowns = district.isEmpty ? [] : _childrenOf(district.first);
            _addressTownId = null;
            address['countryStructureId'] = v == null ? null : int.tryParse(v);
          });
          _focusLive('countryStructureId');
        }, isDark, textColor),
        _addressDropdown(
          'الناحية',
          _addressTownId,
          _addressTowns,
          (v) {
            setState(() {
              _addressTownId = v;
              address['countryStructureId'] =
                  int.tryParse(v ?? _addressDistrictId ?? '');
            });
            _focusLive('countryStructureId');
          },
          isDark,
          textColor,
        ),
        field('town', address),
        field('area', address),
        SizedBox(width: double.infinity, child: field('quarter', address)),
        field('street', address),
        field('address1', address),
        field('address2', address),
        field('closestLocation', address),
      ], isDark),
    ];

    final ageReason = student['ageExceptionReason']?.toString() ?? '';
    final genderReason = student['genderExceptionReason']?.toString() ?? '';
    if (ageReason.trim().isNotEmpty || genderReason.trim().isNotEmpty) {
      result.add(
        _studentSection('الاستثناءات', [
          if (ageReason.trim().isNotEmpty) field('ageExceptionReason'),
          if (genderReason.trim().isNotEmpty) field('genderExceptionReason'),
        ], isDark),
      );
    }

    return result;
  }

  bool _identityFieldVisible(String key, dynamic idType) {
    final t = int.tryParse(idType?.toString() ?? '');
    if (t == 3) return {'idNumber','jinsiyaIdNumber','issuer','recordNumber','pageNumber','issuingCountry','issuingDate','nameOfDocument'}.contains(key);
    if (t == 12) return {'idNumber'}.contains(key);
    if (t == 22) return {'birthCertificateNumber','idNumber','issuer','issuingDate','issuingCountry','nameOfDocument','recordNumber','pageNumber'}.contains(key);
    if (t == 16) return {'otherIdNumber','idNumber','nameOfDocument','issuer','issuingDate','issuingCountry'}.contains(key);
    return true;
  }

  SelfieSegmenter? _selfieSegmenter;

  Future<void> _initializeSelfieSegmenter() async {
    _selfieSegmenter ??= SelfieSegmenter(
      mode: SegmenterMode.single,
      enableRawSizeMask: false,
    );
  }

  Future<File?> _removeBackgroundUsingSelfieSegmentation(
    File imageFile,
  ) async {
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      return SelfieBackgroundRemover.removeBackground(imageFile);
    }
    final stopwatch = Stopwatch()..start();
    File? normalizedFile;

    try {
      await _initializeSelfieSegmenter();

      final segmenter = _selfieSegmenter;
      if (segmenter == null) {
        throw Exception('تعذر تهيئة أداة إزالة الخلفية');
      }

      final sourceBytes = await imageFile.readAsBytes();
      var sourceImage = img.decodeImage(sourceBytes);

      if (sourceImage == null) {
        throw Exception('تعذر قراءة الصورة');
      }

      sourceImage = img.bakeOrientation(sourceImage);

      const maxDimension = 512;
      if (sourceImage.width > maxDimension ||
          sourceImage.height > maxDimension) {
        sourceImage = img.copyResize(
          sourceImage,
          width: sourceImage.width >= sourceImage.height
              ? maxDimension
              : null,
          height: sourceImage.height > sourceImage.width
              ? maxDimension
              : null,
          interpolation: img.Interpolation.linear,
        );
      }

      normalizedFile = File(
        '${imageFile.path}_segmentation_input_${DateTime.now().millisecondsSinceEpoch}.jpg',
      );
      await normalizedFile.writeAsBytes(
        img.encodeJpg(sourceImage, quality: 90),
        flush: true,
      );

      final inputImage = InputImage.fromFilePath(normalizedFile.path);
      final mask = await segmenter.processImage(inputImage);

      if (mask == null) {
        throw Exception('لم يتم الحصول على قناع الشخص من ML Kit');
      }

      if (mask.width <= 0 || mask.height <= 0 || mask.confidences.isEmpty) {
        throw Exception('قناع إزالة الخلفية غير صالح');
      }

      final result = img.Image(
        width: sourceImage.width,
        height: sourceImage.height,
        numChannels: 4,
      );

      for (var y = 0; y < sourceImage.height; y++) {
        for (var x = 0; x < sourceImage.width; x++) {
          final index = y * sourceImage.width + x;
          final confidence = mask.confidences[index].clamp(0.0, 1.0);

          final alpha = ((confidence - 0.35) / 0.40 * 255.0)
              .round()
              .clamp(0, 255);

          final sourcePixel = sourceImage.getPixel(x, y);
          result.setPixelRgba(
            x,
            y,
            sourcePixel.r,
            sourcePixel.g,
            sourcePixel.b,
            alpha,
          );
        }
      }

      final outputPath =
          '${imageFile.path}_nobg_${DateTime.now().millisecondsSinceEpoch}.png';
      final outputFile = File(outputPath);

      await outputFile.writeAsBytes(
        img.encodePng(result, level: 6),
        flush: true,
      );

      return outputFile;
    } catch (e) {
      debugPrint('ML Kit background removal error: $e');
      rethrow;
    } finally {
      if (normalizedFile != null) {
        try {
          if (await normalizedFile.exists()) {
            await normalizedFile.delete();
          }
        } catch (_) {}
      }
      stopwatch.stop();
    }
  }

  @override
  void dispose() {
    _liveTimer?.cancel();
    _ambientController.dispose();
    _speechSubscription?.cancel();
    if (_appCoreSettingsListener != null) {
      AppCore.voiceSettingsRevision.removeListener(_appCoreSettingsListener!);
      _appCoreSettingsListener = null;
    }
    unawaited(GoogleSpeechService.cancelListening());
    final segmenter = _selfieSegmenter;
    _selfieSegmenter = null;
    if (segmenter != null) {
      segmenter.close();
    }
    for (final controller in _dateControllers.values) {
      controller.dispose();
    }
    _dateControllers.clear();
    super.dispose();
  }

  Future<void> _showImagePreviewDialog(File imageFile) async {
    File currentImage = imageFile;
    bool isProcessing = false;

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
              title: const Text(
                'معاينة الصورة الشخصية',
                textAlign: TextAlign.center,
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      height: 220,
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
                          child: Image.file(
                            currentImage,
                            fit: BoxFit.contain,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 15),
                    if (isProcessing)
                      const CircularProgressIndicator()
                    else
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: () async {
                            setDialogState(() => isProcessing = true);
                            try {
                              final processed =
                                  await _removeBackgroundUsingSelfieSegmentation(
                                currentImage,
                              );
                              if (processed != null && mounted) {
                                setDialogState(() {
                                  currentImage = processed;
                                  isProcessing = false;
                                });
                              }
                            } catch (e) {
                              if (!mounted) return;
                              setDialogState(() => isProcessing = false);
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
                  onPressed: isProcessing
                      ? null
                      : () => Navigator.pop(dialogContext),
                  child: const Text('إلغاء'),
                ),
                ElevatedButton(
                  onPressed: isProcessing
                      ? null
                      : () {
                          setState(() => _pickedImage = currentImage);
                          Navigator.pop(dialogContext);
                        },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green,
                  ),
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
    } catch (_) {}
  }

  void _deleteCurrentPhoto() {
    setState(() {
      _pickedImage = null;
      if (_studentData != null) _studentData!['imageUrl'] = null;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('تم حذف صورة الطالب')),
    );
  }

  Future<String?> _uploadImageToEmisServer(File imageFile) async {
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('https://emis.moedu.gov.iq/api/student/uploadimage'),
    );
    request.headers['Authorization'] = widget.token;
    request.headers['Accept'] = 'application/json';
    request.files.add(
      await http.MultipartFile.fromPath(
        'image',
        imageFile.path,
        filename: 'avatar.png',
      ),
    );
    try {
      final streamedResponse = await request.send();
      final responseData =
          await streamedResponse.stream.bytesToString();
      if (streamedResponse.statusCode == 200) {
        final jsonResponse = jsonDecode(responseData);
        if (jsonResponse is Map) {
          return jsonResponse['imageUrl']?.toString();
        }
      }
    } catch (_) {}
    return null;
  }

  Future<void> _saveStudentData() async {
    if (_studentData == null) return;
    setState(() => _isSaving = true);

    try {
      if (_pickedImage != null) {
        final newImageUrl =
            await _uploadImageToEmisServer(_pickedImage!);
        if (newImageUrl != null && newImageUrl.isNotEmpty) {
          _studentData!['imageUrl'] = newImageUrl;
        } else {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                  content: Text('تعذر رفع صورة الطالب'),
                  backgroundColor: Colors.red),
            );
          }
          return;
        }
      }

      final studentPayload = Map<String, dynamic>.from(_studentData!);
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
        return null;
      }

      studentPayload['dateOfBirth'] = dateOnly(studentPayload['dateOfBirth']);

      if (studentPayload['identification'] is Map) {
        final identification = Map<String, dynamic>.from(studentPayload['identification'] as Map);
        final issuingDate = identification['issuingDate'];
        if (issuingDate != null && issuingDate.toString().trim().isNotEmpty) {
          identification['issuingDate'] = dateOnly(issuingDate);
        }
        studentPayload['identification'] = identification;
      }

      if (!_includeFatherId) {
        studentPayload['fatherIdentification'] = null;
      } else if (studentPayload['fatherIdentification'] is Map) {
        final fatherId = Map<String, dynamic>.from(studentPayload['fatherIdentification'] as Map);
        final fIdType = int.tryParse(fatherId['idType']?.toString() ?? '');
        if (fIdType == null) {
          studentPayload['fatherIdentification'] = null;
        } else {
          final fIssuingDate = fatherId['issuingDate'];
          studentPayload['fatherIdentification'] = <String, dynamic>{
            'idNumber': AppCore.normalizeDigitsOnly((fatherId['idNumber'] ?? '').toString().trim()),
            'issuingCountry': (fatherId['issuingCountry'] ?? AppCore.defaultCountry).toString().trim(),
            'idType': fIdType,
            'nameOfDocument': (fatherId['nameOfDocument'] ?? '').toString().trim(),
            'recordNumber': (fatherId['recordNumber'] ?? '').toString().trim(),
            'pageNumber': (fatherId['pageNumber'] ?? '').toString().trim(),
            'issuer': (fatherId['issuer'] ?? '').toString().trim(),
            'issuingDate': (fIssuingDate != null && fIssuingDate.toString().trim().isNotEmpty)
                ? dateOnly(fIssuingDate)
                : null,
          };
        }
      }

      final response = await http.post(
        Uri.parse('https://emis.moedu.gov.iq/api/student/updatestudent'),
        headers: {
          'Authorization': widget.token,
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
        body: jsonEncode(studentPayload),
      );

      if (!mounted) return;

      if (response.statusCode == 200 || response.statusCode == 204) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('تم الحفظ بنجاح!'),
            backgroundColor: Colors.green,
          ),
        );
        Navigator.pop(context, true);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('فشل الحفظ (HTTP ${response.statusCode})'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('تعذر إكمال الحفظ: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
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
              _AnimatedEditStudentOrbIcon(
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
                      'نظام إدارة الطلاب',
                      style: TextStyle(
                        color: isDark ? goldNeon : purpleNeon,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'تعديل بيانات الطالب',
                      style: TextStyle(
                        color: isDark ? Colors.white : const Color(0xFF0F172A),
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'تحديث السجلات والبيانات الشخصية في EMIS',
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
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: AppCore.themeNotifier,
      builder: (context, currentMode, child) {
        final isDark = currentMode == ThemeMode.dark;
        final bgColor =
            isDark ? const Color(0xFF070913) : const Color(0xFFF2F5FA);
        final cardColor =
            isDark ? const Color(0xFF141829) : Colors.white;
        final textColor = isDark ? Colors.white : const Color(0xFF0F172A);

        const purpleNeon = Color(0xFFA855F7);
        const emeraldNeon = Color(0xFF10B981);
        const goldNeon = Color(0xFFF59E0B);
        const blueNeon = Color(0xFF3B82F6);

        String imgUrl = _studentData?['imageUrl']?.toString() ?? '';
        if (imgUrl.isNotEmpty && !imgUrl.startsWith('http')) {
          imgUrl = 'https://emis.moedu.gov.iq$imgUrl';
        }

        return Directionality(
          textDirection: TextDirection.rtl,
          child: Scaffold(
            backgroundColor: bgColor,
            appBar: null,
            body: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: () {
                // Any tap outside the microphone control closes active listening.
                if (_speechListening || _activeSpeechSession != null) {
                  unawaited(_stopActiveMic());
                }
              },
              child: Stack(
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
                      : _studentData == null
                          ? const Center(child: Text('فشل جلب البيانات', style: TextStyle(fontWeight: FontWeight.w900)))
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
                                                    color: purpleNeon,
                                                    width: 2.5,
                                                  ),
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
                                                      ? Image.file(
                                                          _pickedImage!,
                                                          fit: BoxFit.cover,
                                                        )
                                                      : imgUrl.isNotEmpty
                                                          ? Image.network(
                                                              imgUrl,
                                                              headers: {
                                                                'Authorization':
                                                                    widget.token,
                                                              },
                                                              fit: BoxFit.cover,
                                                              errorBuilder: (
                                                                context,
                                                                error,
                                                                stackTrace,
                                                              ) {
                                                                return Icon(
                                                                  Icons.person_rounded,
                                                                  size: 80,
                                                                  color: Colors.grey[400],
                                                                );
                                                              },
                                                            )
                                                          : Icon(
                                                              Icons.person_rounded,
                                                              size: 80,
                                                              color: Colors.grey[400],
                                                            ),
                                                ),
                                              ),
                                              Positioned(
                                                bottom: 0,
                                                right: 0,
                                                child: CircleAvatar(
                                                  backgroundColor: blueNeon,
                                                  radius: 20,
                                                  child: IconButton(
                                                    icon: const Icon(
                                                      Icons.camera_alt_rounded,
                                                      color: Colors.white,
                                                      size: 18,
                                                    ),
                                                    onPressed: () => _pickImage(
                                                      ImageSource.camera,
                                                    ),
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
                                                      size: 18,
                                                    ),
                                                    onPressed: () => _pickImage(
                                                      ImageSource.gallery,
                                                    ),
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
                                            icon: const Icon(
                                              Icons.delete_forever_rounded,
                                              color: Color(0xFFEF4444),
                                            ),
                                            label: const Text(
                                              'حذف الصورة الحالية',
                                              style: TextStyle(
                                                color: Color(0xFFEF4444),
                                                fontWeight: FontWeight.w900,
                                              ),
                                            ),
                                          ),
                                        ),
                                        const SizedBox(height: 15),
                                        ..._buildStudentFormSections(
                                          isDark,
                                          textColor,
                                        ),
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
                                      onPressed:
                                          _isSaving ? null : _saveStudentData,
                                      style: FilledButton.styleFrom(
                                        backgroundColor: emeraldNeon,
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(16),
                                        ),
                                        elevation: 6,
                                        shadowColor: emeraldNeon.withOpacity(0.35),
                                      ),
                                      child: _isSaving
                                          ? const SizedBox(
                                              width: 22,
                                              height: 22,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                                color: Colors.white,
                                              ),
                                            )
                                          : const Text(
                                              'حفظ التعديلات',
                                              style: TextStyle(
                                                fontSize: 17,
                                                color: Colors.white,
                                                fontWeight: FontWeight.w900,
                                              ),
                                            ),
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
                    url: 'https://emis.moedu.gov.iq/centers/schools/${_studentData?['schoolId'] ?? ''}/individuals/students/management',
                    mode: 'edit',
                    entity: 'student',
                    token: widget.token,
                    recordId: widget.studentId,
                    aliases: _liveAliases(),
                    onSnapshot: _applyLiveSnapshot,
                    onStatus: (v) { if (mounted) setState(() => _liveStatus = v); },
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
}

class PlainTextField extends StatefulWidget {
  final String label;
  final dynamic initialValue;
  final bool isDark;
  final Color textColor;
  final TextDirection? textDirection;
  final Function(String) onChanged;
  final bool readOnly;
  final bool requiredField;
  final VoidCallback? onTap;
  final VoidCallback? onMic;
  final bool micActive;

  const PlainTextField({
    super.key,
    required this.label,
    required this.initialValue,
    required this.isDark,
    required this.textColor,
    this.textDirection,
    required this.onChanged,
    this.readOnly = false,
    this.requiredField = false,
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
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: widget.initialValue?.toString() ?? '',
    );
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
        textDirection: widget.textDirection,
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
          suffixIcon: widget.onMic == null
              ? null
              : IconButton(
                  tooltip: 'الإدخال الصوتي',
                  onPressed: widget.onMic,
                  icon: Icon(
                    widget.micActive
                        ? Icons.mic_rounded
                        : Icons.mic_none_rounded,
                    color: widget.micActive ? const Color(0xFFEF4444) : purpleNeon,
                  ),
                ),
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

class _AnimatedEditStudentOrbIcon extends StatelessWidget {
  final IconData icon;
  final Color primaryColor;
  final Color secondaryColor;
  final Animation<double> animation;
  final double size;

  const _AnimatedEditStudentOrbIcon({
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
                  painter: _EditStudentAtomOrbitPainter(
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

class _EditStudentAtomOrbitPainter extends CustomPainter {
  final double progress;
  final Color primaryColor;
  final Color secondaryColor;

  _EditStudentAtomOrbitPainter({
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
  bool shouldRepaint(covariant _EditStudentAtomOrbitPainter oldDelegate) =>
      oldDelegate.progress != progress;
}
