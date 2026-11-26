#!/bin/zsh
# Builds stereo test recordings of a call as the Mac records it with its sound: the left channel is the microphone
# (voice A, the user), the right channel the Mac's sound (voices B and C, the others, taking turns).
#
#   scripts/make-meeting-fixture.sh [output folder]   (default: /tmp/porridge-fixtures)
#
# Writes two 48 kHz 16-bit WAV files:
#   meeting-fixture.wav       clean channels
#   meeting-fixture-echo.wav  the same, with the right channel also on the left, 80 ms later and 15 dB quieter
#                             (the loudspeaker picked up by the microphone)
# Voices can be changed with VOICE_A, VOICE_B, VOICE_C (see `say -v '?'`).
#
# Import one into a debug build of the Mac app with the debug driver (PORRIDGE_DEBUG_DRIVER set):
#   echo "import-meeting /tmp/porridge-fixtures/meeting-fixture-echo.wav" > "$TMPDIR/porridge-debug-commands"
#   echo "speakers meeting-fixture-echo" > "$TMPDIR/porridge-debug-commands"   (once it is transcribed)
set -euo pipefail

OUT=${1:-/tmp/porridge-fixtures}
VOICE_A=${VOICE_A:-Samantha}
VOICE_B=${VOICE_B:-Daniel}
VOICE_C=${VOICE_C:-Karen}
RATE=48000
mkdir -p "$OUT"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Turns in order: voice letter, text. B and C each speak well over eight seconds in all, so speaker detection keeps
# both as people of their own.
TURNS=(
  "A|Good morning everyone, thanks for joining. Let's go through the launch plan for next week."
  "B|Morning. The marketing material is ready, the landing page goes live on Monday and the newsletter follows on Tuesday."
  "A|Great. What about the pricing page, is that finished as well?"
  "C|Not yet. We are still waiting for the final numbers from finance, I expect them by Thursday afternoon."
  "B|I can help with the copy once the numbers are in, the layout itself is already done."
  "C|That would be helpful. I will send you the draft as soon as finance confirms the prices."
  "A|Perfect. Then we meet again on Friday morning to check everything before the launch."
  "B|Sounds good to me. I will book the room and send out an invitation today."
  "C|Agreed. One more thing, the support team needs the frequently asked questions by Wednesday."
  "A|Noted, I will write them tomorrow. Thanks everyone, talk to you on Friday."
)

index=0
for turn in "${TURNS[@]}"; do
  voice_letter=${turn%%|*}
  text=${turn#*|}
  case $voice_letter in
    A) voice=$VOICE_A ;;
    B) voice=$VOICE_B ;;
    C) voice=$VOICE_C ;;
  esac
  say -v "$voice" -o "$WORK/$(printf %02d $index)-$voice_letter.wav" --data-format=LEI16@$RATE "$text"
  index=$((index + 1))
done

python3 -I - "$WORK" "$OUT" "$RATE" <<'PY'
import array, glob, os, sys, wave

work, out, rate = sys.argv[1], sys.argv[2], int(sys.argv[3])
gap = int(0.6 * rate)          # silence between turns
delay = int(0.080 * rate)      # loudspeaker to microphone
echo_gain = 10 ** (-15 / 20)   # -15 dB

def read(path):
    with wave.open(path) as w:
        assert w.getsampwidth() == 2 and w.getframerate() == rate, path
        data = array.array("h", w.readframes(w.getnframes()))
        if w.getnchannels() > 1:
            data = data[::w.getnchannels()]
        return [s / 32768 for s in data]

left, right = [], []
for path in sorted(glob.glob(os.path.join(work, "*.wav"))):
    samples = read(path)
    mine = path.endswith("-A.wav")
    pad = [0.0] * gap
    left += (samples if mine else [0.0] * len(samples)) + pad
    right += ([0.0] * len(samples) if mine else samples) + pad

def write(path, l, r):
    frames = array.array("h")
    for a, b in zip(l, r):
        frames.append(max(-32768, min(32767, int(a * 32767))))
        frames.append(max(-32768, min(32767, int(b * 32767))))
    with wave.open(path, "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(frames.tobytes())
    print(f"{path}: {len(l) / rate:.1f} s")

write(os.path.join(out, "meeting-fixture.wav"), left, right)
echoed = [l + (right[i - delay] * echo_gain if i >= delay else 0.0) for i, l in enumerate(left)]
write(os.path.join(out, "meeting-fixture-echo.wav"), echoed, right)
PY
