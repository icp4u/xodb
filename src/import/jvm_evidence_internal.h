#ifndef XODB_IMPORT_JVM_EVIDENCE_INTERNAL_H
#define XODB_IMPORT_JVM_EVIDENCE_INTERNAL_H
/* C05-R4: internal to the in-tree CLI and tests; not a host API. Unstable: the
 * import state's layout changes with any revision of the importer. */
#include "jvm_evidence.h"
const struct jvm_import *jvm_evidence_import_state(const struct jvm_evidence *);
/* Test entry point: jvm_evidence_import with cancellation forced at the Nth
 * importer/adapter poll (0 = off), for cancellation sweeps. */
enum xlf_status jvm_evidence_import_test(const char *path, enum jvm_source source, const struct jvm_query *q,
                                         const struct jvm_evidence_limits *limits, const struct xlf_cancel *cancel,
                                         uint64_t cancel_after_polls, struct jvm_evidence **out,
                                         struct xlf_error *err);
#endif
