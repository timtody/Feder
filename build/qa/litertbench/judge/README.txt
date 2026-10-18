LLM judge for Feder Lab's bench (FED-153)

1. On the iPhone, Feder Lab > Run Bench > Share Report and Data: the .json file holds every run, the raw answers and
   the inputs' text.
2. python3 -I prepare.py <bench-….json> <packets-dir>
   One blind packet per input: transcript, answer key (bench texts: keys/<name>.key.md), the models' summaries under
   shuffled letters. mapping.json (which letter is which model) is for aggregate.py only; judges never see it.
3. A judge (a Claude subagent) reads rubric.md and one packet, and writes <judgements-dir>/<packet>.json in the
   rubric's shape.
4. python3 -I aggregate.py <packets-dir> <judgements-dir> <bench-….json>
   Mean ± sd per model and score, overall by input length, first places, every error listed.

The bench texts are in Lab/BenchTexts (in Feder Lab's bundle only); their keys list what must be covered, the facts,
the tasks and the traps (said first, corrected later). Packets, judgements and reports stay local (they can hold the
user's own transcripts).
