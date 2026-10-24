using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using Microsoft.Win32.SafeHandles;
using static TeXLocal.Bridge.Native;

namespace TeXLocal.Bridge;

public readonly record struct HighlightRun(int Start, int Length, int Kind);

/// A session document's text as the editor sees it. UI thread only; offsets are UTF-16.
public sealed unsafe class Source : SafeHandleZeroOrMinusOneIsInvalid
{
    internal Source(nint handle) : base(true) => SetHandle(handle);

    public static Source New(string text) => new(tl_source_new(text, Bytes(text)));

    protected override bool ReleaseHandle()
    {
        tl_source_free(handle);
        return true;
    }

    /// Each edit RichEdit makes, once. Answers the edits that copy what was typed in a snippet's field to its other
    /// places, from the last, unless mirroring them; null for none, as nearly always.
    public TextEdit[]? Edit(int start, int length, string text, bool mirroring = false) =>
        Parse<TextEdit[]>(tl_source_edit(handle, (uint)start, (uint)length, text, Bytes(text), 0, mirroring));

    /// The selection moved: a snippet ends once it leaves its fields, unless mirroring.
    public void Select(SourceRange selection, bool mirroring) => tl_source_select(handle, (uint)selection.Start, (uint)selection.Length, mirroring);

    /// The whole text, which may hold U+0000.
    public string Text
    {
        get
        {
            nuint length;
            var text = tl_source_text(handle, &length);
            try { return Encoding.UTF8.GetString(text, (int)length); }
            finally { tl_source_free_text(text, length); }
        }
    }

    /// False, keeping its text, when keys were typed after the session sent the reload: a conflict follows.
    public bool Reload(string text) => tl_source_reload(handle, text, Bytes(text));
    public int LineAt(int offset) => (int)tl_source_line_at(handle, (uint)offset);
    public int LineStart(int line) => (int)tl_source_line_start(handle, (uint)line);
    public int LineCount => (int)tl_source_line_count(handle);

    public HighlightRun[] Highlights(int start, int length)
    {
        nuint count;
        var runs = tl_source_highlights(handle, (uint)start, (uint)length, &count);
        // Three u32s a run (start, length, kind), as HighlightRun lays them out.
        try { return MemoryMarshal.Cast<uint, HighlightRun>(new ReadOnlySpan<uint>(runs, (int)count)).ToArray(); }
        finally { tl_source_free_runs(runs, count); }
    }

    /// A document command's answer; default for null or none.
    public T? Call<T>(string cmd, object args) => Parse<T>(tl_source_call(handle, cmd, JsonSerializer.Serialize(args, Core.Json)));

    /// Any thread.
    public static T? SyntaxCall<T>(string cmd, object args) => Parse<T>(tl_syntax_call(cmd, JsonSerializer.Serialize(args, Core.Json)));

    static T? Parse<T>(nint json)
    {
        if (json == 0) return default;
        try { return JsonSerializer.Deserialize<T>(MemoryMarshal.CreateReadOnlySpanFromNullTerminated((byte*)json), Core.Json); }
        finally { tl_free(json); }
    }
}
