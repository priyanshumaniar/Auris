import 'dart:ui' as ui;

import 'package:auris/core/audiometry/audiometry.dart';
import 'package:auris/ui/theme.dart';
import 'package:auris/ui/widgets/audiogram_painter.dart';
import 'package:auris/ui/widgets/audiogram_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget wrap(Widget child) => MaterialApp(
      theme: AurisTheme.light(),
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

void main() {
  const series = <Ear, Map<int, int?>>{
    Ear.right: {250: 10, 500: 15, 1000: 20, 2000: 35, 4000: 55, 8000: null},
    Ear.left: {250: 5, 500: 10, 1000: 15, 2000: 25, 4000: 40, 8000: 60},
  };

  group('AudiogramView', () {
    testWidgets('renders the chart and legend', (tester) async {
      await tester.pumpWidget(wrap(const AudiogramView(series: series)));

      expect(find.byType(CustomPaint), findsWidgets);
      expect(find.text('Right ear'), findsOneWidget);
      expect(find.text('Left ear'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('renders with no data at all', (tester) async {
      // An empty audiogram is a real state - it is what the screen shows before
      // any threshold has been measured.
      await tester.pumpWidget(wrap(const AudiogramView(series: {})));
      expect(tester.takeException(), isNull);
    });

    testWidgets('shows a baseline entry when a previous test is supplied',
        (tester) async {
      await tester.pumpWidget(wrap(const AudiogramView(
        series: series,
        baseline: {
          Ear.right: {1000: 30},
          Ear.left: {1000: 35},
        },
        baselineLabel: 'Previous (1 Jan 2026)',
      )));

      expect(find.text('Previous (1 Jan 2026)'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('hides the legend when asked', (tester) async {
      await tester.pumpWidget(
          wrap(const AudiogramView(series: series, showLegend: false)));
      expect(find.text('Right ear'), findsNothing);
    });
  });

  group('ThresholdTable', () {
    testWidgets('renders thresholds, NR and untested cells distinctly',
        (tester) async {
      await tester.pumpWidget(wrap(const ThresholdTable(
        series: {
          Ear.right: {250: 10, 500: null}, // 500 Hz = no response
          Ear.left: {250: 5}, // 500 Hz never tested for the left ear
        },
        frequencies: [250, 500],
      )));

      expect(find.text('10'), findsOneWidget);
      expect(find.text('5'), findsOneWidget);
      expect(find.text('NR'), findsOneWidget,
          reason: 'no response at max output');
      expect(find.text('-'), findsOneWidget,
          reason: 'untested must not read as a measurement');
    });

    testWidgets('marks floor and not-established results', (tester) async {
      await tester.pumpWidget(wrap(const ThresholdTable(
        series: {
          Ear.right: {250: -10, 1500: 20},
        },
        frequencies: [250, 1000, 1500],
        floor: {
          Ear.right: {250},
        },
        notEstablished: {
          Ear.right: {1000},
        },
      )));

      expect(find.text('≤-10'), findsOneWidget);
      expect(find.text('NE'), findsOneWidget);
      expect(find.text('1.5k'), findsOneWidget);
    });

    testWidgets('labels frequencies in kHz above 1000', (tester) async {
      await tester.pumpWidget(wrap(const ThresholdTable(
        series: {
          Ear.right: {500: 10, 4000: 20}
        },
        frequencies: [500, 4000],
      )));

      expect(find.text('500'), findsOneWidget);
      expect(find.text('4k'), findsOneWidget);
    });
  });

  group('CalibrationWarning', () {
    testWidgets('shows the calibration link when a handler is given',
        (tester) async {
      var tapped = false;
      await tester.pumpWidget(wrap(CalibrationWarning(
        onOpenSettings: () => tapped = true,
      )));

      expect(find.textContaining('not calibrated'), findsOneWidget);
      await tester.tap(find.text('Calibrate this device →'));
      expect(tapped, isTrue);
    });

    testWidgets('omits the link when there is nowhere to go', (tester) async {
      await tester.pumpWidget(wrap(const CalibrationWarning()));
      expect(find.text('Calibrate this device →'), findsNothing);
    });
  });

  group('audiogram rasteriser', () {
    test('produces a PNG-able image at the requested size', () async {
      // The PDF report depends on this path working headlessly.
      final image = await renderAudiogramImage(
        series: series,
        size: const Size(400, 300),
        pixelRatio: 2.0,
      );

      expect(image.width, 800);
      expect(image.height, 600);

      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      expect(png, isNotNull);
      expect(png!.lengthInBytes, greaterThan(0));
    });
  });
}
