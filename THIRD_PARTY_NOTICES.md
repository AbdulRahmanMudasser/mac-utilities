# Third-Party Notices

The MIT license in the repository root applies only to original Mac Utilities source code. The following components and model assets retain their own licenses. Speech-model weights are downloaded or imported by each user and are not included in this repository or the app bundle.

## whisper.cpp runtime and local VAD patch

The app builds the whisper.cpp runtime from revision `d1be6fde11ac6e0407606b4e42fe72d34add8037`. `Scripts/Speech/whisper-vad-compute-error.patch` is applied to that source. The runtime is covered by the upstream [MIT license](https://github.com/ggml-org/whisper.cpp/blob/d1be6fde11ac6e0407606b4e42fe72d34add8037/LICENSE), which the build script copies into the generated framework. The locally authored patch is covered by the repository's root MIT License.

Copyright (c) 2023-2026 The ggml authors.

## English speech model

The app downloads `ggml-large-v3-turbo-q5_0.bin` from the [ggerganov/whisper.cpp model repository](https://huggingface.co/ggerganov/whisper.cpp/tree/98aa99a0a9db05ae2342309f5096248665f7cba3). That repository identifies the model asset as MIT licensed. The model file is downloaded for local use and is not bundled or redistributed by Mac Utilities.

Copyright (c) 2023-2026 The ggml authors.

## Silero voice activity detector

The app downloads `ggml-silero-v6.2.0.bin` from the [ggml-org/whisper-vad repository](https://huggingface.co/ggml-org/whisper-vad/tree/9ffd54a1e1ee413ddf265af9913beaf518d1639b). The repository and upstream Silero VAD project identify this asset as MIT licensed; see the upstream [Silero VAD MIT license](https://github.com/snakers4/silero-vad/blob/master/LICENSE). It is not bundled in this repository.

Copyright (c) 2020-present Silero Team.

## Urdu Sukhan ASR v1

Urdu Sukhan ASR v1 is developed by Asad Shehzad and Loudness.ai. The [publisher's model page](https://huggingface.co/Loudness-ai/urdu-sukhan-asr-v1) identifies it as CC BY-NC 4.0, non-commercial, and gated by individual access approval. The app can import the publisher's q5_0 file after a user selects it and pinned integrity checks pass. Mac Utilities does not ship that file or grant access to it. Each user must request approval for their own account and follow the publisher's current license terms.

Attribution: *Urdu Sukhan ASR v1* by Asad Shehzad / Loudness.ai, licensed under [CC BY-NC 4.0](https://creativecommons.org/licenses/by-nc/4.0/). No model-weight changes are made by Mac Utilities.

## MIT license text

The MIT-licensed third-party components included by this project are the whisper.cpp runtime and Silero VAD. Their upstream notices are reproduced here:

```text
MIT License

Copyright (c) 2023-2026 The ggml authors
Copyright (c) 2020-present Silero Team

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
