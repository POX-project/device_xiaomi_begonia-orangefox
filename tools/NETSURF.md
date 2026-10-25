# NetSurf browser payload

`recovery/root/system/etc/foxbrowse/bin/netsurf-fb` is a **prebuilt** static
AArch64 binary (NetSurf framebuffer frontend with the `linux` surface and the
bundled Duktape JavaScript engine), not built by the OrangeFox build itself.

| field | value |
|---|---|
| source | NetSurf 3.11 + custom libnsfb `linux` surface + musl cross build |
| toolchain | aarch64-linux-musl-gcc (GCC 11.2.1), `-Os -static -s` |
| JS engine | Duktape (bundled in NetSurf) |
| verified by | `.github/workflows/build.yml` (AArch64 + static link) |

Rebuild with `tools/build-netsurf.sh` (requires the musl toolchain and the
NetSurf dependency prefix), then copy the resulting `nsfb` to
`recovery/root/system/etc/foxbrowse/bin/netsurf-fb`, strip it, and update this
file.