# Third-Party Notices

This document describes third-party open-source components used by iOS MCP.
The MIT License in `LICENSE` applies only to code authored for this project.
The attribution and disclaimer text in `NOTICE` applies to project-owned code.
Third-party components remain licensed under their own licenses.

This is an engineering compliance summary, not legal advice.

## PaddleOCR engine components

The optional PaddleOCR engine bundles PP-OCRv5 mobile models (Apache-2.0),
ONNX Runtime 1.20.1 (MIT), OpenCV 4.10.0 core/imgproc (Apache-2.0), and
Clipper 6.4.2 (Boost Software License 1.0). ONNX Runtime's dependencies include
Eigen (MPL-2.0); upstream notices are retained. Sources, immutable model revisions,
checksums and reproducible build steps are in `third_party/paddleocr/` and
`docs/PADDLEOCR.md`. Clipper's only local adaptation changes its header include path.
License texts and ONNX Runtime's full third-party notices are installed under
`/usr/share/doc/ios-mcp/paddleocr/`. Retain them when redistributing binaries.

## External Build Or Runtime Dependencies

These components are required by the build or runtime environment but are not
vendored as project source in this repository unless noted above:

| Component | Used For | Notes |
|---|---|---|
| Theos / Logos | Tweak, tool, and package build system | Build-time dependency. |
| MobileSubstrate / Cydia Substrate / Substitute / ElleKit | Tweak injection runtime | Declared through package dependencies. |
| PreferenceLoader | Settings bundle integration | Runtime package dependency. |
| roothide library | roothide path translation and compatibility | Linked only for roothide builds. |
| zlib | Compression library used by the OCR worker | Linked as a platform library. |

## Distribution Requirements

When distributing source or binary builds of iOS MCP:

1. Keep this `THIRD_PARTY_NOTICES.md` file with the distribution.
2. Keep `LICENSE`, `NOTICE`, and the bundled PaddleOCR dependency license and notice files available.
3. Preserve the source, copyright notices, and redistribution materials required by each bundled dependency's license.

The generated deb package installs this notice, the main license, and project
attribution notice under:

```text
/usr/share/doc/ios-mcp/
```
