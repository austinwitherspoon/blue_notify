import 'package:blue_notify/logs.dart';
import 'package:blue_notify/notification.dart';
import 'package:blue_notify/notification_page.dart';
import 'package:blue_notify/settings.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'overview_page.dart';
import 'settings_page.dart';
import 'package:provider/provider.dart';
import 'package:firebase_core/firebase_core.dart';
import 'firebase_options.dart';
import 'dart:io';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

const dsn =
    'https://476441eeec8d8ababd12e7e148193d62@sentry.austinwitherspoon.com/2';

void configSentryUser() {
  var blueskyDid = settings.accounts.firstOrNull?.did;
  var blueskyHandle = settings.accounts.firstOrNull?.login;
  String? token = settings.lastToken;
  Sentry.configureScope((scope) {
    scope.setUser(
        SentryUser(id: token, username: blueskyDid, name: blueskyHandle));
  });
}

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  try {
    Logs.info(text: 'Handling a background message');
    await SentryFlutter.init(
      (options) {
        options.dsn = dsn;
        options.tracesSampleRate = 0.3;
        options.profilesSampleRate = 0.1;
        options.sampleRate = 1.0;
        options.experimental.replay.sessionSampleRate = 0.0;
        options.experimental.replay.onErrorSampleRate = 1.0;
      },
    );
    await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform);
    await settings.init();
    try {
    configSentryUser();
    } catch (e) {
      Logs.error(text: 'Failed to configure sentry user: $e');
    }
    var rawMessage = message.toMap();
    Logs.info(text: 'About to catalog notification for $rawMessage');
    await catalogNotification(message);
  } catch (e, stackTrace) {
    Logs.error(
        text: 'Error handling background message: $e', stacktrace: stackTrace);
    await Sentry.captureException(
      e,
      stackTrace: stackTrace,
    );
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  await settings.init();
  await FirebaseMessaging.instance.setAutoInitEnabled(true);
  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

  try {
    configSentryUser();
  } catch (e) {
    Logs.error(text: 'Failed to configure sentry user: $e');
  }
  await SentryFlutter.init(
    (options) {
      options.dsn = dsn;
      options.tracesSampleRate = 0.2;
      options.profilesSampleRate = 0.1;
      options.sampleRate = 1.0;
    },
    appRunner: () => runApp(Application()),
  );
}

class Application extends StatefulWidget {
  @override
  State<StatefulWidget> createState() => _Application();
}

class _Application extends State<Application> with WidgetsBindingObserver {
  Key key = UniqueKey();
  bool closed = false;

  Future<void> setupInteractedMessage() async {
    RemoteMessage? initialMessage =
        await FirebaseMessaging.instance.getInitialMessage();

    if (initialMessage != null) {
      _handleMessage(initialMessage);
    }
    FirebaseMessaging.onMessageOpenedApp.listen(_handleMessage);
  }

  void _handleMessage(RemoteMessage message) async {
    try {
      try {
        configSentryUser();
      } catch (e) {
        Logs.error(text: 'Failed to configure sentry user: $e');
      }
      final rawNotification = message.notification?.toMap();
      Logs.info(text: 'Tapped a message! $rawNotification');
      final notification = messageToNotification(message);
      if (notification == null) {
        Logs.error(text: 'No notification available to tap!');
        Sentry.captureMessage(
            'No notification available to tap! Raw message: $rawNotification',
            level: SentryLevel.error);
        return;
      }
      Logs.info(
          text: 'Triggering tap response for notification: $rawNotification');
      await notification.tap();
    } catch (e, stackTrace) {
      Logs.error(
          text: 'Error handling tapped message: $e', stacktrace: stackTrace);
      await Sentry.captureException(
        'Error handling tapped message: $e',
        stackTrace: stackTrace,
      );
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Run code required to handle interacted messages in an async function
    // as initState() must not be async
    setupInteractedMessage();
    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      Logs.info(text: 'Got a message whilst in the foreground!');
      if (message.notification != null) {
        catalogNotification(message);
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) async {
    if (state == AppLifecycleState.resumed) {
      if (closed) {
        closed = false;
        Logs.info(text: 'App resumed, reloading settings');
        await settings.reload();
        setState(() {
          key = UniqueKey();
        });
      }
    } else if (state == AppLifecycleState.paused) {
      Logs.info(text: 'App paused.');
      closed = true;
    }
  }

  @override
  Widget build(BuildContext context) {
    const flutterBlue = Color.fromARGB(255, 32, 139, 254);

    final lightModeScheme = ColorScheme.light(
      primary: flutterBlue,
      onPrimary: Colors.white,
      secondary: Color.fromARGB(255, 240, 240, 240),
      onSecondary: Colors.black,
      surface: const Color.fromARGB(255, 255, 255, 255),
    );

    final darkModeScheme = ColorScheme.dark(
      primary: flutterBlue,
      onPrimary: Colors.white,
      secondary: Color.fromARGB(255, 30, 41, 54),
      onSecondary: Colors.white,
      surface: const Color.fromARGB(255, 22, 30, 39),
      outlineVariant: Color.fromARGB(255, 30, 41, 54),
    );

    final app = MaterialApp(
      title: 'BlueNotify - Bluesky Notifications',
      key: key,
      theme: ThemeData(
        colorScheme: lightModeScheme,
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: darkModeScheme,
        useMaterial3: true,
      ),
      themeMode: ThemeMode.system,
      home: const Navigation(),
    );

    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (context) => settings),
      ],
      child: app,
    );
  }
}

class Navigation extends StatefulWidget {
  const Navigation({super.key});

  @override
  State<Navigation> createState() => _NavigationState();
}

class _NavigationState extends State<Navigation> {
  int currentPageIndex = 0;

  @override
  Widget build(BuildContext context) {
    bool isIOS = false;
    try {
      if (Platform.isIOS) {
        isIOS = true;
      }
    } catch (e) {}

    return Scaffold(
      bottomNavigationBar: NavigationBar(
        onDestinationSelected: (int index) {
          setState(() {
            currentPageIndex = index;
          });
        },
        indicatorColor: Theme.of(context).colorScheme.secondary,
        selectedIndex: currentPageIndex,
        destinations: <Widget>[
          if (!isIOS && !kIsWeb)
            const NavigationDestination(
              selectedIcon: Icon(Icons.home),
              icon: Icon(Icons.home),
              label: 'Overview',
            ),
          const NavigationDestination(
            icon: Icon(Icons.notification_add),
            label: 'Edit Notifications',
          ),
          const NavigationDestination(
            icon: Icon(Icons.settings),
            label: 'Settings',
          ),
        ],
      ),
      body: <Widget>[
        if (!isIOS && !kIsWeb) OverviewPage(),
        NotificationPage(),
        SettingsPage(),
      ][currentPageIndex],
    );
  }
}
