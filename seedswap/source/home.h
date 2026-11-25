// SPDX-License-Identifier: GPL-2.0-only
// A game dump installed as a real console title, with its own HOME menu icon. The dump's NCAs go to
// the SD card through ncm as they are, except the header of an NCA that has a title key (moved into
// its key area, as a standard-crypto NCA) or the cartridge mark; content lists go to ncm's database
// and the record to ns. FS's header signature check has to be off (loader --sig-patch), and Loader
// gets the original header's signature from /ns2jb-modloader/codeinfo/<program>.bin.
// SeedSwap never installs over a title it did not install; its own installs are listed in
// SD:/seedswap/home/<app>.ini, which is what home_remove undoes.
#pragma once
#include <stdbool.h>
#include <stdint.h>

#include "util.h"

#define HOME_DIR SS_ROOT "/home"
#define HOME_CODEINFO_DIR "/ns2jb-modloader/codeinfo"
#define HOME_MAX_INSTALLS 64

typedef struct {
    uint64_t app_id;
    uint32_t version;          // the newest installed (the update's when there is one)
    char name[128];
    char display_version[32];   // the game's own version text ("1.4.1"); may be empty
    int contents;              // NCAs installed
    int64_t bytes;
    int converted;             // NCAs whose title key was put into the key area
    int code_infos;            // Program NCAs Loader needs the original signature for
    bool complete;             // false: an install that stopped part way (remove it)
} HomeInstall;

// What installing would take, without writing anything. False with a sentence in err when it cannot be done.
bool home_check(const char *base_path, const char *update_path, const char *keys_path, HomeInstall *out, char *err,
                size_t errn);
// Installs a base game dump (and its update, may be NULL or "") as a console title. Stops when cb returns
// false; everything written so far is then removed again.
bool home_install(const char *base_path, const char *update_path, const char *keys_path, ProgressFn cb,
                  HomeInstall *out, char *err, size_t errn);
// SeedSwap's own installs (from SD:/seedswap/home), at most max.
int home_list(HomeInstall *out, int max);
bool home_is_ours(uint64_t app);
// Removes one of SeedSwap's installs: record, content lists, NCAs, code info files.
bool home_remove(uint64_t app, char *err, size_t errn);
