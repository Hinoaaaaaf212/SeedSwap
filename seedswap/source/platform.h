// SPDX-License-Identifier: GPL-2.0-only
// SeedSwap platform layer: display, input, files (SD card and the Seedsow
// save), users, time. Two backends: plat_switch.c (kaiHEN, libounce) and
// plat_host.c (PC preview: PNG frames, scripted input, plain directories).
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define SCREEN_W 1280
#define SCREEN_H 720

typedef struct {
    uint32_t *px;   // RGBA8888 in memory order R,G,B,A (u32 little endian: A<<24|B<<16|G<<8|R)
    int w, h, stride;  // stride in pixels
} Canvas;

// ---- lifecycle / display / input
bool plat_init(void);
void plat_exit(void);
bool plat_loop(void);              // false when the app should quit (applet exit)
Canvas *plat_frame_begin(void);
void plat_frame_end(void);
uint64_t plat_buttons_down(void);  // edge-triggered, with auto-repeat for directions
uint64_t plat_buttons_held(void);
uint64_t plat_ms(void);            // monotonic milliseconds
void plat_sleep_ms(int ms);
void plat_keep_awake(bool on);      // no auto-sleep while a long job (a conversion) runs
// During a long job that can be stopped: keeps the system's HOME handling going and returns true
// once B is pressed (or the app has to close).
bool plat_poll_stop(void);
bool plat_now(char *out, size_t n, bool compact);  // local time "2026-11-20 18:40" / "20261120T184000"

enum {
    BTN_A = 1 << 0, BTN_B = 1 << 1, BTN_X = 1 << 2, BTN_Y = 1 << 3,
    BTN_L = 1 << 4, BTN_R = 1 << 5, BTN_ZL = 1 << 6, BTN_ZR = 1 << 7,
    BTN_PLUS = 1 << 8, BTN_MINUS = 1 << 9,
    BTN_UP = 1 << 10, BTN_DOWN = 1 << 11, BTN_LEFT = 1 << 12, BTN_RIGHT = 1 << 13,
};

// ---- files
typedef enum { VFS_SD = 0, VFS_SAVE = 1 } VfsRoot;
typedef struct { char name[256]; bool is_dir; int64_t size; } VfsEntry;
typedef struct VfsFile VfsFile;

int vfs_stat(VfsRoot r, const char *path, bool *is_dir, int64_t *size);   // 0 = exists
int vfs_list(VfsRoot r, const char *dir, VfsEntry **out, int *count);      // caller frees *out
int vfs_create(VfsRoot r, const char *path, int64_t size);
VfsFile *vfs_open(VfsRoot r, const char *path, bool write);
int vfs_read(VfsFile *f, int64_t off, void *buf, size_t n, size_t *got);
int vfs_write(VfsFile *f, int64_t off, const void *buf, size_t n);
int vfs_flush(VfsFile *f);
int64_t vfs_size(VfsFile *f);
void vfs_close(VfsFile *f);
int vfs_mkdir(VfsRoot r, const char *path);              // 0 if it exists already
int vfs_delete(VfsRoot r, const char *path);             // file
int vfs_rmtree(VfsRoot r, const char *path);             // directory, recursively
int vfs_rename(VfsRoot r, const char *from, const char *to);  // file or directory, same root
int64_t vfs_free_space(VfsRoot r);
const char *vfs_last_error(void);

// ---- the account save of one user for the host title (Seedsow 0100ee5021c9e000 unless
// save_set_title chose another host), mounted as VFS_SAVE
#define SEEDSOW_TITLE 0x0100ee5021c9e000ULL
#define SEEDSOW_DEMO_TITLE 0x010042d022aea000ULL  // the demo, which can hold the exploit save too
// The title whose saves the calls below open (unmounts a save that is open). Seedsow until set.
void save_set_title(uint64_t title);
uint64_t save_title(void);
typedef struct { uint8_t b[16]; } Uid;
int save_list_users(Uid *out, int max);       // users that have an account save for the title
int save_list_users_of(uint64_t title, Uid *out, int max);  // the same for another title (nothing unmounted)
int user_list_all(Uid *out, int max);
// The only user whose Seedsow save save_mount opens (NULL: none).
void save_allow_only(const Uid *uid);
// Whether a user's save of `title` (Seedsow or its demo, whatever save_set_title chose) has one of these
// files at its root: opened read-only, nothing read but whether the names exist, closed again. The one
// look into a save that isn't the play user's: it finds the user with the exploit save (users.c).
// 1 = found (found = the name), 0 = none of them, -1 = the save couldn't be opened.
int save_find_files(uint64_t title, const Uid *uid, const char *const *names, int n, char *found, size_t fn);
// The other look into such a save: small files under `dir` (down to `depth` folder levels, each at most
// max_bytes, at most 256 files) are read, read-only, and check() is asked about each. It finds the user
// with ns2jb's SmileBASIC bootstrap (users.c). 1 = check() said yes (found = that file's path),
// 0 = no file did, -1 = the save couldn't be opened.
#define SMILEBASIC_TITLE 0x0100c9100b06a000ULL
#define SMILEBASIC_DEMO_TITLE 0x0100b4b00f9f6000ULL
typedef bool (*SaveFileCheck)(const char *path, const uint8_t *data, size_t n, void *ctx);
int save_check_files(uint64_t title, const Uid *uid, const char *dir, int depth, size_t max_bytes, SaveFileCheck check,
                     void *ctx, char *found, size_t fn);
int save_mount(const Uid *uid, bool write);
int save_commit(void);
void save_unmount(void);
// The save's size: data and journal in bytes (the journal bounds what one commit may write). Only the
// allowed user's; the save must not be mounted.
int save_get_size(const Uid *uid, int64_t *data, int64_t *journal);
// Grow it (fsp-srv ExtendSaveDataFileSystem). Sizes are multiples of 1 MiB and never smaller than now:
// a save can't shrink.
int save_extend(const Uid *uid, int64_t data, int64_t journal);
bool user_name(const Uid *uid, char *out, size_t n);  // profile nickname, false if unknown

// ---- installed games: the console's application records with their names (the PC preview reads
// SEEDSWAP_APPS, "id=name,id=name"). -1 when the console can't tell.
// platform: the game's content platform from ns (ApplicationDeliveryInfo, 20.0.0+): 0 = Switch 1 (Nx),
// above 0 = another (Switch 2), -1 = not known (the PC preview: SEEDSWAP_SWITCH2 lists Switch 2 IDs).
typedef struct { uint64_t id; char name[64]; int platform; } AppEntry;
int apps_list(AppEntry *out, int max);

// The `main` file of system program 0400000000000052 (cmptldr, Nintendo's compatibility patcher),
// read from the console's own system the way Loader reads it to start the program. Read-only.
// 0 = *out holds *size bytes (caller frees); -1 = err says why.
int plat_read_system_patcher(uint8_t **out, size_t *size, char *err, size_t errn);

// ---- HOME installs (home.c): a game's own content on the SD card through ncm (storage 5), its content
// lists in ncm's SD database and its application record in ns, as a normal install has them. IDs are the
// raw 16-byte ncm forms: content and placeholder IDs, and NcmContentMetaKey {u64 id, u32 version, u8 type,
// u8 install type, 2 padding}. 0 = done; otherwise a nonzero code (the result) and home_last_error() says why.
// The PC preview keeps them as files under SEEDSWAP_HOME (no such folder: every call fails).
int home_sd_open(void);                    // opens the SD storage and its database; before the others
void home_sd_close(void);
// 1 = ns has an application record for the ID (an installed game, SeedSwap's or not), 0 = none, <0 = error
int home_record_exists(uint64_t app);
int home_placeholder_create(const uint8_t content[16], uint8_t placeholder_out[16], int64_t size);
int home_placeholder_write(const uint8_t placeholder[16], int64_t off, const void *buf, size_t n);
int home_placeholder_delete(const uint8_t placeholder[16]);
int home_content_register(const uint8_t content[16], const uint8_t placeholder[16]);
int home_content_delete(const uint8_t content[16]);        // 0 also when it isn't there
bool home_content_has(const uint8_t content[16]);
int home_meta_set(const uint8_t key[16], const void *meta, size_t n);   // and commit
int home_meta_remove(const uint8_t key[16]);                            // and commit; 0 if it isn't there
// keys: the meta keys in the database; records: {key, u8 storage, 7 padding} as ns takes them
int home_record_push(uint64_t app, const uint8_t (*keys)[16], int n);
int home_record_delete(uint64_t app);
int home_launch_version(uint64_t app, uint32_t version);   // avm: the version the game may start at
int home_control_invalidate(uint64_t app);                  // ns drops its cached name and icon
const char *home_last_error(void);
