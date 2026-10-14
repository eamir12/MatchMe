import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { withInvocationLogging } from "../_shared/edge_function_logger.ts";

interface RequestBody {
  email: string;
  language?: string;
}

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "authorization, content-type",
};

Deno.serve(withInvocationLogging("send-email-change-otp", async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const supabaseKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const authHeader = req.headers.get("Authorization") || "";

  if (!supabaseUrl || !supabaseKey) {
    return new Response(
      JSON.stringify({
        success: false,
        message: "Missing Supabase configuration",
      }),
      {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      }
    );
  }

  try {
    const body = await req.json() as RequestBody;
    const email = body.email?.toLowerCase().trim();
    const language = body.language || "en";

    if (!email) {
      return new Response(
        JSON.stringify({
          success: false,
          message: "Email is required",
        }),
        {
          status: 400,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        }
      );
    }

    // Create client with user auth to verify they're authenticated
    const userClient = createClient(supabaseUrl, supabaseKey, {
      global: {
        headers: {
          Authorization: authHeader,
        },
      },
    });

    // Get the authenticated user
    const {
      data: { user },
      error: userError,
    } = await userClient.auth.getUser();

    if (userError || !user) {
      return new Response(
        JSON.stringify({
          success: false,
          message: "Unauthorized",
        }),
        {
          status: 401,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        }
      );
    }

    // Create admin client with service role key
    const adminClient = createClient(supabaseUrl, supabaseKey);

    // Use the existing database function to generate and store the code
    const { data, error } = await adminClient.rpc(
      "generate_sensitive_action_email_code",
      {
        p_user_id: user.id,
        p_email: email,
      }
    );

    if (error) {
      console.error("Error generating code:", error);
      return new Response(
        JSON.stringify({
          success: false,
          message: "Failed to generate verification code",
        }),
        {
          status: 500,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        }
      );
    }

    if (!data || data.length === 0) {
      return new Response(
        JSON.stringify({
          success: false,
          message: "Failed to generate verification code",
        }),
        {
          status: 500,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        }
      );
    }

    const { code, expires_at } = data[0];

    // Send email using Supabase's built-in email template
    try {
      const { error: emailError } = await adminClient.auth.admin.sendEmail(
        email,
        "change_email_address",
        {
          token: code,
        }
      );

      if (emailError) {
        console.error("Error sending email via Supabase:", emailError);
        // Log code for testing if email sending fails
        console.log(`\nFallback - Email OTP for ${email}: ${code}`);
      } else {
        console.log(`Email sent successfully to ${email} using Supabase template`);
      }
    } catch (emailError) {
      console.error("Error sending email:", emailError);
      // Log code for testing if email sending fails
      console.log(`\nFallback - Email OTP for ${email}: ${code}`);
    }

    return new Response(
      JSON.stringify({
        success: true,
        message: "Verification code sent to email",
        expiresAt: expires_at,
      }),
      {
        status: 200,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      }
    );
  } catch (error) {
    console.error("Error:", error);
    return new Response(
      JSON.stringify({
        success: false,
        message: "Internal server error",
      }),
      {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      }
    );
  }
}));