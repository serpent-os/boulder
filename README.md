### boulder

This repository contains the `boulder` tool, which is used to produce
`.stone` binary packages from a `stone.yml` source definition file.

#### Prerequisites

`boulder` (and its own dependencies) depends on a couple of system libraries
and development headers, including (in fedora package names format):

- `cmake`, `meson` and `ninja`
- `libcurl` and `libcurl-devel`
- `libzstd` and `libzstd-devel`
- `xxhash-libs` and `xxhash-devel`
- `moss` (build prior to building `boulder`)

### Cloning

Remember to add the `--recurse-submodule` argument (for serpent-style commit hook, `update-format.sh` and editorconfig settings).

### Building

    meson --prefix=/usr build/
    meson compile -C build/
    sudo ninja install -C build/

### Running

    sudo boulder build stone.yml
