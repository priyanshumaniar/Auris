import 'package:flutter/material.dart';

import '../../data/auth_service.dart';
import '../../data/cloud_admin_service.dart';
import '../../data/models/clinic.dart';
import '../../data/models/clinic_role.dart';
import '../app_scope.dart';
import '../theme.dart';
import '../widgets/admin_widgets.dart';
import '../widgets/approvals_view.dart';

/// Super admin console: every clinic, every account, and every request that
/// needs a super admin (or that any clinic's admin could decide).
///
/// What it lists, and every change it makes, is checked again by the database
/// (see `supabase/schema.sql`). Patient records are not shown here: a super
/// admin sees them only in their home clinic, like any admin.
class AdminConsoleScreen extends StatefulWidget {
  const AdminConsoleScreen({super.key});

  @override
  State<AdminConsoleScreen> createState() => _AdminConsoleScreenState();
}

class _AdminConsoleScreenState extends State<AdminConsoleScreen> {
  List<Clinic> _clinics = const [];
  List<ClinicAccount> _accounts = const [];
  int _waiting = 0;
  int _approvalsKey = 0;
  bool _loading = true;
  String? _error;

  CloudAdminService? get _admin => AppScope.of(context).admin;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  /// Reloads everything. [approvals] is false after a decision made in the
  /// Approvals tab, which reloads itself and keeps its filters.
  Future<void> _load({bool approvals = true}) async {
    final admin = _admin;
    if (admin == null) {
      setState(() {
        _loading = false;
        _error = 'The admin console needs cloud sync.';
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
        admin.pendingReviewCount(),
      ]);
      if (!mounted) return;
      setState(() {
        _clinics = results[0] as List<Clinic>;
        _accounts = results[1] as List<ClinicAccount>;
        _waiting = results[2] as int;
        if (approvals) _approvalsKey++;
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

  /// Runs [action], reports [done] or the error, then reloads.
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

  String _clinicName(String? id) {
    if (id == null) return 'no clinic';
    for (final c in _clinics) {
      if (c.id == id) return c.name;
    }
    return 'an unknown clinic';
  }

  Future<void> _editAccount(ClinicAccount account) async {
    final admin = _admin;
    if (admin == null) return;
    if (_clinics.isEmpty) {
      showAdminMessage(context, 'Create a clinic first.');
      return;
    }
    final decision = await showAccessDialog(
      context,
      account: account,
      clinics: _clinics,
    );
    if (decision == null || !mounted) return;
    switch (decision) {
      case GrantAccess(:final clinicId, :final role):
        await _run(
          () => admin.setMemberAccess(
            userId: account.id,
            clinicId: clinicId,
            role: role,
          ),
          '${account.displayName} is now ${role.label.toLowerCase()} at '
          '${_clinicName(clinicId)}.',
        );
      case RevokeAccess():
        await _run(
          () => admin.revokeMember(account.id),
          '${account.displayName} no longer has access.',
        );
    }
  }

  Future<void> _createClinic() async {
    final admin = _admin;
    if (admin == null) return;
    final details = await showClinicForm(context);
    if (details == null || !mounted) return;
    await _run(
      () => admin.createClinic(
        name: details.name,
        address: details.address,
        phone: details.phone,
      ),
      '${details.name} created. Share its join code with its staff.',
    );
  }

  Future<void> _editClinic(Clinic clinic) async {
    final admin = _admin;
    if (admin == null) return;
    final details = await showClinicForm(context, clinic: clinic);
    if (details == null || !mounted) return;
    await _run(
      () => admin.updateClinic(
        clinic.id,
        name: details.name,
        address: details.address,
        phone: details.phone,
      ),
      'Saved.',
    );
    if (!mounted) return;
    // A super admin's home clinic prints on their own reports.
    final auth = AppScope.of(context).auth;
    if (auth is SupabaseAuthService && auth.currentClinician?.clinicId == clinic.id) {
      await auth.refreshProfile();
    }
  }

  Future<void> _regenerate(Clinic clinic) async {
    final admin = _admin;
    if (admin == null || !await confirmRegenerate(context)) return;
    await _run(() => admin.regenerateJoinCode(clinic.id), 'New code created.');
  }

  @override
  Widget build(BuildContext context) {
    final admin = _admin;
    return DefaultTabController(
      length: 3,
      initialIndex:
          ModalRoute.of(context)?.settings.arguments == 'approvals' ? 2 : 0,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Admin console'),
          actions: [
            IconButton(
              tooltip: 'Refresh',
              icon: const Icon(Icons.refresh_rounded),
              onPressed: _loading ? null : _load,
            ),
          ],
          bottom: TabBar(
            tabs: [
              const Tab(text: 'Accounts'),
              const Tab(text: 'Clinics'),
              Tab(text: _waiting == 0 ? 'Approvals' : 'Approvals ($_waiting)'),
            ],
          ),
        ),
        body: _loading && _clinics.isEmpty && _accounts.isEmpty
            ? const Center(child: CircularProgressIndicator())
            : _error != null || admin == null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(28),
                  child: Text(
                    _error ?? 'The admin console needs cloud sync.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: AurisTheme.muted),
                  ),
                ),
              )
            : TabBarView(
                children: [
                  _accountsTab(),
                  _clinicsTab(),
                  ApprovalsView(
                    key: ValueKey(_approvalsKey),
                    admin: admin,
                    clinics: _clinics,
                    showFilters: true,
                    onChanged: () => _load(approvals: false),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _accountsTab() {
    final pending = _accounts.where((a) => a.isPending).toList();
    final placed = _accounts.where((a) => !a.isPending).toList()
      ..sort(
        (a, b) => _clinicName(a.clinicId).compareTo(_clinicName(b.clinicId)),
      );

    String pendingSubtitle(ClinicAccount a) {
      final asked = a.requestedClinicId != null
          ? 'asked to join ${_clinicName(a.requestedClinicId)} '
                '(see Approvals)'
          : a.requestedClinic != null
          ? 'entered code ${a.requestedClinic}, which matches no clinic'
          : 'no clinic requested';
      return '${a.email ?? ''}${a.email == null ? '' : ' · '}$asked';
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
        children: [
          SectionLabel('Without a clinic (${pending.length})'),
          const SizedBox(height: 8),
          if (pending.isEmpty)
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text(
                'Nobody is waiting.',
                style: TextStyle(fontSize: 13, color: AurisTheme.muted),
              ),
            ),
          for (final a in pending)
            AccountTile(
              account: a,
              subtitle: pendingSubtitle(a),
              onTap: () => _editAccount(a),
            ),
          const SizedBox(height: 18),
          SectionLabel('With access (${placed.length})'),
          const SizedBox(height: 8),
          for (final a in placed)
            AccountTile(
              account: a,
              subtitle:
                  '${a.email ?? ''}${a.email == null ? '' : ' · '}'
                  '${a.role.label} · ${_clinicName(a.clinicId)}',
              // A super admin is changed only in the database.
              onTap: a.role == ClinicRole.superAdmin
                  ? null
                  : () => _editAccount(a),
            ),
        ],
      ),
    );
  }

  Widget _clinicsTab() {
    int members(Clinic c) =>
        _accounts.where((a) => !a.isPending && a.clinicId == c.id).length;

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              icon: const Icon(Icons.add_rounded),
              label: const Text('New clinic'),
              onPressed: _createClinic,
            ),
          ),
          const SizedBox(height: 16),
          if (_clinics.isEmpty)
            const Text(
              'No clinics yet.',
              style: TextStyle(fontSize: 13, color: AurisTheme.muted),
            ),
          for (final c in _clinics)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: AurisCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            c.clinicLabel == null
                                ? c.name
                                : '${c.name}  ·  ${c.clinicLabel}',
                            style: const TextStyle(
                              fontSize: 15.5,
                              fontWeight: FontWeight.w600,
                              color: AurisTheme.ink,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Edit clinic',
                          icon: const Icon(Icons.edit_outlined, size: 19),
                          onPressed: () => _editClinic(c),
                        ),
                      ],
                    ),
                    if (c.address != null || c.phone != null)
                      Text(
                        [c.address, c.phone].whereType<String>().join(' · '),
                        style: const TextStyle(
                          fontSize: 12.5,
                          color: AurisTheme.muted,
                        ),
                      ),
                    const SizedBox(height: 4),
                    Text(
                      '${members(c)} member${members(c) == 1 ? '' : 's'}',
                      style: const TextStyle(
                        fontSize: 12.5,
                        color: AurisTheme.muted,
                      ),
                    ),
                    const SizedBox(height: 6),
                    JoinCodeRow(
                      code: c.joinCode,
                      onRegenerate: () => _regenerate(c),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
