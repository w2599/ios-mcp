# Optional PaddleOCR CPU engine (iOS 13+)

This is a per-request addition, not a replacement for Apple Vision. `OCRManager`
selects `paddleocr` when `engine` is absent, including calls made after a Vision
request. Unknown values/types (including JSON null) produce JSON-RPC `-32602`.
No settings preference, network OCR service, Python runtime, or cross-engine retry
is involved. The existing method without `engine` remains source-compatible but
now executes PaddleOCR. Use explicit `engine="vision"` to retain Vision behavior.
This default change is intentional: omitted-engine calls now also inherit the
Paddle model/resource requirements, concurrency limit and known ROI limitations.

Validation status (2026-09-26): freshly built release-mode static-link packages
were installed and tested on iPhone SE (2nd generation) / iOS 14.3 / rootful (221),
iPhone 7 / iOS 15.8.8 / roothide (222), and iPad / iPadOS 18.3.2 / rootless (223).
The latest acceptance uses third-party apps, not system apps. Engine routing,
CPU inference, fault isolation, and portrait OCR-to-tap checks passed on all three;
real-page text recognition is not error-free, and a narrow Telegram ROI triggered
the Paddle recognition-width limit. See the
[three-device report](PADDLEOCR_THREE_DEVICE_TEST_RESULTS.md) for exact coverage
and limitations. A subsequent fresh rootful release-mode build was also installed
and exercised on iPhone 7 Plus / iOS 13.5.1 at 192.168.1.17: Vision revision 1
English recognition, explicit Chinese rejection, and Paddle CPU bilingual
inference passed. See the [iOS 13.5.1 device report](PADDLEOCR_IOS13_TEST_RESULTS.md),
including a very narrow Paddle ROI that missed small text. Exact iOS 13.0 and
other iOS 13 devices remain untested. Historical results remain in
[the original report](PADDLEOCR_TEST_RESULTS.md) and
[the iOS 14 compatibility regression](PADDLEOCR_ROOTFUL_COMPATIBILITY.md).
Those reports were recorded before changing the default from Vision to PaddleOCR;
their original defaults and measurements are intentionally preserved. The latest
default-routing verification is recorded in [the default-change report](PADDLEOCR_DEFAULT_ENGINE_TEST_RESULTS.md).

## Calls

```json
{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"ocr_screen","arguments":{}}}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"ocr_screen","arguments":{"engine":"vision","languages":["en-US"]}}}
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"ocr_screen","arguments":{"engine":"paddleocr","languages":["zh-Hans","en-US"],"min_confidence":0.3}}}
{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"ocr_screen","arguments":{"engine":"paddleocr","region":{"x":0,"y":100,"width":300,"height":200}}}}
{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"describe_screen","arguments":{"include_ocr":true,"engine":"paddleocr"}}}
```

POST to `/mcp` using the usual MCP initialization/session headers. `describe_screen`
keeps its existing partial-result convention: an OCR failure is in `ocr_error`,
while accessibility data remains available. It does not try another engine.

`recognition.engine` identifies the selected engine. Paddle results also report
`provider=CPUExecutionProvider`, runtime/model versions and worker PID. The fixed
mobile model does not have Vision's fast/accurate switch; `fast` is accepted for
compatibility and this is disclosed in `recognition.adjustments`. The bilingual
model's alphabet is not restricted by a language hint. Unsupported hints fail.

Vision keeps its system-provided default revision and availability checks:

- iOS 13: default English; explicit Chinese is rejected, never routed to Paddle.
- iOS 14+: Chinese+English is preferred only if the actual revision's accurate
  path supports both. Fast requests may use accurate when required by language.
- The instance language-query API is used only on iOS 15+; older systems use the
  revision/recognition-level class API. No newer revision is forced on older OSes.

## Dependencies and provenance

Exact URLs, source revisions and SHA256 values are in
`third_party/paddleocr/dependencies.lock.json`; model/dictionary hashes are in
`third_party/paddleocr/models/sha256.json`.

| Component | Pinned version | Use / license |
|---|---|---|
| ONNX Runtime | 1.20.1, built from source | CPU EP only, MIT |
| PP-OCRv5_mobile_det | PaddlePaddle official ONNX export, pinned HF revision | float32, IR 6, opset 11; Apache-2.0 |
| PP-OCRv5_mobile_rec | PaddlePaddle official ONNX export, pinned HF revision | float32, IR 3, opset 7; Apache-2.0 |
| OpenCV | 4.10.0, core/imgproc only | native preprocessing/postprocessing; Apache-2.0 |
| Clipper | 6.4.2 from PaddleOCR v3.0.3 | DB polygon unclip; Boost 1.0 |
| Eigen | e7248b26a1ed53fa030c5c459f7ea095dfd276ac | ORT CPU dependency; MPL-2.0 |

ORT 1.20.1's own [iOS build configuration](https://github.com/microsoft/onnxruntime/blob/v1.20.1/tools/ci_build/github/apple/default_full_ios_framework_build_settings.json)
targets iOS 13 for iPhone. We build our own CPU-only runtime: unlike the default
upstream configuration, CoreML and XNNPACK are disabled. The official
[compatibility matrix](https://onnxruntime.ai/docs/reference/compatibility.html)
lists ORT 1.20 support through ONNX IR 10/opset 21. We additionally check and run
the actual models, not just their declarations. No ONNX IR/opset is rewritten.

The official PaddlePaddle ONNX exports are consumed byte-for-byte. Therefore no
local re-conversion is needed: developers download the pinned **already converted**
models, verify them with ONNX checker and generate the dictionary on the Mac.
Original export settings remain in `det.yml`/`rec.yml`. Nothing is converted on
the phone. This avoids an unpinned Paddle2ONNX conversion changing operators.

The Eigen GitLab ZIP was regenerated upstream and no longer matches the old SHA1
in ORT 1.20.1's deps.txt. We pin the current archive's SHA256 for the same commit
and supply it via `--use_preinstalled_eigen`; we do not disable download checks.
Other ORT dependency versions/checksums remain those in its pinned `cmake/deps.txt`.

## Reproducible build

Requires an Apple Silicon Mac, Xcode (tested build toolchain: 16.4), Theos, CMake,
Ninja, Python 3.9+, and ldid. Python is developer/test tooling only.

```sh
python3 scripts/fetch_paddle_dependencies.py
python3 -m venv .codex-session-data/paddle-build/venv
.codex-session-data/paddle-build/venv/bin/pip install \
  onnx==1.17.0 numpy==1.26.4 PyYAML==6.0.2 Pillow==11.1.0 protobuf==6.33.6
.codex-session-data/paddle-build/venv/bin/python scripts/prepare_paddleocr.py
bash scripts/build_paddle_runtime.sh ios
printf '3\n1\n' | ./build.sh  # 1=rootful, 2=rootless, 3=roothide
python3 scripts/check_paddle_binaries.py
```

Downloads honor normal `https_proxy`/`http_proxy` environment variables. Builds
are incremental. Models and generated runtimes are not source-controlled; the
lockfile and scripts reproduce them, and the resulting deb includes them.
Do not distribute a package until all artifacts and licenses have been staged.

The standalone worker and ORT/OpenCV are built arm64 with iOS 13.0 minimum.
For iOS, `build_paddle_runtime.sh` copies upstream's combined static framework
archive to `runtime/ios/lib/libonnxruntime.a`. It is linked into the worker along
with OpenCV, not shipped as a separate dylib. macOS test tooling still uses a dylib.
An arm64 process also runs on arm64e hardware, avoiding mixed arm64/arm64e C++ ABI
inside SpringBoard. Rootless/roothide retain the project's iOS 15 packaging target;
rootful retains iOS 13. Paddle does not raise the main tweak's deployment target.

`check_paddle_binaries.py` checks actual Mach-O minimum versions (including static
ORT/OpenCV archive members), architecture, linked frameworks and imports. It
also rejects a worker that dynamically links ORT. Passing
that audit is necessary but **does not constitute iOS 13 device validation**.
The runtime's C++ filesystem imports require iOS 13.0 according to
[Apple's C++ support table](https://developer.apple.com/xcode/cpp/). Import listings
are retained in the audit report; they have not been resolved against an actual
iOS 13 dyld shared cache; actual exercised OCR paths now also have iOS 13.5.1
device evidence.

Installed locations (resolved through the existing jailbreak path helper):

```text
/usr/libexec/ios-mcp/mcp-ocr-worker
/usr/share/ios-mcp/paddleocr/{det.onnx,rec.onnx,dictionary.json,...}
/usr/share/doc/ios-mcp/paddleocr/{LICENSE*,dependencies.lock.json,...}
```

ORT is statically linked only into the signed worker. This avoids the extra
dynamic-library signature check that rejected ORT on the tested iOS 14.3 rootful
device. No library-validation entitlement or jailbreak security setting is changed.
A missing/bad worker or model cannot prevent SpringBoard/iOS MCP/Vision from loading.
An upgrade removes the formerly packaged ORT dylib through dpkg's normal ownership
tracking; no broad filesystem cleanup is performed. Install the matching deb
through the existing `upload_file` + `install_deb` workflow or `dpkg -i`; installation
restarts SpringBoard as before.

## Pipeline and coordinates

1. Capture pixels and `MCPScreenGeometry` together using the existing screenshot
   implementation. Keep pixels separate from fixed screen points.
2. Rotate pixels into interface orientation; convert/clip the requested fixed-point
   ROI into that orientation and crop it before inference.
3. Detection: BGR float32 NCHW, `(value/255 - mean)/std`; resize long side to 960
   then ceil dimensions to stride 128, matching `det.yml`/DetResizeForTest.
4. DB: bitmap threshold 0.3, box score 0.6, contour/min-area rectangle, polygon
   expansion ratio 1.5, perspective crop; rotate tall line crops by 90 degrees.
5. Recognition: height 48, BGR NCHW normalized to [-1,1], dynamic width at least
   320, zero right-padding **after normalization**. Greedy CTC removes blank and
   consecutive repeats. Dictionary: blank + 18,383 official characters + space.
6. Map boxes through ROI, image size and captured interface-to-fixed transform.
   Return the existing `texts/count/screen/recognition`, with `rect` and `tap` in
   fixed screen points. No Retina-scale division is required by callers.

Vision's confidence semantics/filtering are unchanged. Paddle's score is the mean
probability of the decoded nonblank characters; `min_confidence` applies to that
score, not DB's detection threshold. Equal scores from the two engines are not
equivalent. The default 0.3 is compatibility-oriented, not a universal calibrated
accuracy guarantee. Validate a threshold on the intended device/screens.

## Resource bounds, isolation and cancellation

- Lazy sessions reused by a single private worker; one active Paddle request,
  **zero queued requests**. A concurrent Paddle request gets a clear busy error.
  Vision requests do not use this gate or worker.
- 2 ORT intra-op threads, sequential graph execution, no CPU arena or memory
  pattern retention. OpenCV threading is separately bounded in the implementation.
- 16 megapixel / 8192-pixel input edge, 24 MB image, 32 MB IPC request, 1 MB result,
  128 text lines, recognition width at most 2048. Exceeding a bound fails explicitly.
- 512 MB worker physical-footprint watchdog; idle worker exits after 60 seconds.
  This is an application bound, not a guarantee against iOS jetsam under pressure.
- 30-second per-request deadline. Disconnect or `notifications/cancelled` for the
  same session and typed request ID terminates and reaps the worker. No background
  inference remains running after that failure is returned. Next call starts fresh.
- Cancellation keys use the incoming session header and typed request ID. The
  existing server issues one shared session token; clients sharing it must use
  distinct outstanding request IDs. This addition does not replace MCP session
  management or introduce authentication.
- On the tested SpringBoard, `poll` on the private Unix socket returns `EPERM`.
  The parent uses a bounded `select` readiness fallback; it does not spin, change
  the Vision environment, or elevate SpringBoard privileges.
- Model/dictionary SHA256 is checked even for warm sessions. Errors never invoke
  Vision. Vision remains in its original SpringBoard environment; this change does
  not claim to solve pre-existing crashes internal to Apple's Vision runtime.

## Executable validation

```sh
bash scripts/test_ocr_unit.sh
bash scripts/build_paddle_runtime.sh macos
bash scripts/build_paddle_worker_macos.sh
.codex-session-data/paddle-build/venv/bin/python tests/paddle_worker_test.py \
  --worker .codex-session-data/paddle-build/mcp-ocr-worker-macos
```

Unit tests use engine doubles **only** to exercise the production router's request
isolation/defaults/errors. The worker tests use real native ONNX CPU inference on
known Chinese/English/digit fixtures, all four rotations, coordinates, ROI, empty
images, session reuse and missing/corrupted resources. Actual device reports are
recorded separately; do not substitute host tests for iOS 13 runtime coverage.

Device/package checks (use only on devices authorized for UI and fault tests):

```sh
python3 tests/paddle_package_test.py --version 1.2.8
# Or inspect only an available scheme: --arch arm / --arch arm64 / --arch arm64e
python3 tests/install_test_package.py --url http://DEVICE:2902/mcp packages/MATCHING.deb
python3 tests/mcp_ocr_engines_test.py --url http://DEVICE:2902/mcp --out engine-results.json
# On an actual iOS 13 device, with a third-party page showing English text:
python3 tests/ocr_ios13_device_test.py --url http://DEVICE:2902/mcp --out ios13-results.json
python3 tests/paddle_lifecycle_device_test.py --url http://DEVICE:2902/mcp \
  --ssh root@DEVICE --resources RESOLVED_JAILBREAK_ROOT/usr/share/ios-mcp/paddleocr \
  --out lifecycle-results.json
# Exercise omitted engine, including describe_screen's OCR cancellation path:
python3 tests/paddle_lifecycle_device_test.py --url http://DEVICE:2902/mcp \
  --ssh root@DEVICE --resources RESOLVED_JAILBREAK_ROOT/usr/share/ios-mcp/paddleocr \
  --app-bundle-id THIRD_PARTY_APP_ID --omit-engine --fault-tool describe_screen \
  --out lifecycle-default-describe.json
python3 tests/ocr_ui_device_test.py --url http://DEVICE:2902/mcp \
  --host-ip DEVELOPER_MAC_LAN_IP --frida 127.0.0.1:FORWARDED_FRIDA_PORT --out ui-results
```

The lifecycle test reads the SSH password from `SSHPASS`, temporarily renames one
model and restores it in `finally`, and suspends only the worker PID returned by
the server. The UI test needs Frida 16 for test-only rotation/idle control and
serves a local fixture; recognition and taps still use MCP. `--portrait-only`
skips Frida and tests only the current portrait UI, not physical rotation. Neither Frida nor
Python is a production OCR dependency. Restore the device if any test is interrupted.
