

import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ChargeablePage extends StatefulWidget {
  final String ticketId;
  final bool initialValue;
  const ChargeablePage({Key? key, required this.ticketId, required this.initialValue}) : super(key: key);

  @override
  State<ChargeablePage> createState() => _ChargeablePageState();
}

class _ChargeablePageState extends State<ChargeablePage> {
  bool _value = false;
  bool _saving = false;
  final Dio _dio = Dio();

  @override
  void initState() {
    super.initState();
    _value = widget.initialValue;
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('user_data');
      String slug = '';
      String domain = '';
      if (raw != null) {
        try {
          final Map<String, dynamic> u = jsonDecode(raw);
          slug = (u['slug'] ?? '').toString();
          domain = (u['domain'] ?? '').toString();
        } catch (_) {}
      }
      if (slug.isEmpty) slug = prefs.getString('slug') ?? '';
      final url = '$domain$slug/updateChargeableApi'; // adjust endpoint if needed

      final body = {
        'tkt_id': widget.ticketId,
        'chargeable': _value ? 1 : 0,
      };

      final resp = await _dio.post(url, data: body, options: Options(headers: {'Accept': 'application/json'}));
      if (resp.statusCode == 200 || resp.statusCode == 201) {
        final msg = (resp.data is Map && resp.data['message'] != null) ? resp.data['message'].toString() : 'Updated';
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
        Navigator.of(context).pop(_value); // return new value
      } else {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Update failed: ${resp.statusCode}')));
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Save error: $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    _dio.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text('Chargeable'),
      ),
      body: const Center(
        child: Text(
          "🚧 Coming Soon 🚧",
          style: TextStyle(
            fontSize: 20,
            color: Colors.black87,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );

  }
}
