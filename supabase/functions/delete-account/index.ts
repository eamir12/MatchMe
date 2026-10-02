// supabase/functions/delete-account/index.ts
import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { logEdgeFunctionInvocation } from "../_shared/edge_function_logger.ts";

// Helper function to decode JWT token and extract user ID
function decodeJWT(token: string): { userId: string; aal: string } | null {
  try {
    const parts = token.split('.');
    if (parts.length !== 3) {
      console.log('JWT does not have 3 parts');
      return null;
    }
    
    // Decode base64url payload
    const payload = parts[1].replace(/-/g, '+').replace(/_/g, '/');
    const decodedPayload = JSON.parse(atob(payload));
    
    console.log('Decoded JWT payload keys:', Object.keys(decodedPayload));
    console.log('User ID (sub):', decodedPayload.sub);
    
    return {
      userId: decodedPayload.sub,
      aal: typeof decodedPayload.aal === 'string' ? decodedPayload.aal : 'aal1',
    };
  } catch (error) {
    console.log('JWT decoding error:', error);
    return null;
  }
}

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

// Storage buckets that may hold objects under the user's folder
const USER_STORAGE_BUCKETS = [
  'profile-photos',
  'verification-photos',
  'event-uploads',
  'profile-edit-attachments',
  'sponsored-ad-images',
];

// Recursively delete everything under `folder` (e.g. "{userId}") in a bucket
async function deleteFolderContents(
  supabase: ReturnType<typeof createClient>,
  bucketName: string,
  folder: string,
) {
  let deleted = 0;
  const { data, error } = await supabase.storage.from(bucketName).list(folder, {
    limit: 1000,
    offset: 0,
    sortBy: { column: 'name', order: 'asc' },
  });
  if (error) throw error;
  if (!data || data.length === 0) return deleted;

  const filePaths: string[] = [];
  const subfolders: string[] = [];
  for (const obj of data) {
    const path = obj?.name ? `${folder}/${obj.name}` : '';
    if (!path) continue;
    // Storage list returns folders without file metadata (null metadata or
    // size 0 with no mimetype); everything else is a file to remove.
    const meta = obj.metadata as { size?: number; mimetype?: string } | null;
    const isFolder = meta === null
      || (typeof meta === 'object' && meta.size === 0 && !meta.mimetype);
    if (isFolder) subfolders.push(path);
    else filePaths.push(path);
  }

  if (filePaths.length > 0) {
    const { error: removeError } = await supabase.storage.from(bucketName).remove(filePaths);
    if (removeError) throw removeError;
    deleted += filePaths.length;
  }

  for (const sub of subfolders) {
    deleted += await deleteFolderContents(supabase, bucketName, sub);
  }

  return deleted;
}

async function deleteAllUserStorage(supabase: ReturnType<typeof createClient>, userId: string) {
  let deleted = 0;
  for (const bucket of USER_STORAGE_BUCKETS) {
    try {
      deleted += await deleteFolderContents(supabase, bucket, userId);
    } catch (error) {
      console.error(`Failed to delete folder ${userId} in bucket ${bucket}:`, error);
    }
  }
  return { deleted };
}

async function userHasVerifiedMfaFactor(
  supabase: ReturnType<typeof createClient>,
  userId: string,
  fallbackUser: unknown,
) {
  try {
    const adminMfa = (supabase.auth.admin as Record<string, unknown>)['mfa'] as Record<string, unknown> | undefined;
    const listFactors = adminMfa?.['listFactors'];
    if (typeof listFactors === 'function') {
      const response = await listFactors({ userId });
      const data = (response as { data?: { totp?: Array<{ status?: string }>; all?: Array<{ status?: string }> } }).data;
      const factors = [...(data?.totp ?? []), ...(data?.all ?? [])];
      if (factors.length > 0) {
        return factors.some((factor) => (factor?.status ?? '').toLowerCase() === 'verified');
      }
    }
  } catch (error) {
    console.error('Admin MFA factor lookup failed:', error);
  }

  const userFactors = (fallbackUser as { factors?: Array<{ status?: string }> } | null)?.factors ?? [];
  return userFactors.some((factor) => (factor?.status ?? '').toLowerCase() === 'verified');
}

// Build a PostgREST filter matching ANY of the given columns against userId:
//   or=(col1.eq.UID,col2.eq.UID)
function orMatcher(userId: string, ...columns: string[]): string {
  const inner = columns.map((c) => `${c}.eq.${userId}`).join(',');
  return `or=${encodeURIComponent(inner)}`;
}

// DELETE from a table via REST; returns true on success (2xx).
async function restDelete(
  restApiUrl: string,
  table: string,
  filter: string,
  headers: Record<string, string>,
): Promise<boolean> {
  const url = `${restApiUrl}/${table}?${filter}`;
  try {
    const res = await fetch(url, { method: 'DELETE', headers });
    if (res.status === 404) {
      console.log(`SKIP ${table} (table does not exist)`);
      return false;
    }
    if (!res.ok) {
      console.error(`Failed to delete ${table} (${filter}): ${res.status} ${await res.text()}`);
      return false;
    }
    console.log(`Deleted ${table} (${filter})`);
    return true;
  } catch (error) {
    console.error(`Error deleting ${table} (${filter}):`, error);
    return false;
  }
}

// Null out a column referencing the deleted user so FK constraints don't block.
async function restNullOut(
  restApiUrl: string,
  table: string,
  filter: string,
  column: string,
  headers: Record<string, string>,
) {
  const url = `${restApiUrl}/${table}?${filter}`;
  try {
    const res = await fetch(url, {
      method: 'PATCH',
      headers,
      body: JSON.stringify({ [column]: null }),
    });
    if (res.status === 404) {
      console.log(`SKIP ${table} (table does not exist)`);
      return;
    }
    if (!res.ok) {
      console.error(`Failed to null ${table}.${column} (${filter}): ${res.status} ${await res.text()}`);
      return;
    }
    console.log(`Nulled ${table}.${column} (${filter})`);
  } catch (error) {
    console.error(`Error nulling ${table}.${column} (${filter}):`, error);
  }
}

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  const requestId = crypto.randomUUID();
  const startedAt = Date.now();
  const functionName = "delete-account";
  let success = false;
  let httpStatus = 500;
  let errorType: string | null = null;
  let errorMessage: string | null = null;
  let userIdForLog: string | null = null;

  try {
    console.log('Delete account function called');
    
    // Get the authorization header
    const authHeader = req.headers.get('Authorization');
    console.log('Auth header present:', !!authHeader);
    
    if (!authHeader || !authHeader.startsWith('Bearer ')) {
      console.log('Missing or invalid auth header');
      httpStatus = 401;
      return new Response(JSON.stringify({ error: 'Unauthorized: missing Authorization header' }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 401,
      });
    }

    // Extract user ID from JWT token
    const token = authHeader.replace('Bearer ', '');
    console.log('Token extracted, length:', token.length);
    
    const decoded = decodeJWT(token);
    if (!decoded) {
      console.log('JWT decoding failed');
      httpStatus = 401;
      return new Response(JSON.stringify({ error: 'Invalid JWT token' }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 401,
      });
    }

    const userId = decoded.userId;
    const aal = decoded.aal;
    userIdForLog = userId;
    console.log('User ID extracted:', userId);

    // Create Supabase client with service role for admin operations
    const supabaseUrl = Deno.env.get('SUPABASE_URL') ?? '';
    const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');

    if (!serviceRoleKey) {
      httpStatus = 500;
      return new Response(JSON.stringify({ error: 'Server configuration error' }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 500,
      });
    }

    const supabase = createClient(supabaseUrl, serviceRoleKey);
    console.log('Created Supabase client with service role key');

    // Try using direct REST API calls to bypass client RLS issues
    const restApiUrl = `${supabaseUrl}/rest/v1`;
    const headers = {
      'Authorization': `Bearer ${serviceRoleKey}`,
      'apikey': serviceRoleKey,
      'Content-Type': 'application/json',
      'Prefer': 'return=minimal'
    };

    console.log('Using direct REST API calls to bypass RLS issues');

    // Verify the user exists (optional additional check)
    const { data: userData, error: userCheckError } = await supabase.auth.admin.getUserById(userId);
    if (userCheckError || !userData.user) {
      console.error('User verification failed:', userCheckError);
      // If user doesn't exist, return success since they're already "deleted"
      success = true;
      httpStatus = 200;
      return new Response(JSON.stringify({ 
        success: true, 
        message: 'User already deleted or does not exist',
        userId: userId
      }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 200, // Return 200 instead of 404 so client treats it as success
      });
    }
    const hasVerifiedMfaFactor = await userHasVerifiedMfaFactor(supabase, userId, userData.user);
    if (hasVerifiedMfaFactor && aal !== 'aal2') {
      httpStatus = 403;
      return new Response(JSON.stringify({
        error: 'MFA verification required',
        code: 'mfa_required',
      }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 403,
      });
    }

    console.log('Deleting account for user:', userId);

    // ---- Delete user data using direct REST API calls to bypass RLS ----
    // Order matters: children before parents (FK constraints). Every step is
    // individually resilient: missing tables / columns are logged, not fatal.

    // Storage: profile photos, verification photos, event uploads, attachments
    try {
      console.log('Deleting user storage objects...');
      const { deleted } = await deleteAllUserStorage(supabase, userId);
      console.log('Storage objects deleted:', deleted);
    } catch (storageError) {
      console.error('Failed to delete storage objects:', storageError);
    }

    // 1. Chat data (messages first - they reference matches)
    await restDelete(restApiUrl, 'chat_messages', orMatcher(userId, 'sender_id', 'recipient_id'), headers);
    await restDelete(restApiUrl, 'message_reactions', `user_id=eq.${userId}`, headers);
    await restDelete(restApiUrl, 'matches', orMatcher(userId, 'user1_id', 'user2_id'), headers);
    await restDelete(restApiUrl, 'chats', orMatcher(userId, 'user_id', 'other_user_id'), headers);
    await restDelete(restApiUrl, 'chat_rooms', `user_id=eq.${userId}`, headers);
    await restDelete(restApiUrl, 'unmatched_pairs', orMatcher(userId, 'user1_id', 'user2_id'), headers);
    await restDelete(restApiUrl, 'unmatched_pairs', `created_by=eq.${userId}`, headers);

    // 2. Ratings
    await restDelete(restApiUrl, 'match_ratings', orMatcher(userId, 'rater_id', 'ratee_id'), headers);
    await restDelete(restApiUrl, 'match_rating_prompts', `user_id=eq.${userId}`, headers);
    await restDelete(restApiUrl, 'pending_rating_prompts', orMatcher(userId, 'user_id', 'other_user_id'), headers);

    // 3. Events (after matches, since matches may reference event_id)
    //    Remove the user's attendance everywhere first. Then delete events
    //    the user created ONLY if no other user attends them; events other
    //    users still attend are KEPT (owner column set to null).
    await restDelete(restApiUrl, 'event_attendees', `user_id=eq.${userId}`, headers);
    await restDelete(restApiUrl, 'event_participants', `user_id=eq.${userId}`, headers);
    await restDelete(restApiUrl, 'event_parse_results', `user_id=eq.${userId}`, headers);

    // Find the events owner column (name varies between environments)
    let eventsOwnerCol: string | null = null;
    for (const col of ['created_by', 'owner_id', 'user_id']) {
      try {
        const res = await fetch(`${restApiUrl}/events?${col}=eq.${userId}&select=id`, { headers });
        if (res.ok) { eventsOwnerCol = col; break; }
      } catch (error) {
        console.error(`Error probing events.${col}:`, error);
      }
    }

    if (eventsOwnerCol) {
      let eventIds: string[] = [];
      try {
        const res = await fetch(
          `${restApiUrl}/events?${eventsOwnerCol}=eq.${userId}&select=id&limit=1000`,
          { headers },
        );
        if (res.ok) {
          const rows = await res.json() as Array<{ id: string }>;
          eventIds = rows.map((r) => r.id);
        }
      } catch (error) {
        console.error('Error listing user events:', error);
      }

      for (const eventId of eventIds) {
        let attendeeCount = 0;
        try {
          const countHeaders = { ...headers, Prefer: 'count=exact' };
          const res = await fetch(
            `${restApiUrl}/event_attendees?event_id=eq.${eventId}&select=id`,
            { headers: countHeaders },
          );
          attendeeCount = Number(res.headers.get('content-range')?.split('/')[1] ?? 0);
        } catch (error) {
          console.error(`Error counting attendees for event ${eventId}:`, error);
        }
        if (attendeeCount === 0) {
          await restDelete(restApiUrl, 'events', `id=eq.${eventId}`, headers);
        } else {
          console.log(`Keeping event ${eventId} (${attendeeCount} other attendee(s))`);
        }
      }

      // Null the owner on every remaining event owned by the user
      await restNullOut(restApiUrl, 'events', `${eventsOwnerCol}=eq.${userId}`, eventsOwnerCol, headers);
    } else {
      console.log('Could not determine events owner column; leaving events untouched');
    }
    await restDelete(restApiUrl, 'event_attendees', `user_id=eq.${userId}`, headers);
    await restDelete(restApiUrl, 'event_participants', `user_id=eq.${userId}`, headers);
    await restDelete(restApiUrl, 'event_parse_results', `user_id=eq.${userId}`, headers);

    // 4. Referrals / promotions
    await restDelete(restApiUrl, 'referrals', orMatcher(userId, 'referrer_id', 'referee_id'), headers);
    await restDelete(restApiUrl, 'promo_code_usages', `user_id=eq.${userId}`, headers);

    // 5. Profile / preferences
    await restDelete(restApiUrl, 'user_locations', `user_id=eq.${userId}`, headers);
    await restDelete(restApiUrl, 'offline_location_history', `user_id=eq.${userId}`, headers);
    await restDelete(restApiUrl, 'user_profiles', `user_id=eq.${userId}`, headers);
    await restDelete(restApiUrl, 'user_interests', `user_id=eq.${userId}`, headers);
    await restDelete(restApiUrl, 'user_intents', `user_id=eq.${userId}`, headers);
    await restDelete(restApiUrl, 'user_blocks', orMatcher(userId, 'user_id', 'blocked_user_id'), headers);
    await restDelete(restApiUrl, 'user_reports', orMatcher(userId, 'user_id', 'reported_user_id'), headers);
    await restDelete(restApiUrl, 'user_invisibility_rules', `user_id=eq.${userId}`, headers);
    await restDelete(restApiUrl, 'user_visibility_schedules', `user_id=eq.${userId}`, headers);
    await restDelete(restApiUrl, 'invisibility_rules', `user_id=eq.${userId}`, headers);

    // 6. Session / activity / notifications
    await restDelete(restApiUrl, 'user_activity', `user_id=eq.${userId}`, headers);
    await restDelete(restApiUrl, 'user_session', `user_id=eq.${userId}`, headers);
    await restDelete(restApiUrl, 'notification_queue', `user_id=eq.${userId}`, headers);
    await restDelete(restApiUrl, 'user_subscription_queue', `user_id=eq.${userId}`, headers);
    await restDelete(restApiUrl, 'admin_broadcast_deliveries', `user_id=eq.${userId}`, headers);
    await restDelete(restApiUrl, 'profile_edit_requests', `user_id=eq.${userId}`, headers);

    // 7. Ads
    await restDelete(restApiUrl, 'ad_impressions', `user_id=eq.${userId}`, headers);
    await restDelete(restApiUrl, 'ad_clicks', `user_id=eq.${userId}`, headers);
    await restDelete(restApiUrl, 'ad_reports', `user_id=eq.${userId}`, headers);
    await restDelete(restApiUrl, 'ad_revenue_events', `user_id=eq.${userId}`, headers);
    await restDelete(restApiUrl, 'ad_consent', `user_id=eq.${userId}`, headers);

    // 8. End-to-end encryption keys
    await restDelete(restApiUrl, 'user_chat_keys', `user_id=eq.${userId}`, headers);
    await restDelete(restApiUrl, 'user_chat_key_wrappers', `user_id=eq.${userId}`, headers);
    await restDelete(restApiUrl, 'user_chat_crk_wrappers', `user_id=eq.${userId}`, headers);

    // 9. Location sharing signals
    await restDelete(restApiUrl, 'location_share_signals', `sharer_id=eq.${userId}`, headers);

    // 10. Logs / fraud signals
    await restDelete(restApiUrl, 'edge_function_invocations', `user_id=eq.${userId}`, headers);
    await restDelete(restApiUrl, 'signup_fraud_signals', `user_id=eq.${userId}`, headers);

    // 11. Null out references TO this user from rows owned by admins/other users
    //     (these FK to auth.users without cascade, so they must be cleared
    //     before the auth user is deleted at the end)
    await restNullOut(restApiUrl, 'admin_broadcasts', `created_by=eq.${userId}`, 'created_by', headers);
    await restNullOut(restApiUrl, 'profile_edit_requests', `reviewed_by=eq.${userId}`, 'reviewed_by', headers);
    await restNullOut(restApiUrl, 'users', `verification_reviewer_id=eq.${userId}`, 'verification_reviewer_id', headers);

    // 12. Delete the public users row (children with ON DELETE CASCADE go with it)
    await restDelete(restApiUrl, 'users', `id=eq.${userId}`, headers);

    // 13. Finally, delete the user from Supabase Auth using admin API
    //     (also removes identities, sessions, MFA factors, passkeys)
    console.log('Deleting user from Supabase Auth...');
    const { error: authDeleteError } = await supabase.auth.admin.deleteUser(userId);

    if (authDeleteError) {
      console.error('Error deleting user from auth:', authDeleteError);
      // This is critical - if we can't delete from auth, the operation partially failed
      httpStatus = 500;
      return new Response(JSON.stringify({
        error: 'Failed to delete user from authentication system',
        details: authDeleteError.message
      }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 500,
      });
    } else {
      console.log('User deleted from Supabase Auth successfully');
    }

    console.log('Account deletion completed for user:', userId);

    success = true;
    httpStatus = 200;
    return new Response(JSON.stringify({
      success: true,
      message: 'Account deleted successfully'
    }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 200,
    });

  } catch (error) {
    console.error('Delete account error:', error);
    errorType = error instanceof Error ? error.name : "Error";
    errorMessage = error instanceof Error ? error.message : String(error);
    httpStatus = 500;
    return new Response(JSON.stringify({ error: errorMessage }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 500,
    });
  } finally {
    await logEdgeFunctionInvocation({
      requestId,
      functionName,
      durationMs: Date.now() - startedAt,
      success,
      httpStatus,
      errorType,
      errorMessage,
      userId: userIdForLog,
      aiUsed: false,
      meta: { method: req.method },
    });
  }
});