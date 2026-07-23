using System;
using System.Diagnostics;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using System.Windows.Forms;
using System.Reflection;

[assembly: AssemblyTitle("OTE-RAG Setup")]
[assembly: AssemblyProduct("OTE-RAG")]
[assembly: AssemblyCompany("OTE-RAG")]
[assembly: AssemblyVersion("1.0.0.0")]
[assembly: AssemblyFileVersion("1.0.0.0")]

namespace OteRagSetup
{
    internal sealed class PackageInfo
    {
        internal string ZipPath;
        internal string ExpectedHash;
        internal string PackageName;
    }

    internal static class PackageLocator
    {
        internal static PackageInfo Find()
        {
            string baseDir = AppDomain.CurrentDomain.BaseDirectory;
            string[] zips = Directory.GetFiles(
                baseDir,
                "OTE-RAG-win64-v*.zip",
                SearchOption.TopDirectoryOnly
            );

            if (zips.Length != 1)
            {
                throw new InvalidOperationException(
                    "Setup.exe \u3068\u540c\u3058\u5834\u6240\u306b OTE-RAG-win64-v*.zip \u30921\u3064\u3060\u3051\u7f6e\u3044\u3066\u304f\u3060\u3055\u3044\u3002"
                );
            }

            string zipPath = zips[0];
            string shaPath = zipPath + ".sha256";
            if (!File.Exists(shaPath))
            {
                throw new FileNotFoundException(
                    "SHA-256 \u306e\u7167\u5408\u30d5\u30a1\u30a4\u30eb\u304c\u898b\u3064\u304b\u308a\u307e\u305b\u3093: " + Path.GetFileName(shaPath)
                );
            }

            string firstLine = File.ReadLines(shaPath).FirstOrDefault() ?? "";
            Match match = Regex.Match(firstLine, @"\b[0-9a-fA-F]{64}\b");
            if (!match.Success)
            {
                throw new InvalidDataException(
                    "SHA-256 \u306e\u7167\u5408\u30d5\u30a1\u30a4\u30eb\u306e\u5f62\u5f0f\u304c\u6b63\u3057\u304f\u3042\u308a\u307e\u305b\u3093: " + Path.GetFileName(shaPath)
                );
            }

            return new PackageInfo
            {
                ZipPath = zipPath,
                ExpectedHash = match.Value.ToLowerInvariant(),
                PackageName = Path.GetFileNameWithoutExtension(zipPath)
            };
        }

        internal static string ComputeSha256(string path, Action<int> progress)
        {
            const int BufferSize = 4 * 1024 * 1024;
            byte[] buffer = new byte[BufferSize];
            long total = new FileInfo(path).Length;
            long readTotal = 0;
            int lastPercent = -1;

            using (FileStream stream = new FileStream(
                path,
                FileMode.Open,
                FileAccess.Read,
                FileShare.Read,
                BufferSize,
                FileOptions.SequentialScan))
            using (SHA256 sha = SHA256.Create())
            {
                int read;
                while ((read = stream.Read(buffer, 0, buffer.Length)) > 0)
                {
                    sha.TransformBlock(buffer, 0, read, buffer, 0);
                    readTotal += read;
                    int percent = total == 0 ? 100 : (int)(readTotal * 100L / total);
                    if (percent != lastPercent)
                    {
                        lastPercent = percent;
                        if (progress != null) progress(percent);
                    }
                }

                sha.TransformFinalBlock(new byte[0], 0, 0);
                return BitConverter.ToString(sha.Hash).Replace("-", "").ToLowerInvariant();
            }
        }
    }

    internal static class Program
    {
        [STAThread]
        private static int Main(string[] args)
        {
            if (args.Length == 1 &&
                string.Equals(args[0], "--verify-only", StringComparison.OrdinalIgnoreCase))
            {
                return VerifyOnly();
            }

            if (!IsAdministrator())
            {
                try
                {
                    ProcessStartInfo elevate = new ProcessStartInfo
                    {
                        FileName = Application.ExecutablePath,
                        UseShellExecute = true,
                        Verb = "runas",
                        WorkingDirectory = AppDomain.CurrentDomain.BaseDirectory
                    };
                    Process.Start(elevate);
                    return 0;
                }
                catch (Exception ex)
                {
                    MessageBox.Show(
                        "\u7ba1\u7406\u8005\u6a29\u9650\u304c\u5fc5\u8981\u3067\u3059\u3002\r\n\r\n" + ex.Message,
                        "OTE-RAG Setup",
                        MessageBoxButtons.OK,
                        MessageBoxIcon.Error
                    );
                    return 1;
                }
            }

            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new SetupForm());
            return 0;
        }

        private static bool IsAdministrator()
        {
            WindowsIdentity identity = WindowsIdentity.GetCurrent();
            WindowsPrincipal principal = new WindowsPrincipal(identity);
            return principal.IsInRole(WindowsBuiltInRole.Administrator);
        }

        private static int VerifyOnly()
        {
            string logPath = Path.Combine(Path.GetTempPath(), "OTE-RAG-Setup-verify.log");
            try
            {
                PackageInfo package = PackageLocator.Find();
                string actual = PackageLocator.ComputeSha256(package.ZipPath, null);
                bool ok = string.Equals(
                    actual,
                    package.ExpectedHash,
                    StringComparison.OrdinalIgnoreCase
                );
                File.WriteAllText(
                    logPath,
                    "zip=" + package.ZipPath + Environment.NewLine +
                    "expected=" + package.ExpectedHash + Environment.NewLine +
                    "actual=" + actual + Environment.NewLine +
                    "result=" + (ok ? "PASS" : "FAIL") + Environment.NewLine,
                    Encoding.ASCII
                );
                return ok ? 0 : 2;
            }
            catch (Exception ex)
            {
                File.WriteAllText(
                    logPath,
                    "result=ERROR" + Environment.NewLine + ex,
                    Encoding.UTF8
                );
                return 1;
            }
        }
    }

    internal sealed class SetupForm : Form
    {
        private readonly TextBox installRoot;
        private readonly NumericUpDown serverPort;
        private readonly TextBox logBox;
        private readonly ProgressBar progress;
        private readonly Button installButton;
        private readonly Button browseButton;
        private readonly Label packageLabel;
        private readonly string logPath;
        private bool busy;

        internal SetupForm()
        {
            Text = "OTE-RAG Setup";
            Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath);
            ClientSize = new Size(760, 570);
            MinimumSize = new Size(760, 570);
            StartPosition = FormStartPosition.CenterScreen;
            Font = new Font("Yu Gothic UI", 9F);
            MaximizeBox = false;
            FormClosing += delegate(object sender, FormClosingEventArgs e)
            {
                if (!busy) return;
                e.Cancel = true;
                MessageBox.Show(
                    "\u30a4\u30f3\u30b9\u30c8\u30fc\u30eb\u4e2d\u306f\u3053\u306e\u753b\u9762\u3092\u9589\u3058\u3089\u308c\u307e\u305b\u3093\u3002\r\n\u5b8c\u4e86\u307e\u3067\u304a\u5f85\u3061\u304f\u3060\u3055\u3044\u3002",
                    "OTE-RAG Setup",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Information
                );
            };




            string logDir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
                "OTE-RAG",
                "InstallerLogs"
            );
            Directory.CreateDirectory(logDir);
            logPath = Path.Combine(
                logDir,
                "setup-" + DateTime.Now.ToString("yyyyMMdd-HHmmss", CultureInfo.InvariantCulture) + ".log"
            );

            Label heading = new Label
            {
                Text = "OTE-RAG \u30bb\u30c3\u30c8\u30a2\u30c3\u30d7",
                Font = new Font("Yu Gothic UI", 18F, FontStyle.Bold),
                AutoSize = true,
                Location = new Point(24, 20)
            };

            Label description = new Label
            {
                Text = "\u30aa\u30d5\u30e9\u30a4\u30f3\u914d\u5e03\u30d1\u30c3\u30b1\u30fc\u30b8\u3092\u691c\u8a3c\u3057\u3001Windows\u30b5\u30fc\u30d3\u30b9\u3068\u3057\u3066\u30a4\u30f3\u30b9\u30c8\u30fc\u30eb\u3057\u307e\u3059\u3002",
                AutoSize = true,
                Location = new Point(27, 62)
            };

            Label packageCaption = new Label
            {
                Text = "\u914d\u5e03\u30d1\u30c3\u30b1\u30fc\u30b8",
                AutoSize = true,
                Location = new Point(27, 100)
            };
            packageLabel = new Label
            {
                AutoEllipsis = true,
                BorderStyle = BorderStyle.FixedSingle,
                Location = new Point(150, 95),
                Size = new Size(580, 25),
                TextAlign = ContentAlignment.MiddleLeft
            };

            Label rootCaption = new Label
            {
                Text = "\u30a4\u30f3\u30b9\u30c8\u30fc\u30eb\u5148",
                AutoSize = true,
                Location = new Point(27, 140)
            };
            installRoot = new TextBox
            {
                Location = new Point(150, 135),
                Size = new Size(490, 25),
                Text = @"C:\LocalRAG"
            };
            browseButton = new Button
            {
                Text = "\u53c2\u7167...",
                Location = new Point(650, 134),
                Size = new Size(80, 27)
            };
            browseButton.Click += BrowseClicked;

            Label portCaption = new Label
            {
                Text = "\u753b\u9762\u30dd\u30fc\u30c8",
                AutoSize = true,
                Location = new Point(27, 180)
            };
            serverPort = new NumericUpDown
            {
                Location = new Point(150, 175),
                Size = new Size(100, 25),
                Minimum = 1024,
                Maximum = 65535,
                Value = 3001
            };

            progress = new ProgressBar
            {
                Location = new Point(27, 220),
                Size = new Size(703, 20),
                Minimum = 0,
                Maximum = 100
            };

            logBox = new TextBox
            {
                Location = new Point(27, 255),
                Size = new Size(703, 245),
                Multiline = true,
                ReadOnly = true,
                ScrollBars = ScrollBars.Vertical,
                Font = new Font("Consolas", 9F),
                BackColor = Color.White
            };

            installButton = new Button
            {
                Text = "\u30a4\u30f3\u30b9\u30c8\u30fc\u30eb",
                Location = new Point(590, 515),
                Size = new Size(140, 34)
            };
            installButton.Click += InstallClicked;

            Controls.AddRange(new Control[]
            {
                heading, description, packageCaption, packageLabel,
                rootCaption, installRoot, browseButton,
                portCaption, serverPort, progress, logBox, installButton
            });

            Shown += delegate
            {
                try
                {
                    PackageInfo package = PackageLocator.Find();
                    packageLabel.Text = Path.GetFileName(package.ZipPath);
                    AppendLog("Package: " + package.ZipPath);
                    AppendLog("Installer log: " + logPath);
                }
                catch (Exception ex)
                {
                    packageLabel.Text = "\u914d\u5e03ZIP\u3092\u78ba\u8a8d\u3067\u304d\u307e\u305b\u3093";
                    AppendLog("ERROR: " + ex.Message);
                }
            };
        }

        private void BrowseClicked(object sender, EventArgs e)
        {
            using (FolderBrowserDialog dialog = new FolderBrowserDialog())
            {
                dialog.Description = "OTE-RAG \u306e\u30a4\u30f3\u30b9\u30c8\u30fc\u30eb\u5148\u3092\u9078\u629e";
                dialog.SelectedPath = installRoot.Text;
                if (dialog.ShowDialog(this) == DialogResult.OK)
                {
                    installRoot.Text = dialog.SelectedPath;
                }
            }
        }

        private async void InstallClicked(object sender, EventArgs e)
        {
            // --- \u5165\u529b\u691c\u8a3c\u306f\u5148\u306b\u884c\u3046(\u3053\u306e\u6bb5\u968e\u3067\u306f\u30dc\u30bf\u30f3\u6709\u52b9\u306e\u307e\u307e\u3002\u8aa4\u308a\u306f\u305d\u306e\u5834\u3067\u76f4\u305b\u308b) ---
            string rawTarget = installRoot.Text.Trim();
            string target;
            try
            {
                if (string.IsNullOrWhiteSpace(rawTarget))
                {
                    throw new InvalidOperationException(
                        "\u30a4\u30f3\u30b9\u30c8\u30fc\u30eb\u5148\u3092\u6307\u5b9a\u3057\u3066\u304f\u3060\u3055\u3044\u3002"
                    );
                }

                target = Path.GetFullPath(rawTarget).TrimEnd(
                    Path.DirectorySeparatorChar,
                    Path.AltDirectorySeparatorChar
                );
                string driveRoot = Path.GetPathRoot(target).TrimEnd(
                    Path.DirectorySeparatorChar,
                    Path.AltDirectorySeparatorChar
                );
                if (!Path.IsPathRooted(target) || target.StartsWith(@"\\"))
                {
                    throw new InvalidOperationException(
                        "\u30a4\u30f3\u30b9\u30c8\u30fc\u30eb\u5148\u306bWindows\u306e\u30ed\u30fc\u30ab\u30eb\u30d1\u30b9\u3092\u6307\u5b9a\u3057\u3066\u304f\u3060\u3055\u3044\u3002"
                    );
                }
                if (string.Equals(target, driveRoot, StringComparison.OrdinalIgnoreCase))
                {
                    throw new InvalidOperationException(
                        "\u30c9\u30e9\u30a4\u30d6\u76f4\u4e0b\u306f\u6307\u5b9a\u3067\u304d\u307e\u305b\u3093\u3002"
                    );
                }
            }
            catch (Exception vex)
            {
                MessageBox.Show(
                    vex.Message,
                    "OTE-RAG Setup",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Warning
                );
                return;
            }

            int port = Decimal.ToInt32(serverPort.Value);

            string workRoot = null;
            busy = true;
            installButton.Enabled = false;
            browseButton.Enabled = false;
            installRoot.Enabled = false;
            serverPort.Enabled = false;

            try
            {
                PackageInfo package = PackageLocator.Find();

                AppendLog("Verifying SHA-256...");
                progress.Style = ProgressBarStyle.Blocks;
                progress.Value = 0;
                string actualHash = await Task.Run(
                    () => PackageLocator.ComputeSha256(
                        package.ZipPath,
                        value => BeginInvoke(new Action<int>(SetProgress), value)
                    )
                );
                if (!string.Equals(
                    actualHash,
                    package.ExpectedHash,
                    StringComparison.OrdinalIgnoreCase))
                {
                    throw new InvalidDataException(
                        "SHA-256 \u304c\u4e00\u81f4\u3057\u307e\u305b\u3093\u3002\u914d\u5e03\u30d1\u30c3\u30b1\u30fc\u30b8\u304c\u4e0d\u5b8c\u5168\u304b\u7834\u640d\u3057\u3066\u3044\u307e\u3059\u3002"
                    );
                }
                AppendLog("SHA-256: PASS");

                string systemDrive = Path.GetPathRoot(Environment.SystemDirectory);
                workRoot = Path.Combine(
                    systemDrive,
                    "OTR",
                    DateTime.Now.ToString("yyyyMMdd-HHmmss", CultureInfo.InvariantCulture)
                );
                Directory.CreateDirectory(workRoot);

                string tarPath = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.System),
                    "tar.exe"
                );
                if (!File.Exists(tarPath))
                {
                    throw new FileNotFoundException("Windows \u306e tar.exe \u304c\u898b\u3064\u304b\u308a\u307e\u305b\u3093\u3067\u3057\u305f\u3002", tarPath);
                }

                AppendLog("Extracting package to: " + workRoot);
                progress.Style = ProgressBarStyle.Marquee;
                int extractExit = await RunProcessAsync(
                    tarPath,
                    "-xf " + Quote(package.ZipPath) + " -C " + Quote(workRoot)
                );
                if (extractExit != 0)
                {
                    throw new InvalidOperationException(
                        "\u30d1\u30c3\u30b1\u30fc\u30b8\u306e\u5c55\u958b\u306b\u5931\u6557\u3057\u307e\u3057\u305f(\u7d42\u4e86\u30b3\u30fc\u30c9 " + extractExit + ")\u3002"
                    );
                }

                string installer = Path.Combine(
                    workRoot,
                    package.PackageName,
                    "install.ps1"
                );
                if (!File.Exists(installer))
                {
                    throw new FileNotFoundException(
                        "\u5c55\u958b\u5f8c\u306b install.ps1 \u304c\u898b\u3064\u304b\u308a\u307e\u305b\u3093\u3067\u3057\u305f\u3002",
                        installer
                    );
                }

                AppendLog("Starting OTE-RAG installation...");
                int installExit = await RunProcessAsync(
                    "powershell.exe",
                    "-NoProfile -ExecutionPolicy Bypass -File " + Quote(installer) +
                    " -InstallRoot " + Quote(target) +
                    " -ServerPort " + port.ToString(CultureInfo.InvariantCulture)
                );
                // exit 3 = installed OK but the server startup ping timed out
                // (usually the first model load). Treat it as success, not failure.
                if (installExit != 0 && installExit != 3)
                {
                    throw new InvalidOperationException(
                        "OTE-RAG \u306e\u30a4\u30f3\u30b9\u30c8\u30fc\u30eb\u306b\u5931\u6557\u3057\u307e\u3057\u305f(\u7d42\u4e86\u30b3\u30fc\u30c9 " + installExit + ")\u3002"
                    );
                }
                bool startupTimedOut = (installExit == 3);

                progress.Style = ProgressBarStyle.Blocks;
                progress.Value = 100;
                AppendLog(startupTimedOut
                    ? "Installation completed (server startup confirmation timed out)."
                    : "Installation completed successfully.");

                try
                {
                    Directory.Delete(workRoot, true);
                    AppendLog("Temporary package files removed.");
                    workRoot = null;
                }
                catch (Exception cleanupError)
                {
                    AppendLog("WARN: temporary files could not be removed: " + cleanupError.Message);
                }

                string url = "http://localhost:" + port.ToString(CultureInfo.InvariantCulture);
                Process.Start(new ProcessStartInfo(url) { UseShellExecute = true });
                MessageBox.Show(
                    (startupTimedOut
                        ? "\u30a4\u30f3\u30b9\u30c8\u30fc\u30eb\u306f\u5b8c\u4e86\u3057\u307e\u3057\u305f\u3002\u521d\u56de\u306f\u30e2\u30c7\u30eb\u8aad\u307f\u8fbc\u307f\u306b\u6570\u5206\u304b\u304b\u308b\u3053\u3068\u304c\u3042\u308a\u307e\u3059\u3002\u6570\u5206\u5f8c\u306b\u30c7\u30b9\u30af\u30c8\u30c3\u30d7\u306e\u30a2\u30a4\u30b3\u30f3\u304b\u3089\u958b\u3044\u3066\u304f\u3060\u3055\u3044\u3002"
                        : "OTE-RAG \u306e\u30a4\u30f3\u30b9\u30c8\u30fc\u30eb\u304c\u5b8c\u4e86\u3057\u307e\u3057\u305f\u3002") + "\r\n\r\n" + url,
                    "OTE-RAG Setup",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Information
                );
            }
            catch (Exception ex)
            {
                progress.Style = ProgressBarStyle.Blocks;
                AppendLog("ERROR: " + ex);
                string detail = workRoot == null
                    ? ""
                    : "\r\n\r\n\u8abf\u67fb\u7528\u306e\u5c55\u958b\u5148:\r\n" + workRoot;
                MessageBox.Show(
                    "\u30a4\u30f3\u30b9\u30c8\u30fc\u30eb\u306b\u5931\u6557\u3057\u307e\u3057\u305f\u3002\u74b0\u5883\u306f\u81ea\u52d5\u3067\u5143\u306b\u623b\u3057\u307e\u3057\u305f\u3002\u3053\u306e\u753b\u9762\u3092\u9589\u3058\u3066\u3001\u3082\u3046\u4e00\u5ea6\u5b9f\u884c\u3057\u3066\u304f\u3060\u3055\u3044\u3002\r\n\r\n" +
                    ex.Message +
                    "\r\n\r\n\u30ed\u30b0:\r\n" + logPath +
                    detail,
                    "OTE-RAG Setup",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Error
                );
            }
            finally
            {
                // インストールを開始した後(成功・失敗どちらでも)は入力欄と実行ボタンを
                // 再有効化しない。失敗時に安易な再試行(既存インストール残存などで再び失敗)を
                // 防ぐため、ユーザーには一旦ウィンドウを閉じてもらう(閉じるボタン=×のみ有効)。
                // 入力ミスは上の事前検証で弾いており、ここに来る失敗は再試行では解決しない。
                busy = false;
            }
        }

        private async Task<int> RunProcessAsync(string fileName, string arguments)
        {
            AppendLog("> " + fileName + " " + arguments);
            Process process = new Process
            {
                StartInfo = new ProcessStartInfo
                {
                    FileName = fileName,
                    Arguments = arguments,
                    WorkingDirectory = AppDomain.CurrentDomain.BaseDirectory,
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true
                }
            };

            process.OutputDataReceived += delegate(object sender, DataReceivedEventArgs e)
            {
                if (e.Data != null) AppendLog(e.Data);
            };
            process.ErrorDataReceived += delegate(object sender, DataReceivedEventArgs e)
            {
                if (e.Data != null) AppendLog(e.Data);
            };

            if (!process.Start())
            {
                throw new InvalidOperationException("Failed to start: " + fileName);
            }
            process.BeginOutputReadLine();
            process.BeginErrorReadLine();

            int exitCode = await Task.Run(delegate
            {
                process.WaitForExit();
                return process.ExitCode;
            });
            process.Dispose();
            return exitCode;
        }

        private void SetProgress(int value)
        {
            progress.Value = Math.Max(progress.Minimum, Math.Min(progress.Maximum, value));
        }

        private void AppendLog(string message)
        {
            if (InvokeRequired)
            {
                BeginInvoke(new Action<string>(AppendLog), message);
                return;
            }

            string line = "[" + DateTime.Now.ToString("HH:mm:ss", CultureInfo.InvariantCulture) +
                          "] " + message + Environment.NewLine;
            logBox.AppendText(line);
            try
            {
                File.AppendAllText(logPath, line, Encoding.UTF8);
            }
            catch
            {
            }
        }

        private static string Quote(string value)
        {
            return "\"" + value.Replace("\"", "\\\"") + "\"";
        }
    }
}
