#include "EverythingAPFS/apfs_structs.h"
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

// ============================================================================
// CRC-32C (Castagnoli polynomial 0x1EDC6F41)
// ============================================================================

static uint32_t crc32c_table[256];
static bool crc32c_table_init = false;

static void crc32c_init_table(void) {
    const uint32_t poly = 0x82F63B78;  // reflected 0x1EDC6F41
    for (uint32_t i = 0; i < 256; i++) {
        uint32_t crc = i;
        for (int j = 0; j < 8; j++) {
            crc = (crc >> 1) ^ ((crc & 1) ? poly : 0);
        }
        crc32c_table[i] = crc;
    }
    crc32c_table_init = true;
}

uint32_t apfs_crc32c(const uint8_t *data, size_t length, uint32_t crc) {
    if (!crc32c_table_init) crc32c_init_table();
    crc = ~crc;
    for (size_t i = 0; i < length; i++) {
        crc = crc32c_table[(crc ^ data[i]) & 0xFF] ^ (crc >> 8);
    }
    return ~crc;
}

// ============================================================================
// Unicode Normalization (NFD) + Case Folding
// Simplified implementation - in production use ICU or similar
// ============================================================================

// Convert UTF-8 to UTF-32 (simplified, assumes valid UTF-8)
static size_t utf8_to_utf32(const char *utf8, uint32_t *utf32, size_t max_len) {
    size_t count = 0;
    const uint8_t *p = (const uint8_t *)utf8;
    while (*p && count < max_len) {
        uint32_t cp = 0;
        if ((*p & 0x80) == 0) {
            cp = *p++;
        } else if ((*p & 0xE0) == 0xC0) {
            cp = (*p++ & 0x1F) << 6;
            cp |= *p++ & 0x3F;
        } else if ((*p & 0xF0) == 0xE0) {
            cp = (*p++ & 0x0F) << 12;
            cp |= (*p++ & 0x3F) << 6;
            cp |= *p++ & 0x3F;
        } else if ((*p & 0xF8) == 0xF0) {
            cp = (*p++ & 0x07) << 18;
            cp |= (*p++ & 0x3F) << 12;
            cp |= (*p++ & 0x3F) << 6;
            cp |= *p++ & 0x3F;
        } else {
            p++; // invalid, skip
            continue;
        }
        utf32[count++] = cp;
    }
    return count;
}

// Simple NFD decomposition (very limited - production needs ICU)
// This handles common Latin characters with combining marks
static uint32_t nfd_decompose(uint32_t cp, uint32_t *output, size_t max_out) {
    // Very limited decomposition table
    switch (cp) {
        // Precomposed Latin-1 Supplement
        case 0x00C0: output[0]=0x0041; output[1]=0x0300; return 2; // À
        case 0x00C1: output[0]=0x0041; output[1]=0x0301; return 2; // Á
        case 0x00C2: output[0]=0x0041; output[1]=0x0302; return 2; // Â
        case 0x00C3: output[0]=0x0041; output[1]=0x0303; return 2; // Ã
        case 0x00C4: output[0]=0x0041; output[1]=0x0308; return 2; // Ä
        case 0x00C5: output[0]=0x0041; output[1]=0x030A; return 2; // Å
        case 0x00C7: output[0]=0x0043; output[1]=0x0327; return 2; // Ç
        case 0x00C8: output[0]=0x0045; output[1]=0x0300; return 2; // È
        case 0x00C9: output[0]=0x0045; output[1]=0x0301; return 2; // É
        case 0x00CA: output[0]=0x0045; output[1]=0x0302; return 2; // Ê
        case 0x00CB: output[0]=0x0045; output[1]=0x0308; return 2; // Ë
        case 0x00CC: output[0]=0x0049; output[1]=0x0300; return 2; // Ì
        case 0x00CD: output[0]=0x0049; output[1]=0x0301; return 2; // Í
        case 0x00CE: output[0]=0x0049; output[1]=0x0302; return 2; // Î
        case 0x00CF: output[0]=0x0049; output[1]=0x0308; return 2; // Ï
        case 0x00D1: output[0]=0x004E; output[1]=0x0303; return 2; // Ñ
        case 0x00D2: output[0]=0x004F; output[1]=0x0300; return 2; // Ò
        case 0x00D3: output[0]=0x004F; output[1]=0x0301; return 2; // Ó
        case 0x00D4: output[0]=0x004F; output[1]=0x0302; return 2; // Ô
        case 0x00D5: output[0]=0x004F; output[1]=0x0303; return 2; // Õ
        case 0x00D6: output[0]=0x004F; output[1]=0x0308; return 2; // Ö
        case 0x00D9: output[0]=0x0055; output[1]=0x0300; return 2; // Ù
        case 0x00DA: output[0]=0x0055; output[1]=0x0301; return 2; // Ú
        case 0x00DB: output[0]=0x0055; output[1]=0x0302; return 2; // Û
        case 0x00DC: output[0]=0x0055; output[1]=0x0308; return 2; // Ü
        case 0x00DD: output[0]=0x0059; output[1]=0x0301; return 2; // Ý
        case 0x00E0: output[0]=0x0061; output[1]=0x0300; return 2; // à
        case 0x00E1: output[0]=0x0061; output[1]=0x0301; return 2; // á
        case 0x00E2: output[0]=0x0061; output[1]=0x0302; return 2; // â
        case 0x00E3: output[0]=0x0061; output[1]=0x0303; return 2; // ã
        case 0x00E4: output[0]=0x0061; output[1]=0x0308; return 2; // ä
        case 0x00E5: output[0]=0x0061; output[1]=0x030A; return 2; // å
        case 0x00E7: output[0]=0x0063; output[1]=0x0327; return 2; // ç
        case 0x00E8: output[0]=0x0065; output[1]=0x0300; return 2; // è
        case 0x00E9: output[0]=0x0065; output[1]=0x0301; return 2; // é
        case 0x00EA: output[0]=0x0065; output[1]=0x0302; return 2; // ê
        case 0x00EB: output[0]=0x0065; output[1]=0x0308; return 2; // ë
        case 0x00EC: output[0]=0x0069; output[1]=0x0300; return 2; // ì
        case 0x00ED: output[0]=0x0069; output[1]=0x0301; return 2; // í
        case 0x00EE: output[0]=0x0069; output[1]=0x0302; return 2; // î
        case 0x00EF: output[0]=0x0069; output[1]=0x0308; return 2; // ï
        case 0x00F1: output[0]=0x006E; output[1]=0x0303; return 2; // ñ
        case 0x00F2: output[0]=0x006F; output[1]=0x0300; return 2; // ò
        case 0x00F3: output[0]=0x006F; output[1]=0x0301; return 2; // ó
        case 0x00F4: output[0]=0x006F; output[1]=0x0302; return 2; // ô
        case 0x00F5: output[0]=0x006F; output[1]=0x0303; return 2; // õ
        case 0x00F6: output[0]=0x006F; output[1]=0x0308; return 2; // ö
        case 0x00F9: output[0]=0x0075; output[1]=0x0300; return 2; // ù
        case 0x00FA: output[0]=0x0075; output[1]=0x0301; return 2; // ú
        case 0x00FB: output[0]=0x0075; output[1]=0x0302; return 2; // û
        case 0x00FC: output[0]=0x0075; output[1]=0x0308; return 2; // ü
        case 0x00FD: output[0]=0x0079; output[1]=0x0301; return 2; // ý
        case 0x00FF: output[0]=0x0079; output[1]=0x0308; return 2; // ÿ
        default:
            output[0] = cp;
            return 1;
    }
}

// Simple case folding (ASCII only - production needs full Unicode)
static uint32_t case_fold(uint32_t cp) {
    if (cp >= 0x41 && cp <= 0x5A) return cp + 0x20;  // A-Z -> a-z
    // Latin-1 Supplement uppercase
    if (cp >= 0xC0 && cp <= 0xDE && cp != 0xD7) return cp + 0x20;
    return cp;
}

// ============================================================================
// Directory Record Hash Computation
// ============================================================================

uint32_t apfs_drec_compute_hash(const char *utf8_name) {
    // Step 1: UTF-8 -> UTF-32
    uint32_t utf32[1024];
    size_t utf32_len = utf8_to_utf32(utf8_name, utf32, 1024);
    
    // Step 2: NFD + case fold
    uint32_t normalized[4096];
    size_t norm_len = 0;
    for (size_t i = 0; i < utf32_len && norm_len < 4096; i++) {
        uint32_t folded = case_fold(utf32[i]);
        uint32_t decomp[4];
        size_t dlen = nfd_decompose(folded, decomp, 4);
        for (size_t j = 0; j < dlen && norm_len < 4096; j++) {
            normalized[norm_len++] = decomp[j];
        }
    }
    
    // Step 3: Convert to UTF-32LE bytes (no null terminator)
    uint8_t bytes[16384];
    size_t byte_len = 0;
    for (size_t i = 0; i < norm_len; i++) {
        uint32_t cp = normalized[i];
        bytes[byte_len++] = (uint8_t)(cp & 0xFF);
        bytes[byte_len++] = (uint8_t)((cp >> 8) & 0xFF);
        bytes[byte_len++] = (uint8_t)((cp >> 16) & 0xFF);
        bytes[byte_len++] = (uint8_t)((cp >> 24) & 0xFF);
    }
    
    // Step 4: CRC-32C with initial value 0xFFFFFFFF
    uint32_t crc = apfs_crc32c(bytes, byte_len, 0xFFFFFFFF);
    
    // Step 5: Complement
    crc ^= 0xFFFFFFFF;
    
    // Step 6: Low 22 bits
    return crc & 0x3FFFFF;
}

// ============================================================================
// Record Parsing
// ============================================================================

void apfs_parse_inode(const uint8_t *data, size_t length, apfs_inode_parsed_t *out) {
    const j_inode_val_t *val = (const j_inode_val_t *)data;
    out->parent_id = APFS_READ_LE64(&val->parent_id);
    out->private_id = APFS_READ_LE64(&val->private_id);
    out->create_time = APFS_READ_LE64(&val->create_time);
    out->mod_time = APFS_READ_LE64(&val->mod_time);
    out->change_time = APFS_READ_LE64(&val->change_time);
    out->access_time = APFS_READ_LE64(&val->access_time);
    out->internal_flags = APFS_READ_LE64(&val->internal_flags);
    out->nlink = (int32_t)APFS_READ_LE32(&val->nlink);
    out->write_generation_counter = APFS_READ_LE32(&val->write_generation_counter);
    out->bsd_flags = APFS_READ_LE32(&val->bsd_flags);
    out->owner = APFS_READ_LE32(&val->owner);
    out->group = APFS_READ_LE32(&val->group);
    out->mode = APFS_READ_LE16(&val->mode);
    out->uncompressed_size = APFS_READ_LE64(&val->uncompressed_size);
}

void apfs_parse_drec(const j_drec_hashed_key_t *key, const j_drec_val_t *val, apfs_drec_parsed_t *out) {
    out->parent_inode = APFS_KEY_OBJ_ID(&key->hdr);
    out->file_id = APFS_READ_LE64(&val->file_id);
    out->date_added = APFS_READ_LE64(&val->date_added);
    out->flags = APFS_READ_LE16(&val->flags);
    
    // Extract name (follows the key struct)
    uint16_t name_len = APFS_DREC_NAME_LEN(key);
    const char *name_start = (const char *)(key + 1);
    out->name = malloc(name_len + 1);
    memcpy(out->name, name_start, name_len);
    out->name[name_len] = '\0';
}

void apfs_parse_file_extent(const j_file_extent_key_t *key, const j_file_extent_val_t *val, apfs_file_extent_parsed_t *out) {
    out->logical_addr = APFS_READ_LE64(&key->logical_addr);
    out->phys_addr = APFS_READ_LE64(&val->phys_addr);
    out->length = APFS_READ_LE64(&val->length);
    out->flags = APFS_READ_LE32(&val->flags);
    out->crypto_id = APFS_READ_LE32(&val->crypto_id);
}

// Parse extended fields blob
size_t apfs_parse_xfields(const uint8_t *data, size_t length, apfs_xfield_parsed_t **out_fields) {
    if (length < sizeof(xf_blob_t)) return 0;
    
    const xf_blob_t *blob = (const xf_blob_t *)data;
    uint16_t num_exts = APFS_READ_LE16(&blob->xf_num_exts);
    uint16_t used_data = APFS_READ_LE16(&blob->xf_used_data);
    
    const x_field_t *fields = (const x_field_t *)(blob->xf_data);
    const uint8_t *field_data = blob->xf_data + num_exts * sizeof(x_field_t);
    
    // Align to 8 bytes
    field_data = (const uint8_t *)(((uintptr_t)field_data + 7) & ~7);
    
    *out_fields = calloc(num_exts, sizeof(apfs_xfield_parsed_t));
    
    size_t offset = 0;
    for (uint16_t i = 0; i < num_exts; i++) {
        (*out_fields)[i].type = fields[i].x_type;
        (*out_fields)[i].flags = fields[i].x_flags;
        (*out_fields)[i].size = APFS_READ_LE16(&fields[i].x_size);
        
        if ((*out_fields)[i].size > 0) {
            (*out_fields)[i].data = malloc((*out_fields)[i].size);
            memcpy((*out_fields)[i].data, field_data + offset, (*out_fields)[i].size);
        } else {
            (*out_fields)[i].data = NULL;
        }
        
        offset += (*out_fields)[i].size;
        // Align next field
        offset = (offset + 7) & ~7;
    }
    
    return num_exts;
}

void apfs_free_xfields(apfs_xfield_parsed_t *fields, size_t count) {
    for (size_t i = 0; i < count; i++) {
        free(fields[i].data);
    }
    free(fields);
}

void apfs_free_drec(apfs_drec_parsed_t *drec) {
    free(drec->name);
}

// ============================================================================
// B-Tree Node Parsing (simplified)
// ============================================================================

typedef struct {
    uint8_t *data;
    size_t length;
    size_t offset;
} apfs_btree_cursor_t;

bool apfs_btree_cursor_init(apfs_btree_cursor_t *cursor, uint8_t *data, size_t length) {
    cursor->data = data;
    cursor->length = length;
    cursor->offset = 0;
    return true;
}

// B-tree node header (simplified)
typedef struct {
    uint32_t type;          // 0 = internal, 1 = leaf
    uint32_t flags;
    uint64_t parent_oid;
    uint32_t num_keys;
    uint32_t max_keys;
} apfs_btree_node_header_t;

bool apfs_btree_parse_node(apfs_btree_cursor_t *cursor, apfs_btree_node_header_t *header) {
    if (cursor->offset + sizeof(apfs_btree_node_header_t) > cursor->length) return false;
    // Simplified - real implementation parses actual node header
    return true;
}

#ifdef __cplusplus
}
#endif