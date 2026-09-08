/-!
Native OpenSSL >= 3 adapter. Build with `-Kopenssl=<prefix>`; macOS defaults to
`/opt/homebrew/opt/openssl@3`, Linux defaults to system headers/libraries.

Password records are exactly
`$leanapp$scrypt$v1$N=131072$r=8$p=1$<32 lowercase hex salt>$<64 lowercase hex key>`.
Only this version and these parameters are accepted. Scrypt uses a 16-byte salt,
32-byte key, and 256 MiB maxmem. Passwords are 1..1024 UTF-8 bytes (including NUL).
Hashing invalid input throws a generic IO error; verification rejects it with false.
Digest/comparison inputs are bounded to 1024 UTF-8 bytes, allowing empty strings;
oversize inputs throw a generic IO error. Length equality is public; comparison
of equal-length contents uses CRYPTO_memcmp. Tokens contain 32 random bytes as hex.

Transient C buffers are cleansed. Immutable caller-owned Lean strings cannot be
erased by this API. This adapter does not supply rate limits or KDF concurrency
admission: each production scrypt operation requires approximately 128 MiB.

Focused receipt: `lake -Kleansqlite=<cached-source> -Kopenssl=<prefix> build
leanapp_crypto_checks`, then `.lake/build/bin/leanapp_crypto_checks`.
The native checks exercise salted records, correct/wrong/Unicode/NUL passwords,
both byte boundaries, malformed/version/parameter/hex records, known SHA256
vectors, random-token canonical form/nonreuse, and comparison bounds/content.
Qualified locally on macOS against OpenSSL 3.6.3 (9 Jun 2026); native linkage
and LC_RPATH were inspected. Linux system/prefix paths (lib and lib64) are
configured but not executed here. Provider/RNG/allocation failures are checked
in C but not fault-injected by the executable. No KDF parameter reductions.
-/
namespace LeanAppNative.Auth.Crypto

@[extern "leanapp_auth_hash_password"]
opaque hashPassword (password : @& String) : IO String

@[extern "leanapp_auth_verify_password"]
opaque verifyPassword (password encoded : @& String) : IO Bool

@[extern "leanapp_auth_random_token"]
opaque randomToken : IO String

@[extern "leanapp_auth_digest_token"]
opaque digestToken (token : @& String) : IO String

@[extern "leanapp_auth_constant_time_equal"]
opaque constantTimeEqual (a b : @& String) : IO Bool

@[extern "leanapp_auth_version"]
opaque version : IO String

end LeanAppNative.Auth.Crypto
