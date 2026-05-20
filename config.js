// =====================================================================
// 🔑 CONFIGURATION FILE - SCHOOL CLUB REGISTRATION APP
// =====================================================================
// ใส่ URL และ Anon Key ของ Supabase โครงการของคุณที่นี่
// หรือสามารถข้ามไปใส่ผ่านระบบตั้งค่าสำเร็จรูป (Setup screen) บนหน้าเว็บได้เช่นกัน
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
