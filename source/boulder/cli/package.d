/*
 * SPDX-FileCopyrightText: Copyright © 2020-2023 Serpent OS Developers
 *
 * SPDX-License-Identifier: Zlib
 */

/**
 * boulder.cli
 *
 * Module namespace imports & core CLI definition
 *
 * Authors: Copyright © 2020-2023 Serpent OS Developers
 * License: Zlib
 */

module boulder.cli;

public import moss.core.cli;
public import boulder.cli.build_command;
public import boulder.cli.chroot_command;
public import boulder.cli.deletecache_command;
public import boulder.cli.new_command;
public import boulder.cli.update_command;
public import boulder.cli.version_command;

/**
 * The BoulderCLI type holds some global configuration bits
 */
@RootCommand @CommandName("boulder")
@CommandHelp("boulder - produce packages for moss", "A core component of the Serpent tooling")
@CommandUsage("[--args] [command]")
public struct BoulderCLI
{
    /** Extend BaseCommand to give a root command for our CLI */
    BaseCommand pt;
    alias pt this;

    /** When set to true, we enable debug output */
    @Option("d", "debug", "Enable debugging output") bool debugMode = false;

    /** Specific build configuration profile to use */
    @Option("p", "profile", "Override default build profile") string profile = "default-x86_64";

    /**
     * Where to find the root of configurations (/etc + /usr)
     */
    @Option("C", "config-directory", "Root directory for configurations")
    string configDir;
}
