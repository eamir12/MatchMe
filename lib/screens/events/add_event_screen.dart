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
import 'package:matchme/services/error_localization_service.dart';
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
  TimeOfDay _startTime = TimeOfDay.fromDateTime(
    DateTime.now().add(const Duration(hours: 1)),
  );

  bool _isLoading = false;
  EventInputMode _inputMode = EventInputMode.link; // Default to Link
  bool _isProcessingInput = false;

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
      _linkController.text = widget.existingEvent!.eventLink ?? '';
      _startDate = widget.existingEvent!.startTime;
      _startTime = TimeOfDay.fromDateTime(widget.existingEvent!.startTime);
      _inputMode = EventInputMode.manual; // Start in manual mode when editing
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
    if (widget.initialSharedText != null &&
        widget.initialSharedText!.isNotEmpty) {
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
    else if (widget.initialSharedFilePath != null &&
        widget.initialSharedFilePath!.isNotEmpty) {
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
                backgroundColor: Colors.orange,
              ),
            );
          } else {
            _populateFieldsFromResult(result);
            setState(() {
              _hasExtractedData = true;
              _extractionFailed = false;
            });
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(message), backgroundColor: Colors.blue),
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
            backgroundColor: Colors.red,
          ),
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
    if (savedModeIndex != null &&
        savedModeIndex >= 0 &&
        savedModeIndex < EventInputMode.values.length) {
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

    if (_linkController.text.trim().isEmpty ||
        !_linkController.text.trim().startsWith('http')) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.getString('pleaseEnterValidUrl')),
          backgroundColor: Colors.red,
        ),
      );
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

      message = result.name.isNotEmpty
          ? l10n.getString('dataExtractedFromLink')
          : l10n.getString('couldNotFetchDetailsFromLink');

      if (mounted && result.name.isNotEmpty) {
        // If the parsed date is in the past, do not import it — we prevent adding past events
        if (result.date != null && result.date!.isBefore(DateTime.now())) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(l10n.getString('eventDateInPastNotImported')),
              backgroundColor: Colors.orange,
            ),
          ); // ignore: use_build_context_synchronously
          // We still show the form even if date is past, just let user fix it?
          // Current logic seems to be: if past, show warning but do we populate?
          // The previous code showed snackbar and did NOT populate/switch mode.
          // I will stick to previous behavior: show warning, do not proceed to success state.
        } else {
          _populateFieldsFromResult(result);
          setState(() {
            _hasExtractedData = true;
            _extractionFailed = false;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(message), backgroundColor: Colors.green),
          ); // ignore: use_build_context_synchronously
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
        final l10n = ref.read(localizationProvider);
        final errorKey = ErrorLocalizationService.getErrorTranslationKey(e);
        setState(() {
          _extractionFailed = true;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.getString(errorKey)),
            backgroundColor: Colors.red,
          ),
        );
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

      message = result.name.isNotEmpty
          ? l10n.getString('ticketProcessedSuccessfully')
          : l10n.getString('couldNotExtractEventDetailsFromTicket');

      if (mounted) {
        if (result.name.isNotEmpty) {
          // If the parsed date is in the past, do not import it — we prevent adding past events
          if (result.date != null && result.date!.isBefore(DateTime.now())) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(l10n.getString('eventDateInPastNotImported')),
                backgroundColor: Colors.orange,
              ),
            );
          } else {
            _populateFieldsFromResult(result);
            setState(() {
              _hasExtractedData = true;
              _extractionFailed = false;
            });
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(message), backgroundColor: Colors.blue),
            );
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
      if (msg.contains('cancel') ||
          msg.contains('abort') ||
          msg.contains('user canceled') ||
          msg.contains('user cancelled')) {
        return;
      }
      if (mounted) {
        final l10n = ref.read(localizationProvider);
        final errorKey = ErrorLocalizationService.getErrorTranslationKey(e);
        setState(() {
          _extractionFailed = true;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.getString(errorKey)),
            backgroundColor: Colors.red,
          ),
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
        _startDate = DateTime(
          pickedDate.year,
          pickedDate.month,
          pickedDate.day,
          _startTime.hour,
          _startTime.minute,
        );
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
        _startDate = DateTime(
          _startDate.year,
          _startDate.month,
          _startDate.day,
          pickedTime.hour,
          pickedTime.minute,
        );
      });
    }
  }

  DateTime _startDateTime() => DateTime(
    _startDate.year,
    _startDate.month,
    _startDate.day,
    _startTime.hour,
    _startTime.minute,
  );

  Widget _buildPublicEventDisclosure(
    BuildContext context,
    LocalizationState l10n,
  ) {
    final colors = Theme.of(context).colorScheme;
    final title = l10n.getString('eventPublicDisclosureTitle');
    final body = l10n.getString('eventPublicDisclosureBody');
    return Semantics(
      container: true,
      label: '$title. $body',
      child: Card(
        margin: EdgeInsets.zero,
        elevation: 0,
        color: colors.secondaryContainer.withValues(alpha: 0.55),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: colors.secondary.withValues(alpha: 0.35)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.groups_outlined, color: colors.onSecondaryContainer),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: colors.onSecondaryContainer,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      body,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colors.onSecondaryContainer,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<bool> _confirmPublicEventSave(LocalizationState l10n) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.getString('eventPublicDisclosureConfirmTitle')),
        content: Text(l10n.getString('eventPublicDisclosureConfirmBody')),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.getString('generalCancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.getString('saveEvent')),
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  Future<void> _submitEvent() async {
    final l10n = ref.read(localizationProvider);
    if (!_formKey.currentState!.validate()) return;
    if (!mounted) return;

    final startTime = _startDateTime();

    // Prevent creating events that started more than 30 minutes ago
    if (widget.existingEvent == null &&
        startTime.isBefore(
          DateTime.now().subtract(const Duration(minutes: 30)),
        )) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.getString('eventCannotBeInPast')),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    if (widget.existingEvent == null) {
      final confirmed = await _confirmPublicEventSave(l10n);
      if (!confirmed || !mounted) return;
    }
    if (!mounted) return;
    setState(() => _isLoading = true);

    final endTime = startTime.add(const Duration(hours: 1));
    final normalizedLink = _linkController.text.trim();

    final event = EventModel(
      id: widget.existingEvent?.id ?? uuid.v4(),
      eventName: _eventNameController.text.trim(),
      eventVenue: _venueController.text.trim().isEmpty
          ? null
          : _venueController.text.trim(),
      startTime: startTime,
      endTime: endTime,
      notes: _notesController.text.trim().isEmpty
          ? null
          : _notesController.text.trim(),
      eventLink: normalizedLink.isEmpty ? null : normalizedLink,
    );

    bool success;
    String? failureMessage;
    if (widget.existingEvent != null) {
      print(
        '[EVENT_MANUAL_UI] Updating manual event title="${event.eventName}" start=${event.startTime.toIso8601String()} venue="${event.eventVenue ?? ''}"',
      );
      success = await ref
          .read(eventManagerProvider.notifier)
          .updateEvent(event);
    } else {
      print(
        '[EVENT_MANUAL_UI] Creating manual event title="${event.eventName}" start=${event.startTime.toIso8601String()} venue="${event.eventVenue ?? ''}"',
      );
      final result = await ref
          .read(eventManagerProvider.notifier)
          .addEventWithResult(event);
      success = result.success;
      if (!result.success) {
        final reasonKey = result.errorKey ?? 'eventAddFailedUnknown';
        final diagnosticCode = result.diagnosticCode ?? '';
        print(
          '[EVENT_MANUAL_UI] Manual event create failed reasonKey=$reasonKey diagnosticCode=${diagnosticCode.isEmpty ? 'none' : diagnosticCode}',
        );
        final reason = l10n.getString(reasonKey);
        failureMessage = l10n.getString(
          'eventSaveFailedWithReason',
          params: {'reason': reason},
        );
      } else {
        print('[EVENT_MANUAL_UI] Manual event created successfully');
      }
    }

    if (mounted) {
      if (success) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              widget.existingEvent != null
                  ? l10n.getString('eventUpdatedSuccessfully')
                  : l10n.getString('eventSavedSuccessfully'),
            ),
            backgroundColor: Colors.green,
          ),
        );
        Navigator.pop(context);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              widget.existingEvent != null
                  ? l10n.getString('failedToUpdateEvent')
                  : (failureMessage ?? l10n.getString('failedToSaveEvent')),
            ),
            backgroundColor: Colors.red,
          ),
        );
      }
    }

    if (mounted) setState(() => _isLoading = false);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(localizationProvider);
    final isProcessing = _isLoading || _isProcessingInput;
    final isRtl = [
      'ar',
      'he',
    ].contains(l10n.currentLocale.languageCode.toLowerCase());
    final isEditing = widget.existingEvent != null;
    final isNewEvent = !isEditing;
    final showForm =
        isEditing ||
        _inputMode == EventInputMode.manual ||
        _hasExtractedData;
    // In link mode the dedicated link input holds the URL before extraction,
    // so hide the form's link field to avoid showing the same link twice.
    final showLinkField = !(isNewEvent &&
        _inputMode == EventInputMode.link &&
        !_hasExtractedData);

    return Directionality(
      textDirection: isRtl ? ui.TextDirection.rtl : ui.TextDirection.ltr,
      child: Scaffold(
        appBar: widget.showAppBar
            ? AppBar(
                title: Text(
                  isEditing
                      ? l10n.getString('editEventTitle')
                      : l10n.getString('addEventTitle'),
                ),
              )
            : null,
        body: Form(
          key: _formKey,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
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
                      Expanded(
                        child: Text(
                          isEditing
                              ? l10n.getString('editEventTitle')
                              : l10n.getString('addEventTitle'),
                          style: Theme.of(context).textTheme.titleMedium,
                          maxLines: 2,
                          overflow: TextOverflow.visible,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                ],

                // Friendly explainer + way-to-add picker (new events only)
                if (isNewEvent) ...[
                  _buildIntroHeader(context, l10n),
                  const SizedBox(height: 20),
                  Text(
                    l10n.getString('addEventHowTitle'),
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 10),
                  _buildModeCards(context, l10n),
                  const SizedBox(height: 20),
                  if (_inputMode == EventInputMode.link &&
                      !_hasExtractedData)
                    _buildLinkInput(context, l10n, isProcessing)
                  else if (_inputMode == EventInputMode.image &&
                      !_hasExtractedData)
                    _buildImageInput(context, l10n, isProcessing),
                ],

                if (_extractionFailed) ...[
                  _buildExtractionError(context, l10n),
                  const SizedBox(height: 16),
                ],

                // Event details form (manual mode, editing, or after extraction)
                if (showForm) ...[
                  if (isNewEvent) const SizedBox(height: 8),
                  _buildSectionHeader(
                    context,
                    l10n.getString('eventDetails'),
                    Icons.edit_note_rounded,
                  ),
                  const SizedBox(height: 12),

                  TextFormField(
                    controller: _eventNameController,
                    focusNode: _eventNameFocus,
                    textInputAction: TextInputAction.next,
                    onFieldSubmitted: (_) =>
                        FocusScope.of(context).requestFocus(_venueFocus),
                    style: Theme.of(
                      context,
                    ).textTheme.bodyMedium?.copyWith(fontFeatures: const []),
                    decoration: InputDecoration(
                      labelText: l10n.getString('eventNameRequired'),
                      prefixIcon: const Icon(Icons.event_outlined),
                      border: const OutlineInputBorder(),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 16,
                      ),
                    ),
                    validator: (value) => value == null || value.isEmpty
                        ? l10n.getString('nameCannotBeEmpty')
                        : null,
                  ),
                  const SizedBox(height: 16),

                  TextFormField(
                    controller: _venueController,
                    focusNode: _venueFocus,
                    textInputAction: TextInputAction.next,
                    onFieldSubmitted: (_) => FocusScope.of(context).nextFocus(),
                    style: Theme.of(
                      context,
                    ).textTheme.bodyMedium?.copyWith(fontFeatures: const []),
                    decoration: InputDecoration(
                      labelText: l10n.getString('venueLocationOptional'),
                      prefixIcon: const Icon(Icons.place_outlined),
                      border: const OutlineInputBorder(),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 16,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  if (showLinkField)
                    TextFormField(
                      controller: _linkController,
                      textInputAction: TextInputAction.next,
                      keyboardType: TextInputType.url,
                      autocorrect: false,
                      enableSuggestions: false,
                      onFieldSubmitted: (_) =>
                          FocusScope.of(context).nextFocus(),
                      style: Theme.of(
                        context,
                      ).textTheme.bodyMedium?.copyWith(fontFeatures: const []),
                      decoration: InputDecoration(
                        labelText: l10n.getString('eventLinkOptionalLabel'),
                        hintText: l10n.getString('eventLinkHint'),
                        prefixIcon: const Icon(Icons.link_outlined),
                        border: const OutlineInputBorder(),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 16,
                        ),
                      ),
                    ),
                  if (showLinkField) const SizedBox(height: 16),

                  _buildSectionHeader(
                    context,
                    l10n.getString('whenIsTheEvent'),
                    Icons.schedule_rounded,
                  ),
                  const SizedBox(height: 12),

                  Row(
                    children: [
                      Expanded(child: _buildDateButton(context, l10n: l10n)),
                      const SizedBox(width: 16),
                      Expanded(child: _buildTimeButton(context, l10n: l10n)),
                    ],
                  ),

                  const SizedBox(height: 20),

                  TextFormField(
                    controller: _notesController,
                    focusNode: _notesFocus,
                    textInputAction: TextInputAction.done,
                    style: Theme.of(
                      context,
                    ).textTheme.bodyMedium?.copyWith(fontFeatures: const []),
                    decoration: InputDecoration(
                      labelText: l10n.getString('notesOptional'),
                      alignLabelWithHint: true,
                      prefixIcon: const Padding(
                        padding: EdgeInsets.only(bottom: 40),
                        child: Icon(Icons.notes_outlined),
                      ),
                      border: const OutlineInputBorder(),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 16,
                      ),
                    ),
                    maxLines: 3,
                  ),

                  if (widget.existingEvent == null) ...[
                    const SizedBox(height: 24),
                    _buildPublicEventDisclosure(context, l10n),
                  ],

                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: isProcessing ? null : _submitEvent,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(double.infinity, 56),
                      textStyle: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    child: isProcessing
                        ? SizedBox(
                            height: 22,
                            width: 22,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.4,
                              color: Theme.of(context).colorScheme.onPrimary,
                            ),
                          )
                        : Text(
                            isEditing
                                ? l10n.getString('updateEvent')
                                : l10n.getString('saveEvent'),
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

  Widget _buildSectionHeader(
    BuildContext context,
    String title,
    IconData icon,
  ) {
    return Row(
      children: [
        Icon(icon, size: 20, color: Theme.of(context).colorScheme.primary),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            title,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildIntroHeader(BuildContext context, LocalizationState l10n) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.primaryContainer.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: colors.primaryContainer,
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.celebration_rounded,
              color: colors.onPrimaryContainer,
              size: 26,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              l10n.getString('addEventIntroBody'),
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: colors.onSurface,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildModeCards(BuildContext context, LocalizationState l10n) {
    final modes = [
      (
        EventInputMode.link,
        Icons.link_rounded,
        'eventInputModeLinkTitle',
        'eventInputModeLinkDesc',
      ),
      (
        EventInputMode.image,
        Icons.image_outlined,
        'eventInputModeTicketTitle',
        'eventInputModeTicketDesc',
      ),
      (
        EventInputMode.manual,
        Icons.edit_outlined,
        'eventInputModeManualTitle',
        'eventInputModeManualDesc',
      ),
    ];

    return Column(
      children: [
        for (final (index, mode) in modes.indexed) ...[
          if (index > 0) const SizedBox(height: 8),
          _buildModeCard(
            context,
            l10n,
            mode: mode.$1,
            icon: mode.$2,
            titleKey: mode.$3,
            descriptionKey: mode.$4,
          ),
        ],
      ],
    );
  }

  Widget _buildModeCard(
    BuildContext context,
    LocalizationState l10n, {
    required EventInputMode mode,
    required IconData icon,
    required String titleKey,
    required String descriptionKey,
  }) {
    final colors = Theme.of(context).colorScheme;
    final selected = _inputMode == mode;
    final title = l10n.getString(titleKey);
    final description = l10n.getString(descriptionKey);

    return Semantics(
      button: true,
      selected: selected,
      label: '$title. $description',
      child: Card(
        margin: EdgeInsets.zero,
        elevation: 0,
        color: selected
            ? colors.primaryContainer.withValues(alpha: 0.45)
            : colors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(
            color: selected ? colors.primary : colors.outlineVariant,
            width: selected ? 2 : 1,
          ),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () {
            setState(() {
              _inputMode = mode;
              // Reset extraction state when switching modes
              if (mode != EventInputMode.manual) {
                _hasExtractedData = false;
                _extractionFailed = false;
              }
            });
            _saveInputMode(mode);
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: selected
                        ? colors.primary
                        : colors.surfaceContainerHighest,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    icon,
                    size: 20,
                    color: selected
                        ? colors.onPrimary
                        : colors.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        description,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  selected
                      ? Icons.check_circle_rounded
                      : Icons.radio_button_unchecked,
                  color: selected ? colors.primary : colors.outline,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildExtractionError(BuildContext context, LocalizationState l10n) {
    final colors = Theme.of(context).colorScheme;
    final message = _inputMode == EventInputMode.link
        ? l10n.getString('couldNotFetchDetailsFromLink')
        : l10n.getString('couldNotExtractEventDetailsFromTicket');
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.errorContainer.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.error_outline_rounded, color: colors.error),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  message,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _retryExtraction,
            icon: const Icon(Icons.refresh_rounded),
            label: Text(l10n.getString('retryExtractionButton')),
          ),
        ],
      ),
    );
  }

  Widget _buildDateButton(
    BuildContext context, {
    required LocalizationState l10n,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.getString('startDate'),
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 4),
        OutlinedButton.icon(
          icon: const Icon(Icons.calendar_today, size: 18),
          label: Text(
            DateFormat(
              'EEE, MMM d, yyyy',
              l10n.currentLocale.languageCode,
            ).format(_startDate),
          ),
          onPressed: () => _selectDate(context),
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 15),
            minimumSize: const Size(double.infinity, 50), // 44dp+
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTimeButton(
    BuildContext context, {
    required LocalizationState l10n,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.getString('startTime'),
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 4),
        OutlinedButton.icon(
          icon: const Icon(Icons.access_time, size: 18),
          label: Text(_startTime.format(context)),
          onPressed: () => _selectTime(context),
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 15),
            minimumSize: const Size(double.infinity, 50), // 44dp+
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildLinkInput(
    BuildContext context,
    LocalizationState l10n,
    bool isProcessing,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextFormField(
          controller: _linkController,
          keyboardType: TextInputType.url,
          autocorrect: false,
          enableSuggestions: false,
          enabled: !isProcessing,
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(fontFeatures: const []),
          decoration: InputDecoration(
            labelText: l10n.getString('eventLinkHint'),
            prefixIcon: const Icon(Icons.link),
            border: const OutlineInputBorder(),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 16,
            ),
          ),
          validator: (value) => value == null || !value.startsWith('http')
              ? l10n.getString('pleaseEnterValidUrl')
              : null,
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: isProcessing ? null : () => _handleLinkExtraction(),
          icon: isProcessing
              ? SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Theme.of(context).colorScheme.onPrimary,
                  ),
                )
              : const Icon(Icons.travel_explore),
          label: Text(l10n.getString('eventLinkFetchButton')),
          style: FilledButton.styleFrom(
            minimumSize: const Size(double.infinity, 52),
            textStyle: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          l10n.getString('eventLinkHelpText'),
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  Widget _buildImageInput(
    BuildContext context,
    LocalizationState l10n,
    bool isProcessing,
  ) {
    final colors = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: isProcessing ? null : () => _handleFileUpload(),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
        decoration: BoxDecoration(
          color: colors.surfaceContainerHighest.withValues(alpha: 0.45),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: colors.outlineVariant, width: 1.5),
        ),
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: colors.primaryContainer.withValues(alpha: 0.6),
                shape: BoxShape.circle,
              ),
              child: isProcessing
                  ? SizedBox(
                      height: 24,
                      width: 24,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.4,
                        color: colors.primary,
                      ),
                    )
                  : Icon(
                      Icons.upload_file_rounded,
                      size: 28,
                      color: colors.onPrimaryContainer,
                    ),
            ),
            const SizedBox(height: 12),
            Text(
              l10n.getString('eventTicketUploadButton'),
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              l10n.getString('eventTicketUploadHelpText'),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
