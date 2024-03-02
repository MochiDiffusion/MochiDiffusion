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
import GuernikaKit


func CreateMetadata (PositivePrompt: String, NegativePrompt: String, Width: Int, Height: Int, Seed: UInt32, GuidanceScale: Float, Scheduler: Scheduler, StepCount: Int, CurrentModel: String, Upscaler: String, CurrentStyle: String, ComputeUnits: MLComputeUnits)-> NSMutableDictionary{
    var SchedulerString = ""
    var mlComputeUnit = ""
    if Scheduler == .ddim{
        SchedulerString = "DDIM"}
    if Scheduler == .dpmSolverMultistep{
        SchedulerString = "DPM++ 2M"}
    if Scheduler == .dpmSolverMultistepKarras{
        SchedulerString = "DPM++ 2M Karras"}
    if Scheduler == .dpmSolverSinglestep{
        SchedulerString = "DPM++ SDE"}
    if Scheduler == .dpmSolverSinglestepKarras{
        SchedulerString = "DPM++ SDE Karras"}
    if Scheduler == .dpm2{
        SchedulerString = "DPM2"}
    if Scheduler == .dpm2Karras{
        SchedulerString = "DPM2 Karras"}
    if Scheduler == .eulerDiscrete{
        SchedulerString = "Euler"}
    if Scheduler == .eulerDiscreteKarras{
        SchedulerString = "Euler Karras"}
    if Scheduler == .eulerAncenstralDiscrete{
        SchedulerString = "Euler Ancenstral"}
    if Scheduler == .lcm{
        SchedulerString = "LCM"}
    if Scheduler == .pndm{
        SchedulerString = "PNDM"}
    if ComputeUnits == .cpuOnly{
        mlComputeUnit = "cpuOnly"}
    if ComputeUnits == .cpuAndGPU{
        mlComputeUnit = "cpuAndGPU"}
    if ComputeUnits == .cpuAndNeuralEngine{
        mlComputeUnit = "cpuAndNeuralEngine"}
  
    // Add metadata
    let meta = NSMutableDictionary()
    // EXIF Metadata (User Comment)
    let exifMetadata = NSMutableDictionary()
    exifMetadata[kCGImagePropertyExifUserComment as String] = "{\"c\":\"\(PositivePrompt)\", \"uc\":\"\(NegativePrompt)\", \"seed\":\(Seed), \"guidance_scale\":\(GuidanceScale), \"sampler\":\"\(SchedulerString)\", \"steps\":\(StepCount), \"model\":\"\(CurrentModel)\", \"Upscaler\":\"\(Upscaler)\", \"styles\":\"\(CurrentStyle)\"}"
    meta[kCGImagePropertyExifDictionary as String] = exifMetadata
    // IPTC Metadata (Caption)
    let iptcMetadata = NSMutableDictionary()
    
    iptcMetadata[kCGImagePropertyIPTCCaptionAbstract as String] = """
    \(Metadata.includeInImage.rawValue): \(PositivePrompt); \
    \(Metadata.excludeFromImage.rawValue): \(NegativePrompt); \
    \(Metadata.model.rawValue): \(CurrentModel); \
    \(Metadata.steps.rawValue): \(StepCount); \
    \(Metadata.guidanceScale.rawValue): \(GuidanceScale); \
    \(Metadata.seed.rawValue): \(Seed); \
    \(Metadata.size.rawValue): \(Width)x\(Height);
    """
    +
    (!Upscaler.isEmpty ? " \(Metadata.upscaler.rawValue): \(Upscaler); " : " ")
    +
    """
    \(Metadata.scheduler.rawValue): \(Scheduler.rawValue); \
    \(Metadata.mlComputeUnit.rawValue): \(mlComputeUnit); \
    \(Metadata.generator.rawValue): Mochi Diffusion \(NSApplication.appVersion)
    """
    
        meta[kCGImagePropertyIPTCCaptionAbstract as String] = iptcMetadata
        meta[kCGImagePropertyIPTCOriginatingProgram as String] = "Mochi Diffusion"
        meta[kCGImagePropertyIPTCProgramVersion as String] = "\(NSApplication.appVersion)"
        meta[kCGImagePropertyIPTCDictionary as String] = iptcMetadata
    
    // TIFF Metadata (Image Description)
    let tiffMetadata = NSMutableDictionary()
    tiffMetadata[kCGImagePropertyTIFFImageDescription as String] = "c:\(PositivePrompt), uc:\(NegativePrompt), seed:\(Seed), Guidance Scale:\(GuidanceScale), Sampler:\(SchedulerString), Steps:\(StepCount), Model:\(CurrentModel), upscaler:\(Upscaler), Size:\(Width)x\(Height)"
    meta[kCGImagePropertyTIFFDictionary as String] = tiffMetadata
    return meta
}
