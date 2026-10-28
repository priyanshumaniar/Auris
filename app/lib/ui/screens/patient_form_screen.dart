import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';

import '../../data/models/patient.dart';
import '../app_scope.dart';
import '../theme.dart';
import '../widgets/auris_button.dart';
import '../widgets/auris_input_field.dart';

/// Registers a new patient, or edits an existing one when [patient] is given.
class PatientFormScreen extends StatefulWidget {
  const PatientFormScreen({super.key, this.patient});

  final Patient? patient;

  bool get isEditing => patient != null;

  @override
  State<PatientFormScreen> createState() => _PatientFormScreenState();
}

class _PatientFormScreenState extends State<PatientFormScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _age;
  late final TextEditingController _clinicRef;
  late final TextEditingController _phone;
  late final TextEditingController _notes;

  late String _sex;
  DateTime? _dateOfBirth;
  bool _busy = false;
  String? _error;

  static const _sexOptions = ['Male', 'Female', 'Other'];

  @override
  void initState() {
    super.initState();
    final p = widget.patient;
    _name = TextEditingController(text: p?.fullName ?? '');
    // Today's age, not the age typed at registration years ago.
    _age = TextEditingController(
        text: p == null ? '' : p.ageAt(DateTime.now()).toString());
    _clinicRef = TextEditingController(text: p?.clinicRef ?? '');
    _phone = TextEditingController(text: p?.phone ?? '');
    _notes = TextEditingController(text: p?.notes ?? '');
    _sex = p?.sex ?? _sexOptions.first;
    _dateOfBirth = p?.dateOfBirth;
  }

  /// Age in whole years on [today] for someone born on [dob].
  static int _ageOn(DateTime dob, DateTime today) {
    var age = today.year - dob.year;
    if (today.month < dob.month ||
        (today.month == dob.month && today.day < dob.day)) {
      age--;
    }
    return age;
  }

  Future<void> _pickDateOfBirth() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _dateOfBirth ?? DateTime(now.year - 30, now.month, now.day),
      firstDate: DateTime(now.year - 130),
      lastDate: now,
      helpText: 'Date of birth',
    );
    if (picked == null || !mounted) return;
    setState(() {
      _dateOfBirth = picked;
      // Keep the age consistent with the date of birth.
      _age.text = _ageOn(picked, now).toString();
    });
  }

  @override
  void dispose() {
    _name.dispose();
    _age.dispose();
    _clinicRef.dispose();
    _phone.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final now = DateTime.now();
      final existing = widget.patient;
      final trimmedRef = _clinicRef.text.trim();
      final trimmedPhone = _phone.text.trim();
      final trimmedNotes = _notes.text.trim();

      // Built directly rather than with copyWith, so an optional field the
      // user cleared is saved as cleared.
      final patient = Patient(
        id: existing?.id ?? const Uuid().v4(),
        fullName: _name.text.trim(),
        ageYears: int.parse(_age.text.trim()),
        sex: _sex,
        clinicRef: trimmedRef.isEmpty ? null : trimmedRef,
        dateOfBirth: _dateOfBirth,
        phone: trimmedPhone.isEmpty ? null : trimmedPhone,
        notes: trimmedNotes.isEmpty ? null : trimmedNotes,
        createdAt: existing?.createdAt ?? now,
        updatedAt: now,
      );

      final saved = await AppScope.of(context).repository.upsertPatient(patient);
      if (!mounted) return;
      Navigator.pop(context, saved);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not save the patient. $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isEditing ? 'Edit patient' : 'New patient'),
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(0, 8, 0, 40),
          children: [
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 20),
              child: SectionLabel('Patient details'),
            ),
            const SizedBox(height: 12),
            AurisInputField(
              controller: _name,
              textHint: 'Full name',
              icon: Icons.person_outline,
              textCapitalization: TextCapitalization.words,
              autovalidateMode: AutovalidateMode.onUserInteraction,
              validator: (value) =>
                  (value?.trim().isEmpty ?? true) ? 'Enter the patient name' : null,
            ),
            const SizedBox(height: 12),
            AurisInputField(
              controller: _age,
              textHint: 'Age in years',
              icon: Icons.cake_outlined,
              keyboardType: TextInputType.number,
              autovalidateMode: AutovalidateMode.onUserInteraction,
              validator: (value) {
                final age = int.tryParse(value?.trim() ?? '');
                if (age == null) return 'Enter the age in years';
                if (age < 0 || age > 130) return 'Enter a realistic age';
                final dob = _dateOfBirth;
                if (dob != null && age != _ageOn(dob, DateTime.now())) {
                  return 'The date of birth makes them '
                      '${_ageOn(dob, DateTime.now())}';
                }
                return null;
              },
            ),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SectionLabel('Sex'),
                  const SizedBox(height: 8),
                  SegmentedButton<String>(
                    segments: [
                      for (final option in _sexOptions)
                        ButtonSegment(value: option, label: Text(option)),
                    ],
                    selected: {_sex},
                    showSelectedIcon: false,
                    onSelectionChanged: (selection) =>
                        setState(() => _sex = selection.first),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 20),
              child: SectionLabel('Optional'),
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  const Icon(Icons.event_outlined,
                      size: 20, color: AurisTheme.muted),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      _dateOfBirth == null
                          ? 'Date of birth not set'
                          : 'Born ${DateFormat('d MMM yyyy').format(_dateOfBirth!)}',
                      style: const TextStyle(
                          fontSize: 14, color: AurisTheme.ink),
                    ),
                  ),
                  TextButton(
                    onPressed: _pickDateOfBirth,
                    child: Text(_dateOfBirth == null ? 'Set' : 'Change'),
                  ),
                  if (_dateOfBirth != null)
                    TextButton(
                      onPressed: () => setState(() => _dateOfBirth = null),
                      child: const Text('Clear'),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            AurisInputField(
              controller: _clinicRef,
              textHint: 'Patient ID / file number',
              icon: Icons.tag_rounded,
            ),
            const SizedBox(height: 12),
            AurisInputField(
              controller: _phone,
              textHint: 'Phone',
              icon: Icons.phone_outlined,
              keyboardType: TextInputType.phone,
            ),
            const SizedBox(height: 12),
            AurisInputField(
              controller: _notes,
              textHint: 'Clinical notes',
              icon: Icons.notes_rounded,
            ),
            if (_error != null) ...[
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Text(_error!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        color: AurisTheme.rightEar, fontSize: 13)),
              ),
            ],
            const SizedBox(height: 26),
            Center(
              child: AurisButton(
                buttonName: widget.isEditing ? 'Save changes' : 'Register patient',
                busy: _busy,
                width: 240,
                onTap: _save,
              ),
            ),
            const SizedBox(height: 16),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 30),
              child: Text(
                'Patient details are health data. They are stored in your '
                'clinic database and are never shared with third parties.',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 11.5, height: 1.5, color: AurisTheme.muted),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
