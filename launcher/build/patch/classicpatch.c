/*
 * classicpatch.dylib - custom-server patches for the macOS Classic client (1.14.0.40618 and 1.14.2.42597; universal
 * arm64 + x86_64). The client's executable loads it itself (one extra LC_LOAD_DYLIB, added by patch_binary.sh),
 * so it works however the game is started (Finder, open, nohup, a launcher script, "Open using Rosetta").
 * Build: build_classicpatch.sh. arctium_data.h holds the Arctium data (RSA moduli, certificate bundle).
 *
 *   1. The constructor runs before any client code and patches the plaintext data in __TEXT (__const/__cstring):
 *        ConnectTo + GameCrypto RSA modulus, certificate signature modulus, certificate bundle (Arctium data),
 *        ".actual.battle.net" portal suffix, TACT versions URL (Arctium's server, with the client's own build),
 *        telemetry host (-> telemetry.invalid, which never resolves).
 *   2. The client's __TEXT,__text is encrypted on disk and decrypts itself during start-up. A background thread waits
 *      for that, suspends the other threads, FINDS the three code sites by pattern (no fixed addresses, so later
 *      builds may work unchanged) and patches them:
 *        CertBundle  call(0x148505, ...) -> bool test -> early return: the early return is made unconditional
 *        Seed        the function stored next to the 0x576f57 tag in its function table is replaced by a stub
 *                    that copies the first 16 bytes of the signature modulus slot to [arg0]
 *                    (= HermesProxy's SeedHex 179D3DC3235629D07113A9B3867F97A7)
 *        CertCheck   the check before "Could not validate common name." is forced to succeed
 *      Each site must be found exactly once, otherwise it is left alone (and logged).
 *      The patches are re-checked a few seconds later and re-applied if something overwrote them.
 *
 * Log: _classic_era_/Logs/classicpatch.log (the Logs folder next to the .app), or CLASSICPATCH_LOG = log file (appended).
 * CLASSICPATCH_TIMEOUT = seconds to wait for the decryption (default 60).
 * Portions (RSA moduli, certificate bundle, byte patterns) derived from the Arctium Launcher,
 * Copyright (c) 2021-2023 Arctium, MIT license: see LICENSE-Arctium.txt in this folder.
 */
#include <CoreFoundation/CoreFoundation.h>
#include <libkern/OSCacheControl.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach/mach.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "arctium_data.h"

#if defined(__arm64__)
#define ARCH_NAME "arm64"
#elif defined(__x86_64__)
#define ARCH_NAME "x86_64"
#else
#error "unsupported architecture"
#endif

static const uint8_t P_CONNECTTOMODULUS[8] = { 0x91, 0xD5, 0x9B, 0xB7, 0xD4, 0xE1, 0x83, 0xA5 };
static const uint8_t P_SIGNATUREMODULUS[8] = { 0x35, 0xFF, 0x17, 0xE7, 0x33, 0xC4, 0xD3, 0xD4 };
static const uint8_t P_CRYPTORSAMODULUS[8] = { 0x71, 0xFD, 0xFA, 0x60, 0x14, 0x0D, 0xF2, 0x05 };
static const char S_CERTBUNDLE[] = "{\"Created\":";
static const char S_PORTAL[] = ".actual.battle.net";
static const char S_TELEMETRY[] = "telemetry-in.battle.net";                       /* + its NUL: the host, or the end of its https URL */
/* Same length: .invalid is reserved and never resolves, so telemetry goes nowhere */
static const char S_TELEMETRY_OFF[sizeof S_TELEMETRY] = "telemetry.invalid";                               /* + its NUL */
static const char S_VERSIONS[] = "http://%s.patch.battle.net:1119/%s/versions";
/* Arctium's versions server answers for one build: the client's own goes in (5 digits keep the length) */
#define VERSIONS_NEW_FMT "http://ngdp.arctium.io/%%s/%%s/%s/versions"
_Static_assert(sizeof "http://ngdp.arctium.io/%s/%s/00000/versions" == sizeof S_VERSIONS, "versions URL must keep its length");
static const char S_COMMONNAME[] = "Could not validate common name. ";

static intptr_t g_slide;
static uint8_t *g_text;                        /* live __text (slid) */
static uint64_t g_textAddr;                    /* unslid */
static size_t g_textSize;
static uint8_t *g_textCopy;                    /* private copy that the site search runs on */
static uint8_t *g_dataLo, *g_dataHi;           /* __TEXT after __text: __stubs ... __eh_frame */
static uint64_t g_sigSlot;                     /* unslid address of the signature modulus */
static FILE *g_log;
static double g_t0, g_timeout = 60.0;

#define NSAMPLE 256
static size_t g_sampleOff[NSAMPLE];
static uint8_t (*g_sampleSnap)[4096];

static double now(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + ts.tv_nsec / 1e9;
}

static void say(const char *fmt, ...) {
    char line[1024];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(line, sizeof line, fmt, ap);
    va_end(ap);
    fprintf(stderr, "[classicpatch %6.3fs] %s\n", now() - g_t0, line);
    if (g_log) { fprintf(g_log, "[%6.3fs] %s\n", now() - g_t0, line); fflush(g_log); }
}

/* Reads client memory without faulting: while decrypting, the client unmaps __TEXT and maps new pages, so a plain
 * load from the watcher thread can hit an unmapped range (SIGSEGV). Returns 0 when the range is not readable. */
static int safe_read(const void *addr, void *buf, size_t n) {
    vm_size_t got = 0;
    return vm_read_overwrite(mach_task_self(), (vm_address_t)addr, n, (vm_address_t)buf, &got) == KERN_SUCCESS && got == n;
}

/* Writes n bytes at addr inside the client's read-only/executable __TEXT, then restores r-x. */
static int write_text(uint8_t *addr, const void *src, size_t n) {
    vm_address_t page = (vm_address_t)addr & ~(vm_address_t)(vm_page_size - 1);
    vm_size_t len = (((vm_address_t)addr + n + vm_page_size - 1) & ~(vm_address_t)(vm_page_size - 1)) - page;
    kern_return_t kr = vm_protect(mach_task_self(), page, len, FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (kr != KERN_SUCCESS) return 0;
    memcpy(addr, src, n);
    vm_protect(mach_task_self(), page, len, FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
    sys_icache_invalidate(addr, n);
    return memcmp(addr, src, n) == 0;
}

static uint8_t *find_data(const void *pat, size_t len, size_t *count) {
    uint8_t *first = NULL;
    *count = 0;
    for (uint8_t *p = g_dataLo; p + len <= g_dataHi; p++) {
        p = memchr(p, *(const uint8_t *)pat, (size_t)(g_dataHi - p));
        if (!p || p + len > g_dataHi) break;
        if (memcmp(p, pat, len) == 0) { if (!first) first = p; (*count)++; }
    }
    return first;
}

static int data_patch(const char *name, const void *pat, size_t plen, const void *data, size_t dlen, uint8_t **where) {
    size_t cnt;
    uint8_t *p = find_data(pat, plen, &cnt);
    if (!p) { say("[%s] pattern not found", name); return 0; }
    if (p + dlen > g_dataHi) { say("[%s] patch does not fit", name); return 0; }
    int ok = write_text(p, data, dlen);
    say("[%s] 0x%llx (%zu match%s), %zu bytes: %s", name, (unsigned long long)((uintptr_t)p - g_slide), cnt,
        cnt == 1 ? "" : "es", dlen, ok ? "patched" : "WRITE FAILED");
    if (where) *where = p;
    return ok;
}

/* ================================================================== code sites */
typedef struct {
    const char *name;
    size_t off;                    /* offset in __text */
    uint8_t oldb[24], newb[24];
    size_t len;
    int found;                     /* number of distinct matches in the last search; patched only when exactly 1 */
    int done;                      /* patched: not searched again */
    double at;                     /* when it was patched (s since start) */
} Site;

enum { SITE_CERTBUNDLE, SITE_SEED, SITE_CERTCHECK, NSITE };
static Site g_site[NSITE] = { { .name = "CertBundle" }, { .name = "Seed" }, { .name = "CertCheck" } };

static void site_hit(Site *s, size_t off, const void *newb, size_t len) {
    if (s->done || (s->found && s->off == off)) return;   /* already patched / same site reached twice */
    if (s->found++ == 0) {
        s->off = off;
        s->len = len;
        memcpy(s->oldb, g_textCopy + off, len);
        memcpy(s->newb, newb, len);
    }
}

/* unslid address of the string str (with its NUL) in the data part of __TEXT, 0 if missing or not unique */
static uint64_t data_string(const char *str) {
    size_t cnt;
    uint8_t *p = find_data(str, strlen(str) + 1, &cnt);
    return p && cnt == 1 ? (uint64_t)((uintptr_t)p - g_slide) : 0;
}

#if defined(__arm64__)
/* ------------------------------------------------------------------ arm64 */
static uint32_t W(size_t i) { uint32_t w; memcpy(&w, g_textCopy + i * 4, 4); return w; }
static uint64_t PC(size_t i) { return g_textAddr + i * 4; }
static int64_t sx(uint64_t v, int bits) { return (int64_t)(v << (64 - bits)) >> (64 - bits); }

static int is_bl(uint32_t w) { return (w & 0xFC000000u) == 0x94000000u || (w & 0xFFFFFC1Fu) == 0xD63F0000u; }
static int is_ret(uint32_t w) { return w == 0xD65F03C0u; }
/* b.cond / cbz / cbnz / tbz / tbnz: 1 and the target */
static int cond_target(uint32_t w, uint64_t pc, uint64_t *t) {
    if ((w & 0xFF000010u) == 0x54000000u || (w & 0x7E000000u) == 0x34000000u) { *t = pc + (uint64_t)(sx((w >> 5) & 0x7FFFF, 19) * 4); return 1; }
    if ((w & 0x7E000000u) == 0x36000000u) { *t = pc + (uint64_t)(sx((w >> 5) & 0x3FFF, 14) * 4); return 1; }
    return 0;
}
static int is_flow(uint32_t w) { uint64_t t; return cond_target(w, 0, &t) || (w & 0x7C000000u) == 0x14000000u || (w & 0xFE000000u) == 0xD6000000u; }
static int movz_w(uint32_t w, uint32_t imm) { return (w & 0xFFE00000u) == 0x52800000u && ((w >> 5) & 0xFFFFu) == imm ? (int)(w & 31) : -1; }
static int movk_w16(uint32_t w, uint32_t imm) { return (w & 0xFFE00000u) == 0x72A00000u && ((w >> 5) & 0xFFFFu) == imm ? (int)(w & 31) : -1; }
/* adr xd / adrp xd + add xd,xd,#lo (within 3 words): 1, the register and the address */
static int addr_of(size_t i, size_t n, int *rd, uint64_t *a) {
    uint32_t w = W(i);
    if ((w & 0x1F000000u) != 0x10000000u) return 0;
    int64_t imm = sx(((w >> 29) & 3) | (((w >> 5) & 0x7FFFF) << 2), 21);
    *rd = (int)(w & 31);
    if (!(w & 0x80000000u)) { *a = PC(i) + (uint64_t)imm; return 1; }   /* adr */
    uint64_t page = (PC(i) & ~0xFFFULL) + (uint64_t)(imm << 12);
    for (size_t k = i + 1; k <= i + 3 && k < n; k++) {
        uint32_t x = W(k);
        if ((x & 0xFFC00000u) == 0x91000000u && (int)((x >> 5) & 31) == *rd) { *a = page + ((x >> 10) & 0xFFF); *rd = (int)(x & 31); return 1; }
    }
    return 0;
}
static uint32_t enc_adrp(uint64_t pc, uint64_t target, uint32_t rd) {
    int64_t imm = (int64_t)((target & ~0xFFFULL) - (pc & ~0xFFFULL)) >> 12;
    return 0x90000000u | (((uint32_t)imm & 3u) << 29) | ((((uint32_t)(imm >> 2)) & 0x7FFFFu) << 5) | rd;
}

/* movz/movk wD,#0x148505 -> call -> cbz/tbz w0 (early return taken when false): make that branch unconditional */
static void find_certbundle(size_t n) {
    for (size_t i = 12; i + 40 < n; i++) {
        int rd = movz_w(W(i), 0x8505);
        if (rd < 0) continue;
        size_t kpos = SIZE_MAX;
        for (size_t k = i - 12; k <= i + 12; k++) if (k != i && movk_w16(W(k), 0x14) == rd) { kpos = k; break; }
        if (kpos == SIZE_MAX) continue;
        size_t from = (kpos > i ? kpos : i) + 1, call = SIZE_MAX;
        for (size_t k = from; k < from + 20 && k < n; k++) { if (is_bl(W(k))) { call = k; break; } if (is_ret(W(k))) break; }
        if (call == SIZE_MAX) continue;
        for (size_t j = call + 1; j <= call + 8 && j < n; j++) {
            uint32_t x = W(j);
            int falseBranch = (x & 0xFF00001Fu) == 0x34000000u || (x & 0xFFF8001Fu) == 0x36000000u;   /* cbz w0 / tbz w0,#0 */
            if (falseBranch) {
                uint64_t t; cond_target(x, PC(j), &t);
                uint32_t b = 0x14000000u | ((uint32_t)((int64_t)(t - PC(j)) / 4) & 0x03FFFFFFu);
                site_hit(&g_site[SITE_CERTBUNDLE], j * 4, &b, 4);
                break;
            }
            if (is_flow(x)) break;
        }
    }
}

/* movz/movk wN,#0x576f57 ; str wN,[xB,#o] ; adr xF,<fn> ; str xF,[xB,#o+0x10]  ->  <fn> */
static void find_seed(size_t n, uint64_t sig) {
    for (size_t i = 0; i + 12 < n; i++) {
        int rn = movz_w(W(i), 0x6f57);
        if (rn < 0 || movk_w16(W(i + 1), 0x57) != rn) continue;
        int base = -1, fr = -1; int64_t off = -1; uint64_t fn = 0;
        for (size_t k = i + 2; k <= i + 10 && k < n; k++) {
            uint32_t x = W(k); int r; uint64_t a;
            if ((x & 0xFFC00000u) == 0xB9000000u && (int)(x & 31) == rn) { base = (int)((x >> 5) & 31); off = (int64_t)((x >> 10) & 0xFFF) * 4; continue; }
            if (addr_of(k, n, &r, &a)) { fr = r; fn = a; continue; }
            if ((x & 0xFFC00000u) == 0xF9000000u && (int)(x & 31) == fr && (int)((x >> 5) & 31) == base && (int64_t)((x >> 10) & 0xFFF) * 8 == off + 0x10) {
                if (fn < g_textAddr || fn >= g_textAddr + g_textSize) break;
                size_t fi = (size_t)(fn - g_textAddr) / 4;
                uint32_t stub[5] = { enc_adrp(fn, sig, 1), 0x91000021u | ((uint32_t)(sig & 0xFFF) << 10), 0x3dc00020u, 0x3d800000u, 0xd65f03c0u };
                site_hit(&g_site[SITE_SEED], fi * 4, stub, sizeof stub);
                break;
            }
        }
    }
}

/* the check before the code that references "Could not validate common name.":
 * bl <check> ; mov xS,x0 ; tbnz w0,#0,<ok, past the message>   ->   mov xS,x0 becomes mov x0,#1 */
static void find_certcheck(size_t n) {
    uint64_t s = data_string(S_COMMONNAME);
    if (!s) return;
    for (size_t i = 0; i + 4 < n; i++) {
        int rd; uint64_t a;
        if ((W(i) & 0x9F000000u) != 0x90000000u || !addr_of(i, n, &rd, &a) || a != s) continue;
        for (size_t j = i; j-- > 0 && j + 64 > i;) {
            uint32_t m = W(j + 1), t = W(j + 2); uint64_t ok;
            if (!is_bl(W(j)) || (m & 0xFFFFFFE0u) != 0xAA0003E0u || (t & 0xFFF8001Fu) != 0x37000000u) continue;
            cond_target(t, PC(j + 2), &ok);
            if (ok > PC(i)) { uint32_t p = 0xD2800020u; site_hit(&g_site[SITE_CERTCHECK], (j + 1) * 4, &p, 4); }
            break;
        }
    }
}

static void find_sites(void) {
    size_t n = g_textSize / 4;
    find_certbundle(n);
    find_seed(n, g_sigSlot);
    find_certcheck(n);
}

#else
/* ------------------------------------------------------------------ x86_64 */
static const uint8_t *B(size_t i) { return g_textCopy + i; }
static int32_t rel32(size_t i) { int32_t v; memcpy(&v, g_textCopy + i, 4); return v; }
static uint64_t PCx(size_t i) { return g_textAddr + i; }

/* mov r32,0x148505 ... call ; test al,al ; je <early return>  ->  jmp */
static void find_certbundle(size_t n) {
    for (size_t i = 0; i + 64 < n; i++) {
        const uint8_t *b = B(i);
        if (b[0] < 0xB8 || b[0] > 0xBF || b[1] != 0x05 || b[2] != 0x85 || b[3] != 0x14 || b[4] != 0x00) continue;
        for (size_t j = i + 5; j < i + 40; j++) {
            if (*B(j) != 0xE8 || B(j + 5)[0] != 0x84 || B(j + 5)[1] != 0xC0) continue;
            size_t k = j + 7;
            if (B(k)[0] == 0x0F && B(k)[1] == 0x84) {                                  /* je rel32 -> jmp rel32 ; nop */
                int32_t r = rel32(k + 2) + 1;
                uint8_t p[6] = { 0xE9, 0, 0, 0, 0, 0x90 };
                memcpy(p + 1, &r, 4);
                site_hit(&g_site[SITE_CERTBUNDLE], k, p, 6);
            } else if (B(k)[0] == 0x74) {                                              /* je rel8 -> jmp rel8 */
                uint8_t p[2] = { 0xEB, B(k)[1] };
                site_hit(&g_site[SITE_CERTBUNDLE], k, p, 2);
            }
            break;
        }
    }
}

/* mov dword [rip+A],0x576f57 ; lea rX,[rip+<fn>] ; mov [rip+A+0x10],rX  ->  <fn> */
static void find_seed(size_t n, uint64_t sig) {
    for (size_t i = 0; i + 40 < n; i++) {
        const uint8_t *b = B(i);
        if (b[0] != 0xC7 || b[1] != 0x05 || b[6] != 0x57 || b[7] != 0x6F || b[8] != 0x57 || b[9] != 0x00) continue;
        uint64_t tag = PCx(i + 10) + (uint64_t)(int64_t)rel32(i + 2), fn = 0;
        int reg = -1;
        for (size_t j = i + 10; j < i + 34; j++) {
            const uint8_t *c = B(j);
            if ((c[0] & 0xFB) != 0x48 || (c[2] & 0xC7) != 0x05) continue;
            int r = ((c[2] >> 3) & 7) | ((c[0] & 4) << 1);
            if (c[1] == 0x8D) { reg = r; fn = PCx(j + 7) + (uint64_t)(int64_t)rel32(j + 3); }
            else if (c[1] == 0x89 && r == reg && PCx(j + 7) + (uint64_t)(int64_t)rel32(j + 3) == tag + 0x10) {
                if (fn < g_textAddr || fn >= g_textAddr + g_textSize) break;
                /* lea rsi,[rip+sig] ; movups xmm0,[rsi] ; movups [rdi],xmm0 ; mov rax,rdi ; ret */
                uint8_t p[17] = { 0x48, 0x8D, 0x35, 0, 0, 0, 0, 0x0F, 0x10, 0x06, 0x0F, 0x11, 0x07, 0x48, 0x89, 0xF8, 0xC3 };
                int32_t r32 = (int32_t)(int64_t)(sig - (fn + 7));
                memcpy(p + 3, &r32, 4);
                site_hit(&g_site[SITE_SEED], (size_t)(fn - g_textAddr), p, sizeof p);
                break;
            }
        }
    }
}

/* the check before the code that references "Could not validate common name.":
 * call <check> ; [mov r32,eax] ; test al,al ; jne <ok, past the message>   ->   the mov becomes mov al,1
 * (or, without a mov, test al,al becomes or al,1) */
static void find_certcheck(size_t n) {
    uint64_t s = data_string(S_COMMONNAME);
    if (!s) return;
    for (size_t i = 0; i + 7 < n; i++) {
        const uint8_t *c = B(i);
        if ((c[0] & 0xFB) != 0x48 || c[1] != 0x8D || (c[2] & 0xC7) != 0x05 || PCx(i + 7) + (uint64_t)(int64_t)rel32(i + 3) != s) continue;
        for (size_t p = i; p-- > 0 && p + 1024 > i;) {
            if (*B(p) != 0xE8) continue;
            size_t q = p + 5, mv = 0;
            if (B(q)[0] == 0x89 && (B(q)[1] & 0xF8) == 0xC0) mv = 2;
            else if ((B(q)[0] == 0x41 || B(q)[0] == 0x44) && B(q)[1] == 0x89 && (B(q)[2] & 0xF8) == 0xC0) mv = 3;
            const uint8_t *t = B(q + mv);
            if (t[0] != 0x84 || t[1] != 0xC0) continue;
            uint64_t ok;
            if (t[2] == 0x0F && t[3] == 0x85) ok = PCx(q + mv + 8) + (uint64_t)(int64_t)rel32(q + mv + 4);
            else if (t[2] == 0x75) ok = PCx(q + mv + 4) + (uint64_t)(int64_t)(int8_t)t[3];
            else continue;
            if (ok > PCx(i)) {
                if (mv) { uint8_t pt[3] = { 0xB0, 0x01, 0x90 }; site_hit(&g_site[SITE_CERTCHECK], q, pt, mv); }
                else { uint8_t pt[2] = { 0x0C, 0x01 }; site_hit(&g_site[SITE_CERTCHECK], q, pt, 2); }
            }
            break;
        }
    }
}

static void find_sites(void) {
    find_certbundle(g_textSize);
    find_seed(g_textSize, g_sigSlot);
    find_certcheck(g_textSize);
}
#endif

/* ================================================================== decryption watch + patching */
static thread_act_array_t g_threads;
static mach_msg_type_number_t g_nThreads;

static void suspend_others(void) {
    thread_t self = mach_thread_self();
    if (task_threads(mach_task_self(), &g_threads, &g_nThreads) != KERN_SUCCESS) { g_nThreads = 0; return; }
    for (mach_msg_type_number_t i = 0; i < g_nThreads; i++) if (g_threads[i] != self) thread_suspend(g_threads[i]);
    mach_port_deallocate(mach_task_self(), self);
}

static void resume_others(void) {
    thread_t self = mach_thread_self();
    for (mach_msg_type_number_t i = 0; i < g_nThreads; i++) {
        if (g_threads[i] != self) thread_resume(g_threads[i]);
        mach_port_deallocate(mach_task_self(), g_threads[i]);
    }
    mach_port_deallocate(mach_task_self(), self);
    if (g_nThreads) vm_deallocate(mach_task_self(), (vm_address_t)g_threads, g_nThreads * sizeof(thread_t));
    g_nThreads = 0;
}

static int bytes_at(const Site *s, const uint8_t *want) {
    uint8_t cur[24];
    return safe_read(g_text + s->off, cur, s->len) && memcmp(cur, want, s->len) == 0;
}

static int decrypted(void) {
    static uint8_t page[4096];
    for (size_t i = 0; i < NSAMPLE; i++)
        if (!safe_read(g_text + g_sampleOff[i], page, sizeof page) || memcmp(page, g_sampleSnap[i], 4096) == 0) return 0;
    return 1;
}

/* Patches the sites found exactly once and re-applies done ones that were overwritten; returns how many are in place.
 * result[i]: 1 written now, 2 already in place, -1 holds something unexpected, -2 write failed, 0 not found yet.
 * Call with the other threads suspended. */
static int apply_sites(int *result) {
    int ok = 0;
    for (int i = 0; i < NSITE; i++) {
        Site *s = &g_site[i];
        result[i] = 0;
        if (!s->done && s->found != 1) continue;
        if (bytes_at(s, s->newb)) { result[i] = 2; s->done = 1; ok++; continue; }
        if (!bytes_at(s, s->oldb)) { result[i] = -1; continue; }
        result[i] = write_text(g_text + s->off, s->newb, s->len) ? 1 : -2;
        if (result[i] == 1) { s->done = 1; s->at = now() - g_t0; ok++; }
    }
    return ok;
}

static void log_sites(const int *result, int reapply) {
    for (int i = 0; i < NSITE; i++) {
        const Site *s = &g_site[i];
        unsigned long long a = (unsigned long long)(g_textAddr + s->off);
        if (reapply) {
            if (result[i] == 1) say("[%s] 0x%llx: RE-patched", s->name, a);
            else if (result[i] < 0) say("[%s] 0x%llx: could not be re-patched (%d)", s->name, a, result[i]);
        } else if (s->done) say("[%s] 0x%llx: patched at %.3f s (%zu bytes)", s->name, a, s->at, s->len);
        else if (s->found > 1) say("[%s] found %d times - ambiguous, NOT patched", s->name, s->found);
        else if (result[i] == -1) say("[%s] 0x%llx: holds unexpected bytes - NOT patched", s->name, a);
        else if (result[i] == -2) say("[%s] 0x%llx: WRITE FAILED", s->name, a);
        else say("[%s] not found - NOT patched", s->name);
    }
}

static void *watch(void *arg) {
    (void)arg;
    for (;;) {
        if (decrypted()) break;
        if (now() - g_t0 > g_timeout) { say("the client code was not decrypted within %.0f s - code patches NOT applied", g_timeout); return NULL; }
        usleep(1000);
    }
    /* The pages change in more than one pass, so search again (every 20 ms, up to 10 s) until every site is found;
     * a site can only match once its code is fully decrypted, and it is patched as soon as it is found.
     * Search and patch run with the client paused (no allocations in there). */
    double tDec = now() - g_t0, paused = 0;
    int result[NSITE], ok = 0, searches = 0;
    for (;;) {
        for (int i = 0; i < NSITE; i++) if (!g_site[i].done) g_site[i].found = 0;
        suspend_others();
        double t1 = now();
        int copied = safe_read(g_text, g_textCopy, g_textSize);
        if (copied) find_sites();
        ok = copied ? apply_sites(result) : 0;
        paused += now() - t1;
        resume_others();
        searches++;
        if (ok == NSITE || now() - g_t0 - tDec > 10.0) break;
        usleep(20000);
    }
    say("client code changed at %.3f s; %d search(es), client paused %.0f ms in total", tDec, searches, paused * 1000.0);
    log_sites(result, 0);
    say("%d of %d code patches in place", ok, NSITE);
    free(g_textCopy);
    g_textCopy = NULL;

    static const unsigned checks[] = { 500, 2000, 5000, 15000 };
    for (size_t k = 0; k < sizeof checks / sizeof checks[0]; k++) {
        usleep(checks[k] * 1000);
        int bad = 0;
        for (int i = 0; i < NSITE; i++) if (g_site[i].done && !bytes_at(&g_site[i], g_site[i].newb)) bad++;
        if (bad) {
            say("%d code patch(es) were overwritten after %.1f s - re-applying", bad, now() - g_t0);
            suspend_others();
            apply_sites(result);
            resume_others();
            log_sites(result, 1);
        }
    }
    say("code patches verified");
    return NULL;
}

static char g_clientVersion[64] = "?";          /* CFBundleVersion, e.g. 1.14.1.42032 */

static void log_version(void) {
    CFBundleRef b = CFBundleGetMainBundle();
    CFTypeRef v = b ? CFBundleGetValueForInfoDictionaryKey(b, CFSTR("CFBundleVersion")) : NULL;
    if (v && CFGetTypeID(v) == CFStringGetTypeID())
        CFStringGetCString((CFStringRef)v, g_clientVersion, sizeof g_clientVersion, kCFStringEncodingUTF8);
    say("classicpatch (%s) in client %s, image slide 0x%lx", ARCH_NAME, g_clientVersion, (long)g_slide);
}

/* The versions URL with the client's build, or 0 if its build is not 5 digits */
static int versions_url(char *out, size_t n) {
    const char *dot = strrchr(g_clientVersion, '.');
    if (!dot || strlen(dot + 1) != 5 || strspn(dot + 1, "0123456789") != 5) return 0;
    return snprintf(out, n, VERSIONS_NEW_FMT, dot + 1) == (int)n - 1;
}

/* default log: <folder that holds the .app>/Logs/classicpatch.log, i.e. _classic_era_/Logs/classicpatch.log */
static void open_default_log(const char *exePath) {
    char p[1024];
    snprintf(p, sizeof p, "%s", exePath);
    for (int up = 0; up < 4; up++) { char *s = strrchr(p, '/'); if (!s) return; *s = 0; }   /* drop exe, MacOS, Contents, X.app */
    strncat(p, "/Logs", sizeof p - strlen(p) - 1);
    if (access(p, W_OK) != 0) return;
    strncat(p, "/classicpatch.log", sizeof p - strlen(p) - 1);
    g_log = fopen(p, "w");
}

#ifndef CLASSICPATCH_TEST   /* an offline site-finder test can include this file without the constructor */
__attribute__((constructor))
#endif
static void classicpatch_init(void) {
    g_t0 = now();
    const char *e;
    if ((e = getenv("CLASSICPATCH_TIMEOUT"))) g_timeout = atof(e);
    unsetenv("DYLD_INSERT_LIBRARIES");   /* if it was used: nothing the client starts should load us */

    const struct mach_header_64 *mh = NULL;
    const char *exePath = NULL;
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const struct mach_header *h = _dyld_get_image_header(i);
        if (h && h->filetype == MH_EXECUTE) {
            mh = (const struct mach_header_64 *)h;
            g_slide = _dyld_get_image_vmaddr_slide(i);
            exePath = _dyld_get_image_name(i);
            break;
        }
    }
    if ((e = getenv("CLASSICPATCH_LOG")) && *e) g_log = fopen(e, "a");
    else if (exePath) open_default_log(exePath);
    if (!mh) { say("main executable not found - nothing patched"); return; }
    log_version();

    const struct section_64 *text = NULL;
    uint64_t segEnd = 0;
    const struct load_command *lc = (const struct load_command *)(mh + 1);
    for (uint32_t i = 0; i < mh->ncmds; i++, lc = (const struct load_command *)((const uint8_t *)lc + lc->cmdsize)) {
        if (lc->cmd != LC_SEGMENT_64) continue;
        const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
        if (strncmp(seg->segname, "__TEXT", 16) != 0) continue;
        segEnd = seg->vmaddr + seg->vmsize;
        const struct section_64 *sec = (const struct section_64 *)(seg + 1);
        for (uint32_t k = 0; k < seg->nsects; k++) if (!strncmp(sec[k].sectname, "__text", 16)) text = &sec[k];
    }
    if (!text) { say("__TEXT,__text not found - nothing patched"); return; }
    g_textAddr = text->addr;
    g_textSize = (size_t)text->size;
    g_text = (uint8_t *)(uintptr_t)(text->addr + g_slide);
    g_dataLo = (uint8_t *)(uintptr_t)(text->addr + text->size + g_slide);
    g_dataHi = (uint8_t *)(uintptr_t)(segEnd + g_slide);

    /* 1. data patches, before any client code runs */
    uint8_t *sig = NULL;
    int ok = 1;
    ok &= data_patch("ConnectTo RsaModulus", P_CONNECTTOMODULUS, 8, ARC_RSA_MODULUS, 256, NULL);
    ok &= data_patch("GameCrypto RsaModulus", P_CRYPTORSAMODULUS, 8, ARC_RSA_MODULUS, 256, NULL);
    ok &= data_patch("Certificate Signature RsaModulus", P_SIGNATUREMODULUS, 8, ARC_SIGNATURE_MODULUS, 256, &sig);
    ok &= data_patch("Certificate Bundle", S_CERTBUNDLE, sizeof S_CERTBUNDLE - 1, ARC_CERT_BUNDLE, sizeof ARC_CERT_BUNDLE, NULL);
    static const uint8_t zeros[sizeof S_PORTAL - 1] = { 0 };
    ok &= data_patch("Login Portal", S_PORTAL, sizeof S_PORTAL, zeros, sizeof zeros, NULL);
    char versions[sizeof S_VERSIONS];
    if (!versions_url(versions, sizeof versions))
        say("[Versions URL] no 5-digit build in %s - optional, continuing", g_clientVersion);
    else if (!data_patch("Versions URL", S_VERSIONS, sizeof S_VERSIONS, versions, sizeof versions, NULL))
        say("[Versions URL] optional - continuing");
    if (!data_patch("Telemetry", S_TELEMETRY, sizeof S_TELEMETRY, S_TELEMETRY_OFF, sizeof S_TELEMETRY_OFF, NULL))
        say("[Telemetry] optional - continuing");
    if (!ok || !sig) { say("a data patch failed - code patches skipped, the client will not connect to a custom server"); return; }
    g_sigSlot = (uint64_t)((uintptr_t)sig - g_slide);

    /* 2. snapshot sample pages of __text and wait for the decryption in the background */
    size_t npages = g_textSize / 4096;
    g_sampleSnap = malloc(NSAMPLE * 4096);
    g_textCopy = malloc(g_textSize);                 /* allocated now: nothing may allocate while the client is paused */
    if (!g_sampleSnap || !g_textCopy || npages < NSAMPLE) { say("out of memory / __text too small"); return; }
    for (size_t i = 0; i < NSAMPLE; i++) {
        g_sampleOff[i] = (i * npages / NSAMPLE) * 4096;
        if (!safe_read(g_text + g_sampleOff[i], g_sampleSnap[i], 4096)) { say("__text is not readable - code patches skipped"); return; }
    }
    pthread_t th;
    pthread_create(&th, NULL, watch, NULL);
    pthread_detach(th);
}
