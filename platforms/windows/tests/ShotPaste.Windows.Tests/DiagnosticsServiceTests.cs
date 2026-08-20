using System.IO.Compression;
using ShotPaste.Windows.Models;
using ShotPaste.Windows.Services;

namespace ShotPaste.Windows.Tests;

public sealed class DiagnosticsServiceTests
{
    [Fact]
    public void SupportBundle_RedactsPathsDeviceIdentityAndMcpToken()
    {
        var destination = Path.Combine(Path.GetTempPath(), $"ShotPaste-Diagnostics-{Guid.NewGuid():N}.zip");
        var settings = new AppSettings
        {
            SaveDirectory = @"C:\private\captures",
            RecordingMicrophoneDeviceId = "private-device-id",
            RecordingMicrophoneDeviceName = "Private Microphone",
            McpServerAuthToken = "private-mcp-token"
        };
        try
        {
            DiagnosticsService.CreateSupportBundle(destination, settings);

            using var archive = ZipFile.OpenRead(destination);
            var entry = Assert.Single(archive.Entries, item => item.FullName == "settings-sanitized.json");
            using var reader = new StreamReader(entry.Open());
            var content = reader.ReadToEnd();
            Assert.DoesNotContain(settings.SaveDirectory, content, StringComparison.Ordinal);
            Assert.DoesNotContain(settings.RecordingMicrophoneDeviceId, content, StringComparison.Ordinal);
            Assert.DoesNotContain(settings.RecordingMicrophoneDeviceName, content, StringComparison.Ordinal);
            Assert.DoesNotContain(settings.McpServerAuthToken, content, StringComparison.Ordinal);
            using var document = System.Text.Json.JsonDocument.Parse(content);
            foreach (var property in new[]
                     {
                         "SaveDirectory", "RecordingMicrophoneDeviceId", "RecordingMicrophoneDeviceName",
                         "McpServerAuthToken"
                     })
                Assert.Equal("<redacted>", document.RootElement.GetProperty(property).GetString());
        }
        finally
        {
            if (File.Exists(destination)) File.Delete(destination);
        }
    }
}
