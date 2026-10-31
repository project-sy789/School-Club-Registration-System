#!/usr/bin/env node

// Load test for the same public registration RPC used by app.js.
// Run this only against a disposable Supabase project or a dedicated test club.

import crypto from "node:crypto";

function readOption(name, fallback) {
    const index = process.argv.indexOf(`--${name}`);
    return index >= 0 && process.argv[index + 1] ? process.argv[index + 1] : fallback;
}

const supabaseUrl = String(process.env.SUPABASE_URL || "").replace(/\/$/, "");
const anonKey = String(process.env.SUPABASE_ANON_KEY || "");
const clubId = String(process.env.CLUB_ID || readOption("club-id", ""));
const userCount = Number(process.env.LOAD_TEST_USERS || readOption("users", 500));
const concurrency = Number(process.env.LOAD_TEST_CONCURRENCY || readOption("concurrency", userCount));
const requestTimeoutMs = Number(process.env.LOAD_TEST_TIMEOUT_MS || readOption("timeout-ms", 30000));

if (!supabaseUrl || !/^https:\/\//i.test(supabaseUrl)) {
    throw new Error("SUPABASE_URL must be the HTTPS Project URL");
}
if (!anonKey || /service_role|^sb_secret_/i.test(anonKey)) {
    throw new Error("SUPABASE_ANON_KEY must be the public anon/publishable key, not a service_role or secret key");
}
if (!clubId) throw new Error("CLUB_ID is required");
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

async function loadClub() {
    const filter = encodeURIComponent(`eq.${clubId}`);
    const result = await requestJson(`/rest/v1/clubs?id=${filter}&select=id,name,capacity,enrolled_count,grades`);
    if (!result.ok || !Array.isArray(result.body) || !result.body[0]) {
        throw new Error(`Could not load CLUB_ID (${result.status}): ${JSON.stringify(result.body)}`);
    }
    return result.body[0];
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
            latencyMs: result.latencyMs || performance.now() - started
        };
    } catch (error) {
        return {
            success: false,
            code: error.name === "AbortError" ? "TIMEOUT" : "NETWORK_ERROR",
            error: error.message,
            latencyMs: performance.now() - started
        };
    }
}

async function runWorkers(club, runId) {
    const results = new Array(userCount);
    let nextIndex = 0;
    async function worker() {
        while (true) {
            const index = nextIndex++;
            if (index >= userCount) return;
            results[index] = await runOne(club, index, runId);
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

const before = await loadClub();
const runId = `${Date.now().toString(36)}-`;
console.log(`Target: ${before.name} (${before.id})`);
console.log(`Capacity before: ${before.enrolled_count}/${before.capacity}`);
console.log(`Requests: ${userCount}, client concurrency: ${concurrency}, timeout: ${requestTimeoutMs}ms`);
console.log("Warning: this creates real registration rows. Use a disposable test project or test club.");

const started = performance.now();
const results = await runWorkers(before, runId);
const elapsedMs = performance.now() - started;
const latencies = results.map(result => result.latencyMs);
const counts = results.reduce((map, result) => map.set(result.code, (map.get(result.code) || 0) + 1), new Map());
const successCount = results.filter(result => result.success).length;
const expectedMax = Math.max(0, Math.min(userCount, Number(before.capacity) - Number(before.enrolled_count)));
const after = await loadClub();
const unexpected = results.filter(result => !result.success && !["CLUB_FULL", "ALREADY_REGISTERED"].includes(result.code));

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
    capacityAfter: `${after.enrolled_count}/${after.capacity}`,
    responseCodes: Object.fromEntries(counts)
}, null, 2));

if (successCount > expectedMax || Number(after.enrolled_count) > Number(after.capacity)) {
    console.error("FAIL: registration count exceeded the available quota.");
    process.exitCode = 1;
} else if (unexpected.length > 0) {
    console.error("FAIL: unexpected application/network errors occurred.");
    process.exitCode = 1;
} else {
    console.log("PASS: no registration exceeded the club quota.");
}
