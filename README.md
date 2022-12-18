#  Mochi Diffusion

![Screenshot](.github/images/screenshot.png)

Run Stable Diffusion on Apple Silicon Macs natively

## Description

This app uses [Apple's Core ML Stable Diffusion implementation](https://github.com/apple/ml-stable-diffusion) to achieve maximum performance and speed on Apple Silicon based Macs while reducing memory requirements.

For faster inference, we use a very fast scheduler: [DPM-Solver++](https://github.com/LuChengTHU/dpm-solver) that we ported to Swift. Since this scheduler is still not available in Apple's GitHub repository, the application depends on the following fork instead: https://github.com/pcuenca/ml-stable-diffusion. Our Swift port is based on [Diffusers' DPMSolverMultistepScheduler](https://github.com/huggingface/diffusers/blob/main/src/diffusers/schedulers/scheduling_dpmsolver_multistep.py), with a number of simplifications.

## Releases

Download the latest version from the [releases](https://github.com/godly-devotion/mochi-diffusion/releases) page.

## Running

When trying to open the app for the first time, Gatekeeper will prevent you from doing so because the app is not code signed. In order to bypass this warning, you need to right-click on the app and select "Open". You will have to do this twice in order to get the option to open the app.

## Models

You will need to convert or download Core ML models in order to use Mochi Diffusion.

1. Convert or download Core ML models (do one of the following)
   - Follow the steps [here](https://github.com/apple/ml-stable-diffusion#-converting-models-to-core-ml) to convert existing models to Core ML
   - Download the preconverted Stable Diffusion Core ML model from [here](https://huggingface.co/pcuenq/coreml-stable-diffusion/tree/main)
2. Open Mochi Diffusion and in the sidebar click the button with the Folder icon next to the Models list to open the models folder
3. Create a new folder with the name of the model you want displayed in Mochi Diffusion
4. Move all Core ML model & related files to the newly created folder
5. Repeat steps 3 & 4 for each model

## Compatibility

- Apple Silicon (M1 and later), macOS Ventura 13.1 and later, Xcode 14.2 (to build)
- Performance (after initial generation, which is slower)
  * ~10s in macOS on MacBook Pro M1 Max (64 GB).
  * ~20s in macOS on MacBook Pro M1 Pro (32 GB).
  * ~3.5 GB memory usage

## Limitations

- A single model (Stable Diffusion v1.5) is considered. The Core ML compute units have been hardcoded to CPU and GPU, since that's what gives best results on my Mac (M1 Max MacBook Pro).

## Credits

- [Apple's Core ML Stable Diffusion implementation](https://github.com/apple/ml-stable-diffusion)
- [HuggingFace's Swift UI sample implementation](https://github.com/huggingface/swift-coreml-diffusers)
