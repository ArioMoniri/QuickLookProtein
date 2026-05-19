// Settings WPF app entry point. Two responsibilities beyond
// vanilla WPF bootstrap:
//
//   1. Single-instance guard via a named Mutex. If the user
//      double-clicks the Start Menu shortcut while the window
//      is already open we surface the existing window instead of
//      spawning a second process. Without this guard,
//      back-to-back clicks during a crash-loop scenario looked
//      to one user like the app was "infinitely respawning" -
//      Windows itself wasn't restarting it, but multiple
//      transient processes coming up and dying in rapid
//      succession looked the same.
//
//   2. Hook DispatcherUnhandledException + UnhandledException so
//      a startup-time XamlParseException (e.g. missing
//      Microsoft.Web.WebView2.Wpf.dll, which makes <wv2:WebView2>
//      unresolvable at InitializeComponent time) shows the user
//      a MessageBox with the actual error instead of vanishing
//      silently. Previously the window would close so fast the
//      user couldn't tell what failed - exit code 1 only shows
//      up in Event Viewer.

using System;
using System.Diagnostics;
using System.Threading;
using System.Windows;
using System.Windows.Threading;

namespace QuickLookProtein.Settings;

public partial class App : Application
{
    // Per-user mutex so it doesn't collide with another Windows
    // account running the same app. Local\ prefix keeps the kernel
    // object in the session namespace.
    private const string SingleInstanceMutexName =
        "Local\\QuickLookProtein.Settings.SingleInstance";

    private Mutex? _singleInstanceMutex;
    private bool _ownsMutex;

    protected override void OnStartup(StartupEventArgs e)
    {
        // Wire exception handlers FIRST so a XAML parse error in
        // MainWindow's constructor (triggered by base.OnStartup
        // creating the StartupUri window) is caught and surfaced.
        DispatcherUnhandledException += App_DispatcherUnhandledException;
        AppDomain.CurrentDomain.UnhandledException += CurrentDomain_UnhandledException;

        // Single-instance: try to take the mutex; if someone else
        // already owns it, surface their window and exit. We use
        // the "createdNew" pattern instead of WaitOne(0) so a stale
        // abandoned mutex (previous crash) doesn't deadlock the
        // new launch.
        _singleInstanceMutex = new Mutex(initiallyOwned: true,
                                        name: SingleInstanceMutexName,
                                        createdNew: out _ownsMutex);
        if (!_ownsMutex)
        {
            TryActivateExistingInstance();
            Shutdown();
            return;
        }

        // base.OnStartup creates the StartupUri window synchronously.
        // If MainWindow's constructor throws (XamlParseException from
        // a missing WebView2.Wpf assembly is the realistic case here),
        // the exception travels up *this* call stack rather than the
        // dispatcher pump, so DispatcherUnhandledException doesn't fire.
        // Catch it explicitly so we can show a MessageBox before exit.
        try
        {
            base.OnStartup(e);
        }
        catch (Exception ex)
        {
            ReportFatal("Startup exception", ex);
            Shutdown(1);
        }
    }

    protected override void OnExit(ExitEventArgs e)
    {
        if (_ownsMutex)
        {
            try { _singleInstanceMutex?.ReleaseMutex(); } catch { /* benign */ }
        }
        _singleInstanceMutex?.Dispose();
        base.OnExit(e);
    }

    private static void TryActivateExistingInstance()
    {
        // Best-effort: walk the current user's QuickLookProtein.Settings
        // processes and SetForegroundWindow on the first one with a
        // main window. Falls through silently if the lookup fails -
        // the user can still find the existing window in the taskbar.
        try
        {
            var me = Process.GetCurrentProcess();
            foreach (var p in Process.GetProcessesByName(me.ProcessName))
            {
                if (p.Id == me.Id) continue;
                if (p.MainWindowHandle == IntPtr.Zero) continue;
                NativeMethods.ShowWindow(p.MainWindowHandle, NativeMethods.SW_RESTORE);
                NativeMethods.SetForegroundWindow(p.MainWindowHandle);
                return;
            }
        }
        catch { /* nothing useful to do */ }
    }

    private void App_DispatcherUnhandledException(
        object sender, DispatcherUnhandledExceptionEventArgs e)
    {
        ReportFatal("UI-thread exception", e.Exception);
        // Mark handled so WPF doesn't tear down silently; we'll
        // exit from the message-box close below.
        e.Handled = true;
        Shutdown(1);
    }

    private void CurrentDomain_UnhandledException(
        object sender, UnhandledExceptionEventArgs e)
    {
        ReportFatal("Background-thread exception",
                    e.ExceptionObject as Exception);
    }

    private static void ReportFatal(string label, Exception? ex)
    {
        var msg = ex?.ToString() ?? "(no exception object)";
        // Truncate so the MessageBox stays readable.
        if (msg.Length > 2000) msg = msg.Substring(0, 2000) + " ...";
        try
        {
            MessageBox.Show(
                $"QuickLookProtein2 Settings hit a fatal error and has to close.\n\n" +
                $"({label})\n\n" +
                $"{msg}\n\n" +
                $"This usually means a required Windows runtime DLL is missing " +
                $"from the install folder (typically Microsoft.Web.WebView2.*). " +
                $"Reinstall from the Setup.exe to restore the dependencies.",
                "QuickLookProtein2 - Fatal error",
                MessageBoxButton.OK,
                MessageBoxImage.Error);
        }
        catch
        {
            // If even the MessageBox throws (e.g. session 0) there's
            // nothing useful left to do.
        }
    }

    private static class NativeMethods
    {
        public const int SW_RESTORE = 9;

        [System.Runtime.InteropServices.DllImport("user32.dll")]
        [return: System.Runtime.InteropServices.MarshalAs(
            System.Runtime.InteropServices.UnmanagedType.Bool)]
        public static extern bool SetForegroundWindow(IntPtr hWnd);

        [System.Runtime.InteropServices.DllImport("user32.dll")]
        [return: System.Runtime.InteropServices.MarshalAs(
            System.Runtime.InteropServices.UnmanagedType.Bool)]
        public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    }
}
