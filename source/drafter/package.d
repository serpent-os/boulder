/*
 * SPDX-FileCopyrightText: Copyright © 2020-2023 Serpent OS Developers
 *
 * SPDX-License-Identifier: Zlib
 */

/**
 * drafter
 *
 * Automatic generation of boulder recipes from upstream URIs
 *
 * Drafter is the core implementation behind the `boulder new`
 * subcommand, and allows users to generate a new `stone.yml` file
 * from given upstream URIs.
 *
 * It integrates metadata and build system detetion in an attempt
 * to provide a complete stone.yml file. It may not always be
 * 100% accurate, but it is designed to detect as many build deps
 * and licenses as possible to save the maintainer from doing all
 * of the legwork, increasing our compliance.
 *
 * Authors: Copyright © 2020-2023 Serpent OS Developers
 * License: Zlib
 */

module drafter;

import drafter.build;
import drafter.license;
import drafter.metadata;
import moss.core : ExitStatus;
import moss.core.ioutil;
import moss.core.logger;
import moss.core.util : computeSHA256;
import moss.deps.analysis;
import moss.fetcher;
import std.algorithm : each;
import std.container.rbtree : RedBlackTree;
import std.exception : enforce;
import std.file : exists, remove, thisExePath;
import std.format : format;
import std.path : baseName, dirName, buildNormalizedPath, absolutePath;
import std.process;
import std.range : empty;
import std.sumtype;
import std.stdio : File;

public import moss.format.source.upstream_definition;

/**
 * Map our downloads into something *usable* so we can remember
 * things about it.
 */
private struct RemoteAsset
{
    string sourceURI;
    string localPath;
}

/**
 * We really don't care about the vast majority of files.
 */
static private AnalysisReturn silentDrop(scope Analyser an, ref FileInfo info)
{
    return AnalysisReturn.IgnoreFile;
}

/**
 * Main class for analysis of incoming sources to generate an output recipe
 */
public final class Drafter
{
    /**
     * Construct a new Drafter
     */
    this(in string outputPath)
    {
        controller = new FetchController();
        analyser = new Analyser();
        analyser.userdata = this;
        analyser.addChain(AnalysisChain("drop", [&silentDrop], 0));
        analyser.addChain(autotoolsChain);
        analyser.addChain(mesonChain);
        analyser.addChain(cmakeChain);
        analyser.addChain(pythonChain);
        analyser.addChain(cargoChain);
        analyser.addChain(licenseChain);
        controller.onFail.connect(&onFail);
        controller.onComplete.connect(&onComplete);
        _licenseEngine = new Engine();

        auto licenseDir = thisExePath.dirName.buildNormalizedPath("..",
            "share", "boulder", "licenses").absolutePath;
        _licenseEngine.loadFromDirectory(licenseDir);
        _licenses = new RedBlackTree!(string, "a < b", false);
        outputFile = File(outputPath, "w");
        /* only used in destructor on error */
        outputPathDeleteMe_ = outputPath;
    }

    ~this()
    {
        outputFile.close();
        if (run_ == ExitStatus.Failure && outputPathDeleteMe_.exists)
        {
            outputPathDeleteMe_.remove();
        }
    }

    /**
     * Dull handler for failure
     */
    void onFail(Fetchable f, string msg) @trusted
    {
        error(format!"Failed to download %s: %s"(f.sourceURI, msg));
        fetchedDownloads = false;
    }

    /**
     * Handle completion of downloads, validate them
     */
    void onComplete(Fetchable f, long code) @trusted
    {
        import std.algorithm : startsWith;

        trace(format!"Download of %s finished [code: %d]"(f.sourceURI.baseName, code));

        /* The file:// use case is for when wanting to re-use already downloaded artefacts */
        if (code == 200 || (f.sourceURI.startsWith("file://") && code == 0))
        {
            processPaths ~= RemoteAsset(f.sourceURI, f.destinationPath);
            info(format!"Downloaded: %s"(f.destinationPath));
            return;
        }
        onFail(f, format!"Unhandled outcome: Server returned status code: %d"(code));
    }

    /**
     * Run Drafter lifecycle to completion
     */
    ExitStatus run()
    {
        info("Beginning download");

        scope (exit)
        {
            import std.file : remove, rmdirRecurse;
            import std.algorithm : each;

            processPaths.each!((p) {
                trace(format!"Removing: %s"(p.localPath));
                p.localPath.remove();
            });
            directories.each!((d) {
                trace(format!"Removing: %s"(d));
                d.rmdirRecurse();
            });
        }

        while (!controller.empty)
        {
            controller.fetch();
        }

        if (!fetchedDownloads)
        {
            error("Exiting due to abnormal downloads");
            run_ = ExitStatus.Failure;
            return run_;
        }

        if (processPaths.empty)
        {
            error("Nothing for us to process, exiting");
            run_ = ExitStatus.Failure;
            return run_;
        }

        exploreAssets();
        info("Analysing source trees");
        analyser.process();

        outputFile.writeln(meta.emit());
        outputFile.writeln("license     :");
        _licenses.each!((l) => outputFile.writefln!"    - %s"(l));
        emitBuildDependencies();
        emitBuild();
        return ExitStatus.Success;
    }

    /**
     * Increment build confidence in a given system
     */
    void incrementBuildConfidence(BuildType t, ulong incAmount)
    {
        ulong* ptrAmount = t in confidence;
        if (ptrAmount !is null)
        {
            *ptrAmount += incAmount;
            return;
        }
        confidence[t] = incAmount;
    }

    /**
     * Add some kind of input URI into drafter for ... analysing
     */
    void addSource(string uri, UpstreamType type = UpstreamType.Plain)
    {
        enforce(type == UpstreamType.Plain, "Drafter only supports plain sources");
        auto f = Fetchable(uri, "/tmp/boulderDrafterURI-XXXXXX", 0, FetchType.TemporaryFile, null);
        controller.enqueue(f);
    }

    void insertLicense(in string license)
    {
        synchronized (_licenses)
        {
            _licenses.insert([license]);
        }
    }

    /**
     * Allow Metadata to be accessed and updated
     */
    pure @property ref inout(Metadata) metadata() inout @safe @nogc nothrow
    {
        return meta;
    }

    /**
     * Expose build options
     */
    pure @property ref inout(BuildOptions) options() inout @safe @nogc nothrow
    {
        return _options;
    }

    /**
     * Expose the license engine
     */
    pure @property Engine licenseEngine() @safe @nogc nothrow
    {
        return _licenseEngine;
    }

private:

    void emitBuildDependencies()
    {
        import std.container.rbtree : redBlackTree;
        import std.algorithm : joiner, map, each;
        import std.stdio : writefln, writeln;
        import std.array : array;

        /* Merge all dependencies from all buckets, convert to string, sort insert */
        auto set = redBlackTree!("a < b", false, string)(analyser.buckets
                .map!((b) => b.dependencies)
                .joiner
                .map!((d) => d.toString)
                .array);

        /* No build deps. */
        if (set.empty)
        {
            return;
        }

        /* Emit the build dependencies now */
        outputFile.writeln("builddeps   :");
        set[].each!((d) => outputFile.writefln!"    - %s"(d));
    }

    void exploreAssets()
    {
        import std.file : dirEntries, SpanMode;
        import std.path : relativePath;

        foreach (const p; processPaths)
        {
            info(format!"Extracting: %s"(p.localPath));
            auto location = IOUtil.createTemporaryDirectory("/tmp/boulderDrafterExtraction.XXXXXX");
            auto directory = location.match!((string s) => s, (err) {
                error(format!"Error creating tmpdir: %s"(err.toString));
                return null;
            });
            if (directory is null)
            {
                return;
            }
            directories ~= directory;

            /* Capture an upstream definition */
            info(format!"Computing hash for %s"(p.localPath));
            auto hash = computeSHA256(p.localPath, true);
            auto ud = UpstreamDefinition(UpstreamType.Plain);
            ud.plain = PlainUpstreamDefinition(hash);
            ud.uri = p.sourceURI;
            meta.upstreams ~= ud;
            meta.updateSource(ud.uri);
            meta.source.release = 1;

            /* Attempt extraction. For now, we assume everything is a tarball */
            auto cmd = ["tar", "xf", p.localPath, "-C", directory,];

            /* Perform the extraction now */
            auto result = execute(cmd, null, Config.none, size_t.max, directory);
            if (result.status != 0)
            {
                error(format!"Extraction of %s failed with code %s"(p.localPath, result.status));
                trace(result.output);
            }

            info(format!"Scanning sources under %s"(directory));
            foreach (string path; dirEntries(directory, SpanMode.depth, false))
            {
                auto fi = FileInfo(path.relativePath(directory), path);
                fi.target = p.sourceURI.baseName;
                analyser.addFile(fi);
            }
        }
    }

    /**
     * Emit the discovered build pattern
     */
    void emitBuild()
    {
        /* Pick the highest pattern */
        import std.algorithm : sort;
        import std.stdio : writefln;

        auto keyset = confidence.keys;
        if (keyset.empty)
        {
            error("Unhandled build system");
            return;
        }

        /* Sort by confidence level */
        keyset.sort!((a, b) => confidence[a] > confidence[b]);
        auto highest = keyset[0];

        auto build = buildTypeToHelper(highest);

        void emitSection(string displayName, string delegate() helper)
        {
            auto res = helper();
            if (res is null)
            {
                return;
            }
            outputFile.writefln!"%s |\n    %s"(displayName, res);
        }

        emitSection("setup       :", &build.setup);
        emitSection("build       :", &build.build);
        emitSection("install     :", &build.install);
        emitSection("check       :", &build.check);
    }

    FetchController controller;
    Analyser analyser;
    Engine _licenseEngine;
    RemoteAsset[] processPaths;
    string[] directories;
    bool fetchedDownloads = true;
    Metadata meta;
    private ulong[BuildType] confidence;
    BuildOptions _options;
    RedBlackTree!(string, "a < b", false) _licenses;
    File outputFile;
    ExitStatus run_ = ExitStatus.Success;
    string outputPathDeleteMe_;
}
