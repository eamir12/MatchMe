# Email Setup Guide for Sensitive Action Email Codes

## Overview

The email code validation system requires an email service to send verification codes. This guide explains how to set up email sending for your Supabase project.

## Option 1: Using Resend (Recommended)

Resend is Supabase's recommended email service and is the easiest to set up.

### Step 1: Create a Resend Account
1. Go to [resend.com](https://resend.com)
2. Sign up for a free account
3. Verify your email

### Step 2: Get Your API Key
1. In Resend dashboard, go to **API Keys**
2. Copy your API key (starts with `re_`)

### Step 3: Add API Key to Supabase
1. Go to your Supabase project dashboard
2. Navigate to **Settings** → **Edge Functions**
3. Add a new environment variable:
   - **Name**: `RESEND_API_KEY`
   - **Value**: Your Resend API key

### Step 4: Update the Edge Function
In `supabase/functions/sensitive-action-email-code/index.ts`, update the `from` email address:

```typescript
body: JSON.stringify({
  from: "noreply@yourdomain.com", // Change this to your domain
  to: email,
  subject: "Your verification code for sensitive account changes",
  html: emailBody,
}),
```

Replace `yourdomain.com` with your actual domain.

### Step 5: Verify Your Domain (Optional but Recommended)
For production, verify your domain in Resend:
1. In Resend dashboard, go to **Domains**
2. Add your domain
3. Follow the DNS verification steps

## Option 2: Using SendGrid

### Step 1: Create a SendGrid Account
1. Go to [sendgrid.com](https://sendgrid.com)
2. Sign up for a free account
3. Verify your email

### Step 2: Get Your API Key
1. In SendGrid dashboard, go to **Settings** → **API Keys**
2. Create a new API key
3. Copy the key

### Step 3: Add API Key to Supabase
1. Go to your Supabase project dashboard
2. Navigate to **Settings** → **Edge Functions**
3. Add environment variables:
   - **Name**: `SENDGRID_API_KEY`
   - **Value**: Your SendGrid API key
   - **Name**: `SENDGRID_FROM_EMAIL`
   - **Value**: Your verified sender email

### Step 4: Update the Edge Function
Replace the `sendEmailCode` function in `supabase/functions/sensitive-action-email-code/index.ts`:

```typescript
async function sendEmailCode(
  email: string,
  code: string,
  supabaseUrl: string,
  supabaseKey: string
): Promise<void> {
  try {
    const emailBody = generateEmailHtml(code);
    const sendgridApiKey = Deno.env.get("SENDGRID_API_KEY");
    const fromEmail = Deno.env.get("SENDGRID_FROM_EMAIL");

    if (!sendgridApiKey || !fromEmail) {
      throw new Error("SendGrid configuration missing");
    }

    const response = await fetch("https://api.sendgrid.com/v3/mail/send", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Authorization": `Bearer ${sendgridApiKey}`,
      },
      body: JSON.stringify({
        personalizations: [
          {
            to: [{ email: email }],
          },
        ],
        from: { email: fromEmail },
        subject: "Your verification code for sensitive account changes",
        content: [
          {
            type: "text/html",
            value: emailBody,
          },
        ],
      }),
    });

    if (!response.ok) {
      const errorData = await response.text();
      throw new Error(`Failed to send email: ${response.status}`);
    }

    console.log(`Email sent successfully to ${email}`);
  } catch (error) {
    console.error("Error in sendEmailCode:", error);
    throw error;
  }
}
```

## Option 3: Using AWS SES

### Step 1: Set Up AWS SES
1. Go to AWS Console
2. Navigate to **Simple Email Service (SES)**
3. Verify your email or domain
4. Request production access (if needed)

### Step 2: Create IAM Credentials
1. Go to **IAM** → **Users**
2. Create a new user with SES permissions
3. Generate access key and secret key

### Step 3: Add Credentials to Supabase
Add environment variables:
- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`
- `AWS_SES_REGION` (e.g., `us-east-1`)
- `AWS_SES_FROM_EMAIL`

### Step 4: Update the Edge Function
Replace the `sendEmailCode` function to use AWS SES SDK.

## Option 4: Using Your Own SMTP Server

If you have your own email server, you can use an SMTP library in the edge function.

### Step 1: Add SMTP Credentials to Supabase
Add environment variables:
- `SMTP_HOST`
- `SMTP_PORT`
- `SMTP_USER`
- `SMTP_PASSWORD`
- `SMTP_FROM_EMAIL`

### Step 2: Update the Edge Function
Use a Deno SMTP library to send emails.

## Testing Email Sending

After setting up your email service:

1. **Deploy the edge function**:
   ```bash
   supabase functions deploy sensitive-action-email-code
   ```

2. **Test in your app**:
   - Initiate a sensitive action (e.g., change password)
   - Choose "Email code" verification
   - Check if you receive the email with the code

3. **Check edge function logs**:
   - Go to Supabase dashboard
   - Navigate to **Edge Functions** → **sensitive-action-email-code**
   - Check the logs for any errors

## Troubleshooting

### Email Not Received
1. Check spam/junk folder
2. Verify the email address is correct
3. Check edge function logs for errors
4. Verify API key is correct and has permissions

### "Email service not configured" Error
1. Ensure you've added the API key to Supabase environment variables
2. Redeploy the edge function after adding the variable
3. Wait a few seconds for the environment variable to take effect

### API Key Errors
1. Verify the API key is correct
2. Check that the API key has email sending permissions
3. Ensure the API key hasn't expired

### Domain/Sender Issues
1. Verify the sender email is authorized in your email service
2. For Resend, verify your domain in the dashboard
3. For SendGrid, verify your sender email

## Production Recommendations

1. **Use a branded domain**: Instead of `noreply@yourdomain.com`, use a proper domain
2. **Set up SPF/DKIM/DMARC**: Improves email deliverability
3. **Monitor email sending**: Track bounce rates and complaints
4. **Use email templates**: Customize the email template for your brand
5. **Rate limiting**: Consider adding rate limiting to prevent abuse

## Next Steps

1. Choose your email service (Resend recommended)
2. Set up the service and get your API key
3. Add the API key to Supabase environment variables
4. Update the edge function if needed
5. Deploy the function
6. Test email sending in your app
