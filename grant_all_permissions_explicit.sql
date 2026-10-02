-- Grant permissions only to existing tables
-- Run this in Supabase SQL Editor

-- Core user tables
GRANT ALL ON users TO authenticated;
GRANT ALL ON matches TO authenticated;
GRANT ALL ON events TO authenticated;
GRANT ALL ON event_attendees TO authenticated;
GRANT ALL ON chat_messages TO authenticated;
GRANT ALL ON user_recent_matches TO authenticated;
GRANT ALL ON user_recent_chats TO authenticated;

-- Admin tables
GRANT ALL ON admin_broadcasts TO authenticated;
GRANT ALL ON admin_dashboard_tick TO authenticated;

-- Ad system tables
GRANT ALL ON ad_campaigns TO authenticated;
GRANT ALL ON ad_creatives TO authenticated;
GRANT ALL ON ad_impressions TO authenticated;
GRANT ALL ON ad_clicks TO authenticated;
GRANT ALL ON ad_reports TO authenticated;
GRANT ALL ON ad_networks TO authenticated;
GRANT ALL ON ad_units TO authenticated;
GRANT ALL ON ad_revenue_events TO authenticated;
GRANT ALL ON ad_network_analytics TO authenticated;
GRANT ALL ON ad_consent TO authenticated;
GRANT ALL ON ad_revenue_daily_stats TO authenticated;
GRANT ALL ON ad_system_config TO authenticated;
GRANT ALL ON ad_system_placements TO authenticated;
GRANT ALL ON ad_system_tiers TO authenticated;
GRANT ALL ON ad_system_schedules TO authenticated;

-- Subscription & billing
GRANT ALL ON subscriptionPlans TO authenticated;
GRANT ALL ON subscriptionTiers TO authenticated;
GRANT ALL ON subscriptionQueue TO authenticated;

-- Referral system
GRANT ALL ON referrals TO authenticated;
GRANT ALL ON referral_earnings TO authenticated;

-- Promo codes
GRANT ALL ON promo_codes TO authenticated;
GRANT ALL ON promo_code_usages TO authenticated;

-- Other tables
GRANT ALL ON app_config TO authenticated;
GRANT ALL ON translations TO authenticated;
GRANT ALL ON user_interests TO authenticated;
GRANT ALL ON user_locations TO authenticated;
GRANT ALL ON user_events TO authenticated;
GRANT ALL ON user_session TO authenticated;
GRANT ALL ON sensitive_action_email_codes TO authenticated;
GRANT ALL ON passkey_challenges TO authenticated;
GRANT ALL ON passkey_credentials TO authenticated;
GRANT ALL ON user_mfa_recovery_codes TO authenticated;
GRANT ALL ON signup_fraud_signals TO authenticated;
GRANT ALL ON profile_edit_requests TO authenticated;
GRANT ALL ON edge_function_invocations TO authenticated;
GRANT ALL ON ai_quota_status TO authenticated;
GRANT ALL ON ai_quota_alert_state TO authenticated;
GRANT ALL ON currency_exchange_rates TO authenticated;

-- Schema permissions
GRANT USAGE ON SCHEMA public TO authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO authenticated;
GRANT EXECUTE ON ALL PROCEDURES IN SCHEMA public TO authenticated;
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO authenticated;

SELECT 'Done - permissions granted' as result;