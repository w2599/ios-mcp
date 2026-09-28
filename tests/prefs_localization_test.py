#!/usr/bin/env python3
"""Validate prefs translations and run the actual Foundation resolver on macOS.

Run: python3 tests/prefs_localization_test.py
No device, installed preferences, or existing release packages are modified.
"""
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ROOT / "prefs/Resources"
LANGUAGES = ("en", "zh-Hans", "zh-Hant")
HAN = re.compile(r"[\u3400-\u9fff]")
OBJC_STRINGS = re.compile(r'@"(?:\\.|[^"\\])*"(?:\s*@"(?:\\.|[^"\\])*")*')
FORMATS = re.compile(r"%(?:\d+\$)?[-+ #0]*(?:\d+|\*)?(?:\.(?:\d+|\*))?(?:hh|ll|[hljztL])?[@diuoxXfFeEgGaAcCsSpn%]")


def read_strings(path):
    return json.loads(subprocess.check_output(
        ["plutil", "-convert", "json", "-o", "-", str(path)]))


@unittest.skipUnless(sys.platform == "darwin", "Requires macOS Foundation and Xcode command-line tools")
class PreferencesLocalizationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tables = {lang: read_strings(RESOURCES / f"{lang}.lproj/Localizable.strings")
                      for lang in LANGUAGES}
        cls.scratch = tempfile.TemporaryDirectory(prefix="ios-mcp-prefs-localization-")
        cls.addClassCleanup(cls.scratch.cleanup)
        work = Path(cls.scratch.name)
        cls.bundle = work / "iosmcpprefs.bundle"
        contents = cls.bundle / "Contents"
        binary = contents / "MacOS/iosmcpprefs"
        binary.parent.mkdir(parents=True)
        resource_dir = contents / "Resources"
        resource_dir.mkdir()
        for lang in LANGUAGES:
            shutil.copytree(RESOURCES / f"{lang}.lproj", resource_dir / f"{lang}.lproj")
        info = plistlib.loads((RESOURCES / "Info.plist").read_bytes())
        (contents / "Info.plist").write_bytes(plistlib.dumps(info))
        subprocess.run(["xcrun", "clang", "-dynamiclib", "-fobjc-arc", "-framework", "Foundation",
                        str(ROOT / "prefs/IOSMCPLocalization.m"), "-o", str(binary)], check=True)
        cls.host = work / "host"
        subprocess.run(["xcrun", "clang", "-fobjc-arc", "-framework", "Foundation",
                        str(ROOT / "tests/prefs_localization_host.m"), "-o", str(cls.host)], check=True)
        cls.keys_file = work / "keys.json"
        cls.keys_file.write_text(json.dumps(list(cls.tables["en"]) + ["iOS MCP", "2902", "UNKNOWN_KEY"]),
                                 encoding="utf-8")

    def resolve(self, preferences):
        # Each launch gets fresh Foundation preferences and bundle caches.
        apple_languages = "(" + ",".join(f'"{lang}"' for lang in preferences) + ")"
        return json.loads(subprocess.check_output(
            [str(self.host), str(self.bundle), str(self.keys_file), "-AppleLanguages", apple_languages]))

    def test_resources_and_format_arguments(self):
        expected_keys = set(self.tables["en"])
        for lang, table in self.tables.items():
            with self.subTest(language=lang):
                self.assertEqual(set(table), expected_keys)
                source = (RESOURCES / f"{lang}.lproj/Localizable.strings").read_text()
                self.assertEqual(len(re.findall(r'^"', source, re.M)), len(table), "Duplicate keys")
                for key, value in table.items():
                    self.assertTrue(value, key)
                    self.assertEqual(FORMATS.findall(value), FORMATS.findall(self.tables["en"][key]), key)
                self.assertEqual(FORMATS.findall(table["MCP_PROMPT"]), ["%@", "%@"])
                self.assertEqual(re.findall(r"^\d+\.", table["MCP_PROMPT"], re.M),
                                 [f"{i}." for i in range(1, 13)])
        self.assertFalse(any(HAN.search(value) for value in self.tables["en"].values()))
        for key, value in self.tables["zh-Hans"].items():
            if key != "MCP_PROMPT":
                self.assertEqual(key, value, "Preserve the original Simplified Chinese UI")
        info = plistlib.loads((RESOURCES / "Info.plist").read_bytes())
        self.assertEqual(info["CFBundleDevelopmentRegion"], "en")
        self.assertEqual(set(info["CFBundleLocalizations"]), set(LANGUAGES))

    def test_visible_source_strings_are_localized(self):
        keys = self.tables["en"]
        for filename in ("IOSMCPRootListController.m", "IOSMCPQRCodeCell.m"):
            source = (ROOT / "prefs" / filename).read_text()
            for match in OBJC_STRINGS.finditer(source):
                value = "".join(json.loads(token[1:]) for token in
                                re.findall(r'@"(?:\\.|[^"\\])*"', match.group()))
                if HAN.search(value):
                    self.assertIn(value, keys, filename)
                    self.assertTrue(source[:match.start()].rstrip().endswith("IOSMCPLocalizedString("),
                                    f"Unlocalized literal in {filename}: {value}")
        root = plistlib.loads((RESOURCES / "Root.plist").read_bytes())
        for item in root["items"]:
            for prop in ("label", "footerText", "placeholder", "caption"):
                value = item.get(prop, "")
                if HAN.search(value):
                    self.assertIn(value, keys, prop)

    def test_preferred_language_resolution(self):
        cases = [(lang, expected) for expected, variants in (
            ("en", ("en-US", "en-GB", "fr-FR", "ja-JP")),
            ("zh-Hans", ("zh-Hans", "zh-Hans-CN", "zh-CN", "zh-SG")),
            ("zh-Hant", ("zh-Hant", "zh-Hant-TW", "zh-TW", "zh-HK")),
        ) for lang in variants]
        cases = [([lang], expected) for lang, expected in cases]
        cases += [(["en-US", "zh-Hans"], "en"), (["fr-FR", "zh-CN", "en-US"], "zh-Hans")]
        for preferences, expected in cases:
            with self.subTest(preferences=preferences):
                resolved = self.resolve(preferences)
                self.assertEqual({key: resolved[key] for key in self.tables[expected]}, self.tables[expected])
                for literal in ("iOS MCP", "2902", "UNKNOWN_KEY"):
                    self.assertEqual(resolved[literal], literal)

    def test_missing_translation_falls_back_to_english(self):
        # Corrupt only a disposable test bundle, never a source resource.
        path = self.bundle / "Contents/Resources/zh-Hant.lproj/Localizable.strings"
        original = path.read_bytes()
        table = self.tables["zh-Hant"].copy()
        del table["端口无效"]
        try:
            path.write_bytes(plistlib.dumps(table))
            resolved = self.resolve(["zh-TW"])
            self.assertEqual(resolved["端口无效"], self.tables["en"]["端口无效"])
            self.assertEqual(resolved["重启"], self.tables["zh-Hant"]["重启"])
        finally:
            path.write_bytes(original)


if __name__ == "__main__":
    unittest.main(verbosity=2)
