import 'dart:convert';

/// Parses the authoritative employment-status catalog returned by EMIS.
///
/// EMIS has used several response envelopes over time. Search the complete
/// JSON tree for the employment-status catalog instead of assuming it is a
/// top-level property. Never substitute a bundled list for a successful
/// server catalog.
class EmisEmploymentStatusOptions {
  static String _norm(String value) => value
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]'), '');

  static dynamic _decodeIfJson(dynamic value) {
    if (value is String) {
      final text = value.trim();
      if (text.startsWith('[') || text.startsWith('{')) {
        try { return jsonDecode(text); } catch (_) {}
      }
    }
    return value;
  }

  static dynamic _unwrap(dynamic value) {
    value = _decodeIfJson(value);
    for (var i = 0; i < 8; i++) {
      if (value is! Map) break;
      final map = <String, dynamic>{
        for (final e in value.entries) _norm(e.key.toString()): e.value,
      };
      dynamic next;
      for (final key in const ['data', 'items', 'options', 'values', 'result', 'payload']) {
        if (map[key] is List || map[key] is Map || map[key] is String) {
          next = map[key];
          break;
        }
      }
      if (next == null || identical(next, value)) break;
      value = _decodeIfJson(next);
    }
    return value;
  }

  static List<Map<String, dynamic>> _parse(dynamic raw) {
    raw = _unwrap(raw);
    if (raw is Map) {
      final normalizedKeys = raw.keys.map((key) => _norm(key.toString())).toSet();
      if (normalizedKeys.any((key) => const [
        'value', 'id', 'code', 'statustype', 'statusvalue', 'displayname',
        'displaynamear', 'label', 'name', 'namear', 'statusname', 'statusnamear'
      ].contains(key))) {
        raw = <dynamic>[raw];
      } else {
        final entries = <Map<String, dynamic>>[];
        for (final entry in raw.entries) {
          final key = entry.key.toString().trim();
          final val = entry.value;
          if (key.isEmpty || val == null) continue;
          if (val is Map) {
            final parsed = _parse([val]);
            if (parsed.isNotEmpty) {
              entries.addAll(parsed);
            } else {
              entries.add({'value': key, 'displayName': key});
            }
          } else if (val is List) {
            entries.addAll(_parse(val));
          } else {
            final label = val.toString().trim();
            if (label.isNotEmpty) entries.add({'value': key, 'displayName': label});
          }
        }
        raw = entries;
      }
    }
    if (raw is! List) return <Map<String, dynamic>>[];

    final output = <Map<String, dynamic>>[];
    final seen = <String>{};
    for (final item in raw) {
      dynamic value;
      dynamic label;
      if (item is Map) {
        final m = <String, dynamic>{
          for (final e in item.entries) _norm(e.key.toString()): e.value,
        };
        value = m['value'] ?? m['id'] ?? m['code'] ?? m['statustype'] ??
            m['statusvalue'] ?? m['key'] ?? m['name'] ?? m['namear'] ??
            m['displayname'] ?? m['displaynamear'] ?? m['label'] ?? m['text'] ??
            m['statusname'] ?? m['statusnamear'] ?? m['shortname'];
        label = m['displayname'] ?? m['displaynamear'] ?? m['label'] ??
            m['statusname'] ?? m['statusnamear'] ?? m['name'] ?? m['namear'] ??
            m['text'] ?? m['description'] ?? m['title'] ?? m['statustype'] ??
            m['status'] ?? value;
      } else {
        value = item;
        label = item;
      }
      final v = value?.toString().trim() ?? '';
      final title = label?.toString().trim() ?? '';
      if (v.isEmpty || title.isEmpty || v == 'null' || title == 'null') continue;
      if (!seen.add(v)) continue;
      output.add({'value': value, 'displayName': title});
    }
    return output;
  }

  static dynamic _findCatalog(dynamic node, {int depth = 0}) {
    if (depth > 14) return null;
    node = _decodeIfJson(node);
    if (node is Map) {
      final normalized = <String, dynamic>{
        for (final e in node.entries) _norm(e.key.toString()): e.value,
      };
      const preferred = [
        'currentemploymentstatus',
        'currentemploymentstatuses',
        'currentemploymentstatusoptions',
        'employmentstatus',
        'employmentstatuses',
        'employmentstatusoptions',
      ];
      for (final key in preferred) {
        final value = normalized[key];
        if (value is List || value is Map || value is String) return value;
      }
      // Some releases append a suffix/prefix to the catalog property name.
      for (final entry in node.entries) {
        final key = _norm(entry.key.toString());
        if (key.contains('employment') && key.contains('status') &&
            (entry.value is List || entry.value is Map || entry.value is String)) {
          return entry.value;
        }
      }
      for (final value in node.values) {
        final found = _findCatalog(value, depth: depth + 1);
        if (found != null) return found;
      }
    } else if (node is List) {
      for (final value in node) {
        final found = _findCatalog(value, depth: depth + 1);
        if (found != null) return found;
      }
    }
    return null;
  }

  static List<Map<String, dynamic>>? extract(dynamic root) {
    final catalog = _findCatalog(root);
    if (catalog == null) return null;
    return _parse(catalog);
  }
}
