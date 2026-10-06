/* Minimal C caller of the C05-R2 logical-frame reader (candidate API, not an
 * installed xodb interface): decode a file under a budget, aggregate, and print
 * exact totals plus the heaviest inclusive function. Usage: example-caller FILE */
#include "logical_frames.h"
#include <stdio.h>

int main(int argc, char **argv)
{
    if (argc != 2) {
        fputs("usage: example-caller FILE\n", stderr);
        return 1;
    }
    struct xlf_limits limits;
    xlf_default_limits(&limits);
    struct xlf_cancel *cancel = xlf_cancel_create(); /* another thread may xlf_cancel_request() */
    struct xlf_error err;
    struct xlf_doc *doc = xlf_decode_file(argv[1], &limits, cancel, &err);
    if (!doc) {
        printf("decode failed: %s at line %llu: %s (peak %zu bytes)\n", xlf_status_name(err.status),
               (unsigned long long)err.line, err.message, err.peak_bytes);
        xlf_cancel_destroy(cancel);
        return 2;
    }
    struct xlf_aggregate agg;
    if (xlf_aggregate(doc, XLF_NONE, NULL, cancel, &agg, &err) != XLF_OK) {
        printf("aggregate failed: %s: %s\n", xlf_status_name(err.status), err.message);
        xlf_free(doc);
        xlf_cancel_destroy(cancel);
        return 2;
    }
    char total[40], top[40];
    uint64_t narrow;
    xlf_count_format(agg.total_weight, total);
    printf("sha256 %s\nstacks %llu total_weight %s (%s) input_complete %s\n", doc->sha256_hex,
           (unsigned long long)agg.stacks, total,
           xlf_count_to_u64(agg.total_weight, &narrow) ? "fits u64" : "exceeds u64: overflow outcome when narrowing",
           agg.input_incomplete ? "no" : "yes");
    size_t best = 0;
    for (size_t f = 1; f < agg.function_count; ++f)
        if (xlf_count_cmp(agg.inclusive[f], agg.inclusive[best]) > 0)
            best = f;
    if (agg.function_count) {
        xlf_count_format(agg.inclusive[best], top);
        printf("top inclusive %s = %s\n", doc->functions[best].name.ptr, top);
    }
    printf("bytes: decode peak %zu, retained %zu, query peak %zu, combined peak %zu\n", doc->decode_peak_bytes,
           doc->retained_bytes, agg.query_peak_bytes, agg.combined_peak_bytes);
    xlf_aggregate_free(&agg);
    xlf_free(doc);
    xlf_cancel_destroy(cancel);
    return 0;
}
