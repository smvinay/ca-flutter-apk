// login_screen.dart
import 'dart:async';
import 'dart:ui';
import 'dart:convert';
import 'package:ca_desk/widgets/AutoScrollingText.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // for input formatter
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'dart:math' as math;
import 'home.dart';
import 'main_shell.dart';

const Color kPrimaryBlue = Color(0xFF4E7BE7);
const Color kAccentPurple = Color(0xFF6B59C9);
const Color kOrange = Color(0xFFF6922D);

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen>
    with SingleTickerProviderStateMixin {
  final _formKey = GlobalKey<FormState>();
  final _emailC = TextEditingController();
  final _passC = TextEditingController();
  final _companyInputC = TextEditingController();

  String? _companyLogo;
  String? _firmName;
  String? _companyCode;
  bool _btnPressed = false;
  bool _obscure = true;
  bool _companyVerified = false;
  bool _checkingCompany = false;

  late final AnimationController _anim;
  late final Animation<double> _titleAnim;
  late final Animation<double> _fieldsAnim;
  late final Animation<double> _buttonAnim;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    _titleAnim = CurvedAnimation(
      parent: _anim,
      curve: const Interval(0.0, 0.35, curve: Curves.easeOut),
    );
    _fieldsAnim = CurvedAnimation(
      parent: _anim,
      curve: const Interval(0.25, 0.7, curve: Curves.easeOut),
    );
    _buttonAnim = CurvedAnimation(
      parent: _anim,
      curve: const Interval(0.6, 1.0, curve: Curves.elasticOut),
    );
    _anim.forward();

    _loadStartupState();
  }

  Future<void> _loadStartupState() async {
    // Load saved company (if any) and check login; keep UI reactive
    try {
      final prefs = await SharedPreferences.getInstance();

      // 1) Check for saved company info (stored under 'code_data' as JSON)
      final String? rawCodeData = prefs.getString('code_data');
      if (rawCodeData != null && rawCodeData.isNotEmpty) {
        try {
          final Map<String, dynamic> codeData = jsonDecode(rawCodeData);
          final String? slug = codeData['slug']?.toString();
          final String? logo = codeData['logo']?.toString();
          final String? firmName = codeData['firmName']?.toString();

          if (slug != null && slug.isNotEmpty) {
            // populate UI with saved company and show the login card (company verified)
            setState(() {
              _companyVerified = true;
              _companyCode = slug;
              _companyLogo = logo;
              _firmName = firmName;
            });
          }
        } catch (e) {
          // ignore parse errors, treat as no saved company
          debugPrint('Failed to parse saved code_data: $e');
        }
      }

      // 2) Then check if user is already logged in; if so immediately navigate to MainShell
      final bool loggedIn = prefs.getBool('is_logged_in') ?? false;
      if (loggedIn) {
        // small delay to allow build to complete — uses postFrameCallback to be safe
        WidgetsBinding.instance.addPostFrameCallback((_) {
          Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const MainShell()));
        });
        return;
      }

      // 3) If not logged in, start the UI animation (so card fades/slide in)
      // call forward after a tiny delay so animation looks smooth after setting state above
      Future.delayed(const Duration(milliseconds: 120), () {
        if (mounted) _anim.forward();
      });
    } catch (e) {
      debugPrint('Startup load failed: $e');
      // still forward animation so UI shows even when prefs fail
      if (mounted) _anim.forward();
    }
  }

  Future<void> _fetchCompany() async {
    String input = _companyInputC.text.trim();
    if (input.isEmpty) return;

    setState(() => _checkingCompany = true);

    try {
      // ✅ Extract company code from URL or raw text
      String? companyCode;
      if (input.startsWith('http')) {
        final uri = Uri.tryParse(input);
        if (uri != null && uri.pathSegments.isNotEmpty) {
          companyCode = uri.pathSegments.first; // e.g. mounika
        }
      } else {
        companyCode = input;
      }

      if (companyCode == null || companyCode.isEmpty) {
        showTopToast(context, 'Invalid ca firm url or code Format', success: false);
        setState(() => _checkingCompany = false);
        return;
      }

      final url = Uri.parse('https://cadesk.ai/get_companyInfo?company_code=$companyCode');
      final resp = await http.get(url).timeout(const Duration(seconds: 10));
      final body = jsonDecode(resp.body);

      if (body['status'] == true) {
        final data = body['data'];
        final prefs = await SharedPreferences.getInstance();

        // ✅ Store company info locally
        final companyData = {
          'slug': data['slug'],
          'logo': data['logo'],
          'domain': data['domain'],
          'firmName': data['firmName'],
        };
        await prefs.setString('code_data', jsonEncode(companyData));

        setState(() {
          _companyVerified = true;
          _companyCode = data['slug'];
          _companyLogo = data['logo'];
          _firmName = data['firmName'];
        });

        showTopToast(context, 'Company verified successfully', success: true);
      } else {
        showTopToast(context, 'Invalid ca firm url or code', success: false);
      }
    } catch (e) {
      showTopToast(context, 'Error validating company', success: false);
    }

    setState(() => _checkingCompany = false);
  }



  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    FocusScope.of(context).unfocus();
    setState(() => _btnPressed = true);

    final uri = Uri.parse('https://cadesk.ai/loginapinew');
    final payload = {
      'company_code': _companyCode,
      'email': _emailC.text.trim(),
      'password': _passC.text,
    };

    try {
      final resp = await http
          .post(uri,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(payload))
          .timeout(const Duration(seconds: 12));

      if (mounted) setState(() => _btnPressed = false);

      final body = resp.body.isNotEmpty ? jsonDecode(resp.body) : null;
      if (resp.statusCode != 200) {
        final msg = (body is Map && body['message'] != null)
            ? body['message'].toString()
            : 'Server error: ${resp.statusCode}';
        showTopToast(context, msg, success: false);
        return;
      }

      if (body is Map<String, dynamic>) {
        final status = (body['status'] == true);
        final msg = (body['message'] ?? '').toString();
        if (!status) {
          showTopToast(context, msg.isNotEmpty ? msg : 'Login failed', success: false);
          return;
        }
        final data = body['data'];
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('user_data', jsonEncode(data));
        await prefs.setBool('is_logged_in', true);
        await prefs.setString('email', _emailC.text.trim());
        showTopToast(context, msg.isNotEmpty ? msg : 'Login successful', success: true);

        await Future.delayed(const Duration(milliseconds: 350));
        if (!mounted) return;
        Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const MainShell()));
        return;
      }

      showTopToast(context, 'Unexpected server response', success: false);
    } catch (e) {
      if (mounted) setState(() => _btnPressed = false);
      showTopToast(context, 'Something went wrong. Try again.', success: false);
    }
  }

  void showTopToast(BuildContext context, String message,
      {bool success = false, Duration duration = const Duration(seconds: 3)}) {
    final overlay = Overlay.of(context);
    if (overlay == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
      return;
    }
    final color = success ? Colors.green.shade600 : Colors.red.shade600;
    final entry = OverlayEntry(
      builder: (ctx) => Positioned(
        top: MediaQuery.of(ctx).padding.top + 8,
        left: 20,
        right: 20,
        child: Material(
          color: Colors.transparent,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(8),
              boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.15), blurRadius: 8)],
            ),
            child: Row(
              children: [
                Icon(success ? Icons.check_circle : Icons.error_outline, color: Colors.white),
                const SizedBox(width: 10),
                Expanded(child: Text(message, style: const TextStyle(color: Colors.white))),
              ],
            ),
          ),
        ),
      ),
    );
    overlay.insert(entry);
    Timer(duration, () => entry.remove());
  }

  final Uri _techkshetraUrl = Uri.parse('https://techkshetrainfo.com/');
  Future<void> _launchTechkshetra() async {
    if (!await launchUrl(_techkshetraUrl, mode: LaunchMode.externalApplication)) {
      throw Exception('Could not launch $_techkshetraUrl');
    }
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final width = mq.size.width;
    final height = mq.size.height;
    final scaleFactor = height >= 820 ? 1.0 : height >= 700 ? 0.9 : height >= 600 ? 0.8 : 0.72;
    final cardWidth = (width * 0.95).clamp(285.0, 530.0);
    final cardHeight = (height * 0.70).clamp(350.0, 700.0);
    final double keyboardInset = mq.viewInsets.bottom;

    return Scaffold(
      body: Stack(
        children: [
          Positioned(top: -60, left: -40, child: _Blob(size: 220, color: kPrimaryBlue.withOpacity(0.15))),
          Positioned(top: -20, right: -10, child: _Blob(size: 120, color: kAccentPurple.withOpacity(0.18))),
          Positioned(bottom: -70, left: -30, child: _Blob(size: 240, color: kPrimaryBlue.withOpacity(0.14))),
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(vertical: 28),
                child: SizedBox(
                  width: cardWidth,
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 500),
                    child: _companyVerified ? _buildLoginCard(scaleFactor, cardWidth, cardHeight) : _buildCompanyEntryCard(scaleFactor, cardWidth),
                  ),
                ),
              ),
            ),
          ),

          if (keyboardInset == 0)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: SafeArea(
                top: false,
                child: Container(
                  color: Colors.white, // ✅ White background
                  padding: EdgeInsets.only(
                    bottom: keyboardInset > 0 ? keyboardInset : 8,
                    left: 12,
                    right: 12,
                    top: 6, // small top padding
                  ),
                  child: Transform.scale(
                    scale: scaleFactor,
                    alignment: Alignment.bottomCenter,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Version 1.0',
                          style: TextStyle(
                            fontSize: (11.0 * scaleFactor).clamp(9.0, 12.0),
                            color: Colors.grey.shade600,
                            fontWeight: FontWeight.w400,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Container(
                          height: (28.0 * scaleFactor).clamp(20.0, 30.0),
                          alignment: Alignment.center,
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              // "Powered by" + company image
                              Text(
                                'Copyright © ',
                                style: GoogleFonts.poppins(
                                  fontSize: (13.0 * scaleFactor).clamp(11.0, 16.0),
                                  color: Colors.grey.shade700,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),

                              // company image
                              Opacity(
                                opacity: 0.95,
                                child: Image.asset(
                                  'assets/images/ca_logo.webp',
                                  width: (cardWidth * 0.18).clamp(60.0, 120.0),
                                  height: (cardHeight * 0.06).clamp(18.0, 48.0) * scaleFactor,
                                  fit: BoxFit.contain,
                                ),
                              ),

                              SizedBox(width: 8 * scaleFactor),

                              // separator and powered by Techkshetra
                              Text(
                                '| Powered by ',
                                style: TextStyle(
                                  color: Colors.grey.shade700,
                                  fontSize: (12.0 * scaleFactor).clamp(10.0, 14.0),
                                  fontWeight: FontWeight.w400,
                                ),
                              ),

                              GestureDetector(
                                onTap: _launchTechkshetra,
                                child: Text(
                                  'Techkshetra',
                                  style: TextStyle(
                                    color: Colors.orange.shade700,
                                    fontSize: (14.0 * scaleFactor).clamp(11.0, 16.0),
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),

                      ],
                    ),
                  ),
                ),
              ),
            )
        ],
      ),
    );
  }

  Widget _buildCompanyEntryCard(double scaleFactor, double cardWidth) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.65),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.white.withOpacity(0.4)),
          ),
          padding: EdgeInsets.all(20 * scaleFactor),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Enter CA Firm URL or Code', style: GoogleFonts.poppins(fontSize: 18, fontWeight: FontWeight.w600)),
              const SizedBox(height: 16),
              TextFormField(
                controller: _companyInputC,
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.business),
                  labelText: 'CA Firm URL or Code',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              // ElevatedButton.icon(
              //   onPressed: _checkingCompany ? null : _fetchCompany,
              //   icon: _checkingCompany ? const CircularProgressIndicator(strokeWidth: 2, color: Colors.white) : const Icon(Icons.check),
              //   label: Text(_checkingCompany ? 'Checking...' : 'Continue'),
              // ),
              SizedBox(
                // width: 110, // ✅ Full width of parent
                width: double.infinity,
                child: Container(
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFFFFA858), Color(0xFFF57C2B)],
                    ),
                    borderRadius: BorderRadius.circular(8),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.orange.withOpacity(0.15),
                        blurRadius: 6,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: ElevatedButton.icon(
                    onPressed: _checkingCompany ? null : _fetchCompany,
                    icon: _checkingCompany
                        ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                        : const Icon(Icons.check, color: Colors.white),
                    label: Text(
                      _checkingCompany ? 'Checking...' : 'Continue',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      elevation: 0,
                      backgroundColor: Colors.transparent,
                      shadowColor: Colors.transparent,
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                ),
              ),


            ],
          ),
        ),
      ),
    );
  }


  Widget _buildLoginCard(double scaleFactor, double cardWidth, double cardHeight) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.65),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.white.withOpacity(0.4)),
          ),
          padding: EdgeInsets.symmetric(horizontal: 20 * scaleFactor, vertical: 22 * scaleFactor),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // ✅ Company logo if available — larger and proportional to card
              if (_companyLogo != null)
                Padding(
                  padding: EdgeInsets.only(bottom: 8.0 * scaleFactor),
                  child: Image.network(
                    _companyLogo!,
                    // Increased size: proportional to card width/height (no min/max clamps)
                    width: cardWidth * 0.5 * scaleFactor,
                    height: cardHeight * 0.18 * scaleFactor,
                    fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) => const SizedBox(),
                  ),
                ),

              // firm name — single row taking the card width (no min/max)
              if (_firmName != null)
                Center(
                  child: Text(
                    _firmName!,
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis, // This handles overflow after 3 lines
                    softWrap: true, // This enables text wrapping (true by default, but explicit is good)
                  ),
                ),


              const SizedBox(height: 6),
              FadeTransition(
                opacity: _titleAnim,
                child: SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(0, 0.12),
                    end: Offset.zero,
                  ).animate(_titleAnim),
                  child: Text(
                    'LOGIN',
                    style: TextStyle(
                        fontSize: 13 * scaleFactor,
                        color: Colors.black54,
                        fontWeight: FontWeight.w600,

                    ),
                  ),
                ),
              ),

              const SizedBox(height: 3),

              // (fields/form + login button unchanged)
              FadeTransition(
                opacity: _fieldsAnim,
                child: SlideTransition(
                  position: Tween<Offset>(begin: const Offset(0, 0.08), end: Offset.zero).animate(_fieldsAnim),
                  child: Form(
                    key: _formKey,
                    child: Column(
                      children: [
                        if(_companyCode == null)
                        const SizedBox(height: 6),
                        if(_companyCode == null)
                        _buildInput(
                          controller: TextEditingController(text: _companyCode),
                          readOnly: true,
                          hint: 'Company Code',
                          icon: Icons.business,
                          keyboardType: TextInputType.text,
                          validator: (_) => null,
                          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9]'))],
                        ),

                        const SizedBox(height: 6),
                        _buildInput(
                          controller: _emailC,
                          hint: 'Email',
                          readOnly: false,
                          icon: Icons.email_outlined,
                          keyboardType: TextInputType.emailAddress,
                          validator: (v) {
                            if (v == null || v.trim().isEmpty) return 'Enter email';
                            if (!RegExp(r'^[^@]+@[^@]+\.[^@]+').hasMatch(v)) return 'Enter valid email';
                            return null;
                          },
                        ),
                        const SizedBox(height: 12),
                        _buildInput(
                          controller: _passC,
                          hint: 'Password',
                          readOnly: false,
                          icon: Icons.lock_outline,
                          obscure: _obscure,
                          suffix: IconButton(
                            icon: Icon(_obscure ? Icons.visibility_off : Icons.visibility),
                            onPressed: () => setState(() => _obscure = !_obscure),
                          ),
                          validator: (v) {
                            if (v == null || v.isEmpty) return 'Enter password';
                            if (v.length < 6) return 'Password must be 6+ chars';
                            return null;
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 6),
              ScaleTransition(
                scale: _buttonAnim,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 250),
                  transform: Matrix4.translationValues(
                    0,
                    _btnPressed ? 4 : 0,
                    0,
                  ),
                  child: ElevatedButton(
                    onPressed: _submit,
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      backgroundColor: Colors.transparent,
                      elevation: 10,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(5),
                      ),
                      shadowColor: Colors.orange.withOpacity(0.10),
                    ),
                    child: Ink(
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [Color(0xFFFFA858), Color(0xFFF57C2B)],
                        ),
                        borderRadius: BorderRadius.circular(8),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.orange.withOpacity(0.12),
                            blurRadius: 4,
                            offset: const Offset(0, 1),
                          ),
                        ],
                      ),
                      child: Container(
                        alignment: Alignment.center,
                        height: 52 * scaleFactor,
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 300),
                          child: _btnPressed
                              ? const SizedBox(
                            key: ValueKey('loader'),
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(
                              color: Colors.white,
                              strokeWidth: 2,
                            ),
                          )
                              : const Text(
                            'LOGIN',
                            key: ValueKey('label'),
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }


  Widget _buildInput({
    required TextEditingController controller,
    required String hint,
    required IconData icon,
    bool obscure = false,
    Widget? suffix,
    TextInputType keyboardType = TextInputType.text,
    String? Function(String?)? validator,
    List<TextInputFormatter>? inputFormatters,
    required bool readOnly,
  }) {
    return TextFormField(
      controller: controller,
      obscureText: obscure,
      readOnly: readOnly,
      keyboardType: keyboardType,
      validator: validator,
      inputFormatters: inputFormatters,
      decoration: InputDecoration(
        hintText: hint,
        filled: true,
        fillColor: Colors.white,
        prefixIcon: Icon(icon, color: Colors.grey.shade700),
        suffixIcon: suffix,
        contentPadding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: Colors.grey.shade200)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: Colors.grey.shade200)),
      ),
    );
  }
}

class _Blob extends StatelessWidget {
  final double size;
  final Color color;
  const _Blob({required this.size, required this.color});
  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size / 2),
        color: color,
      ),
    );
  }
}
