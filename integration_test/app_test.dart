import 'package:armin/app.dart';
import 'package:armin/core/services/armin_app_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// Armin 模拟器集成回归测试（冷启动与导航冒烟）。
///
/// 运行前必须先用 seed-config.sh 初始化模拟器数据库：
///   DEVICE_ID=emulator-5554 ./scripts/emulator/seed-config.sh
///
/// 运行测试：
///   flutter drive \
///     --driver=test_driver/integration_test.dart \
///     --target=integration_test/app_test.dart \
///     -d emulator-5554
///
/// 覆盖 B09（导航不抢占用户）的模拟器验证。
/// B01-B04、B06、P06 的真实 SSH 自动化门禁见 runtime_gate_test.dart。

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // ── B09: App 冷启动后首页正常渲染 ─────────────────────────────────
  group('Home screen — cold start', () {
    testWidgets('renders Armin header and empty inbox', (tester) async {
      await _pumpApp(tester);

      // 等待 app ready 后 UI 稳定
      await tester.pump(const Duration(seconds: 1));

      // B09: 首页正常渲染，Armin header 可见
      expect(find.text('Armin'), findsOneWidget);

      // 空收件箱状态（无 task）
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('还没有活跃任务'), findsOneWidget);

      // Bottom bar buttons exist
      expect(find.text('新建任务'), findsOneWidget);
      expect(find.byTooltip('添加上下文'), findsOneWidget);
    });

    testWidgets('shows settings button on home screen', (tester) async {
      await _pumpApp(tester);
      await tester.pump(const Duration(seconds: 1));

      // 设置按钮存在
      expect(
        find.byKey(const ValueKey('home-settings-button')),
        findsOneWidget,
      );
    });
  });

  // ── B09: 导航不抢占用户 ──────────────────────────────────────────
  group('Navigation — non-preemptive', () {
    testWidgets('opens settings screen and shows host section',
        (tester) async {
      await _pumpApp(tester);
      await tester.pump(const Duration(seconds: 1));

      // 点击设置按钮
      await tester.tap(find.byKey(const ValueKey('home-settings-button')));
      await tester.pump(const Duration(seconds: 1));

      // 设置页面渲染
      expect(find.text('执行环境'), findsOneWidget);
      expect(find.text('主机连接'), findsOneWidget);
      expect(find.text('项目目录'), findsOneWidget);
      // "语音与播报" appears as both section title and tile title
      expect(find.text('语音与播报'), findsWidgets);
    });

    testWidgets('opens hosts list from settings', (tester) async {
      await _pumpApp(tester);
      await tester.pump(const Duration(seconds: 1));

      await tester.tap(find.byKey(const ValueKey('home-settings-button')));
      await tester.pump(const Duration(seconds: 1));

      // 进入主机连接
      await tester.tap(find.byKey(const ValueKey('settings-hosts')));
      await tester.pump(const Duration(seconds: 1));

      // 验证 seeded host 显示
      expect(find.text('主机连接'), findsOneWidget);
      expect(find.text('添加主机'), findsOneWidget);
      expect(find.text('Local Mac'), findsOneWidget);
      // Host subtitle shows username@host:port only (isThreeLine: false hides password status)
    });

    testWidgets('opens project paths from settings', (tester) async {
      await _pumpApp(tester);
      await tester.pump(const Duration(seconds: 1));

      await tester.tap(find.byKey(const ValueKey('home-settings-button')));
      await tester.pump(const Duration(seconds: 1));

      // 进入项目目录
      await tester.tap(find.byKey(const ValueKey('settings-project-paths')));
      await tester.pump(const Duration(seconds: 1));

      // 验证 seeded projects 显示
      expect(find.text('项目目录'), findsOneWidget);
      expect(find.text('添加目录'), findsOneWidget);
      expect(find.text('countdown_widgets'), findsOneWidget);
      expect(find.text('file-renamer'), findsOneWidget);
      expect(find.text('shotlink'), findsOneWidget);
      expect(find.text('todo-ai'), findsOneWidget);
    });

    testWidgets('can navigate back from settings to home', (tester) async {
      await _pumpApp(tester);
      await tester.pump(const Duration(seconds: 1));

      // 进入设置 → 主机
      await tester.tap(find.byKey(const ValueKey('home-settings-button')));
      await tester.pump(const Duration(seconds: 1));
      await tester.tap(find.byKey(const ValueKey('settings-hosts')));
      await tester.pump(const Duration(seconds: 1));

      // 返回设置
      await tester.tap(find.byIcon(Icons.arrow_back).first);
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('执行环境'), findsOneWidget);

      // 返回首页
      await tester.tap(find.byIcon(Icons.arrow_back).first);
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Armin'), findsOneWidget);
    });
  });

  // ── 任务创建入口可见 ─────────────────────────────────────────────
  group('Task creation entry', () {
    testWidgets('new task button opens draft screen', (tester) async {
      await _pumpApp(tester);
      await tester.pump(const Duration(seconds: 1));

      // 点击新建任务
      await tester.tap(find.text('新建任务'));
      await tester.pump(const Duration(seconds: 1));

      // 草稿页渲染
      expect(find.text('新建任务'), findsOneWidget);
      expect(find.byKey(const ValueKey('host-selector')), findsOneWidget);
      expect(find.byKey(const ValueKey('task-title-field')), findsOneWidget);
    });

    testWidgets('host selector shows seeded host', (tester) async {
      await _pumpApp(tester);
      await tester.pump(const Duration(seconds: 1));

      await tester.tap(find.text('新建任务'));
      await tester.pump(const Duration(seconds: 1));

      // 打开主机选择器
      await tester.tap(find.byKey(const ValueKey('host-selector')));
      await tester.pump(const Duration(seconds: 1));

      // Seeded host 出现在选项中 (dropdown shows "name · user@host:port")
      expect(find.textContaining('Local Mac'), findsWidgets);
    });
  });
}

// ── Helpers ────────────────────────────────────────────────────────

Future<void> _pumpApp(WidgetTester tester) async {
  final state = ArminAppState.run();
  addTearDown(() => state.dispose());

  // ArminApp 内部已包含 MaterialApp，不需要外层再包
  await tester.pumpWidget(ArminApp(state: state));

  // 等待 load() 完成 — ready 变为 true
  // 使用 pump 而非 pumpAndSettle，避免 remoteReconcile timer 导致挂起
  await tester.pump();
  await tester.pump(const Duration(seconds: 2));
  // 再给一个 pump 帧让 UI 刷新
  await tester.pump();
}
