#!/bin/bash
# create_webhook.sh - Creates a webhook for message translation

# You need to provide these:
PROJECT_ID="your_project_id"
SERVICE_ROLE_KEY="your_service_role_key"

# Get these from:
# PROJECT_ID - Supabase Dashboard → Settings → General → Project ID
# SERVICE_ROLE_KEY - Supabase Dashboard → Settings → API → Service Role Key

if [ "$PROJECT_ID" = "your_project_id" ] || [ "$SERVICE_ROLE_KEY" = "your_service_role_key" ]; then
  echo "ERROR: Please update PROJECT_ID and SERVICE_ROLE_KEY in this script"
  exit 1
fi

# Create the webhook
curl -X POST "https://api.supabase.com/v1/projects/$PROJECT_ID/database/webhooks" \
  -H "Authorization: Bearer $SERVICE_ROLE_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "Translate messages on insert",
    "table": "chat_messages",
    "events": ["INSERT"],
    "method": "POST",
    "function_name": "on-message-insert",
    "enabled": true
  }'

echo ""
echo "Webhook created! Check Supabase Dashboard → Database → Webhooks to verify."
