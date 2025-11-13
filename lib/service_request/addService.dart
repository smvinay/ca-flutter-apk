// lib/task_management/addService.dart
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:file_picker/file_picker.dart';

class Template1AddServices extends StatefulWidget {
  const Template1AddServices({Key? key}) : super(key: key);

  @override
  State<Template1AddServices> createState() => _Template1AddServicesState();
}

class _Template1AddServicesState extends State<Template1AddServices> {
  final _formKey = GlobalKey<FormState>();

  // controllers
  final TextEditingController _subjectC = TextEditingController();
  final TextEditingController _descC = TextEditingController();
  final TextEditingController _clientSearchC = TextEditingController();

  // dropdown selections
  String? _category;
  String _priority = 'Medium';
  String? _client;

  // Picked file info (real file picker)
  String? _pickedFileName;
  String? _pickedFilePath;
  int? _pickedFileSizeBytes;

  // sample lists (replace with your API/data)
  final List<String> _categories = ['Select Category', 'GST', 'Audit', 'Income Tax'];
  final List<String> _priorities = ['High', 'Medium', 'Low'];
  final List<String> _clients = ['Client A', 'Client B', 'Client C', 'ACME Corp'];

  // styles
  final Color accentColor = const Color(0xFF6B59C9);

  @override
  void dispose() {
    _subjectC.dispose();
    _descC.dispose();
    _clientSearchC.dispose();
    super.dispose();
  }

  // Helpers for picking a file (file_picker package)
  Future<void> _pickFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['jpg', 'jpeg', 'png', 'pdf', 'doc', 'docx'],
        allowMultiple: false,
        withData: false,
      );
      if (result == null) return;

      final file = result.files.first;
      setState(() {
        _pickedFileName = file.name;
        _pickedFilePath = file.path;
        _pickedFileSizeBytes = file.size;
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Picked: ${file.name}')));
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('File pick failed: $e')));
    }
  }

  void _removePickedFile() {
    setState(() {
      _pickedFileName = null;
      _pickedFilePath = null;
      _pickedFileSizeBytes = null;
    });
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please correct the errors in the form')));
      return;
    }

    final payload = {
      'category': _category,
      'priority': _priority,
      'subject': _subjectC.text.trim(),
      'description': _descC.text.trim(),
      'client': _client ?? _clientSearchC.text.trim(),
      'attachment_name': _pickedFileName,
      'attachment_path': _pickedFilePath,
      'attachment_size_bytes': _pickedFileSizeBytes,
      'created_at': DateFormat('yyyy-MM-dd HH:mm:ss').format(DateTime.now()),
    };

    // Demo: show a confirmation then pop with payload
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Service request added (demo): ${payload['subject'] ?? payload['description']}')));
    Navigator.of(context).pop(payload);
  }

  InputDecoration _fieldDecor({String? hint}) {
    return InputDecoration(
      hintText: hint,
      filled: true,
      fillColor: Colors.white,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.grey.shade300), borderRadius: BorderRadius.circular(8)),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
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

  Widget _twoCol(Widget left, Widget right) {
    return LayoutBuilder(builder: (context, constraints) {
      if (constraints.maxWidth > 700) {
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: left),
            const SizedBox(width: 12),
            Expanded(child: right),
          ],
        );
      } else {
        return Column(
          children: [
            left,
            const SizedBox(height: 12),
            right,
          ],
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Add Service Request'),
        backgroundColor: Colors.white,
        foregroundColor: Colors.black87,
        elevation: 1,
        actions: [
          IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.of(context).maybePop()),
        ],
      ),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: Container(
            color: Colors.grey.shade100,
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12),
              children: [

                Card(
                  elevation: 2,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      children: [
                        // Row 1: Category (left) | Client (right, required)
                        _twoCol(
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _label('Category'),
                              const SizedBox(height: 8),
                              DropdownButtonFormField<String>(
                                value: _category ?? _categories[0],
                                items: _categories.map((c) => DropdownMenuItem(value: c, child: Text(c))).toList(),
                                onChanged: (v) => setState(() => _category = v),
                                decoration: _fieldDecor(hint: 'Select Category'),
                                validator: (v) {
                                  // category optional; no validation required
                                  return null;
                                },
                              ),
                            ],
                          ),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _label('Client', required: true),
                              const SizedBox(height: 8),
                              TextFormField(
                                controller: _clientSearchC,
                                decoration: _fieldDecor(hint: 'Search client...'),
                                onChanged: (val) => setState(() {}),
                                onFieldSubmitted: (v) => setState(() => _client = v),
                                validator: (v) {
                                  final chosen = (_client ?? v ?? '').trim();
                                  if (chosen.isEmpty) return 'Please select client';
                                  return null;
                                },
                              ),
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 8,
                                children: _clients
                                    .where((c) => c.toLowerCase().contains(_clientSearchC.text.toLowerCase()))
                                    .map((c) => ActionChip(
                                  label: Text(c),
                                  onPressed: () {
                                    setState(() {
                                      _client = c;
                                      _clientSearchC.text = c;
                                    });
                                  },
                                ))
                                    .toList(),
                              ),
                            ],
                          ),
                        ),

                        const SizedBox(height: 12),

                        // Row 2: Priority (left) | Subject (right)
                        _twoCol(
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _label('Priority'),
                              const SizedBox(height: 8),
                              DropdownButtonFormField<String>(
                                value: _priority,
                                items: _priorities.map((p) => DropdownMenuItem(value: p, child: Text(p))).toList(),
                                onChanged: (v) => setState(() => _priority = v ?? 'Medium'),
                                decoration: _fieldDecor(hint: 'Select'),
                              ),
                            ],
                          ),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _label('Subject'),
                              const SizedBox(height: 8),
                              TextFormField(
                                controller: _subjectC,
                                decoration: _fieldDecor(hint: 'Enter Subject'),
                              ),
                            ],
                          ),
                        ),

                        const SizedBox(height: 12),

                        // Row 3: Service Description (left) | Upload Documents (right)
                        _twoCol(
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _label('Service Description'),
                              const SizedBox(height: 8),
                              TextFormField(
                                controller: _descC,
                                decoration: _fieldDecor(hint: 'Add Question / Description'),
                                maxLines: 5,
                              ),
                            ],
                          ),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _label('Upload Documents'),
                              const SizedBox(height: 8),
                              Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(color: Colors.grey.shade50, borderRadius: BorderRadius.circular(8)),
                                child: Row(
                                  children: [
                                    // White choose-file button
                                    ElevatedButton.icon(
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: Colors.white,
                                        foregroundColor: accentColor,
                                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                        side: BorderSide(color: Colors.grey.shade200),
                                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                      ),
                                      onPressed: _pickFile,
                                      icon: const Icon(Icons.attach_file),
                                      label: const Text('Choose File'),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: _pickedFileName == null
                                          ? const Text('No file chosen', style: TextStyle(color: Colors.black87))
                                          : Row(
                                        children: [
                                          const Icon(Icons.insert_drive_file, size: 20, color: Colors.grey),
                                          const SizedBox(width: 8),
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              children: [
                                                Text(_pickedFileName ?? '', style: const TextStyle(fontWeight: FontWeight.w600)),
                                                if (_pickedFileSizeBytes != null)
                                                  Text('${(_pickedFileSizeBytes! / 1024).toStringAsFixed(1)} KB', style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
                                              ],
                                            ),
                                          ),
                                          IconButton(icon: const Icon(Icons.close, size: 20), onPressed: _removePickedFile),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text('Supported: jpeg | png | jpg | pdf | doc | docx. Max: 2MB', style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                            ],
                          ),
                        ),

                        const SizedBox(height: 12),
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 16),
              ],
            ),
          ),
        ),
      ),

      bottomNavigationBar: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(color: Colors.white, boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 8)]),
        child: Row(
          children: [
            Expanded(
              child: ElevatedButton(
                onPressed: _submit,
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                child: const Text('Add Service Request'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
