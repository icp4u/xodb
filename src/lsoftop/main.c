/* Standalone lsof-top for machines that run only the C agent. */
#include "lsoftop.h"
int main(int argc, char **argv)
{
    return xodb_lsof_top(argc, argv);
}
