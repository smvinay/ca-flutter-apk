// lib/company_select_page.dart
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;

import 'login_screen.dart';

const Color kPrimaryBlue = Color(0xFF4E7BE7);

class CompanySelectPage extends StatefulWidget {
  const CompanySelectPage({Key? key}) : super(key: key);

  @override
  State<CompanySelectPage> createState() => _CompanySelectPageState();
}

class _CompanySelectPageState extends State<CompanySelectPage>
    with SingleTickerProviderStateMixin {
  final _formKey = GlobalKey<FormState>();
  final TextEditingController _inputController = TextEditingController();

  bool _loading = false;
  String? _errorText;
  Color _bgColor = Colors.white;
  late AnimationController _cardAnimController;
  late Animation<Offset> _cardOffsetAnim;

  @override
  void initState() {
    super.initState();
    _cardAnimController =
        AnimationController(vsync: this, duration: const Duration(milliseconds: 450));
    _cardOffsetAnim = Tween<Offset>(begin: const Offset(0, 0.15), end: Offset.zero)
        .chain(CurveTween(curve: Curves.easeOutCubic))
        .animate(_cardAnimController);

    // small delayed entrance
    Future.delayed(const Duration(milliseconds: 200), () {
      _cardAnimController.forward();
    });
  }

  @override
  void dispose() {
    _inputController.dispose();
    _cardAnimController.dispose();
    super.dispose();
  }

  /// Try to parse a company slug from the input.
  /// If input is a URL -> returns first path segment.
  /// If input looks like just an alphanumeric code -> returns it directly.
  String? _extractCompanySlug(String raw) {
    final s = raw.trim();
    if (s.isEmpty) return null;

    // Try to parse as URI (handles http/https)
    try {
      final uri = Uri.parse(s);
      // If it has a scheme and host, treat as URL
      if (uri.hasScheme && uri.host.isNotEmpty) {
        // get first non-empty path segment
        final segs = uri.pathSegments.where((e) => e.trim().isNotEmpty).toList();
        if (segs.isNotEmpty) {
          return segs[0].toLowerCase();
        } else {
          return null; // URL with no path
        }
      }
    } catch (_) {
      // fallback to treat as plain code
    }

    // If it looks like a domain-only string without scheme (e.g. "cadesk.ai/demo/..")
    if (s.contains('/') || s.contains('.')) {
      // attempt to add scheme and parse
      try {
        final uri = Uri.parse('https://' + s);
        final segs = uri.pathSegments.where((e) => e.trim().isNotEmpty).toList();
        if (segs.isNotEmpty) return segs[0].toLowerCase();
      } catch (_) {}
    }

    // fallback: accept alphanumeric slug/code (letters, numbers, hyphen/underscore)
    final code = s.toLowerCase();
    final valid = RegExp(r'^[a-z0-9\-_]+$');
    if (valid.hasMatch(code)) return code;

    return null;
  }

  /// Call your backend to get company info. Replace the endpoint and
  /// response parsing to match your API contract.
  Future<Map<String, dynamic>> _fetchCompanyInfo(String slug) async {
    // TODO: replace with your real API endpoint
    final String endpoint = 'https://api.yourdomain.com/company/info?slug=$slug';

    final response = await http.get(Uri.parse(endpoint)).timeout(const Duration(seconds: 12));
    if (response.statusCode != 200) {
      throw Exception('Server returned ${response.statusCode}');
    }
    final Map<String, dynamic> body = jsonDecode(response.body);
    // Expected example:
    // { "success": true, "company": {"slug":"mounika","name":"Mounika Co","logo":"/uploads/logo.png"}, "default_user":"demo@..." }
    return body;
  }

  Future<void> _saveCompanyLocally(Map<String, dynamic> companyInfo, String slug) async {
    final prefs = await SharedPreferences.getInstance();
    final cache = Hive.box('cacheBox');

    // Save to SharedPreferences (use keys you prefer)
    await prefs.setString('company_slug', slug);
    if (companyInfo.containsKey('company')) {
      final comp = companyInfo['company'];
      if (comp is Map) {
        if (comp['name'] != null) await prefs.setString('company_name', comp['name'].toString());
        if (comp['logo'] != null) await prefs.setString('company_logo', comp['logo'].toString());
      }
    }

    // Also keep a cached copy in Hive
    cache.put('company_${slug}_meta', companyInfo);
  }

  void _showTemporaryBg(Color color) {
    setState(() => _bgColor = color);
    // animate back to white slowly
    Future.delayed(const Duration(milliseconds: 700), () {
      if (!mounted) return;
      setState(() => _bgColor = Colors.white);
    });
  }

  Future<void> _onSubmitPressed() async {
    setState(() {
      _errorText = null;
    });

    final raw = _inputController.text.trim();
    if (raw.isEmpty) {
      setState(() => _errorText = 'Please enter a URL or company code');
      _showTemporaryBg(Colors.red.withOpacity(0.12));
      return;
    }

    final slug = _extractCompanySlug(raw);
    if (slug == null) {
      setState(() => _errorText = 'Could not extract a valid company code from input.');
      _showTemporaryBg(Colors.red.withOpacity(0.12));
      return;
    }

    // start loading
    setState(() => _loading = true);

    try {
      // attempt fetch - adjust to your API
      final resp = await _fetchCompanyInfo(slug);

      // Basic success handling (adjust depending on your API design)
      final bool success = resp['success'] == true ||
          (resp.containsKey('company') && resp['company'] is Map);

      if (!success) {
        final msg = resp['message']?.toString() ?? 'Company not found';
        setState(() => _errorText = msg);
        _showTemporaryBg(Colors.red.withOpacity(0.12));
        return;
      }

      // save locally
      await _saveCompanyLocally(resp, slug);

      // small success animation
      _showTemporaryBg(Colors.green.withOpacity(0.12));

      // show friendly confirmation
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Company "$slug" found and saved. Redirecting to login...'),
            backgroundColor: kPrimaryBlue,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }

      // small delay to let user see the green flash
      await Future.delayed(const Duration(milliseconds: 700));

      // navigate to login (replace as needed)
      if (!mounted) return;
      await Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const LoginScreen()),
      );
    } on TimeoutException catch (_) {
      setState(() => _errorText = 'Request timed out. Please try again.');
      _showTemporaryBg(Colors.red.withOpacity(0.12));
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('Company info fetch failed: $e');
        debugPrintStack(stackTrace: st);
      }
      setState(() => _errorText = 'Failed to fetch company info. Check code or network.');
      _showTemporaryBg(Colors.red.withOpacity(0.12));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Widget _buildCard(BuildContext context) {
    return SlideTransition(
      position: _cardOffsetAnim,
      child: Material(
        elevation: 8,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 18),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Enter company URL or code',
                style: GoogleFonts.poppins(fontSize: 18, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 10),
              Text(
                'Paste a full URL (https://domain.com/slug/…) or just the company code (e.g. demo)',
                textAlign: TextAlign.center,
                style: GoogleFonts.poppins(fontSize: 13, color: Colors.grey[700]),
              ),
              const SizedBox(height: 16),
              Form(
                key: _formKey,
                child: TextFormField(
                  controller: _inputController,
                  enabled: !_loading,
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.link),
                    hintText: 'https://cadesk.ai/mounika/profile  OR  mounika',
                    labelText: 'Company URL / Code',
                    errorText: _errorText,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    suffixIcon: _loading
                        ? Padding(
                      padding: const EdgeInsets.all(12.0),
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                        : null,
                  ),
                  textInputAction: TextInputAction.done,
                  onFieldSubmitted: (_) {
                    if (!_loading) _onSubmitPressed();
                  },
                ),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton(
                      onPressed: _loading ? null : _onSubmitPressed,
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        backgroundColor: kPrimaryBlue,
                      ),
                      child: Text(
                        _loading ? 'Checking...' : 'Continue',
                        style: GoogleFonts.poppins(fontSize: 15, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (_errorText == null || _errorText!.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8.0),
                  child: Text(
                    'You can change company later from settings.',
                    style: GoogleFonts.poppins(fontSize: 12, color: Colors.grey[600]),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Animated background color for success / error feedback
    return AnimatedContainer(
      duration: const Duration(milliseconds: 420),
      color: _bgColor,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 36),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Header
                  Hero(
                    tag: 'app_logo',
                    child: Material(
                      color: Colors.transparent,
                      child: Column(
                        children: [
                          // simple logo circle
                          Container(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: [kPrimaryBlue.withOpacity(0.95), kPrimaryBlue],
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                              ),
                              borderRadius: BorderRadius.circular(16),
                              boxShadow: [
                                BoxShadow(
                                    color: Colors.black.withOpacity(0.12),
                                    blurRadius: 12,
                                    offset: const Offset(0, 6))
                              ],
                            ),
                            padding: const EdgeInsets.all(14),
                            child: const Icon(
                              Icons.apartment_rounded,
                              color: Colors.white,
                              size: 44,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Text('CA Desk', style: GoogleFonts.poppins(fontSize: 22, fontWeight: FontWeight.w700)),
                          const SizedBox(height: 6),
                          Text('Find your company to continue', style: GoogleFonts.poppins(fontSize: 13, color: Colors.grey[700])),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 26),

                  // Animated card
                  _buildCard(context),

                  const SizedBox(height: 18),

                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
