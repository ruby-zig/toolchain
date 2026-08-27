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
            3,
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
        regeneration = "\n./config.status Makefile\n"
        objcopy_check = 'if [[ "$configured_objcopy" != : ]]; then'
        first_make = "make -s --no-print-directory"

        failed_probe_index = script.index(failed_probe_check)
        normalization_index = script.index(normalization)
        first_normalized_index = script.index(
            normalized_check,
            normalization_index,
        )
        regeneration_index = script.index(regeneration, first_normalized_index)
        second_normalized_index = script.index(
            normalized_check,
            regeneration_index,
        )
        objcopy_index = script.index(objcopy_check, regeneration_index)
        first_make_index = script.index(first_make)
        self.assertLess(failed_probe_index, normalization_index)
        self.assertLess(normalization_index, first_normalized_index)
        self.assertLess(first_normalized_index, regeneration_index)
        self.assertLess(regeneration_index, second_normalized_index)
        self.assertLess(second_normalized_index, objcopy_index)
        self.assertLess(objcopy_index, first_make_index)

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

    def test_release_branch_paths_are_exact_and_noninstalling(self) -> None:
        script = BUILD_SCRIPT.read_text(encoding="utf-8")

        self.assertIn(
            'master|ruby_4_0)\n    rust_source="$source_root/ruby.rs"',
            script,
        )
        self.assertIn(
            'ruby_3_4|ruby_3_3)\n'
            '    rust_source="$source_root/yjit/src/lib.rs"',
            script,
        )
        self.assertEqual(
            script.count("if [[ $source_branch == ruby_4_0 ]]; then"),
            2,
        )
        self.assertNotIn('if [[ "$source_branch" != master ]]; then', script)

        self.assertIn(
            'ruby_3_4|ruby_3_3)\n'
            '    yjit_libs="$(make_value YJIT_LIBS)"',
            script,
        )
        self.assertIn("rust_object_override='YJIT_LIBOBJ='", script)
        self.assertIn(
            "printf 'GROUP(%s %s)\\n' "
            '"$c_archive" "$rust_archive" >"$static_link_bridge"',
            script,
        )
        self.assertIn('post_map_make_options=(-o "$libruby_so")', script)

        bridge_create = script.index("printf 'GROUP(%s %s)")
        ordinary_build = script.index(
            'make -j"$jobs" V=1 "${base_overrides[@]}"\n',
            bridge_create,
        )
        bridge_remove = script.index(
            'rm -f -- "$static_link_bridge"',
            ordinary_build,
        )
        shared_check = script.index(
            'shared="$build_root/$libruby_so"',
            bridge_remove,
        )
        self.assertLess(bridge_create, ordinary_build)
        self.assertLess(ordinary_build, bridge_remove)
        self.assertLess(bridge_remove, shared_check)

        artifacts_start = script.index("artifacts=(")
        artifacts_end = script.index("\n)", artifacts_start)
        artifacts = script[artifacts_start:artifacts_end]
        self.assertNotIn("static_link_bridge", artifacts)
        self.assertNotIn("libruby-static.a", artifacts)
        self.assertIn(
            'if [[ -e "$build_root/libruby-static.a" || '
            '-e "${rust_archive%.a}.o" ]]; then',
            script,
        )

if __name__ == "__main__":
    unittest.main()
