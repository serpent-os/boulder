/*
 * SPDX-FileCopyrightText: Copyright © 2020-2023 Serpent OS Developers
 *
 * SPDX-License-Identifier: Zlib
 */

/**
 * boulder.cli.deletecache_command
 *
 * Implements the `boulder delete-cache` subcommand
 *
 * Authors: Copyright © 2020-2023 Serpent OS Developers
 * License: Zlib
 */

module boulder.cli.deletecache_command;

public import moss.core.cli;
import boulder.buildjob : SharedRootArtefactsCache, SharedRootBuildCache,
    SharedRootCcacheCache, SharedRootPkgCacheCache, SharedRootRootCache;
import boulder.cli : BoulderCLI;
import boulder.upstreamcache : SharedRootUpstreamsCache;
import core.sys.posix.unistd : geteuid;
import moss.core : ExitStatus;
import moss.core.sizing : formattedSize;
import std.format : format;
import std.experimental.logger;

/**
 * The DeleteCacheCommand is responsible deleting the various caches used by boulder
 */
@CommandName("delete-cache") @CommandAlias("dc")
@CommandHelp("Delete assets & caches stored by boulder")
public struct DeleteCacheCommand
{
    /** Extend BaseCommand with DeleteCacheCommand specific functionality */
    BaseCommand pt;
    alias pt this;

    /**
     * Boulder assets and caches deletion
     * Params:
     *      argv = arguments passed to the cli
     * Returns: ExitStatus.Success on success, ExitStatus.Failure on failure
     */
    @CommandEntry() int run(ref string[] argv)
    {
        immutable useDebug = this.findAncestor!BoulderCLI.debugMode;
        globalLogLevel = useDebug ? LogLevel.trace : LogLevel.info;

        if (argv.length > 0)
        {
            warning(
                    "Unexcepted number of arguments specified. For help, run boulder delete-cache -h");
            return ExitStatus.Failure;
        }

        /* Ensure root permissions */
        if (geteuid() != 0 && sizes == false)
        {
            error("boulder must be run with root privileges.");
            return ExitStatus.Failure;
        }

        /* Print out disk usage and return if sizes is requested */
        if (sizes == true)
        {
            string[] cachePaths = [
                SharedRootArtefactsCache, SharedRootBuildCache,
                SharedRootCcacheCache, SharedRootPkgCacheCache,
                SharedRootRootCache, SharedRootUpstreamsCache,
            ];
            double totalSize = 0;
            foreach (string path; cachePaths)
            {
                auto size = getSizeDir(path);
                totalSize += size;
                info(format!"Size of %s is %s"(path, formattedSize(size)));
            }
            info(format!"Total size: %s"(formattedSize(totalSize)));
            return ExitStatus.Success;
        }

        /* Figure out what paths we're nuking */
        string[] nukeCachePaths = [SharedRootRootCache];
        if (deleteAll == true)
        {
            delArtefacts = true;
            delBuild = true;
            delCcache = true;
            delPkgCache = true;
            delUpstreams = true;
        }
        if (delArtefacts == true)
            nukeCachePaths ~= SharedRootArtefactsCache;
        if (delBuild == true)
            nukeCachePaths ~= SharedRootBuildCache;
        if (delCcache == true)
            nukeCachePaths ~= SharedRootCcacheCache;
        if (delPkgCache == true)
            nukeCachePaths ~= SharedRootPkgCacheCache;
        if (delUpstreams == true)
            nukeCachePaths ~= SharedRootUpstreamsCache;

        /* Nuke the paths */
        double totalSize = 0;
        auto exitStatus = ExitStatus.Success;
        foreach (string path; nukeCachePaths)
        {
            auto size = getSizeDir(path);
            exitStatus = deleteDir(path);
            if (exitStatus == ExitStatus.Failure)
            {
                warning(format!"Failed to delete all files in %s"(path));
            }
            info(format!"Removed: %s, %s"(path, formattedSize(size)));
            totalSize += size;
        }
        info(format!"Total restored size: %s"(formattedSize(totalSize)));

        return exitStatus;
    }

    /** Delete all assets & caches */
    @Option("a", "all", "Delete all assets and caches used by boulder")
    bool deleteAll = false;
    /** Delete artefacts */
    @Option("A", "artefacts", "Delete artefacts cache")
    bool delArtefacts = false;
    /** Delete build */
    @Option("b", "build", "Delete build cache")
    bool delBuild = false;
    /** Delete ccache */
    @Option("c", "ccache", "Delete ccache cache")
    bool delCcache = false;
    /** Delete pkgCache */
    @Option("P", "pkgCache", "Delete pkgCache cache")
    bool delPkgCache = false;
    /** Delete upstreams */
    @Option("u", "upstreams", "Delete upstreams cache")
    bool delUpstreams = false;
    /** Get total disk usage of boulder assets and caches */
    @Option("s", "sizes", "Display disk usage used by boulder assets and caches.")
    bool sizes = false;
}

/**
 * Deletes all files in a directory
 * Params:
 *      path = directory to remove
 * Returns: ExitStatus.Success on success, ExitStatus.Failure on failure
 */
auto deleteDir(in string path) @trusted
{
    import std.file : dirEntries, exists, FileException, remove, SpanMode;

    /* Whether we failed to remove some files in the dir */
    bool failed;

    try
    {
        foreach (string name; dirEntries(path, SpanMode.depth))
        {
            trace(format!"Removing: %s"(name));
            remove(name);
        }
    }
    catch (FileException e)
    {
        warning(format!"Caught a FileException when deleting directory %s, reason: %s"(path, e));
        failed = true;
    }
    if (failed == true)
    {
        return ExitStatus.Failure;
    }
    return ExitStatus.Success;
}

/**
 * Get the disk usage of a directory
 * Params:
 *      path = directory to get size of
 * Returns: totalSize
 */
auto getSizeDir(in string path) @trusted
{
    import std.array : array;
    import std.file : dirEntries, FileException, getSize, isFile, SpanMode;
    import std.parallelism : parallel;

    double totalSize = 0;

    try
    {
        foreach (name; parallel(dirEntries(path, SpanMode.breadth, false).array))
        {
            if (name.isFile)
            {
                totalSize += getSize(name);
            }
        }
    }
    /* Don't crash and burn if we fail to stat a file */
    catch (FileException e)
    {
        trace(format!"Caught a FileException within %s, reason: %s"(path, e));
    }

    return totalSize;
}
