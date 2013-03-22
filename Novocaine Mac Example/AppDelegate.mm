#import "AppDelegate.h"

@implementation AppDelegate

@synthesize window = _window;

- (void)dealloc
{
    [super dealloc];
}

#define freqFromNote(note) (440 * pow(2,(note-69)/12))

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

Osc o1, o2, o3;
#define NUM_OSCS 3
Osc oscillators[NUM_OSCS] = {o1, o2, o3};

NSMutableArray *currentlyPlayingNotesInOrder = [NSMutableArray array];
NSMutableSet *currentlyPlayingNotes = [NSMutableSet set];

float pitchBend = 0;
float detune = 0;
float subOscillatorOctavesBelow = 1;
float note;
float amp = 1;

inline void updateFreqs() {
    double notePitched = note + pitchBend;
    oscillators[0].freq = freqFromNote(notePitched);
    oscillators[1].freq = freqFromNote(notePitched + detune);
    oscillators[2].freq = freqFromNote(notePitched - 12 * subOscillatorOctavesBelow);
}


// http://www.musicdsp.org/showone.php?id=185
// cutoff and resonance are from 0 to 127
float cutoff = 0;
float resonance = 0;
float c = 0;
float r = 0;
float v0 = 0;
float v1 = 0;
float fval = 0;

void updateFilter() {
    c = pow(0.5, (128 - cutoff)   / 16.0);
    r = pow(0.5, (resonance + 24) / 16.0);
    fval = 1 - r * c;
}

float filter(float input) {
    v0 = fval * v0 - c * v1 + c * input;
    v1 = fval * v1 + c * v0;

    return v1;
}

void play() {
    float samplingRate = [[Novocaine audioManager] samplingRate];
    [[Novocaine audioManager] setOutputBlock:^(float *data, UInt32 numFrames, UInt32 numChannels)  {
        float sumAmp = 0;
        for (int o = 0; o < NUM_OSCS; ++o)
            sumAmp += oscillators[o].amp;

        for (int i=0; i < numFrames; ++i) {
            float theta = 0;
            for (int o = 0; o < NUM_OSCS; ++o) {
                theta += oscillators[o].amp * (*(oscillators[o].function))(oscillators[o].phase) / sumAmp;
                oscillators[o].phase += 1.0 / (samplingRate / oscillators[o].freq);
                if (oscillators[o].phase > 1.0)
                    oscillators[o].phase = -1;
            }
            theta *= amp;
            
            theta = filter(theta);
            
            // TODO: try to use vDSP_vfill
            //vDSP_vfill(&theta, data, 1, numChannels);
            
            for (int iChannel = 0; iChannel < numChannels; ++iChannel)
                data[i * numChannels + iChannel] = theta;
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
            // http://www.spectrasonics.net/products/legacy/atmosphere-cclist.php
            switch (packet->data[1]) {
                case 74:
                    cutoff = packet->data[2];
                    updateFilter();
                    break;
                case 71:
                    resonance = packet->data[2];
                    updateFilter();
                    break;
                default:
                    detune = (packet->data[2] - 64) / 64.0;
                    updateFreqs();
            }
            break;
        case 0xD0: // after touch
            //detunedOscillator.amp = MIN(packet->data[1] / 64.0, 1);
            NSLog(@"after touch: %d = %f", packet->data[1], o2.amp);
            break;
        case 0xE0: // pitch bend
            pitchBend = combined / (double) 0x1FFF - 1;
            updateFreqs();
            break;
        case 0xF0: // sys stuff, ignore
        default:
            //NSLog(@"%3d %3d %3d", message, note, velocity);
            break;
    }
}

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    // filter init
    cutoff = 127;
    resonance = 0;
    updateFilter();
    oscillators[2].function = &sineOsc;
    amp = 0.1;
    detune = 0.01;
//    // note = 48; // 48 = C3
//    // http://www.phys.unsw.edu.au/jw/notes.html
//    float notes[8] = {48, 50, 52, 53, 55, 57, 59, 60};
//    int i = 0;
//    while (true) {
//        note = notes[i++ % 8];
//        updateFreqs();
//        play();
//        usleep(600000);
//        silence();
//        usleep(300000);
//    }

    //set up midi input
    MIDIClientRef midiClient;
    MIDIEndpointRef src;

    OSStatus result;

    result = MIDIClientCreate(CFSTR("MIDI client"), NULL, NULL, &midiClient);
    if (result != noErr) {
        NSLog(@"Error: %s - %s", GetMacOSStatusErrorString(result), GetMacOSStatusCommentString(result));
        return;
    }

    //note the use of "self" to send the reference to this document object
    result = MIDIDestinationCreate(midiClient, CFSTR("Porta virtuale"), midiInputCallback, self, &src);
    if (result != noErr ) {
        NSLog(@"Error: %s - %s", GetMacOSStatusErrorString(result), GetMacOSStatusCommentString(result));
        return;
    }

    MIDIPortRef inputPort;
    //and again here
    result = MIDIInputPortCreate(midiClient, CFSTR("Input"), midiInputCallback, self, &inputPort);

    ItemCount numOfDevices = MIDIGetNumberOfDevices();

    for (int i = 0; i < numOfDevices; i++) {
        NSDictionary *midiProperties;

        MIDIObjectGetProperties(MIDIGetDevice(i), (CFPropertyListRef *)&midiProperties, YES);
        MIDIPortConnectSource(inputPort, MIDIGetSource(i), NULL);
    }
}

@end
