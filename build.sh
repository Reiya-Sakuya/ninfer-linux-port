#!/usr/bin/env bash
# build.sh — one-command Linux build for ninfer-fusion-kvmem.
#
#   ./build.sh /path/to/ninfer-fusion-kvmem/src-tree/fusion-engine-src
#
# Takes 1.5-2 hours. That is normal -- small_t_i8 is slow.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="nvidia/cuda:13.3.0-devel-ubuntu24.04"
CONTAINER="ninfer-build-$$"
BUILD_ROOT="/tmp/ninfer-build-$$"
ARCH="${NINFER_CUDA_ARCH:-86}"
PARALLEL="${NINFER_PARALLEL:-2}"

die() { echo "error: $*" >&2; exit 1; }
say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

# ---------------------------------------------------------------- prereqs
SRC="${1:-}"
[[ -n "$SRC" ]] || die "usage: $0 <path-to>/src-tree/fusion-engine-src"
SRC="$(cd "$SRC" && pwd)"
[[ -d "$SRC/src/models/qwen3_8_flash_next" ]] \
    || die "$SRC does not look like fusion-engine-src (missing src/models/qwen3_8_flash_next)"

command -v docker >/dev/null || die "docker not found"
docker info >/dev/null 2>&1 || die "cannot talk to docker daemon"

# Build RAM: nvcc heavy TUs need ~3 GiB per parallel job plus slack.
AVAIL_GIB=$(awk '/MemAvailable/{printf "%d", $2/1024/1024}' /proc/meminfo)
NEED_GIB=$(( PARALLEL * 3 + 8 ))
(( AVAIL_GIB >= NEED_GIB )) || \
    die "need ~${NEED_GIB} GiB available RAM for --parallel ${PARALLEL}, have ${AVAIL_GIB} GiB.
       Lower it with: NINFER_PARALLEL=1 $0 ...   (slower but safer)"

# ---------------------------------------------------------------- copy + patch
say "copying source tree (patches go on the copy, your tree is untouched)"
mkdir -p "$BUILD_ROOT"
cp -a "$SRC" "$BUILD_ROOT/src"

say "applying Linux port patches"
( cd "$BUILD_ROOT/src" && bash "$REPO_DIR/apply.sh" . )

# ---------------------------------------------------------------- image
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    say "pulling $IMAGE (~7 GB, one time)"
    docker pull "$IMAGE"
fi

# ---------------------------------------------------------------- build
cleanup() {
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    rm -rf "$BUILD_ROOT"
}
trap cleanup EXIT INT TERM

# tmpfs for the build dir: CUDA compiles generate a lot of small files, and
# writing those to btrfs has been observed to lock up the whole filesystem.
TMPFS_GIB=8
say "starting build container (tmpfs ${TMPFS_GIB}G, --parallel ${PARALLEL}, sm_${ARCH})"
docker run -d --name "$CONTAINER" \
    --memory "${NEED_GIB}g" --memory-swap "${NEED_GIB}g" \
    --tmpfs "/tmpfs:size=${TMPFS_GIB}g" \
    -v "$BUILD_ROOT/src:/src:ro" \
    "$IMAGE" sleep infinity >/dev/null

say "installing toolchain (~2 min)"
docker exec "$CONTAINER" bash -c '
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        cmake ninja-build gcc-13 g++-13 pkg-config \
        libavcodec-dev libavformat-dev libavutil-dev libswscale-dev libcurl4-openssl-dev \
        >/tmp/apt.log 2>&1 || { tail -30 /tmp/apt.log; exit 1; }
' || die "toolchain install failed"

say "compiling -- expect 1.5-2 hours"
docker exec "$CONTAINER" bash -c "
    export CC=/usr/bin/gcc-13 CXX=/usr/bin/g++-13
    export CUDACXX=/usr/local/cuda/bin/nvcc CUDAHOSTCXX=/usr/bin/g++-13
    cd /src
    cmake -S . -B /tmpfs/build -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_COMPILER=/usr/bin/gcc-13 \
        -DCMAKE_CXX_COMPILER=/usr/bin/g++-13 \
        -DCMAKE_CUDA_COMPILER=/usr/local/cuda/bin/nvcc \
        -DCMAKE_CUDA_HOST_COMPILER=/usr/bin/g++-13 \
        -DCMAKE_CUDA_ARCHITECTURES=${ARCH} \
        -DNINFER_BUILD_APPS=ON -DBUILD_TESTING=OFF -DNINFER_BUILD_BENCHMARKS=OFF \
    && cmake --build /tmpfs/build --parallel ${PARALLEL}
" || die "build failed -- see compiler output above"

# ---------------------------------------------------------------- collect
say "collecting artifact"
mkdir -p "$REPO_DIR/dist"
docker cp "$CONTAINER:/tmpfs/build/apps/ninfer-serve" "$REPO_DIR/dist/ninfer-serve"
chmod +x "$REPO_DIR/dist/ninfer-serve"

say "done"
ls -lh "$REPO_DIR/dist/ninfer-serve"
echo
echo "  binary : $REPO_DIR/dist/ninfer-serve"
echo "  sha256 : $(sha256sum "$REPO_DIR/dist/ninfer-serve" | cut -d' ' -f1)"
echo "  arch   : sm_${ARCH}"
echo "Runtime deps (Ubuntu 24.04):"
echo "  sudo apt install libavformat60 libavcodec60 libavutil58 libswscale7 libcurl4"
