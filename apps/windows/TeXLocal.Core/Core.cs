using System.Runtime.InteropServices;
using System.Text.Json;

namespace TeXLocal;

/// <summary>
/// A command the Rust core refused, with the status it gave (400 for a bad
/// request, 404 for something missing, 500 for an I/O failure).
/// </summary>
public sealed class CoreException(string message, int status) : Exception(message)
{
    public int Status { get; } = status;
}

/// <summary>
/// The Rust core through its C ABI (crates/texlocal-ffi), JSON in and out, with
/// the web's command names. <c>tl_call</c> blocks for as long as the command
/// runs (minutes, for a compile), so every call runs on the thread pool.
/// </summary>
public sealed partial class Core
{
    private const string Library = "texlocal_ffi";

    [LibraryImport(Library, StringMarshalling = StringMarshalling.Utf8)]
    private static partial nint tl_open(string? dataDir);

    [LibraryImport(Library, StringMarshalling = StringMarshalling.Utf8)]
    private static partial nint tl_call(nint handle, string command, string argsJson);

    [LibraryImport(Library)]
    private static partial void tl_free(nint text);

    /// <summary>The core's field names are camelCase.</summary>
    public static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);

    // Never closed: the handle lives as long as the process, and quitting
    // stops compiles with kill_all instead, since a call may still be running.
    private readonly nint handle;

    /// <summary>Opens the library folder the core picks: TEXLOCAL_DATA, else TeXLocal in the user's profile.</summary>
    public Core()
    {
        handle = tl_open(null);
        if (handle == 0)
        {
            throw new InvalidOperationException("TeXLocal could not open its library folder.");
        }
    }

    // The Rust side accepts concurrent calls from any thread.
    private string Run(string command, string json)
    {
        var output = tl_call(handle, command, json);
        try
        {
            return Marshal.PtrToStringUTF8(output) ?? "";
        }
        finally
        {
            tl_free(output);
        }
    }

    private async Task<JsonElement> SendAsync(string command, object? args)
    {
        var json = JsonSerializer.Serialize(args ?? new { }, Json);
        var text = await Task.Run(() => Run(command, json));
        using var envelope = JsonDocument.Parse(text);
        var root = envelope.RootElement;
        if (root.TryGetProperty("error", out var error))
        {
            var status = root.TryGetProperty("status", out var code) ? code.GetInt32() : 500;
            throw new CoreException(error.GetString() ?? "", status);
        }
        return root.GetProperty("ok").Clone();
    }

    /// <summary>Run a command and decode its result.</summary>
    public async Task<T> CallAsync<T>(string command, object? args = null) =>
        (await SendAsync(command, args)).Deserialize<T>(Json) ?? throw new CoreException($"The core returned nothing for {command}", 500);

    /// <summary>Run a command whose result is not needed.</summary>
    public Task PerformAsync(string command, object? args = null) => SendAsync(command, args);

    /// <summary>Stop running compiles. Synchronous on purpose: it runs as the app quits.</summary>
    public void KillAll() => Run("kill_all", "{}");
}
