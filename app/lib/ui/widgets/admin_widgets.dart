import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/models/clinic.dart';
import '../../data/models/clinic_role.dart';
import '../theme.dart';

/// What an administrator chose for one account.
sealed class AccessDecision {
  const AccessDecision();
}

/// Give the account [role] in [clinicId].
class GrantAccess extends AccessDecision {
  const GrantAccess(this.clinicId, this.role);
  final String clinicId;
  final ClinicRole role;
}

/// Take the account's access away (or turn down its request).
class RevokeAccess extends AccessDecision {
  const RevokeAccess();
}

/// Asks which clinic and role [account] should have.
///
/// [clinics] are the clinics the administrator may choose from. With
/// [fixedClinic] (a clinic admin, who can only add people to their own
/// clinic) the clinic is not offered as a choice.
Future<AccessDecision?> showAccessDialog(
  BuildContext context, {
  required ClinicAccount account,
  required List<Clinic> clinics,
  Clinic? fixedClinic,
}) {
  return showDialog<AccessDecision>(
    context: context,
    builder: (_) => _AccessDialog(
      account: account,
      clinics: clinics,
      fixedClinic: fixedClinic,
    ),
  );
}

class _AccessDialog extends StatefulWidget {
  const _AccessDialog({
    required this.account,
    required this.clinics,
    required this.fixedClinic,
  });

  final ClinicAccount account;
  final List<Clinic> clinics;
  final Clinic? fixedClinic;

  @override
  State<_AccessDialog> createState() => _AccessDialogState();
}

class _AccessDialogState extends State<_AccessDialog> {
  late String? _clinicId;
  late ClinicRole _role;

  @override
  void initState() {
    super.initState();
    final a = widget.account;
    final ids = widget.clinics.map((c) => c.id).toSet();
    final preferred =
        widget.fixedClinic?.id ?? a.clinicId ?? a.requestedClinicId;
    _clinicId =
        preferred != null &&
            (ids.contains(preferred) || preferred == widget.fixedClinic?.id)
        ? preferred
        : null;
    _role = ClinicRole.assignable.contains(a.role) ? a.role : ClinicRole.viewer;
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.account;
    final hasAccess = !a.isPending;
    final hasRequest = a.isPending && a.requestedClinicId != null;

    return AlertDialog(
      title: Text(a.displayName),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (a.email != null)
              Text(
                a.email!,
                style: const TextStyle(fontSize: 13, color: AurisTheme.muted),
              ),
            const SizedBox(height: 16),
            if (widget.fixedClinic == null) ...[
              const Text(
                'Clinic',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 6),
              DropdownButton<String>(
                isExpanded: true,
                value: _clinicId,
                hint: const Text('Choose a clinic'),
                items: [
                  for (final c in widget.clinics)
                    DropdownMenuItem(value: c.id, child: Text(c.name)),
                ],
                onChanged: (v) => setState(() => _clinicId = v),
              ),
              const SizedBox(height: 14),
            ] else
              Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: Text(
                  'Clinic: ${widget.fixedClinic!.name}',
                  style: const TextStyle(fontSize: 13),
                ),
              ),
            const Text(
              'Role',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            SegmentedButton<ClinicRole>(
              showSelectedIcon: false,
              segments: [
                for (final role in ClinicRole.assignable)
                  ButtonSegment(value: role, label: Text(role.label)),
              ],
              selected: {_role},
              onSelectionChanged: (s) => setState(() => _role = s.first),
            ),
            const SizedBox(height: 8),
            Text(
              _role.description,
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
        if (hasAccess || hasRequest)
          TextButton(
            style: TextButton.styleFrom(foregroundColor: AurisTheme.rightEar),
            onPressed: () => Navigator.pop(context, const RevokeAccess()),
            child: Text(hasAccess ? 'Remove access' : 'Decline'),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _clinicId == null
              ? null
              : () => Navigator.pop(context, GrantAccess(_clinicId!, _role)),
          child: Text(hasAccess ? 'Save' : 'Approve'),
        ),
      ],
    );
  }
}

/// Asks for a clinic's name, address and phone. Returns null when cancelled.
Future<ClinicDetails?> showClinicForm(BuildContext context, {Clinic? clinic}) {
  return showDialog<ClinicDetails>(
    context: context,
    builder: (_) => _ClinicFormDialog(clinic: clinic),
  );
}

class _ClinicFormDialog extends StatefulWidget {
  const _ClinicFormDialog({this.clinic});
  final Clinic? clinic;

  @override
  State<_ClinicFormDialog> createState() => _ClinicFormDialogState();
}

class _ClinicFormDialogState extends State<_ClinicFormDialog> {
  late final _name = TextEditingController(text: widget.clinic?.name ?? '');
  late final _address = TextEditingController(
    text: widget.clinic?.address ?? '',
  );
  late final _phone = TextEditingController(text: widget.clinic?.phone ?? '');

  @override
  void dispose() {
    _name.dispose();
    _address.dispose();
    _phone.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.clinic == null ? 'New clinic' : 'Edit clinic'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _name,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(labelText: 'Name'),
          ),
          TextField(
            controller: _address,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'Address'),
          ),
          TextField(
            controller: _phone,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(labelText: 'Phone'),
          ),
          const SizedBox(height: 10),
          const Text(
            'Printed at the top of every report from this clinic.',
            style: TextStyle(fontSize: 12, color: AurisTheme.muted),
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
        onPressed: () {
          final name = _name.text.trim();
          if (name.isEmpty) return;
          String? opt(TextEditingController c) =>
              c.text.trim().isEmpty ? null : c.text.trim();
          Navigator.pop(
            context,
            ClinicDetails(
              name: name,
              address: opt(_address),
              phone: opt(_phone),
            ),
          );
        },
        child: const Text('Save'),
      ),
    ],
  );
}

/// A clinic's join code, with copy and (optionally) replace buttons.
class JoinCodeRow extends StatelessWidget {
  const JoinCodeRow({super.key, required this.code, this.onRegenerate});

  final String? code;
  final VoidCallback? onRegenerate;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      const Icon(Icons.key_rounded, size: 17, color: AurisTheme.muted),
      const SizedBox(width: 8),
      Expanded(
        child: SelectableText(
          code ?? 'No code yet',
          style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.1,
            color: AurisTheme.ink,
          ),
        ),
      ),
      if (code != null)
        IconButton(
          tooltip: 'Copy the join code',
          icon: const Icon(Icons.copy_rounded, size: 19),
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: code!));
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Join code copied.')),
              );
            }
          },
        ),
      if (onRegenerate != null)
        IconButton(
          tooltip: 'Replace the join code',
          icon: const Icon(Icons.autorenew_rounded, size: 20),
          onPressed: onRegenerate,
        ),
    ],
  );
}

/// Asks before replacing a join code, since the old one stops working.
Future<bool> confirmRegenerate(BuildContext context) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Replace the join code?'),
      content: const Text(
        'The current code stops working at once. People who already asked '
        'to join stay on the waiting list.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Replace'),
        ),
      ],
    ),
  );
  return ok == true;
}

/// One account in a list.
class AccountTile extends StatelessWidget {
  const AccountTile({
    super.key,
    required this.account,
    required this.subtitle,
    this.onTap,
  });

  final ClinicAccount account;
  final String subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final pending = account.isPending;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: AurisCard(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        onTap: onTap,
        child: Row(
          children: [
            Icon(
              pending
                  ? Icons.hourglass_top_rounded
                  : account.role == ClinicRole.superAdmin
                  ? Icons.shield_outlined
                  : Icons.person_outline_rounded,
              size: 20,
              color: pending ? AurisTheme.warning : AurisTheme.primary,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    account.displayName,
                    style: const TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w600,
                      color: AurisTheme.ink,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      fontSize: 12.5,
                      height: 1.35,
                      color: AurisTheme.muted,
                    ),
                  ),
                ],
              ),
            ),
            if (onTap != null)
              const Icon(Icons.chevron_right_rounded, color: AurisTheme.muted),
          ],
        ),
      ),
    );
  }
}

/// Shows [message] in a snack bar.
void showAdminMessage(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}
