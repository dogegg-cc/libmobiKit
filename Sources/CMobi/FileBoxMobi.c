#include "include/FileBoxMobi.h"
#include "mobi.h"
#include "read.h"
#include "util.h"
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>

// 固定上游版本提供的书头解析入口；只复用格式、编码解析，不调用会装载全书的 mobi_load_file。
MOBI_RET mobi_parse_record0(MOBIData *m, size_t seqnumber);

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

static int load_metadata_record(MOBIData *mobi, FILE *file, size_t index, size_t limit, FBMobiCancelled cancelled, void *context) {
    MOBIPdbRecord *record = mobi_get_record_by_seqnumber(mobi, index);
    struct stat info;
    if (!record || fstat(fileno(file), &info)) return FB_MOBI_INVALID;
    uint64_t end = record->next ? record->next->offset : (uint64_t)info.st_size;
    if (end <= record->offset) return FB_MOBI_INVALID;
    if (end - record->offset > limit) return FB_MOBI_LIMIT;
    if (record->data) return FB_MOBI_OK;
    record->size = (size_t)(end - record->offset);
    record->data = malloc(record->size);
    if (!record->data) return FB_MOBI_LIMIT;
    if (fseek(file, record->offset, SEEK_SET)) return FB_MOBI_IO;
    // 封面也可能较大，分块检查取消；不会顺带读出其它图片或压缩正文。
    for (size_t offset = 0; offset < record->size;) {
        if (cancelled && cancelled(context)) return FB_MOBI_CANCELLED;
        size_t length = record->size - offset;
        if (length > 64 * 1024) length = 64 * 1024;
        if (fread(record->data + offset, 1, length, file) != length) return FB_MOBI_IO;
        offset += length;
    }
    return FB_MOBI_OK;
}

void fb_mobi_free_metadata(FBMobiMetadata *metadata) {
    if (!metadata) return;
    free(metadata->title);
    for (size_t i = 0; i < metadata->author_count; i++) free(metadata->authors[i]);
    free(metadata->authors);
    free(metadata->cover);
    memset(metadata, 0, sizeof(*metadata));
}

int fb_mobi_metadata(const char *source, FBMobiMetadata *metadata, FBMobiCancelled cancelled, void *context) {
    if (!metadata) return FB_MOBI_INVALID;
    memset(metadata, 0, sizeof(*metadata));
    if (cancelled && cancelled(context)) return FB_MOBI_CANCELLED;
    int fd = open(source, O_RDONLY | O_NOFOLLOW);
    if (fd < 0) return FB_MOBI_IO;
    FILE *file = fdopen(fd, "rb");
    if (!file) { close(fd); return FB_MOBI_IO; }
    int result = preflight(file);
    MOBIData *mobi = NULL;
    if (result != FB_MOBI_OK) goto done;
    mobi = mobi_init();
    if (!mobi) { result = FB_MOBI_LIMIT; goto done; }
    // 索引节点不含负载。先保留全书相同的结构、加密与预算检查，再按记录偏移定点读取。
    if (mobi_load_pdbheader(mobi, file) != MOBI_SUCCESS || mobi->ph->rec_count < 2 || mobi->ph->rec_count > 10000 || mobi_load_reclist(mobi, file) != MOBI_SUCCESS) { result = FB_MOBI_INVALID; goto done; }
    result = load_metadata_record(mobi, file, 0, 1024 * 1024, cancelled, context);
    if (result != FB_MOBI_OK) goto done;
    if (mobi_parse_record0(mobi, 0) != MOBI_SUCCESS || !mobi->mh) { result = FB_MOBI_INVALID; goto done; }
    MOBIExthHeader *kf8 = mobi_get_exthrecord_by_tag(mobi, EXTH_KF8BOUNDARY);
    // 上游查询函数要求 BOUNDARY 负载已装入内存；预检已校验该标记，直接复用经验证的记录号。
    size_t boundary = kf8 && kf8->size == 4 && be32(kf8->data) != UINT32_MAX ? be32(kf8->data) - 1 : MOBI_NOTSET;
    if (boundary != MOBI_NOTSET) {
        result = load_metadata_record(mobi, file, boundary + 1, 1024 * 1024, cancelled, context);
        if (result != FB_MOBI_OK) goto done;
        mobi->kf8_boundary_offset = (uint32_t)boundary;
        mobi->next = mobi_init();
        if (!mobi->next) { result = FB_MOBI_LIMIT; goto done; }
        mobi->next->ph = mobi->ph;
        mobi->next->rec = mobi->rec;
        mobi->next->internals = mobi->internals;
        mobi->next->next = mobi;
        if (mobi_parse_record0(mobi->next, boundary + 1) != MOBI_SUCCESS || !mobi->next->mh || mobi_swap_mobidata(mobi) != MOBI_SUCCESS) { result = FB_MOBI_INVALID; goto done; }
    }
    if (mobi_is_dictionary(mobi)) { result = FB_MOBI_UNSUPPORTED; goto done; }
    // Print Replica 的标识只需正文首记录的四字节，不为检测类型解压或加载正文。
    if (mobi->rh && mobi->rh->compression_type == MOBI_COMPRESSION_NONE) {
        MOBIPdbRecord *first = mobi_get_record_by_seqnumber(mobi, mobi_get_kf8offset(mobi) + 1);
        unsigned char magic[4];
        if (first && fseek(file, first->offset, SEEK_SET) == 0 && fread(magic, 1, 4, file) == 4 && !memcmp(magic, REPLICA_MAGIC, 4)) { result = FB_MOBI_UNSUPPORTED; goto done; }
    }
    metadata->title = mobi_meta_get_title(mobi);
    size_t authors = 0;
    for (MOBIExthHeader *item = mobi->eh; item; item = item->next) if (item->tag == EXTH_AUTHOR) authors++;
    if (authors) {
        metadata->authors = calloc(authors, sizeof(char *));
        if (!metadata->authors) { result = FB_MOBI_LIMIT; goto done; }
        for (MOBIExthHeader *item = mobi->eh; item; item = item->next) if (item->tag == EXTH_AUTHOR) {
            char *author = mobi_decode_exthstring(mobi, item->data, item->size);
            if (author) metadata->authors[metadata->author_count++] = author;
        }
    }
    MOBIExthHeader *cover = mobi_get_exthrecord_by_tag(mobi, EXTH_COVEROFFSET);
    size_t first = mobi_get_first_resource_record(mobi);
    if (cover && cover->size == 4 && first < mobi->ph->rec_count) {
        uint32_t offset = be32(cover->data);
        // 混合文件的资源起点取 KF7 头，封面偏移取当前 KF8 元数据，与完整转换保持一致。
        if (offset < mobi->ph->rec_count - first) {
            result = load_metadata_record(mobi, file, first + offset, 32 * 1024 * 1024, cancelled, context);
            if (result != FB_MOBI_OK) goto done;
            MOBIPdbRecord *record = mobi_get_record_by_seqnumber(mobi, first + offset);
            metadata->cover = record->data;
            metadata->cover_size = record->size;
            record->data = NULL; // 所有权交给 metadata；mobi_free 仍负责其余已读取的书头。
        }
    }
    result = cancelled && cancelled(context) ? FB_MOBI_CANCELLED : FB_MOBI_OK;
done:
    if (mobi) mobi_free(mobi);
    fclose(file);
    if (result != FB_MOBI_OK) fb_mobi_free_metadata(metadata);
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
