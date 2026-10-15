using System.Runtime.InteropServices;
using System.Text;

namespace TeXLocal.Bridge;

internal static unsafe partial class Native
{
    const string Lib = "texlocal_ffi";

    [LibraryImport(Lib)] public static partial nint tl_open(byte* dataDir);
    [LibraryImport(Lib)] public static partial nint tl_call(nint h, byte* cmd, byte* args);
    [LibraryImport(Lib)] public static partial void tl_call_async(nint h, byte* cmd, byte* args, delegate* unmanaged[Cdecl]<nint, byte*, void> done, nint ctx);
    [LibraryImport(Lib)] public static partial void tl_set_listener(nint h, delegate* unmanaged[Cdecl]<nint, byte*, void> listener, nint ctx);
    [LibraryImport(Lib)] public static partial void tl_free(nint p);
    [LibraryImport(Lib)] public static partial void tl_close(nint h);
    [LibraryImport(Lib)] public static partial nint tl_session_source(nint h, ulong session, byte* path);
    [LibraryImport(Lib)] public static partial nint tl_source_new(byte* text, nuint len);
    [LibraryImport(Lib)] public static partial void tl_source_edit(nint s, uint start, uint length, byte* text, nuint len);
    [LibraryImport(Lib)] public static partial void tl_source_reload(nint s, byte* text, nuint len);
    [LibraryImport(Lib)] public static partial uint tl_source_line_at(nint s, uint offset);
    [LibraryImport(Lib)] public static partial uint tl_source_line_start(nint s, uint line);
    [LibraryImport(Lib)] public static partial uint tl_source_line_count(nint s);
    [LibraryImport(Lib)] public static partial uint* tl_source_highlights(nint s, uint start, uint length, nuint* count);
    [LibraryImport(Lib)] public static partial void tl_source_free_runs(uint* runs, nuint count);
    [LibraryImport(Lib)] public static partial nint tl_source_call(nint s, byte* cmd, byte* args);
    [LibraryImport(Lib)] public static partial void tl_source_free(nint s);
    [LibraryImport(Lib)] public static partial nint tl_syntax_call(byte* cmd, byte* args);

    /// NUL-terminated UTF-8, or null for a null string.
    public static byte[]? Utf8(string? s) => s is null ? null : Encoding.UTF8.GetBytes(s + '\0');

    /// Takes a string the core allocated, freeing it.
    public static string? Take(nint p)
    {
        if (p == 0) return null;
        try { return Marshal.PtrToStringUTF8(p); }
        finally { tl_free(p); }
    }
}
