// SPDX-License-Identifier: GPL-2.0-only
// Nintendo's compatibility patches for the games in the SeedSwap library.
//
// On Switch 2 the system patches every Switch 1 game when it starts, chosen by the game's program
// ID. A game hosted under Seedsow's ID gets Seedsow's treatment, which is none. SeedSwap runs the
// console's own patcher (a copy of its file on the SD card, see COMPAT_PATCHER) on the game's code
// with the game's real ID and stores the result in the game's exefs.nsp. See compat/cmpt.h.
#pragma once
#include "util.h"

// The system patcher: the `main` file of system program 0400000000000052 (cmptldr), copied from the
// console's own system by compat_ensure_patcher. Without it SeedSwap applies nothing.
#define COMPAT_PATCHER SS_ROOT "/system/cmptldr.nso"
// Present while a copy is under way: a copy that never finished (SeedSwap closed or crashed) is not
// tried again at start, only when asked for.
#define COMPAT_PATCHER_TRY SS_ROOT "/system/cmptldr.try"
// The game image as it was before patching, kept once per game in its SeedSwap folder.
#define COMPAT_ORIGINAL "exefs-nocompat.nsp"

typedef enum {
    COMPAT_ST_UNKNOWN,     // not looked at yet (or the game's files changed since)
    COMPAT_ST_NO_PATCHER,  // COMPAT_PATCHER is not on the SD card
    COMPAT_ST_NONE,        // Nintendo's patcher changes nothing in this game
    COMPAT_ST_PENDING,     // it would change something; not applied
    COMPAT_ST_APPLIED,     // applied
    COMPAT_ST_FAILED,      // could not be worked out or applied; see note
} CompatState;

typedef struct {
    CompatState state;
    int changes;           // instructions changed (applied) or to change (pending)
    int width;             // 32 or 64, 0 if unknown
    char version[16];      // the patcher's system version
    char note[200];        // why it failed
    bool have_original;    // COMPAT_ORIGINAL exists, so the patches can be removed
} CompatInfo;

bool compat_patcher_present(void);
// Copies the patcher from the console's system to COMPAT_PATCHER if it isn't there yet: read through
// Loader (plat_read_system_patcher), checked to be a build SeedSwap knows, written beside, read back
// and renamed into place. at_start: skip it if an earlier copy never finished. true = it is there.
bool compat_ensure_patcher(bool at_start, char *err, size_t errn);
// What is recorded for a game, if it still describes the exefs.nsp at exefs_path. Cheap.
void compat_load(const char *exefs_path, const char *game_dir, CompatInfo *out);
// Runs the patcher on the game. With apply, a game that needs patches gets them: the new image is
// written beside the old one, read back, and swapped in; the old one is kept as COMPAT_ORIGINAL.
// Returns false (with err) when it could not finish; the game's files are then as they were.
bool compat_run(const char *exefs_path, const char *game_dir, uint64_t program_id, bool apply, CompatInfo *out,
                ProgressFn cb, char *err, size_t errn);
// The fingerprint compat.ini records for an image (its size, file table and main's NSO header).
bool compat_image_key(const char *exefs_path, char out[17]);
// When another module of the image changed (add-on content in sdk), main and so the patches are the
// same: compat.ini keeps its state and gets the new image's fingerprint, if it described old_key.
bool compat_rekey(const char *game_dir, const char *old_key, const char *new_key);
// Puts COMPAT_ORIGINAL back as the game's exefs.nsp.
bool compat_revert(const char *exefs_path, const char *game_dir, CompatInfo *out, char *err, size_t errn);
