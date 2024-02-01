# Build the main executable.

boulder_sources = [
    'cli/package.d',
    'cli/build_command.d',
    'cli/chroot_command.d',
    'cli/deletecache_command.d',
    'cli/new_command.d',
    'cli/update_command.d',
    'cli/version_command.d',
    'buildjob.d',
    'controller.d',
    'environment.d',
    'upstreamcache.d',
    'stages/build_package.d',
    'stages/chroot_package.d',
    'stages/clean_root.d',
    'stages/create_root.d',
    'stages/configure_root.d',
    'stages/fetch_upstreams.d',
    'stages/populate_root.d',
    'stages/share_upstreams.d',
    'stages/sync_artefacts.d',
    'stages/package.d',
    'main.d',
]

boulder_includes = [
    include_directories('.'),
]

boulder_deps = [
    link_libmoss_config,
    link_libmoss_core,
    link_libmoss_deps,
    link_libmoss_format,
    link_libmoss_fetcher,
    link_libdrafter,
    link_libmason,
]

boulder = executable(
	'boulder',
	boulder_sources,
	install: true,
	dependencies: boulder_deps,
	include_directories: boulder_includes,
	link_args: ['--link-defaultlib-shared=false'],
	d_import_dirs: [
		boulder_data_dir,
	]
)

# Ensure mason works
install_symlink('mason',
    install_dir: 'bin',
    pointing_to: 'boulder')
