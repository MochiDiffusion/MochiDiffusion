#include "flux.h"

extern void (*iris_step_callback)(int, int);
extern void (*iris_phase_callback)(const char *, int);

static iris_params to_iris_params(const flux_params *params) {
    if (params == NULL) {
        return (iris_params)IRIS_PARAMS_DEFAULT;
    }

    iris_params converted = {
        .width = params->width,
        .height = params->height,
        .num_steps = params->num_steps,
        .seed = params->seed,
        .guidance = params->guidance,
        .schedule = IRIS_SCHEDULE_DEFAULT,
        .power_alpha = params->power_alpha,
    };

    if (params->power_schedule) {
        converted.schedule = IRIS_SCHEDULE_POWER;
    } else if (params->linear_schedule) {
        converted.schedule = IRIS_SCHEDULE_LINEAR;
    }

    return converted;
}

flux_ctx *flux_load_dir(const char *model_dir) {
    return iris_load_dir(model_dir);
}

void flux_free(flux_ctx *ctx) {
    iris_free(ctx);
}

void flux_release_text_encoder(flux_ctx *ctx) {
    iris_release_text_encoder(ctx);
}

void flux_set_mmap(flux_ctx *ctx, int enable) {
    iris_set_mmap(ctx, enable);
}

int flux_is_distilled(flux_ctx *ctx) {
    return iris_is_distilled(ctx);
}

flux_image *flux_generate(flux_ctx *ctx, const char *prompt, const flux_params *params) {
    iris_params converted = to_iris_params(params);
    return iris_generate(ctx, prompt, &converted);
}

flux_image *flux_img2img(
    flux_ctx *ctx,
    const char *prompt,
    const flux_image *input,
    const flux_params *params
) {
    iris_params converted = to_iris_params(params);
    return iris_img2img(ctx, prompt, input, &converted);
}

flux_image *flux_img2img_with_embeddings(
    flux_ctx *ctx,
    const float *text_emb,
    int text_seq,
    const flux_image *input,
    const flux_params *params
) {
    iris_params converted = to_iris_params(params);
    return iris_img2img_with_embeddings(ctx, text_emb, text_seq, input, &converted);
}

flux_image *flux_generate_with_embeddings(
    flux_ctx *ctx,
    const float *text_emb,
    int text_seq,
    const flux_params *params
) {
    iris_params converted = to_iris_params(params);
    return iris_generate_with_embeddings(ctx, text_emb, text_seq, &converted);
}

float *flux_encode_text(flux_ctx *ctx, const char *prompt, int *out_seq_len) {
    return iris_encode_text(ctx, prompt, out_seq_len);
}

int flux_text_dim(flux_ctx *ctx) {
    return iris_text_dim(ctx);
}

flux_image *flux_image_create(int width, int height, int channels) {
    return iris_image_create(width, height, channels);
}

void flux_image_free(flux_image *img) {
    iris_image_free(img);
}

const char *flux_get_error(void) {
    return iris_get_error();
}

void flux_set_step_image_callback(flux_ctx *ctx, flux_step_image_cb_t callback) {
    iris_set_step_image_callback(ctx, callback);
}

void flux_set_step_callback(flux_step_cb_t callback) {
    iris_step_callback = callback;
}

void flux_set_phase_callback(flux_phase_cb_t callback) {
    iris_phase_callback = callback;
}

void flux_request_cancel(void) {
    iris_request_cancel();
}

void flux_clear_cancel(void) {
    iris_clear_cancel();
}
