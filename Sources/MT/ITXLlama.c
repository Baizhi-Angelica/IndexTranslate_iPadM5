//
//  ITXLlama.c
//  llama.cpp C 桥。API 对齐 b12397（xcframework 里的 llama.h）。
//

#include "ITXLlama.h"
#include "llama.h"

#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct itx_context {
    struct llama_model       *model;
    struct llama_context     *ctx;
    const struct llama_vocab *vocab;
    struct llama_sampler     *sampler;
    llama_token              *tokens;
    int32_t                   tokens_cap;
};

static bool g_backend_ready = false;

// 设备上没有 Xcode 控制台：把 llama.cpp 的日志存一份，给 App 的「信息」面板显示
#define ITX_LOG_CAP 8192
static char g_log_buf[ITX_LOG_CAP] = {0};

static void itx_log_callback(enum ggml_log_level level, const char * text, void * user_data) {
    (void)level;
    (void)user_data;
    if (text == NULL) {
        return;
    }
    fputs(text, stderr);
    size_t used = strlen(g_log_buf);
    if (used >= (size_t)ITX_LOG_CAP - 1) {
        // 满了就丢掉前半段，保留最近的日志
        size_t keep = ITX_LOG_CAP / 2;
        memmove(g_log_buf, g_log_buf + (ITX_LOG_CAP - keep), keep);
        g_log_buf[keep] = '\0';
        used = keep;
    }
    size_t room = (size_t)ITX_LOG_CAP - used - 1;
    strncat(g_log_buf, text, room);
}

const char *itx_last_log(void) {
    return g_log_buf;
}

void itx_clear_log(void) {
    g_log_buf[0] = '\0';
}

static void itx_backend_init_once(void) {
    if (!g_backend_ready) {
        llama_log_set(itx_log_callback, NULL);
        llama_backend_init();
        g_backend_ready = true;
    }
}

itx_context *itx_load(const char *model_path,
                      int32_t n_threads,
                      int32_t n_ctx,
                      int32_t n_gpu_layers) {
    if (model_path == NULL) {
        return NULL;
    }
    itx_backend_init_once();

    struct llama_model_params mparams = llama_model_default_params();
    mparams.n_gpu_layers = n_gpu_layers;

    struct llama_model *model = llama_model_load_from_file(model_path, mparams);
    if (model == NULL) {
        return NULL;
    }

    struct llama_context_params cparams = llama_context_default_params();
    cparams.n_ctx           = (uint32_t)(n_ctx > 0 ? n_ctx : 2048);
    cparams.n_batch         = 1024;
    cparams.n_threads       = n_threads;
    cparams.n_threads_batch = n_threads;
    cparams.no_perf         = true;

    struct llama_context *ctx = llama_init_from_model(model, cparams);
    if (ctx == NULL) {
        llama_model_free(model);
        return NULL;
    }

    struct llama_sampler *sampler = llama_sampler_init_greedy();
    if (sampler == NULL) {
        llama_free(ctx);
        llama_model_free(model);
        return NULL;
    }

    itx_context *handle = (itx_context *)calloc(1, sizeof(itx_context));
    if (handle == NULL) {
        llama_sampler_free(sampler);
        llama_free(ctx);
        llama_model_free(model);
        return NULL;
    }

    handle->model      = model;
    handle->ctx        = ctx;
    handle->vocab      = llama_model_get_vocab(model);
    handle->sampler    = sampler;
    handle->tokens     = NULL;
    handle->tokens_cap = 0;
    return handle;
}

void itx_free(itx_context *handle) {
    if (handle == NULL) {
        return;
    }
    if (handle->sampler) {
        llama_sampler_free(handle->sampler);
    }
    if (handle->tokens) {
        free(handle->tokens);
    }
    if (handle->ctx) {
        llama_free(handle->ctx);
    }
    if (handle->model) {
        llama_model_free(handle->model);
    }
    free(handle);
}

int32_t itx_model_desc(itx_context *handle, char *buf, int32_t buf_len) {
    if (handle == NULL || buf == NULL || buf_len <= 1) {
        return -1;
    }
    return llama_model_desc(handle->model, buf, (size_t)buf_len);
}

const char *itx_system_info(void) {
    return llama_print_system_info();
}

static int32_t itx_ensure_tokens(itx_context *handle, int32_t need) {
    if (need <= handle->tokens_cap) {
        return 0;
    }
    int32_t cap = handle->tokens_cap > 0 ? handle->tokens_cap : 256;
    while (cap < need) {
        cap *= 2;
    }
    llama_token *next = (llama_token *)realloc(handle->tokens, sizeof(llama_token) * (size_t)cap);
    if (next == NULL) {
        return -1;
    }
    handle->tokens     = next;
    handle->tokens_cap = cap;
    return 0;
}

int32_t itx_generate(itx_context *handle,
                     const char *prompt,
                     int32_t max_tokens,
                     char *out,
                     int32_t out_cap,
                     itx_stats *stats) {
    if (handle == NULL || prompt == NULL || out == NULL || out_cap <= 1) {
        return -1;
    }
    out[0] = '\0';
    if (stats != NULL) {
        stats->prompt_tokens = 0;
        stats->gen_tokens    = 0;
        stats->prompt_ms     = 0;
        stats->gen_ms        = 0;
    }

    const int32_t prompt_len = (int32_t)strlen(prompt);

    int32_t need = llama_tokenize(handle->vocab, prompt, prompt_len, NULL, 0, false, true);
    if (need < 0) {
        need = -need;
    }
    if (need <= 0) {
        return -2;
    }
    if (itx_ensure_tokens(handle, need) != 0) {
        return -2;
    }

    int32_t n_prompt = llama_tokenize(handle->vocab, prompt, prompt_len,
                                      handle->tokens, handle->tokens_cap,
                                      false, true);
    if (n_prompt < 0) {
        return -2;
    }

    const uint32_t n_ctx = llama_n_ctx(handle->ctx);
    if ((uint32_t)n_prompt + 16u >= n_ctx) {
        return -3;
    }
    if ((uint32_t)(n_prompt + max_tokens) >= n_ctx) {
        max_tokens = (int32_t)n_ctx - n_prompt - 16;
        if (max_tokens < 8) {
            return -3;
        }
    }

    // 每次翻译都是独立一句，清空 KV
    llama_memory_clear(llama_get_memory(handle->ctx), true);

    const int64_t t_prompt_start = llama_time_us();

    const int32_t chunk = 512;
    for (int32_t off = 0; off < n_prompt; off += chunk) {
        int32_t len = n_prompt - off;
        if (len > chunk) {
            len = chunk;
        }
        struct llama_batch batch = llama_batch_get_one(handle->tokens + off, len);
        if (llama_decode(handle->ctx, batch) != 0) {
            return -4;
        }
    }

    const int64_t t_gen_start = llama_time_us();

    int32_t written = 0;
    int32_t n_gen   = 0;
    for (int32_t i = 0; i < max_tokens; i++) {
        llama_token token = llama_sampler_sample(handle->sampler, handle->ctx, -1);
        if (llama_vocab_is_eog(handle->vocab, token)) {
            break;
        }

        char piece[256];
        int32_t n_piece = llama_token_to_piece(handle->vocab, token, piece,
                                               (int32_t)sizeof(piece), 0, false);
        if (n_piece > 0) {
            int32_t room = out_cap - 1 - written;
            if (n_piece > room) {
                n_piece = room;
            }
            if (n_piece > 0) {
                memcpy(out + written, piece, (size_t)n_piece);
                written += n_piece;
            }
            if (written >= out_cap - 1) {
                n_gen++;
                break;
            }
        }

        n_gen++;
        struct llama_batch batch = llama_batch_get_one(&token, 1);
        if (llama_decode(handle->ctx, batch) != 0) {
            break;
        }
    }
    out[written] = '\0';

    if (stats != NULL) {
        const int64_t t_end      = llama_time_us();
        stats->prompt_tokens     = n_prompt;
        stats->gen_tokens        = n_gen;
        stats->prompt_ms         = (int32_t)((t_gen_start - t_prompt_start) / 1000);
        stats->gen_ms            = (int32_t)((t_end - t_gen_start) / 1000);
    }
    return written;
}
