import 'ai_command_parser.dart';

/// موجه الأوامر المحسّن للربط بين محرك الذكاء الاصطناعي وشاشات تطبيق EMIS
class AiActionDispatcher {
  Future<String> Function(AiCommand command)? onCommand;

  Future<String> dispatch(AiCommand command) async {
    final handler = onCommand;
    if (handler == null) {
      // تنفيذ سلوك افتراضي مبني على نوع النية (Intent) في حال عدم توفر الموجه الخارجي
      switch (command.intent) {
        case AiIntent.openStudents:
          return 'جاري الانتقال إلى إدارة الطلاب...';
        case AiIntent.openTeachers:
          return 'جاري الانتقال إلى إدارة المعلمين...';
        case AiIntent.openAttendance:
          return 'جاري الانتقال إلى تسجيل الغيابات...';
        case AiIntent.openGrades:
          return 'جاري الانتقال إلى قسم الدرجات...';
        case AiIntent.addStudent:
          return 'تم فتح نموذج إضافة طالب جديد. يجری ملء البيانات المستخرجة.';
        case AiIntent.addTeacher:
          return 'تم فتح نموذج إضافة معلم جديد.';
        case AiIntent.unknown:
          return 'عذراً، لم أتمكن من مطابقة هذا الأمر مع وظائف التطبيق.';
      }
    }
    return handler(command);
  }
}
