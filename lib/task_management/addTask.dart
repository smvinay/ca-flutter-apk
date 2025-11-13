// lib/task_management/addService.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:intl/intl.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:image_picker/image_picker.dart';


class Template2AddTask extends StatefulWidget {
  const Template2AddTask({Key? key}) : super(key: key);

  @override
  State<Template2AddTask> createState() => _Template2AddTaskState();
}

class _Template2AddTaskState extends State<Template2AddTask> {
  final _formKey = GlobalKey<FormState>();


  // controllers
  final TextEditingController _titleC = TextEditingController();
  final TextEditingController _descC = TextEditingController();
  final TextEditingController _startDateC = TextEditingController();
  final TextEditingController _startTimeC = TextEditingController();
  final TextEditingController _dueDateC = TextEditingController();
  final TextEditingController _dueTimeC = TextEditingController();
  final TextEditingController _clientSearchC = TextEditingController();

  final FocusNode _clientSearchFocusNode = FocusNode();
  final TextEditingController _assignToController = TextEditingController();

  // dropdown selections: we store id + label
  int? _categoryId;
  String? _categoryLabel;
  int? _assignToId;
  String? _assignToLabel;
  int? _clientId;
  String? _clientLabel;
  String _priority = 'Medium';

  bool _dirty = false;

  // pick file
  String? _pickedFileName;
  String? _newRid;
  String? _slug;
  String? _domain;
  String? _pickedFilePath;
  int? _pickedFileSizeBytes;

  // API-loaded lists
  List<Map<String, dynamic>> _categories = [];
  List<Map<String, dynamic>> _users = [];
  List<Map<String, dynamic>> _clients = [];

  // UI state
  bool _loading = true; // loading addPageTaskApi
  String? _error;
  bool _submitting = false;
  double _uploadProgress = 0.0;

  // dio
  final Dio _dio = Dio();

  @override
  void initState() {
    super.initState();
    // Set default start date/time to now so the form shows current values on open.
    _setDefaultStartToNow();

    _fetchAddPageData();
  }

  void _setDefaultStartToNow() {
    final now = DateTime.now();
    final nowDateStr = _formatDate(now); // uses your existing _formatDate
    final nowTimeStr = _formatTimeOfDay(TimeOfDay.fromDateTime(now)); // uses your _formatTimeOfDay

    // Only set if the fields are empty (don't overwrite if user already set something)
    if (_startDateC.text.trim().isEmpty) _startDateC.text = nowDateStr;
    if (_startTimeC.text.trim().isEmpty) _startTimeC.text = nowTimeStr;
  }

  @override
  void dispose() {
    _titleC.dispose();
    _descC.dispose();
    _startDateC.dispose();
    _startTimeC.dispose();
    _dueDateC.dispose();
    _dueTimeC.dispose();
    _clientSearchC.dispose();
    _clientSearchFocusNode.dispose();
    _assignToController.dispose();
    _dio.close();
    super.dispose();
  }


  // Actual fetch implementation (keeps robust parsing)
  Future<void> _fetchAddPageData() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final prefs = await SharedPreferences.getInstance();

      final raw = prefs.getString('user_data');
      if (raw != null) {
        try {
          final Map<String, dynamic> data = jsonDecode(raw);
          _slug = (data['slug'] ?? '').toString();
          _domain = (data['domain'] ?? '').toString();
        } catch (_) {}
      }

      final uri = Uri.parse('$_domain$_slug/addPageTaskApi');
      final resp = await _dio.getUri(uri).timeout(const Duration(seconds: 12));
      if (resp.statusCode != 200) {
        throw Exception('Server returned ${resp.statusCode}');
      }

      final data = resp.data ?? {};
      // parse categories
      final List<Map<String, dynamic>> cats = [];
      _newRid = data['new_rdid'] ?? '';
      final rawCats = data['categorys'] ?? data['categories'] ?? [];
      if (rawCats is List) {
        for (final c in rawCats) {
          if (c is Map) cats.add(Map<String, dynamic>.from(c));
        }
      }
      // NOTE: removed placeholder insertion — do NOT insert {"id": null, "name": "Select Category"}

      // parse users
      final List<Map<String, dynamic>> users = [];
      final rawUsers = data['users'] ?? [];
      if (rawUsers is List) {
        for (final u in rawUsers) {
          if (u is Map) users.add(Map<String, dynamic>.from(u));
        }
      }
      // NOTE: removed placeholder insertion for users as well

      // parse clients
      final List<Map<String, dynamic>> clients = [];

// add default option at the top
      clients.add({"name": "Internal", "id": 0});

      final rawClients = data['client'] ?? data['clients'] ?? [];
      if (rawClients is List) {
        for (final c in rawClients) {
          if (c is Map) clients.add(Map<String, dynamic>.from(c));
        }
      }



      setState(() {
        _categories = cats;
        _users = users;
        _clients = clients;
        _loading = false;
        _error = null;

        // DO NOT auto-select first category/user — leave null to show hint placeholder
        // _categoryId and _assignToId remain null until user selects.
      });
    } on TimeoutException {
      setState(() {
        _loading = false;
        _error = 'Request timed out. Pull to retry.';
      });
    } catch (e) {
      setState(() {
        _loading = false;
        _error = 'Sorry, something went wrong there. Try again.';
      });
    }
  }
// helpers (add inside your State class)
  String _formatDate(DateTime d) => DateFormat('dd-MM-yyyy').format(d);
  String _formatTimeOfDay(TimeOfDay t) {
    final now = DateTime.now();
    final dt = DateTime(now.year, now.month, now.day, t.hour, t.minute);
    return DateFormat.jm().format(dt); // e.g. 12:30 PM
  }
  bool _isSameDate(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;

  // small parser for the time format you show (e.g. "12:30 PM")
  TimeOfDay _parseTimeOfDay(String input) {
    final dt = DateFormat.jm().parse(input); // parse "12:30 PM"
    return TimeOfDay(hour: dt.hour, minute: dt.minute);
  }

  Future<void> _selectTimeWithDate({required bool isStart}) async {
    final TextEditingController timeC = isStart ? _startTimeC : _dueTimeC;
    final TextEditingController dateC = isStart ? _startDateC : _dueDateC;

    // If no date selected, auto-fill date to today
    if (dateC.text.trim().isEmpty) {
      final now = DateTime.now();
      dateC.text = _formatDate(DateTime(now.year, now.month, now.day));
    }

    // Use existing value as initial, otherwise now
    final existing = _parseTime(timeC.text);
    final initialTime = existing ?? TimeOfDay.fromDateTime(DateTime.now());

    final picked = await showTimePicker(context: context, initialTime: initialTime);
    if (picked == null) return;

    final chosenDate = _parseDate(dateC.text) ?? DateTime.now();
    final selectedDT = DateTime(chosenDate.year, chosenDate.month, chosenDate.day, picked.hour, picked.minute);
    final now = DateTime.now();

    if (isStart) {
      // If start date is today, don't allow picking a past time. Adjust to now if so.
      if (_isSameDate(chosenDate, now) && selectedDT.isBefore(now)) {
        final nowTime = TimeOfDay.fromDateTime(now);
        timeC.text = _formatTimeOfDay(nowTime);
        // ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Start time cannot be in the past — set to current time.')));
        Fluttertoast.showToast(
          msg: "Start time cannot be in the past — set to current time.",
          toastLength: Toast.LENGTH_SHORT,
          gravity: ToastGravity.BOTTOM,
          backgroundColor: Colors.redAccent.shade200,
          textColor: Colors.white,
          fontSize: 14.0,
        );
        // Update due if needed
        await _ensureDueIsAfterStartOrFix();
        return;
      }
      // valid start time
      timeC.text = _formatTimeOfDay(picked);
      // after changing start, ensure due is still valid
      await _ensureDueIsAfterStartOrFix();
      return;
    }

    // Not start -> due time. If due date == start date ensure due > start.
    final startDate = _parseDate(_startDateC.text);
    final startTime = _parseTime(_startTimeC.text);

    if (startDate != null && startTime != null &&
        startDate.year == chosenDate.year &&
        startDate.month == chosenDate.month &&
        startDate.day == chosenDate.day) {
      final startDT = DateTime(startDate.year, startDate.month, startDate.day, startTime.hour, startTime.minute);

      if (!selectedDT.isAfter(startDT)) {
        // invalid due (not strictly after)
        // ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Due time must be later than the start time')));
        Fluttertoast.showToast(
          msg: "End time must be later than the start time.",
          toastLength: Toast.LENGTH_SHORT,
          gravity: ToastGravity.BOTTOM,
          backgroundColor: Colors.redAccent.shade200,
          textColor: Colors.white,
          fontSize: 14.0,
        );
        timeC.clear(); // clear invalid value
        return;
      }
    }

    // Everything ok, set due time
    timeC.text = _formatTimeOfDay(picked);
  }



  /// Parse date strings in dd-mm-yyyy or dd/mm/yyyy format. Returns null on failure.
  DateTime? _parseDate(String input) {
    if (input.trim().isEmpty) return null;
    final s = input.trim().replaceAll('/', '-');
    final parts = s.split('-');
    if (parts.length != 3) return null;
    try {
      final d = int.parse(parts[0]);
      final m = int.parse(parts[1]);
      final y = int.parse(parts[2]);
      return DateTime(y, m, d);
    } catch (_) {
      return null;
    }
  }

  /// Parse time strings like "02:30 PM", "2:30 pm", or 24-hour "14:30". Returns TimeOfDay or null.
  TimeOfDay? _parseTime(String input) {
    if (input.trim().isEmpty) return null;
    final s = input.trim().toLowerCase();
    // if contains am/pm
    try {
      if (s.contains('am') || s.contains('pm')) {
        final s2 = s.replaceAll(RegExp(r'\s*(am|pm)$'), '');
        final parts = s2.split(':');
        if (parts.length < 2) return null;
        int h = int.parse(parts[0]);
        final int min = int.parse(parts[1]);
        if (s.contains('pm') && h < 12) h += 12;
        if (s.contains('am') && h == 12) h = 0;
        return TimeOfDay(hour: h, minute: min);
      } else {
        // 24-hour format
        final parts = s.split(':');
        if (parts.length < 2) return null;
        final int h = int.parse(parts[0]);
        final int min = int.parse(parts[1]);
        return TimeOfDay(hour: h, minute: min);
      }
    } catch (_) {
      return null;
    }
  }


  Future<void> _selectDateWithTime({required bool isStart}) async {
    final TextEditingController dateC = isStart ? _startDateC : _dueDateC;

    final DateTime now = DateTime.now();
    final DateTime today = DateTime(now.year, now.month, now.day);

    DateTime initial = _parseDate(dateC.text) ?? today;
    DateTime firstDate = today;

    if (!isStart) {
      // For due date, earliest allowed is startDate (if set) or today
      final sd = _parseDate(_startDateC.text);
      if (sd != null) {
        firstDate = sd.isAfter(today) ? sd : today;
        if (initial.isBefore(firstDate)) initial = firstDate;
      }
    } else {
      // For start date first date must be today (can't set past start)
      firstDate = today;
      if (initial.isBefore(firstDate)) initial = firstDate;
    }

    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: firstDate,
      lastDate: DateTime(2100),
    );

    if (picked != null) {
      dateC.text = _formatDate(picked);

      // If user set start date to today and start time exists but is now in the past, adjust start time.
      if (isStart && _startTimeC.text.trim().isNotEmpty) {
        final stime = _parseTime(_startTimeC.text);
        if (stime != null) {
          final startDT = DateTime(picked.year, picked.month, picked.day, stime.hour, stime.minute);
          if (startDT.isBefore(now)) {
            // adjust to 'now' time
            final nowTime = TimeOfDay.fromDateTime(now);
            _startTimeC.text = _formatTimeOfDay(nowTime);
            // ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Start time adjusted to current time because date is today.')));
            Fluttertoast.showToast(
              msg: "Start time adjusted to current time because date is today.",
              toastLength: Toast.LENGTH_SHORT,
              gravity: ToastGravity.BOTTOM,
              backgroundColor: Colors.redAccent.shade200,
              textColor: Colors.white,
              fontSize: 14.0,
            );
          }
        }
      }

      // After date change, make sure due remains valid
      await _ensureDueIsAfterStartOrFix();
    }
  }



  // // client bottom-sheet searchable selector
  // Future<void> _showClientSelector() async {
  //   String query = _clientSearchC.text;
  //   await showModalBottomSheet(
  //     context: context,
  //     isScrollControlled: true,
  //     builder: (c) {
  //       return StatefulBuilder(builder: (context, setModalState) {
  //         final filtered = _clients.where((cl) {
  //           final n = (cl['name'] ?? '').toString().toLowerCase();
  //           return n.contains(query.toLowerCase());
  //         }).toList();
  //
  //         return SafeArea(
  //           child: Padding(
  //             padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
  //             child: Container(
  //               height: MediaQuery.of(context).size.height * 0.7,
  //               padding: const EdgeInsets.all(12),
  //               child: Column(
  //                 children: [
  //                   Row(
  //                     children: [
  //                       Expanded(
  //                         child: TextField(
  //                           controller: _clientSearchC,
  //                           decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search client...'),
  //                           onChanged: (v) {
  //                             query = v;
  //                             setModalState(() {});
  //                           },
  //                         ),
  //                       ),
  //                       IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.of(context).pop()),
  //                     ],
  //                   ),
  //                   const SizedBox(height: 8),
  //                   if (filtered.isEmpty)
  //                     Expanded(child: Center(child: Text('No clients found', style: TextStyle(color: Colors.grey.shade600))))
  //                   else
  //                     Expanded(
  //                       child: ListView.separated(
  //                         itemCount: filtered.length,
  //                         separatorBuilder: (_, __) => const Divider(height: 1),
  //                         itemBuilder: (ctx, i) {
  //                           final cl = filtered[i];
  //                           final name = (cl['name'] ?? '').toString();
  //                           final code = (cl['code'] ?? '').toString();
  //                           final contact = (cl['contact_name'] ?? '').toString();
  //
  //                           return ListTile(
  //                             title: Text(name, style: const TextStyle(fontWeight: FontWeight.w600)),
  //                             subtitle: Text(code.isNotEmpty ? '$code • $contact' : contact),
  //
  //                             onTap: () {
  //                               setState(() {
  //                                 _clientId = int.tryParse((cl['id'] ?? '').toString());
  //                                 _clientLabel = name;
  //                                 _clientSearchC.text = name;
  //                               });
  //                               Navigator.of(context).pop();
  //                             },
  //                           );
  //                         },
  //                       ),
  //                     )
  //                 ],
  //               ),
  //             ),
  //           ),
  //         );
  //       });
  //     },
  //   );
  // }

// Declare globally (inside your State class)


  Future<void> _showClientSelector() async {
    // start with current text (if any)
    String query = _clientSearchC.text ?? '';

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (c) {
        return StatefulBuilder(builder: (context, setModalState) {
          // Ensure the input is focused after the sheet has appeared
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              FocusScope.of(context).requestFocus(_clientSearchFocusNode);
              // optionally place cursor at end
              _clientSearchC.selection = TextSelection.fromPosition(
                TextPosition(offset: _clientSearchC.text.length),
              );
            }
          });

          final filtered = _clients.where((cl) {
            final n = (cl['name'] ?? '').toString().toLowerCase();
            return n.contains(_clientSearchC.text.toLowerCase());
          }).toList();

          return SafeArea(
            child: Padding(
              padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
              child: Container(
                height: MediaQuery.of(context).size.height * 0.65,
                margin: const EdgeInsets.only(top: 20),
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            focusNode: _clientSearchFocusNode,
                            controller: _clientSearchC,
                            autofocus: true, // helpful fallback
                            decoration: InputDecoration(
                              prefixIcon: const Icon(Icons.search),
                              hintText: 'Search client...',
                              filled: true,
                              fillColor: Colors.grey.shade100,
                              contentPadding: const EdgeInsets.symmetric(vertical: 0, horizontal: 12),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: BorderSide.none,
                              ),
                            ),
                            onChanged: (v) {
                              query = v;
                              setModalState(() {}); // rebuild filtered list
                            },
                          ),
                        ),
                        IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.of(context).pop()),
                      ],
                    ),
                    const SizedBox(height: 10),
                    if (filtered.isEmpty)
                      Expanded(
                        child: Center(
                          child: Text('No clients found', style: TextStyle(color: Colors.grey.shade600)),
                        ),
                      )
                    else
                      Expanded(
                        child: ListView.separated(
                          physics: const BouncingScrollPhysics(),
                          itemCount: filtered.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (ctx, i) {
                            final cl = filtered[i];
                            final name = (cl['name'] ?? '').toString();
                            final code = (cl['code'] ?? '').toString();
                            final contact = (cl['contact_name'] ?? '').toString();

                            return ListTile(
                              title: Text(name, style: const TextStyle(fontWeight: FontWeight.w600)),
                              subtitle: Text(code.isNotEmpty ? '$code • $contact' : contact),
                              onTap: () {
                                setState(() {
                                  _clientId = int.tryParse((cl['id'] ?? '').toString());
                                  _clientLabel = name;
                                  _clientSearchC.text = name;
                                });
                                Navigator.of(context).pop();
                              },
                            );
                          },
                        ),
                      ),
                  ],
                ),
              ),
            ),
          );
        });
      },
    );
  }



  // helper date/time pickers
  Future<void> _selectDate(TextEditingController controller) async {
    final now = DateTime.now();
    final picked = await showDatePicker(context: context, initialDate: now, firstDate: DateTime(now.year - 3), lastDate: DateTime(now.year + 5));
    if (picked != null) controller.text = DateFormat('dd-MM-yyyy').format(picked);
  }

  Future<void> _selectTime(TextEditingController controller) async {
    final now = TimeOfDay.now();
    final picked = await showTimePicker(context: context, initialTime: now);
    if (picked != null) controller.text = picked.format(context);
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) {
      // ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please correct the errors in the form')));
      Fluttertoast.showToast(
        msg: "Please correct the errors in the form.",
        toastLength: Toast.LENGTH_SHORT,
        gravity: ToastGravity.BOTTOM,
        backgroundColor: Colors.redAccent.shade200,
        textColor: Colors.white,
        fontSize: 14.0,
      );
      return;
    }

    if (_categoryId == null) {
      Fluttertoast.showToast(
        msg: "Select category",
        toastLength: Toast.LENGTH_SHORT,gravity: ToastGravity.BOTTOM,backgroundColor: Colors.redAccent.shade200,textColor: Colors.white,
        fontSize: 14.0,
      );

      // ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Select category')));
      return;
    }
    if (_assignToId == null) {
      // ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Select assignee')));
      Fluttertoast.showToast(
        msg: "Select assignee",
        toastLength: Toast.LENGTH_SHORT,gravity: ToastGravity.BOTTOM,backgroundColor: Colors.redAccent.shade200,textColor: Colors.white,
        fontSize: 14.0,
      );
      return;
    }
    // after form validation (or instead of) add:
    if (_descC.text.trim().isEmpty) {
      Fluttertoast.showToast(
        msg: "Please enter description",
        toastLength: Toast.LENGTH_SHORT,
        gravity: ToastGravity.BOTTOM,
        backgroundColor: Colors.redAccent.shade200,
        textColor: Colors.white,
        fontSize: 14.0,
      );

      return;
    }


    if (_clientId == null && ( _clientId != 0 || _clientId != '0' )) {
      // ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Select client')));
      Fluttertoast.showToast(
        msg: "Select client",
        toastLength: Toast.LENGTH_SHORT,gravity: ToastGravity.BOTTOM,backgroundColor: Colors.redAccent.shade200,textColor: Colors.white,
        fontSize: 14.0,
      );
      return;
    }

    setState(() {
      _submitting = true;
      _uploadProgress = 0.0;
    });

    // Add detailed logging for debug (remove or reduce in production)
    _dio.interceptors.add(LogInterceptor(
      request: true,
      requestHeader: true,
      requestBody: true,
      responseHeader: true,
      responseBody: true,
      error: true,
    ));

    try {
      final prefs = await SharedPreferences.getInstance();

      // parse user data robustly
      int userId = 0;
      String userType = '';
      String userName = '';

      final raw = prefs.getString('user_data');
      if (raw != null && raw.isNotEmpty) {
        try {
          final Map<String, dynamic> u = jsonDecode(raw);
          userId = (u['id'] is int) ? u['id'] as int : int.tryParse((u['id'] ?? '').toString()) ?? userId;

          // userType in DB expects integer — map common string values
          userType = u['user_type'] ?? u['type'] ?? u['role'] ?? u['userType'] ?? '';

          userName = (u['name'] ?? u['username'] ?? '').toString();
        } catch (_) {}
      }

      final url = '$_domain$_slug/createTaskApi';
      // DEBUG: print final URL so you can see if slug is empty / malformed
      // debugPrint('Submit URL: $url');

      // map priority to integer expected by backend (update mapping if server expects other numbers)
      int intPriority;
      switch (_priority.toLowerCase()) {
        case 'high':
          intPriority = 2;
          break;
        case 'medium':
          intPriority = 1;
          break;
        case 'low':
        default:
          intPriority = 0;
      }

      final Map<String, dynamic> fields = {
        'id': userId,
        'userType': userType,
        'client_id': _clientId,
        'userName': userName,
        'category': _categoryId,
        'subject': _titleC.text.trim(),
        'priority': intPriority,
        'due_date': _dueDateC.text.trim().isNotEmpty ? _dueDateC.text.trim() : null,
        'due_time': _dueTimeC.text.trim().isNotEmpty ? _dueTimeC.text.trim() : null,
        'assign_to': _assignToId != null ? _assignToId.toString() : null,
        'desc': _descC.text.trim().isNotEmpty ? _descC.text.trim() : null,
      };

      // remove nulls
      final cleaned = <String, dynamic>{};
      fields.forEach((k, v) {
        if (v != null) cleaned[k] = v;
      });

      FormData form;
      if (_pickedFilePath != null) {
        final file = File(_pickedFilePath!);
        if (await file.exists()) {
          final size = await file.length();
          const maxBytes = 100 * 1024 * 1024;
          if (size > maxBytes) {
            // ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('File too large. Max allowed 2 MB.')));
            Fluttertoast.showToast(
              msg: "File too large. Max allowed 100 MB.",
              toastLength: Toast.LENGTH_SHORT,gravity: ToastGravity.BOTTOM,backgroundColor: Colors.redAccent.shade200,textColor: Colors.white,
              fontSize: 14.0,
            );
            setState(() => _submitting = false);
            return;
          }
          final name = file.path.split('/').last;
          final mp = await MultipartFile.fromFile(file.path, filename: name);
          form = FormData.fromMap({...cleaned, 'services_doc': mp}); // server expects 'services_doc'
        } else {
          form = FormData.fromMap({...cleaned});
        }
      } else {
        form = FormData.fromMap({...cleaned});
      }

      final resp = await _dio.post(
        url,
        data: form,
        options: Options(headers: {'Accept': 'application/json'}),
        onSendProgress: (sent, total) {
          if (total > 0) {
            setState(() {
              _uploadProgress = sent / total;
            });
          }
        },
      );

      debugPrint('Submit response status: ${resp.statusCode}');
      debugPrint('Submit response data: ${resp.data}');

      if (resp.statusCode == 200 || resp.statusCode == 201) {
        final body = resp.data;
        final msg = (body is Map && body['message'] != null) ? body['message'].toString() : 'Task created';
        final ok = (body is Map && ((body['status']?.toString().toLowerCase() == 'success') || body['status']?.toString() == '1'));

        // show result and pop on success
        await showModalBottomSheet(
          context: context,
          backgroundColor: Colors.transparent,
          barrierColor: Colors.black26,
          builder: (c) {
            Future.delayed(const Duration(milliseconds: 1800), () => Navigator.of(c).maybePop());
            return Align(
                alignment: Alignment.topCenter,
                child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8),
                child: Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(color: Theme.of(context).cardColor, borderRadius: BorderRadius.circular(12)),
                  child: Row(
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(color: ok ? Colors.green.withOpacity(0.12) : Colors.redAccent.withOpacity(0.12), borderRadius: BorderRadius.circular(10)),
                        child: Icon(ok ? Icons.check_circle_outline : Icons.error_outline, color: ok ? Colors.green : Colors.redAccent),
                      ),
                      const SizedBox(width: 12),
                      Expanded(child: Text(msg, style: const TextStyle(fontWeight: FontWeight.w600))),
                      IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.of(context).maybePop()),
                    ],
                  ),
                ),
              ),
                ),
            );
          },
        );


        // if (!_dirty) {
        //   setState(() => _dirty = true);
        // }
        // Navigator.of(context).pop({'created': true, 'message': msg});



        if (ok) Navigator.of(context).pop({'created': true, 'message': msg});
      } else {
        final msg = (resp.data is Map && resp.data['message'] != null) ? resp.data['message'].toString() : 'Server returned ${resp.statusCode}';
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Create failed: $msg')));
      }
    } on DioError catch (err) {
      // show server response when Dio throws
      final r = err.response;
      debugPrint('DioError(${err.type}): ${err.message}');
      debugPrint('Response status: ${r?.statusCode}');
      debugPrint('Response data: ${r?.data}');
      debugPrint('Final url attempted: ${r?.requestOptions.uri ?? "unknown"}');

      // helpful message to user + detailed snackbar for development
      // ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Submit error: ${r?.statusCode ?? ''} ${r?.data ?? err.message}')));
      Fluttertoast.showToast(
        msg: "Submit error: ${r?.statusCode ?? ''} ${r?.data ?? err.message}",
        toastLength: Toast.LENGTH_SHORT,gravity: ToastGravity.BOTTOM,backgroundColor: Colors.redAccent.shade200,textColor: Colors.white,
        fontSize: 14.0,
      );
    } catch (e) {
      debugPrint('Submit unexpected error: $e');
      Fluttertoast.showToast(
        msg: "Submit error: $e",
        toastLength: Toast.LENGTH_SHORT,gravity: ToastGravity.BOTTOM,backgroundColor: Colors.redAccent.shade200,textColor: Colors.white,
        fontSize: 14.0,
      );
      // ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Submit error: $e')));
    } finally {
      setState(() {
        _submitting = false;
        _uploadProgress = 0.0;
      });
    }
  }

  // skeleton UI
  Widget _loadingSkeleton() {
    Widget box({double h = 14, double w = double.infinity}) => Container(height: h, width: w, decoration: BoxDecoration(color: Colors.grey.shade200, borderRadius: BorderRadius.circular(6)));
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12),
      child: Column(
        children: [
          Row(children: [box(h: 36, w: 36), const SizedBox(width: 12), Expanded(child: box(h: 14))]),
          const SizedBox(height: 12),
          Card(
            elevation: 2,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(children: [
                Row(children: [Expanded(child: box(h: 14)), const SizedBox(width: 12), box(h: 14, w: 80)]),
                const SizedBox(height: 12),
                Row(children: [Expanded(child: box(h: 40)), const SizedBox(width: 12), Expanded(child: box(h: 40))]),
                const SizedBox(height: 12),
                box(h: 14),
                const SizedBox(height: 8),
                box(h: 120),
                const SizedBox(height: 8),
                box(h: 14),
                const SizedBox(height: 8),
                Row(children: [Expanded(child: box(h: 40)), const SizedBox(width: 12), Expanded(child: box(h: 40))]),
                const SizedBox(height: 12),
                box(h: 40),
              ]),
            ),
          ),
        ],
      ),
    );
  }

  InputDecoration _fieldDecor({
    String? hint,
    Widget? suffixIcon,
    Widget? prefixIcon,
  }) {
    return InputDecoration(
      hintText: hint,
      filled: true,
      fillColor: Colors.white,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      enabledBorder: OutlineInputBorder(
        borderSide: BorderSide(color: Colors.grey.shade300),
        borderRadius: BorderRadius.circular(8),
      ),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
      suffixIcon: suffixIcon,
      prefixIcon: prefixIcon,
    );
  }

  Widget _label(String text, {bool required = false}) {
    return RichText(
      text: TextSpan(
        text: text,
        style: TextStyle(fontWeight: FontWeight.w600, color: Colors.grey[800]),
        children: required ? [TextSpan(text: ' *', style: TextStyle(color: Colors.red))] : null,
      ),
    );
  }

  // Build dropdown from categories/users loaded from API
  List<DropdownMenuItem<int>> _categoryItems() {
    if (_categories.isEmpty) return <DropdownMenuItem<int>>[];
    return _categories.map<DropdownMenuItem<int>?>((c) {
      // try both category_id and id; allow null-check
      final rawId = (c['category_id'] ?? c['id'] ?? '').toString();
      final id = int.tryParse(rawId);
      final label = (c['category'] ?? c['name'] ?? '').toString();
      if (id == null) return null; // skip invalid entries (no id)
      return DropdownMenuItem<int>(value: id, child: Text(label));
    }).whereType<DropdownMenuItem<int>>().toList();
  }

  List<DropdownMenuItem<int>> _userItems() {
    if (_users.isEmpty) return <DropdownMenuItem<int>>[];
    return _users.map<DropdownMenuItem<int>?>((u) {
      final rawId = (u['id'] ?? '').toString();
      final id = int.tryParse(rawId);
      final label = (u['name'] ?? u['full_name'] ?? '').toString();
      if (id == null) return null;
      return DropdownMenuItem<int>(value: id, child: Text(label));
    }).whereType<DropdownMenuItem<int>>().toList();
  }

  Map<String, dynamic>? _findById(List<Map<String, dynamic>> list, int? id, {List<String> keys = const ['category_id', 'id']}) {
    if (id == null) return null;
    final idx = list.indexWhere((m) {
      for (final k in keys) {
        final raw = (m[k] ?? '').toString();
        if (raw.isNotEmpty && int.tryParse(raw) == id) return true;
      }
      return false;
    });
    if (idx >= 0) return Map<String, dynamic>.from(list[idx]);
    return null;
  }

  DateTime? _parseDateFromController(TextEditingController dateC) {
    final text = dateC.text.trim();
    if (text.isEmpty) return null;
    // expect dd-mm-yyyy
    final parts = text.split(RegExp(r'[-\/]'));
    if (parts.length != 3) return null;
    final d = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    final y = int.tryParse(parts[2]);
    if (d == null || m == null || y == null) return null;
    try {
      return DateTime(y, m, d);
    } catch (_) {
      return null;
    }
  }

  TimeOfDay? _parseTimeFromController(TextEditingController timeC) {
    final text = timeC.text.trim().toLowerCase();
    if (text.isEmpty) return null;
    // support "hh:mm", "h:mm am/pm", "hh:mmam" etc.
    final reg = RegExp(r'^\s*(\d{1,2}):(\d{2})\s*([ap]m)?\s*$');
    final m = reg.firstMatch(text);
    if (m == null) return null;
    final hh = int.tryParse(m.group(1) ?? '');
    final mm = int.tryParse(m.group(2) ?? '');
    final ap = m.group(3); // may be null
    if (hh == null || mm == null) return null;
    var hour = hh;
    if (ap != null) {
      final ampm = ap.toLowerCase();
      if (ampm == 'pm' && hour < 12) hour += 12;
      if (ampm == 'am' && hour == 12) hour = 0;
    }
    if (hour < 0 || hour > 23 || mm < 0 || mm > 59) return null;
    return TimeOfDay(hour: hour, minute: mm);
  }
  DateTime? _buildDateTimeFromControllers(TextEditingController dateC, TextEditingController timeC) {
    final date = _parseDateFromController(dateC);
    final time = _parseTimeFromController(timeC);
    if (date == null || time == null) return null;
    return DateTime(date.year, date.month, date.day, time.hour, time.minute);
  }
// compare; returns true if due > start
  bool _isDueAfterStart() {
    final startDT = _buildDateTimeFromControllers(_startDateC, _startTimeC);
    final dueDT = _buildDateTimeFromControllers(_dueDateC, _dueTimeC);
    if (startDT == null || dueDT == null) return true; // if either not set yet, don't block
    return dueDT.isAfter(startDT);
  }

// friendly error dialog; returns Future<bool> true if user acknowledged
  Future<bool> _showInvalidDueDialog() async {
    return await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Invalid End Date/Time'),
        content: const Text('End date & time must be later than the Start date & time. Please select a valid value.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(c).pop(false), child: const Text('Clear Due')),
          ElevatedButton(onPressed: () => Navigator.of(c).pop(true), child: const Text('Set to +1 hour')),
        ],
      ),
    ) ??
        false;
  }

// Called after user picks or edits the due fields or the start fields
  Future<void> _ensureDueIsAfterStartOrFix() async {
    final startDT = _buildDateTimeFromControllers(_startDateC, _startTimeC);
    final dueDT = _buildDateTimeFromControllers(_dueDateC, _dueTimeC);

    if (startDT == null || dueDT == null) return; // nothing to validate

    if (!dueDT.isAfter(startDT)) {
      // Ask user what to do: Clear due or set to start + 1 hour
      final setPlusOne = await _showInvalidDueDialog();
      if (setPlusOne) {
        final newDt = startDT.add(const Duration(hours: 1));
        // write controllers in dd-mm-yyyy and hh:mm am/pm format
        _dueDateC.text = _formatDateForField(newDt);
        _dueTimeC.text = _formatTimeForField(newDt);
        setState(() {});
      } else {
        // clear due fields
        _dueDateC.clear();
        _dueTimeC.clear();
        setState(() {});
      }
    }
  }
  // small format helpers (dd-mm-yyyy and hh:mm am/pm)
  String _formatDateForField(DateTime dt) {
    final dd = dt.day.toString().padLeft(2, '0');
    final mm = dt.month.toString().padLeft(2, '0');
    final yyyy = dt.year.toString();
    return '$dd-$mm-$yyyy';
  }

  String _formatTimeForField(DateTime dt) {
    int hour = dt.hour;
    final minute = dt.minute.toString().padLeft(2, '0');
    final ampm = hour >= 12 ? 'pm' : 'am';
    hour = hour % 12;
    if (hour == 0) hour = 12;
    return '${hour.toString().padLeft(2, '0')}:$minute $ampm';
  }


// ---------------------- Form validator for due fields ----------------------
// Use this in your TextFormField validator for due date/time fields if you need inline validation
  String? dueDateTimeValidator() {
    final startDT = _buildDateTimeFromControllers(_startDateC, _startTimeC);
    final dueDT = _buildDateTimeFromControllers(_dueDateC, _dueTimeC);
    if (dueDT == null) return 'Select end date/time';
    if (startDT == null) return null; // no start yet -> allow
    if (!dueDT.isAfter(startDT)) return 'End must be after start';
    return null;
  }

// ------------------------------------------------------------------
// Show a bottom sheet allowing the user to pick Camera / Gallery / Files
  Future<void> _showPickSourceSheet() async {
    showModalBottomSheet(
      context: context,
      builder: (c) {
        return SafeArea(
          child: Wrap(
            children: [
              ListTile(
                leading: const Icon(Icons.camera_alt),
                title: const Text('Take Photo'),
                onTap: () {
                  Navigator.of(c).pop();
                  _pickFromCamera();
                },
              ),
              ListTile(
                leading: const Icon(Icons.photo_library),
                title: const Text('Choose from Gallery'),
                onTap: () {
                  Navigator.of(c).pop();
                  _pickFromGallery();
                },
              ),
              ListTile(
                leading: const Icon(Icons.insert_drive_file),
                title: const Text('Choose Document'),
                onTap: () {
                  Navigator.of(c).pop();
                  _pickDocument();
                },
              ),
              // ListTile(
              //   leading: const Icon(Icons.close),
              //   title: const Text('Cancel'),
              //   onTap: () => Navigator.of(c).pop(),
              // )
            ],
          ),
        );
      },
    );
  }

// ------------------------------------------------------------------
// Helper: pick using camera
  Future<void> _pickFromCamera() async {
    try {
      // optional: explicitly request camera permission before opening
      // final status = await Permission.camera.request();
      // if (!status.isGranted) {
      //   ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Camera permission is required')));
      //   return;
      // }

      final ImagePicker picker = ImagePicker();
      final XFile? xfile = await picker.pickImage(
        source: ImageSource.camera,
        imageQuality: 85, // compress quality (0-100)
        maxWidth: 2048,
        maxHeight: 2048,
      );
      if (xfile == null) return;

      final f = File(xfile.path);
      final size = await f.length();
      const maxBytes = 100 * 1024 * 1024;
      if (size > maxBytes) {
        Fluttertoast.showToast(
          msg: "File too large. Max allowed 100 MB.",
          toastLength: Toast.LENGTH_SHORT,gravity: ToastGravity.BOTTOM,backgroundColor: Colors.redAccent.shade200,textColor: Colors.white,
          fontSize: 14.0,
        );
        // ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('File too large. Max allowed 4 MB.')));
        return;
      }

      setState(() {
        _pickedFileName = xfile.name;
        _pickedFilePath = xfile.path;
        _pickedFileSizeBytes = size;
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Picked photo: ${xfile.name}')));
    } catch (e) {
      Fluttertoast.showToast(
        msg: "Camera pick failed: $e",
        toastLength: Toast.LENGTH_SHORT,gravity: ToastGravity.BOTTOM,backgroundColor: Colors.redAccent.shade200,textColor: Colors.white,
        fontSize: 14.0,
      );
      // ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Camera pick failed: $e')));
    }
  }

// ------------------------------------------------------------------
// Helper: pick from gallery (images only)
  Future<void> _pickFromGallery() async {
    try {
      // ask for photos permission on iOS/Android if you prefer explicit handling:
      // final status = await Permission.photos.request();
      // if (!status.isGranted && !status.isLimited) {
      //   ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Photos permission is required')));
      //   // still proceed — image_picker may handle it; adjust per your policy.
      //   return;
      // }

      final ImagePicker picker = ImagePicker();
      final XFile? xfile = await picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 85,
        maxWidth: 2048,
        maxHeight: 2048,
      );
      if (xfile == null) return;

      final f = File(xfile.path);
      final size = await f.length();
      const maxBytes = 100 * 1024 * 1024;
      if (size > maxBytes) {
        Fluttertoast.showToast(
          msg: "File too large. Max allowed 100 MB.",
          toastLength: Toast.LENGTH_SHORT,gravity: ToastGravity.BOTTOM,backgroundColor: Colors.redAccent.shade200,textColor: Colors.white,
          fontSize: 14.0,
        );
        // ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('File too large. Max allowed 4 MB.')));
        return;
      }

      setState(() {
        _pickedFileName = xfile.name;
        _pickedFilePath = xfile.path;
        _pickedFileSizeBytes = size;
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Picked image: ${xfile.name}')));
    } catch (e) {
      Fluttertoast.showToast(
        msg: "Gallery pick failed: $e",
        toastLength: Toast.LENGTH_SHORT,gravity: ToastGravity.BOTTOM,backgroundColor: Colors.redAccent.shade200,textColor: Colors.white,
        fontSize: 14.0,
      );

      // ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Gallery pick failed: $e')));
    }
  }

// ------------------------------------------------------------------
// Helper: pick a generic document (pdf/xlsx/doc/images etc.)
  Future<void> _pickDocument() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['jpg', 'jpeg', 'png', 'pdf', 'doc', 'docx', 'xlsx'],
        allowMultiple: false,
        withData: false, // we just need path
      );
      if (result == null) return;
      final file = result.files.first;
      if (file.path == null) return;

      final size = file.size;
      const maxBytes = 100 * 1024 * 1024;
      if (size > maxBytes) {
        Fluttertoast.showToast(
          msg: "File too large. Max allowed 100 MB.",
          toastLength: Toast.LENGTH_SHORT,gravity: ToastGravity.BOTTOM,backgroundColor: Colors.redAccent.shade200,textColor: Colors.white,
          fontSize: 14.0,
        );
        // ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('File too large. Max allowed 4 MB.')));
        return;
      }

      setState(() {
        _pickedFileName = file.name;
        _pickedFilePath = file.path;
        _pickedFileSizeBytes = file.size;
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Picked file: ${file.name}')));
    } catch (e) {
      Fluttertoast.showToast(
        msg: "File pick failed: $e.",
        toastLength: Toast.LENGTH_SHORT,gravity: ToastGravity.BOTTOM,backgroundColor: Colors.redAccent.shade200,textColor: Colors.white,
        fontSize: 14.0,
      );
      // ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('File pick failed: $e')));
    }
  }

  /// Clears the currently picked file
  void _clearPickedFile() {
    setState(() {
      _pickedFileName = null;
      _pickedFilePath = null;
      _pickedFileSizeBytes = null;
    });
  }

  // // call this from the GestureDetector onTap
  // Future<void> _openUserSearchSheet(BuildContext context) async {
  //   if (_users == null) return; // guard - ensure your _users list is ready
  //
  //   final TextEditingController searchCtrl = TextEditingController();
  //   List<Map<String, dynamic>> filtered = List<Map<String, dynamic>>.from(_users.cast<Map<String, dynamic>>());
  //
  //   await showModalBottomSheet(
  //     context: context,
  //     isScrollControlled: true,
  //     backgroundColor: Colors.white,
  //     shape: const RoundedRectangleBorder(
  //       borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
  //     ),
  //     builder: (ctx) {
  //       return StatefulBuilder(builder: (ctx, setModalState) {
  //         void doFilter(String q) {
  //           final qq = q.trim().toLowerCase();
  //           setModalState(() {
  //             if (qq.isEmpty) {
  //               filtered = List<Map<String, dynamic>>.from(_users.cast<Map<String, dynamic>>());
  //             } else {
  //               filtered = _users
  //                   .cast<Map<String, dynamic>>()
  //                   .where((u) {
  //                 final name = (u['name'] ?? '').toString().toLowerCase();
  //                 final email = (u['email'] ?? '').toString().toLowerCase();
  //                 final id = (u['id'] ?? '').toString().toLowerCase();
  //                 return name.contains(qq) || email.contains(qq) || id.contains(qq);
  //               })
  //                   .toList();
  //             }
  //           });
  //         }
  //
  //         return Padding(
  //           padding: EdgeInsets.only(
  //             bottom: MediaQuery.of(ctx).viewInsets.bottom,
  //             left: 12,
  //             right: 12,
  //             top: 12,
  //           ),
  //           child: Column(
  //             mainAxisSize: MainAxisSize.min,
  //             children: [
  //               // handle / header
  //               Container(
  //                 width: 40,
  //                 height: 4,
  //                 margin: const EdgeInsets.only(bottom: 12),
  //                 decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(4)),
  //               ),
  //
  //               // Search box
  //               TextField(
  //                 controller: searchCtrl,
  //                 autofocus: true,
  //                 onChanged: doFilter,
  //                 decoration: InputDecoration(
  //                   hintText: 'Search name',
  //                   prefixIcon: const Icon(Icons.search),
  //                   suffixIcon: searchCtrl.text.isNotEmpty
  //                       ? IconButton(
  //                     icon: const Icon(Icons.clear),
  //                     onPressed: () {
  //                       searchCtrl.clear();
  //                       doFilter('');
  //                     },
  //                   )
  //                       : null,
  //                   border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
  //                   isDense: true,
  //                   contentPadding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
  //                 ),
  //               ),
  //
  //               const SizedBox(height: 8),
  //
  //               // List
  //               SizedBox(
  //                 height: 320, // adjust as needed
  //                 child: filtered.isEmpty
  //                     ? const Center(child: Text('No users found'))
  //                     : ListView.separated(
  //                   itemCount: filtered.length,
  //                   separatorBuilder: (_, __) => const Divider(height: 1),
  //                   itemBuilder: (context, idx) {
  //                     final user = filtered[idx];
  //                     final uid = (user['id'] ?? '').toString();
  //                     final name = (user['name'] ?? '').toString();
  //                     final subtitleParts = <String>[];
  //                     if (user['email'] != null && user['email'].toString().isNotEmpty) subtitleParts.add(user['email'].toString());
  //                     if (user['phone'] != null && user['phone'].toString().isNotEmpty) subtitleParts.add(user['phone'].toString());
  //                     final subtitle = subtitleParts.join(' • ');
  //
  //                     return ListTile(
  //                       leading: CircleAvatar(child: Text(name.isNotEmpty ? name[0].toUpperCase() : '?')),
  //                       title: Text(name),
  //                       subtitle: subtitle.isNotEmpty ? Text(subtitle) : null,
  //                       onTap: () {
  //                         // choose this user and pop
  //                         setState(() {
  //                           _assignToId = (int.tryParse(uid) ?? uid) as int?; // keep original type if needed
  //                           _assignToLabel = name;
  //                         });
  //                         Navigator.of(ctx).pop();
  //                       },
  //                     );
  //                   },
  //                 ),
  //               ),
  //
  //               const SizedBox(height: 12),
  //             ],
  //           ),
  //         );
  //       });
  //     },
  //   );
  // }

// call this from the GestureDetector onTap
  Future<void> _openUserSearchSheet(BuildContext context) async {
    if (_users == null) return; // guard - ensure your _users list is ready

    final TextEditingController searchCtrl = TextEditingController();
    List<Map<String, dynamic>> filtered = List<Map<String, dynamic>>.from(_users.cast<Map<String, dynamic>>());

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      builder: (ctx) {
        return StatefulBuilder(builder: (ctx, setModalState) {
          void doFilter(String q) {
            final qq = q.trim().toLowerCase();
            setModalState(() {
              if (qq.isEmpty) {
                filtered = List<Map<String, dynamic>>.from(_users.cast<Map<String, dynamic>>());
              } else {
                filtered = _users
                    .cast<Map<String, dynamic>>()
                    .where((u) {
                  final name = (u['name'] ?? '').toString().toLowerCase();
                  final email = (u['email'] ?? '').toString().toLowerCase();
                  final id = (u['id'] ?? '').toString().toLowerCase();
                  return name.contains(qq) || email.contains(qq) || id.contains(qq);
                })
                    .toList();
              }
            });
          }

          // ensure UI updates when controller text changes (to show/hide clear button)
          searchCtrl.addListener(() {
            // call setModalState to refresh suffixIcon when text changes
            try {
              setModalState(() {});
            } catch (_) {}
          });

          return Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(ctx).viewInsets.bottom,
              left: 12,
              right: 12,
              top: 12,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // handle / header
                Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(4)),
                ),

                // Search row with clear (inside) and cancel (to close sheet)
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: searchCtrl,
                        autofocus: true,
                        onChanged: doFilter,
                        decoration: InputDecoration(
                          hintText: 'Search name',
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
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
                        ),
                      ),
                    ),

                    const SizedBox(width: 8),

                    // Cancel/Close button (right side)
                    Container(
                      height: 42,
                      width: 42,
                      decoration: BoxDecoration(
                        color: Colors.grey.shade100,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: IconButton(
                        icon: const Icon(Icons.close, size: 20, color: Colors.black54),
                        tooltip: 'Cancel',
                        onPressed: () => Navigator.of(ctx).pop(),
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 8),

                // List
                SizedBox(
                  height: 320, // adjust as needed or make it dynamic
                  child: filtered.isEmpty
                      ? const Center(child: Text('No users found'))
                      : ListView.separated(
                    itemCount: filtered.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, idx) {
                      final user = filtered[idx];
                      final uid = (user['id'] ?? '').toString();
                      final name = (user['name'] ?? '').toString();
                      final subtitleParts = <String>[];
                      if (user['email'] != null && user['email'].toString().isNotEmpty) subtitleParts.add(user['email'].toString());
                      if (user['phone'] != null && user['phone'].toString().isNotEmpty) subtitleParts.add(user['phone'].toString());
                      final subtitle = subtitleParts.join(' • ');

                      return ListTile(
                        leading: CircleAvatar(child: Text(name.isNotEmpty ? name[0].toUpperCase() : '?')),
                        title: Text(name),
                        subtitle: subtitle.isNotEmpty ? Text(subtitle) : null,
                        onTap: () {
                          // choose this user and pop
                          setState(() {
                            // keep type consistent with your other code
                            _assignToId = (int.tryParse(uid) ?? uid) as int?;
                            _assignToLabel = name;
                          });
                          Navigator.of(ctx).pop();
                        },
                      );
                    },
                  ),
                ),

                const SizedBox(height: 12),
              ],
            ),
          );
        });
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final accentColor = const Color(0xFF6B59C9);
    // return Scaffold(
    return WillPopScope(
      onWillPop: () async {
        // Return _dirty to caller (true if something changed); ensures normal back button also returns this value
        Navigator.of(context).pop(_dirty);
        return false; // we've handled the pop
      },
      child:Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: Colors.black87,
        elevation: 1,
        title: const Text('Add New Task', style: TextStyle(fontWeight: FontWeight.w700)),
        actions: [IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.of(context).maybePop(), tooltip: 'Close')],
      ),
      body: SafeArea(
        child: _loading
            ? SingleChildScrollView(child: _loadingSkeleton())
            : _error != null
            ? SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 25),
          child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.redAccent)),
            const SizedBox(height: 12),
            ElevatedButton.icon(onPressed: () => _fetchAddPageData(), icon: const Icon(Icons.refresh), label: const Text('Retry')),
          ])),
        )
            : Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 12),

            children: [

              // header row
              Row(children: [
                Text(_newRid ?? 'RID-000', style: TextStyle(color: accentColor, fontWeight: FontWeight.bold)),
                const SizedBox(width: 15),
                const Spacer(),
                Text(DateFormat('dd-MM-yyyy HH:mm a').format(DateTime.now()), style: TextStyle(color: Colors.grey.shade700))
              ]),
              const SizedBox(height: 15),

              Card(
                color: Colors.white,
                elevation: 2,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),

                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(children: [
                    // Category & Assign To
                    Row(
                      children: [
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            _label('Category', required: true),
                            const SizedBox(height: 8),

                            DropdownButtonFormField<int>(
                              decoration: _fieldDecor(hint: 'Select Category'), // keep your field decoration helper
                              value: _categoryId, // null shows hint
                              isExpanded: true,
                              hint: const Text('Select Category'),
                              items: _categoryItems(),
                              onChanged: (v) {
                                final sel = _findById(_categories, v, keys: ['category_id', 'id']);
                                setState(() {
                                  _categoryId = v;
                                  _categoryLabel = sel != null ? (sel['category'] ?? sel['name']).toString() : null;
                                });
                              },
                              validator: (v) => v == null ? 'Select category' : null,
                            ),

                          ]),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),

                    // Replace your existing Row / DropdownButtonFormField with this
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _label('Assign To', required: true),
                              const SizedBox(height: 8),
                              // Read-only form field that opens a searchable modal
                              GestureDetector(
                                onTap: () => _openUserSearchSheet(context),
                                child: AbsorbPointer(
                                  child: TextFormField(
                                    readOnly: true,
                                    decoration: _fieldDecor(
                                      hint: 'Select User',

                                    ),
                                    controller: TextEditingController(text: _assignToLabel ?? ''),
                                    validator: (v) => _assignToId == null ? 'Select user' : null,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),



                    const SizedBox(height: 8),

                    // Title & Description
                    Row(
                        children: [
                          Expanded(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              _label('Task Title', required: true),
                              const SizedBox(height: 8),
                              TextFormField(controller: _titleC, decoration: _fieldDecor(hint: 'Enter task title'),
                                  validator: (v) => (v == null || v.trim().isEmpty) ? 'Enter task title' : null),
                            ]),
                          ),
                        ]),
                    const SizedBox(height: 8),
                    //
                    // Row(children: [
                    //   Expanded(
                    //     child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    //       _label('Description'),
                    //       const SizedBox(height: 8),
                    //       TextFormField(controller: _descC, decoration: _fieldDecor(hint: 'Enter description'),
                    //         maxLines: 2,
                    //         maxLength: 150,
                    //       ),
                    //     ]),
                    //   ),
                    // ]),
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _label('Description'),
                              const SizedBox(height: 8),
                              TextFormField(
                                controller: _descC,
                                decoration: _fieldDecor(hint: 'Enter description'),
                                maxLines: 2,
                                // maxLength: 150,
                                validator: (value) {
                                  // Trim whitespace and require non-empty description
                                  if (value == null || value.trim().isEmpty) {
                                    return 'Description is required';
                                  }
                                  // optionally enforce minimum length:
                                  // if (value.trim().length < 5) return 'Please enter at least 5 characters';
                                  return null;
                                },
                                // Important: when saving or using the value later, use .trim()
                                // e.g. cleaned['desc'] = _descC.text.trim();
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),

                    Row(children: [
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          _label('Start Date & Time', required: true),
                          const SizedBox(height: 8),
                          Row(children: [
                            Expanded(
                              child: GestureDetector(
                                onTap: () => _selectDateWithTime(isStart: true),
                                child: AbsorbPointer(
                                  child: TextFormField(
                                    controller: _startDateC,
                                    decoration: _fieldDecor(hint: 'dd-mm-yyyy'),
                                    validator: (v) {
                                      if (v == null || v.isEmpty) return 'Select start date';
                                      final d = _parseDate(v);
                                      if (d == null) return 'Invalid date';
                                      final today = DateTime.now();
                                      final todayDate = DateTime(today.year, today.month, today.day);
                                      if (d.isBefore(todayDate)) return 'Start date cannot be in the past';
                                      return null;
                                    },
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            SizedBox(
                              width: 120,
                              child: GestureDetector(
                                onTap: () => _selectTimeWithDate(isStart: true),
                                child: AbsorbPointer(
                                  child: TextFormField(
                                    controller: _startTimeC,
                                    decoration: _fieldDecor(hint: 'hh:mm am'),
                                    validator: (v) {
                                      if (v == null || v.isEmpty) return 'Select start time';
                                      if (_parseTime(v) == null) return 'Invalid time';
                                      return null;
                                    },
                                  ),
                                ),
                              ),
                            ),
                          ]),
                        ]),
                      ),
                    ]),

                    const SizedBox(height: 8),

                    Row(children: [
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          _label('End Date & Time', required: true),
                          const SizedBox(height: 8),
                          Row(children: [
                            Expanded(
                              child: GestureDetector(
                                onTap: () => _selectDateWithTime(isStart: false),
                                child: AbsorbPointer(
                                  child: TextFormField(
                                    controller: _dueDateC,
                                    decoration: _fieldDecor(hint: 'dd-mm-yyyy'),
                                    validator: (v) {
                                      if (v == null || v.isEmpty) return 'Select end date';
                                      final dueDate = _parseDate(v);
                                      if (dueDate == null) return 'Invalid date';
                                      // ensure due date >= start date (if start date exists)
                                      final startDate = _parseDate(_startDateC.text);
                                      if (startDate != null && dueDate.isBefore(startDate)) return 'End date must be the same or after start date';
                                      // due date ok
                                      return null;
                                    },
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            SizedBox(
                              width: 120,
                              child: GestureDetector(
                                onTap: () => _selectTimeWithDate(isStart: false),
                                child: AbsorbPointer(
                                  child: TextFormField(
                                    controller: _dueTimeC,
                                    decoration: _fieldDecor(hint: 'hh:mm am'),
                                    validator: (v) {
                                      if (v == null || v.isEmpty) return 'Select end time';
                                      final dueTime = _parseTime(v);
                                      if (dueTime == null) return 'Invalid time';

                                      final startDate = _parseDate(_startDateC.text);
                                      final dueDate = _parseDate(_dueDateC.text);
                                      final startTime = _parseTime(_startTimeC.text);

                                      if (startDate != null && dueDate != null && startDate.year == dueDate.year && startDate.month == dueDate.month && startDate.day == dueDate.day) {
                                        // Compare as DateTimes; require due > start (strict)
                                        if (startTime == null) return 'Set start time first';
                                        final dueDT = DateTime(dueDate.year, dueDate.month, dueDate.day, dueTime.hour, dueTime.minute);
                                        final startDT = DateTime(startDate.year, startDate.month, startDate.day, startTime.hour, startTime.minute);
                                        if (!dueDT.isAfter(startDT)) return 'End time must be later than start time';
                                      }
                                      return null;
                                    },

                                  ),
                                ),
                              ),
                            ),
                          ]),
                        ]),
                      ),
                    ]),

                    const SizedBox(height: 8),

                    // Client & Priority
                    Row(children: [
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          _label('Client', required: true),
                          const SizedBox(height: 8),
                          TextFormField(controller: _clientSearchC, decoration: _fieldDecor(hint: 'Search client'), readOnly: true, onTap: _showClientSelector, validator: (v) => ((v?.isEmpty ?? true) && _clientId == null) ? 'Select client' : null),
                        ]),
                      ),
                    ]),

                    const SizedBox(height: 8),


                    // Inline, 3 radios across with adjustable gap between radio and label
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _label('Priority'),
                              const SizedBox(height: 8),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween, // <-- spread them out
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: ['High', 'Medium', 'Low'].map((p) {
                                  const double labelGap = 6.0; // adjust gap between radio and text
                                  return InkWell(
                                    borderRadius: BorderRadius.circular(6),
                                    onTap: () => setState(() => _priority = p),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min, // <-- don't expand, keep tight
                                      children: [
                                        Radio<String>(
                                          value: p,
                                          groupValue: _priority,
                                          onChanged: (v) => setState(() => _priority = v!),
                                          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                          visualDensity: const VisualDensity(vertical: -4, horizontal: 0),
                                        ),
                                        SizedBox(width: labelGap),
                                        Text(p, textAlign: TextAlign.left, softWrap: false), // <-- no wrapping
                                      ],
                                    ),
                                  );
                                }).toList(),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 15),

                    // Upload
                    Align(alignment: Alignment.centerLeft, child: _label('Upload Attachment')),
                    const SizedBox(height: 8),


                    // ---------- Upload area (replace your current upload widgets) ----------

                    // Container(
                    //   padding: const EdgeInsets.all(12),
                    //   decoration: BoxDecoration(
                    //     color: Colors.grey.shade50,
                    //     borderRadius: BorderRadius.circular(8),
                    //   ),
                    //   child: Column(
                    //     mainAxisSize: MainAxisSize.min,
                    //     crossAxisAlignment: CrossAxisAlignment.start,
                    //     children: [
                    //       // Top row: Choose button + optional progress
                    //       Row(
                    //         children: [
                    //           // Choose file button (kept compact with Flexible so it doesn't grow forever)
                    //           OutlinedButton.icon(
                    //             // onPressed: _pickFile, // your file picker handler
                    //             onPressed: _showPickSourceSheet,
                    //             icon: const Icon(Icons.attach_file),
                    //             label: Text('Attach file'),
                    //             style: OutlinedButton.styleFrom(
                    //               backgroundColor: Colors.white,
                    //               foregroundColor: accentColor,
                    //               side: BorderSide(color: Colors.grey.shade200),
                    //               shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    //               padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    //               elevation: 0,
                    //             ),
                    //           ),
                    //
                    //           const SizedBox(width: 12),
                    //
                    //           // Upload progress or a spacer
                    //           if (_loading)
                    //             Expanded(
                    //               child: Column(
                    //                 crossAxisAlignment: CrossAxisAlignment.start,
                    //                 children: [
                    //                   LinearProgressIndicator(value: _uploadProgress, minHeight: 8),
                    //                   const SizedBox(height: 6),
                    //                   Text('${(_uploadProgress * 100).toStringAsFixed(0)}%'),
                    //                 ],
                    //               ),
                    //             )
                    //           else
                    //             const Spacer(),
                    //         ],
                    //       ),
                    //
                    //       const SizedBox(height: 10),
                    //
                    //       // File info row — constrained so clear button remains visible
                    //       LayoutBuilder(builder: (context, constraints) {
                    //         final removeButtonWidth = _pickedFileName != null ? 40.0 : 0.0;
                    //         final iconWidth = 28.0;
                    //         final spacing = 8.0;
                    //         final nameMaxWidth =
                    //         (constraints.maxWidth - removeButtonWidth - iconWidth - spacing).clamp(60.0, constraints.maxWidth);
                    //
                    //         return Row(
                    //           children: [
                    //             // file icon
                    //             const Icon(Icons.insert_drive_file, size: 20, color: Colors.grey),
                    //             const SizedBox(width: 8),
                    //
                    //             // name + size area
                    //             SizedBox(
                    //               width: nameMaxWidth,
                    //               child: _pickedFileName == null
                    //                   ? Text('No file selected',
                    //                   style: TextStyle(color: Colors.grey.shade700), maxLines: 2, overflow: TextOverflow.ellipsis)
                    //                   : Column(
                    //                 crossAxisAlignment: CrossAxisAlignment.start,
                    //                 children: [
                    //                   Text(
                    //                     _pickedFileName ?? '',
                    //                     style: const TextStyle(fontWeight: FontWeight.w600),
                    //                     maxLines: 2,
                    //                     overflow: TextOverflow.ellipsis,
                    //                     softWrap: true,
                    //                   ),
                    //                   if (_pickedFileSizeBytes != null)
                    //                     Padding(
                    //                       padding: const EdgeInsets.only(top: 2.0),
                    //                       child: Text('${(_pickedFileSizeBytes! / 1024).toStringAsFixed(1)} KB',
                    //                           style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
                    //                     ),
                    //                 ],
                    //               ),
                    //             ),
                    //
                    //             const SizedBox(width: 8),
                    //
                    //             // clear/remove button (keeps visible)
                    //             if (_pickedFileName != null)
                    //               GestureDetector(
                    //                 onTap: () => setState(() => _pickedFileName = _pickedFilePath = _pickedFileSizeBytes = null),
                    //                 child: Container(
                    //                   padding: const EdgeInsets.all(6),
                    //                   decoration:
                    //                   BoxDecoration(color: Colors.grey.shade200, borderRadius: BorderRadius.circular(6)),
                    //                   child: const Icon(Icons.clear, size: 16),
                    //                 ),
                    //               ),
                    //           ],
                    //         );
                    //       }),
                    //
                    //       const SizedBox(height: 10),
                    //
                    //       Text('Supported Documents: Jpg, Jpeg, Png, Pdf, Doc, Xlsx. Max size: 4 MB.',
                    //           style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                    //     ],
                    //   ),
                    // ),
                    // const SizedBox(height: 12),

        // Column(
        //   crossAxisAlignment: CrossAxisAlignment.start,
        //   children: [
        //     Row(
        //       children: [
        //         // File select button (opens source sheet: camera / gallery / file)
        //         Flexible(
        //           child: OutlinedButton.icon(
        //             onPressed: _showPickSourceSheet, // your modal that selects source
        //             icon: const Icon(Icons.attach_file),
        //             label: Row(
        //               mainAxisSize: MainAxisSize.min,
        //               children: [
        //                 // Display file name (ellipsized) and optional size next to it
        //                 ConstrainedBox(
        //                   constraints: const BoxConstraints(maxWidth: 250), // avoid huge label
        //                   child: Text(
        //                     _pickedFileName ?? 'Attach file',
        //                     overflow: TextOverflow.ellipsis,
        //                     maxLines: 1,
        //                     softWrap: false,
        //                   ),
        //                 ),
        //
        //                 if (_pickedFileSizeBytes != null) ...[
        //                   const SizedBox(width: 8),
        //                   Text(
        //                     '${(_pickedFileSizeBytes! / 1024).toStringAsFixed(1)} KB',
        //                     style: TextStyle(fontSize: 12, color: Colors.grey[600]),
        //                   ),
        //                 ],
        //               ],
        //             ),
        //             style: OutlinedButton.styleFrom(
        //               shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        //               side: BorderSide(color: Colors.grey.shade300),
        //               padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        //               foregroundColor: accentColor,
        //               backgroundColor: Colors.white,
        //             ),
        //           ),
        //         ),
        //
        //         const SizedBox(width: 8),
        //
        //         // Clear button shown only when a file is selected
        //         if (_pickedFileName != null) ...[
        //           GestureDetector(
        //             onTap: _clearPickedFile,
        //             child: Container(
        //               padding: const EdgeInsets.all(8),
        //               decoration: BoxDecoration(
        //                 color: Colors.grey.shade200,
        //                 borderRadius: BorderRadius.circular(8),
        //               ),
        //               child: const Icon(Icons.clear, size: 18),
        //             ),
        //           ),
        //         ],
        //       ],
        //     ),
        //
        //     const SizedBox(height: 8),
        //
        //     Text(
        //       'Supported Documents: Jpg, Jpeg, Png, Pdf, Doc, Xlsx. Max size: 4 MB.',
        //       style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
        //     ),
        //   ],
        // ),

        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                // Button that adapts to available space for label
                Expanded(
                  child: OutlinedButton(
                    onPressed: _showPickSourceSheet,
                    style: OutlinedButton.styleFrom(
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      side: BorderSide(color: Colors.grey.shade300),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                      backgroundColor: Colors.white,
                      foregroundColor: accentColor,
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.attach_file),
                        const SizedBox(width: 8),
                        // This Expanded ensures the label uses the available button width
                        Expanded(
                          child: LayoutBuilder(builder: (context, constraints) {
                            return Text(
                              _pickedFileName ?? 'Attach file',
                              overflow: TextOverflow.ellipsis,
                              maxLines: 1,
                              softWrap: false,
                              style: const TextStyle(fontSize: 14),
                            );
                          }),
                        ),
                        if (_pickedFileSizeBytes != null) ...[
                          const SizedBox(width: 8),
                          Text(
                            '${(_pickedFileSizeBytes! / 1024).toStringAsFixed(1)} KB',
                            style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),

                const SizedBox(width: 8),

                // Clear button
                if (_pickedFileName != null)
                  GestureDetector(
                    onTap: _clearPickedFile,
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.grey.shade200,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Icon(Icons.clear, size: 18),
                    ),
                  ),
              ],
            ),

            const SizedBox(height: 8),

            Text(
              'Supported Documents: Jpg, Jpeg, Png, Pdf, Doc, Xlsx. Max size: 100 MB.',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
          ],
        ),
                    const SizedBox(height: 8),

// ---------- end upload area ----------
                    // Submit button and progress
                    Row(children: [
                      Expanded(
                        child: ElevatedButton(
                          onPressed: _submitting ? null : _submit,
                          style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 10), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                            backgroundColor: _submitting ? Colors.grey : accentColor,
                            foregroundColor: _submitting ? Colors.grey.shade600 : Colors.white,
                          ),

                          child: _submitting
                              ? Row(mainAxisAlignment: MainAxisAlignment.center, children: [const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)), const SizedBox(width: 10), const Text('Uploading...')])
                              : const Text('Add Task'),
                        ),
                      ),
                    ]),
                    if (_submitting && _uploadProgress > 0) ...[
                      const SizedBox(height: 8),
                      LinearProgressIndicator(value: _uploadProgress, minHeight: 6),
                      const SizedBox(height: 8),
                      Text('${(_uploadProgress * 100).toStringAsFixed(0)}%'),
                    ],
                  ]),
                ),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
      ),
    );
  }
}

