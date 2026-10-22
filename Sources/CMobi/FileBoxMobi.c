#include "include/FileBoxMobi.h"
#include "mobi.h"
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>

static uint16_t be16(const unsigned char *p) { return ((uint16_t)p[0] << 8) | p[1]; }
static uint32_t be32(const unsigned char *p) { return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3]; }

// 解析前限定解压预算并检查两个版本的加密标记，不能仅凭后缀或 KF7 头允许读取 KF8。
static int check_header(FILE *file, const uint32_t *offsets, size_t count, size_t index, uint32_t *kf8) {
    if (index >= count) return FB_MOBI_INVALID;
    size_t size = offsets[index + 1] - offsets[index];
    if (size < 40 || size > 1024 * 1024) return FB_MOBI_INVALID;
    unsigned char *data = malloc(size);
    if (!data) return FB_MOBI_LIMIT;
    int result = FB_MOBI_INVALID;
    if (fseek(file, offsets[index], SEEK_SET) || fread(data, 1, size, file) != size) goto done;
    if (memcmp(data + 16, "MOBI", 4)) goto done;
    if (be16(data + 12)) { result = FB_MOBI_ENCRYPTED; goto done; }
    uint16_t text_count = be16(data + 8), record_size = be16(data + 10);
    if (!record_size || record_size > 4096 || index + text_count >= count ||
        be32(data + 4) > 64 * 1024 * 1024 || (uint64_t)text_count * record_size > 64 * 1024 * 1024) {
        result = FB_MOBI_LIMIT; goto done;
    }
    size_t header_size = be32(data + 20);
    if (header_size < 24 || header_size > size - 16) goto done;
    size_t cursor = 16 + header_size;
    if (cursor + 4 <= size && !memcmp(data + cursor, "EXTH", 4)) {
        if (cursor + 12 > size) goto done;
        size_t length = be32(data + cursor + 4), entries = be32(data + cursor + 8);
        if (length < 12 || length > size - cursor || entries > 10000) goto done;
        size_t end = cursor + length;
        cursor += 12;
        for (size_t i = 0; i < entries; i++) {
            if (cursor + 8 > end) goto done;
            uint32_t tag = be32(data + cursor), entry_size = be32(data + cursor + 4);
            if (entry_size < 8 || entry_size > end - cursor) goto done;
            if (tag == 121 && kf8) {
                if (entry_size != 12) goto done;
                *kf8 = be32(data + cursor + 8);
            }
            cursor += entry_size;
        }
    }
    result = FB_MOBI_OK;
done:
    free(data);
    return result;
}

static int preflight(FILE *file) {
    struct stat info;
    if (fstat(fileno(file), &info) || !S_ISREG(info.st_mode)) return FB_MOBI_INVALID;
    if (info.st_size < 78) return FB_MOBI_INVALID;
    if (info.st_size > 128 * 1024 * 1024) return FB_MOBI_LIMIT;
    unsigned char header[78];
    if (fread(header, 1, sizeof(header), file) != sizeof(header) || memcmp(header + 60, "BOOKMOBI", 8)) return FB_MOBI_INVALID;
    size_t count = be16(header + 76);
    if (count < 2 || count > 10000 || 78 + count * 8 >= (size_t)info.st_size) return FB_MOBI_INVALID;
    uint32_t *offsets = calloc(count + 1, sizeof(uint32_t));
    if (!offsets) return FB_MOBI_LIMIT;
    int result = FB_MOBI_INVALID;
    for (size_t i = 0; i < count; i++) {
        unsigned char entry[8];
        if (fread(entry, 1, 8, file) != 8) goto done;
        offsets[i] = be32(entry);
        if (offsets[i] < 78 + count * 8 || offsets[i] >= info.st_size || (i && offsets[i] <= offsets[i - 1])) goto done;
    }
    offsets[count] = (uint32_t)info.st_size;
    uint32_t kf8 = UINT32_MAX;
    result = check_header(file, offsets, count, 0, &kf8);
    if (result != FB_MOBI_OK) goto done;
    if (kf8 != UINT32_MAX) {
        unsigned char boundary[8];
        if (!kf8 || kf8 >= count || fseek(file, offsets[kf8 - 1], SEEK_SET) || fread(boundary, 1, 8, file) != 8 || memcmp(boundary, "BOUNDARY", 8)) {
            result = FB_MOBI_INVALID; goto done;
        }
        result = check_header(file, offsets, count, kf8, NULL);
    }
done:
    free(offsets);
    rewind(file);
    return result;
}

static int write_part(int directory, const char *name, const MOBIPart *part) {
    // O_EXCL/O_NOFOLLOW 不覆盖文件、不跟随链接；工作目录不接受书内原始路径。
    int fd = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
    if (fd < 0) return FB_MOBI_IO;
    size_t written = 0;
    while (written < part->size) {
        ssize_t size = write(fd, part->data + written, part->size - written);
        if (size <= 0) { close(fd); return FB_MOBI_IO; }
        written += (size_t)size;
    }
    return close(fd) ? FB_MOBI_IO : FB_MOBI_OK;
}

int fb_mobi_extract(const char *source, const char *path, FBMobiCancelled cancelled, void *context) {
    if (cancelled && cancelled(context)) return FB_MOBI_CANCELLED;
    int source_fd = open(source, O_RDONLY | O_NOFOLLOW);
    if (source_fd < 0) return FB_MOBI_IO;
    FILE *file = fdopen(source_fd, "rb");
    if (!file) { close(source_fd); return FB_MOBI_IO; }
    if (!file) return FB_MOBI_IO;
    int result = preflight(file);
    if (result != FB_MOBI_OK) { fclose(file); return result; }
    MOBIData *mobi = mobi_init();
    if (!mobi) { fclose(file); return FB_MOBI_LIMIT; }
    MOBI_RET loaded = mobi_load_file(mobi, file);
    fclose(file);
    MOBIRawml *raw = NULL;
    int directory = -1;
    if (loaded != MOBI_SUCCESS) { result = FB_MOBI_INVALID; goto done; }
    if (mobi_is_encrypted(mobi)) { result = FB_MOBI_ENCRYPTED; goto done; }
    if (mobi_is_replica(mobi) || mobi_is_dictionary(mobi)) { result = FB_MOBI_UNSUPPORTED; goto done; }
    if (cancelled && cancelled(context)) { result = FB_MOBI_CANCELLED; goto done; }
    raw = mobi_init_rawml(mobi);
    if (!raw) { result = FB_MOBI_LIMIT; goto done; }
    if (mobi_parse_rawml(raw, mobi) != MOBI_SUCCESS) { result = FB_MOBI_INVALID; goto done; }
    directory = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
    if (directory < 0) { result = FB_MOBI_IO; goto done; }
    MOBIPart *lists[] = { raw->markup, raw->flow ? raw->flow->next : NULL, raw->resources };
    const char *prefixes[] = { "part", "flow", "resource" };
    uint64_t total = 0;
    size_t count = 0;
    for (size_t group = 0; group < 3; group++) {
        for (MOBIPart *part = lists[group]; part; part = part->next) {
            if (cancelled && cancelled(context)) { result = FB_MOBI_CANCELLED; goto done; }
            if (++count > 10000 || part->size > 32 * 1024 * 1024 || (total += part->size) > 512 * 1024 * 1024) { result = FB_MOBI_LIMIT; goto done; }
            if (!part->size) continue;
            MOBIFileMeta meta = mobi_get_filemeta_by_type(part->type);
            char name[96];
            if (part->type == T_OPF) snprintf(name, sizeof(name), "content.opf");
            else snprintf(name, sizeof(name), "%s%05zu.%s", prefixes[group], part->uid, meta.extension);
            result = write_part(directory, name, part);
            if (result != FB_MOBI_OK) goto done;
        }
    }
done:
    if (directory >= 0) close(directory);
    if (raw) mobi_free_rawml(raw);
    mobi_free(mobi);
    return result;
}
