# ruby.zig

![The Ziguana wrapped around a ruby](assets/ziguana-ruby.png)

`ruby-zig` is a fleet of public forks for the affected native repositories in
`ruby/*`, built with a pinned Zig toolchain. The organization login is
`ruby-zig`; its display name is `ruby.zig`.

The project has three rules:

1. Every upstream repository remains a GitHub fork. Its upstream default
   branch stays clean and fast-forwardable.
2. C, C++, Objective-C, assembly preprocessing, native linking, and C-family
   archive work in a certified profile goes through the pinned Zig
   distribution (`zig cc`, `zig c++`, `zig ar`, and `zig ranlib`).
3. Builds run on public standard GitHub Actions runners. Native and cross
   profiles are split into matrix jobs, with no paid runner dependency.

Rust source is compiled by pinned `rustc`. Cargo and `rustc` use `zig cc` as
their native linker driver, and crates that build C or C++ receive the same Zig
wrappers. This is the mechanism described in
[Zig Makes Rust Cross-compilation Just Work](https://actually.fyi/posts/zig-makes-rust-cross-compilation-just-work/)
and developed further by
[`cargo-zigbuild`](https://github.com/rust-cross/cargo-zigbuild); it does not
pretend that `zig cc` parses Rust syntax.

## Current bring-up

The discovery inventory keeps all 190 public `ruby/*` repositories. The
native-scope scan found 38 repositories that build a native product, one with
committed native tests, three whose native files are only fixtures or examples,
and 148 with no committed native source. The active fork and build fleet is the
first 39 repositories. CRuby's maintained `master`, `ruby_4_0`, `ruby_3_4`,
and `ruby_3_3` branches are distinct tracked sources, giving the fleet 42
source refs in total. The EOL `ruby_3_2` branch is excluded. Fixture-only and
no-native repositories create no fleet lanes; they re-enter automatically when
a later scope scan changes their classification.

The initial controller smoke certifies native glibc and cross-libc musl C,
C++, archive, and Rust links on Linux. Every selected catalog profile remains
`build-only` until its repository adapter records artifact inspection and
target execution.

AArch64 Linux Rust linking is explicitly blocked for Zig 0.16 rather than
dropping Rust's Cortex-A53 erratum mitigation. The exact boundary and evidence
rules are in `CONFORMANCE.md`.

Ruby extensions driven by the prebuilt GNU Ruby SDK are executable only on the
GNU profile. Their musl artifacts remain experimental and non-certifying until
the fleet has a target-native musl Ruby SDK.

CRuby `master` has one executable native GNU baseline with its Rust JITs
enabled. The synchronized master tip remains a continuous candidate until that
exact descendant commit passes independently; `ruby_4_0`, `ruby_3_4`, and
`ruby_3_3` remain tracked but pending.

## Branches

- The upstream default branch is an unmodified, fast-forward-only mirror.
- `zigcc/<upstream-default>` carries the continuously rebased Zig build patch
  stack.
- Small topic branches are cut from `zigcc/<upstream-default>` for upstream
  pull requests.

Organization-owned forks cannot offer GitHub's "allow edits from maintainers"
option. Upstream-facing topic branches therefore stay narrow enough to respin
quickly when review asks for changes.

## Controller and infrastructure

`ruby-zig/toolchain` is public. It contains the pinned compiler distribution,
wrappers, composite action, reusable certification workflow, target catalog,
repository adapters, and fleet manifests. Fork workflows pin it by full commit
SHA:

```yaml
- uses: ruby-zig/toolchain@<full-commit-sha>
  with:
    profile: x86_64-linux-gnu.2.17
    rust: "true"
```

The action configures the compiler boundary; the reusable workflow adds the
Linux process trace, poison path, receipt correlation, and negative controls
that make a lane certifiable. Repository adapters also live in this public
controller, so a source fork remains a clean fast-forward of upstream.

Each lock entry declares an exact Ruby `x.y.z` runtime. The reusable workflow
installs that prebuilt runtime with a commit-pinned `ruby/setup-ruby` action to
drive `extconf.rb`, Rake, and tests. That interpreter is an external build
driver, not a fleet output. The CRuby lane builds its own `miniruby`, `ruby`,
and shared `libruby` through the declared Zig and Rust boundary.

Privileged synchronization belongs in a separate `ruby-zig/infra` repository.
That repository has no build logic and passes no credentials to build jobs. A
narrow GitHub App token may fast-forward clean default branches and dispatch
trusted fleet runs; divergence is reported and never force-pushed.

## Fleet size

The affected fleet has a maximum of 378 jobs: nine target profiles for each of
42 tracked source refs across 39 repositories. GitHub limits a matrix to 256
jobs per workflow run, so the controller reserves two contiguous capacity
shards of 252 and 126 lanes.

The first executable lock admits eight lanes: GNU builds for `bigdecimal`,
`date`, `json`, `stringio`, `strscan`, and CRuby, plus GNU and musl builds for
`prism`. Their source SHAs, controller adapters, selected profile subsets,
and Ruby 3.2.3 driver runtime are explicit. Narrowing those seven sources from
the full nine-profile pending envelope gives the current plan 323 desired
lanes, split into active shards of 252 and 71.

That is a ceiling, not the routine workload. Each immutable executable
fleet-lock entry binds a repository and branch result identity, then selects
the profiles meaningful for its adapter; only those selected lanes are
runnable. Unselected profiles remain target-catalog backlog coverage; they are
not rendered as pending lanes. Planned source identities still render their
full pending envelope, and a selected Rust lane whose target is blocked remains
visible as pending instead of disappearing. Fixture-only and no-native
repositories do not consume runner jobs.

The baseline lock remains immutable. Continuous sync must dispatch the exact
post-sync commit SHA together with an allowlisted repository and tracked branch;
a build job never resolves a moving branch ref. CRuby `master` therefore keeps
the verified `89d3b11eace35b8e279b970b4ff5125f171d0d4b` baseline while a
newer synchronized master tip is supplied only as the exact, ancestry-checked
continuous candidate. A weekly or manually requested sweep exercises the
complete selected scope.

## Repository layout

- `action.yml` is the reusable compiler-configuration action.
- `config/repositories.json` is the complete generated `ruby/*` inventory.
- `config/builds.json` preserves discovery scope and identifies the 39-repository
  affected fleet.
- `config/fleet-lock.json` pins fork commits, exact Ruby runtimes, adapters, and
  selected target profiles.
- `config/zig.json` pins official Zig archives and digests.
- `config/targets.json` declares cross profiles, verification levels, and Rust
  link status.
- `toolchain/bin/` contains the compiler and linker drivers.
- `adapters/` contains controller-owned repository build entry points.
- `scripts/` inventories, forks, synchronizes, installs, and audits the fleet.
- `.github/workflows/` contains reusable runner workflows.

`CONFORMANCE.md` defines what a green Zig badge proves. A build that merely
sets `CC` is not certified.
