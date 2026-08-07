// Atalaya - anfitrion nativo (bin\Atalaya.exe).
//
// Por que existe: el HUD es un script de PowerShell, asi que hasta ahora el
// proceso visible para Windows era "Windows PowerShell". Este ejecutable
// hospeda el mismo script DENTRO de su propio proceso (runspace de PowerShell
// en el hilo STA principal), de modo que el Administrador de tareas, la barra
// de tareas y las notificaciones ven una aplicacion llamada "Atalaya" con su
// propio icono.
//
// Se compila con el csc.exe que ya viene con Windows (.NET Framework 4.x);
// no hace falta instalar ningun SDK. Ver tools\build-host.ps1.
//
// Modos:
//   Atalaya.exe                    lanzador: hub + HUD (equivale a atalaya.cmd)
//   Atalaya.exe --hud              hospeda scripts\hud.ps1 en ESTE proceso
//   Atalaya.exe --panel            lanzador y abre el panel
//   Atalaya.exe --install-shortcut crea los accesos directos (Inicio/Startup)
//   Atalaya.exe --remove-shortcut  los retira

using System;
using System.Collections.Generic;
using System.IO;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

[assembly: AssemblyTitle("Atalaya")]
[assembly: AssemblyDescription("Monitor de sesiones de agentes de IA")]
[assembly: AssemblyProduct("Atalaya")]
[assembly: AssemblyCompany("Atalaya")]
[assembly: AssemblyCopyright("MIT")]

namespace Atalaya
{
    internal static class Program
    {
        // Identidad de aplicacion ante Windows (AppUserModelID). Es lo que
        // agrupa las ventanas en la barra de tareas y lo que hace que los
        // toasts digan "Atalaya" en vez de "Windows PowerShell". Debe ser
        // IDENTICO aqui y en el acceso directo del menu Inicio.
        public const string AppId = "Atalaya.Monitor";

        [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
        private static extern void SetCurrentProcessExplicitAppUserModelID(
            [MarshalAs(UnmanagedType.LPWStr)] string appID);

        // Compilamos como /target:winexe para que el HUD no arrastre una
        // ventana de consola negra. El precio es que los modos de consola
        // (--install-shortcut) tampoco escribirian nada visible; engancharse a
        // la consola del proceso padre devuelve esa salida a la terminal.
        [DllImport("kernel32.dll")]
        private static extern bool AttachConsole(int processId);

        [STAThread]
        private static int Main(string[] args)
        {
            try { SetCurrentProcessExplicitAppUserModelID(AppId); }
            catch { /* Windows antiguo: sin identidad explicita, seguimos */ }

            string exePath = Assembly.GetExecutingAssembly().Location;
            // El exe vive en <repo>\bin\Atalaya.exe
            string repoRoot = Path.GetDirectoryName(Path.GetDirectoryName(exePath));

            string mode = args.Length > 0 ? args[0].ToLowerInvariant() : "";
            switch (mode)
            {
                case "--install-shortcut":
                    try { AttachConsole(-1); } catch { }
                    return Shortcuts.Install(repoRoot, exePath, args);
                case "--remove-shortcut":
                    try { AttachConsole(-1); } catch { }
                    return Shortcuts.Remove();
                case "--hud":
                    return RunScript(repoRoot, Path.Combine(repoRoot, @"scripts\hud.ps1"), new string[0]);
                case "--run":
                    // Diagnostico: hospeda un .ps1 cualquiera con esta misma
                    // identidad de aplicacion (util para reproducir problemas
                    // que solo aparecen dentro del anfitrion).
                    if (args.Length < 2) { Log("--run necesita la ruta de un script"); return 2; }
                    string[] rest = new string[args.Length - 2];
                    Array.Copy(args, 2, rest, 0, rest.Length);
                    return RunScript(repoRoot, args[1], rest);
                case "--panel":
                    return RunScript(repoRoot, Path.Combine(repoRoot, "atalaya.ps1"), new[] { "-Panel" });
                default:
                    return RunScript(repoRoot, Path.Combine(repoRoot, "atalaya.ps1"), args);
            }
        }

        private static void Log(string message)
        {
            try
            {
                string dir = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".atalaya");
                Directory.CreateDirectory(dir);
                File.AppendAllText(Path.Combine(dir, "hub.log"),
                    DateTime.Now.ToString("o") + " Atalaya.exe: " + message + Environment.NewLine,
                    Encoding.UTF8);
            }
            catch { }
        }

        // Ejecuta un .ps1 en un runspace propio. Claves:
        //  - UseCurrentThread + [STAThread]: el script corre en el hilo STA
        //    principal, requisito de WPF (ShowDialog y su bucle de mensajes).
        //  - Bypass de ExecutionPolicy solo para este proceso; no toca la
        //    politica de la maquina ni la del usuario.
        //  - AddCommand(ruta) en vez de AddScript(texto): asi $PSScriptRoot
        //    queda bien definido dentro del script.
        private static int RunScript(string repoRoot, string scriptPath, string[] scriptArgs)
        {
            if (!File.Exists(scriptPath))
            {
                Log("no encuentro el script: " + scriptPath);
                return 2;
            }
            try
            {
                InitialSessionState iss = InitialSessionState.CreateDefault();
                iss.ExecutionPolicy = Microsoft.PowerShell.ExecutionPolicy.Bypass;
                iss.ApartmentState = ApartmentState.STA;
                iss.ThreadOptions = PSThreadOptions.UseCurrentThread;

                using (Runspace rs = RunspaceFactory.CreateRunspace(iss))
                {
                    rs.Open();
                    rs.SessionStateProxy.Path.SetLocation(repoRoot);
                    using (PowerShell ps = PowerShell.Create())
                    {
                        ps.Runspace = rs;
                        ps.AddCommand(scriptPath);
                        foreach (string a in scriptArgs)
                        {
                            if (a.StartsWith("-")) ps.AddParameter(a.TrimStart('-'));
                            else ps.AddArgument(a);
                        }
                        ps.Invoke();
                        foreach (ErrorRecord err in ps.Streams.Error)
                            Log("error de " + Path.GetFileName(scriptPath) + ": " + err);
                    }
                }
                return 0;
            }
            catch (Exception ex)
            {
                Log("fallo hospedando " + Path.GetFileName(scriptPath) + ": " + ex);
                return 1;
            }
        }
    }

    // --- Accesos directos ----------------------------------------------------
    // Se crean desde aqui, y no desde PowerShell, porque hay que grabar en el
    // .lnk la propiedad System.AppUserModel.ID: sin ella Windows no relaciona
    // el proceso con el acceso directo y las notificaciones vuelven a salir a
    // nombre de PowerShell. WScript.Shell (lo que usa PowerShell) no sabe
    // escribir esa propiedad.
    internal static class Shortcuts
    {
        public static int Install(string repoRoot, string exePath, string[] args)
        {
            bool autostart = Array.IndexOf(args, "--autostart") >= 0;
            string icon = Path.Combine(repoRoot, @"assets\atalaya.ico");
            string startMenu = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                @"Microsoft\Windows\Start Menu\Programs\Atalaya.lnk");

            Create(startMenu, exePath, "", repoRoot, icon,
                   "Atalaya - monitor de sesiones de agentes", Program.AppId);
            Console.WriteLine("[+] Menu Inicio: " + startMenu);

            if (autostart)
            {
                string startup = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.Startup), "Atalaya.lnk");
                Create(startup, exePath, "", repoRoot, icon,
                       "Atalaya - monitor de sesiones de agentes", Program.AppId);
                Console.WriteLine("[+] Autoarranque: " + startup);
            }
            return 0;
        }

        public static int Remove()
        {
            string startMenu = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                @"Microsoft\Windows\Start Menu\Programs\Atalaya.lnk");
            if (File.Exists(startMenu)) { File.Delete(startMenu); Console.WriteLine("[+] Acceso directo del menu Inicio retirado"); }
            else Console.WriteLine("[-] Menu Inicio: no habia acceso directo");
            return 0;
        }

        public static void Create(string lnkPath, string target, string arguments,
                                  string workDir, string iconPath, string description, string appId)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(lnkPath));
            var link = (IShellLinkW)new CShellLink();
            link.SetPath(target);
            link.SetArguments(arguments);
            link.SetWorkingDirectory(workDir);
            link.SetDescription(description);
            if (File.Exists(iconPath)) link.SetIconLocation(iconPath, 0);

            var store = (IPropertyStore)link;
            var pkey = PropertyKey.AppUserModelId;
            using (var pv = PropVariant.FromString(appId))
            {
                store.SetValue(ref pkey, pv);
                store.Commit();
            }

            ((IPersistFile)link).Save(lnkPath, true);
            Marshal.ReleaseComObject(link);
        }
    }

    // --- Interop COM del shell ----------------------------------------------

    [ComImport, Guid("00021401-0000-0000-C000-000000000046")]
    internal class CShellLink { }

    [ComImport, Guid("000214F9-0000-0000-C000-000000000046"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IShellLinkW
    {
        void GetPath([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder file, int maxPath, IntPtr fd, int flags);
        void GetIDList(out IntPtr pidl);
        void SetIDList(IntPtr pidl);
        void GetDescription([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder name, int maxName);
        void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string name);
        void GetWorkingDirectory([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder dir, int maxPath);
        void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string dir);
        void GetArguments([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder args, int maxArgs);
        void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string args);
        void GetHotkey(out short hotkey);
        void SetHotkey(short hotkey);
        void GetShowCmd(out int showCmd);
        void SetShowCmd(int showCmd);
        void GetIconLocation([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder iconPath, int iconPathLen, out int iconIndex);
        void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string iconPath, int iconIndex);
        void SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string relPath, int reserved);
        void Resolve(IntPtr hwnd, int flags);
        void SetPath([MarshalAs(UnmanagedType.LPWStr)] string file);
    }

    [ComImport, Guid("0000010b-0000-0000-C000-000000000046"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IPersistFile
    {
        void GetClassID(out Guid classId);
        [PreserveSig] int IsDirty();
        void Load([MarshalAs(UnmanagedType.LPWStr)] string fileName, uint mode);
        void Save([MarshalAs(UnmanagedType.LPWStr)] string fileName, [MarshalAs(UnmanagedType.Bool)] bool remember);
        void SaveCompleted([MarshalAs(UnmanagedType.LPWStr)] string fileName);
        void GetCurFile([MarshalAs(UnmanagedType.LPWStr)] out string fileName);
    }

    [ComImport, Guid("886d8eeb-8cf2-4446-8d02-cdba1dbdcf99"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IPropertyStore
    {
        void GetCount(out uint count);
        void GetAt(uint index, out PropertyKey key);
        void GetValue(ref PropertyKey key, [In, Out] PropVariant value);
        void SetValue(ref PropertyKey key, [In] PropVariant value);
        void Commit();
    }

    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    internal struct PropertyKey
    {
        private Guid formatId;
        private int propertyId;

        public PropertyKey(Guid formatId, int propertyId)
        {
            this.formatId = formatId;
            this.propertyId = propertyId;
        }

        // PKEY_AppUserModel_ID
        public static PropertyKey AppUserModelId
        {
            get { return new PropertyKey(new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"), 5); }
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    internal sealed class PropVariant : IDisposable
    {
        private ushort valueType;
        private ushort reserved1, reserved2, reserved3;
        private IntPtr pointerValue;
        private IntPtr pointerValue2;

        [DllImport("ole32.dll")]
        private static extern int PropVariantClear(PropVariant pvar);

        public static PropVariant FromString(string value)
        {
            var pv = new PropVariant();
            pv.valueType = 31; // VT_LPWSTR
            pv.pointerValue = Marshal.StringToCoTaskMemUni(value);
            return pv;
        }

        public void Dispose()
        {
            PropVariantClear(this);
            GC.SuppressFinalize(this);
        }

        ~PropVariant() { Dispose(); }
    }
}
