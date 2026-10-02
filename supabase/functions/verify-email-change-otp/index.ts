import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

interface RequestBody {
  email: string;
  code: string;
}

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "authorization, content-type",
};

Deno.serve(async (req) => {
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
    const code = body.code?.trim();

    if (!email || !code) {
      return new Response(
        JSON.stringify({
          success: false,
          message: "Email and code are required",
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

    // Use the existing database function to verify the code
    const { data, error } = await adminClient.rpc(
      "verify_sensitive_action_email_code",
      {
        p_user_id: user.id,
        p_email: email,
        p_code: code,
      }
    );

    if (error) {
      console.error("Error verifying code:", error);
      return new Response(
        JSON.stringify({
          success: false,
          message: "Failed to verify code",
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
          message: "Failed to verify code",
        }),
        {
          status: 500,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        }
      );
    }

    const { success, message } = data[0];

    if (!success) {
      return new Response(
        JSON.stringify({
          success: false,
          message: message,
        }),
        {
          status: 400,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        }
      );
    }

    return new Response(
      JSON.stringify({
        success: true,
        message: "Code verified successfully",
        newEmail: email,
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
});
