import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

// Version: 2.0 - Added debug_log support
const VERSION = "2.0-debug";

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

interface LocationPayload {
  userId?: string
  latitude: number
  longitude: number
  speed?: number
  heading?: number
}

serve(async (req) => {
  // Handle CORS
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  try {
    console.log('🚀 Match-engine function invoked')
    // Read incoming Authorization header (may be "Bearer <token>")
    const authHeader = req.headers.get('Authorization') // can be null

    // Decide which key to use for Supabase client:
    // - If an Authorization header was provided, create the client with the anon key and forward the header.
    //   This causes Supabase to act as the authenticated role (assuming the token is valid).
    // - If no Authorization header and a service role key is present in env, fall back to using that (trusted server operations).
    //   WARNING: service role key must never be exposed to clients.
    const supabaseUrl = Deno.env.get('SUPABASE_URL') ?? ''
    const anonKey = Deno.env.get('SUPABASE_ANON_KEY') ?? ''
    const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') // may be undefined

    console.log('Environment check:', {
      hasUrl: !!supabaseUrl,
      hasAnonKey: !!anonKey,
      hasServiceKey: !!serviceRoleKey,
      hasAuthHeader: !!authHeader
    })

    // Create service role client for all database operations
    if (!serviceRoleKey) {
      console.error('CRITICAL: Service role key not found in environment')
      return new Response(JSON.stringify({ error: 'Server configuration error' }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 500,
      })
    }
    const serviceClient = createClient(supabaseUrl, serviceRoleKey)
    
    let usingServiceRole = false
    
    // If no auth header, reject (we require authentication)
    if (!authHeader || !authHeader.startsWith('Bearer ')) {
      console.warn('No valid Authorization header found')
      return new Response(JSON.stringify({ error: 'Unauthorized: missing Authorization header' }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 401,
      })
    }

    const body = await req.json().catch(() => null)
    if (!body) {
      return new Response(JSON.stringify({ error: 'Invalid JSON body' }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 400,
      })
    }

    const { userId: payloadUserId, latitude, longitude, speed, heading }: LocationPayload = body

    // Determine the user id we should use for operations.
    // - If using service role (trusted), we can accept the userId from the payload (use with caution).
    // - If using forwarded Authorization token, derive the user id from the token to prevent spoofing.
    let userId: string | undefined = undefined

    if (usingServiceRole) {
      if (!payloadUserId) {
        return new Response(JSON.stringify({ error: 'Missing userId in request body' }), {
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
          status: 400,
        })
      }
      userId = payloadUserId
    } else {
      // Verify the JWT using service client (which can properly verify tokens)
      console.log('Verifying JWT token...')
      const {
        data: { user },
        error: authGetUserError,
      } = await serviceClient.auth.getUser(authHeader.replace('Bearer ', ''))

      if (authGetUserError || !user) {
        console.error('Unable to get user from token:', authGetUserError)
        console.error('Token prefix:', authHeader.substring(0, 20))
        return new Response(JSON.stringify({ error: 'Unauthorized: invalid token' }), {
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
          status: 401,
        })
      }

      console.log('JWT verified successfully for user:', user.id)
      userId = user.id

      // If caller included a userId in the payload, ensure it matches the authenticated user.
      if (payloadUserId && payloadUserId !== userId) {
        console.warn('Payload userId does not match authenticated user; rejecting request.')
        return new Response(JSON.stringify({ error: 'Forbidden: userId mismatch' }), {
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
          status: 403,
        })
      }
    }

    // Validate coordinates
    if (
      typeof latitude !== 'number' ||
      typeof longitude !== 'number' ||
      Number.isNaN(latitude) ||
      Number.isNaN(longitude)
    ) {
      return new Response(JSON.stringify({ error: 'Invalid latitude/longitude' }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 400,
      })
    }

    // Update user's location (upsert)
    console.log(`Updating location for user ${userId}: lat=${latitude}, lon=${longitude}`)
    const { error: locationError } = await serviceClient
      .from('user_locations')
      .upsert({
        user_id: userId,
        latitude,
        longitude,
        speed,
        heading,
        updated_at: new Date().toISOString(),
      })

    if (locationError) {
      console.error('Error updating location:', locationError)
      // If it's a permission error (42501), give a helpful message to logs; client gets generic 500
      return new Response(JSON.stringify({ error: 'Error updating location' }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 500,
      })
    }

    console.log(`Location updated successfully for user ${userId}`)

    // Get current user's profile data (this shows how to use the authenticated userId)
    const { data: userData, error: userError } = await serviceClient
      .from('users')
      .select('active_modes, match_radius_default, user_visibility_setting, system_visibility_status')
      .eq('id', userId)
      .single()

    if (userError || !userData) {
      console.error('Error fetching user data for', userId, ':', userError)
      console.error('Error fetching user data:', userError)
      return new Response(JSON.stringify({ error: 'User not found' }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 404,
      })
    }

    // Compute true visibility (online + user setting + system status)
    const { data: userActivityRows } = await serviceClient
      .from('user_activity')
      .select('is_online')
      .eq('user_id', userId)
      .limit(1)
    const isOnline = userActivityRows && userActivityRows.length > 0 ? userActivityRows[0].is_online : false
    const systemVisibility = userData.system_visibility_status || 'visible'
    const isTrulyVisible = !!isOnline && !!userData.user_visibility_setting && systemVisibility === 'visible'
    if (!isTrulyVisible) {
      console.log(`User ${userId} is not truly visible (online:${isOnline}, setting:${userData.user_visibility_setting}, system:${systemVisibility}), skipping matching`)
      return new Response(
        JSON.stringify({ message: 'User is not visible', matches_created: 0 }),
        {
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
          status: 200,
        }
      )
    }

    const userIntents = userData.active_modes || []
    const userRadius = userData.match_radius_default || 50

    console.log(`👤 Current user ${userId}:`)
    console.log(`   Intents: ${JSON.stringify(userIntents)}`)
    console.log(`   Radius: ${userRadius}m`)
    console.log(`   Visible: ${isTrulyVisible}`)

    // Get user's interests
    const { data: userProfiles, error: profilesError } = await serviceClient
      .from('user_profiles')
      .select('profile_data')
      .eq('user_id', userId)

    if (profilesError) {
      console.error('Error fetching user profiles:', profilesError)
    }

    console.log(`   Found ${userProfiles?.length || 0} profiles for current user`)

    let userInterests: { [key: string]: string[] } = {}
    if (userProfiles) {
      for (const profile of userProfiles) {
        const profileData = (profile as any).profile_data
        if (profileData?.interests) {
          Object.assign(userInterests, profileData.interests)
        }
      }
    }

    console.log(`   Interest categories: ${Object.keys(userInterests).join(', ')}`)
    console.log(`   Total interests across categories: ${Object.values(userInterests).flat().length}`)

    // Find nearby users via RPC.
    // Note: the role executing this RPC must have permission to read user_locations OR the RPC must be SECURITY DEFINER.
    const { data: nearbyUsers, error: nearbyError } = await serviceClient
      .rpc('find_nearby_users', {
        current_user_id: userId,
        current_lat: latitude,
        current_lng: longitude,
        radius_km: (userRadius || 50) / 1000, // Convert meters to km
      })

    if (nearbyError) {
      console.error('Error finding nearby users:', nearbyError)
      return new Response(JSON.stringify({ error: 'Error finding nearby users' }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 500,
      })
    }

    const matchesCreated: any[] = []
    const debugLog: string[] = []
    
    debugLog.push(`🔍 Found ${nearbyUsers?.length || 0} nearby users to check for matching`)
    console.log(`🔍 Found ${nearbyUsers?.length || 0} nearby users to check for matching`)

    for (const nearbyUser of nearbyUsers || []) {
      const otherUserId = (nearbyUser as any).user_id
      debugLog.push(`\n👤 Checking user ${otherUserId} (distance: ${nearbyUser.distance_km}km)`)
      console.log(`\n👤 Checking potential match with user ${otherUserId}`)
      console.log(`   Distance: ${nearbyUser.distance_km}km`)

      // Check if match already exists (find any match involving both users)
      const { data: existingMatch, error: existingMatchError } = await serviceClient
        .from('matches')
        .select('id')
        .or(
          `and(user1_id.eq.${userId},user2_id.eq.${otherUserId}),and(user1_id.eq.${otherUserId},user2_id.eq.${userId})`
        )
        .limit(1)

      if (existingMatchError) {
        console.error('Error checking existing match:', existingMatchError)
        continue
      }

      if (existingMatch && existingMatch.length > 0) {
        debugLog.push(`   ⏭️  Match already exists, skipping`)
        console.log(`   ⏭️  Match already exists, skipping`)
        continue // Match already exists
      }
      debugLog.push(`   ✅ No existing match found`)
      console.log(`   ✅ No existing match found`)

      // Get other user's intents and visibility settings
      const { data: otherUserData, error: otherUserError } = await serviceClient
        .from('users')
        .select('active_modes, user_visibility_setting, system_visibility_status')
        .eq('id', otherUserId)
        .single()

      if (otherUserError || !otherUserData) continue

      // Check other user's online status
      const { data: otherUserActivityRows } = await serviceClient
        .from('user_activity')
        .select('is_online')
        .eq('user_id', otherUserId)
        .limit(1)
      const otherIsOnline = otherUserActivityRows && otherUserActivityRows.length > 0 ? otherUserActivityRows[0].is_online : false
      const otherSystemVisibility = otherUserData.system_visibility_status || 'visible'
      const otherIsTrulyVisible = !!otherIsOnline && !!otherUserData.user_visibility_setting && otherSystemVisibility === 'visible'

      debugLog.push(`   Visibility: ${otherIsTrulyVisible}, Intents: ${JSON.stringify(otherUserData.active_modes)}`)
      console.log(`   Other user visibility: ${otherIsTrulyVisible}`)
      console.log(`   Other user intents: ${JSON.stringify(otherUserData.active_modes)}`)
      
      // Skip if other user is not truly visible
      if (!otherIsTrulyVisible) {
        debugLog.push(`   ⏭️  Not visible, skipping`)
        console.log(`   ⏭️  Other user is not visible, skipping`)
        continue
      }

      const otherUserIntents = otherUserData.active_modes || []

      // Check shared intents
      const sharedIntents = userIntents.filter((intent: string) => otherUserIntents.includes(intent))
      debugLog.push(`   Shared intents: ${JSON.stringify(sharedIntents)}`)
      console.log(`   Current user intents: ${JSON.stringify(userIntents)}`)
      console.log(`   Shared intents: ${JSON.stringify(sharedIntents)}`)
      if (sharedIntents.length === 0) {
        debugLog.push(`   ⏭️  No shared intents, skipping`)
        console.log(`   ⏭️  No shared intents, skipping`)
        continue
      }

      // Get other user's interests
      const { data: otherUserProfiles, error: otherProfilesError } = await serviceClient
        .from('user_profiles')
        .select('profile_data')
        .eq('user_id', otherUserId)

      if (otherProfilesError) continue

      console.log(`   Found ${otherUserProfiles?.length || 0} profiles for other user`)
      
      let otherUserInterests: { [key: string]: string[] } = {}
      if (otherUserProfiles) {
        for (const profile of otherUserProfiles) {
          const profileData = (profile as any).profile_data
          if (profileData?.interests) {
            Object.assign(otherUserInterests, profileData.interests)
          }
        }
      }

      debugLog.push(`   Current interests: ${Object.keys(userInterests).length} categories, Other interests: ${Object.keys(otherUserInterests).length} categories`)
      console.log(`   Current user interest categories: ${Object.keys(userInterests).length}`)
      console.log(`   Other user interest categories: ${Object.keys(otherUserInterests).length}`)

      // Check shared interests
      let hasSharedInterest = false
      for (const category of Object.keys(userInterests)) {
        const userInterestList = userInterests[category] || []
        const otherInterestList = otherUserInterests[category] || []
        debugLog.push(`   Category "${category}": current=${userInterestList.length}, other=${otherInterestList.length}`)
        console.log(`   Checking category "${category}": current=${userInterestList.length}, other=${otherInterestList.length}`)
        
        if (userInterestList.some((interest: string) => otherInterestList.includes(interest))) {
          hasSharedInterest = true
          debugLog.push(`   ✅ SHARED INTEREST FOUND in "${category}"!`)
          console.log(`   ✅ SHARED INTEREST FOUND in category "${category}"!`)
          break
        }
      }

      debugLog.push(`   hasSharedInterest = ${hasSharedInterest}`)
      console.log(`   hasSharedInterest = ${hasSharedInterest}`)

      if (hasSharedInterest) {
        debugLog.push(`   🎉 Creating match!`)
        console.log(`   🎉 Creating match!`)
        // Create match - ensure user1_id < user2_id for database constraint
        const [userA, userB] = userId < otherUserId ? [userId, otherUserId] : [otherUserId, userId];
        
        const { data: newMatch, error: matchError } = await serviceClient
          .from('matches')
          .insert({
            user1_id: userA,
            user2_id: userB,
            matched_intent: sharedIntents.join(', '), // Store all shared intents
            match_type: 'proximity',
            created_at: new Date().toISOString(),
          })
          .select()
          .single()

        if (!matchError && newMatch) {
          debugLog.push(`   ✅ Match created! ID: ${newMatch.id}`)
          console.log(`   ✅ Match created successfully! ID: ${newMatch.id}`)
          matchesCreated.push(newMatch)
        } else if (matchError) {
          debugLog.push(`   ❌ Match error: ${JSON.stringify(matchError)}`)
          console.error(`   ❌ Match creation error:`, matchError)
        }
      } else {
        debugLog.push(`   ⏭️  No shared interests, skipping`)
        console.log(`   ⏭️  No shared interests found, skipping`)
      }
    }

    return new Response(
      JSON.stringify({
        success: true,
        matches_created: matchesCreated.length,
        matches: matchesCreated,
        debug_log: debugLog,
        user_id: userId,
        nearby_users_found: nearbyUsers?.length || 0,
        version: VERSION,
      }),
      {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      }
    )
  } catch (error) {
    console.error('Error in match-engine:', error)
    return new Response(JSON.stringify({ error: 'Internal server error' }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 500,
    })
  }
})