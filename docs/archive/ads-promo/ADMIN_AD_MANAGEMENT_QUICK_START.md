# Admin Ad Management - Quick Start

## Access the Ad Management Dashboard

1. Open the Admin App
2. Navigate to **Sponsored Ads** section in the left navigation
3. Click **Ad System Settings**

---

## Master Control

### Enable/Disable All Advertising

The **Advertising System** toggle is your master on/off switch:

- **ON**: Advertising is active (choose Internal or External)
- **OFF**: All advertising is disabled

When OFF, both Internal and External ads are disabled regardless of their individual settings.

---

## Configure Internal Ads (Sponsored Cards)

### 1. Enable Internal Ads
- Master switch must be ON
- Toggle **Enable Internal Ads** to ON
- This disables External Ads automatically

### 2. Choose Placements
Select which screens show internal ads:
- ✓ Home Inline (recommended)
- ✓ Matches Inline (recommended)
- ☐ Chats Inline
- ☐ Events Inline

### 3. Choose User Tiers
Select which subscription tiers see ads:
- ✓ Free (recommended - free users see ads)
- ☐ Premium (optional)
- ☐ VIP (optional)

### 4. Optional: Set Schedule
- Toggle **Schedule** ON
- Set **Start Time** (e.g., 08:00)
- Set **End Time** (e.g., 22:00)
- Ads only show during these hours

### 5. Optional: Rate Limiting
- **Max Impressions Per Session**: 3 (default)
- **Min Minutes Between Impressions**: 8 (default)
- **First Impression Delay**: 90 seconds (default)

### 6. Save
Click **Save Settings** - changes take effect immediately

---

## Configure External Ads (AdMob, Facebook, etc.)

### 1. Enable External Ads
- Master switch must be ON
- Toggle **Enable External Ads** to ON
- This disables Internal Ads automatically

### 2. Choose Placements
Select which screens show external ads:
- ✓ Home Inline (recommended)
- ✓ Matches Inline (recommended)
- ☐ Chats Inline
- ☐ Events Inline

### 3. Choose User Tiers
Select which subscription tiers see ads:
- ✓ Free (recommended - free users see ads)
- ☐ Premium (optional)
- ☐ VIP (optional)

### 4. Optional: Set Schedule
- Toggle **Schedule** ON
- Set **Start Time** (e.g., 08:00)
- Set **End Time** (e.g., 22:00)
- Ads only show during these hours

### 5. Optional: Rate Limiting
- **Max Impressions Per Session**: 5 (default)
- **Min Minutes Between Impressions**: 5 (default)
- **First Impression Delay**: 60 seconds (default)

### 6. Save
Click **Save Settings** - changes take effect immediately

---

## Common Scenarios

### Scenario 1: Test Internal Ads
1. Master switch: ON
2. Internal Ads: ON
3. External Ads: OFF
4. Save
5. Open main app → ads appear on configured placements

### Scenario 2: Switch to External Ads
1. Master switch: ON
2. Internal Ads: OFF
3. External Ads: ON
4. Save
5. Open main app → external ads appear instead

### Scenario 3: Disable All Ads
1. Master switch: OFF
2. Save
3. No ads appear anywhere

### Scenario 4: Ads Only During Business Hours
1. Master switch: ON
2. Choose system (Internal or External)
3. Toggle Schedule: ON
4. Start Time: 09:00
5. End Time: 17:00
6. Save
7. Ads only show 9 AM - 5 PM

### Scenario 5: Limit Ad Frequency
1. Master switch: ON
2. Choose system
3. Rate Limiting:
   - Max Impressions Per Session: 2
   - Min Minutes Between Impressions: 15
   - First Impression Delay: 120 seconds
4. Save
5. Users see max 2 ads per session, 15 minutes apart, first ad after 2 minutes

---

## Important Notes

### Only One System at a Time
- You can only have Internal OR External ads enabled
- Enabling one automatically disables the other
- This prevents conflicts and confusion

### Changes Take Effect Immediately
- No app restart needed
- Users see changes within seconds
- Perfect for testing and adjustments

### Master Switch is Global
- Turning OFF the master switch disables everything
- Use this for emergency ad shutdown
- Useful for maintenance or issues

### Placements Control Where Ads Appear
- Home Inline: Ads in home feed
- Matches Inline: Ads in matches feed
- Chats Inline: Ads in chat list
- Events Inline: Ads in events feed

### Tiers Control Who Sees Ads
- Free: Free tier users
- Premium: Premium subscribers
- VIP: VIP subscribers
- Typically only enable "Free" tier

### Schedule Controls When Ads Appear
- Optional feature
- Useful for time-based campaigns
- Format: HH:MM (24-hour)
- Example: 08:00 to 22:00

### Rate Limiting Prevents Ad Fatigue
- Max Impressions: How many ads per session
- Min Minutes Between: Minimum wait between ads
- First Impression Delay: Wait before first ad
- Helps user experience

---

## Troubleshooting

### Ads Not Showing?
1. Check Master switch is ON
2. Check system is enabled (Internal or External)
3. Check placement is enabled
4. Check tier is enabled
5. Check schedule (if enabled) allows current time
6. Check rate limiting hasn't been exceeded

### Settings Not Saving?
1. Check you're logged in as admin
2. Check internet connection
3. Try refreshing the page
4. Check browser console for errors

### Want to Test Quickly?
1. Enable master switch
2. Choose a system
3. Enable all placements
4. Enable all tiers
5. Disable schedule
6. Save
7. Open main app and navigate to home screen

---

## Support

For issues or questions:
- Check the troubleshooting section above
- Review your configuration settings
- Verify all toggles are set correctly
- Try disabling schedule if ads aren't showing
