import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sb;
import 'package:uuid/uuid.dart';

import 'local_database.dart';
import 'models/clinic.dart';
import 'models/clinic_role.dart';

/// The signed-in clinician. Tests are attributed to this person on the report.
class Clinician {
  const Clinician({
    required this.id,
    required this.username,
    required this.displayName,
    this.role = ClinicRole.clinician,
    this.clinicId,
  });

  final String id;
  final String username;
  final String displayName;

  /// What this user is allowed to do. See [ClinicRole].
  final ClinicRole role;

  /// The clinic whose records this user can see. Null in local-only mode,
  /// where the device itself is the boundary.
  final String? clinicId;
}

class AuthException implements Exception {
  const AuthException(this.message);
  final String message;
  @override
  String toString() => message;
}

abstract class AuthService {
  Clinician? get currentClinician;
  bool get isSignedIn => currentClinician != null;

  /// The signed-in user's role, or [ClinicRole.pending] (no access) when
  /// nobody is signed in - an unknown user must fail closed.
  ClinicRole get role => currentClinician?.role ?? ClinicRole.pending;

  Future<Clinician> signIn({required String username, required String password});

  /// Registers a user.
  ///
  /// [role] is honoured only where the caller is allowed to set it: in
  /// local-only mode the first account is always an admin (otherwise nobody
  /// could administer the device), and later accounts wait for approval.
  ///
  /// [joinCode] is a clinic's join code, cloud mode only: it puts the new
  /// account on that clinic's waiting list.
  Future<Clinician> signUp({
    required String username,
    required String displayName,
    required String password,
    ClinicRole? role,
    String? joinCode,
  });
  Future<void> signOut();
}

// ---------------------------------------------------------------------------
// Password hashing
// ---------------------------------------------------------------------------

/// PBKDF2 work factor.
///
/// Deliberately high enough to make offline brute-forcing of a stolen database
/// expensive. Hashing runs on a background isolate so the ~0.5 s cost does not
/// block the UI. (A native argon2 binding would be stronger still; that is
/// noted as a limitation in the README rather than pretended away.)
const int _kPbkdf2Iterations = 50000;
const int _kKeyLengthBytes = 32;

class _HashRequest {
  const _HashRequest(this.password, this.salt);
  final String password;
  final String salt;
}

/// PBKDF2-HMAC-SHA256. Top-level so it can run via [compute].
String _derivePasswordHash(_HashRequest req) {
  final hmac = Hmac(sha256, utf8.encode(req.password));
  final salt = base64Decode(req.salt);

  // Single output block: 32 bytes of SHA-256 output is exactly the key length.
  final block = Uint8List(salt.length + 4)
    ..setRange(0, salt.length, salt)
    ..buffer.asByteData().setUint32(salt.length, 1, Endian.big);

  var u = Uint8List.fromList(hmac.convert(block).bytes);
  final result = Uint8List.fromList(u);

  for (var i = 1; i < _kPbkdf2Iterations; i++) {
    u = Uint8List.fromList(hmac.convert(u).bytes);
    for (var j = 0; j < _kKeyLengthBytes; j++) {
      result[j] ^= u[j];
    }
  }
  return base64Encode(result);
}

/// Compares two strings in time independent of where they first differ, so a
/// timing measurement cannot reveal the hash byte by byte.
bool _constantTimeEquals(String a, String b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return diff == 0;
}

// ---------------------------------------------------------------------------
// Local (offline) authentication
// ---------------------------------------------------------------------------

/// Authenticates against the on-device `clinicians` table.
///
/// Used when cloud sync is not configured. Passwords are stored as a PBKDF2
/// hash with a per-user random salt - never in plain text.
class LocalAuthService implements AuthService {
  LocalAuthService(this._local);

  final LocalDatabase _local;
  Database get _db => _local.db;

  Clinician? _current;
  @override
  Clinician? get currentClinician => _current;

  @override
  bool get isSignedIn => _current != null;

  @override
  ClinicRole get role => _current?.role ?? ClinicRole.pending;

  @override
  Future<Clinician> signIn({
    required String username,
    required String password,
  }) async {
    final rows = await _db.query(
      'clinicians',
      where: 'username = ?',
      whereArgs: [username.trim().toLowerCase()],
      limit: 1,
    );
    if (rows.isEmpty) {
      // Same message for "no such user" and "wrong password", so the login form
      // cannot be used to enumerate who works at the clinic.
      throw const AuthException('Incorrect username or password.');
    }

    final row = rows.first;
    final expected = row['password_hash'] as String;
    final salt = row['password_salt'] as String;
    final actual = await compute(
      _derivePasswordHash,
      _HashRequest(password, salt),
    );

    if (!_constantTimeEquals(expected, actual)) {
      throw const AuthException('Incorrect username or password.');
    }

    return _current = Clinician(
      id: row['id'] as String,
      username: row['username'] as String,
      displayName: row['display_name'] as String,
      role: ClinicRole.fromId(row['role'] as String?),
      clinicId: row['clinic_id'] as String?,
    );
  }

  @override
  Future<Clinician> signUp({
    required String username,
    required String displayName,
    required String password,
    ClinicRole? role,
    String? joinCode,
  }) async {
    final normalised = username.trim().toLowerCase();
    if (normalised.isEmpty) {
      throw const AuthException('Username is required.');
    }
    if (password.length < 8) {
      throw const AuthException('Password must be at least 8 characters.');
    }

    final existing = await _db.query('clinicians',
        where: 'username = ?', whereArgs: [normalised], limit: 1);
    if (existing.isNotEmpty) {
      throw const AuthException('That username is already registered.');
    }

    // The very first account on a device becomes the administrator - there
    // would otherwise be nobody able to grant that role. After that, only an
    // administrator may choose a role. Anyone registering themselves waits
    // for approval, so creating an account is never enough to read records.
    final firstAccount = !await hasAnyClinician();
    final ClinicRole resolvedRole;
    if (firstAccount) {
      resolvedRole = ClinicRole.admin;
    } else if (role != null) {
      if (!(_current?.role.canManageUsers ?? false)) {
        throw const AuthException(
            'Only an administrator can create an account with a chosen role.');
      }
      resolvedRole = role;
    } else {
      resolvedRole = ClinicRole.pending;
    }

    final rng = Random.secure();
    final salt = base64Encode(
        Uint8List.fromList(List.generate(16, (_) => rng.nextInt(256))));
    final hash =
        await compute(_derivePasswordHash, _HashRequest(password, salt));

    final clinician = Clinician(
      id: const Uuid().v4(),
      username: normalised,
      displayName: displayName.trim().isEmpty ? normalised : displayName.trim(),
      role: resolvedRole,
    );

    await _db.insert('clinicians', {
      'id': clinician.id,
      'username': clinician.username,
      'display_name': clinician.displayName,
      'password_hash': hash,
      'password_salt': salt,
      'role': clinician.role.id,
      'created_at': DateTime.now().toIso8601String(),
    });

    // Creating an account for someone else must not sign the administrator out
    // of their own session. Someone registering themselves is signed in, and
    // sees the "awaiting approval" screen until an administrator acts.
    if (firstAccount || _current == null) _current = clinician;
    return clinician;
  }

  /// Every account on this device. Administrators use this to manage users.
  Future<List<Clinician>> listClinicians() async {
    final rows = await _db.query('clinicians', orderBy: 'created_at ASC');
    return [
      for (final row in rows)
        Clinician(
          id: row['id'] as String,
          username: row['username'] as String,
          displayName: row['display_name'] as String,
          role: ClinicRole.fromId(row['role'] as String?),
          clinicId: row['clinic_id'] as String?,
        ),
    ];
  }

  /// Changes another user's role. Administrators only.
  Future<void> setRole(String clinicianId, ClinicRole role) async {
    if (!(_current?.role.canManageUsers ?? false)) {
      throw const AuthException('Only an administrator can change roles.');
    }
    if (clinicianId == _current?.id && role != ClinicRole.admin) {
      // Removing your own admin rights could leave the device with no
      // administrator and no way to appoint one.
      final admins = (await listClinicians())
          .where((c) => c.role == ClinicRole.admin)
          .length;
      if (admins <= 1) {
        throw const AuthException(
            'This is the only administrator. Promote someone else first.');
      }
    }
    await _db.update('clinicians', {'role': role.id},
        where: 'id = ?', whereArgs: [clinicianId]);
    if (clinicianId == _current?.id) {
      _current = Clinician(
        id: _current!.id,
        username: _current!.username,
        displayName: _current!.displayName,
        role: role,
        clinicId: _current!.clinicId,
      );
    }
  }

  /// The signed-in user's own account, for the profile screen.
  Future<ClinicAccount?> loadProfile() async {
    final current = _current;
    if (current == null) return null;
    final rows = await _db.query('clinicians',
        where: 'id = ?', whereArgs: [current.id], limit: 1);
    if (rows.isEmpty) return null;
    final row = rows.first;
    return ClinicAccount(
      id: row['id'] as String,
      displayName: row['display_name'] as String,
      role: ClinicRole.fromId(row['role'] as String?),
      createdAt: DateTime.tryParse(row['created_at'] as String? ?? ''),
      phone: _blankToNull(row['phone']),
      qualification: _blankToNull(row['qualification']),
      registrationNo: _blankToNull(row['registration_no']),
    );
  }

  /// Changes the signed-in user's own details. On a device without a cloud
  /// clinic nobody else reviews them, so they apply at once.
  Future<void> updateProfile({
    required String displayName,
    String? phone,
    String? qualification,
    String? registrationNo,
  }) async {
    final current = _current;
    if (current == null) throw const AuthException('Sign in first.');
    final name = displayName.trim();
    if (name.isEmpty) throw const AuthException('Your name cannot be empty.');
    await _db.update(
      'clinicians',
      {
        'display_name': name,
        'phone': _blankToNull(phone),
        'qualification': _blankToNull(qualification),
        'registration_no': _blankToNull(registrationNo),
      },
      where: 'id = ?',
      whereArgs: [current.id],
    );
    _current = Clinician(
      id: current.id,
      username: current.username,
      displayName: name,
      role: current.role,
      clinicId: current.clinicId,
    );
  }

  /// Sets a new password for another account on this device, for someone who
  /// has forgotten theirs (local accounts have no email to reset by).
  /// Administrators only.
  Future<void> resetPasswordFor(String clinicianId, String newPassword) async {
    if (!(_current?.role.canManageUsers ?? false)) {
      throw const AuthException(
          'Only an administrator can set another person\'s password.');
    }
    if (newPassword.length < 8) {
      throw const AuthException('Password must be at least 8 characters.');
    }
    final rng = Random.secure();
    final salt = base64Encode(
        Uint8List.fromList(List.generate(16, (_) => rng.nextInt(256))));
    final hash =
        await compute(_derivePasswordHash, _HashRequest(newPassword, salt));
    final updated = await _db.update(
      'clinicians',
      {'password_hash': hash, 'password_salt': salt},
      where: 'id = ?',
      whereArgs: [clinicianId],
    );
    if (updated == 0) throw const AuthException('No such account.');
  }

  /// Changes the signed-in user's password after checking the current one.
  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    final current = _current;
    if (current == null) throw const AuthException('Sign in first.');
    if (newPassword.length < 8) {
      throw const AuthException('Password must be at least 8 characters.');
    }
    final rows = await _db.query('clinicians',
        where: 'id = ?', whereArgs: [current.id], limit: 1);
    if (rows.isEmpty) throw const AuthException('Sign in first.');
    final actual = await compute(
      _derivePasswordHash,
      _HashRequest(currentPassword, rows.first['password_salt'] as String),
    );
    if (!_constantTimeEquals(rows.first['password_hash'] as String, actual)) {
      throw const AuthException('Your current password is not right.');
    }
    final rng = Random.secure();
    final salt = base64Encode(
        Uint8List.fromList(List.generate(16, (_) => rng.nextInt(256))));
    final hash =
        await compute(_derivePasswordHash, _HashRequest(newPassword, salt));
    await _db.update(
      'clinicians',
      {'password_hash': hash, 'password_salt': salt},
      where: 'id = ?',
      whereArgs: [current.id],
    );
  }

  @override
  Future<void> signOut() async => _current = null;

  /// True when no clinician has registered yet, so the UI can send a first-run
  /// user to sign-up instead of a login form they cannot pass.
  Future<bool> hasAnyClinician() async {
    final rows = await _db.rawQuery('SELECT COUNT(*) AS n FROM clinicians');
    return ((rows.first['n'] as num?)?.toInt() ?? 0) > 0;
  }
}

String? _blankToNull(Object? v) =>
    v is String && v.trim().isNotEmpty ? v.trim() : null;

// ---------------------------------------------------------------------------
// Supabase authentication
// ---------------------------------------------------------------------------

/// Authenticates against Supabase Auth. Used when cloud sync is configured.
class SupabaseAuthService implements AuthService {
  SupabaseAuthService(this._client);

  final sb.SupabaseClient _client;

  /// Role and clinic come from the `profiles` table, not from the JWT's user
  /// metadata. User metadata is writable by the user themselves, so a role
  /// stored there could be self-promoted to admin with one API call. The
  /// `profiles` table is protected by a policy that forbids changing your own
  /// role - see `supabase/schema.sql`.
  ClinicRole _role = ClinicRole.pending;
  String? _clinicId;
  String? _displayName;
  ClinicDetails? _clinic;
  String? _requestedClinic;
  ClinicAccount? _me;
  Clinic? _clinicRecord;

  /// The signed-in user's clinic, for report headers. Null without one.
  ClinicDetails? get clinic => _clinic;

  /// The signed-in user's approved profile: what others see and what reports
  /// print. Changes waiting for approval are not in it.
  ClinicAccount? get profile => _me;

  /// The signed-in user's clinic, with its number and join code.
  Clinic? get clinicRecord => _clinicRecord;

  /// Profile columns the app reads. Also used by [CloudAdminService].
  static const profileColumns =
      'id, email, display_name, role, clinic_id, requested_clinic_id, '
      'requested_clinic, created_at, phone, qualification, registration_no, '
      'approved_at, email_alerts';

  /// Clinic columns the app reads.
  static const clinicColumns = 'id, name, address, phone, join_code, clinic_no';

  /// The join code a pending user asked to join with, if any.
  String? get requestedClinic => _requestedClinic;

  static const _profileCachePrefix = 'auris.profile.';

  @override
  Clinician? get currentClinician {
    final user = _client.auth.currentUser;
    if (user == null) return null;
    return Clinician(
      id: user.id,
      username: user.email ?? user.id,
      displayName: _displayName ??
          (user.userMetadata?['display_name'] as String?) ??
          // Google sign-in puts the name here instead.
          (user.userMetadata?['full_name'] as String?) ??
          (user.userMetadata?['name'] as String?) ??
          user.email ??
          'Clinician',
      role: _role,
      clinicId: _clinicId,
    );
  }

  @override
  bool get isSignedIn => currentClinician != null;

  @override
  ClinicRole get role =>
      _client.auth.currentUser == null ? ClinicRole.pending : _role;

  /// Loads the signed-in user's profile row.
  ///
  /// A missing profile means no access (pending). When the profile cannot be
  /// read, for example offline, the last profile this device saw for the same
  /// user is used, so a clinic can keep working without a connection. With no
  /// saved profile either, the user gets no access: a network blip must never
  /// hand out access the server has not granted.
  Future<void> refreshProfile() async {
    final user = _client.auth.currentUser;
    if (user == null) {
      _clearProfile();
      return;
    }

    try {
      final row = await _client
          .from('profiles')
          .select(profileColumns)
          .eq('id', user.id)
          .maybeSingle();

      if (row == null) {
        if (kDebugMode) {
          debugPrint('Auris: no profile row for this account; no access '
              'until an administrator assigns a role.');
        }
        _clearProfile();
        await _cacheProfile(user.id);
        return;
      }
      _role = ClinicRole.fromId(row['role'] as String?);
      _clinicId = _role == ClinicRole.pending
          ? null
          : row['clinic_id'] as String?;
      _displayName = row['display_name'] as String?;
      _requestedClinic = row['requested_clinic'] as String?;
      _me = ClinicAccount.fromRow(row);
    } catch (e) {
      // Offline, or the server could not answer: keep working with the
      // profile this device last saw for the same account. The server still
      // enforces access to every record.
      final cached = await _cachedProfile(user.id);
      _role = ClinicRole.fromId(cached?['role'] as String?);
      _clinicId = cached?['clinicId'] as String?;
      _displayName = cached?['displayName'] as String?;
      _requestedClinic = cached?['requestedClinic'] as String?;
      _clinic = ClinicDetails.fromJson(cached?['clinic']);
      _me = ClinicAccount.fromJson(cached?['account']);
      _clinicRecord = Clinic.fromJson(cached?['clinicRecord']);
      if (kDebugMode) {
        debugPrint('Auris: could not read the profile ($e); using the one '
            'last seen on this device.');
      }
      return;
    }

    // The profile was read fresh. The clinic is read on its own, so failing
    // to reach it never brings back an older, wider role from the cache.
    final clinicId = _clinicId;
    final previous = _clinicRecord;
    _clinic = null;
    _clinicRecord = null;
    if (clinicId != null) {
      try {
        final clinicRow = await _client
            .from('clinics')
            .select(clinicColumns)
            .eq('id', clinicId)
            .maybeSingle();
        if (clinicRow != null) _clinicRecord = Clinic.fromRow(clinicRow);
      } catch (_) {
        // Keep what this device knew about the same clinic, if anything.
        if (previous?.id == clinicId) {
          _clinicRecord = previous;
        } else {
          final cached = await _cachedProfile(user.id);
          final cachedClinic = Clinic.fromJson(cached?['clinicRecord']);
          if (cachedClinic?.id == clinicId) _clinicRecord = cachedClinic;
        }
      }
      _clinic = _clinicRecord?.details;
    }
    await _cacheProfile(user.id);
  }

  void _clearProfile() {
    _role = ClinicRole.pending;
    _clinicId = null;
    _displayName = null;
    _clinic = null;
    _requestedClinic = null;
    _me = null;
    _clinicRecord = null;
  }

  Future<void> _cacheProfile(String userId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        '$_profileCachePrefix$userId',
        jsonEncode({
          'role': _role.id,
          'clinicId': _clinicId,
          'displayName': _displayName,
          'requestedClinic': _requestedClinic,
          'clinic': _clinic?.toJson(),
          'account': _me?.toJson(),
          'clinicRecord': _clinicRecord?.toJson(),
        }),
      );
    } catch (_) {
      // The cache only helps offline starts; failing to write it is harmless.
    }
  }

  Future<Map<String, Object?>?> _cachedProfile(String userId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('$_profileCachePrefix$userId');
      if (raw == null) return null;
      final decoded = jsonDecode(raw);
      return decoded is Map<String, Object?> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<Clinician> signIn({
    required String username,
    required String password,
  }) async {
    try {
      await _client.auth
          .signInWithPassword(email: username.trim(), password: password);
    } on sb.AuthException catch (e) {
      throw AuthException(e.message);
    }
    await refreshProfile();
    final clinician = currentClinician;
    if (clinician == null) throw const AuthException('Sign-in failed.');
    return clinician;
  }

  @override
  Future<Clinician> signUp({
    required String username,
    required String displayName,
    required String password,
    ClinicRole? role,
    String? joinCode,
  }) async {
    final code = joinCode?.trim();
    try {
      await _client.auth.signUp(
        email: username.trim(),
        password: password,
        // display_name and join_code are requests only: the role and clinic
        // in `profiles` govern access, and only an administrator sets them.
        data: {
          'display_name': displayName.trim(),
          if (code != null && code.isNotEmpty) 'join_code': code,
        },
      );
    } on sb.AuthException catch (e) {
      throw AuthException(e.message);
    }

    if (_client.auth.currentUser == null) {
      // Supabase can require email confirmation before a session exists.
      throw const AuthException(
          'Account created. Confirm your email address, then sign in.');
    }
    await refreshProfile();

    final clinician = currentClinician;
    if (clinician == null) throw const AuthException('Sign-up failed.');
    return clinician;
  }

  @override
  Future<void> signOut() async {
    try {
      await _client.auth.signOut();
    } finally {
      // Even if the server could not be told, nothing of this account may
      // stay in memory for the next person.
      _clearProfile();
    }
  }

  // -------------------------------------------------------------------------
  // Google sign-in
  // -------------------------------------------------------------------------

  /// Where Google sends the user back after they sign in.
  ///
  /// It must be registered as a URL scheme for the app on every platform
  /// (macOS and iOS Info.plist, Android manifest) AND listed under
  /// Authentication -> URL Configuration -> Redirect URLs in Supabase, or
  /// Supabase refuses to redirect to it.
  static const String oauthRedirectUrl =
      'dev.priyanshumaniar.auris://login-callback';

  /// Opens Google's sign-in page in the browser.
  ///
  /// Returns as soon as the page is open. The session arrives later, when the
  /// browser hands the user back to the app through [oauthRedirectUrl];
  /// listen to [signedIn] to know when.
  Future<void> startGoogleSignIn() async {
    final bool opened;
    try {
      opened = await _client.auth.signInWithOAuth(
        sb.OAuthProvider.google,
        redirectTo: oauthRedirectUrl,
      );
    } on sb.AuthException catch (e) {
      throw AuthException(e.message);
    }
    if (!opened) {
      throw const AuthException(
          'Could not open the browser for Google sign-in.');
    }
  }

  /// Emits each time a session starts, for any sign-in method, including a
  /// password sign-in the screen itself started. The profile is not loaded
  /// yet: a listener that acts on it calls [refreshProfile] first, so only
  /// the listener that needs it pays for the round trip.
  Stream<void> get signedIn => _client.auth.onAuthStateChange
      .where((state) => state.event == sb.AuthChangeEvent.signedIn)
      .map((_) {});

  // -------------------------------------------------------------------------
  // Forgot password
  // -------------------------------------------------------------------------

  /// Emails a one-time recovery code.
  ///
  /// A code rather than a link: a desktop or mobile app has no web page for a
  /// link to land on. The Supabase "Reset Password" email template must
  /// include `{{ .Token }}` for the code to appear in the email.
  ///
  /// Supabase answers the same way whether or not the address has an account,
  /// so this cannot be used to find out who is registered.
  Future<void> sendPasswordResetCode(String email) async {
    try {
      await _client.auth.resetPasswordForEmail(email.trim());
    } on sb.AuthException catch (e) {
      throw AuthException(e.message);
    }
  }

  /// Checks [code], sets [newPassword] and leaves the user signed in.
  Future<Clinician> resetPasswordWithCode({
    required String email,
    required String code,
    required String newPassword,
  }) async {
    try {
      await _client.auth.verifyOTP(
        type: sb.OtpType.recovery,
        email: email.trim(),
        token: code.trim(),
      );
    } on sb.AuthException catch (e) {
      throw AuthException(e.message);
    }
    try {
      await _client.auth.updateUser(sb.UserAttributes(password: newPassword));
    } catch (e) {
      // The code is used up and verifying it signed the user in. Sign out
      // again, or the app would open signed in with no new password set.
      try {
        await _client.auth.signOut();
      } catch (_) {
        // Already signed out, or offline: nothing more to undo here.
      }
      final reason = e is sb.AuthException ? e.message.trim() : '$e';
      final sentence = reason.endsWith('.') ? reason : '$reason.';
      throw AuthException('$sentence The code has been used, so request a new '
          'one and try again.');
    }
    await refreshProfile();
    final clinician = currentClinician;
    if (clinician == null) {
      throw const AuthException(
          'Password changed. Sign in with your new password.');
    }
    return clinician;
  }
}
