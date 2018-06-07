//
//  AssetsMerger.swift
//  provaCella
//
//  Created by Salvatore Scotto di Perta on 25/05/2018.
//  Copyright © 2018 teamRocket. All rights reserved.
//

import UIKit
import AVFoundation


/**
 Enumeration to manage the errors of the exporting process
 
 - Functions:
    - .description() -> String
 
        It returns a string description of the occurred error
 */
enum MergeError {
    case videoAssetsNotValid
    case loadingVideoAssetsFailed
    case loadingAudioAssetsFailed
    case generationExportSessionFailed
    case exportSessionFailed
    
    public func description() -> String{
        switch self {
        case .videoAssetsNotValid:
            return "Video assets are not valid, please use a valid array"
            
        case .loadingVideoAssetsFailed:
            return "Can't load video asset(s)"
            
        case .loadingAudioAssetsFailed:
            return "Can't load audio asset(s)"
            
        case .generationExportSessionFailed:
            return "Can't generate an AVExportSession Succesfully"
            
        case .exportSessionFailed:
            return "Asset export failed"
            
        }
    }
}

/**
 Custom Type for Framerates
 *Eg: 30 fps = Framerate (1,30)*
 *value = 1; scale = 30 => frame duration= 1/30 s*
 
 */
public typealias Framerate = (value: Int64, scale:  Int32)

//TODO: Fix the documentation
/**
 Custom class for merging the assets
 
 - Preconditions:
 
    The class needs an array of AVAssets used as video assets and a given resolution (no more than FHD) and framerate (possibly not higher than the orginal video's framerates) for the exit video;
 
    - Optionals:
 
        It can use a given AVAsset as audiotrack (that has to be equal or longer in duration than the final video asset);
 
        The resulting asset will be managed by the completion handler using the AVAssetExportSession that has already be checked for .success
 
        An UIActivityIndicator can be used to have a visual representation of the export process progressing.
 
 - Postconditions:
 
    The startMerge function will generate an AVAssetExportSession on completion that will be managed by the completionHandler parsed as optional parameter in the constructor of the class;
 
    The escaping completionHandler form startMerge can be used to check for errors and inform the user/app the kind of error.
 
 
 */
class AssetsMerger{
    private var assets: [AVAsset?]
    private weak var progressIndicator: UIActivityIndicatorView?
    private var resolution: CGSize = CGSize(width: 1080, height: 1920)
    private var framerate: Framerate = (1,30)
    private var audioTrack: AVAsset?
    
    private var fadeMix: AVMutableAudioMix?
    private var tracks: [AVMutableCompositionTrack]!
    
    private var completionFunction: ((AVAssetExportSession)->Void)? = nil
    
    
    /**
     AssetMerger constructor using all needed parameters
    
     - Parameters:
        - inputAssets: Array containing the video assets that will make up the video composition
        - audio: *Optional* Audio track used for the final video composition
        - res: Resolution of the final Video File
        - frmtime: Framerate of the final Video File
        - activityIndicator: *Optional* Activity Indicator used to have a visual representation of the export process.
        - handler: *Optional* Completion handler for the export session
     *(Takes an AVAssetExportSession as parameter)*
    */
    public init(withAssets inputAssets: [AVAsset?], usingAudioTrack audio: AVAsset?, withResolution res: CGSize, framerate frmtime: Framerate, activityIndicator: UIActivityIndicatorView?, onCompletion handler: ((AVAssetExportSession)->Void)?){
        self.assets = inputAssets
        self.audioTrack = audio
        self.resolution = res
        self.framerate = frmtime
        self.progressIndicator = activityIndicator
        self.completionFunction = handler
    }
    
    /**
     Starts the merge process using the parameters defined in the class initializer
     
     - Parameters:
        - handler: Escaping completion handler used to manage and/or notify possible errors
            *(uses the enumeration MergeError defined before)*
     
        - error: *(of type MergeError?)* Optional error returned by the AssetsMerger
     */
    public func startMerge(handler: @escaping(_ error: MergeError?)->Void){
        
        //Tries to validate the array of assets by checking if the array is not empty and if all the assets making the array are not nil
        guard validateVideoAssets() else {
            handler(.videoAssetsNotValid)
            return
        }
        
        //Initializing a custom dispatchQueue used by the merge process
        let mergingQueue = DispatchQueue.init(label: "com.teamRcoket.videoClipMerger")
        
        //Starting the progress indicator (if present)
        DispatchQueue.main.async {
            self.progressIndicator?.startAnimating()
        }
        
        //Creating the composition in witch the now created tracks will be added
        let mixComposition = AVMutableComposition()
        
        //Loading the assets in the composition and getting the relative tracks, transitionIsntructions and composition duration
        let (_, mutableTracks, optionalInstructions, duration) = loadVideoAssets(
            assetsList: assets as! [AVAsset],
            toComposition: mixComposition)
        
        //Check if the tracks loading went fine
        guard mutableTracks != nil,
            let instructions = optionalInstructions else {
                stopIndicator()
                handler( .loadingVideoAssetsFailed )
                return
        }
        
        tracks = mutableTracks
        
        //Creating the actual video composition
        let mainComposition = AVMutableVideoComposition()
        //Setting up the editing instructions of the compostion, frametime and resolution
        mainComposition.instructions = [instructions]
        mainComposition.frameDuration = CMTimeMake(framerate.value, framerate.scale)
        mainComposition.renderSize = resolution
        
        //Load the audio tracks for the composition and check for errors in the process
        if !loadAudioAsset(toComposition: mixComposition, compositionDuration: duration!){
            stopIndicator()
            handler( .loadingAudioAssetsFailed )
            return
        }
        
        
        //Start of the exporting procedure:
        //Setting up the variables needed for the exporter
        //The filename will contain the current date as identifier
        //TODO: Add something to customize the filename
        let documentDirectory = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0]
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .long
        dateFormatter.timeStyle = .short
        let date = dateFormatter.string(from: NSDate() as Date)
        let savePath = (documentDirectory as NSString).appendingPathComponent("mergedVideo-\(date).mov")
        let url = NSURL(fileURLWithPath: savePath)
        
        //Creating the actual exporter (using FHD preset, as defined in preconditions)
        guard let exporter = AVAssetExportSession(asset: mixComposition, presetName: AVAssetExportPreset1920x1080) else {
            stopIndicator()
            handler( .generationExportSessionFailed )
            return
        }
        
        //Setting up the exporter settings
        exporter.outputURL = url as URL
        exporter.outputFileType = AVFileType.mp4
        exporter.shouldOptimizeForNetworkUse = false
        
        //Apply the transformations needed to the exporter
        exporter.videoComposition = mainComposition
        
        //If an audioMix is set, add it to the exporter settings
        if let fadeMix = fadeMix {
            exporter.audioMix = fadeMix
        }
        
        //Begin the export process
        exporter.exportAsynchronously {
            //Getting the result asynchronously
            mergingQueue.async {
                //If the export process completed without errors
                if exporter.status == .completed{
                    //Call the completion handler defined in the init
                    self.exportDidFinish(session: exporter)
                    //Call the escaping handler from startMerge
                    handler(nil)
                }else{
                    self.stopIndicator()
                    handler( .exportSessionFailed )
                }
            }
        }
        
    }
    
    //Function used to stop the optional activity indicator
    private func stopIndicator(){
        DispatchQueue.main.async {
            self.progressIndicator?.stopAnimating()
        }
    }
    
    //Function called upon reaching the .completed state for the export session
    //It is used to call the possible completionFunction defined in the initializer
    func exportDidFinish(session: AVAssetExportSession){
        if session.status == .completed{
            print("Done")
            self.completionFunction?(session)
        }
        DispatchQueue.main.async {
            self.progressIndicator?.stopAnimating()
        }
    }
    
    
    private func loadAudioAsset(toComposition composition: AVMutableComposition, compositionDuration: CMTime, startingAt: CMTime? = nil, fadeTime: CMTime? = nil) -> Bool{
        var audioMutableTrack: AVMutableCompositionTrack?
        if let audioTrackAsset = self.audioTrack {
            audioMutableTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: 0)
            
            do{
                let duration = compositionDuration
                try audioMutableTrack?.insertTimeRange(
                    CMTimeRangeMake(
                        startingAt ?? kCMTimeZero,
                        duration),
                    of: audioTrackAsset.tracks(
                        withMediaType: .audio).first!,
                    at: kCMTimeZero
                )
                
                if let unwrappedFadeTime = fadeTime{
                    let mixParams = AVMutableAudioMixInputParameters(track: audioMutableTrack)
                    
                    mixParams.setVolumeRamp(
                        fromStartVolume: 0.0,
                        toEndVolume: 1.0,
                        timeRange: CMTimeRangeMake(
                            kCMTimeZero,
                            unwrappedFadeTime
                        )
                    )
                    
                    mixParams.setVolumeRamp(
                        fromStartVolume: 1.0,
                        toEndVolume: 0.0,
                        timeRange: CMTimeRangeMake(
                            CMTimeSubtract(duration, unwrappedFadeTime),
                            unwrappedFadeTime
                        )
                    )
                    
                    self.fadeMix = AVMutableAudioMix()
                    fadeMix!.inputParameters = [mixParams]
                }
                
                
            }catch let err{
                print(err)
                return false
            }
        }else{
            var curTime = kCMTimeZero
            audioMutableTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: 0)
            for asset in (self.assets as! [AVAsset]) {
                do{
                    try audioMutableTrack!.insertTimeRange(
                        CMTimeRange(
                            start: kCMTimeZero,
                            duration: asset.duration),
                        of: asset.tracks(withMediaType: .audio).first!,
                        at: curTime)
                    curTime = CMTimeAdd(curTime, asset.duration)
                }catch let err{
                    print(err)
                    return false
                }
            }
        }
        
        return true
    }
    
    
    private func loadVideoAssets(assetsList: [AVAsset], toComposition composition: AVMutableComposition) -> (Bool, [AVMutableCompositionTrack]?, AVMutableVideoCompositionInstruction?, CMTime?){
        
        let timeZero = kCMTimeZero
        var currentDuration: CMTime = timeZero
        var tracks: [AVMutableCompositionTrack] = []
        
        for asset in assetsList{
            guard let track = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: Int32(kCMPersistentTrackID_Invalid)) else {
                    return (false,  nil, nil, nil)
            }
            do{
                try track.insertTimeRange(
                    CMTimeRangeMake(timeZero, asset.duration),
                    of: asset.tracks(withMediaType: .video).first!,
                    at: currentDuration)
                tracks.append(track)
                currentDuration = CMTimeAdd(currentDuration, asset.duration)
            }catch let assetLoadingError{
                print(assetLoadingError)
                return (false, nil, nil, nil)
            }
        }
        
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRangeMake(timeZero, currentDuration)
        
        var stepTime: CMTime = timeZero
        var trackInstructions: [AVMutableVideoCompositionLayerInstruction] = []
        for i in 0..<(tracks.count) {
            let inst = videoCompositionInstructionForTrack(
                track: tracks[i],
                asset: assetsList[i])
            stepTime = CMTimeAdd(stepTime, assetsList[i].duration)
            if (i != (tracks.count - 1)){
                inst.setOpacity(0.0, at: stepTime)
            }
            trackInstructions.append(inst)
        }
        instruction.layerInstructions = trackInstructions

        
        return (true, tracks, instruction, currentDuration)
    }
    
    
    private func validateVideoAssets()->Bool{
        guard assets.count > 0 else {return false}
        var i = assets.count
        while i > 0 {
            i -= 1
            guard assets[i] != nil else {return false}
        }
        return true
    }
    
    
    
    private func orientationFromTransform(transform: CGAffineTransform) -> (orientation: UIImageOrientation, isPortrait: Bool) {
        var assetOrientation = UIImageOrientation.up
        var isPortrait = false
        if transform.a == 0 && transform.b == 1.0 && transform.c == -1.0 && transform.d == 0 {
            assetOrientation = .right
            isPortrait = true
        } else if transform.a == 0 && transform.b == -1.0 && transform.c == 1.0 && transform.d == 0 {
            assetOrientation = .left
            isPortrait = true
        } else if transform.a == 1.0 && transform.b == 0 && transform.c == 0 && transform.d == 1.0 {
            assetOrientation = .up
        } else if transform.a == -1.0 && transform.b == 0 && transform.c == 0 && transform.d == -1.0 {
            assetOrientation = .down
        }
        return (assetOrientation, isPortrait)
    }
    
    private func videoCompositionInstructionForTrack(track: AVCompositionTrack, asset: AVAsset) -> AVMutableVideoCompositionLayerInstruction {
        let instruction = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        let assetTrack = asset.tracks(withMediaType: AVMediaType.video)[0]
        
        let transform = assetTrack.preferredTransform
        let assetInfo = orientationFromTransform(transform: transform)
        
        var scaleToFitRatio = resolution.width / assetTrack.naturalSize.width
        if assetInfo.isPortrait {
            scaleToFitRatio = resolution.width / assetTrack.naturalSize.height
            let scaleFactor = CGAffineTransform(scaleX: scaleToFitRatio, y: scaleToFitRatio)
            instruction.setTransform(assetTrack.preferredTransform.concatenating(scaleFactor),
                                     at: kCMTimeZero)
        } else {
            let scaleFactor = CGAffineTransform(scaleX: scaleToFitRatio, y: scaleToFitRatio)
            var concat = assetTrack.preferredTransform.concatenating(scaleFactor).concatenating(CGAffineTransform(translationX: 0, y: resolution.width / 2))
            if assetInfo.orientation == .down {
                let fixUpsideDown = CGAffineTransform(rotationAngle: CGFloat.pi)
                let windowBounds = resolution
                let yFix = assetTrack.naturalSize.height + windowBounds.height
                let centerFix = CGAffineTransform(translationX: assetTrack.naturalSize.width, y: yFix)
                concat = fixUpsideDown.concatenating(centerFix).concatenating(scaleFactor)
                
            }
            instruction.setTransform(concat, at: kCMTimeZero)
        }
        return instruction
    }
}
