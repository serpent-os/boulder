/*
 * SPDX-FileCopyrightText: Copyright © 2020-2023 Serpent OS Developers
 *
 * SPDX-License-Identifier: Zlib
 */

/**
 * boulder.main
 *
 * Main entry point for our binary
 *
 * Through symlink names (in `/usr`) we provide the main entry point
 * for both `mason` and `boulder`. This decision was made to avoid
 * having two binaries which would honestly just be bloat.
 *
 * Authors: Copyright © 2020-2023 Serpent OS Developers
 * License: Zlib
 */

module main;

import boulder.cli;
import core.sys.posix.unistd;
import mason.cli;
import moss.core.logger;
import std.path : baseName;
import std.stdio;

/**
 * Handle main entry for the boulder subtool
 */
int boulderMain(string[] args)
{
    auto clip = cliProcessor!BoulderCLI(args);
    clip.addCommand!BuildControlCommand;
    clip.addCommand!ChrootCommand;
    clip.addCommand!DeleteCacheCommand;
    clip.addCommand!NewCommand;
    clip.addCommand!UpdateCommand;
    clip.addCommand!VersionCommand;
    clip.addCommand!HelpCommand;
    return clip.process(args);
}

/**
 * Handle main entry for the mason subtool
 */
int masonMain(string[] args)
{
    auto clip = cliProcessor!MasonCLI(args);
    clip.addCommand!BuildCommand;
    clip.addCommand!HelpCommand;
    return clip.process(args);
}

int main(string[] args)
{
    if (isatty(0) && isatty(1))
    {
        configureLogger(ColorLoggerFlags.Color | ColorLoggerFlags.Timestamps);
    }
    else
    {
        configureLogger(ColorLoggerFlags.Timestamps);
    }

    auto programName = args[0].baseName;
    switch (programName)
    {
    case "mason":
        return masonMain(args);
    default:
        return boulderMain(args);
    }
}
