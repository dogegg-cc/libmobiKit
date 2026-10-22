#ifndef FILEBOX_MOBI_H
#define FILEBOX_MOBI_H

typedef int (*FBMobiCancelled)(void *context);
enum { FB_MOBI_OK, FB_MOBI_INVALID, FB_MOBI_ENCRYPTED, FB_MOBI_LIMIT, FB_MOBI_CANCELLED, FB_MOBI_IO, FB_MOBI_UNSUPPORTED };

/// 仅写入调用方新建的私有工作目录，资源名全部由数值 ID 生成。
int fb_mobi_extract(const char *source, const char *directory, FBMobiCancelled cancelled, void *context);
#endif
