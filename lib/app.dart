import 'dart:async';

import 'package:flutter/material.dart';

import 'app_state_scope.dart';
import 'core/services/armin_app_state.dart';
import 'features/history/screens/task_detail_screen.dart';
import 'features/tasks/screens/task_home_screen.dart';
import 'shared/theme/armin_theme.dart';

class ArminApp extends StatefulWidget {
  const ArminApp({required this.state, super.key});

  final ArminAppState state;

  @override
  State<ArminApp> createState() => _ArminAppState();
}

class _ArminAppState extends State<ArminApp> {
  final _navigatorKey = GlobalKey<NavigatorState>();
  late final _AppLifecycleObserver _lifecycleObserver =
      _AppLifecycleObserver(widget.state);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(_lifecycleObserver);
    widget.state.notificationTaskToOpen.addListener(_openNotificationTask);
    widget.state.load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(_lifecycleObserver);
    widget.state.notificationTaskToOpen.removeListener(_openNotificationTask);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppStateScope(
      state: widget.state,
      child: MaterialApp(
        title: 'Armin',
        navigatorKey: _navigatorKey,
        debugShowCheckedModeBanner: false,
        theme: ArminTheme.light(),
        home: const TaskHomeScreen(),
      ),
    );
  }

  void _openNotificationTask() {
    final taskId = widget.state.notificationTaskToOpen.value;
    if (taskId == null) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || widget.state.notificationTaskToOpen.value != taskId) {
        return;
      }
      final navigator = _navigatorKey.currentState;
      if (navigator == null) {
        return;
      }
      widget.state.consumeNotificationTaskToOpen(taskId);
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => TaskDetailScreen(taskId: taskId),
        ),
      );
    });
  }
}

class _AppLifecycleObserver extends WidgetsBindingObserver {
  _AppLifecycleObserver(this.state);

  final ArminAppState state;

  @override
  void didChangeAppLifecycleState(AppLifecycleState stateChange) {
    if (stateChange == AppLifecycleState.resumed) {
      unawaited(state.resumeRuntime());
      return;
    }
    if (stateChange == AppLifecycleState.inactive ||
        stateChange == AppLifecycleState.paused ||
        stateChange == AppLifecycleState.detached) {
      state.pauseRuntime();
    }
  }
}
