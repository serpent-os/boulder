# Build the main executable.

boulder_sources = [
    'cli/package.d',
    'cli/new_command.d',
    'cli/version_command.d',
    'cli/build_command.d',
    'buildjob.d',
    'controller.d',
    'upstreamcache.d',
    'stages/build_package.d',
    'stages/clean_root.d',
    'stages/create_root.d',
    'stages/configure_root.d',
    'stages/fetch_upstreams.d',
    'stages/populate_root.d',
    'stages/share_upstreams.d',
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
    link_libchef,
    link_libmason,
]

boulder = executable(
	'boulder',
	boulder_sources,
	install: true,
	dependencies: boulder_deps,
	include_directories: boulder_includes,
	link_args: ['--link-defaultlib-shared=false'],
)