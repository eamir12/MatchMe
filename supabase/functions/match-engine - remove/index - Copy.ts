// supabase/functions/match-engine/index.ts
import { serve } from 'std/http/server.ts';
import { createClient } from 'supabase';
import { Client } from 'upstash_redis';

// --- TYPE DEFINITIONS ---
interface UserProfileData { // Represents data from user_profiles table
    intent_type: string;
    profile_data?: { // profile_data is nullable JSONB
        sub_intent?: string[]; // Make sub_intent optional
        interests?: { [key: string]: string[] }; // Assuming interests structure
        // Add other fields from profile_data if needed
    };
}
interface MatchUser { // Simplified user data from 'users' table
    id: string;
    account_status: string;
    system_visibility_status: string;
    active_modes: string[];
    match_radius_default: number;
}
interface WebhookPayload { /* ... unchanged ... */
    userId: string; latitude: number; longitude: number; speed: number; heading: number;
}
interface RedisUserData { // Data stored in Redis Hash
    id: string; lat: number; lon: number; speed: number; heading: number;
    radius: number; modes: string[];
    subIntents: { [key: string]: string[] }; // e.g., {"Romantic": ["Long-term"]}
}
interface RelationshipCheckResult { /* ... unchanged ... */
    blocked_users: string[]; matched_users: string[];
}

// --- CONSTANTS ---
const USER_LOCATION_TTL = 30;
const MATCH_SCORE_THRESHOLD = 0.5;
const METERS_IN_FOOT = 0.3048;

// --- INITIALIZE CLIENTS ---
const redis = new Client({ /* ... unchanged ... */
    url: Deno.env.get('UPSTASH_REDIS_URL')!, token: Deno.env.get('UPSTASH_REDIS_TOKEN')!,
});

// --- HELPER FUNCTIONS ---
function calculateJaccardSimilarity(a: string[], b: string[]): number { /* ... unchanged ... */
    if (!a || !b || a.length === 0 || b.length === 0) return 0.0;
    const setA = new Set(a); const setB = new Set(b);
    const intersection = new Set([...setA].filter(x => setB.has(x)));
    const union = new Set([...setA, ...setB]);
    return intersection.size === 0 ? 0.0 : intersection.size / union.size;
}
// Updated to accept full RedisUserData for comparison
function calculateCompatibilityScore(userA: MatchUser, userB: RedisUserData): number {
    console.log(`Calculating score between ${userA.id} and ${userB.id}`);
    // Placeholder: Fetch full profiles if needed, or use data from RedisUserData/MatchUser
    // Example using Jaccard on main modes (needs refinement based on actual profile data)
    const modeScore = calculateJaccardSimilarity(userA.active_modes, userB.modes);
    // Add logic for interests, language etc.
    let score = 0.6 * modeScore + 0.4; // Weighted example
    return Math.min(1.0, score); // Cap score at 1.0
}


// --- MAIN SERVER LOGIC ---
serve(async (req) => {
    // --- Request Validation (unchanged) ---
    if (req.method !== 'POST') return new Response('Method Not Allowed', { status: 405 });
    let payload: WebhookPayload;
    try { payload = await req.json(); } catch (e) { return new Response('Bad Request: Invalid JSON', { status: 400 }); }
    const { userId, latitude, longitude, speed, heading } = payload;
    if (!userId || latitude === undefined || longitude === undefined) return new Response('Bad Request: Missing fields', { status: 400 });

    const supabase = createClient( /* ... unchanged ... */
        Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } }
    );

    // --- Fetch User A's Data AND Profile Data ---
    const { data: userAData, error: userError } = await supabase
      .from('users')
      .select(`
          id, account_status, system_visibility_status, active_modes, match_radius_default,
          user_profiles ( intent_type, profile_data )
      `) // Fetch profiles concurrently
      .eq('id', userId)
      .single();

    if (userError || !userAData) {
        console.error('Error fetching user A or user not found:', userError?.message || 'Not Found');
        return new Response(`User ${userId} not found or error`, { status: 404 });
    }

    // Cast and process fetched data
    const userA: MatchUser = userAData as MatchUser; // Cast main user data
    const userAProfiles: UserProfileData[] = (userAData.user_profiles || []) as UserProfileData[]; // Extract profiles

    // --- Process User A's Sub-Intents for Caching ---
    const userASubIntents: { [key: string]: string[] } = {};
    for (const profile of userAProfiles) {
        if (profile.profile_data?.sub_intent && profile.profile_data.sub_intent.length > 0) {
            userASubIntents[profile.intent_type] = profile.profile_data.sub_intent;
        } else {
             userASubIntents[profile.intent_type] = []; // Ensure key exists even if empty
        }
    }
    // --- End Sub-Intent Processing ---


    // --- Check Visibility (unchanged) ---
    if (userA.account_status !== 'active' || userA.system_visibility_status !== 'visible' || userA.active_modes.length === 0) {
        await redis.pipeline().zrem('user_locations', userId).hdel('user_data', userId).exec(); // Ensure cleanup
        console.log(`User ${userId} is invisible.`);
        return new Response(JSON.stringify({ status: 'invisible', matches_found: 0 }), { headers: { 'Content-Type': 'application/json' } });
    }

    // --- Update Redis with Sub-Intents ---
    const userARadiusInMeters = userA.match_radius_default * METERS_IN_FOOT;
    const redisData: RedisUserData = {
        id: userA.id, lat: latitude, lon: longitude, speed, heading,
        radius: userARadiusInMeters, modes: userA.active_modes,
        subIntents: userASubIntents, // Add processed sub-intents
    };

    const p = redis.pipeline();
    p.geoadd('user_locations', longitude, latitude, userId);
    p.hset('user_data', { [userId]: JSON.stringify(redisData) }); // Store full data including sub-intents
    // Expire the hash entry after TTL
    p.expire(userId, USER_LOCATION_TTL); // Expire the hash field directly using userId as key
    await p.exec();
    // --- End Redis Update ---

    // --- Find Nearby Users (unchanged) ---
    const nearbyUsers = await redis.geosearch( 'user_locations', { longitude, latitude }, { radius: userARadiusInMeters, unit: 'm' } );
    const nearbyUserIds = nearbyUsers.filter((id): id is string => typeof id === 'string' && id !== userId);
    if (nearbyUserIds.length === 0) { return new Response(JSON.stringify({ status: 'visible', matches_found: 0 }), { headers: { 'Content-Type': 'application/json' } }); }

    // --- Fetch Nearby Users' Data from Redis (unchanged) ---
    const nearbyUserDataStrings = await redis.hmget('user_data', ...nearbyUserIds);
    const nearbyUsersData: RedisUserData[] = nearbyUserDataStrings
        .filter((data): data is string => data !== null && data !== undefined)
        .map(data => JSON.parse(data));

    // --- Check Existing Relationships (unchanged) ---
    let existingRelationships: RelationshipCheckResult = { blocked_users: [], matched_users: [] };
     if (nearbyUserIds.length > 0) { const { data: relData, error: relError } = await supabase.rpc('get_relationships_with_user', { user_id_input: userId, candidate_ids: nearbyUserIds }); if (relError) { console.error('Error checking relationships:', relError); } else if (relData) { existingRelationships = relData as RelationshipCheckResult; } }
    const blockedSet = new Set(existingRelationships.blocked_users || []);
    const matchedSet = new Set(existingRelationships.matched_users || []); // Contains combined keys like userA-userB-Intent

    let newMatchCount = 0;
    const matchesToCreate = [];

    // --- The Matching Loop ---
    for (const userB of nearbyUsersData) {
        if (blockedSet.has(userB.id)) continue;

        // Mutual Radius Check (unchanged)
        const distanceToUserB = await redis.geodist('user_locations', userA.id, userB.id, 'm');
        if (distanceToUserB === null || distanceToUserB > userB.radius) continue;

        // Find Common Main Intents (unchanged)
        const commonMainIntents = userA.active_modes.filter(mode => userB.modes.includes(mode));
        if (commonMainIntents.length === 0) continue;

        const isCoMotion = false; // Placeholder

        // --- NEW: Sub-Intent Check Loop ---
        for (const mainIntent of commonMainIntents) {
            const matchKey = [userA.id, userB.id].sort().join('-') + `-${mainIntent}`;
            if (matchedSet.has(matchKey)) continue; // Skip if already matched on this intent

            // Get sub-intents for this mainIntent for both users
            const subsA = userASubIntents[mainIntent] || [];
            const subsB = userB.subIntents[mainIntent] || []; // Get from Redis data for user B

            // If BOTH users have specified sub-intents for this mode, check for overlap
            let subIntentOverlap = false;
            if (subsA.length > 0 && subsB.length > 0) {
                 subIntentOverlap = subsA.some(sub => subsB.includes(sub));
                 if (!subIntentOverlap) continue; // No sub-intent match, skip this main intent
            }
            // If one user has sub-intents but the other doesn't, is it a match? (Decision needed)
            // Current logic: If one list is empty, it doesn't block the match. Adjust if needed.
            // Example strict rule: if (subsA.length > 0 !== subsB.length > 0) continue; // Must both have OR both not have subs

            // --- Sub-Intents Match (or one/both didn't specify) ---

            // Calculate Final Score (only if sub-intents match if specified)
            const scoreA_for_B = calculateCompatibilityScore(userA, userB);
            const scoreB_for_A = scoreA_for_B; // Simplification: Assume symmetric for now

            if (scoreA_for_B >= MATCH_SCORE_THRESHOLD && scoreB_for_A >= MATCH_SCORE_THRESHOLD) {
                newMatchCount++;
                const user_a_id = userA.id < userB.id ? userA.id : userB.id;
                const user_b_id = userA.id < userB.id ? userB.id : userA.id;
                matchesToCreate.push({ user_a_id, user_b_id, matched_intent: mainIntent, match_type: isCoMotion ? 'co_motion' : 'proximity' });
                matchedSet.add(matchKey); // Add intent-specific key
                break; // Found match for this user on one intent, move to next user B
            }
        } // End sub-intent check loop
    } // End main user B loop

    // --- Batch Insert Matches (unchanged) ---
    if (matchesToCreate.length > 0) {
        console.log(`Attempting to insert ${matchesToCreate.length} new matches.`);
        const { error: insertError } = await supabase.from('matches').insert(matchesToCreate).select();
        if (insertError) { console.error('Error inserting new matches:', insertError); }
        else { console.log(`Successfully processed ${matchesToCreate.length} potential matches.`); }
    }

    // --- Return Success (unchanged) ---
    return new Response( JSON.stringify({ status: 'visible', matches_found: newMatchCount }), { headers: { 'Content-Type': 'application/json' } });
}); // End serve