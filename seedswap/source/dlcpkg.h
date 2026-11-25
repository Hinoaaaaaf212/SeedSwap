// SPDX-License-Identifier: GPL-2.0-only
// Reads add-on content (DLC) from the user's own .nsp dump: the content list, the ticket, and the
// DLC's RomFS image, decrypted and checked block by block against the dump's own hash tree.
// Plain C with no platform calls (the file is read through a callback), so the PC tests run it too.
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// 0 when all n bytes at off were read
typedef int (*DlcReadFn)(void *user, uint64_t off, void *buf, size_t n);

#ifndef DLCPKG_MAX_IMAGE   // smaller in a test build, to send small packs down the big-content path
#define DLCPKG_MAX_IMAGE (64u * 1024 * 1024)  // add-on content held in memory (unlock-style content)
#endif
#define DLCPKG_MAX_STREAM (32ull << 30)        // bigger content is copied from its dump (dlcpkg_copy)
#define DLCPKG_MAX_HASHES (64u * 1024 * 1024) // the hash levels of streamed content, held in memory

typedef struct DlcStream DlcStream;

typedef struct {
    uint64_t title_id;            // the add-on content's ID
    uint64_t application_id;      // the game it belongs to
    uint32_t version;             // its version
    uint32_t required_version;    // the oldest game version it works with
    int key_generation;
    uint8_t *image;               // its RomFS image (malloc'd), as the game would mount it; NULL when streamed
    size_t image_size;
    DlcStream *stream;            // a big image: not in memory, read from the dump with dlcpkg_copy
    char data_nca[40];
    bool is_signed;               // both NCA headers carry Nintendo's signature (dumpcheck.h)
} DlcPackage;

// Returns true and fills out, or false with a plain sentence in err (the dump cannot be used, and why).
bool dlcpkg_read(DlcReadFn read, void *user, uint64_t size, const char *keys_text, DlcPackage *out, char *err,
                 size_t errn);
void dlcpkg_free(DlcPackage *p);

// 0 when all n bytes were written at off
typedef int (*DlcWriteFn)(void *user, uint64_t off, const void *buf, size_t n);
// false stops the copy
typedef bool (*DlcProgressFn)(void *user, uint64_t done, uint64_t total);
// A streamed image (p->stream): read from the dump again through `read` (the same file dlcpkg_read was
// given), every block decrypted and checked against the dump's hash tree, written at `to` + offset
// through `write`; sha_out is the SHA-256 of the whole image. False with a sentence in err.
bool dlcpkg_copy(const DlcPackage *p, DlcReadFn read, void *user, DlcWriteFn write, void *wuser, uint64_t to,
                 uint8_t sha_out[32], DlcProgressFn progress, void *puser, char *err, size_t errn);
