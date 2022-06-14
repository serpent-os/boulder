/* SPDX-License-Identifier: Zlib */

/**
 * GitHub metadata support
 *
 * Extracts version, homepage, etc.
 *
 * Authors: © 2020-2022 Serpent OS Developers
 * License: ZLib
 */

module chef.metadata.github;

import std.typecons : Nullable;
import moss.format.source.source_definition;
import std.regex;

/**
 * Github automatically generated downloads
 */
auto reGithubAutomatic = ctRegex!(
        r"\w+\:\/\/github\.com\/([A-Za-z0-9-_]+)\/([A-Za-z0-9-_]+)\/archive\/refs\/tags\/([A-Za-z0-9.-_]+)\.(tar|zip)");

/**
 * Manually uploaded files on GitHub
 */
auto reGithubManual = ctRegex!(
        r"\w+\:\/\/github\.com\/([A-Za-z0-9-_]+)\/([A-Za-z0-9-_]+)\/releases\/download\/([A-Za-z0-9-_.]+)\/.*");

/**
 * More advanced matching.
 */
public struct GithubMatcher
{
    /**
     * Not yet implemented
     */
    Nullable!(SourceDefinition, SourceDefinition.init) match(in string uri)
    {
        Nullable!(SourceDefinition, SourceDefinition.init) ret = SourceDefinition.init;

        return ret;
    }
}