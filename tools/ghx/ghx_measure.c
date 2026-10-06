/* ghx_measure OUT.json -- CMD ARGS...: run CMD (no shell), record wall time,
 * exit status and peak RSS of the largest descendant (RUSAGE_CHILDREN).
 * C01 test helper, GPLv3. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

int main(int argc, char **argv)
{
	struct timespec a, b;
	struct rusage ru;
	int st = 0;
	pid_t p;
	FILE *f;
	if (argc < 4 || strcmp(argv[2], "--") != 0) {
		fprintf(stderr, "usage: ghx_measure OUT.json -- CMD [ARGS]\n");
		return 2;
	}
	clock_gettime(CLOCK_MONOTONIC, &a);
	p = fork();
	if (p == 0) { execvp(argv[3], argv + 3); _exit(127); }
	if (p < 0) return 2;
	while (waitpid(p, &st, 0) < 0) ;
	clock_gettime(CLOCK_MONOTONIC, &b);
	getrusage(RUSAGE_CHILDREN, &ru);
	f = fopen(argv[1], "w");
	if (f) {
		fprintf(f, "{\"wall_ms\":%.1f,\"exit\":%d,\"signal\":%d,\"max_rss_kb\":%ld,\"user_ms\":%.1f,\"sys_ms\":%.1f}\n",
			(b.tv_sec - a.tv_sec) * 1e3 + (b.tv_nsec - a.tv_nsec) / 1e6,
			WIFEXITED(st) ? WEXITSTATUS(st) : -1, WIFSIGNALED(st) ? WTERMSIG(st) : 0,
			ru.ru_maxrss, ru.ru_utime.tv_sec * 1e3 + ru.ru_utime.tv_usec / 1e3,
			ru.ru_stime.tv_sec * 1e3 + ru.ru_stime.tv_usec / 1e3);
		fclose(f);
	}
	return WIFEXITED(st) ? WEXITSTATUS(st) : 128 + WTERMSIG(st);
}
