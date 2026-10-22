#ifndef FILEBOX_MOBI_H
#define FILEBOX_MOBI_H
#include <stddef.h>

typedef int (*FBMobiCancelled)(void *context);
enum { FB_MOBI_OK, FB_MOBI_INVALID, FB_MOBI_ENCRYPTED, FB_MOBI_LIMIT, FB_MOBI_CANCELLED, FB_MOBI_IO, FB_MOBI_UNSUPPORTED };

/// 仅写入调用方新建的私有工作目录，资源名全部由数值 ID 生成。
int fb_mobi_extract(const char *source, const char *directory, FBMobiCancelled cancelled, void *context);

typedef struct {
    char *title;
    char **authors;
    size_t author_count;
    unsigned char *cover;
    size_t cover_size;
} FBMobiMetadata;

/// 只读取书头和明确声明的封面记录；缺少可靠封面时返回空封面，不扫描正文或猜测首张插图。
int fb_mobi_metadata(const char *source, FBMobiMetadata *metadata, FBMobiCancelled cancelled, void *context);
void fb_mobi_free_metadata(FBMobiMetadata *metadata);
#endif
