import 'package:famchat/theme/app_theme.dart';
import 'package:famchat/window/title_bar.dart';
import 'package:famchat/window/window_controls.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

class FakeWindowControls implements WindowControls {
  final calls = <String>[];

  @override
  final ValueNotifier<bool> maximized = ValueNotifier(false);

  @override
  final ValueNotifier<bool> fullScreen = ValueNotifier(false);

  @override
  void startDrag() => calls.add('startDrag');

  @override
  void startResize(ResizeEdge edge) => calls.add('startResize:${edge.name}');

  @override
  void minimize() => calls.add('minimize');

  @override
  void toggleMaximize() => calls.add('toggleMaximize');

  @override
  void close() => calls.add('close');

  @override
  void showMenu() => calls.add('showMenu');
}

Future<FakeWindowControls> pumpFrame(
  WidgetTester tester, {
  WindowChrome? chrome,
  Brightness brightness = Brightness.light,
}) async {
  final controls = FakeWindowControls();
  await tester.pumpWidget(MaterialApp(
    theme: buildTheme(brightness),
    builder: (context, child) => WindowFrame(chrome: chrome, controls: controls, child: child!),
    home: const Scaffold(body: Text('body')),
  ));
  return controls;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('desktop platforms get their own title bar; phones and the web keep the system one', () {
    expect(windowChromeFor(TargetPlatform.windows, web: false), WindowChrome.windows);
    expect(windowChromeFor(TargetPlatform.linux, web: false), WindowChrome.linux);
    expect(windowChromeFor(TargetPlatform.macOS, web: false), WindowChrome.macos);
    expect(windowChromeFor(TargetPlatform.android, web: false), WindowChrome.system);
    expect(windowChromeFor(TargetPlatform.iOS, web: false), WindowChrome.system);
    expect(windowChromeFor(TargetPlatform.fuchsia, web: false), WindowChrome.system);
    for (final p in TargetPlatform.values) {
      expect(windowChromeFor(p, web: true), WindowChrome.system, reason: 'web on $p');
    }
  });

  testWidgets('no title bar on phones', (tester) async {
    await pumpFrame(tester);
    expect(find.byType(AppTitleBar), findsNothing);
    expect(find.text('body'), findsOneWidget);
  }, variant: const TargetPlatformVariant({TargetPlatform.android, TargetPlatform.iOS}));

  testWidgets('a title bar with caption buttons on Windows and Linux', (tester) async {
    final controls = await pumpFrame(tester);
    expect(find.byType(AppTitleBar), findsOneWidget);
    expect(find.text('FamChat'), findsOneWidget);
    // The app sits below the bar.
    expect(tester.getTopLeft(find.text('body')).dy, greaterThanOrEqualTo(tester.getSize(find.byType(AppTitleBar)).height));

    await tester.tap(find.bySemanticsLabel('Minimize'));
    await tester.tap(find.bySemanticsLabel('Maximize'));
    await tester.tap(find.bySemanticsLabel('Close'));
    expect(controls.calls, ['minimize', 'toggleMaximize', 'close']);

    controls.maximized.value = true;
    await tester.pump();
    expect(find.bySemanticsLabel('Maximize'), findsNothing);
    await tester.tap(find.bySemanticsLabel('Restore'));
    expect(controls.calls.last, 'toggleMaximize');
  }, variant: const TargetPlatformVariant({TargetPlatform.windows, TargetPlatform.linux}));

  testWidgets('macOS gets a blank band under the traffic lights', (tester) async {
    final controls = await pumpFrame(tester);
    expect(find.byType(AppTitleBar), findsOneWidget);
    expect(tester.getSize(find.byType(AppTitleBar)).height, AppTitleBar.macosHeight);
    expect(find.bySemanticsLabel('Close'), findsNothing);
    expect(find.text('FamChat'), findsNothing);

    controls.fullScreen.value = true;
    await tester.pump();
    expect(tester.getSize(find.byType(AppTitleBar)).height, 0);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  for (final chrome in [WindowChrome.windows, WindowChrome.linux, WindowChrome.macos]) {
    testWidgets('${chrome.name}: dragging the bar moves the window, a double click maximizes', (tester) async {
      final controls = await pumpFrame(tester, chrome: chrome);
      final bar = find.byType(AppTitleBar);
      // Clear of the buttons and the macOS traffic lights.
      final spot = tester.getTopLeft(bar) + Offset(AppTitleBar.macosLeading + 40, tester.getSize(bar).height / 2);

      final gesture = await tester.startGesture(spot, kind: PointerDeviceKind.mouse);
      await gesture.moveBy(const Offset(30, 10));
      await gesture.up();
      expect(controls.calls, ['startDrag']);

      controls.calls.clear();
      await tester.tapAt(spot);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(spot);
      await tester.pumpAndSettle();
      expect(controls.calls, ['toggleMaximize']);
    });
  }

  testWidgets('Windows: the top edge resizes the window unless it is maximized', (tester) async {
    final controls = await pumpFrame(tester, chrome: WindowChrome.windows);
    final width = tester.getSize(find.byType(AppTitleBar)).width;
    await tester.tapAt(Offset(width / 2, 1), kind: PointerDeviceKind.mouse);
    await tester.tapAt(const Offset(1, 1), kind: PointerDeviceKind.mouse);
    expect(controls.calls, ['startResize:top', 'startResize:topLeft']);

    controls.maximized.value = true;
    await tester.pump();
    controls.calls.clear();
    await tester.tapAt(Offset(width / 2, 1), kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(controls.calls, isNot(contains(startsWith('startResize'))));
  });

  testWidgets('the bar takes the theme surface in light and dark', (tester) async {
    for (final b in Brightness.values) {
      await pumpFrame(tester, chrome: WindowChrome.linux, brightness: b);
      await tester.pumpAndSettle(); // the theme animates between brightnesses
      final material = tester.widget<Material>(
        find.descendant(of: find.byType(AppTitleBar), matching: find.byType(Material)).first,
      );
      expect(material.color, schemeFor(b).surface);
    }
  });

  group('ChannelWindowControls', () {
    const channel = MethodChannel(ChannelWindowControls.channelName);
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('reads the window state and forwards requests', () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return call.method == 'state' ? {'maximized': true, 'fullScreen': false} : null;
      });
      final controls = ChannelWindowControls();
      await pumpEventQueue();
      expect(controls.maximized.value, isTrue);

      controls
        ..startResize(ResizeEdge.topRight)
        ..close();
      await pumpEventQueue();
      expect(calls.map((c) => c.method), ['state', 'startResize', 'quit']);
      expect(calls[1].arguments, 'topRight');
    });

    test('close hides to the tray with Close to tray on, and quits with it off', () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return null;
      });
      final controls = ChannelWindowControls();
      controls
        ..setCloseToTray(true)
        ..close()
        ..setCloseToTray(false)
        ..close();
      await pumpEventQueue();
      expect(calls.map((c) => c.method), ['state', 'setCloseToTray', 'hide', 'setCloseToTray', 'quit']);
      expect(calls[1].arguments, isTrue);
      expect(calls[3].arguments, isFalse);
    });

    test('follows the tray host and the hidden state from the window', () async {
      final controls = ChannelWindowControls();
      await pumpEventQueue();
      expect(controls.trayAvailable.value, isFalse);
      await messenger.handlePlatformMessage(
        ChannelWindowControls.channelName,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('stateChanged', {'trayAvailable': true, 'hidden': true}),
        ),
        (_) {},
      );
      expect(controls.trayAvailable.value, isTrue);
      expect(controls.hidden.value, isTrue);
    });

    test('follows state changes from the window', () async {
      final controls = ChannelWindowControls();
      await pumpEventQueue();
      expect(controls.fullScreen.value, isFalse);
      await messenger.handlePlatformMessage(
        ChannelWindowControls.channelName,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('stateChanged', {'maximized': false, 'fullScreen': true}),
        ),
        (_) {},
      );
      expect(controls.fullScreen.value, isTrue);
    });

    test('does nothing where no runner answers', () async {
      final controls = ChannelWindowControls();
      controls
        ..startDrag()
        ..minimize()
        ..toggleMaximize();
      await pumpEventQueue();
      expect(controls.maximized.value, isFalse);
    });
  });
}
