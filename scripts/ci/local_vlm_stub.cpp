// CI links this unavailable-model implementation to run tests without downloaded weights.
#include "prts_local_vlm.h"

#include <atomic>

struct prts_vlm_cancel {
    std::atomic<bool> requested{false};
};

prts_vlm_cancel *prts_vlm_cancel_create(void) {
    return new prts_vlm_cancel;
}

void prts_vlm_cancel_set(prts_vlm_cancel *cancel) {
    if (cancel) {
        cancel->requested.store(true);
    }
}

int prts_vlm_cancel_is_requested(const prts_vlm_cancel *cancel) {
    return cancel && cancel->requested.load();
}

void prts_vlm_cancel_free(prts_vlm_cancel *cancel) {
    delete cancel;
}

prts_vlm *prts_vlm_open(const char *, const char *, int) {
    return nullptr;
}

prts_vlm_status prts_vlm_describe(prts_vlm *, const unsigned char *, size_t, const char *,
                                  const char *, int, const prts_vlm_cancel *cancel,
                                  prts_vlm_text_fn, void *, char **answer) {
    if (answer) {
        *answer = nullptr;
    }
    return prts_vlm_cancel_is_requested(cancel) ? PRTS_VLM_CANCELLED : PRTS_VLM_EVAL_FAILED;
}

prts_vlm_status prts_vlm_continue(prts_vlm *, const char *, int, const prts_vlm_cancel *cancel,
                                  prts_vlm_text_fn, void *, char **answer) {
    if (answer) {
        *answer = nullptr;
    }
    return prts_vlm_cancel_is_requested(cancel) ? PRTS_VLM_CANCELLED : PRTS_VLM_EVAL_FAILED;
}

void prts_vlm_close(prts_vlm *) {}
