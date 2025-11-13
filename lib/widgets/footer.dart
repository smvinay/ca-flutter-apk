// lib/widgets/footer.dart
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

const Color _primaryPurple = Color(0xFF6B59C9);
const Color _secondaryPurple = Color(0xFF8A7CEE);

class Footer extends StatefulWidget {
  final int selectedIndex;
  final ValueChanged<int> onTap;
  final VoidCallback? onFabPressed;

  const Footer({
    Key? key,
    this.selectedIndex = 1,
    required this.onTap,
    this.onFabPressed,
  }) : super(key: key);

  @override
  _FooterState createState() => _FooterState();
}

class _FooterState extends State<Footer> {
  // stateful fields
  bool _showSR = false;
  String? _userType;
  String? _slug;
  String? _domain;
  String? _serviceType;
  String? _userID;

  @override
  void initState() {
    super.initState();
    _loadUserInfo();
  }

  Future<void> _loadUserInfo() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('user_data');

      if (raw != null) {
        final Map<String, dynamic> user = jsonDecode(raw);
        if (mounted) {
          setState(() {
            _userID = (user['id'] ?? '').toString();
            _userType = (user['type'] ?? '').toString();
            _domain = (user['domain'] ?? '').toString();
            _slug = (user['slug'] ?? '').toString();
            _serviceType = (user['servicesettings'] ?? '').toString();

            // show SR logic: admin always sees, otherwise check serviceType
            _showSR = (_userType == 'admin') ? true : false;
            print((user));
          });
        }
      }
    } catch (e) {
      if (kDebugMode) debugPrint('Failed to load user info: $e');
    }
  }

  Widget _navItem(BuildContext context, IconData icon, int index, String label, double scale) {
    final bool isSelected = widget.selectedIndex == index;
    final double boxSize = 45.0 * scale;
    final double iconPad = isSelected ? 4.0 * scale : 2.0 * scale;
    final double iconSize = 20.0 * scale;

    return InkWell(
      onTap: () => widget.onTap(index),
      borderRadius: BorderRadius.circular(16.0 * scale),
      child: SizedBox(
        width: boxSize * 1.8,
        height: boxSize * 1.6,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              padding: EdgeInsets.all(iconPad),
              decoration: BoxDecoration(
                color: isSelected ? _primaryPurple.withOpacity(0.10) : Colors.transparent,
                shape: BoxShape.circle,
              ),
              child: Icon(
                icon,
                size: iconSize,
                color: isSelected ? _primaryPurple : Colors.grey.shade600,
              ),
            ),
            SizedBox(height: 1.0 * scale),
            Text(
              label,
              textAlign: TextAlign.center,
              overflow: TextOverflow.ellipsis, // prevent wrapping
              maxLines: 1,                     // single line only
              softWrap: false,                 // disable wrapping completely
              style: TextStyle(
                fontSize: 9.5 * scale,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                color: isSelected ? _primaryPurple : Colors.grey.shade600,
              ),
            )


          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final double width = MediaQuery.of(context).size.width;
    final double scale = (width / 390.0).clamp(0.82, 1.18);
    final double containerHeight = 60.0 * scale; // slightly taller for text

    return SizedBox(
      height: containerHeight,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.08),
              blurRadius: 18.0 * scale,
              offset: const Offset(0, -3),
            )
          ],
          borderRadius: BorderRadius.only(
            topLeft: Radius.circular(20.0 * scale),
            topRight: Radius.circular(20.0 * scale),
          ),
        ),
        padding: EdgeInsets.symmetric(vertical: 2.0 * scale, horizontal: 5.0 * scale),
        child: SafeArea(
          top: false,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              if (_showSR) _navItem(context, Icons.receipt, 0, "SR", scale),
              _navItem(context, Icons.home_rounded, 1, "Dashboard", scale),
              _navItem(context, Icons.task, 2, "Task", scale),
            ],
          ),
        ),
      ),
    );
  }
}
