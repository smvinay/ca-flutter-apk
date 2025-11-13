// notifications_page_compact.dart
import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/gestures.dart';
import 'widgets/AutoScrollingText.dart';

class NotificationsPage extends StatefulWidget {
  const NotificationsPage({Key? key}) : super(key: key);

  @override
  State<NotificationsPage> createState() => _NotificationsPageState();
}

class _NotificationsPageState extends State<NotificationsPage> {
  final Dio _dio = Dio();
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _notifications = [];

  // Date format required by user
  final DateFormat _dtFormat = DateFormat('dd-MM-yyyy HH:mm');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _fetchNotifications());
  }

  @override
  void dispose() {
    _dio.close();
    super.dispose();
  }

  // Add this method to extract assignee names
  String _extractAssigneeNames(Map<String, dynamic> notification) {
    final assignToNames = notification['assign_to_names']?.toString();
    if (assignToNames != null && assignToNames.isNotEmpty && assignToNames != 'null') {
      return assignToNames;
    }
    return '';
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
      } catch (_) {}
    }
    if (slug.isEmpty) slug = prefs.getString('slug') ?? '';
    final base = (domain ?? '').endsWith('/') ? domain : '$domain/';
    return Uri.parse('$base$slug/dashboardApi?id=$id&type=$type&slug=$slug');
  }

  Future<void> _fetchNotifications({bool showLoading = true}) async {
    if (!mounted) return;
    if (showLoading) {
      setState(() {
        _loading = true;
        _error = null;
      });
    } else {
      setState(() => _error = null);
    }

    try {
      final uri = await _buildUserStatsUri();
      final resp = await _dio.getUri(uri).timeout(const Duration(seconds: 12));
      if (resp.statusCode != 200) {
        throw Exception('Server returned ${resp.statusCode}');
      }

      final body = resp.data;
      final Map<String, dynamic> dataWrapper =
      (body is Map && body.containsKey('data')) ? Map<String, dynamic>.from(body['data']) : (body is Map ? Map<String, dynamic>.from(body) : {});

      // UPDATED: Use 'notify' instead of 'logs'
      final List notifyRaw = (dataWrapper['notify'] is List) ? dataWrapper['notify'] : [];

      final List<Map<String, dynamic>> notifications = notifyRaw.map<Map<String, dynamic>>((e) {
        if (e is Map) return Map<String, dynamic>.from(e);
        return {'id': null, 'remarks': e.toString()};
      }).toList();

      setState(() {
        _notifications = notifications;
        _loading = false;
        _error = null;
      });
    } on TimeoutException {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Request timed out. Pull to retry.';
      });
    } catch (e, st) {
      if (!mounted) return;
      if (kDebugMode) debugPrint('Fetch notifications error: $e\n$st');
      setState(() {
        _loading = false;
        _error = 'Sorry, something went wrong there. Try again.';
      });
    }
  }

  String _extractUserName(Map<String, dynamic> notification) {
    // UPDATED: Use account_name or company_name from notify data
    if (notification['account_name'] != null && notification['account_name'].toString().isNotEmpty) {
      return notification['account_name'].toString();
    }
    if (notification['company_name'] != null && notification['company_name'].toString().isNotEmpty) {
      return notification['company_name'].toString();
    }
    return '';
  }


  Map<String, String> _extractActionParts(Map<String, dynamic> notification) {
    // returns {'title': ..., 'body': ...} - both non-null strings (may be empty)
    String title = '';
    String body = '';

    final sourceTable = notification['source_table']?.toString();

    if (sourceTable == 'ticket') {
      // For tickets, use title + description
      final t = (notification['title'] ?? '').toString().trim();
      final d = (notification['task_description'] ?? '').toString().trim();

      if (t.isNotEmpty && d.isNotEmpty) {
        title = t;
        body = d;
        return {'title': title, 'body': body};
      } else if (t.isNotEmpty) {
        title = t;
        body = '';
        return {'title': title, 'body': body};
      } else if (d.isNotEmpty) {
        title = '';
        body = d;
        return {'title': title, 'body': body};
      }
    }

    // For elogs or fallback, use remarks
    final remarks = (notification['remarks'] ?? '').toString().trim();
    if (remarks.isNotEmpty) {
      return {'title': '', 'body': remarks};
    }

    // all else fallback
    return {'title': '', 'body': ''};
  }


  String _getStatusText(dynamic status) {
    final statusCode = int.tryParse(status?.toString() ?? '0') ?? 0;
    switch (statusCode) {
      case 0: return 'New SR';
      case 1: return 'Pending';
      case 2: return 'In Progress';
      case 3: return 'Extended';
      case 4: return 'Completed';
      default: return 'Updated';
    }
  }

  String _formatDateShort(String raw) {
    if (raw.isEmpty) return '';
    try {
      DateTime? dt = DateTime.tryParse(raw);
      if (dt == null && raw.contains('-')) {
        // try common alternative by swapping separators
        final alt = raw.replaceAll('-', '/');
        dt = DateTime.tryParse(alt);
      }
      if (dt != null) return _dtFormat.format(dt);
    } catch (_) {}
    return raw;
  }

  Color _typeColor(String type) {
    final t = type.toLowerCase();
    if (t.contains('task')) return const Color(0xFF8E8E8E);   // #666666
    if (t.contains('service')) return const Color(0xFFF8790C); // #f8790c
    if (t.contains('invoice')) return const Color(0xFF2E86AB); // keep invoice as before (blue) or change if needed
    return Colors.grey.shade700;
  }

  String _getUserType(Map<String, dynamic> notification) {
    final userType = notification['usertype']?.toString();
    switch (userType) {
      case '1': return 'Admin';
      case '2': return 'User';
      case '3': return 'Client';
      default: return 'User';
    }
  }

  // NEW: Get task type for left border color
  String _getTaskType(Map<String, dynamic> notification) {

      final taskSr = notification['task_sr']?.toString();
      if (taskSr == '1') return 'Task';
      if (taskSr == '2') return 'Service';
      return 'Task'; // Default

  }

  // NEW: Get left border color based on task type
  Color _getLeftBorderColor(String taskType) {
    return _typeColor(taskType);
  }

  @override
  Widget build(BuildContext context) {
    // scale based on width
    final width = MediaQuery.of(context).size.width;
    final s = (width / 390.0).clamp(0.82, 1.12);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Recent Activities'),
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : (_error != null)
            ? Center(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.red)),
              const SizedBox(height: 12),
              ElevatedButton.icon(onPressed: () => _fetchNotifications(), icon: const Icon(Icons.refresh), label: const Text('Retry'))
            ]),
          ),
        )
            : RefreshIndicator(
          onRefresh: () => _fetchNotifications(showLoading: false),
          child: _notifications.isEmpty
              ? Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.notifications_none, size: 64, color: Colors.grey.shade400),
                SizedBox(height: 16),
                Text(
                  'No recent activities',
                  style: TextStyle(fontSize: 16, color: Colors.grey.shade600),
                ),
                SizedBox(height: 8),
                Text(
                  'Your recent activities will appear here',
                  style: TextStyle(fontSize: 14, color: Colors.grey.shade500),
                ),
              ],
            ),
          )
              : ListView.separated(
            padding: EdgeInsets.symmetric(horizontal: 12.0 * s, vertical: 8.0 * s),
            itemCount: _notifications.length,
            separatorBuilder: (_, __) => SizedBox(height: 8.0 * s),
            itemBuilder: (ctx, i) {
              final item = _notifications[i];
              // final action = _extractActionMessage(item);

              final parts = _extractActionParts(item);
              final titleText = parts['title'] ?? '';
              final bodyText = parts['body'] ?? '';
              // define base styles (inherit from context)
              final baseStyle = TextStyle(fontSize: 12.0 * s, color: Colors.grey.shade800, height: 1.18);
              final titleStyle = baseStyle.copyWith(fontWeight: FontWeight.w700); // bold
              final bodyStyle = baseStyle.copyWith(fontWeight: FontWeight.w400);

              final profile = (item['user_profile'] ?? item['logo'] ?? '').toString();
              final userName = _extractUserName(item);
              final createdAtRaw = (item['created_at'] ?? item['updated_at'] ?? '').toString();
              final createdAt = _formatDateShort(createdAtRaw);
              final type = _getUserType(item);
              final status = _getStatusText(item['status']);
              final taskType = _getTaskType(item);
              final leftBorderColor = _getLeftBorderColor(taskType);

              // avatar and sizes
              final avatarRadius = 15.0 * s;
              final avatarWidget = CircleAvatar(
                radius: avatarRadius,
                // backgroundColor: Colors.grey.shade200,
                backgroundImage: profile.isNotEmpty ? NetworkImage(profile) as ImageProvider : null,
                child: profile.isEmpty
                    ? Text(
                  (userName.isNotEmpty ? userName : 'U').trim().split(' ').map((p) => p.isNotEmpty ? p[0] : '').take(1).join().toUpperCase(),
                  style: TextStyle(fontWeight: FontWeight.bold, color: Colors.black54, fontSize: 12.0 * s),
                )
                    : null,
              );

              return Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(8.0 * s),
                  boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.03), blurRadius: 6.0 * s, offset: Offset(0, 2.0 * s))],
                  border: Border(
                    left: BorderSide(
                      color: leftBorderColor,
                      width: 3.0 * s,
                    ),
                  ),
                ),
                padding: EdgeInsets.all(10.0 * s),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // avatar
                    avatarWidget,
                    SizedBox(width: 8.0 * s),

                    // main column
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // top row: name+type (left) and date/time (right)
                          Row(
                            children: [
                              Expanded(
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.center,
                                  children: [
                                    Flexible(
                                      child: RichText(
                                        text: TextSpan(
                                          children: [
                                            TextSpan(
                                              text: userName, // main user name
                                              style: TextStyle(
                                                color: Colors.red.shade700,
                                                fontWeight: FontWeight.w500,
                                                fontSize: 13.5 * s,
                                              ),
                                            ),
                                            TextSpan(
                                              text: '  assigned to  ',
                                              style: TextStyle(
                                                color: Colors.grey.shade500,
                                                fontWeight: FontWeight.w500,
                                                fontSize: 13.0 * s,
                                              ),
                                            ),
                                            TextSpan(
                                              text: _extractAssigneeNames(item), // assigned users
                                              style: TextStyle(
                                                color: Colors.grey.shade800,
                                                fontWeight: FontWeight.w500,
                                                fontSize: 13.0 * s,
                                              ),
                                            ),
                                          ],
                                        ),
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),

                                    SizedBox(width: 4.0 * s),

                                    Container(
                                      padding: EdgeInsets.symmetric(horizontal: 6.0 * s, vertical: 3.0 * s),
                                      decoration: BoxDecoration(
                                        color: _getStatusColor(status).withOpacity(0.12),
                                        borderRadius: BorderRadius.circular(5.0 * s),
                                      ),
                                      child: Text(
                                        status,
                                        style: TextStyle(
                                          fontSize: 11.0 * s,
                                          fontWeight: FontWeight.w700,
                                          color: _getStatusColor(status),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),

                            ],
                          ),
                          // SizedBox(height: 3.0 * s),
                          if(titleText.isNotEmpty || bodyText.isNotEmpty)
                          // _buildNotificationPreview(
                          //   context,
                          //   titleText: titleText, // your title string
                          //   bodyText: bodyText,   // your body string
                          //   titleStyle : titleStyle,
                          //   bodyStyle : bodyStyle,
                          //   maxLinesPreview: 3,   // how many lines to show by default
                          // ),
                            NotificationPreview(
                              titleText: titleText,
                              bodyText: bodyText,
                              titleStyle: titleStyle,
                              bodyStyle: bodyStyle,
                              maxLinesPreview: 3,
                            ),


                          if ((item['rid'] ?? '').toString().isNotEmpty)
                            Padding(
                              padding: EdgeInsets.only(top: 6.0 * s),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  // 🗓️ Date
                                  Expanded(
                                    child: Row(
                                      children: [
                                        Icon(Icons.calendar_today, size: 12.0 * s, color: Colors.grey.shade500),
                                        SizedBox(width: 4.0 * s),
                                        Text(
                                          createdAt.split(' ').first, // Extract date if string has both date/time
                                          style: TextStyle(fontSize: 11.0 * s, color: Colors.grey.shade600),
                                        ),
                                      ],
                                    ),
                                  ),

                                  // ⏰ Time
                                  Expanded(
                                    child: Row(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        Icon(Icons.access_time, size: 12.0 * s, color: Colors.grey.shade500),
                                        SizedBox(width: 4.0 * s),
                                        Text(
                                          createdAt.contains(' ')
                                              ? createdAt.split(' ').last
                                              : createdAt, // fallback if only date present
                                          style: TextStyle(fontSize: 11.0 * s, color: Colors.grey.shade600),
                                        ),
                                      ],
                                    ),
                                  ),

                                  // 🎫 Ticket ID (RID)
                                  Expanded(
                                    child: Row(
                                      mainAxisAlignment: MainAxisAlignment.end,
                                      children: [
                                        Icon(Icons.confirmation_number, size: 12.0 * s, color: Colors.grey.shade500),
                                        SizedBox(width: 4.0 * s),
                                        Text(
                                          '${item['rid']}',
                                          style: TextStyle(fontSize: 11.0 * s, color: Colors.grey.shade600),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),

                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }


  Color _getStatusColor(String status) {
    final s = status.toLowerCase();
    if (s.contains('new') || s.contains('new sr')) return const Color(0xFF3B7080);       // #3B7080
    if (s.contains('pending')) return const Color(0xFFF26522);                          // #F26522
    if (s.contains('in progress') || s.contains('inprogress')) return const Color(0xFFBC8F07); // #FFC107
    if (s.contains('extend') || s.contains('extended')) return const Color(0xFF1B84FF);  // #1B84FF
    if (s.contains('completed')) return const Color(0xFF03C95A);                         // #03C95A
    return Colors.grey;
  }
}


/// A notification preview widget that shows title+body combined,
/// detects overflow and toggles expand/collapse with a smooth height animation.
class NotificationPreview extends StatefulWidget {
  final String titleText;
  final String bodyText;
  final TextStyle? titleStyle;
  final TextStyle? bodyStyle;
  final int maxLinesPreview;

  const NotificationPreview({
    Key? key,
    required this.titleText,
    required this.bodyText,
    this.titleStyle,
    this.bodyStyle,
    this.maxLinesPreview = 3,
  }) : super(key: key);

  @override
  _NotificationPreviewState createState() => _NotificationPreviewState();
}

class _NotificationPreviewState extends State<NotificationPreview>
    with SingleTickerProviderStateMixin {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final titleStyle = widget.titleStyle ??
        const TextStyle(fontWeight: FontWeight.bold, color: Colors.black87);
    final bodyStyle =
        widget.bodyStyle ?? const TextStyle(color: Colors.black87);

    final combinedSpan = TextSpan(children: [
      if (widget.titleText.isNotEmpty)
        TextSpan(text: widget.titleText + (widget.bodyText.isNotEmpty ? ' ' : ''), style: titleStyle),
      if (widget.bodyText.isNotEmpty) TextSpan(text: widget.bodyText, style: bodyStyle),
    ]);

    return LayoutBuilder(builder: (context, constraints) {
      final double availableWidth = constraints.maxWidth;
      final double textScale = MediaQuery.textScaleFactorOf(context);

      // measure full and preview heights via TextPainter
      final fullTp = TextPainter(
        text: combinedSpan,
        textDirection: ui.TextDirection.ltr,
        textScaleFactor: textScale,
        textWidthBasis: TextWidthBasis.longestLine,
      )..layout(minWidth: 0, maxWidth: availableWidth);

      final previewTp = TextPainter(
        text: combinedSpan,
        textDirection: ui.TextDirection.ltr,
        maxLines: widget.maxLinesPreview,
        ellipsis: '...',
        textScaleFactor: textScale,
        textWidthBasis: TextWidthBasis.longestLine,
      )..layout(minWidth: 0, maxWidth: availableWidth);

      final bool exceeds = fullTp.height > previewTp.height + 0.5;

      if (!exceeds) {
        // No overflow: render full combined text inline
        return RichText(
          text: combinedSpan,
        );
      }

      // Overflowing: show AnimatedSize + AnimatedCrossFade so parent resizes smoothly
      return AnimatedSize(
        // vsync: this,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeInOut,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AnimatedCrossFade(
              firstChild: GestureDetector(
                onTap: () => setState(() => _expanded = true),
                child: RichText(
                  text: combinedSpan,
                  maxLines: widget.maxLinesPreview,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              secondChild: GestureDetector(
                onTap: () => setState(() => _expanded = false),
                child: RichText(
                  text: combinedSpan,
                ),
              ),
              crossFadeState:
              _expanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
              duration: const Duration(milliseconds: 220),
            ),

            // const SizedBox(height: 2),

            // Centered toggle button
            Row(
              children: [
                Expanded(
                  child: Center(
                    child: InkWell(
                      onTap: () => setState(() => _expanded = !_expanded),
                      borderRadius: BorderRadius.circular(10),
                      child: Container(
                        padding: const EdgeInsets.all(1),
                        decoration: const BoxDecoration(shape: BoxShape.circle),
                        child: Icon(
                          _expanded ? Icons.expand_less : Icons.expand_more,
                          size: 20,
                          color: Theme.of(context).primaryColor,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    });
  }
}
