<p align="center">
<img height="256" src="https://github.com/godly-devotion/MochiDiffusion/raw/main/Mochi Diffusion/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png" />
</p>

<h1 align="center">Mochi Diffusion</h1>

<p align="center">Run Stable Diffusion on Mac natively</p>

<p align="center">
<a href="https://github.com/godly-devotion/MochiDiffusion/blob/main/README.md">English</a>,
<a href="https://github.com/godly-devotion/MochiDiffusion/blob/main/README.ko.md">한국어</a>,
<a href="https://github.com/godly-devotion/MochiDiffusion/blob/main/README.zh-Hans.md">中文</a>
</p>

![Screenshot](.github/images/screenshot.png)

## Description

This app uses [Apple's Core ML Stable Diffusion implementation](https://github.com/apple/ml-stable-diffusion) to achieve maximum performance and speed on Apple Silicon based Macs while reducing memory requirements. It also runs on Intel based Macs too.

## Features

- Extremely fast and memory efficient (~150MB with Neural Engine)
- Runs well on all Apple Silicon Macs by fully utilizing Neural Engine
- Generate images locally and completely offline
- Generated images are saved with prompt info inside EXIF metadata
- Convert generated images to high resolution (using RealESRGAN)
- Use custom Stable Diffusion Core ML models
- No worries about pickled models
- macOS native app using SwiftUI

## Releases

Download the latest version from the [releases](https://github.com/godly-devotion/MochiDiffusion/releases) page.

## Running

When using a model for the very first time, it may take up to 2 minutes for the Neural Engine to compile a cached version. Afterwards, subsequent generations will be much faster.

## Compute Unit

- `CPU & Neural Engine` provides a good balance between speed and low memory usage
- `CPU & GPU` may be faster on M1 Max, Ultra and later but will use more memory

Depending on the option chosen, you will need to use the correct model version (see Models section for details).

Intel Macs uses `CPU & GPU` as it doesn't have Neural Engine.

## Models

You will need to convert or download Core ML models in order to use Mochi Diffusion.

A few models have been converted and uploaded [here](https://huggingface.co/coreml).

1. [Convert](https://github.com/apple/ml-stable-diffusion#-converting-models-to-core-ml) or download Core ML models
    - `split_einsum` version is compatible with all compute unit options including Neural Engine
    - `original` version is only compatible with `CPU & GPU` option
2. By default, the app's working directory will be created under the Documents folder. This location can be customized under Settings
3. In the working folder, create a new folder with the name you'd like displayed in the app then move or extract the converted models here
4. Your directory should look like this:
```
Documents/
└── MochiDiffusion/
    └── models/
        ├── stable-diffusion-2-1_split-einsum_compiled/
        │   ├── merges.txt
        │   ├── TextEncoder.mlmodelc
        │   ├── Unet.mlmodelc
        │   ├── VAEDecoder.mlmodelc
        │   └── vocab.json
        ├── ...
        └── ...
```

## Compatibility

- Apple Silicon (M1 and later) or Intel Mac (high performance CPU & GPU required)
- macOS Ventura 13.1 and later
- Xcode 14.2 (to build)

## Privacy

All generation happens locally and absolutely nothing is sent to the cloud.

## Contributing

Mochi Diffusion is always looking for contributions, whether it's through bug reports, code, or new translations.

- If you have a question, try [searching for your question first](https://github.com/godly-devotion/MochiDiffusion/discussions) as someone might have asked the same question already. If you do not find your question listed, feel free to [create a new question](https://github.com/godly-devotion/MochiDiffusion/discussions/new?category=q-a). Don't create a new issue for your question as those are for bugs and feature requests only.

- If you find a bug, or would like to suggest a new feature or enhancement, try [searching for your problem first](https://github.com/godly-devotion/MochiDiffusion/issues) as it helps avoid duplicates. If you can't find your issue, feel free to [create a new issue](https://github.com/godly-devotion/MochiDiffusion/issues/new/choose).

- If you're looking to contribute code, feel free to [open a Pull Request](https://github.com/godly-devotion/MochiDiffusion/pulls) or [create a new discussion](https://github.com/godly-devotion/MochiDiffusion/discussions) to talk about it first.

- If you'd like to translate Mochi Diffusion to your language, please visit the [project page on Crowdin](https://crowdin.com/project/mochi-diffusion). You can create an account for free and start translating and/or approving.

## Credits

- [Apple's Core ML Stable Diffusion implementation](https://github.com/apple/ml-stable-diffusion)
- [HuggingFace's Swift UI sample implementation](https://github.com/huggingface/swift-coreml-diffusers)
- App Icon by [Zabriskije](https://github.com/Zabriskije)
