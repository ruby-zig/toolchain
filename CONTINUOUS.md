# Continuous source builds

The public `ruby-zig/toolchain` controller owns the build policy. Continuous
sync code may request a build, but it cannot select an adapter, targets, Ruby
runtime, Rust boundary, compiler version, or build command.

## Dispatch contract

`.github/workflows/continuous.yml` accepts exactly three values:

- `source-repository`: an exact `ruby-zig/<name>` fork in the fleet lock (the
  fork name may differ from its upstream repository after a rename);
- `source-ref-name`: an exact tracked branch for that fork;
- `source-sha`: the lowercase 40-character commit produced by synchronization.

`scripts/render-continuous-matrix.py` validates the complete pinned fleet plan
and finds that exact repository/branch identity in `config/fleet-lock.json`.
The executable entry supplies the controller-owned adapter, selected profile
subset, exact external Ruby runtime, and Rust boundary. The candidate SHA
replaces only the baseline source SHA in the derived matrix. Profile-specific
`build_script` and `rust` overrides, when declared by the lock, are resolved
before both fleet and continuous matrix entries reach the same reusable
workflow. There is no input through which a caller can broaden the build.

A tracked source without an executable entry is rejected. All four maintained
CRuby refs have certified native GNU shared baselines and executable entries.
The immutable baselines are `89d3b11eace35b8e279b970b4ff5125f171d0d4b`
for `master`, `f3a72fe0a6d35583e215422e8887d3df0a1670b8` for
`ruby_4_0`, `aac3e36dd4bee40fc89893209553903706fa5666` for
`ruby_3_4`, and `0581089df9f0af0fe6b64cb8167987c211100947` for
`ruby_3_3`. Master and 4.0 certify YJIT and ZJIT; 3.4 and 3.3 are
YJIT-only. Each synchronized descendant is dispatched by exact SHA. Cross
profiles remain uncertified catalog backlog and are absent from these locks.

## ziguanite caller

`.github/workflows/ziguanite.yml` is the no-input entry point for the CRuby
fork. It fixes `source-repository` to `ruby-zig/ziguanite`, admits only the four
maintained branch names, and resolves the newest commit shared by that public
fork branch and its matching `ruby/ruby` branch. This prevents workflow-only
commits in the fork from becoming Ruby source while retaining an exact,
publicly verifiable source SHA.
The source repository therefore cannot supply a compiler, adapter, target,
runtime, build command, or alternate source identity. The controller commit is
derived from the workflow file that defines the controller job rather than the
caller commit, so a cross-repository reusable call still checks out the exact
pinned controller revision.

## Public graph proof

Before any candidate source checkout or build command, the plan job fetches
only the allowlisted branch from the public upstream and public fork into a
temporary bare Git object store. It does not check out or execute source. The
candidate is accepted only when all three conditions hold:

1. the certified baseline is an ancestor of the candidate;
2. the candidate is reachable from the current public upstream tracked ref;
3. the candidate is reachable from the current public fork tracked ref.

The build job depends on that proof and checks out the candidate by exact SHA.
Both controller and source checkouts are credential-free and the workflow has
only `contents: read`. Concurrency is keyed by repository, branch, and SHA;
duplicate dispatches wait rather than cancelling evidence already in flight.

## Provenance artifact

Every reusable build writes `toolchain/provenance/provenance.json` before the
repository adapter runs. The uploaded record binds:

- source fork, tracked branch, and exact source SHA;
- controller SHA and fleet-lock digest;
- adapter ID, schema, manifest digest, build-script path, and script digest;
- the full selected target profile;
- declared and observed Zig, Ruby, and optional Rust tool versions;
- caller repository, event, workflow, run ID, attempt, and run URL.

Receipts and traces remain the compiler-boundary evidence. Provenance makes the
policy and dispatch identity that produced those receipts independently
auditable.

## Trust split

The controller should remain public: its wrappers, adapters, locks, workflows,
and certification claims need public review and reuse. Privileged fork
fast-forwarding belongs in the separate `ruby-zig/infra` repository described
in `ARCHITECTURE.md`; credentials are organization secrets and never enter a
source build. This controller path neither updates forks nor requires a write
token.
