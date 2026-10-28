import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../data/models/change_request.dart';
import '../theme.dart';

final _date = DateFormat('d MMM yyyy, HH:mm');

/// "12 Oct 2026, 14:05", or an empty string.
String formatWhen(DateTime? when) =>
    when == null ? '' : _date.format(when.toLocal());

/// The colour a request's status is shown in.
Color statusColor(ChangeStatus status) => switch (status) {
  ChangeStatus.pending => AurisTheme.warning,
  ChangeStatus.approved || ChangeStatus.completed => AurisTheme.success,
  ChangeStatus.rejected || ChangeStatus.flagged => AurisTheme.rightEar,
  ChangeStatus.cancelled => AurisTheme.muted,
};

/// Who decides a request at [level], in words.
String reviewerWords(String level) => level == 'clinic_admin'
    ? 'your clinic\'s admin'
    : 'a super admin';

/// One request: what it asks, old and new values side by side, and its
/// status. [footer] holds the buttons for whoever is looking at it.
class ChangeRequestCard extends StatelessWidget {
  const ChangeRequestCard({
    super.key,
    required this.request,
    this.showWho = false,
    this.clinicName,
    this.footer,
  });

  final ChangeRequest request;

  /// Show who asked (for reviewers); the requester knows already.
  final bool showWho;

  /// The clinic the request belongs to, when the viewer sees several.
  final String? clinicName;

  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final r = request;
    final diffs = r.differences;
    final clinicLabel = r.requestedClinicLabel;
    const small = TextStyle(fontSize: 12.5, height: 1.4, color: AurisTheme.muted);

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: AurisCard(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    showWho ? '${r.who} · ${r.kind.label}' : r.kind.label,
                    style: const TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w600,
                      color: AurisTheme.ink,
                    ),
                  ),
                ),
                _StatusChip(r.status),
              ],
            ),
            const SizedBox(height: 3),
            Text(
              [
                formatWhen(r.createdAt),
                if (showWho && r.userEmail != null) r.userEmail!,
                if (clinicName != null) clinicName!,
              ].where((s) => s.isNotEmpty).join(' · '),
              style: small,
            ),
            if (clinicLabel != null) ...[
              const SizedBox(height: 8),
              Text(
                r.kind == ChangeKind.move
                    ? 'From ${r.previous['clinic_name'] ?? 'their clinic'} '
                          'to $clinicLabel'
                    : r.kind == ChangeKind.join
                    ? 'Clinic: $clinicLabel'
                    : clinicLabel,
                style: const TextStyle(fontSize: 13, color: AurisTheme.ink),
              ),
            ],
            if (r.kind == ChangeKind.leave &&
                r.previous['clinic_name'] != null) ...[
              const SizedBox(height: 8),
              Text(
                'Left ${r.previous['clinic_name']}',
                style: const TextStyle(fontSize: 13, color: AurisTheme.ink),
              ),
            ],
            if (diffs.isNotEmpty) ...[
              const SizedBox(height: 8),
              Table(
                columnWidths: const {
                  0: IntrinsicColumnWidth(),
                  1: FlexColumnWidth(),
                  2: FlexColumnWidth(),
                },
                defaultVerticalAlignment: TableCellVerticalAlignment.top,
                children: [
                  const TableRow(
                    children: [
                      SizedBox(),
                      _Cell('Now', header: true),
                      _Cell('Asked for', header: true),
                    ],
                  ),
                  for (final (field, before, after) in diffs)
                    TableRow(
                      children: [
                        _Cell(field, header: true),
                        _Cell(before),
                        _Cell(after, highlight: true),
                      ],
                    ),
                ],
              ),
            ],
            if (r.reason != null) ...[
              const SizedBox(height: 8),
              Text('Reason given: ${r.reason}', style: small),
            ],
            if (r.isPending && !showWho) ...[
              const SizedBox(height: 6),
              Text('Waiting for ${reviewerWords(r.reviewerLevel)}.',
                  style: small),
            ],
            if (r.status == ChangeStatus.flagged) ...[
              const SizedBox(height: 6),
              const Text(
                'The login email was changed outside Auris, without an '
                'approved request.',
                style: small,
              ),
            ],
            if (!r.isPending && r.reviewedAt != null) ...[
              const SizedBox(height: 6),
              Text(
                '${r.status.label} ${formatWhen(r.reviewedAt)}'
                '${r.decisionNote == null ? '' : ': ${r.decisionNote}'}',
                style: small,
              ),
            ],
            if (footer != null) ...[const SizedBox(height: 10), footer!],
          ],
        ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip(this.status);
  final ChangeStatus status;

  @override
  Widget build(BuildContext context) {
    final color = statusColor(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(AurisTheme.pillRadius),
      ),
      child: Text(
        status.label,
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}

class _Cell extends StatelessWidget {
  const _Cell(this.text, {this.header = false, this.highlight = false});
  final String text;
  final bool header;
  final bool highlight;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(right: 10, bottom: 4),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 12.5,
        height: 1.35,
        fontWeight: header || highlight ? FontWeight.w600 : FontWeight.w400,
        color: highlight
            ? AurisTheme.ink
            : header
            ? AurisTheme.muted
            : AurisTheme.ink,
      ),
    ),
  );
}

/// Asks for one line of text. Returns null when cancelled. With [required],
/// the confirm button stays off until something is typed.
Future<String?> askForText(
  BuildContext context, {
  required String title,
  required String label,
  String? message,
  String confirm = 'Send',
  String initial = '',
  bool required = true,
  bool multiline = false,
  TextInputType? keyboardType,
  bool destructive = false,
  bool obscure = false,
  int minLength = 0,
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _TextPrompt(
      title: title,
      label: label,
      message: message,
      confirm: confirm,
      initial: initial,
      required: required,
      multiline: multiline,
      keyboardType: keyboardType,
      destructive: destructive,
      obscure: obscure,
      minLength: minLength,
    ),
  );
}

class _TextPrompt extends StatefulWidget {
  const _TextPrompt({
    required this.title,
    required this.label,
    required this.message,
    required this.confirm,
    required this.initial,
    required this.required,
    required this.multiline,
    required this.keyboardType,
    required this.destructive,
    required this.obscure,
    required this.minLength,
  });

  final String title;
  final String label;
  final String? message;
  final String confirm;
  final String initial;
  final bool required;
  final bool multiline;
  final TextInputType? keyboardType;
  final bool destructive;
  final bool obscure;
  final int minLength;

  @override
  State<_TextPrompt> createState() => _TextPromptState();
}

class _TextPromptState extends State<_TextPrompt> {
  late final _controller = TextEditingController(text: widget.initial);
  bool _show = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _ok =>
      (!widget.required || _controller.text.trim().isNotEmpty) &&
      _controller.text.length >= widget.minLength;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.message != null) ...[
            Text(
              widget.message!,
              style: const TextStyle(
                fontSize: 13,
                height: 1.45,
                color: AurisTheme.muted,
              ),
            ),
            const SizedBox(height: 12),
          ],
          TextField(
            controller: _controller,
            autofocus: true,
            keyboardType: widget.keyboardType,
            obscureText: widget.obscure && !_show,
            minLines: widget.multiline ? 2 : 1,
            maxLines: widget.multiline ? 4 : 1,
            decoration: InputDecoration(
              labelText: widget.label,
              suffixIcon: !widget.obscure
                  ? null
                  : IconButton(
                      tooltip: _show ? 'Hide' : 'Show',
                      icon: Icon(
                        _show
                            ? Icons.visibility_off_outlined
                            : Icons.visibility_outlined,
                        size: 19,
                      ),
                      onPressed: () => setState(() => _show = !_show),
                    ),
            ),
            onChanged: (_) => setState(() {}),
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
        style: widget.destructive
            ? FilledButton.styleFrom(backgroundColor: AurisTheme.rightEar)
            : null,
        onPressed: _ok
            ? () => Navigator.pop(
                  context,
                  widget.obscure ? _controller.text : _controller.text.trim(),
                )
            : null,
        child: Text(widget.confirm),
      ),
    ],
  );
}

/// Asks a yes/no question. True only when confirmed.
Future<bool> confirmAction(
  BuildContext context, {
  required String title,
  required String message,
  required String confirm,
  bool destructive = false,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: destructive
              ? FilledButton.styleFrom(backgroundColor: AurisTheme.rightEar)
              : null,
          onPressed: () => Navigator.pop(context, true),
          child: Text(confirm),
        ),
      ],
    ),
  );
  return ok == true;
}
