import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/providers/external_ad_provider.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:matchme/widgets/safe_text.dart';

/// Screen for managing ad preferences
class AdSettingsScreen extends ConsumerStatefulWidget {
  const AdSettingsScreen({super.key});

  @override
  ConsumerState<AdSettingsScreen> createState() => _AdSettingsScreenState();
}

class _AdSettingsScreenState extends ConsumerState<AdSettingsScreen> {
  bool? _personalizedAds;
  bool? _nonPersonalizedAds;
  bool _isLoading = true;
  bool _isSaving = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _loadConsent();
  }

  Future<void> _loadConsent() async {
    final l10n = ref.read(localizationProvider);
    try {
      final currentUser = Supabase.instance.client.auth.currentUser;
      if (currentUser == null) {
        setState(() {
          _isLoading = false;
          _errorMessage = l10n.getString('adSettingsNotAuthenticated');
        });
        return;
      }

      final consentService = ref.read(adConsentServiceProvider);
      final consent = await consentService.getUserConsent(currentUser.id);

      if (mounted) {
        setState(() {
          _personalizedAds = consent?.personalizedAds ?? false;
          _nonPersonalizedAds = consent?.nonPersonalizedAds ?? true;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = '${l10n.getString('adSettingsLoadFailed')}: $e';
        });
      }
    }
  }

  Future<void> _saveConsent() async {
    final l10n = ref.read(localizationProvider);
    if (_personalizedAds == null || _nonPersonalizedAds == null) {
      return;
    }

    // Validate at least one option is selected
    if (!_personalizedAds! && !_nonPersonalizedAds!) {
      _showSnackBar(l10n.getString('adSettingsAtLeastOneConsent'));
      return;
    }

    setState(() => _isSaving = true);

    try {
      final consentService = ref.read(adConsentServiceProvider);
      final result = await consentService.updateUserConsent(
        personalizedAds: _personalizedAds!,
        nonPersonalizedAds: _nonPersonalizedAds!,
      );

      if (result != null && mounted) {
        _showSnackBar(l10n.getString('adSettingsSaved'));
      } else if (mounted) {
        _showSnackBar(l10n.getString('adSettingsSaveFailed'));
      }
    } catch (e) {
      if (mounted) {
        _showSnackBar('${l10n.getString('generalError')}: $e');
      }
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  Future<void> _optOutOfAllAds() async {
    final l10n = ref.read(localizationProvider);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.getString('externalAdsOptOutAllTitle')),
        content: Text(l10n.getString('externalAdsOptOutAllConfirmation')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.getString('generalCancel')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.getString('externalAdsOptOutAll')),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() => _isSaving = true);

    try {
      final consentService = ref.read(adConsentServiceProvider);
      final result = await consentService.optOutOfAllAds();

      if (result && mounted) {
        setState(() {
          _personalizedAds = false;
          _nonPersonalizedAds = false;
        });
        _showSnackBar(l10n.getString('externalAdsOptOutAllSuccess'));
      } else if (mounted) {
        _showSnackBar(l10n.getString('externalAdsOptOutAllFailed'));
      }
    } catch (e) {
      if (mounted) {
        _showSnackBar('${l10n.getString('generalError')}: $e');
      }
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(localizationProvider);
    final theme = Theme.of(context);

    if (_isLoading) {
      return Scaffold(
        appBar: AppBar(title: ShrinkText(l10n.getString('externalAdsSettingsTitle'))),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    if (_errorMessage != null) {
      return Scaffold(
        appBar: AppBar(title: ShrinkText(l10n.getString('externalAdsSettingsTitle'))),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(_errorMessage!),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () {
                  setState(() => _isLoading = true);
                  _loadConsent();
                },
                child: Text(l10n.getString('generalRetry')),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: ShrinkText(l10n.getString('externalAdsSettingsTitle'))),
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Description
              Text(
                l10n.getString('externalAdsSettingsDescription'),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 24),

              // Personalized ads toggle
              Card(
                child: SwitchListTile(
                  title: Text(l10n.getString('externalAdsPersonalizedToggle')),
                  subtitle: Text(
                    l10n.getString('adSettingsPersonalizedDesc'),
                    style: theme.textTheme.bodySmall,
                  ),
                  value: _personalizedAds ?? false,
                  onChanged: _isSaving
                      ? null
                      : (value) {
                          setState(() => _personalizedAds = value);
                        },
                ),
              ),
              const SizedBox(height: 12),

              // Non-personalized ads toggle
              Card(
                child: SwitchListTile(
                  title: Text(
                    l10n.getString('externalAdsNonPersonalizedToggle'),
                  ),
                  subtitle: Text(
                    l10n.getString('adSettingsNonPersonalizedDesc'),
                    style: theme.textTheme.bodySmall,
                  ),
                  value: _nonPersonalizedAds ?? true,
                  onChanged: _isSaving
                      ? null
                      : (value) {
                          setState(() => _nonPersonalizedAds = value);
                        },
                ),
              ),
              const SizedBox(height: 24),

              // Warning if no ads selected
              if (!(_personalizedAds ?? false) &&
                  !(_nonPersonalizedAds ?? false))
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    l10n.getString('externalAdsOptOutWarning'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onErrorContainer,
                    ),
                  ),
                ),
              const SizedBox(height: 24),

              // Save button
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _isSaving ? null : _saveConsent,
                  child: _isSaving
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(l10n.getString('generalSave')),
                ),
              ),
              const SizedBox(height: 12),

              // Opt out button
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: _isSaving ? null : _optOutOfAllAds,
                  child: Text(l10n.getString('externalAdsOptOutAll')),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
