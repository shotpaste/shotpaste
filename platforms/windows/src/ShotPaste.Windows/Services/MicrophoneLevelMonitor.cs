using System.Runtime.InteropServices;
using ShotPaste.Windows.Models;

namespace ShotPaste.Windows.Services;

public enum MicrophoneFeedbackState
{
    Disabled,
    Active,
    NoInput,
    Muted,
    Disconnected
}

public sealed record MicrophoneLevelSnapshot(MicrophoneFeedbackState State, double Level);

/// <summary>
/// Reads the same Core Audio capture endpoint and input gain selected for the
/// recorder. Failures are converted to a disconnected state so device removal
/// cannot terminate a recording or its toolbar.
/// </summary>
public sealed class MicrophoneLevelMonitor : IDisposable
{
    private const uint DeviceStateActive = 0x1;
    private const uint ClsCtxAll = 23;
    private readonly bool _enabled;
    private readonly string _deviceId;
    private readonly double _inputVolume;
    private IMMDeviceEnumerator? _enumerator;
    private IMMDevice? _device;
    private IAudioMeterInformation? _meter;
    private IAudioEndpointVolume? _endpointVolume;
    private DateTimeOffset _lastSignal = DateTimeOffset.UtcNow;
    private DateTimeOffset _lastOpenAttempt = DateTimeOffset.MinValue;
    private bool _disposed;

    public MicrophoneLevelMonitor(AppSettings settings)
    {
        _enabled = settings.RecordMicrophone;
        _deviceId = settings.RecordingMicrophoneDeviceId;
        _inputVolume = Math.Clamp(settings.RecordingMicrophoneVolume, 0d, 1d);
        if (_enabled) TryOpen();
    }

    public MicrophoneLevelSnapshot Read(DateTimeOffset? timestamp = null)
    {
        if (!_enabled) return new MicrophoneLevelSnapshot(MicrophoneFeedbackState.Disabled, 0);
        if (_disposed) return new MicrophoneLevelSnapshot(MicrophoneFeedbackState.Disconnected, 0);
        var now = timestamp ?? DateTimeOffset.UtcNow;
        if (_meter is null && now - _lastOpenAttempt >= TimeSpan.FromSeconds(1)) TryOpen();
        if (_meter is null || _device is null) return new MicrophoneLevelSnapshot(MicrophoneFeedbackState.Disconnected, 0);
        try
        {
            if (_device.GetState(out var state) != 0 || (state & DeviceStateActive) == 0)
            {
                ReleaseEndpoint();
                return new MicrophoneLevelSnapshot(MicrophoneFeedbackState.Disconnected, 0);
            }
            if (_inputVolume <= 0.0001d ||
                (_endpointVolume is not null && _endpointVolume.GetMute(out var muted) == 0 && muted))
                return new MicrophoneLevelSnapshot(MicrophoneFeedbackState.Muted, 0);
            if (_meter.GetPeakValue(out var peak) != 0)
            {
                ReleaseEndpoint();
                return new MicrophoneLevelSnapshot(MicrophoneFeedbackState.Disconnected, 0);
            }
            var effective = Math.Clamp(peak * _inputVolume, 0d, 1d);
            if (effective >= 0.006d) _lastSignal = now;
            var feedback = effective >= 0.006d || now - _lastSignal < TimeSpan.FromSeconds(1.25)
                ? MicrophoneFeedbackState.Active
                : MicrophoneFeedbackState.NoInput;
            return new MicrophoneLevelSnapshot(feedback, effective);
        }
        catch (Exception exception) when (exception is COMException or InvalidComObjectException)
        {
            ReleaseEndpoint();
            return new MicrophoneLevelSnapshot(MicrophoneFeedbackState.Disconnected, 0);
        }
    }

    internal static MicrophoneLevelSnapshot Classify(
        bool enabled,
        bool connected,
        bool muted,
        double rawLevel,
        double inputVolume,
        TimeSpan silenceDuration)
    {
        if (!enabled) return new MicrophoneLevelSnapshot(MicrophoneFeedbackState.Disabled, 0);
        if (!connected) return new MicrophoneLevelSnapshot(MicrophoneFeedbackState.Disconnected, 0);
        if (muted || inputVolume <= 0.0001d) return new MicrophoneLevelSnapshot(MicrophoneFeedbackState.Muted, 0);
        var effective = Math.Clamp(rawLevel * inputVolume, 0d, 1d);
        var state = effective < 0.006d && silenceDuration >= TimeSpan.FromSeconds(1.25)
            ? MicrophoneFeedbackState.NoInput
            : MicrophoneFeedbackState.Active;
        return new MicrophoneLevelSnapshot(state, effective);
    }

    private void TryOpen()
    {
        _lastOpenAttempt = DateTimeOffset.UtcNow;
        ReleaseEndpoint();
        try
        {
            _enumerator ??= (IMMDeviceEnumerator)(object)new MMDeviceEnumeratorComObject();
            var result = string.IsNullOrWhiteSpace(_deviceId)
                ? _enumerator.GetDefaultAudioEndpoint(EDataFlow.Capture, ERole.Console, out _device)
                : _enumerator.GetDevice(_deviceId, out _device);
            if (result != 0 || _device is null) { ReleaseEndpoint(); return; }
            var meterId = typeof(IAudioMeterInformation).GUID;
            result = _device.Activate(ref meterId, ClsCtxAll, IntPtr.Zero, out var meterObject);
            if (result != 0 || meterObject is not IAudioMeterInformation meter)
            {
                ReleaseComObject(meterObject);
                ReleaseEndpoint();
                return;
            }
            _meter = meter;
            var volumeId = typeof(IAudioEndpointVolume).GUID;
            if (_device.Activate(ref volumeId, ClsCtxAll, IntPtr.Zero, out var volumeObject) == 0 &&
                volumeObject is IAudioEndpointVolume endpointVolume)
                _endpointVolume = endpointVolume;
            else
                ReleaseComObject(volumeObject);
            _lastSignal = DateTimeOffset.UtcNow;
        }
        catch (Exception exception) when (exception is COMException or InvalidCastException or UnauthorizedAccessException)
        {
            ReleaseEndpoint();
        }
    }

    private void ReleaseEndpoint()
    {
        ReleaseComObject(_endpointVolume);
        ReleaseComObject(_meter);
        ReleaseComObject(_device);
        _endpointVolume = null;
        _meter = null;
        _device = null;
    }

    private static void ReleaseComObject(object? value)
    {
        if (value is not null && Marshal.IsComObject(value))
        {
            try { Marshal.FinalReleaseComObject(value); }
            catch (InvalidComObjectException) { }
        }
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        ReleaseEndpoint();
        ReleaseComObject(_enumerator);
        _enumerator = null;
    }

    private enum EDataFlow { Render, Capture, All }
    private enum ERole { Console, Multimedia, Communications }

    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    private sealed class MMDeviceEnumeratorComObject;

    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMMDeviceEnumerator
    {
        [PreserveSig] int EnumAudioEndpoints(EDataFlow dataFlow, uint stateMask, out IntPtr devices);
        [PreserveSig] int GetDefaultAudioEndpoint(EDataFlow dataFlow, ERole role, out IMMDevice? device);
        [PreserveSig] int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id, out IMMDevice? device);
        [PreserveSig] int RegisterEndpointNotificationCallback(IntPtr client);
        [PreserveSig] int UnregisterEndpointNotificationCallback(IntPtr client);
    }

    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMMDevice
    {
        [PreserveSig] int Activate(ref Guid interfaceId, uint context, IntPtr activationParameters,
            [MarshalAs(UnmanagedType.IUnknown)] out object? interfaceObject);
        [PreserveSig] int OpenPropertyStore(uint access, out IntPtr properties);
        [PreserveSig] int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
        [PreserveSig] int GetState(out uint state);
    }

    [ComImport, Guid("C02216F6-8C67-4B5B-9D00-D008E73E0064"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IAudioMeterInformation
    {
        [PreserveSig] int GetPeakValue(out float peak);
        [PreserveSig] int GetMeteringChannelCount(out int channelCount);
        [PreserveSig] int GetChannelsPeakValues(int channelCount, [Out] float[] peakValues);
        [PreserveSig] int QueryHardwareSupport(out int hardwareSupportMask);
    }

    [ComImport, Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IAudioEndpointVolume
    {
        [PreserveSig] int RegisterControlChangeNotify(IntPtr notify);
        [PreserveSig] int UnregisterControlChangeNotify(IntPtr notify);
        [PreserveSig] int GetChannelCount(out uint channelCount);
        [PreserveSig] int SetMasterVolumeLevel(float levelDb, IntPtr context);
        [PreserveSig] int SetMasterVolumeLevelScalar(float level, IntPtr context);
        [PreserveSig] int GetMasterVolumeLevel(out float levelDb);
        [PreserveSig] int GetMasterVolumeLevelScalar(out float level);
        [PreserveSig] int SetChannelVolumeLevel(uint channel, float levelDb, IntPtr context);
        [PreserveSig] int SetChannelVolumeLevelScalar(uint channel, float level, IntPtr context);
        [PreserveSig] int GetChannelVolumeLevel(uint channel, out float levelDb);
        [PreserveSig] int GetChannelVolumeLevelScalar(uint channel, out float level);
        [PreserveSig] int SetMute([MarshalAs(UnmanagedType.Bool)] bool mute, IntPtr context);
        [PreserveSig] int GetMute([MarshalAs(UnmanagedType.Bool)] out bool mute);
        [PreserveSig] int GetVolumeStepInfo(out uint step, out uint stepCount);
        [PreserveSig] int VolumeStepUp(IntPtr context);
        [PreserveSig] int VolumeStepDown(IntPtr context);
        [PreserveSig] int QueryHardwareSupport(out uint supportMask);
        [PreserveSig] int GetVolumeRange(out float minimumDb, out float maximumDb, out float incrementDb);
    }
}
