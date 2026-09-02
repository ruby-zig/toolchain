# ruby/fiddle Zig adapter

This adapter builds Fiddle and its libffi dependency for the
`x86_64-linux-gnu.2.17` lane. The dependency is the official libffi 3.4.6
release archive declared in `libffi.json`, pinned by byte size and SHA-256.
The reusable workflow verifies that contract before setting the scoped
`RZ_DEP_LIBFFI_ARCHIVE` input; the adapter verifies it again before extraction.

libffi is configured with shared libraries disabled. Its C and C++ sources,
archives, and indexes all pass through the controller's Zig wrappers, and the
resulting convenience archive is linked into `fiddle.so`. Certification rejects
a dynamic libffi dependency, unresolved `ffi_*` symbols, RPATH or RUNPATH, a
wrong target receipt, or a GLIBC requirement above 2.17.

The exact staged artifact must call a real foreign function and execute and
free a libffi closure callback. Cross profiles remain pending until they have a
matching target-native Ruby SDK and runtime; the pinned source dependency alone
does not make the Ruby extension cross-runnable.
