using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.IO.Compression;
using System.Security.Principal;
using System.Reflection;
using System.Text;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;

public static class Program
{
    private static readonly byte[] Magic = Encoding.ASCII.GetBytes("OCSFX01");
    private const string ElevationSentinel = "--openclaw-elevated";
    private const string DefaultLocale = __OPENCLAW_LOCALE__;
    private const string DefaultApiBaseUrl = __OPENCLAW_DEFAULT_LICENSE_API_BASE_URL__;
    internal const bool RequireLicenseGate = false;

    [STAThread]
    public static int Main(string[] args)
    {
        try
        {
            if (!IsAdministrator())
            {
                return ElevateSelf(args);
            }

            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);

            using (BootstrapForm form = new BootstrapForm())
            {
                Application.Run(form);
                return form.ResultExitCode;
            }
        }
        catch (Exception ex)
        {
            MessageBox.Show(
                ex.Message,
                T("安装器错误", "Installer Error"),
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
            return 1;
        }
    }

    internal static string T(string zhCn, string enUs)
    {
        return string.Equals(DefaultLocale, "en-US", StringComparison.OrdinalIgnoreCase) ? enUs : zhCn;
    }

    internal static string GetInitialApiBaseUrl()
    {
        string envValue = NormalizeBaseUrl(Environment.GetEnvironmentVariable("OPENCLAW_LICENSE_API_BASE_URL"));
        return string.IsNullOrWhiteSpace(envValue) ? NormalizeBaseUrl(DefaultApiBaseUrl) : envValue;
    }

    internal static string GetProgramDataRoot()
    {
        string programData = Environment.GetEnvironmentVariable("ProgramData");
        if (string.IsNullOrWhiteSpace(programData))
        {
            programData = Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData);
        }

        return Path.Combine(programData, "OpenClaw");
    }

    internal static string GetInstallStatePath()
    {
        return Path.Combine(GetProgramDataRoot(), "install-state.json");
    }

    internal static string GetLicenseStatePath()
    {
        return Path.Combine(GetProgramDataRoot(), "license-state.json");
    }

    internal static void EnsureDirectory(string path)
    {
        if (!string.IsNullOrWhiteSpace(path) && !Directory.Exists(path))
        {
            Directory.CreateDirectory(path);
        }
    }

    internal static string NormalizeBaseUrl(string value)
    {
        return string.IsNullOrWhiteSpace(value) ? string.Empty : value.Trim().TrimEnd('/');
    }

    internal static Icon TryGetExecutableIcon()
    {
        try
        {
            string executablePath = Application.ExecutablePath;
            if (string.IsNullOrWhiteSpace(executablePath) || !File.Exists(executablePath))
            {
                return null;
            }

            Icon icon = Icon.ExtractAssociatedIcon(executablePath);
            return icon == null ? null : (Icon)icon.Clone();
        }
        catch
        {
            return null;
        }
    }

    internal static bool IsAdministrator()
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

    internal static int ElevateSelf(string[] args)
    {
        if (ContainsSentinel(args))
        {
            throw new InvalidOperationException(T("安装器提权失败。", "The installer elevation flow failed."));
        }

        string exePath = Process.GetCurrentProcess().MainModule.FileName;
        string[] elevatedArgs = PrependSentinel(args);
        ProcessStartInfo startInfo = new ProcessStartInfo(exePath, BuildArguments(elevatedArgs));
        startInfo.UseShellExecute = true;
        startInfo.Verb = "runas";

        try
        {
            using (Process process = Process.Start(startInfo))
            {
                if (process == null)
                {
                    throw new InvalidOperationException(T("无法启动提权后的安装器。", "Failed to start the elevated installer."));
                }
            }

            return 0;
        }
        catch (Win32Exception ex)
        {
            if (ex.NativeErrorCode == 1223)
            {
                MessageBox.Show(
                    T("未授予管理员权限，安装已取消。", "Administrator permission was not granted. Installation was cancelled."),
                    T("需要管理员权限", "Administrator Permission Required"),
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Warning);
                return 1;
            }

            throw;
        }
    }

    internal static string BuildArguments(IEnumerable<string> args)
    {
        StringBuilder builder = new StringBuilder();
        foreach (string value in args)
        {
            if (builder.Length > 0)
            {
                builder.Append(' ');
            }

            builder.Append(QuoteArgument(value));
        }

        return builder.ToString();
    }

    internal static string QuoteArgument(string value)
    {
        string raw = value ?? string.Empty;
        if (raw.Length == 0)
        {
            return "\"\"";
        }

        if (raw.IndexOfAny(new[] { ' ', '\t', '"' }) < 0)
        {
            return raw;
        }

        return "\"" + raw.Replace("\\", "\\\\").Replace("\"", "\\\"") + "\"";
    }

    internal static void ExtractPayload(string exePath, string payloadZipPath)
    {
        using (FileStream exeStream = File.OpenRead(exePath))
        {
            long payloadLength = ReadPayloadLength(exeStream);
            long payloadOffset = exeStream.Length - payloadLength - Magic.Length - sizeof(long);
            exeStream.Position = payloadOffset;
            using (FileStream payloadStream = File.Create(payloadZipPath))
            {
                CopyBytes(exeStream, payloadStream, payloadLength);
            }
        }
    }

    internal static void ExtractZip(string zipPath, string extractRoot)
    {
        if (!File.Exists(zipPath))
        {
            throw new FileNotFoundException(T("未找到安装载荷压缩包。", "The installer payload archive was not found."), zipPath);
        }

        Directory.CreateDirectory(extractRoot);
        ZipFile.ExtractToDirectory(zipPath, extractRoot);
    }

    internal static void TryDelete(string path)
    {
        try
        {
            if (!string.IsNullOrWhiteSpace(path) && File.Exists(path))
            {
                File.Delete(path);
            }
        }
        catch
        {
        }
    }

    internal static void TryDeleteDirectory(string path)
    {
        try
        {
            if (!string.IsNullOrWhiteSpace(path) && Directory.Exists(path))
            {
                Directory.Delete(path, true);
            }
        }
        catch
        {
        }
    }

    internal static Dictionary<string, object> DeserializeJsonObject(string content)
    {
        if (string.IsNullOrWhiteSpace(content))
        {
            return new Dictionary<string, object>(StringComparer.OrdinalIgnoreCase);
        }

        JavaScriptSerializer serializer = new JavaScriptSerializer();
        object value = serializer.DeserializeObject(content);
        Dictionary<string, object> dictionary = value as Dictionary<string, object>;
        return dictionary ?? new Dictionary<string, object>(StringComparer.OrdinalIgnoreCase);
    }

    internal static string GetString(IDictionary<string, object> dictionary, string key)
    {
        if (dictionary == null || string.IsNullOrWhiteSpace(key))
        {
            return string.Empty;
        }

        foreach (KeyValuePair<string, object> pair in dictionary)
        {
            if (string.Equals(pair.Key, key, StringComparison.OrdinalIgnoreCase))
            {
                return pair.Value == null ? string.Empty : Convert.ToString(pair.Value);
            }
        }

        return string.Empty;
    }

    private static bool ContainsSentinel(IEnumerable<string> args)
    {
        foreach (string value in args)
        {
            if (string.Equals(value, ElevationSentinel, StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }
        }

        return false;
    }

    private static string[] PrependSentinel(string[] args)
    {
        string[] source = args ?? new string[0];
        string[] result = new string[source.Length + 1];
        result[0] = ElevationSentinel;
        for (int index = 0; index < source.Length; index++)
        {
            result[index + 1] = source[index];
        }

        return result;
    }

    private static long ReadPayloadLength(FileStream exeStream)
    {
        int trailerSize = Magic.Length + sizeof(long);
        if (exeStream.Length < trailerSize)
        {
            throw new InvalidDataException(T("安装器载荷头无效。", "The installer payload header is invalid."));
        }

        exeStream.Position = exeStream.Length - trailerSize;
        byte[] trailer = new byte[trailerSize];
        ReadExact(exeStream, trailer, 0, trailer.Length);

        long payloadLength = -1;
        if (TrailerHasMagicAt(trailer, 0))
        {
            payloadLength = BitConverter.ToInt64(trailer, Magic.Length);
        }
        else if (TrailerHasMagicAt(trailer, sizeof(long)))
        {
            payloadLength = BitConverter.ToInt64(trailer, 0);
        }
        else
        {
            if (payloadLength < 0)
            {
                throw new InvalidDataException(T("未找到安装器内嵌载荷。", "The embedded installer payload was not found."));
            }
        }

        long payloadOffset = exeStream.Length - trailerSize - payloadLength;
        if (payloadLength <= 0 || payloadOffset < 0)
        {
            throw new InvalidDataException(T("The embedded installer payload length is invalid.", "The embedded installer payload length is invalid."));
        }

        return payloadLength;
    }

    private static bool TrailerHasMagicAt(byte[] trailer, int offset)
    {
        if (trailer == null || offset < 0 || trailer.Length < offset + Magic.Length)
        {
            return false;
        }

        for (int index = 0; index < Magic.Length; index++)
        {
            if (trailer[offset + index] != Magic[index])
            {
                return false;
            }
        }

        return true;
    }

    private static void CopyBytes(Stream input, Stream output, long bytesToCopy)
    {
        byte[] buffer = new byte[81920];
        long remaining = bytesToCopy;
        while (remaining > 0)
        {
            int read = input.Read(buffer, 0, (int)Math.Min(buffer.Length, remaining));
            if (read <= 0)
            {
                throw new EndOfStreamException(T("安装器载荷已损坏。", "The embedded installer payload is corrupted."));
            }

            output.Write(buffer, 0, read);
            remaining -= read;
        }
    }

    private static void ReadExact(Stream stream, byte[] buffer, int offset, int count)
    {
        int readTotal = 0;
        while (readTotal < count)
        {
            int read = stream.Read(buffer, offset + readTotal, count - readTotal);
            if (read <= 0)
            {
                throw new EndOfStreamException(T("读取安装器载荷时发生截断。", "The installer payload was truncated unexpectedly."));
            }

            readTotal += read;
        }
    }
}

internal sealed class BootstrapForm : Form
{
    private readonly TextBox authorizationCodeTextBox;
    private readonly TextBox apiBaseUrlTextBox;
    private readonly TextBox logTextBox;
    private readonly Label statusLabel;
    private readonly Label stepReadyLabel;
    private readonly Label stepValidateLabel;
    private readonly Label stepInstallLabel;
    private readonly Button installButton;
    private readonly Button cancelButton;
    private readonly Button networkToggleButton;
    private readonly Button logToggleButton;
    private readonly ProgressBar progressBar;
    private readonly Panel authorizationPanel;
    private readonly Panel networkPanel;
    private readonly Panel logPanel;
    private readonly string installStatePath;
    private readonly string licenseStatePath;
    private bool workflowRunning;
    private bool networkExpanded;
    private bool logExpanded;
    private string extractRoot;
    private string helperPath;
    private string runInstallPath;
    private string installationId;
    private string validatedActivationId;
    private FileSnapshot originalInstallStateSnapshot;
    private FileSnapshot originalLicenseStateSnapshot;
    private WorkflowStage lastNonFailedStage = WorkflowStage.Ready;

    public int ResultExitCode { get; private set; }

    private enum WorkflowStage
    {
        Ready = 0,
        Validating = 1,
        Installing = 2,
        Completed = 3,
        Failed = 4
    }

    private static readonly Color RootBackground = Color.FromArgb(241, 246, 252);
    private static readonly Color SurfaceBackground = Color.FromArgb(248, 251, 255);
    private static readonly Color SurfaceRaised = Color.FromArgb(255, 255, 255);
    private static readonly Color SurfaceBorder = Color.FromArgb(204, 219, 238);
    private static readonly Color TextPrimary = Color.FromArgb(29, 49, 78);
    private static readonly Color TextSecondary = Color.FromArgb(86, 112, 147);
    private static readonly Color Accent = Color.FromArgb(47, 117, 214);
    private static readonly Color AccentSoft = Color.FromArgb(223, 236, 252);
    private static readonly Color Success = Color.FromArgb(39, 157, 111);
    private static readonly Color Error = Color.FromArgb(196, 59, 79);
    private const int HelperProcessTimeoutMilliseconds = 120000;
    private const int InstallerProcessTimeoutMilliseconds = 1800000;
    private readonly object activeProcessLock = new object();
    private Process activeProcess;
    private bool forceCloseRequested;

    public BootstrapForm()
    {
        ResultExitCode = 1;
        installStatePath = Program.GetInstallStatePath();
        licenseStatePath = Program.GetLicenseStatePath();
        Text = Program.T("OpenClaw Windows 安装器", "OpenClaw Windows Installer");
        StartPosition = FormStartPosition.CenterScreen;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        MinimizeBox = true;
        ShowIcon = true;
        ClientSize = new Size(980, 700);
        BackColor = RootBackground;
        ForeColor = TextPrimary;
        Font = new Font("Segoe UI", 9F, FontStyle.Regular, GraphicsUnit.Point);
        AutoScaleMode = AutoScaleMode.Dpi;
        Icon windowIcon = Program.TryGetExecutableIcon();
        if (windowIcon != null)
        {
            Icon = windowIcon;
        }
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.UserPaint, true);
        UpdateStyles();
        Paint += PaintBackgroundGlow;

        Panel header = new Panel();
        header.Dock = DockStyle.Top;
        header.Height = 136;
        header.BackColor = Color.FromArgb(235, 244, 254);
        header.BorderStyle = BorderStyle.None;
        Controls.Add(header);

        Label title = new Label();
        title.Left = 30;
        title.Top = 22;
        title.Width = 720;
        title.Height = 34;
        title.ForeColor = TextPrimary;
        title.Font = new Font("Segoe UI Semibold", 20F, FontStyle.Bold, GraphicsUnit.Point);
        title.Text = Program.T("OpenClaw Windows 安装器", "OpenClaw Windows Installer");
        header.Controls.Add(title);

        Label subtitle = new Label();
        subtitle.Left = 32;
        subtitle.Top = 64;
        subtitle.Width = 800;
        subtitle.Height = 40;
        subtitle.ForeColor = TextSecondary;
        subtitle.Font = new Font("Segoe UI", 9.5F, FontStyle.Regular, GraphicsUnit.Point);
        subtitle.Text = Program.T(
            "点击下方按钮即可开始安装，完成后可直接使用。",
            "Click the button below to start installation.");
        header.Controls.Add(subtitle);

        Label signatureLabel = new Label();
        signatureLabel.Left = 792;
        signatureLabel.Top = 72;
        signatureLabel.Width = 140;
        signatureLabel.Height = 24;
        signatureLabel.TextAlign = ContentAlignment.MiddleRight;
        signatureLabel.ForeColor = TextSecondary;
        signatureLabel.Font = new Font("Segoe UI", 9F, FontStyle.Italic, GraphicsUnit.Point);
        signatureLabel.Text = "by 那纸";
        header.Controls.Add(signatureLabel);

        networkToggleButton = new Button();
        networkToggleButton.Left = 790;
        networkToggleButton.Top = 30;
        networkToggleButton.Width = 138;
        networkToggleButton.Height = 34;
        networkToggleButton.Text = Program.T("网络设置", "Network Settings");
        StyleGhostButton(networkToggleButton);
        networkToggleButton.Click += delegate { ToggleNetworkPanel(); };
        networkToggleButton.Visible = false;
        header.Controls.Add(networkToggleButton);

        authorizationPanel = new Panel();
        authorizationPanel.Left = 24;
        authorizationPanel.Top = 284;
        authorizationPanel.Width = 932;
        authorizationPanel.Height = 104;
        StyleCardPanel(authorizationPanel, SurfaceRaised);
        Controls.Add(authorizationPanel);

        Label codeLabel = new Label();
        codeLabel.Left = 24;
        codeLabel.Top = 18;
        codeLabel.Width = 260;
        codeLabel.Text = Program.T("安装准备", "Installation Preparation");
        codeLabel.Font = new Font("Segoe UI Semibold", 11F, FontStyle.Bold, GraphicsUnit.Point);
        codeLabel.ForeColor = TextPrimary;
        authorizationPanel.Controls.Add(codeLabel);

        authorizationCodeTextBox = new TextBox();
        authorizationCodeTextBox.Left = 24;
        authorizationCodeTextBox.Top = 48;
        authorizationCodeTextBox.Width = 620;
        authorizationCodeTextBox.Height = 34;
        authorizationCodeTextBox.Font = new Font("Segoe UI", 12F, FontStyle.Regular, GraphicsUnit.Point);
        authorizationCodeTextBox.CharacterCasing = CharacterCasing.Upper;
        authorizationCodeTextBox.MaxLength = 64;
        StyleTextBox(authorizationCodeTextBox, true);
        authorizationPanel.Controls.Add(authorizationCodeTextBox);

        installButton = new Button();
        installButton.Left = 664;
        installButton.Top = 45;
        installButton.Width = 220;
        installButton.Height = 38;
        installButton.Text = Program.T("开始安装", "Start Installation");
        StylePrimaryButton(installButton);
        installButton.Click += async delegate { await StartWorkflowAsync(); };
        authorizationPanel.Controls.Add(installButton);

        if (!Program.RequireLicenseGate)
        {
            codeLabel.Text = Program.T("安装准备", "Installation");
            authorizationCodeTextBox.Visible = false;
            installButton.Left = 24;
            installButton.Top = 48;
            installButton.Width = 860;
        }

        networkPanel = new Panel();
        networkPanel.Left = 24;
        networkPanel.Top = 398;
        networkPanel.Width = 932;
        networkPanel.Height = 86;
        StyleCardPanel(networkPanel, SurfaceBackground);
        networkPanel.Visible = false;
        Controls.Add(networkPanel);

        Label apiLabel = new Label();
        apiLabel.Left = 24;
        apiLabel.Top = 12;
        apiLabel.Width = 240;
        apiLabel.Text = Program.T("License API 地址", "License API URL");
        apiLabel.Font = new Font("Segoe UI Semibold", 10F, FontStyle.Bold, GraphicsUnit.Point);
        apiLabel.ForeColor = TextPrimary;
        networkPanel.Controls.Add(apiLabel);

        apiBaseUrlTextBox = new TextBox();
        apiBaseUrlTextBox.Left = 24;
        apiBaseUrlTextBox.Top = 36;
        apiBaseUrlTextBox.Width = 860;
        apiBaseUrlTextBox.Height = 30;
        apiBaseUrlTextBox.Font = new Font("Segoe UI", 10F, FontStyle.Regular, GraphicsUnit.Point);
        apiBaseUrlTextBox.Text = Program.GetInitialApiBaseUrl();
        StyleTextBox(apiBaseUrlTextBox, false);
        networkPanel.Controls.Add(apiBaseUrlTextBox);

        Panel statusPanel = new Panel();
        statusPanel.Left = 24;
        statusPanel.Top = 146;
        statusPanel.Width = 932;
        statusPanel.Height = 124;
        StyleCardPanel(statusPanel, SurfaceRaised);
        Controls.Add(statusPanel);

        statusLabel = new Label();
        statusLabel.Left = 24;
        statusLabel.Top = 70;
        statusLabel.Width = 860;
        statusLabel.Height = 26;
        statusLabel.Font = new Font("Segoe UI", 10.5F, FontStyle.Bold, GraphicsUnit.Point);
        statusLabel.ForeColor = TextPrimary;
        statusLabel.Text = Program.T("准备开始安装。", "Ready to start installation.");
        statusPanel.Controls.Add(statusLabel);

        stepReadyLabel = BuildStepLabel(24, Program.T("1. 准备安装", "1. Prepare"));
        statusPanel.Controls.Add(stepReadyLabel);

        stepValidateLabel = BuildStepLabel(300, Program.T("2. 执行安装", "2. Install"));
        statusPanel.Controls.Add(stepValidateLabel);

        stepInstallLabel = BuildStepLabel(576, Program.T("3. 完成确认", "3. Complete"));
        statusPanel.Controls.Add(stepInstallLabel);

        progressBar = new ProgressBar();
        progressBar.Left = 24;
        progressBar.Top = 498;
        progressBar.Width = 932;
        progressBar.Height = 14;
        progressBar.Style = ProgressBarStyle.Continuous;
        progressBar.Minimum = 0;
        progressBar.Maximum = 100;
        progressBar.Value = 0;
        progressBar.ForeColor = Accent;
        progressBar.BackColor = AccentSoft;
        Controls.Add(progressBar);

        logToggleButton = new Button();
        logToggleButton.Left = 24;
        logToggleButton.Top = 524;
        logToggleButton.Width = 138;
        logToggleButton.Height = 30;
        logToggleButton.Text = Program.T("显示详细日志", "Show Details");
        StyleGhostButton(logToggleButton);
        logToggleButton.Click += delegate { ToggleLogPanel(); };
        Controls.Add(logToggleButton);

        logPanel = new Panel();
        logPanel.Left = 24;
        logPanel.Top = 562;
        logPanel.Width = 932;
        logPanel.Height = 118;
        StyleCardPanel(logPanel, SurfaceBackground);
        logPanel.Visible = false;
        Controls.Add(logPanel);

        logTextBox = new TextBox();
        logTextBox.Left = 0;
        logTextBox.Top = 0;
        logTextBox.Width = 932;
        logTextBox.Height = 118;
        logTextBox.Multiline = true;
        logTextBox.ScrollBars = ScrollBars.Vertical;
        logTextBox.ReadOnly = true;
        logTextBox.BorderStyle = BorderStyle.None;
        logTextBox.BackColor = SurfaceBackground;
        logTextBox.ForeColor = Color.FromArgb(183, 196, 219);
        logTextBox.Font = new Font("Consolas", 9.5F, FontStyle.Regular, GraphicsUnit.Point);
        logPanel.Controls.Add(logTextBox);

        cancelButton = new Button();
        cancelButton.Left = 846;
        cancelButton.Top = 524;
        cancelButton.Width = 110;
        cancelButton.Height = 34;
        cancelButton.Text = Program.T("退出", "Exit");
        StyleGhostButton(cancelButton);
        cancelButton.Click += delegate { Close(); };
        Controls.Add(cancelButton);

        AcceptButton = installButton;
        CancelButton = cancelButton;
        FormClosing += OnFormClosing;
        ApplyRoundedRegion(authorizationPanel, 16);
        ApplyRoundedRegion(networkPanel, 16);
        ApplyRoundedRegion(statusPanel, 16);
        ApplyRoundedRegion(logPanel, 14);
        ApplyRoundedRegion(installButton, 14);
        ApplyRoundedRegion(networkToggleButton, 12);
        ApplyRoundedRegion(logToggleButton, 12);
        ApplyRoundedRegion(cancelButton, 12);
        if (Program.RequireLicenseGate)
        {
            SetWorkflowStage(WorkflowStage.Ready, Program.T("请输入授权码后点击“验证并安装”。", "Enter your code and click Validate and Install."), 0);
            AppendLog(Program.T("安装器已启动，等待输入授权码。", "Installer started. Waiting for authorization input."));
        }
        else
        {
            SetWorkflowStage(WorkflowStage.Ready, Program.T("点击“开始安装”继续。", "Click Start Installation to continue."), 0);
            AppendLog(Program.T("安装器已启动。", "Installer started."));
        }
    }

    private async Task StartWorkflowAsync()
    {
        if (workflowRunning)
        {
            return;
        }

        string authorizationCode = (authorizationCodeTextBox.Text ?? string.Empty).Trim().ToUpperInvariant();
        string apiBaseUrl = Program.NormalizeBaseUrl(apiBaseUrlTextBox.Text);
        if (Program.RequireLicenseGate && string.IsNullOrWhiteSpace(authorizationCode))
        {
            ShowValidationError(Program.T("请输入授权码后再继续。", "Enter the authorization code before continuing."));
            return;
        }

        if (Program.RequireLicenseGate && string.IsNullOrWhiteSpace(apiBaseUrl))
        {
            ShowValidationError(Program.T("网络设置中的 License API 地址为空，请填写后重试。", "The License API URL in network settings is empty. Fill it and retry."));
            return;
        }

        if (!Program.RequireLicenseGate)
        {
            authorizationCode = string.Empty;
            apiBaseUrl = string.Empty;
        }

        workflowRunning = true;
        forceCloseRequested = false;
        SetWorkflowStage(
            WorkflowStage.Validating,
            Program.RequireLicenseGate
                ? Program.T("正在校验授权码，请稍候...", "Validating authorization code...")
                : Program.T("正在准备安装环境，请稍候...", "Preparing installation environment..."),
            18);
        installationId = string.IsNullOrWhiteSpace(installationId) ? Guid.NewGuid().ToString("N") : installationId;

        try
        {
            originalInstallStateSnapshot = FileSnapshot.Capture(installStatePath);
            originalLicenseStateSnapshot = FileSnapshot.Capture(licenseStatePath);
            EnsurePayloadPrepared();

            if (Program.RequireLicenseGate)
            {
                HelperResult activation = RunHelperActivate(apiBaseUrl, authorizationCode);
                validatedActivationId = activation.ActivationId;
                if (forceCloseRequested || IsDisposed)
                {
                    return;
                }

                AppendLog(Program.T("授权验证通过，准备启动安装。", "Authorization validated. Preparing installation."));
                SetWorkflowStage(WorkflowStage.Validating, Program.T("授权验证通过，准备切换到安装阶段...", "Authorization validated. Switching to installation stage..."), 32);
            }
            else
            {
                validatedActivationId = null;
                AppendLog(Program.T("安装环境准备完成，开始安装。", "Installation environment is ready. Starting setup."));
                SetWorkflowStage(WorkflowStage.Validating, Program.T("安装准备完成，正在切换到安装阶段...", "Preparation completed. Switching to installation..."), 32);
            }

            if (forceCloseRequested || IsDisposed)
            {
                return;
            }
            SetInstallerViewMode(true);
            RestoreInstallStateSnapshot();
            SetWorkflowStage(
                WorkflowStage.Installing,
                Program.RequireLicenseGate
                    ? Program.T("授权通过，正在安装组件...", "Authorization validated. Installing components...")
                    : Program.T("正在安装组件...", "Installing components..."),
                55);
            int exitCode = await RunInstallerAsync(apiBaseUrl, authorizationCode);
            if (forceCloseRequested || IsDisposed)
            {
                return;
            }
            if (exitCode != 0)
            {
                if (Program.RequireLicenseGate)
                {
                    AppendLog(Program.T("安装失败，正在回收本次预激活状态。", "Installation failed. Releasing the prevalidated activation."));
                    RollbackPrevalidatedState(apiBaseUrl);
                }

                SetWorkflowStage(WorkflowStage.Failed, Program.T("安装未完成，请根据提示修复后重试。", "Installation did not complete. Fix the issue and try again."), 0);
                MessageBox.Show(
                    this,
                    Program.RequireLicenseGate
                        ? Program.T("安装未完成，授权状态已回滚。请修复问题后重新运行安装器。", "Installation did not complete. The prevalidated state was rolled back. Fix the issue and rerun the installer.")
                        : Program.T("安装未完成。请修复问题后重新运行安装器。", "Installation did not complete. Fix the issue and rerun the installer."),
                    Program.T("安装失败", "Installation Failed"),
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Error);
                return;
            }

            SetWorkflowStage(WorkflowStage.Completed, Program.T("安装完成，可以开始使用。", "Installation completed and ready to use."), 100);
            ResultExitCode = 0;
            MessageBox.Show(
                this,
                Program.T("安装已完成，后续正常窗口和 PowerShell 流程会继续按既有逻辑运行。", "Installation completed. The normal windows and PowerShell flows continue with their existing behavior."),
                Program.T("安装完成", "Installation Complete"),
                MessageBoxButtons.OK,
                MessageBoxIcon.Information);
            workflowRunning = false;
            Close();
        }
        catch (Exception ex)
        {
            if (forceCloseRequested || IsDisposed)
            {
                return;
            }

            AppendLog(ex.Message);
            if (Program.RequireLicenseGate)
            {
                RollbackPrevalidatedState(apiBaseUrl);
                SetWorkflowStage(WorkflowStage.Failed, Program.T("授权验证失败，请修正后重试。", "Validation failed. Correct the issue and retry."), 0);
            }
            else
            {
                SetWorkflowStage(WorkflowStage.Failed, Program.T("安装失败，请修正后重试。", "Installation failed. Correct the issue and retry."), 0);
            }

            MessageBox.Show(
                this,
                ex.Message,
                    Program.RequireLicenseGate
                        ? Program.T("校验失败", "Validation Failed")
                        : Program.T("安装失败", "Installation Failed"),
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
        }
        finally
        {
            workflowRunning = false;
        }
    }

    private void EnsurePayloadPrepared()
    {
        if (!string.IsNullOrWhiteSpace(helperPath) && File.Exists(helperPath) && !string.IsNullOrWhiteSpace(runInstallPath) && File.Exists(runInstallPath))
        {
            return;
        }

        AppendLog(Program.T("正在解包安装载荷...", "Extracting the installer payload..."));
        string exePath = Process.GetCurrentProcess().MainModule.FileName;
        extractRoot = Path.Combine(Path.GetTempPath(), "openclaw-oneclick-run-" + Guid.NewGuid().ToString("N"));
        Program.EnsureDirectory(extractRoot);
        string payloadZipPath = Path.Combine(Path.GetTempPath(), "openclaw-oneclick-payload-" + Guid.NewGuid().ToString("N") + ".zip");
        try
        {
            Program.ExtractPayload(exePath, payloadZipPath);
            Program.ExtractZip(payloadZipPath, extractRoot);
        }
        finally
        {
            Program.TryDelete(payloadZipPath);
        }

        helperPath = Path.Combine(extractRoot, "OpenClaw-License.exe");
        runInstallPath = Path.Combine(extractRoot, "run-install.cmd");
        if (Program.RequireLicenseGate && !File.Exists(helperPath))
        {
            throw new FileNotFoundException(Program.T("安装载荷中缺少授权 helper。", "The embedded payload is missing the license helper."), helperPath);
        }

        if (!File.Exists(runInstallPath))
        {
            throw new FileNotFoundException(Program.T("安装载荷中缺少 run-install.cmd。", "The embedded payload is missing run-install.cmd."), runInstallPath);
        }
    }

    private HelperResult RunHelperActivate(string apiBaseUrl, string authorizationCode)
    {
        AppendLog(Program.T("正在向授权中心校验授权码...", "Validating the authorization code with the license service..."));
        Dictionary<string, string> env = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        env["OPENCLAW_LICENSE_API_BASE_URL"] = apiBaseUrl;
        env["OPENCLAW_INSTALLATION_ID"] = installationId;

        ProcessCapture capture = RunProcessCapture(
            helperPath,
            "activate --mode cli --json --code " + Program.QuoteArgument(authorizationCode),
            extractRoot,
            env,
            HelperProcessTimeoutMilliseconds,
            Program.T("Authorization validation timed out. Check network and retry.", "Authorization validation timed out. Check network and retry."));

        HelperResult result = HelperResult.FromCapture(capture);
        if (capture.ExitCode != 0)
        {
            RestoreOriginalStateFiles();
            string friendlyMessage = BuildFriendlyValidationMessage(result);
            throw new InvalidOperationException(friendlyMessage);
        }

        AppendLog(string.IsNullOrWhiteSpace(result.Message)
            ? Program.T("授权验证成功。", "Authorization validated successfully.")
            : result.Message);
        return result;
    }

    private string BuildFriendlyValidationMessage(HelperResult result)
    {
        string status = (result.Status ?? string.Empty).Trim().ToLowerInvariant();
        switch (status)
        {
            case "invalid-code":
            case "not-activated":
                return Program.T("授权码无效，请确认输入内容后重试。", "The authorization code is invalid. Verify the code and retry.");
            case "revoked":
                return Program.T("该授权码已停用，请联系管理员重新发码。", "This authorization code has been revoked. Contact your administrator.");
            case "device-limit-exceeded":
                return Program.T("该授权码已达到设备上限，请先在后台释放旧设备。", "This code has reached the device limit. Release an old device in admin console first.");
            case "offline":
            case "offline-without-valid-lease":
                return Program.T("无法连接授权服务，请检查网络或稍后重试。", "Cannot reach the license service. Check network and retry.");
            case "misconfigured":
                return Program.T("授权服务地址配置无效，请检查网络设置。", "The license service URL is invalid. Check network settings.");
            default:
                if (result.ExitCode == 44)
                {
                    return Program.T("授权服务暂不可用，请检查网络后重试。", "License service is unavailable. Check network and retry.");
                }

                if (!string.IsNullOrWhiteSpace(result.Message))
                {
                    return result.Message;
                }

                return Program.T("授权验证失败，请确认授权码和网络设置。", "Authorization validation failed. Check code and network settings.");
        }
    }

    private Task<int> RunInstallerAsync(string apiBaseUrl, string authorizationCode)
    {
        AppendLog(Program.T("开始执行安装脚本。", "Starting the installer script."));
        return Task.Run(delegate
        {
            ProcessStartInfo startInfo = new ProcessStartInfo("cmd.exe", "/d /s /c \"\"" + runInstallPath + "\"\"")
            {
                WorkingDirectory = extractRoot,
                UseShellExecute = false,
                RedirectStandardOutput = false,
                RedirectStandardError = false,
                CreateNoWindow = false
            };
            if (!string.IsNullOrWhiteSpace(apiBaseUrl))
            {
                startInfo.EnvironmentVariables["OPENCLAW_LICENSE_API_BASE_URL"] = apiBaseUrl;
            }
            if (!string.IsNullOrWhiteSpace(authorizationCode))
            {
                startInfo.EnvironmentVariables["OPENCLAW_INSTALLER_AUTH_CODE"] = authorizationCode;
            }
            startInfo.EnvironmentVariables["OPENCLAW_INSTALLATION_ID"] = installationId;

            using (Process process = new Process())
            {
                process.StartInfo = startInfo;

                if (!process.Start())
                {
                    throw new InvalidOperationException(Program.T("无法启动安装脚本。", "Failed to start the installer script."));
                }

                AppendLog(Program.T("已打开外部 PowerShell 安装窗口，请在该窗口中查看实时安装输出。", "An external PowerShell install window is open. View live installer output there."));
                RegisterActiveProcess(process);
                try
                {
                    if (!process.WaitForExit(InstallerProcessTimeoutMilliseconds))
                    {
                        TryTerminateProcess(process);
                        throw new TimeoutException(Program.T("Installation timed out. Force close and retry.", "Installation timed out. Force close and retry."));
                    }

                    process.WaitForExit();
                    return process.ExitCode;
                }
                finally
                {
                    ClearActiveProcess(process);
                }
            }
        });
    }

    private void RollbackPrevalidatedState(string apiBaseUrl)
    {
        if (ShouldReleasePrevalidatedActivation())
        {
            try
            {
                RunProcessCapture(
                    helperPath,
                    "release --json",
                    extractRoot,
                    new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
                    {
                        { "OPENCLAW_LICENSE_API_BASE_URL", apiBaseUrl }
                    },
                    30000,
                    Program.T("Timed out while releasing prevalidated activation. Ignored.", "Timed out while releasing prevalidated activation. Ignored."));
            }
            catch (Exception ex)
            {
                AppendLog(Program.T("回收预激活状态失败：", "Failed to release the prevalidated activation: ") + ex.Message);
            }
        }

        RestoreOriginalStateFiles();
    }

    private bool ShouldReleasePrevalidatedActivation()
    {
        if (string.IsNullOrWhiteSpace(validatedActivationId))
        {
            return false;
        }

        string originalActivationId = originalLicenseStateSnapshot == null ? string.Empty : originalLicenseStateSnapshot.ActivationId;
        return string.IsNullOrWhiteSpace(originalActivationId) || !string.Equals(originalActivationId, validatedActivationId, StringComparison.OrdinalIgnoreCase);
    }

    private void RestoreInstallStateSnapshot()
    {
        FileSnapshot.Restore(installStatePath, originalInstallStateSnapshot);
    }

    private void RestoreOriginalStateFiles()
    {
        FileSnapshot.Restore(installStatePath, originalInstallStateSnapshot);
        FileSnapshot.Restore(licenseStatePath, originalLicenseStateSnapshot);
    }

    private ProcessCapture RunProcessCapture(string fileName, string arguments, string workingDirectory, IDictionary<string, string> environmentVariables, int timeoutMilliseconds, string timeoutMessage)
    {
        ProcessStartInfo startInfo = new ProcessStartInfo(fileName, arguments)
        {
            WorkingDirectory = workingDirectory,
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8
        };

        if (environmentVariables != null)
        {
            foreach (KeyValuePair<string, string> pair in environmentVariables)
            {
                startInfo.EnvironmentVariables[pair.Key] = pair.Value ?? string.Empty;
            }
        }

        using (Process process = new Process())
        {
            StringBuilder outputBuilder = new StringBuilder();
            StringBuilder errorBuilder = new StringBuilder();
            object syncLock = new object();
            process.StartInfo = startInfo;
            process.OutputDataReceived += delegate(object sender, DataReceivedEventArgs args)
            {
                if (string.IsNullOrWhiteSpace(args.Data))
                {
                    return;
                }

                lock (syncLock)
                {
                    outputBuilder.AppendLine(args.Data);
                }
            };
            process.ErrorDataReceived += delegate(object sender, DataReceivedEventArgs args)
            {
                if (string.IsNullOrWhiteSpace(args.Data))
                {
                    return;
                }

                lock (syncLock)
                {
                    errorBuilder.AppendLine(args.Data);
                }
            };
            if (!process.Start())
            {
                throw new InvalidOperationException(Program.T("无法启动子进程。", "Failed to start the child process."));
            }

            RegisterActiveProcess(process);
            try
            {
                process.BeginOutputReadLine();
                process.BeginErrorReadLine();
                if (!process.WaitForExit(timeoutMilliseconds))
                {
                    TryTerminateProcess(process);
                    throw new TimeoutException(string.IsNullOrWhiteSpace(timeoutMessage)
                        ? Program.T("The operation timed out. Retry.", "The operation timed out. Retry.")
                        : timeoutMessage);
                }

                process.WaitForExit();
            }
            finally
            {
                ClearActiveProcess(process);
            }

            string standardOutput;
            string standardError;
            lock (syncLock)
            {
                standardOutput = outputBuilder.ToString();
                standardError = errorBuilder.ToString();
            }
            if (!string.IsNullOrWhiteSpace(standardOutput) && !LooksLikeJson(standardOutput))
            {
                AppendLog(standardOutput.Trim());
            }

            if (!string.IsNullOrWhiteSpace(standardError))
            {
                AppendLog("[ERR] " + standardError.Trim());
            }

            return new ProcessCapture(process.ExitCode, standardOutput, standardError);
        }
    }

    private static bool LooksLikeJson(string value)
    {
        string trimmed = (value ?? string.Empty).Trim();
        return trimmed.StartsWith("{", StringComparison.Ordinal) && trimmed.EndsWith("}", StringComparison.Ordinal);
    }

    private Label BuildStepLabel(int left, string text)
    {
        Label label = new Label();
        label.Left = left;
        label.Top = 18;
        label.Width = 272;
        label.Height = 30;
        label.Font = new Font("Segoe UI Semibold", 10F, FontStyle.Bold, GraphicsUnit.Point);
        label.ForeColor = TextSecondary;
        label.BackColor = SurfaceBackground;
        label.Text = text;
        label.TextAlign = ContentAlignment.MiddleLeft;
        return label;
    }

    private void StyleCardPanel(Panel panel, Color fillColor)
    {
        panel.BackColor = fillColor;
        panel.BorderStyle = BorderStyle.None;
    }

    private void StylePrimaryButton(Button button)
    {
        button.BackColor = Accent;
        button.ForeColor = Color.White;
        button.FlatStyle = FlatStyle.Flat;
        button.FlatAppearance.BorderSize = 0;
        button.Font = new Font("Segoe UI Semibold", 10F, FontStyle.Bold, GraphicsUnit.Point);
    }

    private void StyleGhostButton(Button button)
    {
        button.BackColor = Color.FromArgb(238, 245, 253);
        button.ForeColor = Color.FromArgb(41, 72, 111);
        button.FlatStyle = FlatStyle.Flat;
        button.FlatAppearance.BorderColor = SurfaceBorder;
        button.FlatAppearance.BorderSize = 1;
        button.Font = new Font("Segoe UI", 9F, FontStyle.Regular, GraphicsUnit.Point);
    }

    private void StyleTextBox(TextBox box, bool large)
    {
        box.BorderStyle = BorderStyle.FixedSingle;
        box.BackColor = Color.White;
        box.ForeColor = TextPrimary;
        if (large)
        {
            box.Font = new Font("Segoe UI", 12F, FontStyle.Regular, GraphicsUnit.Point);
        }
    }

    private void ApplyRoundedRegion(Control control, int radius)
    {
        if (control == null)
        {
            return;
        }

        Rectangle rect = new Rectangle(0, 0, control.Width, control.Height);
        using (GraphicsPath path = BuildRoundedPath(rect, radius))
        {
            control.Region = new Region(path);
        }
    }

    private GraphicsPath BuildRoundedPath(Rectangle rectangle, int radius)
    {
        GraphicsPath path = new GraphicsPath();
        int diameter = Math.Max(2, radius * 2);
        Rectangle arc = new Rectangle(rectangle.Location, new Size(diameter, diameter));
        path.AddArc(arc, 180, 90);
        arc.X = rectangle.Right - diameter;
        path.AddArc(arc, 270, 90);
        arc.Y = rectangle.Bottom - diameter;
        path.AddArc(arc, 0, 90);
        arc.X = rectangle.Left;
        path.AddArc(arc, 90, 90);
        path.CloseFigure();
        return path;
    }

    private void PaintBackgroundGlow(object sender, PaintEventArgs e)
    {
        using (LinearGradientBrush baseBrush = new LinearGradientBrush(
            ClientRectangle,
            Color.FromArgb(245, 250, 255),
            Color.FromArgb(233, 242, 253),
            90f))
        {
            e.Graphics.FillRectangle(baseBrush, ClientRectangle);
        }

        using (SolidBrush glowOne = new SolidBrush(Color.FromArgb(42, 106, 160, 228)))
        {
            e.Graphics.FillEllipse(glowOne, new Rectangle(700, -120, 340, 340));
        }

        using (SolidBrush glowTwo = new SolidBrush(Color.FromArgb(36, 116, 191, 152)))
        {
            e.Graphics.FillEllipse(glowTwo, new Rectangle(-160, 520, 360, 260));
        }
    }

    private void SetWorkflowStage(WorkflowStage stage, string statusText, int progressValue)
    {
        bool busy = stage == WorkflowStage.Validating || stage == WorkflowStage.Installing;
        bool showBottomTools = stage != WorkflowStage.Ready;
        if (stage != WorkflowStage.Failed)
        {
            lastNonFailedStage = stage;
        }

        statusLabel.Text = statusText;
        progressBar.Visible = showBottomTools;
        logToggleButton.Visible = showBottomTools;
        cancelButton.Visible = showBottomTools;
        progressBar.Style = busy ? ProgressBarStyle.Marquee : ProgressBarStyle.Continuous;
        if (!busy)
        {
            progressBar.Value = Math.Max(progressBar.Minimum, Math.Min(progressBar.Maximum, progressValue));
        }

        if (!showBottomTools)
        {
            SetLogPanelExpanded(false);
        }

        if (stage == WorkflowStage.Installing && showBottomTools)
        {
            SetLogPanelExpanded(true);
        }

        ApplyStepIndicatorState(stage);

        installButton.Enabled = !busy;
        cancelButton.Enabled = true;
        cancelButton.Text = busy
            ? Program.T("Force Exit", "Force Exit")
            : Program.T("退出", "Exit");
        authorizationCodeTextBox.Enabled = !busy;
        apiBaseUrlTextBox.Enabled = !busy;
        networkToggleButton.Enabled = !busy;
        logToggleButton.Enabled = !busy;
        if (!busy)
        {
            cancelButton.Text = Program.T("退出", "Exit");
        }
    }

    private void SetInstallerViewMode(bool installationView)
    {
        authorizationPanel.Visible = !installationView;
        if (installationView)
        {
            networkExpanded = false;
            networkPanel.Visible = false;
            networkToggleButton.Text = Program.T("网络设置", "Network Settings");
            SetLogPanelExpanded(true);
        }
    }

    private void ApplyStepIndicatorState(WorkflowStage stage)
    {
        bool readyComplete = false;
        bool readyActive = false;
        bool readyFailed = false;
        bool validateComplete = false;
        bool validateActive = false;
        bool validateFailed = false;
        bool installComplete = false;
        bool installActive = false;
        bool installFailed = false;

        switch (stage)
        {
            case WorkflowStage.Ready:
                readyActive = true;
                break;
            case WorkflowStage.Validating:
                readyComplete = true;
                validateActive = true;
                break;
            case WorkflowStage.Installing:
                readyComplete = true;
                validateComplete = true;
                installActive = true;
                break;
            case WorkflowStage.Completed:
                readyComplete = true;
                validateComplete = true;
                installComplete = true;
                break;
            case WorkflowStage.Failed:
                if (lastNonFailedStage == WorkflowStage.Validating)
                {
                    readyComplete = true;
                    validateFailed = true;
                }
                else if (lastNonFailedStage == WorkflowStage.Installing)
                {
                    readyComplete = true;
                    validateComplete = true;
                    installFailed = true;
                }
                else
                {
                    readyFailed = true;
                }

                break;
        }

        ApplyStepVisual(stepReadyLabel, readyComplete, readyActive, readyFailed);
        ApplyStepVisual(stepValidateLabel, validateComplete, validateActive, validateFailed);
        ApplyStepVisual(stepInstallLabel, installComplete, installActive, installFailed);
    }

    private void ApplyStepVisual(Label label, bool completed, bool active, bool failed)
    {
        if (failed)
        {
            label.ForeColor = Error;
            label.BackColor = Color.FromArgb(255, 236, 239);
            return;
        }

        if (active)
        {
            label.ForeColor = Accent;
            label.BackColor = Color.FromArgb(229, 240, 255);
            return;
        }

        if (completed)
        {
            label.ForeColor = Success;
            label.BackColor = Color.FromArgb(232, 248, 241);
            return;
        }

        label.ForeColor = TextSecondary;
        label.BackColor = SurfaceBackground;
    }

    private void ToggleNetworkPanel()
    {
        networkExpanded = !networkExpanded;
        networkPanel.Visible = networkExpanded;
        networkToggleButton.Text = networkExpanded
            ? Program.T("隐藏网络设置", "Hide Network Settings")
            : Program.T("网络设置", "Network Settings");
    }

    private void ToggleLogPanel()
    {
        SetLogPanelExpanded(!logExpanded);
    }

    private void SetLogPanelExpanded(bool expanded)
    {
        logExpanded = expanded;
        logPanel.Visible = expanded;
        logPanel.Height = expanded ? 118 : 0;
        if (expanded)
        {
            ApplyRoundedRegion(logPanel, 14);
            logPanel.BringToFront();
        }

        logToggleButton.Text = expanded
            ? Program.T("隐藏详细日志", "Hide Details")
            : Program.T("显示详细日志", "Show Details");
    }

    private void ShowValidationError(string message)
    {
        statusLabel.Text = message;
        MessageBox.Show(this, message, Program.T("需要补充信息", "Missing Required Information"), MessageBoxButtons.OK, MessageBoxIcon.Warning);
    }

    private void AppendLog(string message)
    {
        if (string.IsNullOrWhiteSpace(message))
        {
            return;
        }

        if (logTextBox.TextLength > 0)
        {
            logTextBox.AppendText(Environment.NewLine);
        }

        logTextBox.AppendText(string.Format("[{0}] {1}", DateTime.Now.ToString("HH:mm:ss"), message.Trim()));
        logTextBox.SelectionStart = logTextBox.TextLength;
        logTextBox.ScrollToCaret();
    }

    private void AppendLogSafe(string message)
    {
        if (IsDisposed)
        {
            return;
        }

        if (InvokeRequired)
        {
            BeginInvoke((MethodInvoker)delegate { AppendLog(message); });
            return;
        }

        AppendLog(message);
    }

    private void RegisterActiveProcess(Process process)
    {
        lock (activeProcessLock)
        {
            activeProcess = process;
        }
    }

    private void ClearActiveProcess(Process process)
    {
        lock (activeProcessLock)
        {
            if (process == null || object.ReferenceEquals(activeProcess, process))
            {
                activeProcess = null;
            }
        }
    }

    private void TryTerminateActiveProcess()
    {
        Process process = null;
        lock (activeProcessLock)
        {
            process = activeProcess;
        }

        TryTerminateProcess(process);
    }

    private static void TryTerminateProcess(Process process)
    {
        if (process == null)
        {
            return;
        }

        try
        {
            if (process.HasExited)
            {
                return;
            }
        }
        catch
        {
            return;
        }

        try
        {
            MethodInfo killTreeMethod = typeof(Process).GetMethod("Kill", new[] { typeof(bool) });
            if (killTreeMethod != null)
            {
                killTreeMethod.Invoke(process, new object[] { true });
                return;
            }
        }
        catch
        {
        }

        try
        {
            process.Kill();
        }
        catch
        {
        }
    }

    private void OnFormClosing(object sender, FormClosingEventArgs e)
    {
        if (workflowRunning)
        {
            DialogResult forceClose = MessageBox.Show(
                this,
                Program.T(
                    "Validation or installation is still running. Force close will terminate current process. Continue?",
                    "Validation or installation is still running. Force close will terminate current process. Continue?"),
                Program.T("Confirm Force Close", "Confirm Force Close"),
                MessageBoxButtons.YesNo,
                MessageBoxIcon.Warning,
                MessageBoxDefaultButton.Button2);

            if (forceClose != DialogResult.Yes)
            {
                e.Cancel = true;
                return;
            }

            forceCloseRequested = true;
            TryTerminateActiveProcess();
            workflowRunning = false;
        }

        if (workflowRunning && DateTime.UtcNow.Ticks < 0)
        {
            e.Cancel = true;
            MessageBox.Show(
                this,
                Program.T("安装正在进行中，请等待当前步骤完成。", "Installation is still running. Wait for the current step to complete."),
                Program.T("请稍候", "Please Wait"),
                MessageBoxButtons.OK,
                MessageBoxIcon.Information);
            return;
        }

        Program.TryDeleteDirectory(extractRoot);
    }
}

internal sealed class ProcessCapture
{
    public ProcessCapture(int exitCode, string standardOutput, string standardError)
    {
        ExitCode = exitCode;
        StandardOutput = standardOutput ?? string.Empty;
        StandardError = standardError ?? string.Empty;
    }

    public int ExitCode { get; private set; }
    public string StandardOutput { get; private set; }
    public string StandardError { get; private set; }
}

internal sealed class HelperResult
{
    public string Status { get; private set; }
    public string Message { get; private set; }
    public string ActivationId { get; private set; }
    public int ExitCode { get; private set; }

    public static HelperResult FromCapture(ProcessCapture capture)
    {
        Dictionary<string, object> payload = Program.DeserializeJsonObject(capture.StandardOutput);
        HelperResult result = new HelperResult();
        result.Status = Program.GetString(payload, "status");
        result.Message = Program.GetString(payload, "message");
        result.ActivationId = Program.GetString(payload, "activationId");
        result.ExitCode = ParseExitCode(payload, capture.ExitCode);
        if (string.IsNullOrWhiteSpace(result.Message) && !string.IsNullOrWhiteSpace(capture.StandardError))
        {
            result.Message = capture.StandardError.Trim();
        }

        return result;
    }

    private static int ParseExitCode(Dictionary<string, object> payload, int fallback)
    {
        if (payload == null)
        {
            return fallback;
        }

        object value;
        if (!payload.TryGetValue("exitCode", out value) || value == null)
        {
            return fallback;
        }

        int parsed;
        if (int.TryParse(Convert.ToString(value), out parsed))
        {
            return parsed;
        }

        return fallback;
    }
}

internal sealed class FileSnapshot
{
    public bool Exists { get; private set; }
    public byte[] Content { get; private set; }
    public string ActivationId { get; private set; }

    public static FileSnapshot Capture(string path)
    {
        FileSnapshot snapshot = new FileSnapshot();
        try
        {
            snapshot.Exists = File.Exists(path);
            if (!snapshot.Exists)
            {
                snapshot.Content = new byte[0];
                snapshot.ActivationId = string.Empty;
                return snapshot;
            }

            snapshot.Content = File.ReadAllBytes(path);
            snapshot.ActivationId = ReadActivationId(snapshot.Content);
        }
        catch
        {
            snapshot.Exists = false;
            snapshot.Content = new byte[0];
            snapshot.ActivationId = string.Empty;
        }

        return snapshot;
    }

    public static void Restore(string path, FileSnapshot snapshot)
    {
        if (snapshot == null || !snapshot.Exists)
        {
            Program.TryDelete(path);
            return;
        }

        Program.EnsureDirectory(Path.GetDirectoryName(path));
        File.WriteAllBytes(path, snapshot.Content ?? new byte[0]);
    }

    private static string ReadActivationId(byte[] bytes)
    {
        if (bytes == null || bytes.Length == 0)
        {
            return string.Empty;
        }

        try
        {
            string json = DecodeJsonText(bytes);
            if (string.IsNullOrWhiteSpace(json))
            {
                return string.Empty;
            }

            string trimmed = json.Trim();
            if (!trimmed.StartsWith("{", StringComparison.Ordinal))
            {
                return string.Empty;
            }

            Dictionary<string, object> payload = Program.DeserializeJsonObject(trimmed);
            return Program.GetString(payload, "activationId");
        }
        catch
        {
            return string.Empty;
        }
    }

    private static string DecodeJsonText(byte[] bytes)
    {
        string content;
        if (HasUtf8Bom(bytes))
        {
            content = new UTF8Encoding(false, false).GetString(bytes, 3, bytes.Length - 3);
        }
        else if (HasUtf16LeBom(bytes))
        {
            content = Encoding.Unicode.GetString(bytes, 2, bytes.Length - 2);
        }
        else if (HasUtf16BeBom(bytes))
        {
            content = Encoding.BigEndianUnicode.GetString(bytes, 2, bytes.Length - 2);
        }
        else
        {
            content = Encoding.UTF8.GetString(bytes);
        }

        return NormalizeJson(content);
    }

    private static string NormalizeJson(string value)
    {
        if (string.IsNullOrEmpty(value))
        {
            return string.Empty;
        }

        return value.Trim().Trim('\uFEFF', '\u200B', '\0');
    }

    private static bool HasUtf8Bom(byte[] bytes)
    {
        return bytes.Length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF;
    }

    private static bool HasUtf16LeBom(byte[] bytes)
    {
        return bytes.Length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE;
    }

    private static bool HasUtf16BeBom(byte[] bytes)
    {
        return bytes.Length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF;
    }
}
