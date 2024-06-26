<p align="center">
<img height="256" src="https://github.com/MochiDiffusion/MochiDiffusion/raw/main/Mochi Diffusion/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png" />
</p>

<h1 align="center">Mochi Diffusion</h1>

<p align="center">在 Mac 上原生运行 Stable Diffusion</p>

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

## 简介

本应用内置 [Apple 的 Core ML Stable Diffusion 框架](https://github.com/apple/ml-stable-diffusion) 以实现在搭载 Apple 芯片的 Mac 上用极低的内存占用发挥出最优性能。

## 功能

- 极致性能和极低内存占用 (使用神经网络引擎时 ~150MB)
- 在所有搭载 Apple 芯片的 Mac 上充分发挥神经网络引擎的优势
- 生成图像时无需联网
- 图像转图像（Image2Image）
- 使用 ControlNet 生成图像
- 在图像的 EXIF 信息中存储所有的关键词（在访达的“显示简介”窗口中查看）
- 使用 RealESRGAN 放大生成的图像
- 自动保存 & 恢复图像
- 自定义 Stable Diffusion Core ML 模型
- 无需担心损坏的模型
- 使用 macOS 原生框架 SwiftUI 开发

## 下载

在 [发行](https://github.com/MochiDiffusion/MochiDiffusion/releases) 页面下载最新版本。

## 运行

在初次运行模型时, 神经网络引擎可能需要约2分钟编译缓存，后续运行速度会显著提高。

## 计算单元

- `CPU 和神经网络引擎` 能很好地平衡性能和内存占用
- `CPU 和 GPU` 在 M1 Max/Ultra 及后续型号上可能更快，但会占用更多内存

你需要根据不同的计算单元选择对应的模型 (详情见模型部分)。

## 模型

你需要自行转换或下载 Core ML 模型以使用 Mochi Diffusion。

[这里](https://huggingface.co/coreml-community) 上传了几个已经转换好的模型

1. [转换](https://github.com/MochiDiffusion/MochiDiffusion/wiki/How-to-convert-Stable-Diffusion-models-to-Core-ML) 或下载 Core ML 模型
    - `split_einsum` 版本适用于包括神经网络引擎在内的所有计算单元
    - `original` 版本仅适用于 `CPU 和 GPU`
2. 默认情况下，应用程序的模型文件夹将创建在您的主目录下。 可以在“设置”下自定义此位置
3. 在模型文件夹中，你可以新建一个文件夹，用自己想在应用内显示的名字为其重命名，再将转换好的模型放到文件夹中
4. 你的文件夹路径应该像这样:
```
<主目录>/
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

## 兼容性

- Apple 芯片的 Mac (M1 及后续)
- macOS Sonoma 14.0 以上
- Xcode 15.2 (自行构建)

## 隐私

所有计算均在本地完成并绝对不会上传任何数据。

## 贡献

无论是修复 bug，新增代码，还是完善翻译，Mochi Diffusion 欢迎你的贡献。

- 如果你发现了一个bug，或者有新的建议和想法，请先在这里[搜索议题](https://github.com/MochiDiffusion/MochiDiffusion/issues)以避免重复。在确认没有重复后，你可以[创建一个新议题](https://github.com/MochiDiffusion/MochiDiffusion/issues/new/choose)。

- 如果你想贡献代码，请[创建拉取请求](https://github.com/MochiDiffusion/MochiDiffusion/pulls)或[发起一个新的讨论](https://github.com/MochiDiffusion/MochiDiffusion/discussions)来探讨。我个人推荐安装 [swift-format](https://github.com/apple/swift-format#getting-swift-format) 以规范代码格式。

- 如果你想对 Mochi Diffusion 贡献翻译，请到项目的 [Crowdin 页面](https://crowdin.com/project/mochi-diffusion)，你可以免费创建一个账户然后开始翻译。

## 致谢

- [Apple's Core ML Stable Diffusion implementation](https://github.com/apple/ml-stable-diffusion)
- [Hugging Face's Swift UI sample implementation](https://github.com/huggingface/swift-coreml-diffusers)
- 应用图标作者 [Zabriskije](https://github.com/Zabriskije)
