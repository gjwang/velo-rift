/**
 * C Variadic Shim for macOS ARM64
 *
 * This bridge solves the variadic ABI hazard on macOS ARM64 and avoids
 * deadlocks during dyld initialization by using direct svc #0x80 syscalls
 * when the shim is bootstrapping.
 */

#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>
#include <unistd.h>

/* Rust VFS implementation functions */
extern int velo_open_impl(const char *path, int flags, mode_t mode);
extern int velo_openat_impl(int dirfd, const char *path, int flags,
                            mode_t mode);

/* Atomic flags exported from Rust (1-byte atomics) */
extern _Atomic char INITIALIZING;

/**
 * Raw syscall for macOS ARM64 (AArch64) using svc #0x80
 * Correctly handles the Carry bit for error detection.
 */
static inline long raw_syscall(long number, long arg1, long arg2, long arg3,
                               long arg4) {
  long ret;
  long err_flag;
  register long x16 __asm__("x16") = number;
  register long x0 __asm__("x0") = arg1;
  register long x1 __asm__("x1") = arg2;
  register long x2 __asm__("x2") = arg3;
  register long x3 __asm__("x3") = arg4;

  __asm__ volatile("svc #0x80\n"
                   "cset %1, cs\n" /* %1 (err_flag) = 1 if Carry Set, else 0 */
                   : "+r"(x0), "=r"(err_flag)
                   : "r"(x16), "r"(x1), "r"(x2), "r"(x3)
                   : "memory");

  if (err_flag) {
    errno = (int)x0;
    return -1;
  }
  return x0;
}

/**
 * open() variadic wrapper
 */
int open_c_wrapper(const char *path, int flags, ...) {
  mode_t mode = 0;

  if (flags & O_CREAT) {
    va_list ap;
    va_start(ap, flags);
    mode = (mode_t)va_arg(ap, int);
    va_end(ap);
  }

  /*
   * Recursion & Boot Guard:
   * If we are in dyld init OR Velo state initialization,
   * we MUST use direct syscalls to avoid deadlock.
   */
  if (INITIALIZING) {
    /* macOS SYS_open = 5 */
    return (int)raw_syscall(5, (long)path, (long)flags, (long)mode, 0);
  }

  return velo_open_impl(path, flags, mode);
}

/**
 * openat() variadic wrapper
 */
int openat_c_wrapper(int dirfd, const char *path, int flags, ...) {
  mode_t mode = 0;

  if (flags & O_CREAT) {
    va_list ap;
    va_start(ap, flags);
    mode = (mode_t)va_arg(ap, int);
    va_end(ap);
  }

  if (INITIALIZING) {
    /* macOS SYS_openat = 463 */
    return (int)raw_syscall(463, (long)dirfd, (long)path, (long)flags,
                            (long)mode);
  }

  return velo_openat_impl(dirfd, path, flags, mode);
}
