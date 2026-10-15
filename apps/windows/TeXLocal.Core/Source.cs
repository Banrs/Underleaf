using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using static TeXLocal.Bridge.Native;

namespace TeXLocal.Bridge;

public readonly record struct HighlightRun(int Start, int Length, int Kind);

/// A session document's text as the editor sees it. UI thread only; offsets are UTF-16.
public sealed unsafe class Source : SafeHandle
{
    internal Source(nint handle) : base(0, true) => SetHandle(handle);

    public static Source New(string text)
    {
        var bytes = Encoding.UTF8.GetBytes(text);
        fixed (byte* t = bytes) return new Source(tl_source_new(t, (nuint)bytes.Length));
    }

    public override bool IsInvalid => handle == 0;

    protected override bool ReleaseHandle()
    {
        tl_source_free(handle);
        return true;
    }

    public void Edit(int start, int length, string text)
    {
        var bytes = Encoding.UTF8.GetBytes(text);
        fixed (byte* t = bytes) tl_source_edit(handle, (uint)start, (uint)length, t, (nuint)bytes.Length);
    }

    public void Reload(string text)
    {
        var bytes = Encoding.UTF8.GetBytes(text);
        fixed (byte* t = bytes) tl_source_reload(handle, t, (nuint)bytes.Length);
    }

    public int LineAt(int offset) => (int)tl_source_line_at(handle, (uint)offset);
    public int LineStart(int line) => (int)tl_source_line_start(handle, (uint)line);
    public int LineCount => (int)tl_source_line_count(handle);

    public HighlightRun[] Highlights(int start, int length)
    {
        nuint count;
        var runs = tl_source_highlights(handle, (uint)start, (uint)length, &count);
        try
        {
            var result = new HighlightRun[(int)count / 3];
            for (var i = 0; i < result.Length; i++)
                result[i] = new((int)runs[3 * i], (int)runs[3 * i + 1], (int)runs[3 * i + 2]);
            return result;
        }
        finally { tl_source_free_runs(runs, count); }
    }

    public string? Call(string cmd, object args)
    {
        fixed (byte* c = Utf8(cmd))
        fixed (byte* a = Utf8(JsonSerializer.Serialize(args, Core.Json)))
            return Take(tl_source_call(handle, c, a));
    }
}
