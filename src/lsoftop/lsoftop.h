#ifndef XODB_LSOFTOP_H
#define XODB_LSOFTOP_H
/* lsof-top: a live terminal view of open files and descriptor activity over
 * the C runtime's /proc scanner. argv[0] is the program name. Returns an exit
 * status: 0 ok, 1 runtime failure, 2 usage. */
int xodb_lsof_top(int argc, char **argv);
#endif
