import 'package:supabase_flutter/supabase_flutter.dart';

void main() async {
  // Initialize Supabase (you'll need to add your actual URL and anon key)
  await Supabase.initialize(
    url: 'YOUR_SUPABASE_URL',
    anonKey: 'YOUR_SUPABASE_ANON_KEY',
  );

  final supabase = Supabase.instance.client;

  try {
    // print('Testing perform_event_matching function...');

    // Call the function
    await supabase.rpc('perform_event_matching', params: {
      'p_event_id': '6497a84c-6ae6-445b-b3e1-e7acc984b2c5'
    });

    // print('Function call successful!');
    // print('Result: $result');

  } catch (e) {
    // print('Error calling function: $e');
  }
}