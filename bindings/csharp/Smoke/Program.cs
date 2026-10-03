using System;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text.Json;
using ArkTrace.Native;

internal static class Program
{
    private static void Check(bool condition) { if (!condition) throw new InvalidOperationException("C ABI contract mismatch"); }
    private static unsafe int Main(string[] args)
    {
        Check(args.Length == 2 && IntPtr.Size == 8);
        IntPtr library = NativeLibrary.Load(args[0]);
        NativeLibrary.SetDllImportResolver(typeof(NativeMethods).Assembly, (_, _, _) => library);
        try
        {
            using var layouts = JsonDocument.Parse(System.IO.File.ReadAllBytes(args[1]));
            int fields = 0;
            foreach (var layout in layouts.RootElement.EnumerateArray())
            {
                var type = typeof(AbiIdentity).Assembly.GetType("ArkTrace.Native." + layout.GetProperty("name").GetString())!;
                Check(Marshal.SizeOf(type) == layout.GetProperty("size").GetInt32());
                foreach (var field in layout.GetProperty("offsets").EnumerateObject())
                { Check(Marshal.OffsetOf(type, field.Name).ToInt64() == field.Value.GetInt64()); fields++; }
            }
            AbiIdentity identity = default;
            Check(NativeMethods.arktrace_abi_identity(&identity, (ulong)sizeof(AbiIdentity)) == NativeMethods.STATUS_OK);
            Check(identity.abi_version == NativeMethods.ABI_VERSION);
            Check(Convert.ToHexString(new ReadOnlySpan<byte>(identity.contract_digest, 32)).ToLowerInvariant() == NativeMethods.CONTRACT_DIGEST);
            Check(NativeMethods.arktrace_abi_identity(null, (ulong)sizeof(AbiIdentity)) == NativeMethods.STATUS_INVALID_BUFFER);
            Check(NativeMethods.arktrace_abi_identity(&identity, 0) == NativeMethods.STATUS_INVALID_BUFFER);
            Check(NativeMethods.arktrace_engine_drain(ulong.MaxValue) == NativeMethods.STATUS_INVALID_HANDLE);
            Check(NativeMethods.arktrace_result_release(ulong.MaxValue) == NativeMethods.STATUS_INVALID_HANDLE);
            Console.WriteLine(JsonSerializer.Serialize(new { consumer = "C# LibraryImport", records = layouts.RootElement.GetArrayLength(), fields, abiVersion = identity.abi_version, capabilities = identity.capabilities, nativeEngineAcceptance = false }));
        }
        finally { NativeLibrary.Free(library); }
        return 0;
    }
}
