// lib/newDesign/main_shell.dart
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'home.dart';
import 'task_management/TaskList.dart';
import 'service_request/serviceList.dart';
import 'widgets/custom_headerV2.dart';
import 'widgets/footer.dart';
import 'task_management/addTask.dart'; // adjust if different path

class MainShell extends StatefulWidget {
  const MainShell({Key? key}) : super(key: key);

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> with SingleTickerProviderStateMixin {
  final PageController _pageController = PageController(initialPage: 1);
  int _selectedIndex = 1;

  bool _showSR = false;
  String? _userType;
  String? _slug ;
  String? _domain;
  String? _serviceType;
  String? _userID;


  late final AnimationController _fabController;
// declare untyped key
  final GlobalKey<TaskListPageV2State> _taskListKey = GlobalKey<TaskListPageV2State>();

  @override
  void initState() {
    super.initState();
    _fabController = AnimationController(vsync: this, duration: const Duration(milliseconds: 300));
    _fabController.forward();

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _loadUserInfo(); // <-- Load user info first
    });
  }

  @override
  void dispose() {
    _pageController.dispose();
    _fabController.dispose();
    super.dispose();
  }

  void _onFooterTap(int idx) {
    if (_selectedIndex == idx) return;
    setState(() => _selectedIndex = idx);
    _pageController.animateToPage(idx, duration: const Duration(milliseconds: 350), curve: Curves.easeInOut);
  }

  Future<void> _loadUserInfo() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('user_data');

      if (raw != null) {
        final Map<String, dynamic> user = jsonDecode(raw);
        setState(() {
          _userID = (user['id'] ?? '').toString();
          _userType = (user['type'] ?? '').toString();
          _domain = (user['domain'] ?? '').toString();
          _slug = (user['slug'] ?? '').toString();
          _serviceType = (user['servicesettings'] ?? '').toString();

          _showSR =  _userType == 'admin' ? true :  false ;

        });
      }
    } catch (e) {
      if (kDebugMode) debugPrint('Failed to load user info: $e');
    }
  }

  void _navigateToAddTask() {
    _fabController.reverse().then((_) => _fabController.forward());

    Navigator.of(context).push(
      PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) =>
        const Template2AddTask(),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          const begin = Offset(0.0, 1.0);
          const end = Offset.zero;
          const curve = Curves.easeInOutQuart;
          var tween = Tween(begin: begin, end: end).chain(CurveTween(curve: curve));
          final offsetAnimation = animation.drive(tween);
          return SlideTransition(position: offsetAnimation, child: child);
        },
        transitionDuration: const Duration(milliseconds: 600),
      ),
    ).then((result) async {
      // Replay animation
      try {
        _fabController.reset();
        _fabController.forward();
      } catch (_) {}

      if (result != null && result is Map && result['created'] == true) {
        if (_selectedIndex != 2) {
          setState(() => _selectedIndex = 2);
          _pageController.animateToPage(
            2,
            duration: const Duration(milliseconds: 350),
            curve: Curves.easeInOut,
          );
          await Future.delayed(const Duration(milliseconds: 400));
        } else {
          await Future.delayed(const Duration(milliseconds: 150));
        }

        final state = _taskListKey.currentState;
        if (state != null) {
          await state.refresh();
        } else {
          debugPrint(' TaskListPage state not found!');
        }
      }

    });
  }



  // Optional: children can request a page change
  void _requestPage(int idx) {
    _onFooterTap(idx);
  }

  @override
// inside MainShell.build
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // put header here so it is not recreated with each page
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(75),
        child: CustomHeader(
          title: _selectedIndex == 1 ? 'Dashboard' : _selectedIndex == 2 ? 'Task Management' : 'Service Requests',
          currentIndex: _selectedIndex,
          showBack: false,
          onActionPressed: () {
            // open add task screen
            _navigateToAddTask();
          },
          onProfileTap: () {
            // open profile page
          },
          onNotificationsTap: () {
            // open notifications
          },
        ),
      ),


      body: PageView(
        controller: _pageController,
        // when _showSR is false we still keep a placeholder so page indices remain stable
        children: [
          // Index 0: Service list or placeholder
          if (_showSR)
            ServiceListPage(onPageRequested: _requestPage)
          else
            const SizedBox.shrink(),

          // Index 1: Home (center)
          HomePage(onPageRequested: _requestPage),

          // Index 2: Task list
          TaskListPageV2(key: _taskListKey, onPageRequested: _requestPage),
        ],
        // when user changes page, keep index stable and avoid landing on page 0 if service list is hidden
        onPageChanged: (idx) {
          if (!_showSR && idx == 0) {
            // user tried to swipe to the hidden ServiceList page — snap back to Home (1)
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) {
                _pageController.animateToPage(
                  1,
                  duration: const Duration(milliseconds: 250),
                  curve: Curves.easeOut,
                );
              }
            });
            return;
          }
          setState(() => _selectedIndex = idx);
        },
        physics: const BouncingScrollPhysics(),
      ),

      bottomNavigationBar: Footer(
        selectedIndex: _selectedIndex,
        onTap: (idx) {
          setState(() { _selectedIndex = idx; });
          _pageController.animateToPage(idx, duration: const Duration(milliseconds: 350), curve: Curves.easeInOut);
        },
        onFabPressed: _navigateToAddTask,
      ),

    );
  }

}
