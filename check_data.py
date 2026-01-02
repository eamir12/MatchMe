import os
from supabase import create_client, Client

# Supabase credentials
SUPABASE_URL = "https://vazkmvrbshxwyodentng.supabase.co"
SUPABASE_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InZhemttdnJic2h4d3lvZGVudG5nIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NjA2ODgyOTIsImV4cCI6MjA3NjI2NDI5Mn0.z4b2Mh_sTYjHAmqcvh14FBOfDJ-NmEC8iAirKitleUU"

def main():
    supabase: Client = create_client(SUPABASE_URL, SUPABASE_KEY)

    try:
        # Check interests data
        print("Checking interests data for test users...")
        result = supabase.table('user_profiles').select('user_id, profile_data').in_('user_id', ['35fe114e-eae5-49d6-9eba-8459617e7b82', 'ffc20046-a777-463b-922a-547151aa1455']).execute()
        for row in result.data:
            print(f"User {row['user_id']}: interests = {row['profile_data'].get('interests', 'None')}")

        # Check users data
        print("\nChecking users data...")
        result = supabase.table('users').select('id, active_modes, shared_event_matching_enabled').in_('id', ['35fe114e-eae5-49d6-9eba-8459617e7b82', 'ffc20046-a777-463b-922a-547151aa1455']).execute()
        for row in result.data:
            print(f"User {row['id']}: active_modes = {row['active_modes']}, shared_event_matching_enabled = {row['shared_event_matching_enabled']}")

        # Check event attendance
        print("\nChecking event attendance...")
        result = supabase.table('event_attendees').select('user_id, event_id').eq('event_id', '6497a84c-6ae6-445b-b3e1-e7acc984b2c5').in_('user_id', ['35fe114e-eae5-49d6-9eba-8459617e7b82', 'ffc20046-a777-463b-922a-547151aa1455']).execute()
        for row in result.data:
            print(f"User {row['user_id']} is attending event {row['event_id']}")

        # Try to call the function
        print("\nTrying to call perform_event_matching function...")
        try:
            result = supabase.rpc('perform_event_matching', {'p_event_id': '6497a84c-6ae6-445b-b3e1-e7acc984b2c5'}).execute()
            print("Function call successful!")
        except Exception as e:
            print(f"Function call failed: {e}")

        # Check current matches
        print("\nChecking current matches in database...")
        try:
            result = supabase.table('matches').select('*').execute()
            print(f"Found {len(result.data)} matches:")
            for match in result.data:
                print(f"  Match: {match['user_a_id']} <-> {match['user_b_id']} (type: {match['match_type']}, event: {match.get('event_id', 'N/A')})")
        except Exception as e:
            print(f"Error checking matches: {e}")

    except Exception as e:
        print(f"Error: {e}")

if __name__ == "__main__":
    main()