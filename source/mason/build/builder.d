/*
 * SPDX-FileCopyrightText: Copyright © 2020-2023 Serpent OS Developers
 *
 * SPDX-License-Identifier: Zlib
 */

/**
 * mason.build.builder
 *
 * Defines the notion of a Builder, which is responsible for converting a
 * package recipe to a binary moss .stone package.
 *
 * Authors: Copyright © 2020-2023 Serpent OS Developers
 * License: Zlib
 */

module mason.build.builder;

import core.sys.posix.sys.stat;
import mason.build.analysers;
import mason.build.collector;
import mason.build.context;
import mason.build.emitter;
import mason.build.profile;
import mason.build.util;
import moss.deps.analysis;
import moss.deps.analysis.elves;
import moss.format.source.spec;
import std.algorithm : each, filter, sort, uniq;
import std.experimental.logger;
import std.path : baseName, dirName;
import std.parallelism : parallel;
import std.range : chain;
import std.string : endsWith, format, startsWith;

/**
 * As far as boulder is concerned, any directory mode 0755 is utterly uninteresting
 * and doesn't need to be recorded in the final payload, as we can simply recreate
 * it.
 */
private static immutable auto regularDirectoryMode = S_IFDIR | S_IROTH | S_IXOTH
    | S_IRGRP | S_IXGRP | S_IRWXU;

/**
 * The Builder is responsible for the full build of a source package
 * and emitting a binary package.
 */
final class Builder
{

public:

    /**
     * Construct a new Builder with the given input file. It must be
     * a stone.yml formatted file and actually be valid.
     */
    this(string nativeArchitecture)
    {
        //trace(__FUNCTION__);
        if (buildContext.rootDir is null)
        {
            buildContext.rootDir = getBuildRoot();
        }
        else
        {
            boulderRoot = true;
        }

        /* Collection + analysis */
        collector = new BuildCollector();
        analyser = new Analyser();
        analyser.userdata = this;
        setupChains();

        if (nativeArchitecture == "native")
        {
            import moss.core.platform : platform;

            nativeArchitecture = platform().name;
        }

        /* Handle emission */
        emitter = new BuildEmitter(nativeArchitecture);

        /* TODO: Ban emul32 on non-64bit hosts */
        immutable emul32name = format!"emul32/%s"(nativeArchitecture);
        if (buildContext.spec.supportedArchitecture(emul32name)
                || buildContext.spec.supportedArchitecture("emul32"))
        {
            addArchitecture(emul32name);
        }

        /* Add builds if this is a supported platform */
        if (buildContext.spec.supportedArchitecture(nativeArchitecture)
                || buildContext.spec.supportedArchitecture("native")
                || nativeArchitecture != "native")
        {
            addArchitecture(nativeArchitecture);
        }
        preparePackageDefinitions();
    }

    /**
     * Add an architecture to the build list
     */
    void addArchitecture(string name)
    {
        architectures ~= name;
        profiles ~= new BuildProfile(name);
    }

    /**
     * Prepare our root filesystem for building on
     */
    void prepareRoot() @system
    {
        import std.file : rmdirRecurse, mkdirRecurse, exists;
        import std.process : environment;

        trace(format!"Preparing root tree (as user: %s)"(environment.get("USER")));

        if (buildContext.rootDir.exists && !boulderRoot)
        {
            trace("Removing existing (!boulderRoot) root tree");
            buildContext.rootDir.rmdirRecurse;
        }

        if (!buildContext.rootDir.exists)
        {
            trace("No existing root tree; creating fresh root tree");
            buildContext.rootDir.mkdirRecurse;
        }
    }

    /**
     * Copy all package files to pkgDir
     */
    void preparePkgFiles() @system
    {
        import std.array : array, join;
        import std.file : copy, dirEntries, exists, isDir, mkdirRecurse, SpanMode;
        import std.path : asRelativePath;
        import std.process : environment;

        ///FIXME: Ensure that moss-container exposes a USER env var
        /* Create directory for the package files*/
        trace(format!"Preparing buildContext.pkgDir: %s (as user: %s)"(buildContext.pkgDir,
                environment.get("USER")));
        buildContext.pkgDir.mkdirRecurse;

        /* Copy the recipe pkg/ directory into the buildroot */
        auto location = join([buildContext.specDir, "pkg"], "/");
        if (location.exists && location.isDir)
        {
            foreach (file; dirEntries(location, SpanMode.breadth, false))
            {
                auto relName = asRelativePath(file.name, location).array;
                auto destName = join([buildContext.pkgDir, relName], "/");
                if (file.isDir())
                {
                    destName.mkdirRecurse();
                }
                else
                {
                    copy(file.name, destName);
                }
            }
        }
    }

    /**
     * Ensure all profile builds will compile ahead of time
     */
    void validateProfiles() @system
    {
        import std.algorithm.iteration : each;

        profiles.each!((ref p) => p.validate());
    }

    /**
     * Build all of the given profiles
     */
    bool buildProfiles() @system
    {
        foreach (p; profiles)
        {
            if (!p.build())
            {
                return false;
            }
        }
        return true;
    }

    /**
     * Collect and analyse all assets using the
     * given collector
     */
    void collectAssets() @system
    {
        import std.algorithm : map, uniq, each, sort;
        import std.array : array;

        auto roots = profiles.map!((ref p) => p.installRoot).array();
        roots.sort();
        roots.uniq.each!((const s) => this.collectRootfs(s));
        analyser.process();
        collectElves();
    }

    /**
     * Explicitly requested addition of some path, so add it now.
     */
    void collectPath(in string path, in string root)
    {
        import std.path : relativePath;
        import std.string : format;

        debug
        {
            //trace(format!"collectPath: %s"(path));
        }
        auto targetPath = path.relativePath(root);
        if (targetPath[0] != '/')
        {
            targetPath = format!"/%s"(targetPath);
        }
        /// FIXME: care about type information
        auto inf = FileInfo(targetPath, path);
        inf.target = collector.packageTarget(targetPath);
        analyser.addFile(inf);
    }

    /**
     * Emit all binary packages
     */
    void emitPackages() @system
    {
        emitter.emit(buildContext.outputDirectory, this.analyser);
    }

    /**
     * Returns: Installation root (identical across profiles)
     */
    pure auto @property installRoot() @safe @nogc nothrow
    {
        return profiles[0].installRoot;
    }

    /**
     * ELF files with a buildid need post-processing for dbginfo +
     * stripping. To do so we must factor in uniqueness, hence
     * running in a separate loop.
     *
     * Params:
     *      fileInfo = Post-processing fileInfo
     */
    void pushDeferredElf(ref FileInfo fileInfo) @safe
    {
        synchronized (this)
        {
            deferred ~= fileInfo;
        }
    }

private:

    /**
     * Post-process all of our ELF files
     */
    void collectElves() @system
    {
        deferred.sort!((a, b) => a.buildID < b.buildID);

        auto nonLinkedFiles = deferred.filter!((d) => d.stat.st_nlink < 2);
        auto linkedFiles = deferred.filter!((d) => d.stat.st_nlink >= 2)
            .uniq!"a.buildID == b.buildID";

        /* Uniquely generate dbginfo symbols  */
        foreach (fileInfo; deferred.uniq!"a.buildID == b.buildID".parallel)
        {
            copyElfDebug(analyser, fileInfo);
        }

        /* Now go strip em all in parallel */
        foreach (fileInfo; chain(nonLinkedFiles, linkedFiles).parallel)
        {
            stripElfFiles(this, fileInfo);
        }

        /* For all of them, re-stat + include */
        foreach (ref fileInfo; deferred.parallel)
        {
            fileInfo.update();
            analyser.forceAddFile(fileInfo);
        }

        /* Last run, may have some latent *new* files (dbginfo, etc) */
        analyser.process();
    }

    /**
     * Setup our boulder chains */
    void setupChains()
    {
        //trace(__FUNCTION__);
        const auto boulderChains = [
            /* Highest policy */
            AnalysisChain("badFiles", [&dropBadPaths], 100),

            /* Handle binary providers */
            AnalysisChain("binary", [&handleBinaryFiles], 100),

            /* Handle ELF files */
            AnalysisChain("elves", [
                &acceptElfFiles, &scanElfFiles, &deferElfInclusion,
            ], 90),

            /* Handle pkgconfig files */
            AnalysisChain("pkgconfig", [
                &acceptPkgconfigFiles, &handlePkgconfigFiles, &includeFile
            ], 50),

            /* Handle cmake files */
            AnalysisChain("cmake", [
                &acceptCmakeFiles, &handleCmakeFiles, &includeFile
            ], 50),

            /* Compress man and info pages if enabled */
            AnalysisChain("compressman", [&acceptManInfoPages, &compressPage], 40),

            /* Default inclusion policy */
            AnalysisChain("default", [&includeFile], 0),
        ];

        boulderChains.each!((const c) {
            auto chain = cast(AnalysisChain) c;
            analyser.addChain(chain);
        });
    }

    /**
     * Begin collection on the given rootfs tree, from the collectAssets
     * call.
     */
    void collectRootfs(const(string) root)
    {
        import std.file : dirEntries, DirEntry, SpanMode;

        //trace(__FUNCTION__);

        /**
         * Custom recursive dirEntries (DFS) style function which lets us
         * detect empty directories and directories with special permissions
         * so that for the most part we won't explicitly include directory
         * records in the payload.
         */
        void collectionHelper(in string path, bool specialDirectory = false)
        {
            auto entries = dirEntries(path, SpanMode.shallow, false);

            if (entries.empty)
            {
                /* Include empty directory */
                collectPath(path, root);
                return;
            }
            else if (specialDirectory)
            {
                /* Include directory with non standard mode */
                collectPath(path, root);
            }
            /* Otherwise, ignore the directory and rely on mkdir recursive */

            /* Depth first, close fd early to prevent exhaustion */
            foreach (entry; entries)
            {
                auto specialDir = entry.isDir() && entry.statBuf.st_mode != regularDirectoryMode;
                if (entry.isDir)
                {
                    collectionHelper(entry.name, specialDir);
                }
                else
                {
                    collectPath(entry.name, root);
                }
                entry.destroy();
            }
        }

        collectionHelper(root);
    }

    /**
     * Load all package definitions in
     */
    void preparePackageDefinitions() @system
    {
        import std.algorithm : map, each, joiner;
        import std.array : array;

        //trace(__FUNCTION__);
        string[] arches = ["base"];
        arches ~= architectures;

        /* Insert core package definitions */
        arches.map!((a) => buildContext.defFiles[a].packages)
            .joiner
            .each!((p) => addDefinition(p));

        /* Insert custom package definitions */
        inclusionPriority += 1000;
        addDefinition(buildContext.spec.rootPackage);
        buildContext.spec.subPackages.values.each!((p) => addDefinition(p));

        /* Fully baked definitions, pass to the emitter */
        packages.values.each!((p) => emitter.addPackage(buildContext.spec.source, p));
    }

    /**
     * Insert a definition to allow matching file paths to a proper
     * PackageDefinition merged object. This comes from the spec and
     * our base definitions.
     */
    void addDefinition(PackageDefinition pkd)
    {
        import std.algorithm : each, uniq, sort;
        import std.range : chain;
        import std.array : array;

        debug
        {
            trace(format!"Add (sub)package definition: [%s]"(pkd.name));
        }
        /* Always insert paths as they're encountered */
        pkd = buildContext.spec.expand(pkd);

        void insertRule(const(PathDefinition) pd)
        {
            collector.addRule(pd, pkd.name, inclusionPriority);
            ++inclusionPriority;
        }

        pkd.paths.each!((pd) => insertRule(pd));

        /* Insert new package if needed */
        if (!(pkd.name in packages))
        {
            packages[pkd.name] = pkd;
            return;
        }

        /* Merge rules */
        auto oldPkg = &packages[pkd.name];
        oldPkg.runtimeDependencies = oldPkg.runtimeDependencies.chain(pkd.runtimeDependencies)
            .uniq.array;
        oldPkg.paths = oldPkg.paths.chain(pkd.paths).uniq.array;
        oldPkg.conflicts = oldPkg.conflicts.chain(pkd.conflicts).uniq.array;

        sort(oldPkg.runtimeDependencies);
        sort(oldPkg.paths);
        sort(oldPkg.conflicts);

        /* Merge details */
        if (oldPkg.summary is null)
        {
            oldPkg.summary = pkd.summary;
        }
        if (oldPkg.description is null)
        {
            oldPkg.description = pkd.description;
        }
    }

    /**
     * Safely get the home root tree
     */
    string getBuildRoot() @safe
    {
        import std.path : expandTilde;
        import std.file : exists;
        import std.exception : enforce;
        import std.string : format;
        import std.array : join;

        auto hdir = expandTilde("~");
        enforce(hdir.exists, "Home directory not found!");

        return join([
            hdir,
            ".moss/buildRoot/%s-%s".format(buildContext.spec.source.name,
                    buildContext.spec.source.release)
        ], "/");
    }

    string[] architectures;
    BuildProfile*[] profiles;
    Analyser analyser;
    BuildCollector collector;
    BuildEmitter emitter;
    PackageDefinition[string] packages;
    int inclusionPriority = 0;
    bool boulderRoot = false;
    FileInfo[] deferred;
}
