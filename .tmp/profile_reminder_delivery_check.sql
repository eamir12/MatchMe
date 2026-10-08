-- =============================================================================
-- READ-ONLY, no parameters: the two profile-reminder sends + target platform
-- =============================================================================

-- 1) Delivery rows for the profile_reminder automation
SELECT 'deliveries' AS section,
       u.email,
       d.delivery_status,
       d.delivered_at,
       d.failure_reason,
       d.created_at
FROM public.admin_broadcast_deliveries d
JOIN public.admin_broadcasts b ON b.id = d.broadcast_id
JOIN public.users u ON u.id = d.user_id
WHERE b.automation_type = 'profile_reminder'
ORDER BY d.created_at DESC
LIMIT 20;

-- 2) For the incomplete-profile accounts: platform of the session that
--    holds the FCM token (i.e. the device the reminder was sent to)
SELECT 'target_sessions' AS section,
       u.email,
       us.platform,
       us.revoked,
       us.last_active_at,
       LEFT(COALESCE(us.metadata->>'fcm_token', ''), 10) || '…' AS fcm_token_prefix
FROM public.users u
JOIN public.user_session us ON us.user_id = u.id
WHERE COALESCE(u.is_profile_complete, false) = false
ORDER BY u.email, us.last_active_at DESC NULLS LAST;
