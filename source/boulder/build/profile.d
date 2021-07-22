/*
 * This file is part of boulder.
 *
 * Copyright © 2020-2021 Serpent OS Developers
 *
 * This software is provided 'as-is', without any express or implied
 * warranty. In no event will the authors be held liable for any damages
 * arising from the use of this software.
 *
 * Permission is granted to anyone to use this software for any purpose,
 * including commercial applications, and to alter it and redistribute it
 * freely, subject to the following restrictions:
 *
 * 1. The origin of this software must not be misrepresented; you must not
 *    claim that you wrote the original software. If you use this software
 *    in a product, an acknowledgment in the product documentation would be
 *    appreciated but is not required.
 * 2. Altered source versions must be plainly marked as such, and must not be
 *    misrepresented as being the original software.
 * 3. This notice may not be removed or altered from any source distribution.
 */

module boulder.build.profile;

import moss.format.source.spec;
import moss.format.source.script;
import boulder.build.collector;
import boulder.build.context;
import boulder.build.stage;
import boulder.build.manifest;

import std.path : buildPath;

/**
 * A build profile is generated for each major build profile in the
 * source configuration, i.e. x86_64, emul32, etc.
 *
 * It is tied to a specific architecture and will be seeded from
 * the architecture-specific build options.
 */
struct BuildProfile
{

public:

    /**
     * Construct a new BuildProfile using the given (parsed) spec file.
     */
    this(const(string) architecture)
    {
        this._architecture = architecture;
        this._buildRoot = buildContext.rootDir.buildPath("build", architecture);
        this._installRoot = buildContext.rootDir.buildPath("install");

        /* Construct manifests for comparison & emission */
        _sourceManifest = new BuildManifestBinary(architecture);

        _targetManifests = [
            new BuildManifestJSON(architecture),
            new BuildManifestBinary(architecture),
        ];

        /* PGO handling */
        pgoDir = buildRoot ~ "-pgo";

        StageType[] stages;

        /* CSPGO is only available with LLVM toolchain */
        const bool multiStagePGO = (buildContext.spec.options.toolchain == "llvm"
                && buildContext.spec.options.cspgo == true);

        /* PGO specific staging */
        if (hasPGOWorkload)
        {
            /* Always construct a stage1 */
            stages = [
                StageType.Prepare | StageType.ProfileStage1,
                StageType.Setup | StageType.ProfileStage1,
                StageType.Build | StageType.ProfileStage1,
                StageType.Workload | StageType.ProfileStage1,
            ];

            /* Mulitistage uses + refines */
            if (multiStagePGO)
            {
                stages ~= [
                    StageType.Prepare | StageType.ProfileStage2,
                    StageType.Setup | StageType.ProfileStage2,
                    StageType.Build | StageType.ProfileStage2,
                    StageType.Workload | StageType.ProfileStage2,
                ];
            }

            /* Always add the use/final stage */
            stages ~= [
                StageType.Prepare | StageType.ProfileUse,
                StageType.Setup | StageType.ProfileUse,
                StageType.Build | StageType.ProfileUse,
                StageType.Install | StageType.ProfileUse,
                StageType.Check | StageType.ProfileUse,
            ];
        }
        else
        {
            /* No PGO, just execute stages */
            stages = [
                StageType.Prepare, StageType.Setup, StageType.Build,
                StageType.Install, StageType.Check,
            ];
        }

        /* Lights, cameras, action */
        foreach (s; stages)
        {
            insertStage(s);
        }

    }

    /**
     * Return the architecture for this profile
     */
    pure @property string architecture() @safe @nogc nothrow
    {
        return _architecture;
    }

    /**
     * Return the build root directory for this profile
     */
    pure @property string buildRoot() @safe @nogc nothrow
    {
        return _buildRoot;
    }

    /**
     * Return the installation root directory for this profile
     */
    pure @property string installRoot() @safe @nogc nothrow
    {
        return _installRoot;
    }

    /**
     * Return the original manifest, which may not be populated
     */
    pure @property BuildManifest sourceManifest() @safe @nogc nothrow
    {
        return _sourceManifest;
    }

    /**
     * The manifest we're going to write
     */
    pure @property BuildManifest[2] targetManifests() @safe @nogc nothrow
    {
        return _targetManifests;
    }

    /**
     * Write the temporary script to disk, then execute it.
     */
    void runStage(ExecutionStage* stage, string workDir, ref string script) @system
    {
        import core.sys.posix.stdlib : mkstemp;
        import std.stdio : File, fflush, stdin, stderr, stdout;
        import std.string : format;
        import std.file : remove;
        import std.exception : enforce;

        auto tmpname = "/tmp/moss-stage-%s-XXXXXX".format(stage.name);
        auto copy = new char[tmpname.length + 1];
        copy[0 .. tmpname.length] = tmpname[];
        copy[tmpname.length] = '\0';
        const int fd = mkstemp(copy.ptr);

        File fi;
        fi.fdopen(fd, "w");

        scope (exit)
        {
            fi.close();
            enforce(copy.length > 1, "Runtime error: copy.length < 1");
            const auto li = cast(long) copy.length;
            remove(cast(string) copy[0 .. li - 1]);
        }

        /* Write + flush */
        fi.write(script);
        fi.flush();
        fflush(fi.getFP);

        /* Execute, TODO: Fix environment */
        import std.process : Config, spawnProcess, wait;

        auto config = Config.retainStderr | Config.retainStdout
            | Config.stderrPassThrough | Config.inheritFDs;
        auto prenv = cast(const(string[string])) null;

        enforce(copy.length > 1, "Runtime error: copy.length < 1");
        const auto lin = cast(long) copy.length;
        auto args = ["/bin/sh", cast(string) copy[0 .. lin - 1]];

        auto id = spawnProcess(args, stdin, stdout, stderr, prenv, config, workDir);
        auto status = wait(id);
        enforce(status == 0, "Stage '%s' exited with code '%d'".format(stage.name, status));
    }

    /**
     * Request for this profile to now build
     */
    void build()
    {
        import std.array : replace;
        import std.file : mkdirRecurse;

        bool preparedFS = false;

        foreach (ref e; stages)
        {
            string workdir = buildRoot;
            if (preparedFS)
            {
                workdir = getWorkDir();
            }

            /* Prepare the rootfs now */
            auto builder = ScriptBuilder();
            prepareScripts(builder, workdir);
            buildRoot.mkdirRecurse();

            auto scripted = builder.process(e.script).replace("%%", "%");

            /* Ensure PGO dirs are present if needed */
            if ((e.type & StageType.ProfileStage1) == StageType.ProfileStage1)
            {
                import std.file : mkdirRecurse;

                pgoDir.mkdirRecurse();
            }

            runStage(e, workdir, scripted);

            /* Did we prepare the fs for building? */
            if ((e.type & StageType.Prepare) == StageType.Prepare)
            {
                preparedFS = true;
            }
        }
    }

    /**
     * Throw an error if script building fails
     */
    void validate()
    {
        foreach (ref e; stages)
        {
            ScriptBuilder builder;
            prepareScripts(builder, buildRoot);

            /* Throw script away, just ensure it can build */
            const auto scripted = builder.process(e.script);
        }
    }

    /**
     * Prepare a script builder for use
     */
    void prepareScripts(ref ScriptBuilder sbuilder, string workDir)
    {
        sbuilder.addDefinition("installroot", installRoot);
        sbuilder.addDefinition("buildroot", buildRoot);
        sbuilder.addDefinition("workdir", workDir);

        /* Set the relevant compilers */
        if (buildContext.spec.options.toolchain == "llvm")
        {
            sbuilder.addDefinition("compiler_c", "clang");
            sbuilder.addDefinition("compiler_cxx", "clang++");
            sbuilder.addDefinition("compiler_cpp", "clang-cpp");
            sbuilder.addDefinition("compiler_ar", "llvm-ar");
            sbuilder.addDefinition("compiler_objcopy", "llvm-objcopy");
            sbuilder.addDefinition("compiler_nm", "llvm-nm");
            sbuilder.addDefinition("compiler_ranlib", "llvm-ranlib");
            sbuilder.addDefinition("compiler_strip", "llvm-strip");
            sbuilder.addDefinition("compiler_path", "/usr/bin");
        }
        else
        {
            sbuilder.addDefinition("compiler_c", "gcc");
            sbuilder.addDefinition("compiler_cxx", "g++");
            sbuilder.addDefinition("compiler_cpp", "gcc -E");
            sbuilder.addDefinition("compiler_ar", "ar");
            sbuilder.addDefinition("compiler_objcopy", "objcopy");
            sbuilder.addDefinition("compiler_nm", "nm");
            sbuilder.addDefinition("compiler_ranlib", "ranlib");
            sbuilder.addDefinition("compiler_strip", "strip");
            sbuilder.addDefinition("compiler_path", "/usr/binutils/bin:/usr/bin");
        }

        sbuilder.addDefinition("pgo_dir", pgoDir);

        /* Load system macros */
        buildContext.prepareScripts(sbuilder, architecture);

        bakeFlags(sbuilder);

        /* Fully cooked */
        sbuilder.bake();
    }

    /**
     * Save our future manifest now
     */
    void produceManifest(ref BuildCollector col)
    {
        import std.array : array;
        import std.algorithm : sort, each;
        import std.range : empty;

        auto names = col.targets.array;
        names.sort();
        foreach (nom; names)
        {
            auto fileSet = col.filesForTarget(nom);
            if (fileSet.empty)
            {
                continue;
            }
            /* Ensure stable sorting */
            fileSet.sort!((a, b) => a.path < b.path);
            targetManifests.each!((m) => m.recordPackage(nom, fileSet));
        }
        targetManifests.each!((m) => m.write());
    }

private:

    /**
     * Specialist function to work with the ScriptBuilder in enabling a sane
     * set of build flags
     */
    void bakeFlags(ref ScriptBuilder sbuilder) @safe
    {
        import moss.format.source.tuning_flag : TuningFlag, Toolchain;
        import std.array : join;
        import std.string : strip;
        import std.algorithm : uniq, filter, map;
        import std.array : array;

        /* Set toolchain type for flag probing */
        auto toolchain = buildContext.spec.options.toolchain == "llvm"
            ? Toolchain.LLVM : Toolchain.GNU;

        /* Enable basic cflags always */
        sbuilder.enableGroup("architecture");

        /* Take all tuning selections */
        foreach (ref t; buildContext.spec.options.tuneSelections)
        {
            final switch (t.type)
            {
            case TuningSelectionType.Enable:
                sbuilder.enableGroup(t.name);
                break;
            case TuningSelectionType.Disable:
                sbuilder.disableGroup(t.name);
                break;
            case TuningSelectionType.Config:
                sbuilder.enableGroup(t.name, t.configValue);
                break;
            }
        }

        /* Always pick defaults for optimize, harden + bindnow */
        auto wanted = ["base", "optimize", "avxwidth", "harden", "asneeded", "bindnow"];

        foreach (w; wanted)
        {
            if (!buildContext.spec.options.hasTuningSelection(w))
            {
                sbuilder.enableGroup(w);
            }
        }

        /* Help fix up flag mappings */
        pragma(inline, true) string fixupFlags(T)(T inp)
        {
            return inp.map!((f) => f.strip)
                .array
                .uniq
                .filter!((e) => e.length > 1)
                .join(" ");
        }

        /* Fix up unique set of flags and stringify them */
        auto flagset = sbuilder.buildFlags();
        auto cflags = fixupFlags(flagset.map!((f) => f.cflags(toolchain)));
        auto cxxflags = fixupFlags(flagset.map!((f) => f.cxxflags(toolchain)));
        auto ldflags = fixupFlags(flagset.map!((f) => f.ldflags(toolchain)));

        sbuilder.addDefinition("cflags", cflags);
        sbuilder.addDefinition("cxxflags", cxxflags);
        sbuilder.addDefinition("ldflags", ldflags);
    }

    /**
     * Attempt to grab the workdir from the build tree
     *
     * Unless explicitly specified, it will be the first directory
     * entry within the build root
     */
    string getWorkDir() @system
    {
        import std.file : dirEntries, SpanMode;
        import std.path : buildPath, baseName;
        import std.string : startsWith;

        /* TODO: Support workdir variable in spec and verify it exists */
        auto items = dirEntries(buildRoot, SpanMode.shallow, false);
        foreach (item; items)
        {
            auto name = item.name.baseName;
            if (!item.name.startsWith("."))
            {
                return buildRoot.buildPath(name);
            }
        }

        return buildRoot;
    }

    /**
     * Return true if a PGO workload is found for this architecture
     */
    bool hasPGOWorkload() @safe
    {
        import std.string : startsWith;

        BuildDefinition buildDef = buildContext.spec.rootBuild;
        if (architecture in buildContext.spec.profileBuilds)
        {
            buildDef = buildContext.spec.profileBuilds[architecture];
        }
        else if (architecture.startsWith("emul32/") && "emul32" in buildContext.spec.profileBuilds)
        {
            buildDef = buildContext.spec.profileBuilds["emul32"];
        }

        return buildDef.workload() != null;
    }

    /**
     * Insert a stage for processing + execution
     *
     * We'll only insert stages if we find a relevant build description for it,
     * and doing so will result in parent traversal of profiles (i.e. root namespace
     * and emul32 namespace)
     */
    void insertStage(StageType t)
    {
        import std.string : startsWith;

        string script = null;

        /* Default to root namespace */
        BuildDefinition buildDef = buildContext.spec.rootBuild;

        /* Find specific definition for stage, or an appropriate parent */
        if (architecture in buildContext.spec.profileBuilds)
        {
            buildDef = buildContext.spec.profileBuilds[architecture];
        }
        else if (architecture.startsWith("emul32/") && "emul32" in buildContext.spec.profileBuilds)
        {
            buildDef = buildContext.spec.profileBuilds["emul32"];
        }

        /* Check core type of stage */
        if ((t & StageType.Setup) == StageType.Setup)
        {
            script = buildDef.setup();
        }
        else if ((t & StageType.Build) == StageType.Build)
        {
            script = buildDef.build();
        }
        else if ((t & StageType.Install) == StageType.Install)
        {
            script = buildDef.install();
        }
        else if ((t & StageType.Check) == StageType.Check)
        {
            script = buildDef.check();
        }
        else if ((t & StageType.Workload) == StageType.Workload)
        {
            script = buildDef.workload();
        }
        else if ((t & StageType.Prepare) == StageType.Prepare)
        {
            script = genPrepareScript();
        }

        /* Need valid script to continue */
        if (script is null)
        {
            return;
        }

        auto stage = new ExecutionStage(&this, t);
        stage.script = script;
        stages ~= stage;
    }

    /**
     * Generate preparation script
     *
     * The sole purpose of this internal script is to make the sources
     * available to the current build in their extracted/exploded form
     * via the %(sourcedir) definition.
     */
    string genPrepareScript() @system
    {
        import std.string : endsWith;
        import std.path : baseName;

        string ret = "";

        /* Push commands to extract a zip */
        void extractZip(ref UpstreamDefinition u)
        {
            ret ~= "mkdir -p " ~ u.plain.unpackdir ~ "\n";
            ret ~= "unzip -d \"" ~ u.plain.unpackdir ~ "\" \"%(sourcedir)/" ~ u.plain.rename
                ~ "\" || (echo \"Failed to extract archive\"; exit 1);";
        }

        /* Push commands to extract a tar */
        void extractTar(ref UpstreamDefinition u)
        {
            ret ~= "mkdir -p " ~ u.plain.unpackdir ~ "\n";
            ret ~= "tar xf \"%(sourcedir)/" ~ u.plain.rename
                ~ "\" -C \"" ~ u.plain.unpackdir
                ~ "\" --strip-components=" ~ u.plain.stripdirs
                ~ " || (echo \"Failed to extract archive\"; exit 1);";
        }

        foreach (source; buildContext.spec.upstreams)
        {
            final switch (source.type)
            {
            case UpstreamType.Plain:
                if (!source.plain.unpack)
                {
                    continue;
                }
                /* Ensure a target name */
                if (source.plain.rename is null)
                {
                    source.plain.rename = source.uri.baseName;
                }
                if (source.plain.rename.endsWith(".zip"))
                {
                    extractZip(source);
                }
                else
                {
                    extractTar(source);
                }
                break;
            case UpstreamType.Git:
                assert(0, "GIT SOURCE NOT YET SUPPORTED");
            }
        }

        return ret == "" ? null : ret;
    }

    string _architecture;
    ExecutionStage*[] stages;
    string _buildRoot;
    string _installRoot;
    string pgoDir;

    BuildManifest _sourceManifest = null;
    BuildManifest[2] _targetManifests = null;
}
