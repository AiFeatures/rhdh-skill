#!/usr/bin/env bash
#
# Update base images and RPM lockfiles in RHDH upstream GitHub repos.
# See skills/base-images-and-rpms/SKILL.md (1-rhdh-skill)
#
# SPDX-License-Identifier: EPL-2.0

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
SKILL_DIR=$(cd "${SCRIPT_DIR}/.." && pwd)

BRANCH=""
UPDATE_BASE_IMAGES_SCRIPT=""
RPM_LOCKFILE_PROTOTYPE=""
REPO_DIRS=()
SKIP_BASE=0
SKIP_RPM=0
DRY_RUN=0
ALLOW_DIRTY=0
BASE_IMAGE_ARGS=(--pr --no-push)

GITLAB_SCRIPTS_BASE="https://gitlab.cee.redhat.com/rhidp/rhdh/-/raw"
CACHE_DIR="${XDG_CACHE_HOME:-${HOME}/.cache}/base-images-and-rpms"

usage() {
    cat <<'EOF'
Update base images and RPM lockfiles in rhdh, rhdh-must-gather, and rhdh-operator.

Usage:
  base-images-and-rpms.sh -b BRANCH [OPTIONS] [REPO_DIR ...]

Required:
  -b, --branch BRANCH       Branch to update: main or release-* (e.g. release-1.10)

Optional paths (fetch/install when omitted):
  --update-base-images-script PATH   Path to updateBaseImages.sh (needs createPR.sh alongside)
  --rpm-lockfile-prototype PATH      Path to rpm-lockfile-prototype binary

Repo selection (default: all three under --parent-dir, or current directory if it matches one repo):
  --parent-dir PATH         Directory containing local clones (e.g. ~/RHDH/)
  REPO_DIR ...              One or more repo checkouts to update

Workflow:
  --skip-base               Skip updateBaseImages.sh
  --skip-rpm                Skip rpm-lockfile-prototype
  --dirty                   Pass --dirty to updateBaseImages.sh
  --push                    Allow updateBaseImages.sh to push (default: --pr --no-push)
  --no-pr                   Attempt direct push instead of opening a PR
  --dry-run                 Print actions without changing files

Examples:
  base-images-and-rpms.sh -b release-1.10 --parent-dir ~/RHDH/
  base-images-and-rpms.sh -b main \
    --update-base-images-script ~/src/rhdh/build/scripts/updateBaseImages.sh \
    ~/RHDH/rhdh ~/RHDH/rhdh-operator ~/RHDH/rhdh-must-gather
EOF
}

die() {
    echo "[ERROR] $*" >&2
    exit 1
}

log() {
    echo "[INFO] $*"
}

warn() {
    echo "[WARN] $*" >&2
}

validate_branch() {
    local branch="$1"
    if [[ "${branch}" == "main" ]] || [[ "${branch}" =~ ^release-.+ ]]; then
        return 0
    fi
    die "Invalid branch '${branch}'. Expected main or release-*"
}

scripts_branch_for() {
    local branch="$1"
    if [[ "${branch}" == "main" ]]; then
        echo "rhdh-1-rhel-9"
    elif [[ "${branch}" =~ ^release-(.+)$ ]]; then
        echo "rhdh-${BASH_REMATCH[1]}-rhel-9"
    else
        die "No GitLab scripts branch mapping for ${branch}"
    fi
}

detect_repo_kind() {
    local repo_dir="$1"
    if [[ -f "${repo_dir}/build/containerfiles/Containerfile" && -f "${repo_dir}/rpms.in.yaml" ]]; then
        echo "rhdh"
    elif [[ -f "${repo_dir}/.rhdh/docker/Dockerfile" && -f "${repo_dir}/rpms.in.yaml" ]]; then
        echo "rhdh-operator"
    elif [[ -f "${repo_dir}/Containerfile" && -f "${repo_dir}/rpms.in.yaml" && -d "${repo_dir}/collection-scripts" ]]; then
        echo "rhdh-must-gather"
    else
        echo "unknown"
    fi
}

rpm_containerfile_for() {
    local kind="$1"
    case "${kind}" in
        rhdh) echo "build/containerfiles/Containerfile" ;;
        rhdh-operator) echo ".rhdh/docker/Dockerfile" ;;
        rhdh-must-gather) echo "Containerfile" ;;
        *) die "Unknown repo kind '${kind}'" ;;
    esac
}

ensure_tools() {
    local tool
    for tool in "$@"; do
        command -v "${tool}" >/dev/null 2>&1 || die "${tool} is required"
    done
}

fetch_gitlab_script() {
    local scripts_branch="$1"
    local script_name="$2"
    local dest_dir="$3"
    local url="${GITLAB_SCRIPTS_BASE}/${scripts_branch}/build/scripts/${script_name}"
    mkdir -p "${dest_dir}"
    if [[ ! -f "${dest_dir}/${script_name}" ]]; then
        log "Downloading ${script_name} from ${scripts_branch}"
        curl -fsSL "${url}" -o "${dest_dir}/${script_name}"
        chmod +x "${dest_dir}/${script_name}"
    fi
}

resolve_update_base_images_script() {
    local scripts_branch="$1"
    if [[ -n "${UPDATE_BASE_IMAGES_SCRIPT}" ]]; then
        [[ -f "${UPDATE_BASE_IMAGES_SCRIPT}" ]] || die "updateBaseImages.sh not found: ${UPDATE_BASE_IMAGES_SCRIPT}"
        [[ -x "${UPDATE_BASE_IMAGES_SCRIPT}" ]] || chmod +x "${UPDATE_BASE_IMAGES_SCRIPT}"
        local script_parent
        script_parent=$(cd "$(dirname "${UPDATE_BASE_IMAGES_SCRIPT}")" && pwd)
        if [[ ! -f "${script_parent}/createPR.sh" ]]; then
            fetch_gitlab_script "${scripts_branch}" "createPR.sh" "${script_parent}"
        fi
        echo "${UPDATE_BASE_IMAGES_SCRIPT}"
        return 0
    fi

    local cached="${CACHE_DIR}/${scripts_branch}/updateBaseImages.sh"
    fetch_gitlab_script "${scripts_branch}" "updateBaseImages.sh" "${CACHE_DIR}/${scripts_branch}"
    fetch_gitlab_script "${scripts_branch}" "createPR.sh" "${CACHE_DIR}/${scripts_branch}"
    echo "${cached}"
}

resolve_rpm_lockfile_prototype() {
    if [[ -n "${RPM_LOCKFILE_PROTOTYPE}" ]]; then
        [[ -x "${RPM_LOCKFILE_PROTOTYPE}" ]] || die "rpm-lockfile-prototype is not executable: ${RPM_LOCKFILE_PROTOTYPE}"
        echo "${RPM_LOCKFILE_PROTOTYPE}"
        return 0
    fi
    if [[ -x "${HOME}/.local/bin/rpm-lockfile-prototype" ]]; then
        echo "${HOME}/.local/bin/rpm-lockfile-prototype"
        return 0
    fi
    log "Installing rpm-lockfile-prototype to ${HOME}/.local/bin"
    mkdir -p "${HOME}/.local/bin"
    python3 -m pip install --user \
        https://github.com/konflux-ci/rpm-lockfile-prototype/archive/refs/heads/main.zip 2>/dev/null
    [[ -x "${HOME}/.local/bin/rpm-lockfile-prototype" ]] \
        || die "rpm-lockfile-prototype install failed; pass --rpm-lockfile-prototype PATH"
    echo "${HOME}/.local/bin/rpm-lockfile-prototype"
}

discover_repos_in_parent() {
    local parent="$1"
    local candidate kind
    for candidate in \
        "${parent}/1-rhdh" "${parent}/rhdh" \
        "${parent}/1-rhdh-operator" "${parent}/rhdh-operator" \
        "${parent}/1-must-gather" "${parent}/1-rhdh-must-gather" "${parent}/rhdh-must-gather"; do
        [[ -d "${candidate}/.git" ]] || continue
        kind=$(detect_repo_kind "${candidate}")
        [[ "${kind}" != "unknown" ]] || continue
        REPO_DIRS+=("${candidate}")
    done
}

checkout_branch() {
    local repo_dir="$1"
    local branch="$2"
    pushd "${repo_dir}" >/dev/null
    git fetch origin "${branch}" 2>/dev/null || true
    if git show-ref --verify --quiet "refs/remotes/origin/${branch}"; then
        git checkout "${branch}"
        git pull --ff-only origin "${branch}" 2>/dev/null || true
    elif git show-ref --verify --quiet "refs/heads/${branch}"; then
        git checkout "${branch}"
    else
        popd >/dev/null
        die "${repo_dir}: branch ${branch} not found"
    fi
    popd >/dev/null
}

update_base_images() {
    local repo_dir="$1"
    local branch="$2"
    local scripts_branch="$3"
    local update_script="$4"
    local extra=()
    [[ ${ALLOW_DIRTY} -eq 1 ]] && extra+=(--dirty)

    log "Base images: $(basename "${repo_dir}") @ ${branch} (scripts branch ${scripts_branch})"
    if [[ ${DRY_RUN} -eq 1 ]]; then
        echo "  dry-run: ${update_script} -w ${repo_dir} -b ${branch} -sb ${scripts_branch} -maxdepth 5 ${BASE_IMAGE_ARGS[*]} ${extra[*]}"
        return 0
    fi

    pushd "${repo_dir}" >/dev/null
    git config user.name "rhdh-bot" 2>/dev/null || true
    git config user.email "rhdh-bot@redhat.com" 2>/dev/null || true
    popd >/dev/null

    # createPR.sh runs `gh pr view --web` on every createPr() call; updateBaseImages.sh
    # calls createPr once per image bump. Suppress repeated browser opens and show once below.
    GITLAB_PIPELINE=true "${update_script}" -w "${repo_dir}" -b "${branch}" -sb "${scripts_branch}" \
        -maxdepth 5 "${BASE_IMAGE_ARGS[@]}" "${extra[@]}" \
        || warn "updateBaseImages.sh reported no change or failed for ${repo_dir}"

    if [[ " ${BASE_IMAGE_ARGS[*]} " == *" --pr "* ]]; then
        open_automation_pr_in_browser "${repo_dir}" "${branch}"
    fi
}

open_automation_pr_in_browser() {
    local repo_dir="$1"
    local branch="$2"
    local pr_branch

    command -v gh >/dev/null 2>&1 || return 0
    pushd "${repo_dir}" >/dev/null
    pr_branch=$(find_open_base_images_pr_branch "${branch}" || true)
    if [[ -n "${pr_branch}" ]]; then
        log "Opening PR once for ${branch} (${pr_branch})"
        gh pr view "${pr_branch}" --web 2>/dev/null || true
    fi
    popd >/dev/null
}

update_rpm_lockfile() {
    local repo_dir="$1"
    local kind="$2"
    local rpm_tool="$3"
    local branch="$4"
    local containerfile
    containerfile=$(rpm_containerfile_for "${kind}")

    [[ -f "${repo_dir}/${containerfile}" ]] || die "${repo_dir}: missing ${containerfile}"
    [[ -f "${repo_dir}/rpms.in.yaml" ]] || die "${repo_dir}: missing rpms.in.yaml"

    log "RPM lockfile: $(basename "${repo_dir}") using ${containerfile}"
    if [[ ${DRY_RUN} -eq 1 ]]; then
        echo "  dry-run: (cd ${repo_dir} && ${rpm_tool} -f ${containerfile} rpms.in.yaml)"
        echo "  dry-run: commit and push rpms.lock.yaml to open base-images PR branch (or chore/automated-update-rpm-lockfile/${branch})"
        return 0
    fi

    pushd "${repo_dir}" >/dev/null
    "${rpm_tool}" -f "${containerfile}" rpms.in.yaml \
        || warn "rpm-lockfile-prototype failed for ${repo_dir}; keeping existing rpms.lock.yaml"
    commit_push_rpm_lockfile "${branch}"
    popd >/dev/null
}

find_open_base_images_pr_branch() {
    local base_branch="$1"
    if ! command -v gh >/dev/null 2>&1; then
        return 0
    fi
    gh pr list --base "${base_branch}" --state open --author "rhdh-bot" \
        --json headRefName \
        --jq '.[] | select(.headRefName | startswith("chore/automated-update-base-images")) | .headRefName' \
        2>/dev/null | head -n1
}

ensure_automation_branch() {
    local branch="$1"
    local current
    current=$(git rev-parse --abbrev-ref HEAD)

    if [[ "${current}" != "${branch}" ]]; then
        printf '%s\n' "${current}"
        return 0
    fi

    local pr_branch
    pr_branch=$(find_open_base_images_pr_branch "${branch}" || true)
    if [[ -n "${pr_branch}" ]]; then
        log "Switching to open base-images PR branch ${pr_branch}" >&2
        git checkout "${pr_branch}"
        printf '%s\n' "${pr_branch}"
        return 0
    fi

    local rpm_branch="chore/automated-update-rpm-lockfile/${branch}"
    log "No automation PR branch; using ${rpm_branch}" >&2
    git checkout -B "${rpm_branch}"
    printf '%s\n' "${rpm_branch}"
}

commit_push_paths() {
    local branch="$1"
    local message="$2"
    shift 2
    local paths=("$@")

    if [[ ${#paths[@]} -eq 0 ]]; then
        return 0
    fi

    local has_changes=0 path
    for path in "${paths[@]}"; do
        if ! git diff --quiet -- "${path}" 2>/dev/null \
            || ! git diff --cached --quiet -- "${path}" 2>/dev/null \
            || [[ -n "$(git ls-files --others --exclude-standard -- "${path}")" ]]; then
            has_changes=1
            break
        fi
    done
    if [[ ${has_changes} -eq 0 ]]; then
        return 0
    fi

    local current push_branch
    current=$(git rev-parse --abbrev-ref HEAD)
    push_branch="${current}"

    if [[ "${current}" == "${branch}" ]]; then
        push_branch=$(ensure_automation_branch "${branch}")
    fi

    git add "${paths[@]}"
    if git diff --cached --quiet; then
        log "Nothing to commit for: ${paths[*]}"
        return 0
    fi

    git commit -s -m "${message}"
    git push -u origin "${push_branch}"
    log "Pushed ${message} to origin/${push_branch}"

    if [[ "${push_branch}" == chore/automated-update-rpm-lockfile/* ]] \
        && command -v gh >/dev/null 2>&1 \
        && ! gh pr list --head "${push_branch}" --state open --json number -q '.[0].number' 2>/dev/null | grep -q .; then
        gh pr create \
            --base "${branch}" \
            --head "${push_branch}" \
            --title "chore: update RPM lockfile in branch (${branch}) [skip-build]" \
            --body "Automated RPM lockfile refresh from base-images-and-rpms.sh." \
            2>/dev/null \
            || warn "Could not open RPM lockfile PR for ${push_branch}"
    fi
}

rhdh_nodejs_builder_image() {
    local containerfile="$1"
    grep -E '^FROM registry\.access\.redhat\.com/ubi9/nodejs-[0-9]+:' "${containerfile}" \
        | grep -v minimal | head -1 | awk '{print $2}'
}

node_version_from_image() {
    local image="$1"
    local runner=podman
    command -v podman >/dev/null 2>&1 || runner=docker
    "${runner}" run --rm --entrypoint node "${image}" --version 2>/dev/null | tr -d '\n\r'
}

update_rhdh_node_headers() {
    local repo_dir="$1"
    local branch="$2"
    local containerfile="${repo_dir}/build/containerfiles/Containerfile"

    [[ -f "${containerfile}" ]] || return 0

    local image
    image=$(rhdh_nodejs_builder_image "${containerfile}")
    if [[ -z "${image}" ]]; then
        log "Node headers: no ubi9/nodejs builder image in Containerfile"
        return 0
    fi

    log "Node headers: checking node version from ${image##*/}"
    if [[ ${DRY_RUN} -eq 1 ]]; then
        echo "  dry-run: podman/docker run ${image} --version; refresh .nvm/releases if changed"
        return 0
    fi

    if ! command -v podman >/dev/null 2>&1 && ! command -v docker >/dev/null 2>&1; then
        warn "Node headers: podman or docker required; skipping"
        return 0
    fi

    pushd "${repo_dir}" >/dev/null

    local node_version node_version_plain headers_file current_nvmrc old
    node_version=$(node_version_from_image "${image}") || true
    if [[ -z "${node_version}" ]]; then
        warn "Node headers: could not read node version from ${image}"
        popd >/dev/null
        return 0
    fi

    node_version_plain="${node_version#v}"
    headers_file=".nvm/releases/node-${node_version}-headers.tar.gz"
    current_nvmrc=""
    [[ -f .nvmrc ]] && current_nvmrc=$(tr -d '\n\r' < .nvmrc)

    if [[ -f "${headers_file}" && "${current_nvmrc}" == "${node_version_plain}" ]]; then
        log "Node headers: already up to date (${node_version})"
        popd >/dev/null
        return 0
    fi

    log "Node headers: updating to ${node_version} (was ${current_nvmrc:-unset})"
    mkdir -p .nvm/releases
    curl -fsSL "https://nodejs.org/dist/${node_version}/node-${node_version}-headers.tar.gz" \
        -o "${headers_file}"
    echo "${node_version_plain}" > .nvmrc

    for old in .nvm/releases/node-v*-headers.tar.gz; do
        [[ -e "${old}" && "${old}" != "${headers_file}" ]] || continue
        if git ls-files --error-unmatch "${old}" >/dev/null 2>&1; then
            git rm -f "${old}"
        else
            rm -f "${old}"
        fi
    done

    commit_push_paths "${branch}" "chore: update node headers to ${node_version} [skip-build]" \
        .nvmrc "${headers_file}"
    popd >/dev/null
}

commit_push_rpm_lockfile() {
    local branch="$1"

    if git diff --quiet rpms.lock.yaml 2>/dev/null \
        && git diff --cached --quiet rpms.lock.yaml 2>/dev/null; then
        log "RPM lockfile: no changes in rpms.lock.yaml"
        return 0
    fi

    local current
    current=$(git rev-parse --abbrev-ref HEAD)
    if [[ "${current}" == "${branch}" ]]; then
        local pr_branch
        pr_branch=$(find_open_base_images_pr_branch "${branch}" || true)
        if [[ -n "${pr_branch}" ]]; then
            log "RPM lockfile: attaching to open base-images PR branch ${pr_branch}"
            git stash push -m "rpm-lock" -- rpms.lock.yaml
            git checkout "${pr_branch}"
            git stash pop || true
        else
            ensure_automation_branch "${branch}" >/dev/null
        fi
    fi

    commit_push_paths "${branch}" "chore: update rpms.lock.yaml [skip-build]" rpms.lock.yaml
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -b|--branch) BRANCH="$2"; shift 2 ;;
        --update-base-images-script) UPDATE_BASE_IMAGES_SCRIPT="$2"; shift 2 ;;
        --rpm-lockfile-prototype) RPM_LOCKFILE_PROTOTYPE="$2"; shift 2 ;;
        --parent-dir)
            discover_repos_in_parent "$2"
            shift 2
            ;;
        --skip-base) SKIP_BASE=1; shift ;;
        --skip-rpm) SKIP_RPM=1; shift ;;
        --dirty) ALLOW_DIRTY=1; shift ;;
        --push)
            BASE_IMAGE_ARGS=(--pr)
            shift
            ;;
        --no-pr)
            BASE_IMAGE_ARGS=(--no-push)
            shift
            ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) usage; exit 0 ;;
        --) shift; break ;;
        -*) die "Unknown option: $1 (try --help)" ;;
        *)
            [[ -d "$1/.git" ]] || die "Not a git repo: $1"
            REPO_DIRS+=("$1")
            shift
            ;;
    esac
done

while [[ $# -gt 0 ]]; do
    [[ -d "$1/.git" ]] || die "Not a git repo: $1"
    REPO_DIRS+=("$1")
    shift
done

[[ -n "${BRANCH}" ]] || { usage; exit 1; }
validate_branch "${BRANCH}"

if [[ ${#REPO_DIRS[@]} -eq 0 ]]; then
    if [[ -d ".git" ]] && [[ "$(detect_repo_kind "$(pwd)")" != "unknown" ]]; then
        REPO_DIRS=("$(pwd)")
    else
        die "No repo directories found. Pass REPO_DIR paths or --parent-dir."
    fi
fi

SCRIPTS_BRANCH=$(scripts_branch_for "${BRANCH}")

if [[ ${SKIP_BASE} -eq 0 ]]; then
    ensure_tools jq skopeo curl
    command -v gh >/dev/null 2>&1 || warn "gh not found; --pr will fail if updateBaseImages.sh needs to open a PR"
fi

UPDATE_SCRIPT=""
RPM_TOOL=""
if [[ ${SKIP_BASE} -eq 0 ]]; then
    UPDATE_SCRIPT=$(resolve_update_base_images_script "${SCRIPTS_BRANCH}")
fi
if [[ ${SKIP_RPM} -eq 0 ]]; then
    RPM_TOOL=$(resolve_rpm_lockfile_prototype)
fi
command -v gh >/dev/null 2>&1 || warn "gh not found; automation commits may not reach an open PR"

declare -A SEEN_KIND=()
for repo_dir in "${REPO_DIRS[@]}"; do
    repo_dir=$(cd "${repo_dir}" && pwd)
    kind=$(detect_repo_kind "${repo_dir}")
    [[ "${kind}" != "unknown" ]] || die "${repo_dir}: cannot detect repo type (rhdh, rhdh-operator, or rhdh-must-gather)"
    if [[ -n "${SEEN_KIND[${kind}]:-}" ]]; then
        warn "Skipping duplicate ${kind} repo: ${repo_dir}"
        continue
    fi
    SEEN_KIND[${kind}]=1

    echo "=================================================="
    log "Processing ${kind} (${repo_dir})"
    if [[ ${DRY_RUN} -eq 1 ]]; then
        log "dry-run: would checkout ${BRANCH} in ${repo_dir}"
    else
        checkout_branch "${repo_dir}" "${BRANCH}"
    fi

    if [[ ${SKIP_BASE} -eq 0 ]]; then
        update_base_images "${repo_dir}" "${BRANCH}" "${SCRIPTS_BRANCH}" "${UPDATE_SCRIPT}"
    fi
    if [[ ${SKIP_RPM} -eq 0 ]]; then
        update_rpm_lockfile "${repo_dir}" "${kind}" "${RPM_TOOL}" "${BRANCH}"
    fi
    if [[ "${kind}" == "rhdh" ]]; then
        update_rhdh_node_headers "${repo_dir}" "${BRANCH}"
    fi
done

log "Done. Review open PRs for base image, RPM lockfile, and node header updates."
