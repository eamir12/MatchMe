import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

interface RequestBody {
  action: "generate" | "verify" | "resend" | "generate_email_change_code" | "verify_email_change_code" | "complete_email_change" | "send_code_email" | "send_email_changed_notification";
  email?: string;
  new_email?: string;
  old_email?: string;
  code?: string;
  language?: string;
  force_resend?: boolean;
}

interface GenerateResponse {
  success: boolean;
  message: string;
  expiresAt?: string;
}

interface VerifyResponse {
  success: boolean;
  message: string;
}

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "authorization, content-type",
};

async function sendEmailCode(
  email: string,
  code: string,
  supabaseUrl: string,
  supabaseKey: string,
  language: string = "en"
): Promise<void> {
  const emailBody = generateEmailHtml(code, language);
  const emailSubject = getEmailSubject(language);
  
  console.log("=".repeat(60));
  console.log("EMAIL VERIFICATION CODE");
  console.log("=".repeat(60));
  console.log(`To: ${email}`);
  console.log(`Subject: ${emailSubject}`);
  console.log(`Code: ${code}`);
  console.log("=".repeat(60));
  
  // Collect all errors to provide meaningful diagnostic if every provider fails
  const errors: string[] = [];

  // 1) Try Resend if configured – this is the preferred provider
  const resendApiKey = Deno.env.get("RESEND_API_KEY");
  if (resendApiKey) {
    // Allow operators to configure a verified sender domain via env.
    // Hard-coded onboarding@resend.dev only delivers to the Resend account owner,
    // so it must NOT be used for arbitrary user emails in production.
    const resendFrom =
      Deno.env.get("RESEND_FROM_EMAIL") ||
      Deno.env.get("FROM_EMAIL") ||
      "MatchMe <onboarding@resend.dev>";
    try {
      const response = await fetch("https://api.resend.com/emails", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Authorization": `Bearer ${resendApiKey}`,
        },
        body: JSON.stringify({
          from: resendFrom,
          to: email,
          subject: emailSubject,
          html: emailBody,
        }),
      });

      if (response.ok) {
        const result = await response.json();
        console.log(`Email sent successfully via Resend to ${email}. Message ID: ${result.id}`);
        return;
      } else {
        const errorData = await response.text();
        const msg = `Resend API error ${response.status}: ${errorData}`;
        console.warn(msg);
        errors.push(msg);
        // If Resend returns a testing-restriction error, surface it clearly
        if (errorData.includes("testing emails") || errorData.includes("own email")) {
          console.warn(
            "Resend is in testing mode (onboarding@resend.dev only sends to your own address). " +
            "Set RESEND_FROM_EMAIL to a verified domain to deliver to any user. " +
            "See EMAIL_SETUP_GUIDE.md"
          );
        }
      }
    } catch (resendError) {
      const msg = `Failed to send via Resend: ${resendError}`;
      console.warn(msg);
      errors.push(msg);
    }
  } else {
    const msg = "RESEND_API_KEY not configured";
    console.warn(msg);
    errors.push(msg);
  }

  // 2) Fallback: try to send via Supabase Auth email (uses the same SMTP that
  // powers registration / password-reset OTPs, which are known to arrive).
  // We use a service-role client to invoke `signInWithOtp` for the target email
  // would create a different Supabase OTP, so instead we call the privileged
  // `admin.generateLink`/`admin.inviteUserByEmail` path via raw fetch if available,
  // otherwise attempt a direct SMTP send if SMTP env is configured.
  // If no fallback is configured, we surface a hard error so callers don't
  // silently succeed while the user receives nothing.
  const smtpHost = Deno.env.get("SMTP_HOST");
  const smtpUser = Deno.env.get("SMTP_USER");
  const smtpPass = Deno.env.get("SMTP_PASSWORD");
  if (smtpHost && smtpUser && smtpPass) {
    try {
      // Dynamically import nodemailer SMTP – Deno edge supports npm:
      // deno-lint-ignore no-explicit-any
      let nodemailer: any;
      try {
        // @ts-ignore: Deno npm import
        nodemailer = await import("npm:nodemailer@6.9.9");
      } catch (_) {
        errors.push("SMTP configured but nodemailer not available");
        throw new Error("nodemailer not available");
      }
      const transporter = nodemailer.createTransport({
        host: smtpHost,
        port: parseInt(Deno.env.get("SMTP_PORT") || "587", 10),
        secure: Deno.env.get("SMTP_SECURE") === "true",
        auth: { user: smtpUser, pass: smtpPass },
      });
      const fromEmail = Deno.env.get("SMTP_FROM_EMAIL") || smtpUser;
      await transporter.sendMail({
        from: fromEmail,
        to: email,
        subject: emailSubject,
        html: emailBody,
      });
      console.log(`Email sent successfully via SMTP to ${email}`);
      return;
    } catch (smtpError) {
      const msg = `Failed to send via SMTP: ${smtpError}`;
      console.warn(msg);
      errors.push(msg);
    }
  }

  // No provider succeeded – throw so handleGenerate/handleResend can return
  // an error to the client instead of a false "sent" success.
  console.error("All email providers failed:", errors.join(" | "));
  throw new Error(
    `Failed to send verification email. ${errors.join(" | ")} ` +
    `(Code was ${code} – check edge function logs). ` +
    `Configure RESEND_API_KEY + RESEND_FROM_EMAIL with a verified domain ` +
    `or SMTP_HOST/SMTP_USER/SMTP_PASSWORD.`
  );
}

/**
 * MatchMe ships exactly three languages: en, es, he.
 * The `language` field arrives from the request body, so it is untrusted —
 * normalise it so an unsupported value can never pick a translation table and
 * so `isRTL` is derived from a validated locale. Keep in sync with the
 * AppLanguage entries in lib/providers/locale_provider.dart.
 */
function normalizeSupportedLocale(raw: unknown): string {
  const s = String(raw ?? '').trim().toLowerCase();
  if (s.startsWith('he')) return 'he';
  if (s.startsWith('es')) return 'es';
  return 'en';
}

function getEmailSubject(language: string = "en"): string {
  language = normalizeSupportedLocale(language);
  const subjects: Record<string, string> = {
    en: "Your verification code for sensitive account changes",
    es: "Tu código de verificación para cambios de cuenta sensibles",
    he: "קוד האימות שלך לשינויים חשובים בחשבון",
  };
  return subjects[language] || subjects.en;
}

function generateEmailHtml(code: string, language: string = "en"): string {
  language = normalizeSupportedLocale(language);
  const translations: Record<string, Record<string, string>> = {
    en: {
      title: "Verify Your Identity",
      description: "You requested to perform a sensitive action on your account. To continue, please verify your identity using the code below.",
      codeLabel: "Your verification code is:",
      expiration: "This code will expire in 10 minutes.",
      security: "Security Notice",
      securityText: "If you did not request this code, please ignore this email. Do not share this code with anyone.",
      footer: "This is an automated message. Please do not reply to this email.",
    },
    es: {
      title: "Verifica tu identidad",
      description: "Solicitaste realizar una acción sensible en tu cuenta. Para continuar, verifica tu identidad usando el código a continuación.",
      codeLabel: "Tu código de verificación es:",
      expiration: "Este código expirará en 10 minutos.",
      security: "Aviso de seguridad",
      securityText: "Si no solicitaste este código, ignora este correo. No compartas este código con nadie.",
      footer: "Este es un mensaje automatizado. Por favor, no respondas a este correo.",
    },
    he: {
      title: "אמת את הזהות שלך",
      description: "ביקשת לבצע פעולה רגישה בחשבונך. כדי להמשיך, אמת את הזהות שלך באמצעות הקוד למטה.",
      codeLabel: "קוד האימות שלך הוא:",
      expiration: "קוד זה יפוג בעוד 10 דקות.",
      security: "הודעת אבטחה",
      securityText: "אם לא ביקשת קוד זה, התעלם מהודעת דוא״ל זו. אל תשתף קוד זה עם אף אחד.",
      footer: "זו הודעה אוטומטית. אנא אל תשיב להודעת דוא״ל זו.",
    },
  };

  const t = translations[language] || translations.en;
  const isRTL = language === "he";

  return `
    <!DOCTYPE html>
    <html ${isRTL ? 'dir="rtl"' : 'dir="ltr"'}>
      <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <style>
          body {
            ${isRTL ? 'direction: rtl !important; text-align: right !important;' : 'direction: ltr; text-align: left;'}
            font-family: Arial, sans-serif;
            line-height: 1.6;
            color: #333;
            margin: 0;
            padding: 0;
          }
          .container {
            max-width: 600px;
            margin: 0 auto;
            padding: 20px;
            ${isRTL ? 'direction: rtl; text-align: right;' : 'direction: ltr; text-align: left;'}
          }
          .header {
            background-color: #f5f5f5;
            padding: 20px;
            border-radius: 5px;
            margin-bottom: 20px;
            ${isRTL ? 'direction: rtl; text-align: right;' : 'direction: ltr; text-align: left;'}
          }
          .header h2 {
            margin-top: 0;
            ${isRTL ? 'text-align: right;' : 'text-align: left;'}
          }
          .header p {
            ${isRTL ? 'text-align: right;' : 'text-align: left;'}
          }
          .code-box {
            background-color: #f0f0f0;
            padding: 20px;
            border-radius: 5px;
            text-align: center;
            margin: 20px 0;
          }
          .code {
            font-size: 32px;
            font-weight: bold;
            letter-spacing: 5px;
            color: #000;
            font-family: monospace;
            text-align: center;
            direction: ltr;
          }
          .warning {
            background-color: #fff3cd;
            border: 1px solid #ffc107;
            padding: 10px;
            border-radius: 5px;
            margin: 20px 0;
            font-size: 14px;
            ${isRTL ? 'text-align: right; direction: rtl;' : 'text-align: left; direction: ltr;'}
          }
          .footer {
            color: #666;
            font-size: 12px;
            margin-top: 20px;
            border-top: 1px solid #ddd;
            padding-top: 10px;
            ${isRTL ? 'text-align: right;' : 'text-align: left;'}
          }
          p {
            ${isRTL ? 'text-align: right;' : 'text-align: left;'}
          }
        </style>
      </head>
      <body ${isRTL ? 'dir="rtl" align="right" style="direction: rtl !important; text-align: right !important;"' : 'dir="ltr" align="left"'}>
        <div class="container" ${isRTL ? 'dir="rtl" style="direction: rtl; text-align: right;"' : 'dir="ltr"'}>
          <div class="header" ${isRTL ? 'dir="rtl" style="direction: rtl; text-align: right;"' : 'dir="ltr"'}>
            <h2 ${isRTL ? 'dir="rtl" style="text-align: right;"' : 'dir="ltr"'}>${t.title}</h2>
            <p ${isRTL ? 'dir="rtl" style="text-align: right;"' : 'dir="ltr"'}>${t.description}</p>
          </div>

          <p ${isRTL ? 'dir="rtl" style="text-align: right;"' : 'dir="ltr"'}>${t.codeLabel}</p>

          <div class="code-box">
            <div class="code" dir="ltr">${code}</div>
          </div>

          <p ${isRTL ? 'dir="rtl" style="text-align: right;"' : 'dir="ltr"'}>${t.expiration}</p>

          <div class="warning" ${isRTL ? 'dir="rtl" style="direction: rtl; text-align: right;"' : 'dir="ltr"'}>
            <strong>⚠️ ${t.security}:</strong> ${t.securityText}
          </div>

          <div class="footer" ${isRTL ? 'dir="rtl" style="text-align: right;"' : 'dir="ltr"'}>
            <p ${isRTL ? 'dir="rtl" style="text-align: right;"' : 'dir="ltr"'}>${t.footer}</p>
          </div>
        </div>
      </body>
    </html>
  `;
}

function generateEmailChangedNotificationHtml(oldEmail: string, newEmail: string, language: string = "en"): string {
  language = normalizeSupportedLocale(language);
  const translations: Record<string, Record<string, string>> = {
    en: {
      title: "Email Address Changed",
      description: "Your email address has been successfully changed.",
      oldEmailLabel: "Old email address:",
      newEmailLabel: "New email address:",
      security: "Security Notice",
      securityText: "If you did not make this change, please contact our support team immediately.",
      footer: "This is an automated message. Please do not reply to this email.",
    },
    es: {
      title: "Dirección de Correo Electrónico Cambiada",
      description: "Tu dirección de correo electrónico ha sido cambiada exitosamente.",
      oldEmailLabel: "Dirección de correo anterior:",
      newEmailLabel: "Nueva dirección de correo:",
      security: "Aviso de seguridad",
      securityText: "Si no realizaste este cambio, por favor contacta a nuestro equipo de soporte inmediatamente.",
      footer: "Este es un mensaje automatizado. Por favor, no respondas a este correo.",
    },
    he: {
      title: "כתובת הדוא״ל שונתה",
      description: "כתובת הדוא״ל שלך שונתה בהצלחה.",
      oldEmailLabel: "כתובת הדוא״ל הישנה:",
      newEmailLabel: "כתובת הדוא״ל החדשה:",
      security: "הודעת אבטחה",
      securityText: "אם לא ביצעת שינוי זה, אנא צור קשר עם צוות התמיכה שלנו מיד.",
      footer: "זו הודעה אוטומטית. אנא אל תשיב להודעת דוא״ל זו.",
    },
  };

  const t = translations[language] || translations.en;
  const isRTL = language === "he";

  return `
    <!DOCTYPE html>
    <html ${isRTL ? 'dir="rtl"' : 'dir="ltr"'}>
      <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <style>
          body {
            ${isRTL ? 'direction: rtl !important; text-align: right !important;' : 'direction: ltr; text-align: left;'}
            font-family: Arial, sans-serif;
            line-height: 1.6;
            color: #333;
            margin: 0;
            padding: 0;
          }
          .container {
            max-width: 600px;
            margin: 0 auto;
            padding: 20px;
            ${isRTL ? 'direction: rtl; text-align: right;' : 'direction: ltr; text-align: left;'}
          }
          .header {
            background-color: #f5f5f5;
            padding: 20px;
            border-radius: 5px;
            margin-bottom: 20px;
            ${isRTL ? 'direction: rtl; text-align: right;' : 'direction: ltr; text-align: left;'}
          }
          .header h2 {
            margin-top: 0;
            ${isRTL ? 'text-align: right;' : 'text-align: left;'}
          }
          .header p {
            ${isRTL ? 'text-align: right;' : 'text-align: left;'}
          }
          .email-info {
            background-color: #f9f9f9;
            padding: 15px;
            border-radius: 5px;
            margin: 20px 0;
            border-left: 4px solid #007bff;
          }
          .email-row {
            margin: 10px 0;
            ${isRTL ? 'text-align: right;' : 'text-align: left;'}
          }
          .email-label {
            font-weight: bold;
            ${isRTL ? 'text-align: right;' : 'text-align: left;'}
          }
          .warning {
            background-color: #fff3cd;
            border: 1px solid #ffc107;
            padding: 10px;
            border-radius: 5px;
            margin: 20px 0;
            font-size: 14px;
            ${isRTL ? 'text-align: right; direction: rtl;' : 'text-align: left; direction: ltr;'}
          }
          .footer {
            color: #666;
            font-size: 12px;
            margin-top: 20px;
            border-top: 1px solid #ddd;
            padding-top: 10px;
            ${isRTL ? 'text-align: right;' : 'text-align: left;'}
          }
          p {
            ${isRTL ? 'text-align: right;' : 'text-align: left;'}
          }
        </style>
      </head>
      <body ${isRTL ? 'dir="rtl" align="right" style="direction: rtl !important; text-align: right !important;"' : 'dir="ltr" align="left"'}>
        <div class="container" ${isRTL ? 'dir="rtl" style="direction: rtl; text-align: right;"' : 'dir="ltr"'}>
          <div class="header" ${isRTL ? 'dir="rtl" style="direction: rtl; text-align: right;"' : 'dir="ltr"'}>
            <h2 ${isRTL ? 'dir="rtl" style="text-align: right;"' : 'dir="ltr"'}>${t.title}</h2>
            <p ${isRTL ? 'dir="rtl" style="text-align: right;"' : 'dir="ltr"'}>${t.description}</p>
          </div>

          <div class="email-info">
            <div class="email-row">
              <span class="email-label">${t.oldEmailLabel}</span>
              <div>${oldEmail}</div>
            </div>
            <div class="email-row">
              <span class="email-label">${t.newEmailLabel}</span>
              <div>${newEmail}</div>
            </div>
          </div>

          <div class="warning" ${isRTL ? 'dir="rtl" style="direction: rtl; text-align: right;"' : 'dir="ltr"'}>
            <strong>⚠️ ${t.security}:</strong> ${t.securityText}
          </div>

          <div class="footer" ${isRTL ? 'dir="rtl" style="text-align: right;"' : 'dir="ltr"'}>
            <p ${isRTL ? 'dir="rtl" style="text-align: right;"' : 'dir="ltr"'}>${t.footer}</p>
          </div>
        </div>
      </body>
    </html>
  `;
}

async function handleGenerate(
  body: RequestBody,
  supabaseUrl: string,
  supabaseKey: string,
  authHeader: string
): Promise<GenerateResponse> {
  const supabase = createClient(supabaseUrl, supabaseKey, {
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
  } = await supabase.auth.getUser();

  if (userError || !user) {
    return {
      success: false,
      message: "Unauthorized",
    };
  }

  const email = body.email?.toLowerCase().trim();

  if (!email) {
    return {
      success: false,
      message: "Email is required",
    };
  }

  // Verify the email matches the user's email
  if (user.email?.toLowerCase() !== email) {
    return {
      success: false,
      message: "Email does not match authenticated user",
    };
  }

  try {
    // Generate and store the email code
    const { data, error } = await supabase.rpc(
      "generate_sensitive_action_email_code",
      {
        p_user_id: user.id,
        p_email: email,
      }
    );

    if (error) {
      console.error("Error generating email code:", error);
      return {
        success: false,
        message: "Failed to generate email code",
      };
    }

    if (!data || data.length === 0) {
      return {
        success: false,
        message: "Failed to generate email code",
      };
    }

    const { code, expires_at } = data[0];

    // Send the email code
    try {
      const language = body.language || "en";
      await sendEmailCode(email, code, supabaseUrl, supabaseKey, language);
    } catch (emailError) {
      console.error("Failed to send email:", emailError);
      return {
        success: false,
        message: emailError instanceof Error ? emailError.message : "Failed to send verification email. Please check your email address and try again.",
      };
    }

    return {
      success: true,
      message: "Email code generated and sent",
      expiresAt: expires_at,
    };
  } catch (error) {
    console.error("Error in handleGenerate:", error);
    return {
      success: false,
      message: "Internal server error",
    };
  }
}

async function handleResend(
  body: RequestBody,
  supabaseUrl: string,
  supabaseKey: string,
  authHeader: string
): Promise<GenerateResponse> {
  const supabase = createClient(supabaseUrl, supabaseKey, {
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
  } = await supabase.auth.getUser();

  if (userError || !user) {
    return {
      success: false,
      message: "Unauthorized",
    };
  }

  const email = body.email?.toLowerCase().trim();

  if (!email) {
    return {
      success: false,
      message: "Email is required",
    };
  }

  // Verify the email matches the user's email
  if (user.email?.toLowerCase() !== email) {
    return {
      success: false,
      message: "Email does not match authenticated user",
    };
  }

  try {
    // Get the active email code without generating a new one
    const { data, error } = await supabase.rpc(
      "get_active_sensitive_action_email_code",
      {
        p_user_id: user.id,
        p_email: email,
      }
    );

    if (error) {
      console.error("Error retrieving email code:", error);
      return {
        success: false,
        message: "Failed to retrieve email code",
      };
    }

    let code: string;
    let expiresAt: string;
    let isNewCode = false;

    if (!data || data.length === 0) {
      // No active code found, generate a new one
      console.log("No active code found, generating new code");
      const { data: generateData, error: generateError } = await supabase.rpc(
        "generate_sensitive_action_email_code",
        {
          p_user_id: user.id,
          p_email: email,
        }
      );

      if (generateError) {
        console.error("Error generating new email code:", generateError);
        return {
          success: false,
          message: "Failed to generate email code",
        };
      }

      if (!generateData || generateData.length === 0) {
        return {
          success: false,
          message: "Failed to generate email code",
        };
      }

      code = generateData[0].code;
      expiresAt = generateData[0].expires_at;
      isNewCode = true;
    } else {
      // Check if the existing code is older than 10 minutes
      const codeCreatedAt = new Date(data[0].created_at);
      const now = new Date();
      const ageInMinutes = (now.getTime() - codeCreatedAt.getTime()) / (1000 * 60);

      if (ageInMinutes > 10) {
        // Code is older than 10 minutes, generate a new one
        console.log(`Existing code is ${ageInMinutes.toFixed(2)} minutes old, generating new code`);
        const { data: generateData, error: generateError } = await supabase.rpc(
          "generate_sensitive_action_email_code",
          {
            p_user_id: user.id,
            p_email: email,
          }
        );

        if (generateError) {
          console.error("Error generating new email code:", generateError);
          return {
            success: false,
            message: "Failed to generate email code",
          };
        }

        if (!generateData || generateData.length === 0) {
          return {
            success: false,
            message: "Failed to generate email code",
          };
        }

        code = generateData[0].code;
        expiresAt = generateData[0].expires_at;
        isNewCode = true;
      } else {
        // Code is still fresh, use the existing one
        console.log(`Existing code is ${ageInMinutes.toFixed(2)} minutes old, reusing existing code`);
        code = data[0].code;
        expiresAt = data[0].expires_at;
        isNewCode = false;
      }
    }

    // Send the email code (either new or existing)
    try {
      const language = body.language || "en";
      await sendEmailCode(email, code, supabaseUrl, supabaseKey, language);
    } catch (emailError) {
      console.error("Failed to send email:", emailError);
      return {
        success: false,
        message: emailError instanceof Error ? emailError.message : "Failed to send verification email. Please try again.",
      };
    }

    return {
      success: true,
      message: isNewCode ? "New email code generated and sent" : "Email code resent",
      expiresAt: expiresAt,
    };
  } catch (error) {
    console.error("Error in handleResend:", error);
    return {
      success: false,
      message: "Internal server error",
    };
  }
}

async function handleVerify(
  body: RequestBody,
  supabaseUrl: string,
  supabaseKey: string,
  authHeader: string
): Promise<VerifyResponse> {
  const supabase = createClient(supabaseUrl, supabaseKey, {
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
  } = await supabase.auth.getUser();

  if (userError || !user) {
    return {
      success: false,
      message: "Unauthorized",
    };
  }

  const email = body.email?.toLowerCase().trim();
  const code = body.code?.trim();

  if (!email || !code) {
    return {
      success: false,
      message: "Email and code are required",
    };
  }

  // Verify the email matches the user's email
  if (user.email?.toLowerCase() !== email) {
    return {
      success: false,
      message: "Email does not match authenticated user",
    };
  }

  try {
    // Verify the email code
    const { data, error } = await supabase.rpc(
      "verify_sensitive_action_email_code",
      {
        p_user_id: user.id,
        p_email: email,
        p_code: code,
      }
    );

    if (error) {
      console.error("Error verifying email code:", error);
      return {
        success: false,
        message: "Failed to verify email code",
      };
    }

    if (!data || data.length === 0) {
      return {
        success: false,
        message: "Failed to verify email code",
      };
    }

    const { success, message } = data[0];

    return {
      success,
      message,
    };
  } catch (error) {
    console.error("Error in handleVerify:", error);
    return {
      success: false,
      message: "Internal server error",
    };
  }
}

async function handleGenerateEmailChangeCode(
  body: RequestBody,
  supabaseUrl: string,
  supabaseKey: string,
  authHeader: string
): Promise<GenerateResponse> {
  const supabase = createClient(supabaseUrl, supabaseKey, {
    global: {
      headers: {
        Authorization: authHeader,
      },
    },
  });

  const {
    data: { user },
    error: userError,
  } = await supabase.auth.getUser();

  if (userError || !user) {
    return {
      success: false,
      message: "Unauthorized",
    };
  }

  const newEmail = body.new_email?.toLowerCase().trim();

  if (!newEmail) {
    return {
      success: false,
      message: "New email is required",
    };
  }

  if (user.email?.toLowerCase() === newEmail) {
    return {
      success: false,
      message: "New email must be different from current email",
    };
  }

  try {
    const { data, error } = await supabase.rpc(
      "generate_email_change_code",
      {
        p_user_id: user.id,
        p_new_email: newEmail,
      }
    );

    if (error) {
      console.error("Error generating email change code:", error);
      return {
        success: false,
        message: "Failed to generate verification code",
      };
    }

    if (!data || data.length === 0) {
      return {
        success: false,
        message: "Failed to generate verification code",
      };
    }

    const { code, expires_at } = data[0];

    try {
      const language = body.language || "en";
      await sendEmailCode(newEmail, code, supabaseUrl, supabaseKey, language);
    } catch (emailError) {
      console.error("Failed to send email:", emailError);
      return {
        success: false,
        message: emailError instanceof Error ? emailError.message : "Failed to send verification email",
      };
    }

    return {
      success: true,
      message: "Verification code sent to new email",
      expiresAt: expires_at,
    };
  } catch (error) {
    console.error("Error in handleGenerateEmailChangeCode:", error);
    return {
      success: false,
      message: "Internal server error",
    };
  }
}

async function handleVerifyEmailChangeCode(
  body: RequestBody,
  supabaseUrl: string,
  supabaseKey: string,
  authHeader: string
): Promise<VerifyResponse> {
  const supabase = createClient(supabaseUrl, supabaseKey, {
    global: {
      headers: {
        Authorization: authHeader,
      },
    },
  });

  const {
    data: { user },
    error: userError,
  } = await supabase.auth.getUser();

  if (userError || !user) {
    return {
      success: false,
      message: "Unauthorized",
    };
  }

  const code = body.code?.trim();

  if (!code) {
    return {
      success: false,
      message: "Code is required",
    };
  }

  try {
    const { data, error } = await supabase.rpc(
      "verify_email_change_code",
      {
        p_user_id: user.id,
        p_code: code,
      }
    );

    if (error) {
      console.error("Error verifying email change code:", error);
      return {
        success: false,
        message: "Failed to verify code",
      };
    }

    if (!data || data.length === 0) {
      return {
        success: false,
        message: "Failed to verify code",
      };
    }

    const { success, message } = data[0];

    return {
      success,
      message,
    };
  } catch (error) {
    console.error("Error in handleVerifyEmailChangeCode:", error);
    return {
      success: false,
      message: "Internal server error",
    };
  }
}

async function handleCompleteEmailChange(
  body: RequestBody,
  supabaseUrl: string,
  supabaseKey: string,
  authHeader: string
): Promise<VerifyResponse> {
  const supabase = createClient(supabaseUrl, supabaseKey, {
    global: {
      headers: {
        Authorization: authHeader,
      },
    },
  });

  const {
    data: { user },
    error: userError,
  } = await supabase.auth.getUser();

  if (userError || !user) {
    return {
      success: false,
      message: "Unauthorized",
    };
  }

  const code = body.code?.trim();

  if (!code) {
    return {
      success: false,
      message: "Code is required",
    };
  }

  try {
    const { data, error } = await supabase.rpc(
      "complete_email_change",
      {
        p_user_id: user.id,
        p_code: code,
      }
    );

    if (error) {
      console.error("Error completing email change:", error);
      return {
        success: false,
        message: "Failed to complete email change",
      };
    }

    if (!data || data.length === 0) {
      return {
        success: false,
        message: "Failed to complete email change",
      };
    }

    const { success, message } = data[0];

    return {
      success,
      message,
    };
  } catch (error) {
    console.error("Error in handleCompleteEmailChange:", error);
    return {
      success: false,
      message: "Internal server error",
    };
  }
}

async function handleSendCodeEmail(
  body: RequestBody,
  supabaseUrl: string,
  supabaseKey: string
): Promise<VerifyResponse> {
  const email = body.email?.toLowerCase().trim();
  const code = body.code?.trim();
  const language = body.language || "en";

  if (!email || !code) {
    return {
      success: false,
      message: "Email and code are required",
    };
  }

  try {
    await sendEmailCode(email, code, supabaseUrl, supabaseKey, language);
    return {
      success: true,
      message: "Email sent successfully",
    };
  } catch (error) {
    console.error("Error in handleSendCodeEmail:", error);
    return {
      success: false,
      message: "Failed to send email",
    };
  }
}

async function handleSendEmailChangedNotification(
  body: RequestBody,
  supabaseUrl: string,
  supabaseKey: string
): Promise<VerifyResponse> {
  const oldEmail = body.old_email?.toLowerCase().trim();
  const newEmail = body.new_email?.toLowerCase().trim();
  const language = body.language || "en";

  if (!oldEmail || !newEmail) {
    return {
      success: false,
      message: "Old email and new email are required",
    };
  }

  try {
    const emailBody = generateEmailChangedNotificationHtml(oldEmail, newEmail, language);
    const emailSubject = "Email Address Changed";

    console.log("=".repeat(60));
    console.log("EMAIL CHANGED NOTIFICATION");
    console.log("=".repeat(60));
    console.log(`To: ${oldEmail}`);
    console.log(`Subject: ${emailSubject}`);
    console.log("=".repeat(60));
    console.log("HTML Body:");
    console.log(emailBody);
    console.log("=".repeat(60));

    const resendApiKey = Deno.env.get("RESEND_API_KEY");
    const resendFrom =
      Deno.env.get("RESEND_FROM_EMAIL") ||
      Deno.env.get("FROM_EMAIL") ||
      "MatchMe <onboarding@resend.dev>";
    if (resendApiKey) {
      try {
        const response = await fetch("https://api.resend.com/emails", {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            "Authorization": `Bearer ${resendApiKey}`,
          },
          body: JSON.stringify({
            from: resendFrom,
            to: oldEmail,
            subject: emailSubject,
            html: emailBody,
          }),
        });

        if (response.ok) {
          const result = await response.json();
          console.log(`Email sent successfully via Resend to ${oldEmail}. Message ID: ${result.id}`);
          return {
            success: true,
            message: "Notification email sent successfully",
          };
        } else {
          const errorData = await response.text();
          console.warn("Resend API error:", response.status, errorData);
          throw new Error(`Resend API error ${response.status}: ${errorData}`);
        }
      } catch (resendError) {
        console.warn("Failed to send via Resend:", resendError);
        throw resendError instanceof Error ? resendError : new Error(String(resendError));
      }
    }

    throw new Error(
      "Failed to send notification email: RESEND_API_KEY not configured. " +
      "Configure RESEND_API_KEY and RESEND_FROM_EMAIL with a verified domain."
    );
  } catch (error) {
    console.error("Error in handleSendEmailChangedNotification:", error);
    return {
      success: false,
      message: "Failed to send notification email",
    };
  }
}

Deno.serve(async (req) => {
  // Handle CORS
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
    const action = body.action;

    let response: GenerateResponse | VerifyResponse;

    if (action === "generate") {
      response = await handleGenerate(body, supabaseUrl, supabaseKey, authHeader);
    } else if (action === "resend") {
      response = await handleResend(body, supabaseUrl, supabaseKey, authHeader);
    } else if (action === "verify") {
      response = await handleVerify(body, supabaseUrl, supabaseKey, authHeader);
    } else if (action === "generate_email_change_code") {
      response = await handleGenerateEmailChangeCode(body, supabaseUrl, supabaseKey, authHeader);
    } else if (action === "verify_email_change_code") {
      response = await handleVerifyEmailChangeCode(body, supabaseUrl, supabaseKey, authHeader);
    } else if (action === "complete_email_change") {
      response = await handleCompleteEmailChange(body, supabaseUrl, supabaseKey, authHeader);
    } else if (action === "send_code_email") {
      response = await handleSendCodeEmail(body, supabaseUrl, supabaseKey);
    } else if (action === "send_email_changed_notification") {
      response = await handleSendEmailChangedNotification(body, supabaseUrl, supabaseKey);
    } else {
      return new Response(
        JSON.stringify({
          success: false,
          message: "Invalid action",
        }),
        {
          status: 400,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        }
      );
    }

    return new Response(JSON.stringify(response), {
      status: response.success ? 200 : 400,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
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
