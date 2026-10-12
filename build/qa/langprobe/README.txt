Language probe bench (Recorder/Services/LanguageProbe.swift, README › Import).
  ./probe <seconds> <skip> files…        harness: transcribe each file in de_DE and en_US, confidences, NLLanguageRecognizer, pick
  app/probe files…                       the app's own LanguageProbe (CHOSEN=en-US to choose English; German by default), built with:
    swiftc -O -swift-version 6 -o app/probe ../../../Recorder/Services/LanguageProbe.swift app/main.swift
de/, en/, fr/: synthetic speech (say -v …); real German: ../diarbench/meet and ../diarbench/utt (Multilingual LibriSpeech).
Needs Apple's de_DE and en_US speech assets installed on the Mac.
The mixed file (German meeting with 36 s of English at 18 s), as the final review made it:
  ffmpeg -i ../diarbench/meet/m00_normal_2.wav -t 18 -ar 16000 -ac 1 a.wav; ffmpeg -i en/en0.aiff -i en/en1.aiff \
    -filter_complex "[0:a][1:a]concat=n=2:v=0:a=1,aresample=16000" -ac 1 b.wav; ffmpeg -ss 18 -i ../diarbench/meet/m00_normal_2.wav \
    -ar 16000 -ac 1 c.wav; ffmpeg -i a.wav -i b.wav -i c.wav -filter_complex "[0:a][1:a][2:a]concat=n=3:v=0:a=1" -c:a pcm_s16le mixed.wav
