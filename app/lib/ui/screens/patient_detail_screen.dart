import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/audiometry/audiometry.dart';
import '../../core/audiometry/calibration.dart';
import '../../data/models/clinic_role.dart';
import '../../data/models/patient.dart';
import '../../data/models/test_session.dart';
import '../../utils/route_constants.dart';
import '../app_scope.dart';
import '../theme.dart';
import '../widgets/auris_button.dart';

/// A patient's record: details, test history, and the entry point for a new
/// test or a retest comparison.
class PatientDetailScreen extends StatefulWidget {
  const PatientDetailScreen({super.key, required this.patient});

  final Patient patient;

  @override
  State<PatientDetailScreen> createState() => _PatientDetailScreenState();
}

class _PatientDetailScreenState extends State<PatientDetailScreen> {
  static final _dateFormat = DateFormat('d MMM yyyy, HH:mm');

  late Patient _patient;
  List<TestSession> _sessions = const [];
  bool _loading = true;

  ClinicRole get _role => AppScope.of(context).auth.role;

  @override
  void initState() {
    super.initState();
    _patient = widget.patient;
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final repo = AppScope.of(context).repository;
    try {
      final sessions = await repo.listSessions(_patient.id);
      final refreshed = await repo.getPatient(_patient.id);
      if (!mounted) return;
      setState(() {
        _sessions = sessions;
        if (refreshed != null) _patient = refreshed;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not load the tests. $e')),
      );
    }
  }

  Future<void> _startTest() async {
    await Navigator.pushNamed(context, testSetupRoute, arguments: _patient);
    if (mounted) await _load();
  }

  Future<void> _confirmDelete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete patient?'),
        content: Text(
          'This permanently deletes ${_patient.fullName} and all '
          '${_sessions.length} test${_sessions.length == 1 ? '' : 's'} on record. '
          'This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: AurisTheme.rightEar),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;
    try {
      await AppScope.of(context).repository.deletePatient(_patient.id);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not delete the patient. $e')),
      );
      return;
    }
    if (!mounted) return;
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_patient.fullName),
        actions: [
          if (_sessions.length >= 2)
            IconButton(
              tooltip: 'Compare tests',
              icon: const Icon(Icons.compare_arrows_rounded),
              onPressed: () => Navigator.pushNamed(
                context,
                comparisonRoute,
                arguments: (patient: _patient, sessions: _sessions),
              ),
            ),
          if (_role.canEditPatients || _role.canDeletePatients)
            PopupMenuButton<String>(
              onSelected: (value) async {
                if (value == 'edit') {
                  final updated = await Navigator.pushNamed(
                      context, patientFormRoute,
                      arguments: _patient);
                  if (updated is Patient && mounted) {
                    setState(() => _patient = updated);
                  }
                  await _load();
                } else if (value == 'delete') {
                  await _confirmDelete();
                }
              },
              itemBuilder: (context) => [
                if (_role.canEditPatients)
                  const PopupMenuItem(
                      value: 'edit', child: Text('Edit details')),
                if (_role.canDeletePatients)
                  const PopupMenuItem(
                      value: 'delete', child: Text('Delete patient')),
              ],
            ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
          children: [
            _detailsCard(),
            const SizedBox(height: 18),
            if (_role.canRunTests)
              Center(
                child: AurisButton(
                  buttonName:
                      _sessions.isEmpty ? 'Start first test' : 'New test',
                  width: 240,
                  onTap: _startTest,
                ),
              )
            else
              const AurisCard(
                padding: EdgeInsets.all(13),
                child: Row(
                  children: [
                    Icon(Icons.lock_outline_rounded,
                        size: 18, color: AurisTheme.muted),
                    SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Your role can review history and print reports, but '
                        'not run new tests.',
                        style: TextStyle(
                            fontSize: 12.5, color: AurisTheme.muted),
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 26),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const SectionLabel('Test history'),
                Text(
                  '${_sessions.length} test${_sessions.length == 1 ? '' : 's'}',
                  style: const TextStyle(fontSize: 12, color: AurisTheme.muted),
                ),
              ],
            ),
            const SizedBox(height: 10),
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 30),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_sessions.isEmpty)
              const AurisCard(
                padding: EdgeInsets.all(22),
                child: Column(
                  children: [
                    Icon(Icons.timeline_rounded,
                        size: 32, color: AurisTheme.muted),
                    SizedBox(height: 10),
                    Text(
                      'No tests recorded yet.',
                      style:
                          TextStyle(fontSize: 13.5, color: AurisTheme.muted),
                    ),
                  ],
                ),
              )
            else
              for (final session in _sessions)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _sessionTile(session),
                ),
          ],
        ),
      ),
    );
  }

  Widget _detailsCard() => AurisCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 24,
              runSpacing: 12,
              children: [
                _field('Age', '${_patient.ageAt(DateTime.now())} years'),
                _field('Sex', _patient.sex),
                if (_patient.clinicRef != null)
                  _field('Patient ID', _patient.clinicRef!),
                if (_patient.phone != null) _field('Phone', _patient.phone!),
              ],
            ),
            if (_patient.notes != null && _patient.notes!.trim().isNotEmpty) ...[
              const SizedBox(height: 14),
              const Divider(height: 1),
              const SizedBox(height: 12),
              const SectionLabel('Notes'),
              const SizedBox(height: 5),
              Text(_patient.notes!,
                  style: const TextStyle(
                      fontSize: 13.5, height: 1.5, color: AurisTheme.ink)),
            ],
          ],
        ),
      );

  Widget _field(String label, String value) => SizedBox(
        width: 120,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionLabel(label),
            const SizedBox(height: 3),
            Text(value,
                style: const TextStyle(fontSize: 14.5, color: AurisTheme.ink)),
          ],
        ),
      );

  Widget _sessionTile(TestSession session) {
    final right = session.ptaFor(Ear.right);
    final left = session.ptaFor(Ear.left);

    return AurisCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      onTap: () async {
        await Navigator.pushNamed(
          context,
          resultsRoute,
          arguments: (patient: _patient, session: session, isFresh: false),
        );
        await _load();
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  _dateFormat.format(session.testedAt),
                  style: const TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w600,
                      color: AurisTheme.ink),
                ),
              ),
              if (!session.calibration.isCalibrated)
                Tooltip(
                  message: session.calibration.method == CalibrationMethod.none
                      ? 'Recorded on an uncalibrated device (or ear)'
                      : 'Calibrated with a human listener, not a meter',
                  child: const Icon(Icons.warning_amber_rounded,
                      size: 17, color: AurisTheme.warning),
                ),
              if (session.syncedAt != null) ...[
                const SizedBox(width: 6),
                const Tooltip(
                  message: 'Synced to cloud',
                  child: Icon(Icons.cloud_done_outlined,
                      size: 17, color: AurisTheme.muted),
                ),
              ],
              const SizedBox(width: 4),
              const Icon(Icons.chevron_right_rounded,
                  color: AurisTheme.muted, size: 20),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              _ptaChip('Right', session.ptaDisplayFor(Ear.right),
                  right?.degree.label,
                  AurisTheme.rightEar),
              const SizedBox(width: 8),
              _ptaChip('Left', session.ptaDisplayFor(Ear.left),
                  left?.degree.label,
                  AurisTheme.leftEar),
            ],
          ),
        ],
      ),
    );
  }

  Widget _ptaChip(String ear, String? pta, String? degree, Color color) =>
      Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.07),
            borderRadius: BorderRadius.circular(9),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(ear.toUpperCase(),
                  style: TextStyle(
                      fontSize: 9,
                      letterSpacing: 0.6,
                      fontWeight: FontWeight.w700,
                      color: color)),
              const SizedBox(height: 2),
              Text(
                pta == null ? 'Not tested' : 'PTA $pta',
                style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AurisTheme.ink),
              ),
              if (degree != null)
                Text(degree,
                    style: const TextStyle(
                        fontSize: 11, color: AurisTheme.muted)),
            ],
          ),
        ),
      );
}
