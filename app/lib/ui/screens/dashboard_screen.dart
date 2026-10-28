import 'package:flutter/material.dart';

import '../../data/account_service.dart';
import '../../data/auth_service.dart';
import '../../data/models/clinic.dart';
import '../../data/models/patient.dart';
import '../../utils/route_constants.dart';
import '../app_scope.dart';
import '../theme.dart';
import '../widgets/calibration_by_ear.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  late Future<List<Patient>> _patients;

  /// Requests waiting for this user's decision (clinic and super admins).
  int _waiting = 0;

  @override
  void initState() {
    super.initState();
    _patients = Future.value(const []);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _reload();
      _syncInBackground(force: true);
      _countApprovals();
    });
  }

  Future<void> _countApprovals() async {
    final services = AppScope.of(context);
    final admin = services.admin;
    if (admin == null || !services.auth.role.canManageUsers) {
      if (_waiting != 0) setState(() => _waiting = 0);
      return;
    }
    final n = await admin.pendingReviewCount();
    if (mounted) setState(() => _waiting = n);
  }

  Future<void> _openApprovals() async {
    final services = AppScope.of(context);
    final isSuper = services.auth.role.canManageClinics;
    await Navigator.pushNamed(
      context,
      isSuper ? adminConsoleRoute : clinicTeamRoute,
      arguments: 'approvals',
    );
    if (!mounted) return;
    await _refreshProfile();
  }

  Future<void> _openProfile() async {
    await Navigator.pushNamed(context, profileRoute);
    if (!mounted) return;
    await _refreshProfile();
  }

  /// Re-reads the profile (role, clinic, name) and everything shown here.
  /// [force] syncs even if a sync ran a moment ago, for pull-to-refresh.
  Future<void> _refreshProfile({bool force = false}) async {
    final auth = AppScope.of(context).auth;
    if (auth is SupabaseAuthService) await auth.refreshProfile();
    if (!mounted) return;
    setState(() {});
    _reload();
    await Future.wait([
      _syncInBackground(force: force),
      _countApprovals(),
    ]);
  }

  /// Brings the device copy up to date for whoever just signed in, then
  /// refreshes the list. Records on the device are shown by clinic, so this is
  /// also what makes a clinic's earlier records appear on a device that kept
  /// them from before records carried a clinic.
  ///
  /// Coming back to the dashboard does not sync again within a couple of
  /// minutes of the last sync; pull-to-refresh always does.
  Future<void> _syncInBackground({bool force = false}) async {
    final services = AppScope.of(context);
    final syncing = services.syncing;
    if (syncing == null || !services.auth.role.canViewRecords) return;
    final report =
        force ? await syncing.syncNow() : await syncing.syncIfStale();
    if (mounted && report != null) _reload();
  }

  void _reload() {
    // Braces, not an arrow: `setState(() => x = future)` returns the Future
    // from the closure, and setState asserts its callback returns nothing.
    setState(() {
      _patients = AppScope.of(context).repository.listPatients();
    });
  }

  Future<void> _signOut() async {
    await AppScope.of(context).auth.signOut();
    if (!mounted) return;
    Navigator.pushNamedAndRemoveUntil(context, loginRoute, (_) => false);
  }

  @override
  Widget build(BuildContext context) {
    final services = AppScope.of(context);
    final clinician = services.auth.currentClinician;
    final profile = services.calibration.profile;
    final calibrated = profile.isCalibrated;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Dashboard'),
        actions: [
          IconButton(
            tooltip: 'My profile',
            icon: const Icon(Icons.account_circle_outlined),
            onPressed: _openProfile,
          ),
          IconButton(
            tooltip: 'Settings & calibration',
            icon: const Icon(Icons.tune_rounded),
            onPressed: () async {
              await Navigator.pushNamed(context, settingsRoute);
              // Settings can sync, change the clinic or calibrate.
              if (mounted) await _refreshProfile();
            },
          ),
          IconButton(
            tooltip: 'Sign out',
            icon: const Icon(Icons.logout_rounded),
            onPressed: _signOut,
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => _refreshProfile(force: true),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
          children: [
            Text(
              clinician == null
                  ? 'Welcome'
                  : 'Welcome, ${clinician.displayName}',
              style: const TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w600,
                color: AurisTheme.ink,
              ),
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Icon(
                  services.cloudSyncEnabled
                      ? Icons.cloud_done_outlined
                      : Icons.phone_android_rounded,
                  size: 15,
                  color: AurisTheme.muted,
                ),
                const SizedBox(width: 6),
                Text(
                  !services.cloudSyncEnabled
                      ? 'Records stored on this device only'
                      : clinician?.clinicId == null
                          ? 'No clinic'
                          : '${services.clinic.name} · synced to the cloud',
                  style:
                      const TextStyle(fontSize: 12.5, color: AurisTheme.muted),
                ),
                const Text('  ·  ',
                    style: TextStyle(fontSize: 12.5, color: AurisTheme.muted)),
                Text(
                  services.auth.role.label,
                  style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: AurisTheme.primary),
                ),
              ],
            ),
            const SizedBox(height: 18),
            if (_waiting > 0)
              Padding(
                padding: const EdgeInsets.only(bottom: 18),
                child: AurisCard(
                  onTap: _openApprovals,
                  child: Row(
                    children: [
                      const Icon(Icons.how_to_reg_outlined,
                          size: 22, color: AurisTheme.warning),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          _waiting == 1
                              ? '1 request is waiting for your approval.'
                              : '$_waiting requests are waiting for your '
                                  'approval.',
                          style: const TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                              color: AurisTheme.ink),
                        ),
                      ),
                      const Icon(Icons.chevron_right_rounded,
                          color: AurisTheme.muted),
                    ],
                  ),
                ),
              ),
            if (!calibrated)
              Padding(
                padding: const EdgeInsets.only(bottom: 18),
                child: CalibrationWarning(
                  message: calibrationStatusMessage(profile),
                  onOpenSettings: () async {
                    await Navigator.pushNamed(context, settingsRoute);
                    if (mounted) setState(() {});
                  },
                ),
              ),
            if (!services.auth.role.canViewRecords) ...[
              _AwaitingApproval(
                cloud: services.cloudSyncEnabled,
                account: services.account,
                profile: services.auth is SupabaseAuthService
                    ? (services.auth as SupabaseAuthService).profile
                    : null,
                onCheckAgain: _refreshProfile,
              ),
            ] else if (services.cloudSyncEnabled &&
                clinician?.clinicId == null) ...[
              // A super admin without a home clinic: no patients to show.
              _NoHomeClinic(
                onOpenConsole: services.auth.role.canManageClinics
                    ? () => Navigator.pushNamed(context, adminConsoleRoute)
                    : null,
              ),
            ] else ...[
            const SectionLabel('Start'),
            const SizedBox(height: 10),
            if (services.auth.role.canRegisterPatients) ...[
              _ActionTile(
                icon: Icons.person_add_alt_1_rounded,
                title: 'New patient',
                subtitle: 'Register a patient, then run their first test',
                onTap: () async {
                  await Navigator.pushNamed(context, patientFormRoute);
                  if (mounted) _reload();
                },
              ),
              const SizedBox(height: 12),
            ],
            _ActionTile(
              icon: Icons.groups_2_rounded,
              title: 'Existing patients',
              subtitle: 'Open a record for history, retest or a report',
              onTap: () async {
                await Navigator.pushNamed(context, patientListRoute);
                if (mounted) _reload();
              },
            ),
            const SizedBox(height: 26),
            const SectionLabel('Recent patients'),
            const SizedBox(height: 10),
            FutureBuilder<List<Patient>>(
              future: _patients,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Padding(
                    padding: EdgeInsets.symmetric(vertical: 28),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                if (snapshot.hasError) {
                  return AurisCard(
                    child: Text('Could not load patients.\n${snapshot.error}',
                        style: const TextStyle(
                            fontSize: 13, color: AurisTheme.muted)),
                  );
                }

                final patients = snapshot.data ?? const [];
                if (patients.isEmpty) {
                  return const AurisCard(
                    padding: EdgeInsets.all(22),
                    child: Column(
                      children: [
                        Icon(Icons.folder_open_rounded,
                            size: 34, color: AurisTheme.muted),
                        SizedBox(height: 10),
                        Text(
                          'No patients yet.\nRegister your first patient to get started.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              fontSize: 13.5,
                              height: 1.5,
                              color: AurisTheme.muted),
                        ),
                      ],
                    ),
                  );
                }

                return Column(
                  children: [
                    for (final patient in patients.take(5))
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: PatientTile(
                          patient: patient,
                          onTap: () async {
                            await Navigator.pushNamed(
                                context, patientDetailRoute,
                                arguments: patient);
                            if (mounted) _reload();
                          },
                        ),
                      ),
                  ],
                );
              },
            ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Shown instead of the patient list to an account an administrator has not
/// approved yet. In cloud mode it also takes a clinic's join code, for
/// someone who signed up without one (Google sign-in has no field for it).
class _AwaitingApproval extends StatefulWidget {
  const _AwaitingApproval({
    required this.cloud,
    required this.account,
    required this.profile,
    required this.onCheckAgain,
  });

  final bool cloud;
  final AccountService account;

  /// The signed-in account, in cloud mode.
  final ClinicAccount? profile;
  final Future<void> Function() onCheckAgain;

  /// The code typed at sign-up, if any.
  String? get requestedCode => profile?.requestedClinic;

  /// Whether that code matched a clinic.
  bool get codeMatched => profile?.requestedClinicId != null;

  @override
  State<_AwaitingApproval> createState() => _AwaitingApprovalState();
}

class _AwaitingApprovalState extends State<_AwaitingApproval> {
  final _code = TextEditingController();
  bool _busy = false;
  String? _message;
  bool _messageIsError = false;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _sendRequest() async {
    final code = _code.text.trim();
    if (code.isEmpty) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final clinic = await widget.account.requestClinic(code);
      if (!mounted) return;
      setState(() {
        _message = 'Request sent to $clinic. You will get access once its '
            'administrator approves you.';
        _messageIsError = false;
      });
      _code.clear();
      await widget.onCheckAgain();
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() {
        _message = e.message;
        _messageIsError = true;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AurisCard(
        padding: const EdgeInsets.all(22),
        child: Column(
          children: [
            const Icon(Icons.hourglass_top_rounded,
                size: 34, color: AurisTheme.warning),
            const SizedBox(height: 12),
            const Text(
              'Waiting for approval',
              style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  color: AurisTheme.ink),
            ),
            const SizedBox(height: 8),
            Text(
              widget.cloud
                  ? 'Your account cannot see or add patient records until your '
                      'clinic\'s admin (or a super admin) approves it.'
                  : 'Your account cannot see or add patient records until an '
                      'administrator gives it a role in Settings, Team.',
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: 13.5, height: 1.5, color: AurisTheme.muted),
            ),
            if (widget.cloud) ...[
              const SizedBox(height: 14),
              if (widget.requestedCode != null)
                Text(
                  widget.codeMatched
                      ? 'You asked to join the clinic with code '
                          '${widget.requestedCode}.'
                      : 'The code ${widget.requestedCode} matches no clinic. '
                          'Check it with your clinic and enter it again.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13,
                    color: widget.codeMatched
                        ? AurisTheme.ink
                        : AurisTheme.rightEar,
                  ),
                ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _code,
                      textCapitalization: TextCapitalization.characters,
                      decoration: InputDecoration(
                        labelText: widget.codeMatched
                            ? 'A different join code'
                            : 'Clinic join code',
                        hintText: 'AUR-7K2PQ',
                      ),
                      onSubmitted: (_) => _sendRequest(),
                    ),
                  ),
                  const SizedBox(width: 10),
                  FilledButton(
                    onPressed: _busy ? null : _sendRequest,
                    child: const Text('Send'),
                  ),
                ],
              ),
              if (_message != null) ...[
                const SizedBox(height: 10),
                Text(
                  _message!,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: _messageIsError
                        ? AurisTheme.rightEar
                        : AurisTheme.success,
                  ),
                ),
              ],
              const SizedBox(height: 14),
              OutlinedButton.icon(
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('Check again'),
                onPressed: _busy ? null : widget.onCheckAgain,
              ),
            ],
          ],
        ),
      );
}

/// Shown to a super admin who has no home clinic.
class _NoHomeClinic extends StatelessWidget {
  const _NoHomeClinic({required this.onOpenConsole});

  final VoidCallback? onOpenConsole;

  @override
  Widget build(BuildContext context) => AurisCard(
        padding: const EdgeInsets.all(22),
        child: Column(
          children: [
            const Icon(Icons.admin_panel_settings_outlined,
                size: 34, color: AurisTheme.primary),
            const SizedBox(height: 12),
            const Text(
              'No clinic',
              style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  color: AurisTheme.ink),
            ),
            const SizedBox(height: 8),
            const Text(
              'Your account is not in a clinic, so there are no patient '
              'records to show. Clinics and accounts are managed in the admin '
              'console.',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 13.5, height: 1.5, color: AurisTheme.muted),
            ),
            if (onOpenConsole != null) ...[
              const SizedBox(height: 14),
              FilledButton.icon(
                icon: const Icon(Icons.admin_panel_settings_outlined, size: 18),
                label: const Text('Open the admin console'),
                onPressed: onOpenConsole,
              ),
            ],
          ],
        ),
      );
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => AurisCard(
        onTap: onTap,
        child: Row(
          children: [
            Container(
              height: 46,
              width: 46,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                color: AurisTheme.primary.withValues(alpha: 0.10),
              ),
              child: Icon(icon, color: AurisTheme.primary),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                          fontSize: 15.5,
                          fontWeight: FontWeight.w600,
                          color: AurisTheme.ink)),
                  const SizedBox(height: 2),
                  Text(subtitle,
                      style: const TextStyle(
                          fontSize: 12.5, color: AurisTheme.muted)),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded, color: AurisTheme.muted),
          ],
        ),
      );
}

/// Shared patient row, used by the dashboard and the patient list.
class PatientTile extends StatelessWidget {
  const PatientTile({super.key, required this.patient, required this.onTap});

  final Patient patient;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final initials = patient.fullName
        .trim()
        .split(RegExp(r'\s+'))
        .where((part) => part.isNotEmpty)
        .take(2)
        .map((part) => part[0].toUpperCase())
        .join();

    return AurisCard(
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          CircleAvatar(
            radius: 21,
            backgroundColor: AurisTheme.primary.withValues(alpha: 0.12),
            child: Text(
              initials.isEmpty ? '?' : initials,
              style: const TextStyle(
                color: AurisTheme.primary,
                fontWeight: FontWeight.w600,
                fontSize: 14,
              ),
            ),
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(patient.fullName,
                    style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: AurisTheme.ink)),
                const SizedBox(height: 2),
                Text(
                  [
                    '${patient.ageAt(DateTime.now())} yrs',
                    patient.sex,
                    if (patient.clinicRef != null) patient.clinicRef!,
                  ].join(' · '),
                  style: const TextStyle(
                      fontSize: 12.5, color: AurisTheme.muted),
                ),
              ],
            ),
          ),
          const Icon(Icons.chevron_right_rounded, color: AurisTheme.muted),
        ],
      ),
    );
  }
}
