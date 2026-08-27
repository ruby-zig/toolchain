from __future__ import annotations

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
BUILD_SCRIPT = ROOT / "adapters" / "repo" / "ruby" / "build.sh"


class CrubyBuildContractTests(unittest.TestCase):
    def test_strip_is_verified_then_normalized_before_make(self) -> None:
        script = BUILD_SCRIPT.read_text(encoding="utf-8")

        configure_start = script.index('"$source_root/configure"')
        configure_end = script.index("\n\ncp config.log", configure_start)
        configure = script[configure_start:configure_end]
        self.assertIn("  OBJCOPY=: \\\n  STRIP=/bin/false \\", configure)
        self.assertNotIn("  STRIP=:", configure)
        self.assertIn("A configure-time `:`", script)
        self.assertIn("would therefore become `: -A -n`", script)

        self.assertIn("'$1 == \"OBJCOPY\" {print $2; exit}' Makefile", script)
        self.assertIn('if [[ "$configured_objcopy" != : ]]; then', script)
        self.assertIn(
            'awk \'index($0, "S[\\"STRIP\\"]=") == 1 {print}\' config.status',
            script,
        )
        self.assertEqual(
            script.count(
                'configured_strip_record="$(config_status_strip_records)"'
            ),
            2,
        )
        failed_probe_check = (
            """if [[ "$configured_strip_record" != """
            """'S["STRIP"]="/bin/false"' ]]; then"""
        )
        normalization = (
            r"""sed -i 's|^S\["STRIP"\]="/bin/false"$|"""
            r"""S["STRIP"]=":"|' config.status"""
        )
        normalized_check = (
            """if [[ "$configured_strip_record" != """
            """'S["STRIP"]=":"' ]]; then"""
        )
        first_make = "make -s --no-print-directory"

        failed_probe_index = script.index(failed_probe_check)
        normalization_index = script.index(normalization)
        normalized_check_index = script.index(normalized_check)
        first_make_index = script.index(first_make)
        self.assertLess(failed_probe_index, normalization_index)
        self.assertLess(normalization_index, normalized_check_index)
        self.assertLess(normalized_check_index, first_make_index)

        overrides_start = script.index("base_overrides=(")
        overrides_end = script.index("\n)", overrides_start)
        overrides = script[overrides_start:overrides_end]
        self.assertIn("  'STRIP=:'", overrides)

        make_invocations = [
            line.strip()
            for line in script.splitlines()
            if line.lstrip().startswith("make ")
        ]
        self.assertTrue(make_invocations)
        for invocation in make_invocations:
            self.assertTrue(
                "'STRIP=:'" in invocation
                or '"${base_overrides[@]}"' in invocation,
                f"make invocation does not force inert STRIP: {invocation}",
            )

        self.assertIn(
            '    "OBJCOPY" => ":",\n    "STRIP" => ":",',
            script,
        )


if __name__ == "__main__":
    unittest.main()
