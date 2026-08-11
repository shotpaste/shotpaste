using Xunit;

// WPF imaging, Windows OCR and System.Drawing all use process-wide native state.
[assembly: CollectionBehavior(DisableTestParallelization = true)]
