using System.Runtime.InteropServices;
using System.Text;

namespace TeXLocal.Bridge;

/// texlocal_ffi's C API. Strings go as NUL-terminated UTF-8; a text with its length in bytes may hold NULs too.
internal static unsafe partial class Native
{
    const string Lib = "texlocal_ffi";
    const StringMarshalling Utf8 = StringMarshalling.Utf8;

    [LibraryImport(Lib, StringMarshalling = Utf8)] public static partial nint tl_open(string dataDir);
    [LibraryImport(Lib, StringMarshalling = Utf8)] public static partial void tl_call_async(nint h, string cmd, string? args, delegate* unmanaged[Cdecl]<nint, byte*, void> done, nint ctx);
    [LibraryImport(Lib)] public static partial void tl_set_listener(nint h, delegate* unmanaged[Cdecl]<nint, byte*, void> listener, nint ctx);
    [LibraryImport(Lib)] public static partial void tl_free(nint p);
    [LibraryImport(Lib)] public static partial void tl_close(nint h);
    [LibraryImport(Lib, StringMarshalling = Utf8)] public static partial nint tl_session_source(nint h, ulong session, string path);
    [LibraryImport(Lib, StringMarshalling = Utf8)] public static partial nint tl_source_new(string text, nuint len);
    [LibraryImport(Lib, StringMarshalling = Utf8)] public static partial nint tl_source_edit(nint s, uint start, uint length, string text, nuint len, nint changing, [MarshalAs(UnmanagedType.U1)] bool mirroring);
    [LibraryImport(Lib)] public static partial void tl_source_select(nint s, uint start, uint length, [MarshalAs(UnmanagedType.U1)] bool mirroring);
    [LibraryImport(Lib)] public static partial byte* tl_source_text(nint s, nuint* len);
    [LibraryImport(Lib)] public static partial void tl_source_free_text(byte* text, nuint len);
    [LibraryImport(Lib, StringMarshalling = Utf8)] public static partial void tl_source_reload(nint s, string text, nuint len);
    [LibraryImport(Lib)] public static partial uint tl_source_line_at(nint s, uint offset);
    [LibraryImport(Lib)] public static partial uint tl_source_line_start(nint s, uint line);
    [LibraryImport(Lib)] public static partial uint tl_source_line_count(nint s);
    [LibraryImport(Lib)] public static partial uint* tl_source_highlights(nint s, uint start, uint length, nuint* count);
    [LibraryImport(Lib)] public static partial void tl_source_free_runs(uint* runs, nuint count);
    [LibraryImport(Lib, StringMarshalling = Utf8)] public static partial nint tl_source_call(nint s, string cmd, string args);
    [LibraryImport(Lib)] public static partial void tl_source_free(nint s);
    [LibraryImport(Lib, StringMarshalling = Utf8)] public static partial nint tl_syntax_call(string cmd, string args);

    public static nuint Bytes(string text) => (nuint)Encoding.UTF8.GetByteCount(text);
}
