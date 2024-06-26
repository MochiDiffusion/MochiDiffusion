<p align="center">
<img height="256" src="https://github.com/MochiDiffusion/MochiDiffusion/raw/main/Mochi Diffusion/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png" />
</p>

<h1 align="center">Mochi Diffusion</h1>

<p align="center">Run Stable Diffusion on Mac natively</p>

<p align="center">
<a href="https://github.com/MochiDiffusion/MochiDiffusion/blob/main/README.md">English</a>,
<a href="https://github.com/MochiDiffusion/MochiDiffusion/blob/main/README.ko.md">한국어</a>,
<a href="https://github.com/MochiDiffusion/MochiDiffusion/blob/main/README.zh-Hans.md">中文</a>
</p>

<p align="center">
<a title="Discord" target="_blank" href="https://discord.gg/x2kartzxGv"><img src="https://img.shields.io/discord/1068185566782423092?color=blueviolet&label=discord"></a>
<a title="Crowdin" target="_blank" href="https://crowdin.com/project/mochi-diffusion"><img src="https://badges.crowdin.net/mochi-diffusion/localized.svg"></a>
<a title="License" target="_blank" href="https://github.com/MochiDiffusion/MochiDiffusion/blob/main/LICENSE"><img src="https://img.shields.io/github/license/MochiDiffusion/MochiDiffusion?color=blue"></a>
</p>

![Screenshot](.github/images/screenshot.png)

## Features

- [Apple's Core ML Stable Diffusion implementation](https://github.com/apple/ml-stable-diffusion) to achieve maximum performance and speed on Apple Silicon based Macs while reducing memory requirements
- Extremely fast and memory efficient (~150MB with Neural Engine)
- Runs well on all Apple Silicon Macs by fully utilizing Neural Engine
- Generate images locally and completely offline
- Generate images based on an existing image (commonly known as Image2Image)
- Generate images using ControlNet
- Generated images are saved with prompt info inside EXIF metadata (view in Finder's Get Info window)
- Convert generated images to high resolution (using RealESRGAN)
- Autosave & restore images
- Use custom Stable Diffusion Core ML models
- No worries about pickled models
- macOS native app using SwiftUI

## Downloads

[Latest version](https://github.com/MochiDiffusion/MochiDiffusion/releases)

[Community models](https://huggingface.co/coreml-community#models)

[ControlNet models](https://huggingface.co/coreml-community/ControlNet-Models-For-Core-ML/tree/main/CN)

[Stable Diffusion 1.5 with ControlNet](https://huggingface.co/coreml-community/coreml-stable-diffusion-v1-5_cn/tree/main/split_einsum)

When using a model for the very first time, it may take up to 2 minutes for the Neural Engine to compile a cached version. Afterwards, subsequent generations will be much faster.

## Compute Unit

- `CPU & Neural Engine` provides a good balance between speed and low memory usage
- `CPU & GPU` may be faster on M1 Max, Ultra and later but will use more memory

Depending on the option chosen, you will need to use the correct model version (see Models section for details).

## Models

You will need to convert or download Core ML models in order to use Mochi Diffusion.

1. [Convert](https://github.com/MochiDiffusion/MochiDiffusion/wiki/How-to-convert-Stable-Diffusion-models-to-Core-ML) or download Core ML models
    - `split_einsum` version is compatible with all compute unit options including Neural Engine
    - `original` version is only compatible with `CPU & GPU` option
2. By default, the app's model folder will be created under your home directory. This location can be customized under Settings
3. In the model folder, create a new folder with the name you'd like displayed in the app then move or extract the converted models here
4. Your directory structure should look like this:
```
<Home Directory>/
└── MochiDiffusion/
    └── models/
        ├── stable-diffusion-2-1_split-einsum_compiled/
        │   ├── merges.txt
        │   ├── TextEncoder.mlmodelc
        │   ├── Unet.mlmodelc
        │   ├── VAEDecoder.mlmodelc
        │   ├── VAEEncoder.mlmodelc
        │   └── vocab.json
        ├── ...
        └── ...
```

## Compatibility

- Apple Silicon (M1 and later)
- macOS Sonoma 14.0 and later
- Xcode 15.2 (to build)

## Privacy

All generation happens locally and absolutely nothing is sent to the cloud.

## Contributing

Mochi Diffusion is always looking for contributions, whether it's through bug reports, code, or new translations.

- If you find a bug, or would like to suggest a new feature or enhancement, try [searching for your problem first](https://github.com/MochiDiffusion/MochiDiffusion/issues) as it helps avoid duplicates. If you can't find your issue, feel free to [create a new issue](https://github.com/MochiDiffusion/MochiDiffusion/issues/new/choose). Don't create an issue for your question as those are for bugs and feature requests only.

- If you're looking to contribute code, feel free to [open a Pull Request](https://github.com/MochiDiffusion/MochiDiffusion/pulls). I recommend installing [swift-format](https://github.com/apple/swift-format#getting-swift-format) to catch lint issues.

- If you'd like to translate Mochi Diffusion to your language, please visit the [project page on Crowdin](https://crowdin.com/project/mochi-diffusion). You can create an account for free and start translating and/or approving.

## Credits

- [Apple's Core ML Stable Diffusion implementation](https://github.com/apple/ml-stable-diffusion)
- [Hugging Face's Swift UI sample implementation](https://github.com/huggingface/swift-coreml-diffusers)
- App Icon by [Zabriskije](https://github.com/Zabriskije)
