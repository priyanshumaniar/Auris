import 'package:flutter/material.dart';

import '../../core/audiometry/calibration.dart';
import '../../data/calibration_history.dart';
import '../../services.dart';
import '../../utils/route_constants.dart';
import '../app_scope.dart';
import '../theme.dart';
import '../widgets/auris_button.dart';
import '../widgets/calibration_by_ear.dart';

/// Device settings.
///
/// The calibration procedure itself lives in [CalibrationWizardScreen]; this
/// screen shows the current state and gets out of the way.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  String? _syncMessage;

  CalibrationProfile get _profile => AppScope.of(context).calibration.profile;

  Future<void> _openWizard() async {
    await Navigator.pushNamed(context, calibrationRoute);
    if (mounted) setState(() {});
  }

  Future<void> _syncNow() async {
    final syncing = AppScope.of(context).syncing;
    if (syncing == null) return;

    setState(() => _syncMessage = 'Syncing…');
    final report = await syncing.syncNow();
    if (!mounted) return;
    setState(() => _syncMessage = report.summary);
  }

  Future<void> _confirmResetCalibration() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reset calibration?'),
        content: const Text(
          'Auris will go back to treating this device as uncalibrated, and new '
          'tests will be marked screening-only. Tests already recorded keep the '
          'calibration they were taken with.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: AurisTheme.rightEar),
            child: const Text('Reset'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;
    final services = AppScope.of(context);
    await services.calibration.reset();
    // Resets are part of the history too: a gap in calibration should be as
    // visible in the record as the calibrations either side of it.
    const after = CalibrationProfile();
    const resetEar = EarRecord(
      action: EarAction.reset,
      methodAfter: CalibrationMethod.none,
      offsetAfterDb: 0,
    );
    try {
      await services.calibrationHistory?.record(
        performedBy:
            services.auth.currentClinician?.displayName ?? 'Unknown user',
        method: CalibrationMethod.none,
        earChoice: CalibrationEarChoice.both,
        right: resetEar,
        left: resetEar,
        profile: after,
        isReset: true,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Calibration reset, but the history entry could not '
                'be recorded: $e')));
      }
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final services = AppScope.of(context);
    final profile = _profile;
    final canCalibrate = services.auth.role.canCalibrate;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        actions: [
          IconButton(
            tooltip: 'Help & glossary',
            icon: const Icon(Icons.help_outline_rounded),
            onPressed: () => Navigator.pushNamed(context, helpRoute),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
        children: [
          _accessCard(services),
          const SizedBox(height: 10),
          _linkCard(
            icon: Icons.account_circle_outlined,
            text: services.cloudSyncEnabled
                ? 'My profile: your details, qualification, clinic, email, '
                    'password and requests.'
                : 'My profile: your details, qualification and password.',
            onTap: () => Navigator.pushNamed(context, profileRoute),
          ),
          const SizedBox(height: 22),
          const SectionLabel('Calibration'),
          const SizedBox(height: 8),
          _calibrationCard(profile, canCalibrate),
          if (profile.usesHumanListener) ...[
            const SizedBox(height: 10),
            const HumanCalibrationNotice(),
          ],
          const SizedBox(height: 10),
          AurisCard(
            onTap: () => Navigator.pushNamed(context, calibrationHistoryRoute),
            child: const Row(
              children: [
                Icon(Icons.history_rounded,
                    size: 20, color: AurisTheme.primary),
                SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Calibration history: every calibration on this device, '
                    'with a printable record of each.',
                    style: TextStyle(
                        fontSize: 12.5, height: 1.45, color: AurisTheme.muted),
                  ),
                ),
                Icon(Icons.chevron_right_rounded, color: AurisTheme.muted),
              ],
            ),
          ),
          if (!canCalibrate) ...[
            const SizedBox(height: 10),
            AurisCard(
              padding: const EdgeInsets.all(13),
              child: Row(
                children: [
                  const Icon(Icons.lock_outline_rounded,
                      size: 18, color: AurisTheme.muted),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      services.auth.role.canViewRecords
                          ? 'Calibration is limited to clinicians and '
                              'administrators. You can still review records '
                              'and print reports.'
                          : 'Calibration is limited to clinicians and '
                              'administrators. Your account is waiting for '
                              'approval.',
                      style: const TextStyle(
                          fontSize: 12.5, height: 1.4, color: AurisTheme.muted),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 22),
          const SectionLabel('Storage'),
          const SizedBox(height: 8),
          _storageCard(services),
          if (services.auth.role.canManageClinics &&
              services.cloudSyncEnabled) ...[
            const SizedBox(height: 22),
            const SectionLabel('Auris administration'),
            const SizedBox(height: 8),
            _linkCard(
              icon: Icons.admin_panel_settings_outlined,
              text: 'Admin console: create clinics, place accounts in any '
                  'clinic, and decide requests that need a super admin.',
              onTap: () => Navigator.pushNamed(context, adminConsoleRoute),
            ),
          ],
          if (services.auth.role.canManageUsers &&
              (!services.cloudSyncEnabled ||
                  services.auth.currentClinician?.clinicId != null)) ...[
            const SizedBox(height: 22),
            const SectionLabel('Team'),
            const SizedBox(height: 8),
            _linkCard(
              icon: Icons.manage_accounts_rounded,
              text: services.cloudSyncEnabled
                  ? 'Clinic and team: your clinic\'s details, join code and '
                      'members, and the requests waiting for your approval.'
                  : 'Team: add accounts for the rest of the practice, set '
                      'what each of them can do, and set a new password for '
                      'someone who forgot theirs.',
              onTap: () => Navigator.pushNamed(context,
                  services.cloudSyncEnabled ? clinicTeamRoute : usersRoute),
            ),
          ],
          const SizedBox(height: 22),
          const SectionLabel('Learn'),
          const SizedBox(height: 8),
          AurisCard(
            onTap: () => Navigator.pushNamed(context, helpRoute),
            child: const Row(
              children: [
                Icon(Icons.menu_book_rounded,
                    size: 20, color: AurisTheme.primary),
                SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Help & glossary - what every term on the audiogram and '
                    'the report actually means, in plain language.',
                    style: TextStyle(
                        fontSize: 12.5, height: 1.45, color: AurisTheme.muted),
                  ),
                ),
                Icon(Icons.chevron_right_rounded, color: AurisTheme.muted),
              ],
            ),
          ),
          if (canCalibrate && profile.hasAnyCalibration) ...[
            const SizedBox(height: 26),
            Center(
              child: TextButton.icon(
                onPressed: _confirmResetCalibration,
                icon: const Icon(Icons.restart_alt_rounded, size: 18),
                label: const Text('Reset calibration'),
                style: TextButton.styleFrom(foregroundColor: AurisTheme.muted),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// The headline state: is this device trustworthy, and what to do about it.
  Widget _calibrationCard(CalibrationProfile profile, bool canCalibrate) {
    final (colour, icon, headline) = switch (profile.method) {
      CalibrationMethod.soundLevelMeter => (
          AurisTheme.success,
          Icons.verified_rounded,
          'Calibrated',
        ),
      CalibrationMethod.biological => (
          AurisTheme.primary,
          Icons.person_search_rounded,
          'Roughly calibrated',
        ),
      CalibrationMethod.none => (
          AurisTheme.warning,
          Icons.warning_amber_rounded,
          profile.hasAnyCalibration ? 'Partly calibrated' : 'Not calibrated',
        ),
    };

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colour.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(AurisTheme.cardRadius),
        border: Border.all(color: colour.withValues(alpha: 0.55)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: colour, size: 22),
              const SizedBox(width: 10),
              Text(
                headline,
                style: TextStyle(
                    fontSize: 16.5,
                    fontWeight: FontWeight.w700,
                    color: colour),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            switch (profile.method) {
              CalibrationMethod.soundLevelMeter =>
                'Measured against a sound level meter on '
                    '${profile.transducerName}. Audiograms from this device can '
                    'be read as real dB HL.',
              CalibrationMethod.biological =>
                'Anchored to a normal-hearing listener on '
                    '${profile.transducerName}. Good enough for day-to-day use; '
                    'reports will note that no meter was used.',
              CalibrationMethod.none => profile.hasAnyCalibration
                  ? 'One ear is calibrated and the other is not. Tests will '
                      'run, and reports will be marked screening-only until '
                      'both ears are calibrated.'
                  : 'The shape of an audiogram is still meaningful, but the dB '
                      'numbers are not anchored to anything. Tests will run and '
                      'will be marked screening-only.',
            },
            style: const TextStyle(
                fontSize: 13, height: 1.5, color: AurisTheme.ink),
          ),
          if (profile.hasAnyCalibration) ...[
            const SizedBox(height: 10),
            CalibrationByEar(profile: profile),
          ],
          if (canCalibrate) ...[
            const SizedBox(height: 16),
            AurisButton(
              buttonName: profile.hasAnyCalibration
                  ? 'Calibrate again'
                  : 'Calibrate this device',
              width: double.infinity,
              height: 50,
              color: colour,
              onTap: _openWizard,
            ),
            const SizedBox(height: 8),
            const Center(
              child: Text(
                'Takes about five minutes · works with or without a meter',
                style: TextStyle(fontSize: 11.5, color: AurisTheme.muted),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _linkCard({
    required IconData icon,
    required String text,
    required VoidCallback onTap,
  }) =>
      AurisCard(
        onTap: onTap,
        child: Row(
          children: [
            Icon(icon, size: 20, color: AurisTheme.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Text(text,
                  style: const TextStyle(
                      fontSize: 12.5, height: 1.45, color: AurisTheme.muted)),
            ),
            const Icon(Icons.chevron_right_rounded, color: AurisTheme.muted),
          ],
        ),
      );

  Widget _storageCard(AppServices services) => AurisCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  services.cloudSyncEnabled
                      ? Icons.cloud_done_outlined
                      : Icons.phone_android_rounded,
                  size: 19,
                  color: AurisTheme.muted,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    services.cloudSyncEnabled
                        ? 'Records are saved on this device and mirrored to '
                            'your clinic project.'
                        : 'Local only. Records never leave this device. Add '
                            'Supabase credentials to .env to enable sync.',
                    style: const TextStyle(
                        fontSize: 12.5, height: 1.45, color: AurisTheme.muted),
                  ),
                ),
              ],
            ),
            if (services.cloudSyncEnabled) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  AurisOutlineButton(
                    buttonName: 'Sync now',
                    icon: Icons.sync_rounded,
                    width: 150,
                    height: 44,
                    onTap: _syncNow,
                  ),
                  const SizedBox(width: 12),
                  if (_syncMessage != null)
                    Expanded(
                      child: Text(
                        _syncMessage!,
                        style: const TextStyle(
                            fontSize: 12.5, color: AurisTheme.muted),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              const Text(
                'Sync runs both ways, and by itself whenever the device comes '
                'back online.',
                style: TextStyle(fontSize: 11.5, color: AurisTheme.muted),
              ),
            ],
          ],
        ),
      );

  /// Shows the signed-in user what their role permits, so a blocked action is
  /// never a surprise.
  Widget _accessCard(AppServices services) {
    final clinician = services.auth.currentClinician;
    final role = services.auth.role;

    return AurisCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionLabel('Your access'),
          const SizedBox(height: 8),
          Row(
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: AurisTheme.primary.withValues(alpha: 0.11),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  role.label,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: AurisTheme.primary,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  clinician?.displayName ?? 'Not signed in',
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            role.description,
            style: const TextStyle(
                fontSize: 12.5, height: 1.45, color: AurisTheme.muted),
          ),
        ],
      ),
    );
  }
}
