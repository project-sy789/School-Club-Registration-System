// =====================================================================
// 🔑 CONFIGURATION FILE - SCHOOL CLUB REGISTRATION APP
// =====================================================================
// ใส่ URL และ Anon Key ของ Supabase โครงการของคุณที่นี่ก่อน Deploy
// (หรือฝังผ่าน GitHub Secrets + Actions ตามทางเลือกที่ 1 ใน README เพื่อความปลอดภัยสูงสุด)
// =====================================================================

const SUPABASE_CONFIG = {
    // 🔗 คัดลอกมาจาก Project Settings > API ใน Supabase Dashboard
    SUPABASE_URL: "", 
    SUPABASE_ANON_KEY: "" 
};

// ส่งออกโครงสร้างเพื่อให้เรียกใช้งานได้ง่าย
if (typeof window !== 'undefined') {
    window.SUPABASE_CONFIG = SUPABASE_CONFIG;
}
