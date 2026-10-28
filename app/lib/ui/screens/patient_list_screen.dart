import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/models/patient.dart';
import '../../utils/route_constants.dart';
import '../app_scope.dart';
import '../theme.dart';
import 'dashboard_screen.dart' show PatientTile;

class PatientListScreen extends StatefulWidget {
  const PatientListScreen({super.key});

  @override
  State<PatientListScreen> createState() => _PatientListScreenState();
}

class _PatientListScreenState extends State<PatientListScreen> {
  final _searchController = TextEditingController();
  Timer? _debounce;

  List<Patient> _patients = const [];
  bool _loading = true;
  Object? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await AppScope.of(context)
          .repository
          .listPatients(query: _searchController.text);
      if (!mounted) return;
      setState(() {
        _patients = results;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  /// Debounced so a query does not run on every keystroke.
  void _onSearchChanged(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 260), _load);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Patients')),
      // Viewers look records up; they cannot register patients.
      floatingActionButton: !AppScope.of(context).auth.role.canRegisterPatients
          ? null
          : FloatingActionButton.extended(
              backgroundColor: AurisTheme.primary,
              foregroundColor: Colors.white,
              icon: const Icon(Icons.person_add_alt_1_rounded),
              label: const Text('New patient'),
              onPressed: () async {
                await Navigator.pushNamed(context, patientFormRoute);
                if (mounted) _load();
              },
            ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
            child: TextField(
              controller: _searchController,
              onChanged: _onSearchChanged,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: 'Search by name or patient ID',
                prefixIcon: const Icon(Icons.search_rounded,
                    color: AurisTheme.muted, size: 21),
                suffixIcon: _searchController.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close_rounded, size: 19),
                        onPressed: () {
                          _searchController.clear();
                          _load();
                        },
                      ),
              ),
            ),
          ),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Text('Could not load patients.\n$_error',
              textAlign: TextAlign.center,
              style: const TextStyle(color: AurisTheme.muted)),
        ),
      );
    }

    if (_patients.isEmpty) {
      final searching = _searchController.text.trim().isNotEmpty;
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(searching ? Icons.search_off_rounded : Icons.folder_open_rounded,
                  size: 40, color: AurisTheme.muted),
              const SizedBox(height: 12),
              Text(
                searching
                    ? 'No patients match "${_searchController.text.trim()}".'
                    : 'No patients registered yet.',
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 14, height: 1.5, color: AurisTheme.muted),
              ),
            ],
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 96),
        itemCount: _patients.length,
        separatorBuilder: (_, __) => const SizedBox(height: 10),
        itemBuilder: (context, index) {
          final patient = _patients[index];
          return PatientTile(
            patient: patient,
            onTap: () async {
              await Navigator.pushNamed(context, patientDetailRoute,
                  arguments: patient);
              _load();
            },
          );
        },
      ),
    );
  }
}
