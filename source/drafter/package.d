/* SPDX-License-Identifier: Zlib */

/**
 * Drafter - Recipe Manipulation
 *
 * Generation and manipulation of source recipe files that can then be consumed
 * by boulder.
 *
 * Authors: © 2020-2022 Serpent OS Developers
 * License: ZLib
 */

module drafter;

import std.sumtype;
import moss.core.ioutil;
import moss.core.util : computeSHA256;
import moss.fetcher;
import moss.deps.analysis;
import std.exception : enforce;
import std.path : baseName;
import std.range : empty;
import moss.core.logging;
import std.process;
import drafter.build;
import drafter.metadata;

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
 * Is this autotools?
 */
static private AnalysisReturn acceptAutotools(scope Analyser an, ref FileInfo inpath)
{
    Drafter c = an.userdata!Drafter;
    auto bn = inpath.path.baseName;
    import std.string : count;

    /**
     * Depth too great
     */
    if (inpath.path.count("/") > 1)
    {
        return AnalysisReturn.NextHandler;
    }

    switch (bn)
    {
    case "configure.ac":
    case "configure":
    case "Makefile.am":
    case "Makefile":
        c.incrementBuildConfidence(BuildType.Autotools, 10);
        return AnalysisReturn.IncludeFile;
    default:
        return AnalysisReturn.NextHandler;
    }
}

/**
 * Discover meson projects
 */
static private AnalysisReturn acceptMeson(scope Analyser an, ref FileInfo inpath)
{
    Drafter c = an.userdata!Drafter;
    auto bn = inpath.path.baseName;
    import std.string : count;

    /**
     * Depth too great
     */
    if (inpath.path.count("/") > 1)
    {
        return AnalysisReturn.NextHandler;
    }

    if (bn == "meson.build" || bn == "meson_options.txt")
    {
        c.incrementBuildConfidence(BuildType.Meson, 100);
        return AnalysisReturn.IncludeFile;
    }

    return AnalysisReturn.NextHandler;
}

/**
 * Main class for analysis of incoming sources to generate an output recipe
 */
public final class Drafter
{
    /**
     * Construct a new Drafter
     */
    this()
    {
        controller = new FetchController();
        analyser = new Analyser();
        analyser.userdata = this;
        analyser.addChain(AnalysisChain("drop", [&silentDrop], 0));
        analyser.addChain(AnalysisChain("autotools", [&acceptAutotools], 10));
        analyser.addChain(AnalysisChain("meson", [&acceptMeson], 20));
        controller.onFail.connect(&onFail);
        controller.onComplete.connect(&onComplete);
    }

    /**
     * Dull handler for failure
     */
    void onFail(in Fetchable f, in string msg)
    {
        errorf("Failed to download %s: %s", f.sourceURI, msg);
        fetchedDownloads = false;
    }

    /**
     * Handle completion of downloads, validate them
     */
    void onComplete(in Fetchable f, long code)
    {
        tracef("Download of %s finished [code: %s]", f.sourceURI.baseName, code);

        if (code == 200)
        {
            processPaths ~= RemoteAsset(f.sourceURI, f.destinationPath);
            infof("Downloaded: %s", f.destinationPath);
            return;
        }
        onFail(f, "Server returned non-200 status code");
    }

    /**
     * Run Drafter lifecycle to completion
     */
    void run()
    {
        info("Beginning download");

        scope (exit)
        {
            import std.file : remove, rmdirRecurse;
            import std.algorithm : each;

            processPaths.each!((p) {
                tracef("Removing: %s", p.localPath);
                p.localPath.remove();
            });
            directories.each!((d) { tracef("Removing: %s", d); d.rmdirRecurse(); });
        }

        while (!controller.empty)
        {
            controller.fetch();
        }

        if (!fetchedDownloads)
        {
            error("Exiting due to abnormal downloads");
            return;
        }

        if (processPaths.empty)
        {
            error("Nothing for us to process, exiting");
            return;
        }

        exploreAssets();
        info("Analysing source trees");
        analyser.process();

        /* Debug */
        trace(meta);
        import std.stdio : writeln;

        writeln("recipe: \n");
        writeln(meta.emit());

        emitBuild();
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

private:

    void exploreAssets()
    {
        import std.file : dirEntries, SpanMode;
        import std.path : relativePath;

        foreach (const p; processPaths)
        {
            infof("Extracting: %s", p.localPath);
            auto location = IOUtil.createTemporaryDirectory("/tmp/boulderDrafterExtraction.XXXXXX");
            auto directory = location.match!((string s) => s, (err) {
                errorf("Error creating tmpdir: %s", err.toString);
                return null;
            });
            if (directory is null)
            {
                return;
            }
            directories ~= directory;

            /* Capture an upstream definition */
            infof("Computing hash for %s", p.localPath);
            auto hash = computeSHA256(p.localPath, true);
            auto ud = UpstreamDefinition(UpstreamType.Plain);
            ud.plain = PlainUpstreamDefinition(hash);
            ud.uri = p.sourceURI;
            meta.upstreams ~= ud;
            meta.updateSource(ud.uri);

            /* Attempt extraction. For now, we assume everything is a tarball */
            auto cmd = ["tar", "xf", p.localPath, "-C", directory,];

            /* Perform the extraction now */
            auto result = execute(cmd, null, Config.none, size_t.max, directory);
            if (result.status != 0)
            {
                errorf("Extraction of %s failed with code %s", p.localPath, result.status);
                trace(result.output);
            }

            infof("Scanning sources under %s", directory);
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
            writefln("%s|\n    %s", displayName, res);
        }

        emitSection("setup       :", &build.setup);
        emitSection("build       :", &build.build);
        emitSection("install     :", &build.install);
        emitSection("check       :", &build.check);
    }

    FetchController controller;
    Analyser analyser;
    RemoteAsset[] processPaths;
    string[] directories;
    bool fetchedDownloads = true;
    Metadata meta;
    private ulong[BuildType] confidence;
}