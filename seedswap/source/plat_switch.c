// SPDX-License-Identifier: GPL-2.0-only
// SeedSwap platform backend for kaiHEN (libounce). Display: linear RGBA8888
// framebuffer, double buffered. Files: the SD card and the Seedsow account
// save through fsp-srv (HEN's FS proxy root, as mxdump/mxwrite use it).
#include "platform.h"
#include "vfs_raw.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <switch.h>
#include <kaihen.h>

static Framebuffer g_fb;
static Canvas g_canvas;
static PadState g_pad;
static FsFileSystem g_sd, g_save;
static bool g_save_open, g_acc_ok;
static char g_err[160];
static uint64_t g_down, g_held, g_repeat_at;

struct PVfsFile { FsFile f; };

static void set_err(const char *what, Result rc) { snprintf(g_err, sizeof(g_err), "%s failed (0x%x)", what, rc); }
const char *pvfs_last_error(void) { return g_err; }

bool plat_init(void) {
    if (R_FAILED(framebufferCreate(&g_fb, nwindowGetDefault(), SCREEN_W, SCREEN_H, PIXEL_FORMAT_RGBA_8888, 2)))
        return false;
    framebufferMakeLinear(&g_fb);
    padConfigureInput(1, HidNpadStyleSet_NpadStandard);
    padInitializeDefault(&g_pad);
    Result rc = fsOpenSdCardFileSystem(&g_sd);
    if (R_FAILED(rc)) { set_err("open SD card", rc); return false; }
    g_acc_ok = R_SUCCEEDED(accountInitialize(AccountServiceType_Application));
    timeInitialize();
    return true;
}

void plat_exit(void) {
    save_unmount();
    fsFsClose(&g_sd);
    if (g_acc_ok) accountExit();
    timeExit();
    framebufferClose(&g_fb);
}

static uint64_t map_buttons(uint64_t b) {
    uint64_t o = 0;
    if (b & HidNpadButton_A) o |= BTN_A;
    if (b & HidNpadButton_B) o |= BTN_B;
    if (b & HidNpadButton_X) o |= BTN_X;
    if (b & HidNpadButton_Y) o |= BTN_Y;
    if (b & HidNpadButton_L) o |= BTN_L;
    if (b & HidNpadButton_R) o |= BTN_R;
    if (b & HidNpadButton_ZL) o |= BTN_ZL;
    if (b & HidNpadButton_ZR) o |= BTN_ZR;
    if (b & HidNpadButton_Plus) o |= BTN_PLUS;
    if (b & HidNpadButton_Minus) o |= BTN_MINUS;
    if (b & HidNpadButton_AnyUp) o |= BTN_UP;
    if (b & HidNpadButton_AnyDown) o |= BTN_DOWN;
    if (b & HidNpadButton_AnyLeft) o |= BTN_LEFT;
    if (b & HidNpadButton_AnyRight) o |= BTN_RIGHT;
    return o;
}

static bool g_exit;   // the system asked the app to close (seen once by appletMainLoop)

bool plat_loop(void) {
    if (g_exit || !appletMainLoop()) return false;
    padUpdate(&g_pad);
    g_down = map_buttons(padGetButtonsDown(&g_pad));
    g_held = map_buttons(padGetButtons(&g_pad));
    const uint64_t dirs = BTN_UP | BTN_DOWN | BTN_LEFT | BTN_RIGHT;
    uint64_t now = plat_ms();
    if (g_down & dirs) g_repeat_at = now + 380;
    else if ((g_held & dirs) && now >= g_repeat_at) { g_down |= g_held & dirs; g_repeat_at = now + 70; }
    return true;
}

uint64_t plat_buttons_down(void) { return g_down; }
uint64_t plat_buttons_held(void) { return g_held; }
uint64_t plat_ms(void) { return armTicksToNs(armGetSystemTick()) / 1000000ULL; }
void plat_sleep_ms(int ms) { svcSleepThread((s64)ms * 1000000LL); }
void plat_keep_awake(bool on) { (void)appletSetAutoSleepDisabled(on); }  // best effort: an error changes nothing

bool plat_poll_stop(void) {
    if (g_exit || !appletMainLoop()) {
        g_exit = true;
        return true;
    }
    padUpdate(&g_pad);
    return (padGetButtonsDown(&g_pad) & HidNpadButton_B) != 0;
}

bool plat_now(char *out, size_t n, bool compact) {
    time_t t = time(NULL);
    if (t < 1600000000) { snprintf(out, n, compact ? "boot%llu" : "time unknown", (unsigned long long)plat_ms()); return false; }
    struct tm tm;
    localtime_r(&t, &tm);
    strftime(out, n, compact ? "%Y%m%dT%H%M%S" : "%Y-%m-%d %H:%M", &tm);
    return true;
}

Canvas *plat_frame_begin(void) {
    u32 stride = 0;
    g_canvas.px = framebufferBegin(&g_fb, &stride);
    g_canvas.w = SCREEN_W;
    g_canvas.h = SCREEN_H;
    g_canvas.stride = (int)(stride / 4);
    return &g_canvas;
}
void plat_frame_end(void) { framebufferEnd(&g_fb); }

// ---- files
static FsFileSystem *fsys(VfsRoot r) { return r == VFS_SAVE ? (g_save_open ? &g_save : NULL) : &g_sd; }

int pvfs_stat(VfsRoot r, const char *path, bool *is_dir, int64_t *size) {
    FsFileSystem *fs = fsys(r);
    if (!fs) return -1;
    FsDirEntryType type;
    if (R_FAILED(fsFsGetEntryType(fs, path, &type))) return -1;
    if (is_dir) *is_dir = type == FsDirEntryType_Dir;
    if (size) {
        *size = 0;
        if (type == FsDirEntryType_File) {
            FsFile f;
            if (R_SUCCEEDED(fsFsOpenFile(fs, path, FsOpenMode_Read, &f))) {
                s64 s = 0;
                fsFileGetSize(&f, &s);
                *size = s;
                fsFileClose(&f);
            }
        }
    }
    return 0;
}

int pvfs_list(VfsRoot r, const char *dir, VfsEntry **out, int *count) {
    *out = NULL;
    *count = 0;
    FsFileSystem *fs = fsys(r);
    if (!fs) return -1;
    FsDir d;
    Result rc = fsFsOpenDirectory(fs, dir, FsDirOpenMode_ReadDirs | FsDirOpenMode_ReadFiles, &d);
    if (R_FAILED(rc)) { set_err("open directory", rc); return -1; }
    s64 n = 0;
    fsDirGetEntryCount(&d, &n);
    if (n <= 0) { fsDirClose(&d); return 0; }
    FsDirectoryEntry *raw = calloc((size_t)n, sizeof(*raw));
    VfsEntry *e = calloc((size_t)n, sizeof(*e));
    s64 got = 0;
    rc = raw && e ? fsDirRead(&d, &got, (size_t)n, raw) : MAKERESULT(Module_Libnx, LibnxError_OutOfMemory);
    fsDirClose(&d);
    if (R_FAILED(rc)) { free(raw); free(e); set_err("read directory", rc); return -1; }
    for (s64 i = 0; i < got; i++) {
        snprintf(e[i].name, sizeof(e[i].name), "%s", raw[i].name);
        e[i].is_dir = raw[i].type == FsDirEntryType_Dir;
        e[i].size = raw[i].file_size;
    }
    free(raw);
    *out = e;
    *count = (int)got;
    return 0;
}

int pvfs_create(VfsRoot r, const char *path, int64_t size) {
    FsFileSystem *fs = fsys(r);
    Result rc = fs ? fsFsCreateFile(fs, path, size, 0) : MAKERESULT(Module_Libnx, LibnxError_NotInitialized);
    if (R_FAILED(rc)) { set_err("create file", rc); return -1; }
    return 0;
}

PVfsFile *pvfs_open(VfsRoot r, const char *path, bool write) {
    FsFileSystem *fs = fsys(r);
    if (!fs) return NULL;
    PVfsFile *f = calloc(1, sizeof(*f));
    if (!f) return NULL;
    Result rc = fsFsOpenFile(fs, path, write ? (FsOpenMode_Read | FsOpenMode_Write | FsOpenMode_Append) : FsOpenMode_Read, &f->f);
    if (R_FAILED(rc)) { set_err("open file", rc); free(f); return NULL; }
    return f;
}

int pvfs_read(PVfsFile *f, int64_t off, void *buf, size_t n, size_t *got) {
    u64 g = 0;
    Result rc = fsFileRead(&f->f, off, buf, n, FsReadOption_None, &g);
    if (got) *got = g;
    if (R_FAILED(rc)) { set_err("read", rc); return -1; }
    return 0;
}

int pvfs_write(PVfsFile *f, int64_t off, const void *buf, size_t n) {
    Result rc = fsFileWrite(&f->f, off, buf, n, FsWriteOption_None);
    if (R_FAILED(rc)) { set_err("write", rc); return -1; }
    return 0;
}

int pvfs_flush(PVfsFile *f) { return R_SUCCEEDED(fsFileFlush(&f->f)) ? 0 : -1; }
int64_t pvfs_size(PVfsFile *f) { s64 s = -1; fsFileGetSize(&f->f, &s); return s; }
void pvfs_close(PVfsFile *f) { if (f) { fsFileClose(&f->f); free(f); } }

int vfs_mkdir(VfsRoot r, const char *path) {
    bool dir = false;
    if (pvfs_stat(r, path, &dir, NULL) == 0) return dir ? 0 : -1;
    FsFileSystem *fs = fsys(r);
    Result rc = fs ? fsFsCreateDirectory(fs, path) : MAKERESULT(Module_Libnx, LibnxError_NotInitialized);
    if (R_FAILED(rc)) { set_err("create directory", rc); return -1; }
    return 0;
}

int pvfs_delete(VfsRoot r, const char *path) {
    FsFileSystem *fs = fsys(r);
    Result rc = fs ? fsFsDeleteFile(fs, path) : MAKERESULT(Module_Libnx, LibnxError_NotInitialized);
    if (R_FAILED(rc)) { set_err("delete file", rc); return -1; }
    return 0;
}

int pvfs_rmtree(VfsRoot r, const char *path) {
    FsFileSystem *fs = fsys(r);
    Result rc = fs ? fsFsDeleteDirectoryRecursively(fs, path) : MAKERESULT(Module_Libnx, LibnxError_NotInitialized);
    if (R_FAILED(rc)) { set_err("delete directory", rc); return -1; }
    return 0;
}

int pvfs_rename(VfsRoot r, const char *from, const char *to) {
    FsFileSystem *fs = fsys(r);
    bool dir = false;
    if (!fs || pvfs_stat(r, from, &dir, NULL) != 0) { snprintf(g_err, sizeof(g_err), "rename: %s missing", from); return -1; }
    Result rc = dir ? fsFsRenameDirectory(fs, from, to) : fsFsRenameFile(fs, from, to);
    if (R_FAILED(rc)) { set_err("rename", rc); return -1; }
    return 0;
}

int64_t vfs_free_space(VfsRoot r) {
    FsFileSystem *fs = fsys(r);
    s64 s = -1;
    if (fs) fsFsGetFreeSpace(fs, "/", &s);
    return s;
}

// ---- account saves of the host title (Seedsow unless save_set_title chose another)
static uint64_t g_title = SEEDSOW_TITLE;

void save_set_title(uint64_t title) {
    if (title != g_title) save_unmount();
    g_title = title ? title : SEEDSOW_TITLE;
}

uint64_t save_title(void) { return g_title; }

int save_list_users(Uid *out, int max) { return save_list_users_of(g_title, out, max); }

int save_list_users_of(uint64_t title, Uid *out, int max) {
    FsSaveDataInfoReader reader;
    if (R_FAILED(fsOpenSaveDataInfoReader(&reader, FsSaveDataSpaceId_User))) return -1;
    int n = 0;
    FsSaveDataInfo infos[16];
    s64 total = 0;
    while (R_SUCCEEDED(fsSaveDataInfoReaderRead(&reader, infos, 16, &total)) && total > 0) {
        for (s64 i = 0; i < total && n < max; i++) {
            if (infos[i].application_id != title || infos[i].save_data_type != FsSaveDataType_Account) continue;
            memcpy(out[n++].b, &infos[i].uid, 16);
        }
    }
    fsSaveDataInfoReaderClose(&reader);
    return n;
}

// Second line of defence (model.c and users.c refuse these too): only the play user's save is ever
// mounted; save_find_files only looks whether files exist in another one, read-only. (Which user has the
// exploit save is not asked of the account service: under kaiHEN its preselected and last opened users
// are whoever last started a game.)
static Uid g_allowed;
static bool g_allowed_set;

void save_allow_only(const Uid *uid) {
    g_allowed_set = uid != NULL;
    if (uid) g_allowed = *uid;
}

static bool never_open(const Uid *uid) {
    return !g_allowed_set || memcmp(g_allowed.b, uid->b, 16) != 0;
}

int save_find_files(uint64_t title, const Uid *uid, const char *const *names, int n, char *found, size_t fn) {
    FsSaveDataAttribute attr = {0};
    attr.application_id = title;
    memcpy(&attr.uid, uid->b, 16);
    attr.save_data_type = FsSaveDataType_Account;
    FsFileSystem fs;
    Result rc = fsOpenReadOnlySaveDataFileSystem(&fs, FsSaveDataSpaceId_User, &attr);
    if (R_FAILED(rc)) { set_err("open save (read-only check)", rc); return -1; }
    int hit = 0;
    for (int i = 0; i < n && !hit; i++) {
        char path[96];
        FsDirEntryType type;
        snprintf(path, sizeof(path), "/%s", names[i]);
        if (R_SUCCEEDED(fsFsGetEntryType(&fs, path, &type)) && type == FsDirEntryType_File) {
            hit = 1;
            if (found) snprintf(found, fn, "%s", names[i]);
        }
    }
    fsFsClose(&fs);
    return hit;
}

typedef struct {
    FsFileSystem *fs;
    size_t max;
    SaveFileCheck check;
    void *ctx;
    char *found;
    size_t fn;
    int files;
} SaveWalk;

static int walk_save(SaveWalk *w, const char *dir, int depth) {
    FsDir d;
    if (R_FAILED(fsFsOpenDirectory(w->fs, dir, FsDirOpenMode_ReadDirs | FsDirOpenMode_ReadFiles, &d))) return 0;
    FsDirectoryEntry e[8];
    s64 n = 0;
    int hit = 0;
    while (!hit && w->files < 256 && R_SUCCEEDED(fsDirRead(&d, &n, 8, e)) && n > 0) {
        for (s64 i = 0; i < n && !hit && w->files < 256; i++) {
            char path[FS_MAX_PATH];
            snprintf(path, sizeof(path), "%s%s%s", dir, dir[0] && dir[strlen(dir) - 1] == '/' ? "" : "/", e[i].name);
            if (e[i].type == FsDirEntryType_Dir) {
                if (depth > 0) hit = walk_save(w, path, depth - 1);
                continue;
            }
            w->files++;
            if (e[i].file_size <= 0 || (size_t)e[i].file_size > w->max) continue;
            FsFile f;
            if (R_FAILED(fsFsOpenFile(w->fs, path, FsOpenMode_Read, &f))) continue;
            uint8_t *buf = malloc((size_t)e[i].file_size);
            u64 got = 0;
            if (buf && R_SUCCEEDED(fsFileRead(&f, 0, buf, (u64)e[i].file_size, FsReadOption_None, &got)) &&
                got == (u64)e[i].file_size && w->check(path, buf, (size_t)got, w->ctx)) {
                hit = 1;
                if (w->found) snprintf(w->found, w->fn, "%s", path);
            }
            free(buf);
            fsFileClose(&f);
        }
    }
    fsDirClose(&d);
    return hit;
}

int save_check_files(uint64_t title, const Uid *uid, const char *dir, int depth, size_t max_bytes, SaveFileCheck check,
                     void *ctx, char *found, size_t fn) {
    FsSaveDataAttribute attr = {0};
    attr.application_id = title;
    memcpy(&attr.uid, uid->b, 16);
    attr.save_data_type = FsSaveDataType_Account;
    FsFileSystem fs;
    Result rc = fsOpenReadOnlySaveDataFileSystem(&fs, FsSaveDataSpaceId_User, &attr);
    if (R_FAILED(rc)) { set_err("open save (read-only check)", rc); return -1; }
    SaveWalk w = {&fs, max_bytes, check, ctx, found, fn, 0};
    int hit = walk_save(&w, dir, depth);
    fsFsClose(&fs);
    return hit;
}

int save_mount(const Uid *uid, bool write) {
    save_unmount();
    if (never_open(uid)) { snprintf(g_err, sizeof(g_err), "refused: not the play user's save"); return -1; }
    FsSaveDataAttribute attr = {0};
    attr.application_id = g_title;
    memcpy(&attr.uid, uid->b, 16);
    attr.save_data_type = FsSaveDataType_Account;
    Result rc = write ? fsOpenSaveDataFileSystem(&g_save, FsSaveDataSpaceId_User, &attr)
                      : fsOpenReadOnlySaveDataFileSystem(&g_save, FsSaveDataSpaceId_User, &attr);
    if (R_FAILED(rc)) { set_err(write ? "open save (write)" : "open save", rc); return -1; }
    g_save_open = true;
    return 0;
}

int save_commit(void) {
    if (!g_save_open) return -1;
    Result rc = fsFsCommit(&g_save);
    if (R_FAILED(rc)) { set_err("commit save", rc); return -1; }
    return 0;
}

void save_unmount(void) {
    if (g_save_open) fsFsClose(&g_save);
    g_save_open = false;
}

// the save data ID of the allowed user's account save for the title (0: none)
static u64 save_id_of(const Uid *uid) {
    FsSaveDataInfoReader reader;
    if (R_FAILED(fsOpenSaveDataInfoReader(&reader, FsSaveDataSpaceId_User))) return 0;
    u64 id = 0;
    FsSaveDataInfo infos[16];
    s64 total = 0;
    while (!id && R_SUCCEEDED(fsSaveDataInfoReaderRead(&reader, infos, 16, &total)) && total > 0) {
        for (s64 i = 0; i < total; i++)
            if (infos[i].application_id == g_title && infos[i].save_data_type == FsSaveDataType_Account &&
                !memcmp(&infos[i].uid, uid->b, 16)) {
                id = infos[i].save_data_id;
                break;
            }
    }
    fsSaveDataInfoReaderClose(&reader);
    return id;
}

int save_get_size(const Uid *uid, int64_t *data, int64_t *journal) {
    if (never_open(uid)) { snprintf(g_err, sizeof(g_err), "refused: not the play user's save"); return -1; }
    u64 id = save_id_of(uid);
    if (!id) { snprintf(g_err, sizeof(g_err), "the play user has no save for this host"); return -1; }
    FsSaveDataExtraData extra;
    memset(&extra, 0, sizeof(extra));
    Result rc = fsReadSaveDataFileSystemExtraDataBySaveDataSpaceId(&extra, sizeof(extra), FsSaveDataSpaceId_User, id);
    if (R_FAILED(rc)) { set_err("read the save's size", rc); return -1; }
    *data = extra.data_size;
    *journal = extra.journal_size;
    return 0;
}

int save_extend(const Uid *uid, int64_t data, int64_t journal) {
    if (never_open(uid)) { snprintf(g_err, sizeof(g_err), "refused: not the play user's save"); return -1; }
    if (g_save_open) { snprintf(g_err, sizeof(g_err), "the save is open"); return -1; }
    int64_t now_d = 0, now_j = 0;
    if (save_get_size(uid, &now_d, &now_j) != 0) return -1;
    if (data < now_d || journal < now_j || (data | journal) & 0xFFFFF) {
        snprintf(g_err, sizeof(g_err), "refused: %lld + %lld is not a growth of %lld + %lld", (long long)data,
                 (long long)journal, (long long)now_d, (long long)now_j);
        return -1;
    }
    u64 id = save_id_of(uid);
    Result rc = fsExtendSaveDataFileSystem(FsSaveDataSpaceId_User, id, data, journal);
    if (R_FAILED(rc)) { set_err("ExtendSaveData", rc); return -1; }
    return 0;
}

int user_list_all(Uid *out, int max) {
    if (!g_acc_ok || max <= 0) return -1;
    AccountUid *au = calloc((size_t)max, sizeof(*au));
    s32 total = 0;
    if (!au || R_FAILED(accountListAllUsers(au, max, &total))) { free(au); return -1; }
    for (s32 i = 0; i < total && i < max; i++) memcpy(out[i].b, &au[i], 16);
    free(au);
    return total < max ? total : max;
}

bool user_name(const Uid *uid, char *out, size_t n) {
    if (!g_acc_ok) return false;
    AccountUid au;
    memcpy(&au, uid->b, 16);
    AccountProfile prof;
    if (R_FAILED(accountGetProfile(&prof, au))) return false;
    AccountProfileBase base;
    bool ok = R_SUCCEEDED(accountProfileGet(&prof, NULL, &base));
    accountProfileClose(&prof);
    if (ok) snprintf(out, n, "%s", base.nickname);
    return ok && out[0];
}

int apps_list(AppEntry *out, int max) {
    if (R_FAILED(nsInitialize())) return -1;
    NsApplicationControlData *cd = malloc(sizeof(*cd));
    NsApplicationRecord recs[32];
    int n = 0;
    for (s32 offset = 0; cd && n < max;) {
        s32 got = 0;
        if (R_FAILED(nsListApplicationRecord(recs, 32, offset, &got)) || got <= 0) break;
        for (s32 i = 0; i < got && n < max; i++) {
            AppEntry *e = &out[n++];
            e->id = recs[i].application_id;
            e->name[0] = 0;
            e->platform = -1;
            NsApplicationDeliveryInfo di;   // its platform: Switch 1 (0) or Switch 2
            s32 total = 0;
            memset(&di, 0, sizeof(di));
            if (R_SUCCEEDED(nsGetApplicationDeliveryInfo(&di, 1, e->id, 0, &total)) && total >= 1)
                e->platform = di.data.platform;
            u64 size = 0;
            if (R_FAILED(nsGetApplicationControlData(NsApplicationControlSource_Storage, e->id, cd, sizeof(*cd), &size)))
                continue;
            NacpLanguageEntry *le = NULL;   // the system language's, else another that has a name
            if (R_SUCCEEDED(nacpGetLanguageEntry(&cd->nacp, &le)) && le)
                snprintf(e->name, sizeof(e->name), "%.*s", (int)sizeof(le->name), le->name);
        }
        offset += got;
        if (got < 32) break;
    }
    free(cd);
    nsExit();
    return n;
}

// ---- Nintendo's compatibility patcher, from the console's own system
// kaiHEN gives every libounce program a clone of Loader's fsp-ldr root: as the program's "fsp-ldr"
// override, and through HEN's command 23 (GetLoaderRoot). Its command 0, OpenCodeFileSystem, opens a
// program's code the way Loader does when it starts that program; kaiHEN reads game policies the
// same way (common/policy_package.cpp). Nothing is written.
#define CMPTLDR_PROGRAM 0x0400000000000052ULL
#define HEN_GET_LOADER_ROOT 23
#define PATCHER_MAX (16u << 20)

static Result open_loader_root(Service *out, bool *owned) {
    *owned = false;
    Handle h = smGetServiceOverride(smEncodeName("fsp-ldr"));
    if (h != INVALID_HANDLE) {
        serviceCreate(out, h);
        out->own_handle = 0;   // the override belongs to hbloader's setup: never close it
        return 0;
    }
    Service ro, hen;
    Result rc = kaihenGetRoSession(&ro);
    if (R_SUCCEEDED(rc)) rc = kaihenOpenHomebrewSession(&ro, &hen);
    if (R_FAILED(rc)) return rc;
    h = INVALID_HANDLE;
    rc = serviceDispatch(&hen, HEN_GET_LOADER_ROOT,
        .out_handle_attrs = {SfOutHandleAttr_HipcCopy},
        .out_handles = &h);
    serviceClose(&hen);
    if (R_FAILED(rc)) return rc;
    serviceCreate(out, h);
    *owned = true;
    return 0;
}

int plat_read_system_patcher(uint8_t **out, size_t *size, char *err, size_t errn) {
    *out = NULL;
    *size = 0;
    Service ldr;
    bool owned = false;
    Result rc = open_loader_root(&ldr, &owned);
    if (R_FAILED(rc)) {
        snprintf(err, errn, "kaiHEN didn't give SeedSwap access to the system files (0x%x).", rc);
        return -1;
    }
    const struct {
        u8 attributes;
        u8 storage_id;
        u64 program_id;
    } in = {1, NcmStorageId_BuiltInSystem, CMPTLDR_PROGRAM};
    static u8 code_info[0x1a4];
    FsFileSystem code;
    memset(&code, 0, sizeof(code));
    rc = serviceDispatchIn(&ldr, 0, in,
        .buffer_attrs = {SfBufferAttr_HipcMapAlias | SfBufferAttr_Out},
        .buffers = {{code_info, sizeof(code_info)}},
        .out_num_objects = 1,
        .out_objects = &code.s);
    if (owned) serviceClose(&ldr);
    if (R_FAILED(rc)) {
        snprintf(err, errn, "The system's patcher couldn't be opened (0x%x).", rc);
        return -1;
    }
    FsFile f;
    rc = fsFsOpenFile(&code, "/main", FsOpenMode_Read, &f);
    if (R_FAILED(rc)) {
        fsFsClose(&code);
        snprintf(err, errn, "The system's patcher has no readable main (0x%x).", rc);
        return -1;
    }
    s64 fsize = 0;
    rc = fsFileGetSize(&f, &fsize);
    uint8_t *buf = NULL;
    if (R_SUCCEEDED(rc) && fsize > 0x100 && fsize <= (s64)PATCHER_MAX) buf = malloc((size_t)fsize);
    size_t done = 0;
    while (buf && R_SUCCEEDED(rc) && done < (size_t)fsize) {
        u64 got = 0;
        rc = fsFileRead(&f, done, buf + done, (size_t)fsize - done, FsReadOption_None, &got);
        if (R_SUCCEEDED(rc) && got == 0) rc = MAKERESULT(Module_Libnx, LibnxError_IoError);
        done += got;
    }
    fsFileClose(&f);
    fsFsClose(&code);
    if (!buf || R_FAILED(rc) || done != (size_t)fsize) {
        free(buf);
        snprintf(err, errn, "The system's patcher couldn't be read (0x%x, %lld bytes).", rc, (long long)fsize);
        return -1;
    }
    *out = buf;
    *size = done;
    return 0;
}

// ---- HOME installs: ncm on the SD card (storage 5) and ns's application records. ns command IDs on 23.0.1
// (IApplicationManagerInterface): 16 PushApplicationRecord {u8 event, 7 pad, u64 id} + in-buffer of
// {NcmContentMetaKey, u8 storage, 7 pad}; 27 DeleteApplicationRecord {u64}; 404 InvalidateApplicationControlCache
// {u64} (kernel-research/home-entries/re-scratch/out/ns-impl-table.txt). Game Vault pushes the same way.
static NcmContentStorage g_home_cs;
static NcmContentMetaDatabase g_home_db;
static Service g_home_am;
static bool g_home_open;
static char g_home_err[160];
static int home_fail(const char *what, Result rc) {
    snprintf(g_home_err, sizeof(g_home_err), "%s failed (0x%x)", what, rc);
    return rc ? (int)rc : -1;
}
const char *home_last_error(void) { return g_home_err; }

int home_sd_open(void) {
    if (g_home_open) return 0;
    Result rc = ncmInitialize();
    if (R_FAILED(rc)) return home_fail("ncm", rc);
    rc = ncmOpenContentStorage(&g_home_cs, NcmStorageId_SdCard);
    if (R_FAILED(rc)) { ncmExit(); return home_fail("open the SD card's content storage", rc); }
    rc = ncmOpenContentMetaDatabase(&g_home_db, NcmStorageId_SdCard);
    if (R_FAILED(rc)) { ncmContentStorageClose(&g_home_cs); ncmExit(); return home_fail("open the SD card's content database", rc); }
    rc = nsInitialize();
    if (R_SUCCEEDED(rc)) rc = nsGetApplicationManagerInterface(&g_home_am);
    if (R_FAILED(rc)) {
        ncmContentMetaDatabaseClose(&g_home_db); ncmContentStorageClose(&g_home_cs); ncmExit();
        return home_fail("ns", rc);
    }
    g_home_open = true;
    return 0;
}

void home_sd_close(void) {
    if (!g_home_open) return;
    serviceClose(&g_home_am);
    nsExit();
    ncmContentMetaDatabaseClose(&g_home_db);
    ncmContentStorageClose(&g_home_cs);
    ncmExit();
    g_home_open = false;
}

int home_record_exists(uint64_t app) {
    if (!g_home_open) { home_fail("content storage not open", 0); return -1; }
    NsApplicationRecord recs[32];
    for (s32 offset = 0;;) {
        s32 got = 0;
        Result rc = nsListApplicationRecord(recs, 32, offset, &got);
        if (R_FAILED(rc)) { home_fail("list the installed games", rc); return -1; }
        for (s32 i = 0; i < got; i++) if (recs[i].application_id == app) return 1;
        if (got < 32) return 0;
        offset += got;
    }
}

int home_placeholder_create(const uint8_t content[16], uint8_t placeholder_out[16], int64_t size) {
    NcmPlaceHolderId ph;
    Result rc = ncmContentStorageGeneratePlaceHolderId(&g_home_cs, &ph);
    if (R_FAILED(rc)) return home_fail("make a placeholder ID", rc);
    NcmContentId id;
    memcpy(&id, content, 16);
    rc = ncmContentStorageCreatePlaceHolder(&g_home_cs, &id, &ph, size);
    if (R_FAILED(rc)) return home_fail("create a placeholder", rc);
    memcpy(placeholder_out, &ph, 16);
    return 0;
}

int home_placeholder_write(const uint8_t placeholder[16], int64_t off, const void *buf, size_t n) {
    NcmPlaceHolderId ph;
    memcpy(&ph, placeholder, 16);
    Result rc = ncmContentStorageWritePlaceHolder(&g_home_cs, &ph, (u64)off, buf, n);
    return R_FAILED(rc) ? home_fail("write to the SD card's content storage", rc) : 0;
}

int home_placeholder_delete(const uint8_t placeholder[16]) {
    NcmPlaceHolderId ph;
    memcpy(&ph, placeholder, 16);
    Result rc = ncmContentStorageDeletePlaceHolder(&g_home_cs, &ph);
    return R_FAILED(rc) ? home_fail("delete a placeholder", rc) : 0;
}

int home_content_register(const uint8_t content[16], const uint8_t placeholder[16]) {
    NcmContentId id;
    NcmPlaceHolderId ph;
    memcpy(&id, content, 16);
    memcpy(&ph, placeholder, 16);
    bool has = false;
    if (R_SUCCEEDED(ncmContentStorageHas(&g_home_cs, &has, &id)) && has) ncmContentStorageDelete(&g_home_cs, &id);
    Result rc = ncmContentStorageRegister(&g_home_cs, &id, &ph);
    return R_FAILED(rc) ? home_fail("register the content", rc) : 0;
}

bool home_content_has(const uint8_t content[16]) {
    NcmContentId id;
    memcpy(&id, content, 16);
    bool has = false;
    return R_SUCCEEDED(ncmContentStorageHas(&g_home_cs, &has, &id)) && has;
}

int home_content_delete(const uint8_t content[16]) {
    if (!home_content_has(content)) return 0;
    NcmContentId id;
    memcpy(&id, content, 16);
    Result rc = ncmContentStorageDelete(&g_home_cs, &id);
    return R_FAILED(rc) ? home_fail("delete the content", rc) : 0;
}

int home_meta_set(const uint8_t key[16], const void *meta, size_t n) {
    NcmContentMetaKey k;
    memcpy(&k, key, 16);
    Result rc = ncmContentMetaDatabaseSet(&g_home_db, &k, meta, n);
    if (R_SUCCEEDED(rc)) rc = ncmContentMetaDatabaseCommit(&g_home_db);
    return R_FAILED(rc) ? home_fail("write the content list", rc) : 0;
}

int home_meta_remove(const uint8_t key[16]) {
    NcmContentMetaKey k;
    memcpy(&k, key, 16);
    bool has = false;
    if (R_FAILED(ncmContentMetaDatabaseHas(&g_home_db, &has, &k)) || !has) return 0;
    Result rc = ncmContentMetaDatabaseRemove(&g_home_db, &k);
    if (R_SUCCEEDED(rc)) rc = ncmContentMetaDatabaseCommit(&g_home_db);
    return R_FAILED(rc) ? home_fail("remove the content list", rc) : 0;
}

int home_record_push(uint64_t app, const uint8_t (*keys)[16], int n) {
    if (n <= 0 || n > 16) return home_fail("push the HOME record (bad count)", 0);
    struct { uint8_t key[16]; uint8_t storage; uint8_t pad[7]; } recs[16];
    memset(recs, 0, sizeof(recs));
    for (int i = 0; i < n; i++) { memcpy(recs[i].key, keys[i], 16); recs[i].storage = NcmStorageId_SdCard; }
    const struct { u8 event; u8 pad[7]; u64 app; } in = {3, {0}, app};
    Result rc = serviceDispatchIn(&g_home_am, 16, in,
        .buffer_attrs = {SfBufferAttr_HipcMapAlias | SfBufferAttr_In},
        .buffers = {{recs, sizeof(recs[0]) * (size_t)n}});
    return R_FAILED(rc) ? home_fail("push the HOME record", rc) : 0;
}

int home_record_delete(uint64_t app) {
    Result rc = serviceDispatchIn(&g_home_am, 27, app);
    return R_FAILED(rc) ? home_fail("delete the HOME record", rc) : 0;
}

int home_launch_version(uint64_t app, uint32_t version) {
    Result rc = avmInitialize();
    if (R_SUCCEEDED(rc)) {
        rc = avmPushLaunchVersion(app, version);
        avmExit();
    }
    return R_FAILED(rc) ? home_fail("set the launch version", rc) : 0;
}

int home_control_invalidate(uint64_t app) {
    Result rc = serviceDispatchIn(&g_home_am, 404, app);
    return R_FAILED(rc) ? home_fail("clear the cached name and icon", rc) : 0;
}
