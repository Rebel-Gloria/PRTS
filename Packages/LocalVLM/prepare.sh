#!/bin/bash
# Builds PRTSLocalVLM.xcframework (llama.cpp + mtmd + csrc/ wrapper, Metal embedded) and
# downloads the MiniCPM-V 4.7 weights into models/. Both are git-ignored: run this once after
# cloning or changing the wrapper or simulator backend, then build the app as usual.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
llama_commit=620d2225cc436ab0b001e3200e590e3b286ef9ab
work=$here/.build
src=$work/llama.cpp
jobs=${JOBS:-2} # the 8 GB Mac can't take more

if [[ ${DEVICE_ONLY:-0} != 1 ]]; then
    sim_backend=${PRTS_SIMULATOR_BACKEND:-metal}
    case "$sim_backend" in
        metal | cpu) ;;
        *)
            echo "PRTS_SIMULATOR_BACKEND must be metal or cpu" >&2
            exit 2
            ;;
    esac
fi

mkdir -p "$work"
[[ -d $src/.git ]] || git clone -q --filter=blob:none https://github.com/ggml-org/llama.cpp.git $src
git -C $src cat-file -e $llama_commit 2> /dev/null || git -C $src fetch -q origin
git -C $src checkout -q $llama_commit

build() {
    local sdk=$1 target=$2 src=$3 dir=$4 metal=$5
    shift 5
    cmake -S "$src" -B "$dir" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=$sdk \
        -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 -DBUILD_SHARED_LIBS=OFF \
        -DGGML_METAL="$metal" -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_BLAS=ON -DGGML_ACCELERATE=ON \
        -DGGML_NATIVE=OFF -DGGML_OPENMP=OFF -DGGML_CCACHE=OFF \
        -DLLAMA_BUILD_MTMD=ON -DLLAMA_BUILD_APP=OFF -DLLAMA_BUILD_UI=OFF -DLLAMA_BUILD_COMMON=OFF -DLLAMA_BUILD_TOOLS=OFF -DLLAMA_BUILD_EXAMPLES=OFF \
        -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_SERVER=OFF -DLLAMA_OPENSSL=OFF "$@" > "$dir.log"
    cmake --build "$dir" -j "$jobs" >> "$dir.log"
    xcrun --sdk $sdk clang++ -std=c++17 -O2 -target $target -isysroot "$(xcrun --sdk $sdk --show-sdk-path)" \
        -I"$src/include" -I"$src/ggml/include" -I"$src/tools/mtmd" \
        -c "$here/csrc/prts_local_vlm.cpp" -o "$dir/prts_local_vlm.o"
    local archives=()
    while IFS= read -r -d '' archive; do
        archives+=("$archive")
    done < <(find "$dir" -name 'lib*.a' ! -name libPRTSLocalVLM.a -print0)
    xcrun libtool -static -no_warning_for_no_symbols -o "$dir/libPRTSLocalVLM.a" "${archives[@]}" "$dir/prts_local_vlm.o"
}
build iphoneos arm64-apple-ios17.0 "$src" "$work/iphoneos" ON
if [[ ${DEVICE_ONLY:-0} != 1 ]]; then
    sim_src="$work/llama-simulator-$sim_backend"
    sim_dir="$work/iphonesimulator-$sim_backend"
    sim_files="$here/Simulator"
    if [[ $sim_backend == metal ]]; then
        patch="$sim_files/metal.patch"
        inputs=("$patch" "$sim_files/bf16.metal.txt")
        metal=ON
        flag=-DPRTS_SIMULATOR_METAL=1
    else
        patch="$sim_files/accelerate.patch"
        inputs=("$patch")
        metal=OFF
        flag=-DPRTS_SIMULATOR_ACCELERATE=1
    fi

    # Never apply a simulator patch to the device checkout. Separate build directories also
    # keep stale Metal archives out of the CPU-only slice when switching backends.
    [[ -d "$sim_src/.git" ]] || git clone -q --shared --no-checkout "$src" "$sim_src"
    stamp="$sim_src/.git/prts-simulator-inputs"
    fingerprint="$llama_commit:$(cat "${inputs[@]}" | git hash-object --stdin)"
    if [[ ! -f $stamp || $(cat "$stamp") != "$fingerprint" ]]; then
        rm -f "$stamp"
        git -C "$sim_src" checkout -qf --detach "$llama_commit"
        git -C "$sim_src" apply "$patch"
        if [[ $sim_backend == metal ]]; then
            xxd -i < "$sim_files/bf16.metal.txt" > "$sim_src/ggml/src/ggml-metal/prts-simulator-msl.inc"
        fi
        printf '%s\n' "$fingerprint" > "$stamp"
    fi
    build iphonesimulator arm64-apple-ios17.0-simulator "$sim_src" "$sim_dir" "$metal" \
        "-DCMAKE_C_FLAGS=$flag" "-DCMAKE_CXX_FLAGS=$flag"
fi

rm -rf $work/include $here/PRTSLocalVLM.xcframework
mkdir -p $work/include
cp $here/csrc/prts_local_vlm.h $here/csrc/module.modulemap $work/include/
libraries=(-library "$work/iphoneos/libPRTSLocalVLM.a" -headers "$work/include")
if [[ ${DEVICE_ONLY:-0} != 1 ]]; then
    libraries+=(-library "$sim_dir/libPRTSLocalVLM.a" -headers "$work/include")
fi
xcodebuild -create-xcframework -output "$here/PRTSLocalVLM.xcframework" \
    "${libraries[@]}" > /dev/null
cp "$src/LICENSE" "$here/PRTSLocalVLM.xcframework/LICENSE.llama.cpp"

# Official files from openbmb/MiniCPM-V-4.7-1B-gguf; hashes are the LFS SHA-256 on Hugging Face.
models=$root/models/MiniCPM-V-4.7-1B
model_revision=e81247fa2eac0d99e43aeac55da199221959af15
mkdir -p $models
fetch() {
    local name=$1 sha=$2 file=$models/$1
    if [[ ! -f $file || $(shasum -a 256 $file | cut -d' ' -f1) != $sha ]]; then
        curl -fL --retry 3 -C - -o $file.part https://huggingface.co/openbmb/MiniCPM-V-4.7-1B-gguf/resolve/$model_revision/$name
        [[ $(shasum -a 256 $file.part | cut -d' ' -f1) == $sha ]] || {
            echo "SHA-256 mismatch: $name" >&2
            exit 1
        }
        mv $file.part $file
    fi
}
while read -r sha name; do
    fetch "$name" "$sha"
done < "$here/models.sha256"
echo "PRTSLocalVLM.xcframework and models/MiniCPM-V-4.7-1B are ready"
