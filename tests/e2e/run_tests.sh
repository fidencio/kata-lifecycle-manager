#!/usr/bin/env bash
# Copyright (c) 2026 The Kata Containers Authors
# SPDX-License-Identifier: Apache-2.0
#
# E2E test runner for kata-lifecycle-manager.
# Runs each test case as a separate ansible-playbook invocation,
# collects results, and generates JUnit XML + summary reports.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# -- Defaults --
RUNTIME=""
TC_FILTER="all"
SKIP_CLUSTER_CREATE=false
SKIP_CLUSTER_DELETE=false
FROM_VERSION=""
TO_VERSION=""
TO_IMAGE=""
RESULTS_DIR="${SCRIPT_DIR}/results"
ROTATE_LOGS_ONLY=false

# -- Log rotation defaults (overridable via group_vars) --
RESULTS_BASE_DIR="${RESULTS_BASE_DIR:-/var/lib/kata-e2e/results}"
RESULTS_MAX_RUNS="${RESULTS_MAX_RUNS:-10}"
RESULTS_MAX_AGE_DAYS="${RESULTS_MAX_AGE_DAYS:-30}"
RESULTS_MAX_TOTAL_MB="${RESULTS_MAX_TOTAL_MB:-2048}"

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --runtime <kata-qemu|kata-qemu-coco-dev>  Runtime class to test (required)
  --tc <N|N,M,...|all>                      Test cases to run (default: all)
  --skip-cluster-create                     Reuse existing cluster
  --skip-cluster-delete                     Keep cluster after tests
  --from-version <version>                  Override kata_from_version
  --to-version <version>                    Override kata_to_version
  --to-image <image>                        Override kata_to_image
  --results-dir <path>                      Output directory (default: ./results)
  --rotate-logs-only                        Only perform log rotation, then exit
  -h, --help                                Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --runtime)           RUNTIME="$2"; shift 2 ;;
        --tc)                TC_FILTER="$2"; shift 2 ;;
        --skip-cluster-create) SKIP_CLUSTER_CREATE=true; shift ;;
        --skip-cluster-delete) SKIP_CLUSTER_DELETE=true; shift ;;
        --from-version)      FROM_VERSION="$2"; shift 2 ;;
        --to-version)        TO_VERSION="$2"; shift 2 ;;
        --to-image)          TO_IMAGE="$2"; shift 2 ;;
        --results-dir)       RESULTS_DIR="$2"; shift 2 ;;
        --rotate-logs-only)  ROTATE_LOGS_ONLY=true; shift ;;
        -h|--help)           usage; exit 0 ;;
        *)                   echo "Unknown option: $1"; usage; exit 1 ;;
    esac
done

# =========================================================================
# Log Rotation
# =========================================================================
rotate_logs() {
    mkdir -p "${RESULTS_BASE_DIR}"

    flock --timeout 30 "${RESULTS_BASE_DIR}/.rotation.lock" bash -c '
        RESULTS_BASE_DIR="'"${RESULTS_BASE_DIR}"'"
        RESULTS_MAX_AGE_DAYS="'"${RESULTS_MAX_AGE_DAYS}"'"
        RESULTS_MAX_RUNS="'"${RESULTS_MAX_RUNS}"'"
        RESULTS_MAX_TOTAL_MB="'"${RESULTS_MAX_TOTAL_MB}"'"

        # 1. Age-based: delete run directories older than N days
        find "$RESULTS_BASE_DIR" -maxdepth 1 -mindepth 1 -type d \
            -mtime +"${RESULTS_MAX_AGE_DAYS}" -exec rm -rf {} + 2>/dev/null || true

        # 2. Count-based: keep only the most recent N directories
        ls -1dt "$RESULTS_BASE_DIR"/*/ 2>/dev/null \
            | tail -n +"$((RESULTS_MAX_RUNS + 1))" \
            | xargs -r rm -rf 2>/dev/null || true

        # 3. Size-based: delete oldest until under limit
        while [ "$(du -sm "$RESULTS_BASE_DIR" 2>/dev/null | cut -f1)" -gt "${RESULTS_MAX_TOTAL_MB}" ] 2>/dev/null; do
            OLDEST=$(ls -1dt "$RESULTS_BASE_DIR"/*/ 2>/dev/null | tail -1)
            [ -z "$OLDEST" ] && break
            rm -rf "$OLDEST"
        done
    '
    echo "[INFO] Log rotation complete"
}

if [ "${ROTATE_LOGS_ONLY}" = true ]; then
    rotate_logs
    exit 0
fi

# =========================================================================
# Validation
# =========================================================================
if [ -z "${RUNTIME}" ]; then
    echo "[ERROR] --runtime is required"
    usage
    exit 1
fi

# =========================================================================
# Test case discovery
# =========================================================================
declare -A TC_NAMES
TC_NAMES=(
    [01]="Basic Upgrade"
    [02]="Auto-Rollback Verification Failure"
    [03]="Manual Rollback"
    [04]="Taint and Combined Selection"
    [05]="Upgrade with Drain"
    [06]="Custom Image Upgrade"
    [07]="Verification Pod Override"
    [08]="No Matching Nodes"
    [09]="Timeout Auto-Rollback"
    [10]="Same Version Re-upgrade"
    [11]="No Workload Disruption"
    [12]="DaemonSet Target Node Only"
    [13]="Node-by-Node Sequential"
    [14]="Partial Failure Stops"
    [15]="Drain Multi-Node"
)

declare -A TC_FILES
for num in "${!TC_NAMES[@]}"; do
    pattern="${SCRIPT_DIR}/playbooks/tc${num}_*.yaml"
    # shellcheck disable=SC2086
    file=$(ls ${pattern} 2>/dev/null | head -1)
    if [ -n "${file}" ]; then
        TC_FILES[${num}]="${file}"
    fi
done

# Filter test cases
if [ "${TC_FILTER}" = "all" ]; then
    SELECTED_TCS=($(echo "${!TC_NAMES[@]}" | tr ' ' '\n' | sort))
else
    IFS=',' read -ra SELECTED_TCS <<< "${TC_FILTER}"
    # Zero-pad single digits
    for i in "${!SELECTED_TCS[@]}"; do
        SELECTED_TCS[$i]=$(printf "%02d" "${SELECTED_TCS[$i]}")
    done
fi

# =========================================================================
# Setup
# =========================================================================
echo "=================================================================="
echo "  KATA LIFECYCLE MANAGER E2E TESTS"
echo "=================================================================="
echo "  Runtime:      ${RUNTIME}"
echo "  Test cases:   ${SELECTED_TCS[*]}"
echo "  Results dir:  ${RESULTS_DIR}"
echo "=================================================================="
echo ""

rotate_logs

mkdir -p "${RESULTS_DIR}/logs"
echo "[]" > "${RESULTS_DIR}/results.json"

# Build extra-vars for ansible-playbook
EXTRA_VARS="kata_runtime_class=${RUNTIME}"
EXTRA_VARS="${EXTRA_VARS} skip_cluster_create=${SKIP_CLUSTER_CREATE}"
EXTRA_VARS="${EXTRA_VARS} skip_cluster_delete=${SKIP_CLUSTER_DELETE}"
if [ -n "${FROM_VERSION}" ]; then
    EXTRA_VARS="${EXTRA_VARS} kata_from_version=${FROM_VERSION}"
fi
if [ -n "${TO_VERSION}" ]; then
    EXTRA_VARS="${EXTRA_VARS} kata_to_version=${TO_VERSION}"
fi
if [ -n "${TO_IMAGE}" ]; then
    EXTRA_VARS="${EXTRA_VARS} kata_to_image=${TO_IMAGE}"
fi

# Cluster name includes runtime to avoid conflicts with parallel jobs
CLUSTER_NAME="kata-e2e-${RUNTIME}"
EXTRA_VARS="${EXTRA_VARS} cluster_name=${CLUSTER_NAME}"

# Run setup playbook
echo "[INFO] Running setup playbook..."
if ansible-playbook \
    -e "${EXTRA_VARS}" \
    "${SCRIPT_DIR}/playbooks/setup.yaml" \
    2>&1 | tee "${RESULTS_DIR}/logs/setup.log"; then
    echo "[INFO] Setup completed successfully"
else
    echo "[FAIL] Setup failed. See ${RESULTS_DIR}/logs/setup.log"
    exit 1
fi

# =========================================================================
# Run test cases
# =========================================================================
TOTAL=0
PASSED=0
FAILED=0
SUITE_START=$(date +%s)

for tc_num in "${SELECTED_TCS[@]}"; do
    tc_name="${TC_NAMES[${tc_num}]:-Unknown}"
    tc_file="${TC_FILES[${tc_num}]:-}"
    tc_log="${RESULTS_DIR}/logs/tc${tc_num}.log"

    if [ -z "${tc_file}" ]; then
        echo "[SKIP] TC-${tc_num}: ${tc_name} (playbook not found)"
        continue
    fi

    TOTAL=$((TOTAL + 1))
    echo ""
    echo "------------------------------------------------------------------"
    echo "[RUN]  TC-${tc_num}: ${tc_name}"
    echo "------------------------------------------------------------------"

    TC_START=$(date +%s)

    if ansible-playbook \
        -e "${EXTRA_VARS}" \
        "${tc_file}" \
        2>&1 | tee "${tc_log}"; then
        TC_STATUS="PASSED"
        PASSED=$((PASSED + 1))
        TC_ERROR=""
    else
        TC_STATUS="FAILED"
        FAILED=$((FAILED + 1))
        TC_ERROR=$(tail -20 "${tc_log}" | grep -i "fail\|error\|assert" | head -3 | tr '\n' ' ' || echo "See log for details")
    fi

    TC_END=$(date +%s)
    TC_DURATION=$((TC_END - TC_START))

    echo "[${TC_STATUS}] TC-${tc_num}: ${tc_name} (${TC_DURATION}s)"

    # Append to results JSON
    RESULTS_JSON=$(cat "${RESULTS_DIR}/results.json")
    ENTRY=$(cat <<JSONEOF
{"number": "TC-${tc_num}", "name": "${tc_name}", "status": "${TC_STATUS}", "duration": ${TC_DURATION}, "error": "$(echo "${TC_ERROR}" | sed 's/"/\\"/g' | tr -d '\n')"}
JSONEOF
)
    echo "${RESULTS_JSON}" | python3 -c "
import sys, json
data = json.load(sys.stdin)
data.append(json.loads('${ENTRY}'))
json.dump(data, sys.stdout, indent=2)
" > "${RESULTS_DIR}/results.json"
done

SUITE_END=$(date +%s)
SUITE_DURATION=$((SUITE_END - SUITE_START))

# =========================================================================
# Generate reports
# =========================================================================

# -- JUnit XML --
python3 - "${RESULTS_DIR}/results.json" "${RESULTS_DIR}/junit.xml" "${RUNTIME}" <<'PYEOF'
import json, sys, html

results_file, output_file, runtime = sys.argv[1], sys.argv[2], sys.argv[3]

with open(results_file) as f:
    results = json.load(f)

total = len(results)
failures = sum(1 for r in results if r["status"] == "FAILED")
total_time = sum(r["duration"] for r in results)

lines = [
    '<?xml version="1.0" encoding="UTF-8"?>',
    f'<testsuites>',
    f'  <testsuite name="kata-lifecycle-manager-e2e ({runtime})" tests="{total}" failures="{failures}" time="{total_time}">',
]

for r in results:
    tc_name = f'{r["number"]}: {r["name"]}'
    if r["status"] == "PASSED":
        lines.append(f'    <testcase name="{html.escape(tc_name)}" classname="{runtime}" time="{r["duration"]}" />')
    else:
        error_msg = html.escape(r.get("error", "See log for details"))
        lines.append(f'    <testcase name="{html.escape(tc_name)}" classname="{runtime}" time="{r["duration"]}">')
        lines.append(f'      <failure message="{error_msg}">{error_msg}</failure>')
        lines.append(f'    </testcase>')

lines.append('  </testsuite>')
lines.append('</testsuites>')

with open(output_file, 'w') as f:
    f.write('\n'.join(lines) + '\n')
PYEOF

# -- Summary table (stdout) --
echo ""
echo "=================================================================="
echo "  KATA LIFECYCLE MANAGER E2E RESULTS -- ${RUNTIME}"
echo "=================================================================="

for tc_num in "${SELECTED_TCS[@]}"; do
    tc_name="${TC_NAMES[${tc_num}]:-Unknown}"
    # Read status and duration from results.json
    read -r status duration <<< "$(python3 -c "
import json
with open('${RESULTS_DIR}/results.json') as f:
    for r in json.load(f):
        if r['number'] == 'TC-${tc_num}':
            m, s = divmod(r['duration'], 60)
            print(r['status'], f'{m}m{s:02d}s')
            break
" 2>/dev/null || echo "SKIP 0m00s")"
    printf "  TC-%s  %-45s %-8s %s\n" "${tc_num}" "${tc_name}" "${status}" "${duration}"
done

echo "------------------------------------------------------------------"
SUITE_MIN=$((SUITE_DURATION / 60))
SUITE_SEC=$((SUITE_DURATION % 60))
echo "  Total: ${TOTAL} | Passed: ${PASSED} | Failed: ${FAILED} | Duration: ${SUITE_MIN}m${SUITE_SEC}s"
echo "=================================================================="

# -- Markdown summary --
cat > "${RESULTS_DIR}/summary.md" <<MDEOF
| Test Case | Name | Status | Duration |
|-----------|------|--------|----------|
MDEOF

python3 -c "
import json
with open('${RESULTS_DIR}/results.json') as f:
    for r in json.load(f):
        m, s = divmod(r['duration'], 60)
        status = r['status']
        print(f'| {r[\"number\"]} | {r[\"name\"]} | {status} | {m}m{s:02d}s |')
" >> "${RESULTS_DIR}/summary.md"

echo "" >> "${RESULTS_DIR}/summary.md"
echo "**Total: ${TOTAL} | Passed: ${PASSED} | Failed: ${FAILED} | Duration: ${SUITE_MIN}m${SUITE_SEC}s**" >> "${RESULTS_DIR}/summary.md"

# -- Copy to persistent results dir --
if [ -d "${RESULTS_BASE_DIR}" ]; then
    TIMESTAMP=$(date +%Y-%m-%d_%H%M%S)
    PERSIST_DIR="${RESULTS_BASE_DIR}/${TIMESTAMP}-${RUNTIME}"
    cp -r "${RESULTS_DIR}" "${PERSIST_DIR}" 2>/dev/null || true
fi

# =========================================================================
# Teardown
# =========================================================================
if [ "${SKIP_CLUSTER_DELETE}" != true ]; then
    echo ""
    echo "[INFO] Running teardown playbook..."
    ansible-playbook \
        -e "${EXTRA_VARS}" \
        "${SCRIPT_DIR}/playbooks/teardown.yaml" \
        2>&1 | tee "${RESULTS_DIR}/logs/teardown.log" || true
fi

# =========================================================================
# Exit
# =========================================================================
if [ "${FAILED}" -gt 0 ]; then
    echo ""
    echo "[FAIL] ${FAILED} of ${TOTAL} test(s) failed"
    exit 1
else
    echo ""
    echo "[PASS] All ${TOTAL} tests passed"
    exit 0
fi
