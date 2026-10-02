enum AdPlacement {
  homeInline('home_inline'),
  matchesInline('matches_inline'),
  chatsInline('chats_inline'),
  eventsInline('events_inline'),
  profileInline('profile_inline');

  const AdPlacement(this.value);

  final String value;
}

class AdEligibility {
  const AdEligibility({required this.canShowSponsoredCard, this.reason});

  final bool canShowSponsoredCard;
  final String? reason;
}

class SponsoredAd {
  const SponsoredAd({
    required this.campaignId,
    required this.creativeId,
    required this.placement,
    required this.platform,
    required this.destinationUrl,
    required this.headline,
    required this.sponsorName,
    this.imageUrl,
    this.body,
    this.ctaLabel,
  });

  final String campaignId;
  final String creativeId;
  final String placement;
  final String platform;
  final String destinationUrl;
  final String headline;
  final String sponsorName;
  final String? imageUrl;
  final String? body;
  final String? ctaLabel;

  bool get hasImage => imageUrl != null && imageUrl!.trim().isNotEmpty;
  bool get hasBody => body != null && body!.trim().isNotEmpty;
  bool get hasCtaLabel => ctaLabel != null && ctaLabel!.trim().isNotEmpty;

  Map<String, dynamic> toJson() {
    return {
      'campaign_id': campaignId,
      'creative_id': creativeId,
      'placement': placement,
      'platform': platform,
      'destination_url': destinationUrl,
      'headline': headline,
      'sponsor_name': sponsorName,
      'image_url': imageUrl,
      'body': body,
      'cta_label': ctaLabel,
    };
  }

  factory SponsoredAd.fromJson(Map<String, dynamic> json) {
    return SponsoredAd(
      campaignId: (json['campaign_id'] ?? '').toString(),
      creativeId: (json['creative_id'] ?? '').toString(),
      placement: (json['placement'] ?? '').toString(),
      platform: (json['platform'] ?? '').toString(),
      destinationUrl: (json['destination_url'] ?? '').toString(),
      headline: (json['headline'] ?? '').toString(),
      sponsorName: (json['sponsor_name'] ?? '').toString(),
      imageUrl: json['image_url']?.toString(),
      body: json['body']?.toString(),
      ctaLabel: json['cta_label']?.toString(),
    );
  }

  factory SponsoredAd.fromMap(Map<String, dynamic> data) {
    return SponsoredAd(
      campaignId: (data['campaign_id'] ?? '').toString(),
      creativeId: (data['creative_id'] ?? '').toString(),
      placement: (data['placement'] ?? '').toString(),
      platform: (data['platform'] ?? '').toString(),
      destinationUrl: (data['destination_url'] ?? '').toString(),
      headline: (data['headline'] ?? '').toString(),
      sponsorName: (data['sponsor_name'] ?? '').toString(),
      imageUrl: data['image_url']?.toString(),
      body: data['body']?.toString(),
      ctaLabel: data['cta_label']?.toString(),
    );
  }
}
