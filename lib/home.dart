// home.dart
import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:math' as math;
import 'dart:ui';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'task_management/TaskList.dart';
import 'service_request/serviceList.dart';

const Color _primaryPurple = Color(0xFF6B59C9);

class HomePage extends StatefulWidget {
  final void Function(int page)? onPageRequested;
  const HomePage({Key? key, this.onPageRequested}) : super(key: key);
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with TickerProviderStateMixin {
  bool _loading = true;
  String? _error;
  final Dio _dio = Dio();
  Map<String, int> _summary = {};

  String _userType = 'admin';
  String? _slug ;
  String? _domain;
  String? _serviceType;
  bool _showSR = false;
  String? _userID;

  // cache keys
  static const String _kServicesCacheKey = 'home_services_cache';
  static const String _kServicesCacheTimeKey = 'home_services_cache_time';
  static const String _kUserStatsCacheKey = 'home_userstats_cache';
  static const String _kUserStatsCacheTimeKey = 'home_userstats_cache_time';

// last-updated state
  DateTime? _servicesLastUpdated;
  DateTime? _userStatsLastUpdated;

// add alongside your other static const cache keys and DateTime fields
  static const String _kDashboardCacheKey = 'home_dashboard_cache';
  static const String _kDashboardCacheTimeKey = 'home_dashboard_cache_time';
  DateTime? _dashboardLastUpdated;

  // categories
  List<Map<String, dynamic>> _categories = [];

  // totals parsed from body['services']
  int _totalServices = 0;
  int _exemptedCount = 0;
  int _chargeableCount = 0;
  int _invoicesCount = 0;

  // todays/services list
  List<Map<String, dynamic>> _services = [];

  // entrance animation
  late final AnimationController _entranceController;
  late final Animation<Offset> _serviceSlide;
  late final Animation<double> _serviceFade;
  late final Animation<Offset> _progressSlide;
  late final Animation<double> _progressFade;

  // user stats (chart)
  List<Map<String, dynamic>> _userStats = [];
  bool _loadingUserStats = true;
  late final AnimationController _chartController;


  @override
  void initState() {
    super.initState();
    _entranceController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 100),
    );
    _progressSlide = Tween<Offset>(begin: const Offset(0, 0.10), end: Offset.zero)
        .animate(CurvedAnimation(parent: _entranceController, curve: const Interval(0.0, 0.45, curve: Curves.easeOut)));
    _progressFade = CurvedAnimation(parent: _entranceController, curve: const Interval(0.0, 0.45, curve: Curves.easeIn));

    _serviceSlide = Tween<Offset>(begin: const Offset(0, 0.12), end: Offset.zero)
        .animate(CurvedAnimation(parent: _entranceController, curve: const Interval(0.25, 0.70, curve: Curves.easeOut)));
    _serviceFade = CurvedAnimation(parent: _entranceController, curve: const Interval(0.25, 0.70, curve: Curves.easeIn));

    _chartController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _loadUserInfo(); // <-- Load user info first
      await _initLoad();     // <-- Then continue with the rest
    });

  }

  Future<void> _initLoad() async {
    // Single entry point to load caches & trigger fetches deterministically
    try {
      // Load caches (these set state and apply cached UI if available)
      final needFetchServices = await _loadCachedServices();        // returns true if cache missing/stale
      final needFetchDashboard = await _loadCachedDashboard();      // returns true if cache missing/stale
      final needFetchUserStats = await _loadCachedUserStats();      // returns true if cache missing/stale
      // Trigger background fetches (do not block animation)
      if (needFetchServices) _fetchServices(showLoading: false); // showLoading false to avoid full-screen loader
      if (needFetchDashboard) _fetchDashboard(showLoading: false);
      if (needFetchUserStats) _fetchUserStats();

      // Small delay to let setState settle and layout complete
      await Future.delayed(const Duration(milliseconds: 40));

      // Start entrance animation once first frame and data applied
      if (mounted) {
        try {
          await _entranceController.forward();
        } catch (_) {}
      }

      // Ensure chart animates if userStats already available, otherwise _fetchUserStats will animate when done
      if (!mounted) return;
      if (!_loadingUserStats && _userStats.isNotEmpty) {
        try {
          _chartController.reset();
          await _chartController.forward();
        } catch (_) {}
      }

      // Optionally show a modal/coach overlay here after entrance completes.
      // e.g. if (_shouldShowCoach) _showCoachModal(); // call inside a post frame to be safe
    } catch (e, st) {
      if (kDebugMode) debugPrint('initLoad error: $e\n$st');
      // still try to run entrance so UI appears
      if (mounted) {
        try {
          _entranceController.forward().catchError((_) {});
        } catch (_) {}
      }
    }
  }

  Future<void> _loadUserInfo() async {

    // final prefs = await SharedPreferences.getInstance();
    // print('Stored keys: ${prefs.getKeys()}');
    // prefs.getKeys().forEach((k) {
    //   print('$k => ${prefs.get(k)?.toString().length ?? 0} chars');
    // });

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

          // _showSR =  _userType == 'admin' ? true : _serviceType != '1' ? true : false ;
          _showSR = (_userType == 'admin') ? true : (_serviceType != '1' && _serviceType != '2') ? true : false ;


        });
      }
    } catch (e) {
      if (kDebugMode) debugPrint('Failed to load user info: $e');
    }
  }



// 3) dispose — stop and dispose controllers
  @override
  void dispose() {
    // stop controllers to avoid any running tickers during dispose
    try { _entranceController.stop(); } catch (_) {}
    try { _chartController.stop(); } catch (_) {}

    _entranceController.dispose();
    _chartController.dispose();

    _dio.close();
    super.dispose();
  }

  String _formatUpdated(DateTime? dt) {
    if (dt == null) return '';
    final h = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final m = dt.minute.toString().padLeft(2, '0');
    final ampm = dt.hour >= 12 ? 'PM' : 'AM';
    final dateStr = '${dt.day}/${dt.month}/${dt.year}';
    return 'Updated: $h:$m $ampm • $dateStr';
  }


  /// Loads cached dashboard summary; returns true if we should fetch fresh data.
  Future<bool> _loadCachedDashboard() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kDashboardCacheKey);
      final ts = prefs.getInt(_kDashboardCacheTimeKey);
      if (ts != null) _dashboardLastUpdated = DateTime.fromMillisecondsSinceEpoch(ts);

      if (raw == null) return true; // no cache -> fetch

      final Map<String, dynamic> payload = jsonDecode(raw) as Map<String, dynamic>;
      // Extract 'summary' exactly like _fetchDashboard does
      final rawSummary = (payload['summary'] is Map) ? Map<String, dynamic>.from(payload['summary']) : <String, dynamic>{};
      final Map<String, int> parsedSummary = {};
      rawSummary.forEach((k, v) {
        final key = k.trim();
        final valStr = (v ?? '').toString().trim();
        final val = int.tryParse(valStr) ?? 0;
        parsedSummary[key] = val;
      });

      if (!mounted) return true;
      setState(() {
        _summary = parsedSummary;
      });

      final bool stale = _dashboardLastUpdated == null
          ? true
          : DateTime.now().difference(_dashboardLastUpdated!).inMinutes > 10;
      return stale;
    } catch (e) {
      if (kDebugMode) print('Failed to load dashboard cache: $e');
      return true;
    }
  }

  Future<void> _saveDashboardCache(Map<String, dynamic> payload) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kDashboardCacheKey, jsonEncode(payload));
      await prefs.setInt(_kDashboardCacheTimeKey, DateTime.now().millisecondsSinceEpoch);
      _dashboardLastUpdated = DateTime.now();
    } catch (e) {
      if (kDebugMode) print('Failed to save dashboard cache: $e');
    }
  }

  Future<void> _updateServiceType(String newServiceType) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('user_data');

      if (raw != null) {
        final Map<String, dynamic> user = jsonDecode(raw);
        user['servicesettings'] = newServiceType; // ✅ update only this key
        await prefs.setString('user_data', jsonEncode(user));

        setState(() {
          _serviceType = newServiceType;
          // _showSR = (_userType == 'admin') ? true : (_serviceType != '1' && _serviceType != null);
          _showSR = (_userType == 'admin') ? true : (_serviceType != '1' && _serviceType != '2') ? true : false ;

        });

        if (kDebugMode) debugPrint('✅ Service type updated in local storage: $newServiceType');
      }
    } catch (e) {
      if (kDebugMode) debugPrint('❌ Failed to update service type: $e');
    }
  }



  Future<Uri> _buildUserStatsUri() async {
    final prefs = await SharedPreferences.getInstance();
    String slug = '';
    String domain = '';
    String id = '';
    String type = '';
    final raw = prefs.getString('user_data');
    if (raw != null) {
      try {
        final Map<String, dynamic> u = jsonDecode(raw);
        slug = (u['slug'] ?? '').toString();
        domain = (u['domain'] ?? '').toString();
        id = (u['id'] ?? '').toString();
        type = (u['type'] ?? '').toString();
        _userType = type;
        _userID = id;
      } catch (_) {}
    }
    if (slug.isEmpty) slug = prefs.getString('slug') ?? '';
    return Uri.parse('$domain$slug/dashboardApi?id=$id&type=$type&slug=$slug');
  }

  // 4) _fetchUserStats — safe forward() usage
  Future<void> _fetchUserStats() async {

    if (!mounted) return;
    setState(() {
      _loadingUserStats = true;
    });

    try {
      final uri = await _buildUserStatsUri();

      final resp = await _dio.getUri(uri).timeout(const Duration(seconds: 12));
      if (resp.statusCode != 200) throw Exception('Server returned ${resp.statusCode}');

      final data = resp.data;
      // Save to cache for fast next-load
      try {
        await _saveUserStatsCache(data);
      } catch (_) {}

      List<dynamic> users = [];
      if (data is Map &&
          data.containsKey('data') &&
          data['data'] is Map &&
          data['data']['usersWithTicketStats'] is List) {
        users = List<dynamic>.from(data['data']['usersWithTicketStats']);
      } else if (data is Map && data['usersWithTicketStats'] is List) {
        users = List<dynamic>.from(data['usersWithTicketStats']);
      }


      _serviceType = data['data']['servicesettings'];

      await _updateServiceType(_serviceType!);
      final parsed = users.map<Map<String, dynamic>>((u) {
        final Map uu = (u is Map) ? u : {};

        final newCount = int.tryParse(
            (uu['total_new'] ?? uu['service_new'] ?? uu['task_new'] ?? '0').toString()) ??
            0;

        final pendingCount = int.tryParse(
            (uu['total_accepted'] ?? uu['service_accepted'] ?? uu['task_accepted'] ?? '0').toString()) ??
            0;
        final inProgressCount = int.tryParse(
            (uu['total_in_progress'] ?? uu['service_in_progress'] ?? uu['task_in_progress'] ?? '0').toString()) ??
            0;
        final extendedCount = int.tryParse(
            (uu['total_extended'] ?? uu['service_extended'] ?? uu['task_extended'] ?? '0').toString()) ??
            0;
        final completedCount = int.tryParse(
            (uu['total_completed'] ?? uu['service_completed'] ?? uu['task_completed'] ?? '0').toString()) ??
            0;

        final total = newCount + pendingCount + inProgressCount + extendedCount + completedCount;

        return {
          'account_id': (uu['account_id'] ?? '').toString(),
          'name': (uu['name'] ?? '').toString(),
          'total': total,
          'new': newCount,
          'pending': pendingCount,
          'in_progress': inProgressCount,
          'extended': extendedCount,
          'completed': completedCount,
        };
      }).toList();

      if (!mounted) return;
      setState(() {
        _userStats = parsed;
        _loadingUserStats = false;
      });

      // Play chart animation safely:
      if (!mounted) return;
      _chartController.reset();
      try {
        // wrap await forward in try/catch because forward can throw if controller disposed mid-flight
        await _chartController.forward();
      } catch (err) {
        // ignore safely; this happens on hot reload/navigation sometimes
        if (kDebugMode) print('chart animation skipped: $err');
      }
    } on TimeoutException {
      if (!mounted) return;
      setState(() => _loadingUserStats = false);
      _showErrorToast('User stats request timed out.');
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingUserStats = false);
      _showErrorToast('Failed to load user stats.');
    }
  }
  /// Loads cached services; returns true if we should fetch fresh data (cache absent or stale).
  Future<bool> _loadCachedServices() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kServicesCacheKey);
      final ts = prefs.getInt(_kServicesCacheTimeKey);
      if (ts != null) _servicesLastUpdated = DateTime.fromMillisecondsSinceEpoch(ts);

      if (raw == null) return true; // no cache -> need fetch

      final Map<String, dynamic> body = jsonDecode(raw) as Map<String, dynamic>;
      _parseAndSetServices(body, fromCache: true);

      // stale if older than 30 minutes
      final bool stale = _servicesLastUpdated == null
          ? true
          : DateTime.now().difference(_servicesLastUpdated!).inMinutes > 10;
      return stale;
    } catch (e) {
      if (kDebugMode) print('Failed to load services cache: $e');
      return true;
    }
  }

  Future<void> _saveServicesCache(String rawJson) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kServicesCacheKey, rawJson);
      await prefs.setInt(_kServicesCacheTimeKey, DateTime.now().millisecondsSinceEpoch);
      _servicesLastUpdated = DateTime.now();
    } catch (e) {
      if (kDebugMode) print('Failed to save services cache: $e');
    }
  }


  /// Parse body like in _fetchServices and update state.
  /// If fromCache==true we avoid showing network-loading UI (keeps UX smooth).
  void _parseAndSetServices(Map<String, dynamic> body, {bool fromCache = false}) {
    try {
      final rawCategories =
      (body['category'] is List) ? body['category'] as List<dynamic> : <dynamic>[];
      final parsedCategories =
      rawCategories.map<Map<String, dynamic>>((c) {
        final m = (c is Map) ? Map<String, dynamic>.from(c) : <String, dynamic>{};
        final name = (m['category_name'] ?? m['name'] ?? '').toString();
        final cnt = int.tryParse((m['count'] ?? m['cnt'] ?? 0).toString()) ?? 0;
        return {'category_name': name, 'count': cnt};
      }).toList();

      int totalService = 0;
      int exempted = 0;
      int chargable = 0;
      int invoices = 0;
      if (body['services'] is Map) {
        final Map servicesRaw = Map<String, dynamic>.from(body['services'] as Map);
        final Map<String, String> normalized = {};
        servicesRaw.forEach((k, v) => normalized[k.toString().trim().toLowerCase()] = v?.toString() ?? '');
        int _getIntByKeyContains(String token) {
          final entry = normalized.entries.firstWhere(
                  (e) => e.key.contains(token), orElse: () => const MapEntry('', '0'));
          return int.tryParse(entry.value.replaceAll(RegExp(r'[^0-9\-]'), '')) ?? 0;
        }

        totalService = _getIntByKeyContains('total') == 0
            ? (int.tryParse(normalized['total_service'] ?? '') ?? 0)
            : _getIntByKeyContains('total');
        exempted = _getIntByKeyContains('exempt');
        chargable = _getIntByKeyContains('charg') + _getIntByKeyContains('charge');
        invoices = _getIntByKeyContains('invoice');
      }

      List<dynamic> rawTickets = [];
      if (body.containsKey('todays') && body['todays'] is List) rawTickets = body['todays'] as List<dynamic>;

      final List<Map<String, dynamic>> parsedServices =
      rawTickets.map<Map<String, dynamic>>((t) {
        final Map<String, dynamic> item = (t is Map) ? Map<String, dynamic>.from(t) : {};
        final String rid = (item['rid'] ?? item['request_id'] ?? item['tkt_id'] ?? '').toString();
        final String title = (item['title'] ?? item['subject'] ?? '').toString();
        final String categoryName = (item['category'] ?? item['category_name'] ?? item['services_name'] ?? '').toString();
        final String createdBy = (item['createdBy'] ?? item['created_by_user'] ?? '').toString();
        final String createdAt = (item['createdAt'] ?? item['created_at'] ?? '').toString();
        final String status = (item['status'] ?? item['status_name'] ?? '').toString();

        String priorityLabel = 'Low';
        final dynamic p = item['priority'];
        if (p is num) {
          if (p == 2)
            priorityLabel = 'High';
          else if (p == 1) priorityLabel = 'Medium';
        } else if (p is String) {
          final pl = p.toLowerCase();
          if (pl.contains('high'))
            priorityLabel = 'High';
          else if (pl.contains('med')) priorityLabel = 'Medium';
        }

        final bool chargeable =
        ((item['chargeable'] ?? item['chargable'] ?? 0) is num)
            ? ((item['chargeable'] ?? item['chargable'] ?? 0) == 1)
            : (item['chargeable'] == true || (item['chargeable']?.toString().toLowerCase() == 'true'));

        final String typeLabel = (() {
          final tVal = (item['Type'] ?? item['type'] ?? item['request_type'] ?? '').toString();
          if (tVal.isEmpty) return 'SR';
          if (tVal.toLowerCase().contains('task')) return 'Task';
          if (tVal.toLowerCase().contains('service')) return 'SR';
          if (tVal == '1' || tVal == '0') return (tVal == '1') ? 'SR' : 'Task';
          return tVal;
        }());

        final String id = item['id']?.toString() ?? '';

        return {
          'id': id,
          'rid': rid,
          'title': title,
          'category': categoryName,
          'createdBy': createdBy,
          'status': status,
          'createdAt': createdAt,
          'priority': priorityLabel,
          'chargeable': chargeable,
          'Type': typeLabel,
          'invoice_id': item['invoice_id'],
          'items': item['items'] ?? [],
          'total_rate': item['total_rate'] ?? 0,
          'avatar': (item['createdByProfile'] ?? item['created_by_profile'] ?? item['profile'] ?? item['avatar'] ?? '').toString(),
          'assignedTo': (item['AssignedTo'] ?? item['assignedTo'] ?? '').toString(),
        };
      }).toList();

      if (!mounted) return;
      setState(() {
        _categories = parsedCategories;
        _totalServices = totalService;
        _exemptedCount = exempted;
        _chargeableCount = chargable;
        _invoicesCount = invoices;
        _services = parsedServices;
        // if this came from cache, ensure loading false so UI shows cached immediately
        if (fromCache) {
          _loading = false;
          _error = null;
        }
      });
    } catch (e) {
      if (kDebugMode) print('parseAndSetServices error: $e');
    }
  }


  Future<String> buildApiUrl() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('user_data');
    if (raw == null) throw Exception("user_data not found in local storage");
    final Map<String, dynamic> data = jsonDecode(raw);
    final slug = data['slug']?.toString() ?? '';
    final id = data['id']?.toString() ?? '';
    final type = data['type']?.toString() ?? '';
    final domain = data['domain']?.toString() ?? '';
    if (slug.isEmpty) throw Exception("Slug missing in user_data");
    if (id.isEmpty) throw Exception("ID missing in user_data");
    return "$domain$slug/serviceordersApi?id=$id&type=$type";
  }

  Future<void> _fetchServices({bool showLoading = true}) async {
    if (!mounted) return;
    if (showLoading) {
      setState(() {
        _loading = true;
        _error = null;
      });
    } else {
    }

    try {
      final url = await buildApiUrl();
      final uri = Uri.parse(url);
      final resp = await http.get(uri).timeout(const Duration(seconds: 12));

      if (resp.statusCode != 200) {
        String serverMsg = 'Server returned ${resp.statusCode}';
        try {
          final body = jsonDecode(resp.body);
          if (body is Map && body['message'] != null) serverMsg = body['message'].toString();
        } catch (_) {}
        throw Exception(serverMsg);
      }

      // after successful resp.statusCode == 200 and body parsed:
      final Map<String, dynamic> body = jsonDecode(resp.body) as Map<String, dynamic>;

// parse & set state
      _parseAndSetServices(body, fromCache: false);

// save raw response + timestamp
      try {
        await _saveServicesCache(resp.body);
      } catch (_) {}

// then existing setState to _loading/_refreshing/_error as before
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = null;
      });

    } on TimeoutException {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Request timed out. Please try again.';
      });
      _showErrorToast('Request timed out. Please try again.');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Sorry, something went wrong there. Try again.';
      });
      _showErrorToast('Failed to fetch data. Tap Retry.');
    }

    // keep existing behavior of fetching dashboard
    _fetchDashboard();
  }

  /// Loads cached user stats; returns true if we should fetch fresh data (cache absent or stale).
  Future<bool> _loadCachedUserStats() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kUserStatsCacheKey);
      final ts = prefs.getInt(_kUserStatsCacheTimeKey);
      if (ts != null) _userStatsLastUpdated = DateTime.fromMillisecondsSinceEpoch(ts);

      if (raw == null) return true; // no cache -> need fetch

      final dynamic data = jsonDecode(raw);

      // extract the raw list from likely shapes
      List<dynamic> usersRaw = [];
      if (data is Map &&
          data.containsKey('data') &&
          data['data'] is Map &&
          data['data']['usersWithTicketStats'] is List) {
        usersRaw = List<dynamic>.from(data['data']['usersWithTicketStats']);
      } else if (data is Map && data['usersWithTicketStats'] is List) {
        usersRaw = List<dynamic>.from(data['usersWithTicketStats']);
      } else if (data is List) {
        usersRaw = List<dynamic>.from(data);
      }

      // if still empty -> nothing to show, consider stale so fetch
      if (usersRaw.isEmpty) return true;

      // Normalize and optionally filter based on user type
      final bool isAdmin = _userType.toLowerCase() == 'admin';
      final String? myId = _userID?.toString();

      final List<Map<String, dynamic>> mapped = usersRaw.map<Map<String, dynamic>>((u) {
        final Map uu = (u is Map) ? u : {};
        // preserve account id in normalized form for filtering downstream
        final dynamic rawAccount = uu['account_id'] ?? uu['accountId'] ?? uu['account'] ?? uu['id'] ?? uu['accountid'];
        final String accountIdStr = rawAccount?.toString() ?? '';

        // total and per-status fields: try common keys (fallbacks)

        final int tNew = int.tryParse((uu['total_new'] ?? uu['service_new'] ?? uu['task_new'] ?? uu['new'] ?? 0).toString()) ?? 0;
        final int tPending = int.tryParse((uu['total_accepted'] ?? uu['service_accepted'] ?? uu['task_accepted'] ?? uu['accepted'] ?? uu['pending'] ?? 0).toString()) ?? 0;
        final int tIn = int.tryParse((uu['total_in_progress'] ?? uu['service_in_progress'] ?? uu['task_in_progress'] ?? uu['in_progress'] ?? 0).toString()) ?? 0;
        final int tExt = int.tryParse((uu['total_extended'] ?? uu['service_extended'] ?? uu['task_extended'] ?? uu['extended'] ?? 0).toString()) ?? 0;
        final int tComp = int.tryParse((uu['total_completed'] ?? uu['service_completed'] ?? uu['task_completed'] ?? uu['completed'] ?? 0).toString()) ?? 0;

        // final int total = (uu['total'] is num) ? (uu['total'] as num).toInt() : int.tryParse((uu['total'] ?? '0').toString()) ?? 0;
      // remove complete here
        final int total = tNew +tPending +tIn +tExt ;
        return {
          'account_id': accountIdStr,
          'name': (uu['name'] ?? uu['display_name'] ?? uu['user_name'] ?? '').toString(),
          'total': total,
          'new': tNew,
          'pending': tPending,
          'in_progress': tIn,
          'extended': tExt,
          'completed': tComp,
        };
      }).toList();

      // If user, filter to only entries that match _userID
      final List<Map<String, dynamic>> finalList;
      if (!isAdmin) {
        if (myId == null || myId.isEmpty) {
          // no user id -> treat as no-cache so caller will fetch fresh
          return true;
        }
        finalList = mapped.where((m) => (m['account_id']?.toString() ?? '') == myId).toList();
      } else {
        finalList = mapped;
      }

      // If nothing matched for this user, return true (fetch fresh) but still show empty state
      if (!mounted) return true;
      setState(() {
        _userStats = finalList;
        _loadingUserStats = false;
      });

      // animate chart using cached data (if any)
      _chartController.reset();
      try {
        await _chartController.forward();
      } catch (_) {}

      // decide staleness (10 minutes TTL)
      final bool stale = _userStatsLastUpdated == null
          ? true
          : DateTime.now().difference(_userStatsLastUpdated!).inMinutes > 10;
      return stale;
    } catch (e) {
      if (kDebugMode) print('Failed to load user stats cache: $e');
      return true;
    }
  }


  Future<void> _saveUserStatsCache(dynamic data) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kUserStatsCacheKey, jsonEncode(data));
      await prefs.setInt(_kUserStatsCacheTimeKey, DateTime.now().millisecondsSinceEpoch);
      _userStatsLastUpdated = DateTime.now();
    } catch (e) {
      if (kDebugMode) print('Failed to save user stats cache: $e');
    }
  }



  Future<Uri> _buildDashboardUri() async {
    final prefs = await SharedPreferences.getInstance();
    String slug = '';
    String id = '';
    String type = '';
    String domain = '';
    final raw = prefs.getString('user_data');
    if (raw != null) {
      try {
        final Map<String, dynamic> u = jsonDecode(raw);
        slug = (u['slug'] ?? '').toString();
        id = (u['id'] ?? '').toString();
        type = (u['type'] ?? '').toString();
        domain = (u['domain'] ?? '').toString();
        _userType = type;
        _userID = id ;
      } catch (_) {}
    }
    if (slug.isEmpty) slug = prefs.getString('slug') ?? '';
    return Uri.parse('$domain$slug/taskDashboardApi?id=$id&type=$type');
  }

  Future<void> _fetchDashboard({bool showLoading = true}) async {
    if (showLoading) {
      setState(() {
        _loading = true;
        _error = null;
      });
    } else {
      _error = null;
    }

    try {
      final uri = await _buildDashboardUri();
      final resp = await _dio.getUri(uri).timeout(const Duration(seconds: 12));
      if (resp.statusCode != 200) {
        throw Exception('Server returned ${resp.statusCode}');
      }

      final payload =
      resp.data is Map && resp.data.containsKey('summary')
          ? resp.data
          : (resp.data ?? {});

      final rawSummary =
      (payload['summary'] is Map)
          ? Map<String, dynamic>.from(payload['summary'])
          : <String, dynamic>{};
      final Map<String, int> parsedSummary = {};
      rawSummary.forEach((k, v) {
        final key = k.trim();
        final valStr = (v ?? '').toString().trim();
        final val = int.tryParse(valStr) ?? 0;
        parsedSummary[key] = val;
      });

      // save the payload to cache (non-blocking)
      // try {
      //   // 'payload' is already available in your code and contains 'summary' (same as before)
      //   await _saveDashboardCache(payload);
      // } catch (_) {
      //   // ignore saving errors
      // }

      // save the payload to cache (non-blocking)
      try {
        // 'payload' is already available in your code and contains 'summary' (same as before)
        await _saveDashboardCache(payload);
      } catch (_) {
        // ignore saving errors
      }

      setState(() {
        _summary = parsedSummary;
        _loading = false;
        _error = null;
      });
    } on TimeoutException {
      setState(() {
        _loading = false;
        _error = 'Request timed out. Pull to retry.';
      });
    } catch (e) {
      setState(() {
        _loading = false;
        _error = 'Failed to load dashboard: ${e.toString()}';
      });
    }
  }

  void _showErrorToast(String message) {
    if (!mounted) return;
    final sb = SnackBar(
      content: Text(message),
      backgroundColor: Colors.red.shade300,
      behavior: SnackBarBehavior.floating,
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      action: SnackBarAction(
        label: 'Retry',
        textColor: Colors.white,
        onPressed: () => _fetchServices(),
      ),
    );
    ScaffoldMessenger.of(context).showSnackBar(sb);
  }

  double _calcScaleFromWidth(double w) {
    final double base = 450.0;
    final double raw = (w / base);
    return raw.clamp(0.7, 1.0);
  }

  double _s(double base, double scale) => base * scale;

  Widget _loadingSkeleton(double scale) {
    return Column(
      children: List.generate(3, (index) {
        return Padding(
          padding: EdgeInsets.symmetric(
            horizontal: _s(12, scale),
            vertical: _s(8, scale),
          ),
          child: Container(
            height: _s(96, scale),
            decoration: BoxDecoration(
              color: Colors.grey.shade100,
              borderRadius: BorderRadius.circular(_s(8, scale)),
              border: Border.all(color: Colors.grey.shade200),
            ),
          ),
        );
      }),
    );
  }

  Widget _serviceTotalsCard(double scale) {
    final total = _totalServices == 0 ? _services.length : _totalServices;
    final segs = [
      {
        'count': _exemptedCount,
        'color': const Color(0xFFE70D0D),
        'label': 'Exempted',
      },
      {
        'count': _chargeableCount,
        'color': const Color(0xFFF8790C),
        'label': 'Chargeable',
      },
      {
        'count': _invoicesCount,
        'color': const Color(0xFF03C95A),
        'label': 'Invoices',
      },
    ];

    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: _s(6.0, scale),
        vertical: _s(2, scale),
      ),
      child: Card(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(_s(6, scale)),
        ),
        elevation: 4,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: _s(12.0, scale),
            vertical: _s(10, scale),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.analytics,
                    size: _s(20, scale),
                    color: _primaryPurple,
                  ),
                  SizedBox(width: _s(8, scale)),
                  Text(
                    'SR Summary',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: _s(14, scale),
                    ),
                  ),
                  const Spacer(),
                  Text(
                    'Total',
                    style: TextStyle(
                      color: Colors.black54,
                      fontSize: _s(12, scale),
                    ),
                  ),
                  SizedBox(width: _s(8, scale)),
                  TweenAnimationBuilder<int>(
                    tween: IntTween(begin: 0, end: total),
                    duration: const Duration(milliseconds: 700),
                    builder:
                        (context, value, child) => Text(
                      '$value',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: _s(16, scale),
                      ),
                    ),
                  ),
                ],
              ),

              SizedBox(height: _s(10, scale)),
              LayoutBuilder(
                builder: (context, constraints) {
                  final tiles = [
                    {
                      'icon': Icons.crisis_alert,
                      'label': 'Total SR',
                      'count': total,
                      'color': const Color(0xFF00B8E6),
                    },
                    {
                      'icon': Icons.folder_copy_outlined,
                      'label': 'Exempted',
                      'count': _exemptedCount,
                      'color': const Color(0xFFE70D0D),
                    },
                    {
                      'icon': Icons.currency_rupee,
                      'label': 'Chargeable',
                      'count': _chargeableCount,
                      'color': const Color(0xFFF8790C),
                    },
                    {
                      'icon': Icons.receipt_long,
                      'label': 'Invoices',
                      'count': _invoicesCount,
                      'color': const Color(0xFF03C95A),
                    },
                  ];
                  final tileWidth = (constraints.maxWidth - _s(10, scale)) / 2;
                  return Wrap(
                    spacing: _s(10, scale),
                    runSpacing: _s(10, scale),
                    children:
                    tiles.map((t) {
                      return SizedBox(
                        width: tileWidth,
                        child: Container(
                          padding: EdgeInsets.symmetric(
                            horizontal: _s(12, scale),
                            vertical: _s(10, scale),
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(
                              _s(6, scale),
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.03),
                                blurRadius: 6,
                              ),
                            ],
                          ),
                          child: Row(
                            children: [
                              CircleAvatar(
                                radius: _s(18, scale),
                                backgroundColor: (t['color'] as Color)
                                    .withOpacity(0.12),
                                child: Icon(
                                  t['icon'] as IconData,
                                  color: t['color'] as Color,
                                  size: _s(18, scale),
                                ),
                              ),
                              SizedBox(width: _s(10, scale)),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment:
                                  CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      t['label'] as String,
                                      style: TextStyle(
                                        fontSize: _s(12, scale),
                                        color: Colors.grey[700],
                                      ),
                                    ),
                                    SizedBox(height: _s(6, scale)),
                                    Text(
                                      '${t['count']}',
                                      style: TextStyle(
                                        fontSize: _s(14, scale),
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }).toList(),
                  );
                },
              ),

            ],
          ),
        ),
      ),
    );
  }

  Widget _progressCard(double scale) {
    final int newSR = _summary['new_sr'] ?? _summary['new'] ?? 0;
    final int pending = _summary['pending'] ?? 0;
    final int inProgress = _summary['in_progress'] ?? 0;
    final int extended = _summary['extended'] ?? 0;
    // final int completed = _summary['completed'] ?? 0;
    // final int other = _summary['other'] ?? 0
    ;
    int total = 0 ;
    // (newSR + pending + inProgress + extended + completed + other);
    // (newSR + pending + inProgress + extended );


    final tiles = [
      {
        'icon': Icons.schedule,
        'label': 'Pending',
        'count': pending,
        'color': const Color(0xFFF26522), // #F26522
      },
      {
        'icon': Icons.autorenew,
        'label': 'In Progress',
        'count': inProgress,
        'color': const Color(0xFFFFC107), // #FFC107
      },
      {
        'icon': Icons.update,
        'label': 'Extended',
        'count': extended,
        'color': const Color(0xFF1B84FF), // #1B84FF
      },
      // {
      //   'icon': Icons.check_circle,
      //   'label': 'Completed',
      //   'count': completed,
      //   'color': const Color(0xFF03C95A), // #03C95A (unchanged)
      // },
      // {
      //   'icon': Icons.house_outlined,
      //   'label': 'Internal',
      //   'count': other,
      //   'color': Colors.grey,
      // },
    ];

    if (_showSR) {
      tiles.insert(0, {
        'icon': Icons.fiber_new,
        'label': 'New SR',
        'count': newSR,
        'color': const Color(0xFF3B7080), // #3B7080
      });

       total =
      // (newSR + pending + inProgress + extended + completed + other);
      ( newSR + pending + inProgress + extended );
    }else{
       total =
      // (newSR + pending + inProgress + extended + completed + other);
      ( pending + inProgress + extended );
    }


    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: _s(6, scale),
        vertical: _s(3, scale),
      ),
      child: Card(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(_s(6, scale)),
        ),
        elevation: 5,
        child: Padding(
          padding: EdgeInsets.all(_s(14, scale)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.dashboard_customize,
                    size: _s(20, scale),
                    color: _primaryPurple,
                  ),
                  SizedBox(width: _s(8, scale)),
                  Text(
                    'Task Summary',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: _s(14, scale),
                    ),
                  ),
                  const Spacer(),
                  Text(
                    'Total',
                    style: TextStyle(
                      color: Colors.black54,
                      fontSize: _s(12, scale),
                    ),
                  ),
                  SizedBox(width: _s(8, scale)),
                  TweenAnimationBuilder<int>(
                    tween: IntTween(begin: 0, end: total),
                    duration: const Duration(milliseconds: 700),
                    builder:
                        (context, value, child) => Text(
                      '$value',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: _s(14, scale),
                      ),
                    ),
                  ),
                ],
              ),
              SizedBox(height: _s(12, scale)),
              LayoutBuilder(
                builder: (context, constraints) {
                  final width = constraints.maxWidth;
                  final twoPerRow = width < 520;
                  final itemW =
                  twoPerRow
                      ? (width - _s(12, scale)) / 2
                      : (width / 3) - _s(12, scale);

                  return Wrap(
                    spacing: _s(10, scale),
                    runSpacing: _s(10, scale),
                    children:
                    tiles.map((t) {
                      return SizedBox(
                        width: itemW,
                        child: _smallStatTile(
                          icon: t['icon'] as IconData,
                          label: t['label'] as String,
                          count: t['count'] as int,
                          color: t['color'] as Color,
                          scale: scale,
                        ),
                      );
                    }).toList(),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _smallStatTile({
    required IconData icon,
    required String label,
    required int count,
    required Color color,
    required double scale,
  }) {
    return Container(
      padding: EdgeInsets.symmetric(
        vertical: _s(10, scale),
        horizontal: _s(12, scale),
      ),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(_s(10, scale)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.03),
            blurRadius: _s(8, scale),
          ),
        ],
      ),
      child: Row(
        children: [
          CircleAvatar(
            backgroundColor: color.withOpacity(0.12),
            radius: _s(18, scale),
            child: Icon(icon, size: _s(18, scale), color: color),
          ),
          SizedBox(width: _s(10, scale)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: _s(12, scale),
                    color: Colors.grey[700],
                  ),
                ),
                SizedBox(height: _s(6, scale)),
                Text(
                  '$count',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: _s(14, scale),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }


  @override
  Widget build(BuildContext context) {
    final double scale = _calcScaleFromWidth(MediaQuery.of(context).size.width);
    final ScrollController pageController = ScrollController();
    return GestureDetector(
      // onHorizontalDragEnd: _handleHorizontalDragEnd,
      child: Scaffold(
        body: RefreshIndicator(
          onRefresh: () async {
            await _fetchServices(showLoading: false);
            await _fetchUserStats();
            // await _fetchDashboard();
          },
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 150),
            child: _loading
                ? SingleChildScrollView(
              key: const ValueKey('loading'),
              physics: const AlwaysScrollableScrollPhysics(),
              child: Padding(padding: EdgeInsets.only(top: 12), child: _loadingSkeleton(scale)),
            )
                : SingleChildScrollView(
              key: const ValueKey('content'),
              physics: const AlwaysScrollableScrollPhysics(),
              child: Column(
                children: [

                  SizedBox(height: _s(8, scale)),

                  SlideTransition(
                    position: _progressSlide,
                    child: FadeTransition(
                      opacity: _progressFade,
                      child: _progressCard(scale),
                    ),
                  ),
                  SlideTransition(
                    position: _progressSlide,
                    child: FadeTransition(
                      opacity: _progressFade,
                      child: _loadingUserStats
                          ? Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: _s(8, scale),
                          vertical: _s(4, scale),
                        ),
                        child: Card(
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(_s(10, scale)),
                          ),
                          elevation: 3,
                          child: SizedBox(
                            height: _s(200, scale),
                            child: Center(child: CircularProgressIndicator()),
                          ),
                        ),
                      )
                          : (_userType.toLowerCase() == 'admin'
                      //     ? TaskStatisticsCard(
                      //   users: _userStats,
                      //   animation: _chartController,
                      //   scale: scale,
                      // )
                          ?TaskStatisticsCard(
                        users: _userStats,
                        animation: _chartController,
                        scale: scale,
                        parentScrollController: pageController, // pass here
                      )
                          : UserVerticalBarChart(
                        users: _userStats,
                        animation: _chartController,
                        scale: scale,
                        userId: _userID,
                        serviceType: _serviceType,

                      )),

                    ),
                  ),


                  if(_userType == 'admin')
                  SlideTransition(
                    position: _serviceSlide,
                    child: FadeTransition(
                      opacity: _serviceFade,
                      child: _serviceTotalsCard(scale),
                    ),
                  ),

                  SizedBox(height: _s(8, scale)),

                  // SizedBox(height: _s(8 , scale)),
                  Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: _s(18, scale),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.swipe,
                          size: _s(18, scale),
                          color: Colors.grey,
                        ),
                        SizedBox(width: _s(8, scale)),
                        Text(
                          'Swipe',
                          style: TextStyle(
                            color: Colors.black45,
                            fontSize: _s(12, scale),
                          ),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(height: _s(8 , scale)),

                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}


/// Drop-in enhanced TaskStatisticsCard
/// - pass optional parentScrollController (page's controller) for best behavior
/// - auto-forwards overscroll with animateTo (smoother)
/// - auto-collapses when parent scroll passes a threshold
class TaskStatisticsCard extends StatefulWidget {
  final List<Map<String, dynamic>> users;
  final Animation<double> animation; // used by bars
  final double scale;

  /// Optional: the page's scroll controller. If provided, used to animate parent scroll and for
  /// collapse detection. If null, will fall back to PrimaryScrollController.of(context).
  final ScrollController? parentScrollController;

  const TaskStatisticsCard({
    Key? key,
    required this.users,
    required this.animation,
    required this.scale,
    this.parentScrollController,
  }) : super(key: key);

  @override
  _TaskStatisticsCardState createState() => _TaskStatisticsCardState();
}

class _TaskStatisticsCardState extends State<TaskStatisticsCard> with TickerProviderStateMixin {
  // Colors (kept from original)
  static const Color cNew = Color(0xFF3B7080); // New SR
  static const Color cPending = Color(0xFFF26522); // Pending
  static const Color cInProgress = Color(0xFFFFC107); // In Progress
  static const Color cExtended = Color(0xFF1B84FF); // Extended
  static const Color cCompleted = Color(0xFF03C95A); // Completed
  static const Color cLabel = Color(0xFF666666); // Label

  bool _expanded = false;
  final Duration _animDuration = const Duration(milliseconds: 360);
  final Curve _curve = Curves.easeInOutCubic;

  // configuration (kept from your original values)
  int get _maxVisibleRows => 8;
  double get _rowBaseHeight => 12.0; // logical px before scaling
  double get _rowVerticalSpacing => 6.0; // spacing between rows (logical px)
  double get _cardHorizontalPadding => 12.0; // card padding (from your code)
  double get _cardVerticalPadding => 4.0;

  // internal controllers
  ScrollController? _expandedScrollController;
  ScrollController? _parentController; // resolved parent controller (either passed or Primary)
  final GlobalKey _cardKey = GlobalKey();

  // collapse threshold in pixels (when parent scrolls past this relative to card top -> collapse)
  late double _autoCollapseThreshold;

  @override
  void initState() {
    super.initState();
    _expandedScrollController = ScrollController();
    // Resolve parent in didChangeDependencies for PrimaryScrollController access
    _autoCollapseThreshold = 40.0; // tuneable
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolveParentController();
  }

  @override
  void didUpdateWidget(covariant TaskStatisticsCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.parentScrollController != widget.parentScrollController) {
      _resolveParentController();
    }
  }

  void _resolveParentController() {
    // prefer explicit parent controller
    _parentController = widget.parentScrollController ?? PrimaryScrollController.of(context);
    // attach listener to collapse when parent scrolls
    _parentController?.removeListener(_parentScrollListener);
    _parentController?.addListener(_parentScrollListener);
  }

  @override
  void dispose() {
    _parentController?.removeListener(_parentScrollListener);
    _expandedScrollController?.dispose();
    super.dispose();
  }

  // parent scroll listener: when parent moves enough past the card, collapse
  void _parentScrollListener() {
    if (!_expanded) return;

    try {
      final controller = _parentController;
      if (controller == null || !controller.hasClients) return;

      // compute card's top offset from the global coordinate system
      final RenderBox? rb = _cardKey.currentContext?.findRenderObject() as RenderBox?;
      if (rb == null || !rb.attached) return;
      final cardGlobal = rb.localToGlobal(Offset.zero);
      final cardTop = cardGlobal.dy; // distance from screen top

      // When cardTop is sufficiently above the screen (scrolled up), collapse
      // threshold is configurable; this collapses when card moves mostly off-screen.
      if (cardTop < -_autoCollapseThreshold) {
        // collapse with animation
        _collapseAnimated();
      }
    } catch (_) {
      // silent fallback
    }
  }

  void _collapseAnimated() {
    if (mounted && _expanded) {
      setState(() => _expanded = false);
    }
  }

  int _toInt(dynamic v, {int fallback = 0}) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? fallback;
    return fallback;
  }

  Widget _legendDot(String label, Color color, double scale) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(width: 10 * scale, height: 10 * scale, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2))),
      SizedBox(width: 5 * scale),
      Text(label, style: TextStyle(fontSize: 11 * scale, color: Colors.grey.shade700)),
      SizedBox(width: 6 * scale),
    ]);
  }


  @override
  Widget build(BuildContext context) {
    final scale = widget.scale;
    // defensively create a sorted list (descending by total)
    final List<Map<String, dynamic>> sorted = List<Map<String, dynamic>>.from(widget.users);
    sorted.sort((a, b) {
      final int aTotal = _toInt(a['total']);
      final int bTotal = _toInt(b['total']);
      return bTotal.compareTo(aTotal);
    });

    final int totalUsers = sorted.length;
    final int visibleRows = totalUsers == 0 ? 1 : (totalUsers < _maxVisibleRows ? totalUsers : _maxVisibleRows);

    final int maxTotal = sorted.isEmpty
        ? 1
        : sorted.map((u) => _toInt(u['total'])).fold<int>(1, (prev, v) => v > prev ? v : prev);

    // --- HEIGHT CALCULATION (dynamic & conservative estimates)
    final double headerRowHeight = math.max(25.0, 18.0) * scale + 8.0 * scale;
    final double legendEstimatedHeight = 30.0 * scale;
    final double perRowHeight = (_rowBaseHeight + 8.0 + _rowVerticalSpacing) * scale;
    final double rowsAreaCollapsedHeight = visibleRows * perRowHeight;
    // When expanded, we want to show many rows but cap by half screen
    final double maxExpandedRowsHeight = math.min(sorted.length * perRowHeight, MediaQuery.of(context).size.height * 0.5);

    // total card collapsed height
    final double cardCollapsedHeight = (_cardVerticalPadding * 4.0) * scale +
        headerRowHeight +
        legendEstimatedHeight +
        rowsAreaCollapsedHeight +
        8.0 * scale;

    // total card expanded height (approx)
    final double cardExpandedHeight = (_cardVerticalPadding * 4.0) * scale +
        headerRowHeight +
        legendEstimatedHeight +
        maxExpandedRowsHeight +
        8.0 * scale;

    return AnimatedSize(
      duration: _animDuration,
      curve: _curve,
      alignment: Alignment.topCenter,
      child: Card(
        key: _cardKey,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6 * scale)),
        elevation: 4,
        margin: EdgeInsets.symmetric(horizontal: 10 * scale, vertical: 4 * scale),
        child: InkWell(
          borderRadius: BorderRadius.circular(10 * scale),
          onTap: () {
            setState(() {
              _expanded = !_expanded;
              if (_expanded) {
                // bring card into view if needed
                _ensureCardVisible();
                Future.microtask(() => _expandedScrollController?.jumpTo(0));
              }
            });
          },
      child: Padding(
        padding: EdgeInsets.all(12 * scale),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min, // allow column to size to content
            children: [
              // Header: Title + toggle chevron (unchanged)
              Row(
                children: [
                  Icon(Icons.bar_chart, size: 18 * scale, color: const Color(0xFF6B59C9)),
                  SizedBox(width: 8 * scale),
                  Text('Task Statistics', style: TextStyle(fontSize: 14 * scale, fontWeight: FontWeight.w700)),
                  const Spacer(),
                  InkWell(
                    onTap: () {
                      setState(() {
                        _expanded = !_expanded;
                        if (_expanded) _ensureCardVisible();
                      });
                    },
                    borderRadius: BorderRadius.circular(6),
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: 8 * scale, vertical: 6 * scale),
                      child: Row(
                        children: [
                          AnimatedRotation(
                            turns: _expanded ? 0.5 : 0.0,
                            duration: _animDuration,
                            curve: _curve,
                            child: Icon(Icons.expand_more, size: 18 * scale, color: Colors.blue.shade700),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),

              SizedBox(height: 8 * scale),

              // Legend
              AnimatedOpacity(
                duration: _animDuration,
                opacity: 1.0,
                curve: _curve,
                child: Wrap(
                  spacing: 1 * scale,
                  runSpacing: 4 * scale,
                  children: [
                    _legendDot('New SR', cNew.withOpacity(0.85), scale),
                    _legendDot('Pending', cPending.withOpacity(0.85), scale),
                    _legendDot('In Progress', cInProgress.withOpacity(0.85), scale),
                    _legendDot('Extended', cExtended.withOpacity(0.85), scale),
                  ],
                ),
              ),

              SizedBox(height: 8 * scale),

              // ROWS AREA: Use _buildRowsArea which will provide a fixed collapsed height
              // and an expanded full-height Column when _expanded is true.
              _buildRowsArea(sorted, maxTotal, scale, rowsAreaCollapsedHeight, maxExpandedRowsHeight),
            ],
          ),

        ),
          ),

    ),
    );
  }

  Widget _buildRowsArea(
      List<Map<String, dynamic>> sorted,
      int maxTotal,
      double scale,
      double collapsedHeight,
      double expandedMaxHeight,
      ) {
    // visible rows when collapsed
    final int totalUsers = sorted.length;
    final int visibleRows = totalUsers == 0 ? 1 : (totalUsers < _maxVisibleRows ? totalUsers : _maxVisibleRows);

    if (!_expanded) {
      // collapsed: fixed small area (no internal scroll)
      return SizedBox(
        height: collapsedHeight,
        child: ListView.builder(
          physics: const NeverScrollableScrollPhysics(),
          itemCount: visibleRows,
          itemBuilder: (context, index) => _buildRowItem(context, sorted[index], maxTotal, scale),
        ),
      );
    }

    // expanded: render all rows in a Column so the card grows to fit them
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(height: 4 * scale),
        ...List.generate(sorted.length, (index) => _buildRowItem(context, sorted[index], maxTotal, scale)),
        SizedBox(height: 4 * scale),
      ],
    );
  }




  Widget _buildRowItem(BuildContext context, Map<String, dynamic> u, int maxTotal, double scale) {
    final int tNew = _toInt(u['new']);
    final int tPending = _toInt(u['pending']);
    final int tIn = _toInt(u['in_progress']);
    final int tExt = _toInt(u['extended']);
    final int total = _toInt(u['total'], fallback: tNew + tPending + tIn + tExt);

    final segments = [tNew, tPending, tIn, tExt];
    final segColors = [
      cNew.withOpacity(0.75),
      cPending.withOpacity(0.75),
      cInProgress.withOpacity(0.75),
      cExtended.withOpacity(0.75),
      cCompleted.withOpacity(0.75),
    ];

    final double rowSpacing = (_rowVerticalSpacing / 2.0) * scale;

    return Padding(
      padding: EdgeInsets.symmetric(vertical: rowSpacing),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // name + total (same row)
          Row(
            children: [
              Expanded(
                child: Text(
                  u['name'] ?? '-',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13 * scale, color: cLabel, fontWeight: FontWeight.w600),
                ),
              ),
              SizedBox(width: 8 * scale),
              Padding(
                padding: EdgeInsets.only(right: 8 * scale),
                child: Text(
                  '$total',
                  style: TextStyle(fontSize: 12 * scale, color: Colors.grey.shade700, fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          SizedBox(height: 5 * scale),

          // bar (expands to available width)
          Row(
            children: [
              Expanded(
                child: LayoutBuilder(builder: (context, constraints) {
                  final availableWidth = constraints.maxWidth;
                  return GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    child: SizedBox(
                      width: availableWidth,
                      height: _rowBaseHeight * scale,
                      child: AnimatedBuilder(
                        animation: widget.animation,
                        builder: (context, child) {
                          return CustomPaint(
                            size: Size(availableWidth, _rowBaseHeight * scale),
                            painter: StackedBarPainter(
                              segments: segments,
                              colors: segColors,
                              animationValue: widget.animation.value,
                              maxTotal: maxTotal,
                              scale: scale,
                              borderRadius: 8.0 * scale,
                            ),
                          );
                        },
                      ),
                    ),
                  );
                }),
              ),
              SizedBox(width: 8 * scale),
            ],
          ),
        ],
      ),
    );
  }

  /// Ensures the card is visible in the viewport when expanded by scrolling the parent a bit.
  void _ensureCardVisible() {
    try {
      final controller = _parentController ?? PrimaryScrollController.of(context);
      if (controller == null || !controller.hasClients) return;

      final RenderBox? rb = _cardKey.currentContext?.findRenderObject() as RenderBox?;
      if (rb == null || !rb.attached) return;
      final cardGlobal = rb.localToGlobal(Offset.zero);
      final cardTop = cardGlobal.dy;
      final screenHeight = MediaQuery.of(context).size.height;
      // If card is partially off-screen at bottom, scroll parent down so card top becomes ~80px from top
      const desiredTop = 80.0;
      final delta = cardTop - desiredTop;
      if (delta > 1.0) {
        final target = (controller.position.pixels + delta).clamp(controller.position.minScrollExtent, controller.position.maxScrollExtent);
        controller.animateTo(target, duration: const Duration(milliseconds: 260), curve: Curves.easeInOut);
      }
    } catch (_) {
      // ignore
    }
  }
}

class StackedBarPainter extends CustomPainter {
  final List<int> segments;
  final List<Color> colors;
  final double animationValue; // 0..1
  final int maxTotal;
  final double scale;
  final double borderRadius;

  StackedBarPainter({
    required this.segments,
    required this.colors,
    required this.animationValue,
    required this.maxTotal,
    required this.scale,
    this.borderRadius = 6.0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..style = PaintingStyle.fill;

    final height = size.height;
    final barTop = height * 0.08 ;
    final barHeight = height * 0.8;
    final fullWidth = size.width * animationValue.clamp(0.0, 1.0);

    // background track
    final bgRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, barTop, size.width, barHeight),
      Radius.circular(borderRadius),
    );
    final bgPaint = Paint()..color = Colors.grey.shade200;
    canvas.drawRRect(bgRect, bgPaint);

    // nothing to draw
    if (maxTotal <= 0 || (segments.every((v) => v == 0))) return;

    final denom =
    maxTotal > 0 ? maxTotal : segments.fold<int>(1, (p, e) => p + e);
    double x = 0.0;

    // find first and last non-zero indices so we round only ends
    int firstIdx = -1;
    int lastIdx = -1;
    for (int i = 0; i < segments.length; i++) {
      if (segments[i] > 0) {
        if (firstIdx == -1) firstIdx = i;
        lastIdx = i;
      }
    }

    for (var i = 0; i < segments.length; i++) {
      final segVal = segments[i];
      if (segVal <= 0) continue;
      final frac = segVal / denom;
      final segWidth = fullWidth * frac;
      if (segWidth <= 0) continue;

      // corner radii only at overall start/end segments
      Radius tl = Radius.zero,
          bl = Radius.zero,
          tr = Radius.zero,
          br = Radius.zero;
      if (i == firstIdx) {
        tl = Radius.circular(borderRadius);
        bl = Radius.circular(borderRadius);
      }
      if (i == lastIdx) {
        tr = Radius.circular(borderRadius);
        br = Radius.circular(borderRadius);
      }

      final rrect = RRect.fromRectAndCorners(
        Rect.fromLTWH(x, barTop, segWidth, barHeight),
        topLeft: tl,
        bottomLeft: bl,
        topRight: tr,
        bottomRight: br,
      );

      paint.color = colors[i];
      canvas.drawRRect(rrect, paint);

      // ----------------------------
      // ALWAYS draw the value INSIDE the segment
      // Scale font down until it fits (down to minFont).
      // Then center horizontally & vertically.
      // ----------------------------
      final valueText = segVal.toString();

      // Start font size depending on scale
      double fontSize = 11.0 * scale;
      final double minFontSize = 7.0 * scale;
      TextPainter tp = _textPainter(valueText, fontSize, Colors.white);

      // Layout with an unconstrained width first to measure natural width
      tp.layout();

      // We'll reserve a small padding inside segment
      const double paddingInside = 6.0;

      // If the text doesn't fit, reduce fontSize until it fits or reaches minFontSize
      while ((tp.width + paddingInside) > segWidth && fontSize > minFontSize) {
        fontSize -= 0.6 * scale;
        tp = _textPainter(valueText, fontSize, Colors.white);
        tp.layout();
      }

      // If still wider than segWidth (extremely small segment), we still draw it centered;
      // it will be clipped visually — this avoids drawing it above the bar per your request.
      final dx = x + max(0.0, (segWidth - tp.width) / 2);
      final dy = barTop + (barHeight - tp.height) / 2;
      tp.paint(canvas, Offset(dx, dy));

      x += segWidth;
    }
  }

  TextPainter _textPainter(String text, double fontSize, Color color) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontSize: fontSize,
          fontWeight: FontWeight.w700,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '',
    );
    // layout will be called by caller when needed
    return tp;
  }

  @override
  bool shouldRepaint(covariant StackedBarPainter old) {
    return old.animationValue != animationValue ||
        !listEquals(old.segments, segments) ||
        old.maxTotal != maxTotal ||
        old.scale != scale;
  }
}


/// A compact vertical bar chart for a single user.
class UserVerticalBarChart extends StatelessWidget {
  final List<Map<String, dynamic>> users;
  final Animation<double> animation;
  final double scale;
  final String? userId;
  final String? serviceType;

  const UserVerticalBarChart({
    Key? key,
    required this.users,
    required this.animation,
    required this.scale,
    required this.userId,
    required this.serviceType,
  }) : super(key: key);

  // Colors reused from TaskStatisticsCard for consistency
  static const Color cNew = Color(0xFF3B7080);       // New SR
  static const Color cPending = Color(0xFFF26522);   // Pending
  static const Color cInProgress = Color(0xFFFFC107); // In Progress
  static const Color cExtended = Color(0xFF1B84FF);  // Extended
  static const Color cCompleted = Color(0xFF03C95A); // Completed
  // static const Color labelColor = Color(0xFF666666);


  @override
  Widget build(BuildContext context) {
    final Map<String, int> counts = _buildUserStatusCounts(users, userId);


    final int maxCount = counts.values.fold<int>(1, (p, v) => v > p ? v : p);

    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6 * scale)),
      elevation: 4,
      margin: EdgeInsets.symmetric(horizontal: 10 * scale, vertical: 6 * scale),
      child: Padding(
        padding: EdgeInsets.all(12 * scale),
        child: SizedBox(
          height: 200 * scale,
          child: Column(
            children: [
              // Title row
              Row(
                children: [
                  Icon(Icons.bar_chart, size: 18 * scale, color: const Color(0xFF6B59C9)),
                  SizedBox(width: 8 * scale),
                  Text('Task Statistics', style: TextStyle(fontSize: 14 * scale, fontWeight: FontWeight.w700)),
                  const Spacer(),
                ],
              ),

              SizedBox(height: 8 * scale),

              // Legend moved to top (compact)
              Row(
                // mainAxisSize: MainAxisSize.min,
                // mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  if (serviceType == '3')
                  _legendDot('New SR', cNew.withOpacity(0.92), scale),
                  _legendDot('Pending', cPending.withOpacity(0.92), scale),
                  _legendDot('In Progress', cInProgress.withOpacity(0.92), scale),
                  _legendDot('Extended', cExtended.withOpacity(0.92), scale),
                  _legendDot('Completed', cCompleted.withOpacity(0.92), scale),
                ],
              ),

              SizedBox(height: 10 * scale),

              // Chart area (expanded)
              Expanded(
                child: AnimatedBuilder(
                  animation: animation,
                  builder: (context, _) {
                    // choose colors based on serviceType
                    final List<Color> barColors = (serviceType == '3')
                        ? [cNew, cPending, cInProgress, cExtended, cCompleted]
                        : [cPending, cInProgress, cExtended, cCompleted];
// check if all counts are zero
                    final bool noData = counts.values.every((v) => v == 0);

                    return CustomPaint(
                      size: Size(double.infinity, double.infinity),
                      painter: _VerticalBarsPainter(
                        counts: counts,
                        animationValue: animation.value,
                        maxCount: maxCount,
                        scale: scale,
                        colors: barColors,
                        // tweak painter params for better spacing
                        gridLines: 4,
                        barSpacingFactor: 1.25,
                        topExtraPadding: 14.0,     // more room above bars for values
                        bottomExtraPadding: 10.0,  // small breathing room below bars
                      ),
                    );
                  },
                ),
              ),


              // removed bottom labels — UI is cleaner and fits inside box
            ],
          ),
        ),
      ),
    );
  }

  Widget _legendDot(String label, Color color, double scale) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(width: 10 * scale, height: 10 * scale, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2))),
      SizedBox(width: 5 * scale),
      Text(label, style: TextStyle(fontSize: 11 * scale, color: Colors.grey.shade700)),
      SizedBox(width: 6 * scale),
    ]);
  }

// Sum statuses but only for entries that match account_id == userId
  Map<String, int> _buildUserStatusCounts(
      List<Map<String, dynamic>> allUsers,
      String? userId,

      ) {
    final Map<String, int> result = {
      'new': 0,
      'pending': 0,
      'in_progress': 0,
      'extended': 0,
      'completed': 0,
    };


    if (userId == null) return result;
    for (final Map<String, dynamic> u in allUsers) {
      final dynamic ac =
          u['account_id'] ?? u['accountId'] ?? u['account'] ?? u['id'];
      if (ac != null && ac.toString() == userId.toString()) {
        // ✅ Include 'new' count only if _serviceType != 1

        if (serviceType == '3') {
          result['new'] = result['new']! + _toInt(u['new']);
        }

        result['pending'] = result['pending']! + _toInt(u['pending']);
        result['in_progress'] = result['in_progress']! + _toInt(u['in_progress']);
        result['extended'] = result['extended']! + _toInt(u['extended']);
        result['completed'] = result['completed']! + _toInt(u['completed']);
      }
    }

    // If serviceType == 1, remove the "new" entry to keep map consistent
    if (serviceType != '3') {
      result.remove('new');
    }

    return result;
  }

  int _toInt(dynamic v, {int? fallback = 0}) {
    if (v == null) return fallback ?? 0;
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? (fallback ?? 0);
    return fallback ?? 0;
  }

}

/// Vertical bar chart painter with equal gaps (including left/right),
/// bars prefer a fixed width but shrink if necessary, and value labels always on top.
class _VerticalBarsPainter extends CustomPainter {
  final Map<String, int> counts;
  final double animationValue; // 0..1
  final int maxCount;
  final double scale;
  final List<Color> colors;

  final int gridLines;
  final double barSpacingFactor;
  final double topExtraPadding;
  final double bottomExtraPadding;

  _VerticalBarsPainter({
    required this.counts,
    required this.animationValue,
    required this.maxCount,
    required this.scale,
    required this.colors,
    this.gridLines = 4,
    this.barSpacingFactor = 1.0,
    this.topExtraPadding = 12.0,
    this.bottomExtraPadding = 1.0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final Paint gridPaint = Paint()
      ..color = Colors.grey.withOpacity(0.12)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0 * scale;

    final double leftPadding = 8 * scale;
    final double rightPadding = 8 * scale;
    final double topPadding = (12 * scale) + topExtraPadding * scale;
    final double bottomPadding = (1 * scale) + bottomExtraPadding * scale;

    final double contentW = size.width - leftPadding - rightPadding;
    final double contentH = size.height - topPadding - bottomPadding;
    if (contentW <= 0 || contentH <= 0) return;

    // --- Ordered values (matches your mapping)
    final List<int> orderedValues = (colors.length == 5)
        ? [
      counts['new'] ?? 0,
      counts['pending'] ?? 0,
      counts['in_progress'] ?? 0,
      counts['extended'] ?? 0,
      counts['completed'] ?? 0,
    ]
        : [
      counts['pending'] ?? 0,
      counts['in_progress'] ?? 0,
      counts['extended'] ?? 0,
      counts['completed'] ?? 0,
    ];

    // Keep only positive values
    final List<MapEntry<int, Color>> entries = [];
    for (int i = 0; i < orderedValues.length && i < colors.length; i++) {
      final int v = orderedValues[i];
      if (v > 0) entries.add(MapEntry(v, colors[i])); // keep zeros too if you want spacing for types with 0
    }

    // If you want to hide zero-value types (no bar), filter v>0
    // final List<MapEntry<int, Color>> entries = ... where v>0

    // --- No data ---
    if (entries.isEmpty) {
      final textPainter = TextPainter(
        text: TextSpan(
          text: 'No data found',
          style: TextStyle(
            color: Colors.grey.shade600,
            fontSize: 13 * scale,
            fontWeight: FontWeight.w500,
          ),
        ),
        textAlign: TextAlign.center,
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: size.width - 20 * scale);

      final double dx = (size.width - textPainter.width) / 2;
      final double dy = (size.height - textPainter.height) / 2;
      textPainter.paint(canvas, Offset(dx, dy));
      return;
    }

    // --- Grid lines ---
    for (int i = 0; i <= gridLines; i++) {
      final double y = topPadding + (contentH * i / gridLines);
      canvas.drawLine(Offset(leftPadding, y), Offset(size.width - rightPadding, y), gridPaint);
    }

    final int n = entries.length;

    // --- Preferred sizes ---
    final double targetBarWidth = 40.0 * scale;
    final double minBarWidth = 6.0 * scale;
    final double minGap = 8.0 * scale * barSpacingFactor; // we will try to keep gaps >= this

    // Compute gap and barW such that gaps = n+1 equal gaps (left + between + right)
    // Let gaps = g, bar width = w => (n * w) + ((n + 1) * g) = contentW
    // Prefer w = targetBarWidth and g >= minGap. If not possible, reduce g down to minGap, and if still not possible reduce w proportionally.
    double barW = targetBarWidth;
    double gap = (contentW - n * barW) / (n + 1);

    if (gap < minGap) {
      // try cap gap at minGap and shrink barW
      gap = minGap;
      final double availableForBars = contentW - (n + 1) * gap;
      barW = (availableForBars / n).clamp(minBarWidth, targetBarWidth);
      // if barW still > targetBarWidth (rare), cap it
      if (barW > targetBarWidth) barW = targetBarWidth;
      // recompute gap to evenly center (so tiny rounding won't leave empties)
      gap = (contentW - n * barW) / (n + 1);
    }

    // If gap is larger than needed, it's fine — bars will be centered because left gap equals right gap.
    final double startX = leftPadding + gap;

    final Paint barPaint = Paint()..style = PaintingStyle.fill;

    // --- Draw bars with equal gaps on both sides ---
    for (int i = 0; i < n; i++) {
      final int v = entries[i].key;
      final Color color = entries[i].value;

      final double fraction = (maxCount <= 0) ? 0.0 : (v / maxCount);
      final double animatedFraction = fraction * animationValue;
      final double barH = animatedFraction * contentH;
      final double x = startX + i * (barW + gap);
      final double yTop = topPadding + (contentH - barH);
      final Rect r = Rect.fromLTWH(x, yTop, barW, barH);

      final RRect rr = RRect.fromRectAndCorners(
        r,
        topLeft: Radius.circular(8 * scale),
        topRight: Radius.circular(8 * scale),
        bottomLeft: Radius.circular(6 * scale),
        bottomRight: Radius.circular(6 * scale),
      );

      barPaint.color = color.withOpacity(0.96);
      canvas.drawRRect(rr, barPaint);

      // --- Value text always on top of bar (outside) ---
      if (v != null) {
        final String label = '$v';
        final TextStyle labelStyle = TextStyle(
          fontSize: 11 * scale,
          color: Colors.black87,
          fontWeight: FontWeight.w700,
        );

        final TextPainter tp = TextPainter(
          text: TextSpan(text: label, style: labelStyle),
          textDirection: TextDirection.ltr,
        )..layout(minWidth: 0, maxWidth: barW + 24 * scale);

        // position above the bar (yTop - tp.height - margin)
        final double margin = 6.0 * scale;
        double tx = x + (barW - tp.width) / 2.0;
        double ty = yTop - tp.height - margin;
        // paint label (black by default). If it collides visually with bar top, we still keep it above.
        tp.paint(canvas, Offset(tx, ty));
      }

      // subtle depth
      final Paint line = Paint()..color = Colors.black.withOpacity(0.03);
      canvas.drawRRect(rr.shift(Offset(0, 1 * scale)), line);
    }
  }

  @override
  bool shouldRepaint(covariant _VerticalBarsPainter old) {
    return old.animationValue != animationValue ||
        old.counts != counts ||
        old.maxCount != maxCount ||
        old.colors.length != colors.length ||
        old.barSpacingFactor != barSpacingFactor;
  }
}




