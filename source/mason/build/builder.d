/*
 * SPDX-FileCopyrightText: Copyright © 2020-2022 Serpent OS Developers
 *
 * SPDX-License-Identifier: Zlib
 */

/**
 * mason.build.builder
 *
 * Defines the notion of a Builder, which is responsible for converting a
 * package recipe to a binary moss .stone package.
 *
 * Authors: Copyright © 2020-2022 Serpent OS Developers
 * License: Zlib
 */

module mason.build.builder;

import core.sys.posix.sys.stat;
import mason.build.collector;
import mason.build.context;
import mason.build.emitter;
import mason.build.profile;
import mason.build.util;
import moss.deps.analysis.elves;
import moss.deps.analysis;
import moss.format.source.spec;
import std.algorithm : each, filter, canFind;
import std.experimental.logger;
import std.path : dirName, baseName;
import std.string : startsWith, endsWith, format;

/**
 * As far as boulder is concerned, any directory mode 0755 is utterly uninteresting
 * and doesn't need to be recorded in the final payload, as we can simply recreate
 * it.
 */
private static immutable auto regularDirectoryMode = S_IFDIR | S_IROTH | S_IXOTH
    | S_IRGRP | S_IXGRP | S_IRWXU;

/*
 * Do not allow non /usr paths!
 */
private static AnalysisReturn dropBadPaths(scope Analyser analyser, ref FileInfo info)
{
    if (!info.path.startsWith("/usr/"))
    {
        if (!info.path.startsWith("/usr"))
        {
            warning(format!"Not including non /usr/ file: %s"(info.path));
        }
        return AnalysisReturn.IgnoreFile;
    }

    return AnalysisReturn.NextHandler;
}

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
    }

    /**
     * Emit all binary packages
     */
    void emitPackages() @system
    {
        emitter.emit(buildContext.outputDirectory, this.analyser);
    }

private:

    /**
     * Setup our boulder chains */
    void setupChains()
    {
        //trace(__FUNCTION__);
        const auto boulderChains = [
            /* Highest policy */
            AnalysisChain("badFiles", [&dropBadPaths], 100),

            /* Handle binary providers */
            AnalysisChain("binary", [&acceptBinaryFiles, &handleBinaryFiles],
                    100),

            /* Reject libtool (.la) files */
            AnalysisChain("libtoolFiles", [&rejectLibToolFiles], 90),

            /* Automatically compress any man pages with zstd */
            AnalysisChain("compressManPages", [&compressManPages], 90),

            /* Handle ELF files */
            /* FIXME: Parallel debuginfo handling truncates hardlinked files! */
            AnalysisChain("elves", [
                &acceptElfFiles, &scanElfFiles, /* &copyElfDebug
                    &stripElfFiles, */
                &includeElfFiles,
            ], 90),

            /* Handle pkgconfig files */
            AnalysisChain("pkgconfig", [
                &acceptPkgconfigFiles, &handlePkgconfigFiles, &includeFile
            ], 50),

            /* Handle cmake files */
            AnalysisChain("cmake", [
                &acceptCmakeFiles, &handleCmakeFiles, &includeFile
            ], 50),

            /* Default inclusion policy */
            AnalysisChain("default", [&includeFile], 0),
        ];

        boulderChains.each!((const c) => {
            auto chain = cast(AnalysisChain) c;
            analyser.addChain(chain);
        }());
    }

    /**
     * libtool archive files (.la) were used to supply information to older linkers,
     * but aren't needed today (and are actively avoided) because the ELF object
     * format already supplies the necessary information to the linker. Actively keeping
     * them can also break builds for other packages.
     */
    static AnalysisReturn rejectLibToolFiles(scope Analyser analyser, ref FileInfo fileInfo)
    {
        import std.string : format;

        auto filename = fileInfo.path;
        auto directory = filename.dirName;

        /* We have a libtool file, drop it */
        if (filename.endsWith(".la") && directory.canFind("/usr/lib"))
        {
            trace(format!"[Analyse] Rejecting libtool file: %s"(filename));
            return AnalysisReturn.IgnoreFile;
        }
        return AnalysisReturn.NextHandler;
    }

    /**
     * Does this look like a valid pkgconfig file?
     */
    static AnalysisReturn acceptPkgconfigFiles(scope Analyser analyser, ref FileInfo fileInfo)
    {
        auto filename = fileInfo.path;
        auto directory = filename.dirName;

        if (!directory.canFind("/pkgconfig") || !filename.endsWith(".pc"))
        {
            return AnalysisReturn.NextHandler;
        }

        return AnalysisReturn.NextFunction;
    }

    /**
     * Do something with the pkgconfig file, for now we only
     * add providers.
     */
    static AnalysisReturn handlePkgconfigFiles(scope Analyser analyser, ref FileInfo fileInfo)
    {
        auto providerName = fileInfo.path.baseName()[0 .. $ - 3];
        auto prov = Provider(providerName, ProviderType.PkgconfigName);
        analyser.bucket(fileInfo).addProvider(prov);
        return AnalysisReturn.NextHandler;
    }

    /**
     * Does this look like a valid cmake provider?
     */
    static AnalysisReturn acceptCmakeFiles(scope Analyser analyser, ref FileInfo fileInfo)
    {
        auto filename = fileInfo.path;
        auto directory = filename.dirName;

        if (!directory.canFind("/cmake"))
        {
            return AnalysisReturn.NextHandler;
        }

        if ((!filename.endsWith("Config.cmake")
                && !filename.endsWith("-config.cmake")) || filename.endsWith("-Config.cmake"))
        {
            return AnalysisReturn.NextHandler;
        }

        return AnalysisReturn.NextFunction;
    }

    /**
     * Do something with the cmake file, for now we only
     * add providers.
     */
    static AnalysisReturn handleCmakeFiles(scope Analyser analyser, ref FileInfo fileInfo)
    {
        auto extension = fileInfo.fullPath.endsWith("-config.cmake") ? 13 : 12;

        auto providerName = fileInfo.path.baseName()[0 .. $ - extension];
        auto prov = Provider(providerName, ProviderType.CmakeName);
        analyser.bucket(fileInfo).addProvider(prov);
        return AnalysisReturn.NextHandler;
    }

    /**
     * Detect files in /usr/bin
     */
    static AnalysisReturn acceptBinaryFiles(scope Analyser analyser, ref FileInfo fileInfo)
    {
        auto filename = fileInfo.path;

        if (!filename.startsWith("/usr/bin/"))
        {
            return AnalysisReturn.NextHandler;
        }

        return AnalysisReturn.NextFunction;
    }

    /**
     * Add provider for files in /usr/bin that people can run from PATH
     */
    static AnalysisReturn handleBinaryFiles(scope Analyser analyser, ref FileInfo fileInfo)
    {
        auto providerName = fileInfo.path()[9 .. $];
        auto prov = Provider(providerName, ProviderType.BinaryName);
        analyser.bucket(fileInfo).addProvider(prov);
        return AnalysisReturn.NextHandler;
    }

    /**
     * Copy the ELF debug section into debug files
     */
    static AnalysisReturn copyElfDebug(scope Analyser analyser, ref FileInfo fileInfo)
    {
        auto instance = analyser.userdata!Builder;
        import std.exception : enforce;
        import std.string : format;
        import std.path : dirName;
        import std.file : mkdirRecurse;
        import std.array : join;

        /* Nowt left to do */
        if (fileInfo.type != FileType.Regular)
        {
            return AnalysisReturn.IncludeFile;
        }

        if (fileInfo.buildID is null)
        {
            return AnalysisReturn.NextFunction;
        }

        bool useLLVM = buildContext.spec.options.toolchain == "llvm";
        auto command = useLLVM ? "/usr/bin/llvm-objcopy" : "/usr/bin/objcopy";

        auto debugdir = fileInfo.bitSize == 64
            ? "usr/lib/debug/.build-id" : "usr/lib32/debug/.build-id";
        auto debugInfoPathRelative = join([
            debugdir, fileInfo.buildID[0 .. 2], fileInfo.buildID[2 .. $] ~ ".debug"
        ], "/");
        auto debugInfoPath = join([
            instance.profiles[0].installRoot, debugInfoPathRelative
        ], "/");
        trace("debugInfoPath: ", debugInfoPath);
        auto debugInfoDir = debugInfoPath.dirName;
        debugInfoDir.mkdirRecurse();

        /* Execute, TODO: Fix environment */
        auto ret = executeCommand(command, [
            "--only-keep-debug", fileInfo.fullPath, debugInfoPath
        ], null);
        auto code = ret.match!((err) {
            error(format!"debuginfo failure: %s"(err.toString));
            return -1;
        }, (code) => code);

        /* Collect the debug asset */
        if (code != 0)
        {
            return AnalysisReturn.NextFunction;
        }

        /* GNU debuglink. */
        auto commandLink = useLLVM ? "/usr/bin/llvm-objcopy" : "/usr/bin/objcopy";
        auto linkRet = executeCommand(commandLink, [
            "--add-gnu-debuglink", debugInfoPath, fileInfo.fullPath
        ], null);
        code = linkRet.match!((err) {
            error(format!"debuginfo:link failure: %s"(err.toString));
            return -1;
        }, (code) => code);
        if (code != 0)
        {
            warning(format!"debuginfo:link not including broken debuginfo: /%s"(
                    debugInfoPathRelative));
            return AnalysisReturn.NextFunction;
        }

        trace(format!"debuginfo: %s"(fileInfo.path));
        instance.collectPath(debugInfoPath, instance.profiles[0].installRoot);

        return AnalysisReturn.NextFunction;
    }

    static AnalysisReturn compressManPages(scope Analyser analyser, ref FileInfo fileInfo)
    {
        import std.file;
        import std.stdio: toFile;
        import std.string : format;
        import zstd;

        auto filename = fileInfo.path;
        auto instance = analyser.userdata!Builder;

        /* Find a man page file */
        if (filename.canFind("man") && filename.endsWith("1", "2", "3", "4", "5", "6", "7", "8", "9"))
        {
            /* Already compressed */
            if (filename.endsWith(".gz", ".bz2", ".lz", ".zst", ".xz"))
            {
                return AnalysisReturn.NextHandler;
            }

            /* We have a symlink file, update it to point to the compressed file */
            // FIXME: Not tested
            if ((fileInfo.type == FileType.Symlink) && (fileInfo.type != FileType.Directory))
            {
                auto actualpath = std.file.readLink(fileInfo.path);
                std.file.symlink(format!"%s.zst"(actualpath), format!"%s.zst"(fileInfo.path));
                instance.collectPath(format!"%s.zst"(fileInfo.fullPath), instance.profiles[0].installRoot);
                // HACK: return ignorefile to drop the old link
                return AnalysisReturn.IgnoreFile;
            }

            auto manfile = std.file.read(fileInfo.fullPath);

            // Compress it in memory
            auto compressedmanfile = compress(manfile, 19);
            info(format!"[Man] Compressing: %s. Original size: %s Compressed size: %s"(fileInfo.path, manfile.length, compressedmanfile.length));

            // Write the compressed file to disk
            File f = File(format!"%s.zst"(fileInfo.fullPath), "w");
            f.rawWrite(compressedmanfile);

            // Ensure it's collected into the manifest
            instance.collectPath(format!"%s.zst"(fileInfo.fullPath), instance.profiles[0].installRoot);

            // HACK: Remove the original pre-compressed file.
            return AnalysisReturn.IgnoreFile;
        }
        return AnalysisReturn.NextHandler;
    }

    /**
     * Interface back with boulder instance for file stripping. This is specific
     * to ELF files only (i.e. split for debuginfo)
     */
    static AnalysisReturn stripElfFiles(scope Analyser analyser, ref FileInfo fileInfo)
    {
        Builder instance = analyser.userdata!Builder();
        import std.exception : enforce;
        import std.string : format;

        if (!buildContext.spec.options.strip || fileInfo.type != FileType.Regular)
        {
            return AnalysisReturn.NextFunction;
        }

        bool useLLVM = buildContext.spec.options.toolchain == "llvm";
        auto command = useLLVM ? "/usr/bin/llvm-strip" : "/usr/bin/strip";

        /* Execute, TODO: Fix environment */
        auto ret = executeCommand(command, [
            "--strip-unneeded", fileInfo.fullPath
        ], null);
        auto code = ret.match!((err) {
            error(format!"strip failure: %s"(err.toString));
            return -1;
        }, (code) => code);

        if (code == 0)
        {
            trace(format!"strip: %s"(fileInfo.path));
        }

        return AnalysisReturn.NextFunction;
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

        sort(oldPkg.runtimeDependencies);
        sort(oldPkg.paths);

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
}
