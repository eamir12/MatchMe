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
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

final supabase = Supabase.instance.client;
const uuid = Uuid();

enum EventInputMode { link, image, manual }

class AddEventScreen extends ConsumerStatefulWidget {
  final EventModel? existingEvent;
  final bool showAppBar;
  final String? initialSharedText;
  final String? initialSharedFilePath;
  
  const AddEventScreen({
    super.key,
    this.existingEvent,
    this.showAppBar = true,
    this.initialSharedText,
    this.initialSharedFilePath,
  });

  @override
  ConsumerState<AddEventScreen> createState() => _AddEventScreenState();
}

class _AddEventScreenState extends ConsumerState<AddEventScreen> {
  final _formKey = GlobalKey<FormState>();
  
  // Text Controllers
  final _eventNameController = TextEditingController();
  final _venueController = TextEditingController();
  final _notesController = TextEditingController();
  final _linkController = TextEditingController(); 
  
  // Focus Nodes for logical traversal
  final _eventNameFocus = FocusNode();
  final _venueFocus = FocusNode();
  final _notesFocus = FocusNode();

  DateTime _startDate = DateTime.now().add(const Duration(hours: 1));
  TimeOfDay _startTime = TimeOfDay.fromDateTime(DateTime.now().add(const Duration(hours: 1)));
  
  bool _isLoading = false;
  EventInputMode _inputMode = EventInputMode.link; // Default to Link
  bool _isProcessingInput = false;
  String? _extractedLink; // Store the link when extracted
  
  // State for conditional rendering
  bool _hasExtractedData = false;
  bool _extractionFailed = false;

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
      _hasExtractedData = true; // Treated as extracted/filled
    } else {
      _loadSavedInputMode();
      // Handle shared content (links or files) automatically
      _processSharedContent();
    }
  }

  /// Automatically processes shared content (links or files) when the screen is opened
  void _processSharedContent() {
    // Check for shared text (event links)
    if (widget.initialSharedText != null && widget.initialSharedText!.isNotEmpty) {
      final sharedText = widget.initialSharedText!.trim();
      // Check if it's a URL
      if (sharedText.startsWith('http')) {
        // Set the link in the controller and trigger extraction
        _linkController.text = sharedText;
        // Use post-frame callback to ensure the widget is built before extraction
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _handleLinkExtraction();
          }
        });
      } else {
        // If shared text is not a URL, treat it as event name
        _eventNameController.text = sharedText;
        setState(() {
          _inputMode = EventInputMode.manual;
          _hasExtractedData = true;
        });
      }
    }
    // Check for shared files (event tickets/images)
    else if (widget.initialSharedFilePath != null && widget.initialSharedFilePath!.isNotEmpty) {
      // Switch to image mode and trigger file processing
      setState(() {
        _inputMode = EventInputMode.image;
      });
      // Use post-frame callback to ensure the widget is built before processing
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _processSharedFile(widget.initialSharedFilePath!);
        }
      });
    }
  }

  /// Process a shared file from the given path
  Future<void> _processSharedFile(String filePath) async {
    final l10n = ref.read(localizationProvider);
    if (!mounted) return;

    setState(() {
      _isProcessingInput = true;
      _isLoading = true;
      _extractionFailed = false;
    });

    PleaseWaitDialog.show(context);

    final service = ref.read(eventDataServiceProvider);
    String message = l10n.getString('processingError');
    ExtractedEventData result = ExtractedEventData.empty();

    try {
      result = await service.uploadAndProcessLocalFile(filePath);

      message = result.name.isNotEmpty 
          ? l10n.getString('ticketProcessedSuccessfully') 
          : l10n.getString('couldNotExtractEventDetailsFromTicket');

      if (mounted) {
        if (result.name.isNotEmpty) {
          // If the parsed date is in the past, do not import it
          if (result.date != null && result.date!.isBefore(DateTime.now())) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(l10n.getString('eventDateInPastNotImported')), 
                backgroundColor: Colors.orange
              )
            );
          } else {
            _populateFieldsFromResult(result);
            setState(() {
              _hasExtractedData = true;
              _extractionFailed = false;
            });
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(message), backgroundColor: Colors.blue)
            );
          }
        } else {
          setState(() {
            _extractionFailed = true;
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _extractionFailed = true;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${l10n.getString('processingError')}: $e'), 
            backgroundColor: Colors.red
          )
        );
      }
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

  Future<void> _loadSavedInputMode() async {
    final prefs = await SharedPreferences.getInstance();
    final savedModeIndex = prefs.getInt('event_input_mode');
    if (savedModeIndex != null && savedModeIndex >= 0 && savedModeIndex < EventInputMode.values.length) {
      setState(() {
        _inputMode = EventInputMode.values[savedModeIndex];
      });
    }
  }

  Future<void> _saveInputMode(EventInputMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('event_input_mode', mode.index);
  }

  @override
  void dispose() {
    _eventNameController.dispose();
    _venueController.dispose();
    _notesController.dispose();
    _linkController.dispose();
    _eventNameFocus.dispose();
    _venueFocus.dispose();
    _notesFocus.dispose();
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
      _extractionFailed = false;
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
        // If the parsed date is in the past, do not import it — we prevent adding past events
        if (result.date != null && result.date!.isBefore(DateTime.now())) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.getString('eventDateInPastNotImported')), backgroundColor: Colors.orange)); // ignore: use_build_context_synchronously
          // We still show the form even if date is past, just let user fix it? 
          // Current logic seems to be: if past, show warning but do we populate?
          // The previous code showed snackbar and did NOT populate/switch mode.
          // I will stick to previous behavior: show warning, do not proceed to success state.
        } else {
          _populateFieldsFromResult(result);
          // Store the link for later use
          _extractedLink = _linkController.text.trim();
          
          setState(() {
            _hasExtractedData = true;
            _extractionFailed = false;
          });
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message), backgroundColor: Colors.green)); // ignore: use_build_context_synchronously
        }
      } else if (mounted) {
        setState(() {
           _extractionFailed = true;
        });
        // ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message), backgroundColor: Colors.orange));
      }
    } catch (e) {
      if (mounted) {
        if (!dialogDismissed) {
          PleaseWaitDialog.hide(context);
          dialogDismissed = true;
        }
        setState(() {
           _extractionFailed = true;
        });
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
      _extractionFailed = false;
    });

    PleaseWaitDialog.show(context);

    final service = ref.read(eventDataServiceProvider);
    String message = l10n.getString('processingError');
    ExtractedEventData? result;

    try {
      result = await service.uploadAndProcessFile();

      // If result is null, the user cancelled the file picker; silently close.
      if (result == null) {
        return; // finally will run and hide the dialog
      }

      message = result.name.isNotEmpty ? l10n.getString('ticketProcessedSuccessfully') : l10n.getString('couldNotExtractEventDetailsFromTicket');

      if (mounted) {
        if (result.name.isNotEmpty) {
          // If the parsed date is in the past, do not import it — we prevent adding past events
          if (result.date != null && result.date!.isBefore(DateTime.now())) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.getString('eventDateInPastNotImported')), backgroundColor: Colors.orange));
          } else {
            _populateFieldsFromResult(result);
            setState(() {
              _hasExtractedData = true;
              _extractionFailed = false;
            });
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message), backgroundColor: Colors.blue));
          }
        } else {
           setState(() {
             _extractionFailed = true;
           });
        }
      }
    } catch (e) {
      // If the exception indicates a user cancel, do not show an error.
      final msg = e.toString().toLowerCase();
      if (msg.contains('cancel') || msg.contains('abort') || msg.contains('user canceled') || msg.contains('user cancelled')) {
        return;
      }
      if (mounted) {
        setState(() {
           _extractionFailed = true;
        });
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${l10n.getString('processingError')}: $e'), backgroundColor: Colors.red));
      }
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

  void _retryExtraction() {
    setState(() {
      _extractionFailed = false;
      _hasExtractedData = false;
      // Clear fields? Maybe not needed if they weren't populated.
    });
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

    // Prevent creating events that started more than 30 minutes ago
    if (widget.existingEvent == null && startTime.isBefore(DateTime.now().subtract(const Duration(minutes: 30)))) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.getString('eventCannotBeInPast')), backgroundColor: Colors.red));
      if (mounted) setState(() => _isLoading = false);
      return;
    }

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
      appBar: widget.showAppBar
          ? AppBar(
              title: Text(
                widget.existingEvent != null ? l10n.getString('editEventTitle') : l10n.getString('addEventTitle'),
              ),
            )
          : null,
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!widget.showAppBar) ...[
                Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back),
                      onPressed: () => Navigator.of(context).maybePop(),
                      tooltip: l10n.getString('backToEvents'),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      widget.existingEvent != null ? l10n.getString('editEventTitle') : l10n.getString('addEventTitle'),
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
              ],
              // Input Mode Selector (Only for new events)
              if (widget.existingEvent == null) ...[
                Text(l10n.getString('inputMethod'), style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 8),
                _buildInputModeSelector(l10n),
                const SizedBox(height: 20),
              ],
              
              // Input Mode Specific UI
              if (_inputMode == EventInputMode.link) ...[
                 _buildLinkInput(l10n, isProcessing),
                 if (!_hasExtractedData && !_extractionFailed)
                   Padding(
                     padding: const EdgeInsets.only(top: 8.0),
                     child: Text(
                       l10n.getString('eventLinkMicrocopy'),
                       style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.grey),
                     ),
                   ),
              ] else if (_inputMode == EventInputMode.image) ...[
                 _buildImageInput(l10n, isProcessing),
                 if (!_hasExtractedData && !_extractionFailed)
                   Padding(
                     padding: const EdgeInsets.only(top: 16.0),
                     child: Text(
                       l10n.getString('eventTicketMicrocopy'),
                       style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.grey),
                       textAlign: TextAlign.center,
                     ),
                   ),
              ],
              
              // Retry Button
              if (_extractionFailed) ...[
                const SizedBox(height: 20),
                Center(
                  child: Column(
                    children: [
                      Text(
                         _inputMode == EventInputMode.link 
                             ? l10n.getString('couldNotFetchDetailsFromLink') 
                             : l10n.getString('couldNotExtractEventDetailsFromTicket'),
                         style: const TextStyle(color: Colors.red),
                         textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 10),
                      ElevatedButton.icon(
                        onPressed: _retryExtraction,
                        icon: const Icon(Icons.refresh),
                        label: Text(l10n.getString('retryExtractionButton')),
                        style: ElevatedButton.styleFrom(
                          minimumSize: const Size(200, 50), // 44dp+ touch target
                        ),
                      ),
                    ],
                  ),
                ),
              ],

              // Form Fields (Show if Manual mode OR Data Extracted)
              if (_inputMode == EventInputMode.manual || _hasExtractedData) ...[
                const SizedBox(height: 30),
                Text(l10n.getString('eventDetails'), style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 16),

                TextFormField(
                  controller: _eventNameController,
                  focusNode: _eventNameFocus,
                  textInputAction: TextInputAction.next,
                  onFieldSubmitted: (_) => FocusScope.of(context).requestFocus(_venueFocus),
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontFeatures: const []),
                  decoration: InputDecoration(
                    labelText: l10n.getString('eventNameRequired'),
                    border: const OutlineInputBorder(),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16), // Ensure height
                  ),
                  validator: (value) => value == null || value.isEmpty ? l10n.getString('nameCannotBeEmpty') : null,
                ),
                const SizedBox(height: 16),

                TextFormField(
                  controller: _venueController,
                  focusNode: _venueFocus,
                  textInputAction: TextInputAction.next,
                  onFieldSubmitted: (_) => _selectDate(context), // Logic flow: Venue -> Date
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontFeatures: const []),
                  decoration: InputDecoration(
                    labelText: l10n.getString('venueLocationOptional'),
                    border: const OutlineInputBorder(),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
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
                  focusNode: _notesFocus,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontFeatures: const []),
                  decoration: InputDecoration(
                    labelText: l10n.getString('notesOptional'),
                    alignLabelWithHint: true,
                    border: const OutlineInputBorder(),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
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
                            minimumSize: const Size(200, 50), // 44dp+
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
          style: OutlinedButton.styleFrom( 
             padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 15), 
             minimumSize: const Size(double.infinity, 50), // 44dp+
          ),
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
          style: OutlinedButton.styleFrom( 
             padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 15), 
             minimumSize: const Size(double.infinity, 50), // 44dp+
          ),
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
            EventInputMode.link => l10n.getString('eventInputModeLink'),
            EventInputMode.image => l10n.getString('eventInputModeTicket'),
            EventInputMode.manual => l10n.getString('eventInputModeManual'),
          };

          return ChoiceChip(
            label: Text(label),
            selected: _inputMode == mode,
            onSelected: (selected) {
              if (selected) {
                setState(() {
                  _inputMode = mode;
                  // Reset extraction state when switching modes
                  if (mode != EventInputMode.manual) {
                    _hasExtractedData = false;
                    _extractionFailed = false;
                  }
                });
                _saveInputMode(mode);
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
              labelText: l10n.getString('eventLinkHint'),
              border: const OutlineInputBorder(),
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16), // 44dp+
            ),
            validator: (value) => value == null || !value.startsWith('http') ? l10n.getString('pleaseEnterValidUrl') : null,
          ),
        ),
        const SizedBox(width: 8),
        ElevatedButton(
          onPressed: isProcessing ? null : () => _handleLinkExtraction(),
          style: ElevatedButton.styleFrom(minimumSize: const Size(60, 60)), // 44dp+
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
        label: Text(l10n.getString('eventInputModeTicket')),
        onPressed: isProcessing ? null : () => _handleFileUpload(),
        style: ElevatedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          minimumSize: const Size(200, 50), // 44dp+
        ),
      ),
    );
  }
}
