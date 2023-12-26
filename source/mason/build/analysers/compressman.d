/*
 * SPDX-FileCopyrightText: Copyright © 2020-2023 Serpent OS Developers
 *
 * SPDX-License-Identifier: Zlib
 */

/**
 * mason.build.analysers.compressman;
 *
 * Compress man or info pages with gzip
 *
 * Authors: Copyright © 2020-2023 Serpent OS Developers
 * License: Zlib
 */

module mason.build.analysers.compressman;

import mason.build.builder : Builder;
import mason.build.context;
import moss.core.sizing : formattedSize;
import std.algorithm : canFind, endsWith;
import std.experimental.logger;
import std.file : getTimes, read, readLink, setTimes, symlink, write;
import std.stdio: File, toFile;
import std.string : format;

public import moss.deps.analysis;

/**
 * Detect man or info pages
 *
 * Params:
 *      analyser = Scoped analyser for this run
 *      fileInfo = Current file to run analysis on
 * Returns: AnalysisReturn.NextFunction when a page is found and compressman is enabled,
 *           otherwise AnalysisReturn.NextHandler.
 */
public AnalysisReturn acceptManInfoPages(scope Analyser analyser, ref FileInfo fileInfo)
{
    if (!buildContext.spec.options.compressman)
    {
        return AnalysisReturn.NextHandler;
    }
    if (fileInfo.type == FileType.Directory)
    {
        return AnalysisReturn.NextHandler;
    }

    auto filename = fileInfo.path;

    /* Accept Man pages */
    // FIXME: Some man pages do not end with 1..9 but with .1foobar (such as openssl)
    if (filename.canFind("man") && filename.endsWith("1", "2", "3", "4", "5", "6", "7", "8", "9"))
    {
        return AnalysisReturn.NextFunction;
    }
    /* Accept Info pages */
    if (filename.canFind("info") && filename.endsWith(".info"))
    {
        return AnalysisReturn.NextFunction;
    }

    return AnalysisReturn.NextHandler;
}

/**
 * Compress man or info pages with gzip
 *
 * Params:
 *      analyser = Scoped analyser for this run
 *      fileInfo = Current file to run analysis on
 * Returns: AnalysisReturn.IgnoreFile always
 */
static AnalysisReturn compressPage(scope Analyser analyser, ref FileInfo fileInfo)
{
    import std.zlib : Compress, HeaderFormat;
    import std.datetime : abs, SysTime;

    auto filename = fileInfo.path;
    auto instance = analyser.userdata!Builder;

    immutable ext = ".gz";

    /* We have a symlink file, update it to point to the compressed file */
    // FIXME: Seemingly working but not tested on a real install
    if (fileInfo.type == FileType.Symlink)
    {
        auto actualPath = readLink(fileInfo.fullPath);
        trace(format!"[Man] Updated symlink %s to %s"(filename, format!"%s%s"(actualPath, ext)));
        symlink(format!"%s%s"(actualPath, ext), format!"%s%s"(fileInfo.fullPath, ext));
        /* Collect the updated symlink into the manifest */
        instance.collectPath(format!"%s%s"(fileInfo.fullPath, ext), instance.installRoot);
        /* Remove the original file */
        return AnalysisReturn.IgnoreFile;
    }

    /* Get atime, mtime of the file */
    SysTime accessTime, modificationTime;
    getTimes(fileInfo.fullPath, accessTime, modificationTime);

    /* Compress it in memory */
    Compress cmp = new Compress(9, HeaderFormat.gzip);
    auto page = read(fileInfo.fullPath);
    auto compressedPage = cmp.compress(page) ~ cmp.flush();

    /* Stats */
    immutable double presize = page.length;
    immutable double postsize = compressedPage.length;
    info(format!"[Man] Compressed: %s. Original size: %s Compressed size: %s"(format!"%s%s"(filename, ext),
            formattedSize(presize), formattedSize(postsize)));

    /* Write to disk with extension */
    write(format!"%s%s"(fileInfo.fullPath, ext), compressedPage);

    /* Set atime, mtime of compressed file to the original for reproducibility */
    setTimes(format!"%s%s"(fileInfo.fullPath, ext), accessTime, modificationTime);

    /* Collect the compressed file into the manifest */
    instance.collectPath(format!"%s%s"(fileInfo.fullPath, ext), instance.installRoot);

    /* Remove the original pre-compressed file */
    return AnalysisReturn.IgnoreFile;
}
