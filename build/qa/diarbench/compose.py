import json, random, wave, array
LEAD = 0.12                                   # Parakeet's word times lead the audio by about this much
man = json.load(open('utt/manifest.json'))
by = {}
for m in man:
    w = json.load(open(m['path'] + '.words.json'))
    if len(w) < 5: continue
    with wave.open(m['path']) as f: audio = array.array('h', f.readframes(f.getnframes()))
    by.setdefault(m['speaker'], []).append({'words': w, 'audio': audio})
speakers = sorted(by)
SR = 16000
modes = {'normal': dict(turn=(2, 8), gap=(0.3, 1.0), inter=0.10, overlap=0.0),
         'fast':   dict(turn=(0.6, 3), gap=(0.05, 0.3), inter=0.25, overlap=0.0),
         'overlap': dict(turn=(2, 7), gap=(0.2, 0.8), inter=0.10, overlap=0.35)}
plan = [('normal', 2), ('normal', 3), ('normal', 4), ('normal', 2), ('fast', 2), ('fast', 3), ('fast', 4), ('fast', 2),
        ('overlap', 2), ('overlap', 3), ('overlap', 4), ('overlap', 2)]
for k, (mode, n) in enumerate(plan):
    rng = random.Random(1000 + k)
    cfg = modes[mode]
    who = rng.sample(speakers, n)
    cursor = {s: [rng.randrange(len(by[s])), 0] for s in who}       # utterance, word
    mix = [0.0] * (SR * 200)
    truth = []; t = 0.5; prev_end = 0.5; current = None; turn_id = 0
    while t < 180:
        s = rng.choice([x for x in who if x != current]) if current is not None else who[0]
        inter = rng.random() < cfg['inter'] and current is not None
        target = None if inter else rng.uniform(*cfg['turn'])
        u, wi = cursor[s]
        utt = by[s][u]; words = utt['words']
        if wi >= len(words) - 1: u = (u + 1) % len(by[s]); wi = 0; utt = by[s][u]; words = utt['words']
        take = []
        while wi < len(words):
            take.append(words[wi]); wi += 1
            dur = take[-1]['end'] - take[0]['start']
            if (inter and len(take) >= rng.choice([1, 2])) or (not inter and dur >= target): break
        cursor[s] = [u, wi]
        # cut at the middle of the pauses around the words (in audio time = Parakeet time + LEAD)
        first = words.index(take[0]); last = words.index(take[-1])
        a = (words[first - 1]['end'] + take[0]['start']) / 2 if first > 0 else take[0]['start'] - 0.1
        b = (take[-1]['end'] + words[last + 1]['start']) / 2 if last + 1 < len(words) else take[-1]['end'] + 0.15
        a = max(0, a + LEAD); b = b + LEAD
        seg = utt['audio'][int(a * SR):int(b * SR)]
        if current is not None and cfg['overlap'] and rng.random() < cfg['overlap']:
            start = max(0.2, prev_end - rng.uniform(0.2, 0.8))
        else:
            start = prev_end + (rng.uniform(*cfg['gap']) if current is not None else 0)
        i0 = int(start * SR)
        if i0 + len(seg) >= len(mix): break
        for i, v in enumerate(seg): mix[i0 + i] += v / 32768
        for w in take:
            truth.append({'text': w['text'], 'start': start + (w['start'] + LEAD - a) - LEAD, 'end': start + (w['end'] + LEAD - a) - LEAD,
                          'speaker': s, 'turn': turn_id, 'interjection': inter})
        prev_end = max(prev_end, start + len(seg) / SR); current = s; turn_id += 1; t = prev_end
    end = int((prev_end + 0.5) * SR)
    peak = max(1e-6, max(abs(x) for x in mix[:end]))
    out = array.array('h', (int(max(-1, min(1, x / max(1.0, peak))) * 32000) for x in mix[:end]))
    with wave.open(f'meet/m{k:02d}_{mode}_{n}.wav', 'wb') as f:
        f.setnchannels(1); f.setsampwidth(2); f.setframerate(SR); f.writeframes(out.tobytes())
    json.dump(truth, open(f'meet/m{k:02d}_{mode}_{n}.truth.json', 'w'))
    print(k, mode, n, 'speakers', round(prev_end, 1), 's', turn_id, 'turns', len(truth), 'words', sum(1 for w in truth if w['interjection']), 'in interjections')
