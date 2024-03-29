/*
 * SPDX-FileCopyrightText: Copyright © 2020-2023 Serpent OS Developers
 *
 * SPDX-License-Identifier: Zlib
 */

/**
 * drafter.build.cargo
 *
 * Drafter - Cargo integration
 *
 * Authors: Copyright © 2020-2024 Serpent OS Developers
 * License: Zlib
 */

module drafter.build.cargo;

import moss.deps.analysis;
import drafter : Drafter;
import drafter.build : BuildType, Build;
import std.path : baseName;

/**
 * Discover Cargo projects.
 */
static private AnalysisReturn acceptCargo(scope Analyser an, ref FileInfo inpath)
{
    Drafter c = an.userdata!Drafter;

    switch (inpath.path.baseName)
    {
    case "Cargo.toml":
        c.incrementBuildConfidence(BuildType.Cargo, 100);
        return AnalysisReturn.IncludeFile;
    default:
        return AnalysisReturn.NextHandler;
    }
}

/**
 * Handler for Cargo projects.
 */
public static AnalysisChain cargoChain = AnalysisChain("cargo", [&acceptCargo], 20);

public final class CargoBuild : Build
{
override:

    string setup()
    {
        return "%cargo_fetch";
    }

    string build()
    {
        return "%cargo_build";
    }

    string install()
    {
        return "%cargo_install";
    }

    string check()
    {
        return "%cargo_check";
    }
}
