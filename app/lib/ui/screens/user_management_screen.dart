import 'package:flutter/material.dart';

import '../../data/auth_service.dart';
import '../../data/models/clinic_role.dart';
import '../app_scope.dart';
import '../theme.dart';
import '../widgets/auris_button.dart';
import '../widgets/auris_input_field.dart';
import '../widgets/change_request_widgets.dart';

/// Administrator screen for the accounts on this device.
///
/// Local-only mode manages accounts here, including setting a new password
/// for someone who has forgotten theirs. With cloud sync on, accounts are
/// managed in Clinic and team and the Admin console instead.
class UserManagementScreen extends StatefulWidget {
  const UserManagementScreen({super.key});

  @override
  State<UserManagementScreen> createState() => _UserManagementScreenState();
}

/// Roles on a device without cloud sync: no super admin, which only exists in
/// the cloud.
const _localRoles = [...ClinicRole.assignable, ClinicRole.pending];

class _UserManagementScreenState extends State<UserManagementScreen> {
  List<Clinician> _clinicians = const [];
  bool _loading = true;

  LocalAuthService? get _localAuth {
    final auth = AppScope.of(context).auth;
    return auth is LocalAuthService ? auth : null;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final auth = _localAuth;
    if (auth == null) {
      setState(() => _loading = false);
      return;
    }
    final users = await auth.listClinicians();
    if (!mounted) return;
    setState(() {
      _clinicians = users;
      _loading = false;
    });
  }

  Future<void> _changeRole(Clinician clinician, ClinicRole role) async {
    try {
      await _localAuth!.setRole(clinician.id, role);
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(
                '${clinician.displayName}\'s role is now ${role.label}.')),
      );
    } on AuthException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _setPassword(Clinician clinician) async {
    final password = await askForText(
      context,
      title: 'New password for ${clinician.displayName}',
      label: 'New password (at least 8 characters)',
      confirm: 'Set password',
      obscure: true,
      minLength: 8,
      message: 'For someone who has forgotten theirs. Tell them the new '
          'password; they can change it in My profile.',
    );
    if (password == null || !mounted) return;
    try {
      await _localAuth!.resetPasswordFor(clinician.id, password);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('New password set for ${clinician.displayName}.')),
      );
    } on AuthException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _addUser() async {
    final created = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _AddUserSheet(),
    );
    if (created == true) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final currentId = AppScope.of(context).auth.currentClinician?.id;

    return Scaffold(
      appBar: AppBar(title: const Text('Team')),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: AurisTheme.primary,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.person_add_alt_1_rounded),
        label: const Text('Add account'),
        onPressed: _addUser,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 96),
              children: [
                const AurisCard(
                  child: Text(
                    'Roles decide what each person can do. They are enforced by '
                    'the app and, when cloud sync is on, by the database itself.',
                    style: TextStyle(
                        fontSize: 12.5, height: 1.45, color: AurisTheme.muted),
                  ),
                ),
                const SizedBox(height: 18),
                const SectionLabel('Accounts on this device'),
                const SizedBox(height: 10),
                for (final clinician in _clinicians)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _userTile(clinician, clinician.id == currentId),
                  ),
                const SizedBox(height: 20),
                const SectionLabel('What each role can do'),
                const SizedBox(height: 10),
                for (final role in _localRoles)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: AurisCard(
                      padding: const EdgeInsets.all(13),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(role.label,
                              style: const TextStyle(
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w700,
                                  color: AurisTheme.ink)),
                          const SizedBox(height: 3),
                          Text(role.description,
                              style: const TextStyle(
                                  fontSize: 12,
                                  height: 1.45,
                                  color: AurisTheme.muted)),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
    );
  }

  Widget _userTile(Clinician clinician, bool isSelf) => AurisCard(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            CircleAvatar(
              radius: 20,
              backgroundColor: AurisTheme.primary.withValues(alpha: 0.12),
              child: Text(
                clinician.displayName.isEmpty
                    ? '?'
                    : clinician.displayName[0].toUpperCase(),
                style: const TextStyle(
                    color: AurisTheme.primary, fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(clinician.displayName,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 14.5,
                                fontWeight: FontWeight.w600,
                                color: AurisTheme.ink)),
                      ),
                      if (isSelf)
                        const Padding(
                          padding: EdgeInsets.only(left: 6),
                          child: Text('(you)',
                              style: TextStyle(
                                  fontSize: 11.5, color: AurisTheme.muted)),
                        ),
                    ],
                  ),
                  Text(clinician.username,
                      style: const TextStyle(
                          fontSize: 12, color: AurisTheme.muted)),
                ],
              ),
            ),
            if (!isSelf)
              IconButton(
                tooltip: 'Set a new password',
                icon: const Icon(Icons.key_rounded, size: 19),
                onPressed: () => _setPassword(clinician),
              ),
            DropdownButtonHideUnderline(
              child: DropdownButton<ClinicRole>(
                value: clinician.role,
                isDense: true,
                items: [
                  for (final role in _localRoles)
                    DropdownMenuItem(
                      value: role,
                      child: Text(role.label,
                          style: const TextStyle(fontSize: 13)),
                    ),
                ],
                onChanged: (role) {
                  if (role == null || role == clinician.role) return;
                  _changeRole(clinician, role);
                },
              ),
            ),
          ],
        ),
      );
}

class _AddUserSheet extends StatefulWidget {
  const _AddUserSheet();

  @override
  State<_AddUserSheet> createState() => _AddUserSheetState();
}

class _AddUserSheetState extends State<_AddUserSheet> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  ClinicRole _role = ClinicRole.clinician;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      await AppScope.of(context).auth.signUp(
            username: _username.text,
            displayName: _name.text,
            password: _password.text,
            role: _role,
          );
      if (!mounted) return;
      Navigator.pop(context, true);
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Form(
          key: _formKey,
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(0, 20, 0, 28),
            children: [
              const Center(
                child: Text('New account',
                    style: TextStyle(
                        fontSize: 17, fontWeight: FontWeight.w600)),
              ),
              const SizedBox(height: 18),
              AurisInputField(
                controller: _name,
                textHint: 'Full name',
                icon: Icons.badge_outlined,
                textCapitalization: TextCapitalization.words,
                validator: (v) =>
                    (v?.trim().isEmpty ?? true) ? 'Enter a name' : null,
              ),
              const SizedBox(height: 12),
              AurisInputField(
                controller: _username,
                textHint: 'Username',
                icon: Icons.person_outline,
                validator: (v) =>
                    (v?.trim().isEmpty ?? true) ? 'Enter a username' : null,
              ),
              const SizedBox(height: 12),
              AurisInputField(
                controller: _password,
                textHint: 'Password',
                icon: Icons.lock_outline,
                obscureText: true,
                validator: (v) => (v == null || v.length < 8)
                    ? 'Use at least 8 characters'
                    : null,
              ),
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SectionLabel('Role'),
                    const SizedBox(height: 8),
                    SegmentedButton<ClinicRole>(
                      showSelectedIcon: false,
                      segments: [
                        for (final role in ClinicRole.assignable)
                          ButtonSegment(
                              value: role, label: Text(role.label)),
                      ],
                      selected: {_role},
                      onSelectionChanged: (s) =>
                          setState(() => _role = s.first),
                    ),
                    const SizedBox(height: 8),
                    Text(_role.description,
                        style: const TextStyle(
                            fontSize: 12,
                            height: 1.4,
                            color: AurisTheme.muted)),
                  ],
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 14),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Text(_error!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          color: AurisTheme.rightEar, fontSize: 13)),
                ),
              ],
              const SizedBox(height: 20),
              Center(
                child: AurisButton(
                  buttonName: 'Create account',
                  width: 230,
                  busy: _busy,
                  onTap: _submit,
                ),
              ),
            ],
          ),
        ),
      );
}
