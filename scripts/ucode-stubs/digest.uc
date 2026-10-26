// Stub of ucode's digest module. See README.md.
//
// Note the absence of any HMAC or KDF function: ucode-mod-digest offers plain
// hashes only. That is why console/lib/auth.uc shells out to busybox mkpasswd
// for password hashing rather than deriving a key here.
export function md5(str) {};
export function sha1(str) {};
export function sha256(str) {};
export function sha384(str) {};
export function sha512(str) {};
export function md5_file(path) {};
export function sha1_file(path) {};
export function sha256_file(path) {};
export function sha384_file(path) {};
export function sha512_file(path) {};
