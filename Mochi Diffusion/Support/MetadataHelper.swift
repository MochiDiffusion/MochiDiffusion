//
//  MetadataHelper.swift
//  Mochi Diffusion
//
//  Created by Jones on 18/02/2024.
//

import Foundation
import CoreGraphics
import AppKit
import CoreML
// import GuernikaKit
import StableDiffusion

func CreateMetadata (positivePrompt: String, negativePrompt: String, width: Int, height: Int, seed: UInt32, guidanceScale: Float, scheduler: Scheduler, stepCount: Int, currentModel: String, upscaler: String, currentStyle: String, computeUnits: MLComputeUnits)-> NSMutableDictionary{
    var schedulerString = ""
    var mlComputeUnit = ""
    /// Schedulers for ML-Stable-diffusion
    if scheduler == .pndmScheduler{
        schedulerString = "PNDM"}
    if scheduler == .dpmSolverMultistepScheduler{
        schedulerString = "DPM-Solver++"}
    
    /// Schedulers for Guernika kit
//    if Scheduler == .ddim{
//        SchedulerString = "DDIM"}
//    if Scheduler == .dpmSolverMultistep{
//        SchedulerString = "DPM++ 2M"}
//    if Scheduler == .dpmSolverMultistepKarras{
//        SchedulerString = "DPM++ 2M Karras"}
//    if Scheduler == .dpmSolverSinglestep{
//        SchedulerString = "DPM++ SDE"}
//    if Scheduler == .dpmSolverSinglestepKarras{
//        SchedulerString = "DPM++ SDE Karras"}
//    if Scheduler == .dpm2{
//        SchedulerString = "DPM2"}
//    if Scheduler == .dpm2Karras{
//        SchedulerString = "DPM2 Karras"}
//    if Scheduler == .eulerDiscrete{
//        SchedulerString = "Euler"}
//    if Scheduler == .eulerDiscreteKarras{
//        SchedulerString = "Euler Karras"}
//    if Scheduler == .eulerAncenstralDiscrete{
//        SchedulerString = "Euler Ancenstral"}
//    if Scheduler == .lcm{
//        SchedulerString = "LCM"}
//    if Scheduler == .pndm{
//        SchedulerString = "PNDM"}
    
    
    if computeUnits == .cpuOnly{
        mlComputeUnit = "cpuOnly"}
    if computeUnits == .cpuAndGPU{
        mlComputeUnit = "cpuAndGPU"}
    if computeUnits == .cpuAndNeuralEngine{
        mlComputeUnit = "cpuAndNeuralEngine"}
  
    // Add metadata
    let meta = NSMutableDictionary()
    // EXIF Metadata (User Comment) - used by most other apps "c" and "uc" for prompts are established naming conventions kept for compatability.
    let exifMetadata = NSMutableDictionary()
    exifMetadata[kCGImagePropertyExifUserComment as String] = "{\"c\":\"\(positivePrompt)\", \"uc\":\"\(negativePrompt)\", \"seed\":\(seed), \"guidance_scale\":\(guidanceScale), \"sampler\":\"\(schedulerString)\", \"steps\":\(stepCount), \"model\":\"\(currentModel)\", \"Upscaler\":\"\(upscaler)\", \"styles\":\"\(currentStyle)\"}"
    meta[kCGImagePropertyExifDictionary as String] = exifMetadata
    // IPTC Metadata (Caption)
    let iptcMetadata = NSMutableDictionary()
    
    iptcMetadata[kCGImagePropertyIPTCCaptionAbstract as String] = """
    \(Metadata.includeInImage.rawValue): \(positivePrompt); \
    \(Metadata.excludeFromImage.rawValue): \(negativePrompt); \
    \(Metadata.model.rawValue): \(currentModel); \
    \(Metadata.steps.rawValue): \(stepCount); \
    \(Metadata.guidanceScale.rawValue): \(guidanceScale); \
    \(Metadata.seed.rawValue): \(seed); \
    \(Metadata.size.rawValue): \(width)x\(height);
    """
    +
    (!upscaler.isEmpty ? " \(Metadata.upscaler.rawValue): \(upscaler); " : " ")
    +
    """
    \(Metadata.scheduler.rawValue): \(scheduler.rawValue); \
    \(Metadata.mlComputeUnit.rawValue): \(mlComputeUnit); \
    \(Metadata.generator.rawValue): Mochi Diffusion \(NSApplication.appVersion)
    """
    
        meta[kCGImagePropertyIPTCCaptionAbstract as String] = iptcMetadata
        meta[kCGImagePropertyIPTCOriginatingProgram as String] = "Mochi Diffusion"
        meta[kCGImagePropertyIPTCProgramVersion as String] = "\(NSApplication.appVersion)"
        meta[kCGImagePropertyIPTCDictionary as String] = iptcMetadata
    
    // TIFF Metadata (Image Description)
    let tiffMetadata = NSMutableDictionary()
    tiffMetadata[kCGImagePropertyTIFFImageDescription as String] = "c:\(positivePrompt), uc:\(negativePrompt), seed:\(seed), Guidance Scale:\(guidanceScale), Sampler:\(schedulerString), Steps:\(stepCount), Model:\(currentModel), upscaler:\(upscaler), Size:\(width)x\(height)"
    meta[kCGImagePropertyTIFFDictionary as String] = tiffMetadata
    return meta
}
