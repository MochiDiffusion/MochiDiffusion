#!/bin/sh
set -euo pipefail

resolve_build_number() {
  if [ -n "${MOCHI_BUILD_NUMBER:-}" ]; then
    printf "%s" "${MOCHI_BUILD_NUMBER}"
    return
  fi

  if [ -n "${GITHUB_RUN_NUMBER:-}" ]; then
    printf "%s" "${GITHUB_RUN_NUMBER}"
    return
  fi

  if [ -n "${CI_PIPELINE_IID:-}" ]; then
    printf "%s" "${CI_PIPELINE_IID}"
    return
  fi

  if command -v git >/dev/null 2>&1 && git -C "${SRCROOT}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "${SRCROOT}" rev-list --count HEAD
    return
  fi

  printf "%s" "${CURRENT_PROJECT_VERSION:-1}"
}

resolve_git_sha() {
  if command -v git >/dev/null 2>&1 && git -C "${SRCROOT}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "${SRCROOT}" rev-parse --short=12 HEAD
    return
  fi

  printf "unknown"
}

BUILD_NUMBER="$(resolve_build_number)"
case "${BUILD_NUMBER}" in
  '' | *[!0-9]*)
    echo "error: build number must be numeric. Got: ${BUILD_NUMBER}" >&2
    exit 1
    ;;
esac

GIT_SHA="$(resolve_git_sha)"
PLIST_PATH="${TARGET_BUILD_DIR}/${INFOPLIST_PATH}"

if [ ! -f "${PLIST_PATH}" ]; then
  echo "error: expected Info.plist missing at ${PLIST_PATH}" >&2
  exit 1
fi

if ! /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER}" "${PLIST_PATH}" 2>/dev/null; then
  /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string ${BUILD_NUMBER}" "${PLIST_PATH}"
fi

if ! /usr/libexec/PlistBuddy -c "Set :MochiGitCommit ${GIT_SHA}" "${PLIST_PATH}" 2>/dev/null; then
  /usr/libexec/PlistBuddy -c "Add :MochiGitCommit string ${GIT_SHA}" "${PLIST_PATH}"
fi

echo "Set CFBundleVersion=${BUILD_NUMBER} (MochiGitCommit=${GIT_SHA})"
