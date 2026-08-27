# ruby.zig

![The Ziguana wrapped around a ruby](assets/ziguana-ruby.png)

`ruby-zig` is a fleet of public forks of `ruby/*` built with a pinned Zig
toolchain. The organization login is `ruby-zig`; its display name is
`ruby.zig`.

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

The inventory covers all 190 public `ruby/*` repositories. Of those, 42
contain committed native source and 148 have no native compilation to route.
The initial controller smoke certifies native glibc and cross-libc musl C,
C++, archive, and Rust links on Linux. Every catalog profile remains
`build-only` until its repository adapter records artifact inspection and
target execution.

AArch64 Linux Rust linking is explicitly blocked for Zig 0.16 rather than
dropping Rust's Cortex-A53 erratum mitigation. The exact boundary and evidence
rules are in `CONFORMANCE.md`.

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
that make a lane certifiable.

Privileged synchronization belongs in a separate `ruby-zig/infra` repository.
That repository has no build logic and passes no credentials to build jobs. A
narrow GitHub App token may fast-forward clean default branches and dispatch
trusted fleet runs; divergence is reported and never force-pushed.

## Fleet size

The current full sweep is at most 526 jobs: nine target profiles for each of 42
native-source repositories, plus one ordinary build/test job for each of the
148 repositories where Zig is correctly reported as not applicable. GitHub
limits a matrix to 256 jobs per workflow run, so the active sweep is split
across three runs. The seven 252-job shards in the capacity plan cover the
future worst case where all 190 repositories acquire native source; they are
not launched merely to repeat no-native work.

Normal upstream updates rebuild only the repositories whose source SHA changed.
A weekly or manually requested sweep exercises the complete declared scope.

## Repository layout

- `action.yml` is the reusable compiler-configuration action.
- `config/repositories.json` is the complete generated `ruby/*` inventory.
- `config/builds.json` assigns repository scope, adapter status, and fleet shards.
- `config/zig.json` pins official Zig archives and digests.
- `config/targets.json` declares cross profiles, verification levels, and Rust
  link status.
- `toolchain/bin/` contains the compiler and linker drivers.
- `scripts/` inventories, forks, synchronizes, installs, and audits the fleet.
- `.github/workflows/` contains reusable runner workflows.

`CONFORMANCE.md` defines what a green Zig badge proves. A build that merely
sets `CC` is not certified.
