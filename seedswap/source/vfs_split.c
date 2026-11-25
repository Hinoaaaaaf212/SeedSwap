// SPDX-License-Identifier: GPL-2.0-only
// Files kept in parts on the SD card, for FAT32 cards that hold files up to 4 GB only (issue 11).
// Every caller sees one file:
//   - a dump folder (name ends in .nsp/.nsz/.xci/.xcz) holding 00, 01, ...: a split dump. With its
//     archive bit set the console's FS already shows it as one file; without it (copied from a
//     Mac or Linux PC) it is a folder, read here part by part;
//   - PATH.00, PATH.01, ... beside a missing PATH: what vfs_create makes when the card refuses a
//     file over 4 GB, 0xFFFF0000 bytes per part. The loader reads romfs.bin.NN the same way (PATH wins when
//     both are there).
// Only the SD card; the save is passed through as is.
#include "platform.h"
#include "util.h"
#include "vfs_raw.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

#define SPLIT_MAX 64

enum { K_PLAIN, K_DIR, K_SIB };

static void delete_parts(VfsRoot r, const char *path);

static char g_lerr[256];
static bool g_lset;

static void lerr(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(g_lerr, sizeof(g_lerr), fmt, ap);
    va_end(ap);
    g_lset = true;
}

const char *vfs_last_error(void) { return g_lset ? g_lerr : pvfs_last_error(); }

// The size of each new part. SEEDSWAP_PART_SIZE changes it in the PC build, for tests.
static int64_t vfs_part_size(void) {
#ifndef __SWITCH__
    const char *e = getenv("SEEDSWAP_PART_SIZE");
    if (e && atoll(e) > 0) return atoll(e);
#endif
    return 0xFFFF0000ll;   // as Nintendo's own big files on FAT32; 8 parts = 32 GB, what the loader looks for
}

// The biggest file a FAT32 card holds. SEEDSWAP_FAT32_MAX changes it in the PC build, for tests.
static int64_t fat32_max(void) {
#ifndef __SWITCH__
    const char *e = getenv("SEEDSWAP_FAT32_MAX");
    if (e && atoll(e) > 0) return atoll(e);
#endif
    return 0xFFFFFFFFll;
}

static bool dump_name(const char *path) {
    const char *dot = strrchr(path, '.'), *slash = strrchr(path, '/');
    if (!dot || (slash && dot < slash)) return false;
    return !strcasecmp(dot, ".nsp") || !strcasecmp(dot, ".nsz") || !strcasecmp(dot, ".xci") || !strcasecmp(dot, ".xcz");
}

static void part_name(int kind, const char *path, int i, char *out, size_t n) {
    if (kind == K_DIR) snprintf(out, n, "%s/%02d", path, i);
    else if (kind == K_SIB) snprintf(out, n, "%s.%02d", path, i);
    else snprintf(out, n, "%s", path);
}

static bool raw_file(VfsRoot r, const char *path, int64_t *size) {
    bool dir = false;
    return pvfs_stat(r, path, &dir, size) == 0 && !dir;
}

// What PATH is: -1 missing, 1 a folder, 0 a file (kind, part count, part sizes; sizes may be NULL).
static int lookup(VfsRoot r, const char *path, int *kind, int *n, int64_t *sizes) {
    bool dir = false;
    int64_t size = 0;
    char p[1024];
    *n = 0;
    if (pvfs_stat(r, path, &dir, &size) == 0) {
        if (!dir) {
            *kind = K_PLAIN;
            *n = 1;
            if (sizes) sizes[0] = size;
            return 0;
        }
        if (!dump_name(path)) return 1;
        *kind = K_DIR;
    } else {
        *kind = K_SIB;
    }
    for (int i = 0; i < SPLIT_MAX; i++) {
        part_name(*kind, path, i, p, sizeof(p));
        if (!raw_file(r, p, &size)) break;
        if (sizes) sizes[i] = size;
        ++*n;
    }
    if (*n) return 0;
    return *kind == K_DIR ? 1 : -1;
}

int vfs_stat(VfsRoot r, const char *path, bool *is_dir, int64_t *size) {
    g_lset = false;
    if (r != VFS_SD) return pvfs_stat(r, path, is_dir, size);
    int kind, n;
    int64_t sizes[SPLIT_MAX];
    int t = lookup(r, path, &kind, &n, sizes);
    if (t < 0) return -1;
    if (is_dir) *is_dir = t == 1;
    if (size) {
        *size = 0;
        for (int i = 0; t == 0 && i < n; i++) *size += sizes[i];
    }
    return 0;
}

static bool part_suffix(const char *name, size_t *base_len, int *num) {
    size_t l = strlen(name);
    if (l < 4 || name[l - 3] != '.' || name[l - 2] < '0' || name[l - 2] > '9' || name[l - 1] < '0' || name[l - 1] > '9')
        return false;
    *base_len = l - 3;
    *num = (name[l - 2] - '0') * 10 + (name[l - 1] - '0');
    return true;
}

static int find_entry(const VfsEntry *e, int n, const char *name, size_t len) {
    for (int i = 0; i < n; i++)
        if (strlen(e[i].name) == len && !strncmp(e[i].name, name, len)) return i;
    return -1;
}

int vfs_list(VfsRoot r, const char *dir, VfsEntry **out, int *count) {
    g_lset = false;
    if (pvfs_list(r, dir, out, count) != 0 || r != VFS_SD) return r != VFS_SD ? 0 : -1;
    VfsEntry *e = *out;
    int n = *count, m = 0;
    bool *drop = calloc((size_t)n + 1, 1), *group = calloc((size_t)n + 1, 1);
    if (!drop || !group) { free(drop); free(group); return 0; }
    for (int i = 0; i < n; i++) {
        size_t bl;
        int num;
        if (e[i].is_dir && dump_name(e[i].name)) {   // a split dump folder: one file
            char p[1024];
            int kind, parts;
            int64_t sizes[SPLIT_MAX];
            size_t dl = strlen(dir);
            snprintf(p, sizeof(p), "%.*s/%s", (int)(dl && dir[dl - 1] == '/' ? dl - 1 : dl), dir, e[i].name);
            if (lookup(r, p, &kind, &parts, sizes) == 0) {
                e[i].is_dir = false;
                e[i].size = 0;
                for (int k = 0; k < parts; k++) e[i].size += sizes[k];
            }
        } else if (!e[i].is_dir && part_suffix(e[i].name, &bl, &num)) {   // NAME.NN beside no NAME
            if (find_entry(e, n, e[i].name, bl) >= 0) continue;
            if (num != 0) {   // counted under NAME.00 (or a stray part after a gap)
                drop[i] = true;
                continue;
            }
            group[i] = true;   // renamed below, once every name has been compared as listed
        }
    }
    for (int i = 0; i < n; i++) {
        size_t bl;
        int num;
        if (!group[i] || !part_suffix(e[i].name, &bl, &num)) continue;
        int64_t total = e[i].size;
        for (int k = 1; k < SPLIT_MAX; k++) {
            char q[300];
            snprintf(q, sizeof(q), "%.*s.%02d", (int)bl, e[i].name, k);
            int j = find_entry(e, n, q, strlen(q));
            if (j < 0 || e[j].is_dir) break;
            total += e[j].size;
        }
        e[i].name[bl] = 0;
        e[i].size = total;
    }
    for (int i = 0; i < n; i++)
        if (!drop[i]) e[m++] = e[i];
    free(drop);
    free(group);
    *count = m;
    return 0;
}

struct VfsFile {
    VfsRoot r;
    int kind, n;
    bool write;
    PVfsFile *p[SPLIT_MAX];
    int64_t start[SPLIT_MAX + 1];
    char path[768];
};

VfsFile *vfs_open(VfsRoot r, const char *path, bool write) {
    g_lset = false;
    VfsFile *f = calloc(1, sizeof(*f));
    if (!f) return NULL;
    f->r = r;
    f->write = write;
    snprintf(f->path, sizeof(f->path), "%s", path);
    int64_t sizes[SPLIT_MAX];
    if (r != VFS_SD) {
        f->kind = K_PLAIN;
        f->n = 1;
        sizes[0] = 0;
    } else if (lookup(r, path, &f->kind, &f->n, sizes) != 0) {
        lerr("open %s: no such file", path);
        free(f);
        return NULL;
    }
    for (int i = 0; i < f->n; i++) {
        char p[1024];
        part_name(f->kind, path, i, p, sizeof(p));
        f->p[i] = pvfs_open(r, p, write);
        if (!f->p[i]) {
            for (int k = 0; k < i; k++) pvfs_close(f->p[k]);
            free(f);
            return NULL;
        }
        f->start[i + 1] = f->start[i] + (f->kind == K_PLAIN ? 0 : sizes[i]);
    }
    return f;
}

// The part holding byte off (the last part for off at or past the end).
static int part_at(const VfsFile *f, int64_t off) {
    for (int i = 0; i < f->n - 1; i++)
        if (off < f->start[i + 1]) return i;
    return f->n - 1;
}

int vfs_read(VfsFile *f, int64_t off, void *buf, size_t n, size_t *got) {
    g_lset = false;
    if (f->kind == K_PLAIN) return pvfs_read(f->p[0], off, buf, n, got);
    size_t done = 0;
    while (done < n) {
        int i = part_at(f, off);
        int64_t end = f->start[i + 1];
        if (off >= end) break;   // the end of the file
        size_t want = n - done;
        if ((int64_t)want > end - off) want = (size_t)(end - off);
        size_t k = 0;
        if (pvfs_read(f->p[i], off - f->start[i], (char *)buf + done, want, &k) != 0) {
            if (got) *got = done;
            return -1;
        }
        done += k;
        off += (int64_t)k;
        if (k < want) break;
    }
    if (got) *got = done;
    return 0;
}

int vfs_write(VfsFile *f, int64_t off, const void *buf, size_t n) {
    g_lset = false;
    if (f->kind == K_PLAIN) {
        if (pvfs_write(f->p[0], off, buf, n) == 0) return 0;
        // A file growing past what a FAT32 card holds (DLC appended to a romfs.bin just under 4 GB):
        // it becomes PATH.00, and what follows goes to PATH.01, ...
        int64_t size = pvfs_size(f->p[0]);
        if (f->r != VFS_SD || !f->write || off + (int64_t)n <= fat32_max() || size < 0 || off > size) return -1;
        char p[1024];
        part_name(K_SIB, f->path, 0, p, sizeof(p));
        pvfs_flush(f->p[0]);
        pvfs_close(f->p[0]);
        delete_parts(f->r, f->path);
        if (pvfs_rename(f->r, f->path, p) != 0 || !(f->p[0] = pvfs_open(f->r, p, true))) {
            lerr("%s grew past 4 GB and could not be kept in parts (%s)", f->path, pvfs_last_error());
            if (!raw_file(f->r, f->path, NULL)) pvfs_rename(f->r, p, f->path);
            f->p[0] = pvfs_open(f->r, f->path, true);
            if (!f->p[0]) f->n = 0;
            return -1;
        }
        f->kind = K_SIB;
        f->start[0] = 0;
        f->start[1] = size;
        app_log("%s: past 4 GB, now kept in parts", f->path);
    }
    const int64_t part = vfs_part_size();
    size_t done = 0;
    while (done < n) {
        int i = part_at(f, off);
        bool last = i == f->n - 1;
        int64_t cap = f->start[i + 1] - f->start[i];
        if (last && cap < part) cap = part;   // the last part grows up to a whole part
        int64_t end = f->start[i] + cap;
        if (off > f->start[f->n]) { lerr("write past the end of %s", f->path); return -1; }
        if (off >= end) {   // the last part is whole: start the next one
            if (f->n == SPLIT_MAX) { lerr("%s would need more than %d parts", f->path, SPLIT_MAX); return -1; }
            char p[1024];
            part_name(f->kind, f->path, f->n, p, sizeof(p));
            if (pvfs_create(f->r, p, 0) != 0 || !(f->p[f->n] = pvfs_open(f->r, p, true))) return -1;
            f->start[f->n + 1] = f->start[f->n];
            f->n++;
            continue;
        }
        size_t want = n - done;
        if ((int64_t)want > end - off) want = (size_t)(end - off);
        if (pvfs_write(f->p[i], off - f->start[i], (const char *)buf + done, want) != 0) return -1;
        done += want;
        off += (int64_t)want;
        if (last && off > f->start[i + 1]) f->start[i + 1] = off;
    }
    return 0;
}

int vfs_flush(VfsFile *f) {
    int rc = 0;
    for (int i = 0; i < f->n; i++)
        if (pvfs_flush(f->p[i]) != 0) rc = -1;
    return rc;
}

int64_t vfs_size(VfsFile *f) {
    if (f->kind == K_PLAIN) return pvfs_size(f->p[0]);
    int64_t total = 0;
    for (int i = 0; i < f->n; i++) {
        int64_t s = pvfs_size(f->p[i]);
        if (s < 0) return -1;
        f->start[i] = total;
        total += s;
    }
    f->start[f->n] = total;
    return total;
}

void vfs_close(VfsFile *f) {
    if (!f) return;
    for (int i = 0; i < f->n; i++) pvfs_close(f->p[i]);
    free(f);
}

// Deletes PATH.00 to PATH.63 that exist (parts left from an earlier write).
static void delete_parts(VfsRoot r, const char *path) {
    for (int i = 0; i < SPLIT_MAX; i++) {
        char p[1024];
        part_name(K_SIB, path, i, p, sizeof(p));
        if (raw_file(r, p, NULL)) pvfs_delete(r, p);
    }
}

int vfs_create(VfsRoot r, const char *path, int64_t size) {
    g_lset = false;
    if (r != VFS_SD || size <= fat32_max()) return pvfs_create(r, path, size);
    if (vfs_stat(r, path, NULL, NULL) == 0) { lerr("create %s: it exists", path); return -1; }
    if (pvfs_create(r, path, size) == 0) return 0;   // exFAT: one file
    char first[200];
    snprintf(first, sizeof(first), "%s", pvfs_last_error());
    // FAT32: parts
    const int64_t part = vfs_part_size();
    int parts = (int)((size + part - 1) / part);
    if (parts > SPLIT_MAX) { lerr("create %s: %lld bytes need more than %d parts", path, (long long)size, SPLIT_MAX); return -1; }
    for (int i = 0; i < parts; i++) {
        char p[1024];
        part_name(K_SIB, path, i, p, sizeof(p));
        int64_t s = i == parts - 1 ? size - (int64_t)i * part : part;
        if (pvfs_create(r, p, s) != 0) {
            lerr("create %s (as one file: %s; in parts: %s)", path, first, pvfs_last_error());
            delete_parts(r, path);
            return -1;
        }
    }
    app_log("%s: %.2f GB in %d parts (the card takes no file this big)", path, (double)size / 1e9, parts);
    return 0;
}

int vfs_delete(VfsRoot r, const char *path) {
    g_lset = false;
    if (r != VFS_SD) return pvfs_delete(r, path);
    int kind, n;
    int t = lookup(r, path, &kind, &n, NULL);
    if (t != 0) { lerr("delete %s: no such file", path); return -1; }
    int rc = kind == K_DIR ? pvfs_rmtree(r, path) : kind == K_PLAIN ? pvfs_delete(r, path) : 0;
    delete_parts(r, path);   // with a plain file too, so no old parts show through later
    return rc;
}

int vfs_rmtree(VfsRoot r, const char *path) {
    g_lset = false;
    return pvfs_rmtree(r, path);
}

int vfs_rename(VfsRoot r, const char *from, const char *to) {
    g_lset = false;
    if (r != VFS_SD) return pvfs_rename(r, from, to);
    int kind, n;
    int t = lookup(r, from, &kind, &n, NULL);
    if (t < 0) { lerr("rename: %s missing", from); return -1; }
    if (t == 1 || kind != K_SIB) {
        if (t == 0 && vfs_stat(r, to, NULL, NULL) == 0) { lerr("rename target exists: %s", to); return -1; }
        return pvfs_rename(r, from, to);
    }
    if (vfs_stat(r, to, NULL, NULL) == 0) { lerr("rename target exists: %s", to); return -1; }
    delete_parts(r, to);
    for (int i = 0; i < n; i++) {
        char a[1024], b[1024];
        part_name(K_SIB, from, i, a, sizeof(a));
        part_name(K_SIB, to, i, b, sizeof(b));
        if (pvfs_rename(r, a, b) != 0) {
            char e[200];
            snprintf(e, sizeof(e), "%s", pvfs_last_error());
            for (int k = 0; k < i; k++) {   // put the parts moved so far back
                part_name(K_SIB, from, k, a, sizeof(a));
                part_name(K_SIB, to, k, b, sizeof(b));
                pvfs_rename(r, b, a);
            }
            lerr("rename %s part %d: %s", from, i, e);
            return -1;
        }
    }
    return 0;
}
