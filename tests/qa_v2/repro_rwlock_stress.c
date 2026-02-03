#include <fcntl.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define NUM_THREADS 10
#define NUM_OPENS 100

void *stress_thread(void *arg) {
  char *path = (char *)arg;
  for (int i = 0; i < NUM_OPENS; i++) {
    int fd = open(path, O_RDONLY);
    if (fd >= 0) {
      close(fd);
    }
  }
  return NULL;
}

int main(int argc, char **argv) {
  if (argc < 2) {
    fprintf(stderr, "Usage: %s <file>\n", argv[0]);
    return 1;
  }

  pthread_t threads[NUM_THREADS];
  printf("🚀 Starting %d threads to stress open/close on %s...\n", NUM_THREADS,
         argv[1]);

  for (int i = 0; i < NUM_THREADS; i++) {
    if (pthread_create(&threads[i], NULL, stress_thread, argv[1]) != 0) {
      perror("pthread_create");
      return 1;
    }
  }

  for (int i = 0; i < NUM_THREADS; i++) {
    pthread_join(threads[i], NULL);
  }

  printf("✅ All threads finished successfully.\n");
  return 0;
}
