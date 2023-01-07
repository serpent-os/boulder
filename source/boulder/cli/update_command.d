/*
 * SPDX-FileCopyrightText: Copyright © 2020-2023 Serpent OS Developers
 *
 * SPDX-License-Identifier: Zlib
 */

/**
 * boulder.cli.update_command
 *
 * Implements the `boulder update` subcommand
 *
 * Authors: Copyright © 2020-2023 Serpent OS Developers
 * License: Zlib
 */

module boulder.cli.update_command;

public import moss.core.cli;
import boulder.cli : BoulderCLI;
import core.sys.posix.unistd : geteuid;
import drafter;
import dyaml;
import moss.core;
import moss.core.util : computeSHA256;
import moss.fetcher;
import std.algorithm : each;
import std.stdio : File;
import std.file : exists;
import std.format : format;
import std.experimental.logger;

/**
 * The BuildCommand is responsible for handling requests to build stone.yml
 * formatted files into useful binary packages.
 */
@CommandName("update")
@CommandHelp("Update the version for an existing recipe")
@CommandUsage("[version] [tarball]")
public struct UpdateCommand
{
    /** Extend BaseCommand with UpdateCommand specific functionality */
    BaseCommand pt;
    alias pt this;

    /**
     * Manipulation of recipes
     */
    @CommandEntry() int run(ref string[] argv)
    {
        immutable useDebug = this.findAncestor!BoulderCLI.debugMode;
        globalLogLevel = useDebug ? LogLevel.trace : LogLevel.info;

        if (argv.length != 2)
        {
            warning("No arguments specified. For help, run boulder update -h");
            return ExitStatus.Failure;
        }

        if (!recipeLocation.exists)
        {
            error(format!"Unable to find stone.yml in current directory. Use -r to specify location.");
            return 1;
        }

        immutable ver = argv[0];
        immutable tarball = argv[1];

        /* Download the tarball */
        auto f = new FetchController();
        auto dlLoc= "/tmp/boulderUpdateTarball";
        auto j = Fetchable(tarball, dlLoc, 0, FetchType.RegularFile, null);
        f.enqueue(j);
        while (!f.empty())
        {
            f.fetch();
        }
        info(format!"Wrote tarball to %s"(dlLoc));

        auto hash = computeSHA256(dlLoc, true);
        info(format!"Hash: %s"(hash));

        /* Overwrite recipe with updated params */
        Node root = Loader.fromFile(recipeLocation).load();
        immutable rel = root["release"].as!int;
        // FIXME: This isn't really working as expected
        immutable upstreams = format("%s : %s", tarball, hash);
        root["release"] = rel + 1;
        root["version"] = ver;
        root["upstreams"] = upstreams;
        /* Purposely write as test.yaml for now as this is still PoC */
        dumper().dump(File("test.yaml", "w").lockingTextWriter, root);
        info("Successfully updated recipe");

        return 0;
    }

    /** Where to output the YML file */
    @Option("r", "recipe-location", "Location of existing stone.yml file to update version")
    string recipeLocation = "stone.yml";
}


