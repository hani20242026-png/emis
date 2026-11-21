import 'package:flutter/material.dart';

enum SchoolCardFieldType { text, number, textarea, date, select, radio, checkbox, multiSelect, image }
enum SchoolCardSectionMode { editable, academicRecord, achievement, attendance }

class SchoolCardOption {
  final String label;
  final String value;
  const SchoolCardOption(this.label, this.value);
}

class SchoolCardField {
  final String key;
  final String label;
  final SchoolCardFieldType type;
  final bool half;
  final String? dynamicList;
  final List<SchoolCardOption> options;
  const SchoolCardField(this.key, this.label,
      {this.type = SchoolCardFieldType.text, this.half = false,
       this.dynamicList, this.options = const []});
}

class SchoolCardSection {
  final String key;
  final String label;
  final IconData icon;
  final SchoolCardSectionMode mode;
  final List<SchoolCardField> fields;
  const SchoolCardSection(this.key, this.label, this.icon, this.fields,
      {this.mode = SchoolCardSectionMode.editable});
  bool get editable => mode == SchoolCardSectionMode.editable;
}

/// الحقول التي لا تظهر إلا عند تفعيل خيار الحالة الصحية المرتبط بها.
/// مفاتيح الخيارات مربوطة بحقول checkbox التي تخزن القيم true/false.
const Map<String, String> kSchoolCardDependentHealthFields = {
  'drugAllergyCause': 'drugAllergy',
  'physicalDisabilitiesType': 'physicalDisabilities',
  'chronicDiseasesType': 'chronicDiseases',
  'previousAccidentsType': 'previousAccidents',
  'surgeriesType': 'surgeries',
};

const List<SchoolCardSection> kSchoolCardSections = [
  SchoolCardSection('initialInformation', 'البيانات الأولية', Icons.info_outline, [
    SchoolCardField('governorate', 'المحافظة', type: SchoolCardFieldType.select, dynamicList: 'governorate'),
    SchoolCardField('city', 'المدينة', type: SchoolCardFieldType.select, dynamicList: 'city'),
    SchoolCardField('guardianName', 'اسم ولي الأمر'),
    SchoolCardField('guardianJob', 'مهنة ولي الأمر'),
    SchoolCardField('guardianPhone', 'هاتف ولي الأمر', type: SchoolCardFieldType.number),
    SchoolCardField('guardianRelationship', 'صلة ولي الأمر بالتلميذ'),
    SchoolCardField('fatherIsAlive', 'هل الأب على قيد الحياة؟', type: SchoolCardFieldType.select),
    SchoolCardField('motherIsAlive', 'هل الأم على قيد الحياة؟', type: SchoolCardFieldType.select),
    SchoolCardField('fatherEducation', 'التحصيل الدراسي للأب'),
    SchoolCardField('motherEducation', 'التحصيل الدراسي للأم'),
    SchoolCardField('studentOrderAmongSiblings', 'ترتيب التلميذ بين إخوته وأخواته', type: SchoolCardFieldType.number),
    SchoolCardField('classPhotoUrl', 'صورة الصف', type: SchoolCardFieldType.image),
    SchoolCardField('familyAddress', 'عنوان الأسرة', type: SchoolCardFieldType.textarea),
    SchoolCardField('notes', 'ملاحظات', type: SchoolCardFieldType.textarea),
  ]),
  SchoolCardSection('socialStatus', 'الحالة الاجتماعية', Icons.family_restroom, [
    SchoolCardField('familyMemberCount', 'عدد أفراد الأسرة', type: SchoolCardFieldType.number),
    SchoolCardField('brothersCount', 'عدد الإخوة', type: SchoolCardFieldType.number),
    SchoolCardField('sistersCount', 'عدد الأخوات', type: SchoolCardFieldType.number),
    SchoolCardField('livingWith', 'التلميذ يعيش مع'),
    SchoolCardField('monthlyIncome', 'دخل الأسرة الشهري', type: SchoolCardFieldType.select),
    SchoolCardField('roomCount', 'عدد الغرف التي تشغلها الأسرة', type: SchoolCardFieldType.number),
    SchoolCardField('studyEnvironmentSuitability', 'مدى ملاءمة الجو العام في البيت للدراسة', type: SchoolCardFieldType.select),
    SchoolCardField('studentWorks', 'هل التلميذ يعمل', type: SchoolCardFieldType.select),
    SchoolCardField('notes', 'ملاحظات', type: SchoolCardFieldType.textarea),
  ]),
  SchoolCardSection('healthAndPhysicalTraits', 'الصفات الجسمية والحالة الصحية', Icons.health_and_safety_outlined, [
    SchoolCardField('height', 'الطول (سم)', type: SchoolCardFieldType.number, half: true),
    SchoolCardField('weight', 'الوزن (كغم)', type: SchoolCardFieldType.number, half: true),
    SchoolCardField('visionReport', 'حدة البصر', type: SchoolCardFieldType.select),
    SchoolCardField('rightEyeVisionDegree', 'درجة البصر (العين اليمنى)', type: SchoolCardFieldType.select),
    SchoolCardField('leftEyeVisionDegree', 'درجة البصر (العين اليسرى)', type: SchoolCardFieldType.select),
    SchoolCardField('hearingReport', 'درجة السمع', type: SchoolCardFieldType.select),
    SchoolCardField('hearingDegree', 'درجة السمع - عند اختيار توفر تقرير طبي', type: SchoolCardFieldType.select),
    SchoolCardField('speech', 'النطق', type: SchoolCardFieldType.select),
    SchoolCardField('dentalExaminationAtRegistration', 'فحص الأسنان - أثناء التسجيل'),
    SchoolCardField('visitingHealthTeamDentalNotes', 'فحص الأسنان - ملاحظات الفرقة الصحية الزائرة', type: SchoolCardFieldType.textarea),
    SchoolCardField('completedRequiredVaccinations', 'هل أكمل التلقيحات المطلوبة؟', type: SchoolCardFieldType.select),
    SchoolCardField('vaccinations', 'اللقاحات', type: SchoolCardFieldType.multiSelect, dynamicList: 'vaccinations'),
    SchoolCardField('drugAllergy', 'الحساسية تجاه الأدوية', type: SchoolCardFieldType.select),
    SchoolCardField('drugAllergyCause', 'الدواء المسبب للحساسية', type: SchoolCardFieldType.textarea),
    SchoolCardField('physicalDisabilities', 'العاهات الجسمية', type: SchoolCardFieldType.select),
    SchoolCardField('physicalDisabilitiesType', 'نوع العاهة', type: SchoolCardFieldType.textarea),
    SchoolCardField('chronicDiseases', 'الأمراض المزمنة', type: SchoolCardFieldType.select),
    SchoolCardField('chronicDiseasesType', 'نوع المرض المزمن', type: SchoolCardFieldType.textarea),
    SchoolCardField('previousAccidents', 'الحوادث السابقة', type: SchoolCardFieldType.select),
    SchoolCardField('previousAccidentsType', 'نوع الحادث', type: SchoolCardFieldType.textarea),
    SchoolCardField('surgeries', 'العمليات الجراحية', type: SchoolCardFieldType.select),
    SchoolCardField('surgeriesType', 'نوع العملية', type: SchoolCardFieldType.textarea),
    SchoolCardField('generalHealthStatus', 'الحالة الصحية العامة', type: SchoolCardFieldType.select),
  ]),
  SchoolCardSection('personalTraits', 'الصفات الشخصية', Icons.person_outline, [
    SchoolCardField('traitsOften', 'الصفات بدرجة (كثيراً)', type: SchoolCardFieldType.multiSelect),
    SchoolCardField('traitsSometimes', 'الصفات بدرجة (أحياناً)', type: SchoolCardFieldType.multiSelect),
    SchoolCardField('traitsRarely', 'الصفات بدرجة (نادراً)', type: SchoolCardFieldType.multiSelect),
  ]),
  SchoolCardSection('interests', 'الاهتمامات', Icons.interests_outlined, [
    SchoolCardField('interestsOften', 'الاهتمامات بدرجة (كثيراً)', type: SchoolCardFieldType.multiSelect),
    SchoolCardField('interestsSometimes', 'الاهتمامات بدرجة (أحياناً)', type: SchoolCardFieldType.multiSelect),
    SchoolCardField('interestsRarely', 'الاهتمامات بدرجة (نادراً)', type: SchoolCardFieldType.multiSelect),
  ]),
  SchoolCardSection('scientificInterests', 'الاهتمامات العلمية', Icons.science_outlined, [
    SchoolCardField('subjectsExcelledIn', 'الدروس العلمية التي يتفوق فيها', type: SchoolCardFieldType.textarea),
    SchoolCardField('grade', 'الدرجة'),
    SchoolCardField('practicalParticipation', 'مدى مشاركته في التطبيقات العملية', type: SchoolCardFieldType.textarea),
    SchoolCardField('participationDegree', 'درجة المشاركة', type: SchoolCardFieldType.radio),
    SchoolCardField('talents', 'المواهب العلمية', type: SchoolCardFieldType.textarea),
    SchoolCardField('scientificProgramCenterName', 'المراكز العلمية التي ينتمي إليها - اسم المركز'),
    SchoolCardField('scientificProgramMembershipDate', 'المراكز العلمية التي ينتمي إليها - تاريخ الانتماء', type: SchoolCardFieldType.date),
    SchoolCardField('scientificExhibitionParticipationAndSuccess', 'عدد مرات مشاركته في المعارض العلمية ومستوى نجاحه', type: SchoolCardFieldType.textarea),
    SchoolCardField('createdDeviceTypes', 'نوع الأجهزة التي صنعها', type: SchoolCardFieldType.textarea),
    SchoolCardField('schoolGiftsAndRewards', 'الهدايا والمكافآت التي حصل عليها - من المدرسة', type: SchoolCardFieldType.textarea),
    SchoolCardField('relatedEntityGiftsAndRewardsInIraq', 'الهدايا والمكافآت التي حصل عليها - من الجهات ذات العلاقة في العراق', type: SchoolCardFieldType.textarea),
    SchoolCardField('extracurricularScientificInterests', 'اهتماماته العلمية خارج المناهج الدراسية', type: SchoolCardFieldType.textarea),
    SchoolCardField('notes', 'ملاحظات', type: SchoolCardFieldType.textarea),
  ]),
  SchoolCardSection('problems', 'المشكلات', Icons.warning_amber_outlined, [
    SchoolCardField('problemType', 'نوع المشكلة', type: SchoolCardFieldType.select),
    SchoolCardField('description', 'وصف المشكلة', type: SchoolCardFieldType.textarea),
    SchoolCardField('actionTaken', 'الإجراء المتخذ', type: SchoolCardFieldType.textarea),
    SchoolCardField('actionTakenWithEntity', 'الجهة التي تم الاستعانة بها لحل المشكلة', type: SchoolCardFieldType.textarea),
  ]),
  SchoolCardSection('awardsAndPenalties', 'التقديرات والعقوبات', Icons.emoji_events_outlined, [
    SchoolCardField('hasAwardsPenalties', 'موجود تقديرات أو عقوبات', type: SchoolCardFieldType.checkbox),
    SchoolCardField('school', 'المدرسة'),
    SchoolCardField('honorCount', 'عدد مرات التكريم', type: SchoolCardFieldType.number),
    SchoolCardField('penaltyCount', 'عدد العقوبات', type: SchoolCardFieldType.number),
    SchoolCardField('justificationAndSource', 'مبررات تقديم التكريم أو العقوبة ومصدر ذلك', type: SchoolCardFieldType.textarea),
    SchoolCardField('effectiveness', 'مدى فعالية التكريم أو العقوبة', type: SchoolCardFieldType.textarea),
  ]),
  SchoolCardSection('generalStudentReport', 'التقرير العام عن الطالب', Icons.description_outlined, [
    SchoolCardField('stageLabel', 'المرحلة الدراسية'),
    SchoolCardField('report', 'التقرير العام', type: SchoolCardFieldType.textarea),
  ]),
  SchoolCardSection('academicRecord', 'السجل الدراسي', Icons.school_outlined, const [], mode: SchoolCardSectionMode.academicRecord),
  SchoolCardSection('achievements', 'الإنجازات', Icons.stars_outlined, const [], mode: SchoolCardSectionMode.achievement),
  SchoolCardSection('attendance', 'الغيابات', Icons.event_busy_outlined, const [], mode: SchoolCardSectionMode.attendance),
];

SchoolCardSection schoolCardSectionByKey(String key) =>
    kSchoolCardSections.firstWhere((s) => s.key == key,
        orElse: () => kSchoolCardSections.first);
