#undef _FORTIFY_SOURCE
#define _GNU_SOURCE 1
#define BIONIC_IOCTL_NO_SIGNEDNESS_OVERLOAD 1
#include "unistd.h"
#include "fcntl.h"
#include "errno.h"
#include "poll.h"
#include "signal.h"
#include "spawn.h"
#include "sys/socket.h"
#include "sys/wait.h"
#include "arpa/inet.h"
#include "netinet/tcp.h"
#include "time.h"
