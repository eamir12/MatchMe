// Simulate the Edge Function interest matching logic

const user1Interests = {
  "music": ["music_concerts", "music_studio", "rock"],
  "dining": ["street_food"],
  "movies": ["movies_blockbuster", "movies_indie"],
  "nature": ["camping_nature", "bird_watching"],
  "hobbies": ["photography", "crafts"],
  "category_food_drink": ["interest_cooking", "interest_dining_out"],
  "category_arts_culture": ["interest_music", "interest_movies"],
  "category_sports_fitness": ["interest_gym", "interest_running", "interest_yoga", "interest_team_sports"],
  "category_learning_growth": ["interest_language_exchange"],
  "category_outdoors_travel": ["interest_hiking", "interest_nature", "interest_camping"]
};

const user2Interests = {
  "category_food_drink": ["interest_cooking"],
  "category_arts_culture": ["interest_music", "interest_dancing"],
  "category_sports_fitness": ["interest_yoga", "interest_team_sports"],
  "category_outdoors_travel": ["interest_nature", "interest_hiking"]
};

// Edge Function logic
let hasSharedInterest = false;
for (const category of Object.keys(user1Interests)) {
  const userInterestList = user1Interests[category] || [];
  const otherInterestList = user2Interests[category] || [];
  
  console.log(`Checking category "${category}": user1=${userInterestList.length}, user2=${otherInterestList.length}`);
  
  if (userInterestList.some((interest) => otherInterestList.includes(interest))) {
    hasSharedInterest = true;
    console.log(`  ✅ SHARED INTEREST FOUND in category "${category}"!`);
    break;
  }
}

console.log(`\nFinal result: hasSharedInterest = ${hasSharedInterest}`);
