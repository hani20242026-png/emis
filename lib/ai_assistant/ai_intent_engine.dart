import '../app_core.dart';
import 'ai_command_parser.dart';
import 'ai_llm_service.dart';

/// Deterministic Iraqi-Arabic extraction is authoritative for names, dates and
/// labelled numbers. The bundled local model may enrich other explicitly
/// mentioned fields, but may not replace parsed values or invent defaults.
class AiIntentEngine {
  final AiLlmService llm;
  AiIntentEngine({AiLlmService? service}) : llm = service ?? AiLlmService.instance;
  bool usedLlmLastTurn = false;

  static const List<String> studentFields = <String>[
    'name', 'fatherName', 'grandFatherName', 'fathersGrandFatherName', 'surName',
    'motherName', 'mothersFatherName', 'mothersGrandFatherName', 'nationalId',
    'idNumber', 'idType', 'issuingCountry', 'dateOfBirth', 'gender', 'nationality',
    'countryOfBirth', 'homeTown', 'motherTongue', 'studyLanguage', 'maritalStatus',
    'bloodGroup', 'religion', 'economicLevel', 'specialNeeds', 'notes',
    'jinsiyaIdNumber', 'issuer', 'recordNumber', 'pageNumber', 'issuingDate',
    'nameOfDocument', 'birthCertificateNumber', 'otherIdNumber', 'fatherIdType',
    'fatherIssuingCountry', 'fatherNationalId', 'fatherIdNumber', 'fatherRecordNumber',
    'fatherPageNumber', 'fatherIssuer', 'fatherBirthCertificateNumber',
    'fatherIssuingDate', 'fatherNameOfDocument', 'fatherOtherIdNumber', 'town',
    'area', 'quarter', 'street', 'address1', 'address2', 'closestLocation',
    'homePhoneNumber', 'addressCountry', 'addressGovernorate', 'addressDistrict',
    'addressTown', 'stageId', 'classRoomId', 'isCoveredBySocialWelfare', 'censusNumber',
  ];

  static const List<String> teacherFields = <String>[
    'name', 'fatherName', 'grandFatherName', 'fathersGrandFatherName', 'surName',
    'motherName', 'mothersFatherName', 'mothersGrandFatherName', 'nationalId',
    'nameOfDocument', 'recordNumber', 'pageNumber', 'issuer', 'issuingDate',
    'employeeIdNumber', 'familyNumber', 'idType', 'issuingCountry', 'dateOfBirth',
    'gender', 'nationality', 'countryOfBirth', 'homeTown', 'motherTongue',
    'maritalStatus', 'bloodGroup', 'religion', 'employmentType', 'employeeCategory',
    'classification', 'jobDesignation', 'positionType', 'employmentGrade',
    'weeklyTeachingQuota', 'dateOfStartWorking', 'currentPosition', 'status',
    'statusDate', 'statusReason', 'assignedEntityName', 'educationLevel',
    'universityName', 'graduationYear', 'specialization', 'specialNeedsInformation',
    'emergencyContactName', 'emergencyContactRelationship',
    'emergencyContactPhoneNumber', 'town', 'area', 'quarter', 'street', 'address1',
    'address2', 'closestLocation', 'mobilePhoneNumber', 'email', 'notes',
    'addressCountry', 'addressGovernorate', 'addressDistrict', 'addressTown',
  ];

  static const Set<String> _teacherDefaultFields = <String>{
    'status', 'employeeCategory', 'employmentType', 'classification',
    'currentPosition', 'educationLevel',
  };

  List<String> _splitForLocalModel(String text) {
    final value = text.trim();
    if (value.length <= 850) return <String>[value];
    final chunks = <String>[];
    var start = 0;
    while (start < value.length) {
      var end = (start + 850).clamp(0, value.length).toInt();
      if (end < value.length) {
        final boundary = value.lastIndexOf(RegExp(r'[،؛.!؟?\n ]'), end);
        if (boundary > start + 500) end = boundary;
      }
      final chunk = value.substring(start, end).trim();
      if (chunk.isNotEmpty) chunks.add(chunk);
      if (end >= value.length) break;
      // A 100-character overlap avoids cutting a spoken label from its value.
      start = (end - 100).clamp(0, value.length).toInt();
    }
    return chunks;
  }

  Future<AiCommand> understand(
    String utterance, {
    AiIntent? activeIntent,
    Map<String, String> currentDraft = const <String, String>{},
  }) async {
    usedLlmLastTurn = false;
    final fallback = AiCommandParser.parse(utterance, activeIntent: activeIntent);

    // Always allow the local model to enrich fields that the deterministic
    // parser did not recognize. Parser values remain authoritative, and every
    // model value is checked against the current utterance before acceptance.
    // This is important for long Iraqi dictation where one sentence may contain
    // many fields but deterministic patterns recognize only a subset.

    final parsedCreationIntent =
        (fallback.intent == AiIntent.addStudent || fallback.intent == AiIntent.addTeacher)
            ? fallback.intent
            : null;
    final targetIntent = activeIntent ?? parsedCreationIntent;

    // Known navigation commands stay deterministic. For an otherwise unknown
    // utterance, the local model may classify only the two supported create flows.
    if (targetIntent == null && fallback.intent != AiIntent.unknown) return fallback;
    if (targetIntent == null && fallback.entities.isNotEmpty) return fallback;

    final isStudent = targetIntent == AiIntent.addStudent;
    final baseAllowed = targetIntent == null
        ? <String>{...studentFields, ...teacherFields}.toList()
        : (isStudent ? studentFields : teacherFields);
    // Defaults are supplied by AppCore/settings and should not be re-extracted
    // or guessed by the small local model.
    final allowed = baseAllowed.where((field) {
      if (AppCore.hasConfiguredDefaultForStudentField(field)) return false;
      if (!isStudent && _teacherDefaultFields.contains(field)) return false;
      return true;
    }).toList();
    final extracted = <String, dynamic>{};
    // Long Iraqi dictation can exceed the compact model's 2048-token context.
    // Split only the LLM enrichment pass into overlapping text windows; the
    // deterministic parser above still receives the complete original text.
    // Overlap protects a field label/value pair that falls across a boundary.
    final chunks = _splitForLocalModel(utterance);
    for (final chunk in chunks) {
      final part = await llm.extractFields(
        utterance: chunk,
        target: targetIntent == null ? 'الطالب أو المعلم' : (isStudent ? 'الطالب' : 'المعلم'),
        // Existing draft is intentionally omitted from model context. The
        // model must extract only what was spoken in this turn, not echo old
        // values or treat defaults as newly dictated information.
        currentDraft: const <String, String>{},
        allowedFields: allowed,
      );
      if (part == null) continue;
      for (final entry in part.entries) {
        if (entry.key == '_intent') {
          extracted.putIfAbsent(entry.key, () => entry.value);
        } else {
          extracted.putIfAbsent(entry.key, () => entry.value);
        }
      }
    }
    if (extracted.isEmpty) return fallback;

    // Deterministic parser output is authoritative for known Iraqi Arabic
    // patterns (spoken dates, phone numbers, names and address numbers).
    // The compact 0.5B local model may omit or misread these values, so it is
    // only allowed to enrich fields that the parser did not already extract.
    final entities = <String, String>{...fallback.entities};
    final rawEntities = extracted;
    final normalizedUtterance = AiCommandParser.normalize(utterance);
    final spokenUtterance = AiCommandParser.spokenNumbers(utterance)
        .replaceAll(RegExp(r'\s+'), '');
    for (final entry in rawEntities.entries) {
      if (entry.key == '_intent') continue;
      if (entry.value is! String || (entry.value as String).trim().isEmpty) {
        continue;
      }
      final candidate = (entry.value as String).trim();
      final normalizedCandidate = AiCommandParser.normalize(candidate);
      final spokenCandidate = AiCommandParser.spokenNumbers(candidate)
          .replaceAll(RegExp(r'\s+'), '');
      // The compact local model may hallucinate values. Accept an enrichment
      // only when its value can be traced to words/digits in this utterance.
      final isGrounded = normalizedCandidate.isNotEmpty &&
              normalizedUtterance.contains(normalizedCandidate) ||
          spokenCandidate.isNotEmpty &&
              spokenUtterance.contains(spokenCandidate);
      if (isGrounded) entities.putIfAbsent(entry.key, () => candidate);
    }

    // Keep settings-provided values in the form. The AI only changes a
    // configured default when the deterministic parser explicitly recognized
    // that field in the user's words; a 0.5B model must not invent defaults.
    final explicitlyParsed = fallback.entities.keys.toSet();
    entities.removeWhere((key, _) {
      final isConfiguredStudentDefault =
          AppCore.hasConfiguredDefaultForStudentField(key);
      final isConfiguredTeacherDefault =
          !isStudent && _teacherDefaultFields.contains(key);
      return (isConfiguredStudentDefault || isConfiguredTeacherDefault) &&
          !explicitlyParsed.contains(key);
    });

    // The active workflow wins over model intent to prevent cross-form writes.
    final modelIntent = extracted['_intent']?.toString();
    final resolvedIntent = targetIntent ?? (modelIntent == 'addStudent'
        ? AiIntent.addStudent
        : modelIntent == 'addTeacher'
            ? AiIntent.addTeacher
            : AiIntent.unknown);
    if (resolvedIntent == AiIntent.unknown) return fallback;
    final expectedName = resolvedIntent == AiIntent.addStudent ? 'addStudent' : 'addTeacher';
    if (modelIntent != null && modelIntent != expectedName && activeIntent == null) {
      return fallback;
    }
    if (entities.isEmpty) return fallback;
    // If intent was discovered by the model, discard fields belonging only to
    // the other form before they reach the screen controller.
    final finalAllowed = resolvedIntent == AiIntent.addStudent ? studentFields : teacherFields;
    entities.removeWhere((key, _) => !finalAllowed.contains(key));
    if (entities.isEmpty) return fallback;
    usedLlmLastTurn = true;
    return AiCommand(resolvedIntent, utterance, entities: entities);
  }
}
