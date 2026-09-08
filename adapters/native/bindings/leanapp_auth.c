#include <lean/lean.h>
#include <openssl/crypto.h>
#include <openssl/err.h>
#include <openssl/evp.h>
#include <openssl/rand.h>
#include <openssl/opensslv.h>
#include <stdint.h>
#include <string.h>

#if OPENSSL_VERSION_MAJOR < 3
#error "LeanApp authentication requires OpenSSL 3 or later"
#endif

#define INPUT_MAX 1024u
#define SALT_BYTES 16u
#define KEY_BYTES 32u
#define SCRYPT_N UINT64_C(131072)
#define SCRYPT_MAXMEM (UINT64_C(256) * 1024 * 1024)
static const char prefix[] = "$leanapp$scrypt$v1$N=131072$r=8$p=1$";
#define PREFIX_LEN (sizeof(prefix) - 1)
#define RECORD_LEN (PREFIX_LEN + SALT_BYTES * 2 + 1 + KEY_BYTES * 2)

static lean_obj_res failure(void) {
    ERR_clear_error();
    return lean_io_result_mk_error(lean_mk_io_error_other_error(
        0, lean_mk_string("authentication crypto operation failed")));
}
static int ready(void) {
    ERR_clear_error();
    return OPENSSL_version_major() >= 3;
}
static size_t bytes(b_lean_obj_arg s) { return lean_string_size(s) - 1; }
static lean_obj_res boolean(int value) {
    return lean_io_result_mk_ok(lean_box(value ? 1 : 0));
}
static void hex_encode(const unsigned char *src, size_t n, char *dst) {
    static const char hex[] = "0123456789abcdef";
    for (size_t i = 0; i < n; ++i) {
        dst[2*i] = hex[src[i] >> 4];
        dst[2*i+1] = hex[src[i] & 15];
    }
}
static int nibble(unsigned char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    return -1;
}
static int hex_decode(const char *src, size_t n, unsigned char *dst) {
    for (size_t i = 0; i < n; ++i) {
        int hi = nibble((unsigned char)src[2*i]);
        int lo = nibble((unsigned char)src[2*i+1]);
        if (hi < 0 || lo < 0) return 0;
        dst[i] = (unsigned char)((hi << 4) | lo);
    }
    return 1;
}
static int derive(b_lean_obj_arg password, const unsigned char *salt, unsigned char *key) {
    return EVP_PBE_scrypt(lean_string_cstr(password), bytes(password), salt, SALT_BYTES,
        SCRYPT_N, 8, 1, SCRYPT_MAXMEM, key, KEY_BYTES) == 1;
}

LEAN_EXPORT lean_obj_res leanapp_auth_hash_password(b_lean_obj_arg password, lean_obj_arg world) {
    (void)world;
    if (!ready() || bytes(password) == 0 || bytes(password) > INPUT_MAX) return failure();
    unsigned char salt[SALT_BYTES] = {0}, key[KEY_BYTES] = {0};
    char record[RECORD_LEN + 1] = {0};
    lean_obj_res result;
    if (RAND_bytes(salt, SALT_BYTES) != 1 || !derive(password, salt, key)) {
        result = failure();
    } else {
        memcpy(record, prefix, PREFIX_LEN);
        hex_encode(salt, SALT_BYTES, record + PREFIX_LEN);
        record[PREFIX_LEN + SALT_BYTES * 2] = '$';
        hex_encode(key, KEY_BYTES, record + PREFIX_LEN + SALT_BYTES * 2 + 1);
        result = lean_io_result_mk_ok(lean_mk_string_from_bytes(record, RECORD_LEN));
    }
    OPENSSL_cleanse(salt, sizeof(salt));
    OPENSSL_cleanse(key, sizeof(key));
    OPENSSL_cleanse(record, sizeof(record));
    return result;
}

LEAN_EXPORT lean_obj_res leanapp_auth_verify_password(b_lean_obj_arg password,
        b_lean_obj_arg encoded, lean_obj_arg world) {
    (void)world;
    if (!ready()) return failure();
    if (bytes(password) == 0 || bytes(password) > INPUT_MAX || bytes(encoded) != RECORD_LEN)
        return boolean(0);
    const char *record = lean_string_cstr(encoded);
    if (memcmp(record, prefix, PREFIX_LEN) != 0 || record[PREFIX_LEN + SALT_BYTES * 2] != '$')
        return boolean(0);
    unsigned char salt[SALT_BYTES] = {0}, expected[KEY_BYTES] = {0}, actual[KEY_BYTES] = {0};
    lean_obj_res result;
    if (!hex_decode(record + PREFIX_LEN, SALT_BYTES, salt) ||
        !hex_decode(record + PREFIX_LEN + SALT_BYTES * 2 + 1, KEY_BYTES, expected)) {
        result = boolean(0);
    } else if (!derive(password, salt, actual)) {
        result = failure();
    } else {
        result = boolean(CRYPTO_memcmp(actual, expected, KEY_BYTES) == 0);
    }
    OPENSSL_cleanse(salt, sizeof(salt));
    OPENSSL_cleanse(expected, sizeof(expected));
    OPENSSL_cleanse(actual, sizeof(actual));
    return result;
}

LEAN_EXPORT lean_obj_res leanapp_auth_random_token(lean_obj_arg world) {
    (void)world;
    if (!ready()) return failure();
    unsigned char random[32] = {0};
    char text[64] = {0};
    lean_obj_res result;
    if (RAND_bytes(random, sizeof(random)) != 1) result = failure();
    else {
        hex_encode(random, sizeof(random), text);
        result = lean_io_result_mk_ok(lean_mk_string_from_bytes(text, sizeof(text)));
    }
    OPENSSL_cleanse(random, sizeof(random));
    OPENSSL_cleanse(text, sizeof(text));
    return result;
}

LEAN_EXPORT lean_obj_res leanapp_auth_digest_token(b_lean_obj_arg token, lean_obj_arg world) {
    (void)world;
    if (!ready() || bytes(token) > INPUT_MAX) return failure();
    unsigned char digest[32] = {0};
    char text[64] = {0};
    unsigned int length = 0;
    EVP_MD_CTX *ctx = EVP_MD_CTX_new();
    EVP_MD *md = EVP_MD_fetch(NULL, "SHA256", NULL);
    lean_obj_res result;
    if (!ctx || !md || EVP_DigestInit_ex(ctx, md, NULL) != 1 ||
        EVP_DigestUpdate(ctx, lean_string_cstr(token), bytes(token)) != 1 ||
        EVP_DigestFinal_ex(ctx, digest, &length) != 1 || length != sizeof(digest)) {
        result = failure();
    } else {
        hex_encode(digest, sizeof(digest), text);
        result = lean_io_result_mk_ok(lean_mk_string_from_bytes(text, sizeof(text)));
    }
    EVP_MD_CTX_free(ctx);
    EVP_MD_free(md);
    OPENSSL_cleanse(digest, sizeof(digest));
    OPENSSL_cleanse(text, sizeof(text));
    return result;
}

LEAN_EXPORT lean_obj_res leanapp_auth_constant_time_equal(b_lean_obj_arg a,
        b_lean_obj_arg b, lean_obj_arg world) {
    (void)world;
    if (!ready() || bytes(a) > INPUT_MAX || bytes(b) > INPUT_MAX) return failure();
    if (bytes(a) != bytes(b)) return boolean(0);
    return boolean(CRYPTO_memcmp(lean_string_cstr(a), lean_string_cstr(b), bytes(a)) == 0);
}

LEAN_EXPORT lean_obj_res leanapp_auth_version(lean_obj_arg world) {
    (void)world;
    if (!ready()) return failure();
    return lean_io_result_mk_ok(lean_mk_string(OpenSSL_version(OPENSSL_VERSION)));
}
