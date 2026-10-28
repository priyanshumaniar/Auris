import 'package:flutter/material.dart';

import '../core/audiometry/audiometry.dart';
import '../data/models/patient.dart';
import '../data/models/test_protocol.dart';
import '../data/models/test_session.dart';
import '../ui/screens/admin_console_screen.dart';
import '../ui/screens/calibration_history_screen.dart';
import '../ui/screens/clinic_team_screen.dart';
import '../ui/screens/calibration_wizard_screen.dart';
import '../ui/screens/comparison_screen.dart';
import '../ui/screens/dashboard_screen.dart';
import '../ui/screens/forgot_password_screen.dart';
import '../ui/screens/help_screen.dart';
import '../ui/screens/landing_screen.dart';
import '../ui/screens/login_screen.dart';
import '../ui/screens/onboarding_screen.dart';
import '../ui/screens/patient_detail_screen.dart';
import '../ui/screens/patient_form_screen.dart';
import '../ui/screens/patient_list_screen.dart';
import '../ui/screens/profile_screen.dart';
import '../ui/screens/results_screen.dart';
import '../ui/screens/settings_screen.dart';
import '../ui/screens/sign_up_screen.dart';
import '../ui/screens/test_run_screen.dart';
import '../ui/screens/test_setup_screen.dart';
import '../ui/screens/user_management_screen.dart';
import 'route_constants.dart';

/// Argument records for routes that need more than one value.
typedef TestRunArgs = ({
  Patient patient,
  List<Ear> ears,
  TestProtocolRecord protocol,
});
typedef ResultsArgs = ({Patient patient, TestSession session, bool isFresh});
typedef ComparisonArgs = ({Patient patient, List<TestSession> sessions});

class RouteConfig {
  static Route<dynamic> generateRoute(RouteSettings settings) {
    final args = settings.arguments;

    switch (settings.name) {
      case landingRoute:
        return _page(const Landing(), settings);

      case onboardingRoute:
        return _page(const OnboardingScreen(), settings);

      case loginRoute:
        return _page(const LoginScreen(), settings);

      case signUpRoute:
        return _page(const SignUpScreen(), settings);

      case forgotPasswordRoute:
        return _page(
          ForgotPasswordScreen(
              initialEmail: args is String ? args : null),
          settings,
        );

      case dashboardRoute:
        return _page(const DashboardScreen(), settings);

      case patientListRoute:
        return _page(const PatientListScreen(), settings);

      case patientFormRoute:
        // Null arguments mean "create"; a Patient means "edit".
        return _page(
            PatientFormScreen(patient: args is Patient ? args : null), settings);

      case patientDetailRoute:
        if (args is! Patient) return _error(settings);
        return _page(PatientDetailScreen(patient: args), settings);

      case testSetupRoute:
        if (args is! Patient) return _error(settings);
        return _page(TestSetupScreen(patient: args), settings);

      case testRunRoute:
        if (args is! TestRunArgs) return _error(settings);
        return _page(
            TestRunScreen(
              patient: args.patient,
              ears: args.ears,
              protocol: args.protocol,
            ),
            settings);

      case resultsRoute:
        if (args is! ResultsArgs) return _error(settings);
        return _page(
          ResultsScreen(
            patient: args.patient,
            session: args.session,
            isFresh: args.isFresh,
          ),
          settings,
        );

      case comparisonRoute:
        if (args is! ComparisonArgs) return _error(settings);
        return _page(
          ComparisonScreen(patient: args.patient, sessions: args.sessions),
          settings,
        );

      case settingsRoute:
        return _page(const SettingsScreen(), settings);

      case usersRoute:
        return _page(const UserManagementScreen(), settings);

      case clinicTeamRoute:
        return _page(const ClinicTeamScreen(), settings);

      case adminConsoleRoute:
        return _page(const AdminConsoleScreen(), settings);

      case profileRoute:
        return _page(const ProfileScreen(), settings);

      case calibrationRoute:
        return _page(const CalibrationWizardScreen(), settings);

      case calibrationHistoryRoute:
        return _page(const CalibrationHistoryScreen(), settings);

      case helpRoute:
        return _page(const HelpScreen(), settings);

      default:
        return _error(settings);
    }
  }

  static MaterialPageRoute<dynamic> _page(Widget child, RouteSettings settings) =>
      MaterialPageRoute(builder: (_) => child, settings: settings);

  static MaterialPageRoute<dynamic> _error(RouteSettings settings) =>
      MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(),
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'No screen for "${settings.name}"'
                '${settings.arguments == null ? '' : ' with the arguments given'}.',
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ),
        settings: settings,
      );
}
