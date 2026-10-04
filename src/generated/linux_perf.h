#undef _FORTIFY_SOURCE
#define _GNU_SOURCE 1
#define BIONIC_IOCTL_NO_SIGNEDNESS_OVERLOAD 1
#include "errno.h"
#include "fcntl.h"
#include "stdio.h"
#include "unistd.h"
#include "string.h"
#include "sys/ioctl.h"
#include "sys/mman.h"
#include "sys/syscall.h"
#include "linux/perf_event.h"
#include "time.h"
