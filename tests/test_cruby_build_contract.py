from __future__ import annotations

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
BUILD_SCRIPT = ROOT / "adapters" / "repo" / "ruby" / "build.sh"


class CrubyBuildContractTests(unittest.TestCase):
    def test_strip_probe_fails_then_make_uses_inert_command(self) -> None:
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
        self.assertIn(
            """if [[ "$configured_strip_record" != 'S["STRIP"]="/bin/false"' ]]; then""",
            script,
        )

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
