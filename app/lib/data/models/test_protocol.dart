import '../../core/audiometry/audiometry.dart';

/// One ear at one frequency. Used to list frequencies that were added, skipped
/// or retested.
class FrequencyRef {
  const FrequencyRef(this.ear, this.frequencyHz);

  final Ear ear;
  final int frequencyHz;

  Map<String, Object?> toJson() => {'ear': ear.name, 'hz': frequencyHz};

  static FrequencyRef? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final ear = _ear(raw['ear']);
    final hz = raw['hz'];
    if (ear == null || hz is! num) return null;
    return FrequencyRef(ear, hz.toInt());
  }

  @override
  bool operator ==(Object other) =>
      other is FrequencyRef &&
      other.ear == ear &&
      other.frequencyHz == frequencyHz;

  @override
  int get hashCode => Object.hash(ear, frequencyHz);
}

/// The loudest level the headphones could produce at one frequency in one
/// ear, when that was below [kMaxLevelDbHl]. A "no response" there means no
/// response at this level, not at [kMaxLevelDbHl].
class OutputLimit {
  const OutputLimit(this.ear, this.frequencyHz, this.maxDbHl);

  final Ear ear;
  final int frequencyHz;
  final int maxDbHl;

  Map<String, Object?> toJson() =>
      {'ear': ear.name, 'hz': frequencyHz, 'max': maxDbHl};

  static OutputLimit? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final ear = _ear(raw['ear']);
    final hz = raw['hz'];
    final max = raw['max'];
    if (ear == null || hz is! num || max is! num) return null;
    return OutputLimit(ear, hz.toInt(), max.toInt());
  }
}

/// The pre-test questions and confirmations.
///
/// The questions follow BSA (2018) section 5 (noise exposure in the last 24
/// hours, tinnitus, hearing aids and headwear removed) and the sources of
/// error listed in ASHA (2005) (phones silenced, ear canal condition, room
/// noise). A null answer means the question was not asked, which is how
/// sessions saved before this checklist existed read back.
class PreTestChecklist {
  const PreTestChecklist({
    this.loudNoiseLast24h,
    this.tinnitus,
    this.hearingAidsRemoved = false,
    this.phonesSilenced = false,
    this.quietRoom = false,
    this.earsChecked = false,
  });

  /// Exposure to noise loud enough to need a raised voice at 1 metre in the
  /// last 24 hours (BSA wording). It can raise thresholds temporarily.
  final bool? loudNoiseLast24h;

  /// Tinnitus can mask tones near its pitch.
  final bool? tinnitus;

  final bool hearingAidsRemoved;
  final bool phonesSilenced;
  final bool quietRoom;

  /// The ear canals were looked at and nothing (wax, discharge) blocked them.
  final bool earsChecked;

  /// The confirmations that must all be ticked before a test can start.
  bool get requiredConfirmed =>
      hearingAidsRemoved && phonesSilenced && quietRoom;

  /// Both questions answered.
  bool get questionsAnswered => loudNoiseLast24h != null && tinnitus != null;

  PreTestChecklist copyWith({
    bool? loudNoiseLast24h,
    bool? tinnitus,
    bool? hearingAidsRemoved,
    bool? phonesSilenced,
    bool? quietRoom,
    bool? earsChecked,
  }) => PreTestChecklist(
    loudNoiseLast24h: loudNoiseLast24h ?? this.loudNoiseLast24h,
    tinnitus: tinnitus ?? this.tinnitus,
    hearingAidsRemoved: hearingAidsRemoved ?? this.hearingAidsRemoved,
    phonesSilenced: phonesSilenced ?? this.phonesSilenced,
    quietRoom: quietRoom ?? this.quietRoom,
    earsChecked: earsChecked ?? this.earsChecked,
  );

  Map<String, Object?> toJson() => {
    'loudNoiseLast24h': loudNoiseLast24h,
    'tinnitus': tinnitus,
    'hearingAidsRemoved': hearingAidsRemoved,
    'phonesSilenced': phonesSilenced,
    'quietRoom': quietRoom,
    'earsChecked': earsChecked,
  };

  factory PreTestChecklist.fromJson(Object? raw) {
    if (raw is! Map) return const PreTestChecklist();
    bool? opt(Object? v) => v is bool ? v : null;
    return PreTestChecklist(
      loudNoiseLast24h: opt(raw['loudNoiseLast24h']),
      tinnitus: opt(raw['tinnitus']),
      hearingAidsRemoved: raw['hearingAidsRemoved'] == true,
      phonesSilenced: raw['phonesSilenced'] == true,
      quietRoom: raw['quietRoom'] == true,
      earsChecked: raw['earsChecked'] == true,
    );
  }
}

/// How the familiarisation step went.
///
/// BSA (2018) 6.6: present a clearly audible 1000 Hz tone and check that the
/// responses match the start and the end of the tone; repeat once, and
/// re-instruct if they still do not.
class FamiliarisationOutcome {
  const FamiliarisationOutcome({
    required this.heard,
    required this.levelDbHl,
    required this.onsetOffsetMatched,
    required this.reinstructed,
  });

  /// False when no response was obtained even at the highest level tried.
  final bool heard;

  /// The level the patient responded at, or the last level tried.
  final int levelDbHl;

  /// True when the patient pressed while the tone played and let go when it
  /// stopped.
  final bool onsetOffsetMatched;

  /// True when the clinician had to re-instruct the patient.
  final bool reinstructed;

  Map<String, Object?> toJson() => {
    'heard': heard,
    'levelDbHl': levelDbHl,
    'onsetOffsetMatched': onsetOffsetMatched,
    'reinstructed': reinstructed,
  };

  static FamiliarisationOutcome? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final level = raw['levelDbHl'];
    return FamiliarisationOutcome(
      heard: raw['heard'] == true,
      levelDbHl: level is num ? level.toInt() : kFamiliarisationLevelDbHl,
      onsetOffsetMatched: raw['onsetOffsetMatched'] == true,
      reinstructed: raw['reinstructed'] == true,
    );
  }
}

/// A threshold measured twice in the same ear.
///
/// The 1000 Hz retest follows ASHA (2005) and BSA (2018). When it differs by
/// more than [kRetestToleranceDb], ASHA asks for at least one other frequency
/// to be retested as well, which is recorded the same way.
class RetestRecord {
  const RetestRecord({
    required this.ear,
    required this.frequencyHz,
    required this.firstDbHl,
    required this.retestDbHl,
    required this.withinTolerance,
  });

  final Ear ear;
  final int frequencyHz;

  /// Null when the measurement was a no-response or was not established.
  final int? firstDbHl;
  final int? retestDbHl;

  final bool withinTolerance;

  /// Absolute difference between the two, or null when either is missing.
  int? get differenceDb => firstDbHl == null || retestDbHl == null
      ? null
      : (firstDbHl! - retestDbHl!).abs();

  Map<String, Object?> toJson() => {
    'ear': ear.name,
    'hz': frequencyHz,
    'first': firstDbHl,
    'retest': retestDbHl,
    'withinTolerance': withinTolerance,
  };

  static RetestRecord? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final ear = _ear(raw['ear']);
    final hz = raw['hz'];
    if (ear == null || hz is! num) return null;
    final first = raw['first'];
    final retest = raw['retest'];
    return RetestRecord(
      ear: ear,
      frequencyHz: hz.toInt(),
      firstDbHl: first is num ? first.toInt() : null,
      retestDbHl: retest is num ? retest.toInt() : null,
      withinTolerance: raw['withinTolerance'] == true,
    );
  }
}

/// How a test was run, stored with the session so the report can state it.
///
/// ASHA (2005) asks the record to include the reason for the test, the
/// examiner's credentials, the equipment, any alternate methods or nonstandard
/// stimuli, and an assessment of reliability. BSA (2018) asks for omitted
/// frequencies and any doubt about accuracy to be recorded.
class TestProtocolRecord {
  const TestProtocolRecord({
    this.earOrder = const [],
    this.transducerType = TransducerType.headphones,
    this.reasonForTest,
    this.examinerCredentials,
    this.checklist = const PreTestChecklist(),
    this.familiarisation,
    this.retests = const [],
    this.interoctaveAdded = const [],
    this.skipped = const [],
    this.breaksOffered = 0,
    this.pressesBetweenTones = const {},
    this.testDuration,
    this.minToneMs = kMinToneMs,
    this.maxToneMs = kMaxToneMs,
    this.minGapMs = 1000,
    this.maxGapMs = 3000,
    this.catchTrialsUsed = true,
    this.outputLimits = const [],
    this.reducedPrecisionAudio = false,
  });

  /// Ears in the order tested. The better ear goes first.
  final List<Ear> earOrder;

  final TransducerType transducerType;
  final String? reasonForTest;
  final String? examinerCredentials;
  final PreTestChecklist checklist;
  final FamiliarisationOutcome? familiarisation;
  final List<RetestRecord> retests;
  final List<FrequencyRef> interoctaveAdded;
  final List<FrequencyRef> skipped;
  final int breaksOffered;

  /// Presses made while no tone was playing and no response window was open.
  final Map<Ear, int> pressesBetweenTones;

  /// Wall-clock length of the test, from the first tone to the last.
  final Duration? testDuration;

  final int minToneMs;
  final int maxToneMs;
  final int minGapMs;
  final int maxGapMs;
  final bool catchTrialsUsed;

  /// Frequencies where the headphones could not reach [kMaxLevelDbHl].
  final List<OutputLimit> outputLimits;

  /// True when this device could not play 32-bit float audio and the test
  /// fell back to 16-bit, which is less precise at the quietest levels.
  final bool reducedPrecisionAudio;

  /// The loudest level presented at [hz] in [ear].
  int maxLevelFor(Ear ear, int hz) {
    for (final l in outputLimits) {
      if (l.ear == ear && l.frequencyHz == hz) return l.maxDbHl;
    }
    return kMaxLevelDbHl;
  }

  int get totalPressesBetweenTones =>
      pressesBetweenTones.values.fold(0, (sum, n) => sum + n);

  /// Retests that differed by more than [kRetestToleranceDb].
  List<RetestRecord> get failedRetests =>
      retests.where((r) => !r.withinTolerance).toList();

  TestProtocolRecord copyWith({
    List<Ear>? earOrder,
    TransducerType? transducerType,
    String? reasonForTest,
    String? examinerCredentials,
    PreTestChecklist? checklist,
    FamiliarisationOutcome? familiarisation,
    List<RetestRecord>? retests,
    List<FrequencyRef>? interoctaveAdded,
    List<FrequencyRef>? skipped,
    int? breaksOffered,
    Map<Ear, int>? pressesBetweenTones,
    Duration? testDuration,
    List<OutputLimit>? outputLimits,
    bool? reducedPrecisionAudio,
  }) => TestProtocolRecord(
    earOrder: earOrder ?? this.earOrder,
    transducerType: transducerType ?? this.transducerType,
    reasonForTest: reasonForTest ?? this.reasonForTest,
    examinerCredentials: examinerCredentials ?? this.examinerCredentials,
    checklist: checklist ?? this.checklist,
    familiarisation: familiarisation ?? this.familiarisation,
    retests: retests ?? this.retests,
    interoctaveAdded: interoctaveAdded ?? this.interoctaveAdded,
    skipped: skipped ?? this.skipped,
    breaksOffered: breaksOffered ?? this.breaksOffered,
    pressesBetweenTones: pressesBetweenTones ?? this.pressesBetweenTones,
    testDuration: testDuration ?? this.testDuration,
    minToneMs: minToneMs,
    maxToneMs: maxToneMs,
    minGapMs: minGapMs,
    maxGapMs: maxGapMs,
    catchTrialsUsed: catchTrialsUsed,
    outputLimits: outputLimits ?? this.outputLimits,
    reducedPrecisionAudio: reducedPrecisionAudio ?? this.reducedPrecisionAudio,
  );

  Map<String, Object?> toJson() => {
    'version': 1,
    'earOrder': [for (final e in earOrder) e.name],
    'transducerType': transducerType.name,
    'reasonForTest': reasonForTest,
    'examinerCredentials': examinerCredentials,
    'checklist': checklist.toJson(),
    'familiarisation': familiarisation?.toJson(),
    'retests': [for (final r in retests) r.toJson()],
    'interoctaveAdded': [for (final f in interoctaveAdded) f.toJson()],
    'skipped': [for (final f in skipped) f.toJson()],
    'breaksOffered': breaksOffered,
    'pressesBetweenTones': {
      for (final e in pressesBetweenTones.entries) e.key.name: e.value,
    },
    'testDurationMs': testDuration?.inMilliseconds,
    'minToneMs': minToneMs,
    'maxToneMs': maxToneMs,
    'minGapMs': minGapMs,
    'maxGapMs': maxGapMs,
    'catchTrialsUsed': catchTrialsUsed,
    'outputLimits': [for (final l in outputLimits) l.toJson()],
    'reducedPrecisionAudio': reducedPrecisionAudio,
  };

  /// Reads a stored record. Unknown or missing fields fall back to defaults,
  /// so a damaged record never makes a session unreadable.
  factory TestProtocolRecord.fromJson(Map<String, Object?> json) {
    List<T> list<T>(Object? raw, T? Function(Object?) parse) => raw is List
        ? [for (final item in raw) parse(item)].whereType<T>().toList()
        : <T>[];
    int intOr(Object? v, int fallback) => v is num ? v.toInt() : fallback;
    String? text(Object? v) =>
        v is String && v.trim().isNotEmpty ? v.trim() : null;

    final presses = <Ear, int>{};
    final rawPresses = json['pressesBetweenTones'];
    if (rawPresses is Map) {
      rawPresses.forEach((key, value) {
        final ear = _ear(key);
        if (ear != null && value is num) presses[ear] = value.toInt();
      });
    }
    final durationMs = json['testDurationMs'];

    return TestProtocolRecord(
      earOrder: list(json['earOrder'], _ear),
      transducerType: TransducerType.values.firstWhere(
        (t) => t.name == json['transducerType'],
        orElse: () => TransducerType.headphones,
      ),
      reasonForTest: text(json['reasonForTest']),
      examinerCredentials: text(json['examinerCredentials']),
      checklist: PreTestChecklist.fromJson(json['checklist']),
      familiarisation: FamiliarisationOutcome.fromJson(json['familiarisation']),
      retests: list(json['retests'], RetestRecord.fromJson),
      interoctaveAdded: list(json['interoctaveAdded'], FrequencyRef.fromJson),
      skipped: list(json['skipped'], FrequencyRef.fromJson),
      breaksOffered: intOr(json['breaksOffered'], 0),
      pressesBetweenTones: presses,
      testDuration: durationMs is num
          ? Duration(milliseconds: durationMs.toInt())
          : null,
      minToneMs: intOr(json['minToneMs'], kMinToneMs),
      maxToneMs: intOr(json['maxToneMs'], kMaxToneMs),
      minGapMs: intOr(json['minGapMs'], 1000),
      maxGapMs: intOr(json['maxGapMs'], 3000),
      catchTrialsUsed: json['catchTrialsUsed'] != false,
      outputLimits: list(json['outputLimits'], OutputLimit.fromJson),
      reducedPrecisionAudio: json['reducedPrecisionAudio'] == true,
    );
  }
}

Ear? _ear(Object? raw) {
  for (final ear in Ear.values) {
    if (ear.name == raw) return ear;
  }
  return null;
}
