// custom_header.dart
import 'dart:async';
import 'dart:convert';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'ComingSoonPage.dart';
import '../login_screen.dart';
import '../notificationsPage.dart';
import 'package:hive_flutter/hive_flutter.dart';


const Color _headerStart = Color(0xFF6B59C9);
const Color _headerEnd = Color(0xFF8E55D8);

class CustomHeader extends StatefulWidget implements PreferredSizeWidget {
  final String title;
  final int currentIndex; // 1 = Home, 2 = Tasks, 0 = Services...
  final int unreadCount; // parent can pass current unread
  final bool showSearch;
  final String? profileUrl;
  final String? userName;
  final String? userType;


  // callbacks — parent (MainShell) should handle navigation/actions
  final VoidCallback? onProfileTap;
  final VoidCallback? onNotificationsTap;
  final VoidCallback? onActionPressed; // dynamic action (add task)
  final Future<void> Function(BuildContext context)? onLogout;

  final bool showNotifications;

  CustomHeader({
    Key? key,
    required this.title,
    this.currentIndex = 1,
    this.unreadCount = 0,
    this.showSearch = false,
    this.profileUrl,
    this.userName,
    this.userType,
    this.onProfileTap,
    this.onNotificationsTap,
    this.onActionPressed,
    this.onLogout,
    this.showNotifications = true,
    required bool showBack, // kept for compatibility
  }) : super(key: key);

  @override
  State<CustomHeader> createState() => _CustomHeaderState();

  @override
  Size get preferredSize => const Size.fromHeight(75);
}

class _CustomHeaderState extends State<CustomHeader> with TickerProviderStateMixin {
  String? _profileUrl;
  String? _name;
  String? _userType;
  int _unreadCount = 0;

  String? _slug ;
  String? _domain;
  String? _userID;

  late final AnimationController _entranceController;
  late final Animation<Offset> _nameSlide;
  late final Animation<double> _nameFade;
  late final Animation<double> _avatarScale;
  late final AnimationController _pulseController;

  int _lastTotalCount = 0; // last total value fetched from API
  int _seenCount = 0;      // last seen (stored in prefs)
  static const String _seenCountPrefsKey = 'seen_notifications_count';
  Timer? _pollTimer;       // optional: to poll periodically


  // keep entrance animation only once while widget mounted
  bool _hasEntered = false;

  @override
  void initState() {
    super.initState();

    _entranceController = AnimationController(vsync: this, duration: const Duration(milliseconds: 560));
    _nameSlide = Tween<Offset>(begin: const Offset(0, 0.12), end: Offset.zero)
        .animate(CurvedAnimation(parent: _entranceController, curve: Curves.easeOut));
    _nameFade = CurvedAnimation(parent: _entranceController, curve: Curves.easeIn);
    _avatarScale = Tween<double>(begin: 0.92, end: 1.0).animate(CurvedAnimation(parent: _entranceController, curve: Curves.elasticOut));

    _pulseController = AnimationController(vsync: this, duration: const Duration(milliseconds: 900));
    _pulseController.repeat(reverse: true);

    _loadProfileFromPrefs().whenComplete(() {
      if (!_hasEntered) {
        _entranceController.forward();
        _hasEntered = true;
      }
    });
// initial fetch
    _getNotifyCount();

    // optional: poll every 45 seconds
    _pollTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      _getNotifyCount();
    });

  }


  @override
  void dispose() {
    _entranceController.dispose();
    _pulseController.dispose();

    _pollTimer?.cancel();
    _entranceController.dispose();
    _pulseController.dispose();
    super.dispose();
  }



  Future<void> _loadProfileFromPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('user_data');

      String? nameFromPrefs;
      String? typeFromPrefs;
      String? avatarFromPrefs;
      int unreadFromPrefs = 0;


      if (raw != null) {
        final Map<String, dynamic> data = jsonDecode(raw);
        final possibleNameKeys = ['name', 'userName', 'username', 'full_name', 'fullName', 'first_name'];
        final possibleTypeKeys = ['type', 'user_type', 'role', 'userRole'];
        final possibleAvatarKeys = ['profile', 'avatar', 'profile_url', 'avatar_url', 'picture'];

        _userID = (data['id'] ?? '').toString();
        _domain = (data['domain'] ?? '').toString();
        _slug = (data['slug'] ?? '').toString();

        for (final k in possibleNameKeys) {
          if (data.containsKey(k) && (data[k] != null) && data[k].toString().trim().isNotEmpty) {
            nameFromPrefs = data[k].toString();
            break;
          }
        }
        for (final k in possibleTypeKeys) {
          if (data.containsKey(k) && (data[k] != null) && data[k].toString().trim().isNotEmpty) {
            typeFromPrefs = data[k].toString();
            break;
          }
        }
        for (final k in possibleAvatarKeys) {
          if (data.containsKey(k) && (data[k] != null) && data[k].toString().trim().isNotEmpty) {
            avatarFromPrefs = data[k].toString();
            break;
          }
        }

        // after you read other prefs...
        if (prefs.containsKey(_seenCountPrefsKey)) {
          _seenCount = prefs.getInt(_seenCountPrefsKey) ?? 0;
        }

      }

      if (!mounted) return;
      setState(() {
        _profileUrl = (widget.profileUrl != null && widget.profileUrl!.isNotEmpty) ? widget.profileUrl : avatarFromPrefs;
        _name = (widget.userName != null && widget.userName!.isNotEmpty) ? widget.userName : (nameFromPrefs ?? 'User');
        _userType = (widget.userType != null && widget.userType!.isNotEmpty) ? widget.userType : (typeFromPrefs ?? 'Member');
        // prefer prop, fallback to prefs
        // _unreadCount = widget.unreadCount != 0 ? widget.unreadCount : unreadFromPrefs;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _profileUrl = widget.profileUrl;
        _name = widget.userName ?? '- - -';
        _userType = widget.userType ?? '- - -';
        // keep unread as provided
        // _unreadCount = widget.unreadCount;
      });
    }
  }

  String _initials(String? name) {
    if (name == null || name.trim().isEmpty) return 'U';
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.length == 1) return parts[0][0].toUpperCase();
    return (parts[0][0] + parts[1][0]).toUpperCase();
  }


  Future<void> _getNotifyCount() async {
    try {
      // build URI - adapt _domain/_slug/_userID variables usage to your actual state variables
      // Example: final uri = Uri.parse('$_domain$_slug/getNotifyCount?id=$_userID&type=$_userType&slug=$_slug');
      final uri = Uri.parse('$_domain$_slug/getNotifyCount?id=$_userID&type=$_userType&slug=$_slug');

      final resp = await http.get(uri).timeout(const Duration(seconds: 8));
      if (resp.statusCode != 200) {
        debugPrint('Notify API error: ${resp.statusCode}');
        return;
      }

      final body = jsonDecode(resp.body);
      // expect structure: { status: 'success', counts: { total: 105, elog:..., ticket:... } }
      final counts = body['counts'] ?? body;
      final total = (counts['total'] ?? counts['totalCount'] ?? 0);
      final int totalInt = (total is String) ? int.tryParse(total) ?? 0 : (total as int? ?? 0);
      if (!mounted) return;
      setState(() {
        _lastTotalCount = totalInt;
        // compute badge: number of new items since last seen
        final int newCount = (_lastTotalCount - _seenCount) > 0 ? (_lastTotalCount - _seenCount) : 0;
        _unreadCount = newCount;
      });
    } catch (e, st) {
      debugPrint('Error fetching notify count: $e\n$st');
    }
  }

  Future<void> _markNotificationsSeen() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // set seen to last fetched total (fall back to current _unreadCount if unknown)
      final toStore = _lastTotalCount >= 0 ? _lastTotalCount : (_seenCount + _unreadCount);
      await prefs.setInt(_seenCountPrefsKey, toStore);
      _seenCount = toStore;
      if (!mounted) return;
      setState(() {
        _unreadCount = 0;
      });
    } catch (e) {
      debugPrint('Error storing seen count: $e');
    }
  }

  Future<void> _openNotificationsPage() async {
    // ensure we have latest count first
    await _getNotifyCount();

    // open notifications page and wait until it's popped
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const NotificationsPage()));

    // mark seen after returning
    await _markNotificationsSeen();
  }


// ...
  Future<void> _performLogout(BuildContext context) async {
    // Constants (place them near the top of your class/file)
    const String _cacheBoxName = 'cacheBox';
     const String _cacheKeyServices = 'cache_service_list';
     const String _cacheKeyServicesTs = 'cache_service_list_ts';
     const String _cacheKeyTasks = 'cache_task_list';
     const String _cacheKeyTasksTs = 'cache_task_list_ts';

    try {
      // If a custom logout callback is provided, use it
      if (widget.onLogout != null) {
        await widget.onLogout!(context);
        return;
      }

      // 1️⃣ SharedPreferences - preserve 'code_data'
      final prefs = await SharedPreferences.getInstance();
      final savedCompanyData = prefs.getString('code_data');

      // Clear everything from SharedPreferences
      await prefs.clear();

      // Restore preserved values
      if (savedCompanyData != null && savedCompanyData.isNotEmpty) {
        await prefs.setString('code_data', savedCompanyData);
      }

      // 2️⃣ Hive: clear keys inside the main cache box and certain other boxes
      try {
        // Ensure the main cache box is open
        final cacheBox = Hive.isBoxOpen(_cacheBoxName)
            ? Hive.box(_cacheBoxName)
            : await Hive.openBox(_cacheBoxName);

        final keysToDeleteInCacheBox = [
          _cacheKeyTasks,
          _cacheKeyTasksTs,
          _cacheKeyServices,
          _cacheKeyServicesTs,
          'cache_userstats',
          'offline_data',
          // add any additional keys stored inside cacheBox here
        ];

        for (final key in keysToDeleteInCacheBox) {
          try {
            if (cacheBox.containsKey(key)) {
              await cacheBox.delete(key);
            }
          } catch (e) {
            debugPrint('Error deleting key $key from $_cacheBoxName: $e');
          }
        }

        // Optionally clear other named boxes (if they are actual Hive boxes)
        // If you don't use separate boxes, you can remove/empty this list.
        final boxesToClear = <String>[
          'user_settings', // if this is a separate box in your app
          // add other actual box names here (not keys)
        ];

        for (final name in boxesToClear) {
          try {
            if (Hive.isBoxOpen(name)) {
              await Hive.box(name).clear();
            } else {
              // Try opening, clearing, and closing
              final box = await Hive.openBox(name);
              await box.clear();
              await box.close();
            }
          } catch (e) {
            debugPrint('Error clearing Hive box $name: $e');
          }
        }
      } catch (e) {
        debugPrint('Hive clear-all error: $e');
      }

      // 3️⃣ Navigate back to LoginScreen (if still mounted)
      if (!context.mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const LoginScreen()),
            (route) => false,
      );
    } catch (e, st) {
      debugPrint("Error during logout: $e\n$st");
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Failed to logout. Please try again.")),
        );
      }
    }
  }




  Future<void> _showProfileSheet() async {
    final sheetCtx = context;
    await showModalBottomSheet(
      context: context,
      isScrollControlled: false,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withOpacity(0.36),
      builder: (ctx) {
        return TweenAnimationBuilder<double>(
          tween: Tween(begin: 0.92, end: 1.0),
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOut,
          builder: (context, value, child) {
            return Transform.scale(scale: value, child: child);
          },
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
            decoration: BoxDecoration(
              color: Theme.of(ctx).cardColor,
              borderRadius: BorderRadius.circular(12),
              boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.14), blurRadius: 18)],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(4))),
                const SizedBox(height: 10),
                Row(
                  children: [
                    CircleAvatar(
                      radius: 30,
                      backgroundColor: Colors.grey.shade200,
                      backgroundImage: (_profileUrl != null && _profileUrl!.isNotEmpty) ? NetworkImage(_profileUrl!) : null,
                      child: (_profileUrl == null || _profileUrl!.isEmpty) ? Text(_initials(_name), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)) : null,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(_name ?? 'User', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                        const SizedBox(height: 4),
                        // Text(_userType ?? 'Member', style: TextStyle(color: Colors.grey[700])),
                        Text(
                          _userType != null && _userType!.isNotEmpty
                              ? '${_userType![0].toUpperCase()}${_userType!.substring(1).toLowerCase()}'
                              : 'Member',
                          style: TextStyle(color: Colors.grey[700]),
                        )

                      ]),
                    ),
                    // IconButton(
                    //   icon: const Icon(Icons.edit, size: 20),
                    //   onPressed: () {
                    //     Navigator.of(ctx).pop();
                    //     Navigator.push(
                    //       ctx,
                    //       MaterialPageRoute(
                    //         builder: (_) => const ComingSoonPage(title: 'Edit profile'),
                    //       ),
                    //     );
                    //   },
                    // ),
                  ],
                ),
                const SizedBox(height: 13),
                Row(
                  children: [
                    // Expanded(
                    //   child: OutlinedButton.icon(
                    //     icon: const Icon(Icons.person_outline),
                    //     label: FittedBox(
                    //       fit: BoxFit.scaleDown,
                    //       child: const Text(
                    //         'View profile',
                    //         maxLines: 1,
                    //       ),
                    //     ),
                    //     style: OutlinedButton.styleFrom(
                    //       shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                    //       padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                    //       minimumSize: const Size.fromHeight(44),
                    //     ),
                    //     onPressed: () { /* ... */ },
                    //   ),
                    // ),
                    // const SizedBox(width: 10),
                    Expanded(
                      child: ElevatedButton.icon(
                        icon: const Icon(Icons.logout),
                        label: const Text('Logout'),
                        style: ElevatedButton.styleFrom(
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(6), // smaller radius
                          ),
                        ),
                        onPressed: () async {
                          Navigator.of(ctx).pop();
                          final confirm = await showDialog<bool>(
                            context: sheetCtx,
                            builder: (context) => AlertDialog(
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                              title: const Text("Logout"),
                              content: const Text("Are you sure you want to log out?"),
                              actions: [
                                TextButton(onPressed: () => Navigator.pop(context, false), child: const Text("Cancel")),
                                ElevatedButton(
                                  style: ElevatedButton.styleFrom(
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(5), // smaller radius
                                    ),
                                  ),
                                  onPressed: () => Navigator.pop(context, true),
                                  child: const Text("Logout"),
                                ),

                              ],
                            ),
                          );
                          if (confirm == true) {
                            await _performLogout(sheetCtx);
                          }
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),

              ],
            ),
          ),
        );
      },
    );
  }

  double _calcScaleFromWidth(BuildContext context) {
    const double base = 420.0;
    final double w = MediaQuery.of(context).size.width;
    final double raw = w / base;
    return raw.clamp(0.64, 1.0);
  }


  @override
  Widget build(BuildContext context) {
    final double scale = _calcScaleFromWidth(context);

    // --- reduced sizes for a shorter header
    final double headerHeight = 80 ;     // explicit header height (reduce this to make it shorter)
    final double outerRadius = 20 * scale;     // smaller avatar
    final double innerRadius = 18 * scale;
    final double avatarSpacing = 10 * scale;
    final double sidePadding = 6 * scale;
    final double verticalPadding = 4 * scale; // small vertical padding
    final double iconSize = 18 * scale;
    final double headerFontSize = 13 * scale;
    final double nameFontSize = 13 * scale;
    final double buttonIconSize = 20 * scale;
    final double smallGap = 6 * scale;

    return Container(
      height: headerHeight, // lock the header height
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [_headerStart, _headerEnd],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        // reduce shadow so it looks flatter (optional)
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 6 * scale, offset: Offset(0, 2 * scale))],
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          // smaller vertical padding keeps content tighter
          padding: EdgeInsets.fromLTRB(sidePadding, verticalPadding, sidePadding, verticalPadding),
          child: Row(
            children: [
              ScaleTransition(
                scale: _avatarScale,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () async {
                    await _showProfileSheet();
                    widget.onProfileTap?.call();
                  },
                  child: CircleAvatar(
                    radius: outerRadius,
                    backgroundColor: Colors.white,
                    child: CircleAvatar(
                      radius: innerRadius,
                      backgroundColor: Colors.grey.shade200,
                      backgroundImage: (_profileUrl != null && _profileUrl!.isNotEmpty) ? NetworkImage(_profileUrl!) : null,
                      child: (_profileUrl == null || _profileUrl!.isEmpty)
                          ? Text(_initials(_name),
                          style: TextStyle(fontWeight: FontWeight.bold, color: Colors.black87, fontSize: (innerRadius * 0.6).clamp(12.0, 16.0)))
                          : null,
                    ),
                  ),
                ),
              ),

              SizedBox(width: avatarSpacing),

              // name area — keep it compact
              Expanded(
                child: SlideTransition(
                  position: _nameSlide,
                  child: FadeTransition(
                    opacity: _nameFade,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center, // centers vertically in reduced height
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _name ?? 'User',
                          style: TextStyle(color: Colors.white, fontSize: nameFontSize, fontWeight: FontWeight.w600),
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                        ),
                      ],
                    ),
                  ),
                ),
              ),

              SizedBox(width: smallGap),

              // actions
              Row(mainAxisSize: MainAxisSize.min, children: [
                Padding(
                  padding: EdgeInsets.only(left: 2 * scale),
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8 * scale),
                        child: BackdropFilter(
                          // optional: keep a very subtle blur or remove it if you want completely flat
                          filter: ImageFilter.blur(sigmaX: 6 * scale, sigmaY: 6 * scale),
                          child: ElevatedButton(
                            onPressed: () {
                              if (widget.currentIndex == 2) {
                                widget.onActionPressed?.call();
                              } else {
                                _openNotificationsPage();
                                widget.onNotificationsTap?.call();
                              }
                            },
                            style: ElevatedButton.styleFrom(
                              elevation: 0,
                              backgroundColor: Colors.white.withOpacity(0.18),
                              foregroundColor: Colors.white,
                              padding: EdgeInsets.all(6 * scale), // smaller padding for compact button
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8 * scale),
                                side: BorderSide(color: Colors.white.withOpacity(0.14)),
                              ),
                            ),
                            child: widget.currentIndex == 2
                                ? Row(
                              mainAxisSize: MainAxisSize.min,
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.add, size: buttonIconSize, color: Colors.white),
                                const SizedBox(width: 4),
                                const Text('Add', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                              ],
                            )
                                : Icon(Icons.notifications, size: buttonIconSize, color: Colors.white),
                          ),
                        ),
                      ),

                      if (_unreadCount > 0 && widget.currentIndex != 2)
                        Positioned(
                          right: (2 * scale),
                          top: (-4 * scale),
                          child: ScaleTransition(
                            scale: Tween(begin: 0.95, end: 1.08).animate(
                              CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
                            ),
                            child: Container(
                              width: 18 * scale,
                              height: 18 * scale,
                              decoration: BoxDecoration(
                                color: Colors.redAccent,
                                shape: BoxShape.circle,
                                border: Border.all(color: Colors.white, width: 0.8 * scale),
                              ),
                              alignment: Alignment.center,
                              padding: EdgeInsets.symmetric(horizontal: (1.2 * scale).clamp(1.0, 2.0)),
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text(
                                  _unreadCount > 99 ? '99+' : '$_unreadCount',
                                  textAlign: TextAlign.center,
                                  softWrap: false,
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: (9 * scale).clamp(8.0, 11.0),
                                    fontWeight: FontWeight.w700,
                                    height: 1.0,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ]),
            ],
          ),
        ),
      ),
    );
  }




}
