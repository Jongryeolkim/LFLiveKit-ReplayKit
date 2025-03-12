//
//  LFHardwareAudioEncoder.m
//  LFLiveKit
//
//  Created by LaiFeng on 16/5/20.
//  Copyright © 2016年 LaiFeng All rights reserved.
//
#import "LFHardwareAudioEncoder.h"

@interface LFHardwareAudioEncoder (){
    AudioConverterRef m_converter;
    char *leftBuf;
    char *aacBuf;
    NSInteger leftLength;
    FILE *fp;
    BOOL enabledWriteVideoFile;
}
@property (nonatomic, strong) LFLiveAudioConfiguration *configuration;
@property (nonatomic, weak) id<LFAudioEncodingDelegate> aacDeleage;

@end

@implementation LFHardwareAudioEncoder

- (instancetype)initWithAudioStreamConfiguration:(nullable LFLiveAudioConfiguration *)configuration {
    if (self = [super init]) {
        NSLog(@"USE LFHardwareAudioEncoder");
        _configuration = configuration;
        
        if (!leftBuf) {
            leftBuf = malloc(_configuration.bufferLength);
        }
        
        if (!aacBuf) {
            aacBuf = malloc(_configuration.bufferLength);
        }
        
        
#ifdef DEBUG
        enabledWriteVideoFile = NO;
        [self initForFilePath];
#endif
    }
    return self;
}

- (void)dealloc {
    if (aacBuf) free(aacBuf);
    if (leftBuf) free(leftBuf);
}

#pragma mark -- LFAudioEncoder
- (void)setDelegate:(id<LFAudioEncodingDelegate>)delegate {
    _aacDeleage = delegate;
}

- (void)encodeAudioData:(CMSampleBufferRef)sampleBuffer timeStamp:(uint64_t)timeStamp {
    if (![self createAudioConvert:sampleBuffer]) {
        return;
    }
    [self encodeBuffer:sampleBuffer timeStamp:timeStamp];
}

- (void)encodeBuffer:(CMSampleBufferRef)buf timeStamp:(uint64_t)timeStamp{
    OSStatus status = noErr;
    CMBlockBufferRef blockBuffer = nil;
    AudioBufferList  inBufferList;
    status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(buf, NULL, &inBufferList, sizeof(inBufferList), NULL, NULL, 0, &blockBuffer);
    if (status != noErr)
    {
        return;
    }
    // 初始化一个输出缓冲列表
    AudioBufferList outBufferList;
    outBufferList.mNumberBuffers = 1;
    outBufferList.mBuffers[0].mNumberChannels = 1;
    outBufferList.mBuffers[0].mDataByteSize = (UInt32)self.configuration.bufferLength;   // 设置缓冲区大小
    outBufferList.mBuffers[0].mData = aacBuf;           // 设置AAC缓冲区
    UInt32 outputDataPacketSize = 1;
    status = AudioConverterFillComplexBuffer(m_converter, inputDataProc, &inBufferList, &outputDataPacketSize, &outBufferList, NULL);
    if (status != noErr) {
        return;
    }
    
    LFAudioFrame *audioFrame = [LFAudioFrame new];
    audioFrame.timestamp = timeStamp;
    audioFrame.data = [NSData dataWithBytes:aacBuf length:outBufferList.mBuffers[0].mDataByteSize];
    
    char exeData[2];
    exeData[0] = _configuration.asc[0];
    exeData[1] = _configuration.asc[1];
    audioFrame.audioInfo = [NSData dataWithBytes:exeData length:2];
    if (self.aacDeleage && [self.aacDeleage respondsToSelector:@selector(audioEncoder:audioFrame:)]) {
//        [self logExtensionDebugInfo:@"音频编码成功"];
        [self.aacDeleage audioEncoder:self audioFrame:audioFrame];
    }
    CFRelease(blockBuffer);
}
- (void)stopEncoder {
    
}

#pragma mark -- CustomMethod
- (BOOL)createAudioConvert:(CMSampleBufferRef)sampleBuffer { //根据输入样本初始化一个编码转换器
    if (m_converter != nil) {
        return TRUE;
    }
    AudioStreamBasicDescription inputFormat = *CMAudioFormatDescriptionGetStreamBasicDescription((CMAudioFormatDescriptionRef)CMSampleBufferGetFormatDescription(sampleBuffer));
    
    AudioStreamBasicDescription outputFormat; // 这里开始是输出音频格式
    memset(&outputFormat, 0, sizeof(outputFormat));
    outputFormat.mSampleRate = inputFormat.mSampleRate;       // 采样率保持一致
    outputFormat.mFormatID = kAudioFormatMPEG4AAC;            // AAC编码 kAudioFormatMPEG4AAC kAudioFormatMPEG4AAC_HE_V2
    outputFormat.mChannelsPerFrame = (UInt32)_configuration.numberOfChannels;
    outputFormat.mFramesPerPacket = 1024;                     // AAC一帧是1024个字节
    outputFormat.mFormatFlags = kMPEG4Object_AAC_LC; // 无损编码 ，0表示没有
    const OSType subtype = kAudioFormatMPEG4AAC;

    AudioClassDescription requestedCodecs[2] = {
        {
            kAudioEncoderComponentType,
            subtype,
            kAppleSoftwareAudioCodecManufacturer
        },
        {
            kAudioEncoderComponentType,
            subtype,
            kAppleHardwareAudioCodecManufacturer
        }
    };
    
    OSStatus result = AudioConverterNewSpecific(&inputFormat, &outputFormat, 2, requestedCodecs, &m_converter);;
    UInt32 outputBitrate = _configuration.audioBitrate;
    UInt32 propSize = sizeof(outputBitrate);
    
    
    if(result == noErr) {
        result = AudioConverterSetProperty(m_converter, kAudioConverterEncodeBitRate, propSize, &outputBitrate);
    }
    
    return YES;
}
#pragma mark -- AudioCallBack
OSStatus inputDataProc(AudioConverterRef inConverter, UInt32 *ioNumberDataPackets, AudioBufferList *ioData, AudioStreamPacketDescription * *outDataPacketDescription, void *inUserData) { //<span style="font-family: Arial, Helvetica, sans-serif;">AudioConverterFillComplexBuffer 编码过程中，会要求这个函数来填充输入数据，也就是原始PCM数据</span>
    ioData->mNumberBuffers = 1;
    AudioBufferList bufferList = *(AudioBufferList *)inUserData;
    ioData->mBuffers[0].mNumberChannels = 1;
    ioData->mBuffers[0].mData = bufferList.mBuffers[0].mData;
    ioData->mBuffers[0].mDataByteSize = bufferList.mBuffers[0].mDataByteSize;
    return noErr;
}


#pragma mark -- Custom Method
/**
 *  Add ADTS header at the beginning of each and every AAC packet.
 *  This is needed as MediaCodec encoder generates a packet of raw
 *  AAC data.
 *
 *  Note the packetLen must count in the ADTS header itself.
 *  See: http://wiki.multimedia.cx/index.php?title=ADTS
 *  Also: http://wiki.multimedia.cx/index.php?title=MPEG-4_Audio#Channel_Configurations
 **/
- (NSData *)adtsData:(NSInteger)channel rawDataLength:(NSInteger)rawDataLength {
    int adtsLength = 7;
    char *packet = malloc(sizeof(char) * adtsLength);
    // Variables Recycled by addADTStoPacket
    int profile = 2;  //AAC LC
    //39=MediaCodecInfo.CodecProfileLevel.AACObjectELD;
    NSInteger freqIdx = [self sampleRateIndex:self.configuration.audioSampleRate];  //44.1KHz
    int chanCfg = (int)channel;  //MPEG-4 Audio Channel Configuration. 1 Channel front-center
    NSUInteger fullLength = adtsLength + rawDataLength;
    // fill in ADTS data
    packet[0] = (char)0xFF;     // 11111111     = syncword
    packet[1] = (char)0xF9;     // 1111 1 00 1  = syncword MPEG-2 Layer CRC
    packet[2] = (char)(((profile-1)<<6) + (freqIdx<<2) +(chanCfg>>2));
    packet[3] = (char)(((chanCfg&3)<<6) + (fullLength>>11));
    packet[4] = (char)((fullLength&0x7FF) >> 3);
    packet[5] = (char)(((fullLength&7)<<5) + 0x1F);
    packet[6] = (char)0xFC;
    NSData *data = [NSData dataWithBytesNoCopy:packet length:adtsLength freeWhenDone:YES];
    return data;
}

- (NSInteger)sampleRateIndex:(NSInteger)frequencyInHz {
    NSInteger sampleRateIndex = 0;
    switch (frequencyInHz) {
        case 96000:
            sampleRateIndex = 0;
            break;
        case 88200:
            sampleRateIndex = 1;
            break;
        case 64000:
            sampleRateIndex = 2;
            break;
        case 48000:
            sampleRateIndex = 3;
            break;
        case 44100:
            sampleRateIndex = 4;
            break;
        case 32000:
            sampleRateIndex = 5;
            break;
        case 24000:
            sampleRateIndex = 6;
            break;
        case 22050:
            sampleRateIndex = 7;
            break;
        case 16000:
            sampleRateIndex = 8;
            break;
        case 12000:
            sampleRateIndex = 9;
            break;
        case 11025:
            sampleRateIndex = 10;
            break;
        case 8000:
            sampleRateIndex = 11;
            break;
        case 7350:
            sampleRateIndex = 12;
            break;
        default:
            sampleRateIndex = 15;
    }
    return sampleRateIndex;
}

- (void)initForFilePath {
    NSString *path = [self GetFilePathByfileName:@"IOSCamDemo_HW.aac"];
    NSLog(@"%@", path);
    self->fp = fopen([path cStringUsingEncoding:NSUTF8StringEncoding], "wb");
}

- (NSString *)GetFilePathByfileName:(NSString*)filename {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsDirectory = [paths objectAtIndex:0];
    NSString *writablePath = [documentsDirectory stringByAppendingPathComponent:filename];
    return writablePath;
}

@end
