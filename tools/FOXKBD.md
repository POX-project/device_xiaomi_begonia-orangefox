# foxkbd prebuilt

`recovery/root/system/bin/foxkbd` is a **prebuilt** static binary, not built by
the OrangeFox workflow. The full build only verifies it (architecture, static
linking, checksum); compiling it in the same job forced a distro aarch64 cross
compiler into an apt transaction that also needs `gcc-multilib`, and the two
packages Conflict on Ubuntu 22.04.

| field | value |
|---|---|
| source | `tools/foxkbd.c` + `tools/font8x8.h` |
| built from | `net-fix` at `690d28f` |
| built by | `foxkbd build` run `39914843578` (aarch64-linux-gnu-gcc, `-Os -static -s`) |
| sha256 | `9b198d9658bab50b1b0f8cce78e74059c4220632d413d8e52383a4c46c263eb6` |
| size | 559,888 bytes |
| type | ELF 64-bit LSB executable, ARM aarch64, statically linked, stripped |

## Rebuilding

Edit `tools/foxkbd.c`, then run the `foxkbd build` workflow
(`${GHUSER}/orangefox-begonia-build`, `.github/workflows/foxkbd.yml`),
which installs only the cross sysroot and uses clang:

```sh
clang --target=aarch64-linux-gnu --sysroot=/usr/aarch64-linux-gnu \
  -D_GNU_SOURCE -Os -static -s -Wall -Wextra -I tools \
  -o recovery/root/system/bin/foxkbd tools/foxkbd.c
```

Download the `foxkbd-aarch64` artifact, commit it here, and update the sha256
above and the expectation in `build.yml` (step *Verify on-screen keyboard
helper*).
