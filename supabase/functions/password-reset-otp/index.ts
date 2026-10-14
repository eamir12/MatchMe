import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { withInvocationLogging } from "../_shared/edge_function_logger.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

function normalizeText(v: unknown): string {
  return typeof v === "string" ? v.trim() : "";
}
function normalizeEmail(v: unknown): string {
  return normalizeText(v).toLowerCase();
}

function getEmailSubject(language: string): string {
  const subjects: Record<string, string> = {
    en: "Your password reset code",
    es: "Tu código para restablecer la contraseña",
    he: "קוד לאיפוס הסיסמה שלך",
  };
  return subjects[language] || subjects.en;
}

function generatePasswordResetHtml(code: string, language: string): string {
  const t: Record<string, Record<string, string>> = {
    en: {
      title: "Reset your password",
      desc: "You requested to reset your password. Use the code below to continue. It expires in 10 minutes.",
      label: "Your verification code:",
      expiry: "This code will expire in 10 minutes. If you didn't request it, ignore this email.",
      footer: "This is an automated message. Do not reply.",
    },
    es: {
      title: "Restablece tu contraseña",
      desc: "Solicitaste restablecer tu contraseña. Usa el código abajo. Expira en 10 minutos.",
      label: "Tu código de verificación:",
      expiry: "Este código expira en 10 minutos. Si no lo solicitaste, ignora este correo.",
      footer: "Mensaje automático. No respondas.",
    },
    he: {
      title: "איפוס סיסמה",
      desc: "ביקשת לאפס את הסיסמה. השתמש בקוד למטה. הוא יפוג בעוד 10 דקות.",
      label: "קוד האימות שלך:",
      expiry: "הקוד יפוג בעוד 10 דקות. אם לא ביקשת זאת, התעלם מהודעה זו.",
      footer: "הודעה אוטומטית. אין להשיב.",
    },
  };
  const tr = t[language] || t.en;
  const isRTL = language === "he";
  return `<!DOCTYPE html><html ${isRTL ? 'dir="rtl"' : 'dir="ltr"'}><head><meta charset="utf-8"><style>
  body{font-family:Arial,sans-serif;color:#333;${isRTL ? 'direction:rtl;text-align:right;' : ''}}
  .code{font-size:32px;font-weight:bold;letter-spacing:5px;text-align:center;background:#f0f0f0;padding:20px;border-radius:8px;font-family:monospace}
  .container{max-width:600px;margin:0 auto;padding:20px}
  </style></head><body><div class="container">
  <h2>${tr.title}</h2><p>${tr.desc}</p><p>${tr.label}</p>
  <div class="code">${code}</div>
  <p style="font-size:13px;color:#666">${tr.expiry}</p>
  <hr><p style="font-size:11px;color:#999">${tr.footer}</p>
  </div></body></html>`;
}

async function sendPasswordResetEmail(email: string, code: string, language: string): Promise<void> {
  const subject = getEmailSubject(language);
  const html = generatePasswordResetHtml(code, language);
  console.log(`[password-reset-otp] Sending OTP ${code} to ${email} lang=${language}`);

  const resendApiKey = Deno.env.get("RESEND_API_KEY");
  if (resendApiKey) {
    const from = Deno.env.get("RESEND_FROM_EMAIL") || Deno.env.get("FROM_EMAIL") || "MatchMe <onboarding@resend.dev>";
    try {
      const resp = await fetch("https://api.resend.com/emails", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${resendApiKey}`,
        },
        body: JSON.stringify({ from, to: email, subject, html }),
      });
      if (resp.ok) {
        const j = await resp.json();
        console.log(`[password-reset-otp] Resend OK id=${j.id}`);
        return;
      }
      const txt = await resp.text();
      console.warn(`[password-reset-otp] Resend failed ${resp.status}: ${txt}`);
      if (txt.includes("testing emails") || txt.includes("own email")) {
        console.warn("Resend in testing mode – set RESEND_FROM_EMAIL to verified domain");
      }
      throw new Error(`Resend error ${resp.status}: ${txt}`);
    } catch (e) {
      console.error("[password-reset-otp] Resend exception", e);
      throw e;
    }
  }

  // No RESEND_API_KEY – fall back to Supabase's built-in email by calling
  // auth.resetPasswordForEmail would be circular. Log and throw so client knows.
  console.error("[password-reset-otp] RESEND_API_KEY not configured – cannot send OTP");
  throw new Error("Email service not configured (RESEND_API_KEY missing)");
}

Deno.serve(withInvocationLogging("password-reset-otp", async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  const supabaseUrl = normalizeText(Deno.env.get("SUPABASE_URL"));
  const serviceRoleKey = normalizeText(Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"));
  if (!supabaseUrl || !serviceRoleKey) {
    return new Response(JSON.stringify({ success: false, code: "config_missing", message: "Server not configured" }), {
      status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  try {
    if (req.method !== "POST") {
      return new Response(JSON.stringify({ success: false, code: "method_not_allowed", message: "Method not allowed" }), {
        status: 405, headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const body = await req.json() as { email?: string; language?: string };
    const email = normalizeEmail(body.email);
    const language = normalizeText(body.language).toLowerCase() || "en";
    if (!email || !email.includes("@")) {
      return new Response(JSON.stringify({ success: false, code: "invalid_email", message: "Valid email is required" }), {
        status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const admin = createClient(supabaseUrl, serviceRoleKey);

    // Generate a recovery OTP via Supabase Auth admin API.
    // This creates the OTP entry that can be verified with verifyOTP(type: recovery)
    // and returns the raw 6-digit code in properties.email_otp.
    const { data, error } = await admin.auth.admin.generateLink({
      type: "recovery",
      email,
    });

    if (error) {
      console.error("[password-reset-otp] generateLink error", error);
      // For security, don't reveal if email exists – return generic success for user_not_found
      const msg = (error.message || "").toLowerCase();
      if (msg.includes("user not found") || msg.includes("no user")) {
        // Pretend success to avoid user enumeration
        return new Response(JSON.stringify({ success: true, message: "If an account exists, a code was sent" }), {
          status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }
      return new Response(JSON.stringify({ success: false, code: "generate_failed", message: error.message }), {
        status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // Extract OTP – Supabase returns it in different shapes depending on version
    const props = (data as any)?.properties as Record<string, unknown> | undefined;
    const rawOtp = normalizeText(
      props?.email_otp ??
        (data as any)?.email_otp ??
        props?.hashed_token // fallback – not usable as OTP, but log
    );

    // hashed_token is not the 6-digit code; if email_otp missing we cannot send OTP
    // Supabase's generateLink for recovery with email OTP should populate email_otp.
    // If absent, try to derive from properties; otherwise error.
    let otp = rawOtp;
    // If we got a hashed_token (long hex) instead of 6-digit, treat as failure
    if (otp && otp.length > 10) {
      console.warn("[password-reset-otp] generateLink returned hashed_token instead of email_otp – trying alternative extraction");
      // Some Supabase versions nest under `properties` with `email_otp` – already checked
      // If still missing, fail and suggest checking email template / OTP enabled
      otp = "";
    }

    if (!otp) {
      console.error("[password-reset-otp] No email_otp in generateLink response", JSON.stringify(data));
      return new Response(JSON.stringify({
        success: false,
        code: "otp_not_generated",
        message: "Could not generate verification code. Ensure Email OTP is enabled in Supabase Auth settings and RESEND_API_KEY is set.",
      }), {
        status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // Send the OTP via Resend (guarantees OTP, not link, regardless of Supabase email template)
    await sendPasswordResetEmail(email, otp, language);

    return new Response(JSON.stringify({ success: true, message: "Verification code sent" }), {
      status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (e) {
    console.error("[password-reset-otp] exception", e);
    const message = e instanceof Error ? e.message : String(e);
    return new Response(JSON.stringify({ success: false, code: "exception", message }), {
      status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
}));