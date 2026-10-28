import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/audiometry/audiometry.dart';
import '../../data/models/patient.dart';
import '../../data/models/test_session.dart';
import '../theme.dart';
import '../widgets/audiogram_view.dart';

/// Compares two tests for the same patient.
///
/// The change table is the point of this screen: a shift of 10 dB or more at a
/// frequency is the threshold at which most protocols call a change real rather
/// than test-retest variability, so those rows are highlighted.
class ComparisonScreen extends StatefulWidget {
  const ComparisonScreen({
    super.key,
    required this.patient,
    required this.sessions,
  });

  final Patient patient;

  /// The patient's sessions, most recent first.
  final List<TestSession> sessions;

  @override
  State<ComparisonScreen> createState() => _ComparisonScreenState();
}

class _ComparisonScreenState extends State<ComparisonScreen> {
  static final _dateFormat = DateFormat('d MMM yyyy');

  /// A change of at least this many dB is treated as clinically meaningful
  /// rather than normal test-retest variation.
  static const int _significantShiftDb = 10;

  late TestSession _current;
  late TestSession _previous;

  @override
  void initState() {
    super.initState();
    _current = widget.sessions.first;
    _previous = widget.sessions[1];
    _order();
  }

  /// Keeps "Later" later than "Earlier", whichever picker changed, so the
  /// sign of every change is right.
  void _order() {
    if (_current.testedAt.isBefore(_previous.testedAt)) {
      final later = _previous;
      _previous = _current;
      _current = later;
    }
  }

  @override
  Widget build(BuildContext context) {
    final frequencies = {
      ..._current.testedFrequencies,
      ..._previous.testedFrequencies,
    }.toList()
      ..sort();

    return Scaffold(
      appBar: AppBar(title: const Text('Compare tests')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
        children: [
          Text(
            widget.patient.fullName,
            style: const TextStyle(
                fontSize: 19,
                fontWeight: FontWeight.w600,
                color: AurisTheme.ink),
          ),
          const SizedBox(height: 16),
          _picker(
            label: 'Later test',
            value: _current,
            onChanged: (s) => setState(() {
              _current = s;
              _order();
            }),
          ),
          const SizedBox(height: 10),
          _picker(
            label: 'Earlier test',
            value: _previous,
            onChanged: (s) => setState(() {
              _previous = s;
              _order();
            }),
          ),
          const SizedBox(height: 20),
          if (_current.id == _previous.id)
            const AurisCard(
              child: Text(
                'Select two different tests to compare.',
                style: TextStyle(fontSize: 13.5, color: AurisTheme.muted),
              ),
            )
          else ...[
            AudiogramView(
              series: {
                for (final ear in Ear.values) ear: _current.thresholdsFor(ear),
              },
              noResponseLevel: _current.protocol?.maxLevelFor,
              baseline: {
                for (final ear in Ear.values) ear: _previous.thresholdsFor(ear),
              },
              baselineLabel:
                  'Earlier (${_dateFormat.format(_previous.testedAt)})',
            ),
            const SizedBox(height: 22),
            const SectionLabel('Change since earlier test'),
            const SizedBox(height: 4),
            const Text(
              'Positive numbers mean thresholds got worse (louder tones needed).',
              style: TextStyle(fontSize: 12, color: AurisTheme.muted),
            ),
            const SizedBox(height: 12),
            for (final ear in Ear.values) ...[
              _changeTable(ear, frequencies),
              const SizedBox(height: 14),
            ],
            const SizedBox(height: 6),
            _ptaComparison(),
          ],
        ],
      ),
    );
  }

  Widget _picker({
    required String label,
    required TestSession value,
    required ValueChanged<TestSession> onChanged,
  }) =>
      AurisCard(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        child: Row(
          children: [
            SizedBox(width: 92, child: SectionLabel(label)),
            Expanded(
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  isExpanded: true,
                  value: value.id,
                  items: [
                    for (final session in widget.sessions)
                      DropdownMenuItem(
                        value: session.id,
                        child: Text(
                          DateFormat('d MMM yyyy, HH:mm')
                              .format(session.testedAt),
                          style: const TextStyle(fontSize: 14),
                        ),
                      ),
                  ],
                  onChanged: (id) {
                    if (id == null) return;
                    onChanged(widget.sessions.firstWhere((s) => s.id == id));
                  },
                ),
              ),
            ),
          ],
        ),
      );

  Widget _changeTable(Ear ear, List<int> frequencies) {
    final now = _current.thresholdsFor(ear);
    final before = _previous.thresholdsFor(ear);
    final nowFloor = _current.floorFrequenciesFor(ear);
    final beforeFloor = _previous.floorFrequenciesFor(ear);
    final nowNe = _current.notEstablishedFor(ear);
    final beforeNe = _previous.notEstablishedFor(ear);
    final color = ear == Ear.right ? AurisTheme.rightEar : AurisTheme.leftEar;

    /// null when either test lacks an exact value at this frequency: not
    /// tested, no response, not established, or only "at or below" the floor.
    int? delta(int hz) {
      final a = before[hz], b = now[hz];
      if (!before.containsKey(hz) || !now.containsKey(hz)) return null;
      if (a == null || b == null) return null; // a no-response has no number
      if (nowFloor.contains(hz) || beforeFloor.contains(hz)) return null;
      return b - a;
    }

    String show(Map<int, int?> values, Set<int> floor, Set<int> ne, int hz) {
      if (ne.contains(hz)) return 'NE';
      if (!values.containsKey(hz)) return '-';
      final v = values[hz];
      if (v == null) return 'NR';
      return floor.contains(hz) ? '≤$v' : '$v';
    }

    final hasAny = frequencies.any((hz) => delta(hz) != null);

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AurisTheme.cardRadius),
        border: Border.all(color: AurisTheme.hairline),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Container(
            width: double.infinity,
            color: color.withValues(alpha: 0.07),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Text(
              '${ear.label} ear (${ear.marker})',
              style: TextStyle(
                  fontSize: 12.5, fontWeight: FontWeight.w700, color: color),
            ),
          ),
          if (!hasAny)
            const Padding(
              padding: EdgeInsets.all(14),
              child: Text('No comparable frequencies.',
                  style: TextStyle(fontSize: 13, color: AurisTheme.muted)),
            )
          else
            Table(
              border: const TableBorder.symmetric(
                inside:
                    BorderSide(color: AurisTheme.hairline, width: 0.7),
              ),
              children: [
                TableRow(
                  decoration: const BoxDecoration(color: Color(0xFFF7F9FA)),
                  children: [
                    for (final text in ['Hz', 'Earlier', 'Later', 'Change'])
                      Padding(
                        padding: const EdgeInsets.symmetric(
                            vertical: 7, horizontal: 6),
                        child: Text(text,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w700,
                                color: AurisTheme.muted)),
                      ),
                  ],
                ),
                for (final hz in frequencies)
                  _changeRow(
                    hz,
                    show(before, beforeFloor, beforeNe, hz),
                    show(now, nowFloor, nowNe, hz),
                    delta(hz),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  TableRow _changeRow(int hz, String before, String now, int? delta) {
    final significant = delta != null && delta.abs() >= _significantShiftDb;
    final worse = (delta ?? 0) > 0;

    Widget cell(String text, {Color? color, FontWeight? weight}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
          child: Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12.5,
              color: color ?? AurisTheme.ink,
              fontWeight: weight ?? FontWeight.w400,
            ),
          ),
        );

    return TableRow(
      decoration: significant
          ? BoxDecoration(
              color: (worse ? AurisTheme.warning : AurisTheme.success)
                  .withValues(alpha: 0.09))
          : null,
      children: [
        cell(formatHzShort(hz),
            color: AurisTheme.muted, weight: FontWeight.w600),
        cell(before),
        cell(now),
        cell(
          delta == null ? '-' : (delta > 0 ? '+$delta' : '$delta'),
          color: !significant
              ? AurisTheme.muted
              : (worse ? AurisTheme.warning : AurisTheme.success),
          weight: significant ? FontWeight.w700 : FontWeight.w400,
        ),
      ],
    );
  }

  Widget _ptaComparison() => AurisCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionLabel('Pure-tone average'),
            const SizedBox(height: 10),
            for (final ear in Ear.values)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Builder(builder: (context) {
                  final now = _current.ptaFor(ear);
                  final before = _previous.ptaFor(ear);
                  final color = ear == Ear.right
                      ? AurisTheme.rightEar
                      : AurisTheme.leftEar;

                  final text = (now == null || before == null)
                      ? 'Not comparable'
                      : '${before.displayValue}  →  ${now.displayValue}'
                          '   (${now.degree.label})';

                  return Row(
                    children: [
                      SizedBox(
                        width: 58,
                        child: Text(ear.label,
                            style: TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w700,
                                color: color)),
                      ),
                      Expanded(
                        child: Text(text,
                            style: const TextStyle(
                                fontSize: 13.5, color: AurisTheme.ink)),
                      ),
                    ],
                  );
                }),
              ),
          ],
        ),
      );
}
