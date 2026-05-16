import 'package:flutter/material.dart';

import 'app_state_scope.dart';
import 'core/services/armin_app_state.dart';
import 'features/tasks/screens/task_home_screen.dart';
import 'shared/theme/armin_theme.dart';

class ArminApp extends StatefulWidget {
  const ArminApp({required this.state, super.key});

  final ArminAppState state;

  @override
  State<ArminApp> createState() => _ArminAppState();
}

class _ArminAppState extends State<ArminApp> {
  @override
  void initState() {
    super.initState();
    widget.state.load();
  }

  @override
  Widget build(BuildContext context) {
    return AppStateScope(
      state: widget.state,
      child: MaterialApp(
        title: 'Armin',
        debugShowCheckedModeBanner: false,
        theme: ArminTheme.light(),
        home: const TaskHomeScreen(),
      ),
    );
  }
}
