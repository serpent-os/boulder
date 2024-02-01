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
import moss.core : ExitStatus;
import moss.core.util : computeSHA256;
import moss.fetcher;
import moss.format.source;
import std.array : split;
import std.algorithm : canFind, filter;
import std.conv : to;
import std.experimental.logger;
import std.file : exists, remove, write;
import std.range;
import std.stdio: File;
import std.string : format, indexOf;
import std.uni : isNumber;


/**
 * The UpdateCommand is responsible for updating the version in a recipe
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
            warning("Unexpected number of arguments specified. For help, run boulder update -h");
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
        trace(format!"Wrote tarball to %s"(dlLoc));

        auto hash = computeSHA256(dlLoc, true);
        info(format!"Hash: %s"(hash));

        auto file = File(recipeLocation);
        auto range = file.byLineCopy(Yes.keepTerminator);
        string buffer;
        bool upstreams;
        foreach (line; range)
        {
            // Colon alignment check
            if (!line.canFind("-") && line.canFind(":"))
            {
                immutable index = line.indexOf(":");
                if (index != 12)
                {
                    warning("Found incorrect colon alignment for recipe");
                }
            }
            // Increment release
            if (line.canFind("release"))
            {
                auto rel = line.filter!(a => a.isNumber).to!int;
                rel++;
                line = format!"release     : %s\n"(rel);
            }
            // Update version
            if (line.canFind("version"))
            {
                line = format!"version     : %s\n"(ver);
            }
            // Update tarball and hash
            if (upstreams == true)
            {
                line = format!"    - %s : %s\n"(tarball, hash);
                upstreams = false;
            }
            if (line.canFind("upstreams"))
            {
                // Ensure we update the next line
                upstreams = true;
            }
            buffer ~= line;
        }
        write("test.yml", buffer);

        scope exit()
        {
            file.close();
            if (dlLoc.exists)
            {
                remove(dlLoc);
            }
        }

        info("Successfully updated recipe");

        return ExitStatus.Success;
    }

    /** Where to output the YML file */
    @Option("r", "recipe-location", "Location of existing stone.yml file to update version")
    string recipeLocation = "stone.yml";
}


