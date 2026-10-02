# Admin Functions Audit Report

**Generated:** May 6, 2026  
**Scope:** All `admin_*` functions in Supabase migrations and user-facing functions

---

## [ADMIN_ONLY] - Functions That Should Only Be Callable by Admins

These functions have built-in admin checks and perform administrative operations. All enforce `is_admin = true`.

### Promo Code Analytics (4 functions)
1. **`admin_get_promo_usage_by_user()`**
   - Returns: Table with user promo usage stats
   - Use: Admin dashboard analytics
   - Migration: `20260422170000_add_promo_analytics_drilldown_rpcs.sql`
   - Admin Check: ✅ Yes (line 21)

2. **`admin_get_promo_usage_user_details(p_user_id UUID)`**
   - Returns: Table with user's promo history
   - Use: Admin drilldown by user
   - Migration: `20260422170000_add_promo_analytics_drilldown_rpcs.sql`
   - Admin Check: ✅ Yes (line 65)

3. **`admin_get_promo_usage_by_code()`**
   - Returns: Table with promo code usage stats
   - Use: Admin dashboard analytics by code
   - Migration: `20260422170000_add_promo_analytics_drilldown_rpcs.sql`
   - Admin Check: ✅ Yes (line 104)

4. **`admin_get_promo_discount_by_date()`**
   - Returns: Table with discount breakdown by date
   - Use: Admin analytics time series
   - Migration: `20260422170000_add_promo_analytics_drilldown_rpcs.sql`
   - Admin Check: ✅ Yes (line 142)

### Configuration Management (2 functions)
5. **`admin_update_app_config(p_config_key, p_config_value, p_config_type, p_category, p_description, p_is_user_configurable, p_min_value, p_max_value, p_allowed_values)`**
   - Returns: void
   - Use: Upsert app configuration settings
   - Migration: `20260422160000_create_admin_update_app_config_rpc.sql`
   - Admin Check: ✅ Yes (line 18)

6. **`admin_update_promo_codes_config(p_enabled BOOLEAN)`**
   - Returns: void
   - Use: Enable/disable promo codes feature
   - Migration: `20260422130000_add_promo_codes_config.sql`, `20260422140000_fix_promo_codes_config_jsonb_cast.sql`
   - Admin Check: ⚠️ **MISSING** - Function does NOT check if user is admin (SECURITY ISSUE)
   - Granted to: authenticated (should be admin-only or have RLS)

### Subscription Management (4 functions)
7. **`admin_upsert_subscription_tier(p_id, p_revenue_cat_package_identifier, p_title_key, p_subtitle_key, p_features_key, p_badge_key, p_sort_order, p_is_active)`**
   - Returns: subscription_tiers row
   - Use: Create/update subscription tier
   - Migration: `20260223000000_admin_subscription_crud_rpcs.sql`
   - Admin Check: ✅ Yes (line 20)

8. **`admin_delete_subscription_tier(p_id text)`**
   - Returns: void
   - Use: Delete subscription tier
   - Migration: `20260223000000_admin_subscription_crud_rpcs.sql`
   - Admin Check: ✅ Yes (line 94)

9. **`admin_upsert_subscription_plan(p_id, p_tier_id, p_duration, p_price_display, p_savings_text, p_revenue_cat_package_identifier, p_sort_order)`**
   - Returns: subscription_plans row
   - Use: Create/update subscription plan
   - Migration: `20260223000000_admin_subscription_crud_rpcs.sql`
   - Admin Check: ✅ Yes (confirmed in file)

10. **`admin_delete_subscription_plan(p_id text)`**
    - Returns: void
    - Use: Delete subscription plan
    - Migration: `20260223000000_admin_subscription_crud_rpcs.sql`
    - Admin Check: ✅ Yes (confirmed in file)

### Translation Management (3 functions)
11. **`admin_bulk_upsert_translations(p_items jsonb)`**
    - Returns: integer (count of upserted items)
    - Use: Bulk update translations
    - Migration: `20260223002000_admin_translations_rpcs.sql`
    - Admin Check: ✅ Yes (line 15)

12. **`admin_delete_translation_key(p_key text)`**
    - Returns: void
    - Use: Delete translation key across all locales
    - Migration: `20260223002000_admin_translations_rpcs.sql`
    - Admin Check: ✅ Yes (line 68)

13. **`admin_delete_translation_locale_key(p_locale text, p_key text)`**
    - Returns: void
    - Use: Delete translation for specific locale
    - Migration: `20260223002000_admin_translations_rpcs.sql`
    - Admin Check: ✅ Yes (line 100)

### User Verification & Profile Management (4 functions)
14. **`admin_list_verification_users(p_status, p_query, p_limit, p_offset)`**
    - Returns: Table with verification queue users
    - Use: List users awaiting verification review
    - Migration: `20260223007000_admin_user_tools.sql`, etc.
    - Admin Check: ✅ Yes (line 130)

15. **`admin_set_user_verification_status(p_user_id uuid, p_status text)`**
    - Returns: void
    - Use: Approve/reject user verification
    - Migration: `20260223007000_admin_user_tools.sql`
    - Admin Check: ✅ Yes (line 175)

16. **`admin_list_profile_edit_requests(p_status, p_query, p_limit, p_offset)`**
    - Returns: Table with profile edit requests
    - Use: List pending profile edits for admin review
    - Migration: `20260223007000_admin_user_tools.sql`
    - Admin Check: ✅ Yes (confirmed in file)

17. **`admin_review_profile_edit_request(p_request_id uuid, p_decision text, p_reviewer_note text)`**
    - Returns: void
    - Use: Approve/reject profile edit request
    - Migration: `20260223007000_admin_user_tools.sql`
    - Admin Check: ✅ Yes (line 309)

### Broadcast Management (2 functions)
18. **`admin_list_target_users_for_broadcast(filter_criteria jsonb, p_limit, p_offset)`**
    - Returns: Table with user_id, name, platform, last_active_at
    - Use: Preview users who will receive broadcast
    - Migration: `20260224002000_admin_list_target_users_for_broadcast.sql`
    - Admin Check: ✅ Yes (line 26) - OR service_role

19. **`send_admin_broadcast(broadcast_id uuid)` - INTERNAL ONLY**
    - Returns: void
    - Use: Actually send scheduled broadcast (internal job)
    - Migration: `20260202000000_create_admin_broadcast_system.sql`
    - Admin Check: ✅ Granted to service_role only (revoked from authenticated)
    - Note: NOT for direct authenticated user calls

### Taxonomy Management - Intents & Interests (6 functions)
20. **`admin_list_intents()`**
    - Returns: Table with intent records
    - Use: List all intents
    - Migration: `20260224012000_fix_admin_taxonomy_rpcs_bigint.sql`
    - Admin Check: ✅ Yes (line 36)

21. **`admin_list_interests()`**
    - Returns: Table with interest records
    - Use: List all interests
    - Migration: `20260224012000_fix_admin_taxonomy_rpcs_bigint.sql`
    - Admin Check: ✅ Yes (line 88)

22. **`admin_upsert_intent(p_id, p_key, p_parent_id, p_translation_key, p_sort_order, p_is_social, p_is_business)`**
    - Returns: bigint (id)
    - Use: Create/update intent
    - Migration: `20260224012000_fix_admin_taxonomy_rpcs_bigint.sql`
    - Admin Check: ✅ Yes (line 140)

23. **`admin_upsert_interest(p_id, p_key, p_parent_id, p_translation_key, p_sort_order, p_is_social, p_is_business)`**
    - Returns: bigint (id)
    - Use: Create/update interest
    - Migration: `20260224012000_fix_admin_taxonomy_rpcs_bigint.sql`
    - Admin Check: ✅ Yes (line 218)

24. **`admin_delete_intent(p_id bigint)`**
    - Returns: void
    - Use: Delete intent
    - Migration: `20260224012000_fix_admin_taxonomy_rpcs_bigint.sql`
    - Admin Check: ✅ Yes (line 296)

25. **`admin_delete_interest(p_id bigint)`**
    - Returns: void
    - Use: Delete interest
    - Migration: `20260224012000_fix_admin_taxonomy_rpcs_bigint.sql`
    - Admin Check: ✅ Yes (line 328)

### Dashboard & Analytics (1 function)
26. **`admin_get_dashboard_stats(p_window text)`**
    - Returns: jsonb with comprehensive dashboard stats
    - Use: Real-time admin dashboard metrics
    - Migration: `20260225090000_admin_get_dashboard_stats_rpc.sql`
    - Admin Check: ✅ Yes (line 43)

---

## [USER_FACING] - Functions Regular Authenticated Users Can Call

These are functions that regular users should be able to call for their own operations. They use RLS or built-in context checks to restrict data access.

### User Activity & Status (3 functions)
1. **`update_user_activity(p_user_id uuid)`**
   - Use: Mark user as active (updates last_active_at)
   - Migration: `20260101180000_update_matching_and_visibility_functions.sql`
   - Granted: authenticated
   - Security: Should check that p_user_id == auth.uid()

2. **`set_user_offline(p_user_id uuid)`**
   - Use: Mark user as offline
   - Migration: `20260101180000_update_matching_and_visibility_functions.sql`
   - Granted: authenticated
   - Security: Should check that p_user_id == auth.uid()

3. **`update_user_visibility(p_user_id uuid)`**
   - Use: Update user visibility based on preferences
   - Migration: `20260220000000_improve_user_status_handling.sql`
   - Granted: authenticated

### User Location (1 function)
4. **`update_user_location(p_user_id uuid, p_latitude double precision, p_longitude double precision, p_accuracy integer)`**
   - Use: Update user's current location
   - Migration: `20260101180000_update_matching_and_visibility_functions.sql`
   - Granted: authenticated
   - Security: Should check that p_user_id == auth.uid()

### Chat & Messaging (7 functions)
5. **`get_user_recent_chats(p_user_id uuid, p_limit int)`**
   - Use: Get recent conversations for user
   - Migration: `20260101143000_create_chats_table.sql`
   - Granted: authenticated
   - Security: RLS should restrict to user's own chats

6. **`mark_messages_as_read(p_match_id uuid)`**
   - Use: Mark messages in a match as read
   - Migration: `20260205000000_fix_mark_messages_as_read_return_value.sql`
   - Granted: authenticated
   - Security: RLS should restrict to user's matches

7. **`edit_chat_message(p_message_id uuid, p_new_content text)`**
   - Use: Edit a message you sent
   - Migration: `20260103123000_ensure_edit_chat_message.sql`
   - Granted: authenticated
   - Security: Check that auth.uid() == message.user_id

8. **`set_message_reaction(p_message_id uuid, p_reaction text)`**
   - Use: Add emoji reaction to message
   - Migration: `20260101170000_create_message_reactions.sql`
   - Granted: authenticated
   - Security: RLS controls access

9. **`get_message_reactors(message_id uuid, reaction text)`**
   - Use: See who reacted with specific emoji
   - Migration: `20260102230000_create_get_message_reactors_function.sql`
   - Granted: authenticated
   - Security: RLS controls access

10. **`set_chat_translation(p_message_id uuid, p_target_language text, p_translated_text text)`**
    - Use: Store translation of message
    - Migration: `20260101161000_fix_set_chat_translation_rpc.sql`
    - Granted: authenticated
    - Security: Should check user owns the message or chat

11. **`mark_message_delivered(p_message_id uuid)`**
    - Use: Mark message as delivered to recipient
    - Migration: `20260206110000_add_delivered_at_to_messages.sql`
    - Granted: authenticated
    - Security: Check message belongs to user's chat

### Dashboard Stats (2 functions)
12. **`get_online_users_count(p_user_id UUID)`**
    - Use: Get count of currently online users visible to user
    - Migration: Multiple updates through `20260220000000`
    - Granted: authenticated
    - Security: Uses RLS to show only visible users

13. **`get_nearby_users_count(p_user_id UUID, p_radius_km INTEGER)`**
    - Use: Get count of nearby users within radius
    - Migration: `20251225175225_create_dashboard_stats_functions.sql`
    - Granted: authenticated
    - Security: Uses RLS to show only visible users

### Matching & Events (6 functions)
14. **`get_potential_event_matches(p_event_id UUID, p_user_id UUID)`**
    - Use: Get potential attendees for an event
    - Migration: `20260101180000_update_matching_and_visibility_functions.sql`
    - Granted: authenticated
    - Security: Check p_user_id == auth.uid()

15. **`find_nearby_users(p_user_id uuid, p_latitude double precision, p_longitude double precision, p_radius_km integer)`**
    - Use: Find users within geographic radius
    - Migration: `20260101180000_update_matching_and_visibility_functions.sql`
    - Granted: authenticated

16. **`perform_event_matching(p_event_id UUID)`**
    - Use: Trigger matching algorithm for event
    - Migration: `20260101180000_update_matching_and_visibility_functions.sql`
    - Granted: authenticated
    - Security: Check user owns event

17. **`perform_continuous_user_matching()`**
    - Use: Trigger background user matching
    - Migration: `20260101180000_update_matching_and_visibility_functions.sql`
    - Granted: authenticated

18. **`unmatch_from_system_match(p_match_id uuid)`**
    - Use: Remove a system-generated match
    - Migration: `20260129120000_add_unmatch_pairs_and_rpc.sql`
    - Granted: authenticated

19. **`cleanup_expired_matches(p_cutoff timestamptz, p_limit int)`**
    - Use: Remove old expired matches (background job)
    - Migration: `20260129120000_add_unmatch_pairs_and_rpc.sql`
    - Granted: authenticated (but should be service_role)

### Notifications (2 functions)
20. **`check_unread_notifications(p_user_id UUID, p_message_id UUID)`**
    - Use: Check for new notifications
    - Migration: `20260104173000_add_notification_check.sql`
    - Granted: authenticated
    - Security: Check p_user_id == auth.uid()

21. **`get_broadcast_stats(p_broadcast_id UUID)`**
    - Use: User checks delivery status of broadcast to them
    - Migration: `20260203000000_fix_admin_broadcast_notifications.sql`
    - Granted: authenticated
    - Security: RLS restricts to user's own delivery

### Subscription & Payment (6 functions)
22. **`normalize_user_subscription_queue(p_user_id uuid)`**
    - Use: Sync subscription state after payment
    - Migration: `20260213000000_create_user_subscription_queue.sql`
    - Granted: authenticated

23. **`add_subscription_to_queue(p_tier_id text, p_duration text, p_user_id uuid)`**
    - Use: Queue a subscription purchase
    - Migration: `20260213000000_create_user_subscription_queue.sql`
    - Granted: authenticated

24. **`get_next_queued_subscription(p_user_id uuid)`**
    - Use: Get next subscription in queue
    - Migration: `20260213000000_create_user_subscription_queue.sql`
    - Granted: authenticated

25. **`cancel_queued_subscription(p_queue_id uuid, p_user_id uuid)`**
    - Use: Cancel a queued subscription
    - Migration: `20260213000000_create_user_subscription_queue.sql`
    - Granted: authenticated

26. **`get_user_subscription_timeline(p_user_id uuid)`**
    - Use: View subscription history
    - Migration: `20260213000000_create_user_subscription_queue.sql`
    - Granted: authenticated

27. **`check_and_normalize_user_subscription(p_user_id uuid)`**
    - Use: Verify subscription state matches reality
    - Migration: `20260213000000_create_user_subscription_queue.sql`
    - Granted: authenticated

### Match Ratings (4 functions)
28. **`get_due_match_rating_prompts(p_user_id uuid, p_limit int)`**
    - Use: Get matches user should rate
    - Migration: `20260218000000_add_match_ratings_and_prompts.sql`
    - Granted: authenticated

29. **`set_match_met_answer(p_rating_id uuid, p_met boolean)`**
    - Use: Answer "did you meet?" question
    - Migration: `20260218000000_add_match_ratings_and_prompts.sql`
    - Granted: authenticated

30. **`submit_match_rating(p_rating_id uuid, p_rating integer, p_text_feedback text)`**
    - Use: Submit rating for a match
    - Migration: `20260218000000_add_match_ratings_and_prompts.sql`
    - Granted: authenticated

31. **`get_user_rating_summary(p_user_id uuid)`**
    - Use: View your rating from matches
    - Migration: `20260218000000_add_match_ratings_and_prompts.sql`
    - Granted: authenticated

### Recent Activity (2 functions)
32. **`get_user_recent_matches(p_user_id uuid, p_limit int)`**
    - Use: Get recent matches for user
    - Migration: `20260101141000_add_recent_activity_rpcs.sql`
    - Granted: authenticated

33. **`upsert_user_recent_match(p_user_id uuid, p_match_id uuid)`**
    - Use: Record a match as viewed
    - Migration: `20260101140000_create_user_recent_activity_tables.sql`
    - Granted: authenticated

### Utility Functions (3 functions)
34. **`health_check()`**
    - Use: Health check endpoint
    - Migration: `20260101212000_add_health_check_function.sql`
    - Granted: authenticated, public

35. **`mask_full_name(full_name TEXT)`**
    - Use: Mask name for privacy (e.g., "John D.")
    - Migration: `20260101120000_create_mask_full_name_function.sql`
    - Granted: authenticated (utility function)

36. **`is_user_truly_visible(p_user_id UUID)`**
    - Use: Check if user is truly visible to others
    - Migration: `20260102100000_create_is_user_truly_visible_function.sql`
    - Granted: authenticated

### Other User-Callable Functions (4 functions)
37. **`count_event_attendees(event_id_param UUID)`**
    - Use: Get attendee count for an event
    - Migration: `20251225190651_fix_function_search_path_mutable.sql`
    - Granted: authenticated

38. **`block_user()`**
    - Use: Block another user (implied from context)
    - Security: Check auth.uid() != target user

39. **`get_visible_online_user_map_cells(p_latitude numeric, p_longitude numeric, p_radius_km numeric)`**
    - Use: Get map cells with visible users
    - Migration: `20260218012000_add_nearby_map_cells_rpc.sql`
    - Granted: authenticated

40. **`get_current_timestamp()`**
    - Use: Get server time
    - Granted: anon, authenticated

---

## Summary

### Total Admin Functions: **26**
- ✅ All have admin checks except 1 (SECURITY ISSUE)

### Total User-Facing Functions: **40+**
- These use RLS and parameter validation for security
- Many should include additional checks like `p_user_id == auth.uid()`

### Security Issues Found:

1. **🔴 CRITICAL: `admin_update_promo_codes_config()` MISSING ADMIN CHECK**
   - Location: `20260422130000_add_promo_codes_config.sql` and `20260422140000_fix_promo_codes_config_jsonb_cast.sql`
   - Status: Granted to `authenticated` role
   - Risk: Any authenticated user can enable/disable promo codes
   - **Recommendation:** Add admin check or create RLS policy

### Recommendations:

1. **Fix `admin_update_promo_codes_config()`** to include admin verification
2. **Audit `cleanup_expired_matches()`** - should be service_role only, not authenticated
3. **Verify RLS policies** on all user-facing functions to ensure proper data isolation
4. **Add explicit auth checks** to user-facing functions that accept user_id parameters (check `p_user_id == auth.uid()`)
5. **Consider adding audit logging** to all admin functions for compliance

---

## Function Categories by Feature Area

### 📊 Analytics & Reporting (Admin-Only)
- admin_get_promo_usage_by_user
- admin_get_promo_usage_user_details
- admin_get_promo_usage_by_code
- admin_get_promo_discount_by_date
- admin_get_dashboard_stats

### ⚙️ Configuration (Admin-Only)
- admin_update_app_config
- admin_update_promo_codes_config ⚠️

### 💳 Subscriptions (Admin-Only)
- admin_upsert_subscription_tier
- admin_delete_subscription_tier
- admin_upsert_subscription_plan
- admin_delete_subscription_plan

### 🌐 Translations (Admin-Only)
- admin_bulk_upsert_translations
- admin_delete_translation_key
- admin_delete_translation_locale_key

### 👤 User Management (Admin-Only)
- admin_list_verification_users
- admin_set_user_verification_status
- admin_list_profile_edit_requests
- admin_review_profile_edit_request

### 📢 Broadcasting (Admin-Only)
- admin_list_target_users_for_broadcast
- send_admin_broadcast (service_role only)

### 🏷️ Taxonomy (Admin-Only)
- admin_list_intents
- admin_list_interests
- admin_upsert_intent
- admin_upsert_interest
- admin_delete_intent
- admin_delete_interest

### 💬 Chat & Messaging (User-Facing)
- get_user_recent_chats
- mark_messages_as_read
- edit_chat_message
- set_message_reaction
- get_message_reactors
- set_chat_translation
- mark_message_delivered

### 👥 Matching & Events (User-Facing)
- get_potential_event_matches
- find_nearby_users
- perform_event_matching
- perform_continuous_user_matching
- unmatch_from_system_match
- cleanup_expired_matches ⚠️

### 📊 Dashboard Stats (User-Facing)
- get_online_users_count
- get_nearby_users_count

### 🔔 Notifications (User-Facing)
- check_unread_notifications
- get_broadcast_stats

### 💰 Subscriptions & Payments (User-Facing)
- normalize_user_subscription_queue
- add_subscription_to_queue
- get_next_queued_subscription
- cancel_queued_subscription
- get_user_subscription_timeline
- check_and_normalize_user_subscription

### ⭐ Match Ratings (User-Facing)
- get_due_match_rating_prompts
- set_match_met_answer
- submit_match_rating
- get_user_rating_summary

### 🕐 User Activity (User-Facing)
- update_user_activity
- set_user_offline
- update_user_visibility
- update_user_location

### 📝 Recent Activity (User-Facing)
- get_user_recent_matches
- upsert_user_recent_match

### 🔧 Utilities (User-Facing)
- health_check
- mask_full_name
- is_user_truly_visible
- count_event_attendees
- get_visible_online_user_map_cells
- get_current_timestamp

