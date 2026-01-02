// lib/screens/events/add_event_screen.dart
import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:matchme/models/event_model.dart';
import 'package:matchme/providers/event_provider.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/services/event_data_service.dart';
import 'package:matchme/widgets/please_wait_dialog.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

final supabase = Supabase.instance.client;
const uuid = Uuid();

enum EventInputMode { link, image, manual }

class AddEventScreen extends ConsumerStatefulWidget {
  final EventModel? existingEvent;
  
  const AddEventScreen({super.key, this.existingEvent});

  @override
  ConsumerState<AddEventScreen> createState() => _AddEventScreenState();
}

class _AddEventScreenState extends ConsumerState<AddEventScreen> {
  final _formKey = GlobalKey<FormState>();
  final _eventNameController = TextEditingController();
  final _venueController = TextEditingController();
  final _notesController = TextEditingController();
  final _linkController = TextEditingController(); 
  
  DateTime _startDate = DateTime.now().add(const Duration(hours: 1));
  TimeOfDay _startTime = TimeOfDay.fromDateTime(DateTime.now().add(const Duration(hours: 1)));
  
  bool _isLoading = false;
  EventInputMode _inputMode = EventInputMode.link; // Default to Link
  bool _isProcessingInput = false;
  String? _extractedLink; // Store the link when extracted

  @override
  void initState() {
    super.initState();
    // Pre-populate fields if editing existing event
    if (widget.existingEvent != null) {
      _eventNameController.text = widget.existingEvent!.eventName;
      _venueController.text = widget.existingEvent!.eventVenue ?? '';
      _notesController.text = widget.existingEvent!.notes ?? '';
      _startDate = widget.existingEvent!.startTime;
      _startTime = TimeOfDay.fromDateTime(widget.existingEvent!.startTime);
      _inputMode = EventInputMode.manual; // Start in manual mode when editing
      _extractedLink = widget.existingEvent!.eventLink; // Preserve existing link
    }
  }

  @override
  void dispose() {
    _eventNameController.dispose();
    _venueController.dispose();
    _notesController.dispose();
    _linkController.dispose();
    super.dispose();
  }

  // --- Handle Link Parsing ---
  Future<void> _handleLinkExtraction() async {
    final l10n = ref.read(localizationProvider);
    if (!mounted) return;

    if (_linkController.text.trim().isEmpty || !_linkController.text.trim().startsWith('http')) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.getString('pleaseEnterValidUrl')), backgroundColor: Colors.red));
      return;
    }

    setState(() {
      _isProcessingInput = true;
      _isLoading = true;
    });

    PleaseWaitDialog.show(context);

    final service = ref.read(eventDataServiceProvider);
    String message = l10n.getString('processingError');
    ExtractedEventData result = ExtractedEventData.empty();
    bool dialogDismissed = false;

    try {
      result = await service.extractFromUrl(_linkController.text.trim());
      
      if (mounted) {
        PleaseWaitDialog.hide(context);
        dialogDismissed = true;
      }
      
      message = result.name.isNotEmpty ? l10n.getString('dataExtractedFromLink') : l10n.getString('couldNotFetchDetailsFromLink');

      if (mounted && result.name.isNotEmpty) {
        bool shouldPopulate = true;
        if (result.date != null && result.date!.isBefore(DateTime.now())) {
          final confirm = await _showPastEventConfirmationDialog(result);
          if (!confirm) {
            shouldPopulate = false;
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.getString('eventImportCanceled')), backgroundColor: Colors.orange)); // ignore: use_build_context_synchronously
          }
        }
        if (shouldPopulate) {
          _populateFieldsFromResult(result);
          // Store the link for later use
          _extractedLink = _linkController.text.trim();
          // Switch to manual mode to allow editing
          setState(() {
            _inputMode = EventInputMode.manual;
          });
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message), backgroundColor: Colors.green)); // ignore: use_build_context_synchronously
        }
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message), backgroundColor: Colors.orange));
      }
    } catch (e) {
      if (mounted) {
        if (!dialogDismissed) {
          PleaseWaitDialog.hide(context);
          dialogDismissed = true;
        }
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${l10n.getString('processingError')}: $e'), backgroundColor: Colors.red));
      }
    } finally {
      if (mounted) {
        setState(() {
          _isProcessingInput = false;
          _isLoading = false;
        });
        if (!dialogDismissed) {
          PleaseWaitDialog.hide(context);
        }
      }
    }
  }
  
  // --- Handle Ticket Upload ---
  Future<void> _handleFileUpload() async {
    final l10n = ref.read(localizationProvider);
    if (!mounted) return;

    setState(() {
      _isProcessingInput = true;
      _isLoading = true;
    });

    PleaseWaitDialog.show(context);

    final service = ref.read(eventDataServiceProvider);
    String message = l10n.getString('processingError');
    ExtractedEventData result = ExtractedEventData.empty();

    try {
      result = await service.uploadAndProcessFile();
      message = result.name.isNotEmpty ? l10n.getString('ticketProcessedSuccessfully') : l10n.getString('couldNotExtractEventDetailsFromTicket');

      if (mounted) {
        _populateFieldsFromResult(result);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message), backgroundColor: result.name.isNotEmpty ? Colors.blue : Colors.orange));

        // Switch to manual mode after processing
        setState(() {
          _inputMode = EventInputMode.manual;
        });
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${l10n.getString('processingError')}: $e'), backgroundColor: Colors.red));
    } finally {
      if (mounted) {
        setState(() {
          _isProcessingInput = false;
          _isLoading = false;
        });
        PleaseWaitDialog.hide(context);
      }
    }
  }

  // --- Helper to populate all fields from a result ---
  void _populateFieldsFromResult(ExtractedEventData result) {
    // --- THIS IS THE FIX ---
    // All UI updates MUST be inside this setState call.
    setState(() {
      if (result.name.isNotEmpty) {
        _eventNameController.text = result.name;
      }
      if (result.venue != null && result.venue!.isNotEmpty) {
        _venueController.text = result.venue!;
      }
      
      if (result.date != null) {
        // AI successfully parsed the date, so we update the state
        _startDate = result.date!;
        _startTime = TimeOfDay.fromDateTime(result.date!);
      }
    });
    // --- END FIX ---
  }

  Future<bool> _showPastEventConfirmationDialog(ExtractedEventData result) async {
    final l10n = ref.read(localizationProvider);
    return await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text(l10n.getString('pastEventDetected')),
          content: Text(
            '${l10n.getString('eventDateInPast')}: ${result.dateString ?? result.date?.toString() ?? 'Unknown'}. ${l10n.getString('continueImporting')}',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(l10n.getString('generalCancel')),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(l10n.getString('generalContinue')),
            ),
          ],
        );
      },
    ) ?? false;
  }

  Future<void> _selectDate(BuildContext context) async {
    final DateTime? pickedDate = await showDatePicker(
      context: context,
      initialDate: _startDate,
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (pickedDate != null) {
      setState(() {
        _startDate = DateTime(pickedDate.year, pickedDate.month, pickedDate.day, _startTime.hour, _startTime.minute);
      });
    }
  }

  Future<void> _selectTime(BuildContext context) async {
    final TimeOfDay? pickedTime = await showTimePicker(
      context: context,
      initialTime: _startTime,
    );
    if (pickedTime != null) {
      setState(() {
        _startTime = pickedTime;
        _startDate = DateTime(_startDate.year, _startDate.month, _startDate.day, pickedTime.hour, pickedTime.minute);
      });
    }
  }
  
  DateTime _startDateTime() => DateTime(_startDate.year, _startDate.month, _startDate.day, _startTime.hour, _startTime.minute);
  
  Future<void> _submitEvent() async {
    final l10n = ref.read(localizationProvider);
    if (!_formKey.currentState!.validate()) return;
    if (!mounted) return;
    setState(() => _isLoading = true);

    final startTime = _startDateTime();
    final endTime = startTime.add(const Duration(hours: 1));

    final event = EventModel(
      id: widget.existingEvent?.id ?? uuid.v4(),
      eventName: _eventNameController.text.trim(),
      eventVenue: _venueController.text.trim().isEmpty ? null : _venueController.text.trim(),
      startTime: startTime,
      endTime: endTime,
      notes: _notesController.text.trim().isEmpty ? null : _notesController.text.trim(),
      eventLink: _extractedLink,
    );

    final bool success;
    if (widget.existingEvent != null) {
      success = await ref.read(eventManagerProvider.notifier).updateEvent(event);
    } else {
      success = await ref.read(eventManagerProvider.notifier).addEvent(event);
    }

    if (mounted) {
      if (success) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(widget.existingEvent != null 
              ? l10n.getString('eventUpdatedSuccessfully') 
              : l10n.getString('eventSavedSuccessfully')),
            backgroundColor: Colors.green
          )
        );
        Navigator.pop(context);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(widget.existingEvent != null 
              ? l10n.getString('failedToUpdateEvent') 
              : l10n.getString('failedToSaveEvent')),
            backgroundColor: Colors.red
          )
        );
      }
    }

    if (mounted) setState(() => _isLoading = false);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(localizationProvider);
    final isProcessing = _isLoading || _isProcessingInput;
    final isRtl = ['ar', 'he'].contains(l10n.currentLocale.languageCode.toLowerCase());

    return Directionality(
      textDirection: isRtl ? ui.TextDirection.rtl : ui.TextDirection.ltr,
      child: Scaffold(
      appBar: AppBar(
        title: Text(widget.existingEvent != null 
          ? l10n.getString('editEventTitle') 
          : l10n.getString('addEventTitle'))
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.getString('eventDetails'), style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 16),
              
              // Only show input mode selector when creating new event
              if (widget.existingEvent == null) ...[
                Text(l10n.getString('inputMethod'), style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 8),
                _buildInputModeSelector(l10n),
                const SizedBox(height: 20),
                
                if (_inputMode == EventInputMode.link)
                  _buildLinkInput(l10n, isProcessing)
                else if (_inputMode == EventInputMode.image)
                   _buildImageInput(l10n, isProcessing),
                
                if (_inputMode != EventInputMode.manual)
                  const SizedBox(height: 20),
              ],

              TextFormField(
                controller: _eventNameController,
                decoration: InputDecoration(
                  labelText: l10n.getString('eventNameRequired'),
                  border: const OutlineInputBorder(),
                ),
                validator: (value) => value == null || value.isEmpty ? l10n.getString('nameCannotBeEmpty') : null,
              ),
              const SizedBox(height: 16),

              TextFormField(
                controller: _venueController,
                decoration: InputDecoration(
                  labelText: l10n.getString('venueLocationOptional'),
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              
              Text(l10n.getString('whenIsTheEvent'), style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 16),

              Row(
                children: [
                  Expanded(child: _buildDateButton(context, l10n: l10n)),
                  const SizedBox(width: 16),
                  Expanded(child: _buildTimeButton(context, l10n: l10n)),
                ],
              ),
              
              const SizedBox(height: 30),

              TextFormField(
                controller: _notesController,
                decoration: InputDecoration(
                  labelText: l10n.getString('notesOptional'),
                  alignLabelWithHint: true,
                  border: const OutlineInputBorder(),
                ),
                maxLines: 3,
              ),
              const SizedBox(height: 40),

              Center(
                child: isProcessing
                    ? const CircularProgressIndicator()
                    : ElevatedButton(
                        onPressed: isProcessing ? null : _submitEvent,
                        style: ElevatedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 15),
                          backgroundColor: Theme.of(context).colorScheme.primary,
                          foregroundColor: Theme.of(context).colorScheme.onPrimary,
                        ),
                        child: Text(
                          widget.existingEvent != null 
                            ? l10n.getString('updateEvent') 
                            : l10n.getString('saveEvent'), 
                          style: const TextStyle(fontSize: 18)
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

  Widget _buildDateButton(BuildContext context, {required LocalizationState l10n}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text( l10n.getString('startDate'), style: Theme.of(context).textTheme.bodySmall, ),
        const SizedBox(height: 4),
        OutlinedButton.icon(
          icon: const Icon(Icons.calendar_today, size: 18),
          label: Text(DateFormat('EEE, MMM d, yyyy', l10n.currentLocale.languageCode).format(_startDate)),
          onPressed: () => _selectDate(context),
          style: OutlinedButton.styleFrom( padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 15), minimumSize: const Size(double.infinity, 50), ),
        ),
      ],
    );
  }
  
  Widget _buildTimeButton(BuildContext context, {required LocalizationState l10n}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text( l10n.getString('startTime'), style: Theme.of(context).textTheme.bodySmall, ),
        const SizedBox(height: 4),
        OutlinedButton.icon(
          icon: const Icon(Icons.access_time, size: 18),
          label: Text(_startTime.format(context)),
          onPressed: () => _selectTime(context),
          style: OutlinedButton.styleFrom( padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 15), minimumSize: const Size(double.infinity, 50), ),
        ),
      ],
    );
  }

  Widget _buildInputModeSelector(LocalizationState l10n) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Wrap(
        spacing: 8.0,
        children: EventInputMode.values.map((mode) {
          String label = switch (mode) {
            EventInputMode.link => l10n.getString('pasteLink'),
            EventInputMode.image => l10n.getString('uploadTicket'),
            EventInputMode.manual => l10n.getString('manualInput'),
          };

          return ChoiceChip(
            label: Text(label),
            selected: _inputMode == mode,
            onSelected: (selected) {
              if (selected) {
                setState(() {
                  _inputMode = mode;
                });
              }
            },
            selectedColor: Theme.of(context).colorScheme.tertiaryContainer,
          );
        }).toList(),
      ),
    );
  }

  Widget _buildLinkInput(LocalizationState l10n, bool isProcessing) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: TextFormField(
            controller: _linkController,
            decoration: InputDecoration(
              labelText: l10n.getString('pasteEventUrl'),
              border: const OutlineInputBorder(),
            ),
            validator: (value) => value == null || !value.startsWith('http') ? l10n.getString('enterValidUrl') : null,
          ),
        ),
        const SizedBox(width: 8),
        ElevatedButton(
          onPressed: isProcessing ? null : () => _handleLinkExtraction(),
          style: ElevatedButton.styleFrom(minimumSize: const Size(60, 60)),
          child: isProcessing
            ? CircularProgressIndicator(strokeWidth: 2, color: Theme.of(context).colorScheme.onPrimary)
            : const Icon(Icons.download_for_offline_outlined),
        ),
      ],
    );
  }
  
  Widget _buildImageInput(LocalizationState l10n, bool isProcessing) {
    return Center(
      child: ElevatedButton.icon(
        icon: const Icon(Icons.upload_file),
        label: Text(l10n.getString('selectTicketPdfImage')),
        onPressed: isProcessing ? null : () => _handleFileUpload(),
        style: ElevatedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        ),
      ),
    );
  }
}
