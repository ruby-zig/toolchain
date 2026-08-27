# CRuby x86_64-linux-musl lane

`build-musl.sh` is a certified, run-verified development lane for CRuby
`master`, locked at `12e5584ddc3d05988390016e14556ab543765939` for the
recorded run. It is admitted for `master` through an exact per-profile
override in `config/fleet-lock.json`.

The lane builds a static musl `miniruby`, `ruby`, and `libruby-static.a` with
Zig 0.16.0. Build-machine helpers use the separate GNU/Linux host wrappers.
YJIT and ZJIT are disabled because CRuby currently rejects cross-rustc in
`configure.ac`; the adapter fails if Rust is enabled and rejects every Rust
receipt.

The source patch next to the adapter records four upstream blockers observed
on the locked CRuby source: a relative `Pathname` mismatch while generating
`dump_ast`, the generated helper defaulting to the baseruby's system compiler,
a linker probe executing Zig's bare `ld` program name, and musl reporting only
the mapped portion of the expandable main stack. The fleet leaves the
maintained fork fast-forward-clean: the musl adapter first
checks and then applies the recorded patch to its immutable source checkout. The
GNU lane keeps its normal build script and Rust policy.

The accepted run used controller
`1af1a846cab6fb0cfc31fc6b85a3d3a91d3e235d`, source patch
`a513fc938d0f838c143fd894f53c0206bb935de69538fc25f445d54be502cc3b`,
and a strict poison-`PATH` process audit. It produced 1,507 correlated Zig
receipts, passed all 2,066 bootstrap tests and all 894 basic tests, loaded the
representative static extension set, and executed both static musl binaries on
the x86_64 runner.
