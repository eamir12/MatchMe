# Promo Code UI - Integration Guide for MatchMe Admin App

## Quick Start

The admin dashboard is ready to integrate into your admin navigation. Follow these steps:

## Step 1: Import the Dashboard

```dart
import 'package:matchme_admin/screens/promo_code_dashboard.dart';
```

## Step 2: Add Route to Admin Navigation

In your `matchme_admin/lib/main.dart` or route configuration:

```dart
// In your MaterialApp routes
routes: {
  '/': (context) => const AdminMainScreen(),
  '/promo-codes': (context) => AdminPromoCodeDashboard(),
  // ... other admin routes
},
```

## Step 3: Add Navigation Menu Item

Update your admin sidebar/drawer:

```dart
class AdminMainScreen extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      drawer: Drawer(
        child: ListView(
          children: [
            DrawerHeader(child: Text('Admin Dashboard')),
            
            ListTile(
              leading: Icon(Icons.dashboard),
              title: Text('Dashboard'),
              onTap: () => Navigator.pushNamed(context, '/'),
            ),
            
            // ADD THIS
            ListTile(
              leading: Icon(Icons.local_offer),
              title: Text('Promo Codes'),
              onTap: () => Navigator.pushNamed(context, '/promo-codes'),
            ),
            
            ListTile(
              leading: Icon(Icons.people),
              title: Text('Users'),
              onTap: () => Navigator.pushNamed(context, '/users'),
            ),
            
            // ... other menu items
          ],
        ),
      ),
      body: // ... your content
    );
  }
}
```

## Full Admin App Integration Example

```dart
// matchme_admin/lib/main.dart
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'screens/promo_code_dashboard.dart';

void main() async {
  await Supabase.initialize(
    url: 'YOUR_SUPABASE_URL',
    anonKey: 'YOUR_SUPABASE_ANON_KEY',
  );
  runApp(const AdminApp());
}

class AdminApp extends StatelessWidget {
  const AdminApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MatchMe Admin',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: true,
      ),
      home: const AdminMainScreen(),
      routes: {
        '/promo-codes': (context) => const AdminPromoCodeDashboard(),
      },
    );
  }
}

class AdminMainScreen extends StatelessWidget {
  const AdminMainScreen({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('MatchMe Admin Dashboard'),
        elevation: 0,
      ),
      drawer: _buildDrawer(context),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text('Welcome to Admin Panel'),
            const SizedBox(height: 32),
            ElevatedButton(
              onPressed: () => Navigator.pushNamed(context, '/promo-codes'),
              child: const Text('Go to Promo Code Management'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDrawer(BuildContext context) {
    return Drawer(
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          DrawerHeader(
            decoration: BoxDecoration(
              color: Colors.blue[700],
            ),
            child: const Text(
              'Admin Menu',
              style: TextStyle(
                color: Colors.white,
                fontSize: 24,
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.dashboard),
            title: const Text('Dashboard'),
            onTap: () => Navigator.pop(context),
          ),
          ListTile(
            leading: const Icon(Icons.local_offer),
            title: const Text('Promo Codes'),
            onTap: () {
              Navigator.pop(context);
              Navigator.pushNamed(context, '/promo-codes');
            },
          ),
          ListTile(
            leading: const Icon(Icons.people),
            title: const Text('Users'),
            onTap: () => Navigator.pop(context),
          ),
          ListTile(
            leading: const Icon(Icons.logout),
            title: const Text('Logout'),
            onTap: () => Navigator.pop(context),
          ),
        ],
      ),
    );
  }
}
```

## Admin Dashboard Features

### Tab 1: Create Promo Code

**Form fields:**
- Code name (required)
- Discount type dropdown (percentage/fixed/free_days/tier_upgrade)
- Discount value (percentage or amount)
- Valid from & to dates (date pickers)
- Usage limits (max total uses, per user)
- Applicable tiers (multi-select checkboxes)
- Campaign name (for tracking)

**Actions:**
- Create button (validates and submits)
- Clear button (resets form)

### Tab 2: Active Codes

**Features:**
- List of all active promo codes
- Sort by: created date, uses, expires
- Filter by tier or campaign
- Quick stats on each code

**Actions per code:**
- View details
- Edit code settings
- Disable/deactivate
- View usage history

### Tab 3: Analytics

**Dashboard shows:**
- Total codes created
- Active codes count
- Total uses across all codes
- Unique users who used codes
- Total discount value given

**Charts/visualizations:**
- Discount evolution over time
- Usage by tier
- Most popular codes
- Revenue impact

## Using the Dashboard

### Creating a Promo Code

```dart
// The admin fills the form and clicks "Create"
// Dashboard calls:
await supabase.rpc('admin_create_promo_code', params: {
  'p_code': 'BLACK25',
  'p_description': 'Black Friday 25% Off',
  'p_code_type': 'discount_percentage',
  'p_discount_percent': 25,
  'p_discount_amount_cents': null,
  'p_valid_from': '2024-11-01',
  'p_valid_until': '2024-11-30',
  'p_max_uses': 500,
  'p_max_uses_per_user': 1,
  'p_applicable_tiers': ['gold', 'platinum'],
  'p_campaign_name': 'Black Friday 2024',
});
```

### Viewing Analytics

```dart
// Dashboard fetches stats:
final stats = await supabase.rpc('admin_get_promo_usage_stats', params: {
  'p_promo_code_id': codeId,
});

// Returns:
{
  total_uses: 150,
  unique_users: 143,
  total_discount_cents: 49500,
  last_used: "2024-01-15T10:30:00Z"
}
```

### Disabling a Code

```dart
// Admin clicks disable
await supabase
  .from('promo_codes')
  .update({'is_active': false})
  .eq('id', codeId);
```

## Customization

### Change Tab Order

In `admin_promo_code_dashboard.dart`, modify `_tabs`:

```dart
final _tabs = [
  Tab(text: 'Analytics'),  // Move analytics to first
  Tab(text: 'Active Codes'),
  Tab(text: 'Create Code'),
];
```

### Modify Column Widths

In `_buildActiveCodesTab()`:

```dart
DataColumn(label: SizedBox(width: 150, child: Text('Code'))),
DataColumn(label: SizedBox(width: 100, child: Text('Uses'))),
```

### Add More Statistics

In `_buildAnalyticsTab()`, add new cards:

```dart
_buildStatCard(
  title: 'Average Discount',
  value: '₪${(totalDiscount / totalUses).toStringAsFixed(2)}',
  icon: Icons.trending_down,
)
```

## Testing the Admin Dashboard

### 1. Start Admin App

```bash
cd matchme_admin
flutter run
```

### 2. Navigate to Promo Codes

- Click menu → Promo Codes

### 3. Create Test Code

- Tab 1: Click "Create Code"
- Fill form with test data
- Click "Create"
- Should see success message

### 4. Verify in Database

```sql
SELECT * FROM promo_codes WHERE code = 'TESTCODE';
```

### 5. Test Active Codes Tab

- Tab 2: Should show your new code
- Click edit icon
- Update values
- Save changes

### 6. Check Analytics

- Tab 3: Should show updated stats
- Use the code in the main app
- Refresh analytics to see updated numbers

## Error Handling

Dashboard automatically handles:
- Invalid form input (shows validation errors)
- Database errors (shows toast messages)
- Network issues (shows retry option)
- Permission errors (shows admin-only message)

Custom error scenarios:

```dart
// If user tries to create duplicate code
// Error: "Code already exists"

// If discount value is invalid
// Error: "Invalid discount value for this type"

// If date range is invalid
// Error: "Valid until date must be after valid from"
```

## Security Notes

✅ **Built-in protections:**
- RLS policies ensure only admins can manage codes
- API calls use admin functions (not accessible to regular users)
- No sensitive data exposed in UI (no user PII)
- Audit logging on all CRUD operations

## Best Practices

1. **Always set usage limits** - Prevent unlimited discounts
2. **Set expiration dates** - Old codes keep accruing uses
3. **Monitor analytics** - Watch for suspicious patterns
4. **Review top codes** - See what discounts users actually use
5. **Plan campaigns** - Use campaign names for organization
6. **Test before enabling** - Create with low limits first

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Dashboard not loading | Check Supabase connection in main.dart |
| RPC functions fail | Verify admin user role (check `auth.users` table) |
| Form validation errors | Check database constraints match form logic |
| Slow analytics loading | Add indexes: `CREATE INDEX idx_usage_code ON promo_code_usages(promo_code_id)` |
| Can't edit codes | Ensure user has admin role in MatchMe database |

## Performance Optimization

For large numbers of codes, add pagination:

```dart
// In _buildActiveCodesTab()
const pageSize = 10;
int currentPage = 0;

// Add pagination buttons
Row(
  mainAxisAlignment: MainAxisAlignment.center,
  children: [
    IconButton(icon: Icon(Icons.prev_page), onPressed: _previousPage),
    Text('Page ${currentPage + 1}'),
    IconButton(icon: Icon(Icons.next_page), onPressed: _nextPage),
  ],
)
```

## Files Reference

- **Screen**: `matchme_admin/lib/screens/promo_code_dashboard.dart`
- **Main app entry**: `matchme_admin/lib/main.dart`
- **Backend functions**: Created by `create_promo_code_functions.sql`
- **Database schema**: Created by `create_promo_codes_table.sql`

## Next Steps

1. ✅ Database schema (already created)
2. ✅ Backend RPC functions (already created)
3. ✅ Admin dashboard screen (already created)
4. ⏳ **Integrate into admin app** (YOU ARE HERE)
5. ⏳ Test dashboard functionality
6. ⏳ Deploy admin app

## Common Questions

**Q: Can I manage codes without the dashboard?**
A: Yes, use SQL directly, but the dashboard is much easier and safer.

**Q: What happens if I disable a code while users are checking out?**
A: Existing validations succeed, but new validations will fail. Redemptions already initiated will complete.

**Q: How do I delete codes?**
A: You can't (by design). Disable them instead to keep audit trail. Disabling sets `is_active = false`.

**Q: Can I edit a code's discount value?**
A: Yes, but only before any are redeemed. After redemptions, edits don't affect historical uses.

---

**Ready to deploy?** See DEPLOYMENT_CHECKLIST.md for production readiness steps.
