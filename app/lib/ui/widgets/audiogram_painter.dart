import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/audiometry/audiometry.dart';

/// Colours for the audiogram. Kept explicit rather than pulled from the app
/// theme so the PDF can render on white regardless of the on-screen theme.
class AudiogramStyle {
  const AudiogramStyle({
    this.background = Colors.white,
    this.axis = const Color(0xFF37474F),
    this.grid = const Color(0xFFCFD8DC),
    this.minorGrid = const Color(0xFFECEFF1),
    this.label = const Color(0xFF455A64),
    // Clinical convention, and it is not arbitrary: red/O for right, blue/X for
    // left is standard on every audiogram an ENT will have read.
    this.rightEar = const Color(0xFFD32F2F),
    this.leftEar = const Color(0xFF1976D2),
    this.normalBand = const Color(0x1A4CAF50),
    this.baseline = const Color(0xFF9E9E9E),
  });

  final Color background;
  final Color axis;
  final Color grid;
  final Color minorGrid;
  final Color label;
  final Color rightEar;
  final Color leftEar;
  final Color normalBand;
  final Color baseline;

  Color forEar(Ear ear) => ear == Ear.right ? rightEar : leftEar;
}

/// Draws a standard clinical pure-tone audiogram.
///
/// Conventions implemented here, all of them load-bearing for an ENT reading
/// the chart:
///
///  * **Frequency on a logarithmic X axis.** Each octave gets equal width,
///    matching how pitch is perceived and how every printed audiogram is laid
///    out.
///  * **Hearing level on an inverted Y axis**, 0 dB HL at the top. Better
///    hearing is higher on the page, so a hearing loss reads as a chart that
///    slopes downwards.
///  * **O for the right ear, X for the left**, red and blue respectively.
///  * **Right ear joined with a solid line, left ear with a dashed line**, so
///    the two are distinguishable in a black-and-white printout.
///  * **Square grid.** One octave across is the same length as 20 dB down,
///    as ASHA (2005) recommends, whatever the size of the canvas. The chart
///    is centred in any space left over.
///  * **No-response points** are drawn with a downward arrow and are never
///    joined to neighbouring points - the true threshold is unknown, and a line
///    would imply a measurement that was not made.
/// The loudest level presented at [frequencyHz] in [ear]: where a
/// no-response symbol belongs. See `TestProtocolRecord.maxLevelFor`.
typedef NoResponseLevel = int Function(Ear ear, int frequencyHz);

class AudiogramPainter extends CustomPainter {
  AudiogramPainter({
    required this.series,
    this.baseline,
    this.style = const AudiogramStyle(),
    this.drawBackground = true,
    this.noResponseLevel,
  });

  /// Where [series]' no-responses are drawn. Null draws them all at
  /// [kMaxLevelDbHl].
  final NoResponseLevel? noResponseLevel;

  /// Thresholds per ear, keyed by frequency. A null value is a no-response.
  final Map<Ear, Map<int, int?>> series;

  /// An earlier test drawn faintly underneath, for retest comparison.
  final Map<Ear, Map<int, int?>>? baseline;

  final AudiogramStyle style;
  final bool drawBackground;

  /// Axis bounds. 125-8000 Hz and -10 to 120 dB HL is the standard chart area.
  static const int _minHz = 125;
  static const int _maxHz = 8000;
  static const int _minDb = -10;
  static const int _maxDb = 120;
  static const List<int> _gridHz = [125, 250, 500, 1000, 2000, 4000, 8000];

  /// Interoctave frequencies, drawn as lighter lines without labels.
  static const List<int> _minorGridHz = [750, 1500, 3000, 6000];

  /// Octaves across the chart and 20 dB steps down it. Their ratio fixes the
  /// shape of the plot area so each octave by 20 dB cell is square.
  static final double _octaves = math.log(_maxHz / _minHz) / math.ln2;
  static const double _twentyDbSteps = (_maxDb - _minDb) / 20;

  static const double _padLeft = 46;
  static const double _padRight = 14;
  static const double _padTop = 34;
  static const double _padBottom = 26;

  @override
  void paint(Canvas canvas, Size size) {
    if (drawBackground) {
      canvas.drawRect(
        Offset.zero & size,
        Paint()..color = style.background,
      );
    }

    final plot = plotRect(size);

    _drawNormalBand(canvas, plot);
    _drawGrid(canvas, plot);
    _drawAxisLabels(canvas, plot);

    final earlier = baseline;
    if (earlier != null) {
      for (final ear in Ear.values) {
        _drawSeries(canvas, plot, ear, earlier[ear] ?? const {},
            color: style.baseline, faded: true);
      }
    }

    for (final ear in Ear.values) {
      _drawSeries(canvas, plot, ear, series[ear] ?? const {},
          color: style.forEar(ear), faded: false, nrLevel: noResponseLevel);
    }
  }

  // ------------------------------------------------------------- projection

  /// The plot area for a canvas of [size]: as large as fits, with square
  /// octave by 20 dB cells, centred horizontally.
  static Rect plotRect(Size size) {
    final availableWidth = math.max(1.0, size.width - _padLeft - _padRight);
    final availableHeight = math.max(1.0, size.height - _padTop - _padBottom);
    final unit = math.min(
        availableWidth / _octaves, availableHeight / _twentyDbSteps);
    final width = unit * _octaves;
    final height = unit * _twentyDbSteps;
    final left = _padLeft + (availableWidth - width) / 2;
    return Rect.fromLTWH(left, _padTop, width, height);
  }

  double _x(Rect plot, num hz) {
    final t = (math.log(hz.clamp(_minHz, _maxHz)) - math.log(_minHz)) /
        (math.log(_maxHz) - math.log(_minHz));
    return plot.left + t * plot.width;
  }

  double _y(Rect plot, num db) {
    final t = (db.clamp(_minDb, _maxDb) - _minDb) / (_maxDb - _minDb);
    return plot.top + t * plot.height; // inverted: -10 dB at the top
  }

  // ----------------------------------------------------------------- chrome

  /// Shades 0-25 dB HL, the range conventionally reported as normal hearing.
  void _drawNormalBand(Canvas canvas, Rect plot) {
    canvas.drawRect(
      Rect.fromLTRB(plot.left, _y(plot, 0), plot.right, _y(plot, 25)),
      Paint()..color = style.normalBand,
    );
  }

  void _drawGrid(Canvas canvas, Rect plot) {
    final minor = Paint()
      ..color = style.minorGrid
      ..strokeWidth = 0.5;
    final major = Paint()
      ..color = style.grid
      ..strokeWidth = 1;

    for (var db = _minDb; db <= _maxDb; db += 5) {
      final y = _y(plot, db);
      canvas.drawLine(
          Offset(plot.left, y), Offset(plot.right, y), db % 10 == 0 ? major : minor);
    }
    for (final hz in _minorGridHz) {
      final x = _x(plot, hz);
      canvas.drawLine(Offset(x, plot.top), Offset(x, plot.bottom), minor);
    }
    for (final hz in _gridHz) {
      final x = _x(plot, hz);
      canvas.drawLine(Offset(x, plot.top), Offset(x, plot.bottom), major);
    }

    canvas.drawRect(
      plot,
      Paint()
        ..color = style.axis
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4,
    );

    // 0 dB HL is the reference line - normal hearing threshold.
    canvas.drawLine(
      Offset(plot.left, _y(plot, 0)),
      Offset(plot.right, _y(plot, 0)),
      Paint()
        ..color = style.axis.withValues(alpha: 0.55)
        ..strokeWidth = 1.2,
    );
  }

  void _drawAxisLabels(Canvas canvas, Rect plot) {
    for (var db = _minDb; db <= _maxDb; db += 10) {
      _text(canvas, '$db', Offset(plot.left - 8, _y(plot, db)),
          align: TextAlign.right, anchorRight: true, centreVertically: true);
    }
    for (final hz in _gridHz) {
      final label = formatHzShort(hz);
      _text(canvas, label, Offset(_x(plot, hz), plot.top - 16), centre: true);
    }

    _text(canvas, 'Frequency (Hz)',
        Offset(plot.center.dx, plot.top - 32), centre: true, bold: true);
    _text(canvas, 'dB HL', Offset(plot.left - 40, plot.top - 16), bold: true);
  }

  // ----------------------------------------------------------------- series

  void _drawSeries(
    Canvas canvas,
    Rect plot,
    Ear ear,
    Map<int, int?> thresholds, {
    required Color color,
    required bool faded,
    NoResponseLevel? nrLevel,
  }) {
    if (thresholds.isEmpty) return;

    final opacity = faded ? 0.45 : 1.0;
    final paint = Paint()
      ..color = color.withValues(alpha: opacity)
      ..style = PaintingStyle.stroke
      ..strokeWidth = faded ? 1.4 : 2.0;

    final frequencies = thresholds.keys.toList()..sort();

    // Join consecutive measured points only. A no-response breaks the line,
    // because connecting through it would draw a threshold nobody measured.
    Offset? previous;
    for (final hz in frequencies) {
      final db = thresholds[hz];
      if (db == null) {
        previous = null;
        continue;
      }
      final point = Offset(_x(plot, hz), _y(plot, db));
      if (previous != null) {
        if (ear == Ear.left) {
          _dashedLine(canvas, previous, point, paint);
        } else {
          canvas.drawLine(previous, point, paint);
        }
      }
      previous = point;
    }

    for (final hz in frequencies) {
      final db = thresholds[hz];
      final isNoResponse = db == null;
      final level = db ?? nrLevel?.call(ear, hz) ?? _maxLevelForNoResponse;
      final centre = Offset(_x(plot, hz), _y(plot, level));

      if (ear == Ear.right) {
        _circleMarker(canvas, centre, color.withValues(alpha: opacity), faded);
      } else {
        _crossMarker(canvas, centre, color.withValues(alpha: opacity), faded);
      }
      if (isNoResponse) {
        _noResponseArrow(
            canvas, centre, ear, color.withValues(alpha: opacity), faded);
      }
    }
  }

  /// Where a no-response symbol is plotted: at the loudest level the app can
  /// present, with an arrow indicating the real threshold is beyond it.
  static const int _maxLevelForNoResponse = kMaxLevelDbHl;

  static const double _markerRadius = 6.0;

  void _circleMarker(Canvas canvas, Offset c, Color color, bool faded) {
    canvas.drawCircle(
      c,
      _markerRadius,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = faded ? 1.6 : 2.2,
    );
  }

  void _crossMarker(Canvas canvas, Offset c, Color color, bool faded) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = faded ? 1.6 : 2.2
      ..strokeCap = StrokeCap.round;
    const r = _markerRadius;
    canvas.drawLine(c + const Offset(-r, -r), c + const Offset(r, r), paint);
    canvas.drawLine(c + const Offset(-r, r), c + const Offset(r, -r), paint);
  }

  /// The "no response" arrow: down and away from the midline, per convention.
  void _noResponseArrow(Canvas canvas, Offset c, Ear ear, Color color, bool faded) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = faded ? 1.6 : 2.2
      ..strokeCap = StrokeCap.round;

    final dx = ear == Ear.right ? -1.0 : 1.0;
    final start = c + Offset(dx * 2, _markerRadius);
    final end = start + Offset(dx * 9, 13);
    canvas.drawLine(start, end, paint);
    canvas.drawLine(end, end + Offset(-dx * 6, -2), paint);
    canvas.drawLine(end, end + const Offset(0, -7), paint);
  }

  void _dashedLine(Canvas canvas, Offset a, Offset b, Paint paint) {
    const dash = 6.0, gap = 4.0;
    final total = (b - a).distance;
    if (total == 0) return;
    final step = (b - a) / total;
    var travelled = 0.0;
    while (travelled < total) {
      final end = math.min(travelled + dash, total);
      canvas.drawLine(a + step * travelled, a + step * end, paint);
      travelled = end + gap;
    }
  }

  void _text(
    Canvas canvas,
    String value,
    Offset at, {
    TextAlign align = TextAlign.left,
    bool centre = false,
    bool anchorRight = false,
    bool centreVertically = false,
    bool bold = false,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: value,
        style: TextStyle(
          color: style.label,
          fontSize: 10,
          fontWeight: bold ? FontWeight.w600 : FontWeight.w400,
        ),
      ),
      textAlign: align,
      textDirection: TextDirection.ltr,
    )..layout();

    var dx = at.dx;
    if (centre) dx -= painter.width / 2;
    if (anchorRight) dx -= painter.width;
    final dy = centreVertically ? at.dy - painter.height / 2 : at.dy;
    painter.paint(canvas, Offset(dx, dy));
  }

  @override
  bool shouldRepaint(covariant AudiogramPainter old) =>
      old.series != series || old.baseline != baseline || old.style != style;
}

/// Rasterises an audiogram without needing it on screen.
///
/// The PDF report and the on-screen chart are produced by the same painter, so
/// a printed audiogram cannot drift out of step with the one the clinician
/// approved.
Future<ui.Image> renderAudiogramImage({
  required Map<Ear, Map<int, int?>> series,
  Map<Ear, Map<int, int?>>? baseline,
  Size size = const Size(560, 590),
  double pixelRatio = 2.0,
  AudiogramStyle style = const AudiogramStyle(),
  NoResponseLevel? noResponseLevel,
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);

  canvas.scale(pixelRatio);
  AudiogramPainter(
    series: series,
    baseline: baseline,
    style: style,
    noResponseLevel: noResponseLevel,
  ).paint(canvas, size);

  return recorder.endRecording().toImage(
        (size.width * pixelRatio).round(),
        (size.height * pixelRatio).round(),
      );
}
