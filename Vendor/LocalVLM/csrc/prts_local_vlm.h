#pragma once
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/// A loaded MiniCPM-V model (language model plus vision projector). Not thread-safe:
/// the Swift side runs every call on one serial queue.
typedef struct prts_vlm prts_vlm;

typedef enum {
    PRTS_VLM_OK = 0,
    PRTS_VLM_BAD_IMAGE = 1,
    PRTS_VLM_EVAL_FAILED = 2,
    PRTS_VLM_CANCELLED = 3,
} prts_vlm_status;

/// Loads both files with Metal offload. NULL if either file cannot be loaded.
prts_vlm * prts_vlm_open(const char * model_path, const char * mmproj_path, int n_ctx);

/// Describes one JPEG with greedy decoding. On PRTS_VLM_OK *answer is a malloc'ed UTF-8
/// string the caller frees. `cancel` is polled between chunks and tokens.
prts_vlm_status prts_vlm_describe(prts_vlm * vlm, const unsigned char * jpeg, size_t jpeg_len,
                                  const char * system_prompt, const char * prompt, int max_tokens,
                                  const volatile int * cancel, char ** answer);

void prts_vlm_close(prts_vlm * vlm);

#ifdef __cplusplus
}
#endif
