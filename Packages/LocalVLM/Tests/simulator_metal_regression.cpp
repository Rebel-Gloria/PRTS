// Standalone arm64 iOS Simulator regression. Direct Metal submission, no scheduler or model.
#include "ggml-cpp.h"
#include "ggml-metal.h"
#include <TargetConditionals.h>
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <stdexcept>
#include <sys/mman.h>
#include <unistd.h>
#include <vector>

#if !TARGET_OS_SIMULATOR || !defined(__arm64__)
#error Build this regression for the arm64 simulator.
#endif

namespace {
void require(bool ok, const char *what) {
    if (!ok)
        throw std::runtime_error(what);
}

ggml_context_ptr context() {
    ggml_context_ptr ctx(ggml_init(
        {32 * ggml_tensor_overhead() + ggml_graph_overhead_custom(16, false), nullptr, true}));
    require(ctx != nullptr, "ggml metadata allocation");
    return ctx;
}

void transfers(ggml_backend_t metal, ggml_tensor *t, ggml_tensor *view, ggml_tensor *page,
               bool use_event) {
    using Bytes = std::array<uint8_t, 68>;
    alignas(16) Bytes src{}, full{}, overlap{}, echo{};
    for (size_t i = 0; i < src.size(); ++i)
        src[i] = static_cast<uint8_t>(i * 13 + 7);
    full.fill(0xec);
    auto expected = full;
    std::copy_n(src.begin() + 1, 64, expected.begin() + 3);
    ggml_backend_tensor_set(t, src.data() + 1, 0, 64);
    ggml_backend_tensor_get(t, full.data() + 3, 0, 64);
    require(full == expected, "unaligned synchronous upload/readback or guard");

    // View begins at byte 8. Fill [12,20) of its parent, not [12,32).
    ggml_backend_tensor_memset(view, 0, 4, 8);
    std::fill_n(expected.begin() + 3 + 12, 8, 0);
    ggml_backend_tensor_get(t, full.data() + 3, 0, 64);
    require(full == expected, "partial private fill clobbered guards");
    ggml_backend_tensor_set(t, src.data() + 1, 0, 64);

    // A separate page-sized destination is eligible for no-copy async readback.
    const size_t size = ggml_nbytes(page);
    void *ptr = mmap(nullptr, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    require(ptr != MAP_FAILED, "page allocation");
    const auto unmap = [size](uint8_t *p) { munmap(p, size); };
    std::unique_ptr<uint8_t, decltype(unmap)> aligned(static_cast<uint8_t *>(ptr), unmap);
    std::vector<uint8_t> pattern(size);
    for (size_t i = 0; i < size; ++i)
        pattern[i] = static_cast<uint8_t>(31 * i + (use_event ? 3 : 7));
    std::fill_n(aligned.get(), size, 0xe3);
    ggml_backend_tensor_set(page, pattern.data(), 0, size);
    ggml_backend_event_ptr event(use_event ? ggml_backend_event_new(ggml_backend_get_device(metal))
                                           : nullptr);
    require(!use_event || event != nullptr, "missing Metal event");
    overlap.fill(0xac);
    echo.fill(0xca);
    auto want = overlap, want_echo = echo;
    std::copy_n(src.begin() + 1, 32, want.begin() + 1);
    std::copy_n(src.begin() + 33, 16, want.begin() + 9);
    std::copy_n(want.begin() + 1, 32, want_echo.begin() + 3);

    // Last read wins in the overlapping bytes. The next upload consumes that host range
    // on the same stream, without the caller touching it or inserting an intermediate fence.
    ggml_backend_tensor_get_async(metal, t, overlap.data() + 1, 0, 32);
    ggml_backend_tensor_get_async(metal, t, overlap.data() + 9, 32, 16);
    ggml_backend_tensor_set_async(metal, t, overlap.data() + 1, 16, 32);
    ggml_backend_tensor_get_async(metal, t, echo.data() + 3, 16, 32);
    ggml_backend_tensor_get_async(metal, page, aligned.get(), 0, size);
    if (event) {
        ggml_backend_event_record(event.get(), metal);
        ggml_backend_event_synchronize(event.get());
    } else {
        ggml_backend_synchronize(metal);
    }
    // Inspect before any other backend call can flush pending host deliveries.
    require(overlap == want, "overlapping readbacks or guard");
    require(echo == want_echo, "dependent upload/final readback or guard");
    require(std::equal(pattern.begin(), pattern.end(), aligned.get()), "page readback after fence");
    ggml_backend_synchronize(metal); // Drop retained no-copy buffers before freeing host memory.
}

template <int k, int m, int n> void matrix(ggml_backend_t metal, bool add) {
    auto owner = context();
    auto *ctx = owner.get();
    auto *a = ggml_new_tensor_2d(ctx, GGML_TYPE_BF16, k, m);
    auto *b = ggml_new_tensor_2d(ctx, GGML_TYPE_F32, k, n);
    // The ADD reads a separate, freshly computed intermediate; there is no fence between nodes.
    auto *product = add ? ggml_mul_mat(ctx, a, b) : nullptr;
    auto *bias = add ? ggml_new_tensor_2d(ctx, GGML_TYPE_F32, m, n) : nullptr;
    // Bind the result inside this allocation so even a one-float overstore is observable.
    const size_t guard = std::max<size_t>(ggml_backend_get_alignment(metal), 256) / sizeof(float);
    std::vector<float> initial(guard + m * n + 64, -9876.0f), output(initial);
    auto *storage = ggml_new_tensor_1d(ctx, GGML_TYPE_F32, initial.size());
    ggml_backend_buffer_ptr buf(ggml_backend_alloc_ctx_tensors(ctx, metal));
    require(buf != nullptr, "matrix allocation");
    auto *y = add ? ggml_add(ctx, product, bias) : ggml_mul_mat(ctx, a, b);
    require(ggml_backend_tensor_alloc(buf.get(), y,
                                      static_cast<char *>(storage->data) + guard * sizeof(float)) ==
                GGML_STATUS_SUCCESS,
            "guarded result allocation");
    require(ggml_backend_supports_op(metal, a), "BF16 storage leaf rejected");
    require(ggml_backend_supports_op(metal, add ? product : y), "dense BF16 x F32 rejected");
    require(!add || ggml_backend_supports_op(metal, y), "F32 residual ADD rejected");

    std::array<ggml_bf16_t, k * m> w;
    std::array<float, k * n> x;
    for (int i = 0; i < k * m; ++i)
        w[i] = ggml_fp32_to_bf16(((i * 13 + i / k) % 97 - 48) / 19.0f);
    for (int i = 0; i < k * n; ++i)
        x[i] = ((i * 7 + i / k) % 59 - 29) / 32.0f;
    ggml_backend_tensor_set(a, w.data(), 0, sizeof(w));
    ggml_backend_tensor_set(b, x.data(), 0, sizeof(x));
    ggml_backend_tensor_set(storage, initial.data(), 0, ggml_nbytes(storage));
    std::array<float, m * n> residual;
    if (add) {
        for (int i = 0; i < m * n; ++i)
            residual[i] = ((i * 17) % 123 + 1) / 16.0f;
        ggml_backend_tensor_set(bias, residual.data(), 0, sizeof(residual));
        ggml_backend_tensor_set(product, initial.data(), 0, ggml_nbytes(product));
    }
    auto *graph = ggml_new_graph_custom(ctx, 16, false);
    ggml_build_forward_expand(graph, y);
    require(ggml_backend_graph_compute(metal, graph) == GGML_STATUS_SUCCESS, "Metal dispatch");
    ggml_backend_tensor_get(storage, output.data(), 0, ggml_nbytes(storage));
    for (size_t i = 0; i < output.size(); ++i) {
        if (i < guard || i >= guard + m * n) {
            require(output[i] == initial[i], "Metal output guard overwritten");
            continue;
        }
        const size_t pos = i - guard;
        double ref = add ? residual[pos] : 0;
        for (int j = 0; j < k; ++j)
            ref += double(ggml_bf16_to_fp32(w[pos % m * k + j])) * x[pos / m * k + j];
        require(std::abs(output[i] - ref) <= 5e-5, "incorrect Metal graph output");
    }

    if (add)
        return;
    require(!ggml_backend_supports_op(metal, ggml_dup(ctx, a)), "unrelated BF16 dup admitted");
    require(!ggml_backend_supports_op(metal, ggml_cast(ctx, a, GGML_TYPE_F32)),
            "unrelated BF16 cast admitted");
    auto padded = [&](ggml_type type, int rows) {
        auto *base = ggml_new_tensor_2d(ctx, type, k + 1, rows);
        return ggml_view_2d(ctx, base, k, rows, base->nb[1], 0);
    };
    require(!ggml_backend_supports_op(metal, ggml_mul_mat(ctx, padded(GGML_TYPE_BF16, m), b)),
            "padded BF16 rows admitted");
    require(!ggml_backend_supports_op(metal, ggml_mul_mat(ctx, a, padded(GGML_TYPE_F32, n))),
            "padded F32 rows admitted");
}
} // namespace

int main() {
    try {
        ggml_backend_ptr metal(ggml_backend_metal_init());
        require(metal && ggml_backend_is_metal(metal.get()), "Metal backend unavailable");
        require(!ggml_backend_buft_is_host(ggml_backend_get_default_buffer_type(metal.get())),
                "expected private Metal buffers");
        auto ctx = context();
        auto *bytes = ggml_new_tensor_1d(ctx.get(), GGML_TYPE_I8, 64);
        auto *view = ggml_view_1d(ctx.get(), bytes, 32, 8);
        auto *page = ggml_new_tensor_1d(ctx.get(), GGML_TYPE_I8, getpagesize());
        ggml_backend_buffer_ptr buf(ggml_backend_alloc_ctx_tensors(ctx.get(), metal.get()));
        require(buf != nullptr, "transfer allocation");
        for (bool event : {true, false}) {
            std::fprintf(stderr, "RUN transfers (%s)\n", event ? "event" : "backend");
            transfers(metal.get(), bytes, view, page, event);
        }
        std::fprintf(stderr, "RUN guarded Metal matrix and capability checks\n");
        matrix<17, 33, 35>(metal.get(), false); // Partial reduction and output tiles.
        std::fprintf(stderr, "RUN Metal MUL_MAT -> ADD dependency\n");
        matrix<128, 33, 4>(metal.get(), true); // Few-row fusion candidate.
        std::puts("PASS simulator Metal regression");
        return EXIT_SUCCESS;
    } catch (const std::exception &e) {
        std::fprintf(stderr, "FAIL: %s\n", e.what());
        return EXIT_FAILURE;
    }
}
