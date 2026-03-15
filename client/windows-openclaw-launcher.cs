using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Security.Principal;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Windows.Forms;

internal static class Program
{
    private const int StartTimeoutSeconds = 360;
    private const int RepairTimeoutSeconds = 600;
    private const int UpdateTimeoutSeconds = 3600;
    private const string UiPrefix = "OPENCLAW_UI ";
    private const string WindowTitleSignatureSuffix = " by RZX000";
    private const string RepositoryUrl = "https://github.com/RZX00/openclaw-windows-installer";

    private sealed class LicenseGateResult
    {
        public bool Allowed;
        public int ExitCode;
        public string Message;
    }

    [STAThread]
    private static int Main(string[] args)
    {
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);

        MaintenanceMode mode = ResolveMode(args);
        string installRoot = ResolveInstallRoot();
        string statePath = ResolveStatePath(installRoot);
        string locale = ResolveLocale(statePath);

        try
        {
            if (!IsAdministrator())
            {
                return ElevateSelf(args, mode, locale);
            }

            string logPath = CreateLogPath(mode, installRoot);
            string supportScriptPath = ResolveSupportScriptPath(installRoot, statePath);
            string runtimeControlMode = ResolveRuntimeControlMode(statePath);
            bool enforceLicenseGate = false;
            string licenseHelperPath = null;
            Log(logPath, T(locale, "启动维护窗口。", "Launcher started."));
            Log(logPath, T(locale, "运行模式：", "Mode: ") + GetModeDisplayName(mode, locale));
            Log(logPath, T(locale, "安装根目录：", "Install root: ") + (installRoot ?? T(locale, "未找到", "missing")));
            Log(logPath, T(locale, "维护脚本：", "Support script: ") + (supportScriptPath ?? T(locale, "未找到", "missing")));
            Log(logPath, T(locale, "运行时控制模式：", "Runtime control mode: ") + runtimeControlMode);
            if (enforceLicenseGate)
            {
                Log(logPath, T(locale, "授权组件：", "License helper: ") + (licenseHelperPath ?? T(locale, "未找到", "missing")));
                LicenseGateResult licenseGate = EnsureLicenseAccess(mode, locale, logPath, licenseHelperPath);
                if (!licenseGate.Allowed)
                {
                    if (!string.IsNullOrWhiteSpace(licenseGate.Message))
                    {
                        MessageBox.Show(
                            licenseGate.Message,
                            GetWindowTitle(mode, locale),
                            MessageBoxButtons.OK,
                            MessageBoxIcon.Warning);
                    }

                    return licenseGate.ExitCode;
                }
            }
            else
            {
                Log(logPath, T(locale, "当前包使用标准启动模式。", "Using the standard startup flow."));
            }

            MaintenanceWindow window = new MaintenanceWindow(mode, locale, supportScriptPath, logPath, installRoot);
            Application.Run(window);
            return window.ExitCode;
        }
        catch (Exception ex)
        {
            MessageBox.Show(
                T(locale, "启动 OpenClaw 维护窗口失败：", "Failed to start OpenClaw maintenance: ") + ex.Message,
                GetWindowTitle(mode, locale),
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
            return 1;
        }
    }

    private static bool IsAdministrator()
    {
        try
        {
            WindowsIdentity identity = WindowsIdentity.GetCurrent();
            WindowsPrincipal principal = new WindowsPrincipal(identity);
            return principal.IsInRole(WindowsBuiltInRole.Administrator);
        }
        catch
        {
            return false;
        }
    }

    private static int ElevateSelf(string[] args, MaintenanceMode mode, string locale)
    {
        string exePath = Process.GetCurrentProcess().MainModule.FileName;
        string argumentString = BuildArgumentString(args);

        try
        {
            ProcessStartInfo startInfo = new ProcessStartInfo(exePath, argumentString)
            {
                UseShellExecute = true,
                Verb = "runas"
            };
            Process.Start(startInfo);
            return 0;
        }
        catch (System.ComponentModel.Win32Exception ex)
        {
            if ((uint)ex.NativeErrorCode != 1223)
            {
                throw;
            }

            MessageBox.Show(
                T(locale, "你取消了管理员授权，本次维护没有执行。", "Administrator elevation was cancelled, so maintenance did not run."),
                GetWindowTitle(mode, locale),
                MessageBoxButtons.OK,
                MessageBoxIcon.Warning);
            return 1223;
        }
    }

    private static string BuildArgumentString(string[] args)
    {
        if (args == null || args.Length == 0)
        {
            return string.Empty;
        }

        return string.Join(" ", args.Select(QuoteArgumentForShell));
    }

    private static string QuoteArgumentForShell(string value)
    {
        if (string.IsNullOrEmpty(value))
        {
            return "\"\"";
        }

        if (value.IndexOfAny(new[] { ' ', '\t', '"' }) < 0)
        {
            return value;
        }

        return "\"" + value.Replace("\"", "\\\"") + "\"";
    }

    private static MaintenanceMode ResolveMode(string[] args)
    {
        if (args != null)
        {
            for (int index = 0; index < args.Length - 1; index++)
            {
                if (!string.Equals(args[index], "--mode", StringComparison.OrdinalIgnoreCase))
                {
                    continue;
                }

                return ParseMode(args[index + 1]);
            }
        }

        string exeName = Path.GetFileNameWithoutExtension(Process.GetCurrentProcess().MainModule.FileName) ?? string.Empty;
        return ParseMode(exeName);
    }

    private static MaintenanceMode ParseMode(string rawValue)
    {
        string text = (rawValue ?? string.Empty).Trim().ToLowerInvariant();
        if (text.Contains("repair") || text.Contains("fix") || text.Contains("\u4fee\u590d"))
        {
            return MaintenanceMode.Repair;
        }

        if (text.Contains("update") || text.Contains("\u66f4\u65b0"))
        {
            return MaintenanceMode.Update;
        }

        return MaintenanceMode.Start;
    }

    private static void AddUniqueCandidate(List<string> candidates, string value)
    {
        if (candidates == null || string.IsNullOrWhiteSpace(value))
        {
            return;
        }

        string normalized = value.Trim();
        if (normalized.Length == 0)
        {
            return;
        }

        if (!candidates.Any(existing => string.Equals(existing, normalized, StringComparison.OrdinalIgnoreCase)))
        {
            candidates.Add(normalized);
        }
    }

    private static string ResolveInstallRootFromBasePath(string path)
    {
        if (string.IsNullOrWhiteSpace(path))
        {
            return null;
        }

        string candidate = path.Trim();
        if (File.Exists(candidate))
        {
            candidate = Path.GetDirectoryName(candidate);
        }

        if (string.IsNullOrWhiteSpace(candidate))
        {
            return null;
        }

        string leaf = Path.GetFileName(candidate.TrimEnd(Path.DirectorySeparatorChar));
        if (string.Equals(leaf, "bin", StringComparison.OrdinalIgnoreCase) ||
            string.Equals(leaf, "support", StringComparison.OrdinalIgnoreCase))
        {
            return Path.GetDirectoryName(candidate.TrimEnd(Path.DirectorySeparatorChar));
        }

        return candidate.TrimEnd(Path.DirectorySeparatorChar);
    }

    private static IEnumerable<string> GetCandidateInstallRoots()
    {
        List<string> candidates = new List<string>();
        string exeDir = AppDomain.CurrentDomain.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar);
        string commonAppData = Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData);
        string localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        string roamingAppData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);

        AddUniqueCandidate(candidates, Environment.GetEnvironmentVariable("OPENCLAW_INSTALL_ROOT"));
        AddUniqueCandidate(candidates, ResolveInstallRootFromBasePath(exeDir));
        AddUniqueCandidate(candidates, ResolveInstallRootFromBasePath(Path.GetDirectoryName(exeDir)));
        AddUniqueCandidate(candidates, Path.Combine(commonAppData, "OpenClaw"));
        AddUniqueCandidate(candidates, Path.Combine(localAppData, "OpenClaw"));
        AddUniqueCandidate(candidates, Path.Combine(roamingAppData, "OpenClaw"));

        return candidates;
    }

    private static int GetInstallRootScore(string root)
    {
        if (string.IsNullOrWhiteSpace(root) || !Directory.Exists(root))
        {
            return -1;
        }

        int score = 1;
        if (File.Exists(Path.Combine(root, "install-state.json")))
        {
            score += 30;
        }
        if (File.Exists(Path.Combine(root, "support", "OpenClaw-Maintenance.ps1")))
        {
            score += 20;
        }
        if (File.Exists(Path.Combine(root, "bin", "openclaw.cmd")))
        {
            score += 15;
        }
        if (Directory.Exists(Path.Combine(root, "bundles")))
        {
            score += 8;
        }
        if (Directory.Exists(Path.Combine(root, "source")))
        {
            score += 8;
        }
        if (Directory.Exists(Path.Combine(root, "tools")))
        {
            score += 5;
        }

        return score;
    }

    private static string ResolveInstallRoot()
    {
        string bestRoot = null;
        int bestScore = -1;
        foreach (string candidate in GetCandidateInstallRoots())
        {
            int score = GetInstallRootScore(candidate);
            if (score > bestScore)
            {
                bestScore = score;
                bestRoot = candidate;
            }
        }

        if (!string.IsNullOrWhiteSpace(bestRoot))
        {
            string statePath = ResolveStatePath(bestRoot);
            string configuredDataRoot = ResolveInstallRootFromBasePath(ReadStateValue(statePath, "dataRoot"));
            if (!string.IsNullOrWhiteSpace(configuredDataRoot) && GetInstallRootScore(configuredDataRoot) > bestScore)
            {
                return configuredDataRoot;
            }

            return bestRoot;
        }

        string commonAppData = Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData);
        return Path.Combine(commonAppData, "OpenClaw");
    }

    private static string ResolveStatePath(string installRoot)
    {
        List<string> candidates = new List<string>();
        AddUniqueCandidate(candidates, string.IsNullOrWhiteSpace(installRoot) ? null : Path.Combine(installRoot, "install-state.json"));
        foreach (string root in GetCandidateInstallRoots())
        {
            AddUniqueCandidate(candidates, Path.Combine(root, "install-state.json"));
        }

        foreach (string candidate in candidates)
        {
            if (File.Exists(candidate))
            {
                return candidate;
            }
        }

        return candidates.FirstOrDefault();
    }

    private static string ReadStateValue(string statePath, string propertyName)
    {
        try
        {
            if (string.IsNullOrWhiteSpace(statePath) || string.IsNullOrWhiteSpace(propertyName) || !File.Exists(statePath))
            {
                return null;
            }

            string content = File.ReadAllText(statePath, Encoding.UTF8);
            string pattern = "\"" + Regex.Escape(propertyName) + "\"\\s*:\\s*\"(?<value>[^\"]+)\"";
            Match match = Regex.Match(content, pattern, RegexOptions.IgnoreCase);
            if (match.Success)
            {
                string value = match.Groups["value"].Value.Trim();
                if (!string.IsNullOrWhiteSpace(value))
                {
                    return value;
                }
            }
        }
        catch
        {
        }

        return null;
    }

    private static string ResolveSupportScriptPath(string installRoot, string statePath)
    {
        string exeDir = AppDomain.CurrentDomain.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar);
        List<string> candidates = new List<string>();

        string configuredPath = ReadStateValue(statePath, "maintenanceScriptPath");
        string supportDir = ReadStateValue(statePath, "supportDir");

        AddUniqueCandidate(candidates, configuredPath);
        AddUniqueCandidate(candidates, string.IsNullOrWhiteSpace(supportDir) ? null : Path.Combine(supportDir, "OpenClaw-Maintenance.ps1"));
        AddUniqueCandidate(candidates, Path.Combine(exeDir, "OpenClaw-Maintenance.ps1"));
        AddUniqueCandidate(candidates, Path.Combine(exeDir, "support", "OpenClaw-Maintenance.ps1"));
        AddUniqueCandidate(candidates, string.IsNullOrWhiteSpace(installRoot) ? null : Path.Combine(installRoot, "support", "OpenClaw-Maintenance.ps1"));

        foreach (string root in GetCandidateInstallRoots())
        {
            AddUniqueCandidate(candidates, Path.Combine(root, "support", "OpenClaw-Maintenance.ps1"));
        }

        return candidates.FirstOrDefault(File.Exists);
    }

    private static string ResolveLicenseHelperPath(string installRoot, string statePath)
    {
        try
        {
            string exeDir = AppDomain.CurrentDomain.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar);
            List<string> candidates = new List<string>();
            string configuredPath = ReadStateValue(statePath, "licenseExecutablePath");

            AddUniqueCandidate(candidates, configuredPath);
            AddUniqueCandidate(candidates, Path.Combine(exeDir, "OpenClaw-License.exe"));
            AddUniqueCandidate(candidates, string.IsNullOrWhiteSpace(installRoot) ? null : Path.Combine(installRoot, "bin", "OpenClaw-License.exe"));

            foreach (string root in GetCandidateInstallRoots())
            {
                AddUniqueCandidate(candidates, Path.Combine(root, "bin", "OpenClaw-License.exe"));
            }

            return candidates.FirstOrDefault(value => !string.IsNullOrWhiteSpace(value) && File.Exists(value));
        }
        catch
        {
            return null;
        }
    }

    private static string ResolveLocale(string statePath)
    {
        string locale = ReadStateValue(statePath, "locale");
        return string.IsNullOrWhiteSpace(locale) ? "zh-CN" : locale;
    }

    private static string ResolveRuntimeControlMode(string statePath)
    {
        string value = ReadStateValue(statePath, "runtimeControlMode");
        return string.IsNullOrWhiteSpace(value) ? "none" : value;
    }

    private static string CreateLogPath(MaintenanceMode mode, string installRoot)
    {
        string root = string.IsNullOrWhiteSpace(installRoot)
            ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "OpenClaw", "logs")
            : Path.Combine(installRoot, "logs");
        Directory.CreateDirectory(root);
        return Path.Combine(root, "maintenance-" + mode.ToString().ToLowerInvariant() + "-" + DateTime.Now.ToString("yyyyMMdd-HHmmss") + ".log");
    }

    private static void Log(string logPath, string message)
    {
        try
        {
            string line = "[" + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "] [LAUNCHER] " + message;
            File.AppendAllText(logPath, line + Environment.NewLine, new UTF8Encoding(true));
        }
        catch
        {
        }
    }

    private static string ResolvePowerShellPath()
    {
        string systemRoot = Environment.GetEnvironmentVariable("SystemRoot");
        if (string.IsNullOrWhiteSpace(systemRoot))
        {
            systemRoot = Environment.GetEnvironmentVariable("WINDIR");
        }
        if (string.IsNullOrWhiteSpace(systemRoot))
        {
            systemRoot = @"C:\Windows";
        }

        string candidate = Path.Combine(systemRoot, "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
        if (File.Exists(candidate))
        {
            return candidate;
        }

        return "powershell.exe";
    }

    private static string BuildMergedPath()
    {
        string systemRoot = Environment.GetEnvironmentVariable("SystemRoot");
        if (string.IsNullOrWhiteSpace(systemRoot))
        {
            systemRoot = Environment.GetEnvironmentVariable("WINDIR");
        }
        if (string.IsNullOrWhiteSpace(systemRoot))
        {
            systemRoot = @"C:\Windows";
        }

        string[] candidates =
        {
            AppDomain.CurrentDomain.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar),
            Path.Combine(systemRoot, "System32"),
            systemRoot,
            Path.Combine(systemRoot, "System32", "Wbem"),
            Path.Combine(systemRoot, "System32", "WindowsPowerShell", "v1.0"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Microsoft", "WindowsApps"),
            Environment.GetEnvironmentVariable("PATH")
        };

        return string.Join(";", candidates.Where(value => !string.IsNullOrWhiteSpace(value)).Distinct(StringComparer.OrdinalIgnoreCase));
    }

    private static LicenseGateResult EnsureLicenseAccess(MaintenanceMode mode, string locale, string logPath, string licenseHelperPath)
    {
        if (string.IsNullOrWhiteSpace(licenseHelperPath) || !File.Exists(licenseHelperPath))
        {
            return new LicenseGateResult
            {
                Allowed = false,
                ExitCode = 45,
                Message = T(locale, "未找到授权组件，请先重新安装 OpenClaw。", "The license helper was not found. Please reinstall OpenClaw first.")
            };
        }

        try
        {
            string[] arguments =
            {
                "check",
                "--mode",
                mode.ToString().ToLowerInvariant(),
                "--interactive",
                "--json"
            };

            ProcessStartInfo startInfo = new ProcessStartInfo(licenseHelperPath, string.Join(" ", arguments.Select(QuoteArgumentForProcess)))
            {
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true,
                WindowStyle = ProcessWindowStyle.Hidden
            };

            try
            {
                startInfo.StandardOutputEncoding = Encoding.UTF8;
                startInfo.StandardErrorEncoding = Encoding.UTF8;
            }
            catch
            {
            }

            startInfo.EnvironmentVariables["PATH"] = BuildMergedPath();
            using (Process process = Process.Start(startInfo))
            {
                string stdout = process.StandardOutput.ReadToEnd();
                string stderr = process.StandardError.ReadToEnd();
                process.WaitForExit();
                if (process.ExitCode == 0)
                {
                    return new LicenseGateResult { Allowed = true, ExitCode = 0 };
                }

                string message = !string.IsNullOrWhiteSpace(stderr) ? stderr.Trim() : ExtractJsonMessage(stdout);
                Log(logPath, T(locale, "授权校验失败：", "License check failed: ") + (message ?? process.ExitCode.ToString()));
                return new LicenseGateResult
                {
                    Allowed = false,
                    ExitCode = process.ExitCode,
                    Message = string.IsNullOrWhiteSpace(message)
                        ? T(locale, "当前需要有效授权码才能继续。", "A valid authorization code is required to continue.")
                        : message
                };
            }
        }
        catch (Exception ex)
        {
            Log(logPath, T(locale, "授权校验异常：", "License check failed unexpectedly: ") + ex.Message);
            return new LicenseGateResult
            {
                Allowed = false,
                ExitCode = 47,
                Message = T(locale, "授权校验失败，请稍后重试。", "License validation failed unexpectedly. Try again later.")
            };
        }
    }

    private static string ExtractJsonMessage(string value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return null;
        }

        Match match = Regex.Match(value, "\"message\"\\s*:\\s*\"(?<value>[^\"]+)\"", RegexOptions.IgnoreCase);
        return match.Success ? match.Groups["value"].Value.Trim() : null;
    }

    private static int GetTimeoutSeconds(MaintenanceMode mode)
    {
        switch (mode)
        {
            case MaintenanceMode.Update:
                return UpdateTimeoutSeconds;
            case MaintenanceMode.Repair:
                return RepairTimeoutSeconds;
            default:
                return StartTimeoutSeconds;
        }
    }

    private static string QuoteArgumentForProcess(string value)
    {
        if (string.IsNullOrEmpty(value))
        {
            return "\"\"";
        }

        if (value.IndexOfAny(new[] { ' ', '\t', '"', '&', '|', '<', '>', '^', '(', ')' }) < 0)
        {
            return value;
        }

        return "\"" + value.Replace("\"", "\\\"") + "\"";
    }

    private static string GetWindowTitle(MaintenanceMode mode, string locale)
    {
        return GetModeWindowTitle(mode, locale) + WindowTitleSignatureSuffix;
    }

    private static string GetModeWindowTitle(MaintenanceMode mode, string locale)
    {
        string baseTitle;
        switch (mode)
        {
            case MaintenanceMode.Update:
                baseTitle = T(locale, "OpenClaw 一键更新", "OpenClaw Update");
                break;
            case MaintenanceMode.Repair:
                baseTitle = T(locale, "OpenClaw 一键修复", "OpenClaw Repair");
                break;
            default:
                baseTitle = T(locale, "OpenClaw 一键启动", "OpenClaw Start");
                break;
        }

        return baseTitle;
    }

    private static string GetModeDisplayName(MaintenanceMode mode, string locale)
    {
        switch (mode)
        {
            case MaintenanceMode.Update:
                return T(locale, "一键更新", "Update");
            case MaintenanceMode.Repair:
                return T(locale, "一键修复", "Repair");
            default:
                return T(locale, "一键启动", "Start");
        }
    }

    private static string BuildDefaultResultMessage(MaintenanceMode mode, int exitCode, string locale)
    {
        if (exitCode == 0)
        {
            switch (mode)
            {
                case MaintenanceMode.Update:
                    return T(locale, "更新完成，已恢复 Gateway 服务。", "OpenClaw updated the current channel and restored the gateway service.");
                case MaintenanceMode.Repair:
                    return T(locale, "已完成常见修复，请重新尝试聊天。", "OpenClaw finished the common repair steps and rechecked gateway health.");
                default:
                    return T(locale, "启动成功，已恢复可聊天状态。", "OpenClaw tried to bring the gateway back online.");
            }
        }

        if (exitCode == 10)
        {
            return T(locale, "需要你完成配置，已为你打开配置向导。", "OpenClaw opened the onboarding or configuration flow.");
        }

        if (exitCode == 20)
        {
            return T(locale, "当前已是最新版本。", "OpenClaw is already up to date for the current channel.");
        }

        if (exitCode == 30)
        {
            return T(locale, "核心已损坏，建议重新安装。", "OpenClaw looks damaged and should be reinstalled.");
        }

        return T(locale, "维护失败，请查看日志后重试。", "OpenClaw maintenance failed. Check the log and try again.");
    }

    private static bool IsEnglishLocale(string locale)
    {
        return string.Equals(locale, "en-US", StringComparison.OrdinalIgnoreCase);
    }

    private static string T(string locale, string zhCn, string enUs)
    {
        return IsEnglishLocale(locale) ? enUs : zhCn;
    }

    private enum MaintenanceMode
    {
        Start,
        Update,
        Repair
    }

    private enum VisualState
    {
        Running,
        Success,
        Warning,
        Error
    }

    private sealed class UiEvent
    {
        public string type { get; set; }
        public string key { get; set; }
        public string title { get; set; }
        public string message { get; set; }
        public string reason { get; set; }
        public string summary { get; set; }
        public string nextAction { get; set; }
        public string recoveryCommand { get; set; }
        public int progress { get; set; }
        public string level { get; set; }
        public int code { get; set; }
    }
    private sealed class MaintenanceWindow : Form
    {
        private readonly MaintenanceMode mode;
        private readonly string locale;
        private readonly string supportScriptPath;
        private readonly string logPath;
        private readonly string installRoot;
        private Label titleLabel;
        private Label modeLabel;
        private Label phaseLabel;
        private Label statusLabel;
        private Label progressLabel;
        private PictureBox stateIconBox;
        private ProgressBar progressBar;
        private TextBox logTextBox;
        private Button viewLogButton;
        private Button openLogDirButton;
        private Button closeButton;
        private Process process;
        private System.Windows.Forms.Timer timeoutTimer;
        private System.Windows.Forms.Timer autoCloseTimer;
        private DateTime startedAtUtc;
        private bool completed;
        private UiEvent pendingResult;
        private int exitCode = 1;
        private int completionSignaled;

        public MaintenanceWindow(MaintenanceMode mode, string locale, string supportScriptPath, string logPath, string installRoot)
        {
            this.mode = mode;
            this.locale = string.IsNullOrWhiteSpace(locale) ? "zh-CN" : locale;
            this.supportScriptPath = supportScriptPath;
            this.logPath = logPath;
            this.installRoot = installRoot;

            InitializeWindow();
            SetPhase(T("正在准备环境…", "Preparing environment..."), 0);
            SetStatus(T("正在准备运行维护任务。", "Preparing maintenance task."), VisualState.Running);
            AppendLog(T("维护窗口已打开。", "Maintenance window opened."));
            Shown += HandleShown;
            FormClosing += HandleFormClosing;
        }

        public int ExitCode
        {
            get { return exitCode; }
        }

        private void InitializeWindow()
        {
            Text = GetWindowTitle(mode, locale);
            StartPosition = FormStartPosition.CenterScreen;
            MinimumSize = new Size(860, 620);
            Size = new Size(920, 680);
            Font = new Font("Microsoft YaHei UI", 9F, FontStyle.Regular, GraphicsUnit.Point);
            MaximizeBox = false;
            MinimizeBox = true;

            TableLayoutPanel root = new TableLayoutPanel();
            root.Dock = DockStyle.Fill;
            root.ColumnCount = 1;
            root.RowCount = 3;
            root.RowStyles.Add(new RowStyle(SizeType.Absolute, 165F));
            root.RowStyles.Add(new RowStyle(SizeType.Percent, 100F));
            root.RowStyles.Add(new RowStyle(SizeType.Absolute, 58F));
            Controls.Add(root);

            Panel headerPanel = new Panel();
            headerPanel.Dock = DockStyle.Fill;
            root.Controls.Add(headerPanel, 0, 0);

            stateIconBox = new PictureBox();
            stateIconBox.Location = new Point(22, 24);
            stateIconBox.Size = new Size(48, 48);
            stateIconBox.SizeMode = PictureBoxSizeMode.CenterImage;
            headerPanel.Controls.Add(stateIconBox);

            titleLabel = new Label();
            titleLabel.AutoSize = false;
            titleLabel.Location = new Point(86, 20);
            titleLabel.Size = new Size(760, 28);
            titleLabel.Font = new Font("Microsoft YaHei UI", 16F, FontStyle.Bold, GraphicsUnit.Point);
            titleLabel.Text = GetModeWindowTitle(mode, locale);
            headerPanel.Controls.Add(titleLabel);

            modeLabel = new Label();
            modeLabel.AutoSize = false;
            modeLabel.Location = new Point(88, 57);
            modeLabel.Size = new Size(620, 22);
            modeLabel.ForeColor = Color.DimGray;
            modeLabel.Text = T("当前模式：", "Mode: ") + GetModeDisplayName(mode, locale);
            headerPanel.Controls.Add(modeLabel);

            LinkLabel signatureLinkLabel = new LinkLabel();
            signatureLinkLabel.AutoSize = false;
            signatureLinkLabel.Location = new Point(722, 56);
            signatureLinkLabel.Size = new Size(120, 22);
            signatureLinkLabel.TextAlign = ContentAlignment.MiddleRight;
            signatureLinkLabel.LinkBehavior = LinkBehavior.HoverUnderline;
            signatureLinkLabel.LinkColor = Color.DimGray;
            signatureLinkLabel.ActiveLinkColor = Color.FromArgb(0, 84, 147);
            signatureLinkLabel.VisitedLinkColor = Color.DimGray;
            signatureLinkLabel.Font = new Font("Segoe UI", 9F, FontStyle.Italic, GraphicsUnit.Point);
            signatureLinkLabel.Text = "by RZX000";
            signatureLinkLabel.LinkClicked += delegate { OpenExternalTarget(RepositoryUrl); };
            headerPanel.Controls.Add(signatureLinkLabel);

            phaseLabel = new Label();
            phaseLabel.AutoSize = false;
            phaseLabel.Location = new Point(22, 96);
            phaseLabel.Size = new Size(820, 22);
            phaseLabel.Font = new Font("Microsoft YaHei UI", 10.5F, FontStyle.Bold, GraphicsUnit.Point);
            headerPanel.Controls.Add(phaseLabel);

            statusLabel = new Label();
            statusLabel.AutoSize = false;
            statusLabel.Location = new Point(22, 120);
            statusLabel.Size = new Size(820, 22);
            headerPanel.Controls.Add(statusLabel);

            progressBar = new ProgressBar();
            progressBar.Location = new Point(22, 146);
            progressBar.Size = new Size(720, 11);
            progressBar.Minimum = 0;
            progressBar.Maximum = 100;
            headerPanel.Controls.Add(progressBar);

            progressLabel = new Label();
            progressLabel.AutoSize = false;
            progressLabel.Location = new Point(754, 141);
            progressLabel.Size = new Size(88, 18);
            progressLabel.TextAlign = ContentAlignment.MiddleRight;
            headerPanel.Controls.Add(progressLabel);

            logTextBox = new TextBox();
            logTextBox.Dock = DockStyle.Fill;
            logTextBox.Multiline = true;
            logTextBox.ReadOnly = true;
            logTextBox.ScrollBars = ScrollBars.Vertical;
            logTextBox.WordWrap = false;
            logTextBox.Font = new Font("Consolas", 9F, FontStyle.Regular, GraphicsUnit.Point);
            root.Controls.Add(logTextBox, 0, 1);

            FlowLayoutPanel buttonPanel = new FlowLayoutPanel();
            buttonPanel.Dock = DockStyle.Fill;
            buttonPanel.FlowDirection = FlowDirection.RightToLeft;
            buttonPanel.Padding = new Padding(10, 10, 10, 10);
            root.Controls.Add(buttonPanel, 0, 2);

            closeButton = new Button();
            closeButton.Text = T("关闭", "Close");
            closeButton.AutoSize = true;
            closeButton.Enabled = false;
            closeButton.Click += delegate { Close(); };
            buttonPanel.Controls.Add(closeButton);

            openLogDirButton = new Button();
            openLogDirButton.Text = T("打开日志目录", "Open log folder");
            openLogDirButton.AutoSize = true;
            openLogDirButton.Click += delegate { OpenLogDirectory(); };
            buttonPanel.Controls.Add(openLogDirButton);

            viewLogButton = new Button();
            viewLogButton.Text = T("查看日志", "View log");
            viewLogButton.AutoSize = true;
            viewLogButton.Click += delegate { OpenLogFile(); };
            buttonPanel.Controls.Add(viewLogButton);
        }

        private string T(string zhCn, string enUs)
        {
            return Program.T(locale, zhCn, enUs);
        }

        private void HandleShown(object sender, EventArgs e)
        {
            BeginInvoke((MethodInvoker)StartMaintenance);
        }

        private void HandleFormClosing(object sender, FormClosingEventArgs e)
        {
            if (completed)
            {
                return;
            }

            e.Cancel = true;
            SetStatus(T("任务仍在执行中，请等待完成后再关闭窗口。", "The task is still running. Wait for it to finish before closing the window."), VisualState.Running);
        }

        private void StartMaintenance()
        {
            if (string.IsNullOrWhiteSpace(supportScriptPath) || !File.Exists(supportScriptPath))
            {
                AppendLog(T("未找到维护脚本，无法继续运行。", "Maintenance script was not found."));
                CompleteWindow(30, T("找不到维护组件，请先重新安装 OpenClaw。", "OpenClaw maintenance assets were not found. Please reinstall OpenClaw first."), VisualState.Warning, false);
                return;
            }

            try
            {
                string powerShellPath = ResolvePowerShellPath();
                string exePath = Process.GetCurrentProcess().MainModule.FileName;
                string[] arguments =
                {
                    "-NoLogo",
                    "-NoProfile",
                    "-ExecutionPolicy",
                    "Bypass",
                    "-File",
                    supportScriptPath,
                    "-Mode",
                    mode.ToString(),
                    "-LogPath",
                    logPath,
                    "-InvokerPath",
                    exePath,
                    "-InstallRoot",
                    string.IsNullOrWhiteSpace(installRoot) ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "OpenClaw") : installRoot
                };

                string argumentString = string.Join(" ", arguments.Select(QuoteArgumentForProcess));
                string workingDirectory = !string.IsNullOrWhiteSpace(installRoot) && Directory.Exists(installRoot)
                    ? installRoot
                    : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "OpenClaw");
                if (!Directory.Exists(workingDirectory) && !string.IsNullOrWhiteSpace(supportScriptPath))
                {
                    workingDirectory = Path.GetDirectoryName(supportScriptPath) ?? workingDirectory;
                }
                ProcessStartInfo startInfo = new ProcessStartInfo(powerShellPath, argumentString)
                {
                    UseShellExecute = false,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    CreateNoWindow = true,
                    WindowStyle = ProcessWindowStyle.Hidden,
                    WorkingDirectory = workingDirectory
                };

                try
                {
                    startInfo.StandardOutputEncoding = Encoding.UTF8;
                    startInfo.StandardErrorEncoding = Encoding.UTF8;
                }
                catch
                {
                }

                startInfo.EnvironmentVariables["PATH"] = BuildMergedPath();
                if (!string.IsNullOrWhiteSpace(installRoot))
                {
                    startInfo.EnvironmentVariables["OPENCLAW_INSTALL_ROOT"] = installRoot;
                }
                process = new Process();
                process.StartInfo = startInfo;
                process.EnableRaisingEvents = true;
                process.OutputDataReceived += HandleOutputDataReceived;
                process.ErrorDataReceived += HandleErrorDataReceived;

                AppendLog(T("正在启动维护脚本。", "Starting maintenance script."));
                Log(logPath, T("启动命令：", "Running: ") + powerShellPath + " " + argumentString);
                startedAtUtc = DateTime.UtcNow;
                process.Start();
                process.BeginOutputReadLine();
                process.BeginErrorReadLine();
                StartTimeoutTimer();

                ThreadPool.QueueUserWorkItem(delegate
                {
                    try
                    {
                        process.WaitForExit();
                        TryFinalizeFromWorker(process.ExitCode, false);
                    }
                    catch (Exception ex)
                    {
                        TryFinalizeFromWorker(1, false, ex.Message);
                    }
                });
            }
            catch (Exception ex)
            {
                AppendLog(T("启动维护脚本失败：", "Failed to start maintenance script: ") + ex.Message);
                CompleteWindow(1, T("启动维护脚本失败，请查看日志。", "Failed to start maintenance script. Check the log."), VisualState.Error, false);
            }
        }

        private void StartTimeoutTimer()
        {
            timeoutTimer = new System.Windows.Forms.Timer();
            timeoutTimer.Interval = 1000;
            timeoutTimer.Tick += delegate
            {
                if (completed || process == null)
                {
                    return;
                }

                TimeSpan elapsed = DateTime.UtcNow - startedAtUtc;
                if (elapsed.TotalSeconds < GetTimeoutSeconds(mode))
                {
                    return;
                }

                try
                {
                    process.Kill();
                }
                catch
                {
                }

                AppendLog(T("维护进程执行超时。", "Maintenance timed out."));
                CompleteWindow(124, T("执行超时，请查看日志后重试。", "Maintenance timed out. Check the log and try again."), VisualState.Warning, true);
            };
            timeoutTimer.Start();
        }
        private void HandleOutputDataReceived(object sender, DataReceivedEventArgs e)
        {
            if (string.IsNullOrWhiteSpace(e.Data))
            {
                return;
            }

            PostLine(e.Data, false);
        }

        private void HandleErrorDataReceived(object sender, DataReceivedEventArgs e)
        {
            if (string.IsNullOrWhiteSpace(e.Data))
            {
                return;
            }

            PostLine(e.Data, true);
        }

        private void PostLine(string line, bool isError)
        {
            if (IsDisposed)
            {
                return;
            }

            if (InvokeRequired)
            {
                try
                {
                    BeginInvoke((MethodInvoker)delegate { HandleProcessLine(line, isError); });
                }
                catch
                {
                }
                return;
            }

            HandleProcessLine(line, isError);
        }

        private void HandleProcessLine(string line, bool isError)
        {
            string text = line ?? string.Empty;
            if (text.StartsWith(UiPrefix, StringComparison.Ordinal))
            {
                if (TryApplyUiEvent(text.Substring(UiPrefix.Length)))
                {
                    return;
                }
            }

            if (isError)
            {
                AppendLog("[stderr] " + text);
                return;
            }

            AppendLog(text);
        }

        private bool TryApplyUiEvent(string json)
        {
            try
            {
                UiEvent uiEvent;
                if (!TryParseUiEvent(json, out uiEvent))
                {
                    return false;
                }

                if (uiEvent == null || string.IsNullOrWhiteSpace(uiEvent.type))
                {
                    return false;
                }

                string eventType = uiEvent.type.Trim().ToLowerInvariant();
                if (eventType == "phase")
                {
                    SetPhase(LocalizePhaseTitle(uiEvent.key, uiEvent.title), uiEvent.progress);
                    string localizedMessage = LocalizeUiMessage(uiEvent.message);
                    if (!string.IsNullOrWhiteSpace(localizedMessage))
                    {
                        SetStatus(localizedMessage, VisualState.Running);
                    }
                    return true;
                }

                if (eventType == "status")
                {
                    SetStatus(LocalizeUiMessage(uiEvent.message), GetVisualStateFromLevel(uiEvent.level));
                    return true;
                }

                if (eventType == "result")
                {
                    pendingResult = uiEvent;
                    SetStatus(BuildResultStatusMessage(uiEvent, uiEvent.code), GetVisualStateFromExitCode(uiEvent.code));
                    AppendResultDetails(uiEvent);
                    return true;
                }

                return false;
            }
            catch
            {
                return false;
            }
        }

        private static bool TryParseUiEvent(string json, out UiEvent uiEvent)
        {
            uiEvent = new UiEvent();
            if (string.IsNullOrWhiteSpace(json))
            {
                return false;
            }

            uiEvent.type = ReadJsonString(json, "type");
            if (string.IsNullOrWhiteSpace(uiEvent.type))
            {
                return false;
            }

            uiEvent.key = ReadJsonString(json, "key");
            uiEvent.title = ReadJsonString(json, "title");
            uiEvent.message = ReadJsonString(json, "message");
            uiEvent.reason = ReadJsonString(json, "reason");
            uiEvent.summary = ReadJsonString(json, "summary");
            uiEvent.nextAction = ReadJsonString(json, "nextAction");
            uiEvent.recoveryCommand = ReadJsonString(json, "recoveryCommand");
            uiEvent.level = ReadJsonString(json, "level");
            uiEvent.progress = ReadJsonInt(json, "progress");
            uiEvent.code = ReadJsonInt(json, "code");
            return true;
        }

        private string BuildResultStatusMessage(UiEvent uiEvent, int code)
        {
            if (uiEvent != null)
            {
                string localizedSummary = LocalizeUiMessage(uiEvent.summary);
                if (!string.IsNullOrWhiteSpace(localizedSummary))
                {
                    return localizedSummary;
                }

                string localizedMessage = LocalizeUiMessage(uiEvent.message);
                if (!string.IsNullOrWhiteSpace(localizedMessage))
                {
                    return localizedMessage;
                }
            }

            return BuildDefaultResultMessage(mode, code, locale);
        }

        private void AppendResultDetails(UiEvent uiEvent)
        {
            if (uiEvent == null)
            {
                return;
            }

            if (!string.IsNullOrWhiteSpace(uiEvent.reason))
            {
                AppendLog("reason: " + uiEvent.reason);
            }

            if (!string.IsNullOrWhiteSpace(uiEvent.nextAction))
            {
                AppendLog(T("下一步：", "Next action: ") + LocalizeUiMessage(uiEvent.nextAction));
            }

            if (!string.IsNullOrWhiteSpace(uiEvent.recoveryCommand))
            {
                AppendLog(T("恢复命令：", "Recovery command: ") + uiEvent.recoveryCommand);
            }
        }

        private static string ReadJsonString(string json, string name)
        {
            Match match = Regex.Match(
                json,
                "\"" + Regex.Escape(name) + "\"\\s*:\\s*\"(?<value>(?:\\\\.|[^\"])*)\"",
                RegexOptions.IgnoreCase);

            if (!match.Success)
            {
                return null;
            }

            return Regex.Unescape(match.Groups["value"].Value);
        }

        private static int ReadJsonInt(string json, string name)
        {
            Match match = Regex.Match(
                json,
                "\"" + Regex.Escape(name) + "\"\\s*:\\s*(?<value>-?\\d+)",
                RegexOptions.IgnoreCase);

            if (!match.Success)
            {
                return 0;
            }

            int value;
            return int.TryParse(match.Groups["value"].Value, out value) ? value : 0;
        }

        private void TryFinalizeFromWorker(int code, bool timedOut)
        {
            TryFinalizeFromWorker(code, timedOut, null);
        }

        private void TryFinalizeFromWorker(int code, bool timedOut, string workerMessage)
        {
            if (Interlocked.Exchange(ref completionSignaled, 1) != 0)
            {
                return;
            }

            if (IsDisposed)
            {
                return;
            }

            try
            {
                BeginInvoke((MethodInvoker)delegate
                {
                    if (!string.IsNullOrWhiteSpace(workerMessage))
                    {
                        AppendLog(workerMessage);
                    }

                    string message = BuildResultStatusMessage(pendingResult, code);

                    VisualState state = GetVisualStateFromExitCode(code);
                    if (timedOut)
                    {
                        state = VisualState.Warning;
                        message = T("执行超时，请查看日志后重试。", "Maintenance timed out. Check the log and try again.");
                    }

                    CompleteWindow(code, message, state, timedOut);
                });
            }
            catch
            {
            }
        }

        private void CompleteWindow(int code, string message, VisualState state, bool timedOut)
        {
            if (completed)
            {
                return;
            }

            completed = true;
            exitCode = code;

            if (timeoutTimer != null)
            {
                timeoutTimer.Stop();
                timeoutTimer.Dispose();
                timeoutTimer = null;
            }

            if (autoCloseTimer != null)
            {
                autoCloseTimer.Stop();
                autoCloseTimer.Dispose();
                autoCloseTimer = null;
            }

            if (!timedOut && progressBar.Value < 100 && (code == 0 || code == 10 || code == 20))
            {
                progressBar.Value = 100;
                progressLabel.Text = "100%";
            }

            SetStatus(message, state);
            closeButton.Enabled = true;

            if (ShouldAutoCloseWindow(code, timedOut))
            {
                autoCloseTimer = new System.Windows.Forms.Timer();
                autoCloseTimer.Interval = 900;
                autoCloseTimer.Tick += delegate
                {
                    if (autoCloseTimer != null)
                    {
                        autoCloseTimer.Stop();
                        autoCloseTimer.Dispose();
                        autoCloseTimer = null;
                    }

                    try
                    {
                        Close();
                    }
                    catch
                    {
                    }
                };
                autoCloseTimer.Start();
            }

            if (process != null)
            {
                try { process.Dispose(); } catch { }
                process = null;
            }
        }

        private bool ShouldAutoCloseWindow(int code, bool timedOut)
        {
            return !timedOut && mode == MaintenanceMode.Start && code == 0;
        }
        private void SetPhase(string phaseTitle, int progress)
        {
            string title = string.IsNullOrWhiteSpace(phaseTitle) ? T("正在处理…", "Processing...") : phaseTitle;
            int value = Math.Max(0, Math.Min(100, progress));
            phaseLabel.Text = T("当前阶段：", "Current phase: ") + title;
            progressBar.Value = value;
            progressLabel.Text = value.ToString() + "%";
            if (value < 100 && !completed)
            {
                SetVisualState(VisualState.Running);
            }
        }

        private void SetStatus(string message, VisualState state)
        {
            statusLabel.Text = T("当前状态：", "Status: ") + (message ?? string.Empty);
            SetVisualState(state);
        }

        private void SetVisualState(VisualState state)
        {
            statusLabel.ForeColor = GetStatusColor(state);
            stateIconBox.Image = GetStateIcon(state).ToBitmap();
        }

        private void AppendLog(string message)
        {
            if (string.IsNullOrWhiteSpace(message))
            {
                return;
            }

            logTextBox.AppendText(message + Environment.NewLine);
            logTextBox.SelectionStart = logTextBox.TextLength;
            logTextBox.ScrollToCaret();
        }

        private void OpenLogFile()
        {
            try
            {
                if (!File.Exists(logPath))
                {
                    SetStatus(T("日志文件尚未生成。", "The log file has not been created yet."), VisualState.Warning);
                    return;
                }

                Process.Start(new ProcessStartInfo("notepad.exe", QuoteArgumentForProcess(logPath))
                {
                    UseShellExecute = true
                });
            }
            catch (Exception ex)
            {
                SetStatus(T("打开日志失败：", "Failed to open the log: ") + ex.Message, VisualState.Warning);
            }
        }

        private void OpenLogDirectory()
        {
            try
            {
                string directory = Path.GetDirectoryName(logPath);
                if (string.IsNullOrWhiteSpace(directory))
                {
                    return;
                }

                Directory.CreateDirectory(directory);
                string argument = File.Exists(logPath) ? "/select," + QuoteArgumentForProcess(logPath) : QuoteArgumentForProcess(directory);
                Process.Start(new ProcessStartInfo("explorer.exe", argument)
                {
                    UseShellExecute = true
                });
            }
            catch (Exception ex)
            {
                SetStatus(T("打开日志目录失败：", "Failed to open the log folder: ") + ex.Message, VisualState.Warning);
            }
        }

        private void OpenExternalTarget(string target)
        {
            if (string.IsNullOrWhiteSpace(target))
            {
                return;
            }

            try
            {
                ProcessStartInfo startInfo = new ProcessStartInfo(target);
                startInfo.UseShellExecute = true;
                Process.Start(startInfo);
            }
            catch (Exception ex)
            {
                SetStatus(T("打开仓库链接失败：", "Failed to open the repository link: ") + ex.Message, VisualState.Warning);
            }
        }

        private static Icon GetStateIcon(VisualState state)
        {
            switch (state)
            {
                case VisualState.Success:
                    return SystemIcons.Shield;
                case VisualState.Warning:
                    return SystemIcons.Warning;
                case VisualState.Error:
                    return SystemIcons.Error;
                default:
                    return SystemIcons.Information;
            }
        }

        private static Color GetStatusColor(VisualState state)
        {
            switch (state)
            {
                case VisualState.Success:
                    return Color.FromArgb(0, 120, 60);
                case VisualState.Warning:
                    return Color.FromArgb(180, 110, 0);
                case VisualState.Error:
                    return Color.FromArgb(184, 39, 45);
                default:
                    return Color.FromArgb(0, 84, 147);
            }
        }

        private static VisualState GetVisualStateFromLevel(string level)
        {
            string text = (level ?? string.Empty).Trim().ToLowerInvariant();
            if (text == "warn" || text == "warning")
            {
                return VisualState.Warning;
            }

            if (text == "error")
            {
                return VisualState.Error;
            }

            return VisualState.Running;
        }

        private static VisualState GetVisualStateFromExitCode(int code)
        {
            if (code == 0 || code == 20)
            {
                return VisualState.Success;
            }

            if (code == 10 || code == 30 || code == 124)
            {
                return VisualState.Warning;
            }

            return VisualState.Error;
        }

        private string LocalizePhaseTitle(string key, string fallbackTitle)
        {
            if (Program.IsEnglishLocale(locale))
            {
                return string.IsNullOrWhiteSpace(fallbackTitle) ? T("正在处理…", "Processing...") : fallbackTitle;
            }

            switch ((key ?? string.Empty).Trim().ToLowerInvariant())
            {
                case "start.prepare": return "准备启动";
                case "start.environment": return "检查 OpenClaw 环境";
                case "start.gateway-token": return "检查 Gateway token";
                case "start.gateway": return "检查 Gateway 状态";
                case "start.restart": return "启动或重启 Gateway";
                case "start.rpc": return "验证 Gateway RPC";
                case "start.dashboard-verify": return "验证 Dashboard";
                case "start.verify": return "验证可聊天状态";
                case "start.provider": return "检查模型认证";
                case "update.prepare": return "准备更新";
                case "update.read-state": return "读取安装信息";
                case "update.resolve-target": return "检查目标版本";
                case "update.stop-gateway": return "停止 Gateway";
                case "update.install": return "执行更新安装";
                case "update.restart": return "重启 Gateway";
                case "update.verify": return "验证更新结果";
                case "repair.prepare": return "准备修复";
                case "repair.entry": return "检查入口与版本";
                case "repair.collect": return "采集运行状态";
                case "repair.restart": return "重启 Gateway";
                case "repair.doctor": return "执行 Doctor 检查";
                case "repair.gateway-install": return "重写 Gateway 服务";
                case "repair.verify": return "验证修复结果";
                default: return string.IsNullOrWhiteSpace(fallbackTitle) ? "正在处理…" : fallbackTitle;
            }
        }

        private string LocalizeUiMessage(string message)
        {
            if (string.IsNullOrWhiteSpace(message) || Program.IsEnglishLocale(locale))
            {
                return message;
            }

            switch (message.Trim())
            {
                case "Preparing the startup checks...": return "正在准备启动检查…";
                case "Checking the OpenClaw entrypoint and version...": return "正在检查 OpenClaw 入口和版本…";
                case "Checking local Gateway token readiness...": return "正在检查本机 Gateway token 状态…";
                case "Checking the current Gateway status...": return "正在检查 Gateway 当前状态…";
                case "Checking the Gateway background service...": return "正在检查 Gateway 后台服务…";
                case "Gateway token is missing. Attempting to generate one automatically...": return "当前缺少 Gateway token，正在尝试自动生成…";
                case "The Gateway background service is loaded.": return "Gateway 后台服务已加载。";
                case "The Gateway background service is not loaded.": return "Gateway 后台服务未加载。";
                case "The Gateway background service is registered but not ready. Trying to start it...": return "Gateway 后台服务已注册但尚未就绪，正在尝试启动…";
                case "The Gateway is already healthy and ready to chat.": return "Gateway 已在线，可直接聊天。";
                case "Trying to start or restart the Gateway...": return "正在尝试拉起或重启 Gateway…";
                case "Verifying Gateway RPC health...": return "正在验证 Gateway RPC 健康状态…";
                case "Verifying Dashboard readiness...": return "正在验证 Dashboard 可用性…";
                case "Opening the dashboard...": return "正在打开 Dashboard…";
                case "Checking provider auth readiness...": return "正在检查模型认证状态…";
                case "Opening the dashboard through the native launcher...": return "正在调用原生 Dashboard 打开流程…";
                case "The native dashboard command is unavailable. Falling back to the parsed URL...": return "当前版本缺少原生 Dashboard 命令，正在使用兼容地址兜底打开…";
                case "The Gateway service is loaded but appears unhealthy. Refreshing it...": return "Gateway 服务已加载但当前不健康，正在刷新服务…";
                case "The Gateway service is loaded but unhealthy. Refreshing it...": return "Gateway 服务已加载但当前不健康，正在刷新服务…";
                case "The Gateway service is loaded. Refreshing it after update...": return "Gateway 服务已加载，正在于更新后刷新服务…";
                case "Gateway is not persistent yet. Installing the official background service...": return "当前还不是持久运行，正在安装 OpenClaw 官方后台服务…";
                case "The official background service is not ready. Switching to a persistent console window...": return "官方后台服务暂未就绪，正在切换到持久运行窗口…";
                case "The Gateway is only running temporarily. Switching it to persistent mode...": return "已检测到 Gateway 当前只是临时运行，正在切换为持久运行…";
                case "Start finished. Confirming chat readiness...": return "启动完成，正在确认可聊天状态…";
                case "Gateway token is still missing. The dashboard may open, but startup will not be treated as a full success.": return "Gateway token 仍未就绪；仪表盘可能可以打开，但不会视为完全成功。";
                case "Set a Gateway token on the gateway host, then run Start again.": return "请在网关主机上补齐 Gateway token，然后重新运行一键启动。";
                case "Dashboard verification timed out.": return "Dashboard 预检超时，无法确认可打开状态。";
                case "Run Repair again or inspect the gateway logs.": return "请重新运行一键修复，或检查网关日志。";
                case "Dashboard verification failed.": return "Dashboard 预检未通过，当前配置无法稳定引导控制台。";
                case "Dashboard origin policy drift was detected. Run Repair first.": return "检测到 Dashboard 来源策略漂移，请先运行一键修复。";
                case "Run Repair first to realign the Dashboard and Gateway configuration.": return "请先运行一键修复，确认 Dashboard 与 Gateway 配置一致。";
                case "Dashboard verification did not return a usable URL.": return "Dashboard 预检未返回可用地址。";
                case "Run Repair first and confirm the Control UI address and asset path.": return "请先运行一键修复，确认 Control UI 地址与资源路径正常。";
                case "Dashboard returned an invalid URL.": return "Dashboard 地址格式无效，无法自动打开。";
                case "Run Repair first and confirm the dashboard URL configuration.": return "请先运行一键修复，确认 Dashboard 地址配置。";
                case "The current Dashboard URL is not loopback. One-click Start will not continue through a remote/LAN path.": return "当前 Dashboard 地址不是本机 loopback，一键启动不会再按远程/LAN 路径继续打开。";
                case "Run Repair first to restore a local dashboard path. For remote access, use Tailscale Serve HTTPS or an SSH tunnel.": return "请先运行一键修复，把 Dashboard 恢复到本机打开路径；远程访问请改用 Tailscale Serve HTTPS 或 SSH tunnel。";
                case "The installed runtime does not support the native dashboard command.": return "当前版本不支持原生 Dashboard 启动命令。";
                case "Run Update or Repair first so the dashboard launcher matches this runtime.": return "请先运行一键更新或一键修复，使 Dashboard 启动能力与当前版本一致。";
                case "Dashboard is open, but provider model auth is still missing.": return "Dashboard 已可打开，但当前模型认证仍未完成。";
                case "Add an Anthropic setup-token or re-auth the profile.": return "请补齐 Anthropic setup-token 或重新登录相关认证。";
                case "Complete OpenAI Codex sign-in, then try again.": return "请完成 OpenAI Codex 登录，然后再试。";
                case "Complete auth for the current provider, then try again.": return "请补齐当前默认 provider 的模型认证，然后再试。";
                case "Anthropic auth is missing. Opening the targeted repair flow...": return "Anthropic 认证缺失，正在打开定向修复…";
                case "Anthropic auth is missing. Opening setup-token repair...": return "Anthropic 认证缺失，正在打开 setup-token 修复…";
                case "Anthropic auth is missing. Opening onboarding repair...": return "Anthropic 认证缺失，正在打开引导修复…";
                case "OpenAI Codex auth is missing. Opening the targeted repair flow...": return "OpenAI Codex 认证缺失，正在打开定向修复…";
                case "OpenAI Codex auth is missing. Opening onboarding repair...": return "OpenAI Codex 认证缺失，正在打开引导修复…";
                case "Provider auth still needs attention. Opening onboarding repair...": return "模型认证仍需处理，正在打开引导修复…";
                case "Dashboard is not ready to open.": return "Dashboard 当前无法稳定打开。";
                case "Dashboard failed to open.": return "Dashboard 打开失败。";
                case "Dashboard opened, but provider auth still needs attention.": return "Dashboard 已打开，但模型认证仍需处理。";
                case "Gateway is up and the dashboard path is restored, but the Gateway token still needs attention.": return "Gateway 已启动，Dashboard 路径已恢复，但 Gateway token 仍需处理。";
                case "The OpenClaw entrypoint or version output is invalid.": return "当前 OpenClaw 入口或版本输出异常。";
                case "Run Update or reinstall OpenClaw first.": return "请先运行一键更新或重新安装。";
                case "Gateway could not be stabilized.": return "Gateway 未能稳定进入可用状态。";
                case "The wrapper tried to repair and start the Gateway, but it still did not satisfy persistence and health requirements.": return "已尝试修复并拉起 Gateway，但仍未满足持久化与健康要求。";
                case "Run Repair first. If it still fails, run Update or reinstall.": return "请先运行一键修复；若仍失败，再执行一键更新或重新安装。";
                case "A persistent OpenClaw console window was opened to keep the Gateway online.": return "已打开持久运行窗口，并正在通过该窗口维持 Gateway 在线。";
                case "Gateway is already available on this host. Continuing to open the dashboard.": return "Gateway 已在本机可用，正在继续打开 Dashboard。";
                case "Gateway was restored to a usable state. Continuing to open the dashboard.": return "Gateway 已恢复到可用状态，正在继续打开 Dashboard。";
                case "One-click Start finished verifying the local Gateway, dashboard, and provider auth state.": return "一键启动已完成本机 Gateway、Dashboard 和 provider auth 状态确认。";
                case "Loaded service refresh finished. Confirming chat readiness...": return "服务刷新完成，正在确认可聊天状态…";
                case "Preparing the update checks...": return "正在准备更新检查…";
                case "Reading the current installation state...": return "正在读取当前安装状态…";
                case "Checking the target version for the current channel...": return "正在检查当前渠道的目标版本…";
                case "The current installation is already up to date.": return "当前已是最新版本。";
                case "OpenClaw is already up to date, and a persistent console window was opened.": return "当前已是最新版本，并已打开 OpenClaw 持久运行窗口。";
                case "OpenClaw is already up to date, and chat readiness was confirmed.": return "当前已是最新版本，且已确认可聊天状态。";
                case "OpenClaw is already up to date, and post-update health verification passed.": return "当前已是最新版本，后置健康检查已通过。";
                case "Update verified that the current version is already latest and that the Gateway and dashboard post-checks passed.": return "更新链路确认当前版本已是最新，且 Gateway 与 Dashboard 后置检查已通过。";
                case "The current version is already latest, but the Gateway post-check failed.": return "当前版本虽已是最新，但 Gateway 后置校验未通过。";
                case "No new version was needed, but the current installation still is not stable.": return "无需下载新版本，但当前安装仍未达到稳定可用状态。";
                case "Stopping the Gateway service...": return "正在停止 Gateway 服务…";
                case "Installing the update. Please wait...": return "正在执行更新安装，请稍候…";
                case "Restarting the Gateway service...": return "正在重启 Gateway 服务…";
                case "Update finished. Confirming chat readiness...": return "更新完成，正在确认可聊天状态…";
                case "The update finished, and a persistent OpenClaw console window was opened.": return "更新已完成，并已打开 OpenClaw 持久运行窗口。";
                case "The update finished, and the Gateway/dashboard post-checks passed.": return "更新完成，Gateway 与 Dashboard 后置校验通过。";
                case "The update flow completed and reused the unified post-validation pipeline.": return "更新链路已完成，并复用了统一后置校验。";
                case "The update finished, but the Gateway did not return to a stable state.": return "更新完成，但 Gateway 未能恢复到稳定状态。";
                case "The update completed, but Gateway persistence/RPC post-checks failed.": return "更新已执行完成，但 Gateway 持久化/RPC 后置校验失败。";
                case "Preparing the repair checks...": return "正在准备修复检查…";
                case "Collecting the current runtime status...": return "正在采集当前运行状态…";
                case "Trying to restart the Gateway...": return "正在尝试重启 Gateway…";
                case "Restart finished. Confirming Gateway health...": return "重启完成，正在确认 Gateway 健康状态…";
                case "Running doctor checks...": return "正在执行 Doctor 检查…";
                case "Running the official Doctor repair flow...": return "正在执行官方 Doctor 修复流程…";
                case "Official Doctor repair is unavailable. Falling back to safe Doctor checks...": return "当前版本不支持官方 Doctor 自动修复，正在回退到安全检查…";
                case "Official Doctor repair did not complete cleanly. Falling back to safe Doctor checks...": return "官方 Doctor 自动修复未成功完成，正在回退到安全检查…";
                case "Doctor checks finished. Confirming the repair result...": return "Doctor 检查完成，正在确认修复结果…";
                case "Reinstalling the Gateway service...": return "正在重写 Gateway 服务…";
                case "Gateway service rewrite finished. Confirming the repair result...": return "服务重写完成，正在确认修复结果…";
                case "Manual configuration is required. Opening onboarding...": return "需要你完成配置，正在打开配置向导…";
                case "OpenClaw wrapper is missing before repair.": return "修复前检查发现 OpenClaw wrapper 缺失。";
                case "The current runtime entrypoint is still invalid before repair.": return "修复前检查发现当前版本入口仍然异常。";
                case "Run Update first. Reinstall only if Update still fails.": return "请先运行一键更新；若仍失败，再考虑重装。";
                case "Repair finished, and the Gateway/dashboard post-checks passed.": return "修复完成，Gateway 与 Dashboard 后置校验通过。";
                case "The repair flow passed the unified post-validation after restart.": return "修复链路在重启后已通过统一后置校验。";
                case "Doctor repair finished, and a persistent OpenClaw console window was opened.": return "Doctor 修复完成，并已打开持久运行窗口。";
                case "Doctor repair finished, and the Gateway/dashboard post-checks passed.": return "Doctor 修复完成，Gateway 与 Dashboard 后置校验通过。";
                case "The unified post-validation passed after Doctor repair.": return "Doctor 修复后已通过统一后置校验。";
                case "Gateway service rewrite finished, and a persistent OpenClaw console window was opened.": return "Gateway 服务重写完成，并已打开持久运行窗口。";
                case "Gateway service rewrite finished, and the Gateway/dashboard post-checks passed.": return "Gateway 服务重写完成，Gateway 与 Dashboard 后置校验通过。";
                case "The unified post-validation passed after the Gateway service rewrite.": return "Gateway 服务重写后已通过统一后置校验。";
                case "Repair exhausted its fallback steps, but the installation is still unstable.": return "修复链路已执行完所有回退步骤，但当前安装仍不稳定。";
                case "Restart, Doctor, and service rewrite still did not restore a stable state.": return "重启、Doctor 和服务重写都未能恢复稳定状态。";
                case "Running the compatibility installer update...": return "正在执行兼容安装器更新…";
                case "Updating to the latest official OpenClaw version...": return "正在更新到 OpenClaw 官方最新版本…";
                case "Update finished and the Gateway service was restored.": return "更新完成，已恢复 Gateway 服务。";
                case "Common repair steps finished. Please try chatting again.": return "已完成常见修复，请重新尝试聊天。";
                case "Start completed and chat is available again.": return "启动成功，已恢复可聊天状态。";
                case "A persistent OpenClaw console window was opened. Keep it open to keep chatting.": return "已打开 OpenClaw 持久运行窗口，保持该窗口开启即可聊天。";
                case "Repair finished, and a persistent OpenClaw console window was opened.": return "已完成修复，并已打开 OpenClaw 持久运行窗口。";
                case "Configuration still needs manual action. Onboarding was opened.": return "需要你完成配置，已为你打开配置向导。";
                case "The core installation looks damaged. Reinstall is recommended.": return "核心已损坏，建议重新安装。";
                case "Maintenance failed. Check the log and try again.": return "维护失败，请查看日志后重试。";
                default: return message;
            }
        }
    }
}
