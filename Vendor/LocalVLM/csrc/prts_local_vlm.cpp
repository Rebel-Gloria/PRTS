// On-device MiniCPM-V 4.7 photo description for PRTS, built on llama.cpp + mtmd.
// Prompt layout and decoding match the benchmark in docs/features/local-vlm.md.
#include "prts_local_vlm.h"
#include "llama.h"
#include "mtmd.h"
#include "mtmd-helper.h"

#include <cstdlib>
#include <cstring>
#include <string>

struct prts_vlm {
    llama_model * model;
    llama_context * ctx;
    mtmd_context * mctx;
};

prts_vlm * prts_vlm_open(const char * model_path, const char * mmproj_path, int n_ctx) {
    llama_backend_init();
    llama_model_params mp = llama_model_default_params();
    mp.n_gpu_layers = 999;
    llama_model * model = llama_model_load_from_file(model_path, mp);
    if (!model) return nullptr;

    llama_context_params cp = llama_context_default_params();
    cp.n_ctx = n_ctx; cp.n_batch = 512; cp.n_ubatch = 512;
    llama_context * ctx = llama_init_from_model(model, cp);
    if (!ctx) { llama_model_free(model); return nullptr; }

    mtmd_context_params mcp = mtmd_context_params_default();
    mcp.use_gpu = true; mcp.print_timings = false; mcp.warmup = false;
    mtmd_context * mctx = mtmd_init_from_file(mmproj_path, model, mcp);
    if (!mctx) { llama_free(ctx); llama_model_free(model); return nullptr; }

    return new prts_vlm{model, ctx, mctx};
}

prts_vlm_status prts_vlm_describe(prts_vlm * vlm, const unsigned char * jpeg, size_t jpeg_len,
                                  const char * system_prompt, const char * prompt, int max_tokens,
                                  const volatile int * cancel, char ** answer) {
    // MiniCPM-V chat template; the empty think block is how enable_thinking=false is written.
    std::string text;
    if (system_prompt && *system_prompt) text += std::string("<|im_start|>system\n") + system_prompt + "<|im_end|>\n";
    text += std::string("<|im_start|>user\n") + mtmd_default_marker() + "\n" + prompt +
            "<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n";

    llama_memory_clear(llama_get_memory(vlm->ctx), true);
    mtmd_bitmap * bitmap = mtmd_helper_bitmap_init_from_buf(vlm->mctx, jpeg, jpeg_len, false,
                                                            mtmd_helper_init_opt_default()).bitmap;
    if (!bitmap) return PRTS_VLM_BAD_IMAGE;
    mtmd_input_chunks * chunks = mtmd_input_chunks_init();
    mtmd_input_text it = { text.c_str(), text.size(), true, true };
    const mtmd_bitmap * bitmaps[1] = { bitmap };
    prts_vlm_status status = PRTS_VLM_OK;
    if (mtmd_tokenize(vlm->mctx, chunks, &it, bitmaps, 1) != 0) status = PRTS_VLM_BAD_IMAGE;

    llama_pos n_past = 0;
    const size_t n_chunks = mtmd_input_chunks_size(chunks);
    for (size_t c = 0; status == PRTS_VLM_OK && c < n_chunks; c++) {
        if (*cancel) { status = PRTS_VLM_CANCELLED; break; }
        llama_pos next = n_past;
        if (mtmd_helper_eval_chunk_single(vlm->mctx, vlm->ctx, mtmd_input_chunks_get(chunks, c),
                                          n_past, 0, 512, c + 1 == n_chunks, &next) != 0) status = PRTS_VLM_EVAL_FAILED;
        n_past = next;
    }
    mtmd_input_chunks_free(chunks);
    mtmd_bitmap_free(bitmap);
    if (status != PRTS_VLM_OK) return status;

    const llama_vocab * vocab = llama_model_get_vocab(vlm->model);
    llama_sampler * sampler = llama_sampler_init_greedy();
    std::string out;
    for (int i = 0; i < max_tokens; i++) {
        if (*cancel) { status = PRTS_VLM_CANCELLED; break; }
        llama_token token = llama_sampler_sample(sampler, vlm->ctx, -1);
        if (llama_vocab_is_eog(vocab, token)) break;
        char piece[256];
        const int n = llama_token_to_piece(vocab, token, piece, sizeof piece, 0, false);
        if (n > 0) out.append(piece, n);
        llama_batch batch = llama_batch_get_one(&token, 1);
        if (llama_decode(vlm->ctx, batch) != 0) { status = PRTS_VLM_EVAL_FAILED; break; }
    }
    llama_sampler_free(sampler);
    if (status == PRTS_VLM_OK) *answer = strdup(out.c_str());
    return status;
}

void prts_vlm_close(prts_vlm * vlm) {
    mtmd_free(vlm->mctx);
    llama_free(vlm->ctx);
    llama_model_free(vlm->model);
    delete vlm;
}
