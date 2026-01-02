import 'dart:io';
import 'package:supabase/supabase.dart';

void main() async {
  // You'll need to set these environment variables or replace with actual values
  final supabaseUrl = Platform.environment['SUPABASE_URL'] ?? 'https://vazkmvrbshxwyodentng.supabase.co';
  final supabaseKey = Platform.environment['SUPABASE_ANON_KEY'] ?? 'your-anon-key-here';

  final supabase = SupabaseClient(supabaseUrl, supabaseKey);

  final sql = '''
-- Create a function to update user location (call this from mobile apps)
CREATE OR REPLACE FUNCTION update_user_location(
    p_user_id UUID,
    p_latitude DOUBLE PRECISION,
    p_longitude DOUBLE PRECISION,
    p_speed DOUBLE PRECISION DEFAULT NULL,
    p_heading DOUBLE PRECISION DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
AS \$\$
BEGIN
    SET search_path = 'public';

    INSERT INTO user_locations (user_id, latitude, longitude, speed, heading, updated_at)
    VALUES (p_user_id, p_latitude, p_longitude, p_speed, p_heading, NOW())
    ON CONFLICT (user_id)
    DO UPDATE SET
        latitude = EXCLUDED.latitude,
        longitude = EXCLUDED.longitude,
        speed = EXCLUDED.speed,
        heading = EXCLUDED.heading,
        updated_at = NOW();

    -- Also update user activity to keep them online
    PERFORM update_user_activity(p_user_id);
END;
\$\$;

-- Grant permissions for the location update function
GRANT EXECUTE ON FUNCTION update_user_location(UUID, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION) TO authenticated;
GRANT EXECUTE ON FUNCTION update_user_location(UUID, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION) TO anon;
''';

  try {
    final result = await supabase.rpc('exec_sql', params: {'sql': sql});
    stdout.writeln('SQL executed successfully: $result');
  } catch (e) {
    stderr.writeln('Error executing SQL: $e');
  }
}
