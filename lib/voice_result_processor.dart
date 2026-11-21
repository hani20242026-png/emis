import 'app_core.dart';

/// المركز الموحد لمعالجة النتائج الصوتية باستخدام خوارزميات Google للهجة العراقية
class VoiceResultProcessor {
  const VoiceResultProcessor._();

  /// المعالجة الذكية للأرقام المنطوقة باللهجة العراقية أو الفصحى مع فحص كافة البدائل الصوتية (N-Best Alternates)
  static String resolveNumeric({
    required Iterable<String> segmentCandidates,
    required Iterable<String> fullCandidates,
    required String accumulated,
    String? fieldKey,
    bool allowGradeMarks = false,
    bool preferSingleNumber = false,
  }) {
    final targetLen = fieldKey != null ? AppCore.targetDigitsLengthForField(fieldKey) : null;

    final segmentList = segmentCandidates
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
    final fullList = fullCandidates
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList(growable: false);

    final segment = AppCore.extractBestSpokenNumber(
      segmentList,
      allowGradeMarks: allowGradeMarks,
      preferSingleNumber: preferSingleNumber,
      targetLength: targetLen,
    );
    final full = AppCore.extractBestSpokenNumber(
      fullList,
      allowGradeMarks: allowGradeMarks,
      preferSingleNumber: preferSingleNumber,
      targetLength: targetLen,
    );

    if (preferSingleNumber ||
        (allowGradeMarks && (segment == 'م' || segment == 'غ' || full == 'م' || full == 'غ'))) {
      if (allowGradeMarks && (segment == 'م' || segment == 'غ')) return segment;
      if (allowGradeMarks && (full == 'م' || full == 'غ')) return full;
      return segment.isNotEmpty ? segment : full;
    }

    final mergedSegment = AppCore.mergeAccumulatedDigits(accumulated, segment);
    if (full.isEmpty) return mergedSegment;

    // `full` is the recognizer's current full hypothesis, not automatically a
    // new segment. Never concatenate it to the previous hypothesis merely
    // because a partial result changed its wording/digits.
    if (accumulated.isEmpty) {
      if (targetLen != null && full.length == targetLen) return full;
      return full.length >= mergedSegment.length ? full : mergedSegment;
    }

    if (full == accumulated) return accumulated;

    // Google often revises an earlier partial transcript. If the new full
    // hypothesis extends the old one, it replaces it as a whole.
    if (full.startsWith(accumulated)) {
      if (targetLen != null && full.length > targetLen &&
          mergedSegment.length == targetLen) {
        return mergedSegment;
      }
      return full.length >= mergedSegment.length ? full : mergedSegment;
    }

    // A shorter full hypothesis may be a stale/repeated partial. Keep the
    // accumulated value unless the segment itself provides a genuine extension.
    if (accumulated.startsWith(full)) {
      if (mergedSegment.length > accumulated.length) return mergedSegment;
      return accumulated;
    }

    // Critical duplicate guard: do not merge an unrelated full hypothesis
    // with accumulated digits. Prefer the best current full result, especially
    // when Google corrected a digit sequence.
    if (targetLen != null) {
      if (full.length == targetLen) return full;
      if (mergedSegment.length == targetLen) return mergedSegment;
    }

    if (full.length >= accumulated.length) return full;
    if (mergedSegment.length > accumulated.length) return mergedSegment;
    return accumulated;
  }

  static bool shouldAutoStopForField(String fieldKey, String currentDigits) {
    if (!AppCore.voiceAutoStopOnTargetLength) return false;
    final target = AppCore.targetDigitsLengthForField(fieldKey);
    if (target == null) return false;
    final clean = AppCore.normalizeDigitsOnly(currentDigits).replaceAll(RegExp(r'[^\d]'), '');
    return clean.length >= target;
  }

  /// المعالجة الذكية للكلمات والأسماء العراقية مع اختيار البديل الأنقى من مرشحات Google
  static String resolveText({
    required Iterable<String> segmentCandidates,
    required Iterable<String> fullCandidates,
    required String accumulated,
  }) {
    String normalize(String value) {
      final normalized = AppCore.normalizeIraqiSpokenText(value);
      // Speech recognizers sometimes emit a digit sequence as separated
      // tokens ("1 2 3 4 5"). Join only whitespace between digits; preserve
      // normal word spacing and Arabic text.
      return normalized.replaceAll(
        RegExp(r'(?<=[0-9٠-٩۰-۹])\s+(?=[0-9٠-٩۰-۹])'),
        '',
      );
    }

    final fullList = fullCandidates
        .map(normalize)
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
    final segList = segmentCandidates
        .map(normalize)
        .where((e) => e.isNotEmpty)
        .toList(growable: false);

    final bestFull = fullList.isNotEmpty ? fullList.first : '';
    final bestSeg = segList.isNotEmpty ? segList.first : '';
    final acc = normalize(accumulated);

    if (acc.isEmpty) return bestFull.isNotEmpty ? bestFull : bestSeg;
    if (bestFull.isEmpty && bestSeg.isEmpty) return acc;

    if (bestFull.isNotEmpty) {
      if (bestFull == acc || acc.startsWith('$bestFull ')) {
        if (bestSeg.isEmpty ||
            bestSeg == acc ||
            acc.endsWith(' $bestSeg') ||
            bestSeg.startsWith('$acc ')) {
          return acc;
        }
      }
      if (bestFull.startsWith('$acc ') || bestFull.startsWith(acc)) {
        return bestFull;
      }

      final oldWords = acc.split(RegExp(r'\s+'));
      final fullWords = bestFull.split(RegExp(r'\s+'));
      var commonPrefix = 0;
      while (commonPrefix < oldWords.length &&
          commonPrefix < fullWords.length &&
          oldWords[commonPrefix] == fullWords[commonPrefix]) {
        commonPrefix++;
      }
      final minLength =
          oldWords.length < fullWords.length ? oldWords.length : fullWords.length;
      if (minLength > 0 &&
          commonPrefix >= (minLength > 1 ? minLength - 1 : 1) &&
          fullWords.length >= oldWords.length) {
        return bestFull;
      }
    }

    final incoming = bestSeg.isNotEmpty ? bestSeg : bestFull;
    if (incoming.isEmpty) return acc;
    if (incoming == acc || acc.endsWith(' $incoming')) return acc;
    if (incoming.startsWith('$acc ') || incoming.startsWith(acc)) return incoming;

    final oldWords = acc.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    final newWords = incoming.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    final maxOverlap =
        oldWords.length < newWords.length ? oldWords.length : newWords.length;
    for (int overlap = maxOverlap; overlap >= 1; overlap--) {
      final tail = oldWords.sublist(oldWords.length - overlap).join(' ');
      final head = newWords.sublist(0, overlap).join(' ');
      if (tail == head) {
        return [...oldWords, ...newWords.sublist(overlap)].join(' ');
      }
    }

    if (bestFull.isNotEmpty &&
        bestFull.split(RegExp(r'\s+')).length > newWords.length) {
      return bestFull;
    }
    return '$acc $incoming';
  }

  static String? resolveSpokenDate(String raw, {String? fieldKey}) {
    final value = AppCore.normalizeDigitsOnly(raw.trim())
        .replaceAll('／', '/')
        .replaceAll('٫', '.');
    if (value.isEmpty) return null;

    DateTime? validate(int year, int month, int day) {
      if (year < 100) year += year >= 50 ? 1900 : 2000;
      if (month > 12 && month <= 31 && day >= 1 && day <= 12) {
        final tmp = month;
        month = day;
        day = tmp;
      }
      if (year < 1900 || year > DateTime.now().year + 1 || month < 1 || month > 12 || day < 1 || day > 31) {
        return null;
      }
      final date = DateTime(year, month, day);
      if (date.year != year || date.month != month || date.day != day) return null;
      if (fieldKey == 'dateOfBirth' && date.isAfter(DateTime.now())) return null;
      return date;
    }

    String format(DateTime d) =>
        '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

    var m = RegExp(r'^(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})$').firstMatch(value);
    if (m != null) {
      final d = validate(int.parse(m.group(1)!), int.parse(m.group(2)!), int.parse(m.group(3)!));
      if (d != null) return format(d);
    }

    m = RegExp(r'^(\d{1,2})[-/.](\d{1,2})[-/.](\d{4})$').firstMatch(value);
    if (m != null) {
      final d = validate(int.parse(m.group(3)!), int.parse(m.group(2)!), int.parse(m.group(1)!));
      if (d != null) return format(d);
    }

    final digits = AppCore.extractSpokenDigits(raw);
    final digitGroups = RegExp(r'\d+')
        .allMatches(digits)
        .map((match) => int.tryParse(match.group(0)!))
        .whereType<int>()
        .toList();

    if (digitGroups.length >= 3) {
      final d = digitGroups[0] >= 1900
          ? validate(digitGroups[0], digitGroups[1], digitGroups[2])
          : validate(digitGroups[2], digitGroups[1], digitGroups[0]);
      if (d != null) return format(d);
    }

    final compactDigits = digits.replaceAll(RegExp(r'[^\d]'), '');
    if (compactDigits.length == 8) {
      final first4 = int.tryParse(compactDigits.substring(0, 4)) ?? 0;
      if (first4 >= 1900 && first4 <= 2100) {
        final d = validate(
          first4,
          int.tryParse(compactDigits.substring(4, 6)) ?? 0,
          int.tryParse(compactDigits.substring(6, 8)) ?? 0,
        );
        if (d != null) return format(d);
      } else {
        final d = validate(
          int.tryParse(compactDigits.substring(4, 8)) ?? 0,
          int.tryParse(compactDigits.substring(2, 4)) ?? 0,
          int.tryParse(compactDigits.substring(0, 2)) ?? 0,
        );
        if (d != null) return format(d);
      }
    }

    final cleaned = raw
        .replaceAll(RegExp(r'[,،;؛/\\|]+'), ' ')
        .replaceAll('-', ' ')
        .replaceAll('ـ', ' ')
        .trim();
    final words = cleaned.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    if (words.length >= 3) {
      final day = int.tryParse(AppCore.extractSpokenDigits(words[0]));
      final month = int.tryParse(AppCore.extractSpokenDigits(words[1]));
      final year = int.tryParse(AppCore.extractSpokenDigits(words.sublist(2).join(' ')));
      if (day != null && month != null && year != null) {
        final d = validate(year, month, day);
        if (d != null) return format(d);
      }
    }

    return null;
  }
}
