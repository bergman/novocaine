#import "AppDelegate.h"

@implementation AppDelegate

@synthesize window = _window;

- (void)dealloc
{
    [super dealloc];
}

static inline double sineOsc(double phase){
    return sin(phase * M_PI * 2);
}

static inline double squareOsc(double phase){
    return signbit(phase);
}

static inline double sawOsc(double phase){
    return phase;
}

typedef double (*oscFunction)(double);

struct Osc {
    double amp = 1;
    double freq = 440;
    double phase = 0;
    oscFunction function = &sawOsc;
};

static inline float freqFromNote(double note) {
    return 440 * pow(2,(note-69)/12);
}

Osc o1, detunedOscillator, sub;

NSMutableArray *currentlyPlayingNotesInOrder = [NSMutableArray array];
NSMutableSet *currentlyPlayingNotes = [NSMutableSet set];

float pitchBend = 0;
float detune = 0;
float subOscillatorOctavesBelow = 1;
float note;

inline void updateFreqs() {
    double notePitched = note + pitchBend;
    o1.freq = freqFromNote(notePitched);
    detunedOscillator.freq = freqFromNote(notePitched + detune);
    sub.freq = freqFromNote(notePitched - 12 * subOscillatorOctavesBelow);
}

void play() {
    [[Novocaine audioManager] setOutputBlock:^(float *data, UInt32 numFrames, UInt32 numChannels)  {
        float samplingRate = [[Novocaine audioManager] samplingRate];
        float sumAmp = o1.amp + detunedOscillator.amp + sub.amp;
        for (int i=0; i < numFrames; ++i) {
            float theta = 0;
            theta += o1.amp * (*o1.function)(o1.phase) / sumAmp;
            theta += detunedOscillator.amp * (*detunedOscillator.function)(detunedOscillator.phase) / sumAmp;
            theta += sub.amp * (*sub.function)(sub.phase) / sumAmp;
            
            for (int iChannel = 0; iChannel < numChannels; ++iChannel)
                data[i * numChannels + iChannel] = theta;
            
            o1.phase += 1.0 / (samplingRate / o1.freq);
            detunedOscillator.phase += 1.0 / (samplingRate / detunedOscillator.freq);
            sub.phase += 1.0 / (samplingRate / sub.freq);
            
            if (o1.phase > 1.0) o1.phase = -1;
            if (detunedOscillator.phase > 1.0) detunedOscillator.phase = -1;
            if (sub.phase > 1.0) sub.phase = -1;
        }
    }];
}

void silence() {
    [[Novocaine audioManager] setOutputBlock:^(float *data, UInt32 numFrames, UInt32 numChannels) {
        memset(data, 0, numFrames * numChannels * sizeof(float));
    }];
}

static inline unsigned short CombineBytes(unsigned char First, unsigned char Second) {
    unsigned short combined = (unsigned short)Second;
    combined <<= 7;
    combined |= (unsigned short)First;
    return combined;
}

void midiInputCallback (const MIDIPacketList *packetList, void *procRef, void *srcRef) {
    const MIDIPacket *packet = packetList->packet;
    int combined = CombineBytes(packet->data[1], packet->data[2]);
    
    NSNumber *noteNumber = [NSNumber numberWithInt:packet->data[1]];
    
    switch (packet->data[0] & 0xF0) {
        case 0x80: // note off
            [currentlyPlayingNotes removeObject:noteNumber];
            
            // ta bort senaste noterna om de inte spelas längre
            while ([currentlyPlayingNotesInOrder count] > 0 && ![currentlyPlayingNotes containsObject:[currentlyPlayingNotesInOrder lastObject]])
                [currentlyPlayingNotesInOrder removeLastObject];
            
            if ([currentlyPlayingNotesInOrder count] > 0) {
                note = (int)[[currentlyPlayingNotesInOrder lastObject] integerValue];
                updateFreqs();
            } else {
                silence();
            }
            break;
        case 0x90: // note on
            [currentlyPlayingNotesInOrder addObject:noteNumber];
            [currentlyPlayingNotes addObject:noteNumber];
            note = packet->data[1];
            updateFreqs();
            play();
            break;
        case 0xB0: // control change
            detune = (packet->data[2] - 64) / 64.0;
            updateFreqs();
            //NSLog(@"detune: %f", detune);
            break;
        case 0xD0: // after touch, 2nd oscillator amplification
            detunedOscillator.amp = MIN(packet->data[1] / 64.0, 1);
            NSLog(@"after touch: %d = %f", packet->data[1], detunedOscillator.amp);
            break;
        case 0xE0: // pitch bend
            pitchBend = combined / (double) 0x1FFF - 1;
            updateFreqs();
            break;
        case 0xF0: // sys stuff, ignore
            break;
        default:
            //NSLog(@"%3d %3d %3d", message, note, velocity);
            break;
    }
}

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    sub.function = &sineOsc;
    detunedOscillator.amp = 0;
    
//    detunedOscillator.amp = 1;
//    detune = 0.1;
//    note = 48;
//    updateFreqs();
//    play();
    
    //set up midi input
    MIDIClientRef midiClient;
    MIDIEndpointRef src;
    
    OSStatus result;
    
    result = MIDIClientCreate(CFSTR("MIDI client"), NULL, NULL, &midiClient);
    if (result != noErr) {
        NSLog(@"Errore : %s - %s",
              GetMacOSStatusErrorString(result),
              GetMacOSStatusCommentString(result));
        return;
    }
    
    //note the use of "self" to send the reference to this document object
    result = MIDIDestinationCreate(midiClient, CFSTR("Porta virtuale"), midiInputCallback, self, &src);
    if (result != noErr ) {
        NSLog(@"Errore : %s - %s",
              GetMacOSStatusErrorString(result),
              GetMacOSStatusCommentString(result));
        return;
    }
    
    MIDIPortRef inputPort;
    //and again here
    result = MIDIInputPortCreate(midiClient, CFSTR("Input"), midiInputCallback, self, &inputPort);
    
    ItemCount numOfDevices = MIDIGetNumberOfDevices();
    
    for (int i = 0; i < numOfDevices; i++) {
        NSDictionary *midiProperties;
        
        MIDIObjectGetProperties(MIDIGetDevice(i), (CFPropertyListRef *)&midiProperties, YES);
        MIDIEndpointRef src = MIDIGetSource(i);
        MIDIPortConnectSource(inputPort, src, NULL);
    }
}

@end
