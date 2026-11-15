//
//  ITXLlama.h
//  Minimal C bridge over llama.cpp for the iPad translator.
//
//  设计原则：Swift 只看到"加载模型 / 给一段完整 prompt / 拿回一段完整文本"，
//  tokenize / decode / sampler / KV 清理全部留在 C 里，减少 Swift 侧 FFI 出错面。
//

#ifndef ITX_LLAMA_H
#define ITX_LLAMA_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct itx_context itx_context;

typedef struct itx_stats {
    int32_t prompt_tokens;
    int32_t gen_tokens;
    int32_t prompt_ms;
    int32_t gen_ms;
} itx_stats;

/// 加载 GGUF 并建好 context。失败返回 NULL。
/// n_gpu_layers: 设备上用 999（全部 offload 到 Metal），模拟器上 0。
itx_context *itx_load(const char *model_path,
                      int32_t n_threads,
                      int32_t n_ctx,
                      int32_t n_gpu_layers);

void itx_free(itx_context *ctx);

/// 把模型描述写进 buf，返回写入长度。
int32_t itx_model_desc(itx_context *ctx, char *buf, int32_t buf_len);

/// 生成。out 会写入以 \0 结尾的 UTF-8 文本，返回写入字节数（不含 \0），负数表示失败：
///   -1 参数错 / -2 tokenize 失败 / -3 prompt 超出 context / -4 decode 失败
int32_t itx_generate(itx_context *ctx,
                     const char *prompt,
                     int32_t max_tokens,
                     char *out,
                     int32_t out_cap,
                     itx_stats *stats);

const char *itx_system_info(void);

/// 最近一次 llama.cpp 的日志（截断到 8 KB）。设备上没有 Xcode 控制台，
/// 出错时靠它在 App 的「信息」面板里看到真实原因。
const char *itx_last_log(void);
void itx_clear_log(void);

/// 把后续日志追加写进文件（App 的 Documents 目录，可在「文件」App 里取走）。
/// 传 NULL 关闭。返回 0 成功。
int32_t itx_set_log_path(const char *path);

#ifdef __cplusplus
}
#endif

#endif /* ITX_LLAMA_H */
