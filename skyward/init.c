/* Pid 1 for a Skyward ramdisk that has no Android init.
 * Mounts the kernel filesystems, links GPT partition names, then execs
 * /system/bin/recovery with argv0 "recovery".
 */
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <sys/types.h>
#include <unistd.h>

static void kmsg(const char *line) {
    int fd = open("/dev/kmsg", O_WRONLY | O_CLOEXEC);
    if (fd < 0) {
        return;
    }
    (void)write(fd, line, strlen(line));
    close(fd);
}

static void ensure_dir(const char *path) {
    if (mkdir(path, 0755) != 0 && errno != EEXIST) {
        char buf[160];
        snprintf(buf, sizeof buf, "<3>skyward-init: mkdir %s: %d\n", path, errno);
        kmsg(buf);
    }
}

static void mount_fs(const char *src, const char *target, const char *type, unsigned long flags, const char *data) {
    if (mount(src, target, type, flags, data) != 0 && errno != EBUSY) {
        char buf[200];
        snprintf(buf, sizeof buf, "<3>skyward-init: mount %s on %s (%s): %d\n", src, target, type, errno);
        kmsg(buf);
    }
}

static void link_partitions(void) {
    DIR *dir = opendir("/sys/class/block");
    int linked = 0;
    struct dirent *ent;
    if (dir == NULL) {
        kmsg("<3>skyward-init: no /sys/class/block\n");
        return;
    }
    while ((ent = readdir(dir)) != NULL) {
        char uevent[288];
        char line[256];
        char partname[64];
        char devname[128];
        char node[160];
        char link1[192];
        char link2[224];
        FILE *file;
        int major = -1;
        int minor = -1;
        if (ent->d_name[0] == '.') {
            continue;
        }
        snprintf(uevent, sizeof uevent, "/sys/class/block/%s/uevent", ent->d_name);
        file = fopen(uevent, "r");
        if (file == NULL) {
            continue;
        }
        partname[0] = 0;
        devname[0] = 0;
        while (fgets(line, sizeof line, file) != NULL) {
            if (strncmp(line, "PARTNAME=", 9) == 0) {
                sscanf(line + 9, "%63s", partname);
            } else if (strncmp(line, "DEVNAME=", 8) == 0) {
                sscanf(line + 8, "%127s", devname);
            } else if (strncmp(line, "MAJOR=", 6) == 0) {
                major = atoi(line + 6);
            } else if (strncmp(line, "MINOR=", 6) == 0) {
                minor = atoi(line + 6);
            }
        }
        fclose(file);
        if (partname[0] == 0 || strchr(partname, '/') != NULL) {
            continue;
        }
        if (devname[0] != 0) {
            snprintf(node, sizeof node, "/dev/%s", devname);
        } else {
            snprintf(node, sizeof node, "/dev/block/%s", ent->d_name);
        }
        if (access(node, F_OK) != 0 && major >= 0 && minor >= 0) {
            ensure_dir("/dev/block");
            if (mknod(node, S_IFBLK | 0600, makedev((unsigned)major, (unsigned)minor)) != 0 && errno != EEXIST) {
                continue;
            }
        }
        snprintf(link1, sizeof link1, "/dev/block/by-name/%s", partname);
        snprintf(link2, sizeof link2, "/dev/block/bootdevice/by-name/%s", partname);
        unlink(link1);
        unlink(link2);
        if (symlink(node, link1) == 0) {
            linked++;
        }
        (void)symlink(node, link2);
    }
    closedir(dir);
    {
        char buf[80];
        snprintf(buf, sizeof buf, "<6>skyward-init: linked %d partition names\n", linked);
        kmsg(buf);
    }
}

int main(void) {
    int i;
    int nullfd;
    int kfd;
    char arg0[] = "recovery";
    char *argv[] = {arg0, NULL};

    ensure_dir("/proc");
    ensure_dir("/sys");
    ensure_dir("/dev");
    mount_fs("proc", "/proc", "proc", 0, NULL);
    mount_fs("sysfs", "/sys", "sysfs", 0, NULL);
    if (mount("devtmpfs", "/dev", "devtmpfs", MS_NOSUID, "mode=0755") != 0) {
        mount_fs("tmpfs", "/dev", "tmpfs", MS_NOSUID, "mode=0755");
        mknod("/dev/null", S_IFCHR | 0666, makedev(1, 3));
        mknod("/dev/kmsg", S_IFCHR | 0644, makedev(1, 11));
        mknod("/dev/console", S_IFCHR | 0600, makedev(5, 1));
    }
    ensure_dir("/dev/pts");
    mount_fs("devpts", "/dev/pts", "devpts", 0, NULL);
    ensure_dir("/dev/input");
    ensure_dir("/dev/dri");
    ensure_dir("/dev/block");
    ensure_dir("/dev/block/by-name");
    ensure_dir("/dev/block/bootdevice");
    ensure_dir("/dev/block/bootdevice/by-name");
    ensure_dir("/tmp");
    mount_fs("tmpfs", "/tmp", "tmpfs", 0, "mode=0755");

    for (i = 0; i < 50; i++) {
        link_partitions();
        if (access("/dev/block/by-name/userdata", F_OK) == 0 && access("/dev/block/by-name/system", F_OK) == 0) {
            break;
        }
        usleep(100000);
    }

    nullfd = open("/dev/null", O_RDWR | O_CLOEXEC);
    kfd = open("/dev/kmsg", O_WRONLY | O_CLOEXEC);
    if (nullfd >= 0) {
        dup2(nullfd, 0);
    }
    if (kfd >= 0) {
        dup2(kfd, 1);
        dup2(kfd, 2);
    }
    if (nullfd > 2) {
        close(nullfd);
    }
    if (kfd > 2) {
        close(kfd);
    }

    kmsg("<6>skyward-init: exec /system/bin/recovery\n");
    execv("/system/bin/recovery", argv);
    {
        char buf[80];
        snprintf(buf, sizeof buf, "<3>skyward-init: exec recovery: %d\n", errno);
        kmsg(buf);
    }
    for (;;) {
        sleep(3600);
    }
}
