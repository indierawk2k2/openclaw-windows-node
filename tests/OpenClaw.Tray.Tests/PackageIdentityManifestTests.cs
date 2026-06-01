using System.Diagnostics;
using System.Xml.Linq;

namespace OpenClaw.Tray.Tests;

public sealed class PackageIdentityManifestTests
{
    private static readonly XNamespace AppxNs = "http://schemas.microsoft.com/appx/manifest/foundation/windows10";
    private static readonly XNamespace UapNs = "http://schemas.microsoft.com/appx/manifest/uap/windows10";
    private static readonly XNamespace Uap10Ns = "http://schemas.microsoft.com/appx/manifest/uap/windows10/10";
    private static readonly XNamespace RescapNs = "http://schemas.microsoft.com/appx/manifest/foundation/windows10/restrictedcapabilities";
    private static readonly XNamespace MsixNs = "urn:schemas-microsoft-com:msix.v1";

    [Fact]
    public void WinUiAppManifest_MsixIdentityMatchesPackageManifest()
    {
        var root = GetRepositoryRoot();
        var packageManifest = XDocument.Load(Path.Combine(root, "src", "OpenClaw.Tray.WinUI", "Package.appxmanifest"));
        var appManifest = XDocument.Load(Path.Combine(root, "src", "OpenClaw.Tray.WinUI", "app.manifest"));

        var identity = RequiredElement(packageManifest.Root, AppxNs + "Identity");
        var application = packageManifest
            .Descendants(AppxNs + "Application")
            .Single(element => (string?)element.Attribute("Id") == "App");
        var msix = appManifest.Root!
            .Elements(MsixNs + "msix")
            .Single();

        Assert.Equal((string?)identity.Attribute("Name"), (string?)msix.Attribute("packageName"));
        Assert.Equal((string?)identity.Attribute("Publisher"), (string?)msix.Attribute("publisher"));
        Assert.Equal((string?)application.Attribute("Id"), (string?)msix.Attribute("applicationId"));
        Assert.Null(msix.Attribute("version"));
    }

    [Fact]
    public void BuildPackageIdentityScript_StagesSparseManifest()
    {
        var root = GetRepositoryRoot();
        var stagingRoot = Path.Combine(Path.GetTempPath(), "OpenClawPackageIdentityTests", Guid.NewGuid().ToString("N"));

        try
        {
            RunPowerShellScript(
                Path.Combine(root, "scripts", "build-package-identity.ps1"),
                "-StagingRoot", stagingRoot,
                "-Version", "1.2.3",
                "-SkipPack");

            var stagedManifest = XDocument.Load(Path.Combine(stagingRoot, "AppxManifest.xml"));
            var identity = RequiredElement(stagedManifest.Root, AppxNs + "Identity");
            var properties = RequiredElement(stagedManifest.Root, AppxNs + "Properties");
            var application = stagedManifest
                .Descendants(AppxNs + "Application")
                .Single(element => (string?)element.Attribute("Id") == "App");
            var visualElements = RequiredElement(application, UapNs + "VisualElements");
            var targetDeviceFamily = stagedManifest
                .Descendants(AppxNs + "TargetDeviceFamily")
                .Single(element => (string?)element.Attribute("Name") == "Windows.Desktop");
            var capabilityNames = stagedManifest
                .Descendants(RescapNs + "Capability")
                .Select(element => (string?)element.Attribute("Name"))
                .ToHashSet(StringComparer.Ordinal);

            Assert.Equal("OpenClaw.Companion", (string?)identity.Attribute("Name"));
            Assert.Equal("1.2.3.0", (string?)identity.Attribute("Version"));
            Assert.Equal("neutral", (string?)identity.Attribute("ProcessorArchitecture"));
            Assert.Equal(
                "true",
                (string?)RequiredElement(properties, Uap10Ns + "AllowExternalContent"));
            Assert.True(
                Version.Parse((string)targetDeviceFamily.Attribute("MinVersion")!) >= Version.Parse("10.0.19041.0"));

            Assert.Equal("OpenClaw.Tray.WinUI.exe", (string?)application.Attribute("Executable"));
            Assert.Equal("mediumIL", (string?)application.Attribute(Uap10Ns + "TrustLevel"));
            Assert.Equal("win32App", (string?)application.Attribute(Uap10Ns + "RuntimeBehavior"));
            Assert.Null(application.Attribute("EntryPoint"));
            Assert.Equal("none", (string?)visualElements.Attribute("AppListEntry"));
            Assert.Contains(
                application.Descendants(UapNs + "Protocol"),
                element => (string?)element.Attribute("Name") == "openclaw");

            Assert.Contains("runFullTrust", capabilityNames);
            Assert.Contains("unvirtualizedResources", capabilityNames);
            Assert.True(File.Exists(Path.Combine(stagingRoot, "Assets", "StoreLogo.png")));
            Assert.False(Directory.Exists(Path.Combine(stagingRoot, "Assets", "Setup")));
        }
        finally
        {
            if (Directory.Exists(stagingRoot))
                Directory.Delete(stagingRoot, recursive: true);
        }
    }

    [Fact]
    public void SetupEngineManifest_DoesNotDeclarePackageIdentity()
    {
        var root = GetRepositoryRoot();
        var setupManifestPath = Path.Combine(root, "src", "OpenClaw.SetupEngine.UI", "app.manifest");
        var setupManifest = XDocument.Load(setupManifestPath);

        Assert.DoesNotContain(setupManifest.Root!.Descendants(), element => element.Name == MsixNs + "msix");
    }

    private static XElement RequiredElement(XContainer? container, XName name)
    {
        var element = container?.Element(name);
        Assert.NotNull(element);
        return element;
    }

    private static void RunPowerShellScript(string scriptPath, params string[] arguments)
    {
        using var process = new Process();
        process.StartInfo.FileName = ResolvePowerShell();
        process.StartInfo.ArgumentList.Add("-NoLogo");
        process.StartInfo.ArgumentList.Add("-NoProfile");
        process.StartInfo.ArgumentList.Add("-NonInteractive");
        process.StartInfo.ArgumentList.Add("-ExecutionPolicy");
        process.StartInfo.ArgumentList.Add("Bypass");
        process.StartInfo.ArgumentList.Add("-File");
        process.StartInfo.ArgumentList.Add(scriptPath);
        foreach (var argument in arguments)
            process.StartInfo.ArgumentList.Add(argument);

        process.StartInfo.RedirectStandardOutput = true;
        process.StartInfo.RedirectStandardError = true;

        process.Start();
        var stdout = process.StandardOutput.ReadToEnd();
        var stderr = process.StandardError.ReadToEnd();
        Assert.True(
            process.WaitForExit(TimeSpan.FromSeconds(30)),
            $"Timed out while running {Path.GetFileName(scriptPath)}. Stdout: {stdout}. Stderr: {stderr}");
        Assert.True(
            process.ExitCode == 0,
            $"{Path.GetFileName(scriptPath)} exited with {process.ExitCode}. Stdout: {stdout}. Stderr: {stderr}");
    }

    private static string ResolvePowerShell()
    {
        var windowsPowerShell = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.Windows),
            "System32",
            "WindowsPowerShell",
            "v1.0",
            "powershell.exe");

        return File.Exists(windowsPowerShell) ? windowsPowerShell : "pwsh";
    }

    private static string GetRepositoryRoot()
    {
        var env = Environment.GetEnvironmentVariable("OPENCLAW_REPO_ROOT");
        if (!string.IsNullOrWhiteSpace(env) && Directory.Exists(env))
            return env;

        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory != null)
        {
            if (File.Exists(Path.Combine(directory.FullName, "openclaw-windows-node.slnx")) &&
                Directory.Exists(Path.Combine(directory.FullName, "src")))
            {
                return directory.FullName;
            }

            directory = directory.Parent;
        }

        throw new InvalidOperationException("Could not find repository root.");
    }
}
