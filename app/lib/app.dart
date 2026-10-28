import 'package:flutter/material.dart';

import 'services.dart';
import 'ui/app_scope.dart';
import 'ui/theme.dart';
import 'utils/route_config.dart';
import 'utils/route_constants.dart';

class AurisApp extends StatelessWidget {
  const AurisApp({super.key, required this.services});

  final AppServices services;

  @override
  Widget build(BuildContext context) {
    return AppScope(
      services: services,
      child: MaterialApp(
        title: 'Auris',
        debugShowCheckedModeBanner: false,
        theme: AurisTheme.light(),
        initialRoute: landingRoute,
        onGenerateRoute: RouteConfig.generateRoute,
      ),
    );
  }
}
