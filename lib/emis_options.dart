import 'package:flutter/foundation.dart';

/// أدوات موحّدة لقراءة قوائم EMIS (REST + جسر WebView) مع الحفاظ على
/// **القيمة الحقيقية** للخيار (value) منفصلة عن **النص المعروض** (displayName).
///
/// القواعد المعتمدة:
/// 1) استجابة REST من EMIS هي المرجع الأول للقيمة الحقيقية.
/// 2) الخيار الملتقط من مكوّن Vue (`_src == 'vue'`) قيمته حقيقية فيستبدل أي قيمة قديمة.
/// 3) الخيار الملتقط من DOM (`_src == 'dom'`) قيمته = نصه فقط، فلا يستبدل أبداً
///    قيمة حقيقية موجودة، ويُضاف فقط إذا لم يكن له نظير.
/// 4) القائمة الملتقطة "كاملة" (`_complete == true`) تحدّد العضوية (حذف ما زال من EMIS)
///    مع الإبقاء على القيم الحقيقية للعناصر المتطابقة.
class EmisOptions {
  EmisOptions._();

  static const List<String> defaultValueKeys = <String>[
    'value',
    'id',
    'code',
    'shortName',
    'key',
  ];

  static const List<String> defaultLabelKeys = <String>[
    'displayName',
    'label',
    'name',
    'text',
    'title',
    'description',
  ];

  /// مفاتيح getemployeesoptions → مفاتيح حقول التطبيق (أسماء مطابقة فقط، بلا تخمين).
  static const Map<String, List<String>> catalogKeys = <String, List<String>>{
    'classification': <String>['classification', 'classifications'],
    'employeeCategory': <String>['employeecategory', 'employeecategories'],
    'employmentType': <String>['employmenttype', 'employmenttypes'],
    'employmentGrade': <String>['employmentgrade', 'employmentgrades'],
    'currentPosition': <String>['currentposition', 'currentpositions'],
    'positionType': <String>[
      'positiontype',
      'positiontypes',
      'currentemploymentposition',
    ],
    'educationLevel': <String>['educationlevel', 'educationlevels'],
    'specialization': <String>['specialization', 'specializations'],
  };

  /// مفتاح مقارنة عربي موحّد: بلا تشكيل/تطويل، همزات، تاء مربوطة، ياء، مسافات.
  static String norm(Object? input) {
    var s = '${input ?? ''}';
    s = s
        .replaceAll(RegExp(r'[\u064B-\u065F\u0670\u0640]'), '')
        .replaceAll(RegExp(r'[\u0623\u0625\u0622\u0671]'), '\u0627')
        .replaceAll('\u0629', '\u0647')
        .replaceAll(RegExp(r'[\u0649\u06CC\u06D0]'), '\u064A')
        .replaceAll('\u06A9', '\u0643')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim()
        .toLowerCase();
    return s;
  }

  static String _key(Object? k) =>
      '$k'.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

  static dynamic _pick(Map<dynamic, dynamic> m, List<String> keys) {
    final lower = <String, dynamic>{
      for (final e in m.entries) _key(e.key): e.value,
    };
    for (final k in keys) {
      final v = lower[_key(k)];
      if (v != null && '$v'.trim().isNotEmpty && '$v' != 'null') return v;
    }
    return null;
  }

  /// يفتح أغلفة data/items/results/options/values حتى يصل إلى القائمة.
  static dynamic unwrap(dynamic raw) {
    for (var i = 0; i < 4; i++) {
      if (raw is! Map) break;
      final lower = <String, dynamic>{
        for (final e in raw.entries) _key(e.key): e.value,
      };
      dynamic next;
      for (final k in const ['data', 'items', 'results', 'options', 'values']) {
        if (lower[k] is List) {
          next = lower[k];
          break;
        }
      }
      if (next == null) {
        for (final k in const ['data', 'items', 'results', 'options', 'values']) {
          if (lower[k] is Map) {
            next = lower[k];
            break;
          }
        }
      }
      if (next == null) break;
      raw = next;
    }
    return raw;
  }

  /// يحوّل أي استجابة قائمة من EMIS إلى {value, displayName} مع الإبقاء على
  /// بقية حقول العنصر الأصلية. القيمة تحتفظ بنوعها الأصلي (رقم/نص).
  static List<Map<String, dynamic>> parseList(
    dynamic raw, {
    List<String> valueKeys = defaultValueKeys,
    List<String> labelKeys = defaultLabelKeys,
  }) {
    raw = unwrap(raw);
    if (raw is! List) return <Map<String, dynamic>>[];
    final out = <Map<String, dynamic>>[];
    final seen = <String>{};
    for (final item in raw) {
      dynamic value;
      dynamic label;
      Map<String, dynamic>? extra;
      if (item is Map) {
        value = _pick(item, valueKeys) ?? _pick(item, labelKeys);
        label = _pick(item, labelKeys) ?? value;
        extra = <String, dynamic>{
          for (final e in item.entries) '${e.key}': e.value,
        };
      } else if (item != null) {
        value = item;
        label = item;
      }
      final v = '${value ?? ''}'.trim();
      final l = '${label ?? ''}'.trim();
      if (v.isEmpty || l.isEmpty || v == 'null' || !seen.add(v)) continue;
      out.add(<String, dynamic>{
        ...?extra,
        'value': value,
        'displayName': l,
      });
    }
    return out;
  }

  static List<Map<String, dynamic>> _copy(List<dynamic> list) => <Map<String, dynamic>>[
        for (final e in list)
          if (e is Map) <String, dynamic>{for (final x in e.entries) '${x.key}': x.value},
      ];

  /// يدمج خيارات التقطها جسر WebView من صفحة EMIS الحية مع القائمة الحالية
  /// دون إفساد القيم الحقيقية (انظر القواعد في أعلى الملف).
  static List<Map<String, dynamic>> mergeLive(
    List<dynamic> existing,
    List<dynamic> incoming,
  ) {
    final live = <Map<String, dynamic>>[];
    final seenLive = <String>{};
    for (final raw in incoming) {
      if (raw is! Map) continue;
      final value = raw['value'] ?? raw['id'] ?? raw['displayName'] ?? raw['label'];
      final label = raw['displayName'] ?? raw['label'] ?? raw['text'] ?? value;
      final v = '${value ?? ''}'.trim();
      final l = '${label ?? ''}'.trim();
      if (v.isEmpty || l.isEmpty || !seenLive.add('$v|$l')) continue;
      live.add(<String, dynamic>{
        'value': value,
        'displayName': l,
        '_src': '${raw['_src'] ?? 'dom'}',
        '_complete': raw['_complete'] == true,
      });
    }
    final current = _copy(existing);
    if (live.isEmpty) return current;

    final complete = live.every((o) => o['_complete'] == true);
    final out = <Map<String, dynamic>>[];
    final used = <int>{};
    for (final l in live) {
      final label = norm(l['displayName']);
      final lv = '${l['value']}'.trim();
      final real = l['_src'] == 'vue' || l['_src'] == 'attr';
      var idx = current.indexWhere(
        (o) => norm(o['displayName'] ?? o['label'] ?? o['name']) == label,
      );
      if (idx < 0) {
        idx = current.indexWhere(
          (o) => '${o['value'] ?? o['id'] ?? ''}'.trim() == lv,
        );
      }
      if (idx >= 0 && !used.contains(idx)) {
        final base = Map<String, dynamic>.from(current[idx]);
        if (real) base['value'] = l['value'];
        base['displayName'] = l['displayName'];
        base['_src'] = real ? l['_src'] : (base['_src'] ?? 'server');
        out.add(base);
        used.add(idx);
      } else if (idx < 0) {
        out.add(l);
      }
    }
    if (!complete) {
      for (var i = 0; i < current.length; i++) {
        if (!used.contains(i)) out.add(current[i]);
      }
    }
    return out;
  }

  /// يستخرج كل قوائم getemployeesoptions المعروفة (وبقية المفاتيح تُطبع للتشخيص).
  static Map<String, List<Map<String, dynamic>>> extractCatalog(dynamic root) {
    final out = <String, List<Map<String, dynamic>>>{};
    if (root is! Map) return out;
    final source = <String, dynamic>{
      for (final e in root.entries) _key(e.key): e.value,
    };
    debugPrint(
      'EMIS getemployeesoptions keys: ${root.keys.map((k) => '$k(${root[k] is List ? (root[k] as List).length : root[k].runtimeType})').join(', ')}',
    );
    catalogKeys.forEach((field, names) {
      for (final n in names) {
        if (!source.containsKey(n)) continue;
        final parsed = parseList(source[n]);
        if (parsed.isNotEmpty) {
          out[field] = parsed;
          break;
        }
      }
    });
    for (final wrapper in const ['data', 'result', 'options', 'payload']) {
      final nested = source[wrapper];
      if (nested is Map) {
        extractCatalog(nested).forEach((k, v) => out.putIfAbsent(k, () => v));
      }
    }
    return out;
  }
}
