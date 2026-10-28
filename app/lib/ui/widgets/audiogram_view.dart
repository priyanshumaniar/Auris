import 'package:flutter/material.dart';

import '../../core/audiometry/audiometry.dart';
import '../theme.dart';
import 'audiogram_painter.dart';

/// On-screen audiogram with a legend.
///
/// Close to square, because the chart itself keeps square octave by 20 dB
/// cells (ASHA 2005) and would otherwise leave wide empty margins.
class AudiogramView extends StatelessWidget {
  const AudiogramView({
    super.key,
    required this.series,
    this.baseline,
    this.baselineLabel,
    this.showLegend = true,
    this.noResponseLevel,
  });

  /// Where [series]' no-responses are drawn; see [AudiogramPainter].
  final NoResponseLevel? noResponseLevel;

  final Map<Ear, Map<int, int?>> series;
  final Map<Ear, Map<int, int?>>? baseline;
  final String? baselineLabel;
  final bool showLegend;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AspectRatio(
          aspectRatio: 1.0,
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(AurisTheme.cardRadius),
              border: Border.all(color: AurisTheme.hairline),
            ),
            padding: const EdgeInsets.all(6),
            child: CustomPaint(
              painter: AudiogramPainter(
                series: series,
                baseline: baseline,
                drawBackground: false,
                noResponseLevel: noResponseLevel,
              ),
              size: Size.infinite,
            ),
          ),
        ),
        if (showLegend) ...[
          const SizedBox(height: 10),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 18,
            runSpacing: 6,
            children: [
              const _LegendEntry(
                  symbol: 'O', label: 'Right ear', color: AurisTheme.rightEar),
              const _LegendEntry(
                  symbol: 'X', label: 'Left ear', color: AurisTheme.leftEar),
              if (baseline != null)
                _LegendEntry(
                  symbol: '-',
                  label: baselineLabel ?? 'Previous test',
                  color: Colors.grey.shade600,
                ),
            ],
          ),
        ],
      ],
    );
  }
}

class _LegendEntry extends StatelessWidget {
  const _LegendEntry({
    required this.symbol,
    required this.label,
    required this.color,
  });

  final String symbol;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(symbol,
              style: TextStyle(
                  fontSize: 15, fontWeight: FontWeight.bold, color: color)),
          const SizedBox(width: 6),
          Text(label,
              style: const TextStyle(fontSize: 12.5, color: AurisTheme.muted)),
        ],
      );
}

/// Compact per-frequency threshold table shown under the chart.
///
/// NR is no response at the maximum level, "≤" marks a result at the quietest
/// level the app can present, NE is a threshold that was not established, and
/// "-" is a frequency that was not tested.
class ThresholdTable extends StatelessWidget {
  const ThresholdTable({
    super.key,
    required this.series,
    required this.frequencies,
    this.floor = const {},
    this.notEstablished = const {},
  });

  final Map<Ear, Map<int, int?>> series;
  final List<int> frequencies;
  final Map<Ear, Set<int>> floor;
  final Map<Ear, Set<int>> notEstablished;

  @override
  Widget build(BuildContext context) {
    String cell(Ear ear, int hz) {
      if (notEstablished[ear]?.contains(hz) ?? false) return 'NE';
      final map = series[ear] ?? const {};
      if (!map.containsKey(hz)) return '-';
      // NR = no response at maximum output. Distinct from "not tested".
      if (map[hz] == null) return 'NR';
      final atFloor = floor[ear]?.contains(hz) ?? false;
      return atFloor ? '≤${map[hz]}' : '${map[hz]}';
    }

    TableRow row(String label, Color color, Ear? ear) => TableRow(
          decoration: ear == null
              ? const BoxDecoration(color: Color(0xFFF2F5F7))
              : null,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
              child: Text(label,
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: color)),
            ),
            for (final hz in frequencies)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 2),
                // Shrinks rather than wraps: "≤-10" broken over two lines
                // reads as two different numbers on a narrow phone.
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    ear == null ? formatHzShort(hz) : cell(ear, hz),
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    softWrap: false,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight:
                          ear == null ? FontWeight.w600 : FontWeight.w400,
                      color: AurisTheme.ink,
                    ),
                  ),
                ),
              ),
          ],
        );

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AurisTheme.cardRadius),
        border: Border.all(color: AurisTheme.hairline),
      ),
      clipBehavior: Clip.antiAlias,
      child: Table(
        border: const TableBorder.symmetric(
          inside: BorderSide(color: AurisTheme.hairline, width: 0.7),
        ),
        columnWidths: {
          0: const FixedColumnWidth(74),
          for (var i = 1; i <= frequencies.length; i++)
            i: const FlexColumnWidth(),
        },
        children: [
          row('Hz', AurisTheme.muted, null),
          row('Right (O)', AurisTheme.rightEar, Ear.right),
          row('Left (X)', AurisTheme.leftEar, Ear.left),
        ],
      ),
    );
  }
}
