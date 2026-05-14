// File-based diagnostic logger for the QL-Win plugin.
//
// Why: when QuickLook falls back to its text viewer for a structure
// file, there's no user-visible signal as to why. We need to know:
//   - Was Init() called? (means QL-Win discovered our DLL)
//   - Was CanHandle() called? (and what did it return?)
//   - Was View() called? (and did the WebView2 load throw?)
// Logging to a file the user can attach to a bug report is the
// pragmatic answer. QL-Win also has its own log at
// %LocalAppData%\QuickLook\App.log but it doesn't show plugin-
// internal exceptions unless the plugin re-throws them.
//
// Log file: %LocalAppData%\QuickLookProtein\plugin.log
// Auto-rotates at 1 MB (truncates back to empty) so a long-running
// QL-Win process can't fill the disk with our trace.

using System;
using System.IO;
using System.Threading;

namespace QuickLookProtein.Plugin;

internal static class PluginLog
{
    // Single-writer lock so the QL-Win thread pool doesn't interleave
    // partial lines if a preview happens concurrently with init.
    private static readonly object _lock = new();
    private const long MaxBytes = 1024 * 1024;

    private static string LogPath
    {
        get
        {
            var dir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "QuickLookProtein");
            try { Directory.CreateDirectory(dir); } catch { }
            return Path.Combine(dir, "plugin.log");
        }
    }

    public static void Info(string message)  => Write("INFO", message);
    public static void Warn(string message)  => Write("WARN", message);
    public static void Error(string message) => Write("ERR ", message);

    public static void Exception(string context, Exception ex)
    {
        Write("ERR ", $"{context}: {ex.GetType().Name}: {ex.Message}");
        // Include the stack so we can pinpoint which call site
        // failed. .ToString() on the exception includes inner
        // exceptions as well.
        try { Write("ERR ", ex.ToString()); } catch { }
    }

    private static void Write(string level, string message)
    {
        try
        {
            lock (_lock)
            {
                var path = LogPath;
                // Auto-rotate: if the file's too big, start fresh.
                try
                {
                    var fi = new FileInfo(path);
                    if (fi.Exists && fi.Length > MaxBytes) File.WriteAllText(path, "");
                }
                catch { }
                var line = $"{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff} [{level}] [t{Thread.CurrentThread.ManagedThreadId}] {message}\r\n";
                File.AppendAllText(path, line);
            }
        }
        catch
        {
            // Logging must never throw - the plugin's own correctness
            // is more important than the trace.
        }
    }
}
