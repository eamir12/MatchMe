# Admin Interface - Security Approach

## 🔒 Security Decision

**For security purposes, admin functionality is NOT included in the MatchMe user-facing app.**

This separation ensures:
- No risk of privilege escalation attacks
- Reduced attack surface for user-facing app
- Clear separation of concerns
- Easier security auditing
- Compliance with security best practices

## 📋 Current Admin Access Methods

### Option 1: Supabase Dashboard (Recommended for Now)

**Pros:**
- Already available
- No additional development needed
- Full database access
- Built-in validation
- Audit logging

**How to Use:**
1. Login to Supabase Dashboard
2. Navigate to Table Editor → `app_config`
3. Edit `config_value` column directly
4. Changes propagate to app within 5 minutes (cache TTL)

**Example Workflow:**
```sql
-- View all configs
SELECT * FROM app_config ORDER BY category, config_key;

-- Update a config
UPDATE app_config 
SET config_value = '30'
WHERE config_key = 'gps.battery_low_threshold_percent';

-- Find user-configurable settings
SELECT * FROM app_config WHERE is_user_configurable = true;
```

### Option 2: SQL Editor

**For bulk updates or complex queries:**
```sql
-- Update multiple GPS settings
UPDATE app_config 
SET config_value = '20'
WHERE category = 'gps' 
  AND config_key LIKE '%threshold%';

-- Test queries available in test_app_config.sql
```

## 🚀 Future: Dedicated Admin Interface

### Recommended Approach

Build a **separate web application** for admin use:

**Technology Options:**
1. **Flutter Web** - Reuse existing codebase knowledge
2. **Next.js** - Modern React framework
3. **Svelte/SvelteKit** - Lightweight alternative
4. **Admin panel framework** - Retool, Forest Admin, etc.

### Suggested Architecture

```
┌─────────────────────────────────────┐
│  MatchMe User App                    │
│  (Flutter Mobile/Web)                │
│  - Read-only config access          │
│  - No admin features                │
└─────────────────────────────────────┘
              ↓
┌─────────────────────────────────────┐
│  Supabase Backend                    │
│  - app_config table                 │
│  - RLS: Read all, Write admins only │
└─────────────────────────────────────┘
              ↓
┌─────────────────────────────────────┐
│  Admin Web App                       │
│  (admin.matchme.com)                │
│  - Full CRUD on app_config          │
│  - User management                  │
│  - Analytics dashboard              │
│  - Admin-only authentication        │
└─────────────────────────────────────┘
```

### Features for Admin Interface

**Phase 1: Config Management**
- [ ] Browse all configs by category
- [ ] Search and filter
- [ ] Edit with validation (min/max, allowed_values)
- [ ] Real-time updates
- [ ] Change history/audit log

**Phase 2: User Management**
- [ ] View all users
- [ ] Grant/revoke admin privileges
- [ ] Ban/unban users
- [ ] View user activity

**Phase 3: Analytics**
- [ ] User growth metrics
- [ ] Match statistics
- [ ] GPS usage patterns
- [ ] Performance monitoring

**Phase 4: Advanced**
- [ ] A/B testing configs
- [ ] Scheduled config changes
- [ ] Config presets/templates
- [ ] Bulk import/export

### Security Considerations

**Authentication:**
- Admin-only login (separate from user auth)
- Multi-factor authentication required
- IP whitelist for admin access
- Session timeout (30 minutes)

**Authorization:**
- Role-based access control (RBAC)
- Audit logging for all admin actions
- Require confirmation for critical changes
- Automatic logout after inactivity

**Deployment:**
- Host on admin subdomain (admin.matchme.com)
- Behind VPN or IP whitelist
- HTTPS only
- Rate limiting
- DDoS protection

**API Access:**
- Use Supabase service role key (server-side only)
- Never expose service role key to client
- Use server-side API routes for all writes
- Validate all inputs server-side

### Example: Next.js Admin App Structure

```
admin-panel/
├── app/
│   ├── api/                    # Server-side API routes
│   │   ├── config/
│   │   │   ├── route.ts       # GET /api/config
│   │   │   └── [key]/route.ts # PUT /api/config/:key
│   │   └── users/
│   │       └── route.ts       # Admin user management
│   ├── login/
│   │   └── page.tsx           # Admin login
│   ├── dashboard/
│   │   └── page.tsx           # Admin dashboard
│   └── config/
│       └── page.tsx           # Config management UI
├── lib/
│   ├── supabase-admin.ts      # Server-side client (service role)
│   └── auth.ts                # Admin authentication
└── middleware.ts              # Auth middleware
```

### Example: Admin API Route (Next.js)

```typescript
// app/api/config/[key]/route.ts
import { createClient } from '@supabase/supabase-js';
import { validateAdmin } from '@/lib/auth';

export async function PUT(
  request: Request,
  { params }: { params: { key: string } }
) {
  // Verify admin authentication
  const admin = await validateAdmin(request);
  if (!admin) {
    return new Response('Unauthorized', { status: 401 });
  }

  const { value } = await request.json();
  
  // Use service role client (server-side only)
  const supabase = createClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.SUPABASE_SERVICE_ROLE_KEY!, // Never expose to client
  );

  const { error } = await supabase
    .from('app_config')
    .update({ config_value: value })
    .eq('config_key', params.key);

  if (error) {
    return new Response(error.message, { status: 500 });
  }

  // Log admin action
  await supabase.from('admin_audit_log').insert({
    admin_id: admin.id,
    action: 'update_config',
    details: { key: params.key, value },
  });

  return new Response(JSON.stringify({ success: true }));
}
```

## 📝 Next Steps

1. **Short Term:** Use Supabase Dashboard for admin tasks
2. **Medium Term:** Plan admin interface requirements
3. **Long Term:** Build dedicated admin web app

## 🔗 Related Documentation

- [APP_CONFIG_README.md](APP_CONFIG_README.md) - Complete config system guide
- [DEPLOYMENT_CHECKLIST.md](DEPLOYMENT_CHECKLIST.md) - Deployment steps
- [test_app_config.sql](test_app_config.sql) - SQL test queries
