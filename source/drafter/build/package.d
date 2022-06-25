/*
 * SPDX-FileCopyrightText: Copyright © 2020-2022 Serpent OS Developers
 *
 * SPDX-License-Identifier: Zlib
 */

/**
 * drafter.build
 *
 * Module namespace imports & Build API
 *
 * Authors: Copyright © 2020-2022 Serpent OS Developers
 * License: Zlib
 */

module drafter.build;

public import drafter.build.autotools;
public import drafter.build.cmake;
public import drafter.build.meson;
public import drafter.build.python;
public import drafter.build.rust;

import std.traits : EnumMembers;
import std.string : capitalize;
import std.experimental.typecons : wrap;

public Build buildTypeToHelper(BuildType type)
{
    auto nom = cast(string) type;

    final switch (nom)
    {
        static foreach (member; EnumMembers!BuildType)
        {
    case member:
            /* Disallow unknown, return null */
            static if (member == "unknown")
            {
                return null;
            }
            else
            {
                /* Return class based instantiation */
                mixin("auto helper = " ~ member.capitalize ~ "Build();");
                return helper.wrap!Build;
            }
        }
    }
}

/**
 * Supported build system types.
 */
public enum BuildType : string
{
    /**
     * Uses configure/make/install routine
     */
    Autotools = "autotools",

    /**
     * CMake integration
     */
    CMake = "cmake",

    /**
     * Uses meson + ninja
     */
    Meson = "meson",

    /**
     * Uses python pep517
     */
    PythonPEP517 = "pythonpep517",

    /**
     * Uses python setuptools
     */
    PythonSetuptools = "PythonSetuptools",

    /**
     * Uses cargo.
     */
    Cargo = "cargo",

    /**
     * Unsupported tooling
     */
    Unknown = "unknown",
}

/**
 * Any BuildPattern implementation must have the
 * following members to be valid. For lightweight
 * usage we actually use structs not class implementations.
 */
public interface Build
{
    /**
     * Implement the `setup` step
     */
    string setup();

    /**
     * Implement the `build` step
     */
    string build();

    /**
     * Implement the `install` step
     */
    string install();

    /**
     * Implement the `check` step
     */
    string check();
}

/**
 * Our buildflags allow us to know what is *available* without
 * emitting invalid instructions.
 */
public enum BuildFlags
{
    /**
     * No flags
     */
    None = 1 << 0,

    /**
     * Build has a setup() stage available
     */
    Configurable = 1 << 1,

    /**
     * Build has a build() stage available
     */
    Buildable = 1 << 2,

    /**
     * Build has an install() stage available
     */
    Installable = 1 << 3,

    /**
     * Build has a check() stage available
     */
    Testable = 1 << 4,
}

/**
 * Build options may be non-standard or require specific
 * tweaks, thus we centralise their oddities and make
 * them available to the Build interface.
 */
public struct BuildOptions
{
    /** Explicitly requested working directory */
    string workingDir = null;

    /** No default flags */
    BuildFlags flags = BuildFlags.None;
}
