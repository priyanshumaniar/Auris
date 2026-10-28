import 'dart:io' show Platform;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/services.dart' show rootBundle;
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../core/audiometry/audiometry.dart';
import '../core/audiometry/calibration.dart';
import '../data/models/clinic.dart';
import '../data/models/patient.dart';
import '../data/models/test_protocol.dart';
import '../data/models/test_session.dart';
import '../ui/widgets/audiogram_painter.dart';

export '../data/models/clinic.dart' show ClinicDetails;

/// Builds the printable pure-tone audiometry report.
class AudiogramReport {
  const AudiogramReport({
    required this.patient,
    required this.session,
    required this.clinic,
    this.baseline,
  });

  final Patient patient;
  final TestSession session;
  final ClinicDetails clinic;

  /// An earlier session drawn faintly on the chart for comparison.
  final TestSession? baseline;

  static final _dateFormat = DateFormat('d MMM yyyy');
  static final _timeFormat = DateFormat('HH:mm');

  static const _ink = PdfColor.fromInt(0xFF1B2A32);
  static const _muted = PdfColor.fromInt(0xFF5A6B75);
  static const _rule = PdfColor.fromInt(0xFFCFD8DC);
  static const _rightEar = PdfColor.fromInt(0xFFD32F2F);
  static const _leftEar = PdfColor.fromInt(0xFF1976D2);
  static const _warnBg = PdfColor.fromInt(0xFFFFF4E5);
  static const _warnEdge = PdfColor.fromInt(0xFFE0A458);

  /// Loaded once and reused - parsing a TTF on every report would be wasteful.
  static pw.ThemeData? _theme;

  /// Builds the PDF theme from the bundled Roboto faces.
  ///
  /// The `pdf` package defaults to the PDF standard-14 fonts (Helvetica), which
  /// are Latin-1 only. Any "≥", "≤", or non-Latin patient name would be
  /// dropped from the output - silently, which is the dangerous part on a
  /// clinical document. Roboto covers the full Latin range used here.
  /// The same theme, for other Auris documents (e.g. calibration records).
  static Future<pw.ThemeData> sharedTheme() => _loadTheme();

  static Future<pw.ThemeData> _loadTheme() async {
    if (_theme != null) return _theme!;
    final regular = await rootBundle.load('assets/fonts/Roboto-Regular.ttf');
    final bold = await rootBundle.load('assets/fonts/Roboto-Bold.ttf');
    return _theme = pw.ThemeData.withFont(
      base: pw.Font.ttf(regular),
      bold: pw.Font.ttf(bold),
    );
  }

  /// Renders the report.
  ///
  /// [compress] exists so tests can inspect the uncompressed content stream;
  /// production always compresses.
  Future<Uint8List> build({bool compress = true}) async {
    final chart = await _renderChartPng();
    final doc = pw.Document(
      title: 'Audiogram: ${patient.fullName}',
      author: session.clinicianName,
      creator: 'Auris',
      subject: 'Pure-tone audiometry report',
      theme: await _loadTheme(),
      compress: compress,
    );

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.fromLTRB(36, 34, 36, 40),
        header: (context) =>
            context.pageNumber == 1 ? _header() : pw.SizedBox(),
        footer: _footer,
        build: (context) => [
          pw.SizedBox(height: 12),
          _patientBlock(),
          pw.SizedBox(height: 16),
          _sectionTitle('Audiogram'),
          pw.SizedBox(height: 6),
          _chart(chart),
          pw.SizedBox(height: 6),
          _legend(),
          pw.SizedBox(height: 16),
          _sectionTitle('Thresholds (dB HL)'),
          pw.SizedBox(height: 6),
          _thresholdTable(),
          pw.SizedBox(height: 4),
          _tableKey(),
          pw.SizedBox(height: 16),
          _sectionTitle('Summary'),
          pw.SizedBox(height: 6),
          _summary(),
          pw.SizedBox(height: 16),
          _sectionTitle('Reliability and masking'),
          pw.SizedBox(height: 6),
          _reliability(),
          pw.SizedBox(height: 16),
          _sectionTitle('How the test was done'),
          pw.SizedBox(height: 6),
          _testDetails(),
          if (session.notes != null && session.notes!.trim().isNotEmpty) ...[
            pw.SizedBox(height: 16),
            _sectionTitle('Notes'),
            pw.SizedBox(height: 6),
            pw.Text(
              session.notes!.trim(),
              style: const pw.TextStyle(fontSize: 10, color: _ink),
            ),
          ],
          pw.SizedBox(height: 16),
          _disclaimer(),
          pw.SizedBox(height: 22),
          _signature(),
        ],
      ),
    );

    return doc.save();
  }

  // ----------------------------------------------------------------- header

  pw.Widget _header() => pw.Column(
    children: [
      pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Expanded(
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text(
                  clinic.name,
                  style: const pw.TextStyle(
                    fontSize: 16,
                    fontWeight: pw.FontWeight.bold,
                    color: _ink,
                  ),
                ),
                if (clinic.address != null)
                  pw.Text(
                    clinic.address!,
                    style: const pw.TextStyle(fontSize: 9, color: _muted),
                  ),
                if (clinic.phone != null)
                  pw.Text(
                    clinic.phone!,
                    style: const pw.TextStyle(fontSize: 9, color: _muted),
                  ),
              ],
            ),
          ),
          pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.end,
            children: [
              pw.Text(
                'PURE-TONE AUDIOMETRY',
                style: const pw.TextStyle(
                  fontSize: 11,
                  fontWeight: pw.FontWeight.bold,
                  letterSpacing: 1.1,
                  color: _muted,
                ),
              ),
              pw.Text(
                'Air conduction, unmasked',
                style: const pw.TextStyle(fontSize: 9, color: _muted),
              ),
            ],
          ),
        ],
      ),
      pw.SizedBox(height: 8),
      pw.Divider(color: _rule, thickness: 1, height: 1),
    ],
  );

  pw.Widget _footer(pw.Context context) => pw.Column(
    children: [
      pw.Divider(color: _rule, thickness: 0.5, height: 1),
      pw.SizedBox(height: 4),
      pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(
            'Tested by ${session.clinicianName}',
            style: const pw.TextStyle(fontSize: 8, color: _muted),
          ),
          pw.Text(
            'Generated by Auris, not a certified medical device',
            style: const pw.TextStyle(fontSize: 8, color: _muted),
          ),
          pw.Text(
            'Page ${context.pageNumber} of ${context.pagesCount}',
            style: const pw.TextStyle(fontSize: 8, color: _muted),
          ),
        ],
      ),
    ],
  );

  // ---------------------------------------------------------------- patient

  pw.Widget _patientBlock() {
    final age = patient.ageAt(session.testedAt);
    final protocol = session.protocol;
    final credentials = protocol?.examinerCredentials;
    final fields = <(String, String)>[
      ('Patient', patient.fullName),
      ('Age / Sex', '$age years / ${patient.sex}'),
      if (patient.dateOfBirth != null)
        ('Date of birth', _dateFormat.format(patient.dateOfBirth!)),
      if (patient.clinicRef != null) ('Patient ID', patient.clinicRef!),
      ('Test date', _dateFormat.format(session.testedAt)),
      ('Test time', _timeFormat.format(session.testedAt)),
      (
        'Examiner',
        credentials == null
            ? session.clinicianName
            : '${session.clinicianName}, $credentials',
      ),
      (
        'Transducer',
        protocol == null
            ? session.calibration.transducerName
            : '${session.calibration.transducerName} '
                  '(${protocol.transducerType == TransducerType.insertEarphones ? 'insert earphones' : 'headphones'})',
      ),
      ('Equipment', 'Auris on ${_platformName()}'),
      ('Last calibration', _lastCalibration()),
      if (protocol?.reasonForTest != null)
        ('Reason for test', protocol!.reasonForTest!),
    ];

    return pw.Inseparable(
      child: pw.Container(
        padding: const pw.EdgeInsets.all(10),
        decoration: pw.BoxDecoration(
          border: pw.Border.all(color: _rule, width: 0.8),
          borderRadius: pw.BorderRadius.circular(4),
        ),
        child: pw.Wrap(
          spacing: 26,
          runSpacing: 6,
          children: [
            for (final (label, value) in fields)
              pw.SizedBox(
                width: label == 'Reason for test' ? 470 : 150,
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text(
                      label.toUpperCase(),
                      style: const pw.TextStyle(
                        fontSize: 7,
                        letterSpacing: 0.6,
                        fontWeight: pw.FontWeight.bold,
                        color: _muted,
                      ),
                    ),
                    pw.Text(
                      value,
                      style: const pw.TextStyle(fontSize: 10.5, color: _ink),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _platformName() {
    const names = {
      'macos': 'macOS',
      'ios': 'iOS',
      'android': 'Android',
      'windows': 'Windows',
      'linux': 'Linux',
    };
    return names[Platform.operatingSystem] ?? Platform.operatingSystem;
  }

  /// The most recent calibration of either ear, or a plain "not calibrated".
  String _lastCalibration() {
    DateTime? latest;
    for (final ear in Ear.values) {
      final e = session.calibration.ear(ear);
      final at = e.calibratedAt;
      if (!e.hasCalibration || at == null) continue;
      if (latest == null || at.isAfter(latest)) latest = at;
    }
    if (latest != null) return _dateFormat.format(latest.toLocal());
    return session.calibration.hasAnyCalibration
        ? 'Date not recorded'
        : 'Not calibrated';
  }

  // ------------------------------------------------------------------ chart

  Future<Uint8List> _renderChartPng() async {
    final image = await renderAudiogramImage(
      series: {for (final ear in Ear.values) ear: session.thresholdsFor(ear)},
      noResponseLevel: session.protocol?.maxLevelFor,
      baseline: baseline == null
          ? null
          : {for (final ear in Ear.values) ear: baseline!.thresholdsFor(ear)},
    );
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  }

  pw.Widget _chart(Uint8List png) => pw.Center(
    child: pw.Container(
      decoration: pw.BoxDecoration(
        border: pw.Border.all(color: _rule, width: 0.8),
        borderRadius: pw.BorderRadius.circular(4),
      ),
      padding: const pw.EdgeInsets.all(6),
      child: pw.Image(pw.MemoryImage(png), height: 330),
    ),
  );

  pw.Widget _legend() => pw.Row(
    mainAxisAlignment: pw.MainAxisAlignment.center,
    children: [
      _legendEntry('O', 'Right ear (solid)', _rightEar),
      pw.SizedBox(width: 22),
      _legendEntry('X', 'Left ear (dashed)', _leftEar),
      if (baseline != null) ...[
        pw.SizedBox(width: 22),
        _legendEntry(
          '-',
          'Previous test '
              '(${_dateFormat.format(baseline!.testedAt)})',
          PdfColors.grey600,
        ),
      ],
    ],
  );

  pw.Widget _legendEntry(String symbol, String label, PdfColor color) => pw.Row(
    children: [
      pw.Text(
        symbol,
        style: pw.TextStyle(
          fontSize: 12,
          fontWeight: pw.FontWeight.bold,
          color: color,
        ),
      ),
      pw.SizedBox(width: 5),
      pw.Text(label, style: const pw.TextStyle(fontSize: 9, color: _muted)),
    ],
  );

  // ------------------------------------------------------------------ table

  pw.Widget _thresholdTable() {
    final frequencies = session.testedFrequencies.isEmpty
        ? kAudiometricFrequenciesHz
        : session.testedFrequencies;
    String cell(Ear ear, int hz) {
      if (session.notEstablishedFor(ear).contains(hz)) return 'NE';
      final map = session.thresholdsFor(ear);
      if (!map.containsKey(hz)) return '-';
      final value = map[hz];
      // "NR" is the clinical shorthand for no response at maximum output. It
      // is not the same as an untested frequency, and must not read as one.
      if (value == null) return 'NR';
      return session.floorFrequenciesFor(ear).contains(hz)
          ? '≤$value'
          : '$value';
    }

    pw.Widget headerCell(String text) => pw.Padding(
      padding: const pw.EdgeInsets.symmetric(vertical: 5, horizontal: 4),
      child: pw.Text(
        text,
        textAlign: pw.TextAlign.center,
        style: const pw.TextStyle(
          fontSize: 9,
          fontWeight: pw.FontWeight.bold,
          color: _ink,
        ),
      ),
    );

    pw.Widget dataCell(String text, {PdfColor color = _ink}) => pw.Padding(
      padding: const pw.EdgeInsets.symmetric(vertical: 5, horizontal: 4),
      child: pw.Text(
        text,
        textAlign: pw.TextAlign.center,
        style: pw.TextStyle(fontSize: 10, color: color),
      ),
    );

    return pw.Table(
      border: pw.TableBorder.all(color: _rule, width: 0.6),
      defaultVerticalAlignment: pw.TableCellVerticalAlignment.middle,
      children: [
        pw.TableRow(
          decoration: const pw.BoxDecoration(
            color: PdfColor.fromInt(0xFFF2F5F7),
          ),
          children: [
            headerCell('Ear'),
            for (final hz in frequencies) headerCell(formatHzLong(hz)),
          ],
        ),
        pw.TableRow(
          children: [
            dataCell('Right (O)', color: _rightEar),
            for (final hz in frequencies) dataCell(cell(Ear.right, hz)),
          ],
        ),
        pw.TableRow(
          children: [
            dataCell('Left (X)', color: _leftEar),
            for (final hz in frequencies) dataCell(cell(Ear.left, hz)),
          ],
        ),
      ],
    );
  }

  pw.Widget _tableKey() {
    final skipped = session.protocol?.skipped ?? const <FrequencyRef>[];
    final limits = session.protocol?.outputLimits ?? const <OutputLimit>[];
    final limitText = limits.isEmpty
        ? ''
        : ' The headphones could not reach $kMaxLevelDbHl dB HL at: '
              '${limits.map((l) => '${formatHzLong(l.frequencyHz)} '
                  '${l.ear.label.toLowerCase()} (${l.maxDbHl} dB HL)').join(', ')}'
              '; NR there means no response at that level.';
    return pw.Text(
      'NR: no response at $kMaxLevelDbHl dB HL, the highest level Auris '
      'presents.$limitText ≤: heard at the quietest level available; the '
      'threshold is at or below this value. NE: no threshold could be '
      'established. -: not tested.'
      '${skipped.isEmpty ? '' : ' Skipped by the examiner: ${_frequencyList(skipped)}.'}',
      style: const pw.TextStyle(fontSize: 7.5, color: _muted, lineSpacing: 1.3),
    );
  }

  static String _frequencyList(List<FrequencyRef> refs) => refs
      .map((f) => '${formatHzLong(f.frequencyHz)} ${f.ear.label.toLowerCase()}')
      .join(', ');

  // ---------------------------------------------------------------- summary

  pw.Widget _summary() {
    pw.Widget earSummary(Ear ear, PdfColor color) {
      final pta = session.ptaFor(ear);
      return pw.Expanded(
        child: pw.Container(
          padding: const pw.EdgeInsets.all(10),
          decoration: pw.BoxDecoration(
            border: pw.Border.all(color: _rule, width: 0.8),
            borderRadius: pw.BorderRadius.circular(4),
          ),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text(
                '${ear.label} ear'.toUpperCase(),
                style: pw.TextStyle(
                  fontSize: 8,
                  letterSpacing: 0.6,
                  fontWeight: pw.FontWeight.bold,
                  color: color,
                ),
              ),
              pw.SizedBox(height: 4),
              if (pta == null)
                pw.Text(
                  'Not tested',
                  style: const pw.TextStyle(fontSize: 11, color: _muted),
                )
              else ...[
                pw.Text(
                  'PTA ${session.ptaDisplayFor(ear)}',
                  style: const pw.TextStyle(
                    fontSize: 13,
                    fontWeight: pw.FontWeight.bold,
                    color: _ink,
                  ),
                ),
                pw.Text(
                  '${pta.degree.label} hearing loss'.replaceFirst(
                    'Normal hearing loss',
                    'Normal hearing',
                  ),
                  style: const pw.TextStyle(fontSize: 10, color: _ink),
                ),
                pw.SizedBox(height: 2),
                pw.Text(
                  'Average of '
                  '${pta.frequenciesUsed.map(formatHzLong).join(', ')}',
                  style: const pw.TextStyle(fontSize: 8, color: _muted),
                ),
              ],
            ],
          ),
        ),
      );
    }

    return pw.Column(
      children: [
        pw.Row(
          children: [
            earSummary(Ear.right, _rightEar),
            pw.SizedBox(width: 10),
            earSummary(Ear.left, _leftEar),
          ],
        ),
        pw.SizedBox(height: 6),
        pw.Text(
          'Degree of hearing loss is classified from the PTA using Goodman '
          '(1965): normal up to 25 dB HL.',
          style: const pw.TextStyle(fontSize: 8, color: _muted),
        ),
      ],
    );
  }

  // ------------------------------------------------------------ reliability

  pw.Widget _reliability() {
    final protocol = session.protocol;
    final concerns = session.reliabilityConcerns;
    final masking = session.maskingFlags;
    final lines = <pw.Widget>[];

    void line(String text, {bool warn = false}) => lines.add(
      pw.Padding(
        padding: const pw.EdgeInsets.only(bottom: 3),
        child: pw.Text(
          text,
          style: pw.TextStyle(
            fontSize: 8.5,
            lineSpacing: 1.4,
            color: _ink,
            fontWeight: warn ? pw.FontWeight.bold : null,
          ),
        ),
      ),
    );

    final rate = session.falsePositiveRate;
    if (rate != null) {
      line(
        'Silent catch trials: ${session.totalFalsePositives} '
        'response${session.totalFalsePositives == 1 ? '' : 's'} in '
        '${session.totalCatchTrials} '
        '(${(rate * 100).toStringAsFixed(0)}%).',
      );
    }
    if (protocol != null) {
      line(
        'Presses while no tone was playing: ${session.pressesBetweenTones}, '
        'against ${session.totalTonesPresented} tones presented.',
      );
      final f = protocol.familiarisation;
      if (f != null) {
        line(
          f.heard
              ? 'Familiarisation at 1 kHz: responded at ${f.levelDbHl} dB HL; '
                    '${f.onsetOffsetMatched ? 'presses matched the start and end of the tone' : 'presses did not match the start and end of the tone'}'
                    '${f.reinstructed ? ', after re-instruction' : ''}.'
              : 'Familiarisation at 1 kHz: no response up to ${f.levelDbHl} dB HL.',
        );
      }
      for (final r in protocol.retests) {
        String v(int? db) => db == null ? 'no result' : '$db dB HL';
        line(
          '${formatHzLong(r.frequencyHz)} retest, ${r.ear.label.toLowerCase()} '
          'ear: ${v(r.firstDbHl)} then ${v(r.retestDbHl)} '
          '(${r.withinTolerance ? 'within' : 'more than'} $kRetestToleranceDb dB). '
          'The lower value is reported.',
        );
      }
    }
    if (rate == null && protocol == null) {
      line('No reliability measures were recorded for this test.');
    }
    for (final c in concerns) {
      line('Caution: $c', warn: true);
    }
    final limit = (protocol?.transducerType ?? TransducerType.headphones)
        .interauralAttenuationDb;
    if (masking.isEmpty) {
      line(
        'Masking check: the ears differ by less than $limit dB at every '
        'frequency tested, so masking was not needed (BSA 2018).',
      );
    } else {
      for (final m in masking) {
        line(
          'Masking needed at ${formatHzLong(m.frequencyHz)}: the ears differ '
          'by ${m.isLowerBound ? 'at least ' : ''}${m.differenceDb} dB '
          '($limit dB or more). The ${m.worseEar.label.toLowerCase()} ear '
          'result may be the other ear hearing the tone. Auris does not '
          'mask; confirm with a masked test.',
          warn: true,
        );
      }
    }

    final flagged = concerns.isNotEmpty || masking.isNotEmpty;
    return _box(lines, warn: flagged);
  }

  // ------------------------------------------------------------ test details

  pw.Widget _testDetails() {
    final protocol = session.protocol;
    final lines = <String>[
      'Procedure: modified Hughson-Westlake, down 10 dB after a response and '
          'up 5 dB after a miss. Threshold: the lowest level with responses on '
          'at least half of the ascending runs, and at least two (ASHA 2005; '
          'BSA 2018). Air conduction only, unmasked. Bone conduction and '
          'speech audiometry were not performed, so the type of any hearing '
          'loss is not established.',
    ];

    if (protocol == null) {
      lines.add(
        'This test was saved before Auris recorded the test order, '
        'timing and pre-test checks.',
      );
    } else {
      final order = protocol.earOrder.map((e) => e.label.toLowerCase());
      if (order.isNotEmpty) {
        lines.add(
          'Ear order: ${order.join(' then ')} '
          '(the better ear first, as reported by the patient). Frequencies: '
          '1, 2, 3, 4, 6 and 8 kHz, a 1 kHz retest in the first ear, then '
          '500 and 250 Hz.',
        );
      }
      lines.add(
        'Stimuli: pure tones of '
        '${_seconds(protocol.minToneMs)} to ${_seconds(protocol.maxToneMs)} s '
        'and gaps of ${_seconds(protocol.minGapMs)} to '
        '${_seconds(protocol.maxGapMs)} s, both varied at random. Response: '
        'press when the tone starts and hold until it stops.',
      );
      if (protocol.catchTrialsUsed) {
        lines.add(
          'Silent catch trials (about 1 in 10) were added as a '
          'reliability check. They are not part of the ASHA or BSA '
          'procedures.',
        );
      }
      if (protocol.interoctaveAdded.isNotEmpty) {
        lines.add(
          'Interoctave frequencies added because neighbouring '
          'octaves differed by $kInteroctaveDifferenceDb dB or more: '
          '${_frequencyList(protocol.interoctaveAdded)}.',
        );
      }
      if (protocol.skipped.isNotEmpty) {
        lines.add(
          'Skipped by the examiner: '
          '${_frequencyList(protocol.skipped)}.',
        );
      }
      if (protocol.breaksOffered > 0) {
        lines.add('Breaks offered: ${protocol.breaksOffered}.');
      }
      if (protocol.reducedPrecisionAudio) {
        lines.add(
          'This device could not play 32-bit audio, so tones were played as '
          '16-bit audio, which is less precise at the quietest levels.',
        );
      }
      final duration = protocol.testDuration;
      if (duration != null) {
        lines.add(
          'Test time: about ${(duration.inSeconds / 60).ceil()} '
          'minute${duration.inSeconds <= 60 ? '' : 's'}.',
        );
      }
      final c = protocol.checklist;
      String yn(bool? v) => v == null ? 'not asked' : (v ? 'yes' : 'no');
      String done(bool v) => v ? 'yes' : 'not confirmed';
      lines.add(
        'Before the test: loud noise in the last 24 hours '
        '${yn(c.loudNoiseLast24h)}; tinnitus ${yn(c.tinnitus)}; hearing '
        'aids and headwear removed ${done(c.hearingAidsRemoved)}; phones '
        'silenced ${done(c.phonesSilenced)}; quiet room '
        '${done(c.quietRoom)} (confirmed by the examiner, noise level not '
        'measured); ear canals checked '
        '${c.earsChecked ? 'yes' : 'not done'}.',
      );
    }

    return _box([
      for (final text in lines)
        pw.Padding(
          padding: const pw.EdgeInsets.only(bottom: 3),
          child: pw.Text(
            text,
            style: const pw.TextStyle(
              fontSize: 8.5,
              color: _ink,
              lineSpacing: 1.4,
            ),
          ),
        ),
    ]);
  }

  static String _seconds(int ms) =>
      ms % 1000 == 0 ? '${ms ~/ 1000}' : (ms / 1000).toStringAsFixed(1);

  /// A bordered box that is never split across pages. Without [pw.Inseparable]
  /// a box that does not fit is drawn empty at the foot of one page with its
  /// text on the next.
  pw.Widget _box(List<pw.Widget> children, {bool warn = false}) =>
      pw.Inseparable(
        child: pw.Container(
          width: double.infinity,
          padding: const pw.EdgeInsets.all(10),
          decoration: pw.BoxDecoration(
            color: warn ? _warnBg : null,
            border: pw.Border.all(color: warn ? _warnEdge : _rule, width: 0.8),
            borderRadius: pw.BorderRadius.circular(4),
          ),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: children,
          ),
        ),
      );

  // -------------------------------------------------------------- signature

  pw.Widget _signature() => pw.Inseparable(
    child: pw.Row(
      children: [
        pw.Expanded(
          flex: 3,
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.SizedBox(height: 18),
              pw.Divider(color: _ink, thickness: 0.6, height: 1),
              pw.SizedBox(height: 3),
              pw.Text(
                'Examiner signature',
                style: const pw.TextStyle(fontSize: 8, color: _muted),
              ),
            ],
          ),
        ),
        pw.SizedBox(width: 30),
        pw.Expanded(
          flex: 2,
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.SizedBox(height: 18),
              pw.Divider(color: _ink, thickness: 0.6, height: 1),
              pw.SizedBox(height: 3),
              pw.Text(
                'Date',
                style: const pw.TextStyle(fontSize: 8, color: _muted),
              ),
            ],
          ),
        ),
      ],
    ),
  );

  // ------------------------------------------------------------- disclaimer

  pw.Widget _disclaimer() {
    final method = session.calibration.method;
    final calibrated = method == CalibrationMethod.soundLevelMeter;

    // A biological check sits between the two: worth reporting as a real
    // calibration, but never as a measured one.
    final heading = switch (method) {
      CalibrationMethod.soundLevelMeter => 'Calibration',
      CalibrationMethod.biological =>
        'CALIBRATED BY BIOLOGICAL CHECK, NOT AGAINST A METER',
      CalibrationMethod.none => 'UNCALIBRATED: SCREENING ONLY',
    };

    final body = switch (method) {
      CalibrationMethod.soundLevelMeter =>
        'Output was calibrated against a sound level meter using '
            '${session.calibration.transducerName}.',
      CalibrationMethod.biological =>
        'Output was anchored to a listener assumed to have normal hearing, '
            'using ${session.calibration.transducerName}, rather than measured '
            'with a sound level meter. Absolute dB HL values carry the '
            'uncertainty of that assumption. $kHumanCalibrationWarning',
      CalibrationMethod.none =>
        'This test was run on equipment that has not been calibrated against a '
            'reference sound level. The shape of the audiogram is meaningful, '
            'but the absolute dB HL values are not. Treat this as a screening '
            'result only.',
    };

    return pw.Inseparable(
      child: pw.Container(
        width: double.infinity,
        padding: const pw.EdgeInsets.all(10),
        decoration: pw.BoxDecoration(
          color: calibrated ? PdfColors.grey100 : _warnBg,
          border: pw.Border.all(
            color: calibrated ? _rule : _warnEdge,
            width: 0.8,
          ),
          borderRadius: pw.BorderRadius.circular(4),
        ),
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text(
              heading,
              style: pw.TextStyle(
                fontSize: 9,
                fontWeight: pw.FontWeight.bold,
                letterSpacing: 0.4,
                color: calibrated ? _muted : _warnEdge,
              ),
            ),
            pw.SizedBox(height: 4),
            pw.Text(
              body,
              style: const pw.TextStyle(
                fontSize: 8.5,
                color: _ink,
                lineSpacing: 1.5,
              ),
            ),
            pw.SizedBox(height: 4),
            pw.Text(
              _perEarCalibrationLine(),
              style: const pw.TextStyle(
                fontSize: 8.5,
                color: _ink,
                lineSpacing: 1.5,
              ),
            ),
            if (method != CalibrationMethod.biological &&
                session.calibration.usesHumanListener) ...[
              pw.SizedBox(height: 4),
              pw.Text(
                kHumanCalibrationWarning,
                style: const pw.TextStyle(
                  fontSize: 8.5,
                  color: _ink,
                  lineSpacing: 1.5,
                ),
              ),
            ],
            pw.SizedBox(height: 5),
            pw.Text(
              'Auris is not a certified medical device. This report does not '
              'constitute a diagnosis and does not replace assessment by a '
              'qualified audiologist or ENT specialist.',
              style: const pw.TextStyle(
                fontSize: 8.5,
                fontWeight: pw.FontWeight.bold,
                color: _ink,
                lineSpacing: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// "Calibration by ear: Right: Biological check (measured 22 Oct 2026).
  /// Left: Biological check (copied from the right ear, 22 Oct 2026)."
  String _perEarCalibrationLine() {
    String describe(Ear ear) {
      final e = session.calibration.ear(ear);
      if (!e.hasCalibration) return '${ear.label}: not calibrated';
      final when = e.calibratedAt == null
          ? ''
          : ', ${_dateFormat.format(e.calibratedAt!)}';
      final how = e.isCopied
          ? 'copied from the ${ear.other.label.toLowerCase()} ear'
          : 'measured';
      return '${ear.label}: ${e.method.label} ($how$when)';
    }

    return 'Calibration by ear. ${describe(Ear.right)}. ${describe(Ear.left)}.';
  }

  pw.Widget _sectionTitle(String text) => pw.Text(
    text.toUpperCase(),
    style: const pw.TextStyle(
      fontSize: 9,
      letterSpacing: 0.8,
      fontWeight: pw.FontWeight.bold,
      color: _muted,
    ),
  );
}
