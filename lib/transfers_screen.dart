import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'app_core.dart';

enum TransferDirection { outgoing, incoming }

class _TransferApi {
  static const String root = 'https://emis.moedu.gov.iq/api';

  static Map<String, String> headers(String token) => {
        'Authorization': token,
        'Accept': 'application/json',
      };

  static dynamic decode(http.Response r) {
    final text = utf8.decode(r.bodyBytes);
    if (r.statusCode < 200 || r.statusCode >= 300) {
      throw Exception('HTTP ${r.statusCode}: ${text.isEmpty ? "فشل الطلب" : text}');
    }
    if (text.trim().isEmpty) return null;
    return jsonDecode(text);
  }

  static Future<dynamic> get(String token, String path) async {
    final r = await http
        .get(Uri.parse('$root$path'), headers: headers(token))
        .timeout(const Duration(seconds: 35));
    return decode(r);
  }

  static Future<void> postMultipart(
    String token,
    String path,
    Map<String, String> fields,
    List<PlatformFile> files,
  ) async {
    final request = http.MultipartRequest('POST', Uri.parse('$root$path'));
    request.headers.addAll(headers(token));
    request.fields.addAll(fields);
    for (final file in files) {
      final bytes = file.bytes;
      if (bytes == null) continue;
      request.files.add(http.MultipartFile.fromBytes(
        'attachments',
        bytes,
        filename: file.name,
      ));
    }
    final streamed = await request.send().timeout(const Duration(seconds: 90));
    final response = await http.Response.fromStream(streamed);
    decode(response);
  }

  static Future<void> post(String token, String path) async {
    final r = await http
        .post(Uri.parse('$root$path'), headers: headers(token))
        .timeout(const Duration(seconds: 35));
    decode(r);
  }
}

class TransfersScreen extends StatefulWidget {
  final String token;
  final String schoolId;
  const TransfersScreen({super.key, required this.token, required this.schoolId});

  @override
  State<TransfersScreen> createState() => _TransfersScreenState();
}

class _TransfersScreenState extends State<TransfersScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ambientController;
  @override
  void initState() {
    super.initState();
    _ambientController = AnimationController(vsync: this, duration: const Duration(seconds: 6))..repeat();
  }
  @override
  void dispose() { _ambientController.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: AppCore.themeNotifier,
      builder: (context, mode, _) {
        final dark = mode == ThemeMode.dark;
        return Directionality(
          textDirection: TextDirection.rtl,
          child: Scaffold(
            backgroundColor: dark ? const Color(0xFF070913) : const Color(0xFFF2F5FA),
            appBar: AppBar(title: const Text('الانتقالات'), backgroundColor: Colors.transparent, elevation: 0),
            body: ListView(padding: const EdgeInsets.all(16), children: [
              _menuCard(context, 'انتقالات الطلاب', 'إضافة طلب نقل طالب ومتابعة الصادر والوارد وإلغاء الطلب', Icons.school_rounded, Colors.blue, () {
                Navigator.push(context, MaterialPageRoute(builder: (_) => _TransferListScreen(token: widget.token, schoolId: widget.schoolId, isEmployee: false, direction: TransferDirection.outgoing)));
              }),
              const SizedBox(height: 14),
              _menuCard(context, 'انتقالات الموظفين والمدرسين', 'إضافة نقل أو تنسيب أو تكليف أو إكمال نصاب ومتابعة الطلبات', Icons.badge_rounded, Colors.deepPurple, () {
                Navigator.push(context, MaterialPageRoute(builder: (_) => _TransferListScreen(token: widget.token, schoolId: widget.schoolId, isEmployee: true, direction: TransferDirection.outgoing)));
              }),
            ]),
          ),
        );
      },
    );
  }

  Widget _menuCard(BuildContext context, String title, String subtitle, IconData icon, Color color, VoidCallback tap) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final foreground = dark ? Colors.white : const Color(0xFF0F172A);
    final muted = dark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(26),
        onTap: tap,
        child: Ink(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topRight,
              end: Alignment.bottomLeft,
              colors: dark
                  ? [Color.lerp(const Color(0xFF141829), color, .15)!, const Color(0xFF101525)]
                  : [Colors.white, Color.lerp(const Color(0xFFF8FAFC), color, .06)!],
            ),
            borderRadius: BorderRadius.circular(26),
            border: Border.all(color: color.withOpacity(dark ? .42 : .28), width: 1.3),
            boxShadow: [BoxShadow(color: color.withOpacity(.10), blurRadius: 20, offset: const Offset(0, 7))],
          ),
          child: Row(children: [
            Container(
              width: 58, height: 58,
              decoration: BoxDecoration(shape: BoxShape.circle, color: color.withOpacity(.14), border: Border.all(color: color.withOpacity(.35))),
              child: Icon(icon, color: color, size: 29),
            ),
            const SizedBox(width: 15),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: TextStyle(color: foreground, fontSize: 16, fontWeight: FontWeight.w900)),
              const SizedBox(height: 6),
              Text(subtitle, style: TextStyle(color: muted, fontSize: 12, height: 1.5, fontWeight: FontWeight.w600)),
            ])),
            const SizedBox(width: 8),
            Icon(Icons.chevron_left_rounded, color: color, size: 28),
          ]),
        ),
      ),
    );
  }
}

class _TransferListScreen extends StatefulWidget {
  final String token;
  final String schoolId;
  final bool isEmployee;
  final TransferDirection direction;
  const _TransferListScreen({required this.token, required this.schoolId, required this.isEmployee, required this.direction});

  @override
  State<_TransferListScreen> createState() => _TransferListScreenState();
}

class _TransferListScreenState extends State<_TransferListScreen> {
  bool loading = true;
  String? error;
  List<Map<String, dynamic>> records = [];
  TransferDirection direction = TransferDirection.outgoing;

  bool get employee => widget.isEmployee;
  String get base => employee ? 'employeeTransfer' : 'studentTransfer';
  String get listPath {
    final endpoint = employee
        ? (direction == TransferDirection.outgoing ? 'getoutgoingemployeetransfers' : 'getSchoolincomingemployeetransfers')
        : (direction == TransferDirection.outgoing ? 'getstudenttransfers' : 'getstudenttransferrequests');
    return '/$base/$endpoint?page=1&rowsPerPage=20&sortBy=id&sortOrder=desc&entityId=${Uri.encodeQueryComponent(widget.schoolId)}';
  }

  @override
  void initState() { super.initState(); direction = widget.direction; _load(); }

  Future<void> _load() async {
    setState(() { loading = true; error = null; });
    try {
      final decoded = await _TransferApi.get(widget.token, listPath);
      final data = decoded is Map ? decoded['data'] : decoded;
      final list = data is List ? data : <dynamic>[];
      records = list.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
      if (mounted) setState(() => loading = false);
    } catch (e) {
      if (mounted) setState(() { loading = false; error = e.toString(); });
    }
  }

  Future<void> _cancel(Map<String, dynamic> item) async {
    final id = item['id'];
    if (id == null) return;
    final confirmed = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('تأكيد إلغاء النقل'),
      content: Text('هل تريد إلغاء طلب نقل ${employee ? (item['employeeFullName'] ?? '') : (item['studentFullName'] ?? '')}؟'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('تراجع')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('إلغاء النقل')),
      ],
    ));
    if (confirmed != true) return;
    try {
      final endpoint = employee ? 'cancelemployeetransfer' : 'cancelstudenttransfer';
      final idKey = employee ? 'employeeTransferId' : 'studentTransferId';
      await _TransferApi.post(widget.token, '/$base/$endpoint?$idKey=$id&entityId=${Uri.encodeQueryComponent(widget.schoolId)}');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تم إرسال طلب إلغاء النقل بنجاح')));
      await _load();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('تعذر إلغاء النقل: $e')));
    }
  }

  Future<void> _add() async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _TransferFormDialog(token: widget.token, schoolId: widget.schoolId, isEmployee: employee),
    );
    if (result == true) _load();
  }

  @override
  Widget build(BuildContext context) {
    final accent = employee ? Colors.deepPurple : Colors.blue;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: Theme.of(context).brightness == Brightness.dark
            ? const Color(0xFF070913)
            : const Color(0xFFF2F5FA),
        appBar: AppBar(
          title: Text(employee ? 'انتقالات الموظفين' : 'انتقالات الطلاب',
              style: const TextStyle(fontWeight: FontWeight.w900)),
          centerTitle: true,
          elevation: 0,
          backgroundColor: Theme.of(context).scaffoldBackgroundColor,
          actions: [IconButton(onPressed: _load, icon: const Icon(Icons.refresh_rounded))],
        ),
        floatingActionButton: direction == TransferDirection.outgoing
            ? FloatingActionButton.extended(
                onPressed: _add,
                icon: const Icon(Icons.add_rounded),
                label: Text(employee ? 'إضافة نقل موظف' : 'نقل طالب'),
                backgroundColor: accent,
              )
            : null,
        body: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: SegmentedButton<TransferDirection>(
              segments: const [
                ButtonSegment(value: TransferDirection.outgoing, label: Text('الصادرة'), icon: Icon(Icons.call_made)),
                ButtonSegment(value: TransferDirection.incoming, label: Text('الواردة'), icon: Icon(Icons.call_received)),
              ],
              selected: {direction},
              onSelectionChanged: (s) { setState(() => direction = s.first); _load(); },
            ),
          ),
          Expanded(child: _body(accent)),
        ]),
      ),
    );
  }

  Widget _body(Color accent) {
    if (loading) return const Center(child: CircularProgressIndicator());
    if (error != null) return Center(child: Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [
      const Icon(Icons.cloud_off, size: 42, color: Colors.redAccent),
      const SizedBox(height: 10), Text(error!, textAlign: TextAlign.center),
      const SizedBox(height: 12), FilledButton(onPressed: _load, child: const Text('إعادة المحاولة')),
    ])));
    if (records.isEmpty) return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
      Icon(Icons.inbox_outlined, size: 56, color: accent.withOpacity(.7)),
      const SizedBox(height: 12), const Text('لا توجد عمليات انتقال حالياً'),
      const SizedBox(height: 12), OutlinedButton.icon(onPressed: _add, icon: const Icon(Icons.add), label: const Text('إضافة عملية نقل')),
    ]));
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 90),
        itemCount: records.length,
        itemBuilder: (context, i) {
          final item = records[i];
          final name = employee ? item['employeeFullName'] : item['studentFullName'];
          final status = (item['status'] ?? 'غير محدد').toString();
          final cancelable = direction == TransferDirection.outgoing &&
              status.contains('قيد المراجعة');
          final attachments = item['attachments'] is List ? (item['attachments'] as List).length : 0;
          return Container(
            margin: const EdgeInsets.only(bottom: 13),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topRight,
                end: Alignment.bottomLeft,
                colors: Theme.of(context).brightness == Brightness.dark
                    ? [const Color(0xFF171D31), const Color(0xFF101525)]
                    : [Colors.white, const Color(0xFFF8FAFC)],
              ),
              borderRadius: BorderRadius.circular(23),
              border: Border.all(color: accent.withOpacity(.22), width: 1.2),
              boxShadow: [BoxShadow(color: accent.withOpacity(.07), blurRadius: 18, offset: const Offset(0, 6))],
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Container(
                    width: 46, height: 46,
                    decoration: BoxDecoration(color: accent.withOpacity(.13), shape: BoxShape.circle),
                    child: Icon(employee ? Icons.badge_rounded : Icons.school_rounded, color: accent, size: 23),
                  ),
                  const SizedBox(width: 11),
                  Expanded(child: Text(
                    (name ?? 'بدون اسم').toString(),
                    style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 14.5),
                  )),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: _statusColor(status).withOpacity(.12),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: _statusColor(status).withOpacity(.30)),
                    ),
                    child: Text(status, style: TextStyle(color: _statusColor(status), fontWeight: FontWeight.w800, fontSize: 10.5)),
                  ),
                ]),
                const SizedBox(height: 15),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: accent.withOpacity(.055),
                    borderRadius: BorderRadius.circular(17),
                  ),
                  child: Column(children: [
                    _info('من', item['fromEntity']),
                    _info('إلى', item['toEntity']),
                    if (employee) _info('نوع العملية', item['transferType']),
                    if (!employee && item['transferDestinationType'] != null)
                      _info('نوع النقل', item['transferDestinationType']),
                    _info('تاريخ الطلب', item['date']),
                    if (employee && item['endDate'] != null) _info('تاريخ الانتهاء', item['endDate']),
                    if (item['rejectionReason']?.toString().isNotEmpty == true)
                      _info('الملاحظات', item['rejectionReason']),
                    if (attachments > 0) _info('المرفقات', '$attachments ملف'),
                  ]),
                ),
                if (cancelable) ...[
                  const SizedBox(height: 10),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                      onPressed: () => _cancel(item),
                      icon: const Icon(Icons.cancel_outlined, size: 18),
                      label: const Text('إلغاء النقل'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.redAccent,
                        side: BorderSide(color: Colors.redAccent.withOpacity(.35)),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      ),
                    ),
                  ),
                ],
              ]),
            ),
          );
        },
      ),
    );
  }

  Widget _info(String label, dynamic value) {
    if (value == null || value.toString().isEmpty) return const SizedBox.shrink();
    return Padding(padding: const EdgeInsets.only(bottom: 5), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(width: 92, child: Text('$label:', style: TextStyle(color: Theme.of(context).hintColor, fontSize: 12))),
      Expanded(child: Text(value.toString(), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600))),
    ]));
  }

  Color _statusColor(String status) {
    if (status.contains('مقبول')) return Colors.green;
    if (status.contains('مرفوض') || status == 'ملغي') return Colors.red;
    if (status.contains('مراجعة')) return Colors.orange;
    return Colors.blueGrey;
  }
}

class _TransferFormDialog extends StatefulWidget {
  final String token;
  final String schoolId;
  final bool isEmployee;
  const _TransferFormDialog({required this.token, required this.schoolId, required this.isEmployee});

  @override
  State<_TransferFormDialog> createState() => _TransferFormDialogState();
}

class _TransferFormDialogState extends State<_TransferFormDialog> {
  final _searchController = TextEditingController();
  final _entitySearchController = TextEditingController();
  final _endDateController = TextEditingController();
  List<Map<String, dynamic>> people = [];
  List<Map<String, dynamic>> stages = [];
  List<Map<String, dynamic>> entities = [];
  List<PlatformFile> files = [];
  final Set<String> selectedStudentIds = <String>{};
  Map<String, dynamic>? selectedPerson;
  Map<String, dynamic>? selectedStage;
  Map<String, dynamic>? selectedEntity;
  int? ancestorGdoId;
  int? studentGender;
  String studentTransferDestinationType = 'داخلي';
  int _entitySearchGeneration = 0;
  bool loadingPeople = false;
  bool loadingEntities = false;
  bool saving = false;
  String transferType = 'نقل';
  List<String> transferTypes = <String>[];
  bool isTeacher = true;
  String? error;

  bool get employee => widget.isEmployee;

  @override
  void initState() {
    super.initState();
    _loadSchoolInfo();
    if (employee) {
      _loadPeople();
      _loadTransferOptions();
      _loadEntities();
    } else {
      _loadStages();
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    _entitySearchController.dispose();
    _endDateController.dispose();
    super.dispose();
  }

  List<Map<String, dynamic>> _extractMapList(dynamic decoded) {
    dynamic current = decoded;
    for (var depth = 0; depth < 6; depth++) {
      if (current is List) {
        return current.whereType<Map>().map((item) {
          final map = <String, dynamic>{};
          item.forEach((key, value) => map[key.toString()] = value);
          return map;
        }).toList();
      }
      if (current is Map) {
        dynamic next;
        var found = false;
        for (final key in const [
          'data', 'result', 'items', 'results', 'employees', 'students',
          'schools', 'entities', 'stages'
        ]) {
          final value = current[key];
          if (value is List || value is Map) {
            next = value;
            found = true;
            break;
          }
        }
        if (found) { current = next; continue; }
      }
      break;
    }
    return <Map<String, dynamic>>[];
  }

  String _stageId(Map<String, dynamic> stage) =>
      (stage['id'] ?? stage['value'] ?? stage['stageId'] ?? '').toString();

  String _stageName(Map<String, dynamic> stage) =>
      (stage['displayName'] ?? stage['name'] ?? stage['label'] ??
              stage['text'] ?? stage['value'] ?? 'مرحلة غير مسماة')
          .toString();

  int? _stageOrder(Map<String, dynamic> stage) {
    for (final key in const ['stageOrder', 'order', 'stageLevel', 'stageOrderId']) {
      final value = stage[key];
      if (value is num) return value.toInt();
      final parsed = int.tryParse('$value');
      if (parsed != null) return parsed;
    }
    // Fallback for the official Arabic stage labels (e.g. الثالث متوسط = 9).
    final label = _stageName(stage).replaceAll('أ', 'ا').replaceAll('إ', 'ا');
    final ordinals = <String, int>{
      'الاول': 1, 'الأول': 1, 'اول': 1,
      'الثاني': 2, 'الثالث': 3, 'الرابع': 4,
      'الخامس': 5, 'السادس': 6,
    };
    int? ordinal;
    for (final entry in ordinals.entries) {
      if (label.contains(entry.key)) { ordinal = entry.value; break; }
    }
    if (ordinal == null) {
      final match = RegExp(r'([1-9]|1[0-2])').firstMatch(label);
      ordinal = match == null ? null : int.tryParse(match.group(1)!);
    }
    if (ordinal == null) return null;
    if (label.contains('متوسط')) return ordinal + 6;
    if (label.contains('اعدادي') || label.contains('ثانوي')) return ordinal + 6;
    return ordinal;
  }

  Future<void> _loadSchoolInfo() async {
    try {
      final decoded = await _TransferApi.get(
        widget.token,
        '/ministryentity/getministryentityinformation/${widget.schoolId}',
      );
      if (!mounted || decoded is! Map) return;
      final id = decoded['ancestorGDOId'];
      setState(() => ancestorGdoId = id is num ? id.toInt() : int.tryParse('$id'));
    } catch (_) {}
  }

  Future<void> _loadStages() async {
    setState(() { loadingPeople = true; error = null; });
    try {
      final decoded = await _TransferApi.get(
        widget.token,
        '/selectoption/getAvailableStagesForStudent?schoolId=${widget.schoolId}',
      );
      if (!mounted) return;
      setState(() { stages = _extractMapList(decoded); loadingPeople = false; });
    } catch (e) {
      if (mounted) setState(() {
        loadingPeople = false;
        error = 'تعذر تحميل الصفوف الدراسية: $e';
      });
    }
  }

  Future<void> _loadStudentsForStage(Map<String, dynamic> stage) async {
    final stageId = _stageId(stage);
    if (stageId.isEmpty) return;
    setState(() {
      selectedStage = stage;
      people = [];
      selectedStudentIds.clear();
      loadingPeople = true;
      error = null;
    });
    try {
      final decoded = await _TransferApi.get(
        widget.token,
        '/selectoption/getstudentsbyschoolsandstages/${widget.schoolId}/$stageId',
      );
      if (!mounted) return;
      setState(() {
        people = _extractMapList(decoded);
        loadingPeople = false;
      });
    } catch (e) {
      if (mounted) setState(() {
        loadingPeople = false;
        error = 'تعذر تحميل طلاب الصف: $e';
      });
    }
  }

  Future<void> _loadPeople() async {
    setState(() { loadingPeople = true; error = null; });
    try {
      final decoded = await _TransferApi.get(
        widget.token,
        '/employee/getemployeesbyentities?page=1&rowsPerPage=1000&sortBy=id&sortOrder=desc&entityId=${Uri.encodeQueryComponent(widget.schoolId)}&isTeacher=$isTeacher',
      );
      if (!mounted) return;
      setState(() {
        people = _extractMapList(decoded);
        selectedPerson = null;
        loadingPeople = false;
      });
    } catch (e) {
      if (mounted) setState(() {
        loadingPeople = false;
        error = 'تعذر تحميل قائمة ${isTeacher ? "المدرسين" : "الموظفين"}: $e';
      });
    }
  }

  Future<void> _loadTransferOptions() async {
    try {
      final decoded = await _TransferApi.get(
        widget.token,
        '/employeetransfer/getallemployeetransferoptions',
      );
      if (decoded is Map && decoded['transferType'] is List && mounted) {
        setState(() {
          transferTypes = (decoded['transferType'] as List)
              .map((e) => e.toString())
              .where((e) => e.trim().isNotEmpty)
              .toList();
          if (transferTypes.isNotEmpty && !transferTypes.contains(transferType)) {
            transferType = transferTypes.first;
          }
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = 'تعذر تحميل أنواع النقل: $e');
    }
  }

  Future<void> _loadEntities([String query = '']) async {
    final generation = ++_entitySearchGeneration;
    if (employee) {
      setState(() => loadingEntities = true);
      try {
        final path = query.trim().isEmpty
            ? '/MinistryEntity/GetAllMinistryEntitiesWithSchools'
            : '/MinistryEntity/SearchAndGetAllMinistryEntitiesWithSchools/${Uri.encodeComponent(query.trim())}';
        final decoded = await _TransferApi.get(widget.token, path);
        if (!mounted || generation != _entitySearchGeneration) return;
        setState(() {
          entities = _extractMapList(decoded);
          if (selectedEntity != null &&
              !entities.any((e) => _entityId(e) == _entityId(selectedEntity!))) {
            selectedEntity = null;
          }
          loadingEntities = false;
        });
      } catch (e) {
        if (mounted) setState(() {
          loadingEntities = false;
          error = 'تعذر تحميل الجهات: $e';
        });
      }
      return;
    }

    if (query.trim().isEmpty) {
      if (mounted) setState(() { entities = []; selectedEntity = null; });
      return;
    }
    if (studentTransferDestinationType == 'داخلي' &&
        (selectedStage == null || ancestorGdoId == null)) {
      if (mounted) setState(() {
        error = 'تعذر تحديد المديرية أو الصف الدراسي للبحث عن المدارس';
      });
      return;
    }
    setState(() => loadingEntities = true);
    try {
      String path;
      if (studentTransferDestinationType == 'داخلي') {
        final order = _stageOrder(selectedStage!);
        if (order == null || studentGender == null) {
          throw Exception('بيانات ترتيب الصف أو جنس الطالب غير متاحة');
        }
        path = '/school/GetAllSchoolsByStageOrderAndGender/'
            '$order/$studentGender/$ancestorGdoId/'
            '${Uri.encodeComponent(query.trim())}';
      } else {
        path = '/MinistryEntity/SearchAndGetAllMinistryEntitiesWithSchools/'
            '${Uri.encodeComponent(query.trim())}';
      }
      final decoded = await _TransferApi.get(widget.token, path);
      if (!mounted || generation != _entitySearchGeneration) return;
      setState(() { entities = _extractMapList(decoded); loadingEntities = false; });
    } catch (e) {
      if (mounted) setState(() {
        loadingEntities = false;
        error = 'تعذر البحث عن الجهة المستقبلة: $e';
      });
    }
  }

  Future<void> _pickFiles() async {
    final result = await FilePicker.platform.pickFiles(allowMultiple: true, withData: true, type: FileType.custom, allowedExtensions: ['pdf', 'jpg', 'jpeg', 'png']);
    if (result != null && mounted) setState(() => files = result.files);
  }

  String _personName(Map<String, dynamic> p) =>
      (p['displayName'] ?? p['fullName'] ?? p['employeeFullName'] ??
              p['employeeName'] ?? p['name'] ??
              '${p['firstName'] ?? ''} ${p['lastName'] ?? ''}')
          .toString().replaceAll('|', '').trim();
  String _personId(Map<String, dynamic> p) => (p['value'] ?? p['id'] ?? p['employeeId'] ?? '').toString();
  String _entityName(Map<String, dynamic> e) => (e['name'] ?? e['displayName'] ?? '').toString();
  String _entityId(Map<String, dynamic> e) => (e['id'] ?? e['value'] ?? '').toString();

  Future<void> _save() async {
    if (employee) {
      if (selectedPerson == null || selectedEntity == null) {
        setState(() => error = 'يرجى اختيار المدرس/الموظف والجهة المنقول إليها');
        return;
      }
      if (transferType.trim().isEmpty || _endDateController.text.trim().isEmpty) {
        setState(() => error = 'يرجى اختيار نوع النقل وتاريخ الانتهاء');
        return;
      }
    } else if (selectedStage == null || selectedStudentIds.isEmpty ||
        selectedEntity == null) {
      setState(() => error = 'يرجى اختيار الصف والطالب/الطلاب والجهة المستقبلة');
      return;
    }

    setState(() { saving = true; error = null; });
    try {
      final fields = <String, String>{
        'fromEntityId': widget.schoolId,
        'toEntityId': _entityId(selectedEntity!),
      };
      final endpoint = employee
          ? 'employeeTransfer/addemployeetransfer'
          : 'studentTransfer/addstudenttransfer';
      if (employee) {
        fields['employeeId'] = _personId(selectedPerson!);
        final typeIndex = transferTypes.indexOf(transferType);
        if (typeIndex < 0) throw Exception('نوع النقل المحدد غير موجود ضمن خيارات النظام');
        fields['transferType'] = (typeIndex + 1).toString();
        fields['endDate'] = _endDateController.text.trim();
      } else {
        fields['studentIds'] = selectedStudentIds.join(',');
      }
      await _TransferApi.postMultipart(
        widget.token,
        '/$endpoint?entityId=${Uri.encodeQueryComponent(widget.schoolId)}',
        fields,
        files,
      );
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() {
        saving = false;
        error = 'فشل إرسال طلب النقل: $e';
      });
    }
  }

  Future<void> _pickStudents() async {
    _searchController.clear();
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, updateDialog) {
          final filtered = people.where((p) =>
            _personName(p).toLowerCase().contains(_searchController.text.trim().toLowerCase())
          ).toList();
          return Directionality(
          textDirection: TextDirection.rtl,
          child: AlertDialog(
            title: Text('اختيار الطلاب (${selectedStudentIds.length})'),
            content: SizedBox(
              width: 520,
              height: MediaQuery.of(context).size.height * .55,
              child: Column(children: [
                TextField(
                  controller: _searchController,
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    hintText: 'ابحث باسم الطالب',
                  ),
                  onChanged: (_) => updateDialog(() {}),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: filtered.isEmpty
                      ? const Center(child: Text('لا يوجد طلاب مطابقون'))
                      : ListView.builder(
                          itemCount: filtered.length,
                          itemBuilder: (_, index) {
                            final student = filtered[index];
                            final id = _personId(student);
                            final checked = selectedStudentIds.contains(id);
                            return CheckboxListTile(
                              value: checked,
                              dense: true,
                              title: Text(_personName(student)),
                              onChanged: (value) {
                                updateDialog(() {
                                  if (value == true) {
                                    selectedStudentIds.add(id);
                                    final gender = student['gender'];
                                    studentGender = gender is num ? gender.toInt() : int.tryParse('$gender');
                                  } else {
                                    selectedStudentIds.remove(id);
                                  }
                                });
                                if (mounted) setState(() {});
                              },
                            );
                          },
                        ),
                ),
              ]),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('تم')),
            ],
          ),
        );
        },
      ),
    );
    _searchController.clear();
  }

  InputDecoration _fieldDecoration(String label, {IconData? icon}) {
    return InputDecoration(
      labelText: label,
      prefixIcon: icon == null ? null : Icon(icon),
      filled: true,
      fillColor: Theme.of(context).colorScheme.surface.withOpacity(.68),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 17),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(17), borderSide: BorderSide(color: Theme.of(context).dividerColor.withOpacity(.4))),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(17), borderSide: BorderSide(color: Theme.of(context).dividerColor.withOpacity(.45))),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(17), borderSide: BorderSide(color: Theme.of(context).colorScheme.primary, width: 1.6)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final accent = employee ? const Color(0xFFA855F7) : const Color(0xFF3B82F6);
    final filteredPeople = people.where((p) =>
      _personName(p).toLowerCase().contains(_searchController.text.trim().toLowerCase())
    ).take(100).toList();
    final selectedStudentsLabel = people
        .where((p) => selectedStudentIds.contains(_personId(p)))
        .map(_personName)
        .join('، ');
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 22),
        backgroundColor: dark ? const Color(0xFF141829) : Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 540,
            maxHeight: MediaQuery.of(context).size.height * .88,
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              padding: const EdgeInsets.fromLTRB(20, 18, 16, 18),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: dark
                      ? [Color.lerp(const Color(0xFF141829), accent, .20)!, const Color(0xFF12172A)]
                      : [Color.lerp(Colors.white, accent, .08)!, const Color(0xFFF8FAFC)],
                ),
                borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
                border: Border(bottom: BorderSide(color: accent.withOpacity(.24))),
              ),
              child: Row(children: [
                Container(
                  width: 44, height: 44,
                  decoration: BoxDecoration(color: accent.withOpacity(.14), shape: BoxShape.circle),
                  child: Icon(employee ? Icons.badge_rounded : Icons.school_rounded, color: accent),
                ),
                const SizedBox(width: 12),
                Expanded(child: Text(
                  employee ? 'إضافة عملية نقل موظف' : 'إضافة طلب نقل طالب',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900, color: dark ? Colors.white : const Color(0xFF0F172A)),
                )),
                IconButton(onPressed: saving ? null : () => Navigator.pop(context, false), icon: const Icon(Icons.close_rounded)),
              ]),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(18, 18, 18, 8),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  if (!employee) ...[
                    DropdownButtonFormField<Map<String, dynamic>>(
                      isExpanded: true,
                      value: selectedStage,
                      decoration: _fieldDecoration('الصفوف الدراسية *', icon: Icons.menu_book_rounded),
                      items: stages.map((stage) => DropdownMenuItem(
                        value: stage,
                        child: Text(_stageName(stage), overflow: TextOverflow.ellipsis),
                      )).toList(),
                      onChanged: loadingPeople ? null : (stage) {
                        if (stage != null) _loadStudentsForStage(stage);
                      },
                    ),
                    const SizedBox(height: 14),
                    OutlinedButton.icon(
                      onPressed: loadingPeople || selectedStage == null ? null : _pickStudents,
                      icon: const Icon(Icons.groups_2_rounded),
                      label: Text(selectedStudentIds.isEmpty
                          ? 'اختر الطالب / الطلاب *'
                          : 'تم اختيار ${selectedStudentIds.length} طالب'),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(56),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(17)),
                      ),
                    ),
                    if (selectedStudentsLabel.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 7),
                        child: Text(selectedStudentsLabel, maxLines: 2, overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: Theme.of(context).hintColor, fontSize: 12)),
                      ),
                    const SizedBox(height: 14),
                    DropdownButtonFormField<String>(
                      value: studentTransferDestinationType,
                      decoration: _fieldDecoration('نوع النقل *', icon: Icons.swap_horiz_rounded),
                      items: const [
                        DropdownMenuItem(value: 'داخلي', child: Text('داخلي')),
                        DropdownMenuItem(value: 'خارجي', child: Text('خارجي')),
                      ],
                      onChanged: (value) {
                        setState(() {
                          studentTransferDestinationType = value ?? 'داخلي';
                          selectedEntity = null;
                          entities = [];
                          _entitySearchController.clear();
                        });
                      },
                    ),
                    const SizedBox(height: 14),
                  ] else ...[
                    DropdownButtonFormField<String>(
                      value: transferTypes.contains(transferType) ? transferType : null,
                      isExpanded: true,
                      decoration: _fieldDecoration('نوع النقل *', icon: Icons.assignment_turned_in_outlined),
                      items: transferTypes.map((type) => DropdownMenuItem(value: type, child: Text(type))).toList(),
                      onChanged: (v) => setState(() => transferType = v ?? ''),
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      controller: _searchController,
                      decoration: _fieldDecoration('بحث عن المدرس', icon: Icons.search),
                      onChanged: (_) => setState(() {}),
                    ),
                    const SizedBox(height: 10),
                    if (loadingPeople) const LinearProgressIndicator(),
                    DropdownButtonFormField<Map<String, dynamic>>(
                      isExpanded: true,
                      value: selectedPerson,
                      decoration: _fieldDecoration('اسم المدرس *'),
                      items: filteredPeople.map((p) => DropdownMenuItem(
                        value: p,
                        child: Text('${_personName(p)}${p['employeeIdNumber'] != null ? ' | ${p['employeeIdNumber']}' : ''}', overflow: TextOverflow.ellipsis),
                      )).toList(),
                      onChanged: (v) => setState(() => selectedPerson = v),
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      controller: _endDateController,
                      readOnly: true,
                      decoration: _fieldDecoration('تاريخ الانتهاء *', icon: Icons.calendar_month_rounded).copyWith(hintText: 'yyyy-mm-dd'),
                      onTap: () async {
                        final now = DateTime.now();
                        final date = await showDatePicker(
                          context: context,
                          initialDate: now,
                          firstDate: DateTime(now.year - 1),
                          lastDate: DateTime(now.year + 10),
                        );
                        if (date != null) {
                          setState(() => _endDateController.text =
                            '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}');
                        }
                      },
                    ),
                    const SizedBox(height: 14),
                  ],
                  TextField(
                    controller: _entitySearchController,
                    decoration: _fieldDecoration(
                      employee ? 'بحث عن الجهة المنقول إليها' : 'البحث عن الجهة المستقبلة',
                      icon: Icons.search_rounded,
                    ),
                    onChanged: (value) {
                      // Debounce is deliberately avoided in this lightweight form;
                      // each completed search string maps to the official endpoint.
                      _loadEntities(value);
                    },
                  ),
                  const SizedBox(height: 10),
                  if (loadingEntities) const LinearProgressIndicator(),
                  if (entities.isEmpty && !loadingEntities && _entitySearchController.text.trim().isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Text('لا توجد نتائج مطابقة', textAlign: TextAlign.center,
                        style: TextStyle(color: Theme.of(context).hintColor)),
                    ),
                  DropdownButtonFormField<Map<String, dynamic>>(
                    isExpanded: true,
                    value: selectedEntity,
                    decoration: _fieldDecoration(employee ? 'الجهة المنقول إليها *' : 'إلى الجهة *', icon: Icons.account_balance_rounded),
                    items: entities.map((e) => DropdownMenuItem(
                      value: e,
                      child: Text(
                        _entityName(e) + (e['parents'] is List && (e['parents'] as List).isNotEmpty
                            ? ' — ${(e['parents'] as List).whereType<Map>().map((p) => p['name']).whereType<String>().take(2).join(' / ')}'
                            : ''),
                        overflow: TextOverflow.ellipsis,
                      ),
                    )).toList(),
                    onChanged: (v) => setState(() => selectedEntity = v),
                  ),
                  const SizedBox(height: 14),
                  OutlinedButton.icon(
                    onPressed: _pickFiles,
                    icon: const Icon(Icons.attach_file_rounded),
                    label: Text(files.isEmpty ? 'المرفقات' : 'المرفقات (${files.length})'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(52),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(17)),
                    ),
                  ),
                  if (files.isNotEmpty)
                    ...files.map((f) => ListTile(
                      dense: true,
                      leading: const Icon(Icons.insert_drive_file_outlined),
                      title: Text(f.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                      trailing: IconButton(
                        icon: const Icon(Icons.close, color: Colors.redAccent),
                        onPressed: () => setState(() => files.remove(f)),
                      ),
                    )),
                  if (loadingPeople && !employee && stages.isEmpty)
                    const Padding(padding: EdgeInsets.only(top: 8), child: LinearProgressIndicator()),
                  if (error != null)
                    Container(
                      margin: const EdgeInsets.only(top: 12),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.red.withOpacity(.08),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: Colors.red.withOpacity(.25)),
                      ),
                      child: Text(error!, style: const TextStyle(color: Colors.redAccent), textAlign: TextAlign.center),
                    ),
                ]),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 8, 18, 18),
              child: Row(children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: saving ? null : () => Navigator.pop(context, false),
                    style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(50), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
                    child: const Text('إلغاء'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 2,
                  child: FilledButton.icon(
                    onPressed: saving ? null : _save,
                    style: FilledButton.styleFrom(backgroundColor: accent, minimumSize: const Size.fromHeight(50), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
                    icon: saving
                        ? const SizedBox(width: 17, height: 17, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.send_rounded),
                    label: Text(saving ? 'جارٍ الإرسال...' : 'حفظ طلب النقل'),
                  ),
                ),
              ]),
            ),
          ]),
        ),
      ),
    );
  }

}
