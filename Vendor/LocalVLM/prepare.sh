#!/bin/zsh
# Builds PRTSLocalVLM.xcframework (llama.cpp + mtmd + csrc/ wrapper, Metal embedded) and
# downloads the MiniCPM-V 4.7 weights into models/. Both are git-ignored: run this once after
# cloning (and again after changing csrc/), then build the app as usual. Needs cmake and ninja.
set -euo pipefail
here=${0:A:h}
root=${here:h:h}
llama_commit=620d2225cc436ab0b001e3200e590e3b286ef9ab
work=$here/.build
src=$work/llama.cpp
jobs=${JOBS:-2}  # the 8 GB Mac can't take more

mkdir -p $work
[[ -d $src/.git ]] || git clone -q --filter=blob:none https://github.com/ggml-org/llama.cpp.git $src
git -C $src cat-file -e $llama_commit 2>/dev/null || git -C $src fetch -q origin
git -C $src checkout -q $llama_commit

build() {
    local sdk=$1 target=$2 dir=$work/$1
    cmake -S $src -B $dir -G Ninja \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=$sdk \
        -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 -DBUILD_SHARED_LIBS=OFF \
        -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_BLAS=ON -DGGML_ACCELERATE=ON \
        -DGGML_NATIVE=OFF -DGGML_OPENMP=OFF -DGGML_CCACHE=OFF \
        -DLLAMA_BUILD_MTMD=ON -DLLAMA_BUILD_APP=OFF -DLLAMA_BUILD_UI=OFF -DLLAMA_BUILD_COMMON=OFF -DLLAMA_BUILD_TOOLS=OFF -DLLAMA_BUILD_EXAMPLES=OFF \
        -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_SERVER=OFF -DLLAMA_OPENSSL=OFF > $dir.log
    cmake --build $dir -j $jobs >> $dir.log
    xcrun --sdk $sdk clang++ -std=c++17 -O2 -target $target -isysroot $(xcrun --sdk $sdk --show-sdk-path) \
        -I$src/include -I$src/ggml/include -I$src/tools/mtmd \
        -c $here/csrc/prts_local_vlm.cpp -o $dir/prts_local_vlm.o
    xcrun libtool -static -no_warning_for_no_symbols -o $dir/libPRTSLocalVLM.a $(find $dir -name 'lib*.a' ! -name libPRTSLocalVLM.a) $dir/prts_local_vlm.o
}
build iphoneos arm64-apple-ios17.0
build iphonesimulator arm64-apple-ios17.0-simulator

rm -rf $work/include $here/PRTSLocalVLM.xcframework
mkdir -p $work/include
cp $here/csrc/prts_local_vlm.h $here/csrc/module.modulemap $work/include/
xcodebuild -create-xcframework -output $here/PRTSLocalVLM.xcframework \
    -library $work/iphoneos/libPRTSLocalVLM.a -headers $work/include \
    -library $work/iphonesimulator/libPRTSLocalVLM.a -headers $work/include > /dev/null

# Official files from openbmb/MiniCPM-V-4.7-1B-gguf; hashes are the LFS SHA-256 on Hugging Face.
models=$root/models/MiniCPM-V-4.7-1B
mkdir -p $models
fetch() {
    local name=$1 sha=$2 file=$models/$1
    if [[ ! -f $file || $(shasum -a 256 $file | cut -d' ' -f1) != $sha ]]; then
        curl -fL --retry 3 -C - -o $file.part https://huggingface.co/openbmb/MiniCPM-V-4.7-1B-gguf/resolve/main/$name
        [[ $(shasum -a 256 $file.part | cut -d' ' -f1) == $sha ]] || { echo "SHA-256 mismatch: $name" >&2; exit 1; }
        mv $file.part $file
    fi
}
fetch MiniCPM-V-4_7-1B-Q5_K_M.gguf 9e513c61e42e83a1aa271957eab2b06b15335f6f12756465c739da1ea3192bc5
fetch mmproj-model-f16.gguf fb9cc047a3cdad5317fd8433a4aeda2d22f00f02ca4bd93b34ad84165b25a900
echo "PRTSLocalVLM.xcframework and models/MiniCPM-V-4.7-1B are ready"
