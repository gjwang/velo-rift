#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

int main(int argc, char *argv[]) {
  if (argc < 2) {
    fprintf(stderr, "Usage: %s <path>\n", argv[0]);
    return 1;
  }

  const char *path = argv[1];
  int fd = open(path, O_RDONLY);
  if (fd < 0) {
    perror("open");
    return 1;
  }

  // Try to change mode to 000 (no permissions)
  int res = fchmod(fd, 0000);
  if (res == 0) {
    printf("fchmod SUCCESS (This is a gap if path is VFS)\n");
    close(fd);
    return 0;
  } else {
    printf("fchmod FAILED: %s (errno=%d)\n", strerror(errno), errno);
    close(fd);
    return 0;
  }
}
