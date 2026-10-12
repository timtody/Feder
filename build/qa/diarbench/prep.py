# Decodes MLS German test utterances of 16 speakers (12 each, longest first) to 16 kHz mono WAV.
import pyarrow.parquet as pq, subprocess, json, collections, os
t = pq.read_table('data/test.parquet', columns=['audio', 'speaker_id', 'id', 'audio_duration', 'transcript']).to_pylist()
by = collections.defaultdict(list)
for r in t: by[r['speaker_id']].append(r)
print(len(by), 'speakers;', sorted((len(v) for v in by.values()), reverse=True)[:20])
speakers = sorted(by, key=lambda s: -len(by[s]))[:16]
manifest = []
for s in speakers:
    for r in sorted(by[s], key=lambda r: -r['audio_duration'])[:12]:
        out = f"utt/{r['id']}.wav"
        if not os.path.exists(out):
            subprocess.run(['ffmpeg', '-v', 'error', '-y', '-i', 'pipe:0', '-ac', '1', '-ar', '16000', '-c:a', 'pcm_s16le', out],
                           input=r['audio']['bytes'], check=True)
        manifest.append({'id': r['id'], 'speaker': s, 'path': out, 'duration': r['audio_duration'], 'transcript': r['transcript']})
json.dump(manifest, open('utt/manifest.json', 'w'), indent=1)
print(len(manifest), 'utterances,', round(sum(m['duration'] for m in manifest) / 60, 1), 'min')
