/*
 * SPDX-FileCopyrightText: Copyright © 2020-2023 Serpent OS Developers
 *
 * SPDX-License-Identifier: Zlib
 */

/**
 * drafter.build.cmake
 *
 * CMake integration
 *
 * Authors: Copyright © 2020-2023 Serpent OS Developers
 * License: Zlib
 */

module drafter.build.cmake;

import moss.deps.analysis;
import std.path : baseName;
import drafter : Drafter;
import drafter.build : BuildType, Build;

/**
 * Is this cmake??
 */
static public AnalysisReturn acceptCMake(scope Analyser an, ref FileInfo inpath)
{
    Drafter dr = an.userdata!Drafter;
    auto bn = inpath.path.baseName;
    import std.string : count;

    /**
     * Depth too great
     */
    if (inpath.path.count("/") > 2)
    {
        return AnalysisReturn.NextHandler;
    }

    switch (bn)
    {
    case "CMakeLists.txt":
        dr.incrementBuildConfidence(BuildType.CMake, 20);
        return AnalysisReturn.IncludeFile;
    default:
        return AnalysisReturn.NextHandler;
    }
}

/**
 * Handler for cmake files
 */
public static AnalysisChain cmakeChain = AnalysisChain("cmake", [&acceptCMake], 20);

/**
 * Handle emission of cmake builds
 */
public final class CmakeBuild : Build
{
override:

    string setup()
    {
        return "%cmake";
    }

    string build()
    {
        return "%cmake_build";
    }

    string install()
    {
        return "%cmake_install";
    }

    string check()
    {
        return null;
    }
}
