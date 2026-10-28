import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

/// Runtime configuration, read from `.env`.
///
/// `.env` is git-ignored. Copy `.env.example` to `.env` and fill it in to
/// enable cloud sync; leave it blank and Auris runs entirely offline against
/// the local SQLite database.
class Env {
  Env._();

  static bool _loaded = false;

  /// Loads `.env` if present. A missing or malformed file is not an error -
  /// the app simply runs in local-only mode.
  static Future<void> load() async {
    try {
      await dotenv.load(fileName: '.env');
      _loaded = true;
    } catch (e) {
      _loaded = false;
      debugPrint('Auris: no usable .env found, running local-only. ($e)');
    }
  }

  static String? _get(String key) {
    if (!_loaded) return null;
    final value = dotenv.env[key]?.trim();
    return (value == null || value.isEmpty) ? null : value;
  }

  static String? get supabaseUrl => _get('SUPABASE_URL');

  /// The Supabase *anon* key. This is a publishable key: it is designed to ship
  /// inside client apps and grants no access on its own. Every table is
  /// protected by row-level security policies (see `supabase/schema.sql`), so
  /// data access is decided by the signed-in user, not by this key.
  ///
  /// The service-role key must never appear here or anywhere in this repo.
  static String? get supabaseAnonKey => _get('SUPABASE_ANON_KEY');

  static String get clinicName => _get('CLINIC_NAME') ?? 'Auris Hearing Clinic';
  static String? get clinicAddress => _get('CLINIC_ADDRESS');
  static String? get clinicPhone => _get('CLINIC_PHONE');

  /// True only when both Supabase settings are present.
  static bool get cloudSyncEnabled =>
      supabaseUrl != null && supabaseAnonKey != null;
}
