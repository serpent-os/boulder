/* SPDX-License-Identifier: Zlib */

/**
 * Drafter - Python integration
 *
 * Authors: Â© 2020-2022 Serpent OS Developers
 * License: Zlib
 */

module drafter.build.rust;

import moss.deps.analysis;
import drafter : Drafter;
import drafter.build : BuildType;
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

public struct CargoBuild
{
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
        return null;
    }

    string check()
    {
        return "%cargo_check";
    }
}
