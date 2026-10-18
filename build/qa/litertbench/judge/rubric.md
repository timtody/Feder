# Judge rubric: Feder summaries (FED-153)

You judge short summaries that an on-device model wrote of a transcript. Feder shows the title and the summary on a
transcript's card; the person who recorded reads them to remember what happened. The app asked the model for: a title of
2 to 6 words, and a summary of two or three short sentences covering every topic with its concrete content (results,
decisions, dates, numbers, names, who does what), in the third person, stating facts rather than describing the
conversation ("Anna moves the budget", not "Anna and Jonas discuss the budget"). The summary is written in the app's
language, which may differ from the transcript's.

You get the transcript, for bench texts an answer key (what must be covered, the facts, the tasks, and the traps: things
said first and corrected later), and two to four summaries labelled A, B, C, D in random order. You do not know which
model wrote which. Judge each on its own against the transcript; then compare.

Score each summary 1-5 on:

- **coverage**: are the main topics and outcomes there? 5 = every main outcome; 3 = about half; 1 = misses the point.
  Two or three sentences can't hold everything: reward choosing what matters most (decisions and tasks over chatter).
- **accuracy**: is everything stated true to the transcript? 5 = no errors; 4 = one minor imprecision; 3 = one real
  error (a wrong number, name, date, or a trap fallen for: stating what was corrected later); 2 = two or more real
  errors; 1 = mostly wrong or invented. A misheard word repeated as heard is not an error; a misheard word "corrected"
  wrongly is.
- **specificity**: concrete numbers, dates, names and owners instead of generic phrases. 5 = several precise facts;
  1 = nothing but generic statements.
- **language**: correct, fluent sentences in the summary's language; no broken, fused or misspelled words, no unfinished
  sentence, no labels or Markdown left in. 5 = flawless; 3 = one broken word or clumsy sentence; 1 = hard to read.
- **form**: follows the request: two or three sentences (four is a small slip), facts not meta-description, third person.
- **title**: 2 to 6 words, names the actual subject, no filler. 1 if missing.

A summary shown as "(no summary)" means the app got nothing usable and would show no summary: score it 1 on everything.

Then give each summary an **overall** score 1-10 (your judgment as a reader of the card, not an average), list its
**errors** (each a short phrase, empty if none) and note in one sentence what distinguishes it.

Answer with JSON only, in this shape:

```json
{
  "input": "<input id>",
  "scores": {
    "A": {"coverage": 4, "accuracy": 5, "specificity": 3, "language": 5, "form": 5, "title": 4, "overall": 8,
          "errors": [], "note": "..."},
    "B": {"...": "..."}
  },
  "ranking": ["A", "B", "C"]
}
```
