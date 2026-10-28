import 'package:flutter/material.dart';

import '../../data/cloud_admin_service.dart';
import '../../data/models/change_request.dart';
import '../../data/models/clinic.dart';
import '../../data/models/clinic_role.dart';
import '../theme.dart';
import 'admin_widgets.dart';
import 'change_request_widgets.dart';

/// The requests waiting for this user's decision, and the record of decided
/// ones. Used by the clinic team screen (a clinic admin: their clinic only)
/// and the admin console (a super admin: every clinic, with filters).
///
/// Which requests appear, and who may decide them, is settled by the database
/// (see `supabase/schema.sql`); this view only asks.
class ApprovalsView extends StatefulWidget {
  const ApprovalsView({
    super.key,
    required this.admin,
    this.clinics = const [],
    this.showFilters = false,
    this.onlyClinicId,
    this.onChanged,
  });

  final CloudAdminService admin;

  /// Clinics, to name each request's clinic and to filter by.
  final List<Clinic> clinics;

  final bool showFilters;

  /// Show only this clinic's requests. A super admin can read every clinic's,
  /// so their home clinic's Team screen narrows the list here.
  final String? onlyClinicId;

  /// Called after a decision, so the parent can refresh counts and lists.
  final VoidCallback? onChanged;

  @override
  State<ApprovalsView> createState() => _ApprovalsViewState();
}

class _ApprovalsViewState extends State<ApprovalsView> {
  List<ChangeRequest> _pending = const [];
  List<ChangeRequest> _decided = const [];
  bool _loading = true;
  String? _error;
  bool _history = false;
  String? _clinicFilter;
  ChangeKind? _kindFilter;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await Future.wait([
        widget.admin.listPendingReviews(),
        widget.admin.listDecided(),
      ]);
      if (!mounted) return;
      bool mine(ChangeRequest r) =>
          widget.onlyClinicId == null || r.clinicId == widget.onlyClinicId;
      setState(() {
        _pending = results[0].where(mine).toList();
        _decided = results[1].where(mine).toList();
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

  String? _clinicName(String? id) {
    if (id == null) return null;
    for (final c in widget.clinics) {
      if (c.id == id) {
        return c.clinicLabel == null ? c.name : '${c.name} (${c.clinicLabel})';
      }
    }
    return null;
  }

  Future<void> _decide(
    ChangeRequest r, {
    required bool approve,
  }) async {
    String? note;
    ClinicRole? role;

    if (!approve) {
      note = await askForText(
        context,
        title: 'Turn down this request?',
        label: 'Reason',
        confirm: 'Turn down',
        multiline: true,
        destructive: true,
        message:
            '${r.who} sees this reason${r.kind == ChangeKind.join ? ' and can ask again' : ''}.',
      );
      if (note == null) return;
    } else if (r.kind == ChangeKind.join || r.kind == ChangeKind.move) {
      role = await _askRole(r);
      if (role == null) return;
    } else if (r.kind == ChangeKind.delete) {
      final ok = await confirmAction(
        context,
        title: 'Delete ${r.who}\'s account?',
        message:
            'Their login is removed for good and cannot be undone. Patients and '
            'tests they recorded stay with the clinic.',
        confirm: 'Delete account',
        destructive: true,
      );
      if (!ok) return;
    } else {
      final ok = await confirmAction(
        context,
        title: 'Approve this change?',
        message: r.kind == ChangeKind.email
            ? '${r.who} can then confirm the new address with a code sent to '
                  'it.'
            : r.kind == ChangeKind.clinic
            ? 'The new details print on every report from this clinic.'
            : 'The new details show at once, and print on their reports.',
        confirm: 'Approve',
      );
      if (!ok) return;
    }
    if (!mounted) return;

    try {
      await widget.admin.review(r, approve: approve, note: note, role: role);
      if (!mounted) return;
      showAdminMessage(
        context,
        approve
            ? r.kind == ChangeKind.delete
                  ? 'Account deleted.'
                  : 'Approved.'
            : 'Turned down.',
      );
    } on AdminException catch (e) {
      if (!mounted) return;
      showAdminMessage(context, e.message);
    }
    widget.onChanged?.call();
    await _load();
  }

  Future<ClinicRole?> _askRole(ChangeRequest r) {
    final current = ClinicRole.fromId(r.payload['role'] as String?);
    var role = ClinicRole.assignable.contains(current)
        ? current
        : ClinicRole.viewer;
    return showDialog<ClinicRole>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text(
            r.kind == ChangeKind.move
                ? 'Approve ${r.who}\'s move'
                : 'Approve ${r.who}',
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Role in ${r.requestedClinicLabel ?? 'the clinic'}',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              SegmentedButton<ClinicRole>(
                showSelectedIcon: false,
                segments: [
                  for (final role in ClinicRole.assignable)
                    ButtonSegment(value: role, label: Text(role.label)),
                ],
                selected: {role},
                onSelectionChanged: (s) => setState(() => role = s.first),
              ),
              const SizedBox(height: 8),
              Text(
                role.description,
                style: const TextStyle(
                  fontSize: 12,
                  height: 1.4,
                  color: AurisTheme.muted,
                ),
              ),
              if (r.kind == ChangeKind.move) ...[
                const SizedBox(height: 8),
                const Text(
                  'They lose access to their old clinic\'s records at once.',
                  style: TextStyle(fontSize: 12, color: AurisTheme.muted),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, role),
              child: const Text('Approve'),
            ),
          ],
        ),
      ),
    );
  }

  bool _matches(ChangeRequest r) =>
      (_clinicFilter == null || r.clinicId == _clinicFilter) &&
      (_kindFilter == null || r.kind == _kindFilter);

  @override
  Widget build(BuildContext context) {
    if (_loading && _pending.isEmpty && _decided.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Text(
            _error!,
            textAlign: TextAlign.center,
            style: const TextStyle(color: AurisTheme.muted),
          ),
        ),
      );
    }

    final shown = (_history ? _decided : _pending).where(_matches).toList();
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 40),
        children: [
          SegmentedButton<bool>(
            showSelectedIcon: false,
            segments: [
              ButtonSegment(
                value: false,
                label: Text('Waiting (${_pending.length})'),
              ),
              const ButtonSegment(value: true, label: Text('History')),
            ],
            selected: {_history},
            onSelectionChanged: (s) => setState(() => _history = s.first),
          ),
          if (widget.showFilters) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: DropdownButton<String?>(
                    isExpanded: true,
                    value: _clinicFilter,
                    items: [
                      const DropdownMenuItem(
                        value: null,
                        child: Text('All clinics'),
                      ),
                      for (final c in widget.clinics)
                        DropdownMenuItem(value: c.id, child: Text(c.name)),
                    ],
                    onChanged: (v) => setState(() => _clinicFilter = v),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButton<ChangeKind?>(
                    isExpanded: true,
                    value: _kindFilter,
                    items: [
                      const DropdownMenuItem(
                        value: null,
                        child: Text('All kinds'),
                      ),
                      for (final k in ChangeKind.values)
                        DropdownMenuItem(value: k, child: Text(k.label)),
                    ],
                    onChanged: (v) => setState(() => _kindFilter = v),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 14),
          if (shown.isEmpty)
            Text(
              _history
                  ? 'No decided requests yet.'
                  : 'Nothing is waiting for you.',
              style: const TextStyle(fontSize: 13, color: AurisTheme.muted),
            ),
          for (final r in shown)
            ChangeRequestCard(
              request: r,
              showWho: true,
              clinicName: widget.showFilters ? _clinicName(r.clinicId) : null,
              footer: r.isPending
                  ? Wrap(
                      spacing: 8,
                      children: [
                        FilledButton(
                          style: r.kind == ChangeKind.delete
                              ? FilledButton.styleFrom(
                                  backgroundColor: AurisTheme.rightEar,
                                )
                              : null,
                          onPressed: () => _decide(r, approve: true),
                          child: Text(
                            r.kind == ChangeKind.delete
                                ? 'Delete account'
                                : 'Approve',
                          ),
                        ),
                        OutlinedButton(
                          onPressed: () => _decide(r, approve: false),
                          child: const Text('Turn down'),
                        ),
                      ],
                    )
                  : null,
            ),
        ],
      ),
    );
  }
}
