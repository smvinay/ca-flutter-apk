import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'login_screen.dart';
import 'main_shell.dart';
import 'package:hive_flutter/hive_flutter.dart';

const Color kPrimaryBlue = Color(0xFF4E7BE7);
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // initialize Hive & open the cache box
  await Hive.initFlutter();
  await Hive.openBox('cacheBox'); // single box for simple cache usage

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});



  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CA Desk',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: Colors.white,
        textTheme: GoogleFonts.poppinsTextTheme(),
        colorScheme: ColorScheme.fromSeed(seedColor: kPrimaryBlue),
      ),
      // show the splash screen first; it will decide where to go
      home: const SplashScreen(),
    );
  }
}

/// determines whether the user is logged in (from SharedPreferences).
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  // Minimum time the splash will be visible.
  final Duration minSplashTime = const Duration(milliseconds: 2000);
  String? _slug ;
  @override
  void initState() {
    super.initState();
    _start();
  }
  Future<void> _start() async {
    final stopwatch = Stopwatch()..start();
    String id = '';
    String type = '';
    String domain = '';

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('user_data');
    if (raw != null) {
      try {
        final Map<String, dynamic> data = jsonDecode(raw);
        _slug = data['slug']?.toString() ?? '';
        id = data['id']?.toString() ?? '';
        type = data['type']?.toString() ?? '';
        domain = data['domain']?.toString() ?? '';
      } catch (e, st) {
        debugPrint('Failed to decode user_data: $e');
        debugPrintStack(stackTrace: st);
      }
    }

    final bool hasRequiredLocalValues = id.trim().isNotEmpty &&
        _slug!.trim().isNotEmpty &&
        type.trim().isNotEmpty &&
        domain.trim().isNotEmpty;

    // Ensure minimum splash time
    final elapsed = stopwatch.elapsed;
    if (elapsed < minSplashTime) {
      await Future.delayed(minSplashTime - elapsed);
    }
    stopwatch.stop();
    if (!mounted) return;


    if (hasRequiredLocalValues) {
      debugPrint('Splash -> MainShell');
      await Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const MainShell()));

    } else {
      debugPrint('Splash -> LoginScreen');
      await Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const LoginScreen()),
      );
    }
  }



  @override
  Widget build(BuildContext context) {
    // Use a plain Scaffold to match native splash background color.
    return const Scaffold(
      backgroundColor: Colors.white,
      body: Center(
        // Make sure this path matches your asset in pubspec.yaml
        child: Image(
          image: AssetImage('assets/icon/full_logo.png'),
          width: 300, // tweak size if needed
          height: 300,
          fit: BoxFit.contain,
        ),
      ),
    );
  }
}
