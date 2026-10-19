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

    readonly nint handle;
    readonly Action<Action> post;
    GCHandle self;
    int inFlight;
    bool disposed;

    public event Action<CoreEvent>? Event;

    public static string DefaultDataDir => Environment.GetEnvironmentVariable("TEXLOCAL_DATA") is { Length: > 0 } dir
        ? dir : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "TeXLocal");

    unsafe Core(nint handle, Action<Action> post)
    {
        (this.handle, this.post) = (handle, post);
        self = GCHandle.Alloc(this);
        tl_set_listener(handle, &Listen, GCHandle.ToIntPtr(self));
    }

    public static Core Open(string dataDir, Action<Action> post) =>
        tl_open(dataDir) is var h and not 0 ? new Core(h, post) : throw new CoreException(0, $"Can't open {dataDir}");

    public unsafe Task<JsonElement> CallAsync(string command, object? args = null)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        var pending = new TaskCompletionSource<JsonElement>(TaskCreationOptions.RunContinuationsAsynchronously);
        Interlocked.Increment(ref inFlight);
        tl_call_async(handle, command, args is null ? null : JsonSerializer.Serialize(args, Json), &Done, GCHandle.ToIntPtr(GCHandle.Alloc((pending, this))));
        return pending.Task;
    }

    public async Task<T> CallAsync<T>(string command, object? args = null) =>
        (await CallAsync(command, args)).Deserialize<T>(Json)!;

    public Source? SessionSource(ulong session, string path) =>
        tl_session_source(handle, session, path) is var s and not 0 ? new Source(s) : null;

    /// Straight from the core's UTF-8 into an element that owns its data.
    static unsafe JsonElement Parse(byte* json) =>
        JsonSerializer.Deserialize<JsonElement>(MemoryMarshal.CreateReadOnlySpanFromNullTerminated(json), Json);

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    static unsafe void Done(nint ctx, byte* json)
    {
        var gc = GCHandle.FromIntPtr(ctx);
        var (pending, core) = ((TaskCompletionSource<JsonElement>, Core))gc.Target!;
        gc.Free();
        var root = Parse(json);
        if (root.TryGetProperty("ok", out var ok)) pending.SetResult(ok);
        else pending.SetException(new CoreException(root.GetProperty("status").GetInt32(), root.GetProperty("error").GetString()!));
        Interlocked.Decrement(ref core.inFlight);
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    static unsafe void Listen(nint ctx, byte* json)
    {
        var core = (Core)GCHandle.FromIntPtr(ctx).Target!;
        var root = Parse(json);
        core.post(() => core.Event?.Invoke(new(root.GetProperty("type").GetString()!, root.GetProperty("session").GetUInt64(), root)));
    }

    /// Stops the builds first, so the answers in flight arrive before the core closes.
    public unsafe void Dispose()
    {
        if (disposed) return;
        tl_set_listener(handle, null, 0);
        _ = CallAsync("kill_all");
        disposed = true;
        SpinWait.SpinUntil(() => Volatile.Read(ref inFlight) == 0, TimeSpan.FromSeconds(5));
        tl_close(handle);
        self.Free();
    }
}
