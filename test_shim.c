#include <stdio.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <dirent.h>

int main() {
    struct stat st;
    printf("--- Testing open ---\n");
    int fd = open("Cargo.toml", O_RDONLY);
    if (fd >= 0) {
        printf("Open successful: %d\n", fd);
        close(fd);
    } else {
        perror("open");
    }
    
    printf("--- Testing opendir/readdir ---\n");
    DIR *dir = opendir(".");
    if (dir) {
        printf("Opendir successful\n");
        struct dirent *entry;
        int count = 0;
        while ((entry = readdir(dir)) != NULL && count < 5) {
            printf("Entry: %s\n", entry->d_name);
            count++;
        }
        closedir(dir);
        printf("Closedir successful\n");
    } else {
        perror("opendir");
    }
    
    return 0;
}
