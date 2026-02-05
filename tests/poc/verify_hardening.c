#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/attr.h>
#include <unistd.h>

int main() {
  const char *vfs_path = "/Users/antigravity/vrift_vfs/test_hardening";

  printf("[1] Testing open(O_CREAT) on VFS path...\n");
  int fd = open(vfs_path, O_CREAT | O_WRONLY | O_TRUNC, 0644);
  if (fd == -1 && errno == EPERM) {
    printf("SUCCESS: open() blocked with EPERM\n");
  } else {
    printf("FAILURE: open() returned %d (errno: %d, expected EPERM: %d)\n", fd,
           errno, EPERM);
    if (fd != -1)
      close(fd);
  }

  printf("[2] Testing setattrlist() on VFS path...\n");
  struct attrlist attrs;
  memset(&attrs, 0, sizeof(attrs));
  attrs.bitmapcount = ATTR_BIT_MAP_COUNT;

  int ret = setattrlist(vfs_path, &attrs, NULL, 0, 0);
  if (ret == -1 && errno == EPERM) {
    printf("SUCCESS: setattrlist() blocked with EPERM\n");
  } else {
    printf(
        "FAILURE: setattrlist() returned %d (errno: %d, expected EPERM: %d)\n",
        ret, errno, EPERM);
  }

  printf("[3] Testing getattrlist() on VFS path...\n");
  char buf[1024];
  ret = getattrlist(vfs_path, &attrs, buf, sizeof(buf), 0);
  printf("getattrlist() returned %d (errno: %d)\n", ret, errno);

  return 0;
}
