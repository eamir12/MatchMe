# External Ad Network Integration Spec

## Overview
Integrate Google AdMob and other external ad networks to generate revenue from impressions, clicks, and conversions. This spec covers database schema, backend services, admin configuration, and mobile/web implementations.

## Goals
1. Add revenue-generating external ad networks (AdMob primary, with mediation support)
2. Track earnings, impressions, clicks, and revenue metrics
3. Provide admin dashboard for network configuration and analytics
4. Maintain user privacy and consent compliance
5. Support both native mobile ads and web banner ads
6. Implement mediation logic for optimal revenue

## Architecture

### Database Schema Changes

#### 1. Ad Networks Configuration
```sql
CREATE TABLE ad_networks (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  provider text NOT NULL UNIQUE CHECK (provider IN ('admob', 'facebook', 'applovin', 'unity')),
  display_name text NOT NULL,
  is_enabled boolean NOT NULL DEFAULT false,
  priority integer NOT NULL DEFAULT 100,
  config jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT NOW(),
  updated_at timestamptz NOT NULL DEFAULT NOW()
);
```

#### 2. Ad Units (Network-specific placements)
```sql
CREATE TABLE ad_units (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  network_id uuid NOT NULL REFERENCES ad_networks(id) ON DELETE CASCADE,
  placement text NOT NULL,
  platform text NOT NULL CHECK (platform IN ('android', 'ios', 'web')),
  ad_unit_id text NOT NULL,
  ad_format text NOT NULL CHECK (ad_format IN ('banner', 'interstitial', 'rewarded', 'native')),
  is_active boolean NOT NULL DEFAULT true,
  priority integer NOT NULL DEFAULT 100,
  created_at timestamptz NOT NULL DEFAULT NOW(),
  updated_at timestamptz NOT NULL DEFAULT NOW(),
  UNIQUE(network_id, placement, platform, ad_format)
);
```

#### 3. Revenue Events (Earnings tracking)
```sql
CREATE TABLE ad_revenue_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  network_id uuid NOT NULL REFERENCES ad_networks(id) ON DELETE CASCADE,
  ad_unit_id uuid NOT NULL REFERENCES ad_units(id) ON DELETE CASCADE,
  placement text NOT NULL,
  platform text NOT NULL,
  event_type text NOT NULL CHECK (event_type IN ('impression', 'click', 'conversion')),
  revenue_usd numeric(10, 6) NOT NULL DEFAULT 0,
  currency text NOT NULL DEFAULT 'USD',
  ad_format text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT NOW()
);
```

#### 4. Ad Network Analytics (Aggregated metrics)
```sql
CREATE TABLE ad_network_analytics (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  network_id uuid NOT NULL REFERENCES ad_networks(id) ON DELETE CASCADE,
  date date NOT NULL,
  placement text NOT NULL,
  platform text NOT NULL,
  impressions integer NOT NULL DEFAULT 0,
  clicks integer NOT NULL DEFAULT 0,
  conversions integer NOT NULL DEFAULT 0,
  revenue_usd numeric(12, 2) NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT NOW(),
  updated_at timestamptz NOT NULL DEFAULT NOW(),
  UNIQUE(network_id, date, placement, platform)
);
```

#### 5. User Consent (Privacy compliance)
```sql
CREATE TABLE ad_consent (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL UNIQUE REFERENCES users(id) ON DELETE CASCADE,
  personalized_ads boolean NOT NULL DEFAULT false,
  non_personalized_ads boolean NOT NULL DEFAULT true,
  consent_given_at timestamptz NOT NULL DEFAULT NOW(),
  consent_version text NOT NULL DEFAULT '1.0',
  updated_at timestamptz NOT NULL DEFAULT NOW()
);
```

### Configuration Management

Add to `app_config`:
```sql
INSERT INTO app_config (config_key, config_value, config_type, category, description) VALUES
  ('ads.external_enabled', 'false'::jsonb, 'boolean', 'ads', 'Enable external ad networks'),
  ('ads.external.admob_enabled', 'false'::jsonb, 'boolean', 'ads', 'Enable Google AdMob'),
  ('ads.external.mediation_enabled', 'false'::jsonb, 'boolean', 'ads', 'Enable ad mediation across networks'),
  ('ads.external.personalized_ads_default', 'false'::jsonb, 'boolean', 'ads', 'Default personalization setting'),
  ('ads.external.show_consent_form', 'true'::jsonb, 'boolean', 'ads', 'Show consent form to users'),
  ('ads.external.min_user_age_for_personalization', '13'::jsonb, 'number', 'ads', 'Minimum age for personalized ads');
```

## Implementation Tasks

### Phase 1: Database & Backend Infrastructure

#### Task 1.1: Create Database Migrations
- [ ] Create ad_networks table
- [ ] Create ad_units table
- [ ] Create ad_revenue_events table
- [ ] Create ad_network_analytics table
- [ ] Create ad_consent table
- [ ] Add indexes for analytics queries
- [ ] Add RLS policies for admin access
- [ ] Add app_config entries

#### Task 1.2: Create Backend Services
- [ ] `ExternalAdService` - Core service for ad network operations
- [ ] `AdMobService` - AdMob-specific implementation
- [ ] `AdMediationService` - Mediation logic across networks
- [ ] `AdRevenueService` - Revenue tracking and analytics
- [ ] `AdConsentService` - User consent management

#### Task 1.3: Create RPC Functions
- [ ] `get_external_ad_for_placement()` - Fetch external ads with mediation
- [ ] `record_external_ad_impression()` - Log impressions
- [ ] `record_external_ad_click()` - Log clicks
- [ ] `record_ad_revenue()` - Log revenue events
- [ ] `get_user_ad_consent()` - Fetch user consent
- [ ] `update_user_ad_consent()` - Update consent

### Phase 2: Mobile Implementation (Flutter)

#### Task 2.1: Add Dependencies
- [ ] Add `google_mobile_ads` package
- [ ] Add `firebase_core` (for AdMob analytics)
- [ ] Add `app_tracking_transparency` (iOS privacy)

#### Task 2.2: Create Mobile Ad Models
- [ ] `ExternalAd` model
- [ ] `AdUnit` model
- [ ] `AdConsent` model
- [ ] `AdRevenueEvent` model

#### Task 2.3: Implement AdMob Integration
- [ ] Initialize Google Mobile Ads SDK
- [ ] Create `MobileAdService` for ad loading/display
- [ ] Implement banner ads
- [ ] Implement interstitial ads
- [ ] Implement rewarded ads
- [ ] Implement native ads
- [ ] Add revenue event tracking

#### Task 2.4: Create Consent UI
- [ ] `AdConsentDialog` - Initial consent form
- [ ] `AdConsentSettings` - User privacy settings screen
- [ ] Handle GDPR/CCPA requirements
- [ ] Store consent preferences

#### Task 2.5: Create Ad Display Widgets
- [ ] `ExternalBannerAdWidget` - Banner ad display
- [ ] `ExternalInterstitialAdWidget` - Interstitial wrapper
- [ ] `ExternalRewardedAdWidget` - Rewarded ad wrapper
- [ ] `ExternalNativeAdWidget` - Native ad display

### Phase 3: Web Implementation

#### Task 3.1: Add Web Ad Support
- [ ] Integrate Google AdSense or AdMob for web
- [ ] Create web-specific ad components
- [ ] Implement banner ads for web
- [ ] Add consent management for web

### Phase 4: Admin Dashboard

#### Task 4.1: Ad Network Configuration
- [ ] Create admin screen for network setup
- [ ] Add AdMob API key configuration
- [ ] Add ad unit ID management
- [ ] Enable/disable networks and placements
- [ ] Set network priorities for mediation

#### Task 4.2: Analytics Dashboard
- [ ] Revenue overview (daily/weekly/monthly)
- [ ] Impressions and CTR by network/placement
- [ ] Revenue by network/platform/placement
- [ ] User consent statistics
- [ ] Real-time earnings display

#### Task 4.3: Consent Management
- [ ] View user consent preferences
- [ ] Bulk consent updates
- [ ] Consent audit logs

### Phase 5: Testing & Optimization

#### Task 5.1: Testing
- [ ] Unit tests for ad services
- [ ] Integration tests for revenue tracking
- [ ] Test ad mediation logic
- [ ] Test consent flows

#### Task 5.2: Optimization
- [ ] Implement ad caching
- [ ] Optimize ad load times
- [ ] Monitor fill rates
- [ ] A/B test placements

## Data Models

### ExternalAd
```dart
class ExternalAd {
  final String networkId;
  final String adUnitId;
  final String placement;
  final String platform;
  final String adFormat; // banner, interstitial, rewarded, native
  final bool isActive;
  final int priority;
}
```

### AdConsent
```dart
class AdConsent {
  final String userId;
  final bool personalizedAds;
  final bool nonPersonalizedAds;
  final DateTime consentGivenAt;
  final String consentVersion;
}
```

### AdRevenueEvent
```dart
class AdRevenueEvent {
  final String userId;
  final String networkId;
  final String adUnitId;
  final String placement;
  final String platform;
  final String eventType; // impression, click, conversion
  final double revenueUsd;
  final String adFormat;
  final DateTime createdAt;
}
```

## Configuration

### AdMob Setup
1. Create AdMob account at admob.google.com
2. Create app in AdMob console
3. Generate ad unit IDs for each placement/format
4. Store ad unit IDs in database via admin dashboard
5. Add AdMob App ID to app configuration

### Privacy & Compliance
- Implement GDPR consent form for EU users
- Implement CCPA consent for California users
- Store user consent preferences
- Respect user's personalization choice
- Provide privacy policy link in consent dialog

## Placement Strategy

### Recommended Placements for External Ads
1. **Banner Ads** (low revenue, non-intrusive)
   - Home feed top
   - Matches feed bottom
   - Chat list bottom

2. **Interstitial Ads** (medium revenue, intrusive)
   - After profile view
   - After match action
   - App exit

3. **Rewarded Ads** (high revenue, user-initiated)
   - Unlock premium features
   - Boost profile visibility
   - Extra likes/messages

4. **Native Ads** (medium revenue, blend with content)
   - Sponsored profiles in matches
   - Featured users in discovery

## Revenue Model

### Expected Revenue Streams
- **Banner impressions**: $0.50-$2 CPM
- **Interstitial clicks**: $0.50-$3 CPC
- **Rewarded completions**: $0.50-$5 per completion
- **Native ads**: $1-$5 CPM

### Mediation Strategy
1. Try highest-priority network first
2. Fall back to next network if no fill
3. Show internal sponsored ads if no external fill
4. Track fill rates and optimize priority

## Security & Privacy

### Data Protection
- Encrypt ad unit IDs in transit
- Use HTTPS for all ad requests
- Implement rate limiting on revenue tracking
- Audit log all configuration changes

### User Privacy
- Respect user consent preferences
- Don't track non-consenting users
- Implement GDPR right to be forgotten
- Provide transparent privacy policy

## Success Metrics

- Ad fill rate > 80%
- Revenue per user > $0.50/month
- User consent rate > 60%
- Ad CTR > 1%
- No negative impact on user retention

## Timeline

- **Phase 1**: 2-3 days (database + backend)
- **Phase 2**: 3-4 days (mobile implementation)
- **Phase 3**: 1-2 days (web implementation)
- **Phase 4**: 2-3 days (admin dashboard)
- **Phase 5**: 2-3 days (testing + optimization)

**Total: 10-15 days**

## Risks & Mitigation

| Risk | Impact | Mitigation |
|------|--------|-----------|
| Low ad fill rate | Revenue loss | Implement mediation, optimize placements |
| User privacy concerns | Retention loss | Clear consent, transparent privacy policy |
| Ad quality issues | User experience | Moderate ad content, use family-safe networks |
| Integration bugs | Revenue loss | Comprehensive testing, staging environment |
| Compliance violations | Legal issues | GDPR/CCPA compliance, legal review |

## Next Steps

1. Review and approve spec
2. Start Phase 1 (database migrations)
3. Set up AdMob account and get ad unit IDs
4. Implement backend services
5. Integrate mobile SDK
6. Build admin dashboard
7. Test and optimize
