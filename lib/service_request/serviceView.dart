// serviceView.dart (responsive / overflow fixes)
// Replace your existing file with this

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:math';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:open_file/open_file.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdfx/pdfx.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'dart:ui' as ui;
import '../widgets/AutoScrollingText.dart';


class serviceDetailes extends StatefulWidget {
  final String ticketId;
  final String rid;

  const serviceDetailes({Key? key, required this.ticketId, required this.rid}) : super(key: key);

  @override
  State<serviceDetailes> createState() => _serviceDetailesState();
}

class _serviceDetailesState extends State<serviceDetailes> {
  final Dio _dio = Dio();

  // Domain read from prefs
  String _domain = '';

  // Loading / error
  bool _loading = true;
  String? _error;
  // show the raw date/time text from server (no conversion)
  String expectedDateText = '';
  String expectedTimeText = '';

  // Parsed detail map (keeps original keys)
  Map<String, dynamic> _details = {};

  // Normalized fields for UI
  String status = '';
  String title = '';
  String description = '';
  String priority = '';
  String category = '';
  DateTime? expectedDate;
  TimeOfDay? expectedTime;

  String _createdByName = '';
  String _createdByProfile = '';
  String _companyName = '';

  List<Map<String, dynamic>> _assignedUsers = [];
  List<Map<String, dynamic>> _remarks = [];
  List<Map<String, dynamic>> _files = [];

  // responsive scale (set in build)
  double _scale = 1.0;

  // ---------- category auto-scroll state ----------
  final ScrollController _catScrollController = ScrollController();
  Timer? _catScrollTimer;
  bool _catScrollPaused = false;
  bool _catExpanded = false; // when showing expanded multi-line category sheet

  // ---------- description expand state ----------
  bool _descExpanded = false;

  @override
  void initState() {
    super.initState();
    // run after first frame to avoid calling async during build
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _fetchDetails();
    });
  }

  @override
  void dispose() {
    try { _catScrollTimer?.cancel(); } catch(_) {}
    try { _catScrollController.dispose(); } catch(_) {}
    _dio.close();
    super.dispose();
  }

  // --- helpers for parsing server date/time ---
  DateTime? _parseServerDate(dynamic v) {
    if (v == null) return null;
    try {
      if (v is DateTime) return v;
      final s = v.toString();
      if (s.isEmpty) return null;
      return DateTime.tryParse(s) ??
          (s.contains('/') ? DateFormat('dd/MM/yyyy').parseLoose(s) : null);
    } catch (_) {
      return null;
    }
  }

  TimeOfDay? _parseServerTime(dynamic v) {
    if (v == null) return null;
    try {
      final s = v.toString().trim();
      if (s.isEmpty) return null;

      // direct HH:mm parse
      final hm = RegExp(r'(\d{1,2}):(\d{1,2})').firstMatch(s);
      if (hm != null) {
        final hh = int.tryParse(hm.group(1) ?? '0') ?? 0;
        final mm = int.tryParse(hm.group(2) ?? '0') ?? 0;
        return TimeOfDay(hour: hh % 24, minute: mm % 60);
      }

      // try parse if full datetime given e.g. "13-10-2025 11:54"
      final dt = _parseServerDate(s);
      if (dt != null) return TimeOfDay(hour: dt.hour, minute: dt.minute);
    } catch (_) {}
    return null;
  }

  // Build details URL using stored slug/domain/type/id
  Future<Uri> _buildDetailsUri() async {
    final prefs = await SharedPreferences.getInstance();
    String slug = '';
    String type = '';
    String id = '';

    final raw = prefs.getString('user_data');
    if (raw != null) {
      try {
        final Map<String, dynamic> u = jsonDecode(raw);
        slug = (u['slug'] ?? '').toString();
        type = (u['type'] ?? '').toString();
        id = (u['id'] ?? '').toString();
        _domain = (u['domain'] ?? '').toString();
      } catch (_) {}
    }

    if (slug.isEmpty) slug = prefs.getString('slug') ?? '';

    final base = _domain;
    final uriStr = '$base$slug/detaileApi?tkt_id=${widget.ticketId}&type=$type&id=$id';
    final uri = Uri.parse(uriStr);
    if (kDebugMode) debugPrint('Details URL: $uri');
    return uri;
  }

  Future<void> _fetchDetails({bool showLoading = true}) async {
    if (!mounted) return;
    if (showLoading) {
      setState(() {
        _loading = true;
        _error = null;
      });
    } else {
      setState(() {
        _error = null;
      });
    }

    try {
      final uri = await _buildDetailsUri();
      if (kDebugMode) debugPrint('Fetching details from $uri');
      final resp = await _dio.getUri(uri).timeout(const Duration(seconds: 12));
      if (resp.statusCode != 200) {
        throw Exception('Server returned ${resp.statusCode}');
      }

      final dataWrapper = resp.data;
      final Map<String, dynamic> payload =
      (dataWrapper is Map && dataWrapper.containsKey('data'))
          ? Map<String, dynamic>.from(dataWrapper['data'])
          : (dataWrapper is Map ? Map<String, dynamic>.from(dataWrapper) : {});

      // Prepare local copies
      final Map<String, dynamic> newDetails = Map<String, dynamic>.from(_details);
      List<Map<String, dynamic>> newAssignedUsers = [];
      List<Map<String, dynamic>> newRemarks = [];
      List<Map<String, dynamic>> newFiles = [];

      // Basic fields
      newDetails['id'] = payload['id'] ?? newDetails['id'];
      newDetails['rid'] = payload['rid'] ?? newDetails['rid'];
      newDetails['title'] = payload['title'] ?? payload['subject'] ?? newDetails['title'];
      newDetails['description'] =
          payload['description'] ?? payload['desc'] ?? payload['detail'] ?? newDetails['description'] ?? '';
      newDetails['priority'] = payload['priority']?.toString() ?? '';
      newDetails['category'] = payload['category']?.toString() ?? '';

      // createdBy
      String newCreatedByName = '';
      String newCreatedByProfile = '';
      if (payload['createdBy'] is Map) {
        final cb = payload['createdBy'] as Map;
        newCreatedByName = (cb['name'] ?? cb['fullname'] ?? cb['user_name'] ?? '').toString();
        newCreatedByProfile = (cb['profile'] ?? cb['avatar'] ?? '').toString();
      } else {
        newCreatedByName = (payload['createdBy']?.toString() ?? '');
        newCreatedByProfile = '';
      }

      // company
      String newCompanyName = '';
      if (payload['company'] is Map) {
        final c = payload['company'] as Map;
        newCompanyName = (c['company'] ?? c['name'] ?? '').toString();
      } else {
        newCompanyName = (payload['company']?.toString() ?? '');
      }

      // assignedUsers parsing
      if (payload['assignedUsers'] is List) {
        newAssignedUsers = (payload['assignedUsers'] as List).map<Map<String, dynamic>>((e) {
          if (e is Map) {
            return {
              'id': (e['id'] ?? e['user_id'] ?? '').toString(),
              'name': (e['name'] ?? e['fullname'] ?? e['user_name'] ?? '').toString(),
              'profile': (e['profile'] ?? e['avatar'] ?? '').toString(),
            };
          }
          return {'id': e.toString(), 'name': e.toString(), 'profile': ''};
        }).toList();
      } else {
        final at = (payload['assignedTo'] ?? payload['assigned_to'] ?? payload['assigned'] ?? '').toString();
        if (at.isNotEmpty) {
          newAssignedUsers = at.split(',').map((id) => {'id': id.trim(), 'name': id.trim(), 'profile': ''}).toList();
        }
      }

      // progress / status
      newDetails['progress'] = (payload['progress'] is num) ? (payload['progress'] as num).toDouble() : 0.0;
      newDetails['status'] = (payload['status'] ?? payload['status_name'] ?? 'Pending').toString();
      newDetails['assignedToName'] = payload['assignedToName'] ?? payload['assigned_to_name'] ?? '';

      // parse files/attachments
      final files = payload['files'] ?? payload['attachments'] ?? payload['uploads'] ?? [];
      if (files is List) {
        newFiles = files.map<Map<String, dynamic>>((f) {
          if (f is Map) {
            return {
              'name': (f['name'] ?? f['file_name'] ?? f['filename'] ?? '').toString(),
              'url': (f['url'] ?? f['path'] ?? f['file_url'] ?? '').toString(),
              'mime': (f['mime'] ?? f['content_type'] ?? '').toString(),
            };
          }
          return {'name': f.toString(), 'url': ''};
        }).toList();
      } else if (files is String && files.isNotEmpty) {
        newFiles = files.toString().split(',').map((s) => {'name': s.trim(), 'url': ''}).toList();
      }

      // parse remarks (normalize)
      final remarks = payload['remarks'] ?? payload['comments'] ?? [];
      if (remarks is List) {
        for (final r in remarks) {
          if (r is Map) {
            String rUser = '';
            String rUserProfile = '';
            if (r['user'] is Map) {
              rUser = (r['user']['name'] ?? r['user']['fullname'] ?? '').toString();
              rUserProfile = (r['user']['profile'] ?? r['user']['avatar'] ?? '').toString();
            } else {
              rUser = (r['user']?.toString() ?? r['created_by']?.toString() ?? '');
            }

            String rAssignedTo = '';
            if (r['assigned_to'] is String) {
              rAssignedTo = r['assigned_to'];
            } else if (r['assigned_to'] is List) {
              rAssignedTo = (r['assigned_to'] as List).map((e) {
                if (e is Map) return (e['name'] ?? e['fullname'] ?? '').toString();
                return e.toString();
              }).join(', ');
            }

            List<Map<String, dynamic>> uploadsList = [];
            if (r['uploads'] is List) {
              uploadsList = (r['uploads'] as List).map<Map<String, dynamic>>((u) {
                if (u is Map) return {'name': u['name'] ?? u['file_name'] ?? '', 'url': u['url'] ?? ''};
                return {'name': u.toString(), 'url': ''};
              }).toList();
            } else if (r['uploads'] is String && (r['uploads'] as String).isNotEmpty) {
              uploadsList = [{'name': r['uploads'], 'url': ''}];
            }

            newRemarks.add({
              'id': r['id'],
              'datetime': r['datetime'] ?? r['createdAt'] ?? r['created_at'] ?? '',
              'user': rUser,
              'user_profile': rUserProfile,
              'assigned_to': rAssignedTo,
              'status': r['status'] ?? '',
              'remarks': r['remarks'] ?? r['remark'] ?? '',
              'uploads': uploadsList,
            });
          }
        }
      }

      // Build a CREATED remark if not present
      final createdAt = payload['createdAt'] ?? payload['created_at'] ?? '';
      final createdUser = newCreatedByName.isNotEmpty ? newCreatedByName : (payload['createdBy']?.toString() ?? 'System');
      if (newRemarks.isEmpty || newRemarks.first['id'] != 'created') {
        final createdUploads = (newFiles.isNotEmpty) ? newFiles.map((f) => f['name']).join(', ') : '';
        newRemarks.insert(0, {
          'id': 'created',
          'datetime': createdAt,
          'user': createdUser,
          'user_profile': newCreatedByProfile,
          'assigned_to': newAssignedUsers.map((e) => e['name']).join(', '),
          'status': 'Open',
          'remarks': newDetails['description'] ?? newDetails['title'] ?? 'Ticket created',
          'uploads': createdUploads,
          'uploads_list': newFiles,
        });
      }

      // prefer extendDate if present and non-empty, otherwise use endDate then startDate
      final rawExtendDate = (payload['extendDate'] ?? '').toString().trim();
      final rawEndDate = (payload['endDate'] ?? payload['end_date'] ?? '').toString().trim();
      final rawStartDate = (payload['startDate'] ?? payload['start_date'] ?? '').toString().trim();

      List<Map<String, dynamic>> createdUploads = [];
      final attachmentsFromPayload = payload['attachments'] ?? '';
      if (attachmentsFromPayload is String && (attachmentsFromPayload).isNotEmpty) {
        createdUploads = [
          {'name': 'Attachment File', 'url': attachmentsFromPayload}
        ];
      }

      // commit to state
      if (!mounted) return;
      setState(() {
        _details = newDetails;
        _createdByName = newCreatedByName;
        _createdByProfile = newCreatedByProfile;
        _companyName = newCompanyName;
        _assignedUsers = newAssignedUsers;
        _remarks = newRemarks;
        // _files = newFiles;
        _files = createdUploads;

        // simple field mapping for UI
        status = newDetails['status'] ?? '';
        title = newDetails['title'] ?? '';
        description = newDetails['description'] ?? '';
        priority = newDetails['priority']?.toString() ?? '';
        category = newDetails['category']?.toString() ?? '';

        expectedDateText = rawExtendDate.isNotEmpty
            ? rawExtendDate
            : (rawEndDate.isNotEmpty ? rawEndDate : (rawStartDate.isNotEmpty ? rawStartDate : ''));

        // prefer extendTime if present, otherwise deadline/time fields
        final rawExtendTime = (payload['extendTime'] ?? '').toString().trim();
        final rawDeadline = (payload['deadline'] ?? payload['deadline_time'] ?? payload['time'] ?? payload['end_time'] ?? '').toString().trim();

        expectedTimeText = rawExtendTime.isNotEmpty
            ? rawExtendTime
            : (rawDeadline.isNotEmpty ? rawDeadline : '');

        if (kDebugMode) {
          debugPrint(payload.toString());
          debugPrint('expectedDateText: $expectedDateText   expectedTimeText: $expectedTimeText');
        }

        _loading = false;
        _error = null;
      });

      // Start/refresh category scroller after layout (only if category overflows)
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _maybeStartCategoryAutoScroll();
      });
    } on TimeoutException {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Request timed out. Pull to retry.';
      });
    } catch (e, st) {
      if (!mounted) return;
      if (kDebugMode) debugPrint('Details parse error: $e\n$st');
      setState(() {
        _loading = false;
        _error = 'Sorry, something went wrong there. Try again.';
      });
    }
  }

  // ---------- category auto-scroll helpers ----------
  void _maybeStartCategoryAutoScroll() {
    // cancel any existing timer first
    _catScrollTimer?.cancel();
    _catScrollTimer = null;

    if (_catScrollPaused || _catExpanded) return;

    try {
      if (!_catScrollController.hasClients) return;
      final max = _catScrollController.position.maxScrollExtent;
      if (max <= 2.0) return; // no overflow -> no scroll
      _startCategoryAutoScroll();
    } catch (_) {}
  }

  void _startCategoryAutoScroll() {
    // if already running, cancel first
    _catScrollTimer?.cancel();
    final double maxScroll = _catScrollController.position.maxScrollExtent;
    if (maxScroll <= 2.0) return;

    // loop: scroll forward then back, with slight pauses
    const forwardDuration = Duration(milliseconds: 3000);
    const pauseDuration = Duration(milliseconds: 800);
    const backDuration = Duration(milliseconds: 1800);

    _catScrollTimer = Timer.periodic(Duration(milliseconds: 4200), (t) async {
      if (!mounted) {
        t.cancel();
        return;
      }
      if (_catScrollPaused || !_catScrollController.hasClients) return;
      try {
        await _catScrollController.animateTo(maxScroll, duration: forwardDuration, curve: Curves.easeInOut);
        await Future.delayed(pauseDuration);
        if (!_catScrollController.hasClients || _catScrollPaused) return;
        await _catScrollController.animateTo(0.0, duration: backDuration, curve: Curves.easeInOut);
      } catch (_) {
        // animation failed - ignore; next tick will retry
      }
    });

    // start immediate first cycle
    _catScrollController.animateTo(maxScroll, duration: forwardDuration, curve: Curves.easeInOut).catchError((_) {});
  }

  void _stopCategoryAutoScroll() {
    _catScrollTimer?.cancel();
    _catScrollTimer = null;
  }

  // utility to detect overflow for texts
  bool _textExceedsLines(String text, TextStyle style, int maxLines, double maxWidth) {
    if (text.isEmpty) return false;

    final tp = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: ui.TextDirection.ltr, // use dart:ui alias to avoid conflicts
      maxLines: maxLines,
    );

    tp.layout(minWidth: 0, maxWidth: maxWidth);
    return tp.didExceedMaxLines;
  }

  // Show preview (image/pdf/other). Robust handling and user-friendly errors.
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
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No URL available for this file')));
        return;
      }

      // Fix relative URLs if domain available
      if (!url.startsWith('http') && _domain.isNotEmpty) {
        final prefix = _domain.endsWith('/') ? _domain.substring(0, _domain.length - 1) : _domain;
        final fixed = url.startsWith('/') ? '$prefix$url' : '$prefix/$url';
        url = fixed;
      }

      if (name.isEmpty) {
        final parsed = Uri.tryParse(url);
        if (parsed != null && parsed.pathSegments.isNotEmpty) {
          name = parsed.pathSegments.last;
        } else {
          name = 'file_${DateTime.now().millisecondsSinceEpoch}';
        }
      }

      final lower = url.toLowerCase();
      final bool isImage = lower.endsWith('.png') || lower.endsWith('.jpg') || lower.endsWith('.jpeg') || lower.endsWith('.webp') || lower.endsWith('.gif');
      final bool isPdf = lower.endsWith('.pdf');

      if (isImage) {
        // Image preview sheet
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
                  decoration: BoxDecoration(color: Theme.of(context).canvasColor, borderRadius: BorderRadius.vertical(top: Radius.circular(16 * _scale))),
                  child: Column(children: [
                    Padding(
                      padding: EdgeInsets.symmetric(horizontal: 12.0 * _scale, vertical: 10 * _scale),
                      child: Row(children: [
                        Expanded(child: Text(name.isNotEmpty ? name : 'Image Preview', overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14 * _scale))),
                        IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.of(ctx).pop()),
                      ]),
                    ),
                    const Divider(height: 1),
                    Expanded(
                      child: Padding(
                        padding: EdgeInsets.all(12.0 * _scale),
                        child: InteractiveViewer(
                          child: Center(
                            child: Image.network(url, loadingBuilder: (context, child, progress) {
                              if (progress == null) return child;
                              final p = (progress.cumulativeBytesLoaded / (progress.expectedTotalBytes ?? 1));
                              return Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                                CircularProgressIndicator(value: p),
                                SizedBox(height: 12 * _scale),
                                Text('${(p * 100).toStringAsFixed(0)}%', style: TextStyle(fontSize: 12 * _scale)),
                              ]);
                            }, errorBuilder: (_, __, ___) => Container(padding: EdgeInsets.all(24 * _scale), child: Text('Unable to load image', style: TextStyle(fontSize: 14 * _scale)))),
                          ),
                        ),
                      ),
                    ),
                  ]),
                );
              },
            );
          },
        );
        return;
      }

      if (isPdf) {
        // PDF preview
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



      // Try open externally first
      final uri = Uri.tryParse(url);
      if (uri != null) {
        final launched = await (await canLaunchUrl(uri) ? launchUrl(uri, mode: LaunchMode.externalApplication) : Future.value(false));
        if (launched == true) return;
      }

      final sb = ScaffoldMessenger.of(context);
      final snack = sb.showSnackBar(SnackBar(content: Text('Downloading $name...'), duration: const Duration(days: 1)));

      final ok = await _downloadAndOpen(url, suggestedName: name);

      snack.close();
      if (!ok) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Cannot open file URL')));
      }
    } catch (e, st) {
      if (kDebugMode) debugPrint('Preview error: $e\n$st');
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Preview error: $e')));
    }
  }

  Future<bool> _downloadAndOpen(String url, {String? suggestedName}) async {
    try {
      final uri = Uri.parse(url);

      final res = await _dio.get<List<int>>(
        url,
        options: Options(responseType: ResponseType.bytes, followRedirects: true, validateStatus: (s) => s! < 500),
      );

      if (res.statusCode == 200 && res.data != null) {
        final bytes = res.data is Uint8List ? res.data as Uint8List : Uint8List.fromList(List<int>.from(res.data!));
        final dir = await getTemporaryDirectory();

        final inferredName = uri.pathSegments.isNotEmpty ? uri.pathSegments.last : 'download_${DateTime.now().millisecondsSinceEpoch}';
        final rawName = suggestedName ?? inferredName;
        final fileName = rawName.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_');

        final filePath = '${dir.path}/$fileName';
        final file = File(filePath);
        await file.writeAsBytes(bytes, flush: true);

        if (Platform.isAndroid || Platform.isIOS) {
          await OpenFile.open(file.path);
        } else {
          // fallback on desktop/web: try launching file:// or open in browser
          final fileUri = Uri.file(file.path);
          if (await canLaunchUrl(fileUri)) {
            await launchUrl(fileUri);
          } else {
            // last resort - attempt to open via OpenFile (may or may not work)
            await OpenFile.open(file.path);
          }
        }
        return true;
      }
      return false;
    } catch (e) {
      if (kDebugMode) debugPrint('Download/open error: $e');
      return false;
    }
  }

  Widget _attachmentLeading(Map<String, dynamic> a) {
    final name = a['name']?.toString() ?? '';
    final ext = name.split('.').last.toLowerCase();
    IconData icon;
    Color color;
    if (ext == 'pdf') {
      icon = Icons.picture_as_pdf;
      color = Colors.red.shade700;
    } else if (['png', 'jpg', 'jpeg', 'gif', 'webp'].contains(ext)) {
      icon = Icons.image;
      color = Colors.orange.shade700;
    } else {
      icon = Icons.insert_drive_file;
      color = Colors.blueGrey.shade700;
    }

    final double size = 52.0 * _scale;
    final double iconSize = 30.0 * _scale;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: color.withOpacity(0.12), borderRadius: BorderRadius.circular(8 * _scale)),
      child: Icon(icon, color: color, size: iconSize),
    );
  }

  // status color helper (updated)
  Color _statusColor(String label) {
    final s = label.toLowerCase();
    if (s.contains('new') || s.contains('new sr')) return const Color(0xFF3B7080);       // #3B7080
    if (s.contains('pending')) return const Color(0xFFF26522);                          // #F26522
    if (s.contains('in progress') || s.contains('inprogress')) return const Color(0xFFBC8F07); // #FFC107
    if (s.contains('extend') || s.contains('extended')) return const Color(0xFF1B84FF);  // #1B84FF
    if (s.contains('completed')) return const Color(0xFF03C95A);                         // #03C95A
    return Colors.grey;
  }

  Widget _miniChip({required IconData icon, required String label, required Color background, required Color textColor}) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 5.0 * _scale, vertical: 5.0 * _scale),
      decoration: BoxDecoration(color: background, borderRadius: BorderRadius.circular(5 * _scale)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 13.0 * _scale, color: textColor),
        SizedBox(width: 2.0 * _scale),
        Text(label, style: TextStyle(fontSize: 13.0 * _scale, color: textColor, fontWeight: FontWeight.w700)),
      ]),
    );
  }

  Widget _infoBox({
    required IconData icon,
    required String label,
    required String value,
    bool readOnly = false,
  }) {
    return Container(
      padding: EdgeInsets.all(12.0 * _scale),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade300),
        borderRadius: BorderRadius.circular(10.0 * _scale),
        color: Colors.grey.shade50,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: Colors.deepPurple, size: 16.0 * _scale),
          SizedBox(width: 8.0 * _scale),

          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 14.0 * _scale,
                    color: Colors.grey,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                SizedBox(height: 4.0 * _scale),
                Text(
                  value,
                  style: TextStyle(
                    fontSize: 14.0 * _scale,
                    fontWeight: FontWeight.w600,
                    color: Colors.black87,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _detailRow(String label, String value) {
    return Row(children: [SizedBox(width: 120 * _scale, child: Text(label, style: TextStyle(color: Colors.grey[700], fontSize: 14.0 * _scale))), Expanded(child: Text(value, style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14.0 * _scale)))]);
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

  Color _typeColor(String type) {
    final t = type.toLowerCase();
    if (t.contains('task')) return const Color(0xFF666666); // #666666
    if (t.contains('service')) return const Color(0xFFF8790C); // #f8790c
    if (t.contains('invoice'))
      return const Color(
        0xFF2E86AB,
      ); // keep invoice as before (blue) or change if needed
    return Colors.grey.shade700;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // responsive scale based on 390 baseline width (approx iPhone 12/13)
    final width = MediaQuery.of(context).size.width;
    _scale = (width / 390.0).clamp(0.8, 1.12).toDouble();

    final Color typeColor = _typeColor('service');
    final Color cardBg = typeColor.withOpacity(0.05);

    final pad = 12.0 * _scale;

    return Scaffold(
        backgroundColor: theme.scaffoldBackgroundColor,
        appBar: AppBar(
          title: Text('Service Request', style: TextStyle(fontSize: 18.0 * _scale)),
        ),
        body: SafeArea(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
              ? Center(
            child: Padding(
              padding: EdgeInsets.all(16.0 * _scale),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Text(_error!,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.red, fontSize: 14.0 * _scale)),
                SizedBox(height: 12.0 * _scale),
                ElevatedButton.icon(
                    onPressed: () => _fetchDetails(),
                    icon: Icon(Icons.refresh, size: 16.0 * _scale),
                    label: Text('Retry', style: TextStyle(fontSize: 14.0 * _scale)))
              ]),
            ),
          )
              : SingleChildScrollView(
            padding: EdgeInsets.symmetric(horizontal: pad, vertical: 14.0 * _scale),
            child: Column(
              children: [
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Card(
                      elevation: 6,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12.0 * _scale)),
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(12.0 * _scale),
                          border: Border(
                            left: BorderSide(
                              color: typeColor,
                              width: 4 * _scale,
                            ),
                          ),
                        ),
                        child: Padding(
                          padding: EdgeInsets.fromLTRB(pad, pad + 12.0 * _scale, pad, pad),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            SizedBox(height: 12.0 * _scale),
                            // chips: horizontally scrollable to avoid overflow on narrow screens
                            SizedBox(
                              height: 36.0 * _scale,
                              child: Row(
                                children: [
                                  // --- RID ---
                                  Text(
                                    widget.rid,
                                    style: TextStyle(
                                      fontSize: 15.0 * _scale,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                  SizedBox(width: 8.0 * _scale),

                                  // --- PRIORITY CHIP ---
                                  if (status.isNotEmpty && priority.isNotEmpty)
                                    _miniChip(
                                      icon: Icons.bolt,
                                      label: '$priority',
                                      background: _priorityColor(priority).withOpacity(0.12),
                                      textColor: _priorityColor(priority),
                                    ),
                                  SizedBox(width: 8.0 * _scale),

                                  // --- CATEGORY CHIP ---
                                  if (category.isNotEmpty)
                                    Flexible(
                                      child: LayoutBuilder(
                                        builder: (context, constraints) {
                                          // Measure category text width
                                          final textStyle = TextStyle(
                                            fontSize: 13.0 * _scale,
                                            color: Colors.blue.shade800,
                                            fontWeight: FontWeight.w700,
                                          );

                                          final textSpan = TextSpan(text: category, style: textStyle);
                                          final tp = TextPainter(
                                            text: textSpan,
                                            maxLines: 1,
                                            textDirection: ui.TextDirection.ltr,
                                          )..layout();

                                          final textWidth = tp.width;
                                          final maxWidth = constraints.maxWidth; // full width available inside the row
                                          final chipMaxWidth = maxWidth * 0.8; // avoid touching card edge
                                          final shouldScroll = textWidth > chipMaxWidth;

                                          // ✅ final width — min = textWidth (or cap at chipMaxWidth)
                                          final effectiveWidth = min(textWidth, chipMaxWidth);

                                          return Container(
                                            padding: EdgeInsets.symmetric(horizontal: 8.0 * _scale, vertical: 6.0 * _scale),
                                            decoration: BoxDecoration(
                                              color: Colors.blue.withOpacity(0.08),
                                              borderRadius: BorderRadius.circular(6),
                                            ),
                                            child: Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                Icon(Icons.category, size: 13 * _scale, color: Colors.blue.shade800),
                                                SizedBox(width: 6 * _scale),
                                                ConstrainedBox(
                                                  constraints: BoxConstraints(
                                                    minWidth: effectiveWidth,
                                                    maxWidth: chipMaxWidth,
                                                  ),
                                                  child: ClipRect(
                                                    child: shouldScroll
                                                        ? AutoScrollingText(
                                                      text: category,
                                                      style: textStyle,
                                                    )
                                                        : Text(
                                                      category,
                                                      style: textStyle,
                                                      overflow: TextOverflow.ellipsis,
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          );
                                        },
                                      ),
                                    ),
                                ],
                              ),
                            ),

                            SizedBox(height: 12.0 * _scale),
                            Text(title.isEmpty ? '-' : title,
                                style: TextStyle(fontSize: 20.0 * _scale, fontWeight: FontWeight.w800),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis),
                            SizedBox(height: 8.0 * _scale),

                            // Description: inline expand/collapse (AnimatedSize)
                            LayoutBuilder(builder: (ctx, constraints) {
                              final double maxWidth = constraints.maxWidth;
                              final descStyle = TextStyle(fontSize: 14.0 * _scale, color: Colors.grey[800]);
                              final bool overflows = _textExceedsLines(description, descStyle, 3, maxWidth);

                              return Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  // AnimatedSize to smoothly animate expansion
                                  AnimatedSize(
                                    duration: const Duration(milliseconds: 220),
                                    curve: Curves.easeInOut,
                                    alignment: Alignment.topCenter,
                                    child: ConstrainedBox(
                                      // When collapsed, limit height to roughly 3 lines using maxLines via RichText measurement trick:
                                      constraints: _descExpanded
                                          ? const BoxConstraints()
                                          : BoxConstraints(maxHeight: 3 * (descStyle.fontSize ?? 14.0) * 1.2),
                                      child: Text(
                                        description,
                                        style: descStyle,
                                        softWrap: true,
                                        overflow: TextOverflow.fade,
                                      ),
                                    ),
                                  ),

                                  // only show toggle when content actually overflows
                                  if (overflows)
                                    Align(
                                      alignment: Alignment.centerLeft,
                                      child: TextButton(
                                        onPressed: () => setState(() => _descExpanded = !_descExpanded),
                                        child: Text(_descExpanded ? 'Show less' : 'Read more'),
                                        style: TextButton.styleFrom(
                                          padding: EdgeInsets.zero,
                                          minimumSize: Size(0, 0),
                                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                          textStyle: TextStyle(fontSize: 13.0 * _scale, fontWeight: FontWeight.w600),
                                        ),
                                      ),
                                    ),
                                ],
                              );
                            }),

                            SizedBox(height: 12.0 * _scale),
                            Row(
                              children: [
                                Expanded(child: _infoBox(icon: Icons.calendar_today, label: 'End Date', value: expectedDateText.isNotEmpty ? expectedDateText : '—')),
                                SizedBox(width: 12.0 * _scale),
                                Expanded(child: _infoBox(icon: Icons.access_time, label: 'End Time', value: expectedTimeText.isNotEmpty ? expectedTimeText : '—')),
                              ],
                            ),
                            SizedBox(height: 18.0 * _scale),
                            const Divider(height: 1.0),
                            SizedBox(height: 8.0 * _scale),
                            Text('Attachments', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15.0 * _scale)),
                            SizedBox(height: 8.0 * _scale),
                            if (_files.isEmpty)
                              Padding(padding: EdgeInsets.symmetric(vertical: 8.0 * _scale), child: Text('No attachments', style: TextStyle(color: Colors.grey[700], fontSize: 14.0 * _scale)))
                            else
                              Column(
                                children: _files.map((a) {
                                  return InkWell(
                                    onTap: () => _openFilePreview(a),
                                    child: Padding(
                                      padding: EdgeInsets.symmetric(vertical: 6.0 * _scale),
                                      child: Row(
                                        crossAxisAlignment: CrossAxisAlignment.center,
                                        children: [
                                          _attachmentLeading(a),
                                          SizedBox(width: 9.0 * _scale),
                                          // Ensure name is single-line and ellipsize if too long
                                          Expanded(
                                            child: Text(
                                              a['name'] ?? '',
                                              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14.0 * _scale),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                          SizedBox(width: 8.0 * _scale),
                                          Icon(Icons.open_in_new, color: Colors.grey[500], size: 18.0 * _scale),
                                        ],
                                      ),
                                    ),
                                  );
                                }).toList(),
                              ),
                            SizedBox(height: 16.0 * _scale),
                          ]),
                        ),
                      ),
                    ),
                    Positioned(
                      top: -8.0 * _scale,
                      left: 14.0 * _scale,
                      child: Container(
                        padding: EdgeInsets.symmetric(horizontal: 18.0 * _scale, vertical: 8.0 * _scale),
                        decoration: BoxDecoration(
                            color: _statusColor(status),
                            borderRadius: BorderRadius.circular(6.0 * _scale),
                            boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.08), blurRadius: 6.0 * _scale, offset: Offset(0, 3.0 * _scale))]),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Icon(Icons.check_circle, color: Colors.white, size: 16.0 * _scale),
                          SizedBox(width: 8.0 * _scale),
                          Text(status.isEmpty ? '—' : status, style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 14.0 * _scale)),
                        ]),
                      ),
                    ),
                  ],
                ),
                SizedBox(height: 18.0 * _scale),
              ],
            ),
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
  const _PdfPreviewSheet({required this.url, required this.name, required this.dio});

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
        options: Options(responseType: ResponseType.bytes, followRedirects: true, validateStatus: (s) => s! < 500),
        onReceiveProgress: (r, t) {
          if (t > 0) {
            setState(() => _progress = r / t);
          }
        },
      );

      if (res.statusCode == 200 && res.data != null) {
        final Uint8List bytes = res.data is Uint8List ? res.data as Uint8List : Uint8List.fromList(List<int>.from(res.data!));
        // Dispose old controller if any
        try {
          _controller?.dispose();
        } catch (_) {}
        try {
          _controller = PdfControllerPinch(document: PdfDocument.openData(bytes));
          setState(() {
            _loading = false;
            _error = null;
            _progress = 1.0;
          });
        } catch (e) {
          setState(() {
            _loading = false;
            _error = 'Failed to open PDF: $e';
          });
        }
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
    try {
      _controller?.dispose();
    } catch (_) {}
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Pdf sheet uses local scaling based on width as well so it looks good on tablets/phones
    final width = MediaQuery.of(context).size.width;
    final s = (width / 390.0).clamp(0.8, 1.12).toDouble();

    return Container(
      decoration: BoxDecoration(color: Theme.of(context).canvasColor, borderRadius: BorderRadius.vertical(top: Radius.circular(16.0 * s))),
      child: Column(children: [
        Padding(padding: EdgeInsets.symmetric(horizontal: 12.0 * s, vertical: 10.0 * s), child: Row(children: [
          Expanded(child: Text(widget.name.isNotEmpty ? widget.name : 'PDF', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16.0 * s))),
          IconButton(
            icon: const Icon(Icons.open_in_new),
            onPressed: () async {
              await _openExternalOrDownload(widget.url);
            },
          ),
          IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.of(context).pop()),
        ])),
        const Divider(height: 1),
        Expanded(child: _loading ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [CircularProgressIndicator(value: _progress > 0 ? _progress : null), SizedBox(height: 12), Text(_progress > 0 ? '${(_progress * 100).toStringAsFixed(0)}%' : 'Downloading...')])) : (_error != null) ? Center(child: Padding(padding: const EdgeInsets.all(12), child: Text(_error!, style: const TextStyle(color: Colors.red)))) : (_controller != null ? PdfViewPinch(controller: _controller!) : Center(child: Text('Unable to render PDF')))),
      ]),
    );
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
      if (mounted) ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('Cannot download or open file')));
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
}
