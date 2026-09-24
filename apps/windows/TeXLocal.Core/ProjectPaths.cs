namespace TeXLocal;

/// <summary>
/// Project-relative paths, which the core always returns with forward
/// slashes (web/src/sidebar.js containsPath and remapPath).
/// </summary>
public static class ProjectPaths
{
    /// <summary>Whether <paramref name="candidate"/> is <paramref name="parent"/> or lies inside it.</summary>
    public static bool Contains(string parent, string? candidate) =>
        candidate is not null && (candidate == parent || candidate.StartsWith(parent + "/", StringComparison.Ordinal));

    /// <summary>Where <paramref name="candidate"/> lands once <paramref name="from"/> is renamed to <paramref name="to"/>.</summary>
    public static string? Remap(string? candidate, string from, string to) =>
        Contains(from, candidate) ? to + candidate![from.Length..] : candidate;
}
