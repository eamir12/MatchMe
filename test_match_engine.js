const https = require('https');

// Test the match engine function
async function testMatchEngine() {
  const functionUrl = 'https://vazkmvrbshxwyodentng.supabase.co/functions/v1/match-engine';

  // TODO: Replace with actual service role key and user IDs from environment variables
  const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
  const testUserId = process.env.TEST_USER_ID_1;
  const testUserId2 = process.env.TEST_USER_ID_2;

  if (!serviceRoleKey || !testUserId || !testUserId2) {
    console.error('Missing required environment variables. Please set SUPABASE_SERVICE_ROLE_KEY, TEST_USER_ID_1, and TEST_USER_ID_2');
    return;
  }

  console.log('Testing match engine function...');

  // Simple HTTPS request without external dependencies
  function makeRequest(userId) {
    return new Promise((resolve, reject) => {
      const postData = JSON.stringify({
        userId: userId,
        latitude: 41.7151,
        longitude: 44.8271
      });

      const options = {
        hostname: 'vazkmvrbshxwyodentng.supabase.co',
        path: '/functions/v1/match-engine',
        method: 'POST',
        headers: {
          'Authorization': `Bearer ${serviceRoleKey}`,
          'Content-Type': 'application/json',
          'Content-Length': postData.length
        }
      };

      const req = https.request(options, (res) => {
        let data = '';
        res.on('data', (chunk) => {
          data += chunk;
        });
        res.on('end', () => {
          try {
            resolve(JSON.parse(data));
          } catch (e) {
            resolve(data);
          }
        });
      });

      req.on('error', (error) => {
        reject(error);
      });

      req.write(postData);
      req.end();
    });
  }

  try {
    // Test with first user
    const result1 = await makeRequest(testUserId);
    console.log('User 1 result:', result1);

    // Test with second user (should be nearby)
    const result2 = await makeRequest(testUserId2);
    console.log('User 2 result:', result2);

  } catch (error) {
    console.error('Error testing match engine:', error.message);
  }
}

testMatchEngine();