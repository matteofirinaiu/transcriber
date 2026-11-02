# Third-party notices

Transcriber's own code is released under the MIT License (see [LICENSE](LICENSE)). It relies on the open-source software and models below. Their full license texts ship inside the app, in `Transcriber.app/Contents/Resources/Licenses`.

## Built into the app

| Component | License | Source |
|---|---|---|
| FluidAudio, by FluidInference | Apache License 2.0 | [github.com/FluidInference/FluidAudio](https://github.com/FluidInference/FluidAudio) |

FluidAudio includes code and data under their own licenses, such as fastcluster, VBx and NeMo text processing. See its [ThirdPartyLicenses](https://github.com/FluidInference/FluidAudio/tree/main/ThirdPartyLicenses) folder.

## Downloaded on first launch

These models aren't part of this repository or of the app. Transcriber downloads them once from Hugging Face, with no account.

| Model | License | Source |
|---|---|---|
| Parakeet Ultra speech recognition, based on NVIDIA Parakeet TDT 0.6B v3 and converted to Core ML by FluidInference | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) | [FluidInference/parakeet-ultra-coreml](https://huggingface.co/FluidInference/parakeet-ultra-coreml) |
| Silero VAD voice detector, converted to Core ML by FluidInference | MIT | [FluidInference/silero-vad-coreml](https://huggingface.co/FluidInference/silero-vad-coreml) |
| Speaker separation models from pyannote "community-1", converted to Core ML by FluidInference | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) | [FluidInference/speaker-diarization-coreml](https://huggingface.co/FluidInference/speaker-diarization-coreml) |
