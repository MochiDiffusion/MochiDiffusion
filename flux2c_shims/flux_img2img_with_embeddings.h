#ifndef FLUX_IMG2IMG_WITH_EMBEDDINGS_H
#define FLUX_IMG2IMG_WITH_EMBEDDINGS_H

#include "flux.h"

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Image-to-image generation with pre-computed text embeddings.
 *
 * This mirrors flux_img2img() but skips prompt tokenization/encoding,
 * allowing callers to reuse embeddings across repeated generations.
 *
 * Note: like flux_generate_with_embeddings(), this API only supports
 * distilled models (no CFG path).
 */
flux_image *flux_img2img_with_embeddings(
    flux_ctx *ctx,
    const float *text_emb,
    int text_seq,
    const flux_image *input,
    const flux_params *params
);

#ifdef __cplusplus
}
#endif

#endif
