#!/bin/bash
# Records a code health snapshot: test coverage, unused code, unused imports,
# force unwraps, complexity and a Thread Sanitizer test run.
#
# The snapshot is informational. Findings never fail the script, and a tool that
# is not installed is skipped with a note in the summary.
#
# Usage: scripts/code_health.sh [--skip-tsan] [output-directory]
#
# Tools: Xcode, periphery and swiftlint (Homebrew), and uv. The Homebrew formula
# named lizard is an unrelated compression tool, so the complexity analyzer runs
# from PyPI through uvx.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

skip_tsan=false
out_dir=""
for arg in "$@"; do
  case "$arg" in
    --skip-tsan) skip_tsan=true ;;
    -h | --help)
      sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) out_dir="$arg" ;;
  esac
done

commit="$(git rev-parse --short=12 HEAD)"
if [ -z "$out_dir" ]; then
  out_dir="${TMPDIR:-/tmp}/mochi-code-health/$(date +%Y%m%d-%H%M%S)-${commit}"
fi
mkdir -p "$out_dir"
out_dir="$(cd "$out_dir" && pwd)"

project="Mochi Diffusion.xcodeproj"
scheme="Mochi Diffusion"
app_sources="Mochi Diffusion"
summary="$out_dir/summary.txt"

has() { command -v "$1" >/dev/null 2>&1; }
log() { printf '==> %s\n' "$*"; }
note() { printf '%s\n' "$*" >>"$summary"; }

run_tests() {
  local name="$1"
  shift
  xcodebuild test \
    -project "$project" \
    -scheme "$scheme" \
    -destination "platform=macOS" \
    -configuration Debug \
    -derivedDataPath "$out_dir/$name/DerivedData" \
    -resultBundlePath "$out_dir/$name/result.xcresult" \
    CODE_SIGNING_ALLOWED=NO \
    "$@" >"$out_dir/$name/xcodebuild.log" 2>&1
}

# Prints "result, N passed, N failed" from a result bundle.
test_totals() {
  xcrun xcresulttool get test-results summary --path "$1" 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    print("%s, %d passed, %d failed" % (d["result"], d["passedTests"], d["failedTests"]))
except Exception:
    print("no test results")
'
}

{
  echo "Code health snapshot"
  echo "Commit: $commit ($(git log -1 --format=%cs))"
  echo "Date: $(date '+%Y-%m-%d %H:%M')"
  echo "Output: $out_dir"
  echo
} >"$summary"

# Coverage. This build's index store and compiler log feed Periphery and
# SwiftLint analyze, so this step runs first.
log "Running tests with code coverage"
mkdir -p "$out_dir/coverage"
run_tests coverage -enableCodeCoverage YES
coverage_bundle="$out_dir/coverage/result.xcresult"
index_store="$out_dir/coverage/DerivedData/Index.noindex/DataStore"
compiler_log="$out_dir/coverage/xcodebuild.log"
note "Tests: $(test_totals "$coverage_bundle")"

if [ -d "$coverage_bundle" ]; then
  xcrun xccov view --report --json "$coverage_bundle" >"$out_dir/coverage/coverage.json" 2>/dev/null
  python3 - "$out_dir/coverage/coverage.json" "$app_sources" >"$out_dir/coverage/files.txt" <<'EOF'
import json, sys
report, sources = json.load(open(sys.argv[1])), sys.argv[2]
app = next(t for t in report["targets"] if t["name"] == sources + ".app")
print(f"app {app['lineCoverage'] * 100:.1f}% ({app['coveredLines']}/{app['executableLines']})")
rows = []
for f in app["files"]:
    path = f["path"].split(sources + "/", 1)[-1]
    if path.startswith(("Support/", "Model/")):
        rows.append((f["lineCoverage"], f["executableLines"], path))
for coverage, lines, path in sorted(rows):
    print(f"{coverage * 100:5.1f}% {lines:5d} {path}")
EOF
  note "Coverage, app target: $(head -1 "$out_dir/coverage/files.txt" | cut -d' ' -f2-)"
  note "  The test bundle runs inside the app, so view coverage mostly reflects the app launch."
  note "  Per-file coverage for Support and Model: coverage/files.txt"
else
  note "Coverage: no result bundle. See coverage/xcodebuild.log"
fi

# Unused code. The first scan counts test usage. The second ignores it, so its
# extra results are declarations that only the tests use.
if has periphery && [ -d "$index_store" ]; then
  log "Running Periphery"
  periphery_args=(
    --project "$project"
    --schemes "$scheme"
    --index-store-path "$index_store"
    --retain-swift-ui-previews
    --retain-codable-properties
    --retain-equatable-properties
    --retain-hashable-properties
    --report-exclude "Vendor/**"
    --report-exclude "iris.c/**"
    --report-exclude "Mochi DiffusionTests/**"
    --relative-results
    --quiet
  )
  periphery scan "${periphery_args[@]}" >"$out_dir/periphery.txt" 2>&1
  periphery scan "${periphery_args[@]}" --index-exclude "Mochi DiffusionTests/**" \
    >"$out_dir/periphery-without-tests.txt" 2>&1
  unused=$(grep -c ': warning: ' "$out_dir/periphery.txt")
  test_only=$(comm -13 <(sort "$out_dir/periphery.txt") \
    <(sort "$out_dir/periphery-without-tests.txt") | grep -c ': warning: ')
  note "Periphery: $unused unused declarations, $test_only more used only by tests"
  note "  This count includes the preserved OpenAI and engine-picker code."
else
  note "Periphery: skipped (not installed, or the coverage build failed)"
fi

# Unused imports and force unwraps.
if has swiftlint; then
  log "Running SwiftLint"
  analyze_config="$out_dir/swiftlint-analyze.yml"
  printf 'analyzer_rules:\n  - unused_import\n' >"$analyze_config"
  swiftlint analyze --config "$analyze_config" --compiler-log-path "$compiler_log" \
    --quiet "$app_sources" >"$out_dir/swiftlint-analyze.txt" 2>&1
  lint_config="$out_dir/swiftlint-lint.yml"
  printf 'only_rules:\n  - force_unwrapping\n  - force_try\n  - force_cast\n' >"$lint_config"
  swiftlint lint --config "$lint_config" --quiet "$app_sources" \
    >"$out_dir/swiftlint-lint.txt" 2>&1
  note "Unused imports: $(grep -c '(unused_import)' "$out_dir/swiftlint-analyze.txt")"
  note "Force unwraps, tries and casts in the app target: $(grep -c ': \(warning\|error\): ' "$out_dir/swiftlint-lint.txt")"
else
  note "SwiftLint: skipped (not installed)"
fi

# Complexity.
if has uvx; then
  log "Running Lizard"
  uvx --quiet --from lizard lizard "$app_sources" -l swift >"$out_dir/lizard.txt" 2>&1
  uvx --quiet --from lizard lizard "$app_sources" -l swift -C 15 -w >"$out_dir/lizard-over-15.txt" 2>&1
  totals=$(tail -1 "$out_dir/lizard.txt")
  functions=$(awk '{print $5}' <<<"$totals")
  average=$(awk '{print $3}' <<<"$totals")
  note "Complexity: $functions functions, average cyclomatic complexity $average, $(grep -c 'warning:' "$out_dir/lizard-over-15.txt") above 15"
else
  note "Lizard: skipped (uv is not installed)"
fi

# Data races. Thread Sanitizer needs its own instrumented build.
if [ "$skip_tsan" = true ]; then
  note "Thread Sanitizer: skipped (--skip-tsan)"
else
  log "Running tests under Thread Sanitizer"
  mkdir -p "$out_dir/tsan"
  run_tests tsan -enableThreadSanitizer YES
  races=$(grep -c 'WARNING: ThreadSanitizer' "$out_dir/tsan/xcodebuild.log")
  note "Thread Sanitizer: $(test_totals "$out_dir/tsan/result.xcresult"), $races reports"
fi

echo
cat "$summary"
