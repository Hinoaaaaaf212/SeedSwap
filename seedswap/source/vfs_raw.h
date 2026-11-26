// SPDX-License-Identifier: GPL-2.0-only
#pragma once
#include "platform.h"

typedef struct PVfsFile PVfsFile;

int pvfs_stat(VfsRoot r, const char *path, bool *is_dir, int64_t *size);
int pvfs_list(VfsRoot r, const char *dir, VfsEntry **out, int *count);
int pvfs_create(VfsRoot r, const char *path, int64_t size);
PVfsFile *pvfs_open(VfsRoot r, const char *path, bool write);
int pvfs_read(PVfsFile *f, int64_t off, void *buf, size_t n, size_t *got);
int pvfs_write(PVfsFile *f, int64_t off, const void *buf, size_t n);
int pvfs_flush(PVfsFile *f);
int64_t pvfs_size(PVfsFile *f);
void pvfs_close(PVfsFile *f);
int pvfs_delete(VfsRoot r, const char *path);
int pvfs_rmtree(VfsRoot r, const char *path);
int pvfs_rename(VfsRoot r, const char *from, const char *to);
const char *pvfs_last_error(void);
