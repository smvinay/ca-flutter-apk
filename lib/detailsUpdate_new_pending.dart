// lib/template2/template2_details.dart
import 'dart:io';
import 'dart:math';
import 'dart:async';
import 'dart:convert';
import 'package:ca_desk/widgets/AutoScrollingText.dart';
import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:hive/hive.dart';
import 'package:image_picker/image_picker.dart';
import 'package:open_file/open_file.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdfx/pdfx.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

const Color _primaryPurple = Color(0xFF6B59C9);

class Template2Details extends StatefulWidget {
  final String ticketId;
  final String? rid;
  final String cacheType; // 'task' or 'service'
  const Template2Details({
    Key? key,
    required this.ticketId,
    this.rid,
    this.cacheType = 'service',
  })
    : super(key: key);

  @override
  State<Template2Details> createState() => _Template2DetailsState();
}

class _Template2DetailsState extends State<Template2Details>
    with SingleTickerProviderStateMixin {

  bool _dirty = false;
  late Map<String, dynamic> _details;
  final List<Map<String, dynamic>> _remarks = [];

  // options loaded from API
  List<String> _statusOptions = [];
  List<Map<String, dynamic>> _reassignOptions = [];

  static const String _cacheKeyServices = 'cache_service_list'; // services
  static const String _cacheKeyTasks = 'cache_task_list'; // tasks

// sliding / cache state
  List<Map<String, dynamic>> _cacheList = [];
  int _currentIndex = 0;
  PageController? _pageController;

// helper to select cache key based on incoming widget.cacheType (if you added that)
  String get _effectiveCacheKey {
    // if you haven't added widget.cacheType, keep the fixed key or detect by caller
    return ((widget).cacheType == 'task')
        ? _cacheKeyTasks
        : _cacheKeyServices;
  }
  bool _isFetching = false;


  String? _activeTicketID;
  String? _serviceType;
  bool _showSR = false;
  String _userType = '';
  int _visiblePage = 0;
  bool _pageReady = true; // first page shows immediately
  bool _initialPageLoaded = false; // track first-time load


  String _status = 'Pending';
  String _domain = 'https://cadesk.net/';
  String? _reassign;
  String? _slug;
  String? _userID;
  bool _submitting = false;

  // NEW fields
  List<Map<String, dynamic>> _assignedUsers = []; // each: {id, name, profile}

  // Extend date/time
  DateTime? _extendDate;
  TimeOfDay? _extendTime;

  // baseDesignWidth is the width you designed for (e.g. 420). On narrower screens scale down.
  double _calcScaleFromWidth(double w) {
    const double base = 420.0;
    final raw = w / base;
    // clamp between 0.64 and 1.0 so things remain legible on tiny phones
    return raw.clamp(0.64, 1.0);
  }

  double _s(double value, double scale) => value * scale;


  final Set<String> allowedExtensions = {
    '.pdf',
    '.png',
    '.jpg',
    '.jpeg',
    '.webp',
    '.gif',
    '.docx', // Word
    '.doc', // old Word
    '.xlsx', // Excel
    '.xls', // old Excel
    '.csv',
    '.txt',
    '.pptx',
  };

  // controllers to show selected values in the TextFormFields
  final TextEditingController _extendDateController = TextEditingController();
  final TextEditingController _extendTimeController = TextEditingController();

  String _formatDate(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  String _formatTime(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  // NEW: persistent saved file (path) key pattern
  String get _prefsFileKey => 'pending_file_ticket_${widget.ticketId}';

  String? _savedFilePath; // actual device path to file
  String? _savedFileName; // display name

  // upload state
  bool _uploading = false;
  double _uploadProgress = 0.0;

  // animations
  late final AnimationController _anim;
  late final Animation<double> _fade;

  // controllers
  final TextEditingController _remarkController = TextEditingController();

  // network / loading state
  bool _loading = true;
  String? _error;

  // Dio instance
  final Dio _dio = Dio();
  // inside _Template2DetailsState
  final ImagePicker _picker = ImagePicker();
  int? _savedFileSizeBytes; // size in bytes of the saved file (used to display KB)

  bool _cachePagerInitialized = false;
  Timer? _cacheReloadTimer; // if you create one later
  String? _cachePagerForKey; // the cache key (e.g. 'cache_service_list' or slug-based key) we initialized for


  // at top of State class
  late Box _cacheBox;
  final Map<String, Map<String, dynamic>> _detailsById = {}; // in-memory mirror for fast access
  final Set<String> _fetchingIds = {};
  final int _cacheMax = 10;
  final String _cacheOrderKey = '_cache_order';


  @override
  void initState() {
    super.initState();

    _anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 320),
    );
    _fade = CurvedAnimation(parent: _anim, curve: Curves.easeOut);
    _anim.forward();

    // prepare a default empty structure to avoid null errors in the UI before data arrives
    _details = {
      'rid': widget.rid ?? 'RID-0000',
      'title': '',
      'description': '',
      'priority': '',
      'category': '',
      'assignedBy': '',
      'assignedTo': '',
      'startDate': '',
      'endDate': '',
      'deadline': '',
      'progress': 0.0,
      'files': [],
    };

    // Delay ALL async initialization until after first frame
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initializeAfterBuild();
    });
  }

  Future<void> _initializeAfterBuild() async {
    // 🔹 Load user info & initialize cache
    await _loadUserInfo();
    await _initCacheAndPager();
    _loadSavedFileFromPrefs();

    if (!mounted) return;

    // 🔹 Show skeleton immediately (now safe, post-frame)
    setState(() {
      _pageReady = false;
      _initialPageLoaded = false;
    });

    try {
      // 🔹 Fetch the first record AFTER the widget fully built
      await _fetchDetails();
    } catch (_) {
      // handled internally
    } finally {
      if (!mounted) return;

      // 🔹 Mark the first page as ready
      setState(() {
        _pageReady = true;
        _initialPageLoaded = true;
        _prefetchAroundIndex(_currentIndex, radius: 4);
        _visiblePage = _currentIndex;
      });
    }
  }

  void safeSetState(VoidCallback fn) {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(fn);
    });
  }

  @override
  void dispose() {
    _anim.dispose();
    _remarkController.dispose();
    _extendDateController.dispose();
    _extendTimeController.dispose();
    // dispose page controller
    try {
      _pageController?.dispose();
    } catch (_) {}

    _dio.close();
    super.dispose();
  }


  Future<void> _initCacheAndPager({bool force = false}) async {
    try {
      final key = _effectiveCacheKey; // your existing getter for cache key

      if (!force && _cachePagerInitialized && _cachePagerForKey == key && _pageController != null) {
        return;
      }

      // dispose previous controller gracefully
      if (_pageController != null) {
        try {
          _pageController!.dispose();
        } catch (_) {}
        _pageController = null;
      }

      // reset state
      _cacheList = [];
      _currentIndex = 0;
      _cachePagerInitialized = false;
      _cachePagerForKey = key;

      // --- ensure Hive box is opened and assign to _cacheBox ---
      if (!Hive.isBoxOpen('cacheBox')) {
        await Hive.openBox('cacheBox');
      }
      _cacheBox = Hive.box('cacheBox');

      // --- read stored page list under `key` (accept List, String, Uint8List) ---
      final dynamic raw = _cacheBox.get(key);

      List<Map<String, dynamic>> listFromBox = [];

      if (raw == null) {
        // no cached array found -> create empty controller
        _pageController = PageController(initialPage: 0);
        _cachePagerInitialized = true;
        _cachePagerForKey = key;
        return;
      }

      if (raw is List) {
        // stored directly as a list of maps
        listFromBox = raw.map<Map<String, dynamic>>((e) {
          if (e is Map) return Map<String, dynamic>.from(e);
          return <String, dynamic>{};
        }).toList();
      } else if (raw is String) {
        try {
          final parsed = jsonDecode(raw);
          if (parsed is List) {
            listFromBox = parsed.map<Map<String, dynamic>>((e) {
              if (e is Map) return Map<String, dynamic>.from(e);
              return <String, dynamic>{};
            }).toList();
          }
        } catch (e, st) {
          debugPrint('Failed to parse JSON cache for $key: $e\n$st');
        }
      } else if (raw is Uint8List) {
        try {
          final parsed = jsonDecode(utf8.decode(raw));
          if (parsed is List) {
            listFromBox = parsed.map<Map<String, dynamic>>((e) {
              if (e is Map) return Map<String, dynamic>.from(e);
              return <String, dynamic>{};
            }).toList();
          }
        } catch (e) {
          debugPrint('Failed to decode Uint8List cache for $key: $e');
        }
      }

      // assign loaded list
      _cacheList = listFromBox;

      // --- hydrate in-memory mirror from LRU order stored in box (if present) ---
      try {
        final List<dynamic> rawOrder = _cacheBox.get(_cacheOrderKey, defaultValue: <dynamic>[]) as List<dynamic>;
        final List<String> order = rawOrder.map((e) => e.toString()).toList();

        // hydrate in-memory detailsById for items referenced in order (up to _cacheMax)
        for (final id in order.reversed) {
          // reversed so newest are first when hydrating; but stop at limit
          if (_detailsById.length >= _cacheMax) break;
          final cached = _cacheBox.get(id);
          if (cached == null) continue;
          try {
            Map<String, dynamic>? map;
            if (cached is String) {
              map = Map<String, dynamic>.from(jsonDecode(cached) as Map<String, dynamic>);
            } else if (cached is Map) {
              map = Map<String, dynamic>.from(cached);
            }
            if (map != null && map.isNotEmpty) _detailsById[id] = map;
          } catch (e) {
            // ignore parse error
          }
        }
      } catch (e) {
        debugPrint('Failed to hydrate detailsById: $e');
      }

      // find incoming index by rid (if widget.rid provided)
      int idx = 0;
      if (widget.rid != null && widget.rid!.isNotEmpty && _cacheList.isNotEmpty) {
        final found = _cacheList.indexWhere((m) {
          final v = (m['rid'] ?? m['id'] ?? '').toString();
          return v == widget.rid;
        });
        if (found >= 0) idx = found;
      }

      _currentIndex = idx;
      _pageController = PageController(initialPage: idx);

      _cachePagerInitialized = true;
      _cachePagerForKey = key;
    } catch (e, st) {
      debugPrint('Cache init failed: $e\n$st');
      if (_pageController == null) _pageController = PageController(initialPage: 0);
      _cachePagerInitialized = true;
    }
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
          _showSR = (_userType == 'admin') ? true : (_serviceType == '3') ? true : false ;
        });
      }
    } catch (e) {
      if (kDebugMode) debugPrint('Failed to load user info: $e');
    }
  }


  Future<void> _fetchDetails({String? ticketId, bool showLoading = true}) async {
    if (!mounted) return;
    if (showLoading) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }

    try {
      // Reset lightweight fields
      _statusOptions = [];
      _extendDate = null;
      _extendTime = null;
      _assignedUsers = [];
      _reassign = null;
      _reassignOptions = [];
      _remarkController.clear();
      _remarks.clear();
      _savedFilePath = null;

      final ticketIdParam = ticketId ?? _activeTicketID ?? widget.ticketId ?? '';
      final uri = Uri.parse(
        '$_domain$_slug/detaileApi?tkt_id=$ticketIdParam&type=$_userType&id=$_userID&slug=$_slug',
      );

      final resp = await _dio.getUri(uri).timeout(const Duration(seconds: 12));
      if (resp.statusCode != 200 || resp.data == null) {
        throw Exception('Invalid response from server');
      }

      final dataWrapper = resp.data;
      final Map<String, dynamic> payload =
      (dataWrapper is Map && dataWrapper['data'] is Map)
          ? Map<String, dynamic>.from(dataWrapper['data'])
          : (dataWrapper is Map ? Map<String, dynamic>.from(dataWrapper) : {});

      // --- Local variable prep ---
      final Map<String, dynamic> newDetails = Map<String, dynamic>.from(_details);
      List<Map<String, dynamic>> newRemarks = [];
      List<Map<String, dynamic>> newReassignOptions = [];
      List<Map<String, dynamic>> newAssignedUsers = [];
      List<Map<String, dynamic>> firstAssignedUsers = [];
      List<String> statusOptionsLocal = [];

      String newCreatedByName = '';
      String newCreatedByProfile = '';
      String newCompanyName = '';
      String? computedReassign;

      // --- Core details ---
      newDetails['id'] = payload['id'] ?? newDetails['id'];
      newDetails['rid'] = payload['rid'] ?? newDetails['rid'];
      newDetails['task_type'] = payload['type'] ?? newDetails['type'];
      newDetails['title'] = payload['title'] ?? newDetails['title'];
      newDetails['description'] = payload['description'] ?? payload['desc'] ?? '';
      newDetails['priority'] = payload['priority'] ?? '';
      newDetails['category'] = payload['category'] ?? '';
      newDetails['ticket_firststatus'] = payload['ticket_firststatus'] ?? '';
      _status = payload['status']?.toString() ?? _status;

      // --- Created by ---
      final cb = payload['createdBy'];
      if (cb is Map) {
        newCreatedByName = (cb['name'] ?? cb['fullname'] ?? cb['user_name'] ?? '').toString();
        newCreatedByProfile = (cb['profile'] ?? cb['avatar'] ?? '').toString();
      } else {
        newCreatedByName = cb?.toString() ?? '';
      }

      // --- Company ---
      final comp = payload['company'];
      if (comp is Map) {
        newCompanyName = (comp['company'] ?? comp['name'] ?? '').toString();
      } else {
        newCompanyName = comp?.toString() ?? '';
      }

      // --- Assigned Users ---
      if (payload['assignedUsers'] is List) {
        newAssignedUsers = (payload['assignedUsers'] as List)
            .map<Map<String, dynamic>>((e) => {
          'id': (e['id'] ?? '').toString(),
          'name': (e['name'] ?? '').toString(),
          'profile': (e['profile'] ?? '').toString(),
        })
            .toList();
      } else {
        final at = (payload['assignedTo'] ?? payload['assigned_to'] ?? '').toString();
        if (at.isNotEmpty) {
          newAssignedUsers = at
              .split(',')
              .map((id) => {'id': id.trim(), 'name': id.trim(), 'profile': ''})
              .toList();
        }
      }

      // --- First assigned users (from old_assigned first row) ---
      if (payload['first_assignedUsers'] is List) {
        firstAssignedUsers = (payload['first_assignedUsers'] as List)
            .map<Map<String, dynamic>>((e) => {
          'id': (e['id'] ?? '').toString(),
          'name': (e['name'] ?? '').toString(),
          'profile': (e['profile'] ?? '').toString(),
        })
            .toList();
      }

      // --- Assign other small details ---
      newDetails['assignedBy'] = newCreatedByName;
      newDetails['assignedTo'] =
          payload['assignedTo'] ?? payload['assigned_to'] ?? newDetails['assignedTo'];
      newDetails['startDate'] = payload['startDate'] ?? '';
      newDetails['endDate'] = payload['endDate'] ?? '';
      newDetails['deadline'] = payload['deadline'] ?? '';
      newDetails['extendDate'] = payload['extendDate'] ?? '';
      newDetails['extendTime'] = payload['extendTime'] ?? '';
      _extendDate = _parseServerDate(newDetails['extendDate']);
      _extendTime = _parseServerTime(newDetails['extendTime']);
      _applyExtendFromServer(newDetails);

      newDetails['status'] = payload['status'] ?? 'Pending';
      newDetails['assignedToName'] = payload['assignedToName'] ?? '-';

      // --- Status options ---
      final so = payload['status_options'];
      if (so is List) {
        statusOptionsLocal = so.map((e) => e.toString()).toList();
      }
      if (!_showSR) {
        statusOptionsLocal.removeWhere((s) => s.toLowerCase().trim() == 'new sr');
      }
      if (statusOptionsLocal.contains(_status)) {
        final currentIndex = statusOptionsLocal.indexOf(_status!);
        statusOptionsLocal = statusOptionsLocal.sublist(currentIndex);
      }

      // --- Reassign options ---
      final ro = payload['reassign_options'] ?? [];
      if (ro is List) {
        newReassignOptions = ro.map<Map<String, dynamic>>((e) {
          if (e is Map) return Map<String, dynamic>.from(e);
          return {'id': e.toString(), 'name': e.toString()};
        }).toList();
      }

      // --- Auto-select reassign ---
      final assignedStr = (payload['assignedTo'] ?? payload['assigned_to'] ?? '').toString();
      final assignedParts = assignedStr.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
      if (assignedParts.length == 1 && newAssignedUsers.length == 1 && newReassignOptions.isNotEmpty) {
        final candidate = assignedParts.first;
        computedReassign = newReassignOptions.firstWhere(
              (opt) => opt['id'].toString() == candidate || opt['name'].toString() == candidate,
          orElse: () => {},
        )['id']?.toString();
      }

      // --- Attachments ---
      if (payload['attachments'] is String && payload['attachments'].toString().isNotEmpty) {
        newDetails['attachments'] = payload['attachments'];
      } else {
        newDetails.remove('attachments');
      }

      // --- Files ---
      final files = payload['files'];
      newDetails['files'] = (files is List)
          ? files.map((f) {
        if (f is Map) return Map<String, dynamic>.from(f);
        return {'name': f.toString(), 'url': f.toString()};
      }).toList()
          : [];

      List<Map<String, dynamic>> createdUploads = [];
      final attachmentsFromPayload = payload['attachments'] ?? '';

      if (attachmentsFromPayload is String && (attachmentsFromPayload).isNotEmpty) {
        createdUploads = [
          {'name': 'Attachment File', 'url': attachmentsFromPayload}
        ];
      }

      // --- Remarks ---
      final remarks = payload['remarks'];
      if (remarks is List) {
        for (final r in remarks.whereType<Map>()) {
          final userMap = r['user'] is Map ? r['user'] : {};
          final rUser = (userMap['name'] ?? r['user'] ?? '').toString();
          final rUserProfile = (userMap['profile'] ?? '').toString();

          String rAssignedTo = '';
          if (r['assigned_to'] is List) {
            rAssignedTo = (r['assigned_to'] as List)
                .map((e) => (e is Map ? e['name'] ?? '' : e.toString()))
                .where((s) => s.toString().trim().isNotEmpty)
                .join(', ');
          } else {
            rAssignedTo = (r['assigned_to'] ?? '').toString();
          }

          final uploads = (r['uploads'] is List)
              ? (r['uploads'] as List)
              .map<Map<String, dynamic>>((u) => {
            'name': u['name'] ?? u['file_name'] ?? '',
            'url': u['url'] ?? '',
          })
              .toList()
              : [];

          newRemarks.add({
            'id': r['id'],
            'datetime': r['datetime'] ?? '',
            'user': rUser,
            'user_profile': rUserProfile,
            'assigned_to': rAssignedTo,
            'status': r['status'] ?? '',
            'remarks': r['remarks'] ?? '',
            'uploads_list': uploads,
            'uploads': createdUploads.isNotEmpty ? createdUploads.map((u) => u['name']).join(', ') : '',
            'assignedToIds': newDetails['assignedTo'],
            'is_created': false,
          });
        }
      }

      // --- Inject "Created" record ---
      final createdAt = payload['createdAt'] ?? '';
      final createdRemarksText =
      (payload['description'] ?? payload['desc'] ?? payload['title'] ?? 'Ticket created').toString();

      newRemarks.add({
        'id': 'created',
        'datetime': createdAt,
        'user': newCreatedByName,
        'user_profile': newCreatedByProfile,
        'assigned_to': newAssignedUsers,
        'status': ((newDetails['task_type'] == 'Service Request') && newDetails['ticket_firststatus'] != '1')
            ? 'New SR'
            : 'Pending',
        'remarks': createdRemarksText,
        'uploads_list': createdUploads,
        'assignedToIds': newDetails['assignedTo'],
        'is_created': true,
        'first_assignedUsers': firstAssignedUsers,
      });


      // ✅ Safe state update
      // if (mounted) {
      //   WidgetsBinding.instance.addPostFrameCallback((_) {
      //     if (!mounted) return;
      //     setState(() {
      //       _details = newDetails;
      //       _assignedUsers = newAssignedUsers;
      //       _reassignOptions = newReassignOptions;
      //       _remarks
      //         ..clear()
      //         ..addAll(newRemarks);
      //       _statusOptions = statusOptionsLocal;
      //       _status = payload['status']?.toString() ?? _status;
      //       if (computedReassign?.isNotEmpty ?? false) _reassign = computedReassign;
      //       _loading = false;
      //       _error = null;
      //     });
      //   });
      // }
      // Update UI immediately (fast)
      // update UI (deferred safely)
      safeSetState(() {
        _details = newDetails;
        _assignedUsers = newAssignedUsers;
        _reassignOptions = newReassignOptions;
        _remarks
          ..clear()
          ..addAll(newRemarks);
        _statusOptions = statusOptionsLocal;
        _status = payload['status']?.toString() ?? _status;
        if (computedReassign?.isNotEmpty ?? false) _reassign = computedReassign;
        _loading = false;
        _error = null;
      });

// background cache save (non-blocking)
      final String savedId = (newDetails['id'] ?? '').toString();
      if (savedId.isNotEmpty) {
        _saveDetailsToCache(savedId, newDetails)
            .then((_) => _touchCacheId(savedId))
            .catchError((e, st) {
          debugPrint('Failed to persist fetched details for $savedId: $e\n$st');
        });
      }


    } on TimeoutException {
      safeSetState(() {
        _loading = false;
        _error = 'Request timed out. Pull to retry.';
      });
    } catch (e) {
      safeSetState(() {
        _loading = false;
        _error = 'Something went wrong: $e';
      });
    }
  }


// --------------------------------------------------------------------------------
  /// Get cached details synchronously (returns null if not found).
  Map<String, dynamic>? _getCachedDetails(String id) {
    if (id.isEmpty) return null;
    try {
      final cached = _cacheBox.get(id);
      if (cached == null) return null;
      if (cached is String) {
        final Map<String, dynamic> map = jsonDecode(cached) as Map<String, dynamic>;
        return map;
      }
      if (cached is Map) {
        // rare, but handle gracefully
        return Map<String, dynamic>.from(cached);
      }
    } catch (e) {
      debugPrint('getCachedDetails error for $id: $e');
    }
    return null;
  }

  Future<void> _saveDetailsToCache(String id, Map<String, dynamic> details) async {
    if (id.isEmpty) return;
    try {
      // store as JSON string (stable)
      final String jsonStr = jsonEncode(details);
      await _cacheBox.put(id, jsonStr);

      // maintain LRU order list
      final List<dynamic> raw = _cacheBox.get(_cacheOrderKey, defaultValue: <dynamic>[]) as List<dynamic>;
      List<String> order = raw.map((e) => e.toString()).toList();
      order.remove(id);
      order.add(id);

      while (order.length > _cacheMax) {
        final String removeId = order.removeAt(0);
        await _cacheBox.delete(removeId);
      }
      await _cacheBox.put(_cacheOrderKey, order);
      _detailsById[id] = Map<String, dynamic>.from(details);
    } catch (e) {
      debugPrint('Failed to save cache for $id: $e');
    }
  }

  Future<void> _touchCacheId(String id) async {
    if (id.isEmpty) return;
    try {
      final List<dynamic> raw = _cacheBox.get(_cacheOrderKey, defaultValue: <dynamic>[]) as List<dynamic>;
      List<String> order = raw.map((e) => e.toString()).toList();
      order.remove(id);
      order.add(id);
      while (order.length > _cacheMax) {
        final String removeId = order.removeAt(0);
        await _cacheBox.delete(removeId);
      }
      await _cacheBox.put(_cacheOrderKey, order);
    } catch (e) {
      debugPrint('touchCache error: $e');
    }
  }

  Future<Map<String, dynamic>> _fetchDetailsFromApi(String id) async {
    if (id.isEmpty) throw Exception('Empty id');
    // avoid duplicate fetch if already in progress
    if (_fetchingIds.contains(id)) {
      // wait until it's removed (simple busy-wait with timeout)
      while (_fetchingIds.contains(id)) {
        await Future.delayed(const Duration(milliseconds: 80));
      }
      final cached = _getCachedDetails(id);
      if (cached != null) return cached;
      throw Exception('Fetch conflict: no data after waiting for $id');
    }

    _fetchingIds.add(id);
    try {
      // call your existing fetch method (ensure it returns a Future that completes when _details updated)
      await _fetchDetails(ticketId: id, showLoading: false);

      // after fetch completes, check _details (it must match id)
      if (_details != null && (_details['id'] ?? '').toString() == id) {
        final result = Map<String, dynamic>.from(_details);
        return result;
      }

      // fallback: attempt to read from API directly (if you have _dio or http client)
      // throw if we don't have a result
      throw Exception('No details returned for $id after fetch');
    } finally {
      _fetchingIds.remove(id);
    }
  }




  /// Prefetch neighbors around `index`. `radius` controls how many neighbors on each side.
  /// Example: radius = 4 will prefetch up to 8 neighbors around index (4 left, 4 right).
  void _prefetchAroundIndex(int index, {int radius = 4}) {
    if (_cacheList.isEmpty) return;
    final int len = _cacheList.length;

    // Calculate window: if near edges, expand other side to try to fetch up to (2*radius) items total
    int start = (index - radius).clamp(0, len - 1);
    int end = (index + radius).clamp(0, len - 1);

    // optional: if fewer items on left, extend right
    if (index - start < radius) {
      end = (end + (radius - (index - start))).clamp(0, len - 1);
    }
    // if fewer on right, extend left
    if (end - index < radius) {
      start = (start - (radius - (end - index))).clamp(0, len - 1);
    }

    // Create list of ids to prefetch (exclude current index if desired or include)
    final List<String> idsToPrefetch = [];
    for (int i = start; i <= end; i++) {
      if (i < 0 || i >= len) continue;
      final item = _cacheList[i] as Map<String, dynamic>;
      final id = (item['id'] ?? '').toString();
      if (id.isEmpty) continue;
      // skip if already cached or currently fetching or is active and already loaded
      if (_getCachedDetails(id) != null) {
        // touch to mark MRU
        _touchCacheId(id);
        continue;
      }
      if (_fetchingIds.contains(id)) continue;
      idsToPrefetch.add(id);
    }

    // limit how many we fetch (e.g., up to 8)
    final int limit = 8;
    final toFetch = idsToPrefetch.take(limit).toList();

    for (final id in toFetch) {
      _fetchAndCache(id);
    }
  }

  /// Fetch a single id and save to cache (in background).
  Future<void> _fetchAndCache(String id) async {
    if (id.isEmpty) return;
    if (_fetchingIds.contains(id)) return;
    _fetchingIds.add(id);
    try {
      final data = await _fetchDetailsFromApi(id);
      if (data.isNotEmpty) {
        await _saveDetailsToCache(id, data);
      }
    } catch (e) {
      debugPrint('Prefetch failed for $id: $e');
    } finally {
      _fetchingIds.remove(id);
      // After saving a prefetched id, try to keep the window topped up.
      // Use a short delay to avoid tight loops.
      Future.delayed(const Duration(milliseconds: 60), () {
        try {
          // Ensure we still have a current index
          if (mounted) _prefetchAroundIndex(_currentIndex, radius: 4);
        } catch (_) {}
      });

      // If the prefetched item is the visible page, cause rebuild
      if (mounted) setState(() {});
    }
  }


// --------------------------------------------------------------------------------


  DateTime? _parseServerDate(dynamic v) {
    if (v == null) return null;
    if (v is DateTime) return v;
    if (v is! String) return null;
    final s = v.trim();
    if (s.isEmpty) return null;

    // Try dd-mm-yyyy or dd/mm/yyyy
    final parts = s.contains('-') ? s.split('-') : s.split('/');
    if (parts.length == 3) {
      try {
        final d = int.parse(parts[0]);
        final m = int.parse(parts[1]);
        final y = int.parse(parts[2]);
        return DateTime(y, m, d);
      } catch (_) {
        return null;
      }
    }

    // Try ISO yyyy-mm-dd
    if (RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(s)) {
      try {
        final p = s.split('-');
        final y = int.parse(p[0]);
        final m = int.parse(p[1]);
        final d = int.parse(p[2]);
        return DateTime(y, m, d);
      } catch (_) {
        return null;
      }
    }

    return null;
  }

  /// Parse server time strings like "09:00", "9:00", "09:00 AM", "09:00PM"
  TimeOfDay? _parseServerTime(dynamic v) {
    if (v == null) return null;
    if (v is TimeOfDay) return v;
    if (v is! String) return null;
    String s = v.trim().toLowerCase();
    if (s.isEmpty) return null;

    // handle formats with AM/PM
    final ampmMatch = RegExp(r'(\d{1,2}:\d{2})\s*(am|pm)$').firstMatch(s);
    if (ampmMatch != null) {
      final hhmm = ampmMatch.group(1)!;
      final period = ampmMatch.group(2)!;
      final parts = hhmm.split(':');
      try {
        int h = int.parse(parts[0]);
        final m = int.parse(parts[1]);
        if (period == 'pm' && h < 12) h += 12;
        if (period == 'am' && h == 12) h = 0;
        return TimeOfDay(hour: h, minute: m);
      } catch (_) {
        return null;
      }
    }

    // handle 24-hour "HH:mm" or "H:mm"
    final parts = s.split(':');
    if (parts.length >= 2) {
      try {
        int h = int.parse(parts[0]);
        int m = int.parse(parts[1]);
        // clamp to valid ranges
        h = h.clamp(0, 23);
        m = m.clamp(0, 59);
        return TimeOfDay(hour: h, minute: m);
      } catch (_) {
        return null;
      }
    }

    return null;
  }


  // Load saved file info (if any) for this ticket
  Future<void> _loadSavedFileFromPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final path = prefs.getString(_prefsFileKey);
      if (path != null && path.isNotEmpty) {
        final file = File(path);
        if (await file.exists()) {
          setState(() {
            _savedFilePath = path;
            _savedFileName = file.path.split('/').last;
          });
        } else {
          await prefs.remove(_prefsFileKey);
        }
      }
    } catch (_) {}
  }

  Future<void> _clearSavedFile() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsFileKey);
    setState(() {
      _savedFilePath = null;
      _savedFileName = null;
      _savedFileSizeBytes = null ;
    });
  }

  // Converts status text to required integer code for API
  // (0 New,1 Pending,2 In Progress,3 Extend,4 Completed)
  int _statusToCode(String status) {
    final s = status.toLowerCase();
    if (s == 'new' || s == 'new sr' || s == 'New SR' || s == '0') return 0;
    if (s.contains('pending') || s == '1') return 1;
    if (s.contains('in progress') || s.contains('inprogress') || s == '2') return 2;
    if (s.contains('extend') || s == '3') return 3;
    if (s.contains('completed') || s == '4') return 4;
    // fallback to Pending
    return 1;
  }

  // Submit entire form (fields + saved file if exists) to ticketRemarkApi
  Future<void> _submitUpdate() async {
    // validation for extend
    if (_remarkController.text.trim().isEmpty) {
      Fluttertoast.showToast(
        msg: "Please enter a remark.",
        toastLength: Toast.LENGTH_SHORT,
        gravity: ToastGravity.BOTTOM,
        backgroundColor: Colors.redAccent.shade200,
        textColor: Colors.white,
        fontSize: 14.0,
      );
      return;
    }

    final code = _statusToCode(_status);
    if (code == 3) {
      if (_extendDate == null) {
        // ScaffoldMessenger.of(context).showSnackBar(
        //   const SnackBar(content: Text('Please pick extend due date')),
        // );
        Fluttertoast.showToast(
          msg: "Please pick extend end date.",
          toastLength: Toast.LENGTH_SHORT,
          gravity: ToastGravity.BOTTOM,
          backgroundColor: Colors.redAccent.shade200,
          textColor: Colors.white,
          fontSize: 14.0,
        );

        return;
      }
      if (_extendTime == null) {
        // ScaffoldMessenger.of(context).showSnackBar(
        //   const SnackBar(content: Text('Please pick extend due time')),
        // );

        Fluttertoast.showToast(
          msg: "Please pick extend end time.",
          toastLength: Toast.LENGTH_SHORT,
          gravity: ToastGravity.BOTTOM,
          backgroundColor: Colors.redAccent.shade200,
          textColor: Colors.white,
          fontSize: 14.0,
        );

        return;
      }
    }

    setState(() {
      _submitting = true;
      _uploading = true;
      _uploadProgress = 0.0;
    });

    try {

      // endpoint
      final submitEndpoint = '$_domain$_slug/ticketRemarkApi';

      // Prepare fields according to the API contract
      final fields = {
        'tkt_id': _activeTicketID ?? widget.ticketId,
        'assign_to': _reassign ?? '',
        'status': _statusToCode(_status).toString(),
        'remarks': _remarkController.text.trim(),
        'user_id': _userID.toString(),
        'user_type': _userType,
      };

      if (code == 3 && _extendDate != null && _extendTime != null) {
        final y = _extendDate!.year.toString().padLeft(4, '0');
        final m = _extendDate!.month.toString().padLeft(2, '0');
        final d = _extendDate!.day.toString().padLeft(2, '0');
        final hh = _extendTime!.hour.toString().padLeft(2, '0');
        final mm = _extendTime!.minute.toString().padLeft(2, '0');
        fields['extend_due_date'] = '$y-$m-$d';
        fields['extend_due_time'] = '$hh:$mm';
      }

      FormData form;
      if (_savedFilePath != null) {
        final file = File(_savedFilePath!);
        if (await file.exists()) {
          final fileName = file.path.split('/').last;
          form = FormData.fromMap({
            ...fields,
            'file': await MultipartFile.fromFile(file.path, filename: fileName),
          });
        } else {
          await _clearSavedFile();
          form = FormData.fromMap({...fields});
        }
      } else {
        form = FormData.fromMap({...fields});
      }

      final response = await _dio.post(
        submitEndpoint,
        data: form,
        options: Options(
          headers: {
            "Accept": "application/json",
            "Content-Type": "multipart/form-data",
          },
        ),
        onSendProgress: (sent, total) {
          if (total > 0) {
            setState(() {
              _uploadProgress = sent / total;
            });
          }
        },
      );

      // --- REPLACE your old success/error handling with this block ---
      if (response.statusCode == 200 || response.statusCode == 201) {
        final respData = response.data;
        final statusStr =
            (respData is Map && respData['status'] != null)
                ? respData['status'].toString()
                : null;

        final message =
            (respData is Map && respData['message'] != null)
                ? respData['message'].toString()
                : 'Details updated successfully.';

        final bool success =
            (statusStr != null &&
                (statusStr.toLowerCase() == 'success' ||
                    statusStr.toLowerCase() == 'ok' ||
                    statusStr.toLowerCase() == '1' ||
                    statusStr.toLowerCase() == 'true'));

        // show polished sheet (auto-dismiss) and fallback SnackBar
        try {
          await _showResultSheet(success: success, message: message);
        } catch (_) {
          // fallback to plain snackbar if sheet fails
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Row(
                children: [
                  Icon(
                    success ? Icons.check_circle : Icons.error,
                    color: Colors.white,
                  ),
                  const SizedBox(width: 8),
                  Expanded(child: Text(message)),
                ],
              ),
              backgroundColor: success ? Colors.green : Colors.redAccent,
              duration: const Duration(seconds: 3),
            ),
          );

        }



        // clear and refresh
        await _clearSavedFile();
        _remarkController.clear();
        await _fetchDetails(showLoading: false);

        if (!_dirty) {
          setState(() => _dirty = true);
        }

      } else {
        final String msg =
            response.data != null && response.data['message'] != null
                ? response.data['message'].toString()
                : 'Server returned ${response.statusCode}';
        await _showResultSheet(success: false, message: 'Submit failed: $msg');
      }
    } catch (e) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Submit error: $e')));
    } finally {
      setState(() {
        _submitting = false;
        _uploading = false;
        _uploadProgress = 0.0;
      });
    }
  }

  /// Shows a polished bottom sheet for success/error with auto-dismiss.
  Future<void> _showResultSheet({
    required bool success,
    required String message,
  }) async {
    if (!mounted) return;

    final color = success ? Colors.green : Colors.redAccent;
    final icon = success ? Icons.check_circle_outline : Icons.error_outline;
    final Completer<void> completer = Completer<void>();
    showModalBottomSheet(
      context: context,
      isDismissible: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black26,
      builder: (c) {
        Future.delayed(const Duration(milliseconds: 2200)).then((_) {
          if (mounted && !completer.isCompleted) {
            Navigator.of(c).maybePop();
            completer.complete();
          }
        });

        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8),
            child: Container(
              decoration: BoxDecoration(
                color: Theme.of(context).cardColor,
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.08),
                    blurRadius: 12,
                  ),
                ],
              ),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: color.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(icon, color: color, size: 28),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          success ? 'Success' : 'Error',
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: Colors.grey.shade800,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          message,
                          style: TextStyle(color: Colors.grey.shade700),
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: 'Dismiss',
                    onPressed: () {
                      if (Navigator.of(context).canPop())
                        Navigator.of(context).pop();
                      if (!completer.isCompleted) completer.complete();
                    },
                    icon: Icon(Icons.close, color: Colors.grey.shade600),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );

    return completer.future;
  }

  Future<void> _pickFileAndSave() async {
    try {
      final fp = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['jpg', 'jpeg', 'png', 'pdf', 'doc', 'docx', 'xlsx'],
        allowMultiple: false,
        withData: false,
      );
      if (fp == null) return;

      final picked = fp.files.single;
      final filePath = picked.path;
      if (filePath == null) return;

      final size = picked.size;
      const maxBytes = 100 * 1024 * 1024; // 4MB limit
      if (size > maxBytes) {
        // ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('File too large. Max allowed 4 MB.')));

        Fluttertoast.showToast(
          msg: "File too large. Max allowed 100 MB.",
          toastLength: Toast.LENGTH_SHORT,
          gravity: ToastGravity.BOTTOM,
          backgroundColor: Colors.redAccent.shade200,
          textColor: Colors.white,
          fontSize: 14.0,
        );
        return;
      }

      await _savePickedFileToPrefs(filePath);
      setState(() {
        _savedFileSizeBytes = size;
      });

      // ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('File saved for upload: ${picked.name}')));
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('File pick error: $e')));
    }
  }


  Future<void> _openFilePreview(dynamic f) async {
    try {
      if (f == null) return;

      String url = '';
      String name = '';

      if (f is String) {
        url = f;
      } else if (f is Map) {
        url = (f['url'] ?? f['path'] ?? '').toString();
        name = (f['name'] ?? f['file_name'] ?? f['title'] ?? '').toString();
      } else {
        return;
      }

      if (url.isEmpty) {
        // ScaffoldMessenger.of(context).showSnackBar(
        //   const SnackBar(content: Text('No URL available for this file')),
        // );

        Fluttertoast.showToast(
          msg: "No URL available for this file.",
          toastLength: Toast.LENGTH_SHORT,
          gravity: ToastGravity.BOTTOM,
          backgroundColor: Colors.redAccent.shade200,
          textColor: Colors.white,
          fontSize: 14.0,
        );

        return;
      }

      // Make sure url is absolute. If your backend sometimes returns relative paths,
      // prepend domain or slug here (example below uses _details domain if you saved it)
      if (!url.startsWith('http')) {
        // Try to build an absolute URL - adapt to your app's base domain:
        // final domain = 'https://cadesk.net'; // or get from prefs
        // url = domain + (url.startsWith('/') ? url : '/$url');
      }

      // infer a name
      if (name.isEmpty) {
        final parsed = Uri.tryParse(url);
        if (parsed != null && parsed.pathSegments.isNotEmpty) {
          name = parsed.pathSegments.last;
        } else {
          name = 'file_${DateTime.now().millisecondsSinceEpoch}';
        }
      }

      final lower = url.toLowerCase();
      final bool isImage =
          lower.endsWith('.png') ||
          lower.endsWith('.jpg') ||
          lower.endsWith('.jpeg') ||
          lower.endsWith('.webp') ||
          lower.endsWith('.gif');
      final bool isPdf = lower.endsWith('.pdf');

      if (isImage) {
        // Image preview in draggable sheet
        await showModalBottomSheet(
          context: context,
          isScrollControlled: true,
          backgroundColor: Colors.transparent,
          builder: (c) {
            return DraggableScrollableSheet(
              expand: false,
              initialChildSize: 0.85,
              minChildSize: 0.4,
              maxChildSize: 0.95,
              builder: (ctx, sc) {
                return Container(
                  decoration: BoxDecoration(
                    color: Theme.of(context).canvasColor,
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(16),
                    ),
                  ),
                  child: Column(
                    children: [
                      // header
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12.0,
                          vertical: 10,
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                name.isNotEmpty ? name : 'Image Preview',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),

                            IconButton(
                              icon: const Icon(Icons.close),
                              onPressed: () => Navigator.of(ctx).pop(),
                            ),
                          ],
                        ),
                      ),
                      const Divider(height: 1),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.all(12.0),
                          child: InteractiveViewer(
                            panEnabled: true,
                            child: Center(
                              child: Image.network(
                                url,
                                loadingBuilder: (context, child, progress) {
                                  if (progress == null) return child;
                                  final p =
                                      (progress.cumulativeBytesLoaded /
                                          (progress.expectedTotalBytes ?? 1));
                                  return Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      CircularProgressIndicator(value: p),
                                      const SizedBox(height: 12),
                                      Text('${(p * 100).toStringAsFixed(0)}%'),
                                    ],
                                  );
                                },
                                errorBuilder:
                                    (_, __, ___) => Container(
                                      padding: const EdgeInsets.all(24),
                                      child: const Text('Unable to load image'),
                                    ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            );
          },
        );
        return;
      }

      if (isPdf) {
        // PDF preview sheet (uses your _PdfPreviewSheet widget)
        await showModalBottomSheet(
          context: context,
          isScrollControlled: true,
          backgroundColor: Colors.transparent,
          builder: (c) {
            return DraggableScrollableSheet(
              expand: false,
              initialChildSize: 0.95,
              minChildSize: 0.4,
              maxChildSize: 0.99,
              builder: (ctx, sc) {
                return _PdfPreviewSheet(url: url, name: name, dio: _dio);
              },
            );
          },
        );
        return;
      }

      // For other file types (xlsx, docx, csv, etc.) first try opening the URL in external app/browser.
      final uri = Uri.tryParse(url);
      if (uri != null) {
        // try launch in external application (browser)
        final launched =
            await canLaunchUrl(uri)
                ? await launchUrl(uri, mode: LaunchMode.externalApplication)
                : false;

        if (launched == true) {
          return;
        }
      }

      // if launch failed or not possible, download file to temp and open it
      // show a SnackBar so user sees something is happening
      final sb = ScaffoldMessenger.of(context);
      final snack = sb.showSnackBar(
        SnackBar(
          content: Text('Downloading ${name}...'),
          duration: const Duration(days: 1),
        ),
      );

      final ok = await _downloadAndOpen(url, suggestedName: name);

      // remove the long-lived snack bar
      snack.close();

      if (!ok) {
        Fluttertoast.showToast(
          msg: "Cannot open file URL",
          toastLength: Toast.LENGTH_SHORT,
          gravity: ToastGravity.BOTTOM,
          backgroundColor: Colors.redAccent.shade200,
          textColor: Colors.white,
          fontSize: 14.0,
        );

      }
    } catch (e) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Preview error: $e')));
    }
  }

  Future<bool> _downloadAndOpen(String url, {String? suggestedName}) async {
    try {
      final uri = Uri.parse(url);

      final res = await _dio.get<List<int>>(
        url,
        options: Options(
          responseType: ResponseType.bytes,
          followRedirects: true,
          validateStatus: (s) => s! < 500,
        ),
        onReceiveProgress: (received, total) {
          // Optional: update a state progress var and show a progress indicator
          // if (total > 0 && mounted) setState(() => _downloadProgress = received/total);
        },
      );

      if (res.statusCode == 200 && res.data != null) {
        final bytes =
            res.data is Uint8List
                ? res.data as Uint8List
                : Uint8List.fromList(List<int>.from(res.data!));

        final dir = await getTemporaryDirectory();

        // IMPORTANT: parenthesize ternary when used with ??
        final inferredName =
            uri.pathSegments.isNotEmpty
                ? uri.pathSegments.last
                : 'download_${DateTime.now().millisecondsSinceEpoch}';
        final rawName = suggestedName ?? inferredName;

        // sanitize filename: remove characters that can break paths
        final fileName = rawName.replaceAll(
          RegExp(r'[<>:"/\\|?*\x00-\x1F]'),
          '_',
        );

        final filePath = '${dir.path}/$fileName';
        final file = File(filePath);

        await file.writeAsBytes(bytes, flush: true);

        // Open with platform handler
        final result = await OpenFile.open(file.path);

        // Optionally check result.type / result.message. We'll treat open attempt as success.
        return true;
      } else {
        return false;
      }
    } catch (e) {
      debugPrint('Download/open error: $e');
      return false;
    }
  }


  // skeleton UI while loading
  Widget _loadingSkeleton() {
    Widget skeletonCard() {
      return Card(
        margin: const EdgeInsets.only(bottom: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(height: 16, width: 180, color: Colors.grey.shade200),
              const SizedBox(height: 12),
              Row(
                children: [
                  Container(height: 12, width: 80, color: Colors.grey.shade200),
                  const SizedBox(width: 8),
                  Container(height: 12, width: 80, color: Colors.grey.shade200),
                ],
              ),
              const SizedBox(height: 12),
              Container(
                height: 8,
                width: double.infinity,
                color: Colors.grey.shade100,
              ),
              const SizedBox(height: 8),
              Container(
                height: 8,
                width: double.infinity,
                color: Colors.grey.shade100,
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      );
    }

    return Column(children: [skeletonCard(), skeletonCard(), skeletonCard()]);
  }

  Widget _card({required Widget child}) {
    return FadeTransition(
      opacity: _fade,
      child: Card(
        color: Colors.white,
        margin: const EdgeInsets.only(bottom: 8),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
        elevation: 1,
        child: Padding(padding: const EdgeInsets.all(6), child: child),
      ),
    );
  }
  // status color helper (updated)
  // status color helper (updated)
  Color _statusColor(String label) {
    final s = label.toLowerCase();
    if (s.contains('new') || s.contains('new sr'))
      return const Color(0xFF3B7080); // #3B7080
    if (s.contains('pending')) return const Color(0xFFF26522); // #F26522
    if (s.contains('in progress') || s.contains('inprogress'))
      return const Color(0xFFBC8E04); // #FFC107
    if (s.contains('extend') || s.contains('extended'))
      return const Color(0xFF1B84FF); // #1B84FF
    if (s.contains('completed')) return const Color(0xFF03C95A); // #03C95A
    return Colors.grey;
  }



  Color _priorityColor(String p) {
    switch (p.toLowerCase()) {
      case 'high':
        return const Color(0xFFE70D0D); // #E70D0D
      case 'medium':
        return const Color(0xFFBC8E04); // #FFC107
      case 'low':
      default:
        return const Color(0xFF03C95A); // #03C95A
    }
  }

  bool _descExpanded = false; // when true show full description dialog


  Widget _headerCard() {
    // defensive extraction
    final status = (_details['status'] ?? '').toString();
    final category = (_details['category'] ?? '').toString();
    final title = (_details['title'] ?? '').toString();
    final description = (_details['description'] ?? '').toString();
    final taskType = (_details['task_type'] ?? '').toString();

    // local constants / styles
    final double borderRadius = 10.0;
    final double leftStripWidth = _s(4, 1.0);
    final titleStyle = TextStyle(fontSize: _s(16, 1.0), fontWeight: FontWeight.w600);
    final descStyle = TextStyle(fontSize: _s(14, 1.0), fontWeight: FontWeight.w400, color: Colors.grey.shade800);

    bool _textExceeds(String text, TextStyle style, int maxLines, double maxWidth) {
      try {
        if (text.trim().isEmpty) return false;
        final tp = TextPainter(
          text: TextSpan(text: text, style: style),
          maxLines: maxLines,
          textDirection: TextDirection.ltr,
        );
        tp.layout(minWidth: 0, maxWidth: maxWidth);
        return tp.didExceedMaxLines;
      } catch (_) {
        return false;
      }
    }

    Color _typeColorSafe(dynamic type) {
      final t = (type?.toString() ?? '').trim().toLowerCase();
      if (t.contains('task')) return const Color(0xFF8E8E8E);
      if (t.contains('service') || t.contains('service request')) return const Color(0xFFF8790C);
      if (t.contains('invoice')) return const Color(0xFF2E86AB);
      return Colors.grey.shade700;
    }

    // Build card content as a Stack so the left strip is always visible (positioned)
    final cardInner = ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: Stack(
        children: [
          // Left colored strip (positioned)
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            child: Container(
              width: leftStripWidth,
              color: _typeColorSafe(taskType),
            ),
          ),

          // Main content — padded on the left to make room for the strip
          Padding(
            // ensure we leave space equal to leftStripWidth + some gap
            padding: EdgeInsets.fromLTRB(leftStripWidth + _s(8, 1.0), _s(8, 1.0), _s(8, 1.0), _s(8, 1.0)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Top row: icon + category + chips
                Row(
                  children: [
                    const Icon(Icons.category, size: 14, color: Colors.grey),
                    SizedBox(width: _s(6, 1.0)),

                    // Category area — safe LayoutBuilder
                    Expanded(
                      child: LayoutBuilder(builder: (context, constraints) {
                        // if (constraints.maxWidth <= 0) {
                        return Text(
                          category.isNotEmpty ? category : '-',
                          style: TextStyle(fontSize: _s(12, 1.0), color: Colors.black87),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        );
                        // }

                        // return AutoScrollingText(
                        //   text: category.isNotEmpty ? category : '-',
                        //   style: TextStyle(fontSize: _s(14, 1.0), color: Colors.black87),
                        //   pixelsPerSecond: 40,
                        //   leadingGap: 20.0,
                        // );
                      }),
                    ),

                    SizedBox(width: _s(8, 1.0)),

                    // small chips: priority/status
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Container(
                          padding: EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(5),
                            border: Border.all(color: _statusColor(status).withOpacity(0.12)),
                          ),
                          child: Text(
                            status.isNotEmpty ? status[0].toUpperCase() : '',
                            style: TextStyle(color: _statusColor(status), fontWeight: FontWeight.w500),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),

                SizedBox(height: _s(8, 1.0)),

                // Title
                Text(
                  title.isNotEmpty ? title : '-',
                  style: titleStyle,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),

                SizedBox(height: _s(6, 1.0)),

                // Description area — measure to decide whether to show "read more" toggle
                LayoutBuilder(builder: (context, constraints) {
                  final double contentWidth = constraints.maxWidth;
                  final int titleMaxLines = 3;
                  final int descMaxLines = 3;

                  final bool titleOverflow = _textExceeds(title, titleStyle, titleMaxLines, contentWidth);
                  final bool descOverflow = _textExceeds(description, descStyle, descMaxLines, contentWidth);
                  final bool needReadMore = titleOverflow || descOverflow;

                  if (description.trim().isEmpty) {
                    return const SizedBox.shrink();
                  }

                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (needReadMore)
                        AnimatedCrossFade(
                          firstChild: GestureDetector(
                            onTap: () => setState(() => _descExpanded = true),
                            child: Text(description, style: descStyle, maxLines: descMaxLines, overflow: TextOverflow.ellipsis),
                          ),
                          secondChild: GestureDetector(
                            onTap: () => setState(() => _descExpanded = false),
                            child: Text(description, style: descStyle),
                          ),
                          crossFadeState: _descExpanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
                          duration: const Duration(milliseconds: 240),
                        )
                      else
                        Text(description, style: descStyle),

                      if (needReadMore) ...[
                        SizedBox(height: _s(4, 1.0)),
                        Row(
                          children: [
                            Expanded(
                              child: Center(
                                child: InkWell(
                                  onTap: () => setState(() => _descExpanded = !_descExpanded),
                                  borderRadius: BorderRadius.circular(10),
                                  child: Container(
                                    padding: const EdgeInsets.all(0),
                                    decoration: const BoxDecoration(shape: BoxShape.circle),
                                    child: Icon(_descExpanded ? Icons.expand_less : Icons.expand_more, size: 20, color: _primaryPurple),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  );
                }),
              ],
            ),
          ),
        ],
      ),
    );

    // Wrap cardInner in your _card() so external styling remains consistent.
    // If your _card() already adds rounded corners, you can call it directly.
    // Here we call _card and place cardInner as its child (assuming _card doesn't clip).
    return _card(child: cardInner);
  }



  Widget _headerCardFor(Map<String, dynamic>? details) {
    final d =  _details ?? <String, dynamic>{};

    final status = (d['status'] ?? '').toString();
    final category = (d['category'] ?? '').toString();
    final title = (d['title'] ?? '').toString();
    final description = (d['description'] ?? '').toString();
    final taskType = (d['task_type'] ?? '').toString();

    final double borderRadius = 8.0;
    final double leftStripWidth = _s(4, 1.0);
    final titleStyle = TextStyle(fontSize: _s(16, 1.0), fontWeight: FontWeight.w600);
    final descStyle = TextStyle(fontSize: _s(14, 1.0), fontWeight: FontWeight.w400, color: Colors.grey.shade800);

    Color _typeColorSafe(dynamic type) {
      final t = (type?.toString() ?? '').trim().toLowerCase();
      if (t.contains('task')) return const Color(0xFF8E8E8E);
      if (t.contains('service') || t.contains('service request')) return const Color(0xFFF8790C);
      if (t.contains('invoice')) return const Color(0xFF2E86AB);
      return Colors.grey.shade700;
    }

    bool _textExceeds(String text, TextStyle style, int maxLines, double maxWidth) {
      try {
        if (text.trim().isEmpty) return false;
        final tp = TextPainter(
          text: TextSpan(text: text, style: style),
          maxLines: maxLines,
          textDirection: TextDirection.ltr,
        );
        tp.layout(minWidth: 0, maxWidth: maxWidth);
        return tp.didExceedMaxLines;
      } catch (_) {
        return false;
      }
    }

    return Container(

      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(borderRadius),

        // 👇 Add subtle shadow similar to Flutter's default Card
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.08), // soft shadow
            blurRadius: 8,                         // how much it spreads
            offset: const Offset(0, 4),            // shadow position (x, y)
          ),
          BoxShadow(
            color: Colors.black.withOpacity(0.03),
            blurRadius: 2,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      margin: EdgeInsets.symmetric( vertical: _s(4, 1.0)),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: Stack(
          children: [
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              child: Container(width: leftStripWidth, color: _typeColorSafe(taskType)),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(leftStripWidth + _s(8, 1.0), _s(8, 1.0), _s(8, 1.0), _s(8, 1.0)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.category, size: 14, color: Colors.grey),
                      SizedBox(width: _s(6, 1.0)),
                      Expanded(
                        child: LayoutBuilder(builder: (context, constraints) {
                          if (constraints.maxWidth <= 0) {
                            return Text(
                              category.isNotEmpty ? category : '-',
                              style: TextStyle(fontSize: _s(12, 1.0), color: Colors.black87),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            );
                          }
                          return AutoScrollingText(
                            text: category.isNotEmpty ? category : '-',
                            style: TextStyle(fontSize: _s(14, 1.0), color: Colors.black87),
                            pixelsPerSecond: 40,
                            leadingGap: 20.0,
                          );
                        }),
                      ),
                      SizedBox(width: _s(8, 1.0)),
                      Container(
                        padding: EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(5),
                          border: Border.all(color: _statusColor(status).withOpacity(0.12)),
                        ),
                        child: Text(
                          // status.isNotEmpty ? status[0].toUpperCase() : '',
                          status.isNotEmpty ? status : '',
                          style: TextStyle(color: _statusColor(status), fontWeight: FontWeight.w500 , fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: _s(8, 1.0)),
                  Text(
                    title.isNotEmpty ? title : '-',
                    style: titleStyle,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                  SizedBox(height: _s(6, 1.0)),
                  LayoutBuilder(builder: (context, constraints) {
                    final double contentWidth = constraints.maxWidth;
                    final bool titleOverflow = _textExceeds(title, titleStyle, 3, contentWidth);
                    final bool descOverflow = _textExceeds(description, descStyle, 3, contentWidth);
                    final bool needReadMore = titleOverflow || descOverflow;
                    if (description.trim().isEmpty) return const SizedBox.shrink();
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (needReadMore)
                          AnimatedCrossFade(
                            firstChild: GestureDetector(
                              onTap: () => setState(() => _descExpanded = true),
                              child: Text(
                                description,
                                style: descStyle,
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            secondChild: GestureDetector(
                              onTap: () => setState(() => _descExpanded = false),
                              child: Text(description, style: descStyle),
                            ),
                            crossFadeState: _descExpanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
                            duration: const Duration(milliseconds: 240),
                          )
                        else
                          Text(description, style: descStyle),
                        if (needReadMore) ...[
                          SizedBox(height: _s(4, 1.0)),
                          Center(
                            child: InkWell(
                              onTap: () => setState(() => _descExpanded = !_descExpanded),
                              borderRadius: BorderRadius.circular(10),
                              child: Container(
                                padding: const EdgeInsets.all(0),
                                decoration: const BoxDecoration(shape: BoxShape.circle),
                                child: Icon(
                                  _descExpanded ? Icons.expand_less : Icons.expand_more,
                                  size: 20,
                                  color: _primaryPurple,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ],
                    );
                  }),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }


  Widget buildPageContentForIndex(int index) {
    final item = _cacheList[index] as Map<String, dynamic>? ?? <String, dynamic>{};
    final String id = (item['id'] ?? '').toString();

    // Try cached details first
    final Map<String, dynamic>? cached = _getCachedDetails(id);

    // If cached present, mirror to in-memory and render
    if (cached != null) {
      _detailsById[id] = cached;
      if (index == _currentIndex) {
        // ensure dependent widgets rebuild with this details
        if (mounted) setState(() {
          _details = cached;
        });
      }
      return _buildPageFromDetails(cached, index);
    }


    // Not cached:
    // If this is active page, start fetching now (if not already)
    if (index == _currentIndex) {
      if (!_fetchingIds.contains(id)) {
        // fetch and cache in background, and rebuild when done
        _fetchAndCache(id).whenComplete(() {
          if (mounted) setState(() {});
        });
      }
      // show skeleton for active page while waiting
      return _loadingSkeleton();
    }

    // For non-active pages that are uncached, show blank
    return Container(color: Colors.white);
  }
  Widget _buildPageFromDetails(Map<String, dynamic> details, int index) {
    final leftColumn = KeepAliveWidget(
      keepKey: PageStorageKey('left-col-${details['id'] ?? index}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _headerCardFor(details),
          _detailsCard(),
          _actionsCard(),
        ],
      ),
    );

    final rightColumn = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _historyCard(),
        const SizedBox(height: 24),
      ],
    );

    final width = MediaQuery.of(context).size.width;
    final bool isTablet = width >= 800;

    return RefreshIndicator(
      onRefresh: () => _fetchDetails(showLoading: false),
      child: LayoutBuilder(
        builder: (context, constraints) {
          return SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(12),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: isTablet
                  ? Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 360, minWidth: 280),
                    child: leftColumn,
                  ),
                  const SizedBox(width: 12),
                  Expanded(child: rightColumn),
                ],
              )
                  : Column(
                children: [
                  leftColumn,
                  const SizedBox(height: 8),
                  rightColumn,
                  const SizedBox(height: 80),
                ],
              ),
            ),
          );
        },
      ),
    );
  }




  Widget _assignedAvatars(BuildContext context, List<Map<String, String>> assigned, int maxInlineAvatars) {
    return InkWell(
      onTap: assigned.isEmpty ? null : () => _showAssignedUsersModal(context, assigned),
      borderRadius: BorderRadius.circular(20),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (assigned.isEmpty)
            Text(' ', style: TextStyle(color: Colors.grey.shade600, fontSize: 13))
          else ...[
            ...List.generate(
              (assigned.length > maxInlineAvatars ? maxInlineAvatars : assigned.length),
                  (idx) {
                final bool isOverflowSlot =
                    assigned.length > maxInlineAvatars && idx == (maxInlineAvatars - 1);
                if (isOverflowSlot) {
                  final remaining = assigned.length - (maxInlineAvatars - 1);
                  return Container(
                    margin: EdgeInsets.only(left: 6),
                    width: 30,
                    height:30,
                    decoration: BoxDecoration(
                        color: Colors.grey.shade200,
                        borderRadius: BorderRadius.circular(16)),
                    child: Center(
                      child: Text(
                        '+$remaining',
                        style: TextStyle(
                            color: Colors.grey.shade800,
                            fontWeight: FontWeight.w600,
                            fontSize: 12),
                      ),
                    ),
                  );
                }

                final au = assigned[idx];
                final aname = (au['name'] ?? '').toString();
                final aprofile = (au['profile'] ?? '').toString();
                return Container(
                  margin: EdgeInsets.only(left: 6),
                  child: CircleAvatar(
                    radius: 16,
                    backgroundImage: aprofile.isNotEmpty ? NetworkImage(aprofile) : null,
                    backgroundColor: aprofile.isEmpty ? Colors.grey.shade400 : Colors.transparent,
                    child: aprofile.isEmpty
                        ? Text(
                      aname.isNotEmpty ? aname[0].toUpperCase() : '?',
                      style: TextStyle(
                          color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12),
                    )
                        : null,
                  ),
                );
              },
            ),
          ],
        ],
      ),
    );
  }

  /// Shows a bottom sheet listing all assigned users (image + name).
  Future<void> _showAssignedUsersModal(BuildContext context, List<Map<String, String>> assigned) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (c) {
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.45,
          minChildSize: 0.2,
          maxChildSize: 0.9,
          builder: (ctx, sc) {
            return Container(
              decoration: BoxDecoration(color: Theme.of(context).canvasColor, borderRadius: const BorderRadius.vertical(top: Radius.circular(16))),
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14.0, vertical: 12),
                    child: Row(
                      children: [
                        const Expanded(child: Text('Assigned Users', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16))),
                        IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.of(ctx).pop()),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: ListView.separated(
                      controller: sc,
                      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                      itemCount: assigned.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (_, i) {
                        final u = assigned[i];
                        final name = (u['name'] ?? '').toString();
                        final profile = (u['profile'] ?? '').toString();
                        return ListTile(
                          leading: CircleAvatar(
                            radius: 20,
                            backgroundImage: profile.isNotEmpty ? NetworkImage(profile) : null,
                            backgroundColor: profile.isEmpty ? Colors.grey.shade300 : Colors.transparent,
                            child: profile.isEmpty ? Text(name.isNotEmpty ? name[0].toUpperCase() : '?') : null,
                          ),
                          title: Text(name.isNotEmpty ? name : '-'),
                          // subtitle: Text(u['id'] ?? ''),
                          onTap: () {
                            // optionally navigate to user details or copy id
                          },
                        );
                      },
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _detailsCard() {
    String startDate = (_details['startDate'] ?? '-').toString();
    String endDate = (('${_details['endDate'] ?? ''} ${_details['deadline'] ?? ''}').trim().isEmpty)
        ? '-'
        : ('${_details['endDate'] ?? ''} ${_details['deadline'] ?? ''}').trim();
    String extendDateTime = (('${_details['extendDate'] ?? ''} ${_details['extendTime'] ?? ''}').trim().isEmpty)
        ? ''
        : ('${_details['extendDate'] ?? ''} ${_details['extendTime'] ?? ''}').trim();

    Widget dateItem(IconData icon, String label, String value, Color iconColor) {
      return Expanded(
        child: Row(
          children: [
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(icon, size: 15, color: iconColor),
                      const SizedBox(width: 8),
                      Text(label, style: const TextStyle(fontSize: 13, color: Colors.black54)),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    softWrap: false,
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    // choose colors based on presence / type
    final Color startIconColor = Colors.orange.shade700;

    final Color endIconColor = (endDate != '-' ? Colors.blue.shade700 : Colors.blue.shade500);


    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // single row containing start & end date items
          Row(
            children: [
              dateItem(Icons.calendar_month_outlined, 'Start', startDate, startIconColor),
              const SizedBox(width: 12),
              dateItem(Icons.calendar_month_outlined, 'End', endDate,  endIconColor),
            ],
          ),
        ],
      ),
    );
  }

// --- open sheet ---
  void _openUserSearchSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) {
        final TextEditingController searchCtrl = TextEditingController();
        List<Map<String, dynamic>> filtered = List.from(_reassignOptions);
        final FocusNode searchFocus = FocusNode();

        // request focus after the sheet opens
        Future.delayed(const Duration(milliseconds: 250), () {
          if (searchFocus.canRequestFocus) searchFocus.requestFocus();
        });

        return StatefulBuilder(
          builder: (context, setModalState) => Padding(
            padding: EdgeInsets.only(
              left: 16,
              right: 16,
              top: 50,
              bottom: MediaQuery.of(context).viewInsets.bottom + 16,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Search + Cancel row
                Row(
                  children: [
                    // Search field (auto-focused)
                    Expanded(
                      child: TextField(
                        autofocus: true,
                        // focusNode: searchFocus,
                        controller: searchCtrl,
                        decoration: InputDecoration(
                          hintText: 'Search user...',
                          prefixIcon: const Icon(Icons.search),
                          contentPadding: const EdgeInsets.symmetric(
                              vertical: 12, horizontal: 12),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                        onChanged: (q) {
                          setModalState(() {
                            filtered = _reassignOptions
                                .where((u) => u['name']
                                .toString()
                                .toLowerCase()
                                .contains(q.toLowerCase()))
                                .toList();
                          });
                        },
                      ),
                    ),

                    const SizedBox(width: 8),

                    // Cancel icon button
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.black54),
                      tooltip: 'Cancel',
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),

                const SizedBox(height: 6),

                // Reduced-spacing list
                Expanded(
                  child: ListView.separated(
                    itemCount: filtered.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      final u = filtered[i];
                      return ListTile(
                        dense: true, // reduces vertical height
                        visualDensity: const VisualDensity(vertical: -3), // tighter
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 3),
                        title: Text(
                          u['name'].toString(),
                          style: const TextStyle(height: 1.0), // tighter line height
                        ),
                        onTap: () {
                          setState(() => _reassign = u['id'].toString());
                          Navigator.pop(context);
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }



  // Actions card now includes: Status, Reassign, remark textarea, file upload, submit
  Widget _actionsCard() {
      final bool isExtend = _status.toLowerCase().contains('extend');
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // const Text('Actions', style: TextStyle(fontWeight: FontWeight.bold)),
          // const SizedBox(height: 12),

          // remark textarea
          TextFormField(
            controller: _remarkController,
            maxLines: 2,
            maxLength: 150,
            decoration: InputDecoration(
              labelText: 'Add Remark',
              hintText: 'Enter your remark here...',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
          const SizedBox(height: 8),

          DropdownButtonFormField<String>(
            decoration: InputDecoration(
              labelText: 'Status',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            value: (_status != null && _statusOptions.contains(_status)) ? _status : null,
            items: _statusOptions
                .map((s) => DropdownMenuItem(value: s, child: Text(s)))
                .toList(),
            onChanged: (v) => setState(() => _status = v!),
          ),

          const SizedBox(height: 8),


          // --- read-only display field that reflects selection ---
          GestureDetector(
            onTap: () => _openUserSearchSheet(context),
            child: AbsorbPointer(
              child: TextFormField(
                decoration: InputDecoration(
                  labelText: 'Assign To',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                // compare ids as strings so it matches whatever type _reassign holds
                controller: TextEditingController(
                  text: _reassignOptions
                      .firstWhere(
                        (u) => u['id'].toString() == (_reassign ?? ''),
                    orElse: () => {'name': 'Select user'},
                  )['name']
                      ?.toString() ??
                      '',
                ),
              ),
            ),
          ),

          const SizedBox(height: 8),

          // Extend date/time pickers (shown when status == Extend)
          if (isExtend) ...[
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _extendDateController,
                    readOnly: true,
                    decoration: InputDecoration(
                      labelText: 'Extend Date',
                      hintText: 'Select date',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      suffixIcon: const Icon(Icons.calendar_today),
                    ),
                    onTap: () async {
                      final now = DateTime.now();
                      final initial =
                          _extendDate ?? now.add(const Duration(days: 1));
                      final picked = await showDatePicker(
                        context: context,
                        initialDate: initial.isBefore(now) ? now : initial,
                        firstDate: DateTime(now.year, now.month, now.day),
                        lastDate: DateTime(now.year + 1, now.month, now.day),
                      );
                      if (picked != null) {
                        setState(() {
                          _extendDate = picked;
                          _extendDateController.text = _formatDate(picked);

                          // If user has already picked a time and the date is today,
                          // ensure the time is not in the past — if it is, update to now.
                          if (_extendTime != null) {
                            final selectedDt = DateTime(
                              picked.year,
                              picked.month,
                              picked.day,
                              _extendTime!.hour,
                              _extendTime!.minute,
                            );
                            final nowDt = DateTime.now();

                            if (selectedDt.isBefore(nowDt)) {
                              // pick current time
                              final nowTime = TimeOfDay.fromDateTime(nowDt);
                              _extendTime = nowTime;
                              _extendTimeController.text = _formatTime(nowTime);

                              Fluttertoast.showToast(
                                msg: "Selected time was in the past — adjusted to current time.",
                                toastLength: Toast.LENGTH_SHORT,
                                gravity: ToastGravity.BOTTOM,
                                backgroundColor: Colors.redAccent,
                                textColor: Colors.white,
                                fontSize: 14.0,
                              );
                            }


                          }
                        });
                      }
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextFormField(
                    controller: _extendTimeController,
                    readOnly: true,
                    decoration: InputDecoration(
                      labelText: 'Extend Time',
                      hintText: 'Select time',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      suffixIcon: const Icon(Icons.access_time),
                    ),
                    onTap: () async {
                      // Choose sensible initial time:
                      final nowDt = DateTime.now();
                      final initialTime =
                          _extendTime ??
                          ((_extendDate != null &&
                                  _isSameDate(_extendDate!, nowDt))
                              ? TimeOfDay.fromDateTime(nowDt)
                              : const TimeOfDay(
                                hour: 9,
                                minute: 0,
                              ) // default for future date
                              );

                      final picked = await showTimePicker(
                        context: context,
                        initialTime: initialTime,
                      );

                      if (picked != null) {
                        setState(() {
                          // Build a DateTime using chosen date (or today if null)
                          final chosenDate = _extendDate ?? DateTime.now();
                          final selectedDt = DateTime(
                            chosenDate.year,
                            chosenDate.month,
                            chosenDate.day,
                            picked.hour,
                            picked.minute,
                          );
                          final now = DateTime.now();

                          // If chosen date is today, ensure selected time isn't in the past.
                          if (_isSameDate(chosenDate, now) && selectedDt.isBefore(now)) {
                            // set to current time instead
                            final nowTime = TimeOfDay.fromDateTime(now);
                            _extendTime = nowTime;
                            _extendTimeController.text = _formatTime(nowTime);

                            Fluttertoast.showToast(
                              msg: "Cannot select a past time — set to current time.",
                              toastLength: Toast.LENGTH_SHORT,
                              gravity: ToastGravity.BOTTOM,
                              backgroundColor: Colors.redAccent.shade200,
                              textColor: Colors.white,
                              fontSize: 14.0,
                            );
                          } else {
                            _extendTime = picked;
                            _extendTimeController.text = _formatTime(picked);
                          }

                        });
                      }
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 5),
          ],


          // const SizedBox(height: 5),
          Row(
            children: [
              // File select button (opens source sheet: camera / gallery / file)
              Flexible(
                child: OutlinedButton.icon(
                  onPressed: _showFileSourceSheet, // <--- show modal to choose source
                  icon: const Icon(Icons.attach_file),
                  label: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Display file name (ellipsized) and optional size next to it
                      Expanded(
                        child: Text(
                          _savedFileName ?? 'Attach File',
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                          softWrap: false,
                        ),
                      ),

                      if (_savedFileSizeBytes != null) ...[
                        const SizedBox(width: 8),
                        Text(
                          '${(_savedFileSizeBytes! / 1024).toStringAsFixed(1)} KB',
                          style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                        ),
                      ],
                    ],
                  ),
                  style: OutlinedButton.styleFrom(
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                ),
              ),

              const SizedBox(height: 6),

              if (_savedFileName != null) ...[
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: _clearSavedFile,
                  child: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade200,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Icon(Icons.clear, size: 16),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 8),

          Text(
            'Supported Documents: Only Jpg, Jpeg, Png, Pdf, Doc,xlsx files are allowed. Max size: 100 MB.',
            style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
          ),
          const SizedBox(height: 2),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ElevatedButton.icon(
                onPressed: _submitting ? null : _submitUpdate,
                icon:
                    _submitting
                        ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                        : const Icon(Icons.send),
                label: const Text('Submit'),
                style: ButtonStyle(
                  shape: WidgetStateProperty.all(
                    RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  backgroundColor: MaterialStateProperty.all(
                    _submitting ? Colors.grey.shade300 : _primaryPurple,
                  ),
                  iconColor: MaterialStateProperty.all(Colors.white),
                  foregroundColor: MaterialStateProperty.all(Colors.white),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  bool _isSameDate(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }



  Future<void> _showFileSourceSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      builder: (BuildContext modalContext) {
        return SafeArea(
          child: Wrap(
            children: [
              ListTile(
                leading: const Icon(Icons.camera_alt),
                title: const Text('Take Photo'),
                onTap: () {
                  Navigator.of(modalContext).pop();
                  _pickFromCamera();
                },
              ),
              ListTile(
                leading: const Icon(Icons.photo_library),
                title: const Text('Choose from Gallery'),
                onTap: () {
                  Navigator.of(modalContext).pop();
                  _pickFromGallery();
                },
              ),
              ListTile(
                leading: const Icon(Icons.insert_drive_file),
                title: const Text('Choose Document'),
                onTap: () {
                  Navigator.of(modalContext).pop();
                  _pickFileAndSave();
                },
              ),
              // ListTile(
              //   leading: const Icon(Icons.close),
              //   title: const Text('Cancel'),
              //   onTap: () => Navigator.of(modalContext).pop(),
              // ),
            ],
          ),
        );
      },
    );
  }



// Replace your existing _savePickedFileToPrefs with this improved version
  Future<void> _savePickedFileToPrefs(String filePath) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) {
        // ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Selected file missing')));

        Fluttertoast.showToast(
          msg: "Selected file missing.",
          toastLength: Toast.LENGTH_SHORT,
          gravity: ToastGravity.BOTTOM,
          backgroundColor: Colors.redAccent.shade200,
          textColor: Colors.white,
          fontSize: 14.0,
        );
        return;
      }

      final name = file.path.split(Platform.pathSeparator).last;
      final size = await file.length();

      // update state first so UI updates immediately
      setState(() {
        _savedFileName = name;
        _savedFilePath = filePath;
        _savedFileSizeBytes = size;
      });

      // persist temporarily so user can resume later
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('pending_upload_path', filePath);
      await prefs.setString('pending_upload_name', name);
      await prefs.setInt('pending_upload_size', size);
    } catch (e) {
      debugPrint('savePickedFile error: $e');
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to save file: $e')));
    }
  }

// Camera picker (image)
  Future<void> _pickFromCamera() async {
    try {
      final XFile? xfile = await _picker.pickImage(
        source: ImageSource.camera,
        maxWidth: 1920,
        maxHeight: 1080,
        imageQuality: 85,
      );
      if (xfile == null) return; // user cancelled

      final file = File(xfile.path);
      final size = await file.length();
      const maxBytes = 100 * 1024 * 1024; // 4MB

      if (size > maxBytes) {
        // ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Photo too large. Max allowed 4 MB.')));
        Fluttertoast.showToast(
          msg: "Photo too large. Max allowed 100 MB.",
          toastLength: Toast.LENGTH_SHORT,
          gravity: ToastGravity.BOTTOM,
          backgroundColor: Colors.redAccent.shade200,
          textColor: Colors.white,
          fontSize: 14.0,
        );

        return;
      }

      await _savePickedFileToPrefs(file.path);
      // ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Photo ready: ${file.path.split(Platform.pathSeparator).last}')));
    } catch (e) {
      debugPrint('Camera pick error: $e');
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Camera error: $e')));
    }
  }

// Gallery picker (image)
  Future<void> _pickFromGallery() async {
    try {
      final XFile? xfile = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1920,
        maxHeight: 1080,
        imageQuality: 85,
      );
      if (xfile == null) return; // user cancelled

      final file = File(xfile.path);
      final size = await file.length();
      const maxBytes = 100 * 1024 * 1024; // 4MB

      if (size > maxBytes) {
        // ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Selected image too large. Max allowed 4 MB.')));

        Fluttertoast.showToast(
          msg: "Selected image too large. Max allowed 100 MB.",
          toastLength: Toast.LENGTH_SHORT,
          gravity: ToastGravity.BOTTOM,
          backgroundColor: Colors.redAccent.shade200,
          textColor: Colors.white,
          fontSize: 14.0,
        );

        return;
      }

      await _savePickedFileToPrefs(file.path);
      // ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Picked: ${file.path.split(Platform.pathSeparator).last}')));
    } catch (e) {
      debugPrint('Gallery pick error: $e');
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Gallery pick error: $e')));
    }
  }



  Widget _historyCard() {
    // local helpers for text measurement / truncation
    bool _textExceedsLines(String text, TextStyle style, int maxLines, double maxWidth) {
      if (text.trim().isEmpty) return false;
      final tp = TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: TextDirection.ltr,
        maxLines: maxLines,
      );
      tp.layout(minWidth: 0, maxWidth: maxWidth);
      return tp.didExceedMaxLines;
    }

    // Handle both list and string formats
    List<String> _extractNames(dynamic value) {
      if (value is List) {
        // when it's a list of maps
        return value
            .map((v) => (v is Map && v['name'] != null) ? v['name'].toString().trim() : v.toString().trim())
            .where((s) => s.isNotEmpty)
            .toList();
      } else if (value is String && value.trim().isNotEmpty) {
        // when it's a comma-separated string
        return value
            .split(',')
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toList();
      } else {
        return <String>[];
      }
    }

    final Set<String> _expandedRemarks = {};
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Task History',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),

          ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: _remarks.length,
            separatorBuilder: (_, __) => Divider(height: 14, color: Colors.grey.shade200),
            itemBuilder: (ctx, i) {
              final r = _remarks[i];
              final remarkId = (r['id'] ?? r['rid'] ?? i).toString();
              final uploadsList = (r['uploads_list'] is List)
                  ? List<Map<String, dynamic>>.from(r['uploads_list'])
                  : <Map<String, dynamic>>[];
              final createdBy = (r['user'] ?? r['created_by'] ?? '').toString().trim();
              final assignedToRaw = (r['assigned_to'] ?? '').toString().trim();
              final datetime = (r['datetime'] ?? '').toString();
              final status = (r['status'] ?? '').toString();
              final remarkText = (r['remarks'] ?? '').toString().trim();


              // assigned names array
              final assignedNames = assignedToRaw.isEmpty
                  ? <String>[]
                  : assignedToRaw.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();

              final headerText = assignedNames.isEmpty
                  ? (createdBy.isNotEmpty ? createdBy : '-')
                  : '${createdBy.isNotEmpty ? createdBy : '-'} assigned to ${assignedNames.join(', ')}';

              final bool expanded = _expandedRemarks.contains(remarkId);

              // styles (compact)
              final titleStyle = const TextStyle(fontWeight: FontWeight.w700, fontSize: 13.0);
              final remarkStyle = TextStyle(fontSize: 10.0, color: Colors.grey.shade800, height: 1.35);
              final metaStyle = TextStyle(fontSize: 11.0, color: Colors.grey.shade600);

              // normalize assigned names for this remark (works with List<Map> or String)
              final List<String> currentAssignedNames = _extractNames(r['assigned_to']);
              final List<String> prevAssignedNames = _extractNames(r['old_assigned']);
              final List<String> first_assignedUsers = _extractNames(r['first_assignedUsers']);

// flags populated earlier in fetchDetails OR derived here
              final bool isCreated = r['is_created'] == true;
              final bool autoAssigned = r['auto_assigned'] == true || (_serviceType == '1'); // fallback
              final String prevStatus = (r['prev_status'] ?? r['previous_status'] ?? '').toString().trim();
              final String currStatus = (r['status'] ?? '').toString().trim();
// keep your existing status logic if you want that global behaviour
              final bool statusChanged = r['status_changed'] == true ||
                  (prevStatus.isNotEmpty && prevStatus != currStatus) ||
                  ((_showSR && currStatus != '1') || (!_showSR && currStatus != '0'));

              final String actionBy = (r['action_by'] ?? r['status_changed_by'] ?? r['updated_by'] ?? r['user'] ?? createdBy).toString().trim();

// Build header spans
              final List<TextSpan> headerSpans = <TextSpan>[];

              if (isCreated) {
                // Always show "Created by X" as the first row
                headerSpans.add(const TextSpan(
                  text: 'Created by ',
                  style: TextStyle(fontWeight: FontWeight.w500, fontSize: 13.0, color: Colors.grey),
                ));
                headerSpans.add(TextSpan(
                  text: createdBy.isNotEmpty ? createdBy : (r['user']?.toString() ?? '-'),
                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.0, color: Colors.black),
                ));


                if (_remarks.length == 1 && currentAssignedNames.isNotEmpty ) {
                  headerSpans.add(TextSpan(
                    text: autoAssigned ? ' is auto assigned to ' : ' assigned to ',
                    style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 13.0, color: Colors.grey),
                  ));
                  headerSpans.add(TextSpan(
                    text: currentAssignedNames.join(', '),
                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.0, color: Colors.black),
                  ));
                }else   if (first_assignedUsers.isNotEmpty ) {
                    headerSpans.add(TextSpan(
                      text: autoAssigned ? ' is auto assigned to ' : ' assigned to ',
                      style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 13.0, color: Colors.grey),
                    ));
                    headerSpans.add(TextSpan(
                      text: first_assignedUsers.join(', '),
                      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.0, color: Colors.black),
                    ));
                  }



                // 🔹 Add status text after assignment or directly if no assigned users
                final String createdStatus = (r['status'] ?? '').toString().trim();
                if (createdStatus.isNotEmpty) {
                  // if status shown after assignment, prefix differently for flow
                  headerSpans.add(TextSpan(
                    text: currentAssignedNames.isNotEmpty
                        ? ' and status set to '
                        : ' with status set to ',
                    style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 13.0, color: Colors.grey),
                  ));
                  headerSpans.add(TextSpan(
                    text: createdStatus,
                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.0, color: Colors.black),
                  ));
                }

                headerSpans.add(const TextSpan(
                  text: '.',
                  style: TextStyle(fontSize: 13.0, color: Colors.grey),
                ));
              } else if (statusChanged) {
                // existing status-change wording (unchanged)
                headerSpans.add(
                  TextSpan(
                    text: actionBy.isNotEmpty ? actionBy : '-',
                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.0, color: Colors.black),
                  ),
                );
                headerSpans.add(
                  const TextSpan(
                    text: ' updated the status to ',
                    style: TextStyle(fontWeight: FontWeight.w500, fontSize: 13.0, color: Colors.grey),
                  ),
                );
                headerSpans.add(
                  TextSpan(
                    text: currStatus.isNotEmpty ? currStatus : '-',
                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.0, color: Colors.black),
                  ),
                );

                // append reassigned clause if assignees changed
                final bool assigneesChanged = prevAssignedNames.join(',') != currentAssignedNames.join(',');
                if (assigneesChanged && currentAssignedNames.isNotEmpty) {
                  headerSpans.add(
                    const TextSpan(
                      text: ' and reassigned to ',
                      style: TextStyle(fontWeight: FontWeight.w500, fontSize: 13.0, color: Colors.grey),
                    ),
                  );
                  headerSpans.add(
                    TextSpan(
                      text: currentAssignedNames.join(', '),
                      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.0, color: Colors.black),
                    ),
                  );
                }

                headerSpans.add(const TextSpan(text: '.', style: TextStyle(fontSize: 13.0, color: Colors.grey)));
              } else if (currentAssignedNames.isNotEmpty) {
                // fallback: show assigned line for non-created rows that carry assigned info
                headerSpans.add(
                  TextSpan(
                    text: createdBy.isNotEmpty ? createdBy : (r['user']?.toString() ?? '-'),
                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.0, color: Colors.black),
                  ),
                );
                headerSpans.add(
                  TextSpan(
                    text: autoAssigned ? ' is auto assigned to ' : ' assigned to ',
                    style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 13.0, color: Colors.grey),
                  ),
                );
                headerSpans.add(
                  TextSpan(
                    text: currentAssignedNames.join(', '),
                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.0, color: Colors.black),
                  ),
                );
                headerSpans.add(const TextSpan(text: '.', style: TextStyle(fontSize: 13.0, color: Colors.grey)));
              } else {
                // default fallback (Created by X.)
                headerSpans.add(
                  TextSpan(
                    text: createdBy.isNotEmpty ? createdBy : (r['user']?.toString() ?? '-'),
                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.0, color: Colors.black),
                  ),
                );
              }

              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                decoration: BoxDecoration(
                  color: Theme.of(context).cardColor,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Top row: header text (left) + status/files/datetime (right)
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [

                        // Render the header with ellipsis if too long (keeps a single line)
                        Expanded(
                          child: RichText(
                            text: TextSpan(children: headerSpans),
                            // maxLines: 2,
                            // overflow: TextOverflow.ellipsis,
                          ),
                        ),

                        // small spacer
                        const SizedBox(width: 2),

                        // files icons
                        if (uploadsList.isNotEmpty) ...[
                          Row(
                            children: [
                              ...List.generate(
                                min(uploadsList.length, 3),
                                    (idx) {
                                  final file = uploadsList[idx];
                                  final name = (file['name'] ?? file['file_name'] ?? '').toString();
                                  return Padding(
                                    padding: const EdgeInsets.only(right: 4.0),
                                    child: InkWell(
                                      borderRadius: BorderRadius.circular(6),
                                      onTap: () => _openFilePreview(file),
                                      child: Tooltip(
                                        message: name,
                                        child: Container(
                                          width: 20,
                                          height: 20,
                                          decoration: BoxDecoration(
                                            color: Colors.grey.shade100,
                                            borderRadius: BorderRadius.circular(6),
                                          ),
                                          child: const Icon(
                                            Icons.insert_drive_file,
                                            size: 18,
                                            color: Colors.black54,
                                          ),
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              ),
                              if (uploadsList.length > 3)
                                Text('+${uploadsList.length - 3}', style: metaStyle),
                            ],
                          ),
                          // const SizedBox(width: 4),
                        ],

                      ],
                    ),

                    // --- replace the whole "Remark text with reliable inline expand/collapse" block ---
                    // Remark text with reliable inline expand/collapse (AnimatedSize + Text maxLines)
                    if (remarkText.isNotEmpty) ...[
                      const SizedBox(height: 3),

                      LayoutBuilder(builder: (c, constraints) {
                        final double maxWidth = constraints.maxWidth;
                        final bool overflows = _textExceedsLines(remarkText, remarkStyle, 3, maxWidth);

                        // stored per-row expand flag (no new state vars)
                        final bool expanded = r['_exp'] == true;
                        final String rk = remarkId; // stable key for this remark

                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // AnimatedSize keeps smooth height animation
                            AnimatedSize(
                              duration: const Duration(milliseconds: 220),
                              curve: Curves.easeInOut,
                              child: overflows
                                  ? AnimatedCrossFade(
                                firstChild: GestureDetector(
                                  key: ValueKey('remark-collapsed-$rk'),
                                  onTap: () {
                                    setState(() => r['_exp'] = true);
                                  },
                                  child: Text(
                                    remarkText,
                                    style: remarkStyle,
                                    maxLines: 3,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                secondChild: GestureDetector(
                                  key: ValueKey('remark-expanded-$rk'),
                                  onTap: () {
                                    setState(() => r['_exp'] = false);
                                  },
                                  child: Text(
                                    remarkText,
                                    style: remarkStyle,
                                  ),
                                ),
                                crossFadeState:
                                expanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
                                duration: const Duration(milliseconds: 180),
                              )
                                  : // no overflow -> plain text (no gestures or icons)
                              Text(
                                remarkText,
                                style: remarkStyle,
                              ),
                            ),

                            // show centered toggle icon only when overflow is true
                            if (overflows) ...[
                              SizedBox(height: 4),
                              Row(
                                children: [
                                  Expanded(
                                    child: Center(
                                      child: InkWell(
                                        onTap: () {
                                          setState(() {
                                            r['_exp'] = !(r['_exp'] == true);
                                          });
                                        },
                                        borderRadius: BorderRadius.circular(12),
                                        child: Container(
                                          padding: const EdgeInsets.all(0),
                                          decoration: const BoxDecoration(shape: BoxShape.circle),
                                          child: Icon(
                                            expanded ? Icons.expand_less : Icons.expand_more,
                                            size: 20,
                                            color: _primaryPurple,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ],
                        );
                      }),
                    ],


                    // small spacer then right-aligned datetime
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        const Expanded(child: SizedBox()), // push date to right
                        Text(datetime, style: metaStyle),
                      ],
                    ),


                    // const SizedBox(height: 3),

                    // Optional: secondary meta row for compact details (if you want to push some things to a second row)
                    // Row(children: [ ... ]),
                  ],
                ),
              );
            },
          ),

        ],
      ),
    );
  }


  /// Call this with server map that contains extendDate and extendTime strings.
  void _applyExtendFromServer(Map<String, dynamic> newDetails) {
    // parse helpers expected in class:
    // DateTime? _parseServerDate(dynamic v)
    // TimeOfDay? _parseServerTime(dynamic v)
    // format helpers: String _formatDate(DateTime), String _formatTime(TimeOfDay)

    final parsedDate = _parseServerDate(newDetails['extendDate']);
    final parsedTime = _parseServerTime(newDetails['extendTime']);

    DateTime? finalDate = parsedDate;
    TimeOfDay? finalTime = parsedTime;

    final now = DateTime.now();
    bool adjusted = false;

    // If server gave a date but it's in the past, clamp it to today (or clear it — choose behavior)
    if (finalDate != null) {
      final today = DateTime(now.year, now.month, now.day);
      if (DateTime(finalDate.year, finalDate.month, finalDate.day).isBefore(today)) {
        // choice: clamp to today (safer), or set to null to force user to re-pick.
        finalDate = today;
        adjusted = true;
      }
    }

    // If we have a time and a date, ensure combined DateTime is not in the past.
    if (finalTime != null && finalDate != null) {
      final candidate = DateTime(finalDate.year, finalDate.month, finalDate.day, finalTime.hour, finalTime.minute);
      if (candidate.isBefore(now)) {
        // if the extend date is today and time is past, choose to set time -> now (rounded to minute)
        if (_isSameDate(finalDate, now)) {
          final nowTime = TimeOfDay.fromDateTime(now);
          finalTime = nowTime;
          adjusted = true;
        } else {
          // date is future but time interpreted as past (unlikely) — keep time, but adjust if needed
          // fallback: clear time so user must re-pick
          finalTime = null;
          adjusted = true;
        }
      }
    }

    // If server gave only time but no date, assume date = today (time-only flow)
    if (finalTime != null && finalDate == null) {
      finalDate = DateTime(now.year, now.month, now.day);
      // ensure time is not in past when assumed date is today
      final candidate = DateTime(finalDate.year, finalDate.month, finalDate.day, finalTime.hour, finalTime.minute);
      if (candidate.isBefore(now)) {
        finalTime = TimeOfDay.fromDateTime(now);
        adjusted = true;
      }
    }

    // Update controllers + state in one setState
    setState(() {
      _extendDate = finalDate;
      _extendTime = finalTime;

      // Update the visible text fields; clear if null
      _extendDateController.text = (finalDate != null) ? _formatDate(finalDate) : '';
      _extendTimeController.text = (finalTime != null) ? _formatTime(finalTime) : '';
    });

    // show a subtle message if we adjusted something
    if (adjusted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Extend date/time adjusted to a valid value.'),
          duration: Duration(seconds: 2),
        ),
      );
      // Fluttertoast.showToast(
      //   msg: "Extend date/time adjusted to a valid value.",
      //   toastLength: Toast.LENGTH_SHORT,
      //   gravity: ToastGravity.BOTTOM,
      //   backgroundColor: Colors.redAccent.shade200,
      //   textColor: Colors.white,
      //   fontSize: 14.0,
      // );
    }
  }


  @override
  Widget build(BuildContext context) {
    final controller = _pageController ??= PageController(initialPage: _currentIndex);
    final width = MediaQuery.of(context).size.width;
    final bool isTablet = width >= 800;
    final priority = _details['priority'];
    const int maxInlineAvatars = 2;

    // Assigned users normalization
    List<Map<String, String>> assigned = [];
    final rawAssigned = _assignedUsers ?? [];
    if (rawAssigned is List) {
      assigned = rawAssigned.map<Map<String, String>>((e) {
        if (e is Map) {
          return {
            'id': (e['id'] ?? e['user_id'] ?? '').toString(),
            'name': (e['name'] ?? e['fullname'] ?? '').toString(),
            'profile': (e['profile'] ?? e['user_profile'] ?? e['userProfile'] ?? '').toString(),
          };
        }
        return {'id': e.toString(), 'name': e.toString(), 'profile': ''};
      }).toList();
    }

    final leftColumn = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [_headerCard(), _detailsCard(), _actionsCard()],
    );

    final rightColumn = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [_historyCard(), const SizedBox(height: 24)],
    );

    Widget buildPageContent() {
      if (_loading) {
        return SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: _loadingSkeleton(),
          ),
        );
      }

      if (_error != null) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.redAccent),
                ),
                const SizedBox(height: 12),
                ElevatedButton.icon(
                  onPressed: () => _fetchDetails(),
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retry'),
                ),
              ],
            ),
          ),
        );
      }

      return RefreshIndicator(
        onRefresh: () => _fetchDetails(showLoading: false),
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(12),
          child: isTablet
              ? Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 360, minWidth: 280),
                child: leftColumn,
              ),
              const SizedBox(width: 12),
              Expanded(child: rightColumn),
            ],
          )
              : Column(
            children: [
              leftColumn,
              const SizedBox(height: 8),
              rightColumn,
              const SizedBox(height: 80),
            ],
          ),
        ),
      );
    }

    // When cache is empty, show a single ticket page
    if (_cacheList.isEmpty) {
      return WillPopScope(
        onWillPop: () async {
          Navigator.of(context).pop(_dirty);
          return false;
        },
        child: Scaffold(
          backgroundColor: Colors.grey.shade50,
          appBar: AppBar(
            backgroundColor: Colors.white,
            elevation: 1,
            actionsPadding: const EdgeInsets.symmetric(horizontal: 12),
            iconTheme: const IconThemeData(color: Colors.black87),
            title: Text(
              '${_details['rid'] ?? ''}',
              style: TextStyle(
                color: _priorityColor(priority),
                fontWeight: FontWeight.w700,
                fontSize: 18,
              ),
            ),
            actions: [
              _assignedAvatars(context, assigned, maxInlineAvatars),
            ],
          ),
          body: buildPageContent(),
        ),
      );
    }

    // Otherwise use PageView for sliding tickets
    return WillPopScope(
      onWillPop: () async {
        Navigator.of(context).pop(_dirty);
        return false;
      },
      child: Scaffold(
        backgroundColor: Colors.white,
        appBar: AppBar(
          backgroundColor: Colors.white,
          elevation: 1,
          actionsPadding: const EdgeInsets.symmetric(horizontal: 12),
          iconTheme: const IconThemeData(color: Colors.black87),
          title: Text(
            '${_details['rid'] ?? ''}',
            style: TextStyle(
              color: _priorityColor(priority),
              fontWeight: FontWeight.w700,
              fontSize: 18,
            ),
          ),
          actions: [
            _assignedAvatars(context, assigned, maxInlineAvatars),
          ],
        ),
        body: Stack(
          children: [
            PageView.builder(
              controller: controller,
              itemCount: _cacheList.length,
              onPageChanged: (int page) {
                // quick guard that prevents overlapping page processing
                if (!mounted || _isFetching) return;

                // Defer the heavy work until after current frame/layout finishes.
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (!mounted) return;

                  // immediate UI change (now safe to call setState because we're post-frame)
                  safeSetState(() {
                    _isFetching = true;
                    _pageReady = false;
                    _visiblePage = page;
                  });

                  // update indexes and active id
                  _currentIndex = page;
                  final item = _cacheList.length > page ? _cacheList[page] : <String, dynamic>{};
                  final String activeRid = (item['id'] ?? '').toString();
                  _activeTicketID = activeRid;

                  // start fetch; we intentionally don't await here to avoid blocking the post-frame callback
                  _fetchDetails(ticketId: activeRid, showLoading: false).whenComplete(() async {
                    if (!mounted) return;
                    // leave a small gap so AnimatedSwitcher / fade transitions look smoother
                    setState(() => _isFetching = false);
                    await Future.delayed(const Duration(milliseconds: 100));
                    if (!mounted) return;
                    setState(() {
                      _pageReady = true;
                      _initialPageLoaded = true;
                    });
                  });
                });
              },




              itemBuilder: (context, index) {
                final item = _cacheList[index] as Map<String, dynamic>? ?? <String, dynamic>{};
                final String id = (item['id'] ?? '').toString();

                final bool isActive = index == _visiblePage;
                final bool isFirstPage = index == 0;

                // show first page immediately on initial load
                final bool hasCache = _getCachedDetails(id) != null;
                final bool showContent = (isActive && _pageReady) || (isFirstPage && !_initialPageLoaded) || hasCache;

                return AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  reverseDuration: const Duration(milliseconds: 180),
                  switchInCurve: Curves.easeInOut,
                  switchOutCurve: Curves.easeOutCubic,
                  transitionBuilder: (child, anim) => FadeTransition(opacity: anim, child: child),
                  child: showContent
                      ? KeyedSubtree(
                    key: ValueKey('page-$index'),
                    child: buildPageContentForIndex(index),
                  )
                      : (isFirstPage && !_initialPageLoaded
                      ? KeyedSubtree(
                    key: ValueKey('skeleton-$index'),
                    child: _loadingSkeleton(), // keep skeleton for initial only
                  )
                      : Container(
                    key: ValueKey('blank-$index'),
                    color: Colors.white,
                  )),
                );
              },
            ),
          ],
        ),
      ),
    );
  }


}

// -----------
class _PdfPreviewSheet extends StatefulWidget {
  final String url;
  final String name;
  final Dio dio;
  const _PdfPreviewSheet({
    required this.url,
    required this.name,
    required this.dio,
  });

  @override
  State<_PdfPreviewSheet> createState() => _PdfPreviewSheetState();
}

class _PdfPreviewSheetState extends State<_PdfPreviewSheet> {
  double _progress = 0.0;
  PdfControllerPinch? _controller;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _downloadAndLoad();
  }

  Future<void> _downloadAndLoad() async {
    setState(() {
      _loading = true;
      _error = null;
      _progress = 0.0;
    });
    try {
      final res = await widget.dio.get<List<int>>(
        widget.url,
        options: Options(
          responseType: ResponseType.bytes,
          followRedirects: true,
          validateStatus: (s) => s! < 500,
        ),
        onReceiveProgress: (r, t) {
          if (t > 0) {
            setState(() {
              _progress = r / t;
            });
          }
        },
      );

      if (res.statusCode == 200 && res.data != null) {
        // res.data may already be a Uint8List when responseType = bytes
        final Uint8List bytes =
            res.data is Uint8List
                ? res.data as Uint8List
                : Uint8List.fromList(List<int>.from(res.data!));

        // Pass the Future<PdfDocument> directly — PdfControllerPinch accepts Future<PdfDocument>
        _controller?.dispose();
        _controller = PdfControllerPinch(
          document: PdfDocument.openData(bytes), // Future<PdfDocument>
        );

        setState(() {
          _loading = false;
          _error = null;
          _progress = 1.0;
        });
      } else {
        setState(() {
          _loading = false;
          _error = 'Failed to download PDF (status ${res.statusCode})';
        });
      }
    } catch (e) {
      setState(() {
        _loading = false;
        _error = 'Error loading PDF: $e';
      });
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }



  Future<void> _openExternalOrDownload(String rawUrl, {String? preferredName}) async {
    final ctx = context;
    String url = (rawUrl ?? '').toString().trim();
    if (url.isEmpty) {
      if (mounted) ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('Invalid URL')));
      return;
    }

    // Normalize URL (add https if missing)
    Uri? uri = Uri.tryParse(url);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      final candidate = url.startsWith('//') ? 'https:$url' : (url.startsWith('http') ? url : 'https://$url');
      uri = Uri.tryParse(candidate);
    }
    if (uri == null) {
      if (mounted) ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('Cannot parse URL')));
      return;
    }

    // Determine extension/type
    final lastSegment = uri.pathSegments.isNotEmpty ? uri.pathSegments.last : '';
    final ext = lastSegment.contains('.') ? lastSegment.split('.').last.toLowerCase() : '';
    final isImage = ['png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'].contains(ext);
    final isPdf = ext == 'pdf';

    // Helper to download bytes using Dio (returns null on failure)
    Future<Uint8List?> _downloadBytes(String u) async {
      try {
        final messenger = ScaffoldMessenger.of(ctx);
        final snack = messenger.showSnackBar(SnackBar(content: Text('Downloading ${lastSegment.isNotEmpty ? lastSegment : 'file'}...'), duration: const Duration(days: 1)));

        final res = await widget.dio.get<List<int>>(
          u,
          options: Options(responseType: ResponseType.bytes, followRedirects: true, validateStatus: (s) => s! < 500),
        );

        snack.close();

        if (res.statusCode == 200 && res.data != null) {
          final bytes = res.data is Uint8List ? res.data as Uint8List : Uint8List.fromList(List<int>.from(res.data!));
          return bytes;
        } else {
          return null;
        }
      } catch (e) {
        debugPrint('download error: $e');
        return null;
      }
    }

    // 1) If image: try quick in-app network preview (best UX); if it fails, fall back to download+memory preview
    if (isImage) {
      try {
        // Show network image inside a dialog (handles most cases)
        await showDialog(
          context: ctx,
          builder: (dCtx) {
            return Dialog(
              insetPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // header
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    child: Row(
                      children: [
                        Expanded(child: Text( lastSegment.isNotEmpty ? lastSegment : 'Image', overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700))),
                        IconButton(icon: const Icon(Icons.open_in_new), onPressed: () async {
                          // Try external open if user wants it
                          try {
                            if (await canLaunchUrl(uri!)) await launchUrl(uri, mode: LaunchMode.externalApplication);
                          } catch (_) {}
                        }),
                        IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.of(dCtx).pop()),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Flexible(
                    child: InteractiveViewer(
                      child: Padding(
                        padding: const EdgeInsets.all(12.0),
                        child: Image.network(
                          uri.toString(),
                          loadingBuilder: (c, child, progress) {
                            if (progress == null) return child;
                            final p = (progress.cumulativeBytesLoaded / (progress.expectedTotalBytes ?? 1));
                            return SizedBox(height: 200, child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [CircularProgressIndicator(value: p), const SizedBox(height: 8), Text('${(p * 100).toStringAsFixed(0)}%')])));
                          },
                          errorBuilder: (c, e, st) {
                            // network image failed — close dialog and fallback to download below
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              if (Navigator.of(dCtx).canPop()) Navigator.of(dCtx).pop();
                            });
                            return const SizedBox.shrink();
                          },
                          fit: BoxFit.contain,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
              ),
            );
          },
        );
        // If dialog displayed successfully, return (we handled preview)
        return;
      } catch (e) {
        // continue to fallbacks
        debugPrint('network image preview failed: $e');
      }
    }

    // 2) Try opening externally (browser / associated app)
    try {
      if (await canLaunchUrl(uri)) {
        final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
        if (launched) return;
      } else {
        // Some devices return false for canLaunchUrl; try launch anyway (catching errors)
        try {
          final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
          if (launched) return;
        } catch (_) {}
      }
    } catch (e) {
      debugPrint('external launch error: $e');
    }

    // 3) Fallback: download file bytes and handle in-app
    final bytes = await _downloadBytes(uri.toString());
    if (bytes == null) {
      if (mounted)
        // ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('Cannot download or open file')));
        Fluttertoast.showToast(
          msg: "Cannot download or open file",
          toastLength: Toast.LENGTH_SHORT,
          gravity: ToastGravity.BOTTOM,
          backgroundColor: Colors.redAccent.shade200,
          textColor: Colors.white,
          fontSize: 14.0,
        );
        return;
    }

    // If image bytes -> show in-dialog Image.memory
    if (isImage) {
      if (!mounted) return;
      await showDialog(
        context: ctx,
        builder: (dCtx) {
          return Dialog(
            insetPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 24),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8), child: Row(children: [
                Expanded(child: Text( lastSegment.isNotEmpty ? lastSegment : 'Image', overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700))),
                IconButton(icon: const Icon(Icons.open_in_new), onPressed: () async {
                  // open temp file externally
                  try {
                    final dir = await getTemporaryDirectory();
                    final name =  lastSegment.isNotEmpty ? lastSegment : 'image_${DateTime.now().millisecondsSinceEpoch}';
                    final safe = name.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_');
                    final f = File('${dir.path}/$safe');
                    await f.writeAsBytes(bytes, flush: true);
                    await OpenFile.open(f.path);
                  } catch (e) { debugPrint('open temp image error: $e'); }
                }),
                IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.of(dCtx).pop()),
              ])),
              const Divider(height: 1),
              Flexible(child: InteractiveViewer(child: Padding(padding: const EdgeInsets.all(12), child: Image.memory(bytes, fit: BoxFit.contain)))),
              const SizedBox(height: 12),
            ]),
          );
        },
      );
      return;
    }

    // For PDFs and other types: save to temp and open with platform app (OpenFile)
    try {
      final dir = await getTemporaryDirectory();
      final inferred = lastSegment.isNotEmpty ? lastSegment : 'download_${DateTime.now().millisecondsSinceEpoch}';
      final rawName = preferredName ?? inferred;
      final fileName = rawName.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_');
      final file = File('${dir.path}/$fileName');
      await file.writeAsBytes(bytes, flush: true);

      // Try to open with platform handler
      final result = await OpenFile.open(file.path);

      // Optionally show feedback when result is not success
      debugPrint('OpenFile result: ${result.type} ${result.message}');
      return;
    } catch (e) {
      debugPrint('save/open fallback error: $e');
      if (mounted) ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('Unable to open file')));
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).canvasColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Column(
        children: [
          // header
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 10),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    widget.name.isNotEmpty ? widget.name : 'PDF',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.open_in_new),
                  onPressed: () async {
                    await _openExternalOrDownload(widget.url);
                  },
                ),

                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child:
                _loading
                    ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircularProgressIndicator(
                            value: _progress > 0 ? _progress : null,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            _progress > 0
                                ? '${(_progress * 100).toStringAsFixed(0)}%'
                                : 'Downloading...',
                          ),
                        ],
                      ),
                    )
                    : (_error != null)
                    ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(
                          _error!,
                          style: const TextStyle(color: Colors.red),
                        ),
                      ),
                    )
                    : PdfViewPinch(controller: _controller!),
          ),
        ],
      ),
    );
  }
}
// ---------------

// Simple wrapper that keeps its child alive in PageView / TabBarView
class KeepAliveWidget extends StatefulWidget {
  final Widget child;
  final Key? keepKey; // optional: allows PageStorageKey usage outside

  const KeepAliveWidget({super.key, required this.child, this.keepKey});

  @override
  _KeepAliveWidgetState createState() => _KeepAliveWidgetState();
}

class _KeepAliveWidgetState extends State<KeepAliveWidget> with AutomaticKeepAliveClientMixin<KeepAliveWidget> {
  @override
  bool get wantKeepAlive => true; // keep the widget alive

  @override
  Widget build(BuildContext context) {
    super.build(context); // important for AutomaticKeepAliveClientMixin
    return KeyedSubtree(
      key: widget.keepKey,
      child: widget.child,
    );
  }
}
