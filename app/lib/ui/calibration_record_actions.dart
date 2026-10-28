import 'package:flutter/material.dart';
import 'package:printing/printing.dart';

import '../data/calibration_history.dart';
import '../report/calibration_report.dart';
import 'app_scope.dart';

/// Opens the system print dialog for a calibration record. On every platform
/// that dialog also offers "Save as PDF".
Future<void> printCalibrationRecord(
    BuildContext context, CalibrationEvent event) async {
  final report = CalibrationRecordReport(
    event: event,
    clinic: AppScope.of(context).clinic,
  );
  try {
    await Printing.layoutPdf(
      onLayout: (_) => report.build(),
      name: report.fileName,
    );
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not create the PDF: $e')));
    }
  }
}

/// Shares a calibration record as a PDF file.
Future<void> shareCalibrationRecord(
    BuildContext context, CalibrationEvent event) async {
  final report = CalibrationRecordReport(
    event: event,
    clinic: AppScope.of(context).clinic,
  );
  try {
    final bytes = await report.build();
    await Printing.sharePdf(bytes: bytes, filename: report.fileName);
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not create the PDF: $e')));
    }
  }
}
