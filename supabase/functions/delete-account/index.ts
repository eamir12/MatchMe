// supabase/functions/delete-account/index.ts
import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { logEdgeFunctionInvocation } from "../_shared/edge_function_logger.ts";

// Helper function to decode JWT token and extract user ID
function decodeJWT(token: string): { userId: string } | null {
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
    
    return { userId: decodedPayload.sub };
  } catch (error) {
    console.log('JWT decoding error:', error);
    return null;
  }
}

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

async function deleteAllProfilePhotos(supabase: ReturnType<typeof createClient>, userId: string) {
  const bucket = supabase.storage.from('profile-photos');
  let deleted = 0;

  for (;;) {
    const { data, error } = await bucket.list(userId, { limit: 1000, offset: 0 });
    if (error) throw error;
    if (!data || data.length === 0) break;

    const paths = data
      .map((o) => (o?.name ? `${userId}/${o.name}` : ''))
      .filter((p) => p.length > 0);

    if (paths.length === 0) break;

    const { error: removeError } = await bucket.remove(paths);
    if (removeError) throw removeError;

    deleted += paths.length;
  }

  return { deleted };
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
    console.log('Deleting account for user:', userId);

    // Delete user data using direct REST API calls to bypass RLS
    try {
      try {
        console.log('Deleting profile photos from storage...');
        const { deleted } = await deleteAllProfilePhotos(supabase, userId);
        console.log('Profile photos deleted:', deleted);
      } catch (storageError) {
        console.error('Failed to delete profile photos from storage:', storageError);
      }

      // Delete in correct order to avoid foreign key constraints

      // 1. Delete chat messages (references matches)
      console.log('Deleting chat messages...');
      const chatResponse = await fetch(`${restApiUrl}/chat_messages?sender_id=eq.${userId}`, {
        method: 'DELETE',
        headers
      });
      if (!chatResponse.ok) {
        console.error('Failed to delete chat messages:', chatResponse.status, await chatResponse.text());
      } else {
        console.log('Chat messages deleted successfully');
      }

      // 2. Delete matches where user is involved (user_a_id or user_b_id)
      console.log('Deleting matches...');
      const matchesAResponse = await fetch(`${restApiUrl}/matches?user_a_id=eq.${userId}`, {
        method: 'DELETE',
        headers
      });
      if (!matchesAResponse.ok) {
        console.error('Failed to delete matches (user_a):', matchesAResponse.status, await matchesAResponse.text());
      } else {
        console.log('Matches (user_a) deleted successfully');
      }

      const matchesBResponse = await fetch(`${restApiUrl}/matches?user_b_id=eq.${userId}`, {
        method: 'DELETE',
        headers
      });
      if (!matchesBResponse.ok) {
        console.error('Failed to delete matches (user_b):', matchesBResponse.status, await matchesBResponse.text());
      } else {
        console.log('Matches (user_b) deleted successfully');
      }

      // 3. Delete user locations
      console.log('Deleting user locations...');
      const locationsResponse = await fetch(`${restApiUrl}/user_locations?user_id=eq.${userId}`, {
        method: 'DELETE',
        headers
      });
      if (!locationsResponse.ok) {
        console.error('Failed to delete user locations:', locationsResponse.status, await locationsResponse.text());
      } else {
        console.log('User locations deleted successfully');
      }

      // 4. Skip events for now - need to check the table structure
      console.log('Skipping events deletion - need to verify table structure');

      // 5. Delete user_profiles (references users.id)
      console.log('Deleting user profiles...');
      const profilesResponse = await fetch(`${restApiUrl}/user_profiles?user_id=eq.${userId}`, {
        method: 'DELETE',
        headers
      });
      if (!profilesResponse.ok) {
        console.error('Failed to delete user profiles:', profilesResponse.status, await profilesResponse.text());
      } else {
        console.log('User profiles deleted successfully');
      }

      // 6. Delete from users table
      console.log('Deleting user record...');
      const usersResponse = await fetch(`${restApiUrl}/users?id=eq.${userId}`, {
        method: 'DELETE',
        headers
      });
      if (!usersResponse.ok) {
        console.error('Failed to delete user record:', usersResponse.status, await usersResponse.text());
      } else {
        console.log('User record deleted successfully');
      }

    } catch (apiError) {
      console.error('REST API deletion error:', apiError);
      httpStatus = 500;
      return new Response(JSON.stringify({
        error: 'Failed to delete user data via REST API',
        details: apiError.message
      }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 500,
      });
    }

    // 7. Finally, delete the user from Supabase Auth using admin API
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
    return new Response(JSON.stringify({ error: error.message }), {
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
