#ifndef XODB_XSQ_REPORT_H
#define XODB_XSQ_REPORT_H

#include "xsq.h"
#include <stdio.h>

#define XSQ_REPORT_MAX_PATH 256u

const char *xsq_certainty_name(unsigned certainty);
const char *xsq_vn_role(const struct xsq_graph *graph, uint32_t vn);
void xsq_transform(const struct xsq_graph *graph, uint32_t op, char *text, size_t size);
void xsq_report_slice_json(FILE *out, const struct xsq_graph *graph,
                           const struct xsq_result *result, const struct xsq_budget *budget,
                           uint32_t max_rows);
void xsq_report_controls_json(FILE *out, const struct xsq_graph *graph,
                              const struct xsq_result *result, const struct xsq_budget *budget,
                              uint32_t max_rows);
void xsq_report_slice_text(FILE *out, const struct xsq_graph *graph,
                           const struct xsq_result *result, uint32_t max_lines);
void xsq_report_controls_text(FILE *out, const struct xsq_graph *graph,
                              const struct xsq_result *result, uint32_t max_lines);
#endif
