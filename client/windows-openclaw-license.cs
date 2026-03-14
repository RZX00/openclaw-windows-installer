using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using Microsoft.Win32;

internal static class Program
{
    private const string DefaultLocale = "zh-CN";
    private const string DefaultProduct = "windows-licensed";
    private const string RuntimeControlMode = "server-enforced";
    private const int DefaultLeaseHours = 72;
    private const int DefaultRefreshHours = 24;

    private static readonly JavaScriptSerializer Json = new JavaScriptSerializer { MaxJsonLength = int.MaxValue };

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

    private enum LicenseExitCode
    {
        Valid = 0,
        NotActivated = 40,
        Expired = 41,
        Revoked = 42,
        DeviceMismatch = 43,
        OfflineWithoutValidLease = 44,
        Misconfigured = 45,
        Cancelled = 46,
        Failed = 47
    }

    private sealed class CommandOptions
    {
        public string Command = "check";
        public string Mode = "cli";
        public bool Interactive;
        public bool JsonOutput;
        public bool EmitEnvironmentCommands;
        public string AuthorizationCode;

        public static CommandOptions Parse(string[] args)
        {
            CommandOptions options = new CommandOptions();
            for (int index = 0; index < args.Length; index++)
            {
                string arg = args[index] ?? string.Empty;
                if (!arg.StartsWith("-", StringComparison.Ordinal))
                {
                    options.Command = arg.Trim().ToLowerInvariant();
                    continue;
                }

                if (arg.Equals("--interactive", StringComparison.OrdinalIgnoreCase))
                {
                    options.Interactive = true;
                    continue;
                }

                if (arg.Equals("--json", StringComparison.OrdinalIgnoreCase))
                {
                    options.JsonOutput = true;
                    continue;
                }

                if (arg.Equals("--emit-env-cmd", StringComparison.OrdinalIgnoreCase))
                {
                    options.EmitEnvironmentCommands = true;
                    continue;
                }

                if (arg.Equals("--mode", StringComparison.OrdinalIgnoreCase) && index + 1 < args.Length)
                {
                    index++;
                    options.Mode = (args[index] ?? string.Empty).Trim().ToLowerInvariant();
                    continue;
                }

                if ((arg.Equals("--code", StringComparison.OrdinalIgnoreCase) || arg.Equals("--auth-code", StringComparison.OrdinalIgnoreCase)) && index + 1 < args.Length)
                {
                    index++;
                    options.AuthorizationCode = args[index];
                }
            }

            if (string.IsNullOrWhiteSpace(options.Command))
            {
                options.Command = "check";
            }

            if (string.IsNullOrWhiteSpace(options.Mode))
            {
                options.Mode = "cli";
            }

            return options;
        }
    }

    private sealed class RuntimeContext
    {
        public string Locale;
        public string DataRoot;
        public string InstallStatePath;
        public string LicenseStatePath;
        public string ExecutablePath;
        public string ApiBaseUrl;
        public string Product;
        public string BrandName;
        public string Channel;
        public string Version;
        public string SupportUrl;
        public string SupportEmail;
        public string SupportText;
        public Dictionary<string, object> InstallState;
    }

    private sealed class LicenseState
    {
        public string ActivationId;
        public string InstallationId;
        public string DeviceFingerprintHash;
        public string LeaseExpiresAt;
        public string RefreshAfter;
        public string Status;
        public string LastValidatedAt;
        public string MaskedLicenseCode;
        public string ProtectedPayload;
    }

    private sealed class ProtectedLicenseState
    {
        public string LeaseToken;
        public string RuntimeGrant;
        public string RuntimeGrantExpiresAt;
        public string ApiBaseUrl;
        public string Product;
        public string Channel;
        public string Version;
        public string LicensePolicyJson;
    }

    private sealed class OperationResult
    {
        public LicenseExitCode ExitCode;
        public string Status;
        public string Message;
        public LicenseState LicenseState;
        public ProtectedLicenseState ProtectedState;
    }

    private sealed class ApiResult
    {
        public bool Succeeded;
        public bool NetworkFailure;
        public int StatusCode;
        public string ErrorMessage;
        public Dictionary<string, object> Payload;
    }

    private sealed class ActivationPromptForm : Form
    {
        private readonly RuntimeContext context;
        private readonly string locale;
        private readonly string modeLabel;
        private readonly Func<string, OperationResult> activationCallback;
        private readonly bool submitInitialCodeOnShown;
        private readonly TextBox codeTextBox;
        private readonly Button activateButton;
        private readonly Button cancelButton;
        private readonly Button copyDiagnosticsButton;
        private readonly ProgressBar progressBar;
        private readonly Panel statusPanel;
        private readonly Label statusLabel;
        private readonly Label localStateLabel;
        private readonly Label supportSummaryLabel;
        private readonly Label guidanceLabel;
        private readonly LinkLabel supportUrlLinkLabel;
        private readonly LinkLabel supportEmailLinkLabel;
        private LicenseState currentLicenseState;
        private ProtectedLicenseState currentProtectedState;
        private OperationResult latestResult;
        private OperationResult activationResult;
        private bool activationInProgress;

        public string AuthorizationCode
        {
            get { return (codeTextBox.Text ?? string.Empty).Trim(); }
        }

        public OperationResult ActivationResult
        {
            get { return activationResult; }
        }

        public ActivationPromptForm(RuntimeContext context, string modeLabel, string initialCode, string initialMessage, bool submitInitialCodeOnShown, Func<string, OperationResult> activationCallback, LicenseState initialLicenseState, ProtectedLicenseState initialProtectedState)
        {
            this.context = context;
            string resolvedLocale = context == null ? DefaultLocale : (context.Locale ?? DefaultLocale);
            this.locale = resolvedLocale;
            this.modeLabel = modeLabel;
            this.activationCallback = activationCallback;
            this.submitInitialCodeOnShown = submitInitialCodeOnShown;
            currentLicenseState = initialLicenseState;
            currentProtectedState = initialProtectedState;

            Text = GetBrandName(context) + " " + T(locale, "\u6388\u6743\u4e2d\u5fc3", "License Center");
            StartPosition = FormStartPosition.CenterScreen;
            ClientSize = new Size(940, 520);
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;
            MinimizeBox = false;
            ShowInTaskbar = true;
            ShowIcon = true;
            TopMost = false;
            BackColor = Color.FromArgb(248, 250, 252);
            AutoScaleMode = AutoScaleMode.Dpi;
            Icon windowIcon = Program.TryGetExecutableIcon();
            if (windowIcon != null)
            {
                Icon = windowIcon;
            }

            Panel headerPanel = new Panel();
            headerPanel.Left = 0;
            headerPanel.Top = 0;
            headerPanel.Width = ClientSize.Width;
            headerPanel.Height = 104;
            headerPanel.Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right;
            headerPanel.BackColor = Color.FromArgb(15, 23, 42);
            Controls.Add(headerPanel);

            Panel brandBadgePanel = new Panel();
            brandBadgePanel.Left = 24;
            brandBadgePanel.Top = 20;
            brandBadgePanel.Width = 62;
            brandBadgePanel.Height = 62;
            brandBadgePanel.BackColor = Color.FromArgb(37, 99, 235);
            headerPanel.Controls.Add(brandBadgePanel);

            Label brandBadgeLabel = new Label();
            brandBadgeLabel.Dock = DockStyle.Fill;
            brandBadgeLabel.TextAlign = ContentAlignment.MiddleCenter;
            brandBadgeLabel.ForeColor = Color.White;
            brandBadgeLabel.Font = new Font("Segoe UI", 17F, FontStyle.Bold);
            brandBadgeLabel.Text = GetBrandInitials(GetBrandName(context));
            brandBadgePanel.Controls.Add(brandBadgeLabel);

            Label titleLabel = new Label();
            titleLabel.Text = string.Format(CultureInfo.InvariantCulture, T(locale, "{0} Windows \u6388\u6743\u6fc0\u6d3b", "{0} Windows License Activation"), GetBrandName(context));
            titleLabel.Left = 108;
            titleLabel.Top = 18;
            titleLabel.Width = 760;
            titleLabel.Height = 28;
            titleLabel.ForeColor = Color.White;
            titleLabel.BackColor = Color.Transparent;
            titleLabel.Font = new Font("Segoe UI", 15.5F, FontStyle.Bold);
            headerPanel.Controls.Add(titleLabel);

            Label subtitleLabel = new Label();
            subtitleLabel.Text = string.Format(
                CultureInfo.InvariantCulture,
                T(
                    locale,
                    "\u5f53\u524d\u6d41\u7a0b\uff1a{0}\u3002\u8be5\u7a97\u53e3\u7531\u72ec\u7acb helper \u8fdb\u7a0b\u6258\u7ba1\uff0c\u6fc0\u6d3b\u6210\u529f\u540e\u4f1a\u81ea\u52a8\u8fd4\u56de\u5e76\u7ee7\u7eed\u539f\u6709\u542f\u52a8 / \u66f4\u65b0 / \u4fee\u590d / PowerShell \u6d41\u7a0b\u3002",
                    "Current flow: {0}. This window runs in a separate helper process. After activation succeeds, the original start/update/repair/PowerShell flow resumes automatically."),
                modeLabel);
            subtitleLabel.Left = 108;
            subtitleLabel.Top = 52;
            subtitleLabel.Width = 790;
            subtitleLabel.Height = 40;
            subtitleLabel.ForeColor = Color.FromArgb(219, 234, 254);
            subtitleLabel.BackColor = Color.Transparent;
            subtitleLabel.Font = new Font("Segoe UI", 9.25F, FontStyle.Regular);
            headerPanel.Controls.Add(subtitleLabel);

            Label modeLabelControl = new Label();
            modeLabelControl.Text = string.Format(CultureInfo.InvariantCulture, T(locale, "\u5f53\u524d\u64cd\u4f5c\uff1a{0}", "Current action: {0}"), modeLabel);
            modeLabelControl.Left = 24;
            modeLabelControl.Top = 124;
            modeLabelControl.Width = 300;
            modeLabelControl.Height = 20;
            modeLabelControl.ForeColor = Color.FromArgb(17, 24, 39);
            Controls.Add(modeLabelControl);

            Label deviceLabel = new Label();
            deviceLabel.Text = string.Format(CultureInfo.InvariantCulture, T(locale, "\u5f53\u524d\u8bbe\u5907\uff1a{0}", "Current device: {0}"), Environment.MachineName);
            deviceLabel.Left = 348;
            deviceLabel.Top = 124;
            deviceLabel.Width = 324;
            deviceLabel.Height = 20;
            deviceLabel.ForeColor = Color.FromArgb(17, 24, 39);
            Controls.Add(deviceLabel);

            guidanceLabel = new Label();
            guidanceLabel.Left = 24;
            guidanceLabel.Top = 148;
            guidanceLabel.Width = 648;
            guidanceLabel.Height = 42;
            guidanceLabel.ForeColor = Color.FromArgb(71, 85, 105);
            guidanceLabel.Font = new Font("Segoe UI", 9.15F, FontStyle.Regular);
            Controls.Add(guidanceLabel);

            Label inputLabel = new Label();
            inputLabel.Text = T(locale, "\u6388\u6743\u7801", "Authorization code");
            inputLabel.Left = 24;
            inputLabel.Top = 202;
            inputLabel.Width = 180;
            inputLabel.Height = 20;
            inputLabel.ForeColor = Color.FromArgb(17, 24, 39);
            Controls.Add(inputLabel);

            codeTextBox = new TextBox();
            codeTextBox.Left = 24;
            codeTextBox.Top = 228;
            codeTextBox.Width = 648;
            codeTextBox.Height = 30;
            codeTextBox.CharacterCasing = CharacterCasing.Upper;
            codeTextBox.Font = new Font("Consolas", 11F, FontStyle.Regular);
            codeTextBox.Text = initialCode ?? string.Empty;
            Controls.Add(codeTextBox);

            Label hintLabel = new Label();
            hintLabel.Text = T(locale, "\u683c\u5f0f\u793a\u4f8b\uff1aOC-XXXXX-XXXXX-XXXXX-XXXXX\u3002\u4e0d\u4f1a\u5728\u672c\u5730\u843d\u76d8\u660e\u6587\u6388\u6743\u7801\u3002", "Example format: OC-XXXXX-XXXXX-XXXXX-XXXXX. The plain-text authorization code is never stored on disk.");
            hintLabel.Left = 24;
            hintLabel.Top = 264;
            hintLabel.Width = 648;
            hintLabel.Height = 32;
            hintLabel.ForeColor = Color.FromArgb(75, 85, 99);
            Controls.Add(hintLabel);

            statusPanel = new Panel();
            statusPanel.Left = 24;
            statusPanel.Top = 308;
            statusPanel.Width = 648;
            statusPanel.Height = 96;
            statusPanel.BackColor = Color.FromArgb(239, 246, 255);
            Controls.Add(statusPanel);

            statusLabel = new Label();
            statusLabel.Left = 14;
            statusLabel.Top = 12;
            statusLabel.Width = 620;
            statusLabel.Height = 72;
            statusLabel.ForeColor = Color.FromArgb(30, 64, 175);
            statusLabel.TextAlign = ContentAlignment.MiddleLeft;
            statusLabel.Font = new Font("Segoe UI", 9.25F, FontStyle.Regular);
            statusPanel.Controls.Add(statusLabel);

            progressBar = new ProgressBar();
            progressBar.Left = 24;
            progressBar.Top = 418;
            progressBar.Width = 648;
            progressBar.Height = 12;
            progressBar.Style = ProgressBarStyle.Marquee;
            progressBar.MarqueeAnimationSpeed = 28;
            progressBar.Visible = false;
            Controls.Add(progressBar);

            activateButton = new Button();
            activateButton.Text = T(locale, "\u9a8c\u8bc1\u5e76\u6fc0\u6d3b", "Validate and activate");
            activateButton.Left = 468;
            activateButton.Top = 448;
            activateButton.Width = 124;
            activateButton.Height = 32;
            activateButton.Click += delegate { BeginActivation(); };
            Controls.Add(activateButton);

            cancelButton = new Button();
            cancelButton.Text = T(locale, "\u53d6\u6d88", "Cancel");
            cancelButton.Left = 600;
            cancelButton.Top = 448;
            cancelButton.Width = 72;
            cancelButton.Height = 32;
            cancelButton.Click += delegate
            {
                DialogResult = DialogResult.Cancel;
                Close();
            };
            Controls.Add(cancelButton);

            Panel sidePanel = new Panel();
            sidePanel.Left = 694;
            sidePanel.Top = 124;
            sidePanel.Width = 222;
            sidePanel.Height = 356;
            sidePanel.BackColor = Color.White;
            sidePanel.BorderStyle = BorderStyle.FixedSingle;
            Controls.Add(sidePanel);

            Label overviewLabel = new Label();
            overviewLabel.Text = T(locale, "\u8bbe\u5907\u4e0e\u672c\u5730\u6388\u6743", "Device and local license");
            overviewLabel.Left = 14;
            overviewLabel.Top = 14;
            overviewLabel.Width = 188;
            overviewLabel.Height = 20;
            overviewLabel.ForeColor = Color.FromArgb(15, 23, 42);
            overviewLabel.Font = new Font("Segoe UI", 9.6F, FontStyle.Bold);
            sidePanel.Controls.Add(overviewLabel);

            localStateLabel = new Label();
            localStateLabel.Left = 14;
            localStateLabel.Top = 42;
            localStateLabel.Width = 188;
            localStateLabel.Height = 132;
            localStateLabel.ForeColor = Color.FromArgb(51, 65, 85);
            localStateLabel.Font = new Font("Segoe UI", 8.95F, FontStyle.Regular);
            sidePanel.Controls.Add(localStateLabel);

            copyDiagnosticsButton = new Button();
            copyDiagnosticsButton.Text = T(locale, "\u590d\u5236\u8bca\u65ad", "Copy diagnostics");
            copyDiagnosticsButton.Left = 14;
            copyDiagnosticsButton.Top = 184;
            copyDiagnosticsButton.Width = 118;
            copyDiagnosticsButton.Height = 28;
            copyDiagnosticsButton.Click += delegate { CopyDiagnostics(); };
            sidePanel.Controls.Add(copyDiagnosticsButton);

            Label supportLabel = new Label();
            supportLabel.Text = T(locale, "\u652f\u6301\u4e0e\u5904\u7406", "Support and handling");
            supportLabel.Left = 14;
            supportLabel.Top = 226;
            supportLabel.Width = 188;
            supportLabel.Height = 20;
            supportLabel.ForeColor = Color.FromArgb(15, 23, 42);
            supportLabel.Font = new Font("Segoe UI", 9.6F, FontStyle.Bold);
            sidePanel.Controls.Add(supportLabel);

            supportSummaryLabel = new Label();
            supportSummaryLabel.Left = 14;
            supportSummaryLabel.Top = 252;
            supportSummaryLabel.Width = 188;
            supportSummaryLabel.Height = 46;
            supportSummaryLabel.ForeColor = Color.FromArgb(71, 85, 105);
            supportSummaryLabel.Font = new Font("Segoe UI", 8.9F, FontStyle.Regular);
            sidePanel.Controls.Add(supportSummaryLabel);

            supportUrlLinkLabel = new LinkLabel();
            supportUrlLinkLabel.Left = 14;
            supportUrlLinkLabel.Top = 304;
            supportUrlLinkLabel.Width = 188;
            supportUrlLinkLabel.Height = 16;
            supportUrlLinkLabel.Text = T(locale, "\u6253\u5f00\u652f\u6301\u5165\u53e3", "Open support entry");
            supportUrlLinkLabel.LinkClicked += delegate
            {
                if (!string.IsNullOrWhiteSpace(context.SupportUrl))
                {
                    OpenExternalTarget(context.SupportUrl);
                }
            };
            sidePanel.Controls.Add(supportUrlLinkLabel);

            supportEmailLinkLabel = new LinkLabel();
            supportEmailLinkLabel.Left = 14;
            supportEmailLinkLabel.Top = 324;
            supportEmailLinkLabel.Width = 188;
            supportEmailLinkLabel.Height = 16;
            supportEmailLinkLabel.LinkClicked += delegate
            {
                if (!string.IsNullOrWhiteSpace(context.SupportEmail))
                {
                    OpenExternalTarget("mailto:" + context.SupportEmail);
                }
            };
            sidePanel.Controls.Add(supportEmailLinkLabel);

            AcceptButton = activateButton;
            CancelButton = cancelButton;

            FormClosing += delegate(object sender, FormClosingEventArgs e)
            {
                if (activationInProgress)
                {
                    e.Cancel = true;
                    SetWarningMessage(T(locale, "\u6b63\u5728\u9a8c\u8bc1\u6388\u6743\uff0c\u8bf7\u7a0d\u5019\u3002", "Authorization is being validated. Please wait."));
                }
            };

            Shown += delegate
            {
                codeTextBox.Focus();
                codeTextBox.SelectAll();
                if (submitInitialCodeOnShown && !string.IsNullOrWhiteSpace(AuthorizationCode))
                {
                    BeginInvoke(new MethodInvoker(BeginActivation));
                }
            };

            RefreshSidePanel();
            SetSupportSection();
            SetInfoMessage(string.IsNullOrWhiteSpace(initialMessage)
                ? T(locale, "\u8bf7\u8f93\u5165\u6388\u6743\u7801\u5b8c\u6210\u8bbe\u5907\u6fc0\u6d3b\u3002\u6210\u529f\u540e\u8be5\u7a97\u53e3\u4f1a\u81ea\u52a8\u5173\u95ed\uff0c\u4e0d\u4f1a\u63a5\u7ba1\u540e\u7eed\u7ef4\u62a4\u7a97\u53e3\u3002", "Enter an authorization code to activate this device. After success, this window closes automatically and does not replace the maintenance window.")
                : initialMessage);
        }

        private void BeginActivation()
        {
            if (activationInProgress)
            {
                return;
            }

            string authorizationCode = AuthorizationCode;
            if (string.IsNullOrWhiteSpace(authorizationCode))
            {
                SetWarningMessage(T(locale, "\u8bf7\u8f93\u5165\u6388\u6743\u7801\u3002", "Enter an authorization code."));
                codeTextBox.Focus();
                return;
            }

            SetBusyState(true, T(locale, "\u6b63\u5728\u8fde\u63a5 License API \u6821\u9a8c\u6388\u6743\u5e76\u7ed1\u5b9a\u8bbe\u5907\u2026", "Connecting to the License API and binding this device..."));
            ThreadPool.QueueUserWorkItem(delegate
            {
                OperationResult result;
                try
                {
                    result = activationCallback(authorizationCode);
                }
                catch (Exception ex)
                {
                    result = new OperationResult
                    {
                        ExitCode = LicenseExitCode.Failed,
                        Status = "activation-failed",
                        Message = ex.Message
                    };
                }

                if (!IsDisposed && IsHandleCreated)
                {
                    try
                    {
                        BeginInvoke(new MethodInvoker(delegate { CompleteActivation(result); }));
                    }
                    catch (InvalidOperationException)
                    {
                    }
                }
            });
        }

        private void CompleteActivation(OperationResult result)
        {
            latestResult = result;
            activationResult = result;
            if (result != null && result.LicenseState != null)
            {
                currentLicenseState = result.LicenseState;
            }
            if (result != null && result.ProtectedState != null)
            {
                currentProtectedState = result.ProtectedState;
            }
            RefreshSidePanel();
            SetBusyState(false, null);

            if (result != null && result.ExitCode == LicenseExitCode.Valid)
            {
                activateButton.Enabled = false;
                cancelButton.Enabled = false;
                codeTextBox.Enabled = false;
                progressBar.Visible = true;
                SetSuccessMessage(string.IsNullOrWhiteSpace(result.Message)
                    ? T(locale, "\u6388\u6743\u5df2\u751f\u6548\uff0c\u6b63\u5728\u8fd4\u56de\u539f\u6d41\u7a0b\u2026", "License activated. Returning to the original flow...")
                    : result.Message + Environment.NewLine + T(locale, "\u6b63\u5728\u8fd4\u56de\u539f\u542f\u52a8 / \u66f4\u65b0 / \u4fee\u590d\u6d41\u7a0b\u2026", "Returning to the original start/update/repair flow..."));

                System.Windows.Forms.Timer closeTimer = new System.Windows.Forms.Timer();
                closeTimer.Interval = 900;
                closeTimer.Tick += delegate
                {
                    closeTimer.Stop();
                    closeTimer.Dispose();
                    DialogResult = DialogResult.OK;
                    Close();
                };
                closeTimer.Start();
                return;
            }

            cancelButton.Text = T(locale, "\u5173\u95ed", "Close");
            SetErrorMessage(result == null || string.IsNullOrWhiteSpace(result.Message)
                ? T(locale, "\u6388\u6743\u6fc0\u6d3b\u5931\u8d25\u3002", "License activation failed.")
                : result.Message);
            codeTextBox.Focus();
            codeTextBox.SelectAll();
        }

        private void CopyDiagnostics()
        {
            try
            {
                Clipboard.SetText(BuildDiagnosticSnapshot(context, modeLabel, currentLicenseState, currentProtectedState, latestResult));
                SetInfoMessage(T(locale, "\u8bca\u65ad\u4fe1\u606f\u5df2\u590d\u5236\uff0c\u53ef\u76f4\u63a5\u53d1\u7ed9\u7ba1\u7406\u5458\u6216\u6280\u672f\u652f\u6301\u3002", "Diagnostics were copied and can be sent to your administrator or support."));
            }
            catch (Exception ex)
            {
                SetWarningMessage(string.Format(CultureInfo.InvariantCulture, T(locale, "\u590d\u5236\u8bca\u65ad\u4fe1\u606f\u5931\u8d25\uff1a{0}", "Copying diagnostics failed: {0}"), ex.Message));
            }
        }

        private void RefreshSidePanel()
        {
            if (guidanceLabel != null)
            {
                guidanceLabel.Text = BuildGuidanceSummary(context, modeLabel, latestResult);
            }
            if (localStateLabel != null)
            {
                localStateLabel.Text = BuildLocalStateSummary(locale, currentLicenseState, currentProtectedState);
            }
        }

        private void SetSupportSection()
        {
            if (supportSummaryLabel != null)
            {
                supportSummaryLabel.Text = BuildSupportSummary(context);
            }
            if (supportUrlLinkLabel != null)
            {
                supportUrlLinkLabel.Visible = !string.IsNullOrWhiteSpace(context.SupportUrl);
            }
            if (supportEmailLinkLabel != null)
            {
                supportEmailLinkLabel.Visible = !string.IsNullOrWhiteSpace(context.SupportEmail);
                supportEmailLinkLabel.Text = string.IsNullOrWhiteSpace(context.SupportEmail)
                    ? string.Empty
                    : string.Format(CultureInfo.InvariantCulture, T(locale, "\u53d1\u9001\u90ae\u4ef6\uff1a{0}", "Send email: {0}"), context.SupportEmail);
            }
        }

        private void SetBusyState(bool isBusy, string message)
        {
            activationInProgress = isBusy;
            activateButton.Enabled = !isBusy;
            cancelButton.Enabled = !isBusy;
            codeTextBox.Enabled = !isBusy;
            if (copyDiagnosticsButton != null)
            {
                copyDiagnosticsButton.Enabled = !isBusy;
            }
            progressBar.Visible = isBusy;
            UseWaitCursor = isBusy;
            if (!string.IsNullOrWhiteSpace(message))
            {
                SetInfoMessage(message);
            }
        }

        private void SetInfoMessage(string message)
        {
            SetStatusMessage(message, Color.FromArgb(239, 246, 255), Color.FromArgb(30, 64, 175));
        }

        private void SetWarningMessage(string message)
        {
            SetStatusMessage(message, Color.FromArgb(255, 247, 237), Color.FromArgb(154, 52, 18));
        }

        private void SetErrorMessage(string message)
        {
            SetStatusMessage(message, Color.FromArgb(254, 242, 242), Color.FromArgb(153, 27, 27));
        }

        private void SetSuccessMessage(string message)
        {
            statusPanel.BackColor = Color.FromArgb(240, 253, 244);
            statusLabel.ForeColor = Color.FromArgb(22, 101, 52);
            statusLabel.Text = message ?? string.Empty;
        }

        private void SetStatusMessage(string message, Color backgroundColor, Color foregroundColor)
        {
            statusPanel.BackColor = backgroundColor;
            statusLabel.ForeColor = foregroundColor;
            statusLabel.Text = message ?? string.Empty;
        }
    }

    [STAThread]
    private static int Main(string[] args)
    {
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);

        try
        {
            CommandOptions options = CommandOptions.Parse(args);
            RuntimeContext context = CreateContext();
            OperationResult result;

            switch (options.Command)
            {
                case "activate":
                    result = Activate(context, options, options.AuthorizationCode, null);
                    break;
                case "status":
                    result = GetStatus(context);
                    break;
                case "release":
                    result = Release(context);
                    break;
                default:
                    result = Check(context, options);
                    break;
            }

            PersistInstallState(context, result);
            EmitResult(options, context, result);
            return (int)result.ExitCode;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine(ex.Message);
            return (int)LicenseExitCode.Failed;
        }
    }

    private static RuntimeContext CreateContext()
    {
        string programData = Environment.GetEnvironmentVariable("ProgramData");
        if (string.IsNullOrWhiteSpace(programData))
        {
            programData = Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData);
        }

        string dataRoot = Path.Combine(programData, "OpenClaw");
        string installStatePath = Path.Combine(dataRoot, "install-state.json");
        Dictionary<string, object> installState = ReadJsonDictionary(installStatePath);
        RuntimeContext context = new RuntimeContext();
        context.Locale = GetString(installState, "locale", DefaultLocale);
        context.DataRoot = dataRoot;
        context.InstallStatePath = installStatePath;
        context.LicenseStatePath = Path.Combine(dataRoot, "license-state.json");
        context.ExecutablePath = Process.GetCurrentProcess().MainModule.FileName;
        context.ApiBaseUrl = NormalizeBaseUrl(Environment.GetEnvironmentVariable("OPENCLAW_LICENSE_API_BASE_URL"));
        if (string.IsNullOrWhiteSpace(context.ApiBaseUrl))
        {
            context.ApiBaseUrl = NormalizeBaseUrl(GetString(installState, "licenseApiBaseUrl", string.Empty));
        }
        context.Product = GetString(installState, "licenseProduct", DefaultProduct);
        context.BrandName = GetString(installState, "licenseBrandName", "OpenClaw");
        context.Channel = GetString(installState, "channel", "latest");
        context.Version = GetString(installState, "installedVersion", string.Empty);
        context.SupportUrl = NormalizeBaseUrl(Environment.GetEnvironmentVariable("OPENCLAW_LICENSE_SUPPORT_URL"));
        if (string.IsNullOrWhiteSpace(context.SupportUrl))
        {
            context.SupportUrl = NormalizeBaseUrl(GetString(installState, "licenseSupportUrl", string.Empty));
        }
        context.SupportEmail = Environment.GetEnvironmentVariable("OPENCLAW_LICENSE_SUPPORT_EMAIL");
        if (string.IsNullOrWhiteSpace(context.SupportEmail))
        {
            context.SupportEmail = GetString(installState, "licenseSupportEmail", string.Empty);
        }
        context.SupportText = Environment.GetEnvironmentVariable("OPENCLAW_LICENSE_SUPPORT_TEXT");
        if (string.IsNullOrWhiteSpace(context.SupportText))
        {
            context.SupportText = GetString(installState, "licenseSupportText", string.Empty);
        }
        context.InstallState = installState;
        return context;
    }

    private static OperationResult Check(RuntimeContext context, CommandOptions options)
    {
        LicenseState state = LoadLicenseState(context);
        ProtectedLicenseState protectedState = LoadProtectedLicenseState(state);
        string currentFingerprint = ComputeDeviceFingerprintHash();

        if (state == null || protectedState == null || string.IsNullOrWhiteSpace(state.ActivationId))
        {
            return EnsureActivation(context, options, LicenseExitCode.NotActivated, "not-activated", T(context.Locale, "\u5f53\u524d\u8bbe\u5907\u5c1a\u672a\u6fc0\u6d3b\u6388\u6743\u3002", "This device has not been activated yet."));
        }

        if (!string.Equals(state.DeviceFingerprintHash ?? string.Empty, currentFingerprint, StringComparison.OrdinalIgnoreCase))
        {
            DeleteLicenseState(context);
            return EnsureActivation(context, options, LicenseExitCode.DeviceMismatch, "device-mismatch", T(context.Locale, "\u5f53\u524d\u6388\u6743\u4e0e\u672c\u673a\u8bbe\u5907\u4e0d\u5339\u914d\u3002", "The current license does not match this device."));
        }

        if (string.Equals(state.Status, "revoked", StringComparison.OrdinalIgnoreCase))
        {
            return EnsureActivation(context, options, LicenseExitCode.Revoked, "revoked", T(context.Locale, "\u5f53\u524d\u6388\u6743\u5df2\u7ecf\u88ab\u505c\u7528\u3002", "The current license has been revoked."));
        }

        DateTimeOffset now = DateTimeOffset.UtcNow;
        DateTimeOffset expiresAt = ParseTime(state.LeaseExpiresAt, now.AddHours(DefaultLeaseHours));
        DateTimeOffset refreshAfter = ParseTime(state.RefreshAfter, now.AddHours(DefaultRefreshHours));

        if (now >= refreshAfter)
        {
            OperationResult refreshResult = Refresh(context, state, protectedState, currentFingerprint);
            if (refreshResult.ExitCode == LicenseExitCode.Valid)
            {
                return refreshResult;
            }

            if (refreshResult.ExitCode == LicenseExitCode.OfflineWithoutValidLease && now < expiresAt)
            {
                state.Status = "valid";
                state.LastValidatedAt = now.ToString("o");
                SaveLicenseState(context, state, protectedState);
                return BuildValidResult(T(context.Locale, "\u79bb\u7ebf\u6a21\u5f0f\u4e0b\u7ee7\u7eed\u4f7f\u7528\u672c\u5730\u6709\u6548 lease\u3002", "Continuing with the cached local lease while offline."), state, protectedState);
            }

            return options.Interactive ? Activate(context, options, null, refreshResult.Message) : refreshResult;
        }

        if (now >= expiresAt)
        {
            return EnsureActivation(context, options, LicenseExitCode.Expired, "expired", T(context.Locale, "\u5f53\u524d lease \u5df2\u8fc7\u671f\uff0c\u8bf7\u91cd\u65b0\u6fc0\u6d3b\u3002", "The current lease has expired. Reactivate to continue."));
        }

        state.Status = "valid";
        state.LastValidatedAt = now.ToString("o");
        SaveLicenseState(context, state, protectedState);
        return BuildValidResult(T(context.Locale, "\u6388\u6743\u6821\u9a8c\u901a\u8fc7\u3002", "License validation succeeded."), state, protectedState);
    }

    private static OperationResult GetStatus(RuntimeContext context)
    {
        LicenseState state = LoadLicenseState(context);
        ProtectedLicenseState protectedState = LoadProtectedLicenseState(state);
        if (state == null || protectedState == null)
        {
            return new OperationResult
            {
                ExitCode = LicenseExitCode.NotActivated,
                Status = "not-activated",
                Message = T(context.Locale, "\u5f53\u524d\u8bbe\u5907\u5c1a\u672a\u6fc0\u6d3b\u6388\u6743\u3002", "This device has not been activated yet.")
            };
        }

        return BuildValidResult(T(context.Locale, "\u5df2\u8bfb\u53d6\u672c\u5730\u6388\u6743\u72b6\u6001\u3002", "Loaded the local license state."), state, protectedState);
    }

    private static OperationResult Release(RuntimeContext context)
    {
        LicenseState state = LoadLicenseState(context);
        ProtectedLicenseState protectedState = LoadProtectedLicenseState(state);
        if (state == null || protectedState == null)
        {
            return new OperationResult
            {
                ExitCode = LicenseExitCode.Valid,
                Status = "released",
                Message = T(context.Locale, "\u672c\u5730\u6ca1\u6709\u53ef\u91ca\u653e\u7684\u6388\u6743\u72b6\u6001\u3002", "No local license state was found to release.")
            };
        }

        string apiBaseUrl = NormalizeBaseUrl(string.IsNullOrWhiteSpace(context.ApiBaseUrl) ? protectedState.ApiBaseUrl : context.ApiBaseUrl);
        if (string.IsNullOrWhiteSpace(apiBaseUrl))
        {
            return new OperationResult
            {
                ExitCode = LicenseExitCode.Misconfigured,
                Status = "misconfigured",
                Message = T(context.Locale, "\u672a\u914d\u7f6e\u6388\u6743\u670d\u52a1\u5730\u5740\uff0c\u65e0\u6cd5\u91ca\u653e\u6388\u6743\u3002", "The license service base URL is not configured, so the license cannot be released.")
            };
        }

        Dictionary<string, object> payload = new Dictionary<string, object>(StringComparer.OrdinalIgnoreCase);
        payload["activationId"] = state.ActivationId;
        payload["installationId"] = state.InstallationId;
        payload["deviceFingerprintHash"] = ComputeDeviceFingerprintHash();
        payload["leaseToken"] = protectedState.LeaseToken ?? string.Empty;
        payload["product"] = string.IsNullOrWhiteSpace(protectedState.Product) ? context.Product : protectedState.Product;

        ApiResult apiResult = PostJson(apiBaseUrl + "/v1/licenses/release", payload);
        if (!apiResult.Succeeded)
        {
            return BuildApiFailureResult(context, apiResult, "release", LicenseExitCode.Failed, "release-failed", T(context.Locale, "\u91ca\u653e\u6388\u6743\u5931\u8d25\u3002", "Failed to release the license."));
        }

        DeleteLicenseState(context);
        return new OperationResult
        {
            ExitCode = LicenseExitCode.Valid,
            Status = "released",
            Message = T(context.Locale, "\u6388\u6743\u5df2\u4ece\u5f53\u524d\u8bbe\u5907\u91ca\u653e\u3002", "The license was released from this device.")
        };
    }

    private static OperationResult Activate(RuntimeContext context, CommandOptions options, string initialCode, string initialMessage)
    {
        if (!options.Interactive)
        {
            if (string.IsNullOrWhiteSpace(initialCode))
            {
                return new OperationResult
                {
                    ExitCode = LicenseExitCode.NotActivated,
                    Status = "not-activated",
                    Message = T(context.Locale, "\u672a\u63d0\u4f9b\u6388\u6743\u7801\u3002", "No authorization code was provided.")
                };
            }

            return ActivateWithCode(context, initialCode);
        }

        string modeLabel = GetModeLabel(context.Locale, options.Mode);
        LicenseState currentState = LoadLicenseState(context);
        ProtectedLicenseState currentProtectedState = LoadProtectedLicenseState(currentState);
        using (ActivationPromptForm form = new ActivationPromptForm(
            context,
            modeLabel,
            initialCode,
            initialMessage,
            !string.IsNullOrWhiteSpace(initialCode),
            delegate(string authorizationCode) { return ActivateWithCode(context, authorizationCode); },
            currentState,
            currentProtectedState))
        {
            form.ShowDialog();
            if (form.ActivationResult != null)
            {
                return form.ActivationResult;
            }

            return new OperationResult
            {
                ExitCode = LicenseExitCode.Cancelled,
                Status = "cancelled",
                Message = T(context.Locale, "\u4f60\u53d6\u6d88\u4e86\u6388\u6743\u6fc0\u6d3b\u3002", "License activation was cancelled.")
            };
        }
    }

    private static OperationResult ActivateWithCode(RuntimeContext context, string authorizationCode)
    {
        if (string.IsNullOrWhiteSpace(context.ApiBaseUrl))
        {
            return new OperationResult
            {
                ExitCode = LicenseExitCode.Misconfigured,
                Status = "misconfigured",
                Message = T(context.Locale, "\u672a\u914d\u7f6e\u6388\u6743\u670d\u52a1\u5730\u5740\uff0c\u8bf7\u5148\u8bbe\u7f6e OPENCLAW_LICENSE_API_BASE_URL\u3002", "The license service URL is not configured. Set OPENCLAW_LICENSE_API_BASE_URL first.")
            };
        }

        LicenseState existing = LoadLicenseState(context) ?? new LicenseState();
        string preferredInstallationId = NormalizeInstallationId(Environment.GetEnvironmentVariable("OPENCLAW_INSTALLATION_ID"));
        string installationId = string.IsNullOrWhiteSpace(existing.InstallationId)
            ? (string.IsNullOrWhiteSpace(preferredInstallationId) ? Guid.NewGuid().ToString("N") : preferredInstallationId)
            : existing.InstallationId;
        existing.InstallationId = installationId;

        Dictionary<string, object> payload = new Dictionary<string, object>(StringComparer.OrdinalIgnoreCase);
        payload["authCode"] = authorizationCode;
        payload["installationId"] = installationId;
        payload["deviceFingerprintHash"] = ComputeDeviceFingerprintHash();
        payload["product"] = context.Product;
        payload["channel"] = context.Channel;
        payload["version"] = context.Version ?? string.Empty;
        payload["machineName"] = Environment.MachineName;

        ApiResult apiResult = PostJson(context.ApiBaseUrl + "/v1/licenses/activate", payload);
        if (!apiResult.Succeeded)
        {
            return BuildApiFailureResult(context, apiResult, "activate", LicenseExitCode.Failed, "activation-failed", T(context.Locale, "\u6fc0\u6d3b\u5931\u8d25\uff0c\u8bf7\u68c0\u67e5\u7f51\u7edc\u6216\u6388\u6743\u7801\u3002", "Activation failed. Check the network connection or authorization code."));
        }

        return SaveApiState(context, existing, authorizationCode, apiResult.Payload, T(context.Locale, "\u6388\u6743\u5df2\u6210\u529f\u6fc0\u6d3b\u3002", "The license was activated successfully."));
    }

    private static OperationResult Refresh(RuntimeContext context, LicenseState state, ProtectedLicenseState protectedState, string currentFingerprint)
    {
        string apiBaseUrl = NormalizeBaseUrl(string.IsNullOrWhiteSpace(context.ApiBaseUrl) ? protectedState.ApiBaseUrl : context.ApiBaseUrl);
        if (string.IsNullOrWhiteSpace(apiBaseUrl))
        {
            return new OperationResult
            {
                ExitCode = LicenseExitCode.Misconfigured,
                Status = "misconfigured",
                Message = T(context.Locale, "\u672a\u914d\u7f6e\u6388\u6743\u670d\u52a1\u5730\u5740\uff0c\u65e0\u6cd5\u5237\u65b0 lease\u3002", "The license service URL is not configured, so the lease cannot be refreshed.")
            };
        }

        Dictionary<string, object> payload = new Dictionary<string, object>(StringComparer.OrdinalIgnoreCase);
        payload["activationId"] = state.ActivationId;
        payload["installationId"] = state.InstallationId;
        payload["deviceFingerprintHash"] = currentFingerprint;
        payload["leaseToken"] = protectedState.LeaseToken ?? string.Empty;
        payload["product"] = string.IsNullOrWhiteSpace(protectedState.Product) ? context.Product : protectedState.Product;
        payload["channel"] = string.IsNullOrWhiteSpace(protectedState.Channel) ? context.Channel : protectedState.Channel;
        payload["version"] = string.IsNullOrWhiteSpace(protectedState.Version) ? context.Version : protectedState.Version;

        ApiResult apiResult = PostJson(apiBaseUrl + "/v1/licenses/refresh", payload);
        if (!apiResult.Succeeded)
        {
            return BuildApiFailureResult(context, apiResult, "refresh", LicenseExitCode.Failed, "refresh-failed", T(context.Locale, "\u5237\u65b0 lease \u5931\u8d25\u3002", "Refreshing the lease failed."));
        }

        return SaveApiState(context, state, state.MaskedLicenseCode, apiResult.Payload, T(context.Locale, "\u6388\u6743\u5df2\u6210\u529f\u6fc0\u6d3b\u3002", "The license was activated successfully."));
    }

    private static OperationResult EnsureActivation(RuntimeContext context, CommandOptions options, LicenseExitCode exitCode, string status, string message)
    {
        if (!options.Interactive)
        {
            return new OperationResult
            {
                ExitCode = exitCode,
                Status = status,
                Message = message
            };
        }

        return Activate(context, options, null, message);
    }

    private static OperationResult SaveApiState(RuntimeContext context, LicenseState baseState, string codeOrMaskedCode, Dictionary<string, object> payload, string message)
    {
        Dictionary<string, object> envelope = GetObject(payload, "data") ?? payload ?? new Dictionary<string, object>(StringComparer.OrdinalIgnoreCase);
        DateTimeOffset now = DateTimeOffset.UtcNow;

        LicenseState state = baseState ?? new LicenseState();
        state.ActivationId = GetString(envelope, "activationId", string.IsNullOrWhiteSpace(state.ActivationId) ? Guid.NewGuid().ToString("N") : state.ActivationId);
        state.InstallationId = string.IsNullOrWhiteSpace(state.InstallationId) ? Guid.NewGuid().ToString("N") : state.InstallationId;
        state.DeviceFingerprintHash = ComputeDeviceFingerprintHash();
        state.LeaseExpiresAt = ParseTime(GetString(envelope, "leaseExpiresAt", string.Empty), now.AddHours(DefaultLeaseHours)).ToString("o");
        state.RefreshAfter = ParseTime(GetString(envelope, "refreshAfter", string.Empty), now.AddHours(DefaultRefreshHours)).ToString("o");
        state.Status = NormalizeStatus(GetString(envelope, "status", "valid"));
        state.LastValidatedAt = now.ToString("o");
        state.MaskedLicenseCode = MaskCode(GetString(envelope, "maskedLicenseCode", codeOrMaskedCode));

        ProtectedLicenseState protectedState = new ProtectedLicenseState();
        protectedState.LeaseToken = GetString(envelope, "leaseToken", string.Empty);
        protectedState.RuntimeGrant = GetString(envelope, "runtimeGrant", string.Empty);
        protectedState.RuntimeGrantExpiresAt = GetString(envelope, "runtimeGrantExpiresAt", state.LeaseExpiresAt);
        protectedState.ApiBaseUrl = context.ApiBaseUrl;
        protectedState.Product = GetString(envelope, "product", context.Product);
        protectedState.Channel = GetString(envelope, "channel", context.Channel);
        protectedState.Version = GetString(envelope, "version", context.Version);
        protectedState.LicensePolicyJson = SerializeJson(GetObject(envelope, "licensePolicy"));

        if (string.IsNullOrWhiteSpace(protectedState.LeaseToken))
        {
            return new OperationResult
            {
                ExitCode = LicenseExitCode.Misconfigured,
                Status = "misconfigured",
                Message = T(context.Locale, "\u6388\u6743\u670d\u52a1\u672a\u8fd4\u56de lease token\uff0c\u8bf7\u68c0\u67e5\u670d\u52a1\u7aef\u914d\u7f6e\u3002", "The license service did not return a lease token. Check the server configuration.")
            };
        }

        if (string.IsNullOrWhiteSpace(protectedState.RuntimeGrant))
        {
            return new OperationResult
            {
                ExitCode = LicenseExitCode.Misconfigured,
                Status = "misconfigured",
                Message = T(context.Locale, "\u6388\u6743\u670d\u52a1\u672a\u8fd4\u56de runtime grant\uff0c\u65e0\u6cd5\u542f\u7528\u5546\u4e1a\u7248\u80fd\u529b\u3002", "The license service did not return a runtime grant, so commercial runtime access cannot be enabled.")
            };
        }

        SaveLicenseState(context, state, protectedState);
        return BuildValidResult(message, state, protectedState);
    }

    private static OperationResult BuildValidResult(string message, LicenseState state, ProtectedLicenseState protectedState)
    {
        return new OperationResult
        {
            ExitCode = LicenseExitCode.Valid,
            Status = NormalizeStatus(state == null ? "valid" : state.Status),
            Message = message,
            LicenseState = state,
            ProtectedState = protectedState
        };
    }

    private static LicenseState LoadLicenseState(RuntimeContext context)
    {
        Dictionary<string, object> payload = ReadJsonDictionary(context.LicenseStatePath);
        if (payload.Count == 0)
        {
            return null;
        }

        return new LicenseState
        {
            ActivationId = GetString(payload, "activationId", string.Empty),
            InstallationId = GetString(payload, "installationId", string.Empty),
            DeviceFingerprintHash = GetString(payload, "deviceFingerprintHash", string.Empty),
            LeaseExpiresAt = GetString(payload, "leaseExpiresAt", string.Empty),
            RefreshAfter = GetString(payload, "refreshAfter", string.Empty),
            Status = NormalizeStatus(GetString(payload, "status", "unknown")),
            LastValidatedAt = GetString(payload, "lastValidatedAt", string.Empty),
            MaskedLicenseCode = GetString(payload, "maskedLicenseCode", string.Empty),
            ProtectedPayload = GetString(payload, "protectedPayload", string.Empty)
        };
    }

    private static ProtectedLicenseState LoadProtectedLicenseState(LicenseState state)
    {
        if (state == null || string.IsNullOrWhiteSpace(state.ProtectedPayload))
        {
            return null;
        }

        try
        {
            Dictionary<string, object> payload = Json.DeserializeObject(UnprotectString(state.ProtectedPayload)) as Dictionary<string, object>;
            return payload == null
                ? null
                : new ProtectedLicenseState
                {
                    LeaseToken = GetString(payload, "leaseToken", string.Empty),
                    RuntimeGrant = GetString(payload, "runtimeGrant", string.Empty),
                    RuntimeGrantExpiresAt = GetString(payload, "runtimeGrantExpiresAt", string.Empty),
                    ApiBaseUrl = GetString(payload, "apiBaseUrl", string.Empty),
                    Product = GetString(payload, "product", string.Empty),
                    Channel = GetString(payload, "channel", string.Empty),
                    Version = GetString(payload, "version", string.Empty),
                    LicensePolicyJson = GetString(payload, "licensePolicyJson", string.Empty)
                };
        }
        catch
        {
            return null;
        }
    }

    private static void SaveLicenseState(RuntimeContext context, LicenseState state, ProtectedLicenseState protectedState)
    {
        Dictionary<string, object> securePayload = new Dictionary<string, object>(StringComparer.OrdinalIgnoreCase);
        securePayload["leaseToken"] = protectedState.LeaseToken ?? string.Empty;
        securePayload["runtimeGrant"] = protectedState.RuntimeGrant ?? string.Empty;
        securePayload["runtimeGrantExpiresAt"] = protectedState.RuntimeGrantExpiresAt ?? string.Empty;
        securePayload["apiBaseUrl"] = protectedState.ApiBaseUrl ?? string.Empty;
        securePayload["product"] = protectedState.Product ?? string.Empty;
        securePayload["channel"] = protectedState.Channel ?? string.Empty;
        securePayload["version"] = protectedState.Version ?? string.Empty;
        securePayload["licensePolicyJson"] = protectedState.LicensePolicyJson ?? string.Empty;

        Dictionary<string, object> payload = new Dictionary<string, object>(StringComparer.OrdinalIgnoreCase);
        payload["schemaVersion"] = 1;
        payload["activationId"] = state.ActivationId ?? string.Empty;
        payload["installationId"] = state.InstallationId ?? string.Empty;
        payload["deviceFingerprintHash"] = state.DeviceFingerprintHash ?? string.Empty;
        payload["leaseExpiresAt"] = state.LeaseExpiresAt ?? string.Empty;
        payload["refreshAfter"] = state.RefreshAfter ?? string.Empty;
        payload["status"] = NormalizeStatus(state.Status);
        payload["lastValidatedAt"] = state.LastValidatedAt ?? string.Empty;
        payload["maskedLicenseCode"] = state.MaskedLicenseCode ?? string.Empty;
        payload["protectedPayload"] = ProtectString(SerializeJson(securePayload));

        EnsureDirectory(Path.GetDirectoryName(context.LicenseStatePath));
        File.WriteAllText(context.LicenseStatePath, SerializeJson(payload), new UTF8Encoding(false));
    }

    private static void DeleteLicenseState(RuntimeContext context)
    {
        if (File.Exists(context.LicenseStatePath))
        {
            File.Delete(context.LicenseStatePath);
        }
    }

    private static void PersistInstallState(RuntimeContext context, OperationResult result)
    {
        Dictionary<string, object> installState = context.InstallState ?? new Dictionary<string, object>(StringComparer.OrdinalIgnoreCase);
        installState["runtimeControlMode"] = RuntimeControlMode;
        installState["licenseExecutablePath"] = context.ExecutablePath;
        installState["licenseStatePath"] = context.LicenseStatePath;
        installState["licenseProduct"] = context.Product;
        installState["licenseBrandName"] = context.BrandName ?? "OpenClaw";
        installState["licenseApiBaseUrl"] = context.ApiBaseUrl ?? string.Empty;
        installState["licenseSupportUrl"] = context.SupportUrl ?? string.Empty;
        installState["licenseSupportEmail"] = context.SupportEmail ?? string.Empty;
        installState["licenseSupportText"] = context.SupportText ?? string.Empty;
        installState["licenseStatus"] = result == null ? "unknown" : (result.Status ?? "unknown");
        installState["lastLicenseCheckAt"] = DateTimeOffset.UtcNow.ToString("o");
        EnsureDirectory(Path.GetDirectoryName(context.InstallStatePath));
        File.WriteAllText(context.InstallStatePath, SerializeJson(installState), new UTF8Encoding(false));
    }

    private static void EmitResult(CommandOptions options, RuntimeContext context, OperationResult result)
    {
        if (options.EmitEnvironmentCommands && result.ExitCode == LicenseExitCode.Valid)
        {
            foreach (KeyValuePair<string, string> item in BuildEnvironmentMap(result))
            {
                Console.WriteLine("set \"{0}={1}\"", item.Key, item.Value ?? string.Empty);
            }
            return;
        }

        if (options.JsonOutput)
        {
            Dictionary<string, object> payload = new Dictionary<string, object>(StringComparer.OrdinalIgnoreCase);
            payload["status"] = result.Status ?? "unknown";
            payload["exitCode"] = (int)result.ExitCode;
            payload["message"] = result.Message ?? string.Empty;
            payload["licenseStatePath"] = context.LicenseStatePath;
            if (result.LicenseState != null)
            {
                payload["activationId"] = result.LicenseState.ActivationId ?? string.Empty;
                payload["leaseExpiresAt"] = result.LicenseState.LeaseExpiresAt ?? string.Empty;
                payload["refreshAfter"] = result.LicenseState.RefreshAfter ?? string.Empty;
                payload["lastValidatedAt"] = result.LicenseState.LastValidatedAt ?? string.Empty;
                payload["maskedLicenseCode"] = result.LicenseState.MaskedLicenseCode ?? string.Empty;
            }

            if (result.ExitCode == LicenseExitCode.Valid)
            {
                Dictionary<string, object> env = new Dictionary<string, object>(StringComparer.OrdinalIgnoreCase);
                foreach (KeyValuePair<string, string> item in BuildEnvironmentMap(result))
                {
                    env[item.Key] = item.Value ?? string.Empty;
                }
                payload["env"] = env;
            }

            Console.WriteLine(SerializeJson(payload));
            return;
        }

        if (result.ExitCode == LicenseExitCode.Valid)
        {
            Console.WriteLine(result.Message);
        }
        else
        {
            Console.Error.WriteLine(result.Message);
        }
    }

    private static IDictionary<string, string> BuildEnvironmentMap(OperationResult result)
    {
        Dictionary<string, string> env = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        env["OPENCLAW_LICENSE_STATUS"] = result.Status ?? "valid";
        env["OPENCLAW_RUNTIME_CONTROL_MODE"] = RuntimeControlMode;
        if (result.LicenseState != null)
        {
            env["OPENCLAW_LICENSE_ACTIVATION_ID"] = result.LicenseState.ActivationId ?? string.Empty;
            env["OPENCLAW_LICENSE_INSTALLATION_ID"] = result.LicenseState.InstallationId ?? string.Empty;
            env["OPENCLAW_LICENSE_LEASE_EXPIRES_AT"] = result.LicenseState.LeaseExpiresAt ?? string.Empty;
        }
        if (result.ProtectedState != null)
        {
            env["OPENCLAW_RUNTIME_GRANT"] = result.ProtectedState.RuntimeGrant ?? string.Empty;
            env["OPENCLAW_RUNTIME_GRANT_EXPIRES_AT"] = result.ProtectedState.RuntimeGrantExpiresAt ?? string.Empty;
            env["OPENCLAW_LICENSE_LEASE"] = result.ProtectedState.LeaseToken ?? string.Empty;
            env["OPENCLAW_LICENSE_API_BASE_URL"] = result.ProtectedState.ApiBaseUrl ?? string.Empty;
            env["OPENCLAW_RUNTIME_API_BASE_URL"] = string.IsNullOrWhiteSpace(result.ProtectedState.ApiBaseUrl) ? string.Empty : (NormalizeBaseUrl(result.ProtectedState.ApiBaseUrl) + "/v1/runtime");
        }
        return env;
    }

    private static string GetBrandName(RuntimeContext context)
    {
        return context == null || string.IsNullOrWhiteSpace(context.BrandName) ? "OpenClaw" : context.BrandName.Trim();
    }

    private static string GetBrandInitials(string brandName)
    {
        if (string.IsNullOrWhiteSpace(brandName))
        {
            return "OC";
        }

        string[] parts = brandName
            .Split(new[] { ' ', '-', '_' }, StringSplitOptions.RemoveEmptyEntries)
            .Where(part => !string.IsNullOrWhiteSpace(part))
            .Take(2)
            .ToArray();
        if (parts.Length == 0)
        {
            return brandName.Length >= 2 ? brandName.Substring(0, 2).ToUpperInvariant() : brandName.ToUpperInvariant();
        }

        return string.Concat(parts.Select(part => char.ToUpperInvariant(part[0]))).PadRight(2, 'C');
    }

    private static string BuildSupportSummary(RuntimeContext context)
    {
        string locale = context == null ? DefaultLocale : context.Locale;
        List<string> parts = new List<string>();
        if (!string.IsNullOrWhiteSpace(context == null ? null : context.SupportText))
        {
            parts.Add(context.SupportText.Trim());
        }
        else
        {
            parts.Add(T(locale, "\u5982\u9700\u6362\u673a\uff0c\u89e3\u7ed1\u6216\u4eba\u5de5\u91ca\u653e\u8bbe\u5907\uff0c\u8bf7\u8054\u7cfb\u4f60\u4eec\u7684\u7ba1\u7406\u5458\u6216\u6388\u6743\u652f\u6301\u3002", "For device transfer, unbinding, or manual release, contact your administrator or license support."));
        }

        if (context != null && !string.IsNullOrWhiteSpace(context.SupportUrl))
        {
            parts.Add(T(locale, "\u53ef\u76f4\u63a5\u6253\u5f00\u53f3\u4fa7\u652f\u6301\u5165\u53e3\u3002", "You can open the support entry from the link below."));
        }
        else if (context != null && !string.IsNullOrWhiteSpace(context.SupportEmail))
        {
            parts.Add(T(locale, "\u53ef\u76f4\u63a5\u901a\u8fc7\u90ae\u4ef6\u53d1\u9001\u8bca\u65ad\u4fe1\u606f\u3002", "You can send diagnostics directly by email."));
        }
        else
        {
            parts.Add(T(locale, "\u82e5\u65e0\u81ea\u52a9\u5165\u53e3\uff0c\u8bf7\u590d\u5236\u8bca\u65ad\u4fe1\u606f\u540e\u53d1\u7ed9\u7ba1\u7406\u5458\u3002", "If no self-service entry is configured, copy the diagnostics and send them to your administrator."));
        }

        return string.Join(Environment.NewLine, parts.Where(part => !string.IsNullOrWhiteSpace(part)).ToArray());
    }

    private static string BuildGuidanceSummary(RuntimeContext context, string modeLabel, OperationResult result)
    {
        string locale = context == null ? DefaultLocale : context.Locale;
        if (result == null)
        {
            return string.Format(
                CultureInfo.InvariantCulture,
                T(locale, "\u8f93\u5165\u6388\u6743\u7801\u540e\uff0chelper \u4f1a\u5355\u72ec\u5b8c\u6210\u6821\u9a8c\uff0c\u6210\u529f\u540e\u518d\u628a\u63a7\u5236\u6743\u8fd8\u7ed9 {0} \u6d41\u7a0b\u3002", "After you enter the authorization code, the helper validates it independently and then returns control to the {0} flow."),
                modeLabel);
        }

        switch ((result.Status ?? string.Empty).Trim().ToLowerInvariant())
        {
            case "offline":
                return T(locale, "\u5f53\u524d\u65e0\u6cd5\u8fde\u63a5\u6388\u6743\u670d\u52a1\uff0c\u82e5\u672c\u5730 lease \u5df2\u8fc7\u671f\uff0c\u5219\u5fc5\u987b\u8054\u7f51\u624d\u80fd\u7ee7\u7eed\u3002", "The license service is currently unreachable. If the local lease has expired, you must reconnect to continue.");
            case "revoked":
                return T(locale, "\u8be5\u6388\u6743\u5df2\u88ab\u505c\u7528\uff0c\u8bf7\u8054\u7cfb\u7ba1\u7406\u5458\u786e\u8ba4\u6388\u6743\u72b6\u6001\u3002", "This license has been revoked. Contact your administrator to confirm the license status.");
            case "device-mismatch":
                return T(locale, "\u5f53\u524d\u8bbe\u5907\u4e0e\u672c\u5730\u6388\u6743\u72b6\u6001\u4e0d\u5339\u914d\uff0c\u901a\u5e38\u9700\u8981\u91cd\u65b0\u6fc0\u6d3b\u6216\u5148\u91ca\u653e\u65e7\u8bbe\u5907\u3002", "The current device does not match the local license state. Usually you need to reactivate or release the old device first.");
            default:
                return string.Format(
                    CultureInfo.InvariantCulture,
                    T(locale, "\u53ef\u4ee5\u5148\u590d\u5236\u53f3\u4fa7\u8bca\u65ad\u4fe1\u606f\u3002\u82e5 {0} \u6d41\u7a0b\u88ab\u6388\u6743\u62e6\u622a\uff0c\u5904\u7406\u5b8c\u6210\u540e\u4f1a\u81ea\u52a8\u7ee7\u7eed\u539f\u6d41\u7a0b\u3002", "You can copy the diagnostics on the right first. If the {0} flow is blocked by authorization, it resumes automatically after the issue is resolved."),
                    modeLabel);
        }
    }

    private static string BuildLocalStateSummary(string locale, LicenseState state, ProtectedLicenseState protectedState)
    {
        List<string> lines = new List<string>();
        lines.Add(T(locale, "\u8bbe\u5907\uff1a", "Device: ") + Environment.MachineName);
        if (state == null)
        {
            lines.Add(T(locale, "\u72b6\u6001\uff1a\u672a\u6fc0\u6d3b", "Status: not activated"));
            lines.Add(T(locale, "\u8bf4\u660e\uff1a\u672c\u5730\u8fd8\u6ca1\u6709\u53ef\u7528 lease \u7f13\u5b58\u3002", "Note: no local lease cache is available yet."));
            return string.Join(Environment.NewLine, lines.ToArray());
        }

        lines.Add(T(locale, "\u72b6\u6001\uff1a", "Status: ") + NormalizeStatus(state.Status));
        if (!string.IsNullOrWhiteSpace(state.MaskedLicenseCode))
        {
            lines.Add(T(locale, "\u6388\u6743\u7801\uff1a", "License: ") + state.MaskedLicenseCode);
        }
        if (!string.IsNullOrWhiteSpace(state.InstallationId))
        {
            lines.Add(T(locale, "\u5b89\u88c5 ID\uff1a", "Installation ID: ") + ShortenForDisplay(state.InstallationId, 16));
        }
        if (!string.IsNullOrWhiteSpace(state.ActivationId))
        {
            lines.Add(T(locale, "\u6fc0\u6d3b ID\uff1a", "Activation ID: ") + ShortenForDisplay(state.ActivationId, 16));
        }
        lines.Add(T(locale, "lease \u5230\u671f\uff1a", "Lease expires: ") + FormatDisplayTime(locale, state.LeaseExpiresAt));
        lines.Add(T(locale, "\u4e0b\u6b21\u5237\u65b0\uff1a", "Next refresh: ") + FormatDisplayTime(locale, state.RefreshAfter));
        if (protectedState != null && !string.IsNullOrWhiteSpace(protectedState.RuntimeGrantExpiresAt))
        {
            lines.Add(T(locale, "grant \u5230\u671f\uff1a", "Grant expires: ") + FormatDisplayTime(locale, protectedState.RuntimeGrantExpiresAt));
        }
        return string.Join(Environment.NewLine, lines.ToArray());
    }

    private static string BuildDiagnosticSnapshot(RuntimeContext context, string modeLabel, LicenseState state, ProtectedLicenseState protectedState, OperationResult result)
    {
        string locale = context == null ? DefaultLocale : context.Locale;
        List<string> lines = new List<string>();
        lines.Add("brand=" + GetBrandName(context));
        lines.Add("mode=" + (modeLabel ?? string.Empty));
        lines.Add("machineName=" + Environment.MachineName);
        lines.Add("product=" + (context == null ? string.Empty : (context.Product ?? string.Empty)));
        lines.Add("channel=" + (context == null ? string.Empty : (context.Channel ?? string.Empty)));
        lines.Add("version=" + (context == null ? string.Empty : (context.Version ?? string.Empty)));
        lines.Add("apiBaseUrl=" + (context == null ? string.Empty : (context.ApiBaseUrl ?? string.Empty)));
        lines.Add("resultStatus=" + (result == null ? string.Empty : (result.Status ?? string.Empty)));
        lines.Add("resultExitCode=" + (result == null ? string.Empty : ((int)result.ExitCode).ToString(CultureInfo.InvariantCulture)));
        lines.Add("resultMessage=" + (result == null ? string.Empty : (result.Message ?? string.Empty)).Replace(Environment.NewLine, " | "));
        lines.Add("activationId=" + (state == null ? string.Empty : (state.ActivationId ?? string.Empty)));
        lines.Add("installationId=" + (state == null ? string.Empty : (state.InstallationId ?? string.Empty)));
        lines.Add("maskedLicenseCode=" + (state == null ? string.Empty : (state.MaskedLicenseCode ?? string.Empty)));
        lines.Add("leaseExpiresAt=" + (state == null ? string.Empty : (state.LeaseExpiresAt ?? string.Empty)));
        lines.Add("refreshAfter=" + (state == null ? string.Empty : (state.RefreshAfter ?? string.Empty)));
        lines.Add("runtimeGrantExpiresAt=" + (protectedState == null ? string.Empty : (protectedState.RuntimeGrantExpiresAt ?? string.Empty)));
        lines.Add("capturedAtUtc=" + DateTimeOffset.UtcNow.ToString("o", CultureInfo.InvariantCulture));
        return string.Join(Environment.NewLine, lines.ToArray());
    }

    private static string ShortenForDisplay(string value, int maxLength)
    {
        if (string.IsNullOrWhiteSpace(value) || value.Length <= maxLength)
        {
            return value ?? string.Empty;
        }

        return value.Substring(0, Math.Max(4, maxLength - 6)) + "..." + value.Substring(value.Length - 3, 3);
    }

    private static string FormatDisplayTime(string locale, string rawValue)
    {
        if (string.IsNullOrWhiteSpace(rawValue))
        {
            return T(locale, "\u672a\u77e5", "unknown");
        }

        DateTimeOffset parsed;
        if (!DateTimeOffset.TryParse(rawValue, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out parsed))
        {
            return rawValue;
        }

        DateTimeOffset localTime = parsed.ToLocalTime();
        return localTime.ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture);
    }

    private static void OpenExternalTarget(string target)
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
        catch
        {
        }
    }

    private static OperationResult BuildApiFailureResult(RuntimeContext context, ApiResult apiResult, string scenario, LicenseExitCode defaultExitCode, string defaultStatus, string defaultMessage)
    {
        string status = ResolveApiFailureStatus(apiResult, defaultStatus);
        LicenseExitCode exitCode = MapFailureStatusToExitCode(status, apiResult == null ? false : apiResult.NetworkFailure, defaultExitCode);
        return new OperationResult
        {
            ExitCode = exitCode,
            Status = status,
            Message = BuildApiFailureMessage(context, apiResult, scenario, status, defaultMessage)
        };
    }

    private static string ResolveApiFailureStatus(ApiResult apiResult, string fallbackStatus)
    {
        if (apiResult == null)
        {
            return fallbackStatus;
        }

        Dictionary<string, object> envelope = GetObject(apiResult.Payload, "data") ?? apiResult.Payload;
        string status = GetString(envelope, "status", string.Empty);
        if (string.IsNullOrWhiteSpace(status))
        {
            status = GetString(apiResult.Payload, "status", string.Empty);
        }
        if (string.IsNullOrWhiteSpace(status))
        {
            status = apiResult.NetworkFailure ? "offline" : fallbackStatus;
        }
        return NormalizeStatus(status);
    }

    private static LicenseExitCode MapFailureStatusToExitCode(string status, bool networkFailure, LicenseExitCode defaultExitCode)
    {
        if (networkFailure || string.Equals(status, "offline", StringComparison.OrdinalIgnoreCase))
        {
            return LicenseExitCode.OfflineWithoutValidLease;
        }

        switch ((status ?? string.Empty).Trim().ToLowerInvariant())
        {
            case "revoked":
                return LicenseExitCode.Revoked;
            case "device-mismatch":
                return LicenseExitCode.DeviceMismatch;
            case "expired":
                return LicenseExitCode.Expired;
            case "not-activated":
                return LicenseExitCode.NotActivated;
            case "misconfigured":
                return LicenseExitCode.Misconfigured;
            default:
                return defaultExitCode;
        }
    }

    private static string BuildApiFailureMessage(RuntimeContext context, ApiResult apiResult, string scenario, string status, string defaultMessage)
    {
        string locale = context == null ? DefaultLocale : context.Locale;
        string apiMessage = apiResult == null ? string.Empty : (apiResult.ErrorMessage ?? string.Empty);
        string message = string.IsNullOrWhiteSpace(apiMessage) ? defaultMessage : apiMessage.Trim();
        string hint = BuildApiFailureHint(locale, scenario, status, apiResult == null ? 0 : apiResult.StatusCode, apiResult != null && apiResult.NetworkFailure);
        if (string.IsNullOrWhiteSpace(hint))
        {
            return message;
        }

        return message + Environment.NewLine + hint;
    }

    private static string BuildApiFailureHint(string locale, string scenario, string status, int statusCode, bool networkFailure)
    {
        if (networkFailure || string.Equals(status, "offline", StringComparison.OrdinalIgnoreCase))
        {
            return T(locale, "\u5f53\u524d\u5fc5\u987b\u8054\u7f51\u624d\u80fd\u5b8c\u6210\u6388\u6743\u6821\u9a8c\u3002\u5982\u679c\u672c\u5730 lease \u5df2\u8fc7\u671f\uff0c\u79bb\u7ebf\u65f6\u5c06\u65e0\u6cd5\u7ee7\u7eed\u4f7f\u7528\u3002", "A network connection is required to complete license validation. If the local lease has expired, offline use cannot continue.");
        }

        switch ((status ?? string.Empty).Trim().ToLowerInvariant())
        {
            case "invalid-code":
            case "invalid-auth-code":
            case "code-not-found":
            case "license-not-found":
                return T(locale, "\u8bf7\u6838\u5bf9\u6388\u6743\u7801\u662f\u5426\u5b8c\u6574\uff0c\u5e76\u907f\u514d O/0\u3001I/1 \u7b49\u6613\u6df7\u5b57\u7b26\u3002\u5982\u4e3a\u4eba\u5de5\u53d1\u7801\uff0c\u8bf7\u8054\u7cfb\u7ba1\u7406\u5458\u91cd\u65b0\u6838\u53d1\u3002", "Verify that the authorization code is complete and avoid confusing characters like O/0 or I/1. If the code was issued manually, ask your administrator to reissue it.");
            case "revoked":
                return T(locale, "\u8be5\u6388\u6743\u5df2\u88ab\u505c\u7528\uff0c\u8bf7\u8054\u7cfb\u7ba1\u7406\u5458\u786e\u8ba4\u6388\u6743\u72b6\u6001\u6216\u8ba2\u5355\u72b6\u6001\u3002", "This license has been revoked. Contact your administrator to confirm the license or order status.");
            case "device-limit-exceeded":
            case "max-devices":
            case "capacity-exceeded":
            case "device-capacity-exceeded":
                return T(locale, "\u8be5\u6388\u6743\u7801\u5df2\u8fbe\u8bbe\u5907\u4e0a\u9650\uff0c\u8bf7\u5148\u5728\u540e\u53f0\u91ca\u653e\u65e7\u8bbe\u5907\uff0c\u518d\u91cd\u65b0\u6fc0\u6d3b\u3002", "This authorization code has reached its device limit. Release an old device in the admin console before retrying.");
            case "device-mismatch":
                return T(locale, "\u5f53\u524d\u8bbe\u5907\u4e0e\u4e4b\u524d\u7684\u7ed1\u5b9a\u72b6\u6001\u4e0d\u5339\u914d\uff0c\u5efa\u8bae\u5148\u91ca\u653e\u65e7\u8bbe\u5907\u6216\u76f4\u63a5\u91cd\u65b0\u6fc0\u6d3b\u3002", "The current device does not match the previous binding. Release the old device first or reactivate directly.");
            case "expired":
                return T(locale, "\u5f53\u524d lease \u6216\u6388\u6743\u5df2\u8fc7\u671f\uff0c\u8bf7\u91cd\u65b0\u6fc0\u6d3b\u6216\u8054\u7cfb\u7ba1\u7406\u5458\u7eed\u671f\u3002", "The current lease or license has expired. Reactivate or contact your administrator to renew it.");
            case "misconfigured":
                return T(locale, "\u5f53\u524d\u5ba2\u6237\u7aef\u6ca1\u6709\u6b63\u786e\u914d\u7f6e License API \u5730\u5740\uff0c\u8bf7\u8054\u7cfb\u53d1\u884c\u6216\u8fd0\u7ef4\u540c\u4e8b\u91cd\u65b0\u53d1\u5e03\u3002", "The client is missing a valid License API address. Contact the release or operations team to republish the build.");
            default:
                if (statusCode == 401 || statusCode == 403)
                {
                    return T(locale, "\u670d\u52a1\u7aef\u62d2\u7edd\u4e86\u5f53\u524d\u6388\u6743\u8bf7\u6c42\uff0c\u8bf7\u8054\u7cfb\u7ba1\u7406\u5458\u68c0\u67e5\u6388\u6743\u72b6\u6001\u3002", "The server rejected this authorization request. Contact your administrator to inspect the license state.");
                }

                if (statusCode == 409 || string.Equals(scenario, "activate", StringComparison.OrdinalIgnoreCase))
                {
                    return T(locale, "\u82e5\u95ee\u9898\u6301\u7eed\uff0c\u8bf7\u590d\u5236\u53f3\u4fa7\u8bca\u65ad\u4fe1\u606f\u5e76\u8054\u7cfb\u7ba1\u7406\u5458\u6216\u6388\u6743\u652f\u6301\u3002", "If the issue persists, copy the diagnostics on the right and contact your administrator or license support.");
                }

                return string.Empty;
        }
    }

    private static ApiResult PostJson(string url, Dictionary<string, object> payload)
    {
        ApiResult result = new ApiResult();
        byte[] requestBytes = Encoding.UTF8.GetBytes(SerializeJson(payload));
        try
        {
            HttpWebRequest request = (HttpWebRequest)WebRequest.Create(url);
            request.Method = "POST";
            request.ContentType = "application/json; charset=utf-8";
            request.Accept = "application/json";
            request.Timeout = 15000;
            request.ReadWriteTimeout = 15000;
            request.ContentLength = requestBytes.Length;
            using (Stream requestStream = request.GetRequestStream())
            {
                requestStream.Write(requestBytes, 0, requestBytes.Length);
            }

            using (HttpWebResponse response = (HttpWebResponse)request.GetResponse())
            using (StreamReader reader = new StreamReader(response.GetResponseStream(), Encoding.UTF8))
            {
                result.StatusCode = (int)response.StatusCode;
                result.Payload = DeserializeObject(reader.ReadToEnd());
                result.Succeeded = result.StatusCode >= 200 && result.StatusCode < 300;
                result.ErrorMessage = GetString(result.Payload, "message", string.Empty);
            }
        }
        catch (WebException ex)
        {
            result.Succeeded = false;
            result.NetworkFailure = ex.Status != WebExceptionStatus.ProtocolError;
            result.ErrorMessage = ex.Message;
            if (ex.Response != null)
            {
                using (StreamReader reader = new StreamReader(ex.Response.GetResponseStream(), Encoding.UTF8))
                {
                    result.Payload = DeserializeObject(reader.ReadToEnd());
                    string message = GetString(result.Payload, "message", string.Empty);
                    if (!string.IsNullOrWhiteSpace(message))
                    {
                        result.ErrorMessage = message;
                    }
                }
            }
        }

        return result;
    }

    private static string ComputeDeviceFingerprintHash()
    {
        string machineGuid = string.Empty;
        using (RegistryKey key = Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Microsoft\Cryptography"))
        {
            if (key != null)
            {
                machineGuid = Convert.ToString(key.GetValue("MachineGuid"), CultureInfo.InvariantCulture) ?? string.Empty;
            }
        }

        string raw = string.Join("|", new[]
        {
            machineGuid,
            Environment.MachineName ?? string.Empty,
            Environment.OSVersion.VersionString ?? string.Empty,
            Environment.Is64BitOperatingSystem ? "x64" : "x86"
        });

        using (SHA256 sha = SHA256.Create())
        {
            return BitConverter.ToString(sha.ComputeHash(Encoding.UTF8.GetBytes(raw))).Replace("-", string.Empty).ToLowerInvariant();
        }
    }

    private static string ProtectString(string value)
    {
        byte[] entropy = Encoding.UTF8.GetBytes("OpenClaw-License-State-v1");
        byte[] plain = Encoding.UTF8.GetBytes(value ?? string.Empty);
        return Convert.ToBase64String(ProtectedData.Protect(plain, entropy, DataProtectionScope.LocalMachine));
    }

    private static string UnprotectString(string value)
    {
        byte[] entropy = Encoding.UTF8.GetBytes("OpenClaw-License-State-v1");
        byte[] plain = ProtectedData.Unprotect(Convert.FromBase64String(value ?? string.Empty), entropy, DataProtectionScope.LocalMachine);
        return Encoding.UTF8.GetString(plain);
    }

    private static Dictionary<string, object> ReadJsonDictionary(string path)
    {
        return File.Exists(path) ? DeserializeObject(File.ReadAllText(path, Encoding.UTF8)) : new Dictionary<string, object>(StringComparer.OrdinalIgnoreCase);
    }

    private static Dictionary<string, object> DeserializeObject(string content)
    {
        if (string.IsNullOrWhiteSpace(content))
        {
            return new Dictionary<string, object>(StringComparer.OrdinalIgnoreCase);
        }

        object parsed = Json.DeserializeObject(content);
        return parsed as Dictionary<string, object> ?? new Dictionary<string, object>(StringComparer.OrdinalIgnoreCase);
    }

    private static string SerializeJson(object value)
    {
        return Json.Serialize(value ?? new Dictionary<string, object>(StringComparer.OrdinalIgnoreCase));
    }

    private static Dictionary<string, object> GetObject(Dictionary<string, object> payload, string key)
    {
        if (payload == null || string.IsNullOrWhiteSpace(key) || !payload.ContainsKey(key) || payload[key] == null)
        {
            return null;
        }

        return payload[key] as Dictionary<string, object>;
    }

    private static string GetString(Dictionary<string, object> payload, string key, string fallback)
    {
        if (payload == null || string.IsNullOrWhiteSpace(key) || !payload.ContainsKey(key) || payload[key] == null)
        {
            return fallback;
        }

        string value = Convert.ToString(payload[key], CultureInfo.InvariantCulture);
        return string.IsNullOrWhiteSpace(value) ? fallback : value;
    }

    private static DateTimeOffset ParseTime(string rawValue, DateTimeOffset fallback)
    {
        DateTimeOffset parsed;
        return DateTimeOffset.TryParse(rawValue, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out parsed) ? parsed : fallback;
    }

    private static string NormalizeBaseUrl(string value)
    {
        return string.IsNullOrWhiteSpace(value) ? string.Empty : value.Trim().TrimEnd('/');
    }

    private static string NormalizeInstallationId(string value)
    {
        return string.IsNullOrWhiteSpace(value) ? string.Empty : value.Trim();
    }

    private static string NormalizeStatus(string value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return "unknown";
        }

        string normalized = value.Trim().ToLowerInvariant();
        return normalized == "ok" || normalized == "active" ? "valid" : normalized;
    }

    private static string MaskCode(string value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return string.Empty;
        }

        if (value.StartsWith("OC-", StringComparison.OrdinalIgnoreCase))
        {
            string[] parts = value.Split('-');
            if (parts.Length >= 3)
            {
                return parts[0] + "-****-****-" + parts[parts.Length - 1];
            }
        }

        return value.Length > 8 ? value.Substring(0, 4) + "****" + value.Substring(value.Length - 4, 4) : value;
    }

    private static void EnsureDirectory(string path)
    {
        if (!string.IsNullOrWhiteSpace(path))
        {
            Directory.CreateDirectory(path);
        }
    }

    private static string GetModeLabel(string locale, string mode)
    {
        switch ((mode ?? string.Empty).Trim().ToLowerInvariant())
        {
            case "start": return T(locale, "\u542f\u52a8", "Start");
            case "update": return T(locale, "\u66f4\u65b0", "Update");
            case "repair": return T(locale, "\u4fee\u590d", "Repair");
            default: return "CLI";
        }
    }

    private static string T(string locale, string zhCn, string enUs)
    {
        return string.Equals(locale, "zh-CN", StringComparison.OrdinalIgnoreCase) ? zhCn : enUs;
    }
}
