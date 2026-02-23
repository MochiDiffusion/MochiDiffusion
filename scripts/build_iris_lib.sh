#!/bin/sh
set -euo pipefail

# ---- CONFIG ----
VENDOR_DIR="${SRCROOT}/iris.c"
OUT_DIR="${BUILD_DIR}/vendor/iris/${CONFIGURATION}"
OUT_LIB="${OUT_DIR}/libiris_mps.a"

mkdir -p "${OUT_DIR}"
# Prevent stale archives from masking a skipped or failed vendor build.
rm -f "${OUT_LIB}"

# ---- SUBMODULE GUARD ----
if [ ! -f "${VENDOR_DIR}/Makefile" ]; then
  echo "iris.c submodule appears missing; attempting to initialize/update..."

  if ! command -v git >/dev/null 2>&1; then
    echo "error: git is required to fetch the iris.c submodule"
    exit 1
  fi

  if ! git -C "${SRCROOT}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "error: ${SRCROOT} is not a git worktree; cannot fetch iris.c automatically"
    exit 1
  fi

  git -C "${SRCROOT}" submodule sync -- iris.c
  GIT_TERMINAL_PROMPT=0 git -C "${SRCROOT}" submodule update --init --recursive iris.c

  if [ ! -f "${VENDOR_DIR}/Makefile" ]; then
    echo "error: iris.c submodule is still unavailable after update"
    echo "error: Run: git submodule update --init --recursive iris.c"
    exit 1
  fi
fi

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

# We also need the Objective-C Metal bridge object.
# Upstream renamed flux_* to iris_*.
if [ -f "${VENDOR_DIR}/iris_metal.m" ]; then
  METAL_OBJ="iris_metal.o"
elif [ -f "${VENDOR_DIR}/flux_metal.m" ]; then
  METAL_OBJ="flux_metal.o"
else
  echo "error: Could not find Metal bridge source (expected iris_metal.m or flux_metal.m)"
  exit 1
fi

MPS_TARGETS="${MPS_TARGETS} ${METAL_OBJ}"

# ---- BUILD ONLY THE VENDOR OBJECTS (NO LINK STEP) ----
make -C "${VENDOR_DIR}" clean
make -C "${VENDOR_DIR}" ${MPS_TARGETS}

# ---- ARCHIVE INTO A STATIC LIB ----
rm -f "${OUT_LIB}"
/usr/bin/ar rcs "${OUT_LIB}" \
  $(for cfile in ${SRCS_LINE}; do printf "%s/%s.mps.o " "${VENDOR_DIR}" "${cfile%.c}"; done) \
  "${VENDOR_DIR}/${METAL_OBJ}"

if [ ! -s "${OUT_LIB}" ]; then
  echo "error: Expected static library was not created: ${OUT_LIB}"
  exit 1
fi

echo "Built: ${OUT_LIB}"
