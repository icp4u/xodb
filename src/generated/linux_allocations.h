#undef _FORTIFY_SOURCE
#define _GNU_SOURCE 1
#define BIONIC_IOCTL_NO_SIGNEDNESS_OVERLOAD 1
#include "unistd.h"
#include "fcntl.h"
#include "errno.h"
#include "stdio.h"
#include "sys/stat.h"
#include "sys/ioctl.h"
#include "sys/mman.h"
#include "sys/syscall.h"
#include "linux/perf_event.h"
#include "time.h"
#include "signal.h"
#include "sys/wait.h"
#include "dirent.h"
#include "dlfcn.h"
