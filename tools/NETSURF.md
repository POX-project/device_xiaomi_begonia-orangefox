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

Rebuild recipe: there is no build script in this tree.  The binary is a
musl cross build of NetSurf 3.11 configured for the framebuffer frontend
(`--enable-framebuffer --enable-js`, libnsfb with the `linux` and `ram`
surfaces), stripped.  It is committed as a prebuilt because the recovery
build cannot ship the NetSurf dependency stack (libcss, libdom, libhubbub,
libnsfb, duktape, ...).  `tools/build-links.sh` and `tools/build-foxnet.sh`
are the equivalent recipes for the older Links2 payload and for curl.