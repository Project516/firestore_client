# Fixtures

`scout_entry_document.json` is a Firestore REST `Document` whose **wire
encoding** was read from a live `frcspectrumstrategy` database on 2026-09-02
via `GET /v1/projects/{p}/databases/(default)/documents/scoutEntries/{id}`.

The encoding is reproduced exactly, because that is what
`FirestoreValueCodec` has to survive:

- `integerValue` is a JSON **string** (`"90"`), not a number.
- `doubleValue` is a bare JSON **number**, even when integral (`96`).
- An **empty map** is `{"mapValue": {}}` with no `fields` key at all.
- `timestampValue` is an ISO-8601 string.
- `booleanValue` is a bare JSON boolean.

Leaf string values are substituted. The real document names the scout who
filed it, and this repository is public. Team number, field names and the
structure are as-read; personal names are not. Anything asserting on the
encoding is therefore testing a real body, and nothing asserts on the
substituted names.
