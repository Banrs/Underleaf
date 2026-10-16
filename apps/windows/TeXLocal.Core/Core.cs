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

/// The core: commands answer on its threads, and events are posted to the thread `post` runs on.
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
        (this.handle, this.post) = (handle, post);
        self = GCHandle.Alloc(this);
        tl_set_listener(handle, &Listen, GCHandle.ToIntPtr(self));
    }

    public static Core Open(string dataDir, Action<Action> post)
    {
        var h = tl_open(dataDir);
        return h == 0 ? throw new CoreException(0, $"Can't open {dataDir}") : new Core(h, post);
    }

    public unsafe Task<JsonElement> CallAsync(string command, object? args = null)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        var pending = new Pending(this);
        Interlocked.Increment(ref inFlight);
        tl_call_async(handle, command, args is null ? null : JsonSerializer.Serialize(args, Json), &Done, GCHandle.ToIntPtr(GCHandle.Alloc(pending)));
        return pending.Task;
    }

    public async Task<T> CallAsync<T>(string command, object? args = null) =>
        (await CallAsync(command, args)).Deserialize<T>(Json)!;

    public Source? SessionSource(ulong session, string path)
    {
        var s = tl_session_source(handle, session, path);
        return s == 0 ? null : new Source(s);
    }

    /// Straight from the core's UTF-8 into an element that owns its data.
    static unsafe JsonElement Parse(byte* json) =>
        JsonSerializer.Deserialize<JsonElement>(MemoryMarshal.CreateReadOnlySpanFromNullTerminated(json), Json);

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    static unsafe void Done(nint ctx, byte* json)
    {
        var gc = GCHandle.FromIntPtr(ctx);
        var pending = (Pending)gc.Target!;
        gc.Free();
        try
        {
            var root = Parse(json);
            if (root.TryGetProperty("ok", out var ok)) pending.SetResult(ok);
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
        // Nothing may throw into the core's thread.
        try
        {
            var core = (Core)GCHandle.FromIntPtr(ctx).Target!;
            var root = Parse(json);
            var ev = new CoreEvent(
                root.TryGetProperty("type", out var t) ? t.GetString() ?? "" : "",
                root.TryGetProperty("session", out var s) && s.ValueKind == JsonValueKind.Number ? s.GetUInt64() : 0,
                root);
            core.post(() => core.Event?.Invoke(ev));
        }
        catch (Exception) { }
    }

    /// Stops the builds first, so the answers in flight arrive before the core closes.
    public unsafe void Dispose()
    {
        if (disposed) return;
        disposed = true;
        tl_set_listener(handle, null, 0);
        tl_free(tl_call(handle, "kill_all", null));
        SpinWait.SpinUntil(() => Volatile.Read(ref inFlight) == 0, TimeSpan.FromSeconds(5));
        tl_close(handle);
        self.Free();
    }
}
