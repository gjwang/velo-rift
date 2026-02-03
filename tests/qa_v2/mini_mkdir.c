#include <stdio.h>
#include <sys/stat.h>

int main(int argc, char **argv) {
  if (argc < 2) {
    fprintf(stderr, "Usage: %s <dir>\n", argv[0]);
    return 1;
  }
  printf("Creating directory %s...\n", argv[1]);
  if (mkdir(argv[1], 0777) != 0) {
    perror("mkdir");
    return 1;
  }
  printf("Directory created successfully.\n");
  return 0;
}
