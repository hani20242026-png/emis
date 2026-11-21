import 'ai_command_parser.dart';

class AiResponseService {
  String responseFor(AiCommand command) {
    switch (command.intent) {
      case AiIntent.openStudents: return 'سأفتح قسم إدارة الطلاب.';
      case AiIntent.openTeachers: return 'سأفتح قسم إدارة المعلمين.';
      case AiIntent.openAttendance: return 'سأفتح قسم تسجيل الغيابات.';
      case AiIntent.openGrades: return 'سأفتح قسم الدرجات.';
      case AiIntent.addStudent: return 'فهمت أنك تريد إضافة طالب. سأفتح إدارة الطلاب؛ راجع البيانات وأكمل الحفظ من النموذج.';
      case AiIntent.addTeacher: return 'فهمت أنك تريد إضافة معلم. سأفتح إدارة المعلمين؛ راجع البيانات وأكمل الحفظ من النموذج.';
      case AiIntent.unknown: return 'لم أفهم الأمر بدقة. جرّب: افتح الطلاب، افتح المعلمين، افتح الغيابات، أو افتح الدرجات.';
    }
  }
}
