// Polyfill for C# 9+'s `init`-only setters under .NET Framework 4.7.2.
//
// The C# compiler emits a `modreq(IsExternalInit)` attribute on
// init-only property accessors (i.e. `public string Foo { get; init; }`).
// .NET 5+ ships `System.Runtime.CompilerServices.IsExternalInit`,
// but .NET Framework does not.  Declaring an internal type with
// the same fully-qualified name in our own assembly makes the
// compiler accept the modreq under net472.  This pattern is
// officially blessed by the Roslyn team for downlevel targets:
// https://learn.microsoft.com/en-us/dotnet/csharp/language-reference/proposals/csharp-9.0/init
//
// Lives in its own file because C# 10's file-scoped namespace
// syntax (which UpdateChecker.cs uses) doesn't allow a second
// namespace block in the same file.

namespace System.Runtime.CompilerServices
{
    [System.ComponentModel.EditorBrowsable(System.ComponentModel.EditorBrowsableState.Never)]
    internal static class IsExternalInit { }
}
