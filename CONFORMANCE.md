# Zig toolchain conformance

Certification is per repository, commit, and target profile. It is not a claim
about unrelated release artifacts or undeclared optional features.

Every current profile is deliberately `build-only`. A green Linux lane can
certify that a native transformation used the declared Zig/rustc boundary, but
it does not claim that the resulting artifact was inspected or executed. macOS
lanes are receipt-only and are not process-trace certified.

Certification runs only for owner-controlled `push`, `workflow_dispatch`, and
`schedule` events. Pull requests receive static and advisory checks, but the
reusable workflow rejects both `pull_request` and `pull_request_target`
contexts. Repository source and the controller-owned build adapter share a runner
workspace with the verifier, so untrusted pull-request code cannot produce
certification evidence until those roles are isolated.

## Required compiler boundary

For the declared source scope:

- C, Objective-C, and preprocessed assembly use `zig cc`.
- C++ and Objective-C++ use `zig c++`.
- C-family static archives use `zig ar` and `zig ranlib`.
- Native executable and shared-library links use a Zig driver.
- Rust source uses pinned `rustc`; supported Rust final links use the
  `rz-rust-linker` Zig driver.
- Cargo build scripts and native dependencies receive target-specific `CC`,
  `CXX`, and `AR` wrappers.

Platform SDKs, libc, Zig runtime libraries, Rust standard libraries, generators,
the declared Ruby runtime, and read-only inspection tools are external inputs.
Prebuilt third-party native libraries are not allowed in an exclusive lane
unless the profile explicitly marks them as platform inputs.

Every ready lock entry declares an exact numeric Ruby `x.y.z` version. A
commit-pinned `ruby/setup-ruby` action installs that prebuilt interpreter to
drive `extconf.rb`, Rake, and tests. That prebuilt driver is not built by the
fleet and is never a certified output. A green non-CRuby extension lane does
not certify CRuby itself as Zig-built; the dedicated `ruby/ruby` adapter may
make that claim only for the CRuby artifacts it builds and audits.

Pure Ruby, documentation, JavaScript, metadata, and fixture-only repositories
remain in discovery but do not create build lanes. They are recorded as
`not-applicable` for the affected native fleet.

For musl Rust targets, `rustc -C link-self-contained=no` delegates the platform
CRT and native system libraries to the Zig driver. Rust still supplies its
standard libraries and generated objects.

## Known blocked profiles

Rust final linking for the two AArch64 Linux profiles is blocked with Zig 0.16.
Rust 1.98 requires `--fix-cortex-a53-843419`, while Zig does not yet implement
that linker mitigation. The wrapper never discards the safety flag. These lanes
remain blocked until [Zig issue 36624](https://codeberg.org/ziglang/zig/issues/36624)
is fixed and exercised by a regression test. AArch64 links are not claimed safe
for affected Cortex-A53 hardware before that point.

## Evidence required for a green build-only result

1. Start from a clean checkout and empty output/cache directories.
2. Record the upstream SHA, fork SHA, Zig version and archive digest, exact
   external Ruby runtime, Rust version when used, runner image, target profile,
   and dependency lock state.
3. Put failing shims for common host compilers, linkers, archivers, and
   post-link object transformers on `PATH`.
4. On Linux certification jobs, trace process creation and execution and reject
   direct or absolute invocations of foreign C-family compilers, linkers, and
   archivers, along with foreign post-link object transformers.
5. Bidirectionally correlate wrapper receipts with pinned compiler processes.
   Internal Zig or rustc subprocesses must descend from a receipted driver.
   Probe-only receipts do not qualify a lane.
6. Require the repository adapter to propagate every native build failure. An
   adapter that ignores a compiler or linker status, uses `|| true`, or exits
   successfully after a failed native command invalidates the lane.
7. Run negative controls proving that the auditor rejects a forbidden compiler,
   a foreign post-link transformer, an unwrapped pinned compiler, and a
   probe-only false green.
8. Reject foreign `objcopy`, `strip`, and cross-prefixed or versioned variants
   until a reviewed Zig-backed wrapper exists and emits receipts that the
   process auditor can correlate.

Generated `config.log` and CMake cache files are uploaded opportunistically.
They are not inspected or required by the current build-only workflow, and their
presence does not promote a profile. Cargo verbose output, Ruby `showflags`,
and `RbConfig::CONFIG` become required only when a repository adapter declares
and validates them.

Compiler banner text and object-file comment sections are supporting evidence;
they are not sufficient by themselves.

A green build-only result proves only the declared build boundary for that
repository, commit, and profile. It does not prove artifact ABI, dependency
closure, loadability, or target execution.

## Promotion beyond build-only

An `artifact-inspected` result must first satisfy the build-only contract, then
record each declared artifact's architecture, ABI, interpreter, native
dependencies, C++ runtime, and maximum required glibc version where applicable.

A `run-verified` result must also execute the inspected artifact and its tests
on the target or a declared emulator. A repository adapter must record both the
inspection and execution evidence before its profile can be promoted. The
controller's local smoke executions exercise the toolchain itself and do not
promote any current profile beyond `build-only`.

## Build-system rules

- Autoconf profiles set `CC`, `CXX`, `AR`, and `RANLIB` to executable wrapper
  paths and use both `--build` and `--host` for cross builds.
- CMake profiles use a fresh build tree and an explicit toolchain file. A
  configured build tree is never retargeted.
- Recursive Make invocations must propagate wrapper paths. Hard-coded compiler
  paths are patched or rejected.
- Cargo profiles configure both the Rust target linker and `cc-rs` variables.
  Host build scripts/proc macros and target crates are kept separate by an
  explicit Cargo `--target`.
- Repository adapters are loaded from the pinned controller's `adapters/`
  tree and run with the source checkout as their working directory.
  `RZ_SOURCE_REF_NAME` is a trusted, validated tracked-branch identity that an
  adapter may use for branch-specific configuration. Adapters use fail-fast
  shell behavior and never suppress a failed compiler, linker, archiver, or
  native test command.
- Linker-plugin LTO is disabled until the Rust and Zig LLVM boundaries are
  proven compatible for the pinned versions.
- C++ runtime selection is explicit; libc++ and libstdc++ are never mixed by
  accident.
