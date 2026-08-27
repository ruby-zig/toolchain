# Continuous source builds

The public `ruby-zig/toolchain` controller owns the build policy. Continuous
sync code may request a build, but it cannot select an adapter, targets, Ruby
runtime, Rust boundary, compiler version, or build command.

## Dispatch contract

`.github/workflows/continuous.yml` accepts exactly three values:

- `source-repository`: an exact `ruby-zig/<name>` fork in the fleet lock;
- `source-ref-name`: an exact tracked branch for that fork;
- `source-sha`: the lowercase 40-character commit produced by synchronization.

`scripts/render-continuous-matrix.py` validates the complete pinned fleet plan
and finds that exact repository/branch identity in `config/fleet-lock.json`.
The executable entry supplies the controller-owned adapter, selected profile
subset, exact external Ruby runtime, and Rust boundary. The candidate SHA
replaces only the baseline source SHA in the derived matrix. There is no input
through which a caller can broaden the build.

A tracked source without an executable entry is rejected. This includes the
four CRuby branches at present: they remain visible in fleet planning, but no
continuous CRuby source is executed until a CRuby adapter and baseline are
explicitly certified in the lock.

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
