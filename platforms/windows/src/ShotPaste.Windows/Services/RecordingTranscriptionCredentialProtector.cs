using System.Security.Cryptography;
using System.Text;

namespace ShotPaste.Windows.Services;

public static class RecordingTranscriptionCredentialProtector
{
    private static readonly byte[] Entropy = Encoding.UTF8.GetBytes(
        "ShotPaste.Windows.VolcengineRecordingTranscription.v1");

    internal static string ProtectSnapshot(RecordingTranscriptionConfiguration configuration)
    {
        var bytes = System.Text.Json.JsonSerializer.SerializeToUtf8Bytes(configuration);
        try { return Convert.ToBase64String(ProtectedData.Protect(bytes, null, DataProtectionScope.CurrentUser)); }
        finally { CryptographicOperations.ZeroMemory(bytes); }
    }
    internal static RecordingTranscriptionConfiguration UnprotectSnapshot(string protectedValue)
    {
        var bytes = ProtectedData.Unprotect(Convert.FromBase64String(protectedValue), null, DataProtectionScope.CurrentUser);
        try { return System.Text.Json.JsonSerializer.Deserialize<RecordingTranscriptionConfiguration>(bytes) ?? throw new System.Text.Json.JsonException(); }
        finally { CryptographicOperations.ZeroMemory(bytes); }
    }

    public static string Protect(string? value)
    {
        var normalized = (value ?? string.Empty).Trim();
        if (string.IsNullOrEmpty(normalized)) return string.Empty;
        if (normalized.Length > 4_096 || normalized.Contains('\r') || normalized.Contains('\n'))
            throw new ArgumentException("The API Key is invalid.", nameof(value));
        var plaintext = Encoding.UTF8.GetBytes(normalized);
        try
        {
            return Convert.ToBase64String(ProtectedData.Protect(
                plaintext,
                Entropy,
                DataProtectionScope.CurrentUser));
        }
        finally
        {
            CryptographicOperations.ZeroMemory(plaintext);
        }
    }

    public static string Unprotect(string? protectedValue)
    {
        if (string.IsNullOrWhiteSpace(protectedValue)) return string.Empty;
        byte[] encrypted;
        try { encrypted = Convert.FromBase64String(protectedValue); }
        catch (FormatException) { return string.Empty; }

        byte[]? plaintext = null;
        try
        {
            plaintext = ProtectedData.Unprotect(encrypted, Entropy, DataProtectionScope.CurrentUser);
            return Encoding.UTF8.GetString(plaintext);
        }
        catch (CryptographicException)
        {
            return string.Empty;
        }
        finally
        {
            CryptographicOperations.ZeroMemory(encrypted);
            if (plaintext is not null) CryptographicOperations.ZeroMemory(plaintext);
        }
    }
}
