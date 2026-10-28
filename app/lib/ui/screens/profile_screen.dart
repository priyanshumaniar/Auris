import 'package:flutter/material.dart';

import '../../data/account_service.dart';
import '../../data/auth_service.dart';
import '../../data/cloud_admin_service.dart';
import '../../data/models/change_request.dart';
import '../../data/models/clinic.dart';
import '../../data/models/clinic_role.dart';
import '../app_scope.dart';
import '../theme.dart';
import '../widgets/admin_widgets.dart';
import '../widgets/change_request_widgets.dart';

/// The signed-in user's own account: who they are, their clinic, their
/// password and email, and the changes they have asked for.
///
/// In cloud mode a change to anything others rely on (name, credentials,
/// email, clinic) is a request that someone else approves; until then this
/// screen, reports and member lists keep showing the approved values. See
/// `supabase/schema.sql`, "Profiles and change requests".
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  MyAccount? _me;
  bool _loading = true;
  String? _error;

  AccountService get _account => AppScope.of(context).account;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final me = await _account.load();
      if (!mounted) return;
      setState(() {
        _me = me;
        _loading = false;
        if (me == null) _error = 'Sign in to see your profile.';
      });
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.message;
      });
    }
  }

  /// Runs [action], shows what came of it, then reloads.
  Future<void> _run(Future<String> Function() action) async {
    try {
      final done = await action();
      if (!mounted) return;
      showAdminMessage(context, done);
    } on AuthException catch (e) {
      if (!mounted) return;
      showAdminMessage(context, e.message);
    } on AdminException catch (e) {
      if (!mounted) return;
      showAdminMessage(context, e.message);
    }
    await _load();
  }

  String _sentTo(ChangeOutcome outcome, String level) =>
      outcome == ChangeOutcome.applied
      ? 'Saved.'
      : 'Sent to ${reviewerWords(level)} for approval. Your profile keeps '
            'its current details until then.';

  /// Who decides the user's own profile and email changes.
  String get _ownLevel =>
      AppScope.of(context).auth.role == ClinicRole.admin
      ? 'super_admin'
      : 'clinic_admin';

  // -------------------------------------------------------------------------
  // Actions
  // -------------------------------------------------------------------------

  Future<void> _editProfile(MyAccount me) async {
    final pending = me.open(ChangeKind.profile);
    final source = pending?.payload;
    final result = await showDialog<_ProfileForm>(
      context: context,
      builder: (_) => _ProfileDialog(
        // Editing a waiting request starts from what it asks for, including
        // fields it clears.
        initial: source != null
            ? _ProfileForm(
                displayName:
                    source['display_name'] as String? ?? me.profile.displayName,
                phone: source['phone'] as String? ?? '',
                qualification: source['qualification'] as String? ?? '',
                registrationNo: source['registration_no'] as String? ?? '',
              )
            : _ProfileForm(
                displayName: me.profile.displayName,
                phone: me.profile.phone ?? '',
                qualification: me.profile.qualification ?? '',
                registrationNo: me.profile.registrationNo ?? '',
              ),
        usesApprovals: _account.usesApprovals,
        replacesPending: pending != null,
      ),
    );
    if (result == null || !mounted) return;
    final level = _ownLevel;
    await _run(() async {
      final outcome = await _account.updateProfile(
        displayName: result.displayName,
        phone: result.phone,
        qualification: result.qualification,
        registrationNo: result.registrationNo,
      );
      return _sentTo(outcome, level);
    });
  }

  Future<void> _changePassword(MyAccount me) async {
    final result = await showDialog<(String, String)>(
      context: context,
      builder: (_) => _PasswordDialog(askCurrent: me.hasPassword),
    );
    if (result == null || !mounted) return;
    await _run(() async {
      await _account.changePassword(
        currentPassword: result.$1,
        newPassword: result.$2,
      );
      return 'Password changed.';
    });
  }

  Future<void> _changeEmail(MyAccount me) async {
    final role = AppScope.of(context).auth.role;
    final direct = role == ClinicRole.pending || role == ClinicRole.superAdmin;
    final email = await askForText(
      context,
      title: 'Change email',
      label: 'New email address',
      keyboardType: TextInputType.emailAddress,
      message:
          'You will sign in with the new address. '
          '${direct ? '' : 'It goes to ${reviewerWords(_ownLevel)} first. '}'
          'Once it is approved, Auris sends a code to the new address, and '
          'the change is done when you enter it here.',
    );
    if (email == null || !mounted) return;
    final level = _ownLevel;
    await _run(() async {
      final outcome = await _account.requestEmailChange(email);
      if (outcome == ChangeOutcome.applied) {
        await _account.sendEmailChangeCode(email);
        return 'A code is on its way to $email. Enter it under "Confirm new '
            'email".';
      }
      return 'Sent to ${reviewerWords(level)} for approval.';
    });
  }

  Future<void> _sendCode(String email) => _run(() async {
    await _account.sendEmailChangeCode(email);
    return 'A code is on its way to $email.';
  });

  Future<void> _enterCode(String email) async {
    final code = await askForText(
      context,
      title: 'Confirm new email',
      label: 'Code from the email',
      keyboardType: TextInputType.number,
      confirm: 'Confirm',
      message: 'Enter the code sent to $email.',
    );
    if (code == null || !mounted) return;
    await _run(() async {
      await _account.confirmEmailChange(newEmail: email, code: code);
      return 'Your email is now $email.';
    });
  }

  Future<void> _askClinic({required bool move}) async {
    final code = await askForText(
      context,
      title: move ? 'Move to another clinic' : 'Join a clinic',
      label: 'Join code',
      confirm: 'Ask',
      message: move
          ? 'Enter the other clinic\'s join code. Its admin decides. You keep '
                'your access here until then; once approved, you see the new '
                'clinic\'s records instead of these.'
          : 'Enter the join code your clinic gave you. Its admin decides.',
    );
    if (code == null || !mounted) return;
    await _run(() async {
      final name = await _account.requestClinic(code);
      return 'Asked to ${move ? 'move to' : 'join'} $name. Its admin will '
          'decide.';
    });
  }

  Future<void> _leave(Clinic clinic) async {
    final ok = await confirmAction(
      context,
      title: 'Leave ${clinic.name}?',
      message:
          'You lose access to its patients and tests at once. Records you '
          'made stay with the clinic. To come back, you would ask to join '
          'again with its code.',
      confirm: 'Leave',
      destructive: true,
    );
    if (!ok || !mounted) return;
    await _run(() async {
      await _account.leaveClinic();
      return 'You have left ${clinic.name}.';
    });
  }

  Future<void> _regenerate(Clinic clinic) async {
    final admin = AppScope.of(context).admin;
    if (admin == null || !await confirmRegenerate(context)) return;
    await _run(() async {
      await admin.regenerateJoinCode(clinic.id);
      return 'New code created.';
    });
  }

  Future<void> _cancel(ChangeRequest r) async {
    await _run(() async {
      await _account.cancelRequest(r.id);
      return 'Request withdrawn.';
    });
  }

  Future<void> _requestDeletion() async {
    final reason = await askForText(
      context,
      title: 'Delete my account?',
      label: 'Reason (optional)',
      required: false,
      multiline: true,
      confirm: 'Ask to delete',
      destructive: true,
      message:
          'A super admin decides. Once they approve, your login is removed '
          'for good. Patients and tests you recorded stay with the clinic.',
    );
    if (reason == null || !mounted) return;
    await _run(() async {
      await _account.requestDeletion(reason.isEmpty ? null : reason);
      return 'Sent to a super admin.';
    });
  }

  Future<void> _setAlerts(bool on) => _run(() async {
    await _account.setEmailAlerts(on);
    return on ? 'Email alerts on.' : 'Email alerts off.';
  });

  // -------------------------------------------------------------------------
  // Layout
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('My profile'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: _loading && _me == null
          ? const Center(child: CircularProgressIndicator())
          : _me == null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Text(
                  _error ?? 'Your profile could not be loaded.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: AurisTheme.muted),
                ),
              ),
            )
          : RefreshIndicator(onRefresh: _load, child: _body(_me!)),
    );
  }

  Widget _body(MyAccount me) {
    final cloud = _account.usesApprovals;
    final p = me.profile;
    final role = AppScope.of(context).auth.role;
    final pendingProfile = me.open(ChangeKind.profile);
    final pendingEmail = me.open(ChangeKind.email);
    final emailToConfirm = me.emailToConfirm;
    final pendingDelete = me.open(ChangeKind.delete);
    final history = me.requests
        .where((r) => !r.isPending && r.id != emailToConfirm?.id)
        .toList();

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
      children: [
        _identityCard(me, role),
        if (pendingProfile != null) ...[
          const SizedBox(height: 10),
          ChangeRequestCard(
            request: pendingProfile,
            footer: _cancelButton(pendingProfile),
          ),
        ],
        const SizedBox(height: 22),
        Row(
          children: [
            const Expanded(child: SectionLabel('Details')),
            TextButton.icon(
              icon: const Icon(Icons.edit_outlined, size: 17),
              label: Text(pendingProfile == null ? 'Edit' : 'Edit request'),
              onPressed: () => _editProfile(me),
            ),
          ],
        ),
        AurisCard(
          child: Column(
            children: [
              _field('Name', p.displayName),
              _field('Phone', p.phone),
              _field('Qualification', p.qualification),
              _field('Registration / licence no.', p.registrationNo),
              const SizedBox(height: 4),
              Text(
                p.credentials == null
                    ? 'Add your qualification and registration number: they '
                          'are printed under your name on every report.'
                    : 'Printed on reports as: ${p.displayName}, '
                          '${p.credentials}',
                style: const TextStyle(
                  fontSize: 12,
                  height: 1.4,
                  color: AurisTheme.muted,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 22),
        const SectionLabel('Sign-in'),
        const SizedBox(height: 8),
        AurisCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _field(cloud ? 'Email' : 'Username', me.loginName),
              if (cloud && emailToConfirm == null && pendingEmail == null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: () => _changeEmail(me),
                    child: const Text('Change email'),
                  ),
                ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () => _changePassword(me),
                  child: Text(
                    me.hasPassword ? 'Change password' : 'Set a password',
                  ),
                ),
              ),
            ],
          ),
        ),
        if (pendingEmail != null) ...[
          const SizedBox(height: 10),
          ChangeRequestCard(
            request: pendingEmail,
            footer: _cancelButton(pendingEmail),
          ),
        ],
        if (emailToConfirm != null) ...[
          const SizedBox(height: 10),
          _confirmEmailCard(emailToConfirm),
        ],
        const SizedBox(height: 22),
        const SectionLabel('My clinic'),
        const SizedBox(height: 8),
        _clinicSection(me, role),
        if (cloud) ...[
          const SizedBox(height: 22),
          const SectionLabel('Email alerts'),
          const SizedBox(height: 8),
          AurisCard(
            padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
            child: SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: p.emailAlerts,
              onChanged: _setAlerts,
              title: const Text(
                'Email me about requests',
                style: TextStyle(fontSize: 14),
              ),
              subtitle: Text(
                role.canManageUsers
                    ? 'When someone asks for your approval, and when your own '
                          'requests are decided.'
                    : 'When your requests are approved or turned down.',
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ),
        ],
        const SizedBox(height: 22),
        if (cloud) ...[
          SectionLabel('My requests (${history.length})'),
          const SizedBox(height: 8),
          if (history.isEmpty)
            const Text(
              'Decided requests appear here.',
              style: TextStyle(fontSize: 13, color: AurisTheme.muted),
            ),
          for (final r in history) ChangeRequestCard(request: r),
          if (role != ClinicRole.superAdmin) ...[
            const SizedBox(height: 22),
            const SectionLabel('Delete account'),
            const SizedBox(height: 8),
            if (pendingDelete != null)
              ChangeRequestCard(
                request: pendingDelete,
                footer: _cancelButton(pendingDelete),
              )
            else
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AurisTheme.rightEar,
                  ),
                  icon: const Icon(Icons.delete_outline_rounded, size: 18),
                  label: const Text('Ask to delete my account'),
                  onPressed: _requestDeletion,
                ),
              ),
          ],
        ],
      ],
    );
  }

  Widget _identityCard(MyAccount me, ClinicRole role) {
    final p = me.profile;
    final initials = p.displayName
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .take(2)
        .map((w) => w[0].toUpperCase())
        .join();
    const small = TextStyle(fontSize: 12.5, height: 1.4, color: AurisTheme.muted);
    return AurisCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 26,
                backgroundColor: AurisTheme.primary.withValues(alpha: 0.12),
                child: Text(
                  initials.isEmpty ? '?' : initials,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: AurisTheme.primary,
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      p.displayName,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        color: AurisTheme.ink,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      role.label,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AurisTheme.primary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(role.description, style: small),
          const SizedBox(height: 8),
          if (p.createdAt != null)
            Text('Joined ${formatWhen(p.createdAt)}', style: small),
          if (p.approvedAt != null)
            Text(
              'Access approved ${formatWhen(p.approvedAt)}'
              '${me.approvedBy == null ? '' : ' by ${me.approvedBy}'}',
              style: small,
            ),
        ],
      ),
    );
  }

  Widget _field(String label, String? value) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 150,
          child: Text(
            label,
            style: const TextStyle(fontSize: 13, color: AurisTheme.muted),
          ),
        ),
        Expanded(
          child: SelectableText(
            value ?? 'Not set',
            style: TextStyle(
              fontSize: 14,
              color: value == null ? AurisTheme.muted : AurisTheme.ink,
            ),
          ),
        ),
      ],
    ),
  );

  Widget _cancelButton(ChangeRequest r) => Align(
    alignment: Alignment.centerLeft,
    child: TextButton(
      onPressed: () => _cancel(r),
      child: const Text('Withdraw request'),
    ),
  );

  Widget _confirmEmailCard(ChangeRequest r) {
    final email = r.payload['email'] as String? ?? '';
    return AurisCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Confirm new email',
            style: TextStyle(
              fontSize: 14.5,
              fontWeight: FontWeight.w600,
              color: AurisTheme.ink,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Changing to $email was approved. Send a code to that address and '
            'enter it here to finish. Until then you sign in with your '
            'current email.',
            style: const TextStyle(
              fontSize: 12.5,
              height: 1.4,
              color: AurisTheme.muted,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              OutlinedButton(
                onPressed: () => _sendCode(email),
                child: const Text('Send code'),
              ),
              FilledButton(
                onPressed: () => _enterCode(email),
                child: const Text('Enter code'),
              ),
              TextButton(
                onPressed: () => _cancel(r),
                child: const Text('Keep my current email'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _clinicSection(MyAccount me, ClinicRole role) {
    final cloud = _account.usesApprovals;
    final clinic = me.clinic;
    final pendingJoin = me.open(ChangeKind.join);
    final pendingMove = me.open(ChangeKind.move);
    final pendingClinicEdit = me.open(ChangeKind.clinic);
    const small = TextStyle(fontSize: 12.5, height: 1.4, color: AurisTheme.muted);

    if (clinic == null) {
      if (role == ClinicRole.superAdmin) {
        return const AurisCard(
          child: Text(
            'No home clinic. A super admin\'s home clinic is set in the '
            'database; see docs/SUPABASE_SETUP.md.',
            style: small,
          ),
        );
      }
      return AurisCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (pendingJoin != null) ...[
              Text(
                'Asked to join '
                '${me.requestedClinicLabel ?? pendingJoin.requestedClinicLabel ?? 'a clinic'}',
                style: const TextStyle(
                  fontSize: 14.5,
                  fontWeight: FontWeight.w600,
                  color: AurisTheme.ink,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Waiting for that clinic\'s admin since '
                '${formatWhen(pendingJoin.createdAt)}. You see no patient '
                'records until they approve you.',
                style: small,
              ),
            ] else ...[
              const Text(
                'You are not in a clinic yet.',
                style: TextStyle(
                  fontSize: 14.5,
                  fontWeight: FontWeight.w600,
                  color: AurisTheme.ink,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                'Ask your clinic for its join code and enter it here.',
                style: small,
              ),
            ],
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                FilledButton(
                  onPressed: () => _askClinic(move: false),
                  child: Text(
                    pendingJoin == null
                        ? 'Enter a join code'
                        : 'Enter a different code',
                  ),
                ),
                if (pendingJoin != null)
                  TextButton(
                    onPressed: () => _cancel(pendingJoin),
                    child: const Text('Withdraw request'),
                  ),
              ],
            ),
          ],
        ),
      );
    }

    final isAdmin = role.canManageUsers;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AurisCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                clinic.name,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: AurisTheme.ink,
                ),
              ),
              const SizedBox(height: 8),
              if (clinic.clinicLabel != null)
                _field('Clinic ID', clinic.clinicLabel),
              _field('Address', clinic.address),
              _field('Phone', clinic.phone),
              if (cloud) ...[
                const Text(
                  'Join code',
                  style: TextStyle(fontSize: 13, color: AurisTheme.muted),
                ),
                JoinCodeRow(
                  code: clinic.joinCode,
                  onRegenerate: isAdmin ? () => _regenerate(clinic) : null,
                ),
                const Text(
                  'Share it with new staff. Entering it only asks to join; '
                  'an admin decides.',
                  style: small,
                ),
              ] else
                const Text(
                  'On this device the clinic\'s details come from the .env '
                  'file.',
                  style: small,
                ),
              const SizedBox(height: 12),
              const Text(
                'Clinic admins',
                style: TextStyle(fontSize: 13, color: AurisTheme.muted),
              ),
              const SizedBox(height: 4),
              if (me.clinicAdmins.isEmpty)
                const Text('None listed.', style: small),
              for (final a in me.clinicAdmins)
                Padding(
                  padding: const EdgeInsets.only(bottom: 3),
                  child: Text(
                    '${a.displayName}'
                    '${a.email == null ? '' : ' · ${a.email}'}'
                    '${a.id == me.profile.id ? ' (you)' : ''}',
                    style: const TextStyle(
                      fontSize: 13.5,
                      color: AurisTheme.ink,
                    ),
                  ),
                ),
            ],
          ),
        ),
        if (pendingClinicEdit != null) ...[
          const SizedBox(height: 10),
          ChangeRequestCard(
            request: pendingClinicEdit,
            footer: _cancelButton(pendingClinicEdit),
          ),
        ],
        if (pendingMove != null) ...[
          const SizedBox(height: 10),
          ChangeRequestCard(
            request: pendingMove,
            footer: _cancelButton(pendingMove),
          ),
        ],
        if (cloud) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              if (role != ClinicRole.superAdmin && pendingMove == null)
                OutlinedButton(
                  onPressed: () => _askClinic(move: true),
                  child: const Text('Move to another clinic'),
                ),
              TextButton(
                style: TextButton.styleFrom(
                  foregroundColor: AurisTheme.rightEar,
                ),
                onPressed: () => _leave(clinic),
                child: const Text('Leave clinic'),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Dialogs
// ---------------------------------------------------------------------------

class _ProfileForm {
  const _ProfileForm({
    required this.displayName,
    required this.phone,
    required this.qualification,
    required this.registrationNo,
  });

  final String displayName;
  final String phone;
  final String qualification;
  final String registrationNo;
}

class _ProfileDialog extends StatefulWidget {
  const _ProfileDialog({
    required this.initial,
    required this.usesApprovals,
    required this.replacesPending,
  });

  final _ProfileForm initial;
  final bool usesApprovals;
  final bool replacesPending;

  @override
  State<_ProfileDialog> createState() => _ProfileDialogState();
}

class _ProfileDialogState extends State<_ProfileDialog> {
  late final _name = TextEditingController(text: widget.initial.displayName);
  late final _phone = TextEditingController(text: widget.initial.phone);
  late final _qualification = TextEditingController(
    text: widget.initial.qualification,
  );
  late final _registration = TextEditingController(
    text: widget.initial.registrationNo,
  );

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _qualification.dispose();
    _registration.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final role = AppScope.of(context).auth.role;
    final direct =
        !widget.usesApprovals ||
        role == ClinicRole.superAdmin ||
        role == ClinicRole.pending;
    return AlertDialog(
      title: const Text('Edit profile'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _name,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Name'),
              onChanged: (_) => setState(() {}),
            ),
            TextField(
              controller: _phone,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(labelText: 'Phone'),
            ),
            TextField(
              controller: _qualification,
              decoration: const InputDecoration(
                labelText: 'Qualification',
                hintText: 'e.g. MS (ENT), audiologist',
              ),
            ),
            TextField(
              controller: _registration,
              decoration: const InputDecoration(
                labelText: 'Registration / licence no.',
              ),
            ),
            const SizedBox(height: 12),
            Text(
              direct
                  ? 'Saved at once.'
                  : '${widget.replacesPending ? 'This replaces the request '
                                'already waiting. ' : ''}'
                        'Goes to ${reviewerWords(role == ClinicRole.admin ? 'super_admin' : 'clinic_admin')} '
                        'for approval. Until then, reports and the team list '
                        'show your current details.',
              style: const TextStyle(
                fontSize: 12,
                height: 1.4,
                color: AurisTheme.muted,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _name.text.trim().isEmpty
              ? null
              : () => Navigator.pop(
                  context,
                  _ProfileForm(
                    displayName: _name.text.trim(),
                    phone: _phone.text.trim(),
                    qualification: _qualification.text.trim(),
                    registrationNo: _registration.text.trim(),
                  ),
                ),
          child: Text(direct ? 'Save' : 'Send for approval'),
        ),
      ],
    );
  }
}

class _PasswordDialog extends StatefulWidget {
  const _PasswordDialog({required this.askCurrent});
  final bool askCurrent;

  @override
  State<_PasswordDialog> createState() => _PasswordDialogState();
}

class _PasswordDialogState extends State<_PasswordDialog> {
  final _current = TextEditingController();
  final _next = TextEditingController();
  final _again = TextEditingController();
  bool _show = false;

  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    _again.dispose();
    super.dispose();
  }

  String? get _problem {
    if (widget.askCurrent && _current.text.isEmpty) {
      return 'Enter your current password.';
    }
    if (_next.text.length < 8) return 'At least 8 characters.';
    if (_next.text != _again.text) return 'The new passwords do not match.';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final problem = _problem;
    InputDecoration field(String label) => InputDecoration(
      labelText: label,
      suffixIcon: IconButton(
        tooltip: _show ? 'Hide' : 'Show',
        icon: Icon(
          _show ? Icons.visibility_off_outlined : Icons.visibility_outlined,
          size: 19,
        ),
        onPressed: () => setState(() => _show = !_show),
      ),
    );
    return AlertDialog(
      title: Text(widget.askCurrent ? 'Change password' : 'Set a password'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.askCurrent)
              TextField(
                controller: _current,
                obscureText: !_show,
                decoration: field('Current password'),
                onChanged: (_) => setState(() {}),
              ),
            TextField(
              controller: _next,
              obscureText: !_show,
              decoration: field('New password'),
              onChanged: (_) => setState(() {}),
            ),
            TextField(
              controller: _again,
              obscureText: !_show,
              decoration: field('New password again'),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 10),
            Text(
              problem ?? 'Applies at once; no approval needed.',
              style: const TextStyle(fontSize: 12, color: AurisTheme.muted),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: problem != null
              ? null
              : () => Navigator.pop(context, (_current.text, _next.text)),
          child: const Text('Change'),
        ),
      ],
    );
  }
}
