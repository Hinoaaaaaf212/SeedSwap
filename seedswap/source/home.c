// SPDX-License-Identifier: GPL-2.0-only
#include "home.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "compat/nsofile.h"
#include "crypto.h"
#include "pkg.h"

#define MAX_ITEMS 96
#define MAX_METAS 2
#define MAX_CODEINFO 8
#define CHUNK (4u << 20)
#define CODEINFO_ENTRY (0x20 + 0x1a4)

static uint16_t rd16(const uint8_t *p) { return (uint16_t)(p[0] | p[1] << 8); }
static uint32_t rd32(const uint8_t *p) { return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24; }
static uint64_t rd64(const uint8_t *p) { return (uint64_t)rd32(p) | (uint64_t)rd32(p + 4) << 32; }
static void wr16(uint8_t *p, uint16_t v) { p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); }
static void wr32(uint8_t *p, uint32_t v) { for (int i = 0; i < 4; i++) p[i] = (uint8_t)(v >> 8 * i); }
static void wr64(uint8_t *p, uint64_t v) { for (int i = 0; i < 8; i++) p[i] = (uint8_t)(v >> 8 * i); }

static void hex(const uint8_t *b, size_t n, char *out) {
    static const char D[] = "0123456789abcdef";
    for (size_t i = 0; i < n; i++) { out[2 * i] = D[b[i] >> 4]; out[2 * i + 1] = D[b[i] & 15]; }
    out[2 * n] = 0;
}

static int nib(char c) {
    return c >= '0' && c <= '9' ? c - '0' : c >= 'a' && c <= 'f' ? c - 'a' + 10 : c >= 'A' && c <= 'F' ? c - 'A' + 10 : -1;
}

static bool unhex(const char *s, uint8_t *out, size_t n) {
    for (size_t i = 0; i < n; i++) {
        int a = nib(s[2 * i]), b = a < 0 ? -1 : nib(s[2 * i + 1]);
        if (b < 0) return false;
        out[i] = (uint8_t)(a << 4 | b);
    }
    return true;
}

static bool ends_with(const char *s, const char *suffix) {
    size_t a = strlen(s), b = strlen(suffix);
    return a >= b && !strcmp(s + a - b, suffix);
}

static int generation(const uint8_t *h) {
    int g = h[0x206] > h[0x220] ? h[0x206] : h[0x220];
    return g > 0 ? g - 1 : 0;
}

typedef struct {
    Pkg *pkg;
    int entry;
    uint8_t id[16];
    uint64_t size;
    bool convert;      // title key into the key area
    bool cartridge;    // the cartridge mark is cleared
    bool program;      // a Program NCA
    uint64_t program_id;
} Item;

typedef struct {
    uint8_t key[16];   // ncm's content meta key: id, version, type, install type 0
    uint32_t version;
    uint8_t *cnmt;     // the packaged content list, as in the dump
    size_t cnmt_size;
    int item;          // the Meta NCA's item
} Meta;

typedef struct {
    uint64_t program;
    uint8_t entry[CODEINFO_ENTRY];
} CodeInfo;

typedef struct {
    VfsFile *f[2];
    Pkg *pkg[2];
    Meta metas[MAX_METAS];
    int meta_count;
    Item items[MAX_ITEMS];
    int item_count;
    uint64_t programs[MAX_CODEINFO];   // programs that get a code info file
    int program_count;
    CodeInfo infos[MAX_CODEINFO];
    int info_count;
    HomeInstall info;
} Job;

static int vfs_cb(void *user, uint64_t off, void *buf, size_t n) {
    size_t got = 0;
    return vfs_read((VfsFile *)user, (int64_t)off, buf, n, &got) == 0 && got == n ? 0 : -1;
}

static const char *base_name(const char *path) {
    const char *s = strrchr(path, '/');
    return s ? s + 1 : path;
}

static void job_close(Job *j) {
    for (int i = 0; i < j->meta_count; i++) free(j->metas[i].cnmt);
    if (j->pkg[1] && j->pkg[1] != j->pkg[0]) pkg_close(j->pkg[1]);
    pkg_close(j->pkg[0]);
    for (int i = 0; i < 2; i++)
        if (j->f[i]) vfs_close(j->f[i]);
    memset(j, 0, sizeof(*j));
}

// The packaged content list (.cnmt) inside a Meta NCA, malloc'd.
static uint8_t *cnmt_read(Pkg *p, int entry, size_t *size) {
    Nca n;
    char err[240];
    if (!nca_open(p, entry, &n, err, sizeof(err))) return NULL;
    NcaSection s;
    uint8_t *pfs = NULL, *out = NULL;
    uint64_t pfs_off = 0, pfs_size = 0;
    if (nca_section(&n, 1, 0, &s)) {
        pfs_off = rd64(s.fs + 0x40);
        pfs_size = rd64(s.fs + 0x48);
    }
    if (pfs_size >= 0x10 && pfs_size <= 1024 * 1024 && (pfs = malloc((size_t)pfs_size)) &&
        nca_section_read(&n, &s, pfs_off, pfs, (size_t)pfs_size) && !memcmp(pfs, "PFS0", 4)) {
        Pfs0Entry inner[8];
        int count = pfs0_list(pfs, (size_t)pfs_size, inner, 8);
        for (int k = 0; k < count && !out; k++)
            if (ends_with(inner[k].name, ".cnmt") && inner[k].size >= 0x20 && inner[k].offset + inner[k].size <= pfs_size &&
                (out = malloc((size_t)inner[k].size))) {
                memcpy(out, pfs + inner[k].offset, (size_t)inner[k].size);
                *size = (size_t)inner[k].size;
            }
    }
    free(pfs);
    nca_close(&n);
    return out;
}

static int add_item(Job *j, Pkg *p, int entry, const uint8_t id[16], char *err, size_t errn) {
    for (int i = 0; i < j->item_count; i++)
        if (!memcmp(j->items[i].id, id, 16)) return i;
    if (j->item_count >= MAX_ITEMS) {
        snprintf(err, errn, "The game has more than %d files; that is more than SeedSwap handles.", MAX_ITEMS);
        return -1;
    }
    Nca n;
    char e2[240];
    if (!nca_open(p, entry, &n, e2, sizeof(e2))) {
        snprintf(err, errn, "%s", e2);
        return -1;
    }
    Item *it = &j->items[j->item_count];
    memset(it, 0, sizeof(*it));
    it->pkg = p;
    it->entry = entry;
    memcpy(it->id, id, 16);
    it->size = n.size;
    static const uint8_t zero[16];
    it->convert = memcmp(n.header + 0x230, zero, 16) != 0;
    it->cartridge = n.header[0x204] == 1;
    it->program = n.header[0x205] == NCA_PROGRAM;
    it->program_id = rd64(n.header + 0x210);
    nca_close(&n);
    return j->item_count++;
}

// A content list of the dump (by title and type) with its NCAs added to the job.
static bool add_meta(Job *j, Pkg *p, const PkgMeta *want, char *err, size_t errn) {
    for (int e = 0; e < p->count; e++) {
        const PkgEntry *pe = &p->entries[e];
        if (!pe->nca || pe->content_type != NCA_META) continue;
        size_t size = 0;
        uint8_t *c = cnmt_read(p, e, &size);
        if (!c) continue;
        if (rd64(c) != want->title_id || c[0xc] != want->type || rd32(c + 8) != want->version) {
            free(c);
            continue;
        }
        uint8_t id[16];
        if (strlen(pe->name) < 32 || !unhex(pe->name, id, 16)) {
            free(c);
            snprintf(err, errn, "The content list file %s is not named by its ID.", pe->name);
            return false;
        }
        Meta *m = &j->metas[j->meta_count++];
        m->cnmt = c;
        m->cnmt_size = size;
        m->version = want->version;
        memset(m->key, 0, 16);
        wr64(m->key, want->title_id);
        wr32(m->key + 8, want->version);
        m->key[12] = want->type;
        uint16_t ext = rd16(c + 0xe), records = rd16(c + 0x10);
        if (0x20u + ext + 0x38u * records > size) {
            snprintf(err, errn, "The content list in %s is cut short.", pe->name);
            return false;
        }
        if ((m->item = add_item(j, p, e, id, err, errn)) < 0) return false;
        for (unsigned r = 0; r < records; r++) {
            const uint8_t *rec = c + 0x20 + ext + 0x38 * r;
            if (rec[0x36] == 6) continue;   // delta fragments: only for updating an older install
            PkgContent pc = {0};
            memcpy(pc.id, rec + 0x20, 16);
            int entry = pkg_content_entry(p, &pc);
            if (entry < 0) {
                char name[33];
                hex(pc.id, 16, name);
                snprintf(err, errn, "The dump lacks %s.nca, which its content list names; the dump is incomplete.", name);
                return false;
            }
            if (add_item(j, p, entry, pc.id, err, errn) < 0) return false;
        }
        return true;
    }
    snprintf(err, errn, "The content list of %016llx cannot be read from the dump.", (unsigned long long)want->title_id);
    return false;
}

static bool job_open(const char *base_path, const char *update_path, const char *keys_path, Job *j, char *err,
                     size_t errn) {
    memset(j, 0, sizeof(*j));
    char *keys = read_text(VFS_SD, keys_path, 256 * 1024);
    if (!keys) {
        snprintf(err, errn, "prod.keys is missing. Put your console's keys file at SD:/switch/prod.keys.");
        return false;
    }
    const char *paths[2] = {base_path, update_path && update_path[0] && strcmp(update_path, base_path) ? update_path : NULL};
    char e2[300];
    bool ok = true;
    for (int i = 0; ok && i < 2; i++) {
        if (!paths[i]) continue;
        j->f[i] = vfs_open(VFS_SD, paths[i], false);
        if (!j->f[i]) {
            snprintf(err, errn, "%s cannot be opened (%s).", base_name(paths[i]), vfs_last_error());
            ok = false;
        } else if (!(j->pkg[i] = pkg_open(vfs_cb, j->f[i], (uint64_t)vfs_size(j->f[i]), keys, e2, sizeof(e2)))) {
            snprintf(err, errn, "%s: %s", base_name(paths[i]), e2);
            ok = false;
        }
    }
    memset(keys, 0, strlen(keys));
    free(keys);
    if (!ok) {
        job_close(j);
        return false;
    }
    Pkg *base = j->pkg[0], *upd = j->pkg[1] ? j->pkg[1] : base;
    const PkgMeta *app = pkg_meta(base, META_APPLICATION, 0), *patch = NULL;
    if (!app) {
        snprintf(err, errn, "%s holds no base game.", base_name(base_path));
        job_close(j);
        return false;
    }
    for (int k = 0; pkg_meta(upd, META_PATCH, k); k++)
        if (pkg_meta(upd, META_PATCH, k)->other_id == app->title_id) patch = pkg_meta(upd, META_PATCH, k);
    if (j->pkg[1] && !patch) {
        snprintf(err, errn, "%s is not an update for %016llx.", base_name(update_path), (unsigned long long)app->title_id);
        job_close(j);
        return false;
    }
    if (!add_meta(j, base, app, err, errn) || (patch && !add_meta(j, upd, patch, err, errn))) {
        job_close(j);
        return false;
    }
    HomeInstall *in = &j->info;
    in->app_id = app->title_id;
    in->version = patch ? patch->version : app->version;
    PkgControl ctl;
    if (pkg_control(base, patch ? upd : NULL, 0, &ctl)) {
        snprintf(in->name, sizeof(in->name), "%s", ctl.name);
        snprintf(in->display_version, sizeof(in->display_version), "%s", ctl.display_version);
        pkg_control_free(&ctl);
    }
    if (!in->name[0]) snprintf(in->name, sizeof(in->name), "%016llx", (unsigned long long)app->title_id);
    for (int i = 0; i < j->item_count; i++) {
        const Item *it = &j->items[i];
        in->contents++;
        in->bytes += (int64_t)it->size;
        in->converted += it->convert;
        if (!it->program || !(it->convert || it->cartridge)) continue;
        in->code_infos++;
        bool known = false;
        for (int k = 0; k < j->program_count; k++) known |= j->programs[k] == it->program_id;
        if (!known && j->program_count < MAX_CODEINFO) j->programs[j->program_count++] = it->program_id;
    }
    return true;
}

// ---- SeedSwap's list of its installs

static void ini_path(uint64_t app, char *out, size_t n) {
    snprintf(out, n, HOME_DIR "/%016llx.ini", (unsigned long long)app);
}

static void codeinfo_path(uint64_t program, char *out, size_t n) {
    snprintf(out, n, HOME_CODEINFO_DIR "/%016llx.bin", (unsigned long long)program);
}

static bool write_ini(const Job *j, bool complete) {
    size_t cap = 1024 + (size_t)(j->item_count + j->meta_count + j->program_count) * 48;
    char *t = malloc(cap), line[64];
    if (!t) return false;
    const HomeInstall *in = &j->info;
    snprintf(t, cap, "app=%016llx\nversion=%u\nname=%s\ncomplete=%d\ncontents=%d\nbytes=%lld\nconverted=%d\ncode_infos=%d\n",
             (unsigned long long)in->app_id, in->version, in->name, complete ? 1 : 0, in->contents, (long long)in->bytes,
             in->converted, in->code_infos);
    for (int i = 0; i < j->meta_count; i++) {
        char h[33];
        hex(j->metas[i].key, 16, h);
        snprintf(line, sizeof(line), "key=%s\n", h);
        strcat(t, line);
    }
    for (int i = 0; i < j->item_count; i++) {
        char h[33];
        hex(j->items[i].id, 16, h);
        snprintf(line, sizeof(line), "content=%s\n", h);
        strcat(t, line);
    }
    for (int i = 0; i < j->program_count; i++) {
        snprintf(line, sizeof(line), "codeinfo=%016llx\n", (unsigned long long)j->programs[i]);
        strcat(t, line);
    }
    char path[96];
    ini_path(in->app_id, path, sizeof(path));
    bool ok = mkdirs(VFS_SD, HOME_DIR) && write_text(VFS_SD, path, t);
    free(t);
    return ok;
}

static bool parse_install(const char *text, HomeInstall *out) {
    memset(out, 0, sizeof(*out));
    char v[160];
    if (!ini_get(text, "app", v, sizeof(v))) return false;
    out->app_id = strtoull(v, NULL, 16);
    out->version = (uint32_t)ini_get_i64(text, "version", 0);
    if (ini_get(text, "name", v, sizeof(v))) snprintf(out->name, sizeof(out->name), "%s", v);
    out->complete = ini_get_i64(text, "complete", 0) == 1;
    out->contents = (int)ini_get_i64(text, "contents", 0);
    out->bytes = ini_get_i64(text, "bytes", 0);
    out->converted = (int)ini_get_i64(text, "converted", 0);
    out->code_infos = (int)ini_get_i64(text, "code_infos", 0);
    return out->app_id != 0;
}

bool home_is_ours(uint64_t app) {
    char path[96];
    ini_path(app, path, sizeof(path));
    return vfs_stat(VFS_SD, path, NULL, NULL) == 0;
}

int home_list(HomeInstall *out, int max) {
    VfsEntry *e = NULL;
    int count = 0, n = 0;
    if (vfs_list(VFS_SD, HOME_DIR, &e, &count)) return 0;
    for (int i = 0; i < count && n < max; i++) {
        if (e[i].is_dir || !ends_with(e[i].name, ".ini")) continue;
        char path[300];
        snprintf(path, sizeof(path), HOME_DIR "/%s", e[i].name);
        char *t = read_text(VFS_SD, path, 64 * 1024);
        if (t && parse_install(t, &out[n])) n++;
        free(t);
    }
    free(e);
    return n;
}

// Undoes an install as listed in its ini text (each line "key=", "content=", "codeinfo="). Goes on past
// failures; false (first failure in err) if any step failed.
static bool undo(uint64_t app, const char *text, bool record, char *err, size_t errn) {
    bool ok = true;
    err[0] = 0;
#define FAIL(...) do { if (ok) snprintf(err, errn, __VA_ARGS__); ok = false; } while (0)
    if (record && home_record_exists(app) == 1 && home_record_delete(app))
        FAIL("The HOME entry could not be removed (%s).", home_last_error());
    for (const char *l = text; l && *l; l = strchr(l, '\n') ? strchr(l, '\n') + 1 : NULL) {
        uint8_t id[16];
        if (!strncmp(l, "key=", 4) && unhex(l + 4, id, 16)) {
            // not there when the install stopped before it, or the console's Data Management deleted the game
            if (home_meta_remove(id)) app_log("HOME: content list %.32s not removed (%s)", l + 4, home_last_error());
        } else if (!strncmp(l, "content=", 8) && unhex(l + 8, id, 16)) {
            if (home_content_has(id) && home_content_delete(id)) FAIL("Game data could not be removed (%s).", home_last_error());
        } else if (!strncmp(l, "codeinfo=", 9)) {
            char path[96];
            codeinfo_path(strtoull(l + 9, NULL, 16), path, sizeof(path));
            if (vfs_stat(VFS_SD, path, NULL, NULL) == 0 && vfs_delete(VFS_SD, path))
                FAIL("%s could not be deleted (%s).", path, vfs_last_error());
        }
    }
#undef FAIL
    return ok;
}

bool home_remove(uint64_t app, char *err, size_t errn) {
    char path[96];
    ini_path(app, path, sizeof(path));
    char *t = read_text(VFS_SD, path, 64 * 1024);
    if (!t) {
        snprintf(err, errn, "SeedSwap did not install %016llx, so it does not remove it.", (unsigned long long)app);
        return false;
    }
    if (home_sd_open()) {
        snprintf(err, errn, "The console's title storage cannot be opened (%s).", home_last_error());
        free(t);
        return false;
    }
    bool ok = undo(app, t, true, err, errn);
    if (ok && home_control_invalidate(app)) {}   // the entry is gone; a stale name cache does no harm
    home_sd_close();
    free(t);
    if (ok && vfs_delete(VFS_SD, path)) {
        snprintf(err, errn, "%s could not be deleted (%s).", path, vfs_last_error());
        return false;
    }
    if (ok) app_log("HOME: removed %016llx", (unsigned long long)app);
    return ok;
}

// ---- installing

// The header as it goes on the SD card: a title key moves into the key area (standard crypto), the
// cartridge mark is cleared. 1 = changed, 0 = as in the dump, -1 = error.
static int fix_header(const Nca *n, uint8_t h[0xc00], char *err, size_t errn) {
    int changed = 0;
    static const uint8_t zero[16];
    if (memcmp(h + 0x230, zero, 16)) {
        char name[48];
        snprintf(name, sizeof(name), "key_area_key_application_%02x", generation(h));
        uint8_t kak[16], area[0x40] = {0};
        if (!keys_get(n->pkg->keys, name, kak, 16)) {
            snprintf(err, errn, "prod.keys has no %s, which this game needs.", name);
            return -1;
        }
        memcpy(area + 0x20, n->key, 16);
        aes128_ecb_encrypt(kak, area, h + 0x300, sizeof(area));
        memset(kak, 0, sizeof(kak));
        memset(area, 0, sizeof(area));
        h[0x207] = 0;
        memset(h + 0x230, 0, 16);
        changed = 1;
    }
    if (h[0x204] == 1) {
        h[0x204] = 0;
        changed = 1;
    }
    return changed;
}

// ---- no BCAT for games on HOME
// Started from HOME, a game syncs its BCAT data (Nintendo's data delivery) before it loads; where the service
// can't be reached that waits for a time-out (Odyssey: 74 s on the logo). A hosted game runs as its host, which
// has no BCAT, and never waits. So the installed control data says the game has none: control.nacp's delivery
// cache storage size (0x30a0) and passphrase (0x3100, 0x41 bytes) are zeroed and the RomFS hash tree, the
// section's master hash and the header's section hash follow. The changed blocks go into the copied bytes as
// XOR deltas: the section is AES-CTR (or plain), so stored ^ old ^ new is the new stored data.
#define MAX_DELTAS 16
#define NACP_BCAT_SIZE 0x30a0
#define NACP_BCAT_PASS 0x3100
#define NACP_BCAT_PASS_LEN 0x41

typedef struct {
    uint64_t off;   // in the NCA
    size_t len;
    uint8_t *x;     // old ^ new
} Delta;

typedef struct {
    Delta d[MAX_DELTAS];
    int count;
} Deltas;

static void deltas_free(Deltas *ds) {
    for (int i = 0; i < ds->count; i++) free(ds->d[i].x);
    ds->count = 0;
}

static bool delta_add(Deltas *ds, uint64_t off, const uint8_t *old, const uint8_t *new_, size_t len) {
    if (ds->count >= MAX_DELTAS) return false;
    uint8_t *x = malloc(len);
    if (!x) return false;
    for (size_t i = 0; i < len; i++) x[i] = old[i] ^ new_[i];
    ds->d[ds->count].off = off;
    ds->d[ds->count].len = len;
    ds->d[ds->count].x = x;
    ds->count++;
    return true;
}

static void deltas_apply(const Deltas *ds, uint64_t off, uint8_t *buf, size_t len) {
    for (int i = 0; i < ds->count; i++) {
        const Delta *d = &ds->d[i];
        uint64_t a = d->off > off ? d->off : off;
        uint64_t b = d->off + d->len < off + len ? d->off + d->len : off + len;
        for (uint64_t p = a; p < b; p++) buf[p - off] ^= d->x[p - d->off];
    }
}

// The hash of one block as the tree stores it: a short last block hashed zero-padded or as it is, whichever
// the stored hash of the old block says (-1: the old block matches neither).
static int block_mode(const uint8_t *piece, size_t len, size_t bs, const uint8_t want[32]) {
    uint8_t got[32];
    fsha256(piece, len, got);
    if (!memcmp(got, want, 32)) return 0;
    if (len == bs) return -1;
    FastSha256 c;
    static const uint8_t zero[256];
    fsha256_init(&c);
    fsha256_update(&c, piece, len);
    for (size_t left = bs - len; left;) {
        size_t k = left < sizeof(zero) ? left : sizeof(zero);
        fsha256_update(&c, zero, k);
        left -= k;
    }
    fsha256_final(&c, got);
    return memcmp(got, want, 32) ? -1 : 1;
}

static void block_hash(const uint8_t *piece, size_t len, size_t bs, int mode, uint8_t out[32]) {
    if (!mode) {
        fsha256(piece, len, out);
        return;
    }
    FastSha256 c;
    static const uint8_t zero[256];
    fsha256_init(&c);
    fsha256_update(&c, piece, len);
    for (size_t left = bs - len; left;) {
        size_t k = left < sizeof(zero) ? left : sizeof(zero);
        fsha256_update(&c, zero, k);
        left -= k;
    }
    fsha256_final(&c, out);
}

// 1: the control data had BCAT and the deltas and h now take it out; 0: nothing to change (no BCAT, or a
// layout this does not handle; the NCA is then copied as it is).
static int no_bcat(Nca *n, uint8_t h[0xc00], Deltas *ds) {
    NcaSection s;
    if (!nca_section(n, 0, 0, &s) || s.sparse || (s.encryption != 1 && s.encryption != 3) || memcmp(s.fs + 8, "IVFC", 4))
        return 0;
    uint32_t layers = rd32(s.fs + 0x14);
    if (rd32(s.fs + 0x10) != 0x20 || layers < 2 || layers > 7) return 0;
    int levels = (int)layers - 1, data = levels - 1;
    uint64_t off[6], size[6], bs[6];
    for (int i = 0; i < levels; i++) {
        const uint8_t *l = s.fs + 0x18 + 0x18 * i;
        uint32_t log2 = rd32(l + 0x10);
        off[i] = rd64(l);
        size[i] = rd64(l + 8);
        if (log2 < 9 || log2 > 24 || !size[i] || off[i] + size[i] > s.end - s.start) return 0;
        bs[i] = (uint64_t)1 << log2;
    }
    if (size[data] > 64u * 1024 * 1024) return 0;
    uint8_t *img = malloc((size_t)size[data]);
    if (!img || !nca_section_read(n, &s, off[data], img, (size_t)size[data])) {
        free(img);
        return 0;
    }
    size_t nacp_len = 0;
    const uint8_t *nacp = pkg_romfs_file(img, (size_t)size[data], "control.nacp", &nacp_len);
    static const uint8_t zero[NACP_BCAT_PASS_LEN];
    if (!nacp || nacp_len < 0x4000 ||
        (!rd64(nacp + NACP_BCAT_SIZE) && !memcmp(nacp + NACP_BCAT_PASS, zero, NACP_BCAT_PASS_LEN))) {
        free(img);
        return 0;
    }
    uint64_t lo = (uint64_t)(nacp - img) + NACP_BCAT_SIZE, hi = (uint64_t)(nacp - img) + NACP_BCAT_PASS + NACP_BCAT_PASS_LEN;
    // level by level from the data up: the changed block range [b0, b1] of level i, old and new
    uint64_t b0 = lo / bs[data], b1 = (hi - 1) / bs[data];
    uint64_t start = b0 * bs[data], end = (b1 + 1) * bs[data] < size[data] ? (b1 + 1) * bs[data] : size[data];
    uint8_t *old = malloc((size_t)(end - start)), *cur = malloc((size_t)(end - start));
    bool ok = old && cur;
    if (ok) {
        memcpy(old, img + start, (size_t)(end - start));
        memcpy(cur, old, (size_t)(end - start));
        wr64(cur + (lo - start), 0);
        memset(cur + (lo - start) + (NACP_BCAT_PASS - NACP_BCAT_SIZE), 0, NACP_BCAT_PASS_LEN);
    }
    free(img);
    uint8_t *fs = h + 0x400 + 0x200 * s.index;
    for (int i = data; ok; i--) {
        ok = delta_add(ds, s.start + off[i] + start, old, cur, (size_t)(end - start));
        if (!ok) break;
        // the parent's bytes that hold this range's hashes
        uint64_t hs = b0 * 32, he = (b1 + 1) * 32;
        uint8_t *pold = NULL, *pcur = NULL;
        uint64_t pstart = 0, pend = 0;
        if (i == 0) {
            if (b0 != 0 || b1 != 0) { ok = false; break; }
            pold = malloc(32);
            pcur = malloc(32);
            ok = pold && pcur;
            if (ok) memcpy(pold, fs + 0xc8, 32);
        } else {
            uint64_t pb0 = hs / bs[i - 1], pb1 = (he - 1) / bs[i - 1];
            pstart = pb0 * bs[i - 1];
            pend = (pb1 + 1) * bs[i - 1] < size[i - 1] ? (pb1 + 1) * bs[i - 1] : size[i - 1];
            ok = he <= size[i - 1] && (pold = malloc((size_t)(pend - pstart))) && (pcur = malloc((size_t)(pend - pstart))) &&
                 nca_section_read(n, &s, off[i - 1] + pstart, pold, (size_t)(pend - pstart));
        }
        if (ok) memcpy(pcur, pold, i == 0 ? 32 : (size_t)(pend - pstart));
        for (uint64_t b = b0; ok && b <= b1; b++) {
            uint64_t ps = b * bs[i] - start, pl = (b + 1) * bs[i] < size[i] ? bs[i] : size[i] - b * bs[i];
            uint8_t *slot_old = pold + (i == 0 ? 0 : b * 32 - pstart), *slot_new = pcur + (i == 0 ? 0 : b * 32 - pstart);
            int mode = block_mode(old + ps, (size_t)pl, (size_t)bs[i], slot_old);
            ok = mode >= 0;
            if (ok) block_hash(cur + ps, (size_t)pl, (size_t)bs[i], mode, slot_new);
        }
        free(old);
        free(cur);
        old = pold;
        cur = pcur;
        if (!ok) break;
        if (i == 0) {
            memcpy(fs + 0xc8, cur, 32);
            fsha256(fs, 0x200, h + 0x280 + 0x20 * s.index);
            break;
        }
        b0 = hs / bs[i - 1];
        b1 = (he - 1) / bs[i - 1];
        start = pstart;
        end = pend;
    }
    free(old);
    free(cur);
    if (!ok) {
        deltas_free(ds);
        app_log("HOME: %s: control data left with BCAT (its hash tree is not as expected)", n->e->name);
        return 0;
    }
    return 1;
}

static bool install_item(Job *j, int index, ProgressFn cb, int64_t *done, bool *stopped, char *err, size_t errn) {
    Item *it = &j->items[index];
    Nca n;
    if (!nca_open(it->pkg, it->entry, &n, err, errn)) return false;
    uint8_t h[0xc00], enc[0xc00];
    memcpy(h, n.header, sizeof(h));
    int changed = fix_header(&n, h, err, errn);
    if (changed < 0) { nca_close(&n); return false; }
    Deltas ds = {0};
    if (h[0x205] == NCA_CONTROL && no_bcat(&n, h, &ds)) {
        changed = 1;
        app_log("HOME: %s: control data says the game has no BCAT", n.e->name);
    }
    if (changed) {
        aes128_xts_encrypt(it->pkg->header_key, 0, h, enc, sizeof(h));
        if (h[0x205] == NCA_PROGRAM && j->info_count < MAX_CODEINFO) {
            // Loader checks the original header's second signature against the game's NPDM key, using the hash
            // FS gives it. FS now hashes the changed header; the loader swaps in the original block.
            CodeInfo *ci = &j->infos[j->info_count++];
            ci->program = rd64(h + 0x210);
            uint8_t *e = ci->entry;
            memset(e, 0, sizeof(ci->entry));
            fsha256(h + 0x200, 0x200, e);
            memcpy(e + 0x20, n.header + 0x100, 0x100);
            fsha256(n.header + 0x200, 0x200, e + 0x20 + 0x180);
            e[0x20 + 0x1a0] = 1;
        }
    }
    uint8_t ph[16];
    if (home_placeholder_create(it->id, ph, (int64_t)n.size)) {
        snprintf(err, errn, "No room for the game data could be made (%s).", home_last_error());
        deltas_free(&ds);
        nca_close(&n);
        return false;
    }
    uint8_t *buf = malloc(CHUNK);
    bool ok = buf != NULL;
    if (!ok) snprintf(err, errn, "Not enough memory.");
    char text[80];
    snprintf(text, sizeof(text), "Copying game data (%d of %d)", index + 1, j->item_count);
    for (uint64_t off = 0; ok && off < n.size;) {
        size_t k = n.size - off < CHUNK ? (size_t)(n.size - off) : CHUNK;
        if (!nca_read_raw(&n, off, buf, k)) {
            snprintf(err, errn, "The dump could not be read (%s).", vfs_last_error());
            ok = false;
            break;
        }
        deltas_apply(&ds, off, buf, k);
        if (!off && changed) memcpy(buf, enc, k < sizeof(enc) ? k : sizeof(enc));
        if (home_placeholder_write(ph, (int64_t)off, buf, k)) {
            snprintf(err, errn, "Writing the game data failed (%s).", home_last_error());
            ok = false;
            break;
        }
        off += k;
        *done += (int64_t)k;
        if (cb && !cb(j->info.bytes ? (float)((double)*done / (double)j->info.bytes) : -1.0f, text)) {
            *stopped = true;
            snprintf(err, errn, "Stopped.");
            ok = false;
        }
    }
    free(buf);
    deltas_free(&ds);
    nca_close(&n);
    if (ok && home_content_register(it->id, ph)) {
        snprintf(err, errn, "The game data could not be registered (%s).", home_last_error());
        ok = false;
    }
    if (!ok) home_placeholder_delete(ph);
    return ok;
}

// Bytes of extended data a packaged content list carries after its content (meta) infos: an update's patch
// history, sized by its extended header (u32 at +0xc). 0 for other types.
static size_t extended_data_size(const uint8_t *c) {
    uint16_t ext = rd16(c + 0xe);
    return c[0xc] == META_PATCH && ext >= 0x10 ? rd32(c + 0x20 + 0xc) : 0;
}

// ncm's content meta, laid out as ncm's own converter does: header, the extended header as packaged, the Meta
// NCA's own info, the content infos (delta fragments left out: they are not installed), the content meta infos,
// then the extended data. The extended data must be there: the extended header gives its size, and the database
// entry is read by that size (an update without it failed with 2808-1226 "Unable to load data").
static uint8_t *meta_blob(const Job *j, const Meta *m, size_t *size) {
    const uint8_t *c = m->cnmt;
    uint16_t ext = rd16(c + 0xe), records = rd16(c + 0x10), metas = rd16(c + 0x12);
    size_t data_at = 0x20 + ext + 0x38 * (size_t)records + 0x10 * (size_t)metas, data = extended_data_size(c);
    if (data_at + data > m->cnmt_size) return NULL;
    int kept = 0;
    for (unsigned r = 0; r < records; r++) kept += c[0x20 + ext + 0x38 * r + 0x36] != 6;
    size_t n = 8 + ext + 0x18 * (size_t)(kept + 1) + 0x10 * (size_t)metas + data;
    uint8_t *b = calloc(1, n);
    if (!b) return NULL;
    wr16(b, ext);
    wr16(b + 2, (uint16_t)(kept + 1));
    wr16(b + 4, metas);
    b[6] = c[0x14];   // attributes
    memcpy(b + 8, c + 0x20, ext);
    uint8_t *info = b + 8 + ext;
    const Item *mi = &j->items[m->item];
    memcpy(info, mi->id, 16);
    wr32(info + 0x10, (uint32_t)mi->size);
    info[0x14] = (uint8_t)(mi->size >> 32);
    info += 0x18;   // attributes, type (meta) and id offset stay 0
    for (unsigned r = 0; r < records; r++) {
        const uint8_t *rec = c + 0x20 + ext + 0x38 * r;
        if (rec[0x36] == 6) continue;
        memcpy(info, rec + 0x20, 0x18);
        info += 0x18;
    }
    memcpy(info, c + 0x20 + ext + 0x38 * (size_t)records, 0x10 * (size_t)metas + data);
    *size = n;
    return b;
}

static bool write_codeinfos(const Job *j, char *err, size_t errn) {
    if (!j->info_count) return true;
    if (!mkdirs(VFS_SD, HOME_CODEINFO_DIR)) {
        snprintf(err, errn, "%s cannot be made (%s).", HOME_CODEINFO_DIR, vfs_last_error());
        return false;
    }
    for (int p = 0; p < j->program_count; p++) {
        uint8_t data[8 + 4 * CODEINFO_ENTRY];
        int count = 0;
        for (int i = 0; i < j->info_count && count < 4; i++)
            if (j->infos[i].program == j->programs[p]) memcpy(data + 8 + CODEINFO_ENTRY * count++, j->infos[i].entry, CODEINFO_ENTRY);
        if (!count) continue;
        memcpy(data, "SSCI", 4);
        data[4] = 2;
        data[5] = (uint8_t)count;
        data[6] = data[7] = 0;
        char path[96];
        codeinfo_path(j->programs[p], path, sizeof(path));
        size_t n = 8 + (size_t)count * CODEINFO_ENTRY;
        if (vfs_stat(VFS_SD, path, NULL, NULL) == 0) vfs_delete(VFS_SD, path);
        VfsFile *f = vfs_create(VFS_SD, path, (int64_t)n) == 0 ? vfs_open(VFS_SD, path, true) : NULL;
        bool ok = f && vfs_write(f, 0, data, n) == 0 && vfs_flush(f) == 0;
        if (f) vfs_close(f);
        if (!ok) {
            snprintf(err, errn, "%s cannot be written (%s).", path, vfs_last_error());
            return false;
        }
    }
    return true;
}

// Opens the console's title storage and checks the title is free (or SeedSwap's own). 1 = SeedSwap's own install
// is there, 0 = free, -1 = refused (err).
static int check_free(const Job *j, char *err, size_t errn) {
    uint64_t app = j->info.app_id;
    int exists = home_record_exists(app);
    if (exists < 0) {
        snprintf(err, errn, "The console's title list cannot be read (%s).", home_last_error());
        return -1;
    }
    bool ours = home_is_ours(app);
    if (exists && !ours) {
        snprintf(err, errn, "This game (%016llx) is already installed on the console. SeedSwap leaves it alone.",
                 (unsigned long long)app);
        return -1;
    }
    if (!ours)
        for (int i = 0; i < j->item_count; i++)
            if (home_content_has(j->items[i].id)) {
                snprintf(err, errn, "Some of this game's data is already on the SD card from another install. "
                         "SeedSwap leaves it alone.");
                return -1;
            }
    return ours ? 1 : 0;
}

bool home_check(const char *base_path, const char *update_path, const char *keys_path, HomeInstall *out, char *err,
                size_t errn) {
    Job *j = calloc(1, sizeof(Job));
    if (!j) { snprintf(err, errn, "Not enough memory."); return false; }
    bool ok = job_open(base_path, update_path, keys_path, j, err, errn);
    if (ok && home_sd_open()) {
        snprintf(err, errn, "The console's title storage cannot be opened (%s).", home_last_error());
        ok = false;
    } else if (ok) {
        ok = check_free(j, err, errn) >= 0;
        home_sd_close();
    }
    if (ok && vfs_free_space(VFS_SD) >= 0 && vfs_free_space(VFS_SD) < j->info.bytes + (64 << 20)) {
        char need[32], have[32];
        fmt_bytes(j->info.bytes, need, sizeof(need));
        fmt_bytes(vfs_free_space(VFS_SD), have, sizeof(have));
        snprintf(err, errn, "The game needs %s on the SD card; %s is free.", need, have);
        ok = false;
    }
    if (ok && out) *out = j->info;
    job_close(j);
    free(j);
    return ok;
}

bool home_install(const char *base_path, const char *update_path, const char *keys_path, ProgressFn cb,
                  HomeInstall *out, char *err, size_t errn) {
    if (!home_check(base_path, update_path, keys_path, NULL, err, errn)) return false;
    Job *j = calloc(1, sizeof(Job));
    if (!j) { snprintf(err, errn, "Not enough memory."); return false; }
    if (!job_open(base_path, update_path, keys_path, j, err, errn)) { free(j); return false; }
    uint64_t app = j->info.app_id;
    bool ok = false, stopped = false, wrote = false;
    char path[96], e2[300];
    ini_path(app, path, sizeof(path));
    if (home_sd_open()) {
        snprintf(err, errn, "The console's title storage cannot be opened (%s).", home_last_error());
        goto done;
    }
    int state = check_free(j, err, errn);
    if (state < 0) goto close;
    if (state == 1) {   // SeedSwap's own earlier install: replaced
        char *old = read_text(VFS_SD, path, 64 * 1024);
        bool gone = old && undo(app, old, true, e2, sizeof(e2));
        free(old);
        if (!gone) {
            snprintf(err, errn, "The earlier install could not be removed: %s", old ? e2 : "its list cannot be read.");
            goto close;
        }
    }
    // the list first, so an install that stops part way (power, crash) can still be removed
    if (!write_ini(j, false)) {
        snprintf(err, errn, "%s cannot be written (%s).", path, vfs_last_error());
        goto close;
    }
    wrote = true;
    app_log("HOME: installing %016llx v%u: %d files, %lld bytes, %d with a title key", (unsigned long long)app,
            j->info.version, j->info.contents, (long long)j->info.bytes, j->info.converted);
    int64_t done = 0;
    for (int i = 0; i < j->item_count; i++)
        if (!install_item(j, i, cb, &done, &stopped, err, errn)) goto close;
    if (cb && !cb(1.0f, "Adding the game to HOME")) { stopped = true; snprintf(err, errn, "Stopped."); goto close; }
    if (!write_codeinfos(j, err, errn)) goto close;
    uint8_t keys[MAX_METAS][16];
    for (int i = 0; i < j->meta_count; i++) {
        size_t n = 0;
        uint8_t *blob = meta_blob(j, &j->metas[i], &n);
        int r = blob ? home_meta_set(j->metas[i].key, blob, n) : -1;
        free(blob);
        if (r) {
            snprintf(err, errn, "The content list could not be saved (%s).", blob ? home_last_error() : "it is cut short in the dump, or no memory");
            goto close;
        }
        memcpy(keys[i], j->metas[i].key, 16);
    }
    if (home_record_push(app, (const uint8_t (*)[16])keys, j->meta_count)) {
        snprintf(err, errn, "The HOME entry could not be added (%s).", home_last_error());
        goto close;
    }
    if (home_launch_version(app, j->info.version)) app_log("HOME: launch version not set (%s)", home_last_error());
    if (home_control_invalidate(app)) app_log("HOME: name cache not cleared (%s)", home_last_error());
    if (!write_ini(j, true)) app_log("HOME: %s not marked complete (%s)", path, vfs_last_error());
    j->info.complete = true;
    if (out) *out = j->info;
    app_log("HOME: installed %016llx", (unsigned long long)app);
    ok = true;
close:
    if (!ok && wrote) {
        char *t = read_text(VFS_SD, path, 64 * 1024);
        if (t && undo(app, t, true, e2, sizeof(e2))) vfs_delete(VFS_SD, path);
        else app_log("HOME: undo of %016llx incomplete: %s", (unsigned long long)app, t ? e2 : "list unreadable");
        free(t);
        app_log("HOME: install of %016llx %s: %s", (unsigned long long)app, stopped ? "stopped" : "failed", err);
    }
    home_sd_close();
done:
    job_close(j);
    free(j);
    return ok;
}
