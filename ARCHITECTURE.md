# Fleet architecture

The fleet separates public build policy from the one credentialed maintenance
operation. Both repositories should be public: the code contains no secrets,
and public review is part of the value of the project. Credentials remain in
GitHub organization secrets.

## Controller and infrastructure

`ruby-zig/toolchain` is the public controller. It owns the Zig and Rust pins,
compiler wrappers, target profiles, controller-owned repository adapters,
reusable Actions workflow, process-trace auditor, and fleet planner. Build jobs
receive only a read-only GitHub token. Forks and outside projects can review and
reuse the same action by pinning a full controller commit.

`ruby-zig/infra` is the public control plane for inventory, fork creation, and
continuous fast-forward synchronization. Its GitHub App private key is stored
only as an organization Actions secret. A synchronization lane mints a
short-lived token scoped to one destination repository. That token is never
passed to a source build.

Keeping these roles separate makes the trust boundary plain:

- `toolchain` decides how an immutable source commit is built and audited;
- `infra` may advance a clean fork ref and dispatch a trusted build;
- each source build can read code and upload evidence, but cannot update a fork.

## Discovery inventory and fork set

The discovery inventory retains all 190 public `ruby/*` repositories. The
current native-scope scan classifies them as:

- 38 repositories with a directly built native product;
- one repository with committed native tests;
- three repositories where native files are fixtures, templates, or examples;
- 148 repositories with no committed native source.

Only the first 39 repositories belong to the affected fork and build fleet.
CRuby contributes four maintained tracked branches instead of one, so those
repositories currently represent 42 source refs. The other 151 stay in
discovery so a future scope scan can promote them without losing history, but
they do not create forks or runner lanes today. This avoids
claiming that an ordinary pure-Ruby test run is a Zig compilation.

Every fleet repository keeps a public GitHub fork. Its default branch must be
byte-for-byte upstream history and may move only by a non-forced fast-forward.
A missing fork, wrong parent, changed default branch, ahead branch, or
divergence is a visible failure. Zig compatibility patches belong on
`zigcc/<default-branch>` or smaller topic branches.

## Why the plan reserves 378 jobs

The target catalog has nine profiles:

- x86_64 and AArch64 glibc Linux;
- x86_64, AArch64, and RISC-V 64 musl Linux;
- x86_64 and AArch64 Windows GNU;
- x86_64 and AArch64 macOS.

The maximum coverage envelope is therefore `42 * 9 = 378` lanes. GitHub
allows at most 256 matrix jobs in one workflow run. The controller uses two
contiguous capacity shards: 252 lanes in shard 1 and 126 in shard 2.

The plan keeps all 378 lanes visible. It admits only the 17 repository,
branch, and profile combinations with executable certified contracts; every
other lane remains explicitly pending. The ready set is GNU for `bigdecimal`,
`date`, `digest`, `fcntl`, `io-console`, `io-nonblock`, `io-wait`, `json`,
`stringio`, `strscan`, and all four maintained CRuby refs, plus GNU and musl
for `prism`, with CRuby master also admitted for musl. The two active shards
therefore contain 252 and 126 desired lanes while only certified entries are
sent to runners. io-console's executable contract loads the exact staged
extension and exercises terminal behavior on a pseudoterminal.

Each immutable executable source entry in `config/fleet-lock.json` contains a
nonempty, duplicate-free subset of certified profile IDs. Selected profiles
may run; unselected profiles stay in the same fleet as pending target backlog
instead of disappearing from the workload. A selected Rust profile whose link
status is not `smoke-verified` also remains pending so an unsupported target
cannot silently look green.

Each executable source keeps source-level `build_script` and `rust` defaults.
When one selected target needs a different certified contract, an optional
`profile_overrides` object may replace only those two values for that exact
profile ID. Override IDs must already be selected by `profiles`, override
objects are closed to unknown fields, and an absent override preserves the
existing source contract byte-for-byte in rendered matrices.

The baseline lock remains immutable. After a trusted fast-forward, infra must
dispatch the allowlisted repository, tracked branch, and exact resulting SHA.
The controller may reuse only that branch's already certified adapter/profile
contract; it never resolves a moving ref inside a build job. The complete
selected matrix runs on the slower sweep cadence and on demand.

## Immutable lane contract

A tracked source-ref record binds an upstream repository, explicit branch
name, stable result identity, exact snapshot SHA, and Rust boundary. CRuby
`master`, `ruby_4_0`, `ruby_3_4`, and `ruby_3_3` all have executable
native GNU shared baselines. EOL `ruby_3_2` is absent. Master and 4.0 certify
YJIT and ZJIT; 3.4 and 3.3 are YJIT-only. The older-release certification
covers 155 built DSOs and a 26-family native-extension smoke set, explicitly
excluding `fiddle`, `openssl`, `psych`, and `zlib`. A newer tracked-branch
tip is admitted only as an exact, ancestry-checked continuous candidate derived
from that branch's immutable baseline. The release baselines are
`f3a72fe0a6d35583e215422e8887d3df0a1670b8`,
`aac3e36dd4bee40fc89893209553903706fa5666`, and
`0581089df9f0af0fe6b64cb8167987c211100947` for 4.0, 3.4, and 3.3
respectively.

A ready executable lock entry additionally binds:

- the exact `ruby-zig/<name>` fork and lowercase full source commit SHA;
- the matching result identity, adapter ID, and controller-relative
  `adapters/.../build.sh`;
- the selected target profile IDs;
- an exact numeric Ruby runtime version in `x.y.z` form;
- whether the repository includes Rust compilation.

The runner checks out source and controller at immutable commits. It executes
the adapter from the controller while keeping the source checkout as its
working directory. Source forks therefore do not need fleet-only workflow or
adapter commits on their clean default branches.

The pinned `ruby/setup-ruby` action supplies a prebuilt Ruby interpreter to
run `extconf.rb`, Rake, and repository tests. That interpreter is an explicit
external runtime input rather than a fleet output. The CRuby adapter builds its
own `miniruby`, `ruby`, and shared `libruby`; certification covers those
outputs and the native transformations inside each adapter's declared source
scope.

## Certification boundary

For a declared profile, C-family compilation, native linking, and C-family
archives must be performed by the pinned Zig distribution. Rust source is
compiled by pinned `rustc`; Zig drives supported final native links and C/C++
dependencies.

Linux certification uses a poison `PATH`, process tracing, and wrapper receipt
correlation. macOS currently records receipts but is not process-trace
certified. All cross profiles remain uncertified catalog backlog until the
adapter inspects their ABI and, where a runner exists, executes their tests;
none of the four CRuby baseline locks admits a cross profile.

A Ruby extension built against the GNU Ruby SDK is not a certifying musl lane,
even when Zig emits a musl ELF artifact. That requires a target-native musl Ruby
SDK and runtime.

## Operating sequence

1. Scan all upstream refs and the affected destination forks.
2. Queue only missing, changed, or erroneous affected forks.
3. Validate fork identity and non-force fast-forward a changed tracked ref.
4. Dispatch the allowlisted repository, tracked source-ref name, and exact
   post-sync SHA.
5. From its immutable baseline, the controller derives the adapter, profile
   subset, Ruby runtime, and Rust boundary, then ancestry-checks the source
   against the expected upstream and fork refs.
6. Run the adapter against pinned controller and source commits on standard
   public runners.
7. Publish receipts, traces, artifact inspection, test results, and explicit
   pending lanes.

This keeps synchronization cheap when nothing changed, makes builds
reproducible, and leaves upstream-facing patch history readable.
