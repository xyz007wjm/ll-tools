using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Windows.Forms;

namespace QingZhangLauncher
{
    internal static class Program
    {
        // 每次重新打包（脚本内容有变化）时请递增此版本号，否则已解压的旧脚本不会被刷新
        private const string Version = "1.2.2";

        private static readonly string[][] Files =
        {
            new[] { "core_ps1",        "core.ps1" },
            new[] { "winguard_ps1",    "WinGuard.ps1" },
            new[] { "cli_ps1",         "cli.ps1" },
            new[] { "watchdog_ps1",    "watchdog.ps1" },
            new[] { "selfcheck_ps1",   "selfcheck.ps1" },
            new[] { "start_gui_bat",   "start-gui.bat" },
            new[] { "restore_all_bat", "restore-all.bat" },
            new[] { "uninstall_bat",   "uninstall.bat" }
        };

        [STAThread]
        private static int Main()
        {
            string appDir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
                "轻账win功能工具箱", "app");
            string marker = Path.Combine(appDir, "version.txt");
            try
            {
                if (!File.Exists(marker) || File.ReadAllText(marker).Trim() != Version)
                {
                    Directory.CreateDirectory(appDir);
                    Assembly asm = Assembly.GetExecutingAssembly();
                    foreach (string[] pair in Files)
                    {
                        using (Stream src = asm.GetManifestResourceStream(pair[0]))
                        {
                            if (src == null) throw new FileNotFoundException("缺少内嵌资源：" + pair[0]);
                            using (FileStream dst = File.Create(Path.Combine(appDir, pair[1])))
                                src.CopyTo(dst);
                        }
                    }
                    File.WriteAllText(marker, Version);
                }
            }
            catch (Exception ex)
            {
                MessageBox.Show("初始化失败：" + ex.Message, "轻账win功能工具箱",
                    MessageBoxButtons.OK, MessageBoxIcon.Error);
                return 1;
            }
            try
            {
                var psi = new ProcessStartInfo
                {
                    FileName = "powershell.exe",
                    Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \""
                        + Path.Combine(appDir, "WinGuard.ps1") + "\"",
                    UseShellExecute = true,
                    WindowStyle = ProcessWindowStyle.Hidden
                };
                Process.Start(psi);
            }
            catch (Exception ex)
            {
                MessageBox.Show("启动失败：" + ex.Message, "轻账win功能工具箱",
                    MessageBoxButtons.OK, MessageBoxIcon.Error);
                return 1;
            }
            return 0;
        }
    }
}
