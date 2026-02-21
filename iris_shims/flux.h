#ifndef FLUX_COMPAT_H
#define FLUX_COMPAT_H

#include "iris.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef iris_ctx flux_ctx;
typedef iris_image flux_image;
typedef iris_tokenizer flux_tokenizer;

struct flux_params {
    int width;
    int height;
    int num_steps;
    int64_t seed;
    float guidance;
    int linear_schedule;
    int power_schedule;
    float power_alpha;
};
typedef struct flux_params flux_params;

#define FLUX_LATENT_CHANNELS IRIS_LATENT_CHANNELS
#define FLUX_VAE_MAX_DIM IRIS_VAE_MAX_DIM
#define FLUX_MAX_SEQ_LEN IRIS_MAX_SEQ_LEN
#define FLUX_DEFAULT_WIDTH IRIS_DEFAULT_WIDTH
#define FLUX_DEFAULT_HEIGHT IRIS_DEFAULT_HEIGHT
#define FLUX_PARAMS_DEFAULT { FLUX_DEFAULT_WIDTH, FLUX_DEFAULT_HEIGHT, 0, -1, 0.0f, 0, 0, 2.0f }

typedef void (*flux_step_image_cb_t)(int step, int total, const flux_image *img);
typedef void (*flux_step_cb_t)(int step, int total);
typedef void (*flux_phase_cb_t)(const char *phase, int done);

flux_ctx *flux_load_dir(const char *model_dir);
void flux_free(flux_ctx *ctx);
void flux_release_text_encoder(flux_ctx *ctx);
void flux_set_mmap(flux_ctx *ctx, int enable);
int flux_is_distilled(flux_ctx *ctx);

flux_image *flux_generate(flux_ctx *ctx, const char *prompt, const flux_params *params);
flux_image *flux_img2img(
    flux_ctx *ctx,
    const char *prompt,
    const flux_image *input,
    const flux_params *params
);
flux_image *flux_img2img_with_embeddings(
    flux_ctx *ctx,
    const float *text_emb,
    int text_seq,
    const flux_image *input,
    const flux_params *params
);
flux_image *flux_generate_with_embeddings(
    flux_ctx *ctx,
    const float *text_emb,
    int text_seq,
    const flux_params *params
);

float *flux_encode_text(flux_ctx *ctx, const char *prompt, int *out_seq_len);
int flux_text_dim(flux_ctx *ctx);

flux_image *flux_image_create(int width, int height, int channels);
void flux_image_free(flux_image *img);

const char *flux_get_error(void);
void flux_set_step_image_callback(flux_ctx *ctx, flux_step_image_cb_t callback);
void flux_set_step_callback(flux_step_cb_t callback);
void flux_set_phase_callback(flux_phase_cb_t callback);
void flux_request_cancel(void);
void flux_clear_cancel(void);

#ifdef __cplusplus
}
#endif

#endif
