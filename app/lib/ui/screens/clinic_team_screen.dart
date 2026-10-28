import 'package:flutter/material.dart';

import '../../data/auth_service.dart';
import '../../data/cloud_admin_service.dart';
import '../../data/models/clinic.dart';
import '../../data/models/clinic_role.dart';
import '../app_scope.dart';
import '../theme.dart';
import '../widgets/admin_widgets.dart';
import '../widgets/approvals_view.dart';

/// A clinic administrator's screen, in cloud mode: the clinic's details,
/// join code and members, and the requests waiting for their approval
/// (people asking to join or move here, and members' profile and email
/// changes).
///
/// The database (see `supabase/schema.sql`) only lets a clinic admin see and
/// change their own clinic, whatever this screen asks for.
class ClinicTeamScreen extends StatefulWidget {
  const ClinicTeamScreen({super.key});

  @override
  State<ClinicTeamScreen> createState() => _ClinicTeamScreenState();
}

class _ClinicTeamScreenState extends State<ClinicTeamScreen> {
  Clinic? _clinic;
  List<ClinicAccount> _members = const [];
  int _waiting = 0;
  int _approvalsKey = 0;
  bool _loading = true;
  String? _error;

  CloudAdminService? get _admin => AppScope.of(context).admin;
  String? get _myClinicId =>
      AppScope.of(context).auth.currentClinician?.clinicId;
  String? get _myId => AppScope.of(context).auth.currentClinician?.id;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  /// Reloads everything. [approvals] is false after a decision made in the
  /// Approvals tab, which reloads itself and keeps its filters.
  Future<void> _load({bool approvals = true}) async {
    final admin = _admin;
    final clinicId = _myClinicId;
    if (admin == null || clinicId == null) {
      setState(() {
        _loading = false;
        _error = 'Your account has no clinic.';
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await Future.wait([
        admin.listClinics(),
        admin.listAccounts(),
        admin.pendingReviewCount(clinicId: clinicId),
      ]);
      if (!mounted) return;
      final clinics = results[0] as List<Clinic>;
      final accounts = results[1] as List<ClinicAccount>;
      setState(() {
        _clinic = clinics.where((c) => c.id == clinicId).firstOrNull;
        _waiting = results[2] as int;
        if (approvals) _approvalsKey++;
        _members = accounts
            .where((a) => !a.isPending && a.clinicId == clinicId)
            .toList();
        _loading = false;
      });
    } on AdminException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.message;
      });
    }
  }

  Future<void> _run(Future<void> Function() action, String done) async {
    try {
      await action();
      if (!mounted) return;
      showAdminMessage(context, done);
    } on AdminException catch (e) {
      if (!mounted) return;
      showAdminMessage(context, e.message);
    }
    await _load();
  }

  Future<void> _editAccount(ClinicAccount account) async {
    final admin = _admin;
    final clinic = _clinic;
    if (admin == null || clinic == null) return;
    final decision = await showAccessDialog(
      context,
      account: account,
      clinics: [clinic],
      fixedClinic: clinic,
    );
    if (decision == null || !mounted) return;
    switch (decision) {
      case GrantAccess(:final role):
        await _run(
          () => admin.setMemberAccess(
            userId: account.id,
            clinicId: clinic.id,
            role: role,
          ),
          '${account.displayName} is now ${role.label.toLowerCase()}.',
        );
      case RevokeAccess():
        await _run(
          () => admin.revokeMember(account.id),
          '${account.displayName} no longer has access.',
        );
    }
  }

  Future<void> _editClinic() async {
    final admin = _admin;
    final clinic = _clinic;
    if (admin == null || clinic == null) return;
    final details = await showClinicForm(context, clinic: clinic);
    if (details == null || !mounted) return;
    try {
      final applied = await admin.updateClinic(
        clinic.id,
        name: details.name,
        address: details.address,
        phone: details.phone,
      );
      if (!mounted) return;
      showAdminMessage(
        context,
        applied
            ? 'Saved.'
            : 'Sent to a super admin for approval, since these details print '
                  'on every report. Nothing changes until then.',
      );
    } on AdminException catch (e) {
      if (!mounted) return;
      showAdminMessage(context, e.message);
    }
    await _load();
    if (!mounted) return;
    // The report header reads the clinic from the signed-in profile.
    final auth = AppScope.of(context).auth;
    if (auth is SupabaseAuthService) await auth.refreshProfile();
  }

  Future<void> _regenerate() async {
    final admin = _admin;
    final clinic = _clinic;
    if (admin == null || clinic == null || !await confirmRegenerate(context)) {
      return;
    }
    await _run(() => admin.regenerateJoinCode(clinic.id), 'New code created.');
  }

  @override
  Widget build(BuildContext context) {
    final admin = _admin;
    return DefaultTabController(
      length: 2,
      initialIndex: _initialTab(context),
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Clinic and team'),
          actions: [
            IconButton(
              tooltip: 'Refresh',
              icon: const Icon(Icons.refresh_rounded),
              onPressed: _loading ? null : _load,
            ),
          ],
          bottom: TabBar(
            tabs: [
              const Tab(text: 'Team'),
              Tab(text: _waiting == 0 ? 'Approvals' : 'Approvals ($_waiting)'),
            ],
          ),
        ),
        body: _loading && _clinic == null
            ? const Center(child: CircularProgressIndicator())
            : _error != null || _clinic == null || admin == null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(28),
                  child: Text(
                    _error ?? 'Your clinic could not be loaded.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: AurisTheme.muted),
                  ),
                ),
              )
            : TabBarView(
                children: [
                  RefreshIndicator(onRefresh: _load, child: _body(_clinic!)),
                  ApprovalsView(
                    key: ValueKey(_approvalsKey),
                    admin: admin,
                    clinics: [_clinic!],
                    onlyClinicId: _clinic!.id,
                    onChanged: () => _load(approvals: false),
                  ),
                ],
              ),
      ),
    );
  }

  /// Opens on Approvals when the route was pushed with `'approvals'`.
  int _initialTab(BuildContext context) =>
      ModalRoute.of(context)?.settings.arguments == 'approvals' ? 1 : 0;

  Widget _body(Clinic clinic) => ListView(
    padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
    children: [
      AurisCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    clinic.name,
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                      color: AurisTheme.ink,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Edit clinic details',
                  icon: const Icon(Icons.edit_outlined, size: 19),
                  onPressed: _editClinic,
                ),
              ],
            ),
            Text(
              [
                clinic.clinicLabel,
                clinic.address,
                clinic.phone,
              ].whereType<String>().join(' · '),
              style: const TextStyle(fontSize: 12.5, color: AurisTheme.muted),
            ),
            const SizedBox(height: 12),
            const Text(
              'Join code',
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: AurisTheme.muted,
              ),
            ),
            JoinCodeRow(code: clinic.joinCode, onRegenerate: _regenerate),
            const Text(
              'Staff enter this code when they sign up. It only asks to '
              'join: they see nothing until you approve them under '
              'Approvals.',
              style: TextStyle(
                fontSize: 12,
                height: 1.4,
                color: AurisTheme.muted,
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 22),
      SectionLabel('Members (${_members.length})'),
      const SizedBox(height: 8),
      for (final a in _members)
        AccountTile(
          account: a,
          subtitle:
              '${a.email ?? ''}${a.email == null ? '' : ' · '}'
              '${a.role.label}${a.id == _myId ? ' (you)' : ''}',
          // Nobody changes their own access, and a super admin is
          // changed only in the database.
          onTap: a.id == _myId || a.role == ClinicRole.superAdmin
              ? null
              : () => _editAccount(a),
        ),
    ],
  );
}
