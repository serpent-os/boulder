libdrafter_sources = [
    'package.d',
    'build/autotools.d',
    'build/cmake.d',
    'build/meson.d',
    'build/package.d',
    'build/python.d',
    'build/rust.d',
    'license/engine.d',
    'license/package.d',
    'metadata/basic.d',
    'metadata/github.d',
    'metadata/package.d',
]

libdrafter_deps = [
    link_libmoss_core,
    link_libmoss_fetcher,
    link_libmoss_deps,
    link_libmoss_format,
]

libdrafter = static_library(
    'drafter',
    libdrafter_sources,
    include_directories: global_includes,
    dependencies: libdrafter_deps,
    d_import_dirs: [
        boulder_data_dir,
    ]
)

link_libdrafter = declare_dependency(
    link_whole: libdrafter,
    include_directories: global_includes,
    dependencies: libdrafter_deps,
)
