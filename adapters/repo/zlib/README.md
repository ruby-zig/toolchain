# ruby/zlib Zig adapter

This adapter builds the `ruby/zlib` extension with the ruby.zig Zig wrappers on
the `x86_64-linux-gnu.2.17` lane. It stages `ext/zlib/extconf.rb` and
`ext/zlib/zlib.c` under the external build root, so mkmf and make never write to
the upstream checkout.

The extension repository does not vendor zlib. The GNU lane therefore declares
the runner's existing Ubuntu zlib development files as platform inputs:

- `/usr/include/zlib.h`
- `/usr/include/zconf.h`
- `/usr/lib/x86_64-linux-gnu/libz.so` for linking
- `libz.so.1` at runtime

The adapter does not install or download a package. It fails closed if those
inputs are absent, if the library SONAME is not `libz.so.1`, or if either the
platform library or produced extension exceeds the GLIBC 2.17 ceiling.

Configuration probes, preprocessing, C compilation, probe linking, and shared
linking are all routed through the controller wrappers. A certified controller
run must additionally retain the poison-PATH process trace and wrapper receipts.
The checked-in manifest deliberately remains pending certification until that
run comes from an immutable controller commit.

Other targets need target-native Ruby headers and runtime plus a pinned zlib
build for that target. Reusing this runner's GNU zlib is not a cross-compilation
strategy.
