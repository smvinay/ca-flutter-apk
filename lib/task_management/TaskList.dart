
import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../ChargeablePage.dart';
import '../widgets/AutoScrollingText.dart';
import '/detailsUpdate.dart';
import 'package:hive_flutter/hive_flutter.dart'; // add to top of file

const Color _primaryPurple = Color(0xFF6B59C9);

class TaskListPageV2 extends StatefulWidget {
  // final void Function(int page)? onPageRequested;
  // const TaskListPageV2({Key? key, this.onPageRequested}) : super(key: key);

  final void Function(int page)? onPageRequested;
  const TaskListPageV2({Key? key, this.onPageRequested}) : super(key: key);

  @override
  TaskListPageV2State createState() => TaskListPageV2State();
}


class TaskListPageV2State extends State<TaskListPageV2>
    with SingleTickerProviderStateMixin {
  bool _showSearch = false; // not the toggle-search; kept for header search if needed
  String _searchQuery = '';
  String _userType = '';
  String _levelID = '';


  String? _serviceType;
  bool _showSR = false;

  // --- priority filter (KEEP AS-IS) ---
  String _selectedPriority = 'All';
  final List<String> _priorityOptions = ['All', 'High', 'Medium', 'Low'];

  // Add these near the top of your state class (constants for cache keys)
  static const String _cacheKeyServices = 'cache_task_list';
  static const String _cacheKeyServicesTs = 'cache_task_list_ts';
// 10 minutes in milliseconds
  static const int _cacheTtlMs = 10 * 60 * 1000;

  // --- card type slider (KEEP AS-IS) ---
  final List<String> _cardTypeOptions = ['All', 'Task', 'Service'];
  int _selectedCardTypeIndex = 0; // default show Task (index 1)
  String get _selectedCardType => _cardTypeOptions[_selectedCardTypeIndex];

  // --- status filter (new extra) ---
  String _selectedStatus = 'All';
  late final List<String> _statusOptions;

  // --- assignee filter (new extra) ---
  // each map: {id: '...', name: '...', profile: '...'}
  List<Map<String, String>> _assignees = [
    {'id': 'All', 'name': 'All assignees', 'profile': ''},
  ];
  String _selectedAssigneeId = 'All';

  // toggle to show/hide filter row (status + assignee) - default true
  bool _showFiltersRow = true;

  // toggle to show/hide the combined search + priority row (default hidden)
  bool _showSearchPriorityRow = false;

  // network + UI state
  bool _loading = true;
  bool _refreshing = false;
  String? _error;
  List<Map<String, dynamic>> services = [];
  List<Map<String, dynamic>> _childUsers = [];

  // animation
  late final AnimationController _entrance;
  late final Animation<double> _fade;

  @override
  void initState() {
    super.initState();
    _entrance = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
    _fade = CurvedAnimation(parent: _entrance, curve: Curves.easeOut);
    _entrance.forward();
    _fetchServices();

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _loadUserInfo(); // <-- Load user info first
    });

  }

  @override
  void dispose() {
    _entrance.dispose();
    super.dispose();
  }

  Future<void> refresh() async {
    if (!mounted) return;
    setState(() => _refreshing = true);
    await _fetchServices(forceRefresh: true);
    if (mounted) setState(() => _refreshing = false);
  }



  Future<void> _loadUserInfo() async {
    _statusOptions = [
      'All',
      'Pending',
      'In Progress',
      'Extend',
      'Completed',
    ];


    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('user_data');

      if (raw != null) {
        final Map<String, dynamic> user = jsonDecode(raw);
        setState(() {
          // _userID = (user['id'] ?? '').toString();
          _userType = (user['type'] ?? '').toString();
          // _domain = (user['domain'] ?? '').toString();
          // _slug = (user['slug'] ?? '').toString();

          _serviceType = (user['servicesettings'] ?? '').toString();

          _showSR = (_userType == 'admin') ? true : (_serviceType != '1' && _serviceType != '2') ? true : false ;


          if (_showSR) {
            _statusOptions.insert(1, 'New SR'); // 👈 add at index 1, right after "All"
          }

        });
      }
    } catch (e) {
      if (kDebugMode) debugPrint('Failed to load user info: $e');
    }
  }

  // ---------- Responsive helpers ----------
  double _calcScaleFromWidth(double w) {
    const double base = 420.0;
    final raw = w / base;
    return raw.clamp(0.64, 1.0);
  }

  double _s(double value, double scale) => value * scale;

  // ---------- Computed aggregates ----------
  int get gstCount =>
      services
          .where((s) => (s['category'] ?? '').toString().toLowerCase() == 'gst')
          .length;
  int get auditCount =>
      services
          .where(
            (s) => (s['category'] ?? '').toString().toLowerCase() == 'audit',
      )
          .length;
  int get incomeTaxCount =>
      services
          .where(
            (s) =>
        (s['category'] ?? '').toString().toLowerCase() == 'income tax',
      )
          .length;
  int get totalServices => services.length;
  int get exemptedCount =>
      services.where((s) => (s['chargeable'] ?? false) == false).length;
  int get chargeableCount =>
      services.where((s) => (s['chargeable'] ?? false) == true).length;
  int get invoicesCount =>
      services
          .where(
            (s) =>
        s['invoice_id'] != null &&
            s['invoice_id'].toString().isNotEmpty,
      )
          .length;

  // ---------- Build API URL from prefs ----------
  Future<String> _buildApiUrl() async {
    final prefs = await SharedPreferences.getInstance();

    final raw = prefs.getString('user_data');
    String slug = '';
    String id = '';
    String type = '';
    String domain = '';
    if (raw != null) {
      try {
        final Map<String, dynamic> data = jsonDecode(raw);
        slug = (data['slug'] ?? '').toString();
        id = (data['id'] ?? '').toString();
        type = (data['type'] ?? '').toString();
        _userType = type ;
        domain = (data['domain'] ?? '').toString();
      } catch (_) {}
    }

    slug = slug.isNotEmpty ? slug : (prefs.getString('slug') ?? '');
    id = id.isNotEmpty ? id : (prefs.getString('id') ?? '');

    if (slug.isEmpty || id.isEmpty)
      throw Exception('Missing slug/id in local storage');

    return '$domain$slug/taskListApi?id=$id&type=$type&slug=$slug';
  }

  // ---------- Fetch ----------

// ---------- Fetch (with caching) ----------
  Future<void> _fetchServices({bool showLoading = true, bool forceRefresh = false}) async {
    if (!mounted) return;

    if (showLoading) {
      setState(() {
        _loading = true;
        _error = null;
      });
    } else {
      setState(() => _refreshing = true);
    }

    try {
      // If not forcing refresh, try to load from cache first
      if (!forceRefresh) {
        final cached = await _loadServicesFromCacheIfFresh();
        if (cached != null) {
          if (!mounted) return;
          setState(() {
            services = cached;
            _buildAssigneesFromServices();
            _loading = false;
            _refreshing = false;
            _error = null;
          });
          // Return early — cached data loaded
          return;
        }
      }

      // No fresh cache (or forced), fetch from API
      final url = await _buildApiUrl();
      print('url $url');

      final uri = Uri.parse(url);
      final resp = await http.get(uri).timeout(const Duration(seconds: 12));

      if (resp.statusCode != 200) {
        throw Exception('Server returned ${resp.statusCode}');
      }

      final dynamic parsedJson = jsonDecode(resp.body);

      // Support two shapes:
      // 1) API returns a List of tickets (old behavior)
      // 2) API returns an object { tickets: [...], childUsers: [...] } (new behavior)
      List rawList;
      List<dynamic> childUsersFromApi = [];

      if (parsedJson is List) {
        rawList = parsedJson;
      } else if (parsedJson is Map && parsedJson['tickets'] is List) {
        rawList = parsedJson['tickets'] as List;
        if (parsedJson['childUsers'] is List) {
          childUsersFromApi = parsedJson['childUsers'] as List<dynamic>;
        }
      } else {
        throw Exception('Unexpected response format');
      }



      final List<Map<String, dynamic>> parsedItems = rawList.map<Map<String, dynamic>>((rawItem) {
        final Map<String, dynamic> item = (rawItem is Map) ? Map<String, dynamic>.from(rawItem) : {};
        final String rid = (item['rid'] ?? item['request_id'] ?? item['tkt_id'] ?? '').toString();
        final String title = (item['title'] ?? item['subject'] ?? '').toString();
        final String category = (item['category'] ?? item['category_name'] ?? '').toString();
        final String createdBy = (item['createdBy'] ?? item['created_by'] ?? item['created_by_user'] ?? '').toString();
        final String createdAt = (item['createdAt'] ?? item['created_at'] ?? '').toString();
        final String enddate = (item['enddate'] ??  '').toString();
        final String status_name = (item['status_name'] ?? item['status'] ?? '').toString();

        String priorityLabel = 'Low';
        final p = item['priority'];
        if (p is num) {
          if (p == 2)
            priorityLabel = 'High';
          else if (p == 1)
            priorityLabel = 'Medium';
          else
            priorityLabel = 'Low';
        } else if (p is String) {
          final pl = p.toLowerCase();
          if (pl.contains('high'))
            priorityLabel = 'High';
          else if (pl.contains('med'))
            priorityLabel = 'Medium';
          else
            priorityLabel = 'Low';
        }

        final dynamic chargeRaw = item['chargeable'] ?? item['chargable'] ?? item['chargeable_flag'] ?? '';
        final bool chargeable = (chargeRaw is num)
            ? (chargeRaw == 1)
            : (chargeRaw is String ? (chargeRaw == '1' || chargeRaw.toLowerCase() == 'yes') : (chargeRaw == true));

        final String type = item['Type']?.toString() ?? item['type']?.toString() ?? 'Service Request';
        final String avatar = (item['createdByProfile'] ?? '').toString();
        final String invoiceId = item['invoice_id']?.toString() ?? '';
        final String id = item['id']?.toString() ?? '';

        return <String, dynamic>{
          'id': id,
          'rid': rid,
          'title': title,
          'category': category,
          'createdBy': createdBy,
          'createdByProfile': avatar,
          'createdAt': createdAt,
          'enddate': enddate,
          'priority': priorityLabel,
          'chargeable': chargeable,
          'Type': type,
          'status_name': status_name,
          'avatar': avatar,
          'invoice_id': invoiceId,
          'items': item['items'] ?? [],
          // keep both key variants so _buildAssigneesFromServices can find them
          'assignedUsers': item['assignedUsers'] ?? item['assigned_users'] ?? [],
          'total_rate': item['total_rate'] ?? 0,
        };
      }).toList();

      if (!mounted) return;



      // If API provided child_users at top-level, stash them on the services list as a special key
      // so _buildAssigneesFromServices can use them directly.
      // We'll add a single pseudo-item with key '__meta_child_users' to carry the child list.
      final List<Map<String, dynamic>> finalItems = List.from(parsedItems);

      // if (childUsersFromApi.isNotEmpty) {
        // Normalize child users to {id, name, profile?}
        final normalizedChildUsers = childUsersFromApi.map<Map<String, dynamic>>((cu) {
          if (cu is Map) {
            return {
              'id': (cu['id'] ?? cu['user_id'] ?? '').toString(),
              'name': (cu['name'] ?? cu['fullname'] ?? '').toString(),
              'profile': (cu['profile'] ?? cu['user_profile'] ?? '').toString(),
            };
          } else {
            return {'id': cu.toString(), 'name': cu.toString(), 'profile': ''};
          }
        }).toList();

      // finalItems.add({
      //   '__meta_child_users': normalizedChildUsers,
      // });
      // }

      setState(() {
        services = finalItems;
        _childUsers = normalizedChildUsers;
        _buildAssigneesFromServices();
        _loading = false;
        _refreshing = false;
        _error = null;
      });

      // save to cache (best-effort)
      await _saveServicesToCache(finalItems);
    } on TimeoutException {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _refreshing = false;
        _error = 'Request timed out. Please try again.';
      });
      _showTopToast('Request timed out. Pull to retry.');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _refreshing = false;
        _error = 'Sorry, something went wrong there. Try again.';
      });
      _showTopToast('Failed to fetch data. Tap Retry.');
    }
  }


// ---------- Cache helpers (Hive) ----------
  Future<void> _saveServicesToCache(List<Map<String, dynamic>> items) async {
    try {
      final box = Hive.box('cacheBox');
      // store JSON string for safety and full compatibility
      final String payload = jsonEncode(items);
      final int ts = DateTime.now().millisecondsSinceEpoch;
      await box.put(_cacheKeyServices, payload);
      await box.put(_cacheKeyServicesTs, ts);
    } catch (e, st) {
      debugPrint('Failed to save services cache to Hive: $e\n$st');
    }
  }


  Future<List<Map<String, dynamic>>?> _loadServicesFromCacheIfFresh() async {
    try {
      final box = Hive.box('cacheBox');
      final String? payload = box.get(_cacheKeyServices) as String?;
      final int? ts = box.get(_cacheKeyServicesTs) as int?;

      if (payload == null || ts == null) return null;
      final int now = DateTime.now().millisecondsSinceEpoch;
      if ((now - ts) > _cacheTtlMs) {
        // cache expired => remove stale entries (optional)
        try {
          await box.delete(_cacheKeyServices);
          await box.delete(_cacheKeyServicesTs);
        } catch (_) {}
        return null;
      }

      final dynamic parsed = jsonDecode(payload);
      if (parsed is! List) return null;
      return (parsed as List).map<Map<String, dynamic>>((dynamic raw) {
        if (raw is Map) return Map<String, dynamic>.from(raw);
        return <String, dynamic>{};
      }).toList();
    } catch (e, st) {
      debugPrint('Failed to load services cache from Hive: $e\n$st');
      return null;
    }
  }

  // Build deduped assignees list from services but prefer API-provided child_users
  void _buildAssigneesFromServices() {
    final Map<String, Map<String, String>> map = {};

    // First, check if services contains a meta entry '__meta_child_users'
    List<dynamic> childUsersFromMeta = [];


        final meta = _childUsers;
        childUsersFromMeta = meta;




    if (childUsersFromMeta.isNotEmpty) {
      // Use child users directly (preferred)
      for (final cu in childUsersFromMeta) {
        if (cu is Map) {
          final id = (cu['id'] ?? '').toString();
          if (id.isEmpty) continue;
          final name = (cu['name'] ?? id).toString();
          final profile = (cu['profile'] ?? '').toString();
          if (!map.containsKey(id)) {
            map[id] = {'name': name, 'profile': profile};
          }
        }
      }
    } else {
      // Fallback: build from per-ticket assignedUsers
      for (final s in services) {
        if (s is Map) {
          final rawAssigned = s['assignedUsers'] ?? s['assigned_users'] ?? [];
          if (rawAssigned is List) {
            for (final a in rawAssigned) {
              if (a is Map) {
                final id = (a['id'] ?? a['user_id'] ?? '').toString();
                final name = (a['name'] ?? a['fullname'] ?? a['username'] ?? id).toString();
                final profile = (a['profile'] ?? a['user_profile'] ?? '').toString();
                if (id.isNotEmpty && !map.containsKey(id)) {
                  map[id] = {'name': name, 'profile': profile};
                }
              }
            }
          }
        }
      }
    }

    final list = <Map<String, String>>[];
    list.add({'id': 'All', 'name': 'All assignees', 'profile': ''});
    for (final e in map.entries) {
      list.add({
        'id': e.key,
        'name': e.value['name'] ?? e.key,
        'profile': e.value['profile'] ?? '',
      });
    }

    setState(() => _assignees = list);
  }


  // ---------- UI helpers ----------
  List<Map<String, dynamic>> get _filteredServices {
    var list = services;

    // card type filter (All / Task / Service)
    if (_selectedCardType != 'All') {
      final target = _selectedCardType.toLowerCase();
      list =
          list.where((s) {
            final t = (s['Type'] ?? s['type'] ?? '').toString().toLowerCase();
            return t.contains(target);
          }).toList();
    }

    // priority
    if (_selectedPriority != 'All') {
      list =
          list
              .where(
                (s) =>
            (s['priority'] ?? '').toString().toLowerCase() ==
                _selectedPriority.toLowerCase(),
          )
              .toList();
    }

    // status
    if (_selectedStatus != 'All') {
      final target = _selectedStatus.toLowerCase();
      list =
          list.where((s) {
            final st =
            (s['status_name'] ?? s['status'] ?? '')
                .toString()
                .toLowerCase();
            return st.contains(target);
          }).toList();
    }

    // assignee
    if (_selectedAssigneeId != 'All') {
      list =
          list.where((s) {
            final asg = s['assignedUsers'] ?? s['assigned_users'] ?? [];
            if (asg is! List) return false;
            return asg.any((a) {
              if (a is Map) {
                final aid = (a['id'] ?? a['user_id'] ?? '').toString();
                return aid == _selectedAssigneeId;
              }
              return a.toString() == _selectedAssigneeId;
            });
          }).toList();
    }

    // search
    if (_searchQuery.trim().isNotEmpty) {
      final q = _searchQuery.trim().toLowerCase();
      list =
          list.where((s) {
            final rid = (s['rid'] ?? '').toString().toLowerCase();
            final category =
            (s['category'] ?? s['category_name'] ?? '')
                .toString()
                .toLowerCase();
            final title =
            (s['title'] ?? s['subject'] ?? '').toString().toLowerCase();
            return rid.contains(q) || category.contains(q) || title.contains(q);
          }).toList();
    }

    return list;
  }

  void _showTopToast(String message) {
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
        onPressed: () => _fetchServices(forceRefresh: true),
      ),
    );
    ScaffoldMessenger.of(context).showSnackBar(sb);
  }

  // small loading skeleton while awaiting data
  Widget _loadingSkeleton(double scale) {
    final h = _s(110, scale);
    final padH = _s(12, scale);
    final padV = _s(8, scale);
    final borderRadius = _s(8, scale);
    return Column(
      children: List.generate(3, (index) {
        return Padding(
          padding: EdgeInsets.symmetric(horizontal: padH, vertical: padV),
          child: Container(
            height: h,
            decoration: BoxDecoration(
              color: Colors.grey.shade100,
              borderRadius: BorderRadius.circular(borderRadius),
              border: Border.all(color: Colors.grey.shade200),
            ),
            child: Row(
              children: [
                Container(width: _s(4, scale), color: Colors.grey.shade300),
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: padH,
                      vertical: padH,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: _s(120, scale),
                          height: _s(14, scale),
                          color: Colors.grey.shade300,
                        ),
                        SizedBox(height: _s(10, scale)),
                        Container(
                          width: double.infinity,
                          height: _s(16, scale),
                          color: Colors.grey.shade200,
                        ),
                        SizedBox(height: _s(8, scale)),
                        Container(
                          width: _s(180, scale),
                          height: _s(12, scale),
                          color: Colors.grey.shade200,
                        ),
                        const Spacer(),
                        Align(
                          alignment: Alignment.bottomLeft,
                          child: Container(
                            width: _s(120, scale),
                            height: _s(10, scale),
                            color: Colors.grey.shade200,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      }),
    );
  }

  // ---------- UI build ----------
  @override
  Widget build(BuildContext context) {
    final filtered = _filteredServices;

    return LayoutBuilder(
      builder: (context, constraints) {
        final scale = _calcScaleFromWidth(constraints.maxWidth);

        return Scaffold(
          body: SafeArea(
            child: Column(
              children: [
                               // small header with search toggle
                _smallHeader(scale),
                // status + assignee row (default visible) including toggle icon to open search+priority
                AnimatedCrossFade(
                  firstChild: const SizedBox.shrink(),
                  secondChild: _buildStatusAndAssigneeRow(scale),
                  crossFadeState:
                  _showFiltersRow
                      ? CrossFadeState.showSecond
                      : CrossFadeState.showFirst,
                  duration: const Duration(milliseconds: 220),
                ),

                // priority & search row — shown only when toggle is active
                AnimatedCrossFade(
                  firstChild: const SizedBox.shrink(),
                  secondChild: _buildPriorityFilterWithNoToggle(scale),
                  crossFadeState:
                  _showSearchPriorityRow
                      ? CrossFadeState.showSecond
                      : CrossFadeState.showFirst,
                  duration: const Duration(milliseconds: 220),
                ),
                // main content area: supports swipe left/right to change card type
                Expanded(

                    child:
                    _loading
                        ? RefreshIndicator(
                      onRefresh:
                          () => _fetchServices(showLoading: false,forceRefresh: true),
                      child: ListView(
                        children: [_loadingSkeleton(scale)],
                      ),
                    )
                        : (_error != null)
                        ? Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 28.0,
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              _error!,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: Colors.redAccent,
                              ),
                            ),
                            const SizedBox(height: 12),
                            ElevatedButton.icon(
                              onPressed: () => _fetchServices(forceRefresh: true),
                              icon: const Icon(Icons.refresh),
                              label: const Text('Retry'),
                            ),
                          ],
                        ),
                      ),
                    )
                        : RefreshIndicator(
                      onRefresh:
                          () => _fetchServices(showLoading: false,forceRefresh: true),
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 360),
                        transitionBuilder: (child, anim) {
                          final offsetAnim = Tween<Offset>(
                            begin: const Offset(0.0, 0.03),
                            end: Offset.zero,
                          ).animate(anim);
                          return SlideTransition(
                            position: offsetAnim,
                            child: FadeTransition(
                              opacity: anim,
                              child: child,
                            ),
                          );
                        },
                        child: Builder(
                          builder: (context) {
                            final listKey = ValueKey<int>(
                              filtered.length ^
                              _selectedCardTypeIndex ^
                              _selectedPriority.hashCode ^
                              _selectedStatus.hashCode ^
                              _selectedAssigneeId.hashCode,
                            );
                            // inside the Builder -> return ListView.builder(...) area,
// replace the commented-out block with this:
                            if (filtered.isEmpty) {
                              return ListView(
                                key: listKey,
                                padding: EdgeInsets.only(
                                  bottom: _s(18, scale),
                                  top: _s(8, scale),
                                ),
                                children: [
                                  SizedBox(height: _s(15, scale)),
                                  Center(
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        // empty card style similar to your _serviceCard look & feel
                                        Container(
                                          width: constraints.maxWidth * 0.92,
                                          padding: EdgeInsets.symmetric(
                                            horizontal: _s(12, scale),
                                            vertical: _s(10, scale),
                                          ),
                                          decoration: BoxDecoration(
                                            color: Theme.of(context).cardColor,
                                            borderRadius: BorderRadius.circular(_s(12, scale)),
                                            boxShadow: [
                                              BoxShadow(
                                                blurRadius: 8,
                                                offset: const Offset(0, 4),
                                                color: Colors.black.withOpacity(0.06),
                                              ),
                                            ],
                                          ),
                                          child: Column(
                                            children: [
                                              Icon(Icons.inbox, size: _s(30, scale), color: Colors.grey),
                                              SizedBox(height: _s(12, scale)),
                                              Text(
                                                'No data found',
                                                style: TextStyle(
                                                  fontSize: _s(16, scale),
                                                  fontWeight: FontWeight.w600,
                                                  color: Colors.grey[700],
                                                ),
                                              ),
                                              SizedBox(height: _s(8, scale)),
                                              Text(
                                                'There are no items that match your current filters.',
                                                textAlign: TextAlign.center,
                                                style: TextStyle(
                                                  fontSize: _s(13, scale),
                                                  color: Colors.grey[600],
                                                ),
                                              ),

                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  SizedBox(height: _s(20, scale)),
                                ],
                              );
                            }


                            return ListView.builder(
                              key: listKey,
                              padding: EdgeInsets.only(
                                bottom: _s(18, scale),
                                top: _s(8, scale),
                              ),
                              itemCount: filtered.length,
                              itemBuilder: (context, i) {
                                final s = filtered[i];
                                return FadeTransition(
                                  opacity: _fade,
                                  child: Transform.translate(
                                    offset: Offset(
                                      0,
                                      (1 - (_fade.value)).clamp(
                                        0.0,
                                        1.0,
                                      ) *
                                          _s(8, scale) *
                                          (i % 3),
                                    ),
                                    child: _serviceCard(s, scale),
                                  ),
                                );
                              },
                            );
                          },
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  // SERVICE CARD (kept unchanged) --------------------------------------------------
// Replace your existing _serviceCard with this version:
  Widget _serviceCard(Map<String, dynamic> s, double scale) {
    final id = (s['id'] ?? '0').toString();
    final priority = (s['priority'] ?? 'Low').toString();
    final rid = (s['rid'] ?? s['request_id'] ?? '').toString();
    final title = (s['title'] ?? s['subject'] ?? '').toString();
    final category = (s['category'] ?? s['category_name'] ?? '').toString();
    final createdAt = (s['createdAt'] ?? s['created_at'] ?? '').toString();
    final enddate = (s['enddate'] ??  '').toString();
    final type = (s['Type'] ?? s['type'] ?? '').toString();

    final statusName = (s['status_name'] ?? s['status'] ?? '').toString();

    final dynamic chargeRaw = s['chargeable'] ?? s['chargable'] ?? s['chargeable_flag'] ?? s['chargable'];
    final bool chargeable = (chargeRaw is num)
        ? (chargeRaw == 1)
        : (chargeRaw is String)
        ? (chargeRaw.toLowerCase() == 'yes' || chargeRaw == '1' || chargeRaw.toLowerCase() == 'true')
        : (chargeRaw == true);

    List<Map<String, String>> assigned = [];
    final rawAssigned = s['assignedUsers'] ?? s['assigned_users'] ?? [];
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

    final Color priColor = _priorityColor(priority);
    final Color typeColor = _typeColor(type);
    final bool istask = type.toLowerCase() == 'task' ? true : false;


    final Color cardBg = typeColor.withOpacity(0.02);

    const int maxInlineAvatars = 2;

    final horizontalPad = _s(8, scale);
    final verticalPad = _s(8, scale);
    final borderRadius = _s(5, scale);

    // Make whole card tappable: Material+InkWell wrapping the existing Container.
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: _s(8, scale),
        vertical: _s(2, scale),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(borderRadius),
        child: InkWell(
          borderRadius: BorderRadius.circular(borderRadius),
          // onTap: () async {
          //   final changed = await Navigator.of(context).push<bool?>(
          //     MaterialPageRoute(builder: (_) => Template2Details(ticketId: id, rid: rid)),
          //   );
          //   if (changed == true && mounted) _fetchServices(forceRefresh: true);
          // },

          // from list page -- pass cacheType as well
          onTap: () async {
            final changed = await Navigator.of(context).push<bool?>(
              MaterialPageRoute(
                builder: (_) => Template2Details(
                  ticketId: id,
                  rid: rid,
                  cacheType: 'task', // or 'service' depending on source page
                ),
              ),
            );
            if (changed == true && mounted) _fetchServices(forceRefresh: true);
          },



          child: IntrinsicHeight(
            child: Container(
              decoration: BoxDecoration(
                // color: istask ? Colors.white : cardBg,
                color: istask ? Colors.white : Colors.white,
                borderRadius: BorderRadius.circular(borderRadius),
                border: Border.all(color: Colors.grey.withOpacity(0.06)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.02),
                    blurRadius: _s(6, scale),
                    offset: Offset(0, _s(3, scale)),
                  ),
                ],
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    width: _s(4, scale),
                    height: double.infinity,
                    decoration: BoxDecoration(
                      color: typeColor,
                      borderRadius: BorderRadius.only(
                        topLeft: Radius.circular(borderRadius),
                        bottomLeft: Radius.circular(borderRadius),
                      ),
                    ),
                  ),

                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: horizontalPad,
                        vertical: verticalPad,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [

                              // RID box stays at the right
                              Container(
                                padding: EdgeInsets.symmetric(
                                  horizontal: _s(8, scale),
                                  vertical: _s(5, scale),
                                ),
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(borderRadius),
                                  border: Border.all( color: priColor.withOpacity(0.22),  ),
                                ),
                                child: Text(
                                  rid,
                                  style: TextStyle(
                                    color: priColor,
                                    fontWeight: FontWeight.w700,
                                    fontSize: _s(12, scale),
                                  ),
                                ),
                              ),
                              SizedBox(width: _s(3, scale)),

                              Expanded(
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.center,
                                  children: [
                                    Icon(Icons.category, size: _s(14, scale), color: Colors.grey),
                                    SizedBox(width: _s(4, scale)),

                                    // Use AutoScrollingText in place of the plain Text
                                    Expanded(
                                      child: AutoScrollingText(
                                        text: category.isNotEmpty ? category : '-',
                                        style: TextStyle(
                                          fontSize: _s(14, scale),
                                          color: Colors.black54,
                                        ),
                                        // scale: scale,
                                        // pixelsPerSecond: 36,   // tweak speed
                                        // pauseAtEndsMillis: 750,
                                        // leadingGap: 20.0,
                                      ),
                                    ),
                                    SizedBox(width: _s(5, scale)),
                                  ],
                                ),
                              ),
                              SizedBox(width: _s(4, scale)),
                              if (((s['Type']).toString().toLowerCase()).contains('service'))
                                ChargeableToggle(
                                  initialValue: chargeable,
                                  ticketId: id,
                                  rid: rid,
                                  scale: scale,
                                  onChanged: (newVal) {
                                    // update the local model and trigger UI change
                                    if (!mounted) return;
                                    setState(() {
                                      // keep the same shape your list expects (1/0 or true/false)
                                      s['chargeable'] = newVal ? 1 : 0;
                                      // also keep any other keys you use
                                    });
                                  },
                                ),

                              SizedBox(width: _s(3, scale)),
                              if (statusName.isNotEmpty)
                                Builder(
                                  builder: (ctx) {
                                    final Color stColor = _statusColor(statusName);
                                    return Container(
                                      padding: EdgeInsets.symmetric(
                                        horizontal: _s(8, scale),
                                        vertical: _s(4, scale),
                                      ),
                                      decoration: BoxDecoration(
                                        borderRadius: BorderRadius.circular(borderRadius),
                                        border: Border.all(color: stColor.withOpacity(0.22)),
                                      ),
                                      child: Text(
                                        statusName.isNotEmpty ? statusName : '',
                                        style: TextStyle(
                                          fontSize: _s(12, scale),
                                          fontWeight: FontWeight.w600,
                                          color: stColor,
                                        ),
                                      ),
                                    );
                                  },
                                ),
                              SizedBox(width: _s(3, scale)),
                            ],
                          ),

                          SizedBox(height: _s(4, scale)),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              // make the whole area tappable and handle return value
                              Expanded(
                                child: GestureDetector(
                                  behavior: HitTestBehavior.translucent,
                                  onTap: () async {
                                    final changed = await Navigator.of(context).push<bool?>(
                                      MaterialPageRoute(builder: (_) => Template2Details(ticketId: id, rid: rid , cacheType: 'task',)),
                                    );
                                    if (changed == true && mounted) _fetchServices(forceRefresh: true);
                                  },
                                  child: Row(
                                    crossAxisAlignment: CrossAxisAlignment.center,
                                    children: [
                                      // Title: allow up to 3 lines, then ellipsize
                                      Expanded(
                                        child: Text(
                                          title,
                                          style: TextStyle(fontSize: _s(15, scale), fontWeight: FontWeight.w700),
                                          maxLines: 2,
                                          softWrap: true,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),

                                      // small spacing then blue dot if created today
                                      if (_isCreatedToday(createdAt)) ...[
                                        SizedBox(width: _s(6, scale)),
                                        Container(
                                          width: _s(9, scale),
                                          height: _s(9, scale),
                                          decoration: BoxDecoration(
                                            color: Colors.blue.shade600,
                                            shape: BoxShape.circle,
                                            boxShadow: [
                                              BoxShadow(
                                                color: Colors.blue.shade200.withOpacity(0.4),
                                                blurRadius: 4,
                                                offset: Offset(0, 1),
                                              )
                                            ],
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                              ),
                              SizedBox(width: _s(8, scale)),
                            ],
                          ),


                          SizedBox(height: _s(6, scale)),
                          Row(
                            children: [
                              Expanded(
                                flex: 8,
                                child: Row(
                                  children: [
                                    // CircleAvatar(
                                    //   radius: _s(13, scale),
                                    //   backgroundImage: (s['createdByProfile'] ?? '').toString().isNotEmpty
                                    //       ? NetworkImage(s['createdByProfile'])
                                    //       : null,
                                    //
                                    //   child: (s['createdByProfile'] ?? '').toString().isEmpty
                                    //       ? Text(
                                    //     (s['createdBy'] ?? 'U')[0].toUpperCase(),
                                    //     style: TextStyle(
                                    //
                                    //       fontWeight: FontWeight.bold,
                                    //       fontSize: _s(12, scale),
                                    //     ),
                                    //   )
                                    //       : null,
                                    // ),
                                    // SizedBox(width: _s(8, scale)),
                                    Expanded(
                                      child: Text(
                                        (s['createdBy'] ?? 'Unknown').toString(),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: _s(13, scale),
                                          color: Colors.black87,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              SizedBox(width: _s(5, scale)),

                              // Make assigned avatars tappable: shows list of assigned users.
                              Expanded(
                                flex: 5,
                                child: Align(
                                  alignment: Alignment.centerRight,
                                  child: InkWell(
                                    onTap: () {
                                      // stop propagation to parent InkWell: this is handled locally.
                                      _showAssignedList(context, assigned, scale);
                                    },
                                    borderRadius: BorderRadius.circular(8),
                                    child: _assignedAvatars(
                                      context,
                                      assigned,
                                      maxInlineAvatars,
                                      scale,
                                    ),
                                  ),
                                ),
                              ),

                            ],
                          ),

                          SizedBox(height: _s(8, scale)),

                          Row(
                            children: [
                              Expanded(
                                flex: 4,
                                child: Row(
                                    children: [
                                      Icon(
                                        Icons.access_time,
                                        size: _s(14, scale),
                                        color: Colors.orange.shade700,
                                      ),
                                      SizedBox(width: _s(5, scale)),
                                      Expanded(
                                        child: Text(
                                          createdAt,
                                          style: TextStyle(
                                            color: Colors.grey.shade600,
                                            fontSize: _s(12, scale),
                                          ),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ]),
                              ),

                              SizedBox(width: _s(6, scale)),
                              // Right side: End date
                              Row(
                                children: [
                                  Icon(
                                    Icons.access_time,
                                    size: _s(14, scale),
                                    color: Colors.blue.shade700,
                                  ),
                                  SizedBox(width: _s(5, scale)),
                                  Text(
                                    enddate,
                                    style: TextStyle(
                                      color: Colors.grey.shade600,
                                      fontSize: _s(12, scale),
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),


                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }


  bool _isCreatedToday(String createdAt) {
    if (createdAt.trim().isEmpty) return false;

    DateTime? parsed;

    // 1) try ISO-ish parse first (works for many formats)
    parsed = DateTime.tryParse(createdAt);

    // 2) try common custom formats if ISO fails
    if (parsed == null) {
      // dd-MM-yyyy or dd-MM-yyyy HH:mm
      final reDash = RegExp(r'^(\d{2})-(\d{2})-(\d{4})(?:\s+(\d{1,2}:\d{2})(?::\d{2})?)?$');
      final m1 = reDash.firstMatch(createdAt);
      if (m1 != null) {
        final day = int.tryParse(m1.group(1)!) ?? 0;
        final month = int.tryParse(m1.group(2)!) ?? 0;
        final year = int.tryParse(m1.group(3)!) ?? 0;
        parsed = DateTime(year, month, day);
      }
    }
    if (parsed == null) {
      // dd/MM/yyyy or dd/MM/yyyy HH:mm
      final reSlash = RegExp(r'^(\d{2})\/(\d{2})\/(\d{4})(?:\s+(\d{1,2}:\d{2})(?::\d{2})?)?$');
      final m2 = reSlash.firstMatch(createdAt);
      if (m2 != null) {
        final day = int.tryParse(m2.group(1)!) ?? 0;
        final month = int.tryParse(m2.group(2)!) ?? 0;
        final year = int.tryParse(m2.group(3)!) ?? 0;
        parsed = DateTime(year, month, day);
      }
    }
    if (parsed == null) {
      // yyyy-MM-dd or yyyy-MM-dd HH:mm
      final reIsoLike = RegExp(r'^(\d{4})-(\d{2})-(\d{2})(?:[T\s](\d{1,2}:\d{2})(?::\d{2})?)?$');
      final m3 = reIsoLike.firstMatch(createdAt);
      if (m3 != null) {
        final year = int.tryParse(m3.group(1)!) ?? 0;
        final month = int.tryParse(m3.group(2)!) ?? 0;
        final day = int.tryParse(m3.group(3)!) ?? 0;
        parsed = DateTime(year, month, day);
      }
    }

    if (parsed == null) return false;

    final now = DateTime.now();
    return parsed.year == now.year && parsed.month == now.month && parsed.day == now.day;
  }

// Add this helper inside the same State class (below your _serviceCard)
  void _showAssignedList(BuildContext context, List<Map<String, String>> assigned, double scale) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(12))),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 12 * scale, vertical: 8 * scale),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  height: 6 * scale,
                  width: 40 * scale,
                  margin: EdgeInsets.only(bottom: 8 * scale),
                  decoration: BoxDecoration(color: Colors.grey.shade300, borderRadius: BorderRadius.circular(4)),
                ),
                Text('Assigned Users', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16 * scale)),
                SizedBox(height: 8 * scale),
                if (assigned.isEmpty)
                  Padding(
                    padding: EdgeInsets.symmetric(vertical: 20 * scale),
                    child: Text('No assignees', style: TextStyle(color: Colors.grey.shade600)),
                  )
                else
                  Flexible(
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: assigned.length,
                      separatorBuilder: (_, __) => Divider(height: 1),
                      itemBuilder: (context, i) {
                        final a = assigned[i];
                        final profile = (a['profile'] ?? '').toString();
                        final name = (a['name'] ?? 'Unknown').toString();
                        return ListTile(
                          leading: CircleAvatar(
                            radius: 18 * scale,
                            backgroundImage: profile.isNotEmpty ? NetworkImage(profile) : null,
                            // backgroundColor: profile.isEmpty ? Colors.grey.shade400 : Colors.transparent,
                            child: profile.isEmpty ? Text(name.isNotEmpty ? name[0].toUpperCase() : 'U', style: TextStyle(color: Colors.white)) : null,
                          ),
                          title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
                          onTap: () {
                            // optional: close modal and navigate to user-specific page if needed
                            Navigator.of(ctx).pop();
                          },
                        );
                      },
                    ),
                  ),
                SizedBox(height: 12 * scale),
              ],
            ),
          ),
        );
      },
    );
  }



  Widget _assignedAvatars(
      BuildContext context,
      List<Map<String, String>> assigned,
      int maxInlineAvatars,
      double scale,
      ) {
    return InkWell(
      onTap:
      assigned.isEmpty
          ? null
          : () => _showAssignedUsersModal(context, assigned),
      borderRadius: BorderRadius.circular(_s(20, scale)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (assigned.isEmpty)
            Text(
              'No assignees',
              style: TextStyle(
                color: Colors.grey.shade600,
                fontSize: _s(13, scale),
              ),
            )
          else ...[
            ...List.generate(
              (assigned.length > maxInlineAvatars
                  ? maxInlineAvatars
                  : assigned.length),
                  (idx) {
                final bool isOverflowSlot =
                    assigned.length > maxInlineAvatars &&
                        idx == (maxInlineAvatars - 1);
                if (isOverflowSlot) {
                  final remaining = assigned.length - (maxInlineAvatars - 1);
                  return Container(
                    margin: EdgeInsets.only(left: _s(6, scale)),
                    width: _s(25, scale),
                    height: _s(25, scale),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade200,
                      borderRadius: BorderRadius.circular(_s(16, scale)),
                    ),
                    child: Center(
                      child: Text(
                        '+$remaining',
                        style: TextStyle(
                          color: Colors.grey.shade800,
                          fontWeight: FontWeight.w600,
                          fontSize: _s(12, scale),
                        ),
                      ),
                    ),
                  );
                }
                final au = assigned[idx];
                final aname = (au['name'] ?? '').toString();
                final aprofile = (au['profile'] ?? '').toString();
                return Container(
                  margin: EdgeInsets.only(left: _s(6, scale)),
                  child: CircleAvatar(
                    radius: _s(13, scale),
                    backgroundImage:
                    aprofile.isNotEmpty ? NetworkImage(aprofile) : null,
                    child:
                    aprofile.isEmpty
                        ? Text(
                      aname.isNotEmpty ? aname[0].toUpperCase() : '?',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: _s(12, scale),
                      ),
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

  Future<void> _showAssignedUsersModal(
      BuildContext context,
      List<Map<String, String>> assigned,
      ) {
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
              decoration: BoxDecoration(
                color: Theme.of(context).canvasColor,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(16),
                ),
              ),
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14.0,
                      vertical: 12,
                    ),
                    child: Row(
                      children: [
                        const Expanded(
                          child: Text(
                            'Assigned Users',
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 16,
                            ),
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
                    child: ListView.separated(
                      controller: sc,
                      padding: const EdgeInsets.symmetric(
                        vertical: 8,
                        horizontal: 12,
                      ),
                      itemCount: assigned.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (_, i) {
                        final u = assigned[i];
                        final name = (u['name'] ?? '').toString();
                        final profile = (u['profile'] ?? '').toString();
                        return ListTile(
                          leading:
                          profile.isNotEmpty
                              ? CircleAvatar(
                            radius: 20,
                            backgroundImage: NetworkImage(profile),

                          )
                              : CircleAvatar(
                            radius: 20,
                            backgroundColor: Colors.grey.shade300,
                            child: Text(
                              name.isNotEmpty
                                  ? name[0].toUpperCase()
                                  : '?',
                            ),
                          ),
                          title: Text(name.isNotEmpty ? name : '-'),
                          onTap: () {},
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


  Widget _smallHeader(double scale) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: _s(12.0, scale), vertical: _s(6, scale)),
      child: Row(
        children: [
          // Search input
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(right: _s(8.0, scale)),
              child: TextField(
                onChanged: (val) => setState(() => _searchQuery = val),
                controller: TextEditingController(text: _searchQuery)
                  ..selection = TextSelection.fromPosition(
                    TextPosition(offset: _searchQuery.length),
                  ),
                style: TextStyle(fontSize: _s(14, scale)),
                decoration: InputDecoration(
                  hintText: 'Search RID or category ...',
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(
                    vertical: _s(8, scale),
                    horizontal: _s(8, scale),
                  ),
                  enabledBorder: const UnderlineInputBorder(
                    borderSide: BorderSide(color: Colors.grey),
                  ),
                  focusedBorder: const UnderlineInputBorder(
                    borderSide: BorderSide(color: Colors.deepPurple),
                  ),
                ),
              ),
            ),
          ),

          // Dynamic icon — search or cancel
          IconButton(
            icon: Icon(
              _searchQuery.isEmpty ? Icons.search : Icons.close,
              size: _s(22, scale),
            ),
            onPressed: () {
              if (_searchQuery.isNotEmpty) {
                setState(() => _searchQuery = "");
                FocusScope.of(context).unfocus(); // Dismiss keyboard
              }
            },
          ),
        ],
      ),
    );
  }

  // PRIORITY filter row (clickable only; removed toggle and sliding reaction)
  Widget _buildPriorityFilterWithNoToggle(double scale) {
    final options = _priorityOptions;
    return Container(
      padding: EdgeInsets.symmetric(
        vertical: _s(6, scale),
        horizontal: _s(6, scale),
      ),
      color: Colors.white,
      child: Row(
        children:
        options.map((opt) {
          final selected = _selectedPriority == opt;
          return Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _selectedPriority = opt),
              child: Container(
                margin: EdgeInsets.symmetric(horizontal: _s(6, scale)),
                padding: EdgeInsets.symmetric(vertical: _s(10, scale)),
                decoration: BoxDecoration(
                  color: selected ? _primaryPurple : Colors.grey.shade200,
                  borderRadius: BorderRadius.circular(_s(8, scale)),
                ),
                child: Center(
                  child: Text(
                    opt,
                    style: TextStyle(
                      color: selected ? Colors.white : Colors.black54,
                      fontWeight: FontWeight.w600,
                      fontSize: _s(13, scale),
                    ),
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildStatusAndAssigneeRow(double scale) {
    // safer lookup -> string fallback
    final selectedAssigneeName = (_assignees.firstWhere(
          (a) => a['id'] == _selectedAssigneeId,
      orElse: () => {'name': 'All assignees'},
    )['name']?.toString()) ??
        'All assignees';

    final selectedStatusName = _selectedStatus ?? 'All';

    return Container(
      color: Colors.white,
      padding: EdgeInsets.symmetric(
        horizontal: _s(10, scale),
        vertical: _s(4, scale),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // -------- STATUS selector --------
          Expanded(
            flex: 3,
            child: GestureDetector(
              onTap: () => _showStatusModal(),
              child: Stack(
                clipBehavior: Clip.none, // ✅ allows floating label to overflow
                children: [
                  // main container
                  Container(
                    padding: EdgeInsets.symmetric(
                      horizontal: _s(10, scale),
                      vertical: _s(12, scale),
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(_s(8, scale)),
                      border: Border.all(color: Colors.grey.shade400, width: 1.2),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.03),
                          blurRadius: 4,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.flag, size: _s(18, scale), color: Colors.black54),
                        SizedBox(width: _s(8, scale)),
                        Expanded(
                          child: Text(
                            selectedStatusName.isNotEmpty
                                ? selectedStatusName
                                : 'Select status',
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              color: selectedStatusName.isNotEmpty
                                  ? Colors.black87
                                  : Colors.grey.shade500,
                            ),
                          ),
                        ),
                        SizedBox(width: _s(8, scale)),
                        Icon(Icons.arrow_drop_down, size: _s(20, scale), color: Colors.black54),
                      ],
                    ),
                  ),

                  // floating label
                  Positioned(
                    left: _s(12, scale),
                    top: _s(-6, scale), // ✅ move label higher
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      color: Colors.white, // covers border behind label
                      child: Text(
                        "Status",
                        style: TextStyle(
                          fontSize: _s(12, scale),
                          fontWeight: FontWeight.w600,
                          color: _primaryPurple,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          SizedBox(width: _s(6, scale)),

          // -------- ASSIGNEE selector (only show when more than one assignee) --------
          if ((_assignees?.length ?? 0) > 2) ...[
            Expanded(
              flex: 3,
              child: GestureDetector(
                onTap: () => _showAssigneeModal(),
                child: Stack(
                  clipBehavior: Clip.none, // ✅ allows floating label overflow
                  children: [
                    // main container
                    Container(
                      padding: EdgeInsets.symmetric(
                        horizontal: _s(10, scale),
                        vertical: _s(12, scale),
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(_s(8, scale)),
                        border: Border.all(color: Colors.grey.shade400, width: 1.2),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.03),
                            blurRadius: 4,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.person, size: _s(18, scale), color: Colors.black54),
                          SizedBox(width: _s(8, scale)),
                          Expanded(
                            child: Text(
                              selectedAssigneeName.isNotEmpty
                                  ? selectedAssigneeName
                                  : 'Select assignee',
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                color: selectedAssigneeName.isNotEmpty
                                    ? Colors.black87
                                    : Colors.grey.shade500,
                              ),
                            ),
                          ),
                          SizedBox(width: _s(8, scale)),
                          Icon(Icons.arrow_drop_down, size: _s(20, scale), color: Colors.black54),
                        ],
                      ),
                    ),

                    // floating label
                    Positioned(
                      left: _s(12, scale),
                      top: _s(-6, scale), // ✅ lifted for better visibility
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        color: Colors.white,
                        child: Text(
                          "Assignee",
                          style: TextStyle(
                            fontSize: _s(12, scale),
                            fontWeight: FontWeight.w600,
                            color: _primaryPurple,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],

          SizedBox(width: _s(6, scale)),

          // -------- toggle: expand/collapse search+priority --------
          InkWell(
            onTap: () => setState(() => _showSearchPriorityRow = !_showSearchPriorityRow),
            borderRadius: BorderRadius.circular(8),
            child: Container(
              padding: EdgeInsets.all(_s(10, scale)),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.grey.shade300),
              ),
              child: Icon(
                _showSearchPriorityRow ? Icons.expand_less : Icons.expand_more,
                size: _s(20, scale),
                color: Colors.black54,
              ),
            ),
          ),

          SizedBox(width: _s(6, scale)),

          // -------- clear filters button --------
          if (_selectedCardType != 'All' ||
              _selectedPriority != 'All' ||
              _selectedStatus != 'All' ||
              _selectedAssigneeId != 'All')
            InkWell(
              onTap: () => setState(() {
                _selectedCardTypeIndex = 0; // reset to Task
                _selectedPriority = 'All';
                _selectedStatus = 'All';
                _selectedAssigneeId = 'All';
              }),
              borderRadius: BorderRadius.circular(8),
              child: Container(
                padding: EdgeInsets.all(_s(10, scale)),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.grey.shade300),
                ),
                child: Icon(
                  Icons.restart_alt_sharp,
                  size: _s(20, scale),
                  color: Colors.black54,
                ),
              ),
            ),
        ],
      ),
    );
  }



  Future<void> _showAssigneeModal() async {
    final TextEditingController searchCtrl = TextEditingController();
    List<Map<String, dynamic>> filtered = List.from(_assignees);

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (c) {
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            void doFilter(String q) {
              final query = q.trim().toLowerCase();
              setModalState(() {
                if (query.isEmpty) {
                  filtered = List.from(_assignees);
                } else {
                  filtered = _assignees
                      .where((a) =>
                      (a['name'] ?? '')
                          .toString()
                          .toLowerCase()
                          .contains(query))
                      .toList();
                }
              });
            }

            return DraggableScrollableSheet(
              expand: false,
              initialChildSize: 0.55,
              minChildSize: 0.3,
              maxChildSize: 0.9,
              builder: (ctx2, sc) {
                return Container(
                  decoration: BoxDecoration(
                    color: Theme.of(context).canvasColor,
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(16),
                    ),
                  ),
                  child: Column(
                    children: [
                      // Header row
                      Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14.0, vertical: 12),
                        child: Row(
                          children: [
                            const Expanded(
                              child: Text(
                                'Select assignee',
                                style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 16,
                                ),
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.close),
                              onPressed: () => Navigator.of(ctx).pop(),
                            ),
                          ],
                        ),
                      ),

                      // Search bar
                      Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 4),
                        child: TextField(
                          controller: searchCtrl,
                          // autofocus: true,
                          onChanged: doFilter,
                          decoration: InputDecoration(
                            hintText: 'Search assignee...',
                            prefixIcon: const Icon(Icons.search),
                            suffixIcon: searchCtrl.text.isNotEmpty
                                ? IconButton(
                              icon: const Icon(Icons.clear),
                              onPressed: () {
                                searchCtrl.clear();
                                doFilter('');
                              },
                            )
                                : null,
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                            contentPadding: const EdgeInsets.symmetric(
                                vertical: 10, horizontal: 12),
                          ),
                        ),
                      ),

                      const Divider(height: 1),

                      // List of assignees
                      Expanded(
                        child: filtered.isEmpty
                            ? const Center(
                          child: Text(
                            'No assignees found',
                            style: TextStyle(color: Colors.grey),
                          ),
                        )
                            : ListView.separated(
                          controller: sc,
                          padding: const EdgeInsets.symmetric(
                              vertical: 8, horizontal: 12),
                          itemCount: filtered.length,
                          separatorBuilder: (_, __) =>
                          const Divider(height: 1),
                          itemBuilder: (_, i) {
                            final a = filtered[i];
                            final name =
                            (a['name'] ?? '').toString().trim();
                            final selected =
                                a['id'] == _selectedAssigneeId;
                            final profile = (a['profile'] ?? '').toString();
                            return ListTile(
                              dense: true,
                              contentPadding:
                              const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 4),

                            leading: profile.isNotEmpty
                                ? CircleAvatar(
                              radius: 18,
                              backgroundImage: NetworkImage(profile),
                            )
                                : CircleAvatar(
                              radius: 18,
                              child: Text(
                                name.isNotEmpty ? name[0].toUpperCase() : '?',
                                style: const TextStyle(fontWeight: FontWeight.bold),
                              ),
                            ),

                            title: Text(
                                name.isNotEmpty ? name : '-',
                                style: const TextStyle(fontSize: 15),
                              ),
                              trailing: selected
                                  ? Icon(
                                Icons.check_circle,
                                color: Theme.of(context)
                                    .colorScheme
                                    .primary,
                              )
                                  : null,
                              onTap: () {
                                setState(() => _selectedAssigneeId =
                                a['id']!);
                                Navigator.of(context).pop();
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
      },
    );
  }


  Future<void> _showStatusModal() async {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (c) {
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.35,
          minChildSize: 0.2,
          maxChildSize: 0.6,
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
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14.0,
                      vertical: 12,
                    ),
                    child: Row(
                      children: [
                        const Expanded(
                          child: Text(
                            'Select status',
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 16,
                            ),
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
                    child: ListView.separated(
                      controller: sc,
                      padding: const EdgeInsets.symmetric(
                        vertical: 8,
                        horizontal: 12,
                      ),
                      itemCount: _statusOptions.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (_, i) {
                        final s = _statusOptions[i];
                        final sel = s == _selectedStatus;
                        return ListTile(
                          leading: Container(
                            width: 36,
                            height: 36,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: _statusColor(s).withOpacity(0.12),
                            ),
                            child: Center(
                              child: Icon(Icons.flag, color: _statusColor(s)),
                            ),
                          ),
                          title: Text(s),
                          trailing:
                          sel
                              ? Icon(
                            Icons.check,
                            color: Colors.green.shade700,
                          )
                              : null,
                          onTap: () {
                            setState(() => _selectedStatus = s);
                            Navigator.of(context).pop();
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

  void _assignedUsersToast() {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('No assignees found for this project.')),
    );
  }

  Color _typeColor(String type) {
    final t = type.toLowerCase();
    if (t.contains('task')) return const Color(0xFF8E8E8E);   // #666666
    if (t.contains('service')) return const Color(0xFFF8790C); // #f8790c
    if (t.contains('invoice')) return const Color(0xFF2E86AB); // keep invoice as before (blue) or change if needed
    return Colors.grey.shade700;
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

// status color helper (updated)
  Color _statusColor(String label) {
    final s = label.toLowerCase();
    if (s.contains('new') || s.contains('new sr')) return const Color(0xFF3B7080);       // #3B7080
    if (s.contains('pending')) return const Color(0xFFF26522);                          // #F26522
    if (s.contains('in progress') || s.contains('inprogress')) return const Color(
        0xFFBC8F07); // #FFC107
    if (s.contains('extend') || s.contains('extended')) return const Color(0xFF1B84FF);  // #1B84FF
    if (s.contains('completed')) return const Color(0xFF03C95A);                         // #03C95A
    return Colors.grey;
  }


// ... SERVICE CARD and helper widgets remain unchanged.  (Truncated in update to keep focus on filter/interaction logic.)

// (Keep the rest of the file identical to your existing _serviceCard, _assignedAvatars, _showAssignedUsersModal, _chargeablePill, _typeIcon, _typeColor, _priorityColor implementations.)
}


class ChargeableToggle extends StatefulWidget {
  final bool initialValue;
  final String ticketId;
  final String rid;
  final ValueChanged<bool>? onChanged;
  final double scale;

  const ChargeableToggle({
    Key? key,
    required this.initialValue,
    required this.ticketId,
    required this.rid,
    this.onChanged,
    this.scale = 1.0,
  }) : super(key: key);

  @override
  _ChargeableToggleState createState() => _ChargeableToggleState();
}

class _ChargeableToggleState extends State<ChargeableToggle> {
  late bool _value;
  bool _loading = false;
  final Duration _animDuration = const Duration(milliseconds: 300);
  final Dio _dio = Dio(); // reuse if possible

  @override
  void initState() {
    super.initState();
    _value = widget.initialValue;
  }

  @override
  void dispose() {
    _dio.close();
    super.dispose();
  }

  Future<String> _buildUpdateChargableApiUrl() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('user_data');

    String slug = '';
    String domain = '';

    if (raw != null) {
      try {
        final Map<String, dynamic> data = jsonDecode(raw);
        slug = (data['slug'] ?? '').toString();
        domain = (data['domain'] ?? '').toString();
      } catch (_) {}
    }

    // fallbacks
    slug = slug.isNotEmpty ? slug : (prefs.getString('slug') ?? '');
    domain = domain.isNotEmpty ? domain : (prefs.getString('domain') ?? '');

    if (slug.isEmpty || domain.isEmpty) {
      throw Exception('Missing slug/domain in local storage');
    }

    // ensure trailing slash if needed
    final normalizedDomain = domain.endsWith('/') ? domain : '$domain/';
    final normalizedSlug = slug.endsWith('/') ? slug : '$slug/';

    // final URL (POST)
    return '${normalizedDomain}${normalizedSlug}updateChargableApi';
  }

  Future<Map<String, dynamic>> _callUpdateChargableApi({
    required String tktId,
    required String rid,
    required int chargable,
    void Function(int sent, int total)? onSendProgress,
  }) async {
    final url = await _buildUpdateChargableApiUrl();

    // Build form data (multipart/form-data)
    final form = FormData.fromMap({
      'tkt_id': int.tryParse(tktId) ?? tktId,
      'chargable': chargable,
    });

    try {
      // No special headers — send raw form-data
      final resp = await _dio.post(
        url,
        data: form,
        options: Options(
          // Do not add auth headers or content-type here.
          // Dio will set multipart/form-data automatically for FormData.
          headers: {},
          responseType: ResponseType.json,
        ),
        onSendProgress: onSendProgress,
      );

      // resp.data should already be decoded JSON (Map)
      if (resp.statusCode != null && resp.statusCode! >= 200 && resp.statusCode! < 300) {
        final data = resp.data;
        if (data is Map<String, dynamic>) {
          return data;
        } else if (data is String) {
          return jsonDecode(data) as Map<String, dynamic>;
        } else {
          // try to coerce
          return Map<String, dynamic>.from(data);
        }
      } else {
        throw Exception('Server responded ${resp.statusCode}');
      }
    } on DioException catch (e) {
      // If server returned a body with error JSON, try to pull message
      if (e.response != null && e.response!.data != null) {
        final d = e.response!.data;
        if (d is Map && d['message'] != null) {
          throw Exception(d['message'].toString());
        }
      }
      throw Exception('Network error: ${e.message}');
    } catch (e) {
      throw Exception('Error: $e');
    }
  }

  Future<void> _onTapToggle() async {
    final newValue = !_value;
    final rid = widget.rid;
    final actionText = newValue ? 'confirm' : 'cancel';
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Confirm'),
        content: Text('Are you sure you want to $actionText this invoice?'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Yes')),
        ],
      ),
    );

    if (confirm != true) return;

    // optimistic update
    setState(() {
      _value = newValue;
      _loading = true;
    });

    try {
      final result = await _callUpdateChargableApi(
        tktId: widget.ticketId,
        rid: widget.rid,
        chargable: _value ? 1 : 0,
      );

      if (result['success'] == true) {
        widget.onChanged?.call(_value);
        if (mounted) {
          // ScaffoldMessenger.of(context).showSnackBar(
          //   SnackBar(content: Text(result['message']?.toString() ?? 'Updated')),
          // );
          final meesage = result['message']?.toString() ?? 'Updated';
          Fluttertoast.showToast(
            msg: meesage,
            toastLength: Toast.LENGTH_SHORT,
            gravity: ToastGravity.BOTTOM,
            backgroundColor: Colors.green,
            textColor: Colors.white,
            fontSize: 14.0,
          );

        }
      } else {
        // server returned success:false
        _rollback(result['message']?.toString() ?? 'Update failed');
      }
    } catch (e) {
      _rollback(e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _rollback(String message) {
    if (mounted) {
      setState(() => _value = !_value);
      // ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));

      Fluttertoast.showToast(
        msg: message,
        toastLength: Toast.LENGTH_SHORT,
        gravity: ToastGravity.BOTTOM,
        backgroundColor: Colors.redAccent.shade200,
        textColor: Colors.white,
        fontSize: 14.0,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final scale = widget.scale;
    final padH = 8.0 * scale;
    final padV = 5.0 * scale;
    final iconSize = 15.0 * scale;
    final textSize = 12.0 * scale;
    final circleSize = 14.0 * scale;

    final backgroundColor = _value ? Colors.green.shade50 : Colors.grey.shade100;
    final borderColor = _value ? Colors.green.withOpacity(0.25) : Colors.grey.shade200;
    final iconColor = _value ? Colors.green.shade700 : Colors.grey.shade600;
    final textColor = _value ? Colors.green.shade700 : Colors.black54;
    final circleBg = _value ? Colors.green : Colors.grey.shade400;

    return GestureDetector(
      onTap: _loading ? null : _onTapToggle,
      child: AnimatedContainer(
        duration: _animDuration,
        padding: EdgeInsets.symmetric(horizontal: padH, vertical: padV),
        decoration: BoxDecoration(
          color: backgroundColor,
          borderRadius: BorderRadius.circular(20.0 * scale),
          border: Border.all(color: borderColor),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.currency_rupee, size: iconSize, color: iconColor),

            SizedBox(width: 3.0 * scale),
            AnimatedSwitcher(
              duration: _animDuration,
              transitionBuilder: (child, animation) {
                return ScaleTransition(scale: animation, child: FadeTransition(opacity: animation, child: child));
              },
              child: _loading
                  ? SizedBox(
                key: const ValueKey('loading'),
                width: circleSize,
                height: circleSize,
                child: Center(
                  child: SizedBox(
                    width: circleSize - 6,
                    height: circleSize - 6,
                    child: const CircularProgressIndicator(strokeWidth: 2.0),
                  ),
                ),
              )
                  : Container(
                key: ValueKey('circle_${_value ? 'checked' : 'unchecked'}'),
                width: circleSize,
                height: circleSize,
                decoration: BoxDecoration(color: circleBg, shape: BoxShape.circle),
                child: Icon(_value ? Icons.check : Icons.close, size: 10.0 * scale, color: Colors.white),
              ),
            ),
          ],
        ),
      ),
    );
  }
}