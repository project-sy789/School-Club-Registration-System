#!/usr/bin/env node

// Load test for the same public registration RPC used by app.js.
// Run this only against a disposable Supabase project or a dedicated test club.

import crypto from "node:crypto";

function readOption(name, fallback) {
    const index = process.argv.indexOf(`--${name}`);
    return index >= 0 && process.argv[index + 1] ? process.argv[index + 1] : fallback;
}

function hasFlag(name) {
    return process.argv.includes(`--${name}`);
}

const supabaseUrl = String(process.env.SUPABASE_URL || "").replace(/\/$/, "");
const anonKey = String(process.env.SUPABASE_ANON_KEY || "");
const clubId = String(process.env.CLUB_ID || readOption("club-id", ""));
const allClubs = hasFlag("all-clubs");
const allowClosed = hasFlag("allow-closed");
const userCount = Number(process.env.LOAD_TEST_USERS || readOption("users", 500));
const concurrency = Number(process.env.LOAD_TEST_CONCURRENCY || readOption("concurrency", userCount));
const requestTimeoutMs = Number(process.env.LOAD_TEST_TIMEOUT_MS || readOption("timeout-ms", 30000));

if (!supabaseUrl || !/^https:\/\//i.test(supabaseUrl)) {
    throw new Error("SUPABASE_URL must be the HTTPS Project URL");
}
if (!anonKey || /service_role|^sb_secret_/i.test(anonKey)) {
    throw new Error("SUPABASE_ANON_KEY must be the public anon/publishable key, not a service_role or secret key");
}
if (!clubId && !allClubs) throw new Error("CLUB_ID is required, or pass --all-clubs");
if (clubId && allClubs) throw new Error("Use either CLUB_ID/--club-id or --all-clubs, not both");
if (!Number.isInteger(userCount) || userCount < 1 || userCount > 2000) {
    throw new Error("--users must be an integer from 1 to 2000");
}
if (!Number.isInteger(concurrency) || concurrency < 1 || concurrency > userCount) {
    throw new Error("--concurrency must be an integer between 1 and --users");
}
if (!Number.isInteger(requestTimeoutMs) || requestTimeoutMs < 1000) {
    throw new Error("--timeout-ms must be at least 1000");
}

const headers = {
    apikey: anonKey,
    Authorization: `Bearer ${anonKey}`,
    Accept: "application/json"
};

async function requestJson(path, options = {}) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), requestTimeoutMs);
    const started = performance.now();
    try {
        const response = await fetch(`${supabaseUrl}${path}`, {
            ...options,
            headers: { ...headers, ...(options.headers || {}) },
            signal: controller.signal
        });
        const text = await response.text();
        let body = null;
        try {
            body = text ? JSON.parse(text) : null;
        } catch (_) {
            body = text;
        }
        return {
            ok: response.ok,
            status: response.status,
            body,
            latencyMs: performance.now() - started
        };
    } finally {
        clearTimeout(timer);
    }
}

async function loadClubs() {
    const filter = clubId ? `&id=${encodeURIComponent(`eq.${clubId}`)}` : "";
    const result = await requestJson(`/rest/v1/clubs?select=id,name,capacity,enrolled_count,grades&order=name.asc${filter}`);
    if (!result.ok || !Array.isArray(result.body) || !result.body.length) {
        throw new Error(`Could not load target clubs (${result.status}): ${JSON.stringify(result.body)}`);
    }
    return result.body;
}

async function loadPublicSettings() {
    const result = await requestJson("/rest/v1/rpc/get_public_settings", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: "{}"
    });
    if (!result.ok || !result.body || typeof result.body !== "object") {
        throw new Error(`Could not load public settings (${result.status}): ${JSON.stringify(result.body)}`);
    }
    return result.body;
}

function getRegistrationWindow(settings) {
    const period = settings.registration_period || {};
    const start = period.start_time ? Date.parse(period.start_time) : null;
    const end = period.end_time ? Date.parse(period.end_time) : null;
    const now = Date.now();
    return {
        open: period.is_active === true
            && (start === null || now >= start)
            && (end === null || now <= end),
        isActive: period.is_active === true,
        startTime: period.start_time || null,
        endTime: period.end_time || null
    };
}

function makePhone(index) {
    // Ten digits, starts with 09, and is unique within this run.
    const suffix = String((Date.now() + index) % 100000000).padStart(8, "0");
    return `09${suffix}`;
}

function makeRegistrationPayload(club, index, runId) {
    const grade = Array.isArray(club.grades) && club.grades.length ? String(club.grades[0]) : "ม.1";
    return {
        p_club_id: club.id,
        p_student_id: makePhone(index),
        p_prefix: "",
        p_first_name: `LoadTest${runId}${index}`,
        p_last_name: "Student",
        p_level: grade,
        p_ip_address: null,
        p_user_agent: "registration-load-test",
        p_request_key: crypto.randomUUID()
    };
}

async function runOne(club, index, runId) {
    const started = performance.now();
    try {
        const result = await requestJson("/rest/v1/rpc/register_student_atomic", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify(makeRegistrationPayload(club, index, runId))
        });
        const body = result.body && typeof result.body === "object" ? result.body : {};
        const code = body.code || (result.ok ? (body.success ? "SUCCESS" : "APPLICATION_REJECTED") : `HTTP_${result.status}`);
        return {
            success: result.ok && body.success === true,
            code,
            clubId: club.id,
            clubName: club.name,
            latencyMs: result.latencyMs || performance.now() - started
        };
    } catch (error) {
        return {
            success: false,
            code: error.name === "AbortError" ? "TIMEOUT" : "NETWORK_ERROR",
            error: error.message,
            clubId: club.id,
            clubName: club.name,
            latencyMs: performance.now() - started
        };
    }
}

function buildTargets(clubs) {
    if (clubs.length === 1) return Array.from({ length: userCount }, () => clubs[0]);

    const totalCapacity = clubs.reduce((sum, club) => sum + Math.max(1, Number(club.capacity) || 1), 0);
    const allocations = clubs.map((club, index) => {
        const raw = userCount * Math.max(1, Number(club.capacity) || 1) / totalCapacity;
        return { club, index, count: Math.floor(raw), remainder: raw - Math.floor(raw) };
    });
    let assigned = allocations.reduce((sum, item) => sum + item.count, 0);
    allocations
        .sort((left, right) => right.remainder - left.remainder || left.index - right.index)
        .forEach(item => {
            if (assigned < userCount) {
                item.count += 1;
                assigned += 1;
            }
        });
    allocations.sort((left, right) => left.index - right.index);
    return allocations.flatMap(item => Array.from({ length: item.count }, () => item.club));
}

async function runWorkers(targets, runId) {
    const results = new Array(targets.length);
    let nextIndex = 0;
    async function worker() {
        while (true) {
            const index = nextIndex++;
            if (index >= targets.length) return;
            results[index] = await runOne(targets[index], index, runId);
        }
    }
    await Promise.all(Array.from({ length: concurrency }, () => worker()));
    return results;
}

function percentile(values, fraction) {
    if (!values.length) return 0;
    const sorted = [...values].sort((a, b) => a - b);
    const index = Math.min(sorted.length - 1, Math.ceil(sorted.length * fraction) - 1);
    return sorted[index];
}

const settings = await loadPublicSettings();
const windowState = getRegistrationWindow(settings);
const before = await loadClubs();
const targets = buildTargets(before);
const targetCounts = targets.reduce((map, club) => map.set(club.id, (map.get(club.id) || 0) + 1), new Map());
const availableByClub = before.reduce((map, club) => map.set(
    club.id,
    Math.max(0, Number(club.capacity) - Number(club.enrolled_count || 0))
), new Map());
const expectedMax = before.reduce((sum, club) => sum + Math.min(
    targetCounts.get(club.id) || 0,
    availableByClub.get(club.id) || 0
), 0);

if (!windowState.open && !allowClosed) {
    console.log(JSON.stringify({
        status: "SKIPPED_REGISTRATION_CLOSED",
        registrationPeriod: windowState,
        targetClubs: before.length,
        targetRequests: userCount,
        message: "Registration RPC was not called. Pass --allow-closed only for a no-write policy probe."
    }, null, 2));
    process.exit(2);
}

const runId = `${Date.now().toString(36)}-`;
console.log(`Targets: ${before.length} club(s), ${before.reduce((sum, club) => sum + Number(club.capacity), 0)} total capacity`);
before.forEach(club => console.log(`- ${club.name} (${club.id}): ${club.enrolled_count}/${club.capacity}, requests=${targetCounts.get(club.id) || 0}`));
console.log(`Registration window: ${windowState.open ? "OPEN" : "CLOSED"}${windowState.startTime ? `, start=${windowState.startTime}` : ""}${windowState.endTime ? `, end=${windowState.endTime}` : ""}`);
console.log(`Requests: ${userCount}, client concurrency: ${concurrency}, timeout: ${requestTimeoutMs}ms`);
console.log(windowState.open
    ? "Warning: this creates real registration rows. Use a disposable test project or test club."
    : "Closed-period probe: the RPC should reject requests before creating registration rows.");

const started = performance.now();
const results = await runWorkers(targets, runId);
const elapsedMs = performance.now() - started;
const latencies = results.map(result => result.latencyMs);
const counts = results.reduce((map, result) => map.set(result.code, (map.get(result.code) || 0) + 1), new Map());
const successCount = results.filter(result => result.success).length;
const after = await loadClubs();
const unexpected = results.filter(result => !result.success && ![
    "CLUB_FULL",
    "ALREADY_REGISTERED",
    ...(allowClosed ? ["REGISTRATION_CLOSED"] : [])
].includes(result.code));
const overCapacity = after.filter(club => Number(club.enrolled_count) > Number(club.capacity));
const perClub = Object.fromEntries(after.map(club => {
    const clubResults = results.filter(result => result.clubId === club.id);
    return [club.id, {
        name: club.name,
        requests: clubResults.length,
        success: clubResults.filter(result => result.success).length,
        clubFull: clubResults.filter(result => result.code === "CLUB_FULL").length,
        responseCodes: Object.fromEntries(clubResults.reduce((map, result) => map.set(result.code, (map.get(result.code) || 0) + 1), new Map())),
        capacityAfter: `${club.enrolled_count}/${club.capacity}`
    }];
}));

console.log("\nResult:");
console.log(JSON.stringify({
    elapsedMs: Math.round(elapsedMs),
    requestsPerSecond: Number((userCount / (elapsedMs / 1000)).toFixed(2)),
    success: successCount,
    expectedMaxSuccess: expectedMax,
    clubFull: counts.get("CLUB_FULL") || 0,
    timeouts: counts.get("TIMEOUT") || 0,
    networkErrors: counts.get("NETWORK_ERROR") || 0,
    httpErrors: [...counts.entries()].filter(([code]) => code.startsWith("HTTP_")).reduce((sum, [, count]) => sum + count, 0),
    p50Ms: Math.round(percentile(latencies, 0.50)),
    p95Ms: Math.round(percentile(latencies, 0.95)),
    p99Ms: Math.round(percentile(latencies, 0.99)),
    responseCodes: Object.fromEntries(counts),
    overCapacity: overCapacity.map(club => ({ id: club.id, name: club.name, enrolled_count: club.enrolled_count, capacity: club.capacity })),
    perClub
}, null, 2));

if (successCount > expectedMax || overCapacity.length > 0) {
    console.error("FAIL: registration count exceeded the available quota.");
    process.exitCode = 1;
} else if (unexpected.length > 0) {
    console.error("FAIL: unexpected application/network errors occurred.");
    process.exitCode = 1;
} else {
    console.log("PASS: no registration exceeded the club quota.");
}
