# DeepL Translation Integration Setup

This document explains how to set up DeepL translation for improved chat translation quality in the MatchMe app.

## Overview

The app has been updated to use DeepL's professional translation service instead of the previous free translation service. DeepL provides superior translation quality, especially for context and nuance.

## Setup Instructions

### 1. Get a DeepL API Key

1. Visit [DeepL API](https://www.deepl.com/pro-api)
2. Sign up for a free account (500,000 characters/month free tier)
3. Get your API key from the dashboard

### 2. Configure Environment Variables

Create a `.env` file in your project root (copy from `.env.example` if it exists):

```env
# Supabase Configuration
SUPABASE_URL=https://your-project.supabase.co
SUPABASE_ANON_KEY=your_supabase_anon_key_here

# DeepL Translation API (Free tier: 500,000 characters/month)
DEEPL_API_KEY=your_deepl_api_key_here
```

**Important**: The `.env` file contains sensitive information and should not be committed to version control.

For Supabase Edge Functions, add the API key to your Supabase project environment variables:

```bash
supabase secrets set DEEPL_API_KEY=your_deepl_api_key_here
```

### 3. Alternative: Build-time Configuration

You can also set the API key at build time:

```bash
flutter build --dart-define=DEEPL_API_KEY=your_deepl_api_key_here
```

## How It Works

### Web Platform
- Uses DeepL API directly from the browser
- Falls back to the old translation service if DeepL fails or API key is not configured
- Tracks usage to prevent exceeding free tier limits

### Mobile Platforms (Android/iOS)
- Uses DeepL API directly (same as web, no CORS issues)
- Requires internet connection for translations
- Same caching and performance benefits as web

### Usage Tracking
- Tracks character usage against the 500,000 free tier limit
- Warns when approaching limits
- Automatically resets monthly

## Fallback Behavior

If DeepL is not configured or fails:
1. Both Web and Mobile: Returns original text (no translation)
2. Cached translations continue to work offline
3. App remains fully functional without DeepL API key

## Testing

To test the integration:

1. Set up a DeepL API key
2. Enable translation in a chat
3. Send messages in different languages
4. Verify translations appear and are cached

## Benefits

- **Better Quality**: More accurate and natural translations
- **Context Aware**: Better handling of idioms and context
- **Gender Support**: Maintains existing gender-aware translation features
- **Reliable**: Professional service with good uptime
- **Free Tier**: 500,000 characters/month at no cost

## Troubleshooting

### Common Issues

1. **"DeepL API key not configured"**
   - Add `DEEPL_API_KEY` to your `.env` file or build arguments

2. **"DeepL usage limit exceeded"**
   - Free tier limit reached (500,000 characters)
   - Wait for monthly reset or upgrade to paid plan

3. **Translation failures**
   - Check internet connection
   - Verify API key is valid
   - Service automatically falls back to previous translation method

### Monitoring Usage

The app tracks DeepL usage locally. You can monitor usage through:
- Debug logs showing usage statistics
- SharedPreferences storage of usage data
- Automatic warnings when approaching limits

## Migration Notes

- Existing cached translations remain valid
- No database changes required
- Backward compatible - works without DeepL configured
- Gradual rollout possible by enabling/disabling API key

