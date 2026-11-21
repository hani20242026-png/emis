import 'package:flutter_test/flutter_test.dart';
import 'package:iraq_emis/ai_assistant/ai_command_parser.dart';

void main() {
  group('AiCommandParser - Iraqi speech', () {
    test('extracts a complete student draft from Iraqi spoken numbers', () {
      const utterance = 'ضيف طالب جديد اسمه علي جاسم عيسى جابر الفتلاوي وامه نادره جبار شريده '
          'مواليده اثمنطعش تلاثة الفين واربعطعش مسقط راسه الديوانية '
          'رقم الموحدة واحد اثنين ثلاثة أربعة خمسة ستة سبعة ثمانية تسعة صفر واحد اثنين '
          'رقم الهاتف صفر سبعة ثمانية واحد اثنين ثلاثة أربعة خمسة ستة سبعة ثمانية '
          'عنوانه الديوانية حي الجمهوري محله مية وستة زقاق اربعة وثمانين دار اثنعش '
          'وخلي بالصف الأول شعبة باء';
      final command = AiCommandParser.parse(utterance);
      expect(command.intent, AiIntent.addStudent);
      expect(command.entities['name'], 'علي');
      expect(command.entities['fatherName'], 'جاسم');
      expect(command.entities['grandFatherName'], 'عيسى');
      expect(command.entities['fathersGrandFatherName'], 'جابر');
      expect(command.entities['surName'], 'الفتلاوي');
      expect(command.entities['motherName'], 'نادره');
      expect(command.entities['mothersFatherName'], 'جبار');
      expect(command.entities['mothersGrandFatherName'], 'شريده');
      expect(command.entities['dateOfBirth'], '2014-03-18');
      expect(command.entities['homeTown'], 'الديوانية');
      expect(command.entities['nationalId'], '123456789012');
      expect(command.entities['homePhoneNumber'], '07812345678');
      expect(command.entities['town'], 'الديوانية');
      expect(command.entities['area'], 'الجمهوري');
      expect(command.entities['quarter'], '106');
      expect(command.entities['street'], '84');
      expect(command.entities['address1'], '12');
      expect(command.entities['stageId'], 'الأول');
      expect(command.entities['classRoomId'], 'ب');
    });


    test('extracts names and Iraqi short slash date during an active student flow', () {
      final command = AiCommandParser.parse(
        'الطالب جديد اسم علي جاسم عيسى جابر واسم الام نهى كريم سالم تاريخ الميلاد 18/3 2014',
        activeIntent: AiIntent.addStudent,
      );
      expect(command.intent, AiIntent.addStudent);
      expect(command.entities['name'], 'علي');
      expect(command.entities['fatherName'], 'جاسم');
      expect(command.entities['grandFatherName'], 'عيسى');
      expect(command.entities['fathersGrandFatherName'], 'جابر');
      expect(command.entities['motherName'], 'نهى');
      expect(command.entities['mothersFatherName'], 'كريم');
      expect(command.entities['mothersGrandFatherName'], 'سالم');
      expect(command.entities['dateOfBirth'], '2014-03-18');
    });


    test('extracts a student name after the spoken phrase الطالب جديد الطالب', () {
      final command = AiCommandParser.parse(
        'طالب جديد الطالب علي جاسم عيسى جابر واسم الام نهى كريم سالم',
      );
      expect(command.intent, AiIntent.addStudent);
      expect(command.entities['name'], 'علي');
      expect(command.entities['fatherName'], 'جاسم');
      expect(command.entities['grandFatherName'], 'عيسى');
      expect(command.entities['fathersGrandFatherName'], 'جابر');
      expect(command.entities['motherName'], 'نهى');
      expect(command.entities['mothersFatherName'], 'كريم');
      expect(command.entities['mothersGrandFatherName'], 'سالم');
    });

    test('normalizes numeric date and preserves yyyy-mm-dd', () {
      final command = AiCommandParser.parse('إضافة طالب اسمه حسن مواليده 2014-03-18');
      expect(command.entities['dateOfBirth'], '2014-03-18');
    });


    test('extracts a phone-number correction as a partial update', () {
      final command = AiCommandParser.parse(
        'غير رقم هاتفه إلى صفر سبعة ثمانية واحد اثنين ثلاثة أربعة خمسة ستة سبعة ثمانية',
      );
      expect(command.entities['homePhoneNumber'], '07812345678');
    });

    test('extracts a student name correction without requiring a new-add command', () {
      final command = AiCommandParser.parse('غير الاسم إلى محمد كريم جبار');
      expect(command.entities['name'], 'محمد');
      expect(command.entities['fatherName'], 'كريم');
      expect(command.entities['grandFatherName'], 'جبار');
    });

    test('extracts an address correction as an incremental update', () {
      final command = AiCommandParser.parse('غير عنوانه إلى الديوانية حي الجامعة محلة 12 زقاق 4 دار 8');
      expect(command.entities['town'], 'الديوانية');
      expect(command.entities['area'], 'الجامعة');
      expect(command.entities['quarter'], '12');
      expect(command.entities['street'], '4');
      expect(command.entities['address1'], '8');
    });

    test('routes spoken teacher phone to mobile field', () {
      final command = AiCommandParser.parse('إضافة معلم اسمه أحمد رقم الهاتف صفر سبعة ثمانية واحد اثنين ثلاثة أربعة خمسة ستة سبعة ثمانية');
      expect(command.intent, AiIntent.addTeacher);
      expect(command.entities['mobilePhoneNumber'], '07812345678');
      expect(command.entities.containsKey('homePhoneNumber'), isFalse);
    });
    test('extracts teacher work, education and emergency-contact fields', () {
      final command = AiCommandParser.parse(
        'إضافة معلم اسمه أحمد جاسم سالم الرقم الوظيفي 12345 رقم العائلة 678 '
        'البريد ahmad@example.com الجامعة جامعة بغداد التخصص رياضيات '
        'سنة التخرج 2018 العنوان الوظيفي مدرس تاريخ المباشرة 1 9 2020 '
        'اسم جهة الاتصال علي جاسم صلة القرابة أخ رقم هاتف الطوارئ 07812345678',
      );
      expect(command.intent, AiIntent.addTeacher);
      expect(command.entities['employeeIdNumber'], '12345');
      expect(command.entities['familyNumber'], '678');
      expect(command.entities['email'], 'ahmad@example.com');
      expect(command.entities['universityName'], 'جامعة بغداد');
      expect(command.entities['specialization'], 'رياضيات');
      expect(command.entities['graduationYear'], '2018');
      expect(command.entities['jobDesignation'], 'مدرس');
      expect(command.entities['dateOfStartWorking'], '2020-09-01');
      expect(command.entities['emergencyContactName'], 'علي جاسم');
      expect(command.entities['emergencyContactRelationship'], 'أخ');
      expect(command.entities['emergencyContactPhoneNumber'], '07812345678');
    });

    test('extracts long student dictation fields and month-name dates', () {
      final command = AiCommandParser.parse(
        'ضيف طالب جديد اسمه علي جاسم عيسى جابر واسم أمه نهى كريم سالم '
        'مواليده 18 آذار 2014 الجنسية عراقية بلد الولادة العراق '
        'اللغة الأم العربية لغة الدراسة العربية الحالة الاجتماعية أعزب '
        'فصيلة الدم O موجب الديانة الإسلام المستوى المعيشي الطبقة الوسطى '
        'نوع الوثيقة البطاقة الوطنية رقم هوية الأحوال المدنية 12345678 '
        'رقم السجل 45 رقم الصحيفة 8 جهة الإصدار مديرية الجنسية '
        'بلد الإصدار العراق رقم الإحصاء 9911',
      );
      expect(command.entities['dateOfBirth'], '2014-03-18');
      expect(command.entities['motherName'], 'نهى');
      expect(command.entities['mothersFatherName'], 'كريم');
      expect(command.entities['mothersGrandFatherName'], 'سالم');
      expect(command.entities['nationality'], 'عراقية');
      expect(command.entities['countryOfBirth'], 'العراق');
      expect(command.entities['motherTongue'], 'العربية');
      expect(command.entities['studyLanguage'], 'العربية');
      expect(command.entities['maritalStatus'], 'أعزب');
      expect(command.entities['bloodGroup'], 'O موجب');
      expect(command.entities['religion'], 'الإسلام');
      expect(command.entities['economicLevel'], 'الطبقة الوسطى');
      expect(command.entities['nameOfDocument'], 'البطاقة الوطنية');
      expect(command.entities['idNumber'], '12345678');
      expect(command.entities['recordNumber'], '45');
      expect(command.entities['pageNumber'], '8');
      expect(command.entities['issuer'], 'مديرية الجنسية');
      expect(command.entities['issuingCountry'], 'العراق');
      expect(command.entities['censusNumber'], '9911');
    });

    test('does not confuse issuing date with date of birth', () {
      final command = AiCommandParser.parse(
        'إضافة طالب اسمه حسن تاريخ الإصدار 5 4 2022',
      );
      expect(command.entities['issuingDate'], '2022-04-05');
      expect(command.entities.containsKey('dateOfBirth'), isFalse);
    });

    test('maps teacher spoken job title to the actual EMIS positionType field', () {
      final command = AiCommandParser.parse(
        'إضافة معلم اسمه أحمد العنوان الوظيفي مدرس المنصب الحالي معاون مدير',
      );
      expect(command.entities['positionType'], 'مدرس');
      expect(command.entities['currentPosition'], 'معاون مدير');
    });

    test('extracts issuing date and explicit gender without guessing dropdown IDs', () {
      final command = AiCommandParser.parse(
        'إضافة طالب اسمه حسن تاريخ الإصدار 5 4 2022 الجنس ذكر',
      );
      expect(command.entities['issuingDate'], '2022-04-05');
      expect(command.entities['gender'], 'ذكر');
    });

  });
}
