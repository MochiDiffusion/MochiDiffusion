# [v5.0](https://github.com/MochiDiffusion/MochiDiffusion/releases/tag/v5.0) - 25 Jan 2024

- Added ability to resize Inspector width
- Removed unnecessary Apply button from Settings window
- Fixed animation glitch when images are added or removed from the gallery
- Fixed gallery occasionally incorrectly sorting by Oldest First
- Fixed missing localization for initial model loading message
- Updated generation preview UI and show by default
- Updated system requirements to macOS 14
  - macOS 14 and later is required to use split-einsum v2 & SDXL models
- General performance improvements

# [v4.7.1](https://github.com/MochiDiffusion/MochiDiffusion/releases/tag/v4.7.1) - 02 Jan 2024

- Fixed using slider for countries that use decimal commas ([@haiodo](https://github.com/haiodo))


# [v4.7](https://github.com/MochiDiffusion/MochiDiffusion/releases/tag/v4.7) - 24 Dec 2023

- Added option to send notifications when images are ready ([@mangoes-dev](https://github.com/mangoes-dev))
- Added ability to change slider control values by keyboard input ([@gdbing](https://github.com/gdbing))
- Changed Quick Look shortcut to spacebar (like Finder)
- Changed scheduler timestep to Karras for SDXL models
- Changed minimum step option to 1 ([@amikot](https://github.com/amikot))
- Updated translations


# [v4.6](https://github.com/MochiDiffusion/MochiDiffusion/releases/tag/v4.6) - 06 Dec 2023

- Added auto refresh of Image, Model, & ControlNet list ([@gdbing](https://github.com/gdbing))
- Added ability to queue images ([@gdbing](https://github.com/gdbing))
- Added ability to drag and drop gallery images out ([@gdbing](https://github.com/gdbing))
- Added ability to set the Starting Image by dragging and dropping an image ([@gdbing](https://github.com/gdbing))
- Added automatic resizing of input images based on output image size ([@gdbing](https://github.com/gdbing))
- Added Hungarian translation (Janos Hunyadi)
- Changed ControlNet list to only show those compatible with the currently selected model ([@gdbing](https://github.com/gdbing))


# [v4.5](https://github.com/MochiDiffusion/MochiDiffusion/releases/tag/v4.5) - 08 Nov 2023

- Added time remaining info for currently generating image ([@hoseins77](https://github.com/hoseins77))
- Changed starting image strength slider range ([@gdbing](https://github.com/gdbing))
- Changed magnifier button in Settings to show folder selection dialog ([@vzsg](https://github.com/vzsg))
- Updated translations


# [v4.4](https://github.com/MochiDiffusion/MochiDiffusion/releases/tag/v4.4) - 09 Oct 2023

- Fixed problem selecting models with chunked Unets ([@vzsg](https://github.com/vzsg))
- Fixed conflicting keyboard shortcuts between text inputs and gallery ([@hoseins77](https://github.com/hoseins77))
- Changed gallery selection keyboard shortcuts to no longer require command key


# [v4.3.1](https://github.com/MochiDiffusion/MochiDiffusion/releases/tag/v4.3.1) - 05 Oct 2023

![roundels](https://github.com/MochiDiffusion/MochiDiffusion/assets/1341760/d71e28e9-2b3f-4c79-8845-9f370f457340)

- Fixed the image gallery background's round things on macOS Sonoma ([@vzsg](https://github.com/vzsg))


# [v4.3](https://github.com/MochiDiffusion/MochiDiffusion/releases/tag/v4.3) - 28 Sep 2023

- Added support for Stable Diffusion XL refiner ([@ZachNagengast](https://github.com/ZachNagengast))
   - Model must have `UnetRefiner.mlmodelc` file
- Added Vietnamese translation (Toàn Hoàng Đức)
- Fixed noisy generated image ([@ZachNagengast](https://github.com/ZachNagengast))
- Fixed Xcode build on macOS 14 ([@ZachNagengast](https://github.com/ZachNagengast))


# [v4.2](https://github.com/MochiDiffusion/MochiDiffusion/releases/tag/v4.2) - 07 Aug 2023

- Fixed setting ControlNet image
- Fixed restoring last gallery sort option
- Added support for Stable Diffusion XL models (requires macOS 14 beta) ([@ZachNagengast](https://github.com/ZachNagengast))
- Added setting to show image preview during generation ([@hoseins77](https://github.com/hoseins77))
- Sorted ControlNet list ([@jrittvo](https://github.com/jrittvo))
- Updated link to HuggingFace Core ML Community


# [v4.1.3](https://github.com/MochiDiffusion/MochiDiffusion/releases/tag/v4.1.3) - 22 Jul 2023

- Fixed ControlNet
- Fixed missing Dutch, Polish, & Ukrainian translations

**Note**: To use inpainting, select an inpainting ControlNet model and provide a mask image with transparent pixels.


# [v4.1.2](https://github.com/MochiDiffusion/MochiDiffusion/releases/tag/v4.1.2) - 20 Jul 2023

- Fixed app crash when changing settings
- Added Norwegian Bokmal translation (Espen Bye)

**Note**: To use inpainting, select an inpainting ControlNet model and provide a mask image with transparent pixels.


# [v4.1.1](https://github.com/MochiDiffusion/MochiDiffusion/releases/tag/v4.1.1) - 20 Jul 2023

- Fixed app crash when changing settings
- Added Norwegian Bokmal translation (Espen Bye)

**Note**: To use inpainting, select an inpainting ControlNet model and provide a mask image with transparent pixels.


# [v4.1](https://github.com/MochiDiffusion/MochiDiffusion/releases/tag/v4.1) - 17 Jul 2023

- Added support for inpainting with ControlNet ([@vzsg](https://github.com/vzsg))
- Added option to sort images by date ([@hoseins77](https://github.com/hoseins77))
- Added symlink support for model directory ([@surjikal](https://github.com/surjikal))
- Changed starting image strength value range ([@jrittvo](https://github.com/jrittvo))
- Fixed potential crash when clearing ControlNet image ([@vzsg](https://github.com/vzsg))

**Note**: To use inpainting, select an inpainting ControlNet model and provide a mask image with transparent pixels.


# [v4.0](https://github.com/MochiDiffusion/MochiDiffusion/releases/tag/v4.0) - 05 Jun 2023

- Added ControlNet ([@stuartjmoore](https://github.com/stuartjmoore))
- Changed starting image strength value range ([@jrittvo](https://github.com/jrittvo))
- Removed support for Intel Macs

**Note:** Previous Stable Diffusion models will need to be reconverted to support ControlNet. Several Core ML ControlNet models have been converted [here](https://huggingface.co/jrrjrr/CoreML-Models-For-ControlNet/tree/main/CN) by [@jrittvo](https://github.com/jrittvo). See [the wiki](https://github.com/MochiDiffusion/MochiDiffusion/wiki/How-to-convert-ControlNet-models-to-Core-ML) to find out how to convert the models.


# [v3.2](https://github.com/MochiDiffusion/MochiDiffusion/releases/tag/v3.2) - 30 Apr 2023

- Added animation when converting image to high resolution ([@jinhongw](https://github.com/jinhongw))
- Changed starting image implementation to follow model image size ([@vzsg](https://github.com/vzsg))
- Changed description too long message to use accent color
- Improved scheduler speed
- Updated translations

Special thanks to the following for supporting this project❣️
**orange-wedge**, **RuralRob**, **vacekj**, **julien-c**, **BirdSesame**, **li775176364**, **Da-mi-en**, **monks1975**, & various translators


# [v3.1](https://github.com/MochiDiffusion/MochiDiffusion/releases/tag/v3.1) - 03 Apr 2023

- Added option to auto select ML Compute Unit ([@vzsg](https://github.com/vzsg))
- Added support for restoring `jpeg` files ([@vzsg](https://github.com/vzsg))
- Changed default model & image folder directory to user's home directory
- Changed import behavior to copy images
- Updated translations

Special thanks to the following for supporting me and making this app possible❣️
**orange-wedge**, **RuralRob**, **vacekj**, **julien-c**, **BirdSesame**, **Da-mi-en**, **monks1975**, & anonymous donors


# [Bubble Tea Mochi (v3.0)](https://github.com/MochiDiffusion/MochiDiffusion/releases/tag/v3.0) - 03 Mar 2023

![image](https://user-images.githubusercontent.com/1341760/222038545-4b50efe9-423b-479b-afc4-6b4148694c21.png)
- Added option to select a starting image (commonly known as Image2Image)
   - Model must have `VAEEncoder.mlmodelc` file
   - Starting image and model must be 512x512 in size
- Added Dutch translation (Richard Venneman)
- Added setting to change default save image type
- Added support for importing and saving HEIC images
   - HEIC images are so small and efficient that it only uses about 5% of the file size of upscaled PNG images 🤯
- Added link to project translation website (Help > Contribute Translation)
- Updated sidebar UI
- Removed focus from text fields if image is clicked to avoid accidentally changing text
- General performance improvements

Has Mochi Diffusion been useful? Support this project on [GitHub](https://github.com/sponsors/godly-devotion) or [Liberapay](https://liberapay.com/joshuapark/)❣️

Special thanks to the following for supporting me and making this app possible 🎉
**raisingfightingspirit**, **serovar**, **orange-wedge**, **RuralRob**, **vacekj**, **julien-c**, **BirdSesame**, **Da-mi-en**, **monks1975**, & anonymous donors

# 🧋


# [Never Gonna Let You Down (v2.5)](https://github.com/MochiDiffusion/MochiDiffusion/releases/tag/v2.5) - 25 Feb 2023

Don't you just hate it when you close the app and realize you forgot to save your images?

Soon this will only be something pepperidge farm remembers.

This release is entitled **Never Gonna Let You Down**, as you're never gonna lose your images again 😎

![rick-roll-rick-rolled](https://user-images.githubusercontent.com/1341760/221377812-b7cee01d-057a-4ba0-8d31-c72dfbf131e9.gif)

- Added option to autosave & restore images
- Added option to hide or show the Info panel
- Changed app behavior to quit when window is closed
- Images that are removed are now moved to Trash
- Fixed Copy image menu option
- Fixed Copy Options to Sidebar menu option
- Fixed incorrect image date on import
- Fixed removing an unselected image causing the selection to unexpectedly change ([@vzsg](https://github.com/vzsg))

Has Mochi Diffusion been useful? Support this project on [GitHub](https://github.com/sponsors/godly-devotion) or [Liberapay](https://liberapay.com/joshuapark/).

Special thanks to the following for supporting me and making this app possible 🎉
**raisingfightingspirit**, **serovar**, **orange-wedge**, **RuralRob**, **vacekj**, **julien-c**, **Quick-Eyed-Sky**, **BirdSesame**, **Da-mi-en**, **monks1975**, & anonymous donors


# [v2.4.1](https://github.com/MochiDiffusion/MochiDiffusion/releases/tag/v2.4.1) - 23 Feb 2023

- Added Ukrainian translation (Pavlo Pavlov)
- Added Copy to clipboard option to image context menu ([@vzsg](https://github.com/vzsg))
- Changed Number of Images option to slider
- Changed image selection to move to beginning if end is reached and vice versa ([@vzsg](https://github.com/vzsg))
- Fixed & improved search ([@vzsg](https://github.com/vzsg))
- Fixed copying Include in Image option to sidebar in Info panel

Can you speak another language? Visit the [project page on Crowdin](https://crowdin.com/project/mochi-diffusion)!

Special thanks to the following for supporting me and making this app possible 🎉
**raisingfightingspirit**, **serovar**, **orange-wedge**, **RuralRob**, **vacekj**, **julien-c**, **Quick-Eyed-Sky**, **BirdSesame**, **Da-mi-en**, **monks1975**, **angeenes**, & anonymous donors


# [Mochi Ice Cream (v2.4)](https://github.com/MochiDiffusion/MochiDiffusion/releases/tag/v2.4) - 17 Feb 2023

Who remembers the release of Mac OS X **Snow** Leopard? 🙋

At WWDC 2009, **Snow** Leopard was advertised with having under the hood improvements rather than adding more features. It was famously marketed as having "zero new features"

![snow-leopard-0-new-features](https://user-images.githubusercontent.com/1341760/219689922-736dfd18-0e74-4e91-b7da-f6ccd2676641.jpg)

Just like **Snow** Leopard, this new release of Mochi Diffusion includes many under the hood improvements that improves performance and stability. It should also help simplify adding new features down the line

The successor of Leopard was called **Snow** Leopard to denote it as a refinement. Therefore I found it appropriate to call this release...

🥁🥁🥁

**Mochi Ice Cream**

Also both snow and ice cream are somewhat similar, who knew? ❄️🍦

It also proudly has "zero new features." Well, there is _one_ new feature...

![Screen Recording](https://user-images.githubusercontent.com/1341760/219784941-9a4188fa-530a-42bc-99fc-13d152125cc2.gif)

A nice animation has been added when removing images from the Gallery 😎

Also "zero new features" doesn't mean much didn't change. Actually there were a lot of changes...

![image](https://user-images.githubusercontent.com/1341760/219790132-0e620023-4b30-431b-81d0-8d6823a212d4.png)

Those numbers represent the lines of code changed...whew

As usual, special thanks to the following for supporting me and making this app possible 🎉
**raisingfightingspirit**, **serovar**, **orange-wedge**, **RuralRob**, **vacekj**, **julien-c**, **Quick-Eyed-Sky**, **BirdSesame**, **Da-mi-en**, **monks1975**, **angeenes**, & anonymous donors


# [v2.3](https://github.com/MochiDiffusion/MochiDiffusion/releases/tag/v2.3) - 07 Feb 2023

- Fixed Quick Look not displaying the correct image if the first image was selected and removed ([@CarterLombardi](https://github.com/CarterLombardi))
- Fixed Quick Look displaying the last removed image when all images were removed from the Gallery ([@CarterLombardi](https://github.com/CarterLombardi))
- Fixed import process for images with empty Exclude from Image description ([@vzsg](https://github.com/vzsg))
- Fixed short descriptions in Info panel causing text to be centered rather than left aligned ([@vzsg](https://github.com/vzsg))
- Added token counter to Include in Image & Exclude from Image text inputs ([@CarterLombardi](https://github.com/CarterLombardi))
- Increased text input size of Include in Image & Exclude from Image to show more lines of text
- Organized Settings window using tabs

Special thanks to the following for supporting me and making this app possible 🎉
**raisingfightingspirit**, **serovar**, **orange-wedge**, **RuralRob**, **vacekj**, **julien-c**, **Quick-Eyed-Sky**, **BirdSesame**, **Da-mi-en**, **monks1975**, **angeenes**, & anonymous donors


# [v2.2](https://github.com/MochiDiffusion/MochiDiffusion/releases/tag/v2.2) - 02 Feb 2023

- Added ability to import images to Gallery (File > Import Image...)
   - Image must be generated by Mochi Diffusion 2.2 or later
- Fixed potential crash if image is removed while being converted to high resolution ([@vzsg](https://github.com/vzsg))
- Improved model selector by sorting by name ([@vzsg](https://github.com/vzsg))
- Improved translation of singular & plural words

[Let's D. I. S. C. O. rd](https://discord.gg/x2kartzxGv)

Special thanks to the following for supporting me and making this app possible 🎉
**raisingfightingspirit**, **serovar**, **orange-wedge**, **RuralRob**, **vacekj**, **julien-c**, **Quick-Eyed-Sky**, **BirdSesame**, **Da-mi-en**, **monks1975**, **angeenes**, & anonymous donors


# [v2.1.5](https://github.com/MochiDiffusion/MochiDiffusion/releases/tag/v2.1.5) - 31 Jan 2023

- Added Russian translation (Regulus)
- Added message if prompt description is too long
- Changed max step setting back to 50
- Postponed changing minimum macOS version to Ventura 13.2

[Link to Discord, this is - Yoda](https://discord.gg/x2kartzxGv)

Special thanks to the following for supporting me and making this app possible 🎉
**raisingfightingspirit**, **serovar**, **orange-wedge**, **RuralRob**, **julien-c**, **Quick-Eyed-Sky**, **BirdSesame**, **Da-mi-en**, **monks1975**, **angeenes**, & anonymous donors


# [v2.1.4](https://github.com/MochiDiffusion/MochiDiffusion/releases/tag/v2.1.4) - 26 Jan 2023

- Added Spanish translation (k-latte)
- Changed max step setting to 40
- Next release will change minimum macOS version to Ventura 13.2

[There's a Discord server?](https://discord.gg/x2kartzxGv)

Special thanks to the following for supporting me and making this app possible 🎉
**raisingfightingspirit**, **serovar**, **orange-wedge**, **RuralRob**, **julien-c**, **Quick-Eyed-Sky**, **BirdSesame**, **Da-mi-en**, **monks1975**, **angeenes**, & anonymous donors


# [v2.1.3](https://github.com/MochiDiffusion/MochiDiffusion/releases/tag/v2.1.3) - 22 Jan 2023

- Fixed prompt file name when saving all images

Tip: File > Save All to save all generated images.

Special thanks to the following for supporting me and making this app possible 🎉
**raisingfightingspirit**, **serovar**, **orange-wedge**, **RuralRob**, **julien-c**, **Quick-Eyed-Sky**, **BirdSesame**, **Da-mi-en**, **angeenes**, & anonymous donors


# [v2.1.2](https://github.com/MochiDiffusion/MochiDiffusion/releases/tag/v2.1.2) - 21 Jan 2023

![screenshot](https://user-images.githubusercontent.com/1341760/213897612-d62a26a0-e38e-4c29-9f1b-27bbbd46a410.png)
- Added ability to search image by seed
- Changed step & guidance scale control style
- Changed saved image metadata to be similar to webui images
- Changed default step setting to 12 (sweet spot)
- Changed max step setting to 50
- Converting image to high resolution replaces existing image
- Cleanup temp images that were created by Quick Look on app close
   - Previous temp images were already being deleted on reboot
- Fixed app briefly freezing when converting image to high resolution

Do you have a model that was converted and wish to upload? Join our community on [Hugging Face](https://huggingface.co/coreml) or create a Pull Request to get started!

Tip: File > Save All to save all generated images.

Special thanks to the following for supporting me and making this app possible 🎉
**raisingfightingspirit**, **serovar**, **orange-wedge**, **julien-c**, **Quick-Eyed-Sky**, **BirdSesame**, **Da-mi-en**, **eidermar**, & anonymous donors


# [v2.1.1](https://github.com/MochiDiffusion/MochiDiffusion/releases/tag/v2.1.1) - 19 Jan 2023

We've reached 10 languages!

- Added Traditional Chinese translation (JacobLinCool)
- Added ability to select Compute Unit option when changing model
- Added option to Filter Inappropriate Images under Settings (model must have safety checker module to work)
- Fixed duplicated model options on refresh

Do you have a model that was converted and wish to upload? Join our community on [Hugging Face](https://huggingface.co/coreml) or create a Pull Request to get started!

Special thanks to the following for supporting me and making this app possible 🎉
**raisingfightingspirit**, **serovar**, **orange-wedge**, **julien-c**, **Quick-Eyed-Sky**, **BirdSesame**, **Da-mi-en**, **eidermar**, & anonymous donors


# [v2.1](https://github.com/MochiDiffusion/MochiDiffusion/releases/tag/v2.1) - 18 Jan 2023

- Changed model folder to be any path and to no longer enforce sub folder structure
- Added Swedish Translation (teodorzacke)
- Added keyboard shortcuts to the Gallery (see under Image menu)
- Added option to save all images (File > Save All...)
- Added color shadow to Inspector image
- Improved auto sizing Settings window
- Improved Quick Look code ([@azyu](https://github.com/azyu))

You will need to set the model folder again after updating.

Do you have a model that was converted and wish to upload? Join our community on [Hugging Face](https://huggingface.co/coreml) or create a Pull Request to get started!

Special thanks to the following for supporting me and making this app possible 🎉
**[@raisingfightingspirit](https://github.com/raisingfightingspirit)**, **serovar**, **orange-wedge**, **julien-c**, **Quick-Eyed-Sky**, **BirdSesame**, **Da-mi-en**, **eidermar**, **Draxredd**, & anonymous donors


# [v2.0.3](https://github.com/MochiDiffusion/MochiDiffusion/releases/tag/v2.0.3) - 14 Jan 2023

- Changed Batches option to Number of Images for simplicity
- Updated Settings layout for different languages
- Updated Generate button to Stop Generation as well
- Updated Download Model menu link
- Added button to set random seed

Do you have a model that was converted and wish to upload? Join our community on [Hugging Face](https://huggingface.co/coreml) or create a Pull Request to get started!

Special thanks to the following for supporting me and making this app possible 🎉
**serovar**, **orange-wedge**, **julien-c**, **Quick-Eyed-Sky**, **BirdSesame**, **Da-mi-en**, **eidermar**, **Draxredd**, & anonymous donors


# [v2.0.2](https://github.com/MochiDiffusion/MochiDiffusion/releases/tag/v2.0.2) - 13 Jan 2023

- New Translations
   - Brazilian Portuguese (thiagomsoares)
   - French (Draxredd)
   - Italian (Zabriskije)
- Fixed converting non-square images to high resolution
- Clicking Apply button in Settings closes the window

Can you speak another language? Visit the [project page on Crowdin](https://crowdin.com/project/mochi-diffusion)!

Special thanks to the following for supporting me and making this app possible 🎉
**serovar**, **orange-wedge**, **julien-c**, **Quick-Eyed-Sky**, **BirdSesame**, **Da-mi-en**, **eidermar**, **Draxredd**, & anonymous donors


# [v2.0.1](https://github.com/MochiDiffusion/MochiDiffusion/releases/tag/v2.0.1) - 08 Jan 2023

**I've figured out how to convert the models to export 512x768 sized images. I will add these new models to the existing list of models I've converted [here](https://huggingface.co/godly-devotion) under the folder `original`. Note that it only supports running with `CPU & GPU` compute unit. See [the wiki](https://github.com/MochiDiffusion/MochiDiffusion/wiki/How-to-convert-ckpt-files-to-Core-ML) for details on the updated steps to create these new models.**

- New Translations
   - Simplified Chinese ([@Jerry23011](https://github.com/Jerry23011))
   - Finnish (tuhoojabotti)
   - German ([@eidermar](https://github.com/eidermar))
   - Japanese ([@atatakun](https://github.com/atatakun))
   - Korean ([@godly-devotion](https://github.com/godly-devotion))
- Added Simplified Chinese & Korean translations for README
- Added app version info to EXIF data
- Fixed generation progress not displaying for some users
- Changed search to be case insensitive
- Changed minimum Gallery columns from 3 to 1
- Include up to 70 characters of prompt text in default image filename

Can you speak another language? Visit the [project page on Crowdin](https://crowdin.com/project/mochi-diffusion)!

Special thanks to the following for supporting me and making this app possible 🎉
**serovar**, **orange-wedge**, **julien-c**, **Quick-Eyed-Sky**, **BirdSesame**, **Da-mi-en**, **eidermar**, **Draxredd**, **kayzen**


# [v2.0](https://github.com/MochiDiffusion/MochiDiffusion/releases/tag/v2.0) - 05 Jan 2023

![image](https://user-images.githubusercontent.com/1341760/210843838-7dc90c3b-f7fc-4fb1-b30b-5386fb2b5bda.png)

- Added support for Intel Macs (universal binary)
   - `CPU & GPU` compute unit will be used
   - High performance CPU & GPU is required
- Updated Gallery UI
   - Images are displayed in a grid
   - Added ability to view images in Quick Look (double click on image)
   - Added ability to search generated images by prompt
   - Added total generated image count
- Update Inspector UI
   - Moved to sidebar to allow easier at a glance view
- Updated names of buttons & labels
- Added menu option to download pre-converted models (Help > Download Models)
- Added menu option to support this project (Help > Support Me)
- Added support for localization

Special thanks to the following for supporting me and making this app possible 🎉
**serovar**, **orange-wedge**, **julien-c**, **Quick-Eyed-Sky**, **BirdSesame**, **Da-mi-en**, **eidermar**, **Draxredd**, **kayzen**


# [v1.4.2](https://github.com/MochiDiffusion/MochiDiffusion/releases/tag/v1.4.2) - 03 Jan 2023

**Mochi Diffusion is now properly code signed and notarized thanks to your donations. Thank You ❤️**

- Image generation progress was moved to the toolbar
   - View both step and batch progress
   - Cancel generation
- Updates can now be downloaded and installed directly from the app

Tip: DPM-Solver++ Scheduler works very well with only 10-25 steps

Special thanks to the following for supporting me and making this app possible 🎉
**serovar**, **orange-wedge**, **julien-c**, **Quick-Eyed-Sky**, **BirdSesame**, **Da-mi-en**, **eidermar**, **Draxredd**

---

I've converted a few models for Mochi Diffusion [here](https://huggingface.co/godly-devotion).

Read the explanation for [Compute Unit](https://github.com/MochiDiffusion/MochiDiffusion#compute-unit) and [Models](https://github.com/MochiDiffusion/MochiDiffusion#models) to understand the difference between `split_einsum` and `original` (_tl;dr_ download the `split_einsum` version to use Neural Engine).


# [v1.4.1](https://github.com/MochiDiffusion/MochiDiffusion/releases/tag/v1.4.1) - 31 Dec 2022

![](https://raw.githubusercontent.com/MochiDiffusion/MochiDiffusion/4640c01ab06efad9bab0a4c9793a6069eaa11d39/.github/images/screenshot.png)

**Mochi Diffusion is now properly code signed and notarized thanks to your donations. Thank You ❤️**

- Added option to convert _all_ generated images to high resolution (will use more memory)
- Changed progress status to show batch progress instead
- Changed filename to include image index at the end (helps avoid name conflicts with images in the same batch when saving)

Tip: DPM-Solver++ Scheduler works very well with only 10-25 steps

Special thanks to the following for supporting me 🎉
**serovar**, **orange-wedge**, **julien-c**, **Quick-Eyed-Sky**, **BirdSesame**, **Da-mi-en**

---

I've converted a few models for Mochi Diffusion [here](https://huggingface.co/godly-devotion).

Read the explanation for [Compute Unit](https://github.com/MochiDiffusion/MochiDiffusion#compute-unit) and [Models](https://github.com/MochiDiffusion/MochiDiffusion#models) to understand the difference between `split_einsum` and `original` (_tl;dr_ download the `split_einsum` version to use Neural Engine).


# [v1.4](https://github.com/MochiDiffusion/MochiDiffusion/releases/tag/v1.4) - 30 Dec 2022

![](https://raw.githubusercontent.com/MochiDiffusion/MochiDiffusion/a59dd7dba91df20263e2ec9ebfb435b41f8299b4/.github/images/screenshot.png)

**When trying to open the app for the first time, Gatekeeper will prevent you from doing so because the app is not code signed. In order to bypass this warning, you need to right-click on the app and select "Open". You will have to do this twice in order to get the option to open the app.**

- Added built-in ability to convert generated images to high resolution (using RealESRGAN)
- Added Copy to Prompt option to Gallery image right click menu
- Added button to open working directory in Finder under Settings
- Improved Info popup
   - Each section is clearly separated with headers
   - Added button to selectively copy an option to the sidebar
- Changed maximum step count to 100 (there are diminishing returns over this)
- Changed scheduler option location to Settings

Tip: DPM-Solver++ Scheduler works very well with only 10-25 steps

Special thanks to serovar, julien-c, Da-mi-en for supporting me 🎉

---

I've converted a few models for Mochi Diffusion [here](https://huggingface.co/godly-devotion).

Read the explanation for [Compute Unit](https://github.com/MochiDiffusion/MochiDiffusion#compute-unit) and [Models](https://github.com/MochiDiffusion/MochiDiffusion#models) to understand the difference between `split_einsum` and `original` (_tl;dr_ download the `split_einsum` version to use Neural Engine).


# [v1.3](https://github.com/MochiDiffusion/MochiDiffusion/releases/tag/v1.3) - 30 Dec 2022

**When trying to open the app for the first time, Gatekeeper will prevent you from doing so because the app is not code signed. In order to bypass this warning, you need to right-click on the app and select "Open". You will have to do this twice in order to get the option to open the app.**

- Added ability to stop image generation
- Added border around the currently selected image in the Gallery
- Changed help text for Reduce Memory Usage option
- Fixed minor bugs

Tip: DPM-Solver++ Scheduler works very well with only 10-25 steps

Special thanks to [@serovar](https://github.com/serovar) [@julien-c](https://github.com/julien-c) [@Da-mi-en](https://github.com/Da-mi-en) for supporting me 🎉

---

I've converted a few models for Mochi Diffusion [here](https://huggingface.co/godly-devotion).

Read the explanation for [Compute Unit](https://github.com/MochiDiffusion/MochiDiffusion#compute-unit) and [Models](https://github.com/MochiDiffusion/MochiDiffusion#models) to understand the difference between `split_einsum` and `original` (_tl;dr_ download the `split_einsum` version to use Neural Engine).


# [v1.2](https://github.com/MochiDiffusion/MochiDiffusion/releases/tag/v1.2) - 26 Dec 2022

![](https://raw.githubusercontent.com/MochiDiffusion/MochiDiffusion/2e93b60683dde597a7b713e298af8bda7c6993f4/.github/images/screenshot.png)

**When trying to open the app for the first time, Gatekeeper will prevent you from doing so because the app is not code signed. In order to bypass this warning, you need to right-click on the app and select "Open". You will have to do this twice in order to get the option to open the app.**

- View the gallery while images are being generated
- Reorganized some options in the sidebar
- Added Number of Batches option
    - Each batch increments the seed by 1 making it easier to regenerate the same image
- Added Images per Batch option (previously called Number of Images)

Note: [Number of Batches] x [Images per Batch] = [Total Number of Images Generated]

---

I've converted a few models for Mochi Diffusion [here](https://huggingface.co/godly-devotion).

Read the explanation for [Compute Unit](https://github.com/MochiDiffusion/MochiDiffusion#compute-unit) and [Models](https://github.com/MochiDiffusion/MochiDiffusion#models) to understand the difference between `split_einsum` and `original` (_tl;dr_ download the `split_einsum` version to use Neural Engine).

I am also looking for help to subsidize for an Apple Developer Program membership which will allow me to properly sign and notarize my apps (I'll be able to finally take down the Gatekeeper banner message).


# [v1.1.3](https://github.com/MochiDiffusion/MochiDiffusion/releases/tag/v1.1.3) - 26 Dec 2022

**When trying to open the app for the first time, Gatekeeper will prevent you from doing so because the app is not code signed. In order to bypass this warning, you need to right-click on the app and select "Open". You will have to do this twice in order to get the option to open the app.**

I've converted a few models for Mochi Diffusion [here](https://huggingface.co/godly-devotion/apple-coreml-models/tree/main).
Read the [Compute Unit](https://github.com/MochiDiffusion/MochiDiffusion#compute-unit) and [Models](https://github.com/MochiDiffusion/MochiDiffusion#models) explanation about the difference between `split_einsum` and `original` model version (_tl;dr_ download the `split_einsum` version to use Neural Engine).

- Added remove image option to toolbar
- Changed toolbar item names to be consistent
- Changed compute unit description label to recommend Neural Engine option for most cases


# [v1.1.2](https://github.com/MochiDiffusion/MochiDiffusion/releases/tag/v1.1.2) - 26 Dec 2022

**When trying to open the app for the first time, Gatekeeper will prevent you from doing so because the app is not code signed. In order to bypass this warning, you need to right-click on the app and select "Open". You will have to do this twice in order to get the option to open the app.**

I've converted a few models for Mochi Diffusion [here](https://huggingface.co/godly-devotion/apple-coreml-models/tree/main).
Read the [Compute Unit](https://github.com/MochiDiffusion/MochiDiffusion#compute-unit) and [Models](https://github.com/MochiDiffusion/MochiDiffusion#models) explanation about the difference between `split_einsum` and `original` model version (_tl;dr_ download the `split_einsum` version to use Neural Engine).

- Minor improvements to Gallery UI
- Added save & remove options to gallery image right-click menu


# [v1.1](https://github.com/MochiDiffusion/MochiDiffusion/releases/tag/v1.1) - 25 Dec 2022

![](https://raw.githubusercontent.com/MochiDiffusion/MochiDiffusion/880cf47e79724dae8bff971e6e4f007bebba0277/.github/images/screenshot.png)

**When trying to open the app for the first time, Gatekeeper will prevent you from doing so because the app is not code signed. In order to bypass this warning, you need to right-click on the app and select "Open". You will have to do this twice in order to get the option to open the app.**

I've converted a few models for Mochi Diffusion [here](https://huggingface.co/godly-devotion/apple-coreml-models/tree/main). Download the `original` version if using `CPU & GPU` compute option. Otherwise download the `split_einsum` version.

- New App Icon (Thanks to [@Zabriskije](https://github.com/Zabriskije) 🎉)
- Fixed max seed value
- Fixed prompt input's size
- Fixed dark text color when selecting info in dark mode
- Changed default compute unit option to `CPU & Neural Engine`
- Changed minimum step value to 2


# [v1.0.6](https://github.com/MochiDiffusion/MochiDiffusion/releases/tag/v1.0.6) - 23 Dec 2022

**When trying to open the app for the first time, Gatekeeper will prevent you from doing so because the app is not code signed. In order to bypass this warning, you need to right-click on the app and select "Open". You will have to do this twice in order to get the option to open the app.**

I will convert and upload a few models for Mochi Diffusion [here](https://huggingface.co/godly-devotion/apple-coreml-models/tree/main). Download the `original` version if using `CPU & GPU` compute option. Otherwise download the `split_einsum` version.

Use compute unit option `CPU & Neural Engine` option for Macs with 8GB of memory.

- Fixed scrolling in sidebar
- Fixed default window size
- Added Reduce Memory Pressure option under Settings


# [v1.0.5](https://github.com/MochiDiffusion/MochiDiffusion/releases/tag/v1.0.5) - 22 Dec 2022

**When trying to open the app for the first time, Gatekeeper will prevent you from doing so because the app is not code signed. In order to bypass this warning, you need to right-click on the app and select "Open". You will have to do this twice in order to get the option to open the app.**

I will convert and upload a few models for Mochi Diffusion [here](https://huggingface.co/godly-devotion/apple-coreml-models/tree/main). Download the `original` version if using `CPU & GPU` compute option. Otherwise download the `split_einsum` version.

- Fixed reloading models
- Changed default image filename to have seed info at the end (helps sort images by prompt first in Finder)


# [v1.0.4](https://github.com/MochiDiffusion/MochiDiffusion/releases/tag/v1.0.4) - 21 Dec 2022

**When trying to open the app for the first time, Gatekeeper will prevent you from doing so because the app is not code signed. In order to bypass this warning, you need to right-click on the app and select "Open". You will have to do this twice in order to get the option to open the app.**

I will convert and upload a few models for Mochi Diffusion [here](https://huggingface.co/godly-devotion/apple-coreml-models/tree/main). Download the `original` version if using `CPU & GPU` compute option. Otherwise download the `split_einsum` version.

- Further clarified compute unit option message under Settings


# [v1.0.3](https://github.com/MochiDiffusion/MochiDiffusion/releases/tag/v1.0.3) - 21 Dec 2022

**When trying to open the app for the first time, Gatekeeper will prevent you from doing so because the app is not code signed. In order to bypass this warning, you need to right-click on the app and select "Open". You will have to do this twice in order to get the option to open the app.**

I will convert and upload a few models for Mochi Diffusion [here](https://huggingface.co/godly-devotion/apple-coreml-models/tree/main). Download the `original` version if using `CPU & GPU` compute option. Otherwise download the `split_einsum` version.

- Added menu item option to Generate image (Command-G)
- Adjusted warning message regarding compute unit options under Settings
- Adjusted spacing between prompt controls
- Adjusted accent color to use system-wide color


# [v1.0.2](https://github.com/MochiDiffusion/MochiDiffusion/releases/tag/v1.0.2) - 20 Dec 2022

![](https://raw.githubusercontent.com/MochiDiffusion/MochiDiffusion/77e96b1a325ced59a79cdfd981316e0b686093bf/.github/images/screenshot.png)

**When trying to open the app for the first time, Gatekeeper will prevent you from doing so because the app is not code signed. In order to bypass this warning, you need to right-click on the app and select "Open". You will have to do this twice in order to get the option to open the app.**

**NOTE: Compute unit options other than \"CPU & GPU\" may not work correctly**

I will convert and upload a few models for Mochi Diffusion [here](https://huggingface.co/godly-devotion/apple-coreml-models/tree/main).

- Fixed scrolling for gallery images
- Fixed scrolling long info text
- Removed Settings window tabs


# [v1.0.1](https://github.com/MochiDiffusion/MochiDiffusion/releases/tag/v1.0.1) - 20 Dec 2022

**When trying to open the app for the first time, Gatekeeper will prevent you from doing so because the app is not code signed. In order to bypass this warning, you need to right-click on the app and select "Open". You will have to do this twice in order to get the option to open the app.**

I will convert and upload a few models [here](https://huggingface.co/godly-devotion/apple-coreml-models/tree/main).

- Fixed incorrect aspect ratio on preview image (saved image was fine)


# [v1.0](https://github.com/MochiDiffusion/MochiDiffusion/releases/tag/v1.0) - 20 Dec 2022

![](https://raw.githubusercontent.com/MochiDiffusion/MochiDiffusion/2b62cb9471becca375a6d3fbd8fad5389e247a18/.github/images/screenshot.png)

**When trying to open the app for the first time, Gatekeeper will prevent you from doing so because the app is not code signed. In order to bypass this warning, you need to right-click on the app and select "Open". You will have to do this twice in order to get the option to open the app.**

- Added Settings window (Command-,)
  - Change Compute Unit (CPU & GPU option is recommended)
  - Change working directory (such as models)
- Allow image generation only if model is available
- Minor bug fixes and enhancements


# [v0.6.2](https://github.com/MochiDiffusion/MochiDiffusion/releases/tag/v0.6.2) - 20 Dec 2022

**When trying to open the app for the first time, Gatekeeper will prevent you from doing so because the app is not code signed. In order to bypass this warning, you need to right-click on the app and select "Open". You will have to do this twice in order to get the option to open the app.**

If upgrading from v0.3 or older, in Finder go to `~/Library/Containers/com.joshua-park.Mochi-Diffusion/Data/Library/Application Support/models/` and move the contents to `~/Documents/MochiDiffusion/models/`. This is the new model location folder.

- Fixed restoring previously selected model


# [v0.6.1](https://github.com/MochiDiffusion/MochiDiffusion/releases/tag/v0.6.1) - 19 Dec 2022

![](https://raw.githubusercontent.com/MochiDiffusion/MochiDiffusion/08252320fcd00fb01d268a1573ae0813f62868e5/.github/images/screenshot.png)

**When trying to open the app for the first time, Gatekeeper will prevent you from doing so because the app is not code signed. In order to bypass this warning, you need to right-click on the app and select "Open". You will have to do this twice in order to get the option to open the app.**

If upgrading from v0.3 or older, in Finder go to `~/Library/Containers/com.joshua-park.Mochi-Diffusion/Data/Library/Application Support/models/` and move the contents to `~/Documents/MochiDiffusion/models/`. This is the new model location folder.

- Changed image save & info button location to toolbar
- Added Save Image menu item (Command-S)
- Added image size info
- Added image caption to gallery
- Minor bug fixes and enhancements


# [v0.6](https://github.com/MochiDiffusion/MochiDiffusion/releases/tag/v0.6) - 19 Dec 2022

**When trying to open the app for the first time, Gatekeeper will prevent you from doing so because the app is not code signed. In order to bypass this warning, you need to right-click on the app and select "Open". You will have to do this twice in order to get the option to open the app.**

If upgrading from v0.3 or older, in Finder go to `~/Library/Containers/com.joshua-park.Mochi-Diffusion/Data/Library/Application Support/models/` and move the contents to `~/Documents/MochiDiffusion/models/`. This is the new model location folder.

- Added ability to view generated image's info including seed & prompt
- Added exif metadata when saving image
- Added seed & prompt info to filename when saving image
- Added ability to choose scheduler if desired
- Added auto saving and restoring of prompt, negative prompt, & selected scheduler


# [v0.5](https://github.com/MochiDiffusion/MochiDiffusion/releases/tag/v0.5) - 19 Dec 2022

**When trying to open the app for the first time, Gatekeeper will prevent you from doing so because the app is not code signed. In order to bypass this warning, you need to right-click on the app and select "Open". You will have to do this twice in order to get the option to open the app.**

If upgrading from v0.3 or older, in Finder go to `~/Library/Containers/com.joshua-park.Mochi-Diffusion/Data/Library/Application Support/models/` and move the contents to `~/Documents/MochiDiffusion/models/`. This is the new model location folder.

- Fixed cursor insertion pointer jumping to end when editing Prompt & Negative Prompt
- Fixed setting seed
- Added button to toggle sidebar visibility


# [v0.4](https://github.com/MochiDiffusion/MochiDiffusion/releases/tag/v0.4) - 18 Dec 2022

![](https://raw.githubusercontent.com/MochiDiffusion/MochiDiffusion/df9f0d3f09fdcb096f53fcb2933049d6a0d2f0de/.github/images/screenshot.png)

**When trying to open the app for the first time, Gatekeeper will prevent you from doing so because the app is not code signed. In order to bypass this warning, you need to right-click on the app and select "Open". You will have to do this twice in order to get the option to open the app.**

If upgrading from v0.3 or older, in Finder go to `~/Library/Containers/com.joshua-park.Mochi-Diffusion/Data/Library/Application Support/models/` and move the contents to `~/Documents/MochiDiffusion/models/`. This is the new model location folder.

- Fixed imprecise sliders for setting Steps & Scale
- Added ability to choose custom Core ML model
- Added ability to generate up to 8 images at once
- Models are not auto downloaded on fresh start (don't have to wait for model to download before start using app)

Known Bugs
- Editing the Prompt & Negative Prompt causes the cursor to jump to the end. I am investigating this bug. As a workaround, edit your prompt in TextEdit then copy and paste into the prompt input


# [v0.3](https://github.com/MochiDiffusion/MochiDiffusion/releases/tag/v0.3) - 18 Dec 2022

![](https://raw.githubusercontent.com/MochiDiffusion/MochiDiffusion/cf8271d315a9673d5c1b9e51a01530031efe1a4b/.github/images/screenshot.png)

**When trying to open the app for the first time, Gatekeeper will prevent you from doing so because the app is not code signed. In order to bypass this warning, you need to right-click on the app and select "Open". You will have to do this twice in order to get the option to open the app.**

- Added ability to check for updates automatically
- Added menu item to toggle sidebar visibility (View > Hide Sidebar)


# [v0.2](https://github.com/MochiDiffusion/MochiDiffusion/releases/tag/v0.2) - 17 Dec 2022

![](https://raw.githubusercontent.com/MochiDiffusion/MochiDiffusion/f526e2192b84bd553bf8c2334153b88a433c58ef/.github/images/screenshot.png)

**When trying to open the app for the first time, Gatekeeper will prevent you from doing so because the app is not code signed. In order to bypass this warning, you need to right-click on the app and select "Open". You will have to do this twice in order to get the option to open the app.**

- Moved controls to side bar
- Added ability to directly save image (in addition to native Share function)
- Increased prompt input size
- Remember previously set Step & Scale


# [v0.1](https://github.com/MochiDiffusion/MochiDiffusion/releases/tag/v0.1) - 16 Dec 2022

![](https://raw.githubusercontent.com/MochiDiffusion/MochiDiffusion/b75a53f8c38ca546aed3319f4c9bf045faf3314e/.github/images/screenshot.png)

**When trying to open the app for the first time, Gatekeeper will prevent you from doing so because the app is not code signed. In order to bypass this warning, you need to right-click on the app and select "Open". You will have to do this twice in order to get the option to open the app.**

There are many things lacking in this version as I just learned SwiftUI within the course of 2 days while battling COVID.
More features and UI adjustments will come later.
