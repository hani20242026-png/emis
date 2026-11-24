import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'google_speech_service.dart';

class AppCore {
  /// Desktop fallback for devices/drivers where Flutter shader gradients are
  /// not composited correctly. Mobile rendering keeps the original gradients.
  static bool get isWindows => Platform.isWindows;

  static Color? windowsGradientFallback(Gradient? gradient) {
    if (gradient == null) return null;
    if (gradient is RadialGradient) {
      return gradient.colors.first.withOpacity(0.16);
    }
    if (gradient is SweepGradient) {
      return gradient.colors.first;
    }
    if (gradient is LinearGradient) {
      return gradient.colors.first;
    }
    return Colors.transparent;
  }

  static SharedPreferences? _preferences;

  /// Optional Windows WebView authentication bridge installed by the app shell.
  static Future<String?> Function(String initialUrl)? windowsWebViewAuthHandler;

  /// SharedPreferences cache used by screens that read lightweight feature flags[span_2](start_span)[span_2](end_span)[span_3](start_span)[span_3](end_span).
  static SharedPreferences get prefs {
    final instance = _preferences;
    if (instance == null) {
      throw StateError(
        'AppCore preferences have not been initialized. '
        'Call AppCore.initPreferences() before accessing AppCore.prefs.',
      );
    }
    return instance;
  }
  static final ValueNotifier<ThemeMode> themeNotifier =
      ValueNotifier<ThemeMode>(ThemeMode.dark);
  static final AudioPlayer audioPlayer = AudioPlayer();
  static bool isAudioMuted = true;
  static double currentVolume = 0.5;
  static bool voiceInputEnabled = true;

  /// يحدد ما إذا كان التطبيق قد تم بناؤه مع دعم الذكاء الاصطناعي المحلي أم بدونه[span_4](start_span)[span_4](end_span)[span_5](start_span)[span_5](end_span)
  static const bool kLocalAiBuildEnabled =
      bool.fromEnvironment('ENABLE_LOCAL_AI', defaultValue: true);

  static bool aiAssistantEnabled = false;
  static final ValueNotifier<bool> aiAssistantEnabledNotifier =
      ValueNotifier<bool>(false);
  static final ValueNotifier<bool> aiAssistantAvailableNotifier =
      ValueNotifier<bool>(false);
  static bool voiceSequentialAutoStart = false;
  static bool centralKeyboardNavigationEnabled = true;
  static String voiceRecognitionEngine = 'google';

  static bool voiceAutoRestart = false;
  static int voicePossibleSilenceMs = 23000;
  static int voiceCompleteSilenceMs = 23000;
  static int voiceMinimumSpeechMs = 2500;
  static int voiceRestartDelayMs = 4100;
  static int voiceFinalizationTimeoutMs = 2400;
  static double voiceArrowOpacity = 0.25;
  static double voiceArrowLeft = 0.0;
  static double? voiceArrowTop;

  static bool voiceContinuousSingleSession = false;
  static bool voiceMuteIntermediateBeeps = false;
  static bool voiceIraqiFastDigitsMode = true;
  static bool voiceAutoStopOnTargetLength = false;

  static final ValueNotifier<int> voiceSettingsRevision = ValueNotifier<int>(0);

  static String defaultGender = '1';
  // Student-only academic defaults (EMIS stage/classroom IDs)[span_6](start_span)[span_6](end_span)[span_7](start_span)[span_7](end_span).
  static String defaultStudentStageId = '';
  static String defaultStudentClassRoomId = '';
  static String defaultCountry = 'العراق';
  static String defaultGovernorate = 'القادسية';
  static String defaultDistrict = 'الديوانية';
  static String defaultTown = 'الديوانية';
  static String defaultArea = '';
  static String defaultHomeTown = '';
  static String defaultIdType = '12';
  static String defaultMotherTongue = 'العربية';
  static String defaultStudyLanguage = 'العربية';
  static String defaultReligion = 'الإسلام';
  static String defaultBloodGroup = 'O+';
  static String defaultEconomicLevel = 'الطبقة الوسطى';
  static String defaultAddress1 = '0';
  static String defaultAddress2 = '0';
  static String defaultClosestLocation = '0';

  static String defaultTeacherStatus = 'مستمر';
  /// الحالة الافتراضية للموظف عند إنشاء سجل جديد[span_8](start_span)[span_8](end_span)[span_9](start_span)[span_9](end_span).
  static String defaultEmployeeStatus = 'مستمر';
  static String defaultEmployeeCategory = 'تدريسي';
  static String defaultEmploymentType = 'ملاك';
  static String defaultClassification = 'معلم';
  static String defaultCurrentPosition = 'مدرس';
  static String defaultEducationLevel = 'بكالوريوس';

  static String? configuredDefaultForStudentField(String fieldKey) {
    switch (fieldKey) {
      case 'gender':
        return defaultGender.trim();
      case 'countryOfBirth':
      case 'nationality':
      case 'issuingCountry':
      case 'fatherIssuingCountry':
      case 'addressCountry':
        return defaultCountry.trim();
      case 'addressGovernorate':
        return defaultGovernorate.trim();
      case 'addressDistrict':
      case 'addressTown':
        return defaultDistrict.trim();
      case 'town':
        return defaultTown.trim();
      case 'area':
        return defaultArea.trim();
      case 'homeTown':
        return defaultHomeTown.trim();
      case 'idType':
      case 'fatherIdType':
        return defaultIdType.trim();
      case 'motherTongue':
        return defaultMotherTongue.trim();
      case 'studyLanguage':
        return defaultStudyLanguage.trim();
      case 'religion':
        return defaultReligion.trim();
      case 'bloodGroup':
        return defaultBloodGroup.trim();
      case 'economicLevel':
        return defaultEconomicLevel.trim();
      case 'address1':
        return defaultAddress1.trim();
      case 'address2':
        return defaultAddress2.trim();
      case 'closestLocation':
        return defaultClosestLocation.trim();
      default:
        return null;
    }
  }

  static bool hasConfiguredDefaultForStudentField(String fieldKey) {
    final val = configuredDefaultForStudentField(fieldKey);
    return val != null && val.isNotEmpty;
  }

  static List<dynamic> cachedAvailableStages =
      <dynamic>[];
  static final Map<String, List<dynamic>>
      cachedClassRoomsByStage = <String, List<dynamic>>{};
  static final Map<String, Map<String, dynamic>>
      cachedStageDetailsByStage = <String, Map<String, dynamic>>{};

  static bool get isDarkMode => themeNotifier.value == ThemeMode.dark;

  static void setAcademicStagesCache({
    List<dynamic>? stages,
    Map<String, List<dynamic>>? roomsByStage,
    Map<String, Map<String, dynamic>>? detailsByStage,
  }) {
    if (stages != null && stages.isNotEmpty) {
      cachedAvailableStages = List<dynamic>.from(stages);
    }
    if (roomsByStage != null) {
      roomsByStage.forEach((k, v) {
        cachedClassRoomsByStage[k] = List<dynamic>.from(v);
      });
    }
    if (detailsByStage != null) {
      detailsByStage.forEach((k, v) {
        cachedStageDetailsByStage[k] = Map<String, dynamic>.from(v);
      });
    }
  }

  static int? targetDigitsLengthForField(String fieldKey) {
    switch (fieldKey) {
      case 'nationalId':
      case 'fatherNationalId':
        return 12;
      case 'homePhoneNumber':
      case 'mobilePhoneNumber':
      case 'schoolPhoneNumber':
      case 'employeePhoneNumber':
        return 11;
      default:
        return null;
    }
  }

  static String voiceFieldTypeForField(String fieldKey) {
    if (targetDigitsLengthForField(fieldKey) != null ||
        fieldKey.toLowerCase().contains('phone') ||
        fieldKey.toLowerCase().contains('id') ||
        fieldKey.toLowerCase().contains('grade') ||
        fieldKey.toLowerCase().contains('mark') ||
        fieldKey.toLowerCase().contains('score') ||
        fieldKey.toLowerCase().contains('number')) {
      return 'digits';
    }
    if (fieldKey.toLowerCase().contains('address') ||
        fieldKey.toLowerCase().contains('location') ||
        fieldKey.toLowerCase().contains('fullname') ||
        fieldKey.toLowerCase().contains('note')) {
      return 'long_text';
    }
    return 'general';
  }

  static const String _arabicIndicChars = '٠١٢٣٤٥٦٧٨٩';
  static const String _easternArabicIndicChars = '۰۱۲۳۴۵۶۷۸۹';

  static String normalizeDigitsOnly(String value) {
    final out = StringBuffer();
    for (final rune in value.runes) {
      final ch = String.fromCharCode(rune);
      final a = _arabicIndicChars.indexOf(ch);
      if (a >= 0) {
        out.write(a);
        continue;
      }
      final e = _easternArabicIndicChars.indexOf(ch);
      if (e >= 0) {
        out.write(e);
        continue;
      }
      out.write(ch);
    }
    return out.toString();
  }

  static String normalizeIraqiSpokenText(String raw) {
    var text = raw.trim();
    if (text.isEmpty) return '';
    text = text.replaceAll(RegExp(r'[،,؛;.!؟?\-_]+'), ' ');
    text = text.replaceAll(RegExp(r'\s+'), ' ');

    final compoundFixes = <RegExp, String>{
      RegExp(r'\bعبد\s+ال'): 'عبد ال',
      RegExp(r'\bعبدال'): 'عبد ال',
      RegExp(r'\bابو\s+'): 'أبو ',
      RegExp(r'\bام\s+'): 'أم ',
      RegExp(r'\bآل\s+'): 'آل ',
      RegExp(r'\bذو\s+ال'): 'ذو ال',
      RegExp(r'\bذي\s+ال'): 'ذي ال',
      RegExp(r'\bزين\s+العابدين\b'): 'زين العابدين',
      RegExp(r'\bنور\s+الهدى\b'): 'نور الهدى',
      RegExp(r'\bفاطمه\s+الزهراء\b'): 'فاطمة الزهراء',
    };
    compoundFixes.forEach((pattern, replacement) {
      text = text.replaceAll(pattern, replacement);
    });
    return text.trim();
  }

  static String _normalizeIraqiNumberToken(String raw) {
    var w = normalizeDigitsOnly(raw).toLowerCase().trim();
    w = w.replaceAll(RegExp(r'[\u064B-\u065F\u0670\u0640]'), '');
    w = w
        .replaceAll('أ', 'ا')
        .replaceAll('إ', 'ا')
        .replaceAll('آ', 'ا')
        .replaceAll('ٱ', 'ا');
    w = w
        .replaceAll('ة', 'ه')
        .replaceAll('ى', 'ي')
        .replaceAll('ؤ', 'و')
        .replaceAll('ئ', 'ي');
    w = w
        .replaceAll('چ', 'ج')
        .replaceAll('گ', 'ك')
        .replaceAll('پ', 'ب')
        .replaceAll('ڤ', 'ف');
    w = w.replaceAll(RegExp(r'[^\u0600-\u06FF0-9]'), '');
    return w;
  }

  static String _phoneticSkeleton(String normalized) {
    return normalized
        .replaceAll('ص', 'س')
        .replaceAll('ض', 'د')
        .replaceAll('ظ', 'د')
        .replaceAll('ذ', 'د')
        .replaceAll('ث', 'ت')
        .replaceAll('ط', 'ت')
        .replaceAll('ق', 'ك')
        .replaceAll('غ', 'خ');
  }

  static int _levenshteinDistance(String s, String t) {
    if (s == t) return 0;
    if (s.isEmpty) return t.length;
    if (t.isEmpty) return s.length;

    final v0 = List<int>.generate(t.length + 1, (i) => i);
    final v1 = List<int>.filled(t.length + 1, 0);

    for (var i = 0; i < s.length; i++) {
      v1[0] = i + 1;
      for (var j = 0; j < t.length; j++) {
        final cost = (s.codeUnitAt(i) == t.codeUnitAt(j)) ? 0 : 1;
        final deletion = v1[j] + 1;
        final insertion = v0[j + 1] + 1;
        final substitution = v0[j] + cost;
        var minVal = deletion < insertion ? deletion : insertion;
        if (substitution < minVal) minVal = substitution;
        v1[j + 1] = minVal;
      }
      for (var j = 0; j <= t.length; j++) {
        v0[j] = v1[j];
      }
    }
    return v1[t.length];
  }

  static const Map<String, int> _iraqiSpokenNumbersMap = {
    'صفر': 0, 'صفير': 0, 'زيرو': 0, 'سفر': 0, 'صفرا': 0, 'صفره': 0, 'اصفر': 0, 'او': 0,
    'واحد': 1, 'واحده': 1, 'وحده': 1, 'احد': 1, 'وحد': 1, 'واحدن': 1, 'وحدة': 1, 'اول': 1,
    'اثنان': 2, 'اثنين': 2, 'ثنين': 2, 'اثنتان': 2, 'اثنتين': 2, 'ثنتين': 2,
    'ثنتان': 2, 'تنين': 2, 'اثن': 2, 'اثنا': 2, 'اثني': 2, 'ثنينهم': 2, 'ثني': 2, 'اتنين': 2,
    'ثلاثه': 3, 'ثلاث': 3, 'تلاثه': 3, 'تلاث': 3, 'تلت': 3, 'ثلث': 3, 'ثلاثت': 3, 'تلاثت': 3, 'تلاته': 3, 'تلات': 3, 'ثلاثا': 3,
    'اربعه': 4, 'اربع': 4, 'اربعاه': 4, 'اربعت': 4, 'ربعه': 4, 'ربع': 4, 'اربعا': 4, 'اربعن': 4,
    'خمسه': 5, 'خمس': 5, 'خمست': 5, 'خمسا': 5, 'خمسن': 5, 'خمساه': 5,
    'سته': 6, 'ست': 6, 'ستت': 6, 'ستا': 6, 'ستاه': 6, 'ستن': 6, 'سيت': 6,
    'سبعه': 7, 'سبع': 7, 'سبعت': 7, 'سبعا': 7, 'سبعن': 7, 'سبعاه': 7,
    'ثمانيه': 8, 'ثماني': 8, 'ثمان': 8, 'تمانيه': 8, 'تماني': 8, 'تمان': 8,
    'ثمنيه': 8, 'ثمن': 8, 'تمن': 8, 'ثمانيت': 8, 'اثمانيه': 8, 'اثمان': 8, 'ثمانيا': 8, 'فمانيه': 8, 'فمان': 8,
    'تسعه': 9, 'تسع': 9, 'تسعت': 9, 'تسعا': 9, 'اتسعه': 9, 'تسعن': 9, 'تسعاه': 9,
    'عشره': 10, 'عشر': 10, 'عشرت': 10, 'عشرا': 10,
    'احدعشر': 11, 'احدعش': 11, 'حدعش': 11, 'اهدعش': 11, 'ادعش': 11, 'حداشر': 11, 'احداشر': 11, 'دعش': 11, 'يدعش': 11, 'اهدعشر': 11,
    'اثناعشر': 12, 'اثنعشر': 12, 'اثنعش': 12, 'ثنعش': 12, 'طنعش': 12, 'اتنعش': 12, 'اثناشر': 12, 'اتناشر': 12, 'صنعش': 12, 'ضنعش': 12,
    'ثلاثهعشر': 13, 'ثلاثعشر': 13, 'ثلطعش': 13, 'تلطعش': 13, 'ثلثطعش': 13, 'تلتطعش': 13, 'تلتاشر': 13, 'ثلاثطعش': 13, 'تلاثطعش': 13, 'تلطاش': 13, 'ثلطاش': 13,
    'اربعهعشر': 14, 'اربععشر': 14, 'اربعطعش': 14, 'اربعتعش': 14, 'اربعتاشر': 14, 'ربعطعش': 14, 'اربعطاش': 14, 'ربعطاش': 14,
    'خمسهعشر': 15, 'خمسعشر': 15, 'خمسطعش': 15, 'خمستعش': 15, 'خمستاشر': 15, 'خمسطاش': 15, 'خمستاش': 15,
    'ستهعشر': 16, 'ستعشر': 16, 'ستطعش': 16, 'ستعش': 16, 'ستاشر': 16, 'سطعش': 16, 'صطعش': 16, 'ستطاش': 16, 'سطاش': 16,
    'سبعهعشر': 17, 'سبععشر': 17, 'سبعطعش': 17, 'سبعتعش': 17, 'سبعتاشر': 17, 'سبعطاش': 17, 'سبعتاش': 17,
    'ثمانيهعشر': 18, 'ثمانعشر': 18, 'ثمنطعش': 18, 'تمنطعش': 18, 'ثمانطعش': 18, 'تمانطعش': 18, 'تمنتاشر': 18, 'اثمنطعش': 18, 'ثمنطاش': 18, 'تمنطاش': 18, 'فمنطعش': 18,
    'تسعهعشر': 19, 'تسععشر': 19, 'تسعطعش': 19, 'تسعتعش': 19, 'تسعتاشر': 19, 'تسعطاش': 19, 'تسعتاش': 19,
    'عشرين': 20, 'عشرون': 20, 'عشرن': 20,
    'ثلاثين': 30, 'ثلاثون': 30, 'تلاثين': 30, 'تلاتين': 30, 'ثلاثينا': 30, 'تلثين': 30, 'ثلثين': 30,
    'اربعين': 40, 'اربعون': 40, 'ربعين': 40,
    'خمسين': 50, 'خمسون': 50,
    'ستين': 60, 'ستون': 60,
    'سبعين': 70, 'سبعون': 70,
    'ثمانين': 80, 'ثمانون': 80, 'تمانين': 80, 'ثمنين': 80, 'تمنين': 80, 'اثمانين': 80, 'فمانين': 80,
    'تسعين': 90, 'تسعون': 90, 'اتسعين': 90,
    'مئه': 100, 'مائه': 100, 'ميه': 100, 'ميت': 100, 'مايه': 100, 'ميا': 100,
    'مئتين': 200, 'مائتين': 200, 'ميتين': 200, 'مئتان': 200, 'مائتان': 200, 'ميتن': 200,
    'ثلاثمئه': 300, 'ثلاثمائه': 300, 'تلثميه': 300, 'ثلثميه': 300, 'تلاثميه': 300, 'ثلاثميه': 300, 'تلتمايه': 300,
    'اربعمئه': 400, 'اربعمائه': 400, 'اربعميه': 400, 'ربعميه': 400, 'اربعمايه': 400,
    'خمسمئه': 500, 'خمسمائه': 500, 'خمسميه': 500, 'خمسمايه': 500,
    'ستمئه': 600, 'ستمائه': 600, 'ستميه': 600, 'ستمايه': 600,
    'سبعمئه': 700, 'سبعمائه': 700, 'سبعميه': 700, 'سبعمايه': 700,
    'ثمانمئه': 800, 'ثمانمائه': 800, 'ثمنميه': 800, 'تمنميه': 800, 'ثمانميه': 800, 'تمانميه': 800,
    'تسعمئه': 900, 'تسعمائه': 900, 'تسعميه': 900, 'تسعمايه': 900,
    'الف': 1000, 'الاف': 1000, 'آلاف': 1000,
    'الفين': 2000, 'الفان': 2000,
  };

  static const Map<String, String> _multiZeroMap = {
    'صفرين': '00', 'وصفرين': '00', 'دبلصفر': '00', 'سفرين': '00',
    'ثلاثاصفار': '000', 'تلاثاصفار': '000', 'ثلثاصفار': '000', 'تريبلصفر': '000',
    'اربعاصفار': '0000',
  };

  static int? _fuzzyLookupIraqiNumber(String cleanToken) {
    if (!voiceIraqiFastDigitsMode || cleanToken.length < 3) return null;
    final tokenSkel = _phoneticSkeleton(cleanToken);

    for (final entry in _iraqiSpokenNumbersMap.entries) {
      if (_phoneticSkeleton(entry.key) == tokenSkel) {
        return entry.value;
      }
    }

    if (cleanToken.length >= 4) {
      int bestDist = 99;
      int? bestVal;
      for (final entry in _iraqiSpokenNumbersMap.entries) {
        if ((entry.key.length - cleanToken.length).abs() > 1) continue;
        final d = _levenshteinDistance(tokenSkel, _phoneticSkeleton(entry.key));
        if (d < bestDist) {
          bestDist = d;
          bestVal = entry.value;
        }
      }
      if (bestDist <= 1) return bestVal;
    }
    return null;
  }

  static int? _lookupIraqiNumberWord(String rawToken) {
    var token = _normalizeIraqiNumberToken(rawToken);
    if (token.isEmpty) return null;
    if (_iraqiSpokenNumbersMap.containsKey(token)) {
      return _iraqiSpokenNumbersMap[token];
    }
    if (token.startsWith('و') && token.length > 1) {
      final withoutWaw = token.substring(1);
      if (_iraqiSpokenNumbersMap.containsKey(withoutWaw)) {
        return _iraqiSpokenNumbersMap[withoutWaw];
      }
      if (withoutWaw.startsWith('ال') && withoutWaw.length > 2) {
        final withoutAl = withoutWaw.substring(2);
        if (_iraqiSpokenNumbersMap.containsKey(withoutAl)) {
          return _iraqiSpokenNumbersMap[withoutAl];
        }
      }
      final fuzzyNoWaw = _fuzzyLookupIraqiNumber(withoutWaw);
      if (fuzzyNoWaw != null) return fuzzyNoWaw;
    }
    if (token.startsWith('ال') && token.length > 2) {
      final withoutAl = token.substring(2);
      if (_iraqiSpokenNumbersMap.containsKey(withoutAl)) {
        return _iraqiSpokenNumbersMap[withoutAl];
      }
      final fuzzyNoAl = _fuzzyLookupIraqiNumber(withoutAl);
      if (fuzzyNoAl != null) return fuzzyNoAl;
    }
    return _fuzzyLookupIraqiNumber(token);
  }

  static List<int>? _trySplitConcatenatedIraqiDigits(String normToken) {
    if (!voiceIraqiFastDigitsMode || normToken.length < 4) return null;
    var clean = normToken;
    if (clean.startsWith('و') &&
        clean.length > 3 &&
        !clean.startsWith('واحد') &&
        !clean.startsWith('وحد')) {
      clean = clean.substring(1);
    }

    final result = <int>[];
    var remaining = clean;
    final sortedKeys = _iraqiSpokenNumbersMap.keys.toList()
      ..sort((a, b) => b.length.compareTo(a.length));

    int safety = 0;
    while (remaining.isNotEmpty && safety++ < 16) {
      if (remaining.startsWith('و') &&
          remaining.length > 2 &&
          !remaining.startsWith('واحد') &&
          !remaining.startsWith('وحد')) {
        remaining = remaining.substring(1);
      }
      String? matchedKey;
      for (final k in sortedKeys) {
        if (k.length >= 2 && remaining.startsWith(k)) {
          matchedKey = k;
          break;
        }
      }
      if (matchedKey == null) return null;
      result.add(_iraqiSpokenNumbersMap[matchedKey]!);
      remaining = remaining.substring(matchedKey.length);
    }
    return result.length >= 2 ? result : null;
  }

  static String extractSpokenDigits(
    String rawSpeech, {
    bool allowGradeMarks = false,
  }) {
    final trimmed = rawSpeech.trim();
    if (trimmed.isEmpty) return '';

    if (allowGradeMarks) {
      final norm = _normalizeIraqiNumberToken(trimmed);
      if (trimmed == 'م' ||
          norm == 'م' ||
          norm == 'ميم' ||
          norm == 'مجاز' ||
          norm == 'معفي' ||
          norm == 'مؤجل') {
        return 'م';
      }
      if (trimmed == 'غ' ||
          norm == 'غ' ||
          norm == 'غين' ||
          norm == 'غائب' ||
          norm == 'غايب') {
        return 'غ';
      }
    }

    var prepared = normalizeDigitsOnly(trimmed);
    prepared = prepared
        .replaceAll(RegExp(r'[,[,،;؛.\-_/\\|]+'), ' ')
        .replaceAllMapped(
            RegExp(r'(\d+)([^\d\s]+)'), (m) => '${m.group(1)} ${m.group(2)}')
        .replaceAllMapped(
            RegExp(r'([^\d\s]+)(\d+)'), (m) => '${m.group(1)} ${m.group(2)}');

    final rawTokens =
        prepared.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
    if (rawTokens.isEmpty) return '';

    final tokens = <_ParsedNumToken>[];

    for (var i = 0; i < rawTokens.length; i++) {
      final raw = rawTokens[i];
      final cleanDigits = raw.replaceAll(RegExp(r'[^0-9]'), '');

      if (cleanDigits.isNotEmpty &&
          cleanDigits.length ==
              _normalizeIraqiNumberToken(raw)
                  .replaceAll(RegExp(r'[^0-9]'), '')
                  .length &&
          _lookupIraqiNumberWord(raw) == null) {
        tokens.add(_ParsedNumToken.digits(cleanDigits));
        continue;
      }

      var norm = _normalizeIraqiNumberToken(raw);
      if (norm.isEmpty) continue;

      if (norm == 'و') {
        tokens.add(_ParsedNumToken.conjunction());
        continue;
      }

      if (_multiZeroMap.containsKey(norm)) {
        tokens.add(_ParsedNumToken.digits(_multiZeroMap[norm]!));
        continue;
      }

      if (norm == 'دبل' ||
          norm == 'ودبل' ||
          norm == 'مرتين' ||
          norm == 'مكرر') {
        tokens.add(_ParsedNumToken.multiplier(2));
        continue;
      }
      if (norm == 'تريبل' || norm == 'ثلاثمرات' || norm == 'تلاثمرات') {
        tokens.add(_ParsedNumToken.multiplier(3));
        continue;
      }

      bool hadLeadingWaw = false;
      if (norm.startsWith('و') &&
          norm.length > 1 &&
          !const {'واحد', 'واحده', 'وحده', 'وحد', 'واحدن', 'وحدة'}
              .contains(norm)) {
        final afterWaw = norm.substring(1);
        if (_lookupIraqiNumberWord(afterWaw) != null) {
          hadLeadingWaw = true;
          norm = afterWaw;
        }
      }

      if (i + 1 < rawTokens.length) {
        final nextNorm = _normalizeIraqiNumberToken(rawTokens[i + 1]);
        final combined = '$norm$nextNorm';
        if (_multiZeroMap.containsKey(combined)) {
          tokens.add(_ParsedNumToken.digits(_multiZeroMap[combined]!));
          i++;
          continue;
        }
        final combinedVal = _lookupIraqiNumberWord(combined);
        if (combinedVal != null) {
          if (hadLeadingWaw) tokens.add(_ParsedNumToken.conjunction());
          tokens.add(_ParsedNumToken.wordValue(combinedVal));
          i++;
          continue;
        }
      }

      final wordVal = _lookupIraqiNumberWord(norm);
      if (wordVal != null) {
        if (hadLeadingWaw) tokens.add(_ParsedNumToken.conjunction());
        tokens.add(_ParsedNumToken.wordValue(wordVal));
        continue;
      }

      final splitVals = _trySplitConcatenatedIraqiDigits(norm);
      if (splitVals != null && splitVals.isNotEmpty) {
        for (final sv in splitVals) {
          tokens.add(_ParsedNumToken.wordValue(sv));
        }
        continue;
      }

      if (cleanDigits.isNotEmpty) {
        tokens.add(_ParsedNumToken.digits(cleanDigits));
      }
    }

    final out = StringBuffer();
    int idx = 0;

    while (idx < tokens.length) {
      final current = tokens[idx];

      if (current.isConjunction) {
        idx++;
        continue;
      }

      if (current.isMultiplier) {
        final repeat = current.multiplier;
        if (idx + 1 < tokens.length) {
          final nextTok = tokens[idx + 1];
          final nextStr = nextTok.isDigits
              ? nextTok.digits
              : (nextTok.isWordValue ? '${nextTok.wordValue}' : '');
          if (nextStr.isNotEmpty) {
            for (int r = 0; r < repeat; r++) {
              out.write(nextStr);
            }
            idx += 2;
            continue;
          }
        }
        idx++;
        continue;
      }

      if (current.isDigits) {
        final parsedInt = int.tryParse(current.digits);
        if (parsedInt != null &&
            parsedInt >= 1 &&
            parsedInt <= 9 &&
            current.digits.length == 1 &&
            idx + 2 < tokens.length &&
            tokens[idx + 1].isConjunction) {
          final afterConj = tokens[idx + 2];
          final tensVal = afterConj.isWordValue
              ? afterConj.wordValue
              : (afterConj.isDigits ? int.tryParse(afterConj.digits) : null);
          if (tensVal != null &&
              tensVal >= 20 &&
              tensVal <= 90 &&
              tensVal % 10 == 0) {
            out.write('${tensVal + parsedInt}');
            idx += 3;
            continue;
          }
        }
        out.write(current.digits);
        idx++;
        continue;
      }

      if (current.isWordValue) {
        final v = current.wordValue;

        if (v == 1000 || v == 2000) {
          int total = v;
          int look = idx + 1;
          bool consumedMore = false;

          if (look < tokens.length && tokens[look].isConjunction) {
            look++;
          }
          if (look < tokens.length &&
              tokens[look].isWordValue &&
              tokens[look].wordValue >= 100 &&
              tokens[look].wordValue <= 900) {
            total += tokens[look].wordValue;
            look++;
            consumedMore = true;
          }
          int afterHundred = look;
          if (afterHundred < tokens.length &&
              tokens[afterHundred].isConjunction) {
            afterHundred++;
          }
          if (afterHundred < tokens.length &&
              tokens[afterHundred].isWordValue) {
            final secondVal = tokens[afterHundred].wordValue;
            if (secondVal >= 1 &&
                secondVal <= 9 &&
                afterHundred + 2 < tokens.length &&
                tokens[afterHundred + 1].isConjunction &&
                tokens[afterHundred + 2].isWordValue) {
              final thirdVal = tokens[afterHundred + 2].wordValue;
              if (thirdVal >= 20 && thirdVal <= 90 && thirdVal % 10 == 0) {
                total += thirdVal + secondVal;
                idx = afterHundred + 3;
                out.write('$total');
                continue;
              }
            }
            if (secondVal >= 1 && secondVal <= 99 && consumedMore) {
              total += secondVal;
              idx = afterHundred + 1;
              out.write('$total');
              continue;
            }
          }
          if (consumedMore) {
            out.write('$total');
            idx = look;
            continue;
          }
        }

        if (v >= 100 && v <= 900 && v % 100 == 0) {
          int nextIdx = idx + 1;
          if (nextIdx < tokens.length && tokens[nextIdx].isConjunction) {
            nextIdx++;
            if (nextIdx < tokens.length && tokens[nextIdx].isWordValue) {
              final secondVal = tokens[nextIdx].wordValue;
              if (secondVal >= 1 &&
                  secondVal <= 9 &&
                  nextIdx + 2 < tokens.length &&
                  tokens[nextIdx + 1].isConjunction &&
                  tokens[nextIdx + 2].isWordValue) {
                final thirdVal = tokens[nextIdx + 2].wordValue;
                if (thirdVal >= 20 && thirdVal <= 90 && thirdVal % 10 == 0) {
                  out.write('${v + thirdVal + secondVal}');
                  idx = nextIdx + 3;
                  continue;
                }
              }
              if (secondVal >= 1 && secondVal <= 99) {
                out.write('${v + secondVal}');
                idx = nextIdx + 1;
                continue;
              }
            }
          }
        }

        if (v >= 1 && v <= 9) {
          if (idx + 2 < tokens.length &&
              tokens[idx + 1].isConjunction &&
              (tokens[idx + 2].isWordValue || tokens[idx + 2].isDigits)) {
            final nextTok = tokens[idx + 2];
            final tens = nextTok.isWordValue
                ? nextTok.wordValue
                : (int.tryParse(nextTok.digits) ?? -1);
            if (tens >= 20 && tens <= 90 && tens % 10 == 0) {
              out.write('${tens + v}');
              idx += 3;
              continue;
            }
          }
        }

        out.write('$v');
        idx++;
        continue;
      }

      idx++;
    }

    return out.toString();
  }

  static String extractBestSpokenNumber(
    List<String> candidates, {
    bool allowGradeMarks = false,
    bool preferSingleNumber = false,
    int? targetLength,
  }) {
    String bestResult = '';
    for (final raw in candidates) {
      if (raw.trim().isEmpty) continue;
      final extracted = extractSpokenDigits(
        raw,
        allowGradeMarks: allowGradeMarks,
      );
      if (extracted.isEmpty) continue;
      if (allowGradeMarks && (extracted == 'م' || extracted == 'غ')) {
        return extracted;
      }
      if (preferSingleNumber) {
        return extracted;
      }
      if (targetLength != null && extracted.length == targetLength) {
        return extracted;
      }
      if (extracted.length > bestResult.length) {
        bestResult = extracted;
      }
    }
    return bestResult;
  }

  static String mergeAccumulatedDigits(
      String previousDigits, String newSegmentDigits) {
    final prev = previousDigits.trim();
    final next = newSegmentDigits.trim();
    if (prev.isEmpty) return next;
    if (next.isEmpty) return prev;
    if (prev == next) return prev;
    if (next.startsWith(prev)) return next;
    if (prev.startsWith(next)) return prev;
    final maxOverlap = prev.length < next.length ? prev.length : next.length;
    for (var overlap = maxOverlap; overlap > 0; overlap--) {
      if (prev.substring(prev.length - overlap) == next.substring(0, overlap)) {
        return prev + next.substring(overlap);
      }
    }
    return '$prev$next';
  }

  static bool _initialized = false;

  static Future<File?> _getSettingsFile() async {
    final candidates = <String>[];
    try {
      final supportDir = await getApplicationSupportDirectory();
      candidates.add('${supportDir.path}${Platform.pathSeparator}emis_app_settings.json');
    } catch (_) {}

    try {
      final tempPath = Directory.systemTemp.path;
      final cacheIdx = tempPath.indexOf('/cache');
      if (cacheIdx > 0) {
        final baseAppDir = tempPath.substring(0, cacheIdx);
        candidates.add('$baseAppDir/app_flutter/emis_app_settings.json');
        candidates.add('$baseAppDir/files/emis_app_settings.json');
      }
      candidates.add('$tempPath${Platform.pathSeparator}emis_app_settings.json');
    } catch (_) {}

    for (final path in candidates) {
      try {
        final file = File(path);
        final parent = file.parent;
        if (!await parent.exists()) {
          await parent.create(recursive: true);
        }
        return file;
      } catch (_) {}
    }
    return null;
  }

  static Future<Map<String, dynamic>> _readLocalStore() async {
    final merged = <String, dynamic>{};

    try {
      final prefs = await SharedPreferences.getInstance()
          .timeout(const Duration(milliseconds: 1200));
      final rawJson = prefs.getString('emis_all_settings_v2');
      if (rawJson != null && rawJson.isNotEmpty) {
        final decoded = jsonDecode(rawJson);
        if (decoded is Map) {
          merged.addAll(Map<String, dynamic>.from(decoded));
        }
      }
      if (prefs.containsKey('emis_theme_is_dark')) {
        merged['isDark'] = prefs.getBool('emis_theme_is_dark');
      } else if (prefs.containsKey('isDark')) {
        merged['isDark'] = prefs.getBool('isDark');
      }
      for (final key in prefs.getKeys()) {
        if (key != 'emis_all_settings_v2' && key != 'emis_theme_is_dark') {
          merged[key] = prefs.get(key);
        }
      }
    } catch (_) {}

    try {
      final file = await _getSettingsFile();
      if (file != null && await file.exists()) {
        final content = await file.readAsString();
        final decoded = jsonDecode(content);
        if (decoded is Map) {
          merged.addAll(Map<String, dynamic>.from(decoded));
        }
      }
    } catch (e) {
      debugPrint('Local settings file read warning: $e');
    }

    return merged;
  }

  static Future<void> _writeLocalStore() async {
    final isDark = themeNotifier.value == ThemeMode.dark;
    final data = <String, dynamic>{
      'isDark': isDark,
      'isAudioMuted': isAudioMuted,
      'currentVolume': currentVolume,
      'voiceInputEnabled': voiceInputEnabled,
      'aiAssistantEnabled': aiAssistantEnabled,
      'voiceSequentialAutoStart': voiceSequentialAutoStart,
      'centralKeyboardNavigationEnabled': centralKeyboardNavigationEnabled,
      'voiceRecognitionEngine': voiceRecognitionEngine,
      'voiceAutoRestart': voiceAutoRestart,
      'voicePossibleSilenceMs': voicePossibleSilenceMs,
      'voiceCompleteSilenceMs': voiceCompleteSilenceMs,
      'voiceMinimumSpeechMs': voiceMinimumSpeechMs,
      'voiceRestartDelayMs': voiceRestartDelayMs,
      'voiceFinalizationTimeoutMs': voiceFinalizationTimeoutMs,
      'voiceArrowOpacity': voiceArrowOpacity,
      'voiceArrowLeft': voiceArrowLeft,
      'voiceArrowTop': voiceArrowTop,
      'voiceMuteIntermediateBeeps': voiceMuteIntermediateBeeps,
      'voiceContinuousSingleSession': voiceContinuousSingleSession,
      'voiceIraqiFastDigitsMode': voiceIraqiFastDigitsMode,
      'voiceAutoStopOnTargetLength': voiceAutoStopOnTargetLength,
      'defaultGender': defaultGender,
      'defaultStudentStageId': defaultStudentStageId,
      'defaultStudentClassRoomId': defaultStudentClassRoomId,
      'defaultCountry': defaultCountry,
      'defaultGovernorate': defaultGovernorate,
      'defaultDistrict': defaultDistrict,
      'defaultTown': defaultTown,
      'defaultArea': defaultArea,
      'defaultHomeTown': defaultHomeTown,
      'defaultIdType': defaultIdType,
      'defaultMotherTongue': defaultMotherTongue,
      'defaultStudyLanguage': defaultStudyLanguage,
      'defaultReligion': defaultReligion,
      'defaultBloodGroup': defaultBloodGroup,
      'defaultEconomicLevel': defaultEconomicLevel,
      'defaultAddress1': defaultAddress1,
      'defaultAddress2': defaultAddress2,
      'defaultClosestLocation': defaultClosestLocation,
      'defaultTeacherStatus': defaultTeacherStatus,
      'defaultEmployeeCategory': defaultEmployeeCategory,
      'defaultEmploymentType': defaultEmploymentType,
      'defaultClassification': defaultClassification,
      'defaultCurrentPosition': defaultCurrentPosition,
      'defaultEducationLevel': defaultEducationLevel,
    };

    final encoded = jsonEncode(data);

    try {
      final file = await _getSettingsFile();
      if (file != null) {
        await file.writeAsString(encoded, flush: true);
      }
    } catch (e) {
      debugPrint('Local settings file write warning: $e');
    }

    try {
      final prefs = await SharedPreferences.getInstance()
          .timeout(const Duration(milliseconds: 1200));
      await prefs.setBool('emis_theme_is_dark', isDark);
      await prefs.setBool('isDark', isDark);
      await prefs.setBool('voiceInputEnabled', voiceInputEnabled);
      await prefs.setBool('aiAssistantEnabled', aiAssistantEnabled);
      await prefs.setBool('voiceSequentialAutoStart', voiceSequentialAutoStart);
      await prefs.setBool(
          'centralKeyboardNavigationEnabled', centralKeyboardNavigationEnabled);
      await prefs.setString('voiceRecognitionEngine', voiceRecognitionEngine);
      await prefs.setBool('voiceAutoRestart', voiceAutoRestart);
      await prefs.setInt('voicePossibleSilenceMs', voicePossibleSilenceMs);
      await prefs.setInt('voiceCompleteSilenceMs', voiceCompleteSilenceMs);
      await prefs.setInt('voiceMinimumSpeechMs', voiceMinimumSpeechMs);
      await prefs.setInt('voiceRestartDelayMs', voiceRestartDelayMs);
      await prefs.setInt(
          'voiceFinalizationTimeoutMs', voiceFinalizationTimeoutMs);
      await prefs.setDouble('voiceArrowOpacity', voiceArrowOpacity);
      await prefs.setString('emis_all_settings_v2', encoded);
    } catch (e) {
      debugPrint('SharedPreferences write warning: $e');
    }
  }

  static Future<void> ensureLoaded() async {
    if (_initialized) return;
    await initPreferences();
  }

  static Future<void> initPreferences() async {
    _preferences ??= await SharedPreferences.getInstance();
    final data = await _readLocalStore();
    _initialized = true;

    if (data.isNotEmpty) {
      final isDark = data['isDark'] == true;
      themeNotifier.value = isDark ? ThemeMode.dark : ThemeMode.light;

      if (data['isAudioMuted'] is bool) {
        isAudioMuted = data['isAudioMuted'] as bool;
      }
      if (data['currentVolume'] is num) {
        currentVolume = (data['currentVolume'] as num).toDouble();
      }
      if (data['voiceInputEnabled'] is bool) {
        voiceInputEnabled = data['voiceInputEnabled'] as bool;
      }
      if (kLocalAiBuildEnabled) {
        aiAssistantEnabled = data['aiAssistantEnabled'] == true;
      } else {
        aiAssistantEnabled = false;
        aiAssistantAvailableNotifier.value = false;
      }
      aiAssistantEnabledNotifier.value = aiAssistantEnabled;
      if (data['voiceSequentialAutoStart'] is bool) {
        voiceSequentialAutoStart = data['voiceSequentialAutoStart'] as bool;
      }
      if (data['centralKeyboardNavigationEnabled'] is bool) {
        centralKeyboardNavigationEnabled =
            data['centralKeyboardNavigationEnabled'] as bool;
      }
      if (data['voiceRecognitionEngine'] is String) {
        voiceRecognitionEngine =
            data['voiceRecognitionEngine'] == 'legacy' ? 'legacy' : 'google';
      } else {
        voiceRecognitionEngine = 'google';
      }
      if (data['voiceAutoRestart'] is bool) {
        voiceAutoRestart = data['voiceAutoRestart'] as bool;
      }
      if (data['voicePossibleSilenceMs'] is num) {
        voicePossibleSilenceMs =
            (data['voicePossibleSilenceMs'] as num).toInt().clamp(1000, 90000);
      }
      if (data['voiceCompleteSilenceMs'] is num) {
        voiceCompleteSilenceMs =
            (data['voiceCompleteSilenceMs'] as num).toInt().clamp(1000, 90000);
      }
      if (data['voiceMinimumSpeechMs'] is num) {
        voiceMinimumSpeechMs =
            (data['voiceMinimumSpeechMs'] as num).toInt().clamp(100, 9000);
      }
      if (data['voiceRestartDelayMs'] is num) {
        voiceRestartDelayMs =
            (data['voiceRestartDelayMs'] as num).toInt().clamp(0, 5000);
      }
      if (data['voiceFinalizationTimeoutMs'] is num) {
        voiceFinalizationTimeoutMs = (data['voiceFinalizationTimeoutMs'] as num)
            .toInt()
            .clamp(500, 10000);
      }
      if (data['voiceArrowOpacity'] is num) {
        voiceArrowOpacity =
            (data['voiceArrowOpacity'] as num).toDouble().clamp(0.20, 0.90);
      }
      if (data['voiceArrowLeft'] is num) {
        voiceArrowLeft = (data['voiceArrowLeft'] as num).toDouble();
      }
      if (data['voiceArrowTop'] is num) {
        voiceArrowTop = (data['voiceArrowTop'] as num).toDouble();
      }
      if (data['voiceMuteIntermediateBeeps'] is bool) {
        voiceMuteIntermediateBeeps = data['voiceMuteIntermediateBeeps'] as bool;
      }
      if (data['voiceContinuousSingleSession'] is bool) {
        voiceContinuousSingleSession =
            data['voiceContinuousSingleSession'] as bool;
      }
      if (data['voiceIraqiFastDigitsMode'] is bool) {
        voiceIraqiFastDigitsMode = data['voiceIraqiFastDigitsMode'] as bool;
      }
      if (data['voiceAutoStopOnTargetLength'] is bool) {
        voiceAutoStopOnTargetLength =
            data['voiceAutoStopOnTargetLength'] as bool;
      }

      defaultGender = (data['defaultGender'] ?? '1').toString();
      defaultStudentStageId = (data['defaultStudentStageId'] ?? '').toString();
      defaultStudentClassRoomId =
          (data['defaultStudentClassRoomId'] ?? '').toString();
      defaultCountry = (data['defaultCountry'] ?? 'العراق').toString();
      defaultGovernorate =
          (data['defaultGovernorate'] ?? 'القادسية').toString();
      defaultDistrict = (data['defaultDistrict'] ?? 'الديوانية').toString();
      defaultTown = (data['defaultTown'] ?? 'الديوانية').toString();
      defaultArea = (data['defaultArea'] ?? '').toString();
      defaultHomeTown = (data['defaultHomeTown'] ?? '').toString();
      defaultIdType = (data['defaultIdType'] ?? '12').toString();
      defaultMotherTongue =
          (data['defaultMotherTongue'] ?? 'العربية').toString();
      defaultStudyLanguage =
          (data['defaultStudyLanguage'] ?? 'العربية').toString();
      defaultReligion = (data['defaultReligion'] ?? 'الإسلام').toString();
      defaultBloodGroup = (data['defaultBloodGroup'] ?? 'O+').toString();
      defaultEconomicLevel =
          (data['defaultEconomicLevel'] ?? 'الطبقة الوسطى').toString();
      defaultAddress1 = (data['defaultAddress1'] ?? '0').toString();
      defaultAddress2 = (data['defaultAddress2'] ?? '0').toString();
      defaultClosestLocation =
          (data['defaultClosestLocation'] ?? '0').toString();

      defaultTeacherStatus =
          (data['defaultTeacherStatus'] ?? 'مستمر').toString();
      defaultEmployeeCategory =
          (data['defaultEmployeeCategory'] ?? 'تدريسي').toString();
      defaultEmploymentType =
          (data['defaultEmploymentType'] ?? 'ملاك').toString();
      defaultClassification =
          (data['defaultClassification'] ?? 'معلم').toString();
      defaultCurrentPosition =
          (data['defaultCurrentPosition'] ?? 'مدرس').toString();
      defaultEducationLevel =
          (data['defaultEducationLevel'] ?? 'بكالوريوس').toString();
    }

    unawaited(GoogleSpeechService.syncLiveSettings());

    try {
      await audioPlayer
          .setVolume(currentVolume)
          .timeout(const Duration(seconds: 1));
      if (!isAudioMuted) {
        unawaited(playRelaxMusic());
      } else {
        await audioPlayer.stop().timeout(const Duration(seconds: 1));
      }
    } catch (e) {
      debugPrint('Audio init error: $e');
    }
  }

  static void _notifyVoiceSettingsChanged() {
    voiceSettingsRevision.value++;
    unawaited(GoogleSpeechService.syncLiveSettings());
  }

  static Future<void> setCentralKeyboardNavigationEnabled(bool enabled) async {
    await ensureLoaded();
    centralKeyboardNavigationEnabled = enabled;
    await _writeLocalStore();
    _notifyVoiceSettingsChanged();
  }

  static Future<void> saveDefaultFieldValues({
    String? gender,
    String? studentStageId,
    String? studentClassRoomId,
    String? country,
    String? governorate,
    String? district,
    String? town,
    String? area,
    String? homeTown,
    String? idType,
    String? motherTongue,
    String? studyLanguage,
    String? religion,
    String? bloodGroup,
    String? economicLevel,
    String? address1,
    String? address2,
    String? closestLocation,
    String? teacherStatus,
    String? employeeCategory,
    String? employmentType,
    String? classification,
    String? currentPosition,
    String? educationLevel,
  }) async {
    await ensureLoaded();
    if (gender != null) defaultGender = gender;
    if (studentStageId != null) defaultStudentStageId = studentStageId.trim();
    if (studentClassRoomId != null) {
      defaultStudentClassRoomId = studentClassRoomId.trim();
    }
    if (country != null) defaultCountry = country.trim();
    if (governorate != null) defaultGovernorate = governorate.trim();
    if (district != null) defaultDistrict = district.trim();
    if (town != null) defaultTown = town.trim();
    if (area != null) defaultArea = area.trim();
    if (homeTown != null) defaultHomeTown = homeTown.trim();
    if (idType != null) defaultIdType = idType;
    if (motherTongue != null) defaultMotherTongue = motherTongue;
    if (studyLanguage != null) defaultStudyLanguage = studyLanguage;
    if (religion != null) defaultReligion = religion;
    if (bloodGroup != null) defaultBloodGroup = bloodGroup;
    if (economicLevel != null) defaultEconomicLevel = economicLevel;
    if (address1 != null) defaultAddress1 = address1.trim();
    if (address2 != null) defaultAddress2 = address2.trim();
    if (closestLocation != null) defaultClosestLocation = closestLocation.trim();
    if (teacherStatus != null) defaultTeacherStatus = teacherStatus;
    if (employeeCategory != null) defaultEmployeeCategory = employeeCategory;
    if (employmentType != null) defaultEmploymentType = employmentType;
    if (classification != null) defaultClassification = classification;
    if (currentPosition != null) defaultCurrentPosition = currentPosition;
    if (educationLevel != null) defaultEducationLevel = educationLevel;

    await _writeLocalStore();
    _notifyVoiceSettingsChanged();
  }

  static Future<void> resetDefaultFieldValues() async {
    defaultGender = '1';
    defaultStudentStageId = '';
    defaultStudentClassRoomId = '';
    defaultCountry = 'العراق';
    defaultGovernorate = 'القادسية';
    defaultDistrict = 'الديوانية';
    defaultTown = 'الديوانية';
    defaultArea = '';
    defaultHomeTown = '';
    defaultIdType = '12';
    defaultMotherTongue = 'العربية';
    defaultStudyLanguage = 'العربية';
    defaultReligion = 'الإسلام';
    defaultBloodGroup = 'O+';
    defaultEconomicLevel = 'الطبقة الوسطى';
    defaultAddress1 = '0';
    defaultAddress2 = '0';
    defaultClosestLocation = '0';
    defaultTeacherStatus = 'مستمر';
    defaultEmployeeCategory = 'تدريسي';
    defaultEmploymentType = 'ملاك';
    defaultClassification = 'معلم';
    defaultCurrentPosition = 'مدرس';
    defaultEducationLevel = 'بكالوريوس';

    await _writeLocalStore();
    _notifyVoiceSettingsChanged();
  }

  static Future<void> saveThemePreference(bool isDark) async {
    themeNotifier.value = isDark ? ThemeMode.dark : ThemeMode.light;
    await ensureLoaded();
    themeNotifier.value = isDark ? ThemeMode.dark : ThemeMode.light;
    await _writeLocalStore();
  }

  static Future<void> toggleTheme() async {
    final nextIsDark = themeNotifier.value != ThemeMode.dark;
    await saveThemePreference(nextIsDark);
  }

  static Future<void> playRelaxMusic() async {
    if (isAudioMuted) return;
    try {
      await audioPlayer
          .setReleaseMode(ReleaseMode.loop)
          .timeout(const Duration(seconds: 1));
      if (audioPlayer.state != PlayerState.playing) {
        await audioPlayer
            .play(AssetSource('relax.mp3'))
            .timeout(const Duration(seconds: 2));
        await audioPlayer
            .setVolume(currentVolume)
            .timeout(const Duration(seconds: 1));
      }
    } catch (e) {
      debugPrint('خطأ في تشغيل الموسيقى الهادئة: $e');
    }
  }

  static Future<void> toggleAudio() async {
    await ensureLoaded();
    isAudioMuted = !isAudioMuted;
    try {
      if (isAudioMuted) {
        await audioPlayer.stop().timeout(const Duration(seconds: 1));
      } else {
        unawaited(playRelaxMusic());
      }
    } catch (e) {
      debugPrint('خطأ أثناء تبديل الصوت: $e');
    }
    await _writeLocalStore();
  }

  static Future<void> setVolume(double vol) async {
    await ensureLoaded();
    currentVolume = vol;
    try {
      await audioPlayer
          .setVolume(vol)
          .timeout(const Duration(milliseconds: 500));
    } catch (e) {
      debugPrint('خطأ في ضبط مستوى الصوت: $e');
    }
    await _writeLocalStore();
  }

  static Future<void> setAiAssistantEnabled(bool enabled) async {
    await ensureLoaded();
    if (!kLocalAiBuildEnabled) {
      aiAssistantEnabled = false;
      aiAssistantEnabledNotifier.value = false;
      aiAssistantAvailableNotifier.value = false;
      return;
    }
    aiAssistantEnabled = enabled;
    aiAssistantEnabledNotifier.value = enabled;
    await _writeLocalStore();
  }

  static Future<void> setVoiceInputEnabled(bool enabled) async {
    await ensureLoaded();
    voiceInputEnabled = enabled;
    await _writeLocalStore();
    _notifyVoiceSettingsChanged();
  }

  static Future<void> setVoiceSequentialAutoStart(bool enabled) async {
    await ensureLoaded();
    voiceSequentialAutoStart = enabled;
    await _writeLocalStore();
    _notifyVoiceSettingsChanged();
  }

  static Future<void> setVoiceRecognitionEngine(String engine) async {
    await ensureLoaded();
    final value = engine == 'legacy' ? 'legacy' : 'google';
    voiceRecognitionEngine = value;
    await _writeLocalStore();
    _notifyVoiceSettingsChanged();
  }

  static Future<void> saveVoiceSettings({
    bool? autoRestart,
    int? possibleSilenceMs,
    int? completeSilenceMs,
    int? minimumSpeechMs,
    int? restartDelayMs,
    int? finalizationTimeoutMs,
    double? arrowOpacity,
    double? arrowLeft,
    double? arrowTop,
    bool? muteIntermediateBeeps,
    bool? continuousSingleSession,
    bool? iraqiFastDigitsMode,
    bool? autoStopOnTargetLength,
  }) async {
    await ensureLoaded();
    if (autoRestart != null) voiceAutoRestart = autoRestart;
    if (possibleSilenceMs != null) {
      voicePossibleSilenceMs = possibleSilenceMs.clamp(1000, 90000);
    }
    if (completeSilenceMs != null) {
      voiceCompleteSilenceMs = completeSilenceMs.clamp(1000, 90000);
    }
    if (minimumSpeechMs != null) {
      voiceMinimumSpeechMs = minimumSpeechMs.clamp(100, 9000);
    }
    if (restartDelayMs != null) {
      voiceRestartDelayMs = restartDelayMs.clamp(0, 5000);
    }
    if (finalizationTimeoutMs != null) {
      voiceFinalizationTimeoutMs = finalizationTimeoutMs.clamp(500, 10000);
    }
    if (arrowOpacity != null) {
      voiceArrowOpacity = arrowOpacity.clamp(0.20, 0.90);
    }
    if (arrowLeft != null) voiceArrowLeft = arrowLeft;
    if (arrowTop != null) voiceArrowTop = arrowTop;
    if (muteIntermediateBeeps != null) {
      voiceMuteIntermediateBeeps = muteIntermediateBeeps;
    }
    if (continuousSingleSession != null) {
      voiceContinuousSingleSession = continuousSingleSession;
    }
    if (iraqiFastDigitsMode != null) {
      voiceIraqiFastDigitsMode = iraqiFastDigitsMode;
    }
    if (autoStopOnTargetLength != null) {
      voiceAutoStopOnTargetLength = autoStopOnTargetLength;
    }

    await _writeLocalStore();
    _notifyVoiceSettingsChanged();
  }

  static Future<void> resetVoiceSettings() async {
    await ensureLoaded();
    voiceAutoRestart = false;
    voicePossibleSilenceMs = 23000;
    voiceCompleteSilenceMs = 23000;
    voiceMinimumSpeechMs = 2500;
    voiceRestartDelayMs = 4100;
    voiceFinalizationTimeoutMs = 2400;
    voiceArrowOpacity = 0.25;
    voiceArrowLeft = 0.0;
    voiceArrowTop = null;
    voiceMuteIntermediateBeeps = false;
    voiceContinuousSingleSession = false;
    voiceIraqiFastDigitsMode = true;
    voiceAutoStopOnTargetLength = false;

    await _writeLocalStore();
    _notifyVoiceSettingsChanged();
  }
}

class _ParsedNumToken {
  final String digits;
  final int wordValue;
  final int multiplier;
  final bool isDigits;
  final bool isWordValue;
  final bool isConjunction;
  final bool isMultiplier;

  const _ParsedNumToken._({
    this.digits = '',
    this.wordValue = 0,
    this.multiplier = 1,
    this.isDigits = false,
    this.isWordValue = false,
    this.isConjunction = false,
    this.isMultiplier = false,
  });

  factory _ParsedNumToken.digits(String d) =>
      _ParsedNumToken._(digits: d, isDigits: true);

  factory _ParsedNumToken.wordValue(int v) =>
      _ParsedNumToken._(wordValue: v, isWordValue: true);

  factory _ParsedNumToken.conjunction() =>
      const _ParsedNumToken._(isConjunction: true);

  factory _ParsedNumToken.multiplier(int m) =>
      _ParsedNumToken._(multiplier: m, isMultiplier: true);
}
