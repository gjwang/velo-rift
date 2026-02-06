#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>

int main(int argc, char *argv[]) {
  if (argc < 2) {
    fprintf(stderr, "Usage: %s <path>\n", argv[0]);
    return 1;
  }

  struct stat sb;
  if (stat(argv[1], &sb) == 0) {
    printf("SUCCESS: stat(\"%s\") worked!\n", argv[1]);
    return 0;
  } else {
    perror("stat failed");
    return 1;
  }
}
