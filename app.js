/* =====================================================================
   💻 CORE APPLICATION JAVASCRIPT - SCHOOL CLUB REGISTRATION SYSTEM
   ===================================================================== */

let supabaseClient = null;
let activeToastTimeout = null; // บันทึกไอดีสำหรับเคลียร์เวลาแสดง Toast ป้องกันการแสดงทับแล้วดับเร็ว

// 📊 Application State
let state = {
    clubs: [],
    students: [],
    registrations: [],
    auditLogs: [], // เก็บประวัติความปลอดภัยระบบ
    settings: {
        school_config: { school_name: "ระบบลงทะเบียนชุมนุม", semester: "1/2569", admin_password: "admin" },
        registration_period: { is_active: true, start_time: "", end_time: "" }
    },
    currentClub: null,
    currentStudentInfo: null, // เก็บรายชื่อเด็กดึงจาก DB
    isAdminLoggedIn: false,
    activeTab: 'home',
    activeAdminSubTab: 'stats',
    myGradesFilterOnly: false
};

// 🏁 App Initialization on Page Load
document.addEventListener("DOMContentLoaded", () => {
    // ผูก Event ให้กับโลโก้กลับหน้าหลัก
    document.getElementById("logo-home-trigger").addEventListener("click", () => {
        switchTab('home');
    });

    // ตรวจสอบการเปลี่ยนตัวเลือกห้องเรียน เพื่อรองรับช่องกรอกระบุเอง (Custom input)
    const levelSelect = document.getElementById("level-input");
    if (levelSelect) {
        levelSelect.addEventListener("change", function() {
            const customContainer = document.getElementById("level-custom-container");
            if (customContainer) {
                if (this.value === "custom") {
                    customContainer.style.display = "block";
                    const customInput = document.getElementById("level-custom-input");
                    if (customInput) customInput.focus();
                } else {
                    customContainer.style.display = "none";
                    const customInput = document.getElementById("level-custom-input");
                    if (customInput) customInput.value = "";
                }
            }
        });
    }

    initSupabaseConnection();
});

// 🌐 ดึงข้อมูล IP Address สาธารณะของนักเรียนแบบ Non-blocking (พร้อม Timeout)
async function getUserIpAddress() {
    try {
        const controller = new AbortController();
        const timeoutId = setTimeout(() => controller.abort(), 2000); // ตั้งหมดเวลา 2 วินาที
        
        const response = await fetch('https://api.ipify.org?format=json', { signal: controller.signal });
        clearTimeout(timeoutId);
        
        if (!response.ok) throw new Error('Response not OK');
        const data = await response.json();
        return data.ip || 'Unknown IP';
    } catch (e) {
        console.warn("Failed to fetch public IP, using fallback.", e);
        return 'Unknown IP';
    }
}

// =====================================================================
// 🔑 1. SUPABASE CLIENT SET-UP & INITIALIZATION
// =====================================================================
function initSupabaseConnection() {
    // ดึงค่าการเชื่อมต่อจากไฟล์ config.js เท่านั้น (หรือฝังผ่าน GitHub Secrets/Actions)
    if (typeof SUPABASE_CONFIG === 'undefined' || !SUPABASE_CONFIG.SUPABASE_URL || !SUPABASE_CONFIG.SUPABASE_ANON_KEY) {
        showFatalConfigError();
        return;
    }

    try {
        supabaseClient = supabase.createClient(SUPABASE_CONFIG.SUPABASE_URL, SUPABASE_CONFIG.SUPABASE_ANON_KEY);

        // โหลดข้อมูลตั้งค่าระบบก่อน แล้วค่อยโหลดรายชื่อชุมนุม
        loadSystemSettings().then(() => {
            loadClubsData();
            startCountdownTimer();
            populateRegistrationLevelDropdown();
        });
    } catch (e) {
        console.error("Supabase init failed:", e);
        showFatalConfigError();
    }
}

// แสดงข้อความผิดพลาดเมื่อยังไม่ได้ตั้งค่า Supabase ใน config.js
function showFatalConfigError() {
    const msg = "ยังไม่ได้ตั้งค่า Supabase URL และ Anon Key ในไฟล์ config.js — กรุณาแก้ไขไฟล์ config.js ตามคำแนะนำใน README แล้ว Deploy ใหม่อีกครั้ง";
    console.error("[CONFIG MISSING]", msg);
    document.body.innerHTML = `
        <div style="min-height: 100vh; display: flex; align-items: center; justify-content: center; padding: 2rem; background: #07170f; color: #e6f1eb; font-family: -apple-system, system-ui, sans-serif;">
            <div style="max-width: 560px; padding: 2.5rem; background: rgba(13, 40, 26, 0.95); border: 1px solid rgba(52, 211, 153, 0.25); border-radius: 16px; box-shadow: 0 10px 40px rgba(0,0,0,0.4);">
                <div style="font-size: 3rem; color: #fca5a5; margin-bottom: 1rem; text-align: center;">⚠️</div>
                <h2 style="font-size: 1.4rem; font-weight: 800; margin: 0 0 1rem; color: #34d399; text-align: center;">ระบบยังไม่ได้ตั้งค่า Supabase</h2>
                <p style="font-size: 0.95rem; line-height: 1.6; color: #b3c8be; margin: 0 0 1.25rem; text-align: center;">
                    กรุณาเปิดไฟล์ <code style="background: rgba(255,255,255,0.08); padding: 2px 8px; border-radius: 4px; color: #34d399;">config.js</code> แล้วใส่ค่า <strong>Supabase URL</strong> และ <strong>Anon Key</strong> ตามคู่มือใน <a href="https://github.com/project-sy789/School-Club-Registration-System#readme" target="_blank" style="color: #34d399; text-decoration: underline;">README</a>
                </p>
                <div style="background: rgba(7, 23, 15, 0.6); padding: 1rem; border-radius: 8px; font-size: 0.82rem; color: #94a3a0; border-left: 3px solid #34d399;">
                    หากเป็นผู้ใช้งานทั่วไป (ไม่ใช่ผู้ดูแลระบบ) กรุณาแจ้งครูผู้ดูแลให้ตรวจสอบการตั้งค่าระบบ
                </div>
            </div>
        </div>
    `;
}

// =====================================================================
// ⚙️ 2. SYSTEM SETTINGS & DATE CONTROLS
// =====================================================================
async function loadSystemSettings() {
    if (!supabaseClient) return;
    try {
        const { data, error } = await supabaseClient.from("settings").select("*");
        if (error) throw error;

        if (data && data.length > 0) {
            data.forEach(item => {
                state.settings[item.key] = item.value;
            });
        }

        // อัปเดตข้อมูลในหน้าเว็บ
        updateSystemUI();
    } catch (e) {
        console.error("Error loading settings:", e);
        showToast("เกิดข้อผิดพลาดในการโหลดการตั้งค่าระบบ", "error");
    }
}

function updateSystemUI() {
    const config = state.settings.school_config || {};
    document.getElementById("header-school-name").innerText = config.school_name || "ระบบลงทะเบียนชุมนุม";
    document.getElementById("header-semester-label").innerText = `ภาคเรียนที่ ${config.semester || "1/2569"}`;
    document.getElementById("banner-school-title").innerText = `ยินดีต้อนรับสู่ระบบลงทะเบียนชุมนุม ${config.school_name || ""}`;
    document.getElementById("banner-semester-badge").innerText = `ปีการศึกษา ${config.semester || "1/2569"}`;
    document.getElementById("ticket-school-name").innerText = config.school_name || "";

    // 🖼️ อัปเดตโลโก้โรงเรียน (Header Logo)
    const logoIcon = document.querySelector(".logo-icon");
    if (logoIcon) {
        if (config.logo_base64) {
            logoIcon.innerHTML = `<img src="${config.logo_base64}" alt="${config.school_name}">`;
        } else {
            logoIcon.innerHTML = `<i class="fa-solid fa-graduation-cap"></i>`;
        }
    }

    // 🎨 อัปเดต Favicon ของเว็บบราวเซอร์
    updateFavicon(config.logo_base64);
}

function updateFavicon(base64Data) {
    let link = document.querySelector("link[rel~='icon']");
    if (!link) {
        link = document.createElement('link');
        link.rel = 'icon';
        document.getElementsByTagName('head')[0].appendChild(link);
    }
    if (base64Data) {
        link.href = base64Data;
    } else {
        // คืนค่า favicon เริ่มต้น (รูปหมวกรับปริญญาสีเขียวมิ้นต์ SVG)
        link.href = "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 640 512'%3E%3Cpath fill='%2334d399' d='M624 138.4l-296-104c-12-4.2-25.1-4.2-37.1 0l-296 104c-20 7-30.7 29.2-23.7 49.2L68 471.1C72 482.9 83 491 95.4 491H544.6c12.4 0 23.4-8.1 27.4-19.9l95.7-283.5c7-20-3.7-42.2-23.7-49.2zM320 224c-35.3 0-64-28.7-64-64s28.7-64 64-64 64 28.7 64 64-28.7 64-64 64z'/%3E%3C/svg%3E";
    }
}

// ฟังก์ชันนับถอยหลังและอัปเดตสถานะของระบบเปิด-ปิดรับสมัคร
function startCountdownTimer() {
    let prevRegState = null;

    setInterval(() => {
        const period = state.settings.registration_period || {};
        const isActive = period.is_active;
        
        let currentRegState = "closed";
        let badgeLabel = "ปิดรับสมัคร (ควบคุมโดยผู้ดูแลระบบ)";
        let showTimer = false;
        let timerLabel = "";
        let timerVal = "";

        if (!isActive) {
            currentRegState = "closed";
            badgeLabel = "ปิดรับสมัคร (ควบคุมโดยผู้ดูแลระบบ)";
        } else {
            const now = new Date();
            const startTime = period.start_time ? new Date(period.start_time) : null;
            const endTime = period.end_time ? new Date(period.end_time) : null;

            if (startTime && now < startTime) {
                // ยังไม่เปิดรับสมัคร -> แสดงเวลานับถอยหลัง
                currentRegState = "pending-time";
                badgeLabel = "กำลังจะเปิดระบบในเร็วๆ นี้";
                showTimer = true;
                timerLabel = "ระบบจะเปิดในอีก:";
                
                const diff = startTime - now;
                timerVal = formatTimeDiff(diff);
            } else if (endTime && now > endTime) {
                // หมดเขตลงทะเบียนแล้ว
                currentRegState = "closed";
                badgeLabel = "ปิดรับสมัคร (หมดเวลารับสมัคร)";
            } else {
                // อยู่ในวันเปิดรับสมัครจริง
                currentRegState = "open";
                badgeLabel = "กำลังเปิดรับสมัครนักเรียน";
                
                if (endTime) {
                    showTimer = true;
                    timerLabel = "จะปิดระบบในอีก:";
                    const diff = endTime - now;
                    timerVal = formatTimeDiff(diff);
                }
            }
        }

        // 1. อัปเดตตราสถานะ (Badge)
        updateStatusBadge(currentRegState, badgeLabel);

        // 2. อัปเดตส่วนแสดงเวลานับถอยหลัง
        const container = document.getElementById("countdown-container");
        if (container) {
            if (showTimer) {
                container.style.display = "flex";
                const labelEl = document.getElementById("countdown-label");
                const valEl = document.getElementById("countdown-timer-val");
                if (labelEl) labelEl.innerText = timerLabel;
                if (valEl) valEl.innerText = timerVal;
            } else {
                container.style.display = "none";
            }
        }

        // 3. หากมีการเปลี่ยนสถานะของระบบรับสมัคร (เช่น จาก pending-time -> open หรือ open -> closed)
        // ให้ทำการเรนเดอร์รายชื่อชุมนุมใหม่โดยอัตโนมัติ เพื่อปรับปรุงปุ่มลงทะเบียนโดยไม่ต้องรีเฟรชหน้า
        if (prevRegState !== null && prevRegState !== currentRegState) {
            console.log(`[Countdown] System registration state transitioned from "${prevRegState}" to "${currentRegState}". Re-rendering clubs grid...`);
            renderClubsGrid();
            
            if (currentRegState === "open") {
                showToast("⏰ ขณะนี้ระบบได้เปิดให้ลงทะเบียนเข้าชุมนุมเรียบร้อยแล้ว!", "success");
            } else if (currentRegState === "closed") {
                showToast("⏰ ระบบปิดรับสมัครลงทะเบียนชุมนุมแล้ว", "info");
            }
        }

        // บันทึกสถานะปัจจุบันไว้เพื่อเปรียบเทียบในวินาทีถัดไป
        prevRegState = currentRegState;
    }, 1000);
}

function updateStatusBadge(statusClass, labelText) {
    const badge = document.getElementById("system-status-badge");
    badge.className = `status-badge ${statusClass}`;
    document.getElementById("system-status-text").innerText = labelText;
}

function formatTimeDiff(ms) {
    const totalSecs = Math.floor(ms / 1000);
    const hours = Math.floor(totalSecs / 3600);
    const minutes = Math.floor((totalSecs % 3600) / 60);
    const seconds = totalSecs % 60;
    
    return [
        hours.toString().padStart(2, '0'),
        minutes.toString().padStart(2, '0'),
        seconds.toString().padStart(2, '0')
    ].join(':');
}

// =====================================================================
// 🏠 3. TAB NAVIGATION SWITCHES
// =====================================================================
function switchTab(tabId) {
    state.activeTab = tabId;
    
    // รีเซ็ตคลาสปุ่มแถบเลือก
    document.querySelectorAll(".nav-btn").forEach(btn => btn.classList.remove("active"));
    document.getElementById(`nav-${tabId}`).classList.add("active");

    // แสดง/ซ่อนพื้นที่เนื้อหาหลัก
    document.getElementById("tab-content-home").style.display = tabId === 'home' ? 'block' : 'none';
    document.getElementById("tab-content-search").style.display = tabId === 'search' ? 'block' : 'none';
    document.getElementById("tab-content-admin").style.display = tabId === 'admin' ? 'block' : 'none';

    // ซ่อน/แสดง Banner ให้เข้ากับหน้าเว็บ
    document.getElementById("hero-area").style.display = tabId === 'home' ? 'block' : 'none';

    if (tabId === 'home') {
        loadClubsData();
    } else if (tabId === 'search') {
        populateSearchClubDropdown();
    } else if (tabId === 'admin' && state.isAdminLoggedIn) {
        loadAdminDashboardData();
    }
}

// =====================================================================
// 🏫 4. CLUBS DATA LOADER & RENDERING
// =====================================================================
async function loadClubsData() {
    if (!supabaseClient) return;
    try {
        const { data, error } = await supabaseClient
            .from("clubs")
            .select("*")
            .order("name", { ascending: true });

        if (error) throw error;
        state.clubs = data || [];
        
        renderClubsGrid();
    } catch (e) {
        console.error("Error loading clubs:", e);
        showToast("ไม่สามารถโหลดรายชื่อชุมนุมได้ กรุณาตรวจสอบอินเทอร์เน็ต", "error");
    }
}

function renderClubsGrid() {
    const container = document.getElementById("clubs-grid-container");
    container.innerHTML = "";

    // ดึงค่าการค้นหาและฟิลเตอร์
    const searchVal = document.getElementById("search-input").value.toLowerCase().trim();
    const gradeVal = document.getElementById("filter-grade").value;
    const availabilityVal = document.getElementById("filter-availability").value;

    const filtered = state.clubs.filter(club => {
        // ค้นหาข้อความชื่อหรือครู
        const matchSearch = club.name.toLowerCase().includes(searchVal) || 
                            club.teacher.toLowerCase().includes(searchVal) ||
                            (club.description && club.description.toLowerCase().includes(searchVal));
        
        // คัดกรองระดับชั้นที่เปิดรับ
        const matchGrade = gradeVal === 'all' || club.grades.includes(gradeVal);

        // คัดกรองเฉพาะห้องเรียนตัวเอง (ถ้าเปิดใช้งาน)
        let matchMyGrade = true;
        if (state.myGradesFilterOnly && state.currentStudentInfo) {
            const levelPrefix = state.currentStudentInfo.level.split('/')[0]; // ดึง เช่น "ม.4" จาก "ม.4/1"
            matchMyGrade = club.grades.includes(levelPrefix);
        }

        // คัดกรองสถานะที่นั่ง
        const matchAvail = availabilityVal === 'all' || club.enrolled_count < club.capacity;

        return matchSearch && matchGrade && matchMyGrade && matchAvail;
    });

    // แสดงจำนวนชุมนุมที่กรองได้
    document.getElementById("clubs-count-badge").innerText = `${filtered.length} ชุมนุม`;

    if (filtered.length === 0) {
        container.innerHTML = `
            <div style="grid-column: 1/-1; text-align: center; padding: 4rem 0; color: var(--text-muted);">
                <i class="fa-regular fa-folder-open" style="font-size: 3rem; margin-bottom: 1rem;"></i>
                <p>ไม่พบรายชื่อชุมนุมตามที่คัดกรอง หรือชุมนุมทั้งหมดโควตาเต็มหมดแล้ว</p>
            </div>
        `;
        return;
    }

    // ตรวจเช็คเวลาเปิดรับสมัครในระดับบราวเซอร์
    const period = state.settings.registration_period || {};
    const now = new Date();
    const systemOpen = period.is_active && 
                       (!period.start_time || now >= new Date(period.start_time)) && 
                       (!period.end_time || now <= new Date(period.end_time));

    filtered.forEach(club => {
        const isFull = club.enrolled_count >= club.capacity;
        const pct = Math.min(100, Math.round((club.enrolled_count / club.capacity) * 100));
        
        // สีของ Progress Bar
        let pctClass = "normal";
        if (pct >= 90) pctClass = "danger";
        else if (pct >= 70) pctClass = "warning";

        // รวบรวมรายชื่อระดับชั้นมาแสดงเป็น Badge
        const gradeBadgesHtml = club.grades.map(g => `<span class="grade-badge">${g}</span>`).join(" ");

        // เช็คการปิดรับของปุ่ม
        let btnHtml = "";
        if (!systemOpen) {
            btnHtml = `<button class="register-btn closed" disabled><i class="fa-solid fa-lock"></i> ยังไม่เปิดให้ลงทะเบียน</button>`;
        } else if (isFull) {
            btnHtml = `<button class="register-btn full" disabled><i class="fa-solid fa-ban"></i> ที่นั่งเต็มแล้ว</button>`;
        } else {
            btnHtml = `<button class="register-btn active" onclick="openRegistrationModal('${club.id}')"><i class="fa-solid fa-pen-to-square"></i> ลงทะเบียนเรียน</button>`;
        }

        const card = document.createElement("div");
        card.className = "club-card glass-container";
        card.innerHTML = `
            <div class="club-header">
                <div class="grade-badges">${gradeBadgesHtml}</div>
            </div>
            <div class="club-name">${club.name}</div>
            <div class="club-info-line">
                <i class="fa-solid fa-user-tie"></i> 
                <span><strong>ผู้สอน:</strong> ${club.teacher}</span>
            </div>
            <div class="club-info-line">
                <i class="fa-solid fa-location-dot"></i> 
                <span><strong>สถานที่:</strong> ${club.location}</span>
            </div>
            <div class="club-description">${club.description || "ไม่ระบุคำอธิบายชุมนุม"}</div>
            
            <div class="seat-progress-container">
                <div class="seat-label">
                    <span>สมัครแล้ว <span class="numbers">${club.enrolled_count}/${club.capacity}</span> คน</span>
                    <span class="percent">${pct}%</span>
                </div>
                <div class="progress-bar-bg">
                    <div class="progress-bar-fill ${pctClass}" style="width: ${pct}%;"></div>
                </div>
            </div>
            
            <div class="club-footer">
                ${btnHtml}
            </div>
        `;
        container.appendChild(card);
    });
}

function filterClubs() {
    renderClubsGrid();
}

function toggleFilterMyGrades() {
    const checkbox = document.getElementById("my-grades-only");
    checkbox.checked = !checkbox.checked;
    state.myGradesFilterOnly = checkbox.checked;
    
    if (state.myGradesFilterOnly && !state.currentStudentInfo) {
        showToast("กรุณากรอกเลขประจำตัวนักเรียนของคุณในช่อง 'ระบุตัวตน' ด้านบนก่อนเพื่อค้นหาระดับชั้นจริงโดยอัตโนมัติ!", "info");
    }
    
    renderClubsGrid();
}

async function quickVerifyStudent() {
    const idInput = document.getElementById("student-quick-id").value.trim();
    if (!idInput) {
        showToast("กรุณากรอกเลขประจำตัวนักเรียนของคุณ", "warning");
        return;
    }

    try {
        const { data, error } = await supabaseClient
            .from("students")
            .select("*")
            .eq("student_id", idInput)
            .maybeSingle();

        if (error) throw error;

        if (data) {
            state.currentStudentInfo = data;
            
            // 1. ดึงระดับชั้นมา เช่น "ม.4" จาก "ม.4/1"
            const levelPrefix = data.level.split('/')[0];
            
            // 2. อัปเดต dropdown ระดับชั้นที่หน้าแรกให้เป็นห้องเรียนของเด็กโดยอัตโนมัติ
            document.getElementById("filter-grade").value = levelPrefix;
            
            // 3. ติ๊กเลือกเช็คบล็อกกรองเฉพาะระดับชั้นที่ฉันสมัครได้ให้ด้วย
            const checkbox = document.getElementById("my-grades-only");
            if (checkbox) {
                checkbox.checked = true;
                state.myGradesFilterOnly = true;
            }

            updateQuickVerifyUI();

            showToast(`ยินดีต้อนรับคุณ ${data.prefix || ""}${data.first_name} ${data.last_name} (${data.level})! ระบบคัดกรองระดับชั้น ${levelPrefix} ให้โดยอัตโนมัติแล้ว`, "success");
            
            // รีเรนเดอร์บอร์ดแสดงรายชื่อชุมนุมใหม่
            renderClubsGrid();
        } else {
            showToast("ไม่พบรหัสประจำตัว กรุณาตรวจสอบอีกครั้ง หรือคลิกปุ่มนักเรียนใหม่ด้านล่างเพื่อเตรียมความพร้อม", "warning");
            state.currentStudentInfo = null;
            updateQuickVerifyUI();
        }
    } catch (e) {
        console.error("Error doing quick verify:", e);
        showToast("เกิดข้อผิดพลาดในการเชื่อมต่อเพื่อตรวจสอบรหัสประจำตัว", "error");
    }
}

function handleQuickIdKeyPress(event) {
    if (event.key === "Enter") {
        quickVerifyStudent();
    }
}

// 🔄 อัปเดตส่วนแสดงผลการระบุตัวตนที่หน้าแรก (Quick Verify UI Profile Badge)
function updateQuickVerifyUI() {
    const wrapper = document.getElementById("quick-verify-wrapper");
    if (!wrapper) return;

    if (state.currentStudentInfo) {
        const data = state.currentStudentInfo;
        const displayName = `${data.prefix || ""}${data.first_name} ${data.last_name}`;
        
        wrapper.innerHTML = `
            <div class="identity-card-header" style="color: var(--accent-mint);">
                <i class="fa-solid fa-circle-check"></i>
                <span>ยืนยันตัวตนสำเร็จ</span>
            </div>
            <div style="background: rgba(52, 211, 153, 0.08); border: 1px solid rgba(52, 211, 153, 0.3); border-radius: 8px; padding: 10px 14px; display: flex; align-items: center; justify-content: space-between; gap: 10px;">
                <div style="display: flex; flex-direction: column; overflow: hidden; flex: 1; text-align: left;">
                    <span style="font-size: 0.95rem; font-weight: 700; color: var(--text-primary); white-space: nowrap; overflow: hidden; text-overflow: ellipsis;" title="${displayName}">${displayName}</span>
                    <span style="font-size: 0.75rem; color: var(--text-secondary); margin-top: 2px;">ระดับชั้น ${data.level} | รหัส: ${data.student_id}</span>
                </div>
                <button onclick="clearStudentVerification()" title="ยกเลิกการระบุตัวตน" style="background: none; border: none; color: rgba(239, 68, 68, 0.8); cursor: pointer; padding: 6px; font-size: 1.1rem; display: flex; align-items: center; transition: all 0.2s;" onmouseover="this.style.color='#ef4444'; this.style.transform='scale(1.15)';" onmouseout="this.style.color='rgba(239, 68, 68, 0.8)'; this.style.transform='scale(1)';">
                    <i class="fa-solid fa-right-from-bracket"></i>
                </button>
            </div>
        `;
    } else if (state.isNewStudentPreRegistering) {
        wrapper.innerHTML = `
            <div class="identity-card-header">
                <i class="fa-solid fa-user-plus"></i>
                <span>เตรียมข้อมูลนักเรียนใหม่</span>
            </div>
            <div style="display: flex; flex-direction: column; gap: 8px;">
                <div style="display: flex; gap: 6px;">
                    <input type="text" id="quick-new-id" placeholder="เบอร์โทร 10 หลัก หรือ เลขบัตร 13 หลัก" style="background: rgba(7,23,15,0.6); border: var(--border-glass); color: white; padding: 8px 10px; border-radius: 8px; font-size: 0.85rem; flex: 1;">
                    <select id="quick-prefix" style="background: rgba(7,23,15,0.6); border: var(--border-glass); color: white; padding: 8px; border-radius: 8px; font-size: 0.85rem; width: 38%;">
                        <option value="">คำนำหน้า</option>
                        <option value="เด็กชาย">เด็กชาย</option>
                        <option value="เด็กหญิง">เด็กหญิง</option>
                        <option value="นาย">นาย</option>
                        <option value="นางสาว">นางสาว</option>
                    </select>
                </div>
                <div style="display: flex; gap: 6px;">
                    <input type="text" id="quick-firstname" placeholder="ชื่อจริง" style="background: rgba(7,23,15,0.6); border: var(--border-glass); color: white; padding: 8px 10px; border-radius: 8px; font-size: 0.85rem; flex: 1;">
                    <input type="text" id="quick-lastname" placeholder="นามสกุล" style="background: rgba(7,23,15,0.6); border: var(--border-glass); color: white; padding: 8px 10px; border-radius: 8px; font-size: 0.85rem; flex: 1;">
                </div>
                <select id="quick-level" style="background: rgba(7,23,15,0.6); border: var(--border-glass); color: white; padding: 8px; border-radius: 8px; font-size: 0.85rem; width: 100%;">
                    <option value="">เลือกระดับชั้น/ห้อง...</option>
                </select>
                <input type="text" id="quick-level-custom" placeholder="ระบุชั้น/ห้องเรียนเอง เช่น ม.4/5" style="display: none; background: rgba(7,23,15,0.6); border: 1px solid var(--accent-mint); color: white; padding: 8px 10px; border-radius: 8px; font-size: 0.85rem; width: 100%;">
                <div style="display: flex; gap: 6px; margin-top: 2px;">
                    <button onclick="saveQuickNewStudent()" style="flex: 1; padding: 9px; font-size: 0.85rem; border-radius: 8px; display: flex; align-items:center; justify-content: center; gap: 6px; background: var(--accent-mint); border: none; color: #07170f; cursor: pointer; font-weight: 700; transition: all 0.2s;"><i class="fa-solid fa-save"></i> บันทึกข้อมูล</button>
                    <button onclick="cancelQuickNewStudent()" style="padding: 9px 14px; font-size: 0.85rem; border-radius: 8px; background: rgba(239,68,68,0.1); border: 1px solid rgba(239,68,68,0.3); color: #fca5a5; cursor: pointer; transition: all 0.2s;">ยกเลิก</button>
                </div>
            </div>
        `;
        // คัดลอกตัวเลือกห้องจาก Modal มาใส่ให้
        const modalSelect = document.getElementById("level-input");
        if (modalSelect && modalSelect.options.length > 1) {
            document.getElementById("quick-level").innerHTML = modalSelect.innerHTML;
            document.getElementById("quick-level").value = "";
        }
        // เปิด/ปิดช่องระบุเองเมื่อเลือก 'อื่นๆ'
        document.getElementById("quick-level").addEventListener("change", function() {
            const customInput = document.getElementById("quick-level-custom");
            if (this.value === "custom") {
                customInput.style.display = "block";
                customInput.focus();
            } else {
                customInput.style.display = "none";
                customInput.value = "";
            }
        });
    } else {
        wrapper.innerHTML = `
            <div class="identity-card-header">
                <i class="fa-solid fa-id-card"></i>
                <span>ระบุตัวตนก่อนเลือกชุมนุม</span>
            </div>
            <label for="student-quick-id" style="font-size:0.8rem; color: var(--text-secondary); margin-bottom: 4px; display:block;">นักเรียนที่มีรหัสประจำตัว</label>
            <div style="display: flex; gap: 6px;">
                <input type="text" id="student-quick-id" placeholder="รหัสประจำตัว 5 หลัก..."
                       onkeyup="handleQuickIdKeyPress(event)"
                       style="background: rgba(7,23,15,0.6); border: var(--border-glass); color: var(--text-primary); padding: 9px 12px; border-radius: 8px; font-size: 1rem; flex: 1;">
                <button onclick="quickVerifyStudent()" title="ตรวจสอบรหัส" style="padding: 0 14px; border-radius: 8px; height: 42px; display: flex; align-items: center; justify-content: center; background: var(--accent-mint); border: none; color: #07170f; cursor: pointer; font-size: 1rem; transition: all 0.2s; font-weight: 700;">
                    <i class="fa-solid fa-user-check"></i>
                </button>
            </div>
            <div class="identity-divider"><span>หรือ</span></div>
            <button onclick="openNewStudentPreRegister()" style="font-size: 0.85rem; padding: 9px 12px; border: 1px dashed var(--accent-mint); color: var(--accent-mint); background: rgba(52,211,153,0.05); width: 100%; display:flex; align-items:center; justify-content: center; gap: 8px; border-radius: 8px; cursor: pointer; transition: all 0.2s; font-weight: 600;" onmouseover="this.style.background='rgba(52,211,153,0.12)'" onmouseout="this.style.background='rgba(52,211,153,0.05)'">
                <i class="fa-solid fa-user-plus"></i> นักเรียนใหม่ — กรอกประวัติเตรียมจอง
            </button>
        `;
    }
}

// 👩‍🎓 เปิดโหมดเตรียมนักเรียนใหม่
function openNewStudentPreRegister() {
    state.isNewStudentPreRegistering = true;
    state.currentStudentInfo = null;
    updateQuickVerifyUI();
}

// 💾 บันทึกข้อมูลนักเรียนใหม่ล่วงหน้าลงใน State (เพื่อความพร้อม)
function saveQuickNewStudent() {
    const newId = document.getElementById("quick-new-id").value.trim();
    const prefix = document.getElementById("quick-prefix").value;
    const levelSelect = document.getElementById("quick-level").value;
    const levelCustom = (document.getElementById("quick-level-custom")?.value || "").trim();
    const level = (levelSelect === "custom") ? levelCustom : levelSelect;
    const firstName = document.getElementById("quick-firstname").value.trim();
    const lastName = document.getElementById("quick-lastname").value.trim();

    if (!newId || !prefix || !level || !firstName || !lastName) {
        showToast("กรุณากรอกข้อมูลให้ครบ: รหัสอ้างอิง, คำนำหน้า, ชื่อ, นามสกุล และระดับชั้น", "warning");
        return;
    }

    state.currentStudentInfo = {
        student_id: newId,
        prefix: prefix,
        first_name: firstName,
        last_name: lastName,
        level: level
    };
    state.isNewStudentPreRegistering = false;

    const levelPrefix = level.split('/')[0];
    document.getElementById("filter-grade").value = levelPrefix;
    
    const checkbox = document.getElementById("my-grades-only");
    if (checkbox) {
        checkbox.checked = true;
        state.myGradesFilterOnly = true;
    }

    updateQuickVerifyUI();
    showToast("เตรียมข้อมูลสำเร็จ! ระบบจำชื่อคุณไว้แล้ว เมื่อถึงเวลาสามารถกดลงทะเบียนชุมนุมได้ทันที", "success");
    renderClubsGrid();
}

function cancelQuickNewStudent() {
    state.isNewStudentPreRegistering = false;
    updateQuickVerifyUI();
}

// 🔓 ยกเลิกการระบุตัวตนของนักเรียน
function clearStudentVerification() {
    state.currentStudentInfo = null;
    
    // รีเซ็ตค่าการคัดกรองต่าง ๆ กลับเป็นปกติ
    document.getElementById("filter-grade").value = "all";
    const checkbox = document.getElementById("my-grades-only");
    if (checkbox) {
        checkbox.checked = false;
        state.myGradesFilterOnly = false;
    }
    
    updateQuickVerifyUI();
    renderClubsGrid();
    showToast("ยกเลิกการยืนยันตัวตน เรียบร้อยแล้ว", "info");
}

// ผูกฟังก์ชันเข้ากับ Global window เพื่อให้กดเรียกใช้งานได้เสมอในทุกเบราวเซอร์ (เช่น Safari WebKit)
window.clearStudentVerification = clearStudentVerification;
window.updateQuickVerifyUI = updateQuickVerifyUI;

// =====================================================================
// 📝 5. STUDENT REGISTRATION FLOW (ATOMIC & CONCURRENCY SAFE)
// =====================================================================
function openRegistrationModal(clubId) {
    const club = state.clubs.find(c => c.id === clubId);
    if (!club) return;
    
    state.currentClub = club;
    
    // ตั้งชื่อชุมนุมและรายละเอียดในฟอร์ม
    document.getElementById("modal-club-name").innerText = club.name;
    document.getElementById("modal-club-teacher").innerHTML = `<i class="fa-solid fa-user-tie"></i> ครูผู้สอน: ${club.teacher}`;
    document.getElementById("modal-club-location").innerHTML = `<i class="fa-solid fa-location-dot"></i> สถานที่: ${club.location}`;
    
    // ดึงค่าจากหน้าแรกเพื่อพรีฟิล
    const quickId = document.getElementById("student-quick-id") ? document.getElementById("student-quick-id").value.trim() : "";
    document.getElementById("student-id-input").value = quickId;
    document.getElementById("prefix-input").value = "";
    document.getElementById("first-name-input").value = "";
    document.getElementById("last-name-input").value = "";
    resetLevelInput();
    
    document.getElementById("verify-alert-box").style.display = "none";
    document.getElementById("verify-alert-box").className = "verification-alert";
    document.getElementById("manual-entry-form").classList.remove("active");
    
    // ดึงค่าสิทธิ์หากเคยระบุและยืนยันตัวตนไว้ที่หน้าแรกแล้ว
    if (state.currentStudentInfo) {
        const data = state.currentStudentInfo;
        document.getElementById("student-id-input").value = data.student_id;
        document.getElementById("prefix-input").value = data.prefix || "";
        document.getElementById("first-name-input").value = data.first_name;
        document.getElementById("last-name-input").value = data.last_name;
        prefillLevelDropdownAndEnsureOption(data.level);
        
        const alertBox = document.getElementById("verify-alert-box");
        alertBox.style.display = "flex";
        alertBox.className = "verification-alert verified";
        const displayName = (data.prefix || "") + data.first_name + " " + data.last_name;
        alertBox.innerHTML = `
            <i class="fa-solid fa-circle-check"></i> 
            <div>
                <strong>ยืนยันตัวตนสำเร็จ:</strong> ${displayName} (${data.level})<br>
                <span style="font-size:0.8rem; opacity:0.85;">ดึงข้อมูลการยืนยันตัวตนจากหน้าแรกอัตโนมัติ กดลงทะเบียนได้ทันที</span>
            </div>
        `;

        // อัปเดตข้อมูลการแสดงผลในการ์ดบัตรรวมสไตล์พรีเมียม
        document.getElementById("modal-verified-name").innerText = displayName;
        document.getElementById("modal-verified-id").innerText = data.student_id || "นักเรียนใหม่ (รอการจัดเลข)";
        document.getElementById("modal-verified-level").innerText = data.level;

        document.getElementById("modal-verified-view").style.display = "flex";
        document.getElementById("modal-unverified-view").style.display = "none";
        document.getElementById("submit-registration-btn").style.display = "flex";
    } else {
        // กรณีที่ไม่ได้กดยืนยันตัวตนจากหน้าแรกมา
        document.getElementById("modal-verified-view").style.display = "none";
        document.getElementById("modal-unverified-view").style.display = "flex";
        document.getElementById("submit-registration-btn").style.display = "none";
    }
    
    // สลับหน้าจอเนื้อหาฟอร์มกลับมา (กรณีคราวก่อนแสดงตั๋วสำเร็จ)
    document.getElementById("modal-form-content").style.display = "block";
    document.getElementById("modal-success-content").style.display = "none";
    
    // เปิดโมดอล
    document.getElementById("registration-modal").classList.add("active");
}

function closeRegistrationModal() {
    document.getElementById("registration-modal").classList.remove("active");
    state.currentClub = null;
}

// 🔒 ปิดโมดอล เลื่อนและไฮไลท์แผงตรวจสอบตัวตนหน้าแรก
function scrollToIdentityPanel() {
    closeRegistrationModal();
    const wrapper = document.getElementById("quick-verify-wrapper");
    if (wrapper) {
        wrapper.scrollIntoView({ behavior: "smooth", block: "center" });
        wrapper.classList.add("pulse-highlight");
        setTimeout(() => {
            wrapper.classList.remove("pulse-highlight");
        }, 3000);
    }
    const input = document.getElementById("student-quick-id");
    if (input) {
        setTimeout(() => {
            input.focus();
            input.select();
        }, 800);
    }
}

// ผูกฟังก์ชันเข้ากับ Global window
window.openRegistrationModal = openRegistrationModal;
window.closeRegistrationModal = closeRegistrationModal;
window.scrollToIdentityPanel = scrollToIdentityPanel;

// 🟢 ตรวจสอบเลขนักเรียนกับตาราง students
async function verifyStudentID() {
    const idInput = document.getElementById("student-id-input").value.trim();
    const alertBox = document.getElementById("verify-alert-box");
    const manualArea = document.getElementById("manual-entry-form");
    
    if (!idInput) {
        showToast("กรุณากรอกเลขประจำตัวนักเรียน", "warning");
        return;
    }

    alertBox.style.display = "flex";
    alertBox.className = "verification-alert verified";
    alertBox.innerHTML = `<i class="fa-solid fa-circle-notch fa-spin"></i> กำลังตรวจสอบสิทธิ์ในระบบ...`;
    manualArea.classList.remove("active");

    try {
        const { data, error } = await supabaseClient
            .from("students")
            .select("*")
            .eq("student_id", idInput)
            .maybeSingle();

        if (error) throw error;

        if (data) {
            // 🟢 เคสที่ 1: ตรวจพบรายชื่อในระบบ
            state.currentStudentInfo = data;
            
            alertBox.className = "verification-alert verified";
            const displayName = (data.prefix || "") + data.first_name + " " + data.last_name;
            alertBox.innerHTML = `
                <i class="fa-solid fa-circle-check"></i> 
                <div>
                    <strong>ยืนยันตัวตนสำเร็จ:</strong> ${displayName} (${data.level})<br>
                    <span style="font-size:0.8rem; opacity:0.85;">ข้อมูลถูกต้องตามทะเบียนราษฎร์โรงเรียน สามารถกดลงทะเบียนได้ทันที</span>
                </div>
            `;
            
            // แอบอัปเดตข้อมูลและเก็บสถานะไว้
            document.getElementById("prefix-input").value = data.prefix || "";
            document.getElementById("first-name-input").value = data.first_name;
            document.getElementById("last-name-input").value = data.last_name;
            prefillLevelDropdownAndEnsureOption(data.level);
            
            // อัปเดต UI คัดกรองของระดับชั้นนั้นทันทีเพื่อความสะดวก
            const userGradePrefix = data.level.split('/')[0];
            document.getElementById("filter-grade").value = userGradePrefix;
            
            // อัปเดตส่วนคัดกรองหน้าแรกด้วย
            updateQuickVerifyUI();
        } else {
            // 🔵 เคสที่ 2: ไม่พบรายชื่อ (นักเรียนใหม่ / ย้ายคลาส) -> เปิดให้กรอกเอง
            state.currentStudentInfo = null;
            updateQuickVerifyUI();
            
            alertBox.className = "verification-alert pending";
            alertBox.innerHTML = `
                <i class="fa-solid fa-triangle-exclamation"></i> 
                <div>
                    <strong>ไม่พบเลขประจำตัวในระบบชั่วคราว:</strong> นักเรียนใหม่อาจจะยังไม่มีชื่อในฐานข้อมูลเดิม<br>
                    <span style="font-weight:600;">โปรดกรอก คำนำหน้า ชื่อ-นามสกุล และเลือกห้องเรียนจริงที่แบบฟอร์มด้านล่างเพื่อจองสิทธิ์เข้าชุมนุมนี้ทันที!</span>
                </div>
            `;
            
            // ล้างข้อมูลฟอร์มเดิมเพื่อความถูกต้อง
            document.getElementById("prefix-input").value = "";
            document.getElementById("first-name-input").value = "";
            document.getElementById("last-name-input").value = "";
            resetLevelInput();
            
            // เปิดสวิตช์ฟิลด์กรอกข้อมูล
            manualArea.classList.add("active");
        }
    } catch (e) {
        console.error("Error verifying ID:", e);
        alertBox.className = "verification-alert error";
        alertBox.innerHTML = `<i class="fa-solid fa-circle-xmark"></i> เกิดข้อผิดพลาดทางเทคนิคในการเชื่อมต่อระบบตรวจสอบ`;
    }
}

// 🔵 สลับเข้าโหมดกรอกข้อมูลด้วยตนเองสำหรับนักเรียนใหม่/ไม่มีเลขประจำตัว
function enableNewStudentManualEntry() {
    state.currentStudentInfo = null;
    updateQuickVerifyUI();
    document.getElementById("student-id-input").value = "";
    
    const alertBox = document.getElementById("verify-alert-box");
    alertBox.style.display = "flex";
    alertBox.className = "verification-alert pending";
    alertBox.innerHTML = `
        <i class="fa-solid fa-user-plus"></i> 
        <div>
            <strong>โหมดลงทะเบียนนักเรียนใหม่ (ไม่มีเลขประจำตัว):</strong><br>
            <span style="font-size:0.85rem; opacity:0.95;">กรุณากรอก คำนำหน้า ชื่อจริง นามสกุล และระดับชั้นจริงที่แบบฟอร์มด้านล่างเพื่อสำรองสิทธิ์เข้าชุมนุมนี้ทันที!</span>
        </div>
    `;
    
    // ล้างข้อมูลฟอร์มเดิมเพื่อความถูกต้องในการสมัครใหม่
    document.getElementById("prefix-input").value = "";
    document.getElementById("first-name-input").value = "";
    document.getElementById("last-name-input").value = "";
    resetLevelInput();
    
    // เปิดสวิตช์ฟิลด์กรอกข้อมูล
    document.getElementById("manual-entry-form").classList.add("active");
}

// ⚡ บันทึกการลงทะเบียนอย่างปลอดภัยแบบรองรับ Concurrent 800 คน
async function submitStudentRegistration() {
    if (!supabaseClient || !state.currentClub) return;

    const studentId = document.getElementById("student-id-input").value.trim() || null;
    let prefix = document.getElementById("prefix-input").value;
    let firstName = document.getElementById("first-name-input").value.trim();
    let lastName = document.getElementById("last-name-input").value.trim();
    let level = document.getElementById("level-input").value;
    if (level === "custom") {
        level = document.getElementById("level-custom-input") ? document.getElementById("level-custom-input").value.trim() : "";
    }

    const submitBtn = document.getElementById("submit-registration-btn");

    // 1. ตรวจสอบความครบถ้วนของข้อมูล
    if (!prefix || !firstName || !lastName || !level) {
        showToast("กรุณากรอกข้อมูลนักเรียน คำนำหน้าชื่อ ชื่อจริง นามสกุล และห้องเรียนให้ครบถ้วน", "warning");
        return;
    }

    // 2. ตรวจสอบเงื่อนไขระดับชั้น (Frontend Check ก่อนยิงไปตัดที่นั่งจริง)
    const levelPrefix = level.split('/')[0]; // ดึง "ม.4" จาก "ม.4/1"
    if (!state.currentClub.grades.includes(levelPrefix)) {
        showToast(`ขออภัย ชุมนุมนี้ไม่เปิดรับสมัครสำหรับระดับชั้น ${levelPrefix} (รับเฉพาะชั้น: ${state.currentClub.grades.join(', ')})`, "error");
        return;
    }

    // 3. ป้องกันการลงสแปมด้วยระบบ Jitter (หน่วงเวลาสุ่ม) เพื่อกระจาย Request หลบ Peak concurrent 
    submitBtn.disabled = true;
    submitBtn.innerHTML = `<div class="spinner"></div> กำลังประมวลผลข้อมูลและจองสิทธิ์...`;

    // สุ่มเวลาหน่วง (Jitter) ระหว่าง 400ms - 1500ms
    const jitterDelay = Math.floor(Math.random() * 1100) + 400;
    
    setTimeout(async () => {
        try {
            // ดึง IP Address และอุปกรณ์ของนักเรียน ณ วินาทีสมัคร
            const ipAddress = await getUserIpAddress();
            const userAgent = navigator.userAgent || "Unknown Device";

            // 4. สั่งเรียก RPC Function register_student_atomic บนฐานข้อมูล Supabase เพื่อตัดที่นั่งแบบปลอดภัย (Row level lock)
            const { data, error } = await supabaseClient.rpc("register_student_atomic", {
                p_club_id: state.currentClub.id,
                p_student_id: studentId,
                p_prefix: prefix,
                p_first_name: firstName,
                p_last_name: lastName,
                p_level: level,
                p_ip_address: ipAddress,
                p_user_agent: userAgent
            });

            if (error) throw error;

            if (data && data.success) {
                // 🎉 ลงทะเบียนเสร็จสิ้น
                showToast(data.message, "success");
                
                // ฉลองด้วย Confetti
                triggerConfettiCelebration();

                // อัปเดตข้อมูลตั๋ว
                document.getElementById("ticket-club-name").innerText = state.currentClub.name;
                document.getElementById("ticket-student-name").innerText = `${prefix}${firstName} ${lastName}`;
                document.getElementById("ticket-student-level").innerText = level;
                document.getElementById("ticket-student-id").innerText = studentId || "นักเรียนใหม่ (รอการจัดเลข)";
                document.getElementById("ticket-location-teacher").innerHTML = `<i class="fa-solid fa-location-dot"></i> ${state.currentClub.location} &nbsp;&nbsp;&nbsp; <i class="fa-solid fa-user-tie"></i> ${state.currentClub.teacher}`;

                const badge = document.getElementById("ticket-status-badge");
                if (data.status === 'verified') {
                    badge.className = "ticket-status-badge verified";
                    badge.innerText = "ยืนยันแล้ว (เดิม)";
                } else {
                    badge.className = "ticket-status-badge pending";
                    badge.innerText = "สำรองสิทธิ์ (นักเรียนใหม่)";
                }

                // สลับแสดงตั๋วสำเร็จ
                document.getElementById("modal-form-content").style.display = "none";
                document.getElementById("modal-success-content").style.display = "block";

                // รีเฟรชข้อมูลในหน้าเว็บบอร์ดหลังบ้าน
                loadClubsData();
            } else {
                // ได้รับข้อความปฏิเสธจาก Stored procedure (เช่น สมัครซ้ำ หรือ ที่นั่งเต็ม)
                showToast(data.message || "เกิดข้อผิดพลาดในการรับสมัคร", "error");
                submitBtn.disabled = false;
                submitBtn.innerHTML = `<i class="fa-solid fa-signature"></i> ยืนยันสมัครเข้าชุมนุมนี้`;
            }
        } catch (e) {
            console.error("Error submitting registration:", e);
            showToast("ไม่สามารถประมวลผลคำขอของคุณได้ในขณะนี้ กรุณาลองใหม่อีกครั้ง", "error");
            submitBtn.disabled = false;
            submitBtn.innerHTML = `<i class="fa-solid fa-signature"></i> ยืนยันสมัครเข้าชุมนุมนี้`;
        }
    }, jitterDelay);
}

function triggerConfettiCelebration() {
    confetti({
        particleCount: 150,
        spread: 80,
        origin: { y: 0.65 },
        colors: ['#10b981', '#34d399', '#059669', '#ffffff']
    });
}

// ผูก Event ปุ่ม Enter บน Input ค้นหาต่างๆ เพื่อความสะดวกในการใช้งาน
function handleVerifyIdKeyPress(event) {
    if (event.key === "Enter") {
        verifyStudentID();
    }
}

// =====================================================================
// 📝 6. REGISTRATIONS SEARCH TAB (FRONTEND)
// =====================================================================
async function searchStudentRegistrations() {
    const term = document.getElementById("reg-search-input").value.trim();
    const resultsContainer = document.getElementById("reg-search-results-container");
    const resultsBody = document.getElementById("reg-search-results-body");
    const emptyState = document.getElementById("reg-search-empty-state");
    const clubSelect = document.getElementById("reg-club-select");

    if (!term) {
        showToast("กรุณากรอกคำที่ต้องการค้นหา", "warning");
        return;
    }

    // รีเซ็ตตัวเลือกใน dropdown ชุมนุม เพื่อไม่ให้สับสน
    if (clubSelect) clubSelect.value = "";

    resultsContainer.style.display = "none";
    emptyState.style.display = "block";
    emptyState.innerHTML = `<i class="fa-solid fa-circle-notch fa-spin" style="font-size:2.5rem; color:var(--accent-mint); margin-bottom:1rem;"></i><p>กำลังค้นหาข้อมูลการลงทะเบียน...</p>`;

    try {
        // 1. ค้นหาชุมนุมที่มีชื่อตรงกับคำค้นหาก่อน เพื่อเก็บ IDs
        let clubIds = [];
        try {
            const { data: matchedClubs, error: clubErr } = await supabaseClient
                .from("clubs")
                .select("id")
                .ilike("name", `%${term}%`);
            
            if (!clubErr && matchedClubs) {
                clubIds = matchedClubs.map(c => c.id);
            }
        } catch (err) {
            console.error("Error fetching matching clubs:", err);
        }

        // 2. ดึงการลงทะเบียนของเด็กพร้อมชื่อชุมนุม (ดึงตามรหัสนักเรียน ชื่อนักเรียน หรือรหัสชุมนุมที่แมตช์)
        let orFilter = `student_id.eq.${term},first_name.ilike.%${term}%,last_name.ilike.%${term}%`;
        if (clubIds.length > 0) {
            orFilter += `,club_id.in.(${clubIds.join(',')})`;
        }

        const { data, error } = await supabaseClient
            .from("registrations")
            .select(`
                *,
                clubs ( name, teacher )
            `)
            .or(orFilter);

        if (error) throw error;

        if (data && data.length > 0) {
            resultsBody.innerHTML = "";
            data.forEach(reg => {
                const date = new Date(reg.created_at).toLocaleString("th-TH", { timeZone: "Asia/Bangkok" });
                const statusBadge = reg.registration_status === 'verified' 
                    ? `<span class="ticket-status-badge verified" style="font-size:0.75rem;">ยืนยันสิทธิ์แล้ว</span>`
                    : `<span class="ticket-status-badge pending" style="font-size:0.75rem;">สำรองสิทธิ์ (Pending)</span>`;

                const row = document.createElement("tr");
                row.innerHTML = `
                    <td><strong>${reg.student_id || "นักเรียนใหม่"}</strong></td>
                    <td>${reg.prefix || ""}${reg.first_name} ${reg.last_name}</td>
                    <td>${reg.level}</td>
                    <td style="color:var(--accent-mint); font-weight:600;">${reg.clubs ? reg.clubs.name : "ไม่ระบุ"}</td>
                    <td>${reg.clubs ? reg.clubs.teacher : "ไม่ระบุ"}</td>
                    <td>${statusBadge}</td>
                    <td style="font-size:0.85rem; color:var(--text-secondary);">${date} น.</td>
                `;
                resultsBody.appendChild(row);
            });

            emptyState.style.display = "none";
            resultsContainer.style.display = "block";
        } else {
            emptyState.style.display = "block";
            emptyState.innerHTML = `
                <i class="fa-regular fa-face-frown" style="font-size: 3rem; color: var(--text-muted); margin-bottom: 1rem;"></i>
                <p>ไม่พบประวัติการลงทะเบียนสำหรับ "${term}"</p>
            `;
        }
    } catch (e) {
        console.error("Error searching registrations:", e);
        showToast("เกิดข้อผิดพลาดในการตรวจสอบรายชื่อลงทะเบียน", "error");
        emptyState.style.display = "block";
        emptyState.innerHTML = `<p>เกิดข้อผิดพลาดทางเทคนิคในการเรียกฐานข้อมูล</p>`;
    }
}

function handleSearchRegKeyPress(event) {
    if (event.key === "Enter") {
        searchStudentRegistrations();
    }
}

// 🏫 ดึงและเติมตัวเลือกรายชื่อชุมนุมในหน้าค้นหาผลการลงทะเบียน
async function populateSearchClubDropdown() {
    const select = document.getElementById("reg-club-select");
    if (!select) return;

    // ถ้าไม่มีข้อมูลชุมนุมใน state ให้โหลดก่อน
    if (!state.clubs || state.clubs.length === 0) {
        await loadClubsData();
    }

    select.innerHTML = '<option value="" style="background: #0d281a; color: var(--text-primary);">-- เลือกจากรายชื่อชุมนุม --</option>';
    
    // เรียงตามชื่อชุมนุมภาษาไทย
    const sortedClubs = [...state.clubs].sort((a, b) => a.name.localeCompare(b.name, 'th'));
    
    sortedClubs.forEach(club => {
        const option = document.createElement("option");
        option.value = club.id;
        option.textContent = `${club.name} (${club.enrolled_count}/${club.capacity} คน)`;
        option.style.background = "#0d281a";
        option.style.color = "var(--text-primary)";
        select.appendChild(option);
    });
}

// 🏫 จัดการเมื่อมีการเลือกชุมนุมใน dropdown ค้นหา
async function handleClubSelectChange(event) {
    const clubId = event.target.value;
    const searchInput = document.getElementById("reg-search-input");
    const resultsContainer = document.getElementById("reg-search-results-container");
    const resultsBody = document.getElementById("reg-search-results-body");
    const emptyState = document.getElementById("reg-search-empty-state");

    if (!clubId) {
        resultsContainer.style.display = "none";
        emptyState.style.display = "block";
        emptyState.innerHTML = `
            <i class="fa-regular fa-folder-open" style="font-size: 3rem; color: var(--text-muted); margin-bottom: 1rem;"></i>
            <p>กรุณากรอกเลขประจำตัว หรือเลือกชุมนุมเพื่อค้นหาข้อมูล</p>
        `;
        return;
    }

    // ล้างข้อความในช่องค้นหาเดิมเพื่อไม่ให้สับสน
    searchInput.value = "";

    resultsContainer.style.display = "none";
    emptyState.style.display = "block";
    emptyState.innerHTML = `<i class="fa-solid fa-circle-notch fa-spin" style="font-size:2.5rem; color:var(--accent-mint); margin-bottom:1rem;"></i><p>กำลังค้นหาข้อมูลการลงทะเบียน...</p>`;

    try {
        const { data, error } = await supabaseClient
            .from("registrations")
            .select(`
                *,
                clubs ( name, teacher )
            `)
            .eq("club_id", clubId)
            .order("created_at", { ascending: true });

        if (error) throw error;

        if (data && data.length > 0) {
            resultsBody.innerHTML = "";
            data.forEach(reg => {
                const date = new Date(reg.created_at).toLocaleString("th-TH", { timeZone: "Asia/Bangkok" });
                const statusBadge = reg.registration_status === 'verified' 
                    ? `<span class="ticket-status-badge verified" style="font-size:0.75rem;">ยืนยันสิทธิ์แล้ว</span>`
                    : `<span class="ticket-status-badge pending" style="font-size:0.75rem;">สำรองสิทธิ์ (Pending)</span>`;

                const row = document.createElement("tr");
                row.innerHTML = `
                    <td><strong>${reg.student_id || "นักเรียนใหม่"}</strong></td>
                    <td>${reg.prefix || ""}${reg.first_name} ${reg.last_name}</td>
                    <td>${reg.level}</td>
                    <td style="color:var(--accent-mint); font-weight:600;">${reg.clubs ? reg.clubs.name : "ไม่ระบุ"}</td>
                    <td>${reg.clubs ? reg.clubs.teacher : "ไม่ระบุ"}</td>
                    <td>${statusBadge}</td>
                    <td style="font-size:0.85rem; color:var(--text-secondary);">${date} น.</td>
                `;
                resultsBody.appendChild(row);
            });

            emptyState.style.display = "none";
            resultsContainer.style.display = "block";
        } else {
            emptyState.style.display = "block";
            const selectedClubName = event.target.options[event.target.selectedIndex].text.split('(')[0].trim();
            emptyState.innerHTML = `
                <i class="fa-regular fa-face-frown" style="font-size: 3rem; color: var(--text-muted); margin-bottom: 1rem;"></i>
                <p>ยังไม่มีนักเรียนลงทะเบียนใน "${selectedClubName}" ในขณะนี้</p>
            `;
        }
    } catch (e) {
        console.error("Error searching registrations by club:", e);
        showToast("เกิดข้อผิดพลาดในการดึงรายชื่อผู้สมัครรายชุมนุม", "error");
        emptyState.style.display = "block";
        emptyState.innerHTML = `<p>เกิดข้อผิดพลาดทางเทคนิคในการเรียกฐานข้อมูล</p>`;
    }
}

// =====================================================================
// ⚙️ 7. ADMIN DASHBOARD & CONTROL SYSTEM
// =====================================================================
function attemptAdminLogin() {
    const entered = document.getElementById("admin-passcode-input").value;
    const config = state.settings.school_config || {};
    
    if (entered === (config.admin_password || "admin")) {
        state.isAdminLoggedIn = true;
        document.getElementById("admin-login-area").style.display = "none";
        document.getElementById("admin-dashboard-area").style.display = "grid";
        
        loadAdminDashboardData();
        showToast("ยินดีต้อนรับผู้บริหารระดับโรงเรียน เข้าสู่ระบบควบคุมสำเร็จรูป", "success");
    } else {
        showToast("รหัสผ่านควบคุมไม่ถูกต้อง กรุณาตรวจสอบรหัสผ่านอีกครั้ง", "error");
    }
}

function handleAdminLoginKeyPress(event) {
    if (event.key === "Enter") {
        attemptAdminLogin();
    }
}

function adminLogout() {
    state.isAdminLoggedIn = false;
    document.getElementById("admin-passcode-input").value = "";
    document.getElementById("admin-dashboard-area").style.display = "none";
    document.getElementById("admin-login-area").style.display = "block";
    showToast("ออกจากระบบหลังบ้านเรียบร้อยแล้ว", "info");
}

function switchAdminSubTab(subTabId) {
    state.activeAdminSubTab = subTabId;
    
    // เปลี่ยนสถานะปุ่มเมนู
    document.querySelectorAll(".admin-tab-btn").forEach(btn => btn.classList.remove("active"));
    document.getElementById(`admin-menu-${subTabId}`).classList.add("active");

    // สลับพื้นที่เนื้อหาย่อย
    document.querySelectorAll(".admin-sub-view").forEach(view => view.style.display = "none");
    document.getElementById(`admin-sub-${subTabId}`).style.display = "block";

    loadAdminDashboardData();
}

// โหลดข้อมูลรายงานและตารางสิทธิ์ต่างๆ ทั้งหมดมาเก็บไว้ที่ State
async function loadAdminDashboardData() {
    if (!supabaseClient || !state.isAdminLoggedIn) return;

    try {
        // ดึงการลงทะเบียนทั้งหมดพร้อมข้อมูลความสัมพันธ์
        const { data: regs, error: errRegs } = await supabaseClient
            .from("registrations")
            .select(`
                *,
                clubs ( name, teacher, location )
            `)
            .order("created_at", { ascending: false });

        if (errRegs) throw errRegs;
        state.registrations = regs || [];

        // อัปเดต Badge แจ้งเตือนยอดเด็กใหม่รอยืนยันสิทธิ์
        const pendingsCount = state.registrations.filter(r => r.registration_status === 'pending').length;
        document.getElementById("admin-pending-badge").innerText = pendingsCount;

        // นำไปเรนเดอร์ย่อยตามแท็บ
        if (state.activeAdminSubTab === 'stats') {
            renderAdminStats();
        } else if (state.activeAdminSubTab === 'pending') {
            renderAdminPendingStudents();
        } else if (state.activeAdminSubTab === 'clubs') {
            renderAdminManageClubs();
        } else if (state.activeAdminSubTab === 'students') {
            loadStudentsList();
        } else if (state.activeAdminSubTab === 'settings') {
            renderAdminSettings();
        } else if (state.activeAdminSubTab === 'logs') {
            loadAdminLogs();
        }
    } catch (e) {
        console.error("Error loading admin dashboard data:", e);
        showToast("ไม่สามารถเรียกข้อมูลสิทธิ์การจัดการระบบได้", "error");
    }
}

// 📊 Render หน้ารายงานสรุปผล
function renderAdminStats() {
    // 1. คำนวณภาพรวมสถิติ
    const totalClubs = state.clubs.length;
    let totalSeats = 0;
    state.clubs.forEach(c => totalSeats += c.capacity);

    const totalEnrolled = state.registrations.length;
    const totalVerified = state.registrations.filter(r => r.registration_status === 'verified').length;
    const totalPending = state.registrations.filter(r => r.registration_status === 'pending').length;

    document.getElementById("stat-total-clubs").innerText = totalClubs;
    document.getElementById("stat-total-seats").innerText = totalSeats;
    document.getElementById("stat-total-enrolled").innerText = totalVerified;
    document.getElementById("stat-total-pending").innerText = totalPending;

    // 2. เติมข้อมูลลงในตารางสถิติแยกตามชุมนุม
    const tbody = document.getElementById("admin-stats-clubs-tbody");
    tbody.innerHTML = "";

    state.clubs.forEach(club => {
        const clubRegs = state.registrations.filter(r => r.club_id === club.id);
        const verifiedCount = clubRegs.filter(r => r.registration_status === 'verified').length;
        const pendingCount = clubRegs.filter(r => r.registration_status === 'pending').length;
        const totalCount = clubRegs.length;
        
        const densityPct = Math.round((totalCount / club.capacity) * 100);

        const row = document.createElement("tr");
        row.innerHTML = `
            <td><strong>${club.name}</strong></td>
            <td>${club.teacher}</td>
            <td><div class="grade-badges">${club.grades.map(g=>`<span class="grade-badge" style="font-size:0.65rem;">${g}</span>`).join('')}</div></td>
            <td>${club.capacity} ที่นั่ง</td>
            <td>
                <strong>${totalCount}</strong> คน 
                <span style="font-size:0.8rem; color:var(--text-muted);">(${verifiedCount} เดิม / ${pendingCount} ใหม่)</span>
            </td>
            <td>
                <span style="font-weight:700; color: ${densityPct >= 100 ? 'var(--status-danger)' : densityPct >= 70 ? 'var(--status-warning)' : 'var(--accent-mint)'};">
                    ${densityPct}%
                </span>
            </td>
            <td>
                <div style="display:flex; gap:6px; justify-content:center; flex-wrap:wrap;">
                    <button class="btn-small" onclick="openAdminClubStudentsModal('${club.id}')" style="background:rgba(52,211,153,0.15); border:1px solid var(--accent-mint); color:var(--accent-mint); padding:4px 8px; border-radius:4px; font-size:0.75rem; display:flex; align-items:center; gap:4px; cursor:pointer;">
                        <i class="fa-solid fa-users-gear"></i> จัดการ
                    </button>
                    <button class="btn-small-success" onclick="exportSingleClubToCSV('${club.id}', '${club.name}')" style="padding:4px 8px; border-radius:4px; font-size:0.75rem; cursor:pointer;">
                        <i class="fa-solid fa-download"></i> รายชื่อ
                    </button>
                </div>
            </td>
        `;
        tbody.appendChild(row);
    });
}

// ⏳ Render หน้าจัดการยืนยันเด็กใหม่ (Pending Students)
function renderAdminPendingStudents() {
    const tbody = document.getElementById("admin-pending-students-tbody");
    tbody.innerHTML = "";

    const pendings = state.registrations.filter(r => r.registration_status === 'pending');

    if (pendings.length === 0) {
        tbody.innerHTML = `
            <tr>
                <td colspan="6" style="text-align: center; color: var(--text-muted); padding: 3rem 0;">
                    <i class="fa-solid fa-circle-check" style="font-size: 2.5rem; color: var(--accent-mint); margin-bottom: 1rem;"></i>
                    <p>ไม่มีรายชื่อนักเรียนใหม่ที่ต้องยืนยันตัวตนในขณะนี้ สบายใจได้!</p>
                </td>
            </tr>
        `;
        return;
    }

    pendings.forEach(reg => {
        const date = new Date(reg.created_at).toLocaleDateString("th-TH") + " " + new Date(reg.created_at).toLocaleTimeString("th-TH", {hour: '2-digit', minute:'2-digit'});
        const clubName = reg.clubs ? reg.clubs.name : "ไม่พบประวัติ";

        const row = document.createElement("tr");
        const fullName = (reg.prefix || "") + reg.first_name + " " + reg.last_name;
        row.innerHTML = `
            <td><strong>${fullName}</strong></td>
            <td>${reg.level}</td>
            <td style="color:var(--accent-mint); font-weight:600;">${clubName}</td>
            <td>
                <input type="text" value="${reg.student_id || ''}" placeholder="กรอกเลขนักเรียน 5 หลัก..." 
                       id="pending-id-input-${reg.id}" 
                       style="background:rgba(7,23,15,0.7); border:var(--border-glass); color:var(--text-primary); padding:6px 10px; border-radius:4px; font-size:0.85rem; width:140px;">
            </td>
            <td style="font-size:0.82rem; color:var(--text-secondary);">${date}</td>
            <td style="display:flex; gap:8px;">
                <button class="btn-small-success" onclick="approvePendingRegistration('${reg.id}')">
                    <i class="fa-solid fa-check"></i> อนุมัติสิทธิ์
                </button>
                <button class="btn-small-danger" onclick="cancelPendingRegistration('${reg.id}', '${reg.club_id}')">
                    <i class="fa-solid fa-trash-can"></i> ยกเลิก
                </button>
            </td>
        `;
        tbody.appendChild(row);
    });
}

// 🟢 อนุมัติข้อมูลเด็กใหม่
async function approvePendingRegistration(regId) {
    if (!supabaseClient) return;
    const stdIdVal = document.getElementById(`pending-id-input-${regId}`).value.trim();

    if (!stdIdVal) {
        showToast("กรุณากรอกเลขประจำตัวนักเรียนจริงเพื่อใช้อ้างอิงการบันทึกสิทธิ์ก่อนยืนยันอนุมัติ", "warning");
        return;
    }

    try {
        const reg = state.registrations.find(r => r.id === regId);
        const studentName = reg ? `${reg.first_name} ${reg.last_name}` : "ไม่ทราบชื่อ";
        const clubName = reg && reg.clubs ? reg.clubs.name : "ไม่ทราบชุมนุม";
        const oldStudentId = reg ? reg.student_id : null;

        const { data, error } = await supabaseClient
            .from("registrations")
            .update({
                student_id: stdIdVal,
                registration_status: "verified"
            })
            .eq("id", regId)
            .select();

        if (error) throw error;

        // บันทึกประวัติความปลอดภัย (Audit Log)
        const ipAddress = await getUserIpAddress();
        await supabaseClient.from("audit_logs").insert({
            student_id: stdIdVal,
            student_name: studentName,
            action: "PENDING_APPROVED",
            club_name: clubName,
            ip_address: ipAddress,
            user_agent: navigator.userAgent || "Unknown Device",
            details: `ผู้ดูแลระบบอนุมัติยืนยันสิทธิ์ของเด็กใหม่ (เลขประจำตัวเดิม: ${oldStudentId || 'ไม่มี'} -> ใหม่: ${stdIdVal})`
        });

        showToast("ยืนยันคุณสมบัติการเลือกเรียนชุมนุมของนักเรียนสำเร็จแล้ว", "success");
        loadAdminDashboardData();
    } catch (e) {
        console.error("Error approving pending:", e);
        showToast("เกิดข้อผิดพลาดในการบันทึกข้อมูล", "error");
    }
}

// 🔴 ยกเลิก/ลบสิทธิ์สมัคร และคืนโควตาที่นั่งให้บอร์ด
async function cancelPendingRegistration(regId, clubId) {
    if (!supabaseClient) return;
    if (!confirm("คุณแน่ใจใช่หรือไม่ว่าต้องการยกเลิกและทำลายคำร้องจองสิทธิ์ของนักเรียนคนนี้? (ระบบจะคืนที่นั่งกลับชุมนุมทันที)")) return;

    try {
        const reg = state.registrations.find(r => r.id === regId);
        const studentName = reg ? `${reg.first_name} ${reg.last_name}` : "ไม่ทราบชื่อ";
        const clubName = reg && reg.clubs ? reg.clubs.name : "ไม่ทราบชุมนุม";
        const studentId = reg ? reg.student_id : null;
        const status = reg ? reg.registration_status : "pending";

        // 1. ลบประวัติการสมัครในทะเบียน
        const { error: errDel } = await supabaseClient
            .from("registrations")
            .delete()
            .eq("id", regId);

        if (errDel) throw errDel;

        // 2. คืนที่นั่ง (หักยอด enrolled_count ออก 1)
        const { error: errUp } = await supabaseClient
            .rpc("decrement_club_seats", { p_club_id: clubId });
            
        // กรณีไม่มี RPC เฉพาะกิจ สามารถรัน update ตรงๆ แบบ concurrency อิสระได้
        if (errUp) {
            // fallback หากยังไม่ได้รันตัว decrement
            const targetClub = state.clubs.find(c => c.id === clubId);
            if (targetClub) {
                const newEnrolled = Math.max(0, targetClub.enrolled_count - 1);
                await supabaseClient
                    .from("clubs")
                    .update({ enrolled_count: newEnrolled })
                    .eq("id", clubId);
            }
        }

        // บันทึกประวัติความปลอดภัย (Audit Log)
        const ipAddress = await getUserIpAddress();
        await supabaseClient.from("audit_logs").insert({
            student_id: studentId,
            student_name: studentName,
            action: status === "verified" ? "REGISTRATION_DELETED" : "PENDING_REJECTED",
            club_name: clubName,
            ip_address: ipAddress,
            user_agent: navigator.userAgent || "Unknown Device",
            details: `ผู้ดูแลระบบทำการยกเลิกสิทธิ์และลบรายชื่อนักเรียนออกจากชุมนุม (สถานะเดิม: ${status})`
        });

        showToast("ยกเลิกและคืนโควตาชุมนุมเสร็จสิ้นแล้ว", "info");
        
        // โหลดข้อมูลใหม่ทั้งหมด
        await loadClubsData();
        loadAdminDashboardData();
    } catch (e) {
        console.error("Error cancelling pending registration:", e);
        showToast("เกิดข้อผิดพลาดในการยกเลิกรายการ", "error");
    }
}

// 🏫 Render หน้าตั้งค่าตารางจัดชุมนุม
function renderAdminManageClubs() {
    const tbody = document.getElementById("admin-manage-clubs-tbody");
    tbody.innerHTML = "";

    state.clubs.forEach(club => {
        const row = document.createElement("tr");
        row.innerHTML = `
            <td><strong>${club.name}</strong></td>
            <td>${club.teacher}</td>
            <td>${club.location}</td>
            <td><div class="grade-badges">${club.grades.map(g=>`<span class="grade-badge" style="font-size:0.65rem;">${g}</span>`).join('')}</div></td>
            <td><strong>${club.enrolled_count} / ${club.capacity}</strong></td>
            <td style="font-size:0.8rem; color:var(--text-secondary); max-width:200px; overflow:hidden; text-overflow:ellipsis; white-space:nowrap;">${club.description || "-"}</td>
            <td>
                <div style="display:flex; gap:8px;">
                    <button class="btn-small-success" style="background:#0284c7; border-color:#38bdf8;" onclick="openClubFormModal('${club.id}')">
                        <i class="fa-solid fa-edit"></i>
                    </button>
                    <button class="btn-small-danger" onclick="deleteClub('${club.id}', '${club.name}')">
                        <i class="fa-solid fa-trash-can"></i>
                    </button>
                </div>
            </td>
        `;
        tbody.appendChild(row);
    });
}

// ➕ เปิด-ปิด ฟอร์มเพิ่ม/แก้ไขชุมนุม
function openClubFormModal(clubId = null) {
    const modal = document.getElementById("club-form-modal");
    
    // เคลียร์ค่าเริ่มต้นกล่อง checkbox ของระดับชั้น
    document.querySelectorAll("#club-form-grades-container input[type='checkbox']").forEach(cb => cb.checked = false);

    if (clubId) {
        // โหมดแก้ไข
        const club = state.clubs.find(c => c.id === clubId);
        if (!club) return;
        
        document.getElementById("club-form-title").innerText = "แก้ไขข้อมูลชุมนุม";
        document.getElementById("club-form-id").value = club.id;
        document.getElementById("club-form-name").value = club.name;
        document.getElementById("club-form-teacher").value = club.teacher;
        document.getElementById("club-form-location").value = club.location;
        document.getElementById("club-form-capacity").value = club.capacity;
        document.getElementById("club-form-description").value = club.description || "";
        
        // ติ๊กเลือกช่วงชั้นที่เปิดรับเดิม
        club.grades.forEach(g => {
            const cb = document.querySelector(`#club-form-grades-container input[value='${g}']`);
            if (cb) cb.checked = true;
        });
    } else {
        // โหมดสร้างใหม่
        document.getElementById("club-form-title").innerText = "เพิ่มข้อมูลชุมนุมใหม่";
        document.getElementById("club-form-id").value = "";
        document.getElementById("club-form-name").value = "";
        document.getElementById("club-form-teacher").value = "";
        document.getElementById("club-form-location").value = "";
        document.getElementById("club-form-capacity").value = "40";
        document.getElementById("club-form-description").value = "";
        
        // ติ๊กเลือกทั้งหมด
        document.querySelectorAll("#club-form-grades-container input[type='checkbox']").forEach(cb => cb.checked = true);
    }

    modal.classList.add("active");
}

function closeClubFormModal() {
    document.getElementById("club-form-modal").classList.remove("active");
}

// บันทึก/อัปเดตข้อมูลชุมนุม
async function saveClubForm() {
    if (!supabaseClient) return;

    const clubId = document.getElementById("club-form-id").value;
    const name = document.getElementById("club-form-name").value.trim();
    const teacher = document.getElementById("club-form-teacher").value.trim();
    const location = document.getElementById("club-form-location").value.trim();
    const capacity = parseInt(document.getElementById("club-form-capacity").value) || 0;
    const description = document.getElementById("club-form-description").value.trim();

    // ดึงระดับชั้นที่เช็ค
    const grades = [];
    document.querySelectorAll("#club-form-grades-container input[type='checkbox']:checked").forEach(cb => {
        grades.push(cb.value);
    });

    if (!name || !teacher || !location || capacity <= 0 || grades.length === 0) {
        showToast("กรุณากรอกข้อมูลชุมนุมและรายละเอียดที่นั่ง/ระดับชั้นที่ต้องการให้ครบถ้วน", "warning");
        return;
    }

    const payload = {
        name,
        teacher,
        location,
        capacity,
        description,
        grades
    };

    try {
        if (clubId) {
            // โหมดแก้ไข
            const existingClub = state.clubs.find(c => c.id === clubId);
            if (existingClub && capacity < existingClub.enrolled_count) {
                showToast(`ไม่สามารถปรับลดโควตาเหลือน้อยกว่า ${existingClub.enrolled_count} ที่นั่งได้ เนื่องจากมีนักเรียนลงทะเบียนไปแล้ว ${existingClub.enrolled_count} คน (หากต้องการลด กรุณายกเลิกสิทธิ์นักเรียนบางคนออกก่อน)`, "error");
                return;
            }

            const { error } = await supabaseClient
                .from("clubs")
                .update(payload)
                .eq("id", clubId);

            if (error) throw error;
            showToast("อัปเดตข้อมูลชุมนุมเรียบร้อยแล้ว", "success");
        } else {
            // โหมดเพิ่มใหม่
            const { error } = await supabaseClient
                .from("clubs")
                .insert([{ ...payload, enrolled_count: 0 }]);

            if (error) throw error;
            showToast("สร้างชุมนุมวิชาการเรียนรู้ใหม่ในระบบเรียบร้อยแล้ว", "success");
        }

        closeClubFormModal();
        
        // อัปเดตข้อมูล UI หลัก
        await loadClubsData();
        loadAdminDashboardData();
    } catch (e) {
        console.error("Error saving club:", e);
        showToast("เกิดข้อผิดพลาดในการบันทึกข้อมูลชุมนุม", "error");
    }
}

// ลบชุมนุมออก
async function deleteClub(clubId, clubName) {
    if (!supabaseClient) return;
    if (!confirm(`คุณแน่ใจใช่หรือไม่ว่าต้องการลบชุมนุม "${clubName}" ออกจากระบบ? (ประวัติการสมัครของเด็กในชุมนุมนี้ทั้งหมดจะถูกลบตามไปด้วยทันที!)`)) return;

    try {
        const { error } = await supabaseClient
            .from("clubs")
            .delete()
            .eq("id", clubId);

        if (error) throw error;

        showToast("ลบข้อมูลชุมนุมเสร็จสิ้นแล้ว", "info");
        await loadClubsData();
        loadAdminDashboardData();
    } catch (e) {
        console.error("Error deleting club:", e);
        showToast("เกิดข้อผิดพลาดทางเทคนิคในการลบ", "error");
    }
}

// 👥 ดึงรายชื่อระดับชั้นนักเรียนทั้งหมดจากฐานข้อมูล เพื่อใส่ในตัวเลือกการสมัครแบบไดนามิก (ป้องกันปัญหานำเข้าห้องเรียนไม่ตรงกัน)
let hasPopulatedRegistrationLevels = false;

async function populateRegistrationLevelDropdown(force = false) {
    const levelSelect = document.getElementById("level-input");
    if (!levelSelect || (!force && hasPopulatedRegistrationLevels)) return;

    try {
        const { data, error } = await supabaseClient
            .from("students")
            .select("level");
        
        if (error) throw error;
        
        if (data && data.length > 0) {
            const levels = [...new Set(data.map(item => item.level).filter(Boolean))];
            // จัดเรียงระดับชั้น/ห้อง (เช่น ม.1/1, ม.1/2)
            levels.sort((a, b) => a.localeCompare(b, 'th', { numeric: true }));
            
            // ล้างข้อมูลเดิม
            levelSelect.innerHTML = '<option value="">เลือกระดับชั้น/ห้อง...</option>';
            
            // แยกกลุ่มระดับชั้น
            const juniorHigh = [];
            const seniorHigh = [];
            const otherLevels = [];
            
            levels.forEach(lvl => {
                const prefix = lvl.split('/')[0];
                if (["ม.1", "ม.2", "ม.3"].includes(prefix)) {
                    juniorHigh.push(lvl);
                } else if (["ม.4", "ม.5", "ม.6"].includes(prefix)) {
                    seniorHigh.push(lvl);
                } else {
                    otherLevels.push(lvl);
                }
            });
            
            if (juniorHigh.length > 0) {
                const grp = document.createElement("optgroup");
                grp.label = "มัธยมศึกษาตอนต้น";
                juniorHigh.forEach(lvl => {
                    const opt = document.createElement("option");
                    opt.value = lvl;
                    opt.textContent = lvl;
                    grp.appendChild(opt);
                });
                levelSelect.appendChild(grp);
            }
            
            if (seniorHigh.length > 0) {
                const grp = document.createElement("optgroup");
                grp.label = "มัธยมศึกษาตอนปลาย";
                seniorHigh.forEach(lvl => {
                    const opt = document.createElement("option");
                    opt.value = lvl;
                    opt.textContent = lvl;
                    grp.appendChild(opt);
                });
                levelSelect.appendChild(grp);
            }
            
            if (otherLevels.length > 0) {
                const grp = document.createElement("optgroup");
                grp.label = "ระดับชั้นอื่นๆ";
                otherLevels.forEach(lvl => {
                    const opt = document.createElement("option");
                    opt.value = lvl;
                    opt.textContent = lvl;
                    grp.appendChild(opt);
                });
                levelSelect.appendChild(grp);
            }
            
            // ปุ่มระบุเอง
            const customOpt = document.createElement("option");
            customOpt.value = "custom";
            customOpt.textContent = "อื่นๆ (ระบุห้องเรียนเอง)...";
            customOpt.style.color = "var(--accent-mint)";
            customOpt.style.fontWeight = "bold";
            levelSelect.appendChild(customOpt);
            
            hasPopulatedRegistrationLevels = true;
        } else {
            useFallbackRegistrationLevels(levelSelect);
        }
    } catch (e) {
        console.error("Error populating registration levels:", e);
        useFallbackRegistrationLevels(levelSelect);
    }
}

function useFallbackRegistrationLevels(levelSelect) {
    levelSelect.innerHTML = `
        <option value="">เลือกระดับชั้น/ห้อง...</option>
        <optgroup label="มัธยมศึกษาตอนต้น">
            <option value="ม.1/1">ม.1/1</option><option value="ม.1/2">ม.1/2</option><option value="ม.1/3">ม.1/3</option><option value="ม.1/4">ม.1/4</option>
            <option value="ม.2/1">ม.2/1</option><option value="ม.2/2">ม.2/2</option><option value="ม.2/3">ม.2/3</option><option value="ม.2/4">ม.2/4</option>
            <option value="ม.3/1">ม.3/1</option><option value="ม.3/2">ม.3/2</option><option value="ม.3/3">ม.3/3</option><option value="ม.3/4">ม.3/4</option>
        </optgroup>
        <optgroup label="มัธยมศึกษาตอนปลาย">
            <option value="ม.4/1">ม.4/1</option><option value="ม.4/2">ม.4/2</option><option value="ม.4/3">ม.4/3</option><option value="ม.4/4">ม.4/4</option>
            <option value="ม.5/1">ม.5/1</option><option value="ม.5/2">ม.5/2</option><option value="ม.5/3">ม.5/3</option><option value="ม.5/4">ม.5/4</option>
            <option value="ม.6/1">ม.6/1</option><option value="ม.6/2">ม.6/2</option><option value="ม.6/3">ม.6/3</option><option value="ม.6/4">ม.6/4</option>
        </optgroup>
        <option value="custom" style="color: var(--accent-mint); font-weight: bold;">อื่นๆ (ระบุห้องเรียนเอง)...</option>
    `;
}

// 🛡️ พรีฟิลระดับชั้นในแบบฟอร์มการสมัครเรียน และตรวจสอบว่ามีตัวเลือกนั้นหรือไม่ (ถ้าไม่มีให้สร้างขึ้นมาแบบไดนามิกเพื่อป้องกันข้อมูลผิดพลาด)
function prefillLevelDropdownAndEnsureOption(levelValue) {
    const levelSelect = document.getElementById("level-input");
    if (!levelSelect || !levelValue) return;

    // ตรวจสอบว่ามี Option ค่านี้อยู่แล้วหรือไม่
    let optionExists = false;
    for (let i = 0; i < levelSelect.options.length; i++) {
        if (levelSelect.options[i].value === levelValue) {
            optionExists = true;
            break;
        }
    }

    // หากไม่มี Option นี้ ให้สร้างและเพิ่มเข้า dropdown ทันที
    if (!optionExists) {
        const opt = document.createElement("option");
        opt.value = levelValue;
        opt.textContent = levelValue;

        // ค้นหา optgroup ที่เหมาะสมตามโครงสร้างชั้นปี
        const prefix = levelValue.split('/')[0];
        let optgroup = null;
        const groups = levelSelect.getElementsByTagName("optgroup");
        for (let g of groups) {
            if (g.label.includes("ตอนต้น") && ["ม.1", "ม.2", "ม.3"].includes(prefix)) {
                optgroup = g;
                break;
            } else if (g.label.includes("ตอนปลาย") && ["ม.4", "ม.5", "ม.6"].includes(prefix)) {
                optgroup = g;
                break;
            }
        }

        if (optgroup) {
            optgroup.appendChild(opt);
        } else {
            // ใส่ไว้ก่อนหน้าตัวเลือกอื่นๆ (ระบุเอง)
            levelSelect.insertBefore(opt, levelSelect.lastElementChild);
        }
    }

    levelSelect.value = levelValue;
    
    // ซ่อนช่องกรอก Custom ระบุเอง เนื่องจากเรามีข้อมูลที่เลือกได้แล้ว
    const customContainer = document.getElementById("level-custom-container");
    if (customContainer) {
        customContainer.style.display = "none";
        const customInput = document.getElementById("level-custom-input");
        if (customInput) customInput.value = "";
    }
}

// 🧹 รีเซ็ตการเลือกห้องเรียนและซ่อนตัวเลือกกรอกเอง
function resetLevelInput() {
    const levelSelect = document.getElementById("level-input");
    if (levelSelect) levelSelect.value = "";
    
    const customContainer = document.getElementById("level-custom-container");
    if (customContainer) customContainer.style.display = "none";
    
    const customInput = document.getElementById("level-custom-input");
    if (customInput) customInput.value = "";
}

// 👥 ดึงรายชื่อนักเรียนที่มีในระบบ (สำหรับ bulk import และแสดงฐานข้อมูลนักเรียน)
let hasPopulatedStudentLevels = false;

async function populateStudentLevelDropdown() {
    const filterSelect = document.getElementById("admin-student-level-filter");
    if (!filterSelect || hasPopulatedStudentLevels) return;

    try {
        const { data, error } = await supabaseClient
            .from("students")
            .select("level");
        
        if (error) throw error;
        
        if (data) {
            const levels = [...new Set(data.map(item => item.level).filter(Boolean))];
            // จัดเรียงระดับชั้น/ห้อง (เช่น ม.1/1, ม.1/2)
            levels.sort((a, b) => a.localeCompare(b, 'th', { numeric: true }));
            
            const prevVal = filterSelect.value;
            filterSelect.innerHTML = '<option value="" style="background: #0d281a; color: var(--text-primary);">-- เลือกห้องเรียนทั้งหมด --</option>';
            
            levels.forEach(lvl => {
                const option = document.createElement("option");
                option.value = lvl;
                option.textContent = lvl;
                option.style.background = "#0d281a";
                option.style.color = "var(--text-primary)";
                filterSelect.appendChild(option);
            });
            
            filterSelect.value = prevVal;
            hasPopulatedStudentLevels = true;
        }
    } catch (e) {
        console.error("Error populating student levels:", e);
    }
}

function filterAdminStudentsList() {
    loadStudentsList();
}

async function loadStudentsList() {
    if (!supabaseClient) return;
    const tbody = document.getElementById("admin-students-list-tbody");
    const searchVal = document.getElementById("admin-student-search-input")?.value.trim() || "";
    const levelVal = document.getElementById("admin-student-level-filter")?.value || "";
    
    try {
        let query = supabaseClient.from("students").select("*");
        
        if (searchVal) {
            // หากเป็นตัวเลขล้วนให้ค้นหารหัสประจำตัวนักเรียน
            if (/^\d+$/.test(searchVal)) {
                query = query.ilike("student_id", `%${searchVal}%`);
            } else {
                query = query.or(`first_name.ilike.%${searchVal}%,last_name.ilike.%${searchVal}%`);
            }
        }
        
        if (levelVal) {
            query = query.eq("level", levelVal);
        }
        
        const { data, error } = await query
            .order("student_id", { ascending: true })
            .limit(100); // แสดงพรีวิวสูงสุด 100 รายการแรก

        if (error) throw error;

        tbody.innerHTML = "";
        if (data && data.length > 0) {
            data.forEach(std => {
                const row = document.createElement("tr");
                const safeId = String(std.student_id).replace(/'/g, "\\'");
                row.innerHTML = `
                    <td><strong>${std.student_id}</strong></td>
                    <td>${std.prefix || "-"}</td>
                    <td>${std.first_name}</td>
                    <td>${std.last_name}</td>
                    <td>${std.level}</td>
                    <td>
                        <div style="display:flex; gap:6px; justify-content:center;">
                            <button onclick="openStudentEditModal('${safeId}')" style="background:rgba(56,189,248,0.15); border:1px solid #38bdf8; color:#38bdf8; padding:4px 9px; border-radius:4px; font-size:0.78rem; cursor:pointer;" title="แก้ไขข้อมูลนักเรียน">
                                <i class="fa-solid fa-pen-to-square"></i>
                            </button>
                            <button onclick="deleteStudentRecord('${safeId}')" style="background:rgba(239,68,68,0.15); border:1px solid #ef4444; color:#ef4444; padding:4px 9px; border-radius:4px; font-size:0.78rem; cursor:pointer;" title="ลบนักเรียนออกจากฐานข้อมูล">
                                <i class="fa-solid fa-trash-can"></i>
                            </button>
                        </div>
                    </td>
                `;
                tbody.appendChild(row);
            });
        } else {
            tbody.innerHTML = `<tr><td colspan="6" style="text-align: center; color: var(--text-muted); padding: 1.5rem 0;">ไม่พบข้อมูลนักเรียนที่ตรงตามเงื่อนไขการค้นหา</td></tr>`;
        }

        // ดึงรายการห้องทั้งหมดมาใส่ใน dropdown
        await populateStudentLevelDropdown();
    } catch (e) {
        console.error("Error loading students list:", e);
        tbody.innerHTML = `<tr><td colspan="6" style="text-align: center; color: var(--status-danger);">ไม่สามารถดาวน์โหลดรายชื่อจากฐานข้อมูลได้</td></tr>`;
    }
}


// 📝 เปิด Modal แก้ไขข้อมูลนักเรียนในฐานข้อมูลหลัก (students)
async function openStudentEditModal(studentId) {
    if (!supabaseClient) return;
    try {
        const { data, error } = await supabaseClient
            .from("students")
            .select("*")
            .eq("student_id", studentId)
            .maybeSingle();
        if (error) throw error;
        if (!data) {
            showToast("ไม่พบนักเรียนรหัสนี้ในฐานข้อมูล", "error");
            return;
        }

        document.getElementById("student-edit-original-id").value = data.student_id;
        document.getElementById("student-edit-id").value = data.student_id;
        document.getElementById("student-edit-prefix").value = data.prefix || "";
        document.getElementById("student-edit-first-name").value = data.first_name || "";
        document.getElementById("student-edit-last-name").value = data.last_name || "";
        document.getElementById("student-edit-level").value = data.level || "";
        document.getElementById("student-edit-title").innerText = `แก้ไขข้อมูลนักเรียน: ${data.first_name} ${data.last_name}`;

        document.getElementById("student-edit-modal").classList.add("active");
    } catch (e) {
        console.error("Error loading student record:", e);
        showToast("ไม่สามารถโหลดข้อมูลนักเรียนได้", "error");
    }
}

function closeStudentEditModal() {
    document.getElementById("student-edit-modal").classList.remove("active");
}

// ➕ เปิด Modal สำหรับเพิ่มนักเรียนใหม่ (ใช้ modal เดียวกันแต่โหมด create)
function openStudentCreateModal() {
    document.getElementById("student-edit-original-id").value = "";
    document.getElementById("student-edit-id").value = "";
    document.getElementById("student-edit-prefix").value = "";
    document.getElementById("student-edit-first-name").value = "";
    document.getElementById("student-edit-last-name").value = "";
    document.getElementById("student-edit-level").value = "";
    document.getElementById("student-edit-title").innerText = "เพิ่มนักเรียนใหม่เข้าฐานข้อมูล";
    document.getElementById("student-edit-modal").classList.add("active");
}

// 💾 บันทึกข้อมูลนักเรียน (รองรับทั้งโหมดเพิ่มใหม่และแก้ไข)
async function saveStudentRecord() {
    if (!supabaseClient) return;

    const originalId = document.getElementById("student-edit-original-id").value;
    const newId = document.getElementById("student-edit-id").value.trim();
    const prefix = document.getElementById("student-edit-prefix").value;
    const firstName = document.getElementById("student-edit-first-name").value.trim();
    const lastName = document.getElementById("student-edit-last-name").value.trim();
    const level = document.getElementById("student-edit-level").value.trim();

    if (!newId || !firstName || !lastName || !level) {
        showToast("กรุณากรอกรหัสประจำตัว, ชื่อจริง, นามสกุล และระดับชั้นให้ครบถ้วน", "warning");
        return;
    }

    const isCreateMode = !originalId;

    try {
        // ตรวจสอบรหัสซ้ำ: เมื่อสร้างใหม่ หรือแก้ไขแล้วเปลี่ยน student_id
        if (isCreateMode || newId !== originalId) {
            const { data: existing, error: checkErr } = await supabaseClient
                .from("students")
                .select("student_id")
                .eq("student_id", newId)
                .maybeSingle();
            if (checkErr) throw checkErr;
            if (existing) {
                showToast(`รหัสประจำตัว ${newId} มีอยู่ในระบบแล้ว ไม่สามารถใช้ซ้ำได้`, "error");
                return;
            }
        }

        if (isCreateMode) {
            const { error } = await supabaseClient
                .from("students")
                .insert([{
                    student_id: newId,
                    prefix: prefix || null,
                    first_name: firstName,
                    last_name: lastName,
                    level: level
                }]);
            if (error) throw error;
        } else {
            const { error } = await supabaseClient
                .from("students")
                .update({
                    student_id: newId,
                    prefix: prefix || null,
                    first_name: firstName,
                    last_name: lastName,
                    level: level
                })
                .eq("student_id", originalId);
            if (error) throw error;
        }

        // เขียน Audit Log
        try {
            const ipAddress = await getUserIpAddress();
            await supabaseClient.from("audit_logs").insert({
                student_id: newId,
                student_name: `${prefix || ""}${firstName} ${lastName}`,
                action: "SETTINGS_UPDATED",
                ip_address: ipAddress,
                user_agent: navigator.userAgent || "Unknown Device",
                details: isCreateMode
                    ? `ผู้ดูแลระบบเพิ่มนักเรียนใหม่ในฐานข้อมูลหลัก (รหัส=${newId}, ชั้น=${level})`
                    : `ผู้ดูแลระบบแก้ไขข้อมูลนักเรียนในฐานข้อมูลหลัก (เดิม=${originalId}, ใหม่=${newId}, ชั้น=${level})`
            });
        } catch (logErr) {
            console.error("Audit log error:", logErr);
        }

        showToast(isCreateMode ? "เพิ่มนักเรียนใหม่สำเร็จ" : "บันทึกข้อมูลนักเรียนสำเร็จ", "success");
        closeStudentEditModal();
        hasPopulatedStudentLevels = false;
        loadStudentsList();
    } catch (e) {
        console.error("Error saving student record:", e);
        showToast("ไม่สามารถบันทึกข้อมูลนักเรียนได้: " + (e.message || e), "error");
    }
}

// 🗑️ ลบนักเรียนออกจากฐานข้อมูลหลัก
async function deleteStudentRecord(studentId) {
    if (!supabaseClient) return;

    if (!confirm(`คุณแน่ใจหรือไม่ว่าต้องการลบนักเรียนรหัส "${studentId}" ออกจากฐานข้อมูล?\n\n⚠️ การดำเนินการนี้จะลบเฉพาะข้อมูลในตารางนักเรียน (students) เท่านั้น ไม่ส่งผลต่อประวัติการลงทะเบียนชุมนุม (registrations) ที่อ้างอิงรหัสนี้`)) {
        return;
    }

    try {
        const { error } = await supabaseClient
            .from("students")
            .delete()
            .eq("student_id", studentId);

        if (error) throw error;

        // เขียน Audit Log
        try {
            const ipAddress = await getUserIpAddress();
            await supabaseClient.from("audit_logs").insert({
                student_id: studentId,
                action: "SETTINGS_UPDATED",
                ip_address: ipAddress,
                user_agent: navigator.userAgent || "Unknown Device",
                details: `ผู้ดูแลระบบลบนักเรียนรหัส "${studentId}" ออกจากฐานข้อมูลหลัก`
            });
        } catch (logErr) {
            console.error("Audit log error:", logErr);
        }

        showToast(`ลบนักเรียนรหัส ${studentId} เรียบร้อยแล้ว`, "info");
        loadStudentsList();
    } catch (e) {
        console.error("Error deleting student:", e);
        showToast("ไม่สามารถลบนักเรียนได้: " + (e.message || e), "error");
    }
}

window.openStudentEditModal = openStudentEditModal;
window.closeStudentEditModal = closeStudentEditModal;
window.openStudentCreateModal = openStudentCreateModal;
window.saveStudentRecord = saveStudentRecord;
window.deleteStudentRecord = deleteStudentRecord;


// 🟢 อัปโหลดรายชื่อเด็ก bulk import ผ่านหน้าบ้าน CSV/Excel
async function handleStudentCSVImport(event) {
    if (!supabaseClient) return;
    const file = event.target.files[0];
    if (!file) return;

    const fileExtension = file.name.split('.').pop().toLowerCase();
    showToast("กำลังเริ่มวิเคราะห์ไฟล์รายชื่อนักเรียน...", "info");

    const reader = new FileReader();
    reader.onload = async function(e) {
        try {
            let rows = [];
            if (fileExtension === 'xlsx' || fileExtension === 'xls' || fileExtension === 'csv') {
                if (typeof XLSX === 'undefined') {
                    showToast("ไม่พบไลบรารีสำหรับประมวลผลไฟล์ Excel/CSV (SheetJS)", "error");
                    return;
                }
                const data = new Uint8Array(e.target.result);
                const workbook = XLSX.read(data, { type: 'array' });
                const firstSheet = workbook.SheetNames[0];
                const worksheet = workbook.Sheets[firstSheet];
                rows = XLSX.utils.sheet_to_json(worksheet, { header: 1 });
            } else {
                showToast("ไม่รองรับรูปแบบไฟล์นี้ กรุณาใช้ไฟล์ .csv หรือ .xlsx", "error");
                return;
            }

            const headers = rows[0] ? rows[0].map(h => String(h).trim().toLowerCase()) : [];
            
            // Map headers to indexes
            let studentIdIdx = headers.findIndex(h => h.includes('student_id') || h.includes('รหัสประจำตัว') || h.includes('เลขประจำตัว'));
            let prefixIdx = headers.findIndex(h => h.includes('prefix') || h.includes('คำนำหน้า'));
            let firstNameIdx = headers.findIndex(h => h.includes('first_name') || h.includes('ชื่อจริง') || h.includes('ชื่อ'));
            let lastNameIdx = headers.findIndex(h => h.includes('last_name') || h.includes('นามสกุล'));
            let levelIdx = headers.findIndex(h => h.includes('level') || h.includes('ชั้นเรียน') || h.includes('ห้องเรียน') || h.includes('ระดับชั้น'));

            // Fallback to defaults if headers were not parsed or missing
            if (studentIdIdx === -1) studentIdIdx = 0;
            if (firstNameIdx === -1) {
                const totalCols = rows[0] ? rows[0].length : 4;
                if (totalCols >= 5) {
                    prefixIdx = 1;
                    firstNameIdx = 2;
                    lastNameIdx = 3;
                    levelIdx = 4;
                } else {
                    prefixIdx = -1;
                    firstNameIdx = 1;
                    lastNameIdx = 2;
                    levelIdx = 3;
                }
            } else {
                if (lastNameIdx === -1) lastNameIdx = firstNameIdx + 1;
                if (levelIdx === -1) levelIdx = lastNameIdx + 1;
            }

            const batch = [];
            // วนลูปอ่านข้อมูลข้ามแถวแรก (Headers)
            for (let i = 1; i < rows.length; i++) {
                const row = rows[i];
                if (!row || row.length === 0) continue;
                
                const student_id = row[studentIdIdx] ? String(row[studentIdIdx]).trim() : '';
                const prefix = prefixIdx !== -1 && row[prefixIdx] ? String(row[prefixIdx]).trim() : '';
                const first_name = row[firstNameIdx] ? String(row[firstNameIdx]).trim() : '';
                const last_name = row[lastNameIdx] ? String(row[lastNameIdx]).trim() : '';
                const level = row[levelIdx] ? String(row[levelIdx]).trim() : '';

                if (student_id && first_name) {
                    batch.push({
                        student_id: student_id,
                        prefix: prefix || null,
                        first_name: first_name,
                        last_name: last_name,
                        level: level
                    });
                }
            }

            if (batch.length === 0) {
                showToast("โครงสร้างไฟล์ไม่ถูกต้อง หรือไม่มีแถวข้อมูลที่สามารถนำเข้าได้", "error");
                return;
            }

            showToast(`กำลังส่งข้อมูลจำนวน ${batch.length} คน เข้าสู่ระบบฐานข้อมูล...`, "info");

            // อัปเดตเข้ารายชื่อ (ใช้ Upsert เพื่อทับรายชื่อเดิมหากเลขซ้ำ)
            const { error } = await supabaseClient
                .from("students")
                .upsert(batch, { onConflict: 'student_id' });

            if (error) throw error;

            showToast(`นำเข้าฐานข้อมูลรายชื่อนักเรียนสำเร็จรวม ${batch.length} รายการ!`, "success");
            loadStudentsList();
            populateRegistrationLevelDropdown(true);
        } catch (err) {
            console.error("Error importing bulk data:", err);
            showToast("เกิดข้อผิดพลาดในการ Bulk อัปเดตรายชื่อนักเรียน", "error");
        }
    };
    
    reader.readAsArrayBuffer(file);
}

// 🟢 อัปโหลดรายชื่อชุมนุม bulk import ผ่านหน้าบ้าน CSV/Excel
async function handleClubsCSVImport(event) {
    if (!supabaseClient) return;
    const file = event.target.files[0];
    if (!file) return;

    const fileExtension = file.name.split('.').pop().toLowerCase();
    showToast("กำลังเริ่มวิเคราะห์ไฟล์รายชื่อชุมนุม...", "info");

    const reader = new FileReader();
    reader.onload = async function(e) {
        try {
            let rows = [];
            if (fileExtension === 'xlsx' || fileExtension === 'xls' || fileExtension === 'csv') {
                if (typeof XLSX === 'undefined') {
                    showToast("ไม่พบไลบรารีสำหรับประมวลผลไฟล์ Excel/CSV (SheetJS)", "error");
                    return;
                }
                const data = new Uint8Array(e.target.result);
                const workbook = XLSX.read(data, { type: 'array' });
                const firstSheet = workbook.SheetNames[0];
                const worksheet = workbook.Sheets[firstSheet];
                rows = XLSX.utils.sheet_to_json(worksheet, { header: 1 });
            } else {
                showToast("ไม่รองรับรูปแบบไฟล์นี้ กรุณาใช้ไฟล์ .csv หรือ .xlsx", "error");
                return;
            }

            const batch = [];
            // วนลูปอ่านข้อมูลข้ามแถวแรก (Headers)
            // โครงสร้าง: name, teacher, location, capacity, description, grades
            for (let i = 1; i < rows.length; i++) {
                const row = rows[i];
                if (!row || row.length === 0) continue;

                const name = row[0] ? String(row[0]).trim() : '';
                const teacher = row[1] ? String(row[1]).trim() : '';
                const location = row[2] ? String(row[2]).trim() : '';
                const capacityRaw = row[3];
                const capacity = parseInt(capacityRaw) || 40;
                const description = row[4] ? String(row[4]).trim() : '';
                
                // แยกชั้นเรียนด้วย ; หรือ / หรือ | หรือ , (ค่าเริ่มต้นคือทุกชั้นปี)
                const gradesStr = row[5] ? String(row[5]).trim() : "ม.1,ม.2,ม.3,ม.4,ม.5,ม.6";
                const grades = gradesStr.split(/[;,/|]/).map(g => g.trim()).filter(Boolean);

                if (name) {
                    batch.push({
                        name: name,
                        teacher: teacher,
                        location: location,
                        capacity: capacity,
                        description: description,
                        grades: grades
                    });
                }
            }

            if (batch.length === 0) {
                showToast("โครงสร้างไฟล์ไม่ถูกต้อง หรือไม่มีแถวข้อมูลที่สามารถนำเข้าได้", "error");
                return;
            }

            showToast(`กำลังส่งข้อมูลชุมนุมจำนวน ${batch.length} ชุมนุม เข้าสู่ระบบฐานข้อมูล...`, "info");

            const { error } = await supabaseClient
                .from("clubs")
                .insert(batch);

            if (error) throw error;

            showToast(`นำเข้าฐานข้อมูลชุมนุมสำเร็จรวม ${batch.length} รายการ!`, "success");
            
            // โหลดข้อมูลชุมนุมใหม่
            loadClubsData();
            
            if (state.isAdminLoggedIn) {
                loadAdminDashboardData();
            }
        } catch (err) {
            console.error("Error importing bulk clubs data:", err);
            showToast("เกิดข้อผิดพลาดในการ Bulk อัปเดตรายชื่อชุมนุมสู่ Supabase", "error");
        }
    };
    
    reader.readAsArrayBuffer(file);
}

// 🟢 อัปโหลดรายชื่อลงทะเบียนชุมนุม bulk import ผ่านหน้าบ้าน CSV/Excel
// คอลัมน์: student_id, prefix, first_name, last_name, level, club_name
// ไม่จำเป็นต้องนำเข้านักเรียนล่วงหน้า: แถวที่มีรหัสตรงกับตาราง students จะถูกตั้งเป็น verified,
// ที่เหลือจะเป็น pending ให้ครูยืนยันสิทธิ์ภายหลังในแท็บ "จัดการเด็กสมัครใหม่"
async function handleRegistrationsCSVImport(event) {
    if (!supabaseClient) return;
    const file = event.target.files[0];
    if (!file) return;

    const fileExtension = file.name.split('.').pop().toLowerCase();
    showToast("กำลังเริ่มวิเคราะห์ไฟล์รายชื่อลงทะเบียนชุมนุม...", "info");

    const reader = new FileReader();
    reader.onload = async function(e) {
        try {
            let rows = [];
            if (fileExtension === 'xlsx' || fileExtension === 'xls' || fileExtension === 'csv') {
                if (typeof XLSX === 'undefined') {
                    showToast("ไม่พบไลบรารีสำหรับประมวลผลไฟล์ Excel/CSV (SheetJS)", "error");
                    return;
                }
                const data = new Uint8Array(e.target.result);
                const workbook = XLSX.read(data, { type: 'array' });
                const firstSheet = workbook.SheetNames[0];
                const worksheet = workbook.Sheets[firstSheet];
                rows = XLSX.utils.sheet_to_json(worksheet, { header: 1 });
            } else {
                showToast("ไม่รองรับรูปแบบไฟล์นี้ กรุณาใช้ไฟล์ .csv หรือ .xlsx", "error");
                return;
            }

            const headers = rows[0] ? rows[0].map(h => String(h).trim().toLowerCase()) : [];

            // Header detection อัจฉริยะ — รองรับทั้งภาษาไทยและอังกฤษ
            let studentIdIdx = headers.findIndex(h => h.includes('student_id') || h.includes('รหัสประจำตัว') || h.includes('เลขประจำตัว'));
            let prefixIdx = headers.findIndex(h => h.includes('prefix') || h.includes('คำนำหน้า'));
            let firstNameIdx = headers.findIndex(h => h.includes('first_name') || h.includes('ชื่อจริง') || (h.includes('ชื่อ') && !h.includes('ชุมนุม') && !h.includes('นามสกุล')));
            let lastNameIdx = headers.findIndex(h => h.includes('last_name') || h.includes('นามสกุล'));
            let levelIdx = headers.findIndex(h => h.includes('level') || h.includes('ชั้นเรียน') || h.includes('ห้องเรียน') || h.includes('ระดับชั้น'));
            let clubNameIdx = headers.findIndex(h => h.includes('club_name') || h.includes('ชุมนุม'));

            // Fallback ตามตำแหน่งคอลัมน์เดิมหากไม่พบ header
            if (studentIdIdx === -1) studentIdIdx = 0;
            if (prefixIdx === -1) prefixIdx = 1;
            if (firstNameIdx === -1) firstNameIdx = 2;
            if (lastNameIdx === -1) lastNameIdx = 3;
            if (levelIdx === -1) levelIdx = 4;
            if (clubNameIdx === -1) clubNameIdx = 5;

            const batch = [];
            for (let i = 1; i < rows.length; i++) {
                const row = rows[i];
                if (!row || row.length === 0) continue;

                const student_id = row[studentIdIdx] ? String(row[studentIdIdx]).trim() : '';
                const prefix = row[prefixIdx] ? String(row[prefixIdx]).trim() : '';
                const first_name = row[firstNameIdx] ? String(row[firstNameIdx]).trim() : '';
                const last_name = row[lastNameIdx] ? String(row[lastNameIdx]).trim() : '';
                const level = row[levelIdx] ? String(row[levelIdx]).trim() : '';
                const club_name = row[clubNameIdx] ? String(row[clubNameIdx]).trim() : '';

                // ต้องมีอย่างน้อยชื่อ + นามสกุล + ชุมนุม
                if (first_name && last_name && club_name) {
                    batch.push({
                        student_id,
                        prefix,
                        first_name,
                        last_name,
                        level,
                        club_name
                    });
                }
            }

            if (batch.length === 0) {
                showToast("โครงสร้างไฟล์ไม่ถูกต้อง หรือไม่มีแถวข้อมูลที่สามารถนำเข้าได้ (ต้องมีอย่างน้อย ชื่อ, นามสกุล, ชุมนุม)", "error");
                return;
            }

            showToast(`กำลังประมวลผลการลงทะเบียน ${batch.length} รายการ เข้าสู่ระบบฐานข้อมูล...`, "info");

            // เรียก RPC ที่จัดการ atomic capacity + dedup + verified/pending ในฝั่ง Postgres
            const ipAddress = await getUserIpAddress();
            const userAgent = navigator.userAgent || "Unknown Device";

            const { data, error } = await supabaseClient.rpc("bulk_register_atomic", {
                p_rows: batch,
                p_ip_address: ipAddress,
                p_user_agent: userAgent
            });

            if (error) throw error;

            const inserted = data?.inserted || 0;
            const skipped = data?.skipped || [];
            const failed = data?.failed || [];

            // แสดง toast สรุปผล
            let summaryType = "success";
            let summary = `นำเข้าทะเบียนสำเร็จ ${inserted} รายการ`;
            if (skipped.length > 0) summary += `, ข้าม ${skipped.length} รายการ`;
            if (failed.length > 0) {
                summary += `, ผิดพลาด ${failed.length} รายการ`;
                summaryType = "warning";
            }
            if (inserted === 0 && (skipped.length > 0 || failed.length > 0)) {
                summaryType = "error";
            }
            showToast(summary, summaryType);

            // แสดงรายงานรายละเอียดในตาราง
            renderBulkRegistrationReport(inserted, skipped, failed);

            // โหลดข้อมูลใหม่ให้สดเสมอ
            await loadClubsData();
            if (state.isAdminLoggedIn) {
                loadAdminDashboardData();
            }
        } catch (err) {
            console.error("Error importing bulk registrations:", err);
            showToast("เกิดข้อผิดพลาดในการนำเข้ารายชื่อลงทะเบียนชุมนุม: " + (err.message || err), "error");
        } finally {
            // เคลียร์ input file เผื่อให้เลือกไฟล์เดิมซ้ำได้
            event.target.value = "";
        }
    };

    reader.readAsArrayBuffer(file);
}

// 📊 แสดงรายงานผลการนำเข้าทะเบียนชุมนุม (รายการที่สำเร็จ/ข้าม/ผิดพลาด)
function renderBulkRegistrationReport(inserted, skipped, failed) {
    const reportBox = document.getElementById("bulk-registrations-report");
    if (!reportBox) return;

    const skippedRows = skipped.map(item => {
        const r = item.row || {};
        const name = `${r.prefix || ""}${r.first_name || ""} ${r.last_name || ""}`.trim() || "(ไม่ระบุชื่อ)";
        return `<tr>
            <td>${r.student_id || "-"}</td>
            <td>${name}</td>
            <td>${r.level || "-"}</td>
            <td>${r.club_name || "-"}</td>
            <td style="color: var(--status-warning);">${item.reason || "-"}</td>
        </tr>`;
    }).join("");

    const failedRows = failed.map(item => {
        const r = item.row || {};
        const name = `${r.prefix || ""}${r.first_name || ""} ${r.last_name || ""}`.trim() || "(ไม่ระบุชื่อ)";
        return `<tr>
            <td>${r.student_id || "-"}</td>
            <td>${name}</td>
            <td>${r.level || "-"}</td>
            <td>${r.club_name || "-"}</td>
            <td style="color: var(--status-danger);">${item.reason || "-"}</td>
        </tr>`;
    }).join("");

    reportBox.style.display = "block";
    reportBox.innerHTML = `
        <div style="display: flex; gap: 1rem; flex-wrap: wrap; margin-bottom: 1rem;">
            <div class="stat-card" style="flex: 1; min-width: 180px;">
                <div class="val" style="color: var(--accent-mint);">${inserted}</div>
                <div class="lbl">ลงทะเบียนสำเร็จ</div>
            </div>
            <div class="stat-card" style="flex: 1; min-width: 180px;">
                <div class="val" style="color: var(--status-warning);">${skipped.length}</div>
                <div class="lbl">ข้าม (ซ้ำ/เต็มโควตา)</div>
            </div>
            <div class="stat-card" style="flex: 1; min-width: 180px;">
                <div class="val" style="color: var(--status-danger);">${failed.length}</div>
                <div class="lbl">ผิดพลาด</div>
            </div>
        </div>
        ${(skipped.length + failed.length) === 0 ? `
            <div style="text-align:center; color: var(--accent-mint); padding: 1rem; background: rgba(16,185,129,0.08); border-radius: 8px;">
                <i class="fa-solid fa-circle-check"></i> นำเข้าครบทุกรายการโดยไม่มีปัญหา
            </div>
        ` : `
            <h4 style="margin: 0.5rem 0;"><i class="fa-solid fa-triangle-exclamation" style="color: var(--status-warning);"></i> รายการที่ไม่ถูกนำเข้า</h4>
            <div class="search-results-table-container" style="max-height: 300px; overflow-y: auto;">
                <table class="data-table">
                    <thead>
                        <tr>
                            <th>รหัสนักเรียน</th>
                            <th>ชื่อ-นามสกุล</th>
                            <th>ระดับชั้น</th>
                            <th>ชุมนุม</th>
                            <th>เหตุผล</th>
                        </tr>
                    </thead>
                    <tbody>
                        ${skippedRows}${failedRows}
                    </tbody>
                </table>
            </div>
        `}
    `;
}

// 📥 ดาวน์โหลดไฟล์เทมเพลตรายชื่อลงทะเบียนชุมนุม (.xlsx)
function downloadRegistrationsTemplate() {
    if (typeof XLSX === 'undefined') {
        showToast("ไม่พบไลบรารีสำหรับประมวลผลไฟล์ Excel (SheetJS)", "error");
        return;
    }

    const data = [
        ["student_id", "prefix", "first_name", "last_name", "level", "club_name"],
        ["10001", "นาย", "กิตติพงศ์", "ทองดี", "ม.4/1", "ชุมนุมคอมพิวเตอร์และวิทยาการคำนวณ"],
        ["10002", "นางสาว", "ณัฏฐณิชา", "จิตอารีย์", "ม.4/1", "ชุมนุมดนตรีสากลและวงสตริง"],
        ["", "เด็กชาย", "นักเรียนใหม่", "ยังไม่มีรหัส", "ม.1/2", "ชุมนุมศิลปะสร้างสรรค์และการออกแบบ"],
        ["10015", "เด็กชาย", "พีรพล", "คงกระพัน", "ม.3/1", "ชุมนุมอนุรักษ์ธรรมชาติและสิ่งแวดล้อม"]
    ];

    const ws = XLSX.utils.aoa_to_sheet(data);

    ws['!cols'] = [
        { wch: 12 }, // student_id
        { wch: 10 }, // prefix
        { wch: 18 }, // first_name
        { wch: 18 }, // last_name
        { wch: 10 }, // level
        { wch: 40 }  // club_name
    ];

    const wb = XLSX.utils.book_new();
    XLSX.utils.book_append_sheet(wb, ws, "รายชื่อลงทะเบียนชุมนุม");

    XLSX.writeFile(wb, "เทมเพลตรายชื่อลงทะเบียนชุมนุม.xlsx");
    showToast("ดาวน์โหลดเทมเพลตรายชื่อลงทะเบียนชุมนุมสำเร็จ", "success");
}

// ผูกฟังก์ชันใหม่กับ window scope ให้ event handler บนหน้า HTML เรียกได้
window.handleRegistrationsCSVImport = handleRegistrationsCSVImport;
window.downloadRegistrationsTemplate = downloadRegistrationsTemplate;

// 📥 ดาวน์โหลดไฟล์เทมเพลตรายชื่อนักเรียน (.xlsx)
function downloadStudentTemplate() {
    if (typeof XLSX === 'undefined') {
        showToast("ไม่พบไลบรารีสำหรับประมวลผลไฟล์ Excel (SheetJS)", "error");
        return;
    }

    const data = [
        ["student_id", "prefix", "first_name", "last_name", "level"],
        ["10001", "เด็กชาย", "สมชาย", "ใจดี", "ม.1/1"],
        ["10002", "เด็กหญิง", "สมหญิง", "รักเรียน", "ม.1/2"],
        ["10003", "นาย", "ศรัญญู", "มุ่งมั่น", "ม.4/3"],
        ["10004", "นางสาว", "นภาพร", "เรียนดี", "ม.5/1"]
    ];

    const ws = XLSX.utils.aoa_to_sheet(data);
    
    // ตั้งค่าความกว้างคอลัมน์ให้อ่านง่าย
    ws['!cols'] = [
        { wch: 15 }, // student_id
        { wch: 10 }, // prefix
        { wch: 15 }, // first_name
        { wch: 15 }, // last_name
        { wch: 10 }  // level
    ];

    const wb = XLSX.utils.book_new();
    XLSX.utils.book_append_sheet(wb, ws, "รายชื่อนักเรียน");
    
    XLSX.writeFile(wb, "เทมเพลตรายชื่อนักเรียน.xlsx");
    showToast("ดาวน์โหลดเทมเพลตรายชื่อนักเรียนสำเร็จ", "success");
}

// 📥 ดาวน์โหลดไฟล์เทมเพลตรายชื่อชุมนุม (.xlsx)
function downloadClubTemplate() {
    if (typeof XLSX === 'undefined') {
        showToast("ไม่พบไลบรารีสำหรับประมวลผลไฟล์ Excel (SheetJS)", "error");
        return;
    }

    const data = [
        ["name", "teacher", "location", "capacity", "description", "grades"],
        ["ชุมนุมฟุตบอลชาย", "ครูสมชาย ใจดี", "สนามฟุตบอล", "40", "ฝึกทักษะกีฬาฟุตบอลและการเล่นเป็นทีม", "ม.1;ม.2;ม.3;ม.4;ม.5;ม.6"],
        ["ชุมนุมคอมพิวเตอร์และหุ่นยนต์", "ครูสมหญิง รักเรียน", "ห้องคอมพิวเตอร์ 3", "30", "เรียนรู้การเขียนโปรแกรมและการประกอบหุ่นยนต์เบื้องต้น", "ม.4;ม.5;ม.6"],
        ["ชุมนุมดนตรีไทย", "ครูศรัญญู มุ่งมั่น", "ห้องดนตรีไทย", "20", "ฝึกฝนการเล่นเครื่องดนตรีไทยประเภทต่างๆ", "ม.1;ม.2;ม.3;ม.4;ม.5;ม.6"],
        ["ชุมนุมอนุรักษ์ธรรมชาติ", "ครูนภาพร เรียนดี", "สวนป่าโรงเรียน", "35", "ศึกษาเรียนรู้ธรรมชาติและการอนุรักษ์สิ่งแวดล้อม", "ม.1;ม.2;ม.3"]
    ];

    const ws = XLSX.utils.aoa_to_sheet(data);

    // ตั้งค่าความกว้างคอลัมน์ให้อ่านง่าย
    ws['!cols'] = [
        { wch: 25 }, // name
        { wch: 20 }, // teacher
        { wch: 15 }, // location
        { wch: 10 }, // capacity
        { wch: 35 }, // description
        { wch: 25 }  // grades
    ];

    const wb = XLSX.utils.book_new();
    XLSX.utils.book_append_sheet(wb, ws, "รายชื่อชุมนุม");
    
    XLSX.writeFile(wb, "เทมเพลตรายชื่อชุมนุม.xlsx");
    showToast("ดาวน์โหลดเทมเพลตรายชื่อชุมนุมสำเร็จ", "success");
}


// ⚙️ Render ข้อมูลหน้าตั้งค่าระบบ
function renderAdminSettings() {
    const config = state.settings.school_config || {};
    const period = state.settings.registration_period || {};

    document.getElementById("admin-settings-school-name").value = config.school_name || "";
    document.getElementById("admin-settings-semester").value = config.semester || "";
    document.getElementById("admin-settings-admin-password").value = config.admin_password || "";

    // 🖼️ แสดงพรีวิวรูปภาพโลโก้เดิม
    const previewBox = document.getElementById("settings-logo-preview");
    if (config.logo_base64) {
        previewBox.innerHTML = `<img src="${config.logo_base64}" alt="School Logo Preview">`;
        document.getElementById("btn-remove-logo").style.display = "inline-flex";
        state.temp_logo_base64 = config.logo_base64;
    } else {
        previewBox.innerHTML = `<i class="fa-solid fa-graduation-cap" style="color: var(--accent-mint); font-size: 1.5rem;" id="settings-logo-preview-icon"></i>`;
        document.getElementById("btn-remove-logo").style.display = "none";
        state.temp_logo_base64 = null;
    }

    const activeCheckbox = document.getElementById("admin-settings-is-active");
    activeCheckbox.checked = period.is_active;
    document.getElementById("admin-settings-status-label").innerText = period.is_active ? "เปิดระบบรับสมัครจริง" : "ปิดระบบรับสมัคร";

    // ตั้งค่ากล่องวันเวลา (แปลง ISO เป็น Format สำหรับ datetime-local: YYYY-MM-DDTHH:MM)
    if (period.start_time) {
        document.getElementById("admin-settings-start-time").value = formatISOToLocalInput(period.start_time);
    }
    if (period.end_time) {
        document.getElementById("admin-settings-end-time").value = formatISOToLocalInput(period.end_time);
    }
}

function formatISOToLocalInput(isoString) {
    const date = new Date(isoString);
    const tzOffset = date.getTimezoneOffset() * 60000; // แปลงส่วนต่างโซนเวลา
    const localISOTime = (new Date(date.getTime() - tzOffset)).toISOString().slice(0, 16);
    return localISOTime;
}

function toggleRegistrationState() {
    const cb = document.getElementById("admin-settings-is-active");
    cb.checked = !cb.checked;
    document.getElementById("admin-settings-status-label").innerText = cb.checked ? "เปิดระบบรับสมัครจริง" : "ปิดระบบรับสมัคร";
}

async function saveSystemSettings() {
    if (!supabaseClient) return;

    const schoolName = document.getElementById("admin-settings-school-name").value.trim();
    const semester = document.getElementById("admin-settings-semester").value.trim();
    const adminPassword = document.getElementById("admin-settings-admin-password").value.trim();

    const is_active = document.getElementById("admin-settings-is-active").checked;
    const start_time = document.getElementById("admin-settings-start-time").value;
    const end_time = document.getElementById("admin-settings-end-time").value;

    if (!schoolName || !semester || !adminPassword) {
        showToast("กรุณากรอกข้อมูลตั้งค่าหลักให้ครบถ้วน (ชื่อ, เทอม, รหัสผ่านใหม่)", "warning");
        return;
    }

    const payloadConfig = {
        school_name: schoolName,
        semester,
        admin_password: adminPassword,
        logo_base64: state.temp_logo_base64 || null
    };

    const payloadPeriod = {
        is_active,
        start_time: start_time ? new Date(start_time).toISOString() : null,
        end_time: end_time ? new Date(end_time).toISOString() : null
    };

    try {
        // อัปเดตข้อมูลลง Supabase แบบขนาน
        const updateConf = supabaseClient.from("settings").update({ value: payloadConfig }).eq("key", "school_config");
        const updatePeriod = supabaseClient.from("settings").update({ value: payloadPeriod }).eq("key", "registration_period");

        const [res1, res2] = await Promise.all([updateConf, updatePeriod]);

        if (res1.error) throw res1.error;
        if (res2.error) throw res2.error;

        showToast("บันทึกการปรับแต่งตั้งค่าโครงสร้างระบบเรียบร้อยแล้ว", "success");
        
        // บันทึกประวัติความปลอดภัย (Audit Log)
        try {
            const ipAddress = await getUserIpAddress();
            await supabaseClient.from("audit_logs").insert({
                action: "SETTINGS_UPDATED",
                ip_address: ipAddress,
                user_agent: navigator.userAgent || "Unknown Device",
                details: `ผู้ดูแลระบบแก้ไขการตั้งค่าระบบ: ชื่อโรงเรียน="${schoolName}", ภาคเรียน="${semester}", สถานะเปิดรับสมัคร=${is_active ? 'เปิด' : 'ปิด'}`
            });
        } catch (logErr) {
            console.error("Failed to write settings audit log:", logErr);
        }

        // อัปโหลดข้อมูลสถานะเก็บเข้าตัวแปรหลัก
        state.settings.school_config = payloadConfig;
        state.settings.registration_period = payloadPeriod;
        
        updateSystemUI();
    } catch (e) {
        console.error("Error saving settings:", e);
    }
}

// 🖼️ จัดการการอัปโหลดโลโก้โรงเรียน (Base64)
function handleLogoUpload(event) {
    const file = event.target.files[0];
    if (!file) return;

    // ตรวจสอบขนาดไฟล์ (ไม่ควรเกิน 2MB เพื่อป้องกันไม่ให้หนักฐานข้อมูลเกินไป)
    if (file.size > 2 * 1024 * 1024) {
        showToast("ขนาดรูปภาพต้องไม่เกิน 2MB เพื่อความเสถียรและรวดเร็วในการโหลดระบบ", "warning");
        event.target.value = "";
        return;
    }

    const reader = new FileReader();
    reader.onload = function(e) {
        const base64Data = e.target.result;
        state.temp_logo_base64 = base64Data; // เก็บรูปไว้ชั่วคราว
        
        // แสดงตัวอย่างรูปภาพในหน้าต่างตั้งค่า
        const previewBox = document.getElementById("settings-logo-preview");
        previewBox.innerHTML = `<img src="${base64Data}" alt="School Logo Preview">`;
        
        // แสดงปุ่มลบโลโก้
        document.getElementById("btn-remove-logo").style.display = "inline-flex";
    };
    reader.readAsDataURL(file);
}

function removeSchoolLogo() {
    state.temp_logo_base64 = null;
    
    // รีเซ็ตหน้าตาตัวอย่างในหน้าตั้งค่า
    const previewBox = document.getElementById("settings-logo-preview");
    previewBox.innerHTML = `<i class="fa-solid fa-graduation-cap" style="color: var(--accent-mint); font-size: 1.5rem;" id="settings-logo-preview-icon"></i>`;
    
    // ซ่อนปุ่มลบโลโก้ และล้างค่าใน input
    document.getElementById("btn-remove-logo").style.display = "none";
    document.getElementById("admin-settings-logo-file").value = "";
}

// ผูกฟังก์ชันเข้ากับ global scope ให้บราวเซอร์เรียกใช้งานผ่าน Event Handler ได้เสมอ
window.handleLogoUpload = handleLogoUpload;
window.removeSchoolLogo = removeSchoolLogo;

// =====================================================================
// 📊 8. EXPORT CSV FOR THAI EXCEL (UTF-8 WITH BOM)
// =====================================================================
function exportAllRegistrationsToCSV() {
    if (state.registrations.length === 0) {
        showToast("ไม่มีข้อมูลประวัติผู้สมัครที่สามารถส่งออกได้ในขณะนี้", "warning");
        return;
    }

    // สร้าง Header ภาษาไทย
    let csvContent = "เลขประจำตัวนักเรียน,คำนำหน้า,ชื่อ,นามสกุล,ระดับชั้น/ห้อง,สถานะสิทธิ์,ชุมนุมที่เลือกเรียน,ครูผู้สอน,สถานที่เรียน,วันเวลาลงทะเบียน\n";

    state.registrations.forEach(r => {
        const studentId = r.student_id || "นักเรียนใหม่";
        const status = r.registration_status === 'verified' ? 'ยืนยันตัวตนสำเร็จ' : 'สำรองสิทธิ์ (Pending)';
        const date = new Date(r.created_at).toLocaleString("th-TH", { timeZone: "Asia/Bangkok" }).replace(",", "");
        const clubName = r.clubs ? r.clubs.name : "ไม่ระบุ";
        const teacherName = r.clubs ? r.clubs.teacher : "ไม่ระบุ";
        const loc = r.clubs ? r.clubs.location : "ไม่ระบุ";

        csvContent += `"${studentId}","${r.prefix || ""}","${r.first_name}","${r.last_name}","${r.level}","${status}","${clubName}","${teacherName}","${loc}","${date}"\n`;
    });

    downloadCSVFile(csvContent, `รายงานการลงทะเบียนชุมนุมทั้งหมด_${state.settings.school_config.semester.replace('/', '-')}.csv`);
}

function exportSingleClubToCSV(clubId, clubName) {
    const clubRegs = state.registrations.filter(r => r.club_id === clubId);

    if (clubRegs.length === 0) {
        showToast(`ชุมนุม "${clubName}" ยังไม่มีผู้ลงทะเบียนเรียนในขณะนี้`, "warning");
        return;
    }

    let csvContent = "เลขประจำตัวนักเรียน,คำนำหน้า,ชื่อ,นามสกุล,ระดับชั้น/ห้อง,สถานะสิทธิ์,วันเวลาลงทะเบียน\n";

    clubRegs.forEach(r => {
        const studentId = r.student_id || "นักเรียนใหม่";
        const status = r.registration_status === 'verified' ? 'ยืนยันตัวตนสำเร็จ' : 'สำรองสิทธิ์ (Pending)';
        const date = new Date(r.created_at).toLocaleString("th-TH", { timeZone: "Asia/Bangkok" }).replace(",", "");

        csvContent += `"${studentId}","${r.prefix || ""}","${r.first_name}","${r.last_name}","${r.level}","${status}","${date}"\n`;
    });

    downloadCSVFile(csvContent, `รายชื่อชุมนุม_${clubName}.csv`);
}

function downloadCSVFile(content, fileName) {
    // 💡 สำคัญ: ใส่ Byte Order Mark (BOM) เพื่อให้ Excel เปิดภาษาไทยได้โดยไม่เพี้ยนหรืออ่านไม่ออก!
    const BOM = "\uFEFF";
    const blob = new Blob([BOM + content], { type: "text/csv;charset=utf-8;" });
    const link = document.createElement("a");
    
    if (navigator.msSaveBlob) { // IE 10+
        navigator.msSaveBlob(blob, fileName);
    } else {
        const url = URL.createObjectURL(blob);
        link.setAttribute("href", url);
        link.setAttribute("download", fileName);
        link.style.visibility = "hidden";
        document.body.appendChild(link);
        link.click();
        document.body.removeChild(link);
    }
    
    showToast("สร้างไฟล์ดาวน์โหลดและส่งออกข้อมูลสำเร็จ", "success");
}

// =====================================================================
// 📧 9. VISUAL TOAST NOTIFICATIONS
// =====================================================================
function showToast(message, type = "info") {
    const toast = document.getElementById("toast-notify");
    const icon = document.getElementById("toast-icon");
    const msg = document.getElementById("toast-message");

    msg.innerText = message;
    toast.className = `toast-notification ${type} active`;

    // เลือกเปลี่ยนรูปไอคอนให้เข้ากับสถานะ
    if (type === "success") {
        icon.className = "fa-solid fa-circle-check";
    } else if (type === "error") {
        icon.className = "fa-solid fa-circle-exclamation";
    } else if (type === "warning") {
        icon.className = "fa-solid fa-triangle-exclamation";
    } else {
        icon.className = "fa-solid fa-circle-info";
    }

    // เคลียร์ Timeout อันเก่าก่อนเพื่อรีสตาร์ตเวลาของข้อความใหม่ (ป้องกันการแชร์เวลาแล้วหายไปก่อนกำหนด)
    if (activeToastTimeout) {
        clearTimeout(activeToastTimeout);
    }

    // คำนวณเวลาแสดงผลตามความยาวข้อความ (ความยาวข้อความ * 85ms ขั้นต่ำ 4.5 วินาที สูงสุด 8 วินาที)
    // เพื่อให้ผู้ใช้มีเวลาเพียงพอในการอ่านข้อความยาว ๆ เช่น คำต้อนรับชื่อ-นามสกุล
    const duration = Math.max(4500, Math.min(8000, message.length * 85));

    // ซ่อนแบนเนอร์หลังหมดเวลา
    activeToastTimeout = setTimeout(() => {
        toast.classList.remove("active");
        activeToastTimeout = null;
    }, duration);
}

// =====================================================================
// 🔒 10. AUDIT LOGS SECURITY AND MONITORING SYSTEM
// =====================================================================

// โหลดข้อมูลล็อกประวัติความปลอดภัยจากฐานข้อมูล Supabase
async function loadAdminLogs() {
    if (!supabaseClient || !state.isAdminLoggedIn) return;

    const tbody = document.getElementById("admin-logs-tbody");
    tbody.innerHTML = `
        <tr>
            <td colspan="6" style="text-align: center; color: var(--text-muted); padding: 3rem 0;">
                <i class="fa-solid fa-circle-notch fa-spin" style="font-size: 2rem; color: var(--accent-mint); margin-bottom: 1rem;"></i>
                <div style="font-size: 0.95rem;">กำลังดึงประวัติความปลอดภัยระบบ...</div>
            </td>
        </tr>
    `;

    try {
        const { data, error } = await supabaseClient
            .from("audit_logs")
            .select("*")
            .order("created_at", { ascending: false });

        if (error) throw error;

        state.auditLogs = data || [];
        renderAdminLogs();
    } catch (e) {
        console.error("Error loading audit logs:", e);
        showToast("ไม่สามารถเรียกข้อมูลประวัติความปลอดภัยได้", "error");
        tbody.innerHTML = `
            <tr>
                <td colspan="6" style="text-align: center; color: #ef4444; padding: 3rem 0;">
                    <i class="fa-solid fa-triangle-exclamation" style="font-size: 2.5rem; margin-bottom: 1rem;"></i>
                    <div style="font-weight: bold;">เกิดข้อผิดพลาดในการโหลดข้อมูล</div>
                    <div style="font-size: 0.85rem; color: var(--text-muted); margin-top: 5px;">${e.message || e}</div>
                </td>
            </tr>
        `;
    }
}

// เรนเดอร์ตารางล็อกความปลอดภัยระบบลงหน้าแอดมิน
function renderAdminLogs(logs = state.auditLogs) {
    const tbody = document.getElementById("admin-logs-tbody");
    tbody.innerHTML = "";

    if (logs.length === 0) {
        tbody.innerHTML = `
            <tr>
                <td colspan="6" style="text-align: center; color: var(--text-muted); padding: 3rem 0;">
                    <i class="fa-regular fa-folder-open" style="font-size: 2.5rem; color: var(--text-secondary); margin-bottom: 1rem;"></i>
                    <div style="font-size: 0.95rem;">ไม่พบรายการประวัติประวัติความปลอดภัยตามเงื่อนไขที่เลือก</div>
                </td>
            </tr>
        `;
        return;
    }

    logs.forEach(log => {
        const tr = document.createElement("tr");
        
        // 1. วัน-เวลา
        let dateStr = "-";
        if (log.created_at) {
            dateStr = new Date(log.created_at).toLocaleString("th-TH", { timeZone: "Asia/Bangkok" });
        }

        // 2. กิจกรรม (badge)
        let badgeHtml = "";
        if (log.action === "REGISTER_SUCCESS") {
            badgeHtml = `<span class="ticket-status-badge" style="background: rgba(16, 185, 129, 0.15); color: var(--accent-mint); border: 1px solid rgba(16, 185, 129, 0.3);">ลงทะเบียนสำเร็จ</span>`;
        } else if (log.action === "REGISTER_PENDING") {
            badgeHtml = `<span class="ticket-status-badge" style="background: rgba(245, 158, 11, 0.15); color: #f59e0b; border: 1px solid rgba(245, 158, 11, 0.3);">ลงสำรอง (เด็กใหม่)</span>`;
        } else if (log.action === "PENDING_APPROVED") {
            badgeHtml = `<span class="ticket-status-badge" style="background: rgba(52, 211, 153, 0.15); color: #34d399; border: 1px solid rgba(52, 211, 153, 0.3);">ครูอนุมัติสิทธิ์</span>`;
        } else if (log.action === "PENDING_REJECTED") {
            badgeHtml = `<span class="ticket-status-badge" style="background: rgba(239, 68, 68, 0.15); color: #ef4444; border: 1px solid rgba(239, 68, 68, 0.3);">ครูปฏิเสธสิทธิ์</span>`;
        } else if (log.action === "REGISTRATION_DELETED") {
            badgeHtml = `<span class="ticket-status-badge" style="background: rgba(239, 68, 68, 0.15); color: #ef4444; border: 1px solid rgba(239, 68, 68, 0.3);">ยกเลิก/ลบประวัติ</span>`;
        } else if (log.action === "SETTINGS_UPDATED") {
            badgeHtml = `<span class="ticket-status-badge" style="background: rgba(56, 189, 248, 0.15); color: #38bdf8; border: 1px solid rgba(56, 189, 248, 0.3);">ครูแก้ไขระบบ</span>`;
        } else {
            badgeHtml = `<span class="ticket-status-badge" style="background: rgba(156, 163, 175, 0.15); color: #9ca3af; border: 1px solid rgba(156, 163, 175, 0.3);">${log.action}</span>`;
        }

        // 3. นักเรียน
        const studentStr = log.student_name 
            ? `<strong>${log.student_name}</strong><br><span style="font-size: 0.8rem; color: var(--text-secondary);">เลขประจําตัว: ${log.student_id || '-'}</span>`
            : `<span style="color: var(--text-secondary);">-</span>`;

        // 4. ชุมนุม
        const clubStr = log.club_name ? `<strong>${log.club_name}</strong>` : `<span style="color: var(--text-secondary);">-</span>`;

        // 5. IP Address
        const ipStr = log.ip_address ? `<code style="background: rgba(255, 255, 255, 0.05); padding: 2px 6px; border-radius: 4px; font-family: monospace; color: var(--accent-mint);">${log.ip_address}</code>` : `<span style="color: var(--text-secondary);">-</span>`;

        // 6. รายละเอียด / อุปกรณ์
        const detailsStr = `
            <div style="font-size: 0.9rem; line-height: 1.4; color: var(--text-primary);">${log.details || '-'}</div>
            <div style="font-size: 0.75rem; color: var(--text-secondary); margin-top: 4px; display: flex; align-items: center; gap: 4px;">
                <i class="fa-solid fa-laptop-code"></i> ${log.user_agent || 'Unknown'}
            </div>
        `;

        tr.innerHTML = `
            <td>${dateStr}</td>
            <td>${badgeHtml}</td>
            <td>${studentStr}</td>
            <td>${clubStr}</td>
            <td>${ipStr}</td>
            <td>${detailsStr}</td>
        `;

        tbody.appendChild(tr);
    });
}

// คัดกรองข้อมูลประวัติความปลอดภัยด้วยคำค้นหาและกิจกรรม
function filterAdminLogs() {
    const searchVal = document.getElementById("admin-log-search-input").value.trim().toLowerCase();
    const actionVal = document.getElementById("admin-log-action-filter").value;

    let filtered = state.auditLogs;

    // 1. คัดกรองตามประเภทกิจกรรม
    if (actionVal) {
        filtered = filtered.filter(log => log.action === actionVal);
    }

    // 2. คัดกรองตามคำค้นหา (รหัสประจำตัว, ชื่อนักเรียน, ชื่อชุมนุม, รายละเอียด หรือ IP)
    if (searchVal) {
        filtered = filtered.filter(log => {
            const studentId = (log.student_id || "").toLowerCase();
            const studentName = (log.student_name || "").toLowerCase();
            const clubName = (log.club_name || "").toLowerCase();
            const details = (log.details || "").toLowerCase();
            const ip = (log.ip_address || "").toLowerCase();
            return studentId.includes(searchVal) || 
                   studentName.includes(searchVal) || 
                   clubName.includes(searchVal) || 
                   details.includes(searchVal) ||
                   ip.includes(searchVal);
        });
    }

    renderAdminLogs(filtered);
}

// ล้างคำค้นและฟิลเตอร์ทั้งหมดเพื่อแสดงผลล็อกทั้งหมด
function clearLogFilters() {
    document.getElementById("admin-log-search-input").value = "";
    document.getElementById("admin-log-action-filter").value = "";
    renderAdminLogs(state.auditLogs);
}

// =====================================================================
// 👥 ADMIN CLUB STUDENT MEMBERSHIP MANAGEMENT FUNCTIONS
// =====================================================================
let currentManagingClubId = null;

// 1. เปิดหน้าต่างจัดการรายชื่อนักเรียนในชุมนุม
async function openAdminClubStudentsModal(clubId) {
    if (!supabaseClient) return;
    currentManagingClubId = clubId;

    const club = state.clubs.find(c => c.id === clubId);
    if (!club) {
        showToast("ไม่พบข้อมูลชุมนุมนี้", "error");
        return;
    }

    // กำหนดหัวข้อและสถิติเบื้องต้น
    document.getElementById("admin-club-students-title").innerText = `จัดการสมาชิกในชุมนุม: ${club.name}`;
    
    // แสดงสถิติและโควตาชุมนุม
    const clubRegs = state.registrations.filter(r => r.club_id === clubId);
    const verifiedCount = clubRegs.filter(r => r.registration_status === 'verified').length;
    const pendingCount = clubRegs.filter(r => r.registration_status === 'pending').length;
    document.getElementById("admin-club-students-subtitle").innerText = `ครูผู้ดูแล: ${club.teacher} | สถานที่: ${club.location} | โควตา: ${clubRegs.length}/${club.capacity} คน (ยืนยันสิทธิ์แล้ว: ${verifiedCount} คน, สำรองเด็กใหม่: ${pendingCount} คน)`;

    // ซ่อน/รีเซ็ต ฟอร์มเพิ่มนักเรียนก่อน
    cancelAdminStudentForm();

    // ล้างและตั้งค่าการค้นหา
    document.getElementById("admin-club-student-search").value = "";

    // เปิดหน้าต่าง Modal Overlay
    document.getElementById("admin-club-students-modal").classList.add("active");

    // โหลดประวัติสดจาก Supabase เพื่อให้ข้อมูลแม่นยำที่สุด
    try {
        await loadAdminDashboardData();
        renderClubStudentsList();
    } catch (e) {
        console.error("Error refreshing registration list:", e);
        renderClubStudentsList(); // fallback
    }
}

// 2. ปิดหน้าต่างจัดการรายชื่อนักเรียนในชุมนุม
function closeAdminClubStudentsModal() {
    document.getElementById("admin-club-students-modal").classList.remove("active");
    currentManagingClubId = null;
    
    // โหลดบอร์ดรายงานสถิติหน้านอกใหม่เพื่อให้ตัวเลข enrolled_count สดอยู่เสมอ
    if (state.activeAdminSubTab === 'stats') {
        renderAdminStats();
    }
}

// 3. เรนเดอร์รายชื่อนักเรียนลงในตารางสไตล์พรีเมียม
function renderClubStudentsList() {
    const tbody = document.getElementById("admin-club-students-tbody");
    if (!tbody) return;
    tbody.innerHTML = "";

    if (!currentManagingClubId) return;

    // ดึงและคัดกรองข้อมูลเฉพาะของชุมนุมนี้
    let clubRegs = state.registrations.filter(r => r.club_id === currentManagingClubId);
    
    // คัดกรองตามคำค้นหา (รหัสประจำตัว หรือ ชื่อ-นามสกุล)
    const searchVal = document.getElementById("admin-club-student-search").value.trim().toLowerCase();
    if (searchVal) {
        clubRegs = clubRegs.filter(reg => {
            const studentId = (reg.student_id || "").toLowerCase();
            const fullName = `${reg.prefix || ""}${reg.first_name} ${reg.last_name}`.toLowerCase();
            return studentId.includes(searchVal) || fullName.includes(searchVal);
        });
    }

    if (clubRegs.length === 0) {
        tbody.innerHTML = `
            <tr>
                <td colspan="6" style="text-align: center; color: var(--text-muted); padding: 2rem 0;">
                    <i class="fa-solid fa-users-slash" style="font-size: 2rem; color: var(--text-muted); margin-bottom: 0.5rem; display:block;"></i>
                    ไม่พบรายชื่อนักเรียนในชุมนุมนี้
                </td>
            </tr>
        `;
        return;
    }

    // วาดแต่ละแถว
    clubRegs.forEach((reg, idx) => {
        const row = document.createElement("tr");
        const fullName = `${reg.prefix || ""}${reg.first_name} ${reg.last_name}`;
        
        let statusBadge = "";
        if (reg.registration_status === 'verified') {
            statusBadge = `<span class="ticket-status-badge verified" style="font-size:0.75rem; padding: 2px 8px; border-radius: 4px;">Verified (ยืนยันแล้ว)</span>`;
        } else {
            statusBadge = `<span class="ticket-status-badge pending" style="font-size:0.75rem; padding: 2px 8px; border-radius: 4px;">Pending (สำรองสิทธิ์)</span>`;
        }

        row.innerHTML = `
            <td>${idx + 1}</td>
            <td><strong>${reg.student_id || "นักเรียนใหม่"}</strong></td>
            <td><strong>${fullName}</strong></td>
            <td>${reg.level}</td>
            <td>${statusBadge}</td>
            <td>
                <div style="display:flex; gap:6px; justify-content:center;">
                    <button class="btn-small" onclick="editAdminStudent('${reg.id}')" style="background:rgba(56, 189, 248, 0.15); border:1px solid #38bdf8; color:#38bdf8; padding:4px 8px; border-radius:4px; font-size:0.75rem; display:flex; align-items:center; gap:2px; cursor:pointer;" title="แก้ไขข้อมูล">
                        <i class="fa-solid fa-pen-to-square"></i>
                    </button>
                    <button class="btn-small-danger" onclick="deleteAdminStudent('${reg.id}', '${currentManagingClubId}')" style="padding:4px 8px; border-radius:4px; font-size:0.75rem; display:flex; align-items:center; gap:2px; cursor:pointer;" title="ลบรายชื่อ">
                        <i class="fa-solid fa-trash-can"></i>
                    </button>
                </div>
            </td>
        `;
        tbody.appendChild(row);
    });
}

// 4. ทริกเกอร์เรนเดอร์ตารางเมื่อพิมพ์ในช่องค้นหา
function filterClubStudentsList() {
    renderClubStudentsList();
}

// 5. เปิด/ปิด การแสดงฟอร์มพับเพิ่ม/แก้ไขนักเรียน
function toggleAdminStudentForm() {
    const container = document.getElementById("admin-student-form-container");
    const toggleBtn = document.getElementById("admin-toggle-student-form-btn");
    
    if (container.style.display === "none") {
        // เปิดฟอร์ม
        container.style.display = "block";
        toggleBtn.innerHTML = `<i class="fa-solid fa-chevron-up"></i> ซ่อนฟอร์มข้อมูลนักเรียน`;
        
        // เคลียร์ค่าหากไม่ใช่โหมดแก้ไข (ไม่มี reg-id ค้างไว้)
        if (!document.getElementById("admin-reg-id").value) {
            resetAdminStudentFormFields();
            document.getElementById("admin-student-form-title").innerHTML = `<i class="fa-solid fa-user-plus"></i> เพิ่มนักเรียนใหม่ในชุมนุมนี้`;
        }
    } else {
        // ปิดฟอร์ม
        cancelAdminStudentForm();
    }
}

// 6. ยกเลิกและซ่อนฟอร์มกลับไปพร้อมเคลียร์ฟิลด์
function cancelAdminStudentForm() {
    const container = document.getElementById("admin-student-form-container");
    const toggleBtn = document.getElementById("admin-toggle-student-form-btn");
    
    container.style.display = "none";
    toggleBtn.innerHTML = `<i class="fa-solid fa-user-plus"></i> เพิ่มนักเรียนใหม่ในชุมนุมนี้`;
    
    resetAdminStudentFormFields();
}

// 7. เคลียร์ค่าทั้งหมดภายในช่องกรอกข้อมูลนักเรียน
function resetAdminStudentFormFields() {
    document.getElementById("admin-reg-id").value = "";
    document.getElementById("admin-reg-student-id").value = "";
    document.getElementById("admin-reg-level").value = "";
    document.getElementById("admin-reg-prefix").value = "";
    document.getElementById("admin-reg-first-name").value = "";
    document.getElementById("admin-reg-last-name").value = "";
    document.getElementById("admin-reg-status").value = "verified"; // ค่าตั้งต้นคือยืนยันตัวตนเลย
    
    document.getElementById("admin-student-submit-btn").innerHTML = `<i class="fa-solid fa-save"></i> บันทึกข้อมูล`;
}

// 8. ดึงประวัตินักเรียนผ่านรหัสประจำตัวอัตโนมัติ (เมื่อพิมพ์เลขนักเรียน 5 หลัก)
async function handleAdminStudentIdChange() {
    const studentIdInput = document.getElementById("admin-reg-student-id");
    if (!studentIdInput) return;
    const studentId = studentIdInput.value.trim();
    if (!studentId) return;

    try {
        const { data, error } = await supabaseClient
            .from("students")
            .select("*")
            .eq("student_id", studentId)
            .maybeSingle();

        if (error) throw error;

        if (data) {
            // เติมฟอร์มโดยอัตโนมัติ
            if (data.prefix) document.getElementById("admin-reg-prefix").value = data.prefix;
            if (data.first_name) document.getElementById("admin-reg-first-name").value = data.first_name;
            if (data.last_name) document.getElementById("admin-reg-last-name").value = data.last_name;
            if (data.level) document.getElementById("admin-reg-level").value = data.level;
            
            showToast(`พบประวัตินักเรียน ${data.prefix || ""}${data.first_name} ${data.last_name} ในระบบล่วงหน้าแล้ว! กรอกข้อมูลอัตโนมัติเรียบร้อย`, "success");
        }
    } catch (e) {
        console.error("Error auto-fetching student:", e);
    }
}

// 9. เลือกนักเรียนมากรอกฟอร์มเพื่อแก้ไข
function editAdminStudent(regId) {
    const reg = state.registrations.find(r => r.id === regId);
    if (!reg) return;

    // เติมข้อมูลลงในช่องกรอก
    document.getElementById("admin-reg-id").value = reg.id;
    document.getElementById("admin-reg-student-id").value = reg.student_id || "";
    document.getElementById("admin-reg-level").value = reg.level;
    document.getElementById("admin-reg-prefix").value = reg.prefix || "";
    document.getElementById("admin-reg-first-name").value = reg.first_name;
    document.getElementById("admin-reg-last-name").value = reg.last_name;
    document.getElementById("admin-reg-status").value = reg.registration_status;

    // อัปเดต UI ฟอร์มและเปิดเลื่อนลงมา
    document.getElementById("admin-student-form-title").innerHTML = `<i class="fa-solid fa-user-pen"></i> แก้ไขข้อมูลสมาชิกในชุมนุม`;
    document.getElementById("admin-student-submit-btn").innerHTML = `<i class="fa-solid fa-floppy-disk"></i> บันทึกการแก้ไข`;

    const container = document.getElementById("admin-student-form-container");
    const toggleBtn = document.getElementById("admin-toggle-student-form-btn");
    
    container.style.display = "block";
    toggleBtn.innerHTML = `<i class="fa-solid fa-chevron-up"></i> ซ่อนฟอร์มข้อมูลนักเรียน`;
    
    // โฟกัสไปที่ฟิลด์แรก
    document.getElementById("admin-reg-student-id").focus();
}

// 10. บันทึกข้อมูลลงทะเบียนนักเรียน (เพิ่มใหม่ หรือ อัปเดต)
async function saveAdminStudentRegistration() {
    if (!supabaseClient || !currentManagingClubId) return;

    const regId = document.getElementById("admin-reg-id").value;
    const studentId = document.getElementById("admin-reg-student-id").value.trim();
    const level = document.getElementById("admin-reg-level").value.trim();
    const prefix = document.getElementById("admin-reg-prefix").value;
    const firstName = document.getElementById("admin-reg-first-name").value.trim();
    const lastName = document.getElementById("admin-reg-last-name").value.trim();
    const status = document.getElementById("admin-reg-status").value;

    // ตรวจสอบความถูกต้องขั้นพื้นฐาน
    if (!firstName || !lastName || !level) {
        showToast("กรุณากรอกชื่อจริง นามสกุล และระดับชั้นเรียนของนักเรียนให้ครบถ้วน", "warning");
        return;
    }

    const club = state.clubs.find(c => c.id === currentManagingClubId);
    if (!club) return;

    const isEditMode = !!regId;

    try {
        const ipAddress = await getUserIpAddress();
        const userAgent = navigator.userAgent || "Unknown Device";

        // ตรวจสอบกรณีชื่อ-นามสกุลซ้ำกันในระบบทะเบียน (ไม่ให้ทับคนอื่น)
        const isDuplicateName = state.registrations.some(r => 
            r.first_name.toLowerCase() === firstName.toLowerCase() && 
            r.last_name.toLowerCase() === lastName.toLowerCase() && 
            r.id !== regId
        );
        if (isDuplicateName) {
            showToast(`ขออภัย นักเรียนชื่อ "${firstName} ${lastName}" ได้ลงทะเบียนในระบบเรียบร้อยแล้ว ไม่สามารถลงซ้ำได้`, "error");
            return;
        }

        // หากเป็นการเพิ่มใหม่ และชุมนุมเต็มแล้ว ให้แอดมินยืนยันอีกรอบ
        if (!isEditMode) {
            const currentTotalCount = state.registrations.filter(r => r.club_id === currentManagingClubId).length;
            if (currentTotalCount >= club.capacity) {
                if (!confirm(`⚠️ ขณะนี้ชุมนุมนี้เต็มแล้ว (${currentTotalCount}/${club.capacity} คน) คุณแน่ใจใช่หรือไม่ว่าต้องการเพิ่มนักเรียนคนนี้เป็นกรณีพิเศษ (Over-capacity)?`)) {
                    return;
                }
            }
        }

        const submitBtn = document.getElementById("admin-student-submit-btn");
        submitBtn.disabled = true;
        submitBtn.innerHTML = `<div class="spinner"></div> กำลังบันทึก...`;

        if (isEditMode) {
            // โหมดแก้ไข
            const { error: updateErr } = await supabaseClient
                .from("registrations")
                .update({
                    student_id: studentId || null,
                    prefix: prefix || null,
                    first_name: firstName,
                    last_name: lastName,
                    level: level,
                    registration_status: status
                })
                .eq("id", regId);

            if (updateErr) throw updateErr;

            // บันทึกประวัติ Audit Log
            await supabaseClient.from("audit_logs").insert({
                student_id: studentId || null,
                student_name: `${prefix || ""}${firstName} ${lastName}`,
                action: "SETTINGS_UPDATED",
                club_name: club.name,
                ip_address: ipAddress,
                user_agent: userAgent,
                details: `ผู้ดูแลระบบแก้ไขข้อมูลทะเบียนนักเรียนโดยตรง (รหัสนักเรียน: ${studentId || 'ไม่มี'}, ชั้น: ${level}, สถานะ: ${status})`
            });

            showToast("แก้ไขข้อมูลนักเรียนในทะเบียนสำเร็จแล้ว", "success");
        } else {
            // โหมดเพิ่มใหม่
            const { error: insertErr } = await supabaseClient
                .from("registrations")
                .insert([{
                    club_id: currentManagingClubId,
                    student_id: studentId || null,
                    prefix: prefix || null,
                    first_name: firstName,
                    last_name: lastName,
                    level: level,
                    registration_status: status
                }]);

            if (insertErr) throw insertErr;

            // ปรับปรุงยอดตัวเลขนับจำนวนผู้ลงสมัครในชุมนุม +1
            const newEnrolled = club.enrolled_count + 1;
            await supabaseClient
                .from("clubs")
                .update({ enrolled_count: newEnrolled })
                .eq("id", currentManagingClubId);

            // บันทึกประวัติ Audit Log
            await supabaseClient.from("audit_logs").insert({
                student_id: studentId || null,
                student_name: `${prefix || ""}${firstName} ${lastName}`,
                action: "REGISTER_SUCCESS",
                club_name: club.name,
                ip_address: ipAddress,
                user_agent: userAgent,
                details: `ผู้ดูแลระบบทำการเพิ่มและลงทะเบียนนักเรียนเข้าสู่ชุมนุมโดยตรง (รหัสนักเรียน: ${studentId || 'ไม่มี'}, ชั้น: ${level}, สถานะ: ${status})`
            });

            showToast(`เพิ่มนักเรียนเข้าสู่ชุมนุม "${club.name}" เรียบร้อยแล้ว`, "success");
        }

        // คืนค่าปุ่ม
        submitBtn.disabled = false;

        // อัปเดตข้อมูล State และ UI
        await loadClubsData();
        await loadAdminDashboardData();
        
        // รีเฟรชหัวข้อย่อยโควตาชุมนุมของ Modal
        const clubRegs = state.registrations.filter(r => r.club_id === currentManagingClubId);
        const verifiedCount = clubRegs.filter(r => r.registration_status === 'verified').length;
        const pendingCount = clubRegs.filter(r => r.registration_status === 'pending').length;
        const targetClub = state.clubs.find(c => c.id === currentManagingClubId);
        if (targetClub) {
            document.getElementById("admin-club-students-subtitle").innerText = `ครูผู้ดูแล: ${targetClub.teacher} | สถานที่: ${targetClub.location} | โควตา: ${clubRegs.length}/${targetClub.capacity} คน (ยืนยันสิทธิ์แล้ว: ${verifiedCount} คน, สำรองเด็กใหม่: ${pendingCount} คน)`;
        }

        cancelAdminStudentForm();
        renderClubStudentsList();

    } catch (e) {
        console.error("Error saving student registration:", e);
        showToast("เกิดข้อผิดพลาดในการบันทึกข้อมูล กรุณาตรวจสอบสิทธิ์และค่าที่ระบุอีกครั้ง", "error");
        document.getElementById("admin-student-submit-btn").disabled = false;
        if (isEditMode) {
            document.getElementById("admin-student-submit-btn").innerHTML = `<i class="fa-solid fa-floppy-disk"></i> บันทึกการแก้ไข`;
        } else {
            document.getElementById("admin-student-submit-btn").innerHTML = `<i class="fa-solid fa-save"></i> บันทึกข้อมูล`;
        }
    }
}

// 11. ลบประวัตินักเรียนและคืนโควตาชุมนุม
async function deleteAdminStudent(regId, clubId) {
    if (!supabaseClient) return;

    const reg = state.registrations.find(r => r.id === regId);
    if (!reg) return;

    const fullName = `${reg.prefix || ""}${reg.first_name} ${reg.last_name}`;

    if (!confirm(`คุณแน่ใจใช่หรือไม่ว่าต้องการลบสิทธิ์ของ "${fullName}" ออกจากทะเบียนชุมนุมนี้?\n(การดำเนินการนี้จะลบข้อมูลออกถาวรและคืนที่นั่ง 1 ที่กลับสู่ระบบทันที!)`)) {
        return;
    }

    try {
        const ipAddress = await getUserIpAddress();
        const userAgent = navigator.userAgent || "Unknown Device";
        const club = state.clubs.find(c => c.id === clubId);

        // 1. ลบจากทะเบียน
        const { error: delErr } = await supabaseClient
            .from("registrations")
            .delete()
            .eq("id", regId);

        if (delErr) throw delErr;

        // 2. คืนที่นั่ง ( decrement_club_seats RPC หรือ อัปเดต enrolled_count Direct)
        const { error: errUp } = await supabaseClient
            .rpc("decrement_club_seats", { p_club_id: clubId });
            
        if (errUp && club) {
            // fallback หาก RPC ไม่มีตัวตน
            const newEnrolled = Math.max(0, club.enrolled_count - 1);
            await supabaseClient
                .from("clubs")
                .update({ enrolled_count: newEnrolled })
                .eq("id", clubId);
        }

        // 3. เขียนประวัติ Audit Log
        await supabaseClient.from("audit_logs").insert({
            student_id: reg.student_id || null,
            student_name: fullName,
            action: "REGISTRATION_DELETED",
            club_name: club ? club.name : "ไม่ทราบชุมนุม",
            ip_address: ipAddress,
            user_agent: userAgent,
            details: `ผู้ดูแลระบบลบชื่อนักเรียนออกจากบัญชีรายชื่อของชุมนุมโดยตรง`
        });

        showToast(`ลบสิทธิ์นักเรียน "${fullName}" และคืนที่นั่งเรียบร้อยแล้ว`, "info");

        // อัปเดตข้อมูล State และ UI
        await loadClubsData();
        await loadAdminDashboardData();

        // รีเฟรชหัวข้อย่อยโควตาชุมนุมของ Modal
        const clubRegs = state.registrations.filter(r => r.club_id === currentManagingClubId);
        const verifiedCount = clubRegs.filter(r => r.registration_status === 'verified').length;
        const pendingCount = clubRegs.filter(r => r.registration_status === 'pending').length;
        const targetClub = state.clubs.find(c => c.id === currentManagingClubId);
        if (targetClub) {
            document.getElementById("admin-club-students-subtitle").innerText = `ครูผู้ดูแล: ${targetClub.teacher} | สถานที่: ${targetClub.location} | โควตา: ${clubRegs.length}/${targetClub.capacity} คน (ยืนยันสิทธิ์แล้ว: ${verifiedCount} คน, สำรองเด็กใหม่: ${pendingCount} คน)`;
        }

        renderClubStudentsList();

    } catch (e) {
        console.error("Error deleting student from club:", e);
        showToast("เกิดข้อผิดพลาดในการลบรายการนักเรียน", "error");
    }
}

// ผูกฟังก์ชันใหม่กับ window scope
window.openAdminClubStudentsModal = openAdminClubStudentsModal;
window.closeAdminClubStudentsModal = closeAdminClubStudentsModal;
window.renderClubStudentsList = renderClubStudentsList;
window.filterClubStudentsList = filterClubStudentsList;
window.toggleAdminStudentForm = toggleAdminStudentForm;
window.cancelAdminStudentForm = cancelAdminStudentForm;
window.handleAdminStudentIdChange = handleAdminStudentIdChange;
window.editAdminStudent = editAdminStudent;
window.saveAdminStudentRegistration = saveAdminStudentRegistration;
window.deleteAdminStudent = deleteAdminStudent;

