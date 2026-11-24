import 'dart:convert';
import 'dart:math' as math;

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
    return Card(
      elevation: 3,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: tap,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(children: [
            CircleAvatar(radius: 28, backgroundColor: color.withOpacity(.12), child: Icon(icon, color: color, size: 29)),
            const SizedBox(width: 15),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
              const SizedBox(height: 6),
              Text(subtitle, style: TextStyle(color: Theme.of(context).hintColor, height: 1.4)),
            ])),
            Icon(Icons.chevron_left, color: color),
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
    return '/$base/$endpoint?page=1&rowsPerPage=100&sortBy=id&sortOrder=desc&entityId=${Uri.encodeQueryComponent(widget.schoolId)}';
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
        appBar: AppBar(
          title: Text(employee ? 'انتقالات الموظفين' : 'انتقالات الطلاب'),
          actions: [IconButton(onPressed: _load, icon: const Icon(Icons.refresh))],
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: _add,
          icon: const Icon(Icons.add),
          label: Text(employee ? 'إضافة نقل موظف' : 'نقل طالب'),
        ),
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
              !['ملغي', 'مرفوض', 'منتهي', 'مقبول'].contains(status);
          final attachments = item['attachments'] is List ? (item['attachments'] as List).length : 0;
          return Card(
            margin: const EdgeInsets.only(bottom: 12),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: Padding(
              padding: const EdgeInsets.all(15),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(child: Text((name ?? 'بدون اسم').toString(), style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 15))),
                  Container(padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5), decoration: BoxDecoration(color: _statusColor(status).withOpacity(.12), borderRadius: BorderRadius.circular(20)), child: Text(status, style: TextStyle(color: _statusColor(status), fontWeight: FontWeight.bold, fontSize: 11))),
                ]),
                const SizedBox(height: 10),
                _info('من', item['fromEntity']),
                _info('إلى', item['toEntity']),
                if (employee) _info('نوع العملية', item['transferType']),
                _info('التاريخ', item['date']),
                if (employee && item['endDate'] != null) _info('تاريخ الانتهاء', item['endDate']),
                if (item['rejectionReason']?.toString().isNotEmpty == true) _info('ملاحظات', item['rejectionReason']),
                if (attachments > 0) _info('المرفقات', '$attachments ملف'),
                if (cancelable) Align(alignment: Alignment.centerLeft, child: TextButton.icon(
                  onPressed: () => _cancel(item),
                  icon: const Icon(Icons.cancel_outlined, color: Colors.red),
                  label: const Text('إلغاء النقل', style: TextStyle(color: Colors.red)),
                )),
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
  final _stageController = TextEditingController(text: '1159');
  final _endDateController = TextEditingController();
  List<Map<String, dynamic>> people = [];
  List<Map<String, dynamic>> entities = [];
  List<PlatformFile> files = [];
  Map<String, dynamic>? selectedPerson;
  Map<String, dynamic>? selectedEntity;
  bool loadingPeople = false;
  bool loadingEntities = false;
  bool saving = false;
  String transferType = 'نقل';
  bool isTeacher = false;
  String? error;

  bool get employee => widget.isEmployee;
  static const Map<String, String> transferTypes = {'نقل': '1', 'تنسیب': '2', 'تكليف': '3', 'إكمال نصاب': '4'};

  /// يحوّل استجابات API المختلفة إلى قائمة خرائط بأمان.
  /// بعض نقاط النهاية تعيد List<dynamic> مباشرة، وأخرى تعيدها داخل data/result/items.
  List<Map<String, dynamic>> _extractMapList(dynamic decoded) {
    dynamic current = decoded;
    for (var depth = 0; depth < 5; depth++) {
      if (current is List) {
        final result = <Map<String, dynamic>>[];
        for (final item in current) {
          if (item is Map) {
            final map = <String, dynamic>{};
            item.forEach((key, value) {
              map[key.toString()] = value;
            });
            result.add(map);
          }
        }
        return result;
      }
      if (current is Map) {
        dynamic next;
        var found = false;
        for (final key in const ['data', 'result', 'items', 'results', 'employees', 'students', 'schools', 'entities']) {
          final value = current[key];
          if (value is List || value is Map) {
            next = value;
            found = true;
            break;
          }
        }
        if (found) {
          current = next;
          continue;
        }
      }
      break;
    }
    return <Map<String, dynamic>>[];
  }

  @override
  void initState() { super.initState(); _loadEntities(); _loadPeople(); }
  @override
  void dispose() { _searchController.dispose(); _stageController.dispose(); _endDateController.dispose(); super.dispose(); }

  Future<void> _loadPeople() async {
    setState(() { loadingPeople = true; error = null; });
    try {
      dynamic decoded;
      if (employee) {
        decoded = await _TransferApi.get(widget.token, '/employee/getemployeesbyentities?page=1&rowsPerPage=1000&sortBy=id&sortOrder=desc&entityId=${widget.schoolId}&isTeacher=$isTeacher');
      } else {
        decoded = await _TransferApi.get(widget.token, '/selectoption/getstudentsbyschoolsandstages/${widget.schoolId}/${_stageController.text.trim()}');
      }
      final parsedPeople = _extractMapList(decoded);
      if (mounted) setState(() {
        people = parsedPeople;
        if (selectedPerson != null &&
            !people.any((p) => _personId(p) == _personId(selectedPerson!))) {
          selectedPerson = null;
        }
        loadingPeople = false;
      });
    } catch (e) {
      if (mounted) setState(() { loadingPeople = false; error = 'تعذر تحميل قائمة ${employee ? "الموظفين" : "الطلاب"}: $e'; });
    }
  }

  Future<void> _loadEntities([String query = '']) async {
    setState(() => loadingEntities = true);
    try {
      final path = !employee && query.trim().isNotEmpty
          ? '/school/GetAllSchoolsByStageOrderAndGender/9/1/25/${Uri.encodeComponent(query.trim())}'
          : (query.trim().isEmpty
              ? '/MinistryEntity/GetAllMinistryEntitiesWithSchools${employee ? '' : '/160'}'
              : '/MinistryEntity/SearchAndGetAllMinistryEntitiesWithSchools/${Uri.encodeComponent(query.trim())}');
      final decoded = await _TransferApi.get(widget.token, path);
      final parsedEntities = _extractMapList(decoded);
      if (mounted) setState(() {
        entities = parsedEntities;
        if (selectedEntity != null &&
            !entities.any((e) => _entityId(e) == _entityId(selectedEntity!))) {
          selectedEntity = null;
        }
        loadingEntities = false;
      });
    } catch (e) {
      if (mounted) setState(() { loadingEntities = false; error = 'تعذر تحميل الجهات: $e'; });
    }
  }

  Future<void> _pickFiles() async {
    final result = await FilePicker.platform.pickFiles(allowMultiple: true, withData: true, type: FileType.custom, allowedExtensions: ['pdf', 'jpg', 'jpeg', 'png']);
    if (result != null && mounted) setState(() => files = result.files);
  }

  String _personName(Map<String, dynamic> p) =>
      (p['displayName'] ?? p['fullName'] ?? p['employeeFullName'] ?? p['employeeName'] ?? p['name'] ?? '${p['firstName'] ?? ''} ${p['lastName'] ?? ''}').toString().trim();
  String _personId(Map<String, dynamic> p) => (p['value'] ?? p['id'] ?? p['employeeId'] ?? '').toString();
  String _entityName(Map<String, dynamic> e) => (e['name'] ?? e['displayName'] ?? '').toString();
  String _entityId(Map<String, dynamic> e) => (e['id'] ?? e['value'] ?? '').toString();

  Future<void> _save() async {
    if (selectedPerson == null || selectedEntity == null) {
      setState(() => error = 'يرجى اختيار ${employee ? "الموظف" : "الطالب"} والجهة المستقبلة');
      return;
    }
    if (employee && _endDateController.text.trim().isEmpty && transferType != 'نقل') {
      setState(() => error = 'يرجى تحديد تاريخ انتهاء العملية');
      return;
    }
    setState(() { saving = true; error = null; });
    try {
      final fields = <String, String>{
        'fromEntityId': widget.schoolId,
        'toEntityId': _entityId(selectedEntity!),
      };
      if (employee) {
        fields['employeeId'] = _personId(selectedPerson!);
        fields['transferType'] = transferTypes[transferType]!;
        if (_endDateController.text.trim().isNotEmpty) fields['endDate'] = _endDateController.text.trim();
      } else {
        fields['studentIds'] = _personId(selectedPerson!);
      }
      final endpoint = employee ? 'employeeTransfer/addemployeetransfer' : 'studentTransfer/addstudenttransfer';
      await _TransferApi.postMultipart(widget.token, '/$endpoint?entityId=${widget.schoolId}', fields, files);
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() { saving = false; error = 'فشل إرسال طلب النقل: $e'; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final filteredPeople = people.where((p) => _personName(p).contains(_searchController.text)).take(100).toList();
    return Directionality(
      textDirection: TextDirection.rtl,
      child: AlertDialog(
        title: Text(employee ? 'إضافة عملية نقل موظف' : 'إضافة طلب نقل طالب'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (!employee) ...[
              TextField(controller: _stageController, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: 'معرّف المرحلة الدراسية', helperText: 'القيمة 1159 مأخوذة من طلب HAR المسجل ويمكن تغييرها حسب المرحلة')),
              Align(alignment: Alignment.centerLeft, child: TextButton.icon(onPressed: loadingPeople ? null : _loadPeople, icon: const Icon(Icons.refresh), label: const Text('تحميل الطلاب للمرحلة'))),
            ],
            if (employee) ...[
              DropdownButtonFormField<bool>(
                value: isTeacher,
                decoration: const InputDecoration(labelText: 'فئة المنقول'),
                items: const [
                  DropdownMenuItem(value: false, child: Text('موظف')),
                  DropdownMenuItem(value: true, child: Text('مدرس / معلم')),
                ],
                onChanged: (v) {
                  setState(() { isTeacher = v ?? false; selectedPerson = null; });
                  _loadPeople();
                },
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
              value: transferType,
              decoration: const InputDecoration(labelText: 'نوع العملية'),
              items: transferTypes.keys.map((e) => DropdownMenuItem(value: e, child: Text(e))).toList(),
              onChanged: (v) => setState(() => transferType = v ?? 'نقل'),
            ),
            ],
            if (employee && transferType != 'نقل') TextField(
              controller: _endDateController,
              readOnly: true,
              decoration: const InputDecoration(labelText: 'تاريخ الانتهاء', hintText: 'yyyy-mm-dd', suffixIcon: Icon(Icons.calendar_month)),
              onTap: () async {
                final now = DateTime.now();
                final date = await showDatePicker(context: context, initialDate: now, firstDate: DateTime(now.year - 1), lastDate: DateTime(now.year + 10));
                if (date != null) _endDateController.text = '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
              },
            ),
            const SizedBox(height: 10),
            TextField(controller: _searchController, decoration: InputDecoration(labelText: employee ? 'بحث عن الموظف' : 'بحث عن الطالب', prefixIcon: const Icon(Icons.search)), onChanged: (_) => setState(() {})),
            if (loadingPeople) const LinearProgressIndicator(),
            DropdownButtonFormField<Map<String, dynamic>>(
              isExpanded: true,
              value: selectedPerson,
              decoration: InputDecoration(labelText: employee ? 'الموظف / المدرس' : 'الطالب'),
              items: filteredPeople.map((p) => DropdownMenuItem(value: p, child: Text(_personName(p), overflow: TextOverflow.ellipsis))).toList(),
              onChanged: (v) => setState(() => selectedPerson = v),
            ),
            const SizedBox(height: 12),
            TextField(
              decoration: const InputDecoration(labelText: 'البحث عن الجهة المستقبلة', prefixIcon: Icon(Icons.search)),
              onChanged: (v) { _loadEntities(v); },
            ),
            if (loadingEntities) const LinearProgressIndicator(),
            DropdownButtonFormField<Map<String, dynamic>>(
              isExpanded: true,
              value: selectedEntity,
              decoration: const InputDecoration(labelText: 'الجهة / المدرسة المستقبلة'),
              items: entities.map((e) => DropdownMenuItem(value: e, child: Text(_entityName(e), overflow: TextOverflow.ellipsis))).toList(),
              onChanged: (v) => setState(() => selectedEntity = v),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(onPressed: _pickFiles, icon: const Icon(Icons.attach_file), label: Text(files.isEmpty ? 'إرفاق ملفات PDF أو صور' : 'المرفقات: ${files.length}')),
            if (files.isNotEmpty) ...files.map((f) => Text('• ${f.name}', style: Theme.of(context).textTheme.bodySmall)),
            if (error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(error!, style: const TextStyle(color: Colors.red))),
          ])),
        ),
        actions: [
          TextButton(onPressed: saving ? null : () => Navigator.pop(context, false), child: const Text('إغلاق')),
          FilledButton.icon(onPressed: saving ? null : _save, icon: saving ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.send), label: Text(saving ? 'جارٍ الإرسال...' : 'إرسال طلب النقل')),
        ],
      ),
    );
  }
}
