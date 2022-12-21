#  Mochi Diffusion

Run Stable Diffusion on Apple Silicon Macs natively

![Screenshot](.github/images/screenshot.png)

## Description

This app uses [Apple's Core ML Stable Diffusion implementation](https://github.com/apple/ml-stable-diffusion) to achieve maximum performance and speed on Apple Silicon based Macs while reducing memory requirements.

## Features

- Generates images locally and completely offline
- Fully utilize Apple Silicon Neural Engine
- Extremely memory efficient compared to PyTorch (~4GB)
- Generated images are saved with prompt info inside EXIF metadata
- Can use custom Stable Diffusion Core ML models
- No worries about pickled models
- macOS native app using SwiftUI

## Releases

Download the latest version from the [releases](https://github.com/godly-devotion/mochi-diffusion/releases) page.

## Running

When trying to open the app for the first time, Gatekeeper will prevent you from doing so because the app is not code signed. In order to bypass this warning, you need to right-click on the app and select "Open". You will have to do this twice in order to get the option to open the app.

For the compute unit option, `CPU & Neural Engine` is recommended for M1 and later or for saving battery. `CPU & GPU` is recommended for M1 Pro, Max, Ultra and later. Depending on the option chosen, you will need to provide the correct models (see Models section for details).

## Models

You will need to convert or download Core ML models in order to use Mochi Diffusion.

A few models have been converted and uploaded [here](https://huggingface.co/godly-devotion/apple-coreml-models/tree/main).

Download the `original` version if using `CPU & GPU` compute option. Otherwise download the `split_einsum` version.

1. [Convert](https://github.com/apple/ml-stable-diffusion#-converting-models-to-core-ml) or download Core ML models
2. By default, the app's working directory will be created under the Documents folder. This location can be customized under Settings
3. In the working folder, create a new folder with the name you'd like displayed in the app then move or extract the converted models here.
4. Your directory should look like this: `~/Documents/MochiDiffusion/models/[Model Folder Name]/[Model's Files]`

## Compatibility

- Apple Silicon (M1 and later)
- macOS Ventura 13.1 and later
- Xcode 14.2 (to build)

## Privacy

All generation happens locally and absolutely nothing is sent to the cloud.

## Credits

- [Apple's Core ML Stable Diffusion implementation](https://github.com/apple/ml-stable-diffusion)
- [HuggingFace's Swift UI sample implementation](https://github.com/huggingface/swift-coreml-diffusers)
