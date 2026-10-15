using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text.Json;
using static TeXLocal.Bridge.Native;

namespace TeXLocal.Bridge;

public sealed class CoreException(int status, string message) : Exception(message)
{
    public int Status { get; } = status;
}

public sealed record CoreEvent(string Type, ulong Session, JsonElement Json);

public sealed class Core : IDisposable
{
    public static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);

    sealed class Pending(Core core) : TaskCompletionSource<JsonElement>(TaskCreationOptions.RunContinuationsAsynchronously)
    {
        public readonly Core Core = core;
    }

    readonly nint handle;
    readonly Action<Action> post;
    GCHandle self;
    int inFlight;
    bool disposed;

    public event Action<CoreEvent>? Event;

    public static string DefaultDataDir =>
        Environment.GetEnvironmentVariable("TEXLOCAL_DATA") is { Length: > 0 } dir
            ? dir
            : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "TeXLocal");

    unsafe Core(nint handle, Action<Action> post)
    {
        this.handle = handle;
        this.post = post;
        self = GCHandle.Alloc(this);
        tl_set_listener(handle, &Listen, GCHandle.ToIntPtr(self));
    }

    public static unsafe Core Open(string dataDir, Action<Action> post)
    {
        nint h;
        fixed (byte* d = Utf8(dataDir)) h = tl_open(d);
        if (h == 0) throw new CoreException(0, $"Can't open {dataDir}");
        return new Core(h, post);
    }

    public unsafe Task<JsonElement> CallAsync(string command, object? args = null)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        var pending = new Pending(this);
        Interlocked.Increment(ref inFlight);
        fixed (byte* c = Utf8(command))
        fixed (byte* a = Utf8(args is null ? null : JsonSerializer.Serialize(args, Json)))
            tl_call_async(handle, c, a, &Done, GCHandle.ToIntPtr(GCHandle.Alloc(pending)));
        return pending.Task;
    }

    public async Task<T> CallAsync<T>(string command, object? args = null) =>
        (await CallAsync(command, args)).Deserialize<T>(Json)!;

    public unsafe Source? SessionSource(ulong session, string path)
    {
        nint s;
        fixed (byte* p = Utf8(path)) s = tl_session_source(handle, session, p);
        return s == 0 ? null : new Source(s);
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    static unsafe void Done(nint ctx, byte* json)
    {
        var gc = GCHandle.FromIntPtr(ctx);
        var pending = (Pending)gc.Target!;
        gc.Free();
        try
        {
            using var doc = JsonDocument.Parse(Marshal.PtrToStringUTF8((nint)json)!);
            var root = doc.RootElement;
            if (root.TryGetProperty("ok", out var ok)) pending.SetResult(ok.Clone());
            else pending.SetException(new CoreException(
                root.TryGetProperty("status", out var s) ? s.GetInt32() : 500,
                root.TryGetProperty("error", out var e) ? e.GetString() ?? "" : ""));
        }
        catch (Exception e) { pending.TrySetException(e); }
        finally { Interlocked.Decrement(ref pending.Core.inFlight); }
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    static unsafe void Listen(nint ctx, byte* json)
    {
        try
        {
            var core = (Core)GCHandle.FromIntPtr(ctx).Target!;
            using var doc = JsonDocument.Parse(Marshal.PtrToStringUTF8((nint)json)!);
            var root = doc.RootElement.Clone();
            var ev = new CoreEvent(
                root.TryGetProperty("type", out var t) ? t.GetString() ?? "" : "",
                root.TryGetProperty("session", out var s) && s.ValueKind == JsonValueKind.Number ? s.GetUInt64() : 0,
                root);
            core.post(() => core.Event?.Invoke(ev));
        }
        catch (Exception) { }
    }

    public unsafe void Dispose()
    {
        if (disposed) return;
        disposed = true;
        tl_set_listener(handle, null, 0);
        fixed (byte* c = Utf8("kill_all")) tl_free(tl_call(handle, c, null));
        SpinWait.SpinUntil(() => Volatile.Read(ref inFlight) == 0, TimeSpan.FromSeconds(5));
        tl_close(handle);
        self.Free();
    }
}
