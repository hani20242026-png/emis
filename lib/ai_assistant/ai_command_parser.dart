/// Conservative Arabic/Iraqi command parser. Unknown option values are never invented.
enum AiIntent { openStudents, openTeachers, openAttendance, openGrades, addStudent, addTeacher, unknown }
class AiCommand {
  final AiIntent intent;
  final String originalText;
  final Map<String, String> entities;
  const AiCommand(this.intent, this.originalText, {this.entities = const {}});
}
class AiCommandParser {
  static const _words = <String,String>{
    'صفر':'0','واحد':'1','واحده':'1','وحده':'1','اثنين':'2','اثنان':'2','ثنين':'2',
    'ثلاثه':'3','ثلاثة':'3','تلاثه':'3','تلاته':'3','اربعه':'4','اربعة':'4',
    'خمسه':'5','خمسة':'5','سته':'6','ستة':'6','سبعه':'7','سبعة':'7',
    'ثمانيه':'8','ثمانية':'8','ثمنيه':'8','تسعه':'9','تسعة':'9',
    'احدعش':'11','اثنعش':'12','ثنعش':'12','ثلاثطعش':'13','اربعتعش':'14','اربعطعش':'14',
    'خمستعش':'15','ستعش':'16','سبعتعش':'17','اثمنطعش':'18','ثمنطعش':'18','ثمانتعش':'18','تسعتعش':'19',
    'عشرين':'20','عشرون':'20','ثلاثين':'30','اربعين':'40','خمسين':'50','ستين':'60','سبعين':'70','ثمانين':'80','تسعين':'90',
    'ميه':'100','مئه':'100','الفين':'2000','ألفين':'2000','الف':'1000'
  };
  static String _digits(String s) {
    const map={'٠':'0','١':'1','٢':'2','٣':'3','٤':'4','٥':'5','٦':'6','٧':'7','٨':'8','٩':'9'};
    map.forEach((a,b)=>s=s.replaceAll(a,b)); return s;
  }
  static String normalize(String value) {
    var s=_digits(value).toLowerCase().trim();
    const map={'أ':'ا','إ':'ا','آ':'ا','ى':'ي','ة':'ه','ؤ':'و','ئ':'ي','ـ':''};
    map.forEach((a,b)=>s=s.replaceAll(a,b));
    return s.replaceAll(RegExp(r'[،,؛;.!؟?]+'),' ').replaceAll(RegExp(r'\s+'),' ').trim();
  }
  static String spokenNumbers(String value) {
    var s=normalize(value);
    const variants={'اثمنطعش':'18','ثمنطعش':'18','تلاثة':'3','تلاثه':'3','تلاته':'3','واربعطعش':'14','الفين':'2000','ميه':'100','مئه':'100'};
    variants.forEach((w,n)=>s=s.replaceAll(RegExp('(?<!\\S)${RegExp.escape(w)}(?!\\S)'),n));
    // Iraqi spoken year: «الفين واربعتعش» -> 2014.
    s=s.replaceAllMapped(RegExp(r'2000\s+(\d{1,2})'),(m)=>(2000+(int.tryParse(m.group(1)!)??0)).toString());
    final parts=s.split(' ');
    for(var i=0;i<parts.length;i++) {
      final word=parts[i].replaceFirst(RegExp(r'^و(?=[ء-ي])'),'');
      if(_words.containsKey(word)) parts[i]=_words[word]!;
    }
    return parts.join(' ');
  }
  static String? _capture(String text,List<RegExp> patterns) {
    for(final p in patterns) { final m=p.firstMatch(text); if(m!=null && (m.group(1)?.trim().isNotEmpty??false)) return m.group(1)!.trim().replaceAll(RegExp(r'[،,.؛]+$'),''); }
    return null;
  }
  static bool _validDate(int y,int m,int d) { if(y<1900||y>2100||m<1||m>12||d<1||d>31)return false; final x=DateTime(y,m,d); return x.year==y&&x.month==m&&x.day==d; }
  static String? _date(String text) {
    final s=spokenNumbers(text);
    final m=RegExp(r'(?:مواليد|مواليده|مواله|تولد|ولادته|تاريخ الميلاد|تاريخ التولد)\s*(\d{1,2})\s+(\d{1,2})\s+(\d{4})').firstMatch(s);
    if(m!=null) { final d=int.tryParse(m.group(1)!); final mo=int.tryParse(m.group(2)!); final y=int.tryParse(m.group(3)!); if(d!=null&&mo!=null&&y!=null&&_validDate(y,mo,d)) return '${y.toString().padLeft(4,'0')}-${mo.toString().padLeft(2,'0')}-${d.toString().padLeft(2,'0')}'; }
    final n=RegExp(r'(\d{1,4})[/-](\d{1,2})[/-](\d{1,4})').firstMatch(s);
    if(n!=null) { final a=int.tryParse(n.group(1)!); final b=int.tryParse(n.group(2)!); final c=int.tryParse(n.group(3)!); if(a!=null&&b!=null&&c!=null) { final y=a>31?a:c; final d=a>31?c:a; if(_validDate(y,b,d)) return '${y.toString().padLeft(4,'0')}-${b.toString().padLeft(2,'0')}-${d.toString().padLeft(2,'0')}'; } }
    // SpeechRecognizer often transcribes Iraqi dates as "18/3 2014".
    final separatedYear = RegExp(r'(\d{1,2})[/-](\d{1,2})\s+(\d{4})').firstMatch(s);
    if (separatedYear != null) {
      final day = int.tryParse(separatedYear.group(1)!);
      final month = int.tryParse(separatedYear.group(2)!);
      final year = int.tryParse(separatedYear.group(3)!);
      if (day != null && month != null && year != null && _validDate(year, month, day)) {
        return '${year.toString().padLeft(4, '0')}-${month.toString().padLeft(2, '0')}-${day.toString().padLeft(2, '0')}';
      }
    }
    return null;
  }
  static String? _spokenDigitsAfter(String text,List<String> markers,{int min=1,int max=20}) {
    final s=spokenNumbers(text);
    for(final marker in markers) { final m=RegExp('${RegExp.escape(normalize(marker))}\\s*([0-9][0-9\\s]{0,40})').firstMatch(s); if(m!=null) { final d=m.group(1)!.replaceAll(RegExp(r'\s+'),''); if(d.length>=min&&d.length<=max)return d; } }
    return null;
  }
  static String? _dateAfterMarkers(String text, List<String> markers) {
    final s = spokenNumbers(text);
    for (final marker in markers) {
      final m = RegExp('${RegExp.escape(normalize(marker))}\\s*(\\d{1,2})\\s+(\\d{1,2})\\s+(\\d{4})').firstMatch(s);
      if (m == null) continue;
      final day = int.tryParse(m.group(1)!);
      final month = int.tryParse(m.group(2)!);
      final year = int.tryParse(m.group(3)!);
      if (day != null && month != null && year != null && _validDate(year, month, day)) {
        return '${year.toString().padLeft(4, '0')}-${month.toString().padLeft(2, '0')}-${day.toString().padLeft(2, '0')}';
      }
    }
    return null;
  }

  static String? _captureLabeled(String text, List<String> labels, List<String> stops) {
    final labelPattern = labels.map((x) => RegExp.escape(x)).join('|');
    final stopPattern = stops.map((x) => RegExp.escape(x)).join('|');
    final pattern = RegExp('(?:$labelPattern)\\s*[:：]?\\s*([^،؛\\n]+?)(?=\\s+(?:$stopPattern)|\$)', caseSensitive: false);
    final match = pattern.firstMatch(text);
    return match?.group(1)?.trim();
  }

  static String? _addressNumber(String text, List<String> markers) {
    final s = spokenNumbers(text);
    for (final marker in markers) {
      final m = RegExp('${RegExp.escape(normalize(marker))}\\s+([0-9]+(?:\\s+[0-9]+){0,2})').firstMatch(s);
      if (m == null) continue;
      final parts = m.group(1)!.split(RegExp(r'\s+')).map((x) => int.tryParse(x)).whereType<int>().toList();
      if (parts.isEmpty) continue;
      var value = parts.first;
      for (final next in parts.skip(1)) {
        if (value == 100 || value == 200 || value == 300 || value == 400 || value == 500 || value == 600 || value == 700 || value == 800 || value == 900) {
          value += next;
        } else if (value >= 20 && value <= 90 && value % 10 == 0 && next < 10) {
          value += next;
        } else if (value < 10 && next >= 20 && next <= 90 && next % 10 == 0) {
          value += next;
        } else {
          break;
        }
      }
      return value.toString();
    }
    return null;
  }
  static AiCommand parse(String text, {AiIntent? activeIntent}) {
    final s=normalize(text); bool has(List<String> ws)=>ws.any((w)=>s.contains(normalize(w)));
    var intent=activeIntent ?? AiIntent.unknown;
    if (activeIntent == null) {
      if(has(['غيابات','الغياب','الحضور','تسجيل غياب'])) intent=AiIntent.openAttendance;
      else if(has(['درجات','النتائج','ادخال الدرجات'])) intent=AiIntent.openGrades;
      else if(has(['المعلمين','المعلم','المدرسين','المدرس','معلم','مدرس'])) intent=has(['اضف','اضافه','ضيف','سجل','انشاء','جديد'])?AiIntent.addTeacher:AiIntent.openTeachers;
      else if(has(['الطلاب','الطالب','التلاميذ','طالب'])) intent=has(['اضف','اضافه','ضيف','سجل','انشاء','جديد','اريد'])?AiIntent.addStudent:AiIntent.openStudents;
    }
    final e=<String,String>{};
    final name=_capture(text,[RegExp(r'(?:اسمه|اسم الطالب|اسم التلميذ|اسم المعلم|(?:الطالب|التلميذ|المعلم)\s+(?:الجديد\s+|جديد\s+)?اسم|غير اسمه الى|غير اسمه إلى|غير الاسم الى|غير الاسم إلى|بدل اسمه الى|بدل اسمه إلى|الاسم الجديد)\s*[:：]?\s*([^،؛\n]+?)(?=\s+(?:وامه|و?\s*اسم\s+(?:الام|الأم|الاب|الأب)|اسم أمه|اسم والدته|مواليد|مواله|تاريخ|رقم|هاتف|عنوان|مسقط|الجنس|ذكر|أنثى)|$)',caseSensitive:false)]);
    final inferredName = name ?? _capture(text, [
      RegExp(r'(?:الطالب|التلميذ|المعلم)\s+(?!جديد(?:\s|$))([^،؛\n]+?)(?=\s+(?:وامه|و?\s*اسم\s+(?:الام|الأم|الاب|الأب)|مواليد|مواله|تاريخ|رقم|هاتف|عنوان|مسقط|الجنس)|$)', caseSensitive: false),
    ]);
    if(inferredName!=null && !RegExp(r'^(?:الام|امه|والدته|الاب|والده)\b',caseSensitive:false).hasMatch(normalize(inferredName))) { final p=inferredName.split(RegExp(r'\s+')).where((x)=>x.isNotEmpty).toList(); if(p.isNotEmpty)e['name']=p[0]; if(p.length>1)e['fatherName']=p[1]; if(p.length>2)e['grandFatherName']=p[2]; if(p.length>3)e['fathersGrandFatherName']=p[3]; if(p.length>4)e['surName']=p.skip(4).join(' '); }
    final mother=_capture(text,[RegExp(r'(?:اسم الام|اسم الأم|اسم أمه|اسم امه|واسم الام|واسم الأم|واسم أمه|واسم امه|اسم والدته|اسم والدتة|وامه|وأمه|غير اسم امه الى|غير اسم امه إلى|غير اسم الام الى|غير اسم الام إلى|اسم الام الجديد)\s*[:：]?\s*([^،؛\n]+?)(?=\s+(?:مواليد|مواليده|مواله|تاريخ|رقم|هاتف|عنوان|مسقط|الجنس|ذكر|أنثى)|$)',caseSensitive:false)]); if(mother!=null) { final mp=mother.split(RegExp(r'\s+')).where((x)=>x.isNotEmpty).toList(); if(mp.isNotEmpty)e['motherName']=mp[0]; if(mp.length>1)e['mothersFatherName']=mp[1]; if(mp.length>2)e['mothersGrandFatherName']=mp.skip(2).join(' '); }
    final date=_date(text); if(date!=null)e['dateOfBirth']=date;
    // Extract phone numbers only after a phone label. Concatenating every
    // number in the utterance can accidentally manufacture a phone from an ID,
    // date and address numbers that happen to be spoken in the same sentence.
    final spokenPhone=_spokenDigitsAfter(text,['رقم الهاتف','رقم هاتفه','رقم هاتفها','رقمه الجديد','رقم الموبايل','رقم موبايله','غير رقم الهاتف الى','غير رقم هاتفه الى','بدل رقم الهاتف الى','خلي رقم الهاتف','هاتفه','موبايله','الموبايل'],min:10,max:13);
    if(spokenPhone!=null)e[intent==AiIntent.addTeacher?'mobilePhoneNumber':'homePhoneNumber']=spokenPhone;
    final national=_spokenDigitsAfter(text,['رقم البطاقة الوطنية الموحدة','البطاقة الوطنية الموحدة','رقم البطاقة الوطنية','البطاقة الوطنية','البطاقة الموحدة','رقم الموحدة','الرقم الوطني','غير رقم البطاقة الى','غير الرقم الوطني الى'],min:8,max:20); if(national!=null)e['nationalId']=national;
    final birthplace=_capture(text,[RegExp(r'(?:مسقط راسه|مسقط رأسه|مسقط الرأس|محل الولادة|محل ولادته|مكان الولادة|مكان ولادته)\s*[:：]?\s*([^،؛\n]+?)(?=\s+(?:رقم|هاتف|عنوان|وخلي|وخله|الجنس|ذكر|أنثى)|$)',caseSensitive:false)]); if(birthplace!=null)e['homeTown']=birthplace;
    final town=_capture(text,[RegExp(r'(?:عنوانه|عنوانه الجديد|غير عنوانه الى|غير عنوانه إلى|غير العنوان الى|غير العنوان إلى|يسكن في|السكن في)\s*[:：]?\s*([^،؛\n]+?)(?=\s+(?:حي|محله|محلة|زقاق|شارع|دار)|$)',caseSensitive:false)]); if(town!=null)e['town']=town;
    final area=_capture(text,[RegExp(r'حي\s*([^،؛\n]+?)(?=\s+(?:محله|محلة|زقاق|شارع|دار)|$)',caseSensitive:false)]); if(area!=null)e['area']=area;
    final quarter=_addressNumber(text,['محله','محلة']); if(quarter!=null)e['quarter']=quarter;
    final street=_addressNumber(text,['زقاق','شارع']); if(street!=null)e['street']=street;
    final house=_addressNumber(text,['دار','منزل','بيت']); if(house!=null)e['address1']=house;
    final stage=_capture(text,[RegExp(r'(?:بالصف|في الصف|الصف)\s*([^،؛\n]+?)(?=\s+(?:شعبة|شعبه)|$)',caseSensitive:false)]); if(stage!=null)e['stageId']=stage;
    final room=_capture(text,[RegExp(r'(?:شعبة|شعبه)\s*(ألف|الف|باء|جيم|دال|هاء|واو|زاي|حاء|طاء|ياء|كاف|لام|ميم|نون|هاء|عين|غين|فاء|قاف|راء|سين|شين|صاد|ضاد|طاء|ظاء|ألف|[أ-يA-Za-z])',caseSensitive:false)]); if(room!=null) { const letters={'الف':'أ','ألف':'أ','باء':'ب','جيم':'ج','دال':'د','هاء':'هـ','واو':'و','زاي':'ز','حاء':'ح','طاء':'ط','ياء':'ي','كاف':'ك','لام':'ل','ميم':'م','نون':'ن','عين':'ع','غين':'غ','فاء':'ف','قاف':'ق','راء':'ر','سين':'س','شين':'ش','صاد':'ص','ضاد':'ض','ظاء':'ظ'}; e['classRoomId']=letters[normalize(room)]??room; }

    // Additional student/teacher fields. These are extracted as labels only;
    // dropdown IDs are resolved later against the live EMIS options.
    final email = RegExp(r'[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}', caseSensitive: false).firstMatch(text);
    if (email != null) e['email'] = email.group(0)!;
    final employeeId = _spokenDigitsAfter(text, ['الرقم الوظيفي', 'رقمه الوظيفي', 'رقم الموظف', 'رقم المعلم الوظيفي'], min: 1, max: 20);
    if (employeeId != null) e['employeeIdNumber'] = employeeId;
    final family = _spokenDigitsAfter(text, ['رقم العائلة', 'رقم الاسرة', 'رقم الأسرة'], min: 1, max: 20);
    if (family != null) e['familyNumber'] = family;
    final emergencyPhone = _spokenDigitsAfter(text, ['رقم هاتف الطوارئ', 'هاتف جهة الاتصال', 'رقم جهة الاتصال'], min: 7, max: 13);
    if (emergencyPhone != null) e['emergencyContactPhoneNumber'] = emergencyPhone;
    final quota = _spokenDigitsAfter(text, ['النصاب الاسبوعي', 'النصاب الأسبوعي', 'عدد الحصص الاسبوعية', 'عدد الحصص الأسبوعية'], min: 1, max: 2);
    if (quota != null) e['weeklyTeachingQuota'] = quota;
    final graduationYear = _spokenDigitsAfter(text, ['سنة التخرج', 'عام التخرج'], min: 4, max: 4);
    if (graduationYear != null) e['graduationYear'] = graduationYear;

    final university = _captureLabeled(text, ['الجامعة', 'اسم الجامعة'], ['التخصص', 'سنة التخرج', 'الرقم الوظيفي', 'الهاتف', 'البريد']);
    if (university != null) e['universityName'] = university;
    final specialization = _captureLabeled(text, ['التخصص', 'الاختصاص'], ['الجامعة', 'سنة التخرج', 'الرقم الوظيفي', 'الهاتف', 'البريد']);
    if (specialization != null) e['specialization'] = specialization;
    final job = _captureLabeled(text, ['العنوان الوظيفي', 'الوظيفة'], ['الدرجة الوظيفية', 'المرحلة', 'الراتب', 'النصاب', 'الهاتف', 'البريد']);
    if (job != null) {
      e['positionType'] = job;
      e['jobDesignation'] = job;
    }
    final emergencyName = _captureLabeled(text, ['اسم شخص الطوارئ', 'اسم جهة الاتصال', 'جهة الاتصال للطوارئ'], ['صلة القرابة', 'رقم هاتف الطوارئ', 'هاتف جهة الاتصال']);
    if (emergencyName != null) e['emergencyContactName'] = emergencyName;
    final emergencyRelation = _captureLabeled(text, ['صلة القرابة', 'علاقته بجهة الاتصال'], ['رقم هاتف الطوارئ', 'هاتف جهة الاتصال', 'البريد']);
    if (emergencyRelation != null) e['emergencyContactRelationship'] = emergencyRelation;

    final startDate = _dateAfterMarkers(text, ['تاريخ المباشرة', 'باشر العمل بتاريخ', 'تاريخ بدء العمل']);
    if (startDate != null) e['dateOfStartWorking'] = startDate;
    final issuingDate = _dateAfterMarkers(text, ['تاريخ الاصدار', 'تاريخ الإصدار', 'تاريخ اصدار الوثيقة']);
    if (issuingDate != null) e['issuingDate'] = issuingDate;

    // Iraqi school/student vocabulary and the long-form fields used by the
    // actual EMIS Add Student and Add Teacher forms. Values are captured only
    // after an explicit spoken label; dropdown IDs are resolved by the screen.
    const allSpokenFieldLabels = <String>[
      'اللغة الأم', 'لغة الدراسة', 'اللغة الدراسية', 'الحالة الاجتماعية',
      'فصيلة الدم', 'فئة الدم', 'الديانة', 'المستوى المعيشي', 'الوضع الاقتصادي',
      'الاحتياجات الخاصة', 'ملاحظات', 'الجنسية', 'بلد الولادة', 'محل الولادة',
      'مسقط الرأس', 'نوع الهوية', 'رقم البطاقة الوطنية', 'رقم هوية الأحوال المدنية', 'رقم الإحصاء', 'رقم الاحصاء',
      'بلد الإصدار', 'جهة الإصدار', 'نوع الوثيقة', 'نوع الهوية', 'رقم السجل', 'رقم الصحيفة',
      'المحافظة', 'القضاء', 'الناحية', 'الحي', 'المدينة', 'الجامعة', 'الكلية',
      'التحصيل الدراسي', 'الشهادة الدراسية', 'سنة التخرج', 'الاختصاص', 'التخصص',
      'العنوان الوظيفي', 'المنصب الحالي', 'الدرجة الوظيفية', 'نوع التوظيف',
      'نوع الموظف', 'التصنيف', 'النصاب الأسبوعي', 'الرقم الوظيفي', 'رقم العائلة',
      'تاريخ المباشرة', 'الحالة الوظيفية', 'سبب الحالة', 'الجهة المنسب إليها',
      'اسم جهة الاتصال', 'صلة القرابة', 'رقم هاتف الطوارئ', 'رقم الهاتف',
      'رقم الموبايل', 'البريد الإلكتروني', 'عنوانه', 'الصف', 'الشعبة',
    ];
    String? labeled(List<String> labels, List<String> stops) =>
        _captureLabeled(text, labels, <String>{...stops, ...allSpokenFieldLabels}.toList());

    final motherTongue = labeled(['اللغة الأم', 'لغته الأم', 'لسانه الأم'],
        ['لغة الدراسة', 'اللغة الدراسية', 'الحالة الاجتماعية', 'فصيلة الدم', 'فئة الدم']);
    if (motherTongue != null) e['motherTongue'] = motherTongue;
    final studyLanguage = labeled(['لغة الدراسة', 'اللغة الدراسية', 'لغة التعليم'],
        ['الحالة الاجتماعية', 'فصيلة الدم', 'فئة الدم', 'الديانة', 'المستوى المعيشي']);
    if (studyLanguage != null) e['studyLanguage'] = studyLanguage;
    final marital = labeled(['الحالة الاجتماعية', 'حالته الاجتماعية'],
        ['فصيلة الدم', 'فئة الدم', 'الديانة', 'الاختصاص', 'التخصص']);
    if (marital != null) e['maritalStatus'] = marital;
    final blood = labeled(['فصيلة الدم', 'فئة الدم', 'زمرة الدم'],
        ['الديانة', 'المستوى المعيشي', 'الحالة الاجتماعية', 'اللغة']);
    if (blood != null) e['bloodGroup'] = blood;
    final religion = labeled(['الديانة', 'ديانته'],
        ['المستوى المعيشي', 'الاحتياجات الخاصة', 'ملاحظات', 'اللغة']);
    if (religion != null) e['religion'] = religion;
    final economic = labeled(['المستوى المعيشي', 'الوضع الاقتصادي', 'الحالة الاقتصادية'],
        ['الاحتياجات الخاصة', 'ملاحظات', 'رقم الهاتف']);
    if (economic != null) e['economicLevel'] = economic;
    final special = labeled(['الاحتياجات الخاصة', 'ذوي الاحتياجات الخاصة'],
        ['ملاحظات', 'رقم الهاتف', 'العنوان']);
    if (special != null) e['specialNeeds'] = special;
    final notes = labeled(['ملاحظات', 'ملاحظة'],
        ['رقم الهاتف', 'رقم الموبايل', 'العنوان', 'المحافظة']);
    if (notes != null) e['notes'] = notes;

    final nationality = labeled(['الجنسية', 'جنسيته'],
        ['بلد الولادة', 'محل الولادة', 'مسقط الرأس', 'نوع الهوية', 'رقم البطاقة']);
    if (nationality != null) e['nationality'] = nationality;
    final countryBirth = labeled(['بلد الولادة', 'محل الولادة', 'مكان الولادة'],
        ['الجنسية', 'مسقط الرأس', 'نوع الهوية', 'رقم البطاقة']);
    if (countryBirth != null) e['countryOfBirth'] = countryBirth;
    final issuingCountry = labeled(['بلد الإصدار', 'بلد الاصدار', 'الدولة المصدرة'],
        ['تاريخ الإصدار', 'تاريخ الاصدار', 'جهة الإصدار', 'رقم السجل']);
    if (issuingCountry != null) e['issuingCountry'] = issuingCountry;
    final issuer = labeled(['جهة الإصدار', 'جهة الاصدار', 'الجهة المصدرة'],
        ['تاريخ الإصدار', 'تاريخ الاصدار', 'رقم السجل', 'رقم الصحيفة']);
    if (issuer != null) e['issuer'] = issuer;
    final documentType = labeled(['نوع الوثيقة', 'اسم الوثيقة'],
        ['رقم السجل', 'رقم الصحيفة', 'جهة الإصدار', 'تاريخ الإصدار']);
    if (documentType != null) e['nameOfDocument'] = documentType;

    final idNumber = _spokenDigitsAfter(text,
        ['رقم هوية الأحوال المدنية', 'رقم هوية الاحوال المدنية', 'رقم الأحوال المدنية'],
        min: 6, max: 20);
    if (idNumber != null) e['idNumber'] = idNumber;
    final recordNumber = _spokenDigitsAfter(text,
        ['رقم السجل', 'السجل المدني'], min: 1, max: 12);
    if (recordNumber != null) e['recordNumber'] = recordNumber;
    final pageNumber = _spokenDigitsAfter(text,
        ['رقم الصحيفة', 'الصحيفة'], min: 1, max: 12);
    if (pageNumber != null) e['pageNumber'] = pageNumber;
    final censusNumber = _spokenDigitsAfter(text,
        ['رقم الإحصاء', 'رقم الاحصاء', 'الإحصاء'], min: 1, max: 20);
    if (censusNumber != null) e['censusNumber'] = censusNumber;
    final familyNo = _spokenDigitsAfter(text,
        ['رقم العائلة', 'الرقم العائلي', 'رقم الأسرة'], min: 1, max: 20);
    if (familyNo != null) e['familyNumber'] = familyNo;

    final employmentGrade = labeled(['الدرجة الوظيفية', 'درجته الوظيفية'],
        ['المرحلة الوظيفية', 'العنوان الوظيفي', 'المنصب الحالي', 'النصاب']);
    if (employmentGrade != null) e['employmentGrade'] = employmentGrade;
    final position = labeled(['العنوان الوظيفي', 'عنوانه الوظيفي'],
        ['المنصب الحالي', 'الدرجة الوظيفية', 'الاختصاص', 'التخصص', 'النصاب']);
    if (position != null) e['positionType'] = position;
    final currentPosition = labeled(['المنصب الحالي', 'منصبه الحالي'],
        ['الحالة الوظيفية', 'سبب الحالة', 'الجهة المنسب', 'الاختصاص', 'التخصص']);
    if (currentPosition != null) e['currentPosition'] = currentPosition;
    final employmentType = labeled(['نوع التوظيف', 'نوع التعيين'],
        ['نوع الموظف', 'تصنيف الموظف', 'العنوان الوظيفي', 'المنصب الحالي']);
    if (employmentType != null) e['employmentType'] = employmentType;
    final employeeCategory = labeled(['نوع الموظف', 'فئة الموظف'],
        ['التصنيف', 'العنوان الوظيفي', 'المنصب الحالي']);
    if (employeeCategory != null) e['employeeCategory'] = employeeCategory;
    final classification = labeled(['التصنيف', 'تصنيفه'],
        ['العنوان الوظيفي', 'المنصب الحالي', 'الدرجة الوظيفية']);
    if (classification != null) e['classification'] = classification;
    final assigned = labeled(['الجهة المنسب إليها', 'الجهة المكلف إليها', 'مكان العمل', 'المدرسة التي يعمل بها'],
        ['التحصيل الدراسي', 'الجامعة', 'الاختصاص', 'رقم الهاتف']);
    if (assigned != null) e['assignedEntityName'] = assigned;
    final education = labeled(['التحصيل الدراسي', 'الشهادة الدراسية', 'الشهادة'],
        ['الجامعة', 'الكلية', 'سنة التخرج', 'الاختصاص', 'التخصص']);
    if (education != null) e['educationLevel'] = education;
    final specialInfo = labeled(['معلومات ذوي الاحتياجات الخاصة', 'تفاصيل الاحتياجات الخاصة'],
        ['اسم جهة الاتصال', 'رقم الهاتف', 'ملاحظات']);
    if (specialInfo != null) e['specialNeedsInformation'] = specialInfo;
    final statusReason = labeled(['سبب الحالة الوظيفية', 'سبب الحالة'],
        ['الجهة المنسب', 'التحصيل الدراسي', 'الجامعة', 'الاختصاص']);
    if (statusReason != null) e['statusReason'] = statusReason;
    final status = labeled(['الحالة الوظيفية', 'حالته الوظيفية'],
        ['تاريخ سريان الحالة', 'سبب الحالة', 'الجهة المنسب']);
    if (status != null) e['status'] = status;

    final fatherId = _spokenDigitsAfter(text,
        ['رقم البطاقة الوطنية للأب', 'رقم بطاقة الأب', 'رقم هوية الأب'],
        min: 6, max: 20);
    if (fatherId != null) e['fatherNationalId'] = fatherId;
    final fatherRecord = _spokenDigitsAfter(text,
        ['رقم سجل الأب', 'رقم السجل للأب'], min: 1, max: 12);
    if (fatherRecord != null) e['fatherRecordNumber'] = fatherRecord;

    // Common Iraqi date phrases with month names. The output remains ISO 8601.
    final monthNames = <String, String>{
      'كانون الثاني':'01','يناير':'01','شباط':'02','فبراير':'02',
      'اذار':'03','مارس':'03','نيسان':'04','ابريل':'04','أبريل':'04',
      'ايار':'05','مايو':'05','حزيران':'06','يونيو':'06','تموز':'07',
      'يوليو':'07','اب':'08','اغسطس':'08','أغسطس':'08','ايلول':'09',
      'سبتمبر':'09','تشرين الاول':'10','اكتوبر':'10','أكتوبر':'10',
      'تشرين الثاني':'11','نوفمبر':'11','كانون الاول':'12','ديسمبر':'12'
    };
    if (!e.containsKey('dateOfBirth')) {
      final normalized = normalize(text);
      for (final entry in monthNames.entries) {
        final month = normalize(entry.key);
        final match = RegExp(r'(?:مواليد|مواليده|تولد|ولد بتاريخ|تاريخ الميلاد)\s*(\d{1,2})\s+(?:من\s+)?' + RegExp.escape(month) + r'\s+(?:سنة\s+|عام\s+)?(\d{4})').firstMatch(normalized);
        if (match == null) continue;
        final day = int.tryParse(match.group(1)!);
        final year = int.tryParse(match.group(2)!);
        final monthNumber = int.tryParse(entry.value);
        if (day != null && year != null && monthNumber != null && _validDate(year, monthNumber, day)) {
          e['dateOfBirth'] = '${year.toString().padLeft(4, '0')}-${entry.value}-${day.toString().padLeft(2, '0')}';
          break;
        }
      }
    }

    final governorate = labeled(['المحافظة', 'محافظته', 'محافظة السكن'],
        ['القضاء', 'الناحية', 'الحي', 'المدينة', 'رقم الهاتف']);
    if (governorate != null) e['addressGovernorate'] = governorate;
    final district = labeled(['القضاء', 'قضاء السكن', 'القضاء والناحية'],
        ['الناحية', 'الحي', 'المدينة', 'الشارع', 'رقم الهاتف']);
    if (district != null) e['addressDistrict'] = district;
    final subdistrict = labeled(['الناحية', 'ناحية السكن'],
        ['الحي', 'المدينة', 'الشارع', 'رقم الهاتف']);
    if (subdistrict != null) e['addressTown'] = subdistrict;
    final addressCountry = labeled(['دولة السكن', 'بلد السكن'],
        ['المحافظة', 'القضاء', 'الناحية', 'الحي']);
    if (addressCountry != null) e['addressCountry'] = addressCountry;
    final socialWelfare = _capture(text, [
      RegExp(r'(?:مشمول بالرعاية الاجتماعية|مشمول بمنحة الرعاية|الرعاية الاجتماعية)\s*[:：]?\s*(نعم|اي|إي|لا|غير مشمول)', caseSensitive: false),
    ]);
    if (socialWelfare != null) e['isCoveredBySocialWelfare'] =
        normalize(socialWelfare).startsWith('لا') || normalize(socialWelfare).startsWith('غير') ? 'لا' : 'نعم';

    final gender = _capture(text, [
      RegExp(r'(?:الجنس|جنسيته من حيث الجنس)\s*[:：]?\s*(ذكر|انثى|أنثى|ولد|بنت)', caseSensitive: false),
      RegExp(r'(?:^|[\s،؛])(?:ذكر|أنثى|انثى)(?=$|[\s،؛])', caseSensitive: false),
    ]);
    if (gender != null) e['gender'] = normalize(gender) == 'انثي' || normalize(gender) == 'بنت' || normalize(gender) == 'انثى' ? 'أنثى' : 'ذكر';

    return AiCommand(intent,text,entities:e);
  }
}
