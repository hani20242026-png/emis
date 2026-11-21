/// Lightweight, deterministic checks for values extracted by the EMIS assistant.
/// This class never changes values and never decides whether a form may be saved.
class AiDraftIssue {
  final String field;
  final String message;
  const AiDraftIssue(this.field, this.message);
}

class AiDraftValidator {
  static const Map<String, String> _labels = {
    'name': 'الاسم الأول',
    'fatherName': 'اسم الأب',
    'grandFatherName': 'اسم الجد',
    'dateOfBirth': 'تاريخ الميلاد',
    'issuingDate': 'تاريخ الإصدار',
    'dateOfStartWorking': 'تاريخ المباشرة',
    'statusDate': 'تاريخ الحالة',
    'homePhoneNumber': 'رقم الهاتف',
    'mobilePhoneNumber': 'رقم الهاتف المحمول',
    'emergencyContactPhoneNumber': 'هاتف الطوارئ',
    'nationalId': 'رقم البطاقة الوطنية',
    'employeeIdNumber': 'الرقم الوظيفي',
    'email': 'البريد الإلكتروني',
  };

  static List<AiDraftIssue> validate(Map<String, String> values) {
    final issues = <AiDraftIssue>[];
    for (final key in const ['dateOfBirth', 'issuingDate', 'dateOfStartWorking', 'statusDate']) {
      final value = values[key]?.trim();
      if (value == null || value.isEmpty) continue;
      if (!_validIsoDate(value)) {
        issues.add(AiDraftIssue(key, '${_labels[key]} يجب أن يكون تاريخاً صحيحاً بصيغة yyyy-mm-dd'));
      }
    }

    for (final key in const ['homePhoneNumber', 'mobilePhoneNumber', 'emergencyContactPhoneNumber']) {
      final value = values[key]?.replaceAll(RegExp(r'[^0-9+]'), '');
      if (value == null || value.isEmpty) continue;
      final digits = value.replaceAll('+', '');
      if (digits.length < 10 || digits.length > 13) {
        issues.add(AiDraftIssue(key, '${_labels[key]} يبدو غير مكتمل؛ راجع عدد الأرقام'));
      }
    }

    final nationalId = values['nationalId']?.replaceAll(RegExp(r'\s+'), '');
    if (nationalId != null && nationalId.isNotEmpty &&
        (!RegExp(r'^\d{8,20}$').hasMatch(nationalId))) {
      issues.add(const AiDraftIssue('nationalId', 'رقم البطاقة الوطنية يجب أن يحتوي على أرقام فقط (8 إلى 20 رقماً)'));
    }

    final employeeId = values['employeeIdNumber']?.trim();
    if (employeeId != null && employeeId.isNotEmpty && !RegExp(r'^[0-9]+$').hasMatch(employeeId)) {
      issues.add(const AiDraftIssue('employeeIdNumber', 'الرقم الوظيفي يحتوي على محارف غير رقمية؛ راجعه'));
    }

    final email = values['email']?.trim();
    if (email != null && email.isNotEmpty &&
        !RegExp(r'^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$', caseSensitive: false).hasMatch(email)) {
      issues.add(const AiDraftIssue('email', 'صيغة البريد الإلكتروني غير صحيحة'));
    }
    return List.unmodifiable(issues);
  }

  static bool _validIsoDate(String value) {
    final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(value);
    if (match == null) return false;
    final year = int.tryParse(match.group(1)!);
    final month = int.tryParse(match.group(2)!);
    final day = int.tryParse(match.group(3)!);
    if (year == null || month == null || day == null) return false;
    final date = DateTime(year, month, day);
    return date.year == year && date.month == month && date.day == day;
  }

  /// Produces a short user-facing warning; an empty result means no detected issue.
  static String warningText(Map<String, String> values) {
    final issues = validate(values);
    if (issues.isEmpty) return '';
    final lines = issues.take(4).map((issue) => '• ${issue.message}').join('\n');
    final remaining = issues.length - 4;
    return 'قبل اعتماد المسودة، راجع هذه الملاحظات:\n$lines${remaining > 0 ? '\n• وملاحظات أخرى ($remaining)' : ''}';
  }
}
