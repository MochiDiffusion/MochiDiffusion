#include "flux_img2img_with_embeddings.h"

#include "flux_kernels.h"
#include "flux_qwen3.h"

#include <stdio.h>
#include <stdlib.h>
#include <time.h>

/*
 * This shim intentionally mirrors private internals from flux.c so we can
 * provide a local extension API without modifying upstream source files.
 */
typedef struct flux_tokenizer flux_tokenizer;
typedef struct flux_vae flux_vae_t;
typedef struct flux_transformer flux_transformer_t;

struct flux_ctx {
    flux_tokenizer *tokenizer;
    qwen3_encoder_t *qwen3_encoder;
    flux_vae_t *vae;
    flux_transformer_t *transformer;

    int max_width;
    int max_height;
    int default_steps;
    float default_guidance;
    int is_distilled;
    int text_dim;
    int is_non_commercial;
    int num_heads;

    char model_name[64];
    char model_version[32];
    char model_dir[512];

    int use_mmap;
};

extern flux_transformer_t *flux_transformer_load_safetensors(
    const char *model_dir
);
extern flux_transformer_t *flux_transformer_load_safetensors_mmap(
    const char *model_dir
);
extern float *flux_image_to_tensor(const flux_image *img);
extern float *flux_vae_encode(
    flux_vae_t *vae,
    const float *img,
    int batch,
    int H,
    int W,
    int *out_h,
    int *out_w
);
extern flux_image *flux_vae_decode(
    flux_vae_t *vae,
    const float *latent,
    int batch,
    int latent_h,
    int latent_w
);
extern float *flux_sample_euler_with_refs(
    void *transformer,
    void *text_encoder,
    float *z,
    int batch,
    int channels,
    int h,
    int w,
    const float *ref_latent,
    int ref_h,
    int ref_w,
    int t_offset,
    const float *text_emb,
    int text_seq,
    const float *schedule,
    int num_steps,
    void (*progress_callback)(int step, int total)
);
extern float *flux_linear_schedule(int num_steps);
extern float *flux_power_schedule(int num_steps, float alpha);
extern float *flux_official_schedule(int num_steps, int image_seq_len);
extern float *flux_init_noise(int batch, int channels, int h, int w, int64_t seed);

static float *flux2c_selected_schedule(const flux_params *p, int image_seq_len) {
    if (p->power_schedule) {
        return flux_power_schedule(p->num_steps, p->power_alpha);
    }
    if (p->linear_schedule) {
        return flux_linear_schedule(p->num_steps);
    }
    return flux_official_schedule(p->num_steps, image_seq_len);
}

static int flux2c_load_transformer_if_needed(flux_ctx *ctx) {
    if (ctx->transformer) {
        return 1;
    }

    if (flux_phase_callback) {
        flux_phase_callback("Loading FLUX.2 transformer", 0);
    }
    if (ctx->use_mmap) {
        ctx->transformer = flux_transformer_load_safetensors_mmap(ctx->model_dir);
    } else {
        ctx->transformer = flux_transformer_load_safetensors(ctx->model_dir);
    }
    if (flux_phase_callback) {
        flux_phase_callback("Loading FLUX.2 transformer", 1);
    }

    return ctx->transformer != NULL;
}

/* 4 GB — MPSTemporaryNDArray hard limit. */
#define ATTENTION_MAX_BYTES ((size_t)4ULL << 30)

static size_t attention_bytes(
    int num_heads,
    int out_h,
    int out_w,
    const int *ref_dims,
    int num_refs,
    int txt_seq
) {
    size_t total_seq = (size_t)(out_h / 16) * (out_w / 16);
    for (int i = 0; i < num_refs; i++) {
        total_seq += (size_t)(ref_dims[i * 2] / 16) * (ref_dims[i * 2 + 1] / 16);
    }
    total_seq += txt_seq;
    return (size_t)num_heads * total_seq * total_seq * sizeof(float);
}

static int fit_refs_for_attention(
    int num_heads,
    int out_h,
    int out_w,
    int *ref_dims,
    int num_refs,
    int txt_seq
) {
    if (
        attention_bytes(num_heads, out_h, out_w, ref_dims, num_refs, txt_seq)
        <= ATTENTION_MAX_BYTES
    ) {
        return 0;
    }

    int shrunk = 0;
    for (;;) {
        int best = -1;
        size_t best_tok = 0;

        for (int i = 0; i < num_refs; i++) {
            size_t tok = (size_t)(ref_dims[i * 2] / 16) * (ref_dims[i * 2 + 1] / 16);
            if (tok > best_tok) {
                best_tok = tok;
                best = i;
            }
        }

        if (best < 0 || best_tok <= 1) {
            break;
        }

        int h = (int)(ref_dims[best * 2] * 0.9f) / 16 * 16;
        int w = (int)(ref_dims[best * 2 + 1] * 0.9f) / 16 * 16;
        if (h < 16) {
            h = 16;
        }
        if (w < 16) {
            w = 16;
        }

        if (h == ref_dims[best * 2] && w == ref_dims[best * 2 + 1]) {
            break;
        }

        ref_dims[best * 2] = h;
        ref_dims[best * 2 + 1] = w;
        shrunk = 1;

        if (
            attention_bytes(num_heads, out_h, out_w, ref_dims, num_refs, txt_seq)
            <= ATTENTION_MAX_BYTES
        ) {
            break;
        }
    }

    return shrunk;
}

flux_image *flux_img2img_with_embeddings(
    flux_ctx *ctx,
    const float *text_emb,
    int text_seq,
    const flux_image *input,
    const flux_params *params
) {
    if (!ctx || !text_emb || text_seq <= 0 || !input) {
        return NULL;
    }

    if (!ctx->is_distilled) {
        fprintf(stderr, "Warning: flux_img2img_with_embeddings() does not support CFG. Use flux_img2img() for base models.\n");
        return NULL;
    }

    flux_params p;
    if (params) {
        p = *params;
    } else {
        p = (flux_params)FLUX_PARAMS_DEFAULT;
    }

    if (p.width <= 0) {
        p.width = input->width;
    }
    if (p.height <= 0) {
        p.height = input->height;
    }

    if (p.width > FLUX_VAE_MAX_DIM || p.height > FLUX_VAE_MAX_DIM) {
        float scale = (float)FLUX_VAE_MAX_DIM / (p.width > p.height ? p.width : p.height);
        p.width = (int)(p.width * scale);
        p.height = (int)(p.height * scale);
    }

    p.width = (p.width / 16) * 16;
    p.height = (p.height / 16) * 16;

    int ref_w = p.width;
    int ref_h = p.height;
    {
        int ref_dims[2] = {p.height, p.width};
        if (
            fit_refs_for_attention(
                ctx->num_heads,
                p.height,
                p.width,
                ref_dims,
                1,
                FLUX_MAX_SEQ_LEN
            )
        ) {
            fprintf(
                stderr,
                "Note: reference image resized from %dx%d to %dx%d (GPU attention memory limit)\n",
                p.width,
                p.height,
                ref_dims[1],
                ref_dims[0]
            );
            ref_h = ref_dims[0];
            ref_w = ref_dims[1];
        }
    }

    flux_image *resized = NULL;
    const flux_image *img_to_use = input;
    if (input->width != ref_w || input->height != ref_h) {
        resized = flux_image_resize(input, ref_w, ref_h);
        if (!resized) {
            return NULL;
        }
        img_to_use = resized;
    }

    if (p.num_steps <= 0) {
        p.num_steps = ctx->default_steps;
    }

    flux_release_text_encoder(ctx);
    if (!flux2c_load_transformer_if_needed(ctx)) {
        if (resized) {
            flux_image_free(resized);
        }
        return NULL;
    }

    if (flux_phase_callback) {
        flux_phase_callback("encoding reference image", 0);
    }
    float *img_tensor = flux_image_to_tensor(img_to_use);
    if (resized) {
        flux_image_free(resized);
    }
    if (!img_tensor) {
        return NULL;
    }

    int latent_h = 0;
    int latent_w = 0;
    float *img_latent = NULL;

    if (ctx->vae) {
        img_latent = flux_vae_encode(
            ctx->vae,
            img_tensor,
            1,
            ref_h,
            ref_w,
            &latent_h,
            &latent_w
        );
    } else {
        latent_h = ref_h / 16;
        latent_w = ref_w / 16;
        img_latent = (float *)calloc(
            (size_t)FLUX_LATENT_CHANNELS * latent_h * latent_w,
            sizeof(float)
        );
    }

    free(img_tensor);
    if (flux_phase_callback) {
        flux_phase_callback("encoding reference image", 1);
    }

    if (!img_latent) {
        return NULL;
    }

    int out_lat_h = p.height / 16;
    int out_lat_w = p.width / 16;
    int image_seq_len = out_lat_h * out_lat_w;

    float *schedule = flux2c_selected_schedule(&p, image_seq_len);
    if (!schedule) {
        free(img_latent);
        return NULL;
    }

    int64_t seed = (p.seed < 0) ? (int64_t)time(NULL) : p.seed;
    float *z = flux_init_noise(1, FLUX_LATENT_CHANNELS, out_lat_h, out_lat_w, seed);
    if (!z) {
        free(schedule);
        free(img_latent);
        return NULL;
    }

    float *latent = flux_sample_euler_with_refs(
        ctx->transformer,
        ctx->qwen3_encoder,
        z,
        1,
        FLUX_LATENT_CHANNELS,
        out_lat_h,
        out_lat_w,
        img_latent,
        latent_h,
        latent_w,
        10,
        text_emb,
        text_seq,
        schedule,
        p.num_steps,
        NULL
    );

    free(z);
    free(img_latent);
    free(schedule);

    if (!latent) {
        return NULL;
    }

    flux_image *result = NULL;
    if (ctx->vae) {
        if (flux_phase_callback) {
            flux_phase_callback("decoding image", 0);
        }
        result = flux_vae_decode(ctx->vae, latent, 1, out_lat_h, out_lat_w);
        if (flux_phase_callback) {
            flux_phase_callback("decoding image", 1);
        }
    }

    free(latent);
    return result;
}
