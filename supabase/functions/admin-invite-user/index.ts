import { createClient } from "npm:@supabase/supabase-js@2";

const corsHeaders = (origin: string | null) => ({
  "Access-Control-Allow-Origin": origin || "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Vary": "Origin",
});

function jsonResponse(body: Record<string, unknown>, status: number, origin: string | null) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders(origin), "Content-Type": "application/json" },
  });
}

Deno.serve(async (request) => {
  const origin = request.headers.get("origin");
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders(origin) });
  }
  if (request.method !== "POST") {
    return jsonResponse({ success: false, message: "Method not allowed" }, 405, origin);
  }

  const authorization = request.headers.get("authorization") || "";
  if (!authorization.toLowerCase().startsWith("bearer ")) {
    return jsonResponse({ success: false, message: "กรุณาเข้าสู่ระบบผู้ดูแลก่อน" }, 401, origin);
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !anonKey || !serviceRoleKey) {
    console.error("Admin invitation function is missing Supabase environment variables");
    return jsonResponse({ success: false, message: "ระบบเชิญผู้ดูแลยังตั้งค่าไม่ครบ" }, 500, origin);
  }

  const caller = createClient(supabaseUrl, anonKey, {
    auth: { autoRefreshToken: false, persistSession: false },
    global: { headers: { Authorization: authorization } },
  });
  const accessToken = authorization.slice(7).trim();
  const { data: userData, error: userError } = await caller.auth.getUser(accessToken);
  if (userError || !userData.user) {
    return jsonResponse({ success: false, message: "เซสชันหมดอายุ กรุณาเข้าสู่ระบบใหม่" }, 401, origin);
  }

  const { data: isAdmin, error: adminCheckError } = await caller.rpc("is_admin");
  if (adminCheckError || isAdmin !== true) {
    return jsonResponse({ success: false, message: "ไม่มีสิทธิ์เพิ่มผู้ดูแลระบบ" }, 403, origin);
  }

  let body: { email?: unknown; redirectTo?: unknown; resend?: unknown };
  try {
    body = await request.json();
  } catch {
    return jsonResponse({ success: false, message: "ข้อมูลคำขอไม่ถูกต้อง" }, 400, origin);
  }

  const email = typeof body.email === "string" ? body.email.trim().toLowerCase() : "";
  const resend = body.resend === true;
  if (!email || email.length > 254 || !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) {
    return jsonResponse({ success: false, message: "กรุณากรอกอีเมลให้ถูกต้อง" }, 400, origin);
  }

  const redirectTo = typeof body.redirectTo === "string" ? body.redirectTo : "";
  try {
    const target = new URL(redirectTo);
    if (!origin || target.origin !== origin || target.username || target.password) {
      throw new Error("Invalid invitation redirect");
    }
  } catch {
    return jsonResponse({ success: false, message: "URL ของเว็บไซต์ไม่ตรงกับต้นทาง กรุณาเปิดระบบจากเว็บไซต์โรงเรียนแล้วลองอีกครั้ง" }, 400, origin);
  }

  const service = createClient(supabaseUrl, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
  try {
    const grantAdmin = async () => caller.rpc("admin_add_user_by_email", { p_email: email });
    const finishExistingAccount = async (grant: Record<string, unknown>) => {
      // Unconfirmed users need another invite link after an expired token.
      // Confirmed users only get a recovery link when the admin explicitly
      // requests a resend, so adding an existing admin remains idempotent.
      if (grant.email_confirmed === false || resend) {
        const linkType = grant.email_confirmed === false ? "invite" : "recovery";
        const { data: linkData, error } = await service.auth.admin.generateLink({
          type: linkType,
          email,
          options: { redirectTo },
        });
        if (error) {
          return {
            success: false,
            email,
            message: "เพิ่มสิทธิ์แล้ว แต่สร้างลิงก์ใหม่ไม่สำเร็จ กรุณาลองอีกครั้ง",
          };
        }
        const inviteLink = linkData?.properties?.action_link;
        if (!inviteLink) {
          return {
            success: false,
            email,
            message: "เพิ่มสิทธิ์แล้ว แต่ Supabase ไม่ได้คืนลิงก์ใหม่ กรุณาลองอีกครั้ง",
          };
        }
        return {
          success: true,
          invited: true,
          resent: true,
          email,
          inviteLink,
        };
      }
      return { success: true, invited: false, email };
    };

    let { data: grant, error: grantError } = await grantAdmin();
    if (grantError) throw grantError;
    if (grant?.success) {
      return jsonResponse(await finishExistingAccount(grant), 200, origin);
    }
    if (grant?.code !== "AUTH_USER_NOT_FOUND") {
      return jsonResponse({ success: false, message: grant?.message || "เพิ่มผู้ดูแลไม่สำเร็จ" }, 400, origin);
    }

    const { data: linkData, error: linkError } = await service.auth.admin.generateLink({
      type: "invite",
      email,
      options: { redirectTo },
    });
    if (linkError) {
      const message = String(linkError.message || "").toLowerCase();
      if (message.includes("redirect") || message.includes("allow list")) {
        return jsonResponse({
          success: false,
          message: "Supabase ยังไม่อนุญาต URL กลับจากลิงก์เชิญ ให้เพิ่ม URL ของเว็บไซต์ใน Authentication > URL Configuration หนึ่งครั้ง",
        }, 400, origin);
      }
      throw linkError;
    }
    const inviteLink = linkData?.properties?.action_link;
    if (!inviteLink) {
      return jsonResponse({
        success: false,
        message: "Supabase สร้างบัญชีแล้วแต่ไม่ได้คืนลิงก์เชิญ กรุณาลองเพิ่มอีเมลนี้อีกครั้ง",
      }, 502, origin);
    }

    ({ data: grant, error: grantError } = await grantAdmin());
    if (grantError) throw grantError;
    if (!grant?.success) {
      return jsonResponse({
        success: false,
        invited: true,
        email,
        message: grant?.message || "ส่งคำเชิญแล้ว แต่ให้สิทธิ์ผู้ดูแลไม่สำเร็จ กรุณากดเพิ่มอีเมลนี้อีกครั้ง",
      }, 500, origin);
    }

    return jsonResponse({
      success: true,
      invited: true,
      email,
      inviteLink,
    }, 200, origin);
  } catch (error) {
    console.error("Admin invitation failed:", error);
    return jsonResponse({ success: false, message: "เพิ่มผู้ดูแลไม่สำเร็จ กรุณาตรวจการตั้งค่า Supabase Function" }, 500, origin);
  }
});
