#!/bin/sh
set -euo pipefail

# ---- CONFIG ----
VENDOR_DIR="${SRCROOT}/flux2.c"
SHIM_DIR="${SRCROOT}/flux2c_shims"
OUT_DIR="${BUILD_DIR}/vendor/flux2c/${CONFIGURATION}"
OUT_LIB="${OUT_DIR}/libflux_mps.a"
SHIM_SRC="${SHIM_DIR}/flux_img2img_with_embeddings.c"
SHIM_OBJ="${OUT_DIR}/flux_img2img_with_embeddings.mps.o"

mkdir -p "${OUT_DIR}"

# ---- PLATFORM GUARD ----
UNAME_S="$(uname -s)"
UNAME_M="$(uname -m)"
if [ "${UNAME_S}" != "Darwin" ] || [ "${UNAME_M}" != "arm64" ]; then
  echo "error: MPS build requires macOS on Apple Silicon (arm64). Got: ${UNAME_S} ${UNAME_M}"
  exit 1
fi

# ---- GET SRCS FROM THE VENDOR MAKEFILE (NO 'make mps-build') ----
SRCS_LINE="$(awk -F'= ' '/^SRCS[[:space:]]*=[[:space:]]*/ {print $2; exit}' "${VENDOR_DIR}/Makefile")"
if [ -z "${SRCS_LINE}" ]; then
  echo "error: Could not parse SRCS from ${VENDOR_DIR}/Makefile"
  exit 1
fi

# Turn "a.c b.c" into "a.mps.o b.mps.o"
MPS_TARGETS=""
for cfile in ${SRCS_LINE}; do
  base="${cfile%.c}"
  MPS_TARGETS="${MPS_TARGETS} ${base}.mps.o"
done

# We also need the Objective-C Metal bridge object
MPS_TARGETS="${MPS_TARGETS} flux_metal.o"

# ---- BUILD ONLY THE VENDOR OBJECTS (NO LINK STEP) ----
make -C "${VENDOR_DIR}" clean
make -C "${VENDOR_DIR}" ${MPS_TARGETS}

# ---- BUILD SHIM OBJECT ----
if [ ! -f "${SHIM_SRC}" ]; then
  echo "error: Missing shim source ${SHIM_SRC}"
  exit 1
fi

MPS_CFLAGS="-Wall -Wextra -O3 -march=native -ffast-math -DUSE_BLAS -DUSE_METAL -DACCELERATE_NEW_LAPACK"
/usr/bin/cc ${MPS_CFLAGS} -I"${VENDOR_DIR}" -I"${SHIM_DIR}" -c -o "${SHIM_OBJ}" "${SHIM_SRC}"

# ---- ARCHIVE INTO A STATIC LIB ----
rm -f "${OUT_LIB}"
/usr/bin/ar rcs "${OUT_LIB}" \
  $(for cfile in ${SRCS_LINE}; do printf "%s/%s.mps.o " "${VENDOR_DIR}" "${cfile%.c}"; done) \
  "${VENDOR_DIR}/flux_metal.o" \
  "${SHIM_OBJ}"

echo "Built: ${OUT_LIB}"
