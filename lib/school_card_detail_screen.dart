import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'platform_permissions.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'platform_image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_core.dart';
import 'emis_live_sync.dart';
import 'google_speech_service.dart';
import 'school_card_sections.dart';
import 'voice_result_processor.dart';

/// البطاقة المدرسية للطالب.
///
/// - أقسام البطاقة وحقولها مطابقة لصفحة EMIS (SchoolStudentCardDetailPage).
/// - على كل حقل مايكروفون (نص، رقم، تاريخ، قائمة منسدلة، اختيار متعدد، تفعيل).
/// - القوائم المنسدلة (المحافظة، المدينة، اللقاحات ...) تُجلب حياً من EMIS،
///   وكل تغيير في قيمة حقل يُدفع آنياً إلى صفحة EMIS عبر جسر المزامنة الحية،
///   وأي تغيير على الصفحة يعود فوراً إلى التطبيق.
/// - الحفظ يتم عبر نفس واجهة EMIS: StudentSchoolCard/savesection.
class SchoolCardDetailScreen extends StatefulWidget {
  final String token;
  final String schoolId;
  final List<Map<String, dynamic>> students;
  final int initialIndex;

  const SchoolCardDetailScreen({
    super.key,
    required this.token,
    required this.schoolId,
    required this.students,
    required this.initialIndex,
  });

  @override
  State<SchoolCardDetailScreen> createState() => _SchoolCardDetailScreenState();
}

class _SchoolCardDetailScreenState extends State<SchoolCardDetailScreen>
    with SingleTickerProviderStateMixin {
  static const String _api = 'https://emis.moedu.gov.iq/api';
  static const String _site = 'https://emis.moedu.gov.iq';

  static const Color _purple = Color(0xFFA855F7);
  static const Color _emerald = Color(0xFF10B981);
  static const Color _gold = Color(0xFFF59E0B);
  static const Color _blue = Color(0xFF3B82F6);
  static const Color _red = Color(0xFFEF4444);

  /// الحقول التي تتبادل فيها القوائم قيمها (اختيار في واحدة يحذفها من الباقي).
  static const Map<String, List<String>> _exclusiveGroups =
      <String, List<String>>{
    'traitsOften': <String>['traitsSometimes', 'traitsRarely'],
    'traitsSometimes': <String>['traitsOften', 'traitsRarely'],
    'traitsRarely': <String>['traitsOften', 'traitsSometimes'],
    'interestsOften': <String>['interestsSometimes', 'interestsRarely'],
    'interestsSometimes': <String>['interestsOften', 'interestsRarely'],
    'interestsRarely': <String>['interestsOften', 'interestsSometimes'],
  };

  late final AnimationController _ambientController;

  // ------------------------------------------------------------- الطالب
  late int _index;
  Map<String, dynamic> get _listStudent => widget.students[_index];
  String get _studentId => '${_listStudent['id']}';

  Map<String, dynamic>? _student;
  bool _loadingStudent = true;
  String? _loadError;

  List<Map<String, dynamic>> _records = <Map<String, dynamic>>[];
  int _recordIndex = 0;
  Map<String, dynamic>? get _record =>
      _records.isEmpty ? null : _records[_recordIndex];

  // -------------------------------------------------------------- القسم
  String _sectionKey = 'initialInformation';
  SchoolCardSection get _section => schoolCardSectionByKey(_sectionKey);

  Map<String, String> _values = <String, String>{};
  Map<String, List<String>> _multi = <String, List<String>>{};
  Map<String, dynamic>? _cardRecord;
  String _baseline = '';
  bool _loadingSection = false;
  bool _saving = false;
  bool _uploading = false;
  final TextEditingController _reasonCtrl = TextEditingController();
  final Map<String, TextEditingController> _ctrls =
      <String, TextEditingController>{};

  // أقسام القراءة فقط
  List<Map<String, dynamic>> _achievements = <Map<String, dynamic>>[];
  Map<String, dynamic>? _attendance;
  final Map<String, TextEditingController> _extraCtrls =
      <String, TextEditingController>{};
  final Set<String> _savingExtra = <String>{};

  // ------------------------------------------------- قوائم EMIS الحية
  List<Map<String, dynamic>> _iraqNodes = <Map<String, dynamic>>[];
  List<SchoolCardOption> _vaccinations = <SchoolCardOption>[];
  final Map<String, List<SchoolCardOption>> _liveOptions =
      <String, List<SchoolCardOption>>{};

  // ---------------------------------------------------- المزامنة الحية
  GlobalKey<EmisLiveSyncState> _liveSyncKey = GlobalKey<EmisLiveSyncState>();
  Timer? _liveTimer;
  Timer? _pollTimer;
  bool _liveReady = false;
  bool _liveDialogReady = false;
  bool _livePending = false;
  int _pollTick = 0;
  String _liveStatus = 'جاري ربط المزامنة الحية مع EMIS...';
  final Map<String, String> _lastPushed = <String, String>{};

  // ------------------------------------------------------- المايكروفون
  StreamSubscription<Map<String, dynamic>>? _speechSubscription;
  VoidCallback? _voiceSettingsListener;
  int? _speechSession;
  String? _activeId;
  String _activeKind = 'text';
  SchoolCardField? _activeField;
  void Function(String)? _activeApply;
  bool _listening = false;
  String _accDigits = '';
  String _accText = '';

  // =================================================================== حياة
  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex.clamp(0, widget.students.length - 1);
    _ambientController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 6),
    )..repeat();

    _speechSubscription = GoogleSpeechService.events.listen(_onSpeech);
    _voiceSettingsListener = () {
      if (mounted) setState(() {});
    };
    AppCore.voiceSettingsRevision.addListener(_voiceSettingsListener!);

    _liveTimer = Timer.periodic(const Duration(milliseconds: 800), (_) {
      if (_livePending) {
        _livePending = false;
        unawaited(_pushLive());
      }
    });
    _pollTimer = Timer.periodic(const Duration(seconds: 25), (_) {
      unawaited(_pollServer());
    });

    unawaited(_restoreLiveOptionsCache());
    unawaited(_loadCountryStructure());
    unawaited(_loadVaccinations());
    unawaited(_loadStudent());
  }

  @override
  void dispose() {
    _liveTimer?.cancel();
    _pollTimer?.cancel();
    _speechSubscription?.cancel();
    if (_voiceSettingsListener != null) {
      AppCore.voiceSettingsRevision.removeListener(_voiceSettingsListener!);
    }
    unawaited(GoogleSpeechService.cancelListening());
    _ambientController.dispose();
    _reasonCtrl.dispose();
    for (final c in _ctrls.values) {
      c.dispose();
    }
    for (final c in _extraCtrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  // ================================================================ الشبكة
  Map<String, String> get _headers => <String, String>{
        'Authorization': widget.token,
        'Accept': 'application/json',
      };

  Map<String, String> get _jsonHeaders => <String, String>{
        ..._headers,
        'Content-Type': 'application/json',
      };

  dynamic _decode(http.Response r) {
    if (r.bodyBytes.isEmpty) return null;
    try {
      return jsonDecode(utf8.decode(r.bodyBytes));
    } catch (_) {
      return null;
    }
  }

  String _errorText(http.Response r) {
    final body = utf8.decode(r.bodyBytes, allowMalformed: true).trim();
    final short = body.length > 160 ? body.substring(0, 160) : body;
    return 'HTTP ${r.statusCode}${short.isEmpty ? '' : ': $short'}';
  }

  void _snack(String message, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message, style: const TextStyle(fontWeight: FontWeight.bold)),
          backgroundColor: error ? _red : _emerald,
        ),
      );
  }

  // ------------------------------------------------------- قوائم EMIS
  Future<void> _loadCountryStructure() async {
    _iraqNodes = <Map<String, dynamic>>[];
    if (mounted) setState(() {});
    try {
      final r = await http
          .get(Uri.parse('$_api/CountryStructure/getcountrystructure'), headers: _headers)
          .timeout(const Duration(seconds: 40));
      if (r.statusCode != 200) return;
      dynamic d = _decode(r);
      if (d is Map && d['data'] != null) d = d['data'];
      if (d is! List) return;
      // الجذر كان يُعرَّف حصراً بـ id == 0؛ إن اختلف المعرّف بقيت المحافظات والمدن فارغة.
      Map? root;
      for (final item in d) {
        if (item is Map && '${item['id']}' == '0') {
          root = item;
          break;
        }
      }
      if (root == null) {
        for (final item in d) {
          if (item is! Map) continue;
          final n = '${item['name'] ?? item['displayName'] ?? ''}'.toLowerCase();
          if (n.contains('العراق') || n.contains('iraq')) {
            root = item;
            break;
          }
        }
      }
      if (root == null && d.length == 1 && d.first is Map) {
        root = d.first as Map;
      }
      final children = root == null ? null : root['children'];
      if (children is List) {
        _iraqNodes = children
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
      } else {
        debugPrint('EMIS CountryStructure: Iraq root not found');
      }
      if (mounted) setState(() {});
    } catch (_) {}
  }

  Future<void> _loadVaccinations() async {
    try {
      // التفويض مطلوب في بعض جلسات EMIS؛ نجربه أولاً ثم نسجل الفشل بوضوح.
      final uri = Uri.parse('$_api/selectoption/Vaccination');
      const base = {
        'Accept': 'application/json, text/plain, */*',
        'Cache-Control': 'no-cache',
        'Pragma': 'no-cache',
      };
      var r = await http
          .get(uri, headers: {...base, ..._headers})
          .timeout(const Duration(seconds: 25));
      if (r.statusCode != 200) {
        debugPrint('EMIS Vaccination (auth) HTTP ${r.statusCode}');
        r = await http.get(uri, headers: base).timeout(const Duration(seconds: 25));
      }
      if (r.statusCode != 200) {
        debugPrint('EMIS Vaccination HTTP ${r.statusCode}');
        return;
      }
      dynamic d = _decode(r);
      if (d is Map) {
        d = d['data'] ?? d['items'] ?? d['options'] ?? d['values'];
      }
      if (d is! List) {
        debugPrint('EMIS Vaccination options response is not a list');
        return;
      }
      final list = <SchoolCardOption>[];
      final seen = <String>{};
      for (final item in d) {
        if (item is! Map) continue;
        final display = '${item['displayName'] ?? item['label'] ?? item['name'] ?? ''}'.trim();
        final value = '${item['value'] ?? item['id'] ?? ''}'.trim();
        final shortName = '${item['shortName'] ?? item['code'] ?? ''}'.trim();
        final name = display.isNotEmpty ? display : (shortName.isNotEmpty ? shortName : value);
        // EMIS stores the selected vaccinations as comma-separated shortName values.
        final key = shortName.isNotEmpty ? shortName : value;
        if (key.isEmpty || !seen.add(key)) continue;
        list.add(SchoolCardOption(key != name ? '$name - $key' : name, key));
      }
      _vaccinations = list;
      debugPrint('EMIS Vaccination: ${list.length} option(s) loaded');
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('تعذر تحميل خيارات اللقاحات من EMIS: $e');
    }
  }

  List<SchoolCardOption> get _governorates => _iraqNodes
      .map((n) => SchoolCardOption('${n['name'] ?? ''}', '${n['name'] ?? ''}'))
      .where((o) => o.value.trim().isNotEmpty)
      .toList();

  List<SchoolCardOption> _citiesFor(String governorate) {
    if (governorate.isEmpty) return <SchoolCardOption>[];
    for (final g in _iraqNodes) {
      if ('${g['name']}' != governorate) continue;
      final children = g['children'];
      if (children is! List) return <SchoolCardOption>[];
      return children
          .whereType<Map>()
          .map((c) => SchoolCardOption('${c['name'] ?? ''}', '${c['name'] ?? ''}'))
          .where((o) => o.value.trim().isNotEmpty)
          .toList();
    }
    return <SchoolCardOption>[];
  }

  /// خيارات الحقل: القوائم الحية من EMIS أولاً، ثم ما التقطه جسر المزامنة
  /// من القوائم داخل صفحة EMIS، ثم القائمة المضمّنة كاحتياط.
  List<SchoolCardOption> _optionsFor(SchoolCardField f) {
    List<SchoolCardOption> base;
    switch (f.dynamicList) {
      case 'governorate':
        base = _governorates;
        break;
      case 'city':
        base = _citiesFor(_values['governorate'] ?? '');
        break;
      case 'vaccination':
      case 'vaccinations':
        base = _vaccinations.isNotEmpty
            ? _vaccinations
            : (_liveOptions[f.key] ?? const <SchoolCardOption>[]);
        break;
      default:
        final live = _liveOptions[f.key];
        base = (f.type == SchoolCardFieldType.select ||
                    f.type == SchoolCardFieldType.multiSelect ||
                    f.type == SchoolCardFieldType.radio)
            ? (live ?? const <SchoolCardOption>[])
            : const <SchoolCardOption>[];
    }
    final out = <SchoolCardOption>[];
    final seen = <String>{};
    for (final o in base) {
      if (seen.add(o.value)) out.add(o);
    }
    return out;
  }

  // ============================================================ تحميل الطالب
  Future<void> _loadStudent() async {
    if (!mounted) return;
    final id = _studentId;
    setState(() {
      _loadingStudent = true;
      _loadError = null;
    });
    try {
      final r = await http
          .get(Uri.parse('$_api/student/getstudent/$id'), headers: _headers)
          .timeout(const Duration(seconds: 25));
      if (r.statusCode != 200) throw Exception(_errorText(r));
      dynamic d = _decode(r);
      if (d is Map && d['data'] is Map) d = d['data'];
      if (d is! Map) throw Exception('بيانات الطالب غير صالحة');
      final student = Map<String, dynamic>.from(d);

      var records = <Map<String, dynamic>>[];
      final rr = await http
          .get(Uri.parse('$_api/StudentSchoolCard/academicrecord/$id'), headers: _headers)
          .timeout(const Duration(seconds: 25));
      if (rr.statusCode == 200) {
        final list = _decode(rr);
        if (list is List) {
          records = list
              .whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e))
              .toList();
        }
      }
      if (!mounted || id != _studentId) return;
      _student = student;
      _records = records;
      _recordIndex = _pickCurrentRecordIndex();
    } catch (e) {
      if (!mounted || id != _studentId) return;
      setState(() {
        _loadingStudent = false;
        _loadError = '$e';
      });
      return;
    }
    if (!mounted || id != _studentId) return;
    setState(() => _loadingStudent = false);
    await _loadSectionData();
  }

  int _pickCurrentRecordIndex() {
    if (_records.isEmpty) return 0;
    final stageId = '${_student?['stageId']}';
    final yearId = '${_student?['academicYearId']}';
    for (var i = _records.length - 1; i >= 0; i--) {
      if ('${_records[i]['stageId']}' == stageId &&
          '${_records[i]['academicYearId']}' == yearId) {
        return i;
      }
    }
    for (var i = _records.length - 1; i >= 0; i--) {
      if ('${_records[i]['stageId']}' == stageId) return i;
    }
    return _records.length - 1;
  }

  int? get _stageIdForCard =>
      int.tryParse('${_record?['stageId'] ?? _student?['stageId'] ?? ''}');

  String get _studentFullName {
    final s = _student;
    if (s != null) {
      final parts = <dynamic>[
        s['name'],
        s['fatherName'],
        s['grandFatherName'],
        s['fathersGrandFatherName'],
        s['surName'],
      ].map((e) => '${e ?? ''}'.trim()).where((e) => e.isNotEmpty).join(' ');
      if (parts.isNotEmpty) return parts;
    }
    return '${_listStudent['fullName'] ?? _listStudent['studentName'] ?? 'طالب'}';
  }

  // ============================================================ بيانات القسم
  Future<void> _loadSectionData() async {
    switch (_section.mode) {
      case SchoolCardSectionMode.editable:
        await _loadEditableSection();
        break;
      case SchoolCardSectionMode.academicRecord:
        _syncRegistrationControllers();
        if (mounted) setState(() {});
        break;
      case SchoolCardSectionMode.achievement:
        await _loadAchievement();
        break;
      case SchoolCardSectionMode.attendance:
        await _loadAttendance();
        break;
    }
    unawaited(_openLiveSection());
  }

  Future<Map<String, dynamic>?> _fetchSectionRecord(String sectionKey, int stageId) async {
    final uri = Uri.parse('$_api/StudentSchoolCard/section').replace(
      queryParameters: <String, String>{
        'studentId': _studentId,
        'sectionKey': sectionKey,
        'stageId': '$stageId',
      },
    );
    final r = await http.get(uri, headers: _headers).timeout(const Duration(seconds: 25));
    if (r.statusCode == 200) {
      final d = _decode(r);
      if (d is Map) return Map<String, dynamic>.from(d);
    }
    return null;
  }

  Future<void> _loadEditableSection() async {
    final sectionKey = _sectionKey;
    final id = _studentId;
    final stageId = _stageIdForCard;
    if (mounted) setState(() => _loadingSection = true);
    Map<String, dynamic>? rec;
    if (stageId != null) {
      try {
        rec = await _fetchSectionRecord(sectionKey, stageId);
      } catch (e) {
        _snack('تعذر جلب بيانات القسم: $e', error: true);
      }
    }
    if (!mounted || sectionKey != _sectionKey || id != _studentId) return;
    _applyRecord(rec);
    setState(() => _loadingSection = false);
  }

  void _unpackDegreeList(Map<String, dynamic> data, String listKey, String degreeKey, String prefix) {
    final raw = data[listKey];
    if (raw is! String || raw.isEmpty) return;
    final often = <String>[];
    final sometimes = <String>[];
    final rarely = <String>[];
    if (raw.startsWith('{')) {
      try {
        final m = jsonDecode(raw);
        if (m is Map) {
          m.forEach((k, v) {
            if (v == 'كثيراً') {
              often.add('$k');
            } else if (v == 'أحياناً') {
              sometimes.add('$k');
            } else if (v == 'نادراً') {
              rarely.add('$k');
            }
          });
        }
      } catch (_) {}
    } else {
      final items = raw.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
      final degree = '${data[degreeKey] ?? ''}'.isEmpty ? 'أحياناً' : '${data[degreeKey]}';
      if (degree == 'كثيراً') {
        often.addAll(items);
      } else if (degree == 'نادراً') {
        rarely.addAll(items);
      } else {
        sometimes.addAll(items);
      }
    }
    data['${prefix}Often'] = often.join(',');
    data['${prefix}Sometimes'] = sometimes.join(',');
    data['${prefix}Rarely'] = rarely.join(',');
    data.remove(listKey);
    data.remove(degreeKey);
  }

  List<String> _splitCsv(String raw) =>
      raw.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();

  void _applyRecord(Map<String, dynamic>? rec) {
    final section = _section;
    final values = <String, String>{};
    final multi = <String, List<String>>{};
    for (final f in section.fields) {
      // لا توجد قيم افتراضية ثابتة لحقول EMIS؛ تبدأ الحقول فارغة حتى تصل بيانات الخادم.
      values[f.key] = f.type == SchoolCardFieldType.checkbox ? 'false' : '';
    }
    var data = <String, dynamic>{};
    final raw = rec?['dataJson'];
    if (raw is String && raw.trim().isNotEmpty) {
      try {
        final d = jsonDecode(raw);
        if (d is Map) data = Map<String, dynamic>.from(d);
      } catch (_) {}
    }
    _unpackDegreeList(data, 'traitsList', 'traitDegree', 'traits');
    _unpackDegreeList(data, 'interestsList', 'interestDegree', 'interests');

    for (final f in section.fields) {
      if (!data.containsKey(f.key)) continue;
      final v = data[f.key];
      var s = v == null ? '' : (v is bool ? (v ? 'true' : 'false') : '$v');
      if (f.type == SchoolCardFieldType.checkbox) {
        s = (s.toLowerCase() == 'true' || s == '1') ? 'true' : 'false';
      }
      values[f.key] = s;
    }
    for (final f in section.fields) {
      if (f.type == SchoolCardFieldType.multiSelect) {
        multi[f.key] = _splitCsv(values[f.key] ?? '');
      }
    }
    _cardRecord = rec;
    _values = values;
    _multi = multi;
    _reasonCtrl.text = '';
    _syncAllControllers();
    _baseline = _signature();
    _lastPushed.clear();
    _livePending = true;
  }

  String _signature() => jsonEncode(<String, dynamic>{'v': _values, 'm': _multi});

  bool get _dirty => _section.editable && _baseline.isNotEmpty && _signature() != _baseline;

  Map<String, String> _degreeMap(String prefix) {
    final m = <String, String>{};
    for (final v in _multi['${prefix}Often'] ?? <String>[]) {
      m[v] = 'كثيراً';
    }
    for (final v in _multi['${prefix}Sometimes'] ?? <String>[]) {
      m[v] = 'أحياناً';
    }
    for (final v in _multi['${prefix}Rarely'] ?? <String>[]) {
      m[v] = 'نادراً';
    }
    return m;
  }

  Map<String, dynamic> _buildDataMap() {
    final out = <String, dynamic>{};
    for (final f in _section.fields) {
      if (f.type == SchoolCardFieldType.multiSelect) {
        out[f.key] = (_multi[f.key] ?? <String>[]).join(',');
      } else {
        out[f.key] = _values[f.key] ?? '';
      }
    }
    if (_sectionKey == 'healthAndPhysicalTraits') {
      kSchoolCardDependentHealthFields.forEach((typeKey, flagKey) {
        if (_values[flagKey] != 'true' && _values[flagKey] != 'توجد') {
          out[typeKey] = '';
        }
      });
    }
    if (_sectionKey == 'personalTraits') {
      out['traitsList'] = jsonEncode(_degreeMap('traits'));
      out['traitDegree'] = '';
    }
    if (_sectionKey == 'interests') {
      out['interestsList'] = jsonEncode(_degreeMap('interests'));
      out['interestDegree'] = '';
    }
    return out;
  }

  // =================================================== التحكم بقيم الحقول
  TextEditingController _ctrl(String key) =>
      _ctrls.putIfAbsent(key, () => TextEditingController(text: _values[key] ?? ''));

  void _syncController(String key) {
    final c = _ctrls[key];
    if (c == null) return;
    final v = _values[key] ?? '';
    if (c.text != v) {
      c.value = TextEditingValue(
        text: v,
        selection: TextSelection.collapsed(offset: v.length),
      );
    }
  }

  void _syncAllControllers() {
    for (final k in _ctrls.keys.toList()) {
      _syncController(k);
    }
  }

  void _setValue(String key, String value, {bool fromWeb = false}) {
    final old = _values[key] ?? '';
    if (old == value) return;
    _values[key] = value;
    _syncController(key);
    if (key == 'governorate' && !fromWeb) {
      _values['city'] = '';
      _syncController('city');
    }
    if (!fromWeb) _livePending = true;
    if (mounted) setState(() {});
  }

  void _onTyped(String key, String value) {
    _values[key] = value;
    _livePending = true;
    if (mounted) setState(() {});
  }

  void _toggleMulti(String key, String value, bool on) {
    final list = List<String>.from(_multi[key] ?? <String>[]);
    if (on) {
      if (!list.contains(value)) list.add(value);
      for (final other in _exclusiveGroups[key] ?? <String>[]) {
        final otherList = List<String>.from(_multi[other] ?? <String>[]);
        if (otherList.remove(value)) _multi[other] = otherList;
      }
    } else {
      list.remove(value);
    }
    _multi[key] = list;
    if (mounted) setState(() {});
  }

  bool _isVisible(SchoolCardField f) {
    if (_sectionKey == 'awardsAndPenalties' &&
        f.key != 'hasAwardsPenalties' &&
        _values['hasAwardsPenalties'] != 'true') {
      return false;
    }
    if (_sectionKey == 'healthAndPhysicalTraits') {
      final dep = kSchoolCardDependentHealthFields[f.key];
      if (dep != null) {
        final flagValue = (_values[dep] ?? '').toLowerCase();
        return flagValue == 'true' || flagValue == '1' ||
            flagValue == 'توجد' || flagValue == 'نعم';
      }
    }
    return true;
  }

  // ======================================================== أقسام القراءة
  String _recordKey(Map<String, dynamic> r) =>
      '${r['academicYearId']}-${r['stageId']}-${r['schoolId'] ?? 0}-${r['classroomId'] ?? 0}';

  TextEditingController _extraCtrl(String id, String initial) =>
      _extraCtrls.putIfAbsent(id, () => TextEditingController(text: initial));

  void _setExtra(String id, String value) {
    final c = _extraCtrls[id];
    if (c == null) return;
    c.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
    if (mounted) setState(() {});
  }

  void _syncRegistrationControllers() {
    for (final r in _records) {
      final id = 'reg:${_recordKey(r)}';
      final text = '${r['studentRegistrationNumber'] ?? ''}';
      final c = _extraCtrls[id];
      if (c == null) {
        _extraCtrls[id] = TextEditingController(text: text);
      } else if (c.text != text && !_savingExtra.contains(id)) {
        c.text = text;
      }
    }
  }

  Future<void> _loadAchievement() async {
    final id = _studentId;
    if (mounted) setState(() => _loadingSection = true);
    try {
      final r = await http
          .get(Uri.parse('$_api/StudentSchoolCard/academicachievement/$id'), headers: _headers)
          .timeout(const Duration(seconds: 25));
      if (r.statusCode == 200) {
        final d = _decode(r);
        if (d is List) {
          final list = <Map<String, dynamic>>[];
          for (var i = 0; i < d.length; i++) {
            final e = d[i];
            if (e is! Map) continue;
            final m = Map<String, dynamic>.from(e);
            m['rowKey'] = '${m['academicYearId']}-${m['stageId'] ?? 0}-${m['schoolId'] ?? 0}-$i';
            list.add(m);
          }
          _achievements = list;
          for (final m in list) {
            final cid = 'rank:${m['rowKey']}';
            final text = '${m['successRankInClassroom'] ?? ''}';
            final c = _extraCtrls[cid];
            if (c == null) {
              _extraCtrls[cid] = TextEditingController(text: text);
            } else if (!_savingExtra.contains(cid)) {
              c.text = text;
            }
          }
        }
      }
    } catch (e) {
      _snack('تعذر جلب التحصيل الدراسي: $e', error: true);
    }
    if (!mounted || id != _studentId) return;
    setState(() => _loadingSection = false);
  }

  Future<void> _loadAttendance() async {
    final id = _studentId;
    if (mounted) setState(() => _loadingSection = true);
    try {
      final r = await http
          .get(Uri.parse('$_api/StudentSchoolCard/attendance/$id'), headers: _headers)
          .timeout(const Duration(seconds: 25));
      if (r.statusCode == 200) {
        final d = _decode(r);
        if (d is Map) _attendance = Map<String, dynamic>.from(d);
      }
    } catch (e) {
      _snack('تعذر جلب المواظبة: $e', error: true);
    }
    if (!mounted || id != _studentId) return;
    setState(() => _loadingSection = false);
  }

  Future<void> _saveRegistration(Map<String, dynamic> rec) async {
    final cid = 'reg:${_recordKey(rec)}';
    if (_savingExtra.contains(cid)) return;
    final text = (_extraCtrls[cid]?.text ?? '').trim();
    setState(() => _savingExtra.add(cid));
    try {
      final r = await http
          .post(
            Uri.parse('$_api/StudentSchoolCard/updateacademicrecord'),
            headers: _jsonHeaders,
            body: jsonEncode(<String, dynamic>{
              'studentId': int.tryParse(_studentId) ?? _studentId,
              'academicYearId': rec['academicYearId'],
              'stageId': rec['stageId'],
              'schoolId': rec['schoolId'],
              'studentRegistrationNumber': text,
            }),
          )
          .timeout(const Duration(seconds: 25));
      if (r.statusCode < 200 || r.statusCode >= 300) throw Exception(_errorText(r));
      rec['studentRegistrationNumber'] = text;
      _snack('تم حفظ رقم قيد الطالب');
    } catch (e) {
      _snack('تعذر حفظ رقم القيد: $e', error: true);
    } finally {
      if (mounted) setState(() => _savingExtra.remove(cid));
    }
  }

  Future<void> _saveRank(Map<String, dynamic> row) async {
    final cid = 'rank:${row['rowKey']}';
    if (_savingExtra.contains(cid)) return;
    final text = (_extraCtrls[cid]?.text ?? '').trim();
    setState(() => _savingExtra.add(cid));
    try {
      final r = await http
          .post(
            Uri.parse('$_api/StudentSchoolCard/updateachievementrank'),
            headers: _jsonHeaders,
            body: jsonEncode(<String, dynamic>{
              'studentId': int.tryParse(_studentId) ?? _studentId,
              'academicYearId': row['academicYearId'],
              'stageId': row['stageId'],
              'schoolId': row['schoolId'],
              'successRankInClassroom': text,
            }),
          )
          .timeout(const Duration(seconds: 25));
      if (r.statusCode < 200 || r.statusCode >= 300) throw Exception(_errorText(r));
      row['successRankInClassroom'] = text;
      _snack('تم حفظ الترتيب في النجاح');
    } catch (e) {
      _snack('تعذر حفظ الترتيب: $e', error: true);
    } finally {
      if (mounted) setState(() => _savingExtra.remove(cid));
    }
  }

  // ================================================================= الحفظ
  Future<void> _save() async {
    if (_saving || !_section.editable) return;
    final stageId = _stageIdForCard;
    if (stageId == null) {
      _snack('لا توجد مرحلة دراسية للطالب', error: true);
      return;
    }
    final reason = _reasonCtrl.text.trim();
    if (_cardRecord != null && reason.isEmpty) {
      _snack('يرجى كتابة سبب التغيير قبل الحفظ', error: true);
      return;
    }
    await _stopMic();
    setState(() => _saving = true);
    final sectionKey = _sectionKey;
    try {
      final r = await http
          .post(
            Uri.parse('$_api/StudentSchoolCard/savesection'),
            headers: _jsonHeaders,
            body: jsonEncode(<String, dynamic>{
              'studentId': int.tryParse(_studentId) ?? _studentId,
              'sectionKey': sectionKey,
              'stageId': stageId,
              'dataJson': jsonEncode(_buildDataMap()),
              'changeReason': reason,
            }),
          )
          .timeout(const Duration(seconds: 40));
      if (r.statusCode < 200 || r.statusCode >= 300) throw Exception(_errorText(r));
      final d = _decode(r);
      if (!mounted || sectionKey != _sectionKey) return;
      if (d is Map) {
        _applyRecord(Map<String, dynamic>.from(d));
      } else {
        await _loadEditableSection();
      }
      _snack('تم حفظ بيانات البطاقة المدرسية');
      unawaited(_reloadLivePage());
    } catch (e) {
      _snack('تعذر الحفظ: $e', error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // ---------------------------------------------------------- رفع الصورة
  Future<void> _pickClassPhoto(ImageSource source, String key) async {
    try {
      final picked = await pickEmisImage(source: source, imageQuality: 85, maxWidth: 1600);
      if (picked == null) return;
      setState(() => _uploading = true);
      final req = http.MultipartRequest('POST', Uri.parse('$_api/Student/uploadimage'));
      req.headers.addAll(_headers);
      req.files.add(await http.MultipartFile.fromPath('image', File(picked.path).path));
      final streamed = await req.send().timeout(const Duration(seconds: 60));
      final r = await http.Response.fromStream(streamed);
      if (r.statusCode < 200 || r.statusCode >= 300) throw Exception(_errorText(r));
      final d = _decode(r);
      final url = d is Map ? '${d['imageUrl'] ?? ''}' : '';
      if (url.isEmpty) throw Exception('لم يرجع الخادم رابط الصورة');
      _setValue(key, url);
    } catch (e) {
      _snack('تعذر رفع الصورة: $e', error: true);
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  // ============================================ مزامنة آنية مع موقع EMIS
  Map<String, List<String>> _liveAliases() {
    // مفاتيح وملصقات الحقول كما تظهر فعلياً في واجهة EMIS (Vue/Quasar).
    // اختلاف نص الملصق عن تسمية التطبيق كان يمنع الجسر من العثور على الحقول.
    const siteLabels = <String, List<String>>{
      'fatherIsAlive': ['هل الأب على قيد الحياة؟'],
      'motherIsAlive': ['هل الأم على قيد الحياة؟'],
      'monthlyIncome': ['دخل الأسرة الشهري'],
      'studyEnvironmentSuitability': ['مدى ملاءمة الجو العام في البيت للدراسة'],
      'studentWorks': ['هل التلميذ يعمل'],
      'height': ['الطول (سم)'],
      'weight': ['الوزن (كغم)'],
      'rightEyeVisionDegree': ['درجة البصر (العين اليمنى)'],
      'leftEyeVisionDegree': ['درجة البصر (العين اليسرى)'],
      'hearingDegree': ['درجة السمع - عند اختيار توفر تقرير طبي'],
      'dentalExaminationAtRegistration': ['فحص الأسنان - أثناء التسجيل'],
      'visitingHealthTeamDentalNotes': ['فحص الأسنان - ملاحظات الفرقة الصحية الزائرة'],
      'traitsOften': ['الصفات بدرجة (كثيراً)'],
      'traitsSometimes': ['الصفات بدرجة (أحياناً)'],
      'traitsRarely': ['الصفات بدرجة (نادراً)'],
      'interestsOften': ['الاهتمامات بدرجة (كثيراً)'],
      'interestsSometimes': ['الاهتمامات بدرجة (أحياناً)'],
      'interestsRarely': ['الاهتمامات بدرجة (نادراً)'],
    };
    final map = <String, List<String>>{};
    for (final section in kSchoolCardSections) {
      for (final field in section.fields) {
        final aliases = <String>{field.key, field.label,
          ...?siteLabels[field.key]};
        map[field.key] = aliases.toList(growable: false);
      }
    }
    return map;
  }

  bool _syncable(SchoolCardField f) =>
      f.type == SchoolCardFieldType.text ||
      f.type == SchoolCardFieldType.number ||
      f.type == SchoolCardFieldType.textarea ||
      f.type == SchoolCardFieldType.date ||
      f.type == SchoolCardFieldType.select ||
      f.type == SchoolCardFieldType.multiSelect;

  void _onLiveStatus(String message) {
    if (!mounted) return;
    // إشارة داخلية من سكربت فتح القسم: النموذج صار جاهزاً فعلاً، فنلتقط القوائم الآن
    // بدل تأخيرات ثابتة (1.4ث/0.9ث) كانت تنتهي قبل فتح النافذة.
    if (message.startsWith('EMIS_SECTION_FLOW_DONE')) {
      if (message.endsWith(':dialog')) unawaited(_collectSectionOptions());
      return;
    }
    final ready = message.contains('جسر المزامنة الذكي جاهز') ||
        message.contains('تم فتح نموذج EMIS');
    setState(() {
      _liveStatus = message;
      if (ready && !_liveReady) _liveReady = true;
    });
    if (ready) unawaited(_openLiveSection());
  }

  void _onLiveSchema(Map<String, Map<String, dynamic>> schema) {
    if (!mounted || !_section.editable) return;
    String norm(String value) => value
        .toLowerCase()
        .replaceAll(RegExp(r'[\s؟?،,:;\-_/()]+'), '')
        .replaceAll('أ', 'ا').replaceAll('إ', 'ا').replaceAll('آ', 'ا');
    final aliases = _liveAliases();
    final found = schema.entries.any((entry) {
      if (_section.fields.any((f) => f.key == entry.key)) return true;
      final label = norm('${entry.value['label'] ?? ''}');
      return _section.fields.any((f) =>
          (aliases[f.key] ?? const <String>[]).any((a) => norm(a) == label));
    });
    if (found && !_liveDialogReady) {
      setState(() {
        _liveDialogReady = true;
        _liveStatus = 'مزامنة حية مع EMIS: متصل';
      });
      _lastPushed.clear();
      _livePending = true;
    }
  }

  void _onLiveOptions(Map<String, List<Map<String, dynamic>>> options) {
    if (!mounted) return;
    var changed = false;
    for (final entry in options.entries) {
      SchoolCardField? field;
      String normOptionKey(String value) => value.toLowerCase()
          .replaceAll(RegExp(r'[\s؟?،,:;\-_/()]+'), '')
          .replaceAll('أ', 'ا').replaceAll('إ', 'ا').replaceAll('آ', 'ا');
      final incomingKey = normOptionKey(entry.key);
      for (final f in _section.fields) {
        final candidates = <String>{f.key, f.label, ...(_liveAliases()[f.key] ?? const <String>[])};
        if (candidates.any((candidate) => normOptionKey(candidate) == incomingKey)) {
          field = f;
          break;
        }
      }
      if (field == null ||
          (field.type != SchoolCardFieldType.select &&
              field.type != SchoolCardFieldType.multiSelect &&
              field.type != SchoolCardFieldType.radio)) {
        continue;
      }
      final list = <SchoolCardOption>[];
      final seen = <String>{};
      for (final o in entry.value) {
        final label = '${o['displayName'] ?? o['label'] ?? ''}'.trim();
        final value = '${o['value'] ?? label}'.trim();
        if (label.isEmpty || value.isEmpty || !seen.add(value)) continue;
        list.add(SchoolCardOption(label, value));
      }
      if (list.isNotEmpty) {
        // كان يُخزَّن تحت entry.key (نص العنوان القادم من EMIS) بينما _optionsFor يقرأ
        // تحت field.key، فتضيع القائمة بصمت كلما اختلف المفتاحان.
        _liveOptions[field.key] = list;
        changed = true;
      }
    }
    if (_mirrorSharedLiveLists()) changed = true;
    if (changed) {
      setState(() {});
      unawaited(_persistLiveOptionsCache());
    }
  }

  /// قوائم الصفات والاهتمامات (كثيراً/أحياناً/نادراً) كتالوج واحد في EMIS؛ إذا التُقطت
  /// إحداها تُنسخ لأخواتها الفارغة.
  bool _mirrorSharedLiveLists() {
    const groups = <List<String>>[
      ['traitsOften', 'traitsSometimes', 'traitsRarely'],
      ['interestsOften', 'interestsSometimes', 'interestsRarely'],
    ];
    var changed = false;
    for (final group in groups) {
      List<SchoolCardOption>? source;
      for (final k in group) {
        final l = _liveOptions[k];
        if (l != null && l.isNotEmpty) {
          source = l;
          break;
        }
      }
      if (source == null) continue;
      for (final k in group) {
        if ((_liveOptions[k] ?? const <SchoolCardOption>[]).isEmpty) {
          _liveOptions[k] = source;
          changed = true;
        }
      }
    }
    return changed;
  }

  static const String _liveOptionsCacheKey = 'school_card_live_options_v1';

  /// آخر قوائم التُقطت فعلاً من EMIS: تُعرض فوراً ولو تأخر الجسر أو فشل في هذه الجلسة،
  /// وتُستبدل عند أي التقاط جديد.
  Future<void> _restoreLiveOptionsCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_liveOptionsCacheKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      var changed = false;
      decoded.forEach((key, value) {
        if (value is! List) return;
        final list = <SchoolCardOption>[];
        for (final item in value) {
          if (item is Map) {
            final l = '${item['l'] ?? ''}'.trim();
            final v = '${item['v'] ?? ''}'.trim();
            if (l.isNotEmpty && v.isNotEmpty) list.add(SchoolCardOption(l, v));
          }
        }
        if (list.isNotEmpty && (_liveOptions['$key'] ?? const <SchoolCardOption>[]).isEmpty) {
          _liveOptions['$key'] = list;
          changed = true;
        }
      });
      if (changed && mounted) setState(() {});
    } catch (_) {}
  }

  Future<void> _persistLiveOptionsCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final data = <String, dynamic>{
        for (final e in _liveOptions.entries)
          if (e.value.isNotEmpty)
            e.key: [
              for (final o in e.value) {'l': o.label, 'v': o.value},
            ],
      };
      await prefs.setString(_liveOptionsCacheKey, jsonEncode(data));
    } catch (_) {}
  }

  /// يلتقط قوائم القسم المفتوح بمحاولات متدرجة، ويعيد المحاولة فقط للحقول الظاهرة
  /// التي ما زالت بلا قائمة (الحقول المخفية شرطياً لا تُحاول).
  Future<void> _collectSectionOptions() async {
    final sync = _liveSyncKey.currentState;
    final section = _section;
    final sectionKey = section.key;
    if (sync == null || !section.editable) return;
    bool wantsList(SchoolCardField f) =>
        (f.type == SchoolCardFieldType.select ||
            f.type == SchoolCardFieldType.multiSelect ||
            f.type == SchoolCardFieldType.radio) &&
        f.dynamicList == null;
    var pending = section.fields.where(wantsList).map((f) => f.key).toList();
    for (var attempt = 0; attempt < 6 && pending.isNotEmpty; attempt++) {
      if (!mounted || sectionKey != _sectionKey) return;
      await sync.refreshOptions(pending);
      await Future<void>.delayed(Duration(milliseconds: 900 + attempt * 400));
      pending = section.fields
          .where((f) =>
              wantsList(f) &&
              _isVisible(f) &&
              (_liveOptions[f.key] ?? const <SchoolCardOption>[]).isEmpty)
          .map((f) => f.key)
          .toList();
    }
  }
  /// تغيير جاء من صفحة EMIS ← يُطبَّق فوراً في التطبيق.
  void _applyLiveSnapshot(Map<String, String> snap) {
    if (!_liveDialogReady || !_section.editable) return;
    var changed = false;
    for (final f in _section.fields) {
      if (!_syncable(f) || !snap.containsKey(f.key)) continue;
      final web = snap[f.key] ?? '';
      final pushed = _lastPushed[f.key];
      if (pushed == null || web == pushed) continue;
      if (web.isEmpty && f.type == SchoolCardFieldType.select) continue;
      _lastPushed[f.key] = web;
      if (f.type == SchoolCardFieldType.multiSelect) {
        final incoming = _splitCsv(web);
        final current = _multi[f.key] ?? <String>[];
        if (incoming.join('|') == current.join('|')) continue;
        _multi[f.key] = incoming;
        _values[f.key] = incoming.join(',');
        changed = true;
        continue;
      }
      if (web == (_values[f.key] ?? '')) continue;
      _values[f.key] = web;
      _syncController(f.key);
      changed = true;
    }
    if (changed && mounted) setState(() {});
  }

  /// تغيير في التطبيق ← يُدفع فوراً إلى صفحة EMIS.
  Future<void> _pushLive() async {
    final sync = _liveSyncKey.currentState;
    if (sync == null || !_liveDialogReady || !_section.editable) return;
    final values = <String, String>{};
    var selectTaken = false;
    var deferred = false;
    for (final f in _section.fields) {
      if (!_syncable(f) || !_isVisible(f)) continue;
      final v = f.type == SchoolCardFieldType.multiSelect
          ? (_multi[f.key] ?? <String>[]).join(',')
          : (_values[f.key] ?? '');
      if (_lastPushed[f.key] == v) continue;
      if (f.type == SchoolCardFieldType.select) {
        if (v.isEmpty) {
          _lastPushed[f.key] = v;
          continue;
        }
        // قائمة منسدلة واحدة في كل دفعة لتجنب تداخل القوائم المفتوحة.
        if (selectTaken) {
          deferred = true;
          continue;
        }
        selectTaken = true;
      }
      values[f.key] = v;
      _lastPushed[f.key] = v;
    }
    if (deferred) _livePending = true;
    if (values.isEmpty) return;
    await sync.pushValues(values);
  }

  static const String _openSectionJsTemplate = r'''
(async function(){
  try {
    const sleep = (ms) => new Promise(r => setTimeout(r, ms));
    const norm = (s) => String(s || '').replace(/\s+/g, ' ').trim();
    const label = __LABEL__;
    const wantDialog = __WANT__;
    const stageName = __STAGE__;
    const yearName = __YEAR__;
    const visible = (el) => !!el && (el.offsetParent !== null || el.getClientRects().length > 0);

    const closeDialogs = async () => {
      for (let i = 0; i < 4; i++) {
        const dlg = [...document.querySelectorAll('.q-dialog')].filter(visible).pop();
        if (!dlg) return;
        const btn = [...dlg.querySelectorAll('button')].find(b => {
          const t = norm(b.innerText);
          return t === 'close' || t === 'إغلاق';
        });
        if (!btn) return;
        btn.click();
        await sleep(350);
      }
    };
    await closeDialogs();

    let tab = null;
    for (let i = 0; i < 40 && !tab; i++) {
      const tabs = [...document.querySelectorAll('.q-tab')];
      tab = tabs.find(t => norm(t.innerText) === label) || null;
      if (!tab) await sleep(300);
    }
    if (!tab) return;
    if (!tab.classList.contains('q-tab--active')) {
      tab.click();
      await sleep(800);
    }
    if (!wantDialog) return;

    let rows = [];
    for (let i = 0; i < 40; i++) {
      rows = [...document.querySelectorAll('.section-history-table tbody tr')];
      if (rows.length) break;
      await sleep(300);
    }
    if (!rows.length) return;
    const text = (r) => norm(r.innerText);
    let row = rows.find(r => text(r).includes(stageName) && (!yearName || text(r).includes(yearName)))
      || rows.find(r => text(r).includes(stageName))
      || rows[rows.length - 1];
    const edit = [...row.querySelectorAll('button')].find(b => norm(b.innerText) === 'edit');
    if (!edit) return;
    edit.click();
    for (let i = 0; i < 24; i++) {
      await sleep(250);
      if ([...document.querySelectorAll('.q-dialog input, .q-dialog textarea')].some(visible)) break;
    }
    await sleep(300);
    try {
      if (window.__EMIS_APP_BRIDGE__ && window.__EMIS_APP_BRIDGE__.scanNow) {
        window.__EMIS_APP_BRIDGE__.scanNow();
      }
    } catch (e) {}
  } catch (e) {} finally {
    try {
      EmisSyncChannel.postMessage(JSON.stringify({type: 'status', message: 'EMIS_SECTION_FLOW_DONE:' + (wantDialog ? 'dialog' : 'tab')}));
    } catch (e) {}
  }
})();
''';

  /// يفتح في صفحة EMIS المخفية نفس القسم ونفس السنة الدراسية ونافذة التعديل،
  /// ليبدأ جسر المزامنة بقراءة الحقول وقوائمها ودفع القيم إليها.
  Future<void> _openLiveSection() async {
    final sync = _liveSyncKey.currentState;
    if (sync == null || !_liveReady || _loadingStudent) return;
    _liveDialogReady = false;
    _lastPushed.clear();
    final section = _section;
    // عناوين تبويبات الموقع تختلف عن العناوين المصاغة داخل التطبيق.
    // يجب استخدام عنوان EMIS الفعلي حتى يفتح القسم الصحيح في WebView المخفي.
    const emisTabLabels = <String, String>{
      'initialInformation': 'البيانات الأولية',
      'socialStatus': 'الحالة الاجتماعية',
      'healthAndPhysicalTraits': 'الصفات الجسمية والحالة الصحية',
      'personalTraits': 'الصفات الشخصية',
      'interests': 'الاهتمامات',
      'scientificInterests': 'الاهتمامات العلمية',
      'problems': 'المشكلات',
      'awardsAndPenalties': 'التقديرات والعقوبات',
      'generalStudentReport': 'التقرير العام عن الطالب',
    };
    final emisTabLabel = emisTabLabels[section.key] ?? section.label;
    final js = _openSectionJsTemplate
        .replaceAll('__LABEL__', jsonEncode(emisTabLabel))
        .replaceAll('__WANT__', section.editable ? 'true' : 'false')
        .replaceAll('__STAGE__', jsonEncode('${_record?['stageName'] ?? _student?['stageName'] ?? ''}'.trim()))
        .replaceAll('__YEAR__', jsonEncode('${_record?['academicYearName'] ?? ''}'.trim()));
    try {
      await sync.runJavaScript(js);
      // التقاط القوائم يبدأ عند وصول إشارة EMIS_SECTION_FLOW_DONE (انظر _onLiveStatus).
    } catch (_) {}
    if (mounted && section.editable) {
      setState(() => _liveStatus = 'جاري فتح القسم في EMIS للمزامنة...');
    }
  }

  Future<void> _reloadLivePage() async {
    final sync = _liveSyncKey.currentState;
    if (sync == null) return;
    _liveReady = false;
    _liveDialogReady = false;
    _lastPushed.clear();
    try {
      await sync.reloadPage();
    } catch (_) {}
  }

  /// تحديث دوري: أي تعديل تم على موقع EMIS من جهاز آخر ينعكس هنا تلقائياً
  /// (ما لم تكن هناك تعديلات غير محفوظة في التطبيق).
  Future<void> _pollServer() async {
    if (!mounted || _loadingStudent || _loadingSection || _saving || _listening) return;
    _pollTick++;
    if (_pollTick % 4 == 0) {
      unawaited(_loadCountryStructure());
      unawaited(_loadVaccinations());
    }
    if (!_section.editable || _dirty) return;
    final stageId = _stageIdForCard;
    if (stageId == null) return;
    final sectionKey = _sectionKey;
    final id = _studentId;
    try {
      final rec = await _fetchSectionRecord(sectionKey, stageId);
      if (!mounted || sectionKey != _sectionKey || id != _studentId || _dirty) return;
      final oldStamp = '${_cardRecord?['lastUpdateAt'] ?? ''}|${_cardRecord?['dataJson'] ?? ''}';
      final newStamp = '${rec?['lastUpdateAt'] ?? ''}|${rec?['dataJson'] ?? ''}';
      if (oldStamp != newStamp) {
        setState(() => _applyRecord(rec));
        _snack('تم تحديث البيانات من موقع EMIS');
      }
    } catch (_) {}
  }

  // ============================================================ المايكروفون
  Future<void> _stopMic() async {
    if (_speechSession == null && !_listening) return;
    _speechSession = null;
    if (mounted) setState(() => _listening = false);
    try {
      await GoogleSpeechService.stopListening();
    } catch (_) {}
  }

  Future<void> _toggleMic(
    String id,
    String kind,
    void Function(String) apply, {
    SchoolCardField? field,
  }) async {
    if (!AppCore.voiceInputEnabled) {
      _snack('الميكروفون مغلق من الإعدادات.', error: true);
      return;
    }
    if (_speechSession != null || _listening) {
      final same = _activeId == id;
      await _stopMic();
      if (same) return;
    }
    final microphoneAllowed = await ensureEmisMicrophonePermission();
    if (!microphoneAllowed) {
      _snack('يرجى السماح للتطبيق باستخدام الميكروفون.', error: true);
      return;
    }
    try {
      final info = await GoogleSpeechService.getInfo();
      if (info['available'] == false) {
        throw Exception('خدمة التعرف الصوتي غير متاحة على الجهاز.');
      }
      final session = GoogleSpeechService.nextSessionId();
      _speechSession = session;
      _activeId = id;
      _activeKind = kind;
      _activeField = field;
      _activeApply = apply;
      _accDigits = '';
      _accText = '';
      final started = await GoogleSpeechService.startListening(sessionId: session, locale: 'ar-IQ');
      if (!started) {
        _speechSession = null;
        throw Exception('تعذر بدء الاستماع. تحقق من خدمة التعرف الصوتي.');
      }
      if (mounted) setState(() => _listening = true);
    } catch (e) {
      if (mounted) setState(() => _listening = false);
      _snack('تعذر تشغيل الميكروفون: $e', error: true);
    }
  }

  void _onSpeech(Map<String, dynamic> event) {
    if (!mounted) return;
    final session = int.tryParse('${event['sessionId'] ?? ''}');
    if (session == null || session != _speechSession) return;
    final type = '${event['type'] ?? ''}';

    if (type == 'listening' || type == 'ready' || type == 'begin' || type == 'partial') {
      if (!_listening) setState(() => _listening = true);
    }

    if (type == 'partial' || type == 'result') {
      List<String> asList(dynamic v) =>
          v is List ? v.map((e) => '$e'.trim()).where((e) => e.isNotEmpty).toList() : <String>[];
      final alternates = asList(event['alternates']);
      final segmentAlternates = asList(event['segmentAlternates']);
      final eventText = '${event['text'] ?? ''}'.trim();
      final segment = '${event['segment'] ?? ''}'.trim();

      final fullCandidates = <String>[
        if (eventText.isNotEmpty) eventText,
        ...alternates,
        if (segment.isNotEmpty) segment,
      ];
      final segmentCandidates = <String>[
        if (segment.isNotEmpty) segment,
        ...segmentAlternates,
      ];
      _applySpeech(fullCandidates, segmentCandidates);
    }

    if (type == 'error') {
      final code = event['code'];
      final message = '${event['message'] ?? ''}'.trim();
      if (message.isNotEmpty && code != 7 && code != 6) _snack(message, error: true);
      return;
    }

    if (type == 'stopped') {
      setState(() => _listening = false);
      _speechSession = null;
    }
  }

  void _applySpeech(List<String> fullCandidates, List<String> segmentCandidates) {
    final apply = _activeApply;
    final id = _activeId;
    if (apply == null || id == null || fullCandidates.isEmpty) return;

    switch (_activeKind) {
      case 'number':
        final text = VoiceResultProcessor.resolveNumeric(
          segmentCandidates: segmentCandidates,
          fullCandidates: fullCandidates,
          accumulated: _accDigits,
          fieldKey: id,
        );
        if (text.isNotEmpty) {
          _accDigits = text;
          apply(text);
        }
        break;
      case 'date':
        for (final c in fullCandidates) {
          final normalized = VoiceResultProcessor.resolveSpokenDate(c);
          if (normalized != null) {
            apply(normalized);
            break;
          }
        }
        break;
      case 'select':
        final field = _activeField;
        if (field == null) return;
        final match = _matchOne(fullCandidates, _optionsFor(field));
        if (match != null) apply(match.value);
        break;
      case 'checkbox':
        final yn = _parseYesNo(fullCandidates);
        if (yn != null) apply(yn ? 'true' : 'false');
        break;
      case 'multi':
        final field = _activeField;
        if (field == null) return;
        final matches = _matchMany(fullCandidates.first, _optionsFor(field));
        for (final m in matches) {
          _toggleMulti(field.key, m.value, true);
        }
        break;
      default:
        final text = VoiceResultProcessor.resolveText(
          segmentCandidates: segmentCandidates,
          fullCandidates: fullCandidates,
          accumulated: _accText,
        );
        if (text.isNotEmpty) {
          _accText = text;
          apply(text);
        }
    }
  }

  // ---- مطابقة الكلام مع خيارات القوائم
  String _nrm(String s) {
    var t = s
        .replaceAll(RegExp('[\u064B-\u065F\u0670\u0640]'), '')
        .replaceAll('أ', 'ا')
        .replaceAll('إ', 'ا')
        .replaceAll('آ', 'ا')
        .replaceAll('ى', 'ي')
        .replaceAll('ة', 'ه')
        .replaceAll(RegExp(r'[^\u0621-\u064A0-9a-zA-Z/ ]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim()
        .toLowerCase();
    t = t
        .split(' ')
        .map((w) => (w.startsWith('ال') && w.length > 3) ? w.substring(2) : w)
        .join(' ');
    return t;
  }

  bool _hasWords(String haystack, String needle) {
    if (needle.isEmpty) return false;
    return ' $haystack '.contains(' $needle ');
  }

  List<String> _optionKeys(SchoolCardOption o) {
    final keys = <String>{_nrm(o.value), _nrm(o.label)};
    final dash = o.label.indexOf('–');
    if (dash > 0) keys.add(_nrm(o.label.substring(0, dash)));
    final hy = o.label.indexOf(' - ');
    if (hy > 0) keys.add(_nrm(o.label.substring(0, hy)));
    keys.removeWhere((k) => k.isEmpty);
    return keys.toList();
  }

  SchoolCardOption? _matchOne(List<String> candidates, List<SchoolCardOption> options) {
    final spoken = candidates.map(_nrm).where((e) => e.isNotEmpty).toList();
    for (final c in spoken) {
      for (final o in options) {
        if (_optionKeys(o).contains(c)) return o;
      }
    }
    for (final c in spoken) {
      SchoolCardOption? best;
      var bestLen = 0;
      for (final o in options) {
        for (final k in _optionKeys(o)) {
          if (_hasWords(c, k) && k.length > bestLen) {
            best = o;
            bestLen = k.length;
          }
        }
      }
      if (best != null) return best;
    }
    for (final c in spoken) {
      if (c.length < 2) continue;
      for (final o in options) {
        for (final k in _optionKeys(o)) {
          if (_hasWords(k, c)) return o;
        }
      }
    }
    return null;
  }

  List<SchoolCardOption> _matchMany(String spokenRaw, List<SchoolCardOption> options) {
    final c = _nrm(spokenRaw);
    final out = <SchoolCardOption>[];
    for (final o in options) {
      if (_optionKeys(o).any((k) => _hasWords(c, k))) out.add(o);
    }
    return out;
  }

  bool? _parseYesNo(List<String> candidates) {
    const yes = <String>{'نعم', 'ايوه', 'اي', 'صح', 'موجود', 'يوجد', 'توجد', 'صحيح', 'تمام', 'فعل'};
    const no = <String>{'لا', 'كلا', 'ماكو', 'خطا', 'لايوجد', 'الغاء'};
    for (final raw in candidates) {
      final tokens = _nrm(raw).split(' ');
      if (tokens.any(no.contains)) return false;
      if (tokens.any(yes.contains)) return true;
    }
    return null;
  }

  // =========================================================== التنقل
  Future<bool> _confirmDiscard() async {
    if (!_dirty) return true;
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: const Text('تعديلات غير محفوظة', style: TextStyle(fontWeight: FontWeight.w900)),
          content: const Text('لديك تعديلات لم تُحفظ في هذا القسم. هل تريد تجاهلها؟'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('بقاء'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('تجاهل', style: TextStyle(color: _red)),
            ),
          ],
        ),
      ),
    );
    return result == true;
  }

  Future<void> _selectSection(String key) async {
    if (key == _sectionKey) return;
    if (!await _confirmDiscard()) return;
    await _stopMic();
    setState(() {
      _liveOptions.clear();
      _sectionKey = key;
      _liveDialogReady = false;
      _cardRecord = null;
      _baseline = '';
    });
    await _loadSectionData();
  }

  Future<void> _selectRecord(int index) async {
    if (index == _recordIndex) return;
    if (!await _confirmDiscard()) return;
    await _stopMic();
    setState(() {
      _recordIndex = index;
      _liveDialogReady = false;
      _baseline = '';
    });
    await _loadSectionData();
  }

  Future<void> _switchStudent(int delta) async {
    final next = _index + delta;
    if (next < 0 || next >= widget.students.length) return;
    if (!await _confirmDiscard()) return;
    await _stopMic();
    setState(() {
      _index = next;
      _student = null;
      _records = <Map<String, dynamic>>[];
      _recordIndex = 0;
      _cardRecord = null;
      _baseline = '';
      _values = <String, String>{};
      _multi = <String, List<String>>{};
      _achievements = <Map<String, dynamic>>[];
      _attendance = null;
      _liveReady = false;
      _liveDialogReady = false;
      _liveStatus = 'جاري ربط المزامنة الحية مع EMIS...';
      _lastPushed.clear();
      _liveSyncKey = GlobalKey<EmisLiveSyncState>();
    });
    await _loadStudent();
  }

  Future<void> _refreshAll() async {
    if (!await _confirmDiscard()) return;
    unawaited(_loadCountryStructure());
    unawaited(_loadVaccinations());
    await _loadStudent();
  }

  // ================================================================== الواجهة
  Widget _glow(Color color, double size) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: AppCore.isWindows ? null : RadialGradient(colors: [color, color.withOpacity(0.0)]),
          color: AppCore.isWindows ? AppCore.windowsGradientFallback(RadialGradient(colors: [color, color.withOpacity(0.0)])) : null,
        ),
      );

  InputDecoration _decoration(String label, bool isDark, {Widget? suffix}) {
    return InputDecoration(
      labelText: label,
      labelStyle: TextStyle(
        fontWeight: FontWeight.bold,
        fontSize: 12.5,
        color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
      ),
      filled: true,
      fillColor: isDark ? const Color(0xFF0B0E1A).withOpacity(0.68) : const Color(0xFFF1F5F9),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      suffixIcon: suffix,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: _purple.withOpacity(isDark ? 0.35 : 0.25), width: 1.2),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: _purple.withOpacity(isDark ? 0.35 : 0.25), width: 1.2),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: _purple, width: 1.8),
      ),
    );
  }

  TextStyle _inputStyle(bool isDark) => TextStyle(
        fontWeight: FontWeight.w800,
        color: isDark ? Colors.white : const Color(0xFF0F172A),
        fontSize: 13.5,
      );

  Widget _micButton(
    String id,
    String kind,
    void Function(String) apply, {
    SchoolCardField? field,
  }) {
    final active = _listening && _activeId == id;
    return IconButton(
      tooltip: 'الإدخال الصوتي',
      visualDensity: VisualDensity.compact,
      onPressed: () => _toggleMic(id, kind, apply, field: field),
      icon: Icon(
        active ? Icons.mic_rounded : Icons.mic_none_rounded,
        color: active ? _red : _purple,
      ),
    );
  }

  // ------------------------------------------------------------ الرأس
  Widget _header(bool isDark) {
    final total = widget.students.length;
    final stage = '${_student?['stageName'] ?? _listStudent['studentStage'] ?? ''}';
    final room = '${_student?['classRoomName'] ?? _listStudent['classRoom'] ?? ''}';
    String imgUrl = '${_student?['imageUrl'] ?? ''}';
    if (imgUrl.isNotEmpty && !imgUrl.startsWith('http')) {
      imgUrl = '$_site${imgUrl.startsWith('/') ? '' : '/'}$imgUrl';
    }
    final titleColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final mutedColor = isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);

    Widget navButton(IconData icon, String tip, VoidCallback? onTap) => IconButton(
          tooltip: tip,
          visualDensity: VisualDensity.compact,
          onPressed: onTap,
          icon: Icon(icon, color: onTap == null ? mutedColor.withOpacity(0.4) : _purple),
        );

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
      decoration: BoxDecoration(
        gradient: AppCore.isWindows ? null : isDark
            ? const LinearGradient(
                begin: Alignment.topRight,
                end: Alignment.bottomLeft,
                colors: [Color(0xFF112A2E), Color(0xFF161A30), Color(0xFF241734)],
              )
            : const LinearGradient(
                begin: Alignment.topRight,
                end: Alignment.bottomLeft,
                colors: [Color(0xFFFFFFFF), Color(0xFFF3F6FC), Color(0xFFEDE9FE)],
              ),
        color: AppCore.isWindows ? AppCore.windowsGradientFallback(isDark
            ? const LinearGradient(
                begin: Alignment.topRight,
                end: Alignment.bottomLeft,
                colors: [Color(0xFF112A2E), Color(0xFF161A30), Color(0xFF241734)],
              )
            : const LinearGradient(
                begin: Alignment.topRight,
                end: Alignment.bottomLeft,
                colors: [Color(0xFFFFFFFF), Color(0xFFF3F6FC), Color(0xFFEDE9FE)],
              )) : null,
        borderRadius: BorderRadius.circular(26),
        border: Border.all(
          color: isDark ? _emerald.withOpacity(0.45) : _purple.withOpacity(0.28),
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: (isDark ? _emerald : _purple).withOpacity(0.12),
            blurRadius: 22,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                width: 58,
                height: 58,
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: AppCore.isWindows ? null : LinearGradient(
                    colors: [Color(0xFFA855F7), Color(0xFF6366F1), Color(0xFF3B82F6)],
                  ),
                  color: AppCore.isWindows ? AppCore.windowsGradientFallback(LinearGradient(
                    colors: [Color(0xFFA855F7), Color(0xFF6366F1), Color(0xFF3B82F6)],
                  )) : null,
                ),
                child: ClipOval(
                  child: Container(
                    color: isDark ? const Color(0xFF0F172A) : const Color(0xFFEEF2FF),
                    child: imgUrl.isNotEmpty
                        ? Image.network(
                            imgUrl,
                            headers: <String, String>{'Authorization': widget.token},
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) =>
                                const Icon(Icons.person_rounded, color: _purple, size: 30),
                          )
                        : const Icon(Icons.person_rounded, color: _purple, size: 30),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'البطاقة المدرسية',
                      style: TextStyle(
                        color: isDark ? _gold : _purple,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _studentFullName,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: titleColor,
                        fontSize: 15.5,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      [
                        if (stage.trim().isNotEmpty) stage,
                        if (room.trim().isNotEmpty) 'شعبة $room',
                      ].join('  •  '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: mutedColor,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              GestureDetector(
                onTap: () => Navigator.of(context).maybePop(),
                child: Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: isDark ? Colors.white.withOpacity(0.08) : _purple.withOpacity(0.10),
                    border: Border.all(
                      color: isDark ? Colors.white.withOpacity(0.18) : _purple.withOpacity(0.28),
                    ),
                  ),
                  child: Icon(
                    Icons.arrow_back_ios_rounded,
                    size: 18,
                    color: isDark ? Colors.white : const Color(0xFF1E293B),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              navButton(
                Icons.keyboard_arrow_right_rounded,
                'الطالب السابق',
                _index > 0 ? () => _switchStudent(-1) : null,
              ),
              Expanded(
                child: Text(
                  'الطالب ${_index + 1} من $total (ترتيب أبجدي)',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: mutedColor,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              navButton(
                Icons.refresh_rounded,
                'تحديث',
                _loadingStudent ? null : _refreshAll,
              ),
              navButton(
                Icons.keyboard_arrow_left_rounded,
                'الطالب التالي',
                _index < total - 1 ? () => _switchStudent(1) : null,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _liveChip(bool isDark) {
    final ok = _liveDialogReady;
    final color = ok ? _emerald : _gold;
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: color.withOpacity(isDark ? 0.14 : 0.10),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withOpacity(0.45)),
      ),
      child: Row(
        children: [
          Icon(ok ? Icons.sync_rounded : Icons.sync_problem_rounded, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _liveStatus,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: isDark ? Colors.white70 : const Color(0xFF334155),
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionTabs(bool isDark) {
    return SizedBox(
      height: 46,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: kSchoolCardSections.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final s = kSchoolCardSections[i];
          final active = s.key == _sectionKey;
          return GestureDetector(
            onTap: () => _selectSection(s.key),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                gradient: AppCore.isWindows ? null : active
                    ? const LinearGradient(colors: [Color(0xFFA855F7), Color(0xFF6366F1)])
                    : null,
                color: AppCore.isWindows
                    ? (active
                        ? AppCore.windowsGradientFallback(
                            const LinearGradient(
                              colors: [Color(0xFFA855F7), Color(0xFF6366F1)],
                            ),
                          )
                        : (isDark ? const Color(0xFF141829) : Colors.white))
                    : (active
                        ? null
                        : (isDark ? const Color(0xFF141829) : Colors.white)),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: active ? Colors.transparent : _purple.withOpacity(isDark ? 0.3 : 0.2),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    s.icon,
                    size: 18,
                    color: active ? Colors.white : _purple,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    s.label,
                    style: TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 12.5,
                      color: active
                          ? Colors.white
                          : (isDark ? Colors.white70 : const Color(0xFF334155)),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _recordPicker(bool isDark) {
    if (_records.length < 2) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: DropdownButtonFormField<int>(
        value: _recordIndex,
        isExpanded: true,
        dropdownColor: isDark ? const Color(0xFF181D32) : Colors.white,
        iconEnabledColor: _purple,
        style: _inputStyle(isDark),
        decoration: _decoration('السنة الدراسية / المرحلة', isDark),
        items: [
          for (var i = 0; i < _records.length; i++)
            DropdownMenuItem<int>(
              value: i,
              child: Text(
                '${_records[i]['academicYearName'] ?? ''} / ${_records[i]['stageName'] ?? ''}',
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
        onChanged: (v) {
          if (v != null) _selectRecord(v);
        },
      ),
    );
  }

  // ------------------------------------------------------ حقول النموذج
  Widget _textField(SchoolCardField f, bool isDark) {
    final isNumber = f.type == SchoolCardFieldType.number;
    final isDate = f.type == SchoolCardFieldType.date;
    final isArea = f.type == SchoolCardFieldType.textarea;
    final isPhone = f.key == 'guardianPhone';

    Future<void> pickDate() async {
      DateTime initial = DateTime.now();
      final parsed = DateTime.tryParse(_values[f.key] ?? '');
      if (parsed != null) initial = parsed;
      final picked = await showDatePicker(
        context: context,
        initialDate: initial,
        firstDate: DateTime(1990),
        lastDate: DateTime(2100),
        locale: const Locale('ar'),
      );
      if (picked != null) {
        final s =
            '${picked.year.toString().padLeft(4, '0')}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}';
        _setValue(f.key, s);
      }
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 15),
      child: TextFormField(
        controller: _ctrl(f.key),
        keyboardType: (isNumber || isPhone)
            ? TextInputType.number
            : (isArea ? TextInputType.multiline : TextInputType.text),
        textDirection: (isNumber || isPhone) ? TextDirection.ltr : null,
        inputFormatters: isPhone
            ? <TextInputFormatter>[
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(11),
              ]
            : null,
        minLines: isArea ? 2 : 1,
        maxLines: isArea ? 6 : 1,
        onChanged: (v) => _onTyped(f.key, v),
        style: _inputStyle(isDark),
        decoration: _decoration(
          f.label,
          isDark,
          suffix: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _micButton(
                f.key,
                isNumber || isPhone ? 'number' : (isDate ? 'date' : 'text'),
                (v) => _setValue(f.key, v),
                field: f,
              ),
              if (isDate)
                IconButton(
                  tooltip: 'اختيار التاريخ',
                  visualDensity: VisualDensity.compact,
                  onPressed: pickDate,
                  icon: const Icon(Icons.calendar_month_rounded, color: _purple),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _selectField(SchoolCardField f, bool isDark) {
    final options = _optionsFor(f);
    final current = _values[f.key] ?? '';
    final selectedValue = options.any((o) => o.value == current) ? current : null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 15),
      child: DropdownButtonFormField<String>(
        value: selectedValue,
        isExpanded: true,
        icon: const SizedBox.shrink(),
        dropdownColor: isDark ? const Color(0xFF181D32) : Colors.white,
        style: _inputStyle(isDark),
        decoration: _decoration(
          f.label,
          isDark,
          suffix: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _micButton(f.key, 'select', (v) => _setValue(f.key, v), field: f),
              const Padding(
                padding: EdgeInsets.only(left: 6),
                child: Icon(Icons.arrow_drop_down_rounded, color: _purple),
              ),
            ],
          ),
        ),
        items: options
            .map(
              (o) => DropdownMenuItem<String>(
                value: o.value,
                child: Text(o.label, overflow: TextOverflow.ellipsis),
              ),
            )
            .toList(),
        onChanged: (v) => _setValue(f.key, v ?? ''),
      ),
    );
  }

  Widget _labelRow(String label, bool isDark, Widget mic) => Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontWeight: FontWeight.w900,
                fontSize: 12.5,
                color: isDark ? Colors.white : const Color(0xFF0F172A),
              ),
            ),
          ),
          mic,
        ],
      );

  BoxDecoration _boxDecoration(bool isDark) => BoxDecoration(
        color: isDark ? const Color(0xFF0B0E1A).withOpacity(0.68) : const Color(0xFFF1F5F9),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _purple.withOpacity(isDark ? 0.35 : 0.25), width: 1.2),
      );

  Widget _radioField(SchoolCardField f, bool isDark) {
    final current = _values[f.key] ?? '';
    return Padding(
      padding: const EdgeInsets.only(bottom: 15),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 6, 6, 12),
        decoration: _boxDecoration(isDark),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _labelRow(
              f.label,
              isDark,
              _micButton(f.key, 'select', (v) => _setValue(f.key, v), field: f),
            ),
            Wrap(
              spacing: 8,
              children: [
                for (final o in _optionsFor(f))
                  ChoiceChip(
                    label: Text(
                      o.label,
                      style: TextStyle(
                        fontWeight: FontWeight.w900,
                        color: current == o.value
                            ? Colors.white
                            : (isDark ? Colors.white70 : const Color(0xFF334155)),
                      ),
                    ),
                    selected: current == o.value,
                    selectedColor: _purple,
                    backgroundColor: isDark ? const Color(0xFF181D32) : Colors.white,
                    onSelected: (_) => _setValue(f.key, o.value),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _checkboxField(SchoolCardField f, bool isDark) {
    final on = (_values[f.key] ?? 'false') == 'true';
    return Padding(
      padding: const EdgeInsets.only(bottom: 15),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 2, 6, 2),
        decoration: _boxDecoration(isDark),
        child: Row(
          children: [
            Expanded(
              child: Text(
                f.label,
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 12.5,
                  color: isDark ? Colors.white : const Color(0xFF0F172A),
                ),
              ),
            ),
            Switch(
              value: on,
              activeColor: _purple,
              onChanged: (v) => _setValue(f.key, v ? 'true' : 'false'),
            ),
            _micButton(f.key, 'checkbox', (v) => _setValue(f.key, v), field: f),
          ],
        ),
      ),
    );
  }

  String _labelForValue(SchoolCardField f, String value) {
    for (final o in _optionsFor(f)) {
      if (o.value == value) return o.label.contains(' – ') ? o.label.split(' – ').first : o.label;
    }
    return value;
  }

  Widget _multiField(SchoolCardField f, bool isDark) {
    final selected = _multi[f.key] ?? <String>[];
    return Padding(
      padding: const EdgeInsets.only(bottom: 15),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 6, 6, 12),
        decoration: _boxDecoration(isDark),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _labelRow(
              f.label,
              isDark,
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _micButton(f.key, 'multi', (_) {}, field: f),
                  IconButton(
                    tooltip: 'اختيار من القائمة',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => _openMultiPicker(f, isDark),
                    icon: const Icon(Icons.playlist_add_check_rounded, color: _purple),
                  ),
                ],
              ),
            ),
            if (selected.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2, bottom: 2),
                child: Text(
                  'لم يُحدَّد شيء',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                  ),
                ),
              )
            else
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final v in selected)
                    Chip(
                      label: Text(
                        _labelForValue(f, v),
                        style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 11.5),
                      ),
                      deleteIcon: const Icon(Icons.close_rounded, size: 16),
                      onDeleted: () => _toggleMulti(f.key, v, false),
                      backgroundColor: _purple.withOpacity(isDark ? 0.22 : 0.12),
                      side: BorderSide.none,
                      visualDensity: VisualDensity.compact,
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _openMultiPicker(SchoolCardField f, bool isDark) async {
    final options = _optionsFor(f);
    var query = '';
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          final shown = options
              .where((o) => query.isEmpty || _nrm('${o.label} ${o.value}').contains(_nrm(query)))
              .toList();
          final selected = _multi[f.key] ?? <String>[];
          return Directionality(
            textDirection: TextDirection.rtl,
            child: Container(
              height: MediaQuery.of(ctx).size.height * 0.8,
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF141829) : Colors.white,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
              ),
              child: Column(
                children: [
                  const SizedBox(height: 10),
                  Container(
                    width: 44,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.grey.withOpacity(0.5),
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 10, 8, 0),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            f.label,
                            style: TextStyle(
                              fontWeight: FontWeight.w900,
                              fontSize: 15,
                              color: isDark ? Colors.white : const Color(0xFF0F172A),
                            ),
                          ),
                        ),
                        TextButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: const Text('تم', style: TextStyle(fontWeight: FontWeight.w900)),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                    child: TextField(
                      onChanged: (v) => setSheet(() => query = v),
                      style: _inputStyle(isDark),
                      decoration: _decoration('بحث', isDark).copyWith(
                        prefixIcon: const Icon(Icons.search_rounded, color: _purple),
                      ),
                    ),
                  ),
                  Expanded(
                    child: ListView.builder(
                      itemCount: shown.length,
                      itemBuilder: (_, i) {
                        final o = shown[i];
                        final on = selected.contains(o.value);
                        return CheckboxListTile(
                          value: on,
                          activeColor: _purple,
                          title: Text(
                            o.label,
                            style: TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 13,
                              color: isDark ? Colors.white : const Color(0xFF0F172A),
                            ),
                          ),
                          onChanged: (v) {
                            _toggleMulti(f.key, o.value, v == true);
                            setSheet(() {});
                          },
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _imageField(SchoolCardField f, bool isDark) {
    String url = _values[f.key] ?? '';
    if (url.isNotEmpty && !url.startsWith('http')) {
      url = '$_site${url.startsWith('/') ? '' : '/'}$url';
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 15),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: _boxDecoration(isDark),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              f.label,
              style: TextStyle(
                fontWeight: FontWeight.w900,
                fontSize: 12.5,
                color: isDark ? Colors.white : const Color(0xFF0F172A),
              ),
            ),
            const SizedBox(height: 8),
            if (url.isNotEmpty)
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.network(
                  url,
                  height: 120,
                  headers: <String, String>{'Authorization': widget.token},
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) =>
                      const Icon(Icons.broken_image_rounded, size: 48, color: Colors.grey),
                ),
              ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                OutlinedButton.icon(
                  onPressed: _uploading ? null : () => _pickClassPhoto(ImageSource.camera, f.key),
                  icon: const Icon(Icons.camera_alt_rounded, size: 18),
                  label: const Text('كاميرا'),
                ),
                OutlinedButton.icon(
                  onPressed: _uploading ? null : () => _pickClassPhoto(ImageSource.gallery, f.key),
                  icon: const Icon(Icons.photo_library_rounded, size: 18),
                  label: const Text('المعرض'),
                ),
                if (url.isNotEmpty)
                  TextButton.icon(
                    onPressed: () => _setValue(f.key, ''),
                    icon: const Icon(Icons.delete_rounded, size: 18, color: _red),
                    label: const Text('حذف', style: TextStyle(color: _red)),
                  ),
                if (_uploading)
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: _purple),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _fieldWidget(SchoolCardField f, bool isDark) {
    switch (f.type) {
      case SchoolCardFieldType.select:
        return _selectField(f, isDark);
      case SchoolCardFieldType.radio:
        return _radioField(f, isDark);
      case SchoolCardFieldType.checkbox:
        return _checkboxField(f, isDark);
      case SchoolCardFieldType.multiSelect:
        return _multiField(f, isDark);
      case SchoolCardFieldType.image:
        return _imageField(f, isDark);
      default:
        return _textField(f, isDark);
    }
  }

  bool _pairable(SchoolCardField f) =>
      f.half &&
      (f.type == SchoolCardFieldType.text ||
          f.type == SchoolCardFieldType.number ||
          f.type == SchoolCardFieldType.date);

  List<Widget> _fieldRows(bool isDark) {
    final fields = _section.fields.where(_isVisible).toList();
    final rows = <Widget>[];
    var i = 0;
    while (i < fields.length) {
      final f = fields[i];
      if (_pairable(f) && i + 1 < fields.length && _pairable(fields[i + 1])) {
        rows.add(
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: _fieldWidget(f, isDark)),
              const SizedBox(width: 10),
              Expanded(child: _fieldWidget(fields[i + 1], isDark)),
            ],
          ),
        );
        i += 2;
      } else {
        rows.add(_fieldWidget(f, isDark));
        i++;
      }
    }
    return rows;
  }

  Widget _panel(bool isDark, Widget child) => Container(
        padding: const EdgeInsets.all(14),
        margin: const EdgeInsets.only(bottom: 14),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF141829) : Colors.white,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: _purple.withOpacity(isDark ? 0.22 : 0.14)),
          boxShadow: [
            BoxShadow(
              color: _purple.withOpacity(isDark ? 0.08 : 0.06),
              blurRadius: 14,
              offset: const Offset(0, 5),
            ),
          ],
        ),
        child: child,
      );

  Widget _editableBody(bool isDark) {
    final updatedBy = '${_cardRecord?['lastUpdateByName'] ?? ''}'.trim();
    final updatedAt = '${_cardRecord?['lastUpdateAt'] ?? ''}'.trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _recordPicker(isDark),
        _panel(
          isDark,
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(_section.icon, color: _purple, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'تعديل بيانات ${_section.label}',
                      style: TextStyle(
                        fontWeight: FontWeight.w900,
                        fontSize: 14.5,
                        color: isDark ? Colors.white : const Color(0xFF0F172A),
                      ),
                    ),
                  ),
                  if (_dirty)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: _gold.withOpacity(0.18),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Text(
                        'غير محفوظ',
                        style: TextStyle(
                          color: _gold,
                          fontSize: 10.5,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 14),
              ..._fieldRows(isDark),
              if (_cardRecord != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: TextFormField(
                    controller: _reasonCtrl,
                    minLines: 2,
                    maxLines: 4,
                    style: _inputStyle(isDark),
                    decoration: _decoration(
                      'سبب التغيير (إلزامي عند التعديل)',
                      isDark,
                      suffix: _micButton(
                        'changeReason',
                        'text',
                        (v) {
                          _reasonCtrl.value = TextEditingValue(
                            text: v,
                            selection: TextSelection.collapsed(offset: v.length),
                          );
                          setState(() {});
                        },
                      ),
                    ),
                  ),
                ),
              Text(
                updatedBy.isEmpty && updatedAt.isEmpty
                    ? 'لا يوجد سجل سابق لهذا القسم'
                    : 'آخر تعديل: ${updatedBy.isEmpty ? '-' : updatedBy} / ${updatedAt.length >= 19 ? updatedAt.substring(0, 19).replaceFirst('T', ' ') : updatedAt}',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // --------------------------------------------- أقسام القراءة فقط (واجهة)
  Widget _infoLine(String label, dynamic value, bool isDark) {
    final text = '${value ?? ''}'.trim();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 112,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
              ),
            ),
          ),
          Expanded(
            child: Text(
              text.isEmpty ? '-' : text,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w900,
                color: isDark ? Colors.white : const Color(0xFF0F172A),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _extraTextField({
    required String id,
    required String label,
    required bool isDark,
    required bool saving,
    required VoidCallback onSave,
  }) {
    final ctrl = _extraCtrls.putIfAbsent(id, () => TextEditingController());
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: TextFormField(
        controller: ctrl,
        style: _inputStyle(isDark),
        decoration: _decoration(
          label,
          isDark,
          suffix: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _micButton(id, 'text', (v) => _setExtra(id, v)),
              saving
                  ? const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 12),
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2, color: _emerald),
                      ),
                    )
                  : IconButton(
                      tooltip: 'حفظ',
                      visualDensity: VisualDensity.compact,
                      onPressed: onSave,
                      icon: const Icon(Icons.save_rounded, color: _emerald),
                    ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _academicRecordBody(bool isDark) {
    if (_records.isEmpty) return _emptyNote('لا يوجد سجل دراسي لهذا الطالب', isDark);
    return Column(
      children: [
        for (final r in _records)
          _panel(
            isDark,
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _infoLine('السنة الدراسية', r['academicYearName'], isDark),
                _infoLine('المدرسة', r['schoolName'], isDark),
                _infoLine('القسم', r['administrativeAuthorityName'], isDark),
                _infoLine('المديرية', r['directorateName'], isDark),
                _infoLine('الصف', r['stageName'], isDark),
                _infoLine('الشعبة', r['classroomName'], isDark),
                _extraTextField(
                  id: 'reg:${_recordKey(r)}',
                  label: 'رقم قيد الطالب',
                  isDark: isDark,
                  saving: _savingExtra.contains('reg:${_recordKey(r)}'),
                  onSave: () => _saveRegistration(r),
                ),
              ],
            ),
          ),
      ],
    );
  }

  String _resultText(dynamic v) {
    if (v == null || '$v'.trim().isEmpty) return '-';
    final t = '$v'.trim().toLowerCase();
    if (t.contains('succeed') || t == 'passed' || t == 'pass') return 'ناجح';
    if (t.contains('fail')) return 'راسب';
    if (t.contains('exempt')) return 'معفى';
    if (t.contains('incomplete') || t.contains('ikmal')) return 'مكمل';
    if (t.contains('pending')) return 'لم يحسب بعد';
    if (t.contains('enterfinalexam')) return 'داخل الامتحان الوزاري';
    if (t.contains('passedbygeneralpardon')) return 'ناجح باعفاء عام';
    if (t.contains('passedbysolopardon')) return 'ناجح باعفاء فردي';
    if (t.contains('passedwithdecisionmark') || t.contains('passedgwithdecisionmark')) {
      return 'ناجح بقرار';
    }
    return '$v';
  }

  Widget _achievementBody(bool isDark) {
    if (_achievements.isEmpty && !_loadingSection) {
      return _emptyNote('لا يوجد تحصيل دراسي مسجل', isDark);
    }
    return Column(
      children: [
        for (final a in _achievements)
          _panel(
            isDark,
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _infoLine('السنة الدراسية', a['academicYearName'], isDark),
                _infoLine('المدرسة', a['schoolName'], isDark),
                _infoLine('الصف', a['stageName'], isDark),
                _infoLine('الشعبة', a['classroomName'], isDark),
                _infoLine('المجموع', a['totalScore'], isDark),
                _infoLine('المعدل', a['averageScore'], isDark),
                _infoLine('الدرجة النهائية', a['effectingFinalMark'], isDark),
                _infoLine('النتيجة', _resultText(a['finalMarkStatus']), isDark),
                _infoLine('الانتقال', a['isPromoted'] == true ? 'منتقل' : (a['isPromoted'] == false ? 'غير منتقل' : '-'), isDark),
                _extraTextField(
                  id: 'rank:${a['rowKey']}',
                  label: 'الترتيب في النجاح',
                  isDark: isDark,
                  saving: _savingExtra.contains('rank:${a['rowKey']}'),
                  onSave: () => _saveRank(a),
                ),
                if (a['subjectResults'] is List && (a['subjectResults'] as List).isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(
                    'درجات المواد',
                    style: TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 12.5,
                      color: isDark ? Colors.white : const Color(0xFF0F172A),
                    ),
                  ),
                  const SizedBox(height: 4),
                  for (final s in (a['subjectResults'] as List).whereType<Map>())
                    _infoLine(
                      '${s['subjectName'] ?? ''}',
                      '${s['effectingFinalMark'] ?? s['yearEffortMark'] ?? '-'}',
                      isDark,
                    ),
                ],
              ],
            ),
          ),
      ],
    );
  }

  Widget _attendanceBody(bool isDark) {
    final att = _attendance;
    final records = att?['records'];
    if (att == null || records is! List || records.isEmpty) {
      final msg = '${att?['message'] ?? ''}'.trim();
      return _emptyNote(msg.isEmpty ? 'لا توجد بيانات مواظبة' : msg, isDark);
    }
    return Column(
      children: [
        for (final r in records.whereType<Map>())
          _panel(
            isDark,
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _infoLine('السنة الدراسية', r['academicYearName'], isDark),
                _infoLine('المدرسة', r['schoolName'], isDark),
                _infoLine('الصف', r['stageName'], isDark),
                _infoLine('الشعبة', r['classroomName'], isDark),
                _infoLine('الحالة', r['studentStatus'], isDark),
                _infoLine('غياب بدون عذر', '${r['unexcusedAbsenceDays'] ?? 0} يوم', isDark),
                _infoLine('غياب بعذر', '${r['excusedAbsenceDays'] ?? 0} يوم', isDark),
                _infoLine('غيابات الحصص', '${r['sessionAbsences'] ?? 0} حصة (${r['sessionAbsenceDays'] ?? 0} يوم)', isDark),
                _infoLine('إجمالي الغيابات', '${r['totalAbsenceDays'] ?? 0} يوم', isDark),
              ],
            ),
          ),
      ],
    );
  }

  Widget _emptyNote(String text, bool isDark) => _panel(
        isDark,
        Center(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontWeight: FontWeight.w900,
                color: isDark ? Colors.white70 : const Color(0xFF334155),
              ),
            ),
          ),
        ),
      );

  Widget _body(bool isDark) {
    if (_loadingStudent) {
      return const Center(child: CircularProgressIndicator(color: _purple));
    }
    if (_loadError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline_rounded, color: _red, size: 48),
              const SizedBox(height: 10),
              Text(
                'فشل جلب بيانات الطالب\n$_loadError',
                textAlign: TextAlign.center,
                style: const TextStyle(fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 12),
              FilledButton(onPressed: _loadStudent, child: const Text('إعادة المحاولة')),
            ],
          ),
        ),
      );
    }
    Widget content;
    switch (_section.mode) {
      case SchoolCardSectionMode.editable:
        content = _editableBody(isDark);
        break;
      case SchoolCardSectionMode.academicRecord:
        content = _academicRecordBody(isDark);
        break;
      case SchoolCardSectionMode.achievement:
        content = _achievementBody(isDark);
        break;
      case SchoolCardSectionMode.attendance:
        content = _attendanceBody(isDark);
        break;
    }
    return Stack(
      children: [
        ListView(
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
          children: [content],
        ),
        if (_loadingSection)
          const Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: LinearProgressIndicator(minHeight: 3, color: _purple),
          ),
      ],
    );
  }

  Widget _saveBar(bool isDark) {
    if (!_section.editable || _loadingStudent || _loadError != null) {
      return const SizedBox.shrink();
    }
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF141829) : Colors.white,
        border: Border(top: BorderSide(color: _purple.withOpacity(0.2))),
      ),
      child: SizedBox(
        width: double.infinity,
        height: 54,
        child: FilledButton(
          onPressed: (_saving || _loadingSection) ? null : _save,
          style: FilledButton.styleFrom(
            backgroundColor: _emerald,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            elevation: 6,
            shadowColor: _emerald.withOpacity(0.35),
          ),
          child: _saving
              ? const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                )
              : const Text(
                  'حفظ البطاقة المدرسية',
                  style: TextStyle(
                    fontSize: 16.5,
                    color: Colors.white,
                    fontWeight: FontWeight.w900,
                  ),
                ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: AppCore.themeNotifier,
      builder: (context, mode, _) {
        final isDark = mode == ThemeMode.dark;
        final bgColor = isDark ? const Color(0xFF070913) : const Color(0xFFF2F5FA);

        return Directionality(
          textDirection: TextDirection.rtl,
          child: PopScope(
            canPop: !_dirty,
            onPopInvokedWithResult: (didPop, result) async {
              if (didPop) return;
              final leave = await _confirmDiscard();
              if (leave && mounted) Navigator.of(context).pop();
            },
            child: Scaffold(
              backgroundColor: bgColor,
              body: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: () {
                  if (_listening || _speechSession != null) unawaited(_stopMic());
                },
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: AnimatedBuilder(
                        animation: _ambientController,
                        builder: (context, _) {
                          final shift = math.sin(_ambientController.value * 2 * math.pi) * 20;
                          return Stack(
                            children: [
                              Positioned(
                                top: -50 + shift,
                                right: -50,
                                child: _glow(_purple.withOpacity(isDark ? 0.18 : 0.12), 250),
                              ),
                              Positioned(
                                top: 240 - shift,
                                left: -70,
                                child: _glow(
                                  (isDark ? _gold : _blue).withOpacity(isDark ? 0.15 : 0.12),
                                  270,
                                ),
                              ),
                              Positioned(
                                bottom: -60 + shift,
                                right: 20,
                                child: _glow(
                                  (isDark ? _emerald : _purple).withOpacity(isDark ? 0.12 : 0.10),
                                  230,
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                    SafeArea(
                      child: Column(
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                            child: Column(
                              children: [
                                _header(isDark),
                                _liveChip(isDark),
                              ],
                            ),
                          ),
                          const SizedBox(height: 10),
                          _sectionTabs(isDark),
                          const SizedBox(height: 6),
                          Expanded(child: _body(isDark)),
                          _saveBar(isDark),
                        ],
                      ),
                    ),
                    // صفحة EMIS المخفية للمزامنة الحية (نفس أسلوب شاشة تعديل الطالب).
                    Positioned(
                      left: 0,
                      bottom: 0,
                      child: EmisLiveSync(
                        key: _liveSyncKey,
                        url:
                            '$_site/centers/schools/${widget.schoolId}/student-affairs/student-card/$_studentId',
                        mode: 'edit',
                        entity: 'studentCard',
                        token: widget.token,
                        recordId: _studentId,
                        ignoreInitialSnapshot: true,
                        aliases: _liveAliases(),
                        onSnapshot: _applyLiveSnapshot,
                        onSchema: _onLiveSchema,
                        onOptions: _onLiveOptions,
                        onStatus: _onLiveStatus,
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
