#!/bin/bash
# Run after fetching the SHA256-pinned source archives documented in docs/PADDLEOCR.md.
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
work_dir="$repo_dir/.codex-session-data/paddle-build"
target="${1:-ios}"
ort_src="$work_dir/onnxruntime-1.20.1"
cv_src="$work_dir/opencv-4.10.0"
out_dir="$repo_dir/third_party/paddleocr/runtime/$target"
mkdir -p "$out_dir"
if [[ "$target" == ios ]]; then
  ort_args=(--ios --use_xcode --apple_sysroot iphoneos --osx_arch arm64 --apple_deploy_target 13.0 --build_apple_framework)
  cv_args=(-DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphoneos -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0)
elif [[ "$target" == macos ]]; then
  ort_args=(--build_shared_lib --cmake_generator Ninja)
  cv_args=(-DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=12.0)
else
  echo 'Expected ios or macos' >&2; exit 2
fi
python3 "$ort_src/tools/ci_build/build.py" --config MinSizeRel --build_dir "$work_dir/ort-$target" \
  "${ort_args[@]}" --skip_tests --skip_submodule_sync --parallel 4 --compile_no_warning_as_error \
  --disable_ml_ops --use_preinstalled_eigen --eigen_path "$work_dir/eigen-e7248b26a1ed53fa030c5c459f7ea095dfd276ac" \
  --cmake_extra_defines onnxruntime_BUILD_UNIT_TESTS=OFF \
  onnxruntime_USE_COREML=OFF onnxruntime_USE_XNNPACK=OFF onnxruntime_DISABLE_EXCEPTIONS=OFF \
  CMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO CMAKE_POLICY_VERSION_MINIMUM=3.5
cmake -S "$cv_src" -B "$work_dir/cv-$target" -G Ninja "${cv_args[@]}" \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DCMAKE_BUILD_TYPE=MinSizeRel -DCMAKE_INSTALL_PREFIX="$out_dir/opencv" \
  -DBUILD_LIST=core,imgproc -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTS=OFF -DBUILD_PERF_TESTS=OFF \
  -DBUILD_EXAMPLES=OFF -DBUILD_opencv_apps=OFF -DWITH_OPENCL=OFF -DWITH_IPP=OFF \
  -DWITH_ITT=OFF -DWITH_LAPACK=OFF -DWITH_EIGEN=OFF -DWITH_TBB=OFF -DWITH_OPENMP=OFF \
  -DWITH_CAROTENE=OFF -DWITH_CPUFEATURES=OFF \
  -DBUILD_JAVA=OFF -DBUILD_opencv_python2=OFF -DBUILD_opencv_python3=OFF
cmake --build "$work_dir/cv-$target" --parallel 4
cmake --install "$work_dir/cv-$target"
mkdir -p "$out_dir/include" "$out_dir/lib"
cp "$ort_src"/include/onnxruntime/core/session/onnxruntime*.h "$out_dir/include/"
if [[ "$target" == ios ]]; then
  # Upstream's combined static framework includes ORT's internal/external object
  # dependencies. Static linking avoids a second dyld code-signature check on
  # older rootful jailbreaks without relaxing the worker's entitlements.
  runtime_file="$out_dir/lib/libonnxruntime.a"
  cp "$work_dir/ort-ios/MinSizeRel/MinSizeRel-iphoneos/static_framework/onnxruntime.framework/onnxruntime" "$runtime_file"
else
  runtime_file="$out_dir/lib/libonnxruntime.dylib"
  cp "$work_dir/ort-macos/MinSizeRel/libonnxruntime.1.20.1.dylib" "$runtime_file"
  install_name_tool -id @rpath/libonnxruntime.dylib "$runtime_file"
fi
shasum -a 256 "$runtime_file" "$out_dir/opencv/lib/"*.a
otool -l "$runtime_file"
otool -L "$runtime_file"
