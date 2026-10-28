import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/audiometry/audiometry.dart';
import '../../core/audiometry/calibration.dart';
import '../../data/calibration_history.dart';
import '../app_scope.dart';
import '../calibration_record_actions.dart';
import '../theme.dart';

/// Every calibration done on this device, newest first, each with a printable
/// record. Calibration belongs to the device, so this history is stored on the
/// device and is not synced.
class CalibrationHistoryScreen extends StatefulWidget {
  const CalibrationHistoryScreen({super.key});

  @override
  State<CalibrationHistoryScreen> createState() =>
      _CalibrationHistoryScreenState();
}

class _CalibrationHistoryScreenState extends State<CalibrationHistoryScreen> {
  static final _date = DateFormat('d MMM yyyy, HH:mm');
  Future<List<CalibrationEvent>>? _events;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _events ??= AppScope.of(context).calibrationHistory?.all() ??
        Future.value(const <CalibrationEvent>[]);
  }

  String _earsSummary(CalibrationEvent e) {
    if (e.isReset) return 'Calibration reset to uncalibrated';
    String part(Ear ear) => '${ear.label}: ${e.recordFor(ear).action.label}';
    return '${e.method.label}. ${part(Ear.right)}. ${part(Ear.left)}.';
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Calibration history')),
        body: FutureBuilder<List<CalibrationEvent>>(
          future: _events,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(28),
                  child: Text(
                    'The calibration history could not be read. '
                    '${snapshot.error}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: AurisTheme.muted, height: 1.5),
                  ),
                ),
              );
            }
            final events = snapshot.data ?? const [];
            if (events.isEmpty) {
              return const Center(
                child: Padding(
                  padding: EdgeInsets.all(28),
                  child: Text(
                    'No calibrations recorded on this device yet. Calibrations '
                    'made from now on appear here, each with a printable '
                    'record.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: AurisTheme.muted, height: 1.5),
                  ),
                ),
              );
            }
            return ListView.separated(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
              itemCount: events.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (context, i) {
                final e = events[i];
                final human = e.profile.usesHumanListener && !e.isReset;
                return AurisCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            e.isReset
                                ? Icons.restart_alt_rounded
                                : e.method == CalibrationMethod.soundLevelMeter
                                    ? Icons.verified_rounded
                                    : Icons.person_search_rounded,
                            size: 20,
                            color: AurisTheme.primary,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              _date.format(e.performedAt),
                              style: const TextStyle(
                                  fontSize: 14.5,
                                  fontWeight: FontWeight.w700,
                                  color: AurisTheme.ink),
                            ),
                          ),
                          if (i == 0)
                            const Text('Latest',
                                style: TextStyle(
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w700,
                                    color: AurisTheme.success)),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        _earsSummary(e),
                        style: const TextStyle(
                            fontSize: 12.5,
                            height: 1.45,
                            color: AurisTheme.ink),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${e.profile.transducerName} · by ${e.performedBy}',
                        style: const TextStyle(
                            fontSize: 12, color: AurisTheme.muted),
                      ),
                      if (human || e.imbalanceAccepted) ...[
                        const SizedBox(height: 6),
                        Text(
                          [
                            if (human) 'Human-listener calibration',
                            if (e.imbalanceAccepted)
                              'Saved despite a '
                                  '${e.imbalanceDb?.toStringAsFixed(1)} dB '
                                  'left/right difference',
                          ].join(' · '),
                          style: const TextStyle(
                              fontSize: 12, color: AurisTheme.warning),
                        ),
                      ],
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        children: [
                          TextButton.icon(
                            onPressed: () => printCalibrationRecord(context, e),
                            icon: const Icon(Icons.print_rounded, size: 18),
                            label: const Text('View / print PDF'),
                          ),
                          TextButton.icon(
                            onPressed: () => shareCalibrationRecord(context, e),
                            icon: const Icon(Icons.ios_share_rounded, size: 18),
                            label: const Text('Share PDF'),
                          ),
                        ],
                      ),
                    ],
                  ),
                );
              },
            );
          },
        ),
      );
}
