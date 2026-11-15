#!/usr/bin/env bash
# [ps5 port] Build the PS5 app (PPSA92046) on a Linux box from nothing but this
# repository and the player's own default.xbe. Written for the Dell's WSL
# distro "Blazing" (Ubuntu 24.04, clang-18/20, cmake, ninja, meson, python3.12),
# usable on any similar Linux.
#
#   bash ps5/tools/dell-build.sh [stage...]
#
# Stages (default: all, in this order; each skips what is already done):
#   src      clone/update this repo's branch into $W/src   (REPO, BRANCH)
#   tri      Nazky/ps5-plume-triangle: payload SDK, zlib, RADV release with
#            ps5/patches/radv-videoout-frame-rate.patch applied
#   prefix   SDL3 $SDL3_VERSION, glslang $GLSLANG_VERSION and RADV's Vulkan
#            headers built/installed for the PS5 into $W/prefix
#   imgui    Dear ImGui v1.92.9b (the version cmake/imgui.cmake pins)
#   gen      the lifted game code: scripts/pipeline-state.py analyze + lift on
#            $XBE (the player's own USA default.xbe; never committed)
#   build    cmake + ninja defjam_recomp
#   package  ps5/tools/ps5_package.sh -> build/ps5/ps5-app/PPSA92046
#   tar      $W/out/defjam-ps5-PPSA92046-<rev>.tar.gz of the app folder,
#            without GameData's contents (the player adds the game files)
#
# Environment: W (work dir, /root/defjam-ps5), XBE (default.xbe path, default
# $W/xbe/default.xbe), JOBS (12), REPO, BRANCH, SRC (use this checkout instead
# of cloning).
set -euo pipefail

W=${W:-/root/defjam-ps5}
REPO=${REPO:-https://github.com/Kaoz625/defjam-ps5.git}
BRANCH=${BRANCH:-blz/ps5-1.1.2}
SRC=${SRC:-$W/src}
XBE=${XBE:-$W/xbe/default.xbe}
JOBS=${JOBS:-12}
TRI=$W/ps5-plume-triangle
TRI_REV=${TRI_REV:-main}
PREFIX=$W/prefix
SDL3_VERSION=${SDL3_VERSION:-3.4.18}
GLSLANG_VERSION=${GLSLANG_VERSION:-14.3.0}
IMGUI_VERSION=1.92.9b
IMGUI_DIR=$W/imgui-$IMGUI_VERSION
BUILD=$SRC/build/ps5
TITLE=PPSA92046

log() { echo "[$(date +%H:%M:%S)] $*"; }
mkdir -p "$W" "$W/logs" "$W/dl"

stage_src() {
    if [[ $SRC != "$W/src" ]]; then log "src: using $SRC as it is"; return; fi
    if [[ ! -d $SRC/.git ]]; then
        log "src: cloning $REPO $BRANCH"
        git clone --branch "$BRANCH" "$REPO" "$SRC"
    else
        log "src: updating to origin/$BRANCH"
        git -C "$SRC" fetch origin "$BRANCH"
        git -C "$SRC" checkout -q -B "$BRANCH" "origin/$BRANCH"
    fi
    log "src: $(git -C "$SRC" log --oneline -1)"
}

stage_tri() {
    if [[ ! -d $TRI/.git ]]; then
        log "tri: cloning Nazky/ps5-plume-triangle"
        git clone https://github.com/Nazky/ps5-plume-triangle.git "$TRI"
        git -C "$TRI" checkout -q "$TRI_REV"
    fi
    log "tri: $(git -C "$TRI" log --oneline -1)"
    (cd "$TRI" && bash tools/setup-native-dependencies.sh) > "$W/logs/tri-deps.log" 2>&1 ||
        { tail -30 "$W/logs/tri-deps.log"; exit 1; }
    local radv=$TRI/.deps/native/radv-release src=$TRI/.deps/work/radv-src
    local patch=$SRC/ps5/patches/radv-videoout-frame-rate.patch
    if [[ ! -f $radv/PROVENANCE.txt ]] || ! grep -q "^patch: radv-videoout-frame-rate" "$radv/PROVENANCE.txt"; then
        # First pass fetches the pinned Mesa into radv-src (and builds it); then the
        # 60/120 Hz patch goes in and RADV is rebuilt incrementally.
        if [[ ! -f $src/.revision ]]; then
            log "tri: RADV release, first pass (fetches PS5_Mesa)"
            (cd "$TRI" && bash tools/build-radv.sh release) > "$W/logs/radv-1.log" 2>&1 ||
                { tail -30 "$W/logs/radv-1.log"; exit 1; }
        fi
        if patch -d "$src" -p1 --dry-run --forward -s < <(sed -n '/^--- /,$p' "$patch") >/dev/null 2>&1; then
            log "tri: applying radv-videoout-frame-rate.patch"
            patch -d "$src" -p1 --forward -s < <(sed -n '/^--- /,$p' "$patch")
        else
            log "tri: radv-videoout-frame-rate.patch already in radv-src (or does not apply: check)"
            patch -d "$src" -p1 -R --dry-run -s < <(sed -n '/^--- /,$p' "$patch") >/dev/null ||
                { echo "the RADV patch neither applies nor is applied" >&2; exit 1; }
        fi
        rm -f "$radv/PROVENANCE.txt"
        log "tri: RADV release with the patch"
        (cd "$TRI" && bash tools/build-radv.sh release) > "$W/logs/radv-2.log" 2>&1 ||
            { tail -30 "$W/logs/radv-2.log"; exit 1; }
        echo "patch: radv-videoout-frame-rate ($(sha256sum "$patch" | cut -c1-16))" >> "$radv/PROVENANCE.txt"
    fi
    log "tri: $(grep -E '^(revision|archive sha256|patch):' "$radv/PROVENANCE.txt" | tr '\n' ' ')"
}

# The PS5 toolchain the game itself uses, for the libraries in the prefix.
ps5_cmake() {
    cmake -G Ninja -DCMAKE_TOOLCHAIN_FILE="$SRC/ps5/cmake/ps5-toolchain.cmake" \
        -DPS5_PAYLOAD_SDK="$TRI/.deps/native/ps5-payload-sdk" -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_POSITION_INDEPENDENT_CODE=ON "$@"
}

stage_prefix() {
    mkdir -p "$PREFIX/include"
    if [[ ! -f $PREFIX/include/vulkan/vulkan_core.h ]]; then
        log "prefix: Vulkan headers from the RADV build (the same ones RADV was built with)"
        cp -r "$TRI/.deps/native/radv-release/include/vulkan" "$PREFIX/include/"
        [[ -d $TRI/.deps/native/radv-release/include/vk_video ]] &&
            cp -r "$TRI/.deps/native/radv-release/include/vk_video" "$PREFIX/include/"
    fi
    if [[ ! -f $PREFIX/lib/libSDL3.a ]]; then
        log "prefix: SDL3 $SDL3_VERSION"
        local t=$W/dl/SDL3-$SDL3_VERSION.tar.gz
        [[ -f $t ]] || wget -q -O "$t" "https://github.com/libsdl-org/SDL/releases/download/release-$SDL3_VERSION/SDL3-$SDL3_VERSION.tar.gz"
        rm -rf "$W/sdl3-src" && mkdir -p "$W/sdl3-src" && tar -xzf "$t" -C "$W/sdl3-src" --strip-components=1
        ps5_cmake -S "$W/sdl3-src" -B "$W/sdl3-build" \
            -DSDL_SHARED=OFF -DSDL_STATIC=ON -DSDL_TEST_LIBRARY=OFF -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF \
            -DSDL_UNIX_CONSOLE_BUILD=ON -DSDL_VIDEO=ON -DSDL_DUMMYVIDEO=ON -DSDL_RENDER=ON \
            -DSDL_X11=OFF -DSDL_WAYLAND=OFF -DSDL_KMSDRM=OFF -DSDL_OPENGL=OFF -DSDL_OPENGLES=OFF \
            -DSDL_VULKAN=OFF -DSDL_OFFSCREEN=OFF -DSDL_GPU=OFF -DSDL_AUDIO=OFF -DSDL_CAMERA=OFF \
            -DSDL_HIDAPI=OFF -DSDL_HAPTIC=OFF -DSDL_SENSOR=OFF -DSDL_POWER=OFF -DSDL_DIALOG=OFF \
            -DSDL_TRAY=OFF -DSDL_LIBUDEV=OFF -DSDL_DBUS=OFF -DSDL_IBUS=OFF -DSDL_PIPEWIRE=OFF \
            -DSDL_PULSEAUDIO=OFF -DSDL_ALSA=OFF -DSDL_JACK=OFF -DSDL_SNDIO=OFF -DSDL_OSS=OFF \
            -DSDL_LIBURING=OFF -DSDL_RPATH=OFF -DSDL_DEPS_SHARED=OFF -DSDL_CLOCK_GETTIME=ON \
            > "$W/logs/sdl3.log" 2>&1 || { tail -40 "$W/logs/sdl3.log"; exit 1; }
        ninja -C "$W/sdl3-build" -j "$JOBS" install >> "$W/logs/sdl3.log" 2>&1 ||
            { grep -E "error|FAILED" "$W/logs/sdl3.log" | head -30; exit 1; }
    fi
    if [[ ! -f $PREFIX/lib/cmake/glslang/glslang-config.cmake ]]; then
        log "prefix: glslang $GLSLANG_VERSION"
        local t=$W/dl/glslang-$GLSLANG_VERSION.tar.gz
        [[ -f $t ]] || wget -q -O "$t" "https://github.com/KhronosGroup/glslang/archive/refs/tags/$GLSLANG_VERSION.tar.gz"
        rm -rf "$W/glslang-src" && mkdir -p "$W/glslang-src" && tar -xzf "$t" -C "$W/glslang-src" --strip-components=1
        ps5_cmake -S "$W/glslang-src" -B "$W/glslang-build" \
            -DBUILD_SHARED_LIBS=OFF -DENABLE_OPT=OFF -DENABLE_GLSLANG_BINARIES=OFF -DGLSLANG_TESTS=OFF \
            -DENABLE_HLSL=ON -DENABLE_SPVREMAPPER=OFF -DGLSLANG_ENABLE_INSTALL=ON -DENABLE_CTEST=OFF \
            > "$W/logs/glslang.log" 2>&1 || { tail -40 "$W/logs/glslang.log"; exit 1; }
        ninja -C "$W/glslang-build" -j "$JOBS" install >> "$W/logs/glslang.log" 2>&1 ||
            { grep -E "error|FAILED" "$W/logs/glslang.log" | head -30; exit 1; }
    fi
    log "prefix: $(ls "$PREFIX/lib" | tr '\n' ' ')"
}

stage_imgui() {
    if [[ ! -f $IMGUI_DIR/imgui.cpp ]]; then
        log "imgui: v$IMGUI_VERSION"
        local t=$W/dl/imgui-$IMGUI_VERSION.tar.gz
        [[ -f $t ]] || wget -q -O "$t" "https://github.com/ocornut/imgui/archive/refs/tags/v$IMGUI_VERSION.tar.gz"
        echo "21d8a0a565e85dce943e375db00812c2f3f0ab21f3f0f7964e364a63422d7f99  $t" | sha256sum -c --strict
        mkdir -p "$IMGUI_DIR" && tar -xzf "$t" -C "$IMGUI_DIR" --strip-components=1
    fi
}

stage_gen() {
    local tk=$SRC/tools/xboxrecomp venv=$W/venv
    [[ -f $XBE ]] || { echo "no default.xbe at $XBE (the player's own USA dump)" >&2; exit 2; }
    echo "31cc0d11f7c656b1a6f337fdf7d9bbaac9df11c324a2fb881f7eb639d4be00c2  $XBE" | sha256sum -c --strict --quiet ||
        { echo "$XBE is not the USA default.xbe this port lifts" >&2; exit 2; }
    if [[ ! -x $venv/bin/python ]]; then
        log "gen: python venv (pyxbe, capstone)"
        python3.12 -m venv "$venv"
        "$venv/bin/pip" install -q pyxbe capstone
    fi
    if [[ -f $SRC/src/recomp/gen/recomp_dispatch.c && ${FORCE_GEN:-0} != 1 ]]; then
        log "gen: src/recomp/gen is there (FORCE_GEN=1 lifts again)"
        return
    fi
    mkdir -p "$tk/game_files"
    cp -f "$XBE" "$tk/game_files/default.xbe"
    log "gen: analyze (scripts/pipeline-state.py analyze)"
    (cd "$SRC" && "$venv/bin/python" scripts/pipeline-state.py analyze --toolkit "$tk") > "$W/logs/analyze.log" 2>&1 ||
        { tail -40 "$W/logs/analyze.log"; exit 1; }
    log "gen: lift (scripts/pipeline-state.py lift)"
    (cd "$SRC" && "$venv/bin/python" scripts/pipeline-state.py lift --toolkit "$tk" --split 1000 --) > "$W/logs/lift.log" 2>&1 ||
        { tail -40 "$W/logs/lift.log"; exit 1; }
    log "gen: $(ls "$SRC/src/recomp/gen" | wc -l) files in src/recomp/gen"
}

stage_build() {
    log "build: configure"
    cmake -S "$SRC" -B "$BUILD" -G Ninja -DCMAKE_TOOLCHAIN_FILE="$SRC/ps5/cmake/ps5-toolchain.cmake" \
        -DCMAKE_BUILD_TYPE=Release -DPS5_PAYLOAD_SDK="$TRI/.deps/native/ps5-payload-sdk" \
        -DDEFJAM_PS5_PREFIX="$PREFIX" -DFETCHCONTENT_SOURCE_DIR_IMGUI="$IMGUI_DIR" \
        > "$W/logs/configure.log" 2>&1 || { tail -40 "$W/logs/configure.log"; exit 1; }
    log "build: ninja defjam_recomp (-j$JOBS)"
    ninja -C "$BUILD" -j "$JOBS" -k 0 defjam_recomp > "$W/logs/build.log" 2>&1 ||
        { grep -E "error:|FAILED|undefined" "$W/logs/build.log" | head -60; exit 1; }
    log "build: done"
}

stage_package() {
    log "package: ps5_package.sh"
    (cd "$SRC" && PS5_PAYLOAD_SDK="$TRI/.deps/native/ps5-payload-sdk" \
        bash ps5/tools/ps5_package.sh "$BUILD" "$TRI" "$TITLE") > "$W/logs/package.log" 2>&1 ||
        { tail -40 "$W/logs/package.log"; exit 1; }
    log "package: $BUILD/ps5-app/$TITLE ($(du -sh "$BUILD/ps5-app/$TITLE" | cut -f1))"
}

stage_tar() {
    local rev app=$BUILD/ps5-app/$TITLE
    rev=$(git -C "$SRC" rev-parse --short HEAD)
    mkdir -p "$W/out"
    local out=$W/out/defjam-ps5-$TITLE-$rev.tar.gz
    # GameData holds only its README: the player copies the game files in on the console.
    [[ $(find "$app/GameData" -type f | wc -l) -le 1 ]] || { echo "$app/GameData holds game files" >&2; exit 1; }
    tar -C "$BUILD/ps5-app" -czf "$out" "$TITLE"
    (cd "$BUILD/ps5-app" && find "$TITLE" -type f -exec sha256sum {} +) > "$out.sha256"
    log "tar: $out ($(du -h "$out" | cut -f1)), eboot $(sha256sum "$app/eboot.bin" | cut -c1-16)"
}

stages=("$@")
[[ ${#stages[@]} -gt 0 ]] || stages=(src tri prefix imgui gen build package tar)
for s in "${stages[@]}"; do "stage_$s"; done
