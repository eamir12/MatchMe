// supabase/functions/cron-jobs/index.ts
import { serve } from 'std/http/server.ts';
import { createClient } from 'supabase';
import { RRule } from 'rrule-deno';

// Initialize Supabase Admin Client
const supabase = createClient(
  Deno.env.get('SUPABASE_URL')!,
  Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  { auth: { persistSession: false } }
);

/**
 * Task 1: Enforces user-defined invisibility schedules.
 */
async function handleInvisibilitySchedules() {
  console.log('Running Invisibility Scheduler...');
  try {
    // Reset system_visibility_status to 'visible' only for users who are manually visible
    // (don't override users who manually set themselves to invisible)
    await supabase.from('users')
      .update({ system_visibility_status: 'visible' })
      .eq('user_visibility_setting', true)
      .eq('system_visibility_status', 'invisible');
    console.log('Scheduler: Reset system visibility to visible for manually visible users who were system-invisible.');

    const { data: schedules, error: scheduleError } = await supabase
      .from('user_visibility_schedules')
      .select('user_id, rrule')
      .eq('is_active', true);

    if (scheduleError) throw scheduleError;
    if (!schedules || schedules.length === 0) {
      console.log('Scheduler: No active schedules found.');
      return; // Exit if no rules to apply
    }

    const now = new Date();
    const usersToMakeInvisible = new Set<string>();

    for (const schedule of schedules) {
      if (!schedule.rrule) {
          console.warn(`Scheduler: Skipping schedule for user ${schedule.user_id} due to missing rrule.`);
          continue;
      }
      try {
        // Need to ensure the rrule string includes a DTSTART
        // Let's assume it does for now, or add parsing/defaulting if needed
        const rule = RRule.fromString(schedule.rrule);
        // Find occurrences between now and a very short time after now
        const occurrences = rule.between(now, new Date(now.getTime() + 60000), true); // Check within the next minute

        if (occurrences.length > 0) {
            // Check if 'now' falls within an "invisible" duration based on rule interpretation
            // RRule itself generates start times. We need logic to determine duration.
            // Simplified: If an occurrence starts *now* or *just before now*, consider invisible.
            // This needs a more robust duration logic based on your RRule format.
            // For example, if RRule defines START and END/DURATION.
            // Let's assume for now: if a rule matches *at all* in this check, user is invisible.
            usersToMakeInvisible.add(schedule.user_id);
        }
      } catch (rruleError) {
        console.error(`Scheduler: Skipping bad rrule for user ${schedule.user_id}: ${schedule.rrule} - ${rruleError.message}`);
      }
    }

    // Batch-update users in PostgreSQL to be invisible (only if they are manually visible)
    if (usersToMakeInvisible.size > 0) {
      const userIds = Array.from(usersToMakeInvisible);
      console.log(`Scheduler: Setting ${userIds.length} users to invisible based on schedule (only if manually visible).`);
      const { error: updateError } = await supabase
        .from('users')
        .update({ system_visibility_status: 'invisible' })
        .in('id', userIds)
        .eq('user_visibility_setting', true);
    } else {
        console.log('Scheduler: No users need to be set to invisible based on current schedules.');
    }

  } catch (error) {
    console.error('Error during Invisibility scheduling:', error.message);
  }
}

/**
 * Task 2: Performs continuous event matching for all events
 */
async function handleContinuousEventMatching() {
  console.log('Running Continuous Event Matching...');
  try {
    const { data, error } = await supabase.rpc('perform_continuous_event_matching');

    if (error) {
      console.error('Error during continuous event matching:', error);
      throw error;
    }

    console.log('Continuous Event Matching completed successfully.');
  } catch (error) {
    console.error('Error during Continuous Event Matching:', error.message);
  }
}

/**
 * Task 3: Performs continuous user proximity matching for all users
 */
async function handleContinuousUserMatching() {
  console.log('Running Continuous User Matching...');
  try {
    const { data, error } = await supabase.rpc('perform_continuous_user_matching');

    if (error) {
      console.error('Error during continuous user matching:', error);
      throw error;
    }

    console.log('Continuous User Matching completed successfully.');
  } catch (error) {
    console.error('Error during Continuous User Matching:', error.message);
  }
}

// Main server logic
serve(async (req) => {
  console.log('Cron job function invoked.'); // Log invocation
  try {
    // Run tasks sequentially for clearer logging
    await handleInvisibilitySchedules();
    await handleContinuousEventMatching();
    await handleContinuousUserMatching();

    console.log('Cron job function completed successfully.');
    return new Response(JSON.stringify({ success: true, message: "Cron jobs executed." }), {
      headers: { 'Content-Type': 'application/json' },
      status: 200 // Explicitly set success status
    });

  } catch (error) {
    console.error('Cron job function failed:', error.message); // Log failure
    return new Response(JSON.stringify({ success: false, error: error.message }), {
      status: 500,
      headers: { 'Content-Type': 'application/json' },
    });
  }
});