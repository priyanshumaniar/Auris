import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:printing/printing.dart';

import '../../core/audiometry/audiometry.dart';
import '../../core/audiometry/calibration.dart';
import '../../data/models/patient.dart';
import '../../data/models/test_session.dart';
import '../../report/pdf_report.dart';
import '../../utils/route_constants.dart';
import '../app_scope.dart';
import '../theme.dart';
import '../widgets/audiogram_view.dart';
import '../widgets/auris_button.dart';
import '../widgets/calibration_by_ear.dart';

class ResultsScreen extends StatefulWidget {
  const ResultsScreen({
    super.key,
    required this.patient,
    required this.session,
    this.isFresh = false,
  });

  final Patient patient;
  final TestSession session;

  /// True when arriving straight from a completed test, which changes the
  /// navigation affordances (retest / done rather than back).
  final bool isFresh;

  @override
  State<ResultsScreen> createState() => _ResultsScreenState();
}

class _ResultsScreenState extends State<ResultsScreen> {
  static final _dateFormat = DateFormat('d MMM yyyy, HH:mm');

  TestSession? _baseline;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadBaseline());
  }

  /// Loads the previous test, if any, to overlay on the chart and the report.
  Future<void> _loadBaseline() async {
    final sessions =
        await AppScope.of(context).repository.listSessions(widget.patient.id);
    final earlier = sessions
        .where((s) => s.testedAt.isBefore(widget.session.testedAt))
        .toList();
    if (!mounted || earlier.isEmpty) return;
    setState(() => _baseline = earlier.first);
  }

  AudiogramReport _buildReport() => AudiogramReport(
        patient: widget.patient,
        session: widget.session,
        clinic: AppScope.of(context).clinic,
        baseline: _baseline,
      );

  Future<void> _withBusy(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not create the PDF: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _printReport() => _withBusy(() async {
        final report = _buildReport();
        await Printing.layoutPdf(
          onLayout: (_) => report.build(),
          name: _fileName,
        );
      });

  Future<void> _shareReport() => _withBusy(() async {
        final bytes = await _buildReport().build();
        await Printing.sharePdf(bytes: bytes, filename: _fileName);
      });

  String get _fileName {
    final safeName =
        widget.patient.fullName.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_');
    final date = DateFormat('yyyy-MM-dd').format(widget.session.testedAt);
    return 'audiogram_${safeName}_$date.pdf';
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final canRetest = AppScope.of(context).auth.role.canRunTests;
    final series = {
      for (final ear in Ear.values) ear: session.thresholdsFor(ear),
    };
    final frequencies = session.testedFrequencies.isEmpty
        ? kAudiometricFrequenciesHz
        : session.testedFrequencies;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Results'),
        automaticallyImplyLeading: !widget.isFresh,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
        children: [
          Text(
            widget.patient.fullName,
            style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w600,
                color: AurisTheme.ink),
          ),
          Text(
            '${widget.patient.ageAt(session.testedAt)} years · '
            '${widget.patient.sex} · ${_dateFormat.format(session.testedAt)}',
            style: const TextStyle(fontSize: 13, color: AurisTheme.muted),
          ),
          const SizedBox(height: 18),
          if (session.calibration.method == CalibrationMethod.none) ...[
            const CalibrationWarning(
              message:
                  'This test ran on a device (or an ear) that was not '
                  'calibrated. The shape of the audiogram is meaningful, but '
                  'the absolute dB HL values are not. Report it as a screening '
                  'result.',
            ),
            const SizedBox(height: 18),
          ],
          // Shown on its own, not as an alternative: one ear calibrated with a
          // listener and the other not at all needs both notices.
          if (session.calibration.usesHumanListener) ...[
            const HumanCalibrationNotice(),
            const SizedBox(height: 18),
          ],
          if (session.reliabilityConcerns.isNotEmpty) ...[
            _notice(
              icon: Icons.report_problem_outlined,
              title: 'Interpret with caution',
              lines: [
                ...session.reliabilityConcerns,
                'Consider re-instructing the patient and repeating the test.',
              ],
            ),
            const SizedBox(height: 18),
          ],
          if (session.maskingFlags.isNotEmpty) ...[
            _notice(
              icon: Icons.hearing_disabled_outlined,
              title: 'Masking would be needed',
              lines: [
                for (final f in session.maskingFlags)
                  '${formatHzLong(f.frequencyHz)}: the ears differ by '
                      '${f.isLowerBound ? 'at least ' : ''}${f.differenceDb} dB. '
                      'The ${f.worseEar.label.toLowerCase()} ear result may be '
                      'the other ear hearing the tone.',
                'Auris does not mask, so confirm these with a masked test.',
              ],
            ),
            const SizedBox(height: 18),
          ],
          AudiogramView(
            series: series,
            noResponseLevel: session.protocol?.maxLevelFor,
            baseline: _baseline == null
                ? null
                : {
                    for (final ear in Ear.values)
                      ear: _baseline!.thresholdsFor(ear)
                  },
            baselineLabel: _baseline == null
                ? null
                : 'Previous (${DateFormat('d MMM yyyy').format(_baseline!.testedAt)})',
          ),
          const SizedBox(height: 22),
          const SectionLabel('Thresholds (dB HL)'),
          const SizedBox(height: 10),
          ThresholdTable(
            series: series,
            frequencies: frequencies,
            floor: {
              for (final ear in Ear.values)
                ear: session.floorFrequenciesFor(ear),
            },
            notEstablished: {
              for (final ear in Ear.values)
                ear: session.notEstablishedFor(ear),
            },
          ),
          const SizedBox(height: 6),
          const Text(
            'NR no response at the maximum level · ≤ at or below the quietest '
            'level available · NE not established · - not tested',
            style: TextStyle(fontSize: 11, color: AurisTheme.muted),
          ),
          if ((session.protocol?.skipped ?? const []).isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              'Skipped: ${session.protocol!.skipped.map((f) => '${f.ear.label} ${formatHzLong(f.frequencyHz)}').join(', ')}',
              style: const TextStyle(fontSize: 11.5, color: AurisTheme.muted),
            ),
          ],
          const SizedBox(height: 22),
          const SectionLabel('Summary'),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(child: _summaryCard(Ear.right)),
              const SizedBox(width: 10),
              Expanded(child: _summaryCard(Ear.left)),
            ],
          ),
          const SizedBox(height: 26),
          const SectionLabel('Report'),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: AurisOutlineButton(
                  buttonName: 'Print / Preview',
                  icon: Icons.print_outlined,
                  width: double.infinity,
                  onTap: _busy ? null : _printReport,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: AurisOutlineButton(
                  buttonName: 'Share PDF',
                  icon: Icons.ios_share_rounded,
                  width: double.infinity,
                  onTap: _busy ? null : _shareReport,
                ),
              ),
            ],
          ),
          if (_busy) ...[
            const SizedBox(height: 14),
            const Center(
              child: SizedBox(
                height: 20,
                width: 20,
                child: CircularProgressIndicator(strokeWidth: 2.2),
              ),
            ),
          ],
          const SizedBox(height: 28),
          if (widget.isFresh) ...[
            Center(
              child: AurisButton(
                buttonName: 'Done',
                width: 240,
                onTap: () => Navigator.pushNamedAndRemoveUntil(
                    context, dashboardRoute, (_) => false),
              ),
            ),
            if (canRetest) ...[
              const SizedBox(height: 12),
              Center(
                child: TextButton.icon(
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  label: const Text('Retest this patient'),
                  onPressed: () => Navigator.pushReplacementNamed(
                      context, testSetupRoute,
                      arguments: widget.patient),
                ),
              ),
            ],
          ] else if (canRetest)
            Center(
              child: AurisButton(
                buttonName: 'Retest',
                width: 240,
                onTap: () => Navigator.pushReplacementNamed(
                    context, testSetupRoute,
                    arguments: widget.patient),
              ),
            ),
        ],
      ),
    );
  }

  Widget _notice({
    required IconData icon,
    required String title,
    required List<String> lines,
  }) =>
      Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AurisTheme.warningSurface,
          borderRadius: BorderRadius.circular(AurisTheme.cardRadius),
          border: Border.all(color: AurisTheme.warning),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: AurisTheme.warning, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: AurisTheme.ink)),
                  const SizedBox(height: 4),
                  for (final line in lines)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Text(line,
                          style: const TextStyle(
                              fontSize: 12.5,
                              height: 1.4,
                              color: AurisTheme.ink)),
                    ),
                ],
              ),
            ),
          ],
        ),
      );

  Widget _summaryCard(Ear ear) {
    final pta = widget.session.ptaFor(ear);
    final color = ear == Ear.right ? AurisTheme.rightEar : AurisTheme.leftEar;

    return AurisCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(ear.marker,
                  style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                      color: color)),
              const SizedBox(width: 6),
              Text('${ear.label} ear'.toUpperCase(),
                  style: TextStyle(
                      fontSize: 10,
                      letterSpacing: 0.6,
                      fontWeight: FontWeight.w700,
                      color: color)),
            ],
          ),
          const SizedBox(height: 8),
          if (pta == null)
            const Text('Not tested',
                style: TextStyle(fontSize: 14, color: AurisTheme.muted))
          else ...[
            Text('PTA ${widget.session.ptaDisplayFor(ear)}',
                style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    color: AurisTheme.ink)),
            const SizedBox(height: 2),
            Text(
              pta.degree.label == 'Normal'
                  ? 'Normal hearing'
                  : '${pta.degree.label} hearing loss',
              style: const TextStyle(fontSize: 13, color: AurisTheme.ink),
            ),
          ],
        ],
      ),
    );
  }
}
